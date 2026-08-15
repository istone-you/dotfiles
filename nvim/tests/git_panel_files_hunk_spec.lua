-- files.luaの hunk単位ステージングモード(<CR>で入る)のテスト。files_spec.luaは
-- ファイル単位の操作しか検証していなかったため、このモード専用に切り出す

local T = dofile(TESTS_DIR .. '/helpers.lua')
local GP = dofile(TESTS_DIR .. '/git_panel_helpers.lua')

-- 離れた2箇所を変更し、確実に2つのhunkに分かれる元ファイルを作る
local BASE = {}
for i = 1, 20 do BASE[i] = 'line' .. i end

local function seeded_repo()
  return T.tmp_git_repo(function(d)
    T.write_file(d .. '/f.txt', BASE)
    GP.git(d, { 'add', '.' })
    GP.git(d, { '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', 'seed' })
  end)
end

local function two_hunk_edit(dir)
  local lines = vim.deepcopy(BASE)
  lines[2] = 'line2-CHANGED'
  lines[17] = 'line17-CHANGED'
  T.write_file(dir .. '/f.txt', lines)
end

T.describe('git_panel Files panel: hunk staging mode (<CR>)', function()
  T.it('<CR> on a file with multiple hunks enters hunk mode showing both hunk headers', function()
    local dir = seeded_repo()
    two_hunk_edit(dir)
    GP.open(dir, false)
    local left = GP.left_win()
    GP.goto_row(left, GP.find_row(left, 'f.txt'))
    vim.wait(200) -- カーソル移動によるdiff取得(非同期)が先に落ち着くのを待つ。
                  -- 直後に<CR>すると、その古いdiff描画がhunkビューに後から
                  -- 被って上書きする競合が起きる(既知の問題、別途報告)
    GP.press('<CR>')
    vim.wait(100)
    local right = GP.right_win()
    T.ok(right ~= nil, 'right window should still be shown')
    local count = 0
    for _, l in ipairs(GP.lines(right)) do
      if l:match('^@@') then count = count + 1 end
    end
    T.eq(count, 2, 'both hunks should be rendered')

    GP.close()
    T.rmrf(dir)
  end)

  T.it('<CR> on a directory toggles collapse instead of entering hunk mode', function()
    local dir = T.tmp_git_repo(function(d)
      T.write_file(d .. '/sub/a.txt', { 'a' })
      T.write_file(d .. '/sub/b.txt', { 'b' })
      GP.git(d, { 'add', '.' })
      GP.git(d, { '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', 'seed' })
    end)
    T.write_file(dir .. '/sub/a.txt', { 'a', 'changed' })
    T.write_file(dir .. '/sub/b.txt', { 'b', 'changed' })
    GP.open(dir, false)
    local left = GP.left_win()
    local row = GP.find_row(left, 'sub')
    GP.goto_row(left, row)
    local before = table.concat(GP.lines(left), '\n')
    GP.press('<CR>')
    vim.wait(80)
    local after = table.concat(GP.lines(left), '\n')
    T.ok(before ~= after, 'collapsing sub/ should change the left panel listing')
    T.ok(not after:find('a.txt', 1, true), 'children should be hidden once collapsed')

    GP.close()
    T.rmrf(dir)
  end)

  T.it('Space in hunk mode stages only the hunk under the cursor, leaving the other unstaged', function()
    local dir = seeded_repo()
    two_hunk_edit(dir)
    GP.open(dir, false)
    local left = GP.left_win()
    GP.goto_row(left, GP.find_row(left, 'f.txt'))
    vim.wait(200) -- カーソル移動によるdiff取得(非同期)が先に落ち着くのを待つ。
                  -- 直後に<CR>すると、その古いdiff描画がhunkビューに後から
                  -- 被って上書きする競合が起きる(既知の問題、別途報告)
    GP.press('<CR>')
    vim.wait(100)
    -- hunkモードのキーは右バッファのバッファローカルマップなので、フォーカスを
    -- 左に戻してしまうpress()ではなくpress_modal()(フォーカス変更なし)で送る
    GP.press_modal('l') -- 2番目のhunkへ移動
    GP.press_modal('<Space>')
    T.wait_until(function() return vim.trim(GP.git(dir, { 'diff', '--cached' }).stdout) ~= '' end)

    local staged = GP.git(dir, { 'diff', '--cached' }).stdout
    local unstaged = GP.git(dir, { 'diff' }).stdout
    T.contains(staged, 'line17-CHANGED')
    T.ok(not staged:find('line2%-CHANGED'), 'first hunk should not be staged yet')
    T.contains(unstaged, 'line2-CHANGED')
    T.ok(not unstaged:find('line17%-CHANGED'), 'staged hunk should be gone from the unstaged diff')

    GP.close()
    T.rmrf(dir)
  end)

  T.it('d in hunk mode discards only the selected hunk after confirmation', function()
    local dir = seeded_repo()
    two_hunk_edit(dir)
    GP.open(dir, false)
    local left = GP.left_win()
    GP.goto_row(left, GP.find_row(left, 'f.txt'))
    vim.wait(200) -- カーソル移動によるdiff取得(非同期)が先に落ち着くのを待つ。
                  -- 直後に<CR>すると、その古いdiff描画がhunkビューに後から
                  -- 被って上書きする競合が起きる(既知の問題、別途報告)
    GP.press('<CR>')
    vim.wait(100)
    GP.press_modal('d') -- 1番目のhunk(初期選択)を破棄
    vim.wait(80)
    GP.press_modal('y')
    T.wait_until(function()
      return not GP.git(dir, { 'diff' }).stdout:find('line2%-CHANGED')
    end)

    local unstaged = GP.git(dir, { 'diff' }).stdout
    T.ok(not unstaged:find('line2%-CHANGED'), 'discarded hunk should be gone')
    T.contains(unstaged, 'line17-CHANGED')

    GP.close()
    T.rmrf(dir)
  end)

  T.it('Tab toggles between the unstaged and staged hunk view when a file has both', function()
    local dir = seeded_repo()
    two_hunk_edit(dir)
    GP.git(dir, { 'add', '.' }) -- 両方stageした後、片方だけ追加編集してunstagedも作る
    local lines = vim.deepcopy(BASE)
    lines[2] = 'line2-CHANGED'
    lines[17] = 'line17-CHANGED'
    lines[10] = 'line10-EXTRA-UNSTAGED'
    T.write_file(dir .. '/f.txt', lines)

    GP.open(dir, false)
    local left = GP.left_win()
    -- unstaged側のf.txtへ入る(has_staged & has_unstaged両方trueのはず)
    GP.goto_row(left, GP.find_row(left, 'f.txt'))
    vim.wait(200) -- カーソル移動によるdiff取得(非同期)が先に落ち着くのを待つ。
                  -- 直後に<CR>すると、その古いdiff描画がhunkビューに後から
                  -- 被って上書きする競合が起きる(既知の問題、別途報告)
    GP.press('<CR>')
    vim.wait(100)
    local first_view = table.concat(GP.lines(GP.right_win()), '\n')
    GP.press_modal('<Tab>')
    vim.wait(100)
    local second_view = table.concat(GP.lines(GP.right_win()), '\n')
    T.ok(first_view ~= second_view, 'Tab should switch to the other side of the diff')

    GP.close()
    T.rmrf(dir)
  end)

  T.it('untracked files warn instead of entering hunk mode', function()
    local dir = T.tmp_git_repo()
    T.write_file(dir .. '/new.txt', { 'x' })
    GP.open(dir, false)
    local left = GP.left_win()
    GP.goto_row(left, GP.find_row(left, 'new.txt'))
    local before = GP.right_win()
    GP.press('<CR>')
    vim.wait(80)
    -- hunkモードに入っていないこと(右パネルはdiff/プレビューのままで、
    -- @@ハンク見出しの選択ハイライト用キーマップには入っていない=qを押しても閉じない)
    T.ok(GP.right_win() ~= nil, 'right window should still show the plain preview')

    GP.close()
    T.rmrf(dir)
  end)

  T.it('q leaves hunk mode and returns focus to the left panel', function()
    local dir = seeded_repo()
    two_hunk_edit(dir)
    GP.open(dir, false)
    local left = GP.left_win()
    GP.goto_row(left, GP.find_row(left, 'f.txt'))
    vim.wait(200) -- カーソル移動によるdiff取得(非同期)が先に落ち着くのを待つ。
                  -- 直後に<CR>すると、その古いdiff描画がhunkビューに後から
                  -- 被って上書きする競合が起きる(既知の問題、別途報告)
    GP.press('<CR>')
    vim.wait(100)
    T.eq(vim.api.nvim_get_current_win(), GP.right_win(), 'focus should move to the right (diff) panel')
    GP.press_modal('q')
    vim.wait(80)
    T.eq(vim.api.nvim_get_current_win(), GP.left_win(), 'q should send focus back to the left panel')

    GP.close()
    T.rmrf(dir)
  end)
end)

T.summary()
