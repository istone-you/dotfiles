local ns = vim.api.nvim_create_namespace('scope_line')

local TS_NODE_TYPES = {
  class = true,
  class_declaration = true,
  class_definition = true,
  method = true,
  method_definition = true,
  function_definition = true,
  function_declaration = true,
  function_statement = true,
  ['function'] = true,
  function_body = true,
  if_statement = true,
  for_statement = true,
  for_in_statement = true,
  for_numeric = true,
  while_statement = true,
  repeat_statement = true,
  do_statement = true,
  do_block = true,
  block = true,
  table_constructor = true,
  object = true,
  object_pattern = true,
  array = true,
  dictionary = true,
}

local function setup_hl()
  vim.api.nvim_set_hl(0, 'ScopeLine', { fg = '#3d59a1' })
end

local function get_indent(line)
  if line:match('^%s*$') then return nil end
  return vim.fn.strdisplaywidth(line:match('^(%s*)'))
end

local function effective_indent(lines, lnum)
  for i = lnum, 0, -1 do
    local ind = get_indent(lines[i + 1] or '')
    if ind then return ind end
  end
  return 0
end

local function node_is_scope(node)
  if not node then return false end
  local typ = node:type()
  if TS_NODE_TYPES[typ] then return true end
  return typ:find('class') ~= nil
    or typ:find('function') ~= nil
    or typ:find('method') ~= nil
    or typ:find('statement') ~= nil
end

local function ts_range(buf, row, col)
  if not vim.treesitter or not vim.treesitter.get_node then return nil end
  local ok, node = pcall(vim.treesitter.get_node, {
    bufnr = buf,
    pos = { row, col },
    ignore_injections = false,
  })
  if not ok or not node then return nil end

  while node do
    local sr, _, er, _ = node:range()
    if sr < er and node_is_scope(node) then
      return { start_lnum = sr, end_lnum = er, error = node.has_error and node:has_error() or false }
    end
    local parent = node:parent()
    if parent == node then break end
    node = parent
  end
  return nil
end

local function indent_range(lines, lnum)
  local cur_indent = effective_indent(lines, lnum)
  if cur_indent == 0 then return nil end

  local start_lnum = nil
  for i = lnum - 1, 0, -1 do
    local ind = get_indent(lines[i + 1] or '')
    if ind and ind < cur_indent then
      start_lnum = i
      break
    end
  end
  if not start_lnum then return nil end

  local start_indent = get_indent(lines[start_lnum + 1]) or 0
  local end_lnum = lnum
  for i = lnum + 1, #lines - 1 do
    local ind = get_indent(lines[i + 1] or '')
    if ind then
      if ind <= start_indent then
        end_lnum = i
        break
      end
      end_lnum = i
    end
  end
  if end_lnum <= start_lnum then return nil end
  return { start_lnum = start_lnum, end_lnum = end_lnum }
end

local function update(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if vim.bo[buf].buftype ~= '' then return end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local lnum = cursor[1] - 1
  local col = cursor[2]

  local total = vim.api.nvim_buf_line_count(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, total, false)

  local range = ts_range(buf, lnum, col) or indent_range(lines, lnum)
  if not range then return end

  local start_indent = get_indent(lines[range.start_lnum + 1] or '') or 0
  local end_indent = get_indent(lines[range.end_lnum + 1] or '') or start_indent
  local guide_col = math.max(math.min(start_indent, end_indent), 0)

  for i = range.start_lnum + 1, range.end_lnum - 1 do
    local line = lines[i + 1] or ''
    local ind = get_indent(line)
    if (not ind) or guide_col < ind then
      vim.api.nvim_buf_set_extmark(buf, ns, i, 0, {
        virt_text = { { '│', 'ScopeLine' } },
        virt_text_win_col = guide_col,
      })
    end
  end
end

setup_hl()
vim.api.nvim_create_autocmd('ColorScheme', { callback = setup_hl })
vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'BufEnter' }, {
  callback = function()
    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].buftype ~= '' then return end
    update(buf)
  end,
})

return {
  _ts_range = ts_range,
  _indent_range = indent_range,
}
