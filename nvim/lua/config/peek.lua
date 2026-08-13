local hidden_cursor = require('config.hidden_cursor')
local win_util      = require('config.util.win_util')
local preview_buf   = require('config.util.preview_buf')

local M = {}

local list_win    = nil
local list_buf    = nil
local prev_win    = nil
local original_win = nil
local locations   = {}
local current_idx = 1
local hl_ns       = vim.api.nvim_create_namespace('peek_hl')
local close_augrp = vim.api.nvim_create_augroup('peek_close', { clear = true })
-- プレビューでハイライトした行を置いたバッファ。プレビューには実ファイルの
-- バッファをそのまま載せるので、消し忘れるとPeekを閉じたあとも当該行が
-- 強調されたまま編集画面に残る。「今から載せるバッファ」だけを消すのでは
-- 別ファイルへ移った時に前のバッファぶんが残るため、置いた先を覚えておく
local hl_bufs = {}

local function clear_highlights()
  for buf in pairs(hl_bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)
    end
  end
  hl_bufs = {}
end

local function close()
  vim.api.nvim_clear_autocmds({ group = close_augrp })
  clear_highlights()
  for _, w in ipairs({ list_win, prev_win }) do
    if w and vim.api.nvim_win_is_valid(w) then
      vim.api.nvim_win_close(w, true)
    end
  end
  if list_buf and vim.api.nvim_buf_is_valid(list_buf) then
    vim.api.nvim_buf_delete(list_buf, { force = true })
  end
  list_win, prev_win, list_buf, original_win = nil, nil, nil, nil
  locations   = {}
  current_idx = 1
end

local function loc_info(loc)
  local uri   = loc.uri or loc.targetUri
  local range = loc.range or loc.targetSelectionRange or loc.targetRange
  return vim.uri_to_fname(uri), range.start.line, range.start.character
end

local function update_preview(idx)
  if not prev_win or not vim.api.nvim_win_is_valid(prev_win) then return end
  local filepath, lnum, col = loc_info(locations[idx])

  local pbuf = preview_buf.load(filepath)
  vim.api.nvim_win_set_buf(prev_win, pbuf)
  vim.api.nvim_win_set_cursor(prev_win, { lnum + 1, col })

  -- win_execute はウィンドウ切り替えの autocmd を発火させない
  vim.fn.win_execute(prev_win, 'normal! zz')
  clear_highlights()
  vim.api.nvim_buf_add_highlight(pbuf, hl_ns, 'Visual', lnum, 0, -1)
  hl_bufs[pbuf] = true
end

local function update_list()
  if not list_buf or not vim.api.nvim_buf_is_valid(list_buf) then return end
  local lines = {}
  for i, loc in ipairs(locations) do
    local filepath, lnum = loc_info(loc)
    local rel  = vim.fn.fnamemodify(filepath, ':~:.')
    local mark = i == current_idx and '▶ ' or '  '
    table.insert(lines, string.format('%s%s:%d', mark, rel, lnum + 1))
  end
  vim.bo[list_buf].modifiable = true
  vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)
  vim.bo[list_buf].modifiable = false
end

