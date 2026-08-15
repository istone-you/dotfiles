-- 自前のdiffレンダラをgitパネルへ繋いだ状態の結合テスト。
-- 単体テスト(panel_diff_render_spec)が「組み立てたデータ」を見るのに対し、
-- ここは実際にパネルを開いた右ペインのバッファとextmarkを見る。

local T = dofile(TESTS_DIR .. '/helpers.lua')
local GP = dofile(TESTS_DIR .. '/git_panel_helpers.lua')

local function seeded_repo(name, before, after)
  local dir = T.tmp_git_repo(function(d)
    T.write_file(d .. '/' .. name, before)
    GP.git(d, { 'add', '.' })
    GP.git(d, { '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', 'seed' })
  end)
  T.write_file(dir .. '/' .. name, after)
  return dir
end

local function show_diff(dir, name)
  GP.open(dir, false)
  local left, right = GP.left_win(), GP.right_win()
  GP.goto_row(left, GP.find_row(left, name))
  return right
end

T.describe('git_panel diff pane (self-rendered)', function()
  T.it('is a normal (non-terminal) buffer with cursorline and highlights', function()
    local dir = seeded_repo('a.txt', { 'one', 'two' }, { 'one', 'CHANGED' })
    local right = show_diff(dir, 'a.txt')
    T.wait_until(function()
      return table.concat(GP.lines(right), '\n'):find('CHANGED', 1, true) ~= nil
    end)

    local rbuf = vim.api.nvim_win_get_buf(right)
    T.ok(vim.bo[rbuf].buftype ~= 'terminal', 'diff pane must be a normal buffer (so selection highlight works)')
    T.eq(vim.wo[right].cursorline, true, 'cursorline (selection highlight) should be on for diffs')
    local marks = vim.api.nvim_buf_get_extmarks(rbuf, -1, 0, -1, {})
    T.ok(#marks > 0, 'the rendered colors should land as extmarks')

    GP.close()
    T.rmrf(dir)
  end)

  T.it('shows line numbers and keeps the +/- markers', function()
    local dir = seeded_repo('a.txt', { 'one', 'two' }, { 'one', 'CHANGED' })
    local right = show_diff(dir, 'a.txt')
    T.wait_until(function()
      return table.concat(GP.lines(right), '\n'):find('CHANGED', 1, true) ~= nil
    end)

    local body = table.concat(GP.lines(right), '\n')
    T.contains(body, '⋮', 'the two line-number columns should be there')
    T.contains(body, '-two')
    T.contains(body, '+CHANGED')

    GP.close()
    T.rmrf(dir)
  end)

  T.it('colors the code with treesitter, the same as the editor does', function()
    local dir = seeded_repo('a.lua', { 'local a = 1' }, { 'local a = 2' })
    local right = show_diff(dir, 'a.lua')
    T.wait_until(function()
      return table.concat(GP.lines(right), '\n'):find('local a = 2', 1, true) ~= nil
    end)

    local rbuf = vim.api.nvim_win_get_buf(right)
    local found = false
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(rbuf, -1, 0, -1, { details = true })) do
      if m[4].hl_group == '@keyword.lua' then found = true end
    end
    T.ok(found, 'lua keywords in the diff should use the editor treesitter groups')

    GP.close()
    T.rmrf(dir)
  end)

  T.it('v re-lays out the same diff into two columns', function()
    local git = require('config.git_panel.git')
    local dir = seeded_repo('a.txt', { 'one', 'two' }, { 'one', 'CHANGED' })
    local right = show_diff(dir, 'a.txt')
    T.wait_until(function()
      return table.concat(GP.lines(right), '\n'):find('CHANGED', 1, true) ~= nil
    end)

    local before = git.side_by_side
    GP.press('v')
    T.wait_until(function()
      for _, l in ipairs(GP.lines(right)) do
        if l:find('-two', 1, true) and l:find('+CHANGED', 1, true) then return true end
      end
      return false
    end)

    GP.press('v')
    T.eq(git.side_by_side, before)
    GP.close()
    T.rmrf(dir)
  end)
end)

T.summary()
