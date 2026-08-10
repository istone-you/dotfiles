-- 汎用の絞り込み picker（namu と同じ prompt + results の2窓構成）。プラグイン不使用。
-- 入力で絞り込み、Ctrl-j/k（↓/↑）で移動、Enter で決定、Esc / Ctrl-c で閉じる。
--
-- 使い方: picker.open({ title, items, format, on_select })
--   format(item) -> { tag, tag_hl, text, right }
--   on_select(item)
-- モーダルなフロート（サイドバーではない）なので win_util の SIDEBAR_FT には登録しない。

local M = {}

local win_util = require('config.util.win_util')
local hidden_cursor = require('config.hidden_cursor')

local hl_ns = vim.api.nvim_create_namespace('picker')
local augrp = vim.api.nvim_create_augroup('picker', { clear = true })

local state = {
  prompt_win = nil,
  prompt_buf = nil,
  results_win = nil,
  results_buf = nil,
  origin_win = nil,
  items = {},
  filtered = {},
  sel = 1,
  width = 60,
  format = nil,
  on_select = nil,
}

M.state = state

-- 番号ラベルのキー列: 1..9 のあとに a..z（最大 35 件）。それ以降はラベル無し。
local LABEL_KEYS = {}
for d = 1, 9 do
  LABEL_KEYS[d] = tostring(d)
end
for c = 0, 25 do
  LABEL_KEYS[10 + c] = string.char(string.byte('a') + c)
end

--- index(1始まり) に対応するラベル文字。範囲外(35超)は nil。
function M.index_label(index)
  return LABEL_KEYS[index]
end

function M.close()
  vim.api.nvim_clear_autocmds({ group = augrp })
  -- prompt_win は no-filter モードでは nil。ipairs だと nil 穴で止まって results を
  -- 閉じ損ねるので、個別に閉じる。
  local function close_win(w)
    if w and vim.api.nvim_win_is_valid(w) then
      vim.api.nvim_win_close(w, true)
    end
  end
  local function del_buf(b)
    if b and vim.api.nvim_buf_is_valid(b) then
      vim.api.nvim_buf_delete(b, { force = true })
    end
  end
  close_win(state.prompt_win)
  close_win(state.results_win)
  del_buf(state.prompt_buf)
  del_buf(state.results_buf)
  state.prompt_win, state.prompt_buf = nil, nil
  state.results_win, state.results_buf = nil, nil
  state.origin_win = nil
  state.items, state.filtered = {}, {}
  state.sel = 1
end

function M.is_open()
  return state.results_buf ~= nil and vim.api.nvim_buf_is_valid(state.results_buf)
end

--- 表示行を作る。numbered のときは左にラベル(1..9, a..z)を出す。35件超はラベル無し(空白)。
--- 戻り値: 行文字列, タグのバイト幅, ラベルプレフィックスのバイト幅(ラベル無しは0だが桁は空白で確保)
local function line_for(item, index)
  local f = state.format(item)
  local tag = f.tag or ''
  local text = f.text or ''
  local right = f.right or ''
  local prefix, label_w = '', 0
  if state.numbered then
    local label = M.index_label(index)
    prefix = label and (label .. ' ') or '  ' -- ラベル無しでも桁を揃える
    label_w = label and #label or 0
  end
  local content_w = state.width - 2
  local avail = content_w - #prefix - #tag - 1 - #right - 1
  if vim.fn.strdisplaywidth(text) > avail then
    while vim.fn.strdisplaywidth(text) > avail - 1 and #text > 0 do
      text = text:sub(1, -2)
    end
    text = text .. '…'
  end
  local pad = math.max(0, avail - vim.fn.strdisplaywidth(text))
  return string.format('%s%s %s%s %s', prefix, tag, text, string.rep(' ', pad), right), #tag, #prefix, label_w
end

local function render()
  if not M.is_open() then return end

  local lines, tag_widths, prefix_lens, label_widths = {}, {}, {}, {}
  for i, item in ipairs(state.filtered) do
    local line, tag_w, prefix_len, label_w = line_for(item, i)
    table.insert(lines, line)
    table.insert(tag_widths, tag_w)
    table.insert(prefix_lens, prefix_len)
    table.insert(label_widths, label_w)
  end
  if #lines == 0 then
    lines = { ' 一致するものがありません' }
  end

  vim.bo[state.results_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.results_buf, 0, -1, false, lines)
  vim.bo[state.results_buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.results_buf, hl_ns, 0, -1)
  for i, item in ipairs(state.filtered) do
    local plen = prefix_lens[i]
    -- ラベル(1..9, a..z)を色付け
    if label_widths[i] > 0 then
      vim.api.nvim_buf_set_extmark(state.results_buf, hl_ns, i - 1, 0, {
        end_col = label_widths[i],
        hl_group = 'PickerNum',
      })
    end
    local hl = state.format(item).tag_hl
    if hl and tag_widths[i] > 0 then
      vim.api.nvim_buf_set_extmark(state.results_buf, hl_ns, i - 1, plen, {
        end_col = plen + tag_widths[i],
        hl_group = hl,
      })
    end
  end
  if state.sel >= 1 and state.sel <= #state.filtered then
    vim.api.nvim_buf_set_extmark(state.results_buf, hl_ns, state.sel - 1, 0, {
      end_row = state.sel,
      end_col = 0,
      hl_group = 'PickerSel',
      hl_eol = true,
      priority = 200,
    })
    if state.results_win and vim.api.nvim_win_is_valid(state.results_win) then
      vim.fn.win_execute(state.results_win, 'normal! ' .. state.sel .. 'gg')
    end
  end
