-- 問題パネル（VSCode の Problems パネル相当）
--
-- 開いているバッファ全体の診断をファイルごとにまとめて下部パネルに並べ、Enter で
-- 該当箇所へ飛ぶ。既存の [d / ]d は「今のファイルの中を順に見る」ものなので、
-- 「どのファイルにいくつ問題があるか」を俯瞰する手段がこれまで無かった。
--
-- 注意: LSP の診断は「サーバーが報告したぶん」しか無い。プロジェクト全体を
-- 常時インデックスする VSCode と違い、まだ開いていないファイルの問題は出ないことがある
-- （gopls / tsserver のようにプロジェクト単位で報告するサーバーは出る）。

local win_util      = require('config.util.win_util')
local hidden_cursor = require('config.hidden_cursor')

local M = {}

local win        = nil
local buf        = nil
local meta       = {}  -- パネルの行番号(1-based) -> 診断項目（ヘッダ行や空行は nil）
local item_lnums = {}  -- 診断が乗っている行番号（昇順）。カーソル吸着で使う
local last_lnum  = nil -- 直前のカーソル行（吸着の向きを決めるため）
local hl_ns   = vim.api.nvim_create_namespace('problems_hl')
local augrp   = vim.api.nvim_create_augroup('problems', { clear = true })

local S = vim.diagnostic.severity

M.PANEL_HEIGHT = 12

-- フィルタ（f キーで巡回）。min はこの重要度以上だけ出す
M.FILTERS = {
  { name = 'すべて',       min = S.HINT },
  { name = 'エラー+警告',  min = S.WARN },
  { name = 'エラーのみ',   min = S.ERROR },
}
local filter_idx = 1

local SEVERITY_MARK = {
  [S.ERROR] = { icon = '', hl = 'DiagnosticError', label = 'error' },
  [S.WARN]  = { icon = '', hl = 'DiagnosticWarn',  label = 'warn' },
  [S.INFO]  = { icon = '', hl = 'DiagnosticInfo',  label = 'info' },
  [S.HINT]  = { icon = '󰌵', hl = 'DiagnosticHint',  label = 'hint' },
}

--- 診断を集めてファイル順・行順に整列した項目リストにする
---@param min_severity integer|nil これ以上の重要度だけ集める（既定は現在のフィルタ）
---@return table[] items { path, bufnr, lnum, col, severity, message, source }
function M.collect(min_severity)
  min_severity = min_severity or M.FILTERS[filter_idx].min
  local items = {}
  for _, d in ipairs(vim.diagnostic.get(nil)) do
    if d.severity <= min_severity and vim.api.nvim_buf_is_valid(d.bufnr) then
      local name = vim.api.nvim_buf_get_name(d.bufnr)
      if name ~= '' then
        table.insert(items, {
          path     = vim.fn.fnamemodify(name, ':.'),
          bufnr    = d.bufnr,
          lnum     = d.lnum + 1, -- 診断は 0-based
          col      = d.col,
          severity = d.severity,
          -- 複数行メッセージは1行に潰す（パネルは1項目1行）
          message  = (d.message or ''):gsub('%s*\n%s*', ' '),
          source   = d.source,
        })
      end
    end
  end
  table.sort(items, function(a, b)
    if a.path ~= b.path then return a.path < b.path end
    if a.lnum ~= b.lnum then return a.lnum < b.lnum end
    return a.col < b.col
  end)
  return items
end

