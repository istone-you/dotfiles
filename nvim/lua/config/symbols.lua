local M = {}

local prompt_win = nil
local prompt_buf = nil
local results_win = nil
local results_buf = nil
local source_win = nil
local source_buf = nil
local source_pos = nil
local source_view = nil
local all_items = {}
local filtered_items = {}
local selected = 1
local width = 72
local row = 0
local col = 0
local max_height = 12
local augrp = vim.api.nvim_create_augroup('symbol_picker', { clear = true })
local hl_ns = vim.api.nvim_create_namespace('symbol_picker')
local preview_ns = vim.api.nvim_create_namespace('symbol_picker_preview')

local ICONS = require('config.util.lsp_symbols').ICONS

local LSP_KIND_NAMES = nil

local function kind_name(kind)
  if type(kind) == 'string' then return kind end
  if not LSP_KIND_NAMES then
    LSP_KIND_NAMES = {}
    for name, value in pairs(vim.lsp.protocol.SymbolKind) do
      if type(value) == 'number' then
        LSP_KIND_NAMES[value] = name
      end
    end
  end
  return LSP_KIND_NAMES[kind] or 'Variable'
end

local function close()
  vim.api.nvim_clear_autocmds({ group = augrp })
  if source_buf and vim.api.nvim_buf_is_valid(source_buf) then
    pcall(vim.api.nvim_buf_clear_namespace, source_buf, preview_ns, 0, -1)
  end
  if source_win and vim.api.nvim_win_is_valid(source_win) then
    if source_pos then pcall(vim.api.nvim_win_set_cursor, source_win, source_pos) end
    if source_view then
      pcall(vim.api.nvim_win_call, source_win, function()
        vim.fn.winrestview(source_view)
      end)
    end
  end
  for _, win in ipairs({ prompt_win, results_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, buf in ipairs({ prompt_buf, results_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  prompt_win, prompt_buf, results_win, results_buf = nil, nil, nil, nil
  source_win, source_buf, source_pos, source_view = nil, nil, nil, nil
  all_items, filtered_items = {}, {}
  selected = 1
end

local function normalize_query(text)
  return (text or ''):lower()
end

local function strwidth(text)
  return vim.fn.strdisplaywidth(text or '')
end

local function truncate(text, max_width)
  if strwidth(text) <= max_width then return text end
  local out = text
  while #out > 0 and strwidth(out) > math.max(0, max_width - 1) do
    out = out:sub(1, -2)
  end
  return out .. '…'
end

local function copy_list(items)
  local out = {}
  for _, item in ipairs(items) do
    table.insert(out, item)
  end
  return out
end

local function fuzzy_match(text, query)
  query = normalize_query(query)
  if query == '' then return true end
  text = normalize_query(text)
  if text:find(query, 1, true) then return true end
  local pos = 1
  for i = 1, #query do
    local ch = query:sub(i, i)
    local found = text:find(ch, pos, true)
    if not found then return false end
    pos = found + 1
  end
  return true
end

local function current_index()
  if results_win and vim.api.nvim_win_is_valid(results_win) then
    local ok, cursor = pcall(vim.api.nvim_win_get_cursor, results_win)
    if ok then return math.max(1, math.min(cursor[1], math.max(1, #filtered_items))) end
  end
  return math.max(1, math.min(selected, math.max(1, #filtered_items)))
end

local function make_tree_guides(item)
  if not item.tree_state or #item.tree_state == 0 then return '' end
  local out = ''
  for i = 1, #item.tree_state - 1 do
    out = out .. (item.tree_state[i] and '  ' or '┆ ')
  end
  out = out .. (item.tree_state[#item.tree_state] and '└─' or '├─')
  return out
end

local function raw_item_line(item)
  local icon = ICONS[item.kind] or '󰌋'
  return '  ' .. make_tree_guides(item) .. icon .. '  ' .. item.name .. ' ' .. string.format('%4d', item.lnum)
end

local function calculate_width(items)
  local min_width = 35
  local max_width = math.min(120, math.max(20, vim.o.columns - 6))
  local content_width = min_width
  for _, item in ipairs(items) do
    content_width = math.max(content_width, strwidth(raw_item_line(item)))
  end
  return math.min(math.max(content_width + 3, min_width), max_width)
end

local function preview(item)
  if not item or item.uri or not source_win or not vim.api.nvim_win_is_valid(source_win) then return end
  if not source_buf or not vim.api.nvim_buf_is_valid(source_buf) then return end
  vim.api.nvim_buf_clear_namespace(source_buf, preview_ns, 0, -1)
  pcall(vim.api.nvim_buf_set_extmark, source_buf, preview_ns, item.lnum - 1, 0, {
    end_row = item.lnum,
    hl_group = 'SymbolPickerPreview',
    hl_eol = true,
    priority = 180,
  })
  pcall(vim.api.nvim_win_call, source_win, function()
    vim.api.nvim_win_set_cursor(source_win, { item.lnum, math.max(0, item.col - 1) })
    vim.cmd('normal! zz')
  end)
end

local function footer_text()
  if #filtered_items == 0 then return ' 0/0 ' end
  return string.format(' %d/%d ', current_index(), #filtered_items)
end

local function current_item_for_cursor(items)
  local cursor_lnum = source_pos and source_pos[1] or vim.api.nvim_win_get_cursor(0)[1]
  local best_index = 1
  local best_depth = -1
  for i, item in ipairs(items) do
    local last = item.end_lnum or item.lnum
    if item.lnum <= cursor_lnum and cursor_lnum <= last and (item.depth or 0) >= best_depth then
      best_index = i
      best_depth = item.depth or 0
    end
  end
  return best_index
end

local function resize_results()
  if not results_win or not vim.api.nvim_win_is_valid(results_win) then return end
  local height = math.min(math.max(1, #filtered_items), max_height)
  vim.api.nvim_win_set_config(results_win, {
    relative = 'editor',
    row = row + 2,
    col = col,
    width = width,
    height = height,
    footer = footer_text(),
    footer_pos = 'right',
  })
end

local function render()
  if not results_buf or not vim.api.nvim_buf_is_valid(results_buf) then return end

  local lines = {}
  local meta = {}
  local content_width = width - 2
  selected = math.max(1, math.min(selected, math.max(1, #filtered_items)))
  for i, item in ipairs(filtered_items) do
    local icon = ICONS[item.kind] or '󰌋'
    local line_text = string.format('%4d', item.lnum)
    local marker = i == selected and ' ' or '  '
    local guide = make_tree_guides(item)
    local prefix = marker .. guide .. icon .. '  '
    local available = content_width - strwidth(prefix) - #line_text - 1
    local name = truncate(item.name, math.max(8, available))
    local pad = math.max(0, available - strwidth(name))
    local line = prefix .. name .. string.rep(' ', pad) .. ' ' .. line_text
    table.insert(lines, line)
    table.insert(meta, {
      marker_start = 0,
      marker_end = #marker,
      guide_start = #marker,
      guide_end = #marker + #guide,
      icon_start = #marker + #guide,
      icon_end = #marker + #guide + #icon,
      name_start = #prefix,
      name_end = #prefix + #name,
      lnum_start = #line - #line_text,
      lnum_end = #line,
    })
  end
  if #lines == 0 then
    lines = { '  一致するものがありません' }
  end

  resize_results()
  vim.bo[results_buf].modifiable = true
  vim.api.nvim_buf_set_lines(results_buf, 0, -1, false, lines)
  vim.bo[results_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(results_buf, hl_ns, 0, -1)

  for i, item in ipairs(filtered_items) do
    local line = i - 1
    local ranges = meta[i]
    local kind_hl = 'SymbolPicker' .. (item.kind or 'Symbol')
    vim.api.nvim_buf_set_extmark(results_buf, hl_ns, line, ranges.marker_start, {
      end_col = ranges.marker_end,
      hl_group = i == selected and 'SymbolPickerCurrentIcon' or 'Comment',
      priority = 210,
    })
    if ranges.guide_end > ranges.guide_start then
      vim.api.nvim_buf_set_extmark(results_buf, hl_ns, line, ranges.guide_start, {
        end_col = ranges.guide_end,
        hl_group = 'Comment',
        priority = 210,
      })
    end
    vim.api.nvim_buf_set_extmark(results_buf, hl_ns, line, ranges.icon_start, {
      end_col = ranges.icon_end,
      hl_group = kind_hl,
      priority = 211,
    })
    vim.api.nvim_buf_set_extmark(results_buf, hl_ns, line, ranges.name_start, {
      end_col = ranges.name_end,
      hl_group = kind_hl,
      priority = 205,
    })
    vim.api.nvim_buf_set_extmark(results_buf, hl_ns, line, ranges.lnum_start, {
      end_col = ranges.lnum_end,
      hl_group = 'Comment',
      priority = 205,
    })
  end

  if #filtered_items > 0 then
    selected = math.max(1, math.min(selected, #filtered_items))
    if results_win and vim.api.nvim_win_is_valid(results_win) then
      pcall(vim.api.nvim_win_set_cursor, results_win, { selected, 0 })
    end
    preview(filtered_items[selected])
  end
end

local function apply_filter(query)
  filtered_items = {}
  for _, item in ipairs(all_items) do
    if fuzzy_match(item.name, query) then
      table.insert(filtered_items, item)
    end
  end
  selected = math.min(selected, math.max(1, #filtered_items))
  render()
end

local function move(delta)
  if #filtered_items == 0 then return end
  local next_index = current_index() + delta
  if next_index < 1 then
    next_index = #filtered_items
  elseif next_index > #filtered_items then
    next_index = 1
  end
  selected = next_index
  if results_win and vim.api.nvim_win_is_valid(results_win) then
    pcall(vim.api.nvim_win_set_cursor, results_win, { selected, 0 })
    pcall(vim.fn.win_execute, results_win, 'normal! zz')
  end
  render()
  resize_results()
  preview(filtered_items[selected])
end

local function jump()
  selected = current_index()
  local item = filtered_items[selected]
  if not item then return end
  local target_win = source_win
  local target_buf = source_buf
  source_pos, source_view = nil, nil
  close()
  if item.uri then
    vim.cmd('edit ' .. vim.fn.fnameescape(vim.uri_to_fname(item.uri)))
  elseif target_win and vim.api.nvim_win_is_valid(target_win) then
    vim.api.nvim_set_current_win(target_win)
    if target_buf and vim.api.nvim_buf_is_valid(target_buf) then
      vim.api.nvim_win_set_buf(target_win, target_buf)
    end
  end
  vim.api.nvim_win_set_cursor(0, { item.lnum, math.max(0, item.col - 1) })
  vim.cmd('normal! zz')
end

local function setup_hl()
  vim.api.nvim_set_hl(0, 'SymbolPickerPrompt', { link = 'NormalFloat' })
  vim.api.nvim_set_hl(0, 'SymbolPickerResults', { link = 'NormalFloat' })
  vim.api.nvim_set_hl(0, 'SymbolPickerSelection', { link = 'CursorLine' })
  vim.api.nvim_set_hl(0, 'SymbolPickerCurrentIcon', { link = 'Special' })
  vim.api.nvim_set_hl(0, 'SymbolPickerPreview', { link = 'Visual' })
  vim.api.nvim_set_hl(0, 'SymbolPickerClass', { link = 'Type' })
  vim.api.nvim_set_hl(0, 'SymbolPickerInterface', { link = 'Type' })
  vim.api.nvim_set_hl(0, 'SymbolPickerStruct', { link = 'Type' })
  vim.api.nvim_set_hl(0, 'SymbolPickerFunction', { link = 'Function' })
  vim.api.nvim_set_hl(0, 'SymbolPickerMethod', { link = 'Function' })
  vim.api.nvim_set_hl(0, 'SymbolPickerConstructor', { link = 'Function' })
  vim.api.nvim_set_hl(0, 'SymbolPickerVariable', { link = 'Identifier' })
  vim.api.nvim_set_hl(0, 'SymbolPickerConstant', { link = 'Constant' })
  vim.api.nvim_set_hl(0, 'SymbolPickerProperty', { link = 'Identifier' })
  vim.api.nvim_set_hl(0, 'SymbolPickerField', { link = 'Identifier' })
  vim.api.nvim_set_hl(0, 'SymbolPickerModule', { link = 'Include' })
  vim.api.nvim_set_hl(0, 'SymbolPickerSymbol', { link = 'Identifier' })
end

local function open_picker(items)
  if #items == 0 then
    vim.notify('[symbols] シンボルが見つかりませんでした', vim.log.levels.WARN)
    return
  end

  close()
  source_win = vim.api.nvim_get_current_win()
  source_buf = vim.api.nvim_get_current_buf()
  source_pos = vim.api.nvim_win_get_cursor(source_win)
  source_view = vim.fn.winsaveview()
  all_items = items
  filtered_items = copy_list(items)
  selected = current_item_for_cursor(filtered_items)

  local ui_width = vim.o.columns
  local ui_height = vim.o.lines - vim.o.cmdheight - 2
  width = calculate_width(items)
  max_height = math.min(41, math.max(1, math.floor(ui_height * 0.6)))
  row = math.max(0, math.floor(ui_height * 0.1))
  col = math.max(0, math.floor((ui_width - width) / 2))
  local list_height = math.min(#items, max_height)

  prompt_buf = vim.api.nvim_create_buf(false, true)
  results_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[prompt_buf].buftype = 'nofile'
  vim.bo[prompt_buf].buflisted = false
  vim.bo[prompt_buf].filetype = 'symbol_picker_prompt'
  vim.bo[results_buf].buftype = 'nofile'
  vim.bo[results_buf].buflisted = false
  vim.bo[results_buf].filetype = 'symbol_picker'
  vim.bo[results_buf].modifiable = false

  prompt_win = vim.api.nvim_open_win(prompt_buf, true, {
    relative = 'editor',
    row = row,
    col = col,
    width = width,
    height = 1,
    style = 'minimal',
    border = { '╭', '─', '╮', '│', '', '', '', '│' },
    zindex = 60,
  })
  vim.wo[prompt_win].winhighlight = 'Normal:SymbolPickerPrompt'

  results_win = vim.api.nvim_open_win(results_buf, false, {
    relative = 'editor',
    row = row + 2,
    col = col,
    width = width,
    height = list_height,
    style = 'minimal',
    border = { '', '', '', '│', '╯', '─', '╰', '│' },
    focusable = true,
    footer = footer_text(),
    footer_pos = 'right',
    zindex = 59,
  })
  vim.wo[results_win].cursorline = true
  vim.wo[results_win].number = false
  vim.wo[results_win].relativenumber = false
  vim.wo[results_win].signcolumn = 'no'
  vim.wo[results_win].winhighlight = 'Normal:SymbolPickerResults,CursorLine:SymbolPickerSelection'

  vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { '' })
  vim.api.nvim_buf_set_extmark(prompt_buf, hl_ns, 0, 0, {
    virt_text = { { '✱', 'SymbolPickerCurrentIcon' } },
    virt_text_pos = 'overlay',
    priority = 220,
  })
  render()
  vim.cmd('startinsert')

  vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged' }, {
    group = augrp,
    buffer = prompt_buf,
    callback = function()
      apply_filter(vim.api.nvim_buf_get_lines(prompt_buf, 0, 1, false)[1] or '')
    end,
  })

  local function map_prompt(mode, lhs, rhs)
    vim.keymap.set(mode, lhs, rhs, { buffer = prompt_buf, silent = true, nowait = true })
  end
  for _, lhs in ipairs({ '<Down>', '<C-n>' }) do
    map_prompt({ 'i', 'n' }, lhs, function() move(1) end)
  end
  for _, lhs in ipairs({ '<Up>', '<C-p>' }) do
    map_prompt({ 'i', 'n' }, lhs, function() move(-1) end)
  end
  map_prompt('n', 'j', function() move(1) end)
  map_prompt('n', 'k', function() move(-1) end)
  map_prompt({ 'i', 'n' }, '<CR>', function()
    vim.cmd('stopinsert')
    jump()
  end)
  map_prompt({ 'i', 'n' }, '<Esc>', function()
    vim.cmd('stopinsert')
    close()
  end)
  map_prompt('i', '<C-c>', function()
    vim.cmd('stopinsert')
    close()
  end)

  local function map_results(lhs, rhs)
    vim.keymap.set('n', lhs, rhs, { buffer = results_buf, silent = true, nowait = true })
  end
  for _, lhs in ipairs({ 'j', '<Down>', '<C-n>' }) do
    map_results(lhs, function() move(1) end)
  end
  for _, lhs in ipairs({ 'k', '<Up>', '<C-p>' }) do
    map_results(lhs, function() move(-1) end)
  end
  map_results('<CR>', jump)
  map_results('i', function()
    if prompt_win and vim.api.nvim_win_is_valid(prompt_win) then
      vim.api.nvim_set_current_win(prompt_win)
      vim.cmd('startinsert')
    end
  end)
  map_results('q', close)
  map_results('<Esc>', close)

  vim.api.nvim_create_autocmd('WinLeave', {
    group = augrp,
    callback = function()
      vim.schedule(function()
        local current = vim.api.nvim_get_current_win()
        if current ~= prompt_win and current ~= results_win then
          close()
        end
      end)
    end,
  })
end

local function item_range(item)
  return {
    start_line = item.lnum,
    start_col = item.col,
    end_line = item.end_lnum or item.lnum,
    end_col = item.end_col or item.col,
  }
end

local function contains(parent, child)
  local p = item_range(parent)
  local c = item_range(child)
  if c.start_line < p.start_line or c.end_line > p.end_line then return false end
  if c.start_line == p.start_line and c.start_col < p.start_col then return false end
  if c.end_line == p.end_line and c.end_col > p.end_col then return false end
  return p.start_line ~= c.start_line or p.start_col ~= c.start_col or p.end_line ~= c.end_line or p.end_col ~= c.end_col
end

local function assign_depth(items)
  table.sort(items, function(a, b)
    if a.lnum == b.lnum then return a.col < b.col end
    return a.lnum < b.lnum
  end)
  local stack = {}
  for _, item in ipairs(items) do
    while #stack > 0 and not contains(stack[#stack], item) do
      table.remove(stack)
    end
    item.depth = #stack
    item.parent = stack[#stack]
    item.children = {}
    if item.parent then
      item.parent.children = item.parent.children or {}
      table.insert(item.parent.children, item)
    end
    table.insert(stack, item)
  end
  for _, item in ipairs(items) do
    local chain = {}
    local node = item
    while node and node.parent do
      table.insert(chain, 1, node)
      node = node.parent
    end
    item.tree_state = {}
    for _, child in ipairs(chain) do
      local siblings = child.parent and child.parent.children or items
      table.insert(item.tree_state, siblings[#siblings] == child)
    end
  end
  return items
end

local function first_node(nodes)
  if type(nodes) == 'table' then return nodes[1] end
  return nodes
end

local function node_text(node, bufnr)
  if not node then return nil end
  bufnr = bufnr or 0
  return vim.treesitter.get_node_text(node, bufnr)
end

local function unquote(text)
  if not text then return nil end
  return text:gsub('^[\'"`]', ''):gsub('[\'"`]$', '')
end

local function make_ts_item(name, kind, symbol_node, name_node, bufnr)
  if not name or name == '' or not symbol_node then return nil end
  local start_line, start_col, end_line, end_col = symbol_node:range()
  local name_col = start_col
  if name_node then
    local _, col = name_node:range()
    name_col = col
  end
  return {
    name = name,
    kind = kind or 'Function',
    lnum = start_line + 1,
    col = (name_col or start_col) + 1,
    end_lnum = end_line + 1,
    end_col = end_col + 1,
    depth = 0,
    bufnr = bufnr,
  }
end

local JS_TS_QUERIES = {
  {
    kind = 'Function',
    query = [[
      (function_declaration
        name: (identifier) @name) @symbol
      (generator_function_declaration
        name: (identifier) @name) @symbol
    ]],
  },
  {
    kind = 'Class',
    query = [[
      (class_declaration
        name: (identifier) @name) @symbol
    ]],
  },
  {
    kind = 'Method',
    query = [[
      (method_definition
        name: [(property_identifier) (private_property_identifier)] @name) @symbol
    ]],
  },
  {
    kind = 'Function',
    query = [[
      (lexical_declaration
        (variable_declarator
          name: (identifier) @name
          value: [
            (arrow_function)
            (function_expression)
            (generator_function)
          ])) @symbol
    ]],
  },
  {
    kind = 'Method',
    query = [[
      (field_definition
        property: (property_identifier) @name
        value: [
          (arrow_function)
          (function_expression)
          (generator_function)
        ]) @symbol
    ]],
  },
  {
    kind = 'Function',
    query = [[
      (expression_statement
        (assignment_expression
          left: (member_expression
            object: (member_expression
              object: (identifier) @module
              property: (property_identifier) @exports)
            property: (property_identifier) @name)
          right: [
            (arrow_function)
            (function_expression)
            (generator_function)
          ])) @symbol
      (expression_statement
        (assignment_expression
          left: (member_expression
            object: (identifier) @exports
            property: (property_identifier) @name)
          right: [
            (arrow_function)
            (function_expression)
            (generator_function)
          ])) @symbol
    ]],
    filter = function(captures)
      if captures.module then
        return node_text(captures.module) == 'module' and node_text(captures.exports) == 'exports'
      end
      return node_text(captures.exports) == 'exports'
    end,
  },
  {
    kind = 'Method',
    query = [[
      (call_expression
        function: (member_expression
          object: (identifier) @object
          property: (property_identifier) @method)
        arguments: (arguments
          (string) @path)) @symbol
    ]],
    name = function(captures)
      if node_text(captures.object) ~= 'app' then return nil end
      local method = node_text(captures.method)
      local allowed = { get = true, post = true, put = true, patch = true, delete = true, options = true, head = true }
      if not allowed[method] then return nil end
      return method:upper() .. ' ' .. (unquote(node_text(captures.path)) or '')
    end,
  },
  {
    kind = 'Method',
    query = [[
      (call_expression
        function: (member_expression
          object: (identifier) @object
          property: (property_identifier) @method)
        arguments: (arguments
          [
            (arrow_function)
            (function_expression)
            (call_expression)
          ])) @symbol
    ]],
    name = function(captures)
      if node_text(captures.object) ~= 'app' or node_text(captures.method) ~= 'use' then return nil end
      return 'USE middleware'
    end,
  },
}

local function lang_for_filetype(ft)
  if ft == 'javascriptreact' then return 'javascript' end
  if ft == 'typescriptreact' then return 'tsx' end
  return ft
end

local function treesitter_symbols(bufnr)
  local ft = vim.bo[bufnr].filetype
  if ft ~= 'javascript' and ft ~= 'javascriptreact' and ft ~= 'typescript' and ft ~= 'typescriptreact' then
    return nil
  end
  local lang = lang_for_filetype(ft)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
  if not ok or not parser then return nil end
  local tree = parser:parse()[1]
  if not tree then return nil end
  local root = tree:root()
  local items = {}
  local seen = {}

  for _, spec in ipairs(JS_TS_QUERIES) do
    local query_ok, query = pcall(vim.treesitter.query.parse, lang, spec.query)
    if query_ok and query then
      for _, match in query:iter_matches(root, bufnr, 0, -1) do
        local captures = {}
        for id, nodes in pairs(match) do
          captures[query.captures[id]] = first_node(nodes)
        end
        local pass = not spec.filter or spec.filter(captures)
        if pass then
          local name = spec.name and spec.name(captures) or node_text(captures.name, bufnr)
          local item = make_ts_item(name, spec.kind, captures.symbol, captures.name or captures.method, bufnr)
          if item then
            local key = string.format('%s:%d:%d', item.name, item.lnum, item.col)
            if not seen[key] then
              seen[key] = true
              table.insert(items, item)
            end
          end
        end
      end
    end
  end

  if #items == 0 then return nil end
  return assign_depth(items)
end

local function with_tree_state(parent_state, is_last)
  local tree_state = {}
  for _, value in ipairs(parent_state or {}) do
    table.insert(tree_state, value)
  end
  table.insert(tree_state, is_last)
  return tree_state
end

local function flatten_lsp(symbols, depth, out, parent_tree_state)
  out = out or {}
  symbols = symbols or {}
  depth = depth or 0
  parent_tree_state = parent_tree_state or {}
  for i, symbol in ipairs(symbols) do
    local range = symbol.range or (symbol.location and symbol.location.range)
    local tree_state = depth == 0 and {} or with_tree_state(parent_tree_state, i == #symbols)
    if range and symbol.name then
      table.insert(out, {
        name = symbol.name,
        kind = kind_name(symbol.kind),
        lnum = range.start.line + 1,
        col = range.start.character + 1,
        end_lnum = range['end'] and (range['end'].line + 1) or (range.start.line + 1),
        end_col = range['end'] and (range['end'].character + 1) or (range.start.character + 1),
        depth = depth,
        tree_state = tree_state,
        uri = symbol.location and symbol.location.uri or nil,
      })
    end
    if symbol.children then
      flatten_lsp(symbol.children, depth + 1, out, tree_state)
    end
  end
  return out
end

local function lsp_symbols()
  local clients = vim.lsp.get_clients({ bufnr = 0 })
  if #clients == 0 then
    vim.notify('[symbols] LSP クライアントが接続されていません', vim.log.levels.WARN)
    return
  end
  local params = { textDocument = vim.lsp.util.make_text_document_params(0) }
  vim.lsp.buf_request_all(0, 'textDocument/documentSymbol', params, function(results)
    local raw = {}
    for _, result in pairs(results or {}) do
      if result.result then
        vim.list_extend(raw, result.result)
      end
    end
    vim.schedule(function()
      open_picker(flatten_lsp(raw, 0, {}))
    end)
  end)
end

function M.open()
  local bufnr = vim.api.nvim_get_current_buf()
  local ts_items = treesitter_symbols(bufnr)
  if ts_items and #ts_items > 0 then
    open_picker(ts_items)
    return
  end
  lsp_symbols()
end

setup_hl()
vim.api.nvim_create_autocmd('ColorScheme', { callback = setup_hl })
vim.keymap.set('n', '<leader>ss', M.open, { desc = 'Symbols: ファイル内シンボル' })

return M
