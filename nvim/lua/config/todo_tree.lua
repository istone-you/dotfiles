-- Todo tree (VSCode todo-tree 相当)
--
-- ripgrep で workspace 内の TODO/FIXME/BUG 等を探し、サイドバーにファイル別 /
-- フラット / タグ別で表示する。開いているバッファ内のタグは軽くハイライトする。

local win_util      = require('config.util.win_util')
local hidden_cursor = require('config.hidden_cursor')

local M = {}

M.PANEL_WIDTH = 42
M.TAGS = { 'TODO', 'FIXME', 'BUG', 'HACK', 'NOTE', 'XXX' }
M.EXCLUDE_GLOBS = { '!**/.git/**', '!**/node_modules/**', '!**/dist/**', '!**/build/**' }
M.VIEWS = { 'tree', 'flat', 'tags' }

local win = nil
local buf = nil
local meta = {}
local item_lnums = {}
local last_lnum = nil
local items = {}
local view_idx = 1
local filter = ''
local tag_filter = {}
local expanded = {}
local filter_win = nil
local filter_buf = nil

local panel_ns = vim.api.nvim_create_namespace('todo_tree_panel')
local mark_ns = vim.api.nvim_create_namespace('todo_tree_marks')
local augrp = vim.api.nvim_create_augroup('todo_tree', { clear = true })

local TAG_HL = {
  TODO  = 'TodoTreeTodo',
  FIXME = 'TodoTreeFixme',
  BUG   = 'TodoTreeBug',
  HACK  = 'TodoTreeHack',
  NOTE  = 'TodoTreeNote',
  XXX   = 'TodoTreeFixme',
}

local TAG_ICON = {
  TODO  = '✓',
  FIXME = '!',
  BUG   = '!',
  HACK  = '*',
  NOTE  = 'i',
  XXX   = '!',
}

local TREE_ARROW_CLOSED = ''
local TREE_ARROW_OPEN = ''

local function root_dir()
  local res = vim.system({ 'git', 'rev-parse', '--show-toplevel' }, { text = true }):wait()
  if res.code == 0 and res.stdout and res.stdout ~= '' then
    return (res.stdout:gsub('%s+$', ''))
  end
  return vim.fn.getcwd()
end