--- 項目リストを表示行に変換する（純粋関数）
---@param items table[]
---@return string[] lines
---@return table<integer, table> line_meta 行番号(1-based) -> 項目
---@return table[] highlights { lnum(0-based), group, col_start, col_end }
function M.build(items)
  local lines, line_meta, hls = {}, {}, {}
  local counts = { [S.ERROR] = 0, [S.WARN] = 0, [S.INFO] = 0, [S.HINT] = 0 }
  for _, it in ipairs(items) do
    counts[it.severity] = (counts[it.severity] or 0) + 1
  end

  local header = string.format(' 問題   %d   %d   [f] %s',
    counts[S.ERROR], counts[S.WARN], M.FILTERS[filter_idx].name)
  table.insert(lines, header)
  table.insert(hls, { 0, 'ProblemsHeader', 0, -1 })
  table.insert(lines, '')

  if #items == 0 then
    table.insert(lines, ' 問題はありません')
    table.insert(hls, { 2, 'ProblemsEmpty', 0, -1 })
    return lines, line_meta, hls
  end

  local current_path = nil
  for _, it in ipairs(items) do
    if it.path ~= current_path then
      current_path = it.path
      table.insert(lines, ' ' .. it.path)
      table.insert(hls, { #lines - 1, 'ProblemsFile', 0, -1 })
    end
    local mark = SEVERITY_MARK[it.severity] or SEVERITY_MARK[S.HINT]
    local pos  = string.format('%d:%d', it.lnum, it.col + 1)
    local tail = it.source and (' [' .. it.source .. ']') or ''
    -- アイコン＋位置までを重要度色で塗る。アイコンはマルチバイトなので
    -- 桁数ではなく実際のバイト長から範囲を出す
    local head = string.format('   %s %-9s', mark.icon, pos)
    local line = head .. ' ' .. it.message .. tail
    table.insert(lines, line)
    local lnum0 = #lines - 1
    table.insert(hls, { lnum0, mark.hl, 0, #head })
    if tail ~= '' then
      table.insert(hls, { lnum0, 'ProblemsSource', #line - #tail, -1 })
    end
    line_meta[#lines] = it
  end

  return lines, line_meta, hls
end

--- パネルの中身を描き直す
function M.refresh()
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local lines, line_meta, hls = M.build(M.collect())
  meta = line_meta

  item_lnums = vim.tbl_keys(line_meta)
  table.sort(item_lnums)

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_add_highlight(buf, hl_ns, h[2], h[1], h[3], h[4])
  end

  if win and vim.api.nvim_win_is_valid(win) then
    -- 診断が1件も無いときはヘッダに選択の帯が出るのがおかしいので消す
    vim.wo[win].cursorline = #item_lnums > 0
    M.snap_cursor()
  end
end

--- フィルタを次へ回す
function M.cycle_filter()
  filter_idx = filter_idx % #M.FILTERS + 1
  M.refresh()
end

-- ══════════════════════════════════════════════
-- カーソルの吸着
--
-- ヘッダ・空行・ファイル見出しにカーソルが止まると「選択できない行を選んでいる」
-- 状態になって紛らわしい。診断行だけを行き来させ、それ以外に乗ったら進行方向の
-- 次の診断行へ寄せる。
-- ══════════════════════════════════════════════

--- 診断行のうち、lnum から見て最も近い行を返す（純粋関数）
--- dir 方向を先に探し、その先に無ければ反対方向へ折り返す
---@param item_lnums integer[] 昇順の診断行リスト
---@param lnum integer
---@param dir 1|-1 進行方向（下向き / 上向き）
---@return integer|nil 診断行が1つも無ければ nil
function M.nearest_item(item_lnums, lnum, dir)
  if #item_lnums == 0 then return nil end
  for _, l in ipairs(item_lnums) do
    if l == lnum then return lnum end
  end

  local forward, backward
  for _, l in ipairs(item_lnums) do
    if l > lnum then
      forward = forward or l
    elseif l < lnum then
      backward = l -- 昇順に走査するので最後に入るのが直近の上側
    end
  end

  if dir >= 0 then
    return forward or backward
  end
  return backward or forward
end

--- カーソルを診断行へ寄せる
function M.snap_cursor()
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  local cur    = vim.api.nvim_win_get_cursor(win)[1]
  local dir    = (last_lnum and cur < last_lnum) and -1 or 1
  local target = M.nearest_item(item_lnums, cur, dir)
  if target and target ~= cur then
    pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
    cur = target
  end
  last_lnum = cur
end

--- カーソル行の診断へ飛ぶ（パネルは開いたまま）
function M.jump()
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  local item = meta[lnum]
  if not item then return end

  win_util.focus_editor()
  -- 編集ウィンドウが無いときにパネル自身へファイルを載せてしまわないようにする
  if not win_util.is_editor(vim.api.nvim_get_current_win()) then return end
  if vim.api.nvim_buf_is_valid(item.bufnr) then
    vim.api.nvim_set_current_buf(item.bufnr)
    pcall(vim.api.nvim_win_set_cursor, 0, { item.lnum, item.col })
    vim.cmd('normal! zz')
  end
end

-- ══════════════════════════════════════════════
-- herdr 連携: 診断をエージェントへ送る
--
-- 問題パネルは「何を直すか」の選択、herdr は「誰に渡すか」。
-- エージェント一覧は herdr サイドバーにあるのでここでは出さず、送り先だけ picker する。
-- send-text は改行を Enter と誤解され得るので、複数件も1行にまとめる。
-- ══════════════════════════════════════════════

--- 診断1件をエージェント向けの場所+内容文字列にする（純粋関数）。
---@param it table collect() の項目
---@return string
function M.format_item(it)
  local mark = SEVERITY_MARK[it.severity] or SEVERITY_MARK[S.HINT]
  local pos = string.format('%d:%d', it.lnum, it.col + 1)
  local src = it.source and (' [' .. it.source .. ']') or ''
  return string.format('%s:%s %s: %s%s', it.path, pos, mark.label, it.message, src)
end

--- 診断複数件を1行の依頼文にする（純粋関数）。0件は nil。
--- 改行を入れないのは pane send-text が改行を送信確定と扱う場合があるため。
---@param items table[]
---@return string|nil
function M.format_items(items)
  if #items == 0 then return nil end
  if #items == 1 then return M.format_item(items[1]) end
  local parts = {}
  for _, it in ipairs(items) do
    parts[#parts + 1] = M.format_item(it)
  end
  return 'これらの診断を修正してください: ' .. table.concat(parts, ' | ')
end

--- パネル上のカーソル行の診断。診断行以外は nil。
---@return table|nil
function M.cursor_item()
  if not (win and vim.api.nvim_win_is_valid(win)) then return nil end
  return meta[vim.api.nvim_win_get_cursor(win)[1]]
end

--- 現在のフィルタ下で path に属する診断だけ返す。
---@param path string
---@return table[]
function M.items_for_path(path)
  local out = {}
  for _, it in ipairs(M.collect()) do
    if it.path == path then
      out[#out + 1] = it
    end
  end
  return out
end

local function send_to_agent(text)
  if not text or text == '' then
    vim.notify('送る診断がありません', vim.log.levels.WARN, { title = 'problems' })
    return
  end
  require('config.herdr').pick_agent(text)
end

--- カーソル行の診断をエージェントへ送る。
function M.send_current()
  local item = M.cursor_item()
  if not item then
    vim.notify('診断行を選んでください', vim.log.levels.WARN, { title = 'problems' })
    return
  end
  send_to_agent(M.format_item(item))
end

--- カーソル行と同じファイルの診断（現フィルタ）をまとめて送る。
--- カーソルは診断行にしか止まらないので、ファイル見出しではなく「今の診断のファイル」単位。
function M.send_file()
  local item = M.cursor_item()
  if not item then
    vim.notify('診断行を選んでください', vim.log.levels.WARN, { title = 'problems' })
    return
  end
  local text = M.format_items(M.items_for_path(item.path))
  send_to_agent(text)
end

--- 現在のフィルタで見えている診断をすべて送る。
function M.send_filtered()
  local text = M.format_items(M.collect())
  send_to_agent(text)
end

function M.close()
  vim.api.nvim_clear_autocmds({ group = augrp })
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  win, buf, meta, item_lnums, last_lnum = nil, nil, {}, {}, nil
end

function M.is_open()
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

--- パネルのウィンドウ ID（テストや外から状態を見るため）
function M.win_id()
  return win
end

function M.open()
  if M.is_open() then return end

  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype    = 'nofile'
  vim.bo[buf].buflisted  = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype   = 'problems'

  vim.cmd('botright ' .. M.PANEL_HEIGHT .. 'split')
  win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  hidden_cursor.mark_buffer(buf)
  win_util.mark_sidebar(win, buf)

  vim.wo[win].wrap           = false
  vim.wo[win].number         = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn     = 'no'
  vim.wo[win].foldcolumn     = '0'
  vim.wo[win].statuscolumn   = ''
  vim.wo[win].cursorline     = true
  vim.wo[win].winfixheight   = true
  vim.wo[win].winhighlight   = 'Normal:ProblemsBg,NormalNC:ProblemsBg,EndOfBuffer:ProblemsBg,CursorLine:ProblemsSel'
  vim.wo[win].statusline     = '%#ProblemsBg#'

  last_lnum = nil
  M.refresh()

  -- j/k はもちろん gg/G やマウスクリックでもヘッダや空行に止まらないようにする
  vim.api.nvim_create_autocmd('CursorMoved', {
    group    = augrp,
    buffer   = buf,
    callback = function() M.snap_cursor() end,
  })

  local function map(key, fn)
    vim.keymap.set('n', key, fn, { buffer = buf, nowait = true, silent = true })
  end
  map('<CR>',  M.jump)
  map('o',     M.jump)
  map('f',     M.cycle_filter)
  map('R',     M.refresh)
  map('a',     M.send_current)
  map('A',     M.send_file)
  map('gA',    M.send_filtered)
  map('q',     M.close)
  map('<Esc>', M.close)

  -- 診断が更新されたら開いている間は追従する
  vim.api.nvim_create_autocmd('DiagnosticChanged', {
    group    = augrp,
    callback = function() M.refresh() end,
  })

  vim.api.nvim_create_autocmd('WinClosed', {
    group    = augrp,
    pattern  = tostring(win),
    once     = true,
    callback = function()
      if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      win, buf, meta, item_lnums, last_lnum = nil, nil, {}, {}, nil
      vim.api.nvim_clear_autocmds({ group = augrp })
    end,
  })
end

function M.toggle()
  if M.is_open() then M.close() else M.open() end
end

local function setup_hl()
  vim.api.nvim_set_hl(0, 'ProblemsBg',     { bg = 'none' })
  vim.api.nvim_set_hl(0, 'ProblemsHeader', { fg = '#7aa2f7', bold = true })
  vim.api.nvim_set_hl(0, 'ProblemsFile',   { fg = '#e0af68', bold = true })
  vim.api.nvim_set_hl(0, 'ProblemsSource', { fg = '#565f89', italic = true })
  vim.api.nvim_set_hl(0, 'ProblemsEmpty',  { fg = '#565f89', italic = true })
  vim.api.nvim_set_hl(0, 'ProblemsSel',    { bg = '#2d3250' })
end

setup_hl()
vim.api.nvim_create_autocmd('ColorScheme', { callback = setup_hl })

vim.keymap.set('n', '<leader>p', M.toggle, { desc = '問題パネルを開閉' })

return M
