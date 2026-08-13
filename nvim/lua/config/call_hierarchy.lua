-- 呼び出し階層（VS Code の Show Call Hierarchy 相当）。
--
-- gr（参照一覧）との違いは「辿った経路が画面に残る」こと。参照一覧はフラットなので
-- 呼び元をもう一段辿るには飛んでから撃ち直すことになり、枝分かれを人間側が
-- 覚えておく羽目になる。ここでは開いた枝が木として残るので、どこまで見たか・
-- どの枝が未着手かが目で分かる。参照と違って呼び出しだけが出る（import 行や
-- コメント中の同じ語は入らない）のも読解では効く。
--
-- LSP は 2 段構え:
--   textDocument/prepareCallHierarchy  カーソル位置を CallHierarchyItem に確定する
--   callHierarchy/incomingCalls        その item の呼び元（from）
--   callHierarchy/outgoingCalls        その item が呼んでいる先（to）
-- 組み込みの vim.lsp.buf.incoming_calls() は quickfix へ 1 段流すだけで再帰的に
-- 辿れないため、ここは自前で木を持つ。
--
-- prepare を返したクライアントに以降の item を投げ続ける必要があるので
-- （item はサーバー固有の data を持つ）、buf_request_all ではなく
-- client:request で 1 クライアントに固定する。

local hidden_cursor = require('config.hidden_cursor')
local win_util      = require('config.util.win_util')
local lsp_symbols   = require('config.util.lsp_symbols')
local preview_buf   = require('config.util.preview_buf')

local M = {}

local DIRECTIONS = {
  incoming = { method = 'callHierarchy/incomingCalls', field = 'from', title = ' Incoming Calls (呼び元) ' },
  outgoing = { method = 'callHierarchy/outgoingCalls', field = 'to',   title = ' Outgoing Calls (呼び先) ' },
}

local tree_win, tree_buf, prev_win, original_win
local roots       = {}          -- ルートノード（prepare の結果は複数返りうる）
local rows        = {}          -- 表示行(1始まり) -> node
local current_idx = 1
local direction   = 'incoming'
local client_id   = nil
local hl_ns       = vim.api.nvim_create_namespace('call_hierarchy_hl')
local text_ns     = vim.api.nvim_create_namespace('call_hierarchy_text')
-- プレビューには実ファイルのバッファをそのまま載せるので、置いた先を覚えておいて
-- まとめて消す。消し忘れると閉じたあとも編集画面に強調行が残る（peek で踏んだ）
local hl_bufs     = {}
local close_augrp = vim.api.nvim_create_augroup('call_hierarchy_close', { clear = true })

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
  for _, w in ipairs({ tree_win, prev_win }) do
    if w and vim.api.nvim_win_is_valid(w) then
      vim.api.nvim_win_close(w, true)
    end
  end
  if tree_buf and vim.api.nvim_buf_is_valid(tree_buf) then
    vim.api.nvim_buf_delete(tree_buf, { force = true })
  end
  tree_win, prev_win, tree_buf, original_win = nil, nil, nil, nil
  roots, rows  = {}, {}
  current_idx  = 1
  client_id    = nil
end

--- 同じ関数か判定するための鍵。循環（A→B→A）を延々と展開できてしまうのを防ぐ
local function item_key(item)
  local r = item.selectionRange or item.range
  return table.concat({ item.uri, r.start.line, r.start.character, item.name }, ':')
end

local function is_cyclic(item, parent)
  local key = item_key(item)
  local p = parent
  while p do
    if item_key(p.item) == key then return true end
    p = p.parent
  end
  return false
end

---@param item table CallHierarchyItem
---@param from_ranges table[]|nil incoming のときだけ渡す（呼び出しているその行）
---@param parent table|nil
local function make_node(item, from_ranges, parent)
  return {
    item        = item,
    from_ranges = from_ranges,
    parent      = parent,
    depth       = parent and (parent.depth + 1) or 0,
    children    = nil,   -- nil = 未取得、{} = 取得済みで 0 件
    expanded    = false,
    loading     = false,
    cyclic      = is_cyclic(item, parent),
  }
end

--- ノードが指す場所。
--- incoming の fromRanges は「呼び元ファイルの中の、実際に呼んでいる位置」なので
--- 関数の定義行より有用。outgoing の fromRanges は親ファイル側の位置なので使わず、
--- 呼び先の定義位置へ寄せる。
local function node_location(node)
  local range = node.item.selectionRange or node.item.range
  if node.from_ranges and node.from_ranges[1] then
    range = node.from_ranges[1]
  end
  return vim.uri_to_fname(node.item.uri), range.start.line, range.start.character
