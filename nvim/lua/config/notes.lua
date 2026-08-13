-- メモ帳。stdpath('config')/notes/ 以下に *.md を置き、内容は実ファイルとして永続化する。
-- <leader>m で開く。fzf は使わず、一覧 / プロンプト / プレビューを nvim のフロート窓で構成する。
-- 空クエリでメモ一覧（各行は先頭行＝見出し）、打てば本文をインクリメンタル検索、Enter で開く。
-- Ctrl-n で空メモを即作成して開く。プレビューは search と同じく実バッファをそのまま載せる。
--
-- 探すのは常に「中身」なのでファイル名は識別子でよく、作成時に名前を決めさせない。
-- ファイル名はタイムスタンプ、タイトルは本文の先頭行で管理する（Obsidian 等と同じ発想）。
-- Requirements: rg
--
-- ロジック（new_note_path / create_blank / parse_result_line / notes_cmd）は dir/引数で受け、
-- stdpath や時刻に触れずテストできるようにしてある。UI（M.open）だけが M.dir()/os.date を使う。

local M = {}

local win_util = require('config.util.win_util')

local function has_cmd(name)
  return vim.fn.executable(name) == 1
end

--- notes ディレクトリの絶対パス（= ~/.config/nvim/notes）。
--- symlink 差異を避けるため normalize してから返す（.config/CLAUDE.md のパス方針）。
function M.dir()
  return vim.fs.normalize(vim.fn.stdpath('config') .. '/notes')
end

--- dir/<stamp>.md を返す。既にあれば -2, -3 ... を付けて衝突を避ける（同秒の連続作成対策）。
function M.new_note_path(dir, stamp)
  local base = dir .. '/' .. stamp
  local path = base .. '.md'
  local n = 2
  while vim.fn.filereadable(path) == 1 do
    path = base .. '-' .. n .. '.md'
    n = n + 1
  end
  return path
end

--- 空のメモを作ってその絶対パスを返す。タイトルは付けない（本文の先頭行に任せる）。
function M.create_blank(dir, stamp)
  vim.fn.mkdir(dir, 'p')
  local path = M.new_note_path(dir, stamp)
  local f = io.open(path, 'w')
  if f then f:close() end
  return path
end

--- rg の 1 行を { path, lnum, col } に分解する。dir を基準に相対パスを絶対化する。
--- 本文ヒット行（path:line:col:text）も一覧行（path:1:1:先頭行）も同じ形なので同じ処理で扱える。
--- rg の ANSI は先に除去する。空行・パス無しは nil。
function M.parse_result_line(line, dir)
  line = (line or ''):gsub('\27%[[0-9;]*m', '')
  if line == '' then return nil end
  local path, lnum, col = line:match('^(.-):(%d+):(%d+):')
  if not path then
    path, lnum = line:match('^(.-):(%d+):')
    col = '1'
  end
  if not path then
    path, lnum, col = line, '1', '1'
  end
  if path == '' then return nil end
  if path:sub(1, 1) ~= '/' then
    path = dir .. '/' .. path
  end
  return { path = path, lnum = tonumber(lnum) or 1, col = tonumber(col) or 1 }
end

--- rg コマンド。空クエリはメモ一覧（path:1:1:先頭行。先頭の # は外し、空ファイルはファイル名で代替）、
--- 非空は本文検索（path:line:col:text）。色は付けず（ハイライトはネイティブ側）、
--- glob 展開を止める set -f を付ける。printf の \n を活かすため長括弧文字列で書く。
--- [==[ ]==] を使う理由: 中の sed の [[:space:]] に ]] が含まれ、素の [[ ]] だと早期終了する。
function M.notes_cmd(query)
  if not query or query == '' then
    return [==[set -f; rg --files -g '*.md' | while IFS= read -r f; do t=$(grep -m1 . -- "$f" 2>/dev/null | sed 's/^#\+[[:space:]]*//'); [ -z "$t" ] && t=$(basename "$f" .md); printf '%s:1:1:%s\n' "$f" "$t"; done]==]
  end
  return string.format(
    [[set -f; rg --column --line-number --no-heading --color=never --smart-case -g '*.md' -- %s || true]],
    vim.fn.shellescape(query))