--- 「カーソルがある行こそが選択」に一本化する。j/k だけをマッピングして
--- そこから選択を進めると、<Down> やマウスクリック・gg/G・検索でカーソルだけが
--- 動いて current_idx が取り残され、プレビューもジャンプ先も 1 件目のまま固定される。
--- explorer / problems と同じく CursorMoved から呼ぶ。
local function sync_from_cursor()
  if not list_win or not vim.api.nvim_win_is_valid(list_win) then return end
  if #locations == 0 then return end
  local row = vim.api.nvim_win_get_cursor(list_win)[1]
  row = math.max(1, math.min(row, #locations))
  if row == current_idx then return end
  current_idx = row
  update_list()
  update_preview(row)
end

--- カーソルを動かすだけ。追随は sync_from_cursor（CursorMoved）に任せる
local function select(idx)
  if not list_win or not vim.api.nvim_win_is_valid(list_win) then return end
  idx = math.max(1, math.min(idx, #locations))
  vim.api.nvim_win_set_cursor(list_win, { idx, 0 })
  sync_from_cursor()
end

local function jump()
  local filepath, lnum, col = loc_info(locations[current_idx])
  local target = original_win
  close()
  if target and vim.api.nvim_win_is_valid(target) then
    vim.api.nvim_set_current_win(target)
  end
  vim.cmd('edit ' .. vim.fn.fnameescape(filepath))
  vim.api.nvim_win_set_cursor(0, { lnum + 1, col })
end

local function setup_keymaps()
  local function map(key, fn)
    vim.keymap.set('n', key, fn, { buffer = list_buf, nowait = true, silent = true })
  end
  -- j/k は素の移動のまま（3j のようなカウントも効く）。追随は CursorMoved が行う
  map('<Tab>',   function() select(current_idx + 1) end)
  map('<S-Tab>', function() select(current_idx - 1) end)
  map('<CR>',    jump)
  map('q',       close)
  map('<Esc>',   close)
end

local function open(locs)
  if #locs == 0 then
    vim.notify('[peek] 結果が見つかりませんでした', vim.log.levels.WARN)
    return
  end
  locations    = locs
  current_idx  = 1
  original_win = vim.api.nvim_get_current_win()

  local sw      = vim.o.columns
  local sh      = vim.o.lines - vim.o.cmdheight - 2
  local total_w = math.min(math.floor(sw * 0.9), sw - 4)
  local total_h = math.floor(sh * 0.6)
  local list_w  = math.floor(total_w * 0.32)
  local prev_w  = total_w - list_w - 3
  local row     = math.floor((sh - total_h) / 2)
  local col     = math.floor((sw - total_w) / 2)

  list_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[list_buf].buftype    = 'nofile'
  vim.bo[list_buf].buflisted  = false
  vim.bo[list_buf].modifiable = false
  vim.bo[list_buf].filetype   = 'peek'
  -- 一覧選択窓なのでテキストカーソルは隠し、カーソル行の強調だけで現在地を示す。
  -- 窓へ入る前にマークしておくこと（explorer と同じ理由。開いてから付けると
  -- フラグが立っていない状態で BufEnter が飛んでカーソルが一瞬見える）
  hidden_cursor.mark_buffer(list_buf)

  list_win = vim.api.nvim_open_win(list_buf, true, {
    relative  = 'editor',
    row       = row,
    col       = col,
    width     = list_w,
    height    = total_h,
    style     = 'minimal',
    border    = 'rounded',
    title     = ' Results ',
    title_pos = 'center',
    zindex    = 50,
  })
  vim.wo[list_win].cursorline     = true
  vim.wo[list_win].number         = false
  vim.wo[list_win].relativenumber = false
  vim.wo[list_win].signcolumn     = 'no'
  vim.wo[list_win].winhighlight   = 'Normal:PeekList,CursorLine:PeekCursorLine'
  win_util.mark_sidebar(list_win, list_buf)

  prev_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
    relative  = 'editor',
    row       = row,
    col       = col + list_w + 2,
    width     = prev_w,
    height    = total_h,
    style     = 'minimal',
    border    = 'rounded',
    title     = ' Preview ',
    title_pos = 'center',
    zindex    = 50,
    focusable = false,
  })
  vim.wo[prev_win].number         = true
  vim.wo[prev_win].relativenumber = false
  vim.wo[prev_win].cursorline     = true
  vim.wo[prev_win].signcolumn     = 'no'
  vim.wo[prev_win].winhighlight   = 'Normal:PeekPreview,CursorLine:PeekCursorLine'
  win_util.mark_sidebar(prev_win)

  setup_keymaps()
  update_list()
  update_preview(1)
  vim.api.nvim_win_set_cursor(list_win, { 1, 0 })

  -- j/k だけでなく <Down> / gg / G / マウスクリック / 検索でも選択が追随する
  vim.api.nvim_create_autocmd('CursorMoved', {
    group    = close_augrp,
    buffer   = list_buf,
    callback = sync_from_cursor,
  })

  -- list_win からフォーカスが外れた時だけ閉じる
  vim.api.nvim_create_autocmd('WinLeave', {
    group    = close_augrp,
    callback = function()
      local leaving = vim.api.nvim_get_current_win()
      if leaving ~= list_win then return end
      vim.schedule(function()
        local cur = vim.api.nvim_get_current_win()
        if cur ~= list_win and cur ~= prev_win then
          close()
        end
      end)
    end,
  })
end

local function request(method, extra_params)
  local clients = vim.lsp.get_clients({ bufnr = 0 })
  if #clients == 0 then
    vim.notify('[peek] LSP クライアントが接続されていません', vim.log.levels.WARN)
    return
  end
  local encoding = clients[1].offset_encoding or 'utf-16'
  local params = vim.lsp.util.make_position_params(0, encoding)
  if extra_params then
    for k, v in pairs(extra_params) do params[k] = v end
  end
  vim.lsp.buf_request_all(0, method, params, function(results)
    local locs = {}
    for _, res in pairs(results) do
      if res.error then
        vim.notify('[peek] LSP エラー: ' .. vim.inspect(res.error), vim.log.levels.ERROR)
      end
      local r = res.result
      if r then
        if r.uri or r.targetUri then
          table.insert(locs, r)
        elseif type(r) == 'table' then
          for _, loc in ipairs(r) do
            table.insert(locs, loc)
          end
        end
      end
    end
    vim.schedule(function() open(locs) end)
  end)
end

function M.definition()      request('textDocument/definition') end
function M.references()      request('textDocument/references', { context = { includeDeclaration = true } }) end
function M.type_definition() request('textDocument/typeDefinition') end
function M.implementation()  request('textDocument/implementation') end

local function setup_hl()
  vim.api.nvim_set_hl(0, 'PeekList',       { bg = '#1e2030' })
  vim.api.nvim_set_hl(0, 'PeekPreview',    { bg = '#1a1b26' })
  vim.api.nvim_set_hl(0, 'PeekCursorLine', { bg = '#2d3250' })
end

setup_hl()
vim.api.nvim_create_autocmd('ColorScheme', { callback = setup_hl })

vim.keymap.set('n', 'gd', M.definition,      { desc = 'Peek: definition' })
vim.keymap.set('n', 'gr', M.references,      { desc = 'Peek: references' })
vim.keymap.set('n', 'gy', M.type_definition, { desc = 'Peek: type definition' })
vim.keymap.set('n', 'gI', M.implementation,  { desc = 'Peek: implementation' })

return M