local function relpath(path, root)
  local p = vim.fn.fnamemodify(path, ':p')
  local r = vim.fn.fnamemodify(root, ':p')
  if p:sub(1, #r) == r then return p:sub(#r + 1) end
  return vim.fn.fnamemodify(path, ':.')
end

local function escape_regex(s)
  return (s:gsub('([%W])', '\\%1'))
end

function M.regex()
  local tags = {}
  for _, tag in ipairs(M.TAGS) do
    table.insert(tags, escape_regex(tag))
  end
  return [[(//|--|#|<!--|;|/\*|^[ \t]*(-|[0-9]+\.))\s*(]] .. table.concat(tags, '|') .. [[)\b]]
end

local function inside_simple_string(line, col0)
  local quote = nil
  local escaped = false
  local i = 1
  while i <= col0 do
    local ch = line:sub(i, i)
    if escaped then
      escaped = false
    elseif ch == '\\' then
      escaped = true
    elseif quote then
      if ch == quote then quote = nil end
    elseif ch == '"' or ch == "'" or ch == '`' then
      quote = ch
    end
    i = i + 1
  end
  return quote ~= nil
end

local function parse_json_line(line, root)
  local ok, obj = pcall(vim.json.decode, line)
  if not ok or type(obj) ~= 'table' or obj.type ~= 'match' then return nil end
  local data = obj.data or {}
  local path = data.path and data.path.text
  local lines = data.lines and data.lines.text
  local subs = data.submatches or {}
  if not path or not lines then return nil end

  local tag, col, match_start
  for _, sub in ipairs(subs) do
    local text = sub.match and sub.match.text
    for _, candidate in ipairs(M.TAGS) do
      local start_in_match = text and text:find(candidate, 1, true)
      if start_in_match then
        tag = candidate
        match_start = sub.start or 0
        col = (sub.start or 0) + start_in_match - 1
        break
      end
    end
    if tag then break end
  end
  if not tag then return nil end

  local lnum = data.line_number or 1
  local abs = vim.fn.fnamemodify(path, ':p')
  local raw = lines:gsub('\r?\n$', '')
  if inside_simple_string(raw, match_start or col or 0) then return nil end
  local after = raw:sub((col or 0) + #tag + 1):gsub('^%s*:?%s*', '')
  return {
    path = relpath(abs, root),
    abs_path = abs,
    lnum = lnum,
    col = col or 0,
    tag = tag,
    text = raw,
    after = after,
  }
end

function M.parse_rg_json(text, root)
  local out = {}
  for line in tostring(text or ''):gmatch('[^\n]+') do
    local item = parse_json_line(line, root or vim.fn.getcwd())
    if item then table.insert(out, item) end
  end
  table.sort(out, function(a, b)
    if a.path ~= b.path then return a.path < b.path end
    if a.lnum ~= b.lnum then return a.lnum < b.lnum end
    return a.col < b.col
  end)
  return out
end

function M.scan(root)
  root = root or root_dir()
  if vim.fn.executable('rg') ~= 1 then
    return nil, 'rg が見つかりません'
  end

  local args = {
    'rg',
    '--json',
    '--hidden',
    '--no-ignore-global',
    '--max-columns=1000',
  }
  for _, glob in ipairs(M.EXCLUDE_GLOBS) do
    table.insert(args, '--glob')
    table.insert(args, glob)
  end
  table.insert(args, '-e')
  table.insert(args, M.regex())
  table.insert(args, root)

  local res = vim.system(args, { text = true }):wait()
  if res.code ~= 0 and (res.stdout == nil or res.stdout == '') then
    return {}, nil
  end
  return M.parse_rg_json(res.stdout, root), nil
end

local function matches_filter(item)
  if next(tag_filter) ~= nil and not tag_filter[item.tag] then return false end
  if filter == '' then return true end
  local needle = filter:lower()
  return item.path:lower():find(needle, 1, true)
    or item.tag:lower():find(needle, 1, true)
    or item.after:lower():find(needle, 1, true)
    or item.text:lower():find(needle, 1, true)
end

local function filtered_items()
  local out = {}
  for _, item in ipairs(items) do
    if matches_filter(item) then table.insert(out, item) end
  end
  return out
end

local function counts_by_tag(list)
  local counts = {}
  for _, tag in ipairs(M.TAGS) do counts[tag] = 0 end
  for _, item in ipairs(list) do counts[item.tag] = (counts[item.tag] or 0) + 1 end
  return counts
end

local function add_item_line(lines, line_meta, hls, item, indent, show_file)
  local pos = string.format('%d:%d', item.lnum, item.col + 1)
  local label = item.after ~= '' and item.after or item.text
  local prefix = string.rep(' ', indent) .. (TAG_ICON[item.tag] or '-') .. ' ' .. item.tag
  local line
  if show_file then
    line = string.format('%s %-9s %s  %s', prefix, pos, item.path, label)
  else
    line = string.format('%s %-9s %s', prefix, pos, label)
  end
  table.insert(lines, line)
  line_meta[#lines] = { kind = 'item', item = item }
  table.insert(hls, { #lines - 1, TAG_HL[item.tag] or 'TodoTreeTodo', indent, indent + #prefix })
end

local function add_group_line(lines, line_meta, hls, key, label, count, hl, indent)
  indent = indent or 0
  local is_open = expanded[key] == true
  local arrow = is_open and TREE_ARROW_OPEN or TREE_ARROW_CLOSED
  table.insert(lines, string.format('%s%s %s (%d)', string.rep(' ', indent), arrow, label, count))
  line_meta[#lines] = { kind = 'group', key = key }
  table.insert(hls, { #lines - 1, hl, 0, -1 })
end

local function tree_node(kind, key, label)
  return {
    kind = kind,
    key = key,
    label = label,
    count = 0,
    dirs = {},
    files = {},
    items = {},
  }
end

local function insert_tree_item(root, item)
  local parts = vim.split(item.path, '/', { plain = true })
  local node = root
  node.count = node.count + 1
  local prefix = {}
  for i = 1, #parts - 1 do
    table.insert(prefix, parts[i])
    local key = table.concat(prefix, '/')
    if not node.dirs[parts[i]] then
      node.dirs[parts[i]] = tree_node('dir', 'dir:' .. key, parts[i])
    end
    node = node.dirs[parts[i]]
    node.count = node.count + 1
  end
  local file = parts[#parts]
  if not node.files[file] then
    node.files[file] = tree_node('file', 'file:' .. item.path, file)
  end
  node.files[file].count = node.files[file].count + 1
  table.insert(node.files[file].items, item)
end

local function sorted_values(t)
  local out = vim.tbl_values(t)
  table.sort(out, function(a, b) return a.label < b.label end)
  return out
end

local function compress_tree(node)
  local dir_names = vim.tbl_keys(node.dirs)
  for _, name in ipairs(dir_names) do
    local child = node.dirs[name]
    while child and vim.tbl_count(child.files) == 0 and vim.tbl_count(child.dirs) == 1 do
      child = vim.tbl_values(child.dirs)[1]
      node.dirs[name] = child
    end
  end
  for _, child in pairs(node.dirs) do
    compress_tree(child)
  end
end

local function dir_path(node)
  return node.key:gsub('^dir:', '')
end

local function display_label(node, parent_path)
  if node.kind ~= 'dir' then return node.label end
  local path = dir_path(node)
  if not parent_path or parent_path == '' then return path end
  return path:sub(#parent_path + 2)
end

local function render_tree_node(lines, line_meta, hls, node, indent, parent_path)
  add_group_line(lines, line_meta, hls, node.key, display_label(node, parent_path), node.count, 'TodoTreeGroup', indent)
  if not expanded[node.key] then return end
  for _, child in ipairs(sorted_values(node.dirs)) do
    render_tree_node(lines, line_meta, hls, child, indent + 2, node.kind == 'dir' and dir_path(node) or nil)
  end
  for _, child in ipairs(sorted_values(node.files)) do
    render_tree_node(lines, line_meta, hls, child, indent + 2, nil)
  end
  if node.kind == 'file' then
    table.sort(node.items, function(a, b)
      if a.lnum ~= b.lnum then return a.lnum < b.lnum end
      return a.col < b.col
    end)
    for _, item in ipairs(node.items) do
      add_item_line(lines, line_meta, hls, item, indent + 4, false)
    end
  end
end

function M.build(list)
  list = list or filtered_items()
  local lines, line_meta, hls = {}, {}, {}
  local counts = counts_by_tag(list)
  local summary = {}
  for _, tag in ipairs(M.TAGS) do
    if counts[tag] and counts[tag] > 0 then table.insert(summary, tag .. ':' .. counts[tag]) end
  end

  local selected = {}
  for _, tag in ipairs(M.TAGS) do
    if tag_filter[tag] then table.insert(selected, tag) end
  end
  local tag_label = #selected > 0 and table.concat(selected, ',') or 'all'
  local header = string.format(' TODO Tree  %d  [%s]  tags:%s  %s',
    #list,
    M.VIEWS[view_idx],
    tag_label,
    filter ~= '' and ('filter: ' .. filter) or 'workspace')
  table.insert(lines, header)
  table.insert(hls, { 0, 'TodoTreeHeader', 0, -1 })
  table.insert(lines, table.concat(summary, '  '))
  table.insert(hls, { 1, 'TodoTreeCounts', 0, -1 })

  if #list == 0 then
    table.insert(lines, '')
    table.insert(lines, ' TODO はありません')
    table.insert(hls, { 3, 'TodoTreeEmpty', 0, -1 })
    return lines, line_meta, hls
  end

  local view = M.VIEWS[view_idx]
  if view == 'flat' then
    table.insert(lines, '')
    for _, item in ipairs(list) do
      add_item_line(lines, line_meta, hls, item, 1, true)
    end
  elseif view == 'tags' then
    for _, tag in ipairs(M.TAGS) do
      local tag_items = {}
      for _, item in ipairs(list) do
        if item.tag == tag then table.insert(tag_items, item) end
      end
      if #tag_items > 0 then
        table.insert(lines, '')
        local key = 'tag:' .. tag
        add_group_line(lines, line_meta, hls, key, (TAG_ICON[tag] or '-') .. ' ' .. tag, #tag_items, TAG_HL[tag] or 'TodoTreeTodo')
        if expanded[key] then
          for _, item in ipairs(tag_items) do
            add_item_line(lines, line_meta, hls, item, 3, true)
          end
        end
      end
    end
  else
    local root = tree_node('root', 'root:', '')
    for _, item in ipairs(list) do
      insert_tree_item(root, item)
    end
    compress_tree(root)
    table.insert(lines, '')
    for _, node in ipairs(sorted_values(root.dirs)) do
      render_tree_node(lines, line_meta, hls, node, 0, nil)
    end
    for _, node in ipairs(sorted_values(root.files)) do
      render_tree_node(lines, line_meta, hls, node, 0, nil)
    end
  end

  return lines, line_meta, hls
end

local function apply_highlights()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      vim.api.nvim_buf_clear_namespace(b, mark_ns, 0, -1)
    end
  end
  for _, item in ipairs(items) do
    local bufnr = vim.fn.bufnr(item.abs_path)
    if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, mark_ns, item.lnum - 1, item.col, {
        end_col = item.col + #item.tag,
        hl_group = TAG_HL[item.tag] or 'TodoTreeTodo',
      })
    end
  end
end

function M.refresh()
  local found, err = M.scan(root_dir())
  if err then vim.notify(err, vim.log.levels.WARN) end
  items = found or {}
  apply_highlights()
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end

  local lines, line_meta, hls = M.build(filtered_items())
  meta = line_meta
  item_lnums = vim.tbl_keys(meta)
  table.sort(item_lnums)

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, panel_ns, 0, -1)
  for _, hl in ipairs(hls) do
    vim.api.nvim_buf_add_highlight(buf, panel_ns, hl[2], hl[1], hl[3], hl[4])
  end
  if win and vim.api.nvim_win_is_valid(win) then
    vim.wo[win].cursorline = #item_lnums > 0
    M.snap_cursor()
  end
end

function M.nearest_item(lnums, lnum, dir)
  if #lnums == 0 then return nil end
  for _, l in ipairs(lnums) do
    if l == lnum then return lnum end
  end
  local forward, backward
  for _, l in ipairs(lnums) do
    if l > lnum then
      forward = forward or l
    elseif l < lnum then
      backward = l
    end
  end
  if dir >= 0 then return forward or backward end
  return backward or forward
end

function M.snap_cursor()
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  local cur = vim.api.nvim_win_get_cursor(win)[1]
  local dir = (last_lnum and cur < last_lnum) and -1 or 1
  local target = M.nearest_item(item_lnums, cur, dir)
  if target and target ~= cur then
    pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
    cur = target
  end
  last_lnum = cur
end

local function jump_to_item(item)
  if not item then return end
  win_util.focus_editor()
  if not win_util.is_editor(vim.api.nvim_get_current_win()) then return end
  vim.cmd.edit(vim.fn.fnameescape(item.abs_path))
  pcall(vim.api.nvim_win_set_cursor, 0, { item.lnum, item.col })
  vim.cmd('normal! zz')
end

function M.jump()
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  local node = meta[vim.api.nvim_win_get_cursor(win)[1]]
  if not node then return end
  if node.kind == 'group' then
    expanded[node.key] = not expanded[node.key]
    M.refresh()
    return
  end
  jump_to_item(node.item)
end

function M.toggle_node(open)
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  local node = meta[vim.api.nvim_win_get_cursor(win)[1]]
  if not node or node.kind ~= 'group' then return end
  if open == nil then
    expanded[node.key] = not expanded[node.key]
  elseif open then
    expanded[node.key] = true
  else
    expanded[node.key] = nil
  end
  M.refresh()
end

function M.expand_all()
  for _, item in ipairs(filtered_items()) do
    local parts = vim.split(item.path, '/', { plain = true })
    local prefix = {}
    for i = 1, #parts - 1 do
      table.insert(prefix, parts[i])
      expanded['dir:' .. table.concat(prefix, '/')] = true
    end
    expanded['file:' .. item.path] = true
    expanded['tag:' .. item.tag] = true
  end
  M.refresh()
end

function M.collapse_all()
  expanded = {}
  M.refresh()
end

local function sorted_for_current_file()
  local path = vim.api.nvim_buf_get_name(0)
  local rel = relpath(path, root_dir())
  local out = {}
  for _, item in ipairs(items) do
    if item.path == rel then table.insert(out, item) end
  end
  table.sort(out, function(a, b)
    if a.lnum ~= b.lnum then return a.lnum < b.lnum end
    return a.col < b.col
  end)
  return out
end

function M.goto_next(dir)
  if #items == 0 then M.refresh() end
  local list = sorted_for_current_file()
  if #list == 0 then
    vim.notify('このファイルに TODO はありません', vim.log.levels.INFO)
    return
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local target
  if dir >= 0 then
    for _, item in ipairs(list) do
      if item.lnum > row or (item.lnum == row and item.col > col) then
        target = item
        break
      end
    end
    target = target or list[1]
  else
    for i = #list, 1, -1 do
      local item = list[i]
      if item.lnum < row or (item.lnum == row and item.col < col) then
        target = item
        break
      end
    end
    target = target or list[#list]
  end
  jump_to_item(target)
end

function M.cycle_view()
  view_idx = view_idx % #M.VIEWS + 1
  M.refresh()
end

local function close_filter_popup()
  if filter_win and vim.api.nvim_win_is_valid(filter_win) then
    vim.api.nvim_win_close(filter_win, true)
  end
  if filter_buf and vim.api.nvim_buf_is_valid(filter_buf) then
    vim.api.nvim_buf_delete(filter_buf, { force = true })
  end
  filter_win, filter_buf = nil, nil
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_set_current_win, win)
  end
end

local function render_filter_popup(selected)
  if not (filter_buf and vim.api.nvim_buf_is_valid(filter_buf)) then return end
  local lines = { ' TODO tags' }
  for _, tag in ipairs(M.TAGS) do
    table.insert(lines, string.format(' [%s] %s %s',
      selected[tag] and 'x' or ' ',
      TAG_ICON[tag] or '-',
      tag))
  end
  vim.bo[filter_buf].modifiable = true
  vim.api.nvim_buf_set_lines(filter_buf, 0, -1, false, lines)
  vim.bo[filter_buf].modifiable = false
end

function M.select_tag_filter()
  if filter_win and vim.api.nvim_win_is_valid(filter_win) then
    close_filter_popup()
    return
  end

  local selected = {}
  if next(tag_filter) == nil then
    for _, tag in ipairs(M.TAGS) do selected[tag] = true end
  else
    for _, tag in ipairs(M.TAGS) do selected[tag] = tag_filter[tag] == true end
  end

  filter_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[filter_buf].buftype = 'nofile'
  vim.bo[filter_buf].buflisted = false
  vim.bo[filter_buf].filetype = 'todo-tree-filter'
  filter_win = vim.api.nvim_open_win(filter_buf, true, {
    relative = 'editor',
    width = 24,
    height = #M.TAGS + 1,
    row = math.max(1, math.floor((vim.o.lines - (#M.TAGS + 1)) / 2)),
    col = math.max(1, math.floor((vim.o.columns - 24) / 2)),
    border = 'single',
    style = 'minimal',
    zindex = 80,
  })
  vim.wo[filter_win].cursorline = true
  vim.wo[filter_win].number = false
  vim.wo[filter_win].relativenumber = false
  vim.wo[filter_win].signcolumn = 'no'
  vim.wo[filter_win].winhighlight = 'Normal:TodoTreeBg,FloatBorder:TodoTreeGroup,CursorLine:TodoTreeSel'
  render_filter_popup(selected)
  vim.api.nvim_win_set_cursor(filter_win, { 2, 0 })

  local function current_tag()
    local row = vim.api.nvim_win_get_cursor(filter_win)[1]
    return M.TAGS[row - 1]
  end
  local function toggle()
    local tag = current_tag()
    if not tag then return end
    selected[tag] = not selected[tag]
    render_filter_popup(selected)
    pcall(vim.api.nvim_win_set_cursor, filter_win, { vim.api.nvim_win_get_cursor(filter_win)[1], 0 })
  end
  local function set_all(value)
    for _, tag in ipairs(M.TAGS) do selected[tag] = value end
    render_filter_popup(selected)
  end
  local function apply()
    local next_filter = {}
    local count = 0
    for _, tag in ipairs(M.TAGS) do
      if selected[tag] then
        next_filter[tag] = true
        count = count + 1
      end
    end
    tag_filter = (count == 0 or count == #M.TAGS) and {} or next_filter
    close_filter_popup()
    M.refresh()
  end

  local function map(key, fn)
    vim.keymap.set('n', key, fn, { buffer = filter_buf, nowait = true, silent = true })
  end
  map('<Space>', toggle)
  map('a', function() set_all(true) end)
  map('c', function() set_all(false) end)
  map('<CR>', apply)
  map('q', close_filter_popup)
  map('<Esc>', close_filter_popup)
end

function M.prompt_filter()
  vim.ui.input({ prompt = 'TODO filter: ', default = filter }, function(input)
    if input == nil then return end
    filter = input
    M.refresh()
  end)
end

function M.clear_filter()
  filter = ''
  M.refresh()
end

function M.close()
  vim.api.nvim_clear_autocmds({ group = augrp })
  close_filter_popup()
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  win, buf, meta, item_lnums, last_lnum, expanded = nil, nil, {}, {}, nil, {}
end

function M.is_open()
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

function M.win_id()
  return win
end

function M.open()
  if M.is_open() then return end
  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].buflisted = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'todo-tree'

  vim.cmd('botright ' .. M.PANEL_WIDTH .. 'vsplit')
  win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  hidden_cursor.mark_buffer(buf)
  win_util.mark_sidebar(win, buf)

  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].foldcolumn = '0'
  vim.wo[win].statuscolumn = ''
  vim.wo[win].cursorline = true
  vim.wo[win].winfixwidth = true
  vim.wo[win].winhighlight = 'Normal:TodoTreeBg,NormalNC:TodoTreeBg,EndOfBuffer:TodoTreeBg,CursorLine:TodoTreeSel'
  vim.wo[win].statusline = '%#TodoTreeBg#'

  last_lnum = nil
  expanded = {}
  M.refresh()

  vim.api.nvim_create_autocmd('CursorMoved', {
    group = augrp,
    buffer = buf,
    callback = function() M.snap_cursor() end,
  })
  vim.api.nvim_create_autocmd({ 'BufWritePost', 'DirChanged' }, {
    group = augrp,
    callback = function() M.refresh() end,
  })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'TextChanged', 'TextChangedI' }, {
    group = augrp,
    callback = function() apply_highlights() end,
  })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = augrp,
    pattern = tostring(win),
    once = true,
    callback = function()
      if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      win, buf, meta, item_lnums, last_lnum, expanded = nil, nil, {}, {}, nil, {}
      vim.api.nvim_clear_autocmds({ group = augrp })
    end,
  })

  local function map(key, fn)
    vim.keymap.set('n', key, fn, { buffer = buf, nowait = true, silent = true })
  end
  map('<CR>', M.jump)
  map('o', M.jump)
  map('<Space>', function() M.toggle_node(nil) end)
  map('l', function() M.toggle_node(true) end)
  map('h', function() M.toggle_node(false) end)
  map('E', M.expand_all)
  map('W', M.collapse_all)
  map('m', M.cycle_view)
  map('f', M.select_tag_filter)
  map('/', M.prompt_filter)
  map('<BS>', M.clear_filter)
  map('R', M.refresh)
  map('q', M.close)
  map('<Esc>', M.close)
end

function M.toggle()
  if M.is_open() then M.close() else M.open() end
end

local function setup_hl()
  vim.api.nvim_set_hl(0, 'TodoTreeBg',     { bg = 'none' })
  vim.api.nvim_set_hl(0, 'TodoTreeHeader', { fg = '#7aa2f7', bold = true })
  vim.api.nvim_set_hl(0, 'TodoTreeCounts', { fg = '#565f89' })
  vim.api.nvim_set_hl(0, 'TodoTreeGroup',  {})
  vim.api.nvim_set_hl(0, 'TodoTreeEmpty',  { fg = '#565f89', italic = true })
  vim.api.nvim_set_hl(0, 'TodoTreeSel',    { bg = '#2d3250' })
  vim.api.nvim_set_hl(0, 'TodoTreeTodo',   { fg = '#9ece6a', bold = true })
  vim.api.nvim_set_hl(0, 'TodoTreeFixme',  { fg = '#f7768e', bold = true })
  vim.api.nvim_set_hl(0, 'TodoTreeBug',    { fg = '#ff9e64', bold = true })
  vim.api.nvim_set_hl(0, 'TodoTreeHack',   { fg = '#bb9af7', bold = true })
  vim.api.nvim_set_hl(0, 'TodoTreeNote',   { fg = '#7dcfff', bold = true })
end

setup_hl()
vim.api.nvim_create_autocmd('ColorScheme', { callback = setup_hl })

vim.keymap.set('n', '<leader>T', M.toggle, { desc = 'TODOツリーを開閉' })
vim.keymap.set('n', ']t', function() M.goto_next(1) end, { desc = '次のTODOへ' })
vim.keymap.set('n', '[t', function() M.goto_next(-1) end, { desc = '前のTODOへ' })

return M
