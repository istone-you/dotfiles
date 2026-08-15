local T = dofile(TESTS_DIR .. '/helpers.lua')
local GP = dofile(TESTS_DIR .. '/git_panel_helpers.lua')

local function bounding_box()
  local min_col, min_row, max_col, max_row
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(w)
    if cfg.relative ~= '' then
      min_col = min_col and math.min(min_col, cfg.col) or cfg.col
      min_row = min_row and math.min(min_row, cfg.row) or cfg.row
      max_col = max_col and math.max(max_col, cfg.col + cfg.width) or (cfg.col + cfg.width)
      max_row = max_row and math.max(max_row, cfg.row + cfg.height) or (cfg.row + cfg.height)
    end
  end
  return min_col, min_row, max_col, max_row
end

T.describe('git_panel init', function()
  T.it('keeps the panel and border backgrounds transparent across ColorScheme changes', function()
    require('config.git_panel')
    vim.api.nvim_set_hl(0, 'GitPanelBg', { bg = '#123456' })
    vim.api.nvim_set_hl(0, 'GitPanelBorder', { bg = '#123456', fg = '#ffffff' })

    vim.api.nvim_exec_autocmds('ColorScheme', {})

    T.eq(vim.api.nvim_get_hl(0, { name = 'GitPanelBg' }).bg, nil,
      'GitPanelBg should have no background')
    T.eq(vim.api.nvim_get_hl(0, { name = 'GitPanelBorder' }).bg, nil,
      'GitPanelBorder should have no background')
  end)

  T.it('layout: normal open is a 90% centered box', function()
    -- fullscreenは close()がqall()を呼ぶ設計(下のテストで確認)なので、同じ
    -- プロセス内でfullscreenを開いてからclose()するとテストプロセス自体が
    -- 終了してしまう。90%表示はfullscreenに触れないここだけで確認する
    vim.o.columns, vim.o.lines = 160, 40
    local dir = T.tmp_git_repo()

    GP.open(dir, false)
    local col, row = bounding_box()
    T.eq(col, 8) -- (160 - floor(160*0.9)) / 2
    T.eq(row, 2) -- (40 - floor(40*0.9)) / 2

    GP.close()
    T.rmrf(dir)
  end)

  T.it('layout: fullscreen fills the whole screen (col=0,row=0)', function()
    -- close()のqall連鎖に巻き込まれないよう、fullscreenは常に別プロセスで検証する
    local dir = T.tmp_git_repo()
    -- 子スクリプト側にも%dなどのformat指定子があるため、外側はstring.formatではなく
    -- 単純な文字列連結でdirを埋め込む(二重にformatすると衝突してエラーになる)
    local script = table.concat({
      'vim.o.columns, vim.o.lines = 160, 40',
      'vim.fn.chdir(' .. vim.inspect(dir) .. ')',
      "require('config.git_panel').open(true)",
      'vim.wait(300)',
      'local min_col, min_row',
      'for _, w in ipairs(vim.api.nvim_list_wins()) do',
      '  local cfg = vim.api.nvim_win_get_config(w)',
      "  if cfg.relative ~= '' then",
      '    min_col = min_col and math.min(min_col, cfg.col) or cfg.col',
      '    min_row = min_row and math.min(min_row, cfg.row) or cfg.row',
      '  end',
      'end',
      [[io.stdout:write(string.format('BBOX %d %d\n', min_col, min_row))]],
      -- close()を呼ばずに直接終了(qallを経由しない、後始末は不要な使い捨てプロセス)
      'os.exit(0)',
    }, '\n')
    local tmp = vim.fn.tempname() .. '.lua'
    vim.fn.writefile(vim.split(script, '\n', { plain = true }), tmp)
    local res = vim.system({
      'nvim', '-u', 'NONE', '--cmd', 'set rtp+=' .. vim.fn.fnamemodify(TESTS_DIR, ':h'), '-l', tmp,
    }, { text = true }):wait()
    local min_col, min_row = (res.stdout or ''):match('BBOX (%d+) (%d+)')
    T.ok(min_col ~= nil, 'child process should report bbox. stdout=' .. (res.stdout or '') .. ' stderr=' .. (res.stderr or ''))
    T.eq(tonumber(min_col), 0)
    T.eq(tonumber(min_row), 0)

    vim.fn.delete(tmp)
    T.rmrf(dir)
  end)

  T.it('the right pane has no title (it is not diff-only)', function()
    local dir = T.tmp_git_repo()
    GP.open(dir, false)
    local right = GP.right_win()
    T.ok(right ~= nil, 'right pane should be found by its window var')
    local title = vim.api.nvim_win_get_config(right).title
    local empty = title == nil or title == ''
      or (type(title) == 'table' and #title == 0)
    T.ok(empty, 'right pane must not show a "Diff" (or any) title')
    GP.close()
    T.rmrf(dir)
  end)

  T.it('+ expands the diff panel (like @ expands the command log), q/+ collapse it, and the two are mutually exclusive', function()
    local dir = T.tmp_git_repo(function(d)
      T.write_file(d .. '/a.txt', { 'a' })
      GP.git(d, { 'add', '.' })
      GP.git(d, { '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', 'seed' })
    end)
    T.write_file(dir .. '/a.txt', { 'a', 'changed' })

    GP.open(dir, false)
    local left, right = GP.left_win(), GP.right_win()
    local normal_width = vim.api.nvim_win_get_config(right).width

    GP.press('+')
    vim.wait(80)
    local tree = GP.review_tree_win()
    T.ok(vim.api.nvim_win_get_config(right).width > normal_width, 'diff panel should widen')
    T.eq(tree, nil, 'expanded diff should hide the file tree sidebar by default')
    T.eq(vim.api.nvim_get_current_win(), right, 'focus should move into the expanded diff stream')
    T.ok(vim.api.nvim_win_is_valid(left), 'the left panel window must still exist (just resized away, not closed)')

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('t', true, false, true), 'x', false)
    vim.wait(80)
    tree = GP.review_tree_win()
    T.ok(tree ~= nil, 't should show the expanded diff file tree')
    T.eq(vim.api.nvim_get_current_win(), tree, 'showing the tree should focus it')
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('t', true, false, true), 'x', false)
    vim.wait(80)
    T.eq(GP.review_tree_win(), nil, 't should hide the expanded diff file tree again')
    T.eq(vim.api.nvim_get_current_win(), right, 'hiding the tree should return focus to the diff stream')

    -- @(コマンドログ拡大)と同じ領域を専有するため、片方を有効にすると
    -- もう片方は自動的に元へ戻る(排他)
    vim.api.nvim_set_current_win(left)
    GP.press('@')
    vim.wait(80)
    T.eq(vim.api.nvim_win_get_config(right).width, normal_width, '@ should collapse the expanded diff panel')
    T.eq(GP.review_tree_win(), nil, '@ should close the expanded diff file tree')
    GP.press('@') -- コマンドログの拡大を戻す
    vim.wait(50)

    -- 拡大中にq/Escを押すとパネル自体は閉じず折り畳まれるだけ
    GP.press('+')
    vim.wait(80)
    vim.api.nvim_set_current_win(right)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('q', true, false, true), 'x', false)
    vim.wait(80)
    T.eq(vim.api.nvim_win_get_config(right).width, normal_width, 'q while expanded should collapse, not close')
    T.ok(vim.api.nvim_win_is_valid(left) and vim.api.nvim_win_is_valid(right), 'panel should still be open')

    GP.close()
    T.rmrf(dir)
  end)

  T.it('+ shows one combined diff stream and j/k in the file tree scrolls the right pane between file sections', function()
    local dir = T.tmp_git_repo(function(d)
      T.write_file(d .. '/src/a.txt', { 'a' })
      T.write_file(d .. '/src/nested/b.txt', { 'b' })
      T.write_file(d .. '/src/deleted.txt', { 'delete-me' })
      GP.git(d, { 'add', '.' })
      GP.git(d, { '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', 'seed' })
    end)
    T.write_file(dir .. '/src/a.txt', { 'a', 'changed-a' })
    T.write_file(dir .. '/src/nested/b.txt', { 'b', 'changed-b' })
    vim.fn.delete(dir .. '/src/deleted.txt')
    T.write_file(dir .. '/added.txt', { 'new-file' })

    GP.open(dir, false)
    GP.press('+')
    T.wait_until(function()
      local right_win = GP.right_win()
      return GP.review_tree_win() == nil
        and table.concat(GP.lines(right_win), '\n'):find('changed%-a') ~= nil
        and table.concat(GP.lines(right_win), '\n'):find('changed%-b') ~= nil
    end)

    local right = GP.right_win()
    local all = table.concat(GP.lines(right), '\n')
    T.contains(all, 'changed-a', 'expanded view should contain the first file diff')
    T.contains(all, 'changed-b', 'expanded view should contain the second file diff')

    vim.api.nvim_set_current_win(right)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('t', true, false, true), 'x', false)
    T.wait_until(function()
      local tree = GP.review_tree_win()
      return tree ~= nil
        and table.concat(GP.lines(tree), '\n'):find('a.txt', 1, true) ~= nil
        and table.concat(GP.lines(tree), '\n'):find('b.txt', 1, true) ~= nil
        and table.concat(GP.lines(tree), '\n'):find('D deleted.txt', 1, true) ~= nil
        and table.concat(GP.lines(tree), '\n'):find('A added.txt', 1, true) ~= nil
    end)
    local tree = GP.review_tree_win()
    T.contains(table.concat(GP.lines(tree), '\n'), '+1 -0', 'file tree should show colored-style +/- stats')

    local top_before = vim.fn.line('w0', right)
    local first_visible = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(right), top_before - 1, top_before + 12, false), '\n')
    T.contains(first_visible, 'b.txt', 'initial right stream should follow the first file in the left tree display order')
    vim.api.nvim_set_current_win(tree)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('j', true, false, true), 'x', false)
    vim.wait(120)
    local top = vim.fn.line('w0', right)
    local visible = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(right), top - 1, top + 12, false), '\n')
    T.contains(visible, 'a.txt', 'j in the file tree should scroll the right stream to the next visible file section')

    GP.close()
    T.rmrf(dir)
  end)

  T.it('+ re-renders the diff at the new panel width, not just resizing the window around stale text', function()
    local git = require('config.git_panel.git')
    local dir = T.tmp_git_repo(function(d)
      T.write_file(d .. '/a.txt', { 'a' })
      GP.git(d, { 'add', '.' })
      GP.git(d, { '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', 'seed' })
    end)
    T.write_file(dir .. '/a.txt', { 'a', 'changed' })

    local widths_used = {}
    local orig_render_diff = git.render_diff
    git.render_diff = function(text, width)
      table.insert(widths_used, width)
      return orig_render_diff(text, width)
    end

    GP.open(dir, false)
    T.wait_until(function() return #widths_used >= 1 end)
    local normal_width = widths_used[#widths_used]

    GP.press('+')
    T.wait_until(function() return #widths_used >= 2 end)
    T.ok(widths_used[#widths_used] > normal_width,
      'expanding should re-render at the wider panel width, not leave it at the old width')

    GP.press('+')
    T.wait_until(function() return #widths_used >= 3 end)
    T.eq(widths_used[#widths_used], normal_width, 'collapsing should re-render back at the normal width')

    git.render_diff = orig_render_diff
    GP.close()
    T.rmrf(dir)
  end)

  T.it('v (side-by-side toggle) still works while the diff panel is expanded via +', function()
    local git = require('config.git_panel.git')
    local dir = T.tmp_git_repo(function(d)
      T.write_file(d .. '/a.txt', { 'a' })
      GP.git(d, { 'add', '.' })
      GP.git(d, { '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', 'seed' })
    end)
    T.write_file(dir .. '/a.txt', { 'a', 'changed' })

    GP.open(dir, false)
    local before = git.side_by_side

    GP.press('+') -- expand + focus moves into the diff stream; file tree is hidden by default
    vim.wait(80)
    T.eq(GP.review_tree_win(), nil, 'expanded diff should hide the file tree by default')
    T.eq(vim.api.nvim_get_current_win(), GP.right_win())
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('v', true, false, true), 'x', false)
    vim.wait(300)
    T.eq(git.side_by_side, not before, 'v should toggle side-by-side while focused on the expanded diff stream')

    GP.close()
    T.rmrf(dir)
  end)

  T.it('regression: the cursor stays hidden across tab switches and diff-panel expand/collapse', function()
    -- 実際に踏んだバグ: activate_panel()のwin.left_buf差し込みと、recreate_right_buf()の
    -- win.right_buf差し込みが、どちらもnvim_win_set_bufをhidden_cursorのmark_bufferより
    -- 先に呼んでいた。+でdiffパネルに実際にフォーカスが移るようになったことで、
    -- そのタイミングのズレがカーソル復活として初めて表面化した
    local dir = T.tmp_git_repo(function(d)
      T.write_file(d .. '/a.txt', { 'a' })
      GP.git(d, { 'add', '.' })
      GP.git(d, { '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', 'seed' })
    end)
    T.write_file(dir .. '/a.txt', { 'a', 'changed' })

    GP.open(dir, false)
    T.contains(vim.o.guicursor, 'HiddenCursor', 'hidden right after open')

    GP.press('2') -- switch tabs (activate_panel re-creates+swaps win.left_buf)
    vim.wait(100)
    T.contains(vim.o.guicursor, 'HiddenCursor', 'hidden after switching to another panel')
    GP.press('1')
    vim.wait(100)
    T.contains(vim.o.guicursor, 'HiddenCursor', 'hidden after switching back')

    GP.press('+') -- expand diff (recreate_right_buf while right_win is the focused window)
    vim.wait(100)
    T.contains(vim.o.guicursor, 'HiddenCursor', 'hidden while the diff panel is expanded and focused')
    GP.press('+')
    vim.wait(100)
    T.contains(vim.o.guicursor, 'HiddenCursor', 'hidden after collapsing the diff panel again')

    GP.close()
    T.rmrf(dir)
  end)

  T.it('1-6 and arrow keys switch panels, updating the tabbar highlight/title', function()
    local dir = T.tmp_git_repo()
    GP.open(dir, false)
    for _, case in ipairs({ { '2', 'Commits' }, { '3', 'Branches' }, { '4', 'Stash' }, { '5', 'Worktree' }, { '6', 'PR' }, { '1', 'Files' } }) do
      GP.press(case[1])
      vim.wait(150)
      T.ok(GP.win_by_title(case[2]) ~= nil, 'panel ' .. case[2] .. ' should be active after pressing ' .. case[1])
    end
    GP.press('<Left>')
    vim.wait(100)
    T.ok(GP.win_by_title('PR') ~= nil, '<Left> from Files should wrap to PR')
    GP.press('<Right>')
    vim.wait(100)
    T.ok(GP.win_by_title('Files') ~= nil, '<Right> from PR should wrap to Files')

    GP.close()
    T.rmrf(dir)
  end)

  T.it('fullscreen: q key and native :q both quit Neovim entirely; normal mode only closes the panel', function()
    -- 別プロセスで実行し、プロセスが本当に終了するかどうかで判定する
    local script = [[
      vim.fn.chdir(%q)
      require('config.git_panel').open(%s)
      vim.wait(300)
      %s
      vim.wait(150)
      io.stderr:write('STILL_ALIVE\n')
      vim.cmd('qa!')
    ]]
    local dir = T.tmp_git_repo()
    local cases = {
      { fullscreen = 'true', action = "vim.cmd('normal q')", expect_alive = false, label = 'fullscreen q-key' },
      { fullscreen = 'true', action = "vim.cmd('q')", expect_alive = false, label = 'fullscreen native :q' },
      { fullscreen = 'false', action = "vim.cmd('normal q')", expect_alive = true, label = 'normal q-key' },
    }
    for _, c in ipairs(cases) do
      local tmp = vim.fn.tempname() .. '.lua'
      vim.fn.writefile(vim.split(string.format(script, dir, c.fullscreen, c.action), '\n'), tmp)
      local res = vim.system({
        'nvim', '-u', 'NONE', '--cmd', 'set rtp+=' .. vim.fn.fnamemodify(TESTS_DIR, ':h'),
        '-l', tmp,
      }, { text = true }):wait()
      local alive = (res.stderr or ''):find('STILL_ALIVE') ~= nil
      T.eq(alive, c.expect_alive, c.label .. ' aliveness')
      vim.fn.delete(tmp)
    end
    T.rmrf(dir)
  end)

  T.it('right pane render is skipped when content is unchanged (no flicker/scroll-reset), updates on real navigation', function()
    local dir = T.tmp_git_repo(function(d)
      T.write_file(d .. '/a.txt', { 'a' })
      T.write_file(d .. '/b.txt', { 'b' })
      GP.git(d, { 'add', '.' })
      GP.git(d, { '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', 'seed' })
    end)
    T.write_file(dir .. '/a.txt', { 'a', 'changed' })
    T.write_file(dir .. '/b.txt', { 'b', 'changed' })

    GP.open(dir, false)
    local left = GP.left_win()
    local row_a = GP.find_row(left, 'a.txt')
    GP.goto_row(left, row_a)
    vim.wait(200)
    local right_buf_before = vim.api.nvim_win_get_buf(GP.right_win())
    local files = require('config.git_panel.files')
    files.refresh(true)
    files.refresh(true)
    vim.wait(200)
    T.eq(vim.api.nvim_win_get_buf(GP.right_win()), right_buf_before,
      'unchanged refresh should not recreate the right buffer')

    -- 実際に別ファイルへ移動すれば内容が切り替わることも確認
    local row_b = GP.find_row(left, 'b.txt')
    GP.goto_row(left, row_b)
    vim.wait(200)
    T.contains(table.concat(GP.lines(GP.right_win()), '\n'), 'changed')

    GP.close()
    T.rmrf(dir)
  end)

  T.it('auto-refresh (2s timer) picks up an out-of-band git change while the left pane is focused, keeping the cursor', function()
    local dir = T.tmp_git_repo()
    GP.git(dir, { 'branch', 'existing' })

    GP.open(dir, false)
    GP.press('3') -- Branchesパネル(cursor_memの挙動が分かりやすい)
    vim.wait(300)
    local left = GP.left_win()
    vim.api.nvim_set_current_win(left)
    GP.goto_row(left, GP.find_row(left, 'existing'))

    -- タイマーの外(別プロセス相当)でブランチを増やす
    GP.git(dir, { 'branch', 'added-out-of-band' })
    T.wait_until(function()
      return table.concat(GP.lines(GP.left_win()), '\n'):find('added%-out%-of%-band') ~= nil
    end, 3500)

    local cur = GP.left_win()
    local cursor_row = vim.api.nvim_win_get_cursor(cur)[1]
    T.contains(GP.lines(cur)[cursor_row], 'existing',
      'cursor should stay on the previously-selected branch across the auto refresh')

    GP.close()
    T.rmrf(dir)
  end)

  T.it('auto-refresh does not fire while focus is away from the left pane (e.g. the diff/right pane)', function()
    local dir = T.tmp_git_repo()
    GP.git(dir, { 'branch', 'existing' })

    GP.open(dir, false)
    GP.press('3')
    vim.wait(300)
    vim.api.nvim_set_current_win(GP.right_win()) -- 左パネルからフォーカスを外す

    GP.git(dir, { 'branch', 'added-while-unfocused' })
    vim.wait(3200) -- 2秒タイマーを跨いでも反映されないはず

    T.ok(not table.concat(GP.lines(GP.left_win()), '\n'):find('added%-while%-unfocused'),
      'auto-refresh should be skipped while the left pane is not focused')

    GP.close()
    T.rmrf(dir)
  end)

  T.it('v toggles side-by-side', function()
    local git = require('config.git_panel.git')
    local dir = T.tmp_git_repo()
    GP.open(dir, false)
    local before = git.side_by_side
    GP.press('v')
    T.eq(git.side_by_side, not before)
    GP.press('v')
    T.eq(git.side_by_side, before)
    GP.close()
    T.rmrf(dir)
  end)
end)

T.summary()
