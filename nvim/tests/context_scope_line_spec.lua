local T = dofile(TESTS_DIR .. '/helpers.lua')
require('config.context')
require('config.scope_line')

local function new_win_with_lines(lines, height)
  -- context.lua/scope_line.luaはbuftype ~= ''のバッファ(scratch=trueで作った'nofile'含む)
  -- を意図的に無視するため、通常の(buftype='')バッファを使う必要がある
  local buf = vim.api.nvim_create_buf(false, false)
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = 'lua'
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor', width = 40, height = height or 5, row = 0, col = 0,
  })
  return win, buf
end

T.describe('context.lua (sticky scrolled-out scope header)', function()
  T.it('shows the scrolled-out enclosing line(s) as a floating overlay, hides them when back at the top', function()
    local lines = { 'function outer()' }
    for i = 1, 15 do table.insert(lines, ('  print(%d)'):format(i)) end
    table.insert(lines, 'end')
    local win, buf = new_win_with_lines(lines, 5)

    -- 下の方まで移動してスクロールさせる(function outer()が画面外に出る)
    vim.api.nvim_win_set_cursor(win, { 12, 0 })
    vim.cmd('normal! zt') -- 現在行を画面最上部にしてスクロールさせる
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
    vim.wait(50)

    local ctx_win
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if w ~= win and vim.api.nvim_win_get_config(w).relative == 'win' then ctx_win = w end
    end
    T.ok(ctx_win ~= nil, 'a context overlay window should appear once the header scrolled out of view')
    local ctx_text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(ctx_win), 0, -1, false), '\n')
    T.contains(ctx_text, 'function outer()')
    T.eq(vim.api.nvim_win_get_config(ctx_win).width, vim.api.nvim_win_get_width(win) - 1)

    -- 先頭まで戻ればcontextは不要になり消える
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    vim.cmd('normal! zt')
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
    vim.wait(50)
    T.ok(not vim.api.nvim_win_is_valid(ctx_win), 'context overlay should close once back at the top')

    vim.api.nvim_win_close(win, true)
  end)
end)

T.describe('scope_line.lua (current-scope indent guide)', function()
  T.it('draws a guide bar only on lines inside the current block, not on the opening/closing lines', function()
    local win, buf = new_win_with_lines({
      'function outer()',
      '    line_a',
      '    line_b',
      'end',
    })
    vim.api.nvim_win_set_cursor(win, { 3, 4 }) -- line_b
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
    vim.wait(30)

    local ns = vim.api.nvim_create_namespace('scope_line')
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
    local marked_rows = {}
    for _, m in ipairs(marks) do marked_rows[m[2]] = true end -- m[2] = row (0-indexed)

    T.ok(marked_rows[1] == true, 'line_a (row 1) should have a guide')
    T.ok(marked_rows[2] == true, 'line_b (row 2) should have a guide')
    T.ok(marked_rows[0] == nil, 'the opening line (function outer()) should not have a guide')
    T.ok(marked_rows[3] == nil, 'the closing line (end) should not have a guide')

    vim.api.nvim_win_close(win, true)
  end)

  T.it('draws nothing at top-level indent (indent 0 == no enclosing block)', function()
    local win, buf = new_win_with_lines({ 'local x = 1', 'local y = 2' })
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
    vim.wait(30)
    local ns = vim.api.nvim_create_namespace('scope_line')
    T.eq(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), 0)

    vim.api.nvim_win_close(win, true)
  end)
end)

T.summary()