end

function M.filter(query)
  local q = (query or ''):lower()
  state.filtered = {}
  for _, item in ipairs(state.items) do
    local f = state.format(item)
    local hay = ((f.tag or '') .. ' ' .. (f.text or '') .. ' ' .. (f.right or '')):lower()
    if q == '' or hay:find(q, 1, true) then
      table.insert(state.filtered, item)
    end
  end
  state.sel = math.max(1, math.min(state.sel, math.max(1, #state.filtered)))
  render()
end

function M.move(delta)
  if #state.filtered == 0 then return end
  state.sel = math.max(1, math.min(state.sel + delta, #state.filtered))
  render()
end

--- 番号(1始まり)で選んで確定する。範囲外は無視。numbered のとき数字キーから呼ぶ。
function M.select_index(i)
  if i >= 1 and i <= #state.filtered then
    state.sel = i
    M.confirm()
  end
end

function M.confirm()
  local item = state.filtered[state.sel]
  local on_select, origin = state.on_select, state.origin_win
  M.close()
  if not item then return end
  if origin and vim.api.nvim_win_is_valid(origin) then
    vim.api.nvim_set_current_win(origin)
  end
  if on_select then on_select(item) end
end

--- filter=true(既定): 入力欄 + リストの2窓。打ち込んで絞り込む(namu 風)。
local function open_with_filter(opts, width, list_h, row, col)
  state.prompt_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.prompt_buf].buftype = 'nofile'
  vim.bo[state.prompt_buf].buflisted = false

  state.results_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.results_buf].buftype = 'nofile'
  vim.bo[state.results_buf].buflisted = false
  vim.bo[state.results_buf].modifiable = false
  vim.bo[state.results_buf].filetype = 'picker'

  state.prompt_win = vim.api.nvim_open_win(state.prompt_buf, true, {
    relative = 'editor',
    row = row,
    col = col,
    width = width,
    height = 1,
    style = 'minimal',
    border = { '╭', '─', '╮', '│', '┤', '─', '├', '│' },
    title = opts.title,
    title_pos = 'center',
    zindex = 51,
  })

  state.results_win = vim.api.nvim_open_win(state.results_buf, false, {
    relative = 'editor',
    row = row + 3,
    col = col,
    width = width,
    height = list_h,
    style = 'minimal',
    border = { '', '', '', '│', '╯', '─', '╰', '│' },
    zindex = 50,
    focusable = false,
  })
  vim.wo[state.results_win].cursorline = false
  vim.wo[state.results_win].number = false
  vim.wo[state.results_win].relativenumber = false
  vim.wo[state.results_win].signcolumn = 'no'
  vim.wo[state.results_win].wrap = false

  win_util.mark_sidebar(state.prompt_win, state.prompt_buf)
  win_util.mark_sidebar(state.results_win, state.results_buf)

  vim.api.nvim_buf_set_lines(state.prompt_buf, 0, -1, false, { '' })
  render()
  vim.cmd('startinsert')

  vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged' }, {
    group = augrp,
    buffer = state.prompt_buf,
    callback = function()
      M.filter(vim.api.nvim_buf_get_lines(state.prompt_buf, 0, 1, false)[1] or '')
    end,
  })

  local map_opts = { buffer = state.prompt_buf, nowait = true, silent = true }
  local function imap(lhs, fn)
    vim.keymap.set('i', lhs, fn, map_opts)
  end
  imap('<C-j>', function() M.move(1) end)
  imap('<C-k>', function() M.move(-1) end)
  imap('<Down>', function() M.move(1) end)
  imap('<Up>', function() M.move(-1) end)
  imap('<CR>', function()
    vim.cmd('stopinsert')
    M.confirm()
  end)
  imap('<Esc>', function()
    vim.cmd('stopinsert')
    M.close()
  end)
  imap('<C-c>', function()
    vim.cmd('stopinsert')
    M.close()
  end)
  -- numbered のときはラベルキー(1..9, a..z)で直接選択。ただし範囲内(その番号の項目がある)
  -- ときだけ選択し、範囲外ならその文字をフィルタへ普通に入力させる(小さいリストでは英字も
  -- フィルタに使える)。表示中のラベルに割り当たっている文字だけが選択キーとして効く。
  if state.numbered then
    for i, key in ipairs(LABEL_KEYS) do
      imap(key, function()
        if i <= #state.filtered then
          vim.cmd('stopinsert')
          M.select_index(i)
        else
          vim.api.nvim_feedkeys(key, 'n', false) -- ラベル未使用 → 通常のフィルタ入力
        end
      end)
    end
  end

  -- ポップアップ外へフォーカスが移ったら閉じる
  vim.api.nvim_create_autocmd('WinLeave', {
    group = augrp,
    callback = function()
      if vim.api.nvim_get_current_win() ~= state.prompt_win then return end
      vim.schedule(function()
        local cur = vim.api.nvim_get_current_win()
        if cur ~= state.prompt_win and cur ~= state.results_win then M.close() end
      end)
    end,
  })
end

--- filter=false: 入力欄なし。リスト窓を直接フォーカスし、ノーマル操作で選ぶ。
local function open_no_filter(opts, width, list_h, row, col)
  state.results_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.results_buf].buftype = 'nofile'
  vim.bo[state.results_buf].buflisted = false
  vim.bo[state.results_buf].modifiable = false
  vim.bo[state.results_buf].filetype = 'picker'
  -- フォーカスするので、他パネルと同様テキストカーソルは隠す(open_win 前にマーク)。
  hidden_cursor.mark_buffer(state.results_buf)

  state.results_win = vim.api.nvim_open_win(state.results_buf, true, {
    relative = 'editor',
    row = row,
    col = col,
    width = width,
    height = list_h,
    style = 'minimal',
    border = { '╭', '─', '╮', '│', '╯', '─', '╰', '│' },
    title = opts.title,
    title_pos = 'center',
    zindex = 51,
  })
  vim.wo[state.results_win].cursorline = false
  vim.wo[state.results_win].number = false
  vim.wo[state.results_win].relativenumber = false
  vim.wo[state.results_win].signcolumn = 'no'
  vim.wo[state.results_win].wrap = false

  win_util.mark_sidebar(state.results_win, state.results_buf)
  render()

  local map_opts = { buffer = state.results_buf, nowait = true, silent = true }
  local function nmap(lhs, fn)
    vim.keymap.set('n', lhs, fn, map_opts)
  end
  nmap('j', function() M.move(1) end)
  nmap('k', function() M.move(-1) end)
  nmap('<C-j>', function() M.move(1) end)
  nmap('<C-k>', function() M.move(-1) end)
  nmap('<Down>', function() M.move(1) end)
  nmap('<Up>', function() M.move(-1) end)
  nmap('<CR>', function() M.confirm() end)
  nmap('<Esc>', function() M.close() end)
  nmap('q', function() M.close() end)
  nmap('<C-c>', function() M.close() end)
  -- numbered のときはラベルキー(1..9, a..z)で直接選択(フィルタが無いので範囲外は無視)。
  if state.numbered then
    for i, key in ipairs(LABEL_KEYS) do
      nmap(key, function() M.select_index(i) end)
    end
  end

  vim.api.nvim_create_autocmd('WinLeave', {
    group = augrp,
    callback = function()
      if vim.api.nvim_get_current_win() ~= state.results_win then return end
      vim.schedule(function()
        if vim.api.nvim_get_current_win() ~= state.results_win then M.close() end
      end)
    end,
  })