end

--- 通常バッファとして開く（編集・保存は標準どおり）。編集窓へ必ず開く。
local function open_result(res)
  if not res then return end
  win_util.focus_editor()
  vim.cmd('edit ' .. vim.fn.fnameescape(res.path))
  pcall(vim.api.nvim_win_set_cursor, 0, { res.lnum, math.max(res.col - 1, 0) })
  vim.cmd('normal! zz')
end

local notes_ns = vim.api.nvim_create_namespace('notes_results')

--- メモ画面を開く。一覧（上）/ プロンプト（下）/ プレビュー（右）のフロート窓。検索は入力に
--- 追従して rg を非同期実行する。並び・向きは search と同じ（最良マッチが最下段＝プロンプト直上）。
function M.open()
  if not has_cmd('rg') then
    vim.notify('rg が見つかりません', vim.log.levels.ERROR)
    return
  end

  local dir = M.dir()
  vim.fn.mkdir(dir, 'p')
  local render_preview = require('config.search').render_preview

  local closing = false
  local items, sel = {}, 1
  local gen, rg_handle, prev_preview_buf = 0, nil, nil

  -- ── レイアウト（左に 一覧＋プロンプト、右にプレビュー） ──
  local outer_w = math.floor(vim.o.columns * 0.9)
  local total_h = math.floor(vim.o.lines * 0.85)
  local base_col = math.floor((vim.o.columns - outer_w) / 2)
  local base_top = math.floor((vim.o.lines - total_h) / 2)
  local gap = 2
  local list_w = math.floor(outer_w * 0.45)
  local preview_w = outer_w - list_w - gap
  local preview_col = base_col + list_w + gap
  local results_h = math.max(3, total_h - 3)

  local function valid(w) return w and vim.api.nvim_win_is_valid(w) end

  local query_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[query_buf].buftype = 'nofile'
  vim.bo[query_buf].bufhidden = 'hide'
  vim.bo[query_buf].swapfile = false
  vim.api.nvim_buf_set_lines(query_buf, 0, -1, false, { '' })

  local results_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[results_buf].buftype = 'nofile'
  vim.bo[results_buf].modifiable = false

  local function results_title()
    return { { string.format(' notes: %d ', #items), 'SearchFieldLabel' } }
  end

  local results_win = vim.api.nvim_open_win(results_buf, false, {
    relative = 'editor', width = list_w, height = results_h, col = base_col, row = base_top,
    style = 'minimal', border = 'single', title = results_title(), title_pos = 'left',
  })
  vim.wo[results_win].number = false
  vim.wo[results_win].relativenumber = false
  vim.wo[results_win].signcolumn = 'no'
  vim.wo[results_win].wrap = false
  vim.wo[results_win].cursorline = true

  local query_win = vim.api.nvim_open_win(query_buf, true, {
    relative = 'editor', width = list_w, height = 1, col = base_col, row = base_top + results_h + 2,
    style = 'minimal', border = 'single', title = ' memo ', title_pos = 'left',
    footer = { { ' Ctrl-n:new memo ', 'Comment' } }, footer_pos = 'center',
  })
  vim.wo[query_win].number = false
  vim.wo[query_win].relativenumber = false
  vim.wo[query_win].signcolumn = 'no'
  vim.wo[query_win].wrap = false

  local preview_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
    relative = 'editor', width = preview_w, height = total_h, col = preview_col, row = base_top,
    style = 'minimal', border = 'single', title = ' preview ', title_pos = 'center',
    focusable = false,
  })
  vim.wo[preview_win].number = true
  vim.wo[preview_win].relativenumber = false
  vim.wo[preview_win].signcolumn = 'no'
  vim.wo[preview_win].wrap = false
  vim.wo[preview_win].cursorline = true

  local function query_line()
    if not vim.api.nvim_buf_is_valid(query_buf) then return '' end
    return vim.api.nvim_buf_get_lines(query_buf, 0, 1, false)[1] or ''
  end

  -- 最良マッチ(sel=1)を最下段＝プロンプト直上に貼り付ける（旧 fzf 既定レイアウト）。件数が窓より
  -- 少なければ上を空行で詰めて下寄せする。よって sel とバッファ行は上下反転＋pad ぶんずれる。
  local pad = 0
  local function row_of(s) return pad + (#items - s + 1) end

  local function set_preview_buf(buf)
    if buf and prev_preview_buf and prev_preview_buf ~= buf
      and vim.api.nvim_buf_is_valid(prev_preview_buf) then
      pcall(vim.api.nvim_buf_delete, prev_preview_buf, { force = true })
    end
    prev_preview_buf = buf
  end

  local function set_preview_title(title)
    if valid(preview_win) then
      vim.api.nvim_win_set_config(preview_win, {
        relative = 'editor', width = preview_w, height = total_h, col = preview_col, row = base_top,
        style = 'minimal', border = 'single', title = title, title_pos = 'center', focusable = false,
      })
    end
  end

  local function update_preview()
    if closing or not valid(preview_win) then return end
    local it = items[sel]
    if not it then
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_win_set_buf(preview_win, buf)
      set_preview_buf(buf)
      set_preview_title(' preview ')
      return
    end
    -- 一覧表示（空クエリ）は lnum が常に 1 で意味のあるヒット行が無いので強調しない。
    local buf = render_preview(preview_win, it.path, it.lnum, { no_highlight = query_line() == '' })
    if buf then
      set_preview_buf(buf)
      set_preview_title(' ' .. vim.fn.fnamemodify(it.path, ':t') .. ' ')
    end
  end

  local function update_cursor()
    if sel < 1 then sel = 1 elseif sel > #items and #items > 0 then sel = #items end
    if valid(results_win) and #items > 0 then
      pcall(vim.api.nvim_win_set_cursor, results_win, { row_of(sel), 0 })
    end
  end

  local function render_results()
    local q = query_line()
    local n = #items
    pad = math.max(0, results_h - n) -- 下寄せ用に上を空行で詰める
    local lines, hls = {}, {}
    for k = 1, pad do lines[k] = '' end
    for i, it in ipairs(items) do
      local pos = pad + (n - i + 1) -- item i は下から i 番目（最良が最下段）
      lines[pos] = it.text
      -- 本文検索時はヒット箇所を強調（rg の col は本文内 1-based バイト位置）
      if q ~= '' and it.col then
        hls[pos] = { it.col - 1, it.col - 1 + #q }
      end
    end
    vim.bo[results_buf].modifiable = true
    vim.api.nvim_buf_set_lines(results_buf, 0, -1, false, lines)
    vim.bo[results_buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(results_buf, notes_ns, 0, -1)
    for row, h in pairs(hls) do
      local e = math.min(h[2], #(lines[row] or ''))
      if h[1] >= 0 and h[1] < e then
        pcall(vim.api.nvim_buf_set_extmark, results_buf, notes_ns, row - 1, h[1], {
          end_col = e, hl_group = 'SearchResultMatch',
        })
      end
    end
    if valid(results_win) then
      vim.api.nvim_win_set_config(results_win, {
        relative = 'editor', width = list_w, height = results_h, col = base_col, row = base_top,
        style = 'minimal', border = 'single', title = results_title(), title_pos = 'left',
      })
    end
    update_cursor()
    update_preview()
  end

  local function move(step)
    if #items == 0 then return end
    sel = sel + step
    update_cursor()
    update_preview()
  end

  -- ── 非同期 rg（デバウンス + 世代管理 + 前ジョブ kill） ──
  local uv = vim.uv or vim.loop
  local debounce = uv.new_timer()

  local function launch_rg()
    if closing then return end
    gen = gen + 1
    local my_gen = gen
    local q = query_line()
    local sh = 'cd ' .. vim.fn.shellescape(dir) .. ' && ' .. M.notes_cmd(q)
    if rg_handle then pcall(function() rg_handle:kill('sigterm') end); rg_handle = nil end
    rg_handle = vim.system({ 'sh', '-c', sh }, { text = true }, function(res)
      vim.schedule(function()
        if closing or my_gen ~= gen then return end
        rg_handle = nil
        local parsed = {}
        for line in (res.stdout or ''):gmatch('[^\n]+') do
          local r = M.parse_result_line(line, dir)
          if r then
            local text = line:gsub('\27%[[0-9;]*m', ''):match('^.-:%d+:%d+:(.*)$') or line
            parsed[#parsed + 1] = { path = r.path, lnum = r.lnum, col = r.col, text = text }
          end
        end
        items = parsed
        sel = 1
        render_results()
      end)
    end)
  end

  local function run_search()
    debounce:stop()
    debounce:start(80, 0, vim.schedule_wrap(launch_rg))
  end

  local function close_picker()
    if closing then return end
    closing = true
    pcall(function() debounce:stop() end)
    pcall(function() debounce:close() end)
    if rg_handle then pcall(function() rg_handle:kill('sigterm') end) end
    for _, w in ipairs({ query_win, results_win, preview_win }) do
      if valid(w) then pcall(vim.api.nvim_win_close, w, true) end
    end
    for _, b in ipairs({ query_buf, results_buf, prev_preview_buf }) do
      if b and vim.api.nvim_buf_is_valid(b) then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
    end
    vim.schedule(function() vim.cmd('stopinsert') end)
  end

  local function open_selected()
    local it = items[sel]
    if not it then return end
    close_picker()
    open_result(it)
  end

  local function new_memo()
    close_picker()
    local path = M.create_blank(dir, os.date('%Y%m%d-%H%M%S'))
    win_util.focus_editor()
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    vim.cmd('startinsert') -- すぐタイトル（先頭行）を書ける
  end

  local opts = { buffer = query_buf, nowait = true }
  local both = { 'i', 'n' }
  -- 最良マッチが一番下なので、↓ は最良側（下）へ、↑ は次候補（上）へ（search と同じ向き）。
  vim.keymap.set(both, '<Down>', function() move(-1) end, opts)
  vim.keymap.set(both, '<Up>', function() move(1) end, opts)
  vim.keymap.set(both, '<CR>', open_selected, opts)
  vim.keymap.set(both, '<C-n>', new_memo, opts)
  vim.keymap.set(both, '<C-u>', function()
    vim.api.nvim_buf_set_lines(query_buf, 0, -1, false, { '' })
  end, opts)
  vim.keymap.set(both, '<Esc>', close_picker, opts)

  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    buffer = query_buf,
    callback = function() if not closing then run_search() end end,
  })
  vim.api.nvim_create_autocmd({ 'WinEnter', 'BufEnter' }, {
    buffer = query_buf,
    callback = function()
      if closing then return end
      vim.schedule(function()
        if closing or vim.api.nvim_get_current_buf() ~= query_buf then return end
        vim.cmd('startinsert!')
      end)
    end,
  })

  render_results()
  run_search() -- 起動直後にメモ一覧を出す
  vim.api.nvim_set_current_win(query_win)
  vim.schedule(function()
    if valid(query_win) then vim.cmd('startinsert') end
  end)
end

vim.keymap.set('n', '<leader>m', M.open,
  { desc = 'メモ帳（notes/ を本文検索・Ctrl-n で新規、内容はローカル永続）' })

M._private = { notes_cmd = M.notes_cmd }

return M