end

local function build_rows()
  rows = {}
  local function walk(node)
    table.insert(rows, node)
    if node.expanded and node.children then
      for _, child in ipairs(node.children) do walk(child) end
    end
  end
  for _, root in ipairs(roots) do walk(root) end
end

-- マーカーは必ず非空白にする（「これ以上たどれない」が見えるように、
-- 子が居ないノードも空白ではなく記号にする）
local function marker_of(node)
  if node.cyclic then return '↻' end
  if node.loading then return '…' end
  if node.children and #node.children == 0 then return '·' end
  if node.expanded then return '▾' end
  return '▸'
end

local function render()
  if not tree_buf or not vim.api.nvim_buf_is_valid(tree_buf) then return end
  build_rows()

  local lines, marks = {}, {}
  for i, node in ipairs(rows) do
    local indent    = string.rep('  ', node.depth)
    local kind_name = lsp_symbols.kind_name(node.item.kind) or ''
    local icon      = lsp_symbols.ICONS[kind_name] or '󰌋'
    local file, lnum = node_location(node)
    local where     = string.format('%s:%d', vim.fn.fnamemodify(file, ':t'), lnum + 1)
    local head      = string.format('%s%s %s ', indent, marker_of(node), icon)
    local line      = head .. node.item.name .. '  ' .. where

    table.insert(lines, line)
    -- アイコンは種別ごとの色、場所は薄く。名前は素のままにして目立たせる
    local icon_col = #indent + #marker_of(node) + 1
    table.insert(marks, { i - 1, icon_col, icon_col + #icon,
      'CallHierarchy' .. lsp_symbols.kind_group(kind_name) })
    table.insert(marks, { i - 1, #line - #where, #line, 'CallHierarchyLocation' })
    if node.cyclic then
      table.insert(marks, { i - 1, 0, #line, 'CallHierarchyCyclic' })
    end
  end

  vim.bo[tree_buf].modifiable = true
  vim.api.nvim_buf_set_lines(tree_buf, 0, -1, false, lines)
  vim.bo[tree_buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(tree_buf, text_ns, 0, -1)
  for _, m in ipairs(marks) do
    pcall(vim.api.nvim_buf_add_highlight, tree_buf, text_ns, m[4], m[1], m[2], m[3])
  end
end

local function update_preview(idx)
  if not prev_win or not vim.api.nvim_win_is_valid(prev_win) then return end
  local node = rows[idx]
  if not node then return end
  local filepath, lnum, col = node_location(node)

  local pbuf = preview_buf.load(filepath)
  vim.api.nvim_win_set_buf(prev_win, pbuf)
  vim.api.nvim_win_set_cursor(prev_win, { lnum + 1, col })
  -- win_execute はウィンドウ切り替えの autocmd を発火させない
  vim.fn.win_execute(prev_win, 'normal! zz')

  clear_highlights()
  vim.api.nvim_buf_add_highlight(pbuf, hl_ns, 'Visual', lnum, 0, -1)
  hl_bufs[pbuf] = true

  if vim.api.nvim_win_is_valid(prev_win) then
    vim.api.nvim_win_set_config(prev_win, {
      title     = ' ' .. vim.fn.fnamemodify(filepath, ':~:.') .. ' ',
      title_pos = 'center',
    })
  end
end

--- カーソル行こそが選択。j/k だけをマッピングして選択を進めると <Down> や
--- マウスクリックでカーソルだけが動いて取り残されるため、CursorMoved から呼ぶ
local function sync_from_cursor()
  if not tree_win or not vim.api.nvim_win_is_valid(tree_win) then return end
  if #rows == 0 then return end
  local row = vim.api.nvim_win_get_cursor(tree_win)[1]
  row = math.max(1, math.min(row, #rows))
  current_idx = row
  update_preview(row)
end

local function move_cursor(idx)
  if not tree_win or not vim.api.nvim_win_is_valid(tree_win) then return end
  idx = math.max(1, math.min(idx, #rows))
  vim.api.nvim_win_set_cursor(tree_win, { idx, 0 })
  sync_from_cursor()
end

local function notify_err(msg)
  vim.notify('[call_hierarchy] ' .. msg, vim.log.levels.WARN)
end

--- 展開に必要な子ノードを取りに行く
local function request_children(node, cb)
  local client = client_id and vim.lsp.get_client_by_id(client_id)
  if not client then cb({}) return end
  local dir = DIRECTIONS[direction]
  client:request(dir.method, { item = node.item }, function(err, result)
    if err then
      vim.schedule(function() notify_err('取得に失敗しました: ' .. tostring(err.message or err)) end)
      cb({})
      return
    end
    local children = {}
    for _, call in ipairs(result or {}) do
      local item = call[dir.field]
      if item then
        -- fromRanges が呼び出し位置を指すのは incoming のときだけ
        local from_ranges = (direction == 'incoming') and call.fromRanges or nil
        table.insert(children, make_node(item, from_ranges, node))
      end
    end
    cb(children)
  end)
end

local function expand(node, on_done)
  if node.cyclic or node.loading then return end
  if node.children then
    node.expanded = true
    render()
    if on_done then on_done() end
    return
  end
  node.loading = true
  render()
  request_children(node, function(children)
    vim.schedule(function()
      node.loading  = false
      node.children = children
      node.expanded = true
      if not tree_buf or not vim.api.nvim_buf_is_valid(tree_buf) then return end
      render()
      sync_from_cursor()
      if on_done then on_done() end
    end)
  end)
end

local function collapse(node)
  if node.expanded then
    node.expanded = false
    render()
    return
  end
  -- 既に閉じているなら親へ上がる（ツリーUIの慣習）
  if node.parent then
    build_rows()
    for i, n in ipairs(rows) do
      if n == node.parent then move_cursor(i) return end
    end
  end
end

local function jump()
  local node = rows[current_idx]
  if not node then return end
  local filepath, lnum, col = node_location(node)
  local target = original_win
  close()
  if target and vim.api.nvim_win_is_valid(target) then
    vim.api.nvim_set_current_win(target)
  end
  vim.cmd('edit ' .. vim.fn.fnameescape(filepath))
  vim.api.nvim_win_set_cursor(0, { lnum + 1, col })
end

--- 呼び元 / 呼び先を切り替える。ルートはそのままに、取得済みの枝を捨てて張り直す
local function set_direction(dir)
  if direction == dir then return end
  direction = dir
  for _, root in ipairs(roots) do
    root.children = nil
    root.expanded = false
    root.loading  = false
  end
  if tree_win and vim.api.nvim_win_is_valid(tree_win) then
    vim.api.nvim_win_set_config(tree_win, {
      title     = DIRECTIONS[direction].title,
      title_pos = 'center',
    })
  end
  render()
  if roots[1] then expand(roots[1], function() move_cursor(1) end) end
end

local function setup_keymaps()
  local function map(key, fn)
    vim.keymap.set('n', key, fn, { buffer = tree_buf, nowait = true, silent = true })
  end
  -- j/k は素の移動のまま（3j のようなカウントも効く）。追随は CursorMoved が行う
  map('l',       function() local n = rows[current_idx]; if n then expand(n) end end)
  map('<Tab>',   function() local n = rows[current_idx]; if n then expand(n) end end)
  map('h',       function() local n = rows[current_idx]; if n then collapse(n) end end)
  map('<CR>',    jump)
  map('o',       function() set_direction('outgoing') end)
  map('i',       function() set_direction('incoming') end)
  map('q',       close)
  map('<Esc>',   close)
end

local function open_windows()
  original_win = vim.api.nvim_get_current_win()

  local sw      = vim.o.columns
  local sh      = vim.o.lines - vim.o.cmdheight - 2
  local total_w = math.min(math.floor(sw * 0.9), sw - 4)
  local total_h = math.floor(sh * 0.6)
  -- peek より木側を広く取る（インデントとシンボル名で横に伸びるため）
  local tree_w  = math.floor(total_w * 0.42)
  local prev_w  = total_w - tree_w - 3
  local row     = math.floor((sh - total_h) / 2)
  local col     = math.floor((sw - total_w) / 2)

  tree_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[tree_buf].buftype    = 'nofile'
  vim.bo[tree_buf].buflisted  = false
  vim.bo[tree_buf].modifiable = false
  vim.bo[tree_buf].filetype   = 'callhierarchy'
  -- 一覧選択窓なのでテキストカーソルは隠す。窓へ入る前にマークしておくこと
  -- （開いてから付けるとフラグが立っていない状態で BufEnter が飛んで一瞬見える）
  hidden_cursor.mark_buffer(tree_buf)

  tree_win = vim.api.nvim_open_win(tree_buf, true, {
    relative  = 'editor',
    row       = row,
    col       = col,
    width     = tree_w,
    height    = total_h,
    style     = 'minimal',
    border    = 'rounded',
    title     = DIRECTIONS[direction].title,
    title_pos = 'center',
    zindex    = 50,
  })
  vim.wo[tree_win].cursorline     = true
  vim.wo[tree_win].number         = false
  vim.wo[tree_win].relativenumber = false
  vim.wo[tree_win].signcolumn     = 'no'
  vim.wo[tree_win].winhighlight   = 'Normal:CallHierarchyList,CursorLine:CallHierarchyCursorLine'
  win_util.mark_sidebar(tree_win, tree_buf)

  prev_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
    relative  = 'editor',
    row       = row,
    col       = col + tree_w + 2,
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
  vim.wo[prev_win].winhighlight   = 'Normal:CallHierarchyPreview,CursorLine:CallHierarchyCursorLine'
  win_util.mark_sidebar(prev_win)

  setup_keymaps()
  render()
  vim.api.nvim_win_set_cursor(tree_win, { 1, 0 })
  update_preview(1)

  -- j/k だけでなく <Down> / gg / G / マウスクリック / 検索でも選択が追随する
  vim.api.nvim_create_autocmd('CursorMoved', {
    group    = close_augrp,
    buffer   = tree_buf,
    callback = sync_from_cursor,
  })

  -- tree_win からフォーカスが外れた時だけ閉じる
  vim.api.nvim_create_autocmd('WinLeave', {
    group    = close_augrp,
    callback = function()
      if vim.api.nvim_get_current_win() ~= tree_win then return end
      vim.schedule(function()
        local cur = vim.api.nvim_get_current_win()
        if cur ~= tree_win and cur ~= prev_win then close() end
      end)
    end,
  })
end

--- callHierarchy を扱えるクライアントを1つ返す
local function hierarchy_client(buf)
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
    if client:supports_method('textDocument/prepareCallHierarchy') then
      return client
    end
  end
  return nil
end

---@param dir 'incoming'|'outgoing'|nil 既定は incoming（呼び元をたどる）
function M.open(dir)
  local buf = vim.api.nvim_get_current_buf()
  local client = hierarchy_client(buf)
  if not client then
    notify_err('このバッファの LSP は呼び出し階層に対応していません')
    return
  end

  direction = dir or 'incoming'
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  client:request('textDocument/prepareCallHierarchy', params, function(err, result)
    if err then
      vim.schedule(function() notify_err('取得に失敗しました: ' .. tostring(err.message or err)) end)
      return
    end
    if not result or vim.tbl_isempty(result) then
      notify_err('カーソル位置に関数・メソッドが見つかりません')
      return
    end
    vim.schedule(function()
      client_id   = client.id
      roots       = {}
      current_idx = 1
      for _, item in ipairs(result) do
        table.insert(roots, make_node(item, nil, nil))
      end
      open_windows()
      -- 開いた瞬間に 1 段目（呼び元一覧）が見えていてほしいので自動で展開する
      expand(roots[1], function() move_cursor(1) end)
    end)
  end, buf)
end

function M.incoming() M.open('incoming') end
function M.outgoing() M.open('outgoing') end

local function setup_hl()
  vim.api.nvim_set_hl(0, 'CallHierarchyList',       { bg = '#1e2030' })
  vim.api.nvim_set_hl(0, 'CallHierarchyPreview',    { bg = '#1a1b26' })
  vim.api.nvim_set_hl(0, 'CallHierarchyCursorLine', { bg = '#2d3250' })
  vim.api.nvim_set_hl(0, 'CallHierarchyLocation',   { fg = '#565f89' })
  vim.api.nvim_set_hl(0, 'CallHierarchyCyclic',     { fg = '#565f89', italic = true })
  -- アイコンの色は winbar / symbols と同じ系統に合わせる
  vim.api.nvim_set_hl(0, 'CallHierarchyType',       { link = 'Type' })
  vim.api.nvim_set_hl(0, 'CallHierarchyFunction',   { link = 'Function' })
  vim.api.nvim_set_hl(0, 'CallHierarchyInclude',    { link = 'Include' })
  vim.api.nvim_set_hl(0, 'CallHierarchyIdentifier', { link = 'Identifier' })
end
setup_hl()
vim.api.nvim_create_autocmd('ColorScheme', { callback = setup_hl })

vim.keymap.set('n', '<leader>ch', M.incoming, { desc = 'Call Hierarchy: 呼び元をたどる' })

return M