end

--- opts = {
---   title     = ポップアップのタイトル,
---   items     = 選択肢のリスト,
---   format    = function(item) -> { tag, tag_hl, text, right },
---   on_select = function(item),
---   numbered  = 左にラベル(1..9,a..z)を出し、そのキーで即選択する(既定 false),
---   filter    = 打ち込んで絞り込む入力欄を出す(既定 true。false ならリスト直操作),
--- }
function M.open(opts)
  if #opts.items == 0 then return end
  M.close()

  state.items = opts.items
  state.filtered = vim.deepcopy(opts.items)
  state.sel = 1
  state.format = opts.format
  state.on_select = opts.on_select
  state.numbered = opts.numbered == true
  state.filtering = opts.filter ~= false
  state.origin_win = vim.api.nvim_get_current_win()

  local sw = vim.o.columns
  local sh = vim.o.lines - vim.o.cmdheight - 2
  local width = math.min(72, sw - 4)
  local list_h = math.max(1, math.min(#opts.items, math.floor(sh * 0.6)))
  -- filter ありは入力欄(3行)+リスト、無しはリストだけ。中央寄せの基準高さを合わせる。
  local total_h = state.filtering and (list_h + 3) or list_h
  local row = math.floor((sh - total_h) / 2)
  local col = math.floor((sw - width) / 2)
  state.width = width

  if state.filtering then
    open_with_filter(opts, width, list_h, row, col)
  else
    open_no_filter(opts, width, list_h, row, col)
  end
end

local function setup_hl()
  vim.api.nvim_set_hl(0, 'PickerSel', { link = 'PmenuSel', default = true })
  vim.api.nvim_set_hl(0, 'PickerNum', { link = 'Comment', default = true })
end

setup_hl()
-- augrp は close() でまとめて消すので、配色の再設定は別グループに置く
vim.api.nvim_create_autocmd('ColorScheme', {
  group = vim.api.nvim_create_augroup('picker_hl', { clear = true }),
  callback = setup_hl,
})

return M
