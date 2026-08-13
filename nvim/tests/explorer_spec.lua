local T = dofile(TESTS_DIR .. '/helpers.lua')

--- explorer.luaはプロセス内で最初に開いた時だけ`cwd = vim.fn.getcwd()`を取り込み、
--- 以降は内部のcwdをnavigationでしか変えない(外部からvim.fn.chdir()しても追従しない)。
--- そのため複数のit()ブロックでそれぞれ別の一時ディレクトリを使おうとすると、
--- 2つ目以降が「最初のテストが使っていた(既に削除済みの)ディレクトリ」を見に行って
--- 落ちる。一連の操作を1つの子プロセス内で連続して行う実際の使用形態に合わせて
--- テストする
local function run_child(body_lua)
  local script = "local function assert_eq(a, b, msg)\n"
    .. "  if not vim.deep_equal(a, b) then\n"
    .. "    error((msg or 'mismatch') .. ': expected ' .. vim.inspect(b) .. ' got ' .. vim.inspect(a))\n"
    .. "  end\n"
    .. "end\n"
    .. "local function feed(keys)\n"
    .. "  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'x', false)\n"
    .. "end\n"
    .. "local function list_win()\n"
    .. "  for _, w in ipairs(vim.api.nvim_list_wins()) do\n"
    .. "    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == 'explorer' then return w end\n"
    .. "  end\n"
    .. "end\n"
    .. "local function lines(win) return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false) end\n"
    .. "local function find_row(win, needle)\n"
    .. "  for i, l in ipairs(lines(win)) do if l:find(needle, 1, true) then return i end end\n"
    .. "end\n"
    .. "local ok, err = pcall(function()\n"
    .. body_lua
    .. "\nend)\n"
    .. "if ok then os.exit(0) else io.stderr:write(tostring(err) .. '\\n'); os.exit(1) end\n"
  local tmp = vim.fn.tempname() .. '.lua'
  vim.fn.writefile(vim.split(script, '\n', { plain = true }), tmp)
  local res = vim.system({
    'nvim', '-u', 'NONE', '--cmd', 'set rtp+=' .. vim.fn.fnamemodify(TESTS_DIR, ':h'), '-l', tmp,
  }, { text = true }):wait()
  vim.fn.delete(tmp)
  return res
end

T.describe('explorer', function()
  T.it('dims only git-ignored entries; untracked/new files are NOT dimmed', function()
    local res = run_child([[
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, 'p')
      local function git(args)
        local c = { 'git', '-C', dir, '-c', 'user.email=t@t', '-c', 'user.name=t' }
        vim.list_extend(c, args)
        vim.system(c):wait()
      end
      git({ 'init', '-q' })
      -- tracked: keep.txt, src/app.txt, .gitignore(=build/を無視)
      vim.fn.mkdir(dir .. '/src', 'p')
      vim.fn.writefile({ 'x' }, dir .. '/keep.txt')
      vim.fn.writefile({ 'x' }, dir .. '/src/app.txt')
      -- build/ はディレクトリごと無視、secret/* は中身だけ無視(.terraform型: 畳まれず個別列挙)
      vim.fn.writefile({ 'build/', 'secret/*' }, dir .. '/.gitignore')
      git({ 'add', 'keep.txt', 'src/app.txt', '.gitignore' })
      git({ 'commit', '-qm', 'seed' })
      -- unmanaged: fresh.txt(未追跡), src/new.txt(trackedなsrc内の未追跡), build/(ignore), secret/(中身がignore)
      vim.fn.writefile({ 'y' }, dir .. '/fresh.txt')
      vim.fn.writefile({ 'y' }, dir .. '/src/new.txt')
      vim.fn.mkdir(dir .. '/build', 'p')
      vim.fn.writefile({ 'y' }, dir .. '/build/out.txt')
      vim.fn.mkdir(dir .. '/secret', 'p')
      vim.fn.writefile({ 'y' }, dir .. '/secret/token.txt')

      vim.fn.chdir(dir)
      local explorer = require('config.explorer')
      explorer.open(false)
      local win = list_win()
      local buf = vim.api.nvim_win_get_buf(win)
      local ns = vim.api.nvim_create_namespace('explorer_hl')

      -- git status(非同期)が届いて再描画され、未追跡に ? が付くまで待つ
      local ok = vim.wait(3000, function()
        for _, l in ipairs(lines(win)) do
          if l:find('fresh.txt', 1, true) and l:find('?', 1, true) then return true end
        end
        return false
      end, 50)
      assert_eq(ok, true, 'git status ready (untracked has ? sign)')

      local function dimmed(needle)
        local row
        for i, l in ipairs(lines(win)) do if l:find(needle, 1, true) then row = i - 1 end end
        assert_eq(row ~= nil, true, 'row for ' .. needle)
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, 10000 }, { details = true })) do
          if m[4].hl_group == 'ExplorerDimmed' then return true end
        end
        return false
      end

      assert_eq(dimmed('fresh.txt'), false, 'untracked/new file should NOT be dimmed')
      assert_eq(dimmed('keep.txt'), false, 'tracked file should NOT be dimmed')
      assert_eq(dimmed('build'), true, 'ignored dir (collapsed) should be dimmed')
      assert_eq(dimmed('src'), false, 'tracked dir with an untracked child should NOT be dimmed')

      -- 無視ディレクトリを開いたら中身も全部薄いこと（畳まれた祖先から継承）
      local brow
      for i, l in ipairs(lines(win)) do if l:find('build', 1, true) then brow = i end end
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { brow, 0 })
      feed('l')
      local ok2 = vim.wait(3000, function()
        if not (lines(win)[1] or ''):find('build', 1, true) then return false end
        for i, l in ipairs(lines(win)) do
          if l:find('out.txt', 1, true) then
            local row = i - 1
            for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, 10000 }, { details = true })) do
              if m[4].hl_group == 'ExplorerDimmed' then return true end
            end
          end
        end
        return false
      end, 50)
      assert_eq(ok2, true, 'contents of an ignored dir should all be dimmed')
    ]])
    T.ok(res.code == 0, 'child failed: ' .. (res.stderr or ''))
  end)

  T.it('i toggles visibility of git-ignored entries', function()
    local res = run_child([[
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, 'p')
      local function git(args)
        local c = { 'git', '-C', dir, '-c', 'user.email=t@t', '-c', 'user.name=t' }
        vim.list_extend(c, args)
        vim.system(c):wait()
      end
      git({ 'init', '-q' })
      vim.fn.writefile({ 'x' }, dir .. '/keep.txt')
      vim.fn.writefile({ 'build/', '*.log' }, dir .. '/.gitignore')
      git({ 'add', 'keep.txt', '.gitignore' })
      git({ 'commit', '-qm', 'seed' })
      vim.fn.writefile({ 'y' }, dir .. '/fresh.txt')     -- 未追跡（ignore ではない）
      vim.fn.writefile({ 'y' }, dir .. '/debug.log')     -- ignore されたファイル
      vim.fn.mkdir(dir .. '/build', 'p')                 -- ignore されたディレクトリ
      vim.fn.writefile({ 'y' }, dir .. '/build/out.txt')

      vim.fn.chdir(dir)
      local explorer = require('config.explorer')
      explorer.open(false)
      local win = list_win()
      vim.api.nvim_set_current_win(win)

      -- git status(非同期)が届くまで待つ
      local ok = vim.wait(3000, function()
        for _, l in ipairs(lines(win)) do
          if l:find('fresh.txt', 1, true) and l:find('?', 1, true) then return true end
        end
        return false
      end, 50)
      assert_eq(ok, true, 'git status ready')

      local function shown(needle) return find_row(win, needle) ~= nil end
      -- '.git' は '.gitignore' に部分一致してしまうため行末で厳密に判定する
      local function shown_exact(name)
        for _, l in ipairs(lines(win)) do
          if l:match('%s' .. vim.pesc(name) .. '%s*$') then return true end
        end
        return false
      end

      assert_eq(shown('build'), true, 'ignored dir is shown by default')
      assert_eq(shown('debug.log'), true, 'ignored file is shown by default')

      feed('i')
      assert_eq(shown('build'), false, 'ignored dir hidden after i')
      assert_eq(shown('debug.log'), false, 'ignored file hidden after i')
      assert_eq(shown('fresh.txt'), true, 'untracked file stays visible')
      assert_eq(shown('keep.txt'), true, 'tracked file stays visible')
      assert_eq((lines(win)[1] or ''):find('ignored: off', 1, true) ~= nil, true, 'header shows the state')
      assert_eq(shown_exact('.git'),false, '.git is hidden too (never reported by git status)')

      feed('i')
      assert_eq(shown('build'), true, 'ignored dir shown again after i')
      assert_eq(shown('debug.log'), true, 'ignored file shown again after i')
      assert_eq(shown_exact('.git'),true, '.git shown again after i')
      assert_eq((lines(win)[1] or ''):find('ignored: off', 1, true) == nil, true, 'header state cleared')

      -- ツリー表示でも隠れること（t で切替 → build が消える）
      feed('t')
      assert_eq(shown('build'), true, 'tree mode shows the ignored dir')
      feed('i')
      assert_eq(shown('build'), false, 'tree mode hides the ignored dir too')
      feed('i')
      feed('t')

      -- ignore ディレクトリの中へ入ってから隠す設定にしても、一覧が空にならないこと
      vim.api.nvim_win_set_cursor(win, { find_row(win, 'build'), 0 })
      feed('l')
      local ok2 = vim.wait(3000, function()
        return (lines(win)[1] or ''):find('build', 1, true) ~= nil and find_row(win, 'out.txt') ~= nil
      end, 50)
      assert_eq(ok2, true, 'entered the ignored dir')
      feed('i')
      assert_eq(shown('out.txt'), true, 'contents stay visible inside an ignored dir')
    ]])
    T.ok(res.code == 0, 'child failed: ' .. (res.stderr or ''))
  end)

  T.it('o launches the browser preview for HTML/Markdown and warns otherwise', function()
    local res = run_child([[
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, 'p')
      vim.fn.writefile({ '# Title' }, dir .. '/doc.md')
      vim.fn.writefile({ 'plain' }, dir .. '/note.txt')
      vim.fn.chdir(dir)

      -- 実サーバ起動/ポート入力/xdg-open を避けるため config.browser をスタブ
      _G.__preview = 0
      package.loaded['config.browser'] = { open = function() _G.__preview = _G.__preview + 1 end }
      local notified = {}
      vim.notify = function(msg) notified[#notified + 1] = msg end

      local explorer = require('config.explorer')
      explorer.open(false)
      local win = list_win()

      -- 非 HTML/Markdown 上の o は起動せず警告のみ（explorer はそのまま）
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { find_row(win, 'note.txt'), 0 })
      feed('o')
      assert_eq(_G.__preview, 0, 'o on .txt must NOT launch preview')
      local warned = false
      for _, m in ipairs(notified) do if tostring(m):find('HTML / Markdown', 1, true) then warned = true end end
      assert_eq(warned, true, 'o on .txt should warn')

      -- Markdown 上の o は preview を起動し、ファイルを origin window に開く
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { find_row(win, 'doc.md'), 0 })
      feed('o')
      assert_eq(_G.__preview, 1, 'o on .md should launch preview')
      assert_eq(vim.api.nvim_buf_get_name(0):match('doc%.md$') ~= nil, true, 'the .md file should be opened')
    ]])
    T.ok(res.code == 0, 'child failed: ' .. (res.stderr or ''))
  end)

  -- nvim-tree 方式の .git 監視: 別ペイン相当(nvim 側では一切ナビゲートしない)で git add した時、
  -- ディレクトリ移動せずに git 表示が更新されること
  T.it('refreshes git status when .git changes without navigating (git add)', function()
    local res = run_child([[
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, 'p')
      local function git(args)
        local c = { 'git', '-C', dir, '-c', 'user.email=t@t', '-c', 'user.name=t' }
        vim.list_extend(c, args)
        vim.system(c):wait()
      end
      git({ 'init', '-q' })
      vim.fn.writefile({ 'x' }, dir .. '/keep.txt')
      git({ 'add', 'keep.txt' })
      git({ 'commit', '-qm', 'seed' })         -- これで .git/index が存在する
      vim.fn.writefile({ 'y' }, dir .. '/fresh.txt')   -- 未追跡

      vim.fn.chdir(dir)
      local explorer = require('config.explorer')
      explorer.open(false)
      local win = list_win()

      -- 初期 git status が載り、fresh.txt が未追跡( ? )として出るまで待つ(= .git 監視も開始済み)
      local function fresh_line()
        for _, l in ipairs(lines(win)) do if l:find('fresh.txt', 1, true) then return l end end
      end
      local ready = vim.wait(3000, function()
        local l = fresh_line()
        return l ~= nil and l:find('?', 1, true) ~= nil
      end, 50)
      assert_eq(ready, true, 'untracked fresh.txt should initially show ?')

      -- nvim 側では何もせず、外から git add（.git/index だけ変わる）
      git({ 'add', 'fresh.txt' })

      -- ディレクトリ移動せずに、? が消える(ステージ済みへ変わる)まで待つ
      local updated = vim.wait(3000, function()
        local l = fresh_line()
        return l ~= nil and l:find('?', 1, true) == nil
      end, 50)
      assert_eq(updated, true, 'git add should refresh the status without navigating (.git watch)')
    ]])
    T.ok(res.code == 0, 'child failed: ' .. (res.stderr or ''))
  end)

  T.it('shows a symlink as "name -> target" with its own highlight', function()
    local res = run_child([[
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir .. '/real', 'p')
      vim.fn.writefile({ 'x' }, dir .. '/real/config.toml')
      vim.uv.fs_symlink('real/config.toml', dir .. '/link.toml')

      vim.fn.chdir(dir)
      local explorer = require('config.explorer')
      explorer.open(false)
      vim.wait(120)
      local win = list_win()
      local buf = vim.api.nvim_win_get_buf(win)
      local ns = vim.api.nvim_create_namespace('explorer_hl')

      local row, text
      for i, l in ipairs(lines(win)) do
        if l:find('link.toml', 1, true) then row = i - 1; text = l end
      end
      assert_eq(row ~= nil, true, 'link.toml row exists')
      assert_eq(text:find('link.toml -> real/config.toml', 1, true) ~= nil, true, 'shows -> target, got: ' .. text)

      local has_symlink_hl = false
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, 10000 }, { details = true })) do
        if m[4].hl_group == 'ExplorerSymlink' then has_symlink_hl = true end
      end
      assert_eq(has_symlink_hl, true, 'the -> target part should use ExplorerSymlink')
    ]])
    T.ok(res.code == 0, 'child failed: ' .. (res.stderr or ''))
  end)

  T.it('does not accumulate slashes when going to / and back (no //app)', function()
    local res = run_child([[
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, 'p')
      vim.fn.chdir(dir)
      local explorer = require('config.explorer')
      explorer.open(false)
      vim.wait(80)
      local win = list_win()
      vim.api.nvim_set_current_win(win)
      local function header() return lines(win)[1] end

      -- ルート(/)まで戻る（go_parentが変化しなくなったら到達）
      local prev
      for _ = 1, 20 do
        local h = header()
        if h == prev then break end
        prev = h
        feed('h')
        vim.wait(60)
      end

      -- / で子へ入る→戻る を数回。二重スラッシュが出ない/累積しないこと
      for round = 1, 3 do
        assert_eq(header():find('//', 1, true), nil, 'no // at root (round ' .. round .. '): ' .. header())
        local trow
        for i, l in ipairs(lines(win)) do if l:find('tmp', 1, true) then trow = i end end
        assert_eq(trow ~= nil, true, 'tmp entry exists at /')
        vim.api.nvim_win_set_cursor(win, { trow, 0 })
        feed('l')
        vim.wait(100)
        assert_eq(header():find('//', 1, true), nil, 'no // after entering (round ' .. round .. '): ' .. header())
        assert_eq(header():find('/tmp', 1, true) ~= nil, true, 'should be /tmp: ' .. header())
        feed('h')
        vim.wait(80)
      end
    ]])
    T.ok(res.code == 0, 'child failed: ' .. (res.stderr or ''))
  end)

  T.it('v toggles a sidebar preview float that follows the cursor; Enter closes it', function()
    local res = run_child([[
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, 'p')
      vim.fn.writefile({ 'AAA', 'BBB' }, dir .. '/a.txt')
      vim.fn.writefile({ 'ZZZ here' }, dir .. '/z.txt')
      vim.fn.chdir(dir)
      local explorer = require('config.explorer')
      explorer.open(false)
      vim.wait(80)
      local win = list_win()
      vim.api.nvim_set_current_win(win)

      local function preview_win()
        for _, w in ipairs(vim.api.nvim_list_wins()) do
          local c = vim.api.nvim_win_get_config(w)
          if c.relative == 'editor' and vim.bo[vim.api.nvim_win_get_buf(w)].filetype ~= 'explorer' then
            return w
          end
        end
      end
      local function pv_lines()
        local w = preview_win()
        return w and vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false) or {}
      end
      local function contains(tbl, needle)
        for _, l in ipairs(tbl) do if l:find(needle, 1, true) then return true end end
        return false
      end

      -- カーソルを a.txt に置く
      local arow = find_row(win, 'a.txt')
      vim.api.nvim_win_set_cursor(win, { arow, 0 })
      assert_eq(preview_win(), nil, 'no preview before toggle')

      feed('v')
      vim.wait(800)
      assert_eq(preview_win() ~= nil, true, 'preview float appears after v')
      assert_eq(contains(pv_lines(), 'AAA'), true, 'shows a.txt content: ' .. vim.inspect(pv_lines()))

      -- z.txt へ移動 → 追従
      vim.api.nvim_win_set_cursor(win, { find_row(win, 'z.txt'), 0 })
      vim.api.nvim_exec_autocmds('CursorMoved', { buffer = vim.api.nvim_win_get_buf(win) })
      vim.wait(800)
      assert_eq(contains(pv_lines(), 'ZZZ here'), true, 'preview follows cursor to z.txt: ' .. vim.inspect(pv_lines()))

      -- サイドバーと被らない（左右どちら側でも）
      local c = vim.api.nvim_win_get_config(preview_win())
      local scol = vim.api.nvim_win_get_position(win)[2]
      local swidth = vim.api.nvim_win_get_width(win)
      local p_left, p_right = c.col, c.col + c.width + 1 -- ボーダー込み
      local s_left, s_right = scol, scol + swidth - 1
      assert_eq(p_right < s_left or p_left > s_right, true, 'preview must not overlap the sidebar')

      -- もう一度で消える
      feed('v')
      vim.wait(100)
      assert_eq(preview_win(), nil, 'preview toggles off')

      -- 再表示して Enter で開くと閉じる
      feed('v')
      vim.wait(300)
      assert_eq(preview_win() ~= nil, true, 'preview on again')
      feed('<CR>')
      vim.wait(200)
      assert_eq(preview_win(), nil, 'Enter (open file) closes the preview')
    ]])
    T.ok(res.code == 0, 'child failed: ' .. (res.stderr or ''))
  end)

  T.it('< / > move the sidebar to the left / right (winid preserved)', function()
    local res = run_child([[
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, 'p')
      vim.fn.writefile({ 'x' }, dir .. '/a.txt')
      vim.fn.chdir(dir)
      local explorer = require('config.explorer')
      explorer.open(false)
      vim.wait(60)
      local win = list_win()
      vim.api.nvim_set_current_win(win)
      local function col() return vim.api.nvim_win_get_position(win)[2] end

      assert_eq(col(), 0, 'default is left side')
      feed('>')
      vim.wait(50)
      assert_eq(list_win(), win, 'same window id after move (wincmd L)')
      assert_eq(col() > 0, true, 'moved to the right')
      feed('<')
      vim.wait(50)
      assert_eq(col(), 0, 'moved back to the left')

      -- 位置は開き直しても維持される
      feed('>')
      vim.wait(50)
      assert_eq(col() > 0, true, 'right again')
      feed('q')
      vim.wait(50)
      explorer.open(false)
      vim.wait(60)
      local win2 = list_win()
      assert_eq(vim.api.nvim_win_get_position(win2)[2] > 0, true, 'reopens on the remembered (right) side')
    ]])
    T.ok(res.code == 0, 'child failed: ' .. (res.stderr or ''))
  end)

  T.it('t toggles between list and collapsible tree view', function()
    local res = run_child([[
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir .. '/alpha/deep', 'p')
      vim.fn.writefile({ 'x' }, dir .. '/alpha/inner.txt')
      vim.fn.writefile({ 'x' }, dir .. '/alpha/deep/nested.txt')
      vim.fn.writefile({ 'x' }, dir .. '/root.txt')
      vim.fn.chdir(dir)
      local explorer = require('config.explorer')
      explorer.open(false)
      vim.wait(80)
      local win = list_win()
      vim.api.nvim_set_current_win(win)

      local function text() return table.concat(lines(win), '\n') end
      assert_eq(lines(win)[1]:find('[list]', 1, true) ~= nil, true, 'starts in list mode')
      assert_eq(text():find('inner.txt', 1, true), nil, 'list mode only shows the current dir')

      feed('t')
      vim.wait(80)
      assert_eq(lines(win)[1]:find('[tree]', 1, true) ~= nil, true, 'switches to tree mode')
      assert_eq(text():find('inner.txt', 1, true), nil, 'tree dirs start collapsed')
      local arrow_hl = vim.api.nvim_get_hl(0, { name = 'ExplorerTreeArrow', link = false })
      assert_eq(arrow_hl.fg, tonumber('626262', 16), 'tree arrows use a subdued neo-tree-like gray')

      local alpha_row = find_row(win, 'alpha')
      assert_eq(lines(win)[alpha_row]:sub(1, #''), '', 'root tree dir starts with the fold arrow, no left padding')
      assert_eq(lines(win)[alpha_row]:find('', 1, true) ~= nil, true, 'collapsed dir uses nvim-tree arrow_closed')
      feed('E')
      vim.wait(80)
      assert_eq(text():find('nested.txt', 1, true) ~= nil, true, 'E expands all directories')
      feed('W')
      vim.wait(80)
      assert_eq(text():find('nested.txt', 1, true), nil, 'W collapses everything after E')

      vim.api.nvim_win_set_cursor(win, { alpha_row, 0 })
      feed('l')
      vim.wait(80)
      assert_eq(text():find('inner.txt', 1, true) ~= nil, true, 'l expands a directory in tree mode')
      alpha_row = find_row(win, 'alpha')
      assert_eq(lines(win)[alpha_row]:find('', 1, true) ~= nil, true, 'expanded dir uses nvim-tree arrow_open')
      assert_eq(lines(win)[alpha_row]:find('', 1, true) ~= nil, true, 'expanded dir uses nvim-tree open folder icon')

      vim.api.nvim_win_set_cursor(win, { find_row(win, 'deep'), 0 })
      feed('l')
      vim.wait(80)
      assert_eq(text():find('nested.txt', 1, true) ~= nil, true, 'can expand nested directories')
      feed('W')
      vim.wait(80)
      assert_eq(text():find('inner.txt', 1, true), nil, 'W collapses every open directory')
      assert_eq(text():find('nested.txt', 1, true), nil, 'W collapses nested open directories too')

      vim.api.nvim_win_set_cursor(win, { find_row(win, 'alpha'), 0 })
      feed('l')
      vim.wait(80)
      vim.api.nvim_win_set_cursor(win, { find_row(win, 'inner.txt'), 0 })
      feed('h')
      vim.wait(80)
      local cursor_row = vim.api.nvim_win_get_cursor(win)[1]
      local current_line = lines(win)[cursor_row] or ''
      assert_eq(current_line:find('alpha', 1, true) ~= nil, true, 'h from a child returns to the parent row')

      feed('h')
      vim.wait(80)
      assert_eq(text():find('inner.txt', 1, true), nil, 'h on an expanded dir collapses it')

      feed('t')
      vim.wait(80)
      assert_eq(lines(win)[1]:find('[list]', 1, true) ~= nil, true, 'switches back to list mode')
    ]])
    T.ok(res.code == 0, 'child failed: ' .. (res.stderr or ''))
  end)

  T.it('c toggles compact folders in tree view (single-child dir chains collapse to one row)', function()
    local res = run_child([[
      local dir = vim.fn.tempname()
      -- a/b/c は各段が子ディレクトリ1つだけの連鎖 → 圧縮対象。leaf.txt で末端の中身を示す
      vim.fn.mkdir(dir .. '/a/b/c', 'p')
      vim.fn.writefile({ 'x' }, dir .. '/a/b/c/leaf.txt')
      -- multi は子が2つある → 圧縮されず単独の行のまま
      vim.fn.mkdir(dir .. '/multi/one', 'p')
      vim.fn.mkdir(dir .. '/multi/two', 'p')
      vim.fn.chdir(dir)
      local explorer = require('config.explorer')
      explorer.open(false)
      vim.wait(80)
      local win = list_win()
      vim.api.nvim_set_current_win(win)

      local function text() return table.concat(lines(win), '\n') end

      -- 圧縮無効のツリー表示では a だけが1段目に出て、b/c は畳まれた表示にならない
      feed('t')
      vim.wait(80)
      assert_eq(lines(win)[1]:find('[tree]', 1, true) ~= nil, true, 'tree mode')
      assert_eq(find_row(win, 'a/b/c') == nil, true, 'without compact, no combined a/b/c row')

      -- c で圧縮を有効化 → a/b/c が1行に畳まれ、ヘッダーに compact 表示が出る
      feed('c')
      vim.wait(80)
      assert_eq(lines(win)[1]:find('tree/compact', 1, true) ~= nil, true, 'header shows compact state')
      local combined = find_row(win, 'a/b/c')
      assert_eq(combined ~= nil, true, 'a/b/c collapses into a single row')
      -- 子が複数ある multi は圧縮されず単独名のまま（multi/one のような結合はしない）
      assert_eq(find_row(win, 'multi/one') == nil, true, 'multi with 2 children is not compacted')
      assert_eq(find_row(win, 'multi') ~= nil, true, 'multi still shows as its own row')

      -- 圧縮行を展開すると末端 c の中身（leaf.txt）が出る
      vim.api.nvim_win_set_cursor(win, { combined, 0 })
      feed('l')
      vim.wait(80)
      assert_eq(text():find('leaf.txt', 1, true) ~= nil, true, 'expanding the compact row reveals the tail dir contents')

      -- もう一度 c で圧縮無効 → 結合行が消える
      feed('c')
      vim.wait(80)
      assert_eq(lines(win)[1]:find('tree/compact', 1, true), nil, 'compact turned off')
      assert_eq(find_row(win, 'a/b/c') == nil, true, 'no combined row after disabling compact')
    ]])
    T.ok(res.code == 0, 'child failed: ' .. (res.stderr or ''))
  end)

  T.it('F reveals the current editor file in both list and tree views', function()
    local res = run_child([[
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir .. '/alpha/deep', 'p')
      vim.fn.writefile({ 'x' }, dir .. '/alpha/deep/nested.txt')
      vim.fn.writefile({ 'x' }, dir .. '/root.txt')
      vim.fn.chdir(dir)
      vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/alpha/deep/nested.txt'))
      local explorer = require('config.explorer')
      explorer.open(false)
      vim.wait(80)
      local win = list_win()
      vim.api.nvim_set_current_win(win)

      feed('F')
      vim.wait(80)
      assert_eq(lines(win)[1]:find('alpha/deep', 1, true) ~= nil, true, 'list reveal moves cwd to file parent')
      local cursor_row = vim.api.nvim_win_get_cursor(win)[1]
      local cursor_line = lines(win)[cursor_row] or ''
      assert_eq(cursor_line:find('nested.txt', 1, true) ~= nil, true, 'list reveal places cursor on current file')

      feed('h')
      vim.wait(60)
      feed('h')
      vim.wait(60)
      feed('t')
      vim.wait(80)
      feed('F')
      vim.wait(80)
      local text = table.concat(lines(win), '\n')
      assert_eq(text:find('nested.txt', 1, true) ~= nil, true, 'tree reveal expands ancestors to current file')
      cursor_row = vim.api.nvim_win_get_cursor(win)[1]
      cursor_line = lines(win)[cursor_row] or ''
      assert_eq(cursor_line:find('nested.txt', 1, true) ~= nil, true, 'tree reveal places cursor on current file')
    ]])
    T.ok(res.code == 0, 'child failed: ' .. (res.stderr or ''))
  end)

  T.it('lists dirs before files (alphabetical); l/h navigate in/out; a/r/d trash / D permanent-delete', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. '/zdir', 'p')
    T.write_file(dir .. '/afile.txt', { 'x' })
    T.write_file(dir .. '/bfile.txt', { 'x' })
    local xdg = vim.fn.tempname()
    vim.fn.mkdir(xdg, 'p')

    local res = run_child(string.format([[
      vim.env.XDG_DATA_HOME = %s
      vim.fn.chdir(%s)
      local explorer = require('config.explorer')
      explorer.open(false)
      vim.wait(80)
      local win = list_win()

      -- 1) dirが先、ファイルはアルファベット順
      local order = {}
      for _, l in ipairs(lines(win)) do
        if l:find('zdir', 1, true) then table.insert(order, 'zdir') end
        if l:find('afile.txt', 1, true) then table.insert(order, 'afile.txt') end
        if l:find('bfile.txt', 1, true) then table.insert(order, 'bfile.txt') end
      end
      assert_eq(order, { 'zdir', 'afile.txt', 'bfile.txt' }, 'STEP1-order')

      -- 2) l で入る、h で親へ戻る(カーソルは元の場所に復帰)
      vim.api.nvim_set_current_win(win)
      local zdir_row = find_row(win, 'zdir')
      assert_eq(zdir_row ~= nil, true, 'STEP2-find-zdir-row')
      vim.api.nvim_win_set_cursor(win, { zdir_row, 0 })
      feed('l')
      vim.wait(50)
      -- explorer.luaはNeovim本体のcwdを変えず、自前の内部cwdだけで一覧・操作を
      -- 行う(ヘッダー行に現在のパスを表示する)。そちらで確認する
      assert_eq(lines(win)[1]:find('zdir', 1, true) ~= nil, true, 'STEP2-header=' .. lines(win)[1])
      feed('h')
      vim.wait(50)
      local back_row = vim.api.nvim_win_get_cursor(win)[1]
      assert_eq(lines(win)[back_row]:find('zdir', 1, true) ~= nil, true, 'h should restore cursor onto zdir')
      feed('j')
      vim.api.nvim_exec_autocmds('CursorMoved', { buffer = vim.api.nvim_win_get_buf(win) })
      local moved_row = vim.api.nvim_win_get_cursor(win)[1]
      assert_eq(lines(win)[moved_row]:find('afile.txt', 1, true) ~= nil, true, 'j after h should move to afile')
      feed('.')
      feed('.')
      vim.wait(50)
      local after_rerender_row = vim.api.nvim_win_get_cursor(win)[1]
      assert_eq(lines(win)[after_rerender_row]:find('afile.txt', 1, true) ~= nil, true, 'rerender after h+j must not snap back to zdir')

      -- 3) a でファイル/ディレクトリ作成
      feed('a')
      vim.wait(50)
      feed('inewdir/')
      feed('<CR>')
      vim.wait(80)
      assert_eq(vim.fn.isdirectory(%s .. '/newdir'), 1)

      feed('a')
      vim.wait(50)
      feed('inewfile.txt')
      feed('<CR>')
      vim.wait(80)
      assert_eq(vim.fn.filereadable(%s .. '/newfile.txt'), 1)

      -- 4) r でリネーム
      vim.api.nvim_win_set_cursor(win, { find_row(win, 'newfile.txt'), 0 })
      feed('r')
      vim.wait(50)
      feed('<C-u>')
      feed('irenamed.txt')
      feed('<CR>')
      vim.wait(80)
      assert_eq(vim.fn.filereadable(%s .. '/renamed.txt'), 1)
      assert_eq(vim.fn.filereadable(%s .. '/newfile.txt'), 0)

      -- 5) d でゴミ箱へ（元の場所から消え、Trash/filesへ移る）
      vim.api.nvim_win_set_cursor(win, { find_row(win, 'renamed.txt'), 0 })
      feed('d')
      vim.wait(50)
      feed('y')
      vim.wait(80)
      assert_eq(vim.fn.filereadable(%s .. '/renamed.txt'), 0)
      assert_eq(vim.fn.filereadable(%s .. '/Trash/files/renamed.txt'), 1)
      assert_eq(vim.fn.filereadable(%s .. '/Trash/info/renamed.txt.trashinfo'), 1)

      -- 6) D で完全削除（ゴミ箱に残らない）
      feed('a')
      vim.wait(50)
      feed('igone.txt')
      feed('<CR>')
      vim.wait(80)
      vim.api.nvim_win_set_cursor(win, { find_row(win, 'gone.txt'), 0 })
      feed('D')
      vim.wait(50)
      feed('y')
      vim.wait(80)
      assert_eq(vim.fn.filereadable(%s .. '/gone.txt'), 0)
      assert_eq(vim.fn.filereadable(%s .. '/Trash/files/gone.txt'), 0)
    ]], vim.inspect(xdg), vim.inspect(dir), vim.inspect(dir), vim.inspect(dir), vim.inspect(dir), vim.inspect(dir),
      vim.inspect(dir), vim.inspect(xdg), vim.inspect(xdg), vim.inspect(dir), vim.inspect(xdg)))

    T.eq(res.code, 0, 'child failed: ' .. (res.stderr or ''))
    T.rmrf(dir)
    T.rmrf(xdg)
  end)

  T.it('X deletes all empty directories under the current folder, including nested ones, after confirmation', function()
    local res = run_child([[
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir .. '/empty_parent/empty_child', 'p')
      vim.fn.mkdir(dir .. '/nonempty/empty_grandchild', 'p')
      vim.fn.writefile({ 'x' }, dir .. '/nonempty/file.txt')
      vim.fn.mkdir(dir .. '/link_target', 'p')
      vim.uv.fs_symlink('link_target', dir .. '/dir_link')
      for i = 1, 14 do
        vim.fn.mkdir(string.format('%s/many/e%02d', dir, i), 'p')
      end

      vim.fn.chdir(dir)
      local explorer = require('config.explorer')
      explorer.open(false)
      vim.wait(80)
      local win = list_win()
      vim.api.nvim_set_current_win(win)

      feed('X')
      local confirm_title = ''
      local confirm_footer = ''
      local function confirm_lines()
        for _, w in ipairs(vim.api.nvim_list_wins()) do
          local cfg = vim.api.nvim_win_get_config(w)
          if cfg.relative ~= '' then
            local title = ''
            if cfg.title then
              for _, chunk in ipairs(cfg.title) do title = title .. chunk[1] end
            end
            if title:find('確認', 1, true) then
              confirm_title = title
              if cfg.footer then
                for _, chunk in ipairs(cfg.footer) do confirm_footer = confirm_footer .. chunk[1] end
              end
              return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)
            end
          end
        end
      end
      assert_eq(vim.wait(3000, function() return confirm_lines() ~= nil end, 20), true, 'confirmation appears after async scan')
      local confirm_text = table.concat(confirm_lines(), '\n')
      assert_eq(confirm_text:find('空ディレクトリ', 1, true) ~= nil, true, 'confirmation shows target count')
      assert_eq(confirm_text:find('empty_parent/empty_child', 1, true) ~= nil, true, 'confirmation lists nested target')
      assert_eq(confirm_text:find('nonempty/empty_grandchild', 1, true) ~= nil, true, 'confirmation lists grandchild target')
      assert_eq(confirm_text:find('many/e14', 1, true) ~= nil, true, 'confirmation lists every target without truncating')
      assert_eq(confirm_text:find('他', 1, true), nil, 'confirmation should not hide targets behind "other N"')
      assert_eq(confirm_text:find('スクロール', 1, true), nil, 'confirmation body should not add an instruction line')
      assert_eq(confirm_footer:find('↓', 1, true) ~= nil, true, 'confirmation footer shows that more lines continue')
      assert_eq(confirm_footer:find('/', 1, true) ~= nil, true, 'confirmation footer shows the visible range')
      assert_eq(confirm_title:find('確認', 1, true) ~= nil, true, 'confirmation title stays compact')
      assert_eq(vim.b[vim.api.nvim_get_current_buf()].hide_cursor, true, 'confirmation popup hides the cursor')
      feed('y')
      vim.wait(160)

      assert_eq(vim.fn.isdirectory(dir .. '/empty_parent/empty_child'), 0, 'nested empty child is deleted')
      assert_eq(vim.fn.isdirectory(dir .. '/empty_parent'), 0, 'parent that became empty is deleted too')
      assert_eq(vim.fn.isdirectory(dir .. '/nonempty/empty_grandchild'), 0, 'empty grandchild under nonempty dir is deleted')
      assert_eq(vim.fn.isdirectory(dir .. '/many/e14'), 0, 'all listed empty dirs are deleted')
      assert_eq(vim.fn.isdirectory(dir .. '/nonempty'), 1, 'nonempty dir remains')
      assert_eq(vim.fn.filereadable(dir .. '/nonempty/file.txt'), 1, 'files are not removed')
      assert_eq(vim.uv.fs_lstat(dir .. '/dir_link').type, 'link', 'directory symlinks are not traversed or removed')
    ]])
    T.ok(res.code == 0, 'child failed: ' .. (res.stderr or ''))
  end)

  T.it('Tab/Ctrl-y/x/p: copy-paste and cut-paste move files between directories', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. '/dest', 'p')
    T.write_file(dir .. '/src.txt', { 'hello' })

    local res = run_child(string.format([[
      vim.fn.chdir(%s)
      local explorer = require('config.explorer')
      explorer.open(false)
      vim.wait(80)
      local win = list_win()
      vim.api.nvim_set_current_win(win)

      vim.api.nvim_win_set_cursor(win, { find_row(win, 'src.txt'), 0 })
      feed('<C-y>') -- copy
      vim.wait(50)
      vim.api.nvim_win_set_cursor(win, { find_row(win, 'dest'), 0 })
      feed('l') -- dest/ へ入る
      vim.wait(50)
      feed('<C-p>') -- paste
      vim.wait(80)
      assert_eq(vim.fn.filereadable(%s .. '/dest/src.txt'), 1)
      assert_eq(vim.fn.filereadable(%s .. '/src.txt'), 1, 'copy should keep the original')

      feed('h') -- 親へ戻る
      vim.wait(50)
      vim.api.nvim_win_set_cursor(win, { find_row(win, 'src.txt'), 0 })
      feed('<C-x>') -- cut
      vim.wait(50)
      vim.api.nvim_win_set_cursor(win, { find_row(win, 'dest'), 0 })
      feed('l')
      vim.wait(50)
      feed('<C-S-p>') -- 上書き貼り付け
      vim.wait(80)
      feed('h')
      vim.wait(50)
      assert_eq(vim.fn.filereadable(%s .. '/src.txt'), 0, 'cut should remove the original')
    ]], vim.inspect(dir), vim.inspect(dir), vim.inspect(dir), vim.inspect(dir)))

    T.eq(res.code, 0, 'child failed: ' .. (res.stderr or ''))
    T.rmrf(dir)
  end)

  T.it('y / Y copy the filename / absolute path under the cursor', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/target.txt', { 'x' })
    local abs = vim.fn.fnamemodify(dir .. '/target.txt', ':p')

    local res = run_child(string.format([[
      vim.fn.chdir(%s)
      local explorer = require('config.explorer')
      explorer.open(false)
      vim.wait(80)
      local win = list_win()
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { find_row(win, 'target.txt'), 0 })

      feed('y')
      vim.wait(50)
      assert_eq(vim.fn.getreg('"'), 'target.txt')

      feed('Y')
      vim.wait(50)
      assert_eq(vim.fn.getreg('"'), %s)
    ]], vim.inspect(dir), vim.inspect(abs)))
    T.eq(res.code, 0, 'child failed: ' .. (res.stderr or ''))
    T.rmrf(dir)
  end)

  T.it('f filters entries incrementally, Esc clears the filter', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/apple.txt', { 'x' })
    T.write_file(dir .. '/banana.txt', { 'x' })

    local res = run_child(string.format([[
      vim.fn.chdir(%s)
      local explorer = require('config.explorer')
      explorer.open(false)
      vim.wait(80)
      local win = list_win()
      vim.api.nvim_set_current_win(win)

      -- f でフィルタ欄を開き、入力を確定すると現在フォルダが名前で絞り込まれる
      feed('fapple<CR>')
      vim.wait(50)
      local text = table.concat(lines(win), '\n')
      assert_eq(text:find('apple.txt', 1, true) ~= nil, true)
      assert_eq(text:find('banana.txt', 1, true) == nil, true)

      feed('<Esc>') -- explorer 側の Esc でフィルタ解除
      vim.wait(50)
      text = table.concat(lines(win), '\n')
      assert_eq(text:find('banana.txt', 1, true) ~= nil, true, 'Esc should clear the filter')
    ]], vim.inspect(dir)))

    T.eq(res.code, 0, 'child failed: ' .. (res.stderr or ''))
    T.rmrf(dir)
  end)

  T.it('fullscreen shows a preview pane: directory listing for dirs, file content for files', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. '/subdir', 'p')
    T.write_file(dir .. '/subdir/inner.txt', { 'x' })
    T.write_file(dir .. '/init.lua', { 'local msg = "hello"', 'print(msg)' })
    local img = assert(io.open(dir .. '/z.png', 'wb'))
    img:write(string.char(0x89) .. 'PNG\r\n\26\n\0\0\0\rIHDR')
    img:close()

    local res = run_child(string.format([[
      vim.o.columns, vim.o.lines = 160, 40
      vim.fn.chdir(%s)
      local explorer = require('config.explorer')
      explorer.open(true)
      vim.wait(80)
      local wins = {}
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        local cfg = vim.api.nvim_win_get_config(w)
        if cfg.relative ~= '' then table.insert(wins, { win = w, col = cfg.col }) end
      end
      table.sort(wins, function(a, b) return a.col < b.col end)
      assert_eq(#wins, 2)
      local list_w, preview_w = wins[1].win, wins[2].win
      local function preview_buf()
        return vim.api.nvim_win_get_buf(preview_w)
      end
      local function preview_text()
        return table.concat(vim.api.nvim_buf_get_lines(preview_buf(), 0, -1, false), '\n')
      end
      assert_eq(preview_text():find('inner.txt', 1, true) ~= nil, true, 'dir preview should list contents')

      vim.api.nvim_set_current_win(list_w)
      vim.api.nvim_win_set_cursor(list_w, { vim.api.nvim_win_get_cursor(list_w)[1] + 1, 0 })
      vim.api.nvim_exec_autocmds('CursorMoved', { buffer = vim.api.nvim_win_get_buf(list_w) })
      vim.wait(1500, function() return preview_text():find('hello', 1, true) ~= nil end, 20)
      assert_eq(preview_text():find('hello', 1, true) ~= nil, true, 'file preview should show its content')
      assert_eq(vim.bo[preview_buf()].buftype, 'nofile', 'file preview should use a normal scratch buffer')
      assert_eq(vim.bo[preview_buf()].filetype, 'lua', 'file preview should use nvim filetype detection')
      assert_eq(vim.bo[preview_buf()].syntax, 'lua', 'file preview should use nvim syntax highlighting')

      vim.api.nvim_win_set_cursor(list_w, { find_row(list_w, 'z.png'), 0 })
      vim.api.nvim_exec_autocmds('CursorMoved', { buffer = vim.api.nvim_win_get_buf(list_w) })
      vim.wait(100)
      assert_eq(preview_text():find('バイナリファイル', 1, true) ~= nil, true, 'binary/image preview should show a placeholder')
    ]], vim.inspect(dir)))

    T.eq(res.code, 0, 'child failed: ' .. (res.stderr or ''))
    T.rmrf(dir)
  end)

  T.it('fullscreen: <CR> on a file closes the floating list/preview so the opened buffer is actually visible', function()
    -- 回帰テスト: open_selected()がis_fullscreen中もfloatを閉じずにorigin_winへ
    -- editしていたため、画面全体を覆うfloatの裏でファイルが開くだけで見た目には
    -- 何も変わらず「ファイルが開けない」ように見えていた
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/a.txt', { 'hello' })

    local res = run_child(string.format([[
      vim.o.columns, vim.o.lines = 160, 40
      vim.fn.chdir(%s)
      local explorer = require('config.explorer')
      explorer.open(true)
      vim.wait(80)
      local list_win
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == 'explorer' then list_win = w end
      end
      vim.api.nvim_set_current_win(list_win)
      vim.api.nvim_win_set_cursor(list_win, { find_row(list_win, 'a.txt'), 0 })
      feed('<CR>')
      vim.wait(80)

      assert_eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':t'), 'a.txt',
        'the file should be edited in the current (visible) window')
      local floats_remaining = 0
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(w).relative ~= '' then floats_remaining = floats_remaining + 1 end
      end
      assert_eq(floats_remaining, 0, 'the fullscreen list/preview floats should be closed, not left covering the screen')
    ]], vim.inspect(dir)))

    T.eq(res.code, 0, 'child failed: ' .. (res.stderr or ''))
    T.rmrf(dir)
  end)

  T.it('sidebar mode: <CR> on a file opens it while keeping the explorer panel open', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/a.txt', { 'hello' })

    local res = run_child(string.format([[
      vim.fn.chdir(%s)
      local explorer = require('config.explorer')
      explorer.open(false)
      vim.wait(80)
      local list_win
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == 'explorer' then list_win = w end
      end
      vim.api.nvim_set_current_win(list_win)
      vim.api.nvim_win_set_cursor(list_win, { find_row(list_win, 'a.txt'), 0 })
      feed('<CR>')
      vim.wait(80)

      assert_eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':t'), 'a.txt')
      local still_open = false
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == 'explorer' then still_open = true end
      end
      assert_eq(still_open, true, 'the sidebar explorer panel should remain open after opening a file')
    ]], vim.inspect(dir)))

    T.eq(res.code, 0, 'child failed: ' .. (res.stderr or ''))
    T.rmrf(dir)
  end)

  T.it('. toggles hidden dotfiles; R refreshes after an out-of-band filesystem change', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/.hidden', { 'x' })
    T.write_file(dir .. '/visible.txt', { 'x' })

    local res = run_child(string.format([[
      vim.fn.chdir(%s)
      local explorer = require('config.explorer')
      explorer.open(false)
      vim.wait(80)
      local win = list_win()
      vim.api.nvim_set_current_win(win)

      -- 既定は表示ありなので、まず非表示に切り替える
      feed('.')
      vim.wait(50)
      local text = table.concat(lines(win), '\n')
      assert_eq(text:find('.hidden', 1, true) == nil, true, 'dotfile should be hidden after .')
      feed('.')
      vim.wait(50)
      text = table.concat(lines(win), '\n')
      assert_eq(text:find('.hidden', 1, true) ~= nil, true, 'dotfile should reappear after . again')

      vim.fn.writefile({'x'}, %s .. '/added-outside.txt')
      feed('R')
      vim.wait(80)
      text = table.concat(lines(win), '\n')
      assert_eq(text:find('added-outside.txt', 1, true) ~= nil, true, 'R should pick up the new file')
    ]], vim.inspect(dir), vim.inspect(dir)))

    T.eq(res.code, 0, 'child failed: ' .. (res.stderr or ''))
    T.rmrf(dir)
  end)

  T.it('fs watcher auto-refreshes after an out-of-band filesystem change without pressing R', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/visible.txt', { 'x' })

    local res = run_child(string.format([[
      vim.fn.chdir(%s)
      local explorer = require('config.explorer')
      explorer.open(false)
      vim.wait(80)
      local win = list_win()
      vim.api.nvim_set_current_win(win)

      vim.fn.writefile({'x'}, %s .. '/added-by-watch.txt')
      local ok = vim.wait(2000, function()
        local text = table.concat(lines(win), '\n')
        return text:find('added-by-watch.txt', 1, true) ~= nil
      end)
      assert_eq(ok, true, 'fs watcher should pick up the new file without R')
    ]], vim.inspect(dir), vim.inspect(dir)))

    T.eq(res.code, 0, 'child failed: ' .. (res.stderr or ''))
    T.rmrf(dir)
  end)

  T.it('Tab toggles multi-select; trash/copy act on the whole selection, not just the cursor row', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/a.txt', { 'x' })
    T.write_file(dir .. '/b.txt', { 'x' })
    T.write_file(dir .. '/c.txt', { 'x' })
    local xdg = vim.fn.tempname()
    vim.fn.mkdir(xdg, 'p')

    local res = run_child(string.format([[
      vim.env.XDG_DATA_HOME = %s
      vim.fn.chdir(%s)
      local explorer = require('config.explorer')
      explorer.open(false)
      vim.wait(80)
      local win = list_win()
      vim.api.nvim_set_current_win(win)

      -- a.txtとb.txtだけ選択(<Tab>2回、c.txtは選ばない)してゴミ箱へ -> c.txtだけ残る
      vim.api.nvim_win_set_cursor(win, { find_row(win, 'a.txt'), 0 })
      feed('<Tab>')
      vim.wait(30)
      feed('<Tab>') -- カーソルが進んでb.txtの上にいるはず
      vim.wait(30)
      feed('d')
      vim.wait(50)
      feed('y') -- 確認モーダル
      vim.wait(80)
      assert_eq(vim.fn.filereadable(%s .. '/a.txt'), 0, 'selected a.txt should be trashed')
      assert_eq(vim.fn.filereadable(%s .. '/b.txt'), 0, 'selected b.txt should be trashed')
      assert_eq(vim.fn.filereadable(%s .. '/c.txt'), 1, 'unselected c.txt should remain')
      assert_eq(vim.fn.filereadable(%s .. '/Trash/files/a.txt'), 1)
      assert_eq(vim.fn.filereadable(%s .. '/Trash/files/b.txt'), 1)
    ]], vim.inspect(xdg), vim.inspect(dir), vim.inspect(dir), vim.inspect(dir), vim.inspect(dir),
      vim.inspect(xdg), vim.inspect(xdg)))
    T.eq(res.code, 0, 'child failed: ' .. (res.stderr or ''))
    T.rmrf(dir)
    T.rmrf(xdg)
  end)

  T.it('<C-a> selects everything and <C-r> inverts the selection before deleting', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/a.txt', { 'x' })
    T.write_file(dir .. '/b.txt', { 'x' })

    local res = run_child(string.format([[
      vim.fn.chdir(%s)
      local explorer = require('config.explorer')
      explorer.open(false)
      vim.wait(80)
      local win = list_win()
      vim.api.nvim_set_current_win(win)

      feed('<C-a>') -- 全選択
      vim.wait(30)
      feed('<C-r>') -- 反転 -> 全解除
      vim.wait(30)
      feed('<Esc>') -- 選択が空ならフィルタ解除/パネルクローズに落ちる。
                     -- ここは選択0件のはずなのでパネルが閉じてしまう前に確認する
    ]], vim.inspect(dir)))
    T.eq(res.code, 0, 'child failed: ' .. (res.stderr or ''))

    -- <C-a>で全選択し、そのままゴミ箱へ移すと全ファイルが消えることを確認する
    local xdg = vim.fn.tempname()
    vim.fn.mkdir(xdg, 'p')
    res = run_child(string.format([[
      vim.env.XDG_DATA_HOME = %s
      vim.fn.chdir(%s)
      local explorer = require('config.explorer')
      explorer.open(false)
      vim.wait(80)
      local win = list_win()
      vim.api.nvim_set_current_win(win)
      feed('<C-a>')
      vim.wait(30)
      feed('d')
      vim.wait(50)
      feed('y')
      vim.wait(80)
      assert_eq(vim.fn.filereadable(%s .. '/a.txt'), 0)
      assert_eq(vim.fn.filereadable(%s .. '/b.txt'), 0)
    ]], vim.inspect(xdg), vim.inspect(dir), vim.inspect(dir), vim.inspect(dir)))
    T.eq(res.code, 0, 'child failed: ' .. (res.stderr or ''))
    T.rmrf(dir)
    T.rmrf(xdg)
  end)

  T.it('<Esc> priority: clears selection first, then the filter, only closing the panel once both are empty', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/apple.txt', { 'x' })
    T.write_file(dir .. '/banana.txt', { 'x' })

    local res = run_child(string.format([[
      vim.fn.chdir(%s)
      local explorer = require('config.explorer')
      explorer.open(false)
      vim.wait(80)
      local win = list_win()
      vim.api.nvim_set_current_win(win)

      feed('fapple<CR>')
      vim.wait(50)
      vim.api.nvim_win_set_cursor(win, { find_row(win, 'apple.txt'), 0 })
      feed('<Tab>') -- フィルタされた状態で選択もする
      vim.wait(50)

      feed('<Esc>') -- 1回目: 選択解除が先
      vim.wait(50)
      assert_eq(list_win() ~= nil, true, 'panel should still be open (selection was cleared, not the panel)')
      local text = table.concat(lines(win), '\n')
      assert_eq(text:find('banana.txt', 1, true), nil, 'filter should still be active (selection was cleared, not the filter)')

      feed('<Esc>') -- 2回目: 選択は既に空なので、今度はフィルタが解除される
      vim.wait(50)
      assert_eq(list_win() ~= nil, true, 'panel should still be open (filter was cleared, not the panel)')
      text = table.concat(lines(win), '\n')
      assert_eq(text:find('banana.txt', 1, true) ~= nil, true, 'filter should be cleared now')

      feed('<Esc>') -- 3回目: 選択・フィルタとも空なので、今度こそパネルを閉じる
      vim.wait(50)
      assert_eq(list_win(), nil, 'panel should close once selection and filter are both empty')
    ]], vim.inspect(dir)))
    T.eq(res.code, 0, 'child failed: ' .. (res.stderr or ''))
    T.rmrf(dir)
  end)

  T.it('Ctrl-S-p (overwrite paste) replaces an existing same-named file instead of creating a "_2" copy', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. '/dest', 'p')
    T.write_file(dir .. '/src.txt', { 'new content' })
    T.write_file(dir .. '/dest/src.txt', { 'old content' })

    local res = run_child(string.format([[
      vim.fn.chdir(%s)
      local explorer = require('config.explorer')
      explorer.open(false)
      vim.wait(80)
      local win = list_win()
      vim.api.nvim_set_current_win(win)

      vim.api.nvim_win_set_cursor(win, { find_row(win, 'src.txt'), 0 })
      feed('<C-y>') -- copy
      vim.wait(50)
      vim.api.nvim_win_set_cursor(win, { find_row(win, 'dest'), 0 })
      feed('l') -- dest/ へ入る
      vim.wait(50)
      feed('<C-S-p>') -- 上書き貼り付け(名前が衝突しても別名にしない)
      vim.wait(80)
      local names = {}
      for _, l in ipairs(lines(win)) do table.insert(names, l) end
      local joined = table.concat(names, '\n')
      assert_eq(joined:find('src_2', 1, true), nil, 'overwrite paste should not create a "_2" copy')
      local content = vim.fn.readfile(%s .. '/dest/src.txt')
      assert_eq(content[1], 'new content', "overwrite paste should replace the existing file's content")
    ]], vim.inspect(dir), vim.inspect(dir)))
    T.eq(res.code, 0, 'child failed: ' .. (res.stderr or ''))
    T.rmrf(dir)
  end)

  T.it('a plain paste (Ctrl-p) onto a name collision creates a "_2" copy instead of overwriting', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. '/dest', 'p')
    T.write_file(dir .. '/src.txt', { 'new content' })
    T.write_file(dir .. '/dest/src.txt', { 'old content' })

    local res = run_child(string.format([[
      vim.fn.chdir(%s)
      local explorer = require('config.explorer')
      explorer.open(false)
      vim.wait(80)
      local win = list_win()
      vim.api.nvim_set_current_win(win)

      vim.api.nvim_win_set_cursor(win, { find_row(win, 'src.txt'), 0 })
      feed('<C-y>')
      vim.wait(50)
      vim.api.nvim_win_set_cursor(win, { find_row(win, 'dest'), 0 })
      feed('l')
      vim.wait(50)
      feed('<C-p>') -- 通常貼り付け: 衝突時は別名になるはず
      vim.wait(80)
      local old_content = vim.fn.readfile(%s .. '/dest/src.txt')
      assert_eq(old_content[1], 'old content', 'the original file at the destination should be untouched')
    ]], vim.inspect(dir), vim.inspect(dir)))
    T.eq(res.code, 0, 'child failed: ' .. (res.stderr or ''))
    T.rmrf(dir)
  end)

  T.it('/ (recursive search) warns when fd is missing, without opening an input', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')

    local res = run_child(string.format([[
      vim.fn.chdir(%s)
      local explorer = require('config.explorer')
      explorer.open(false)
      vim.wait(80)
      local win = list_win()
      vim.api.nvim_set_current_win(win)

      local orig_executable = vim.fn.executable
      vim.fn.executable = function(name)
        if name == 'fd' then return 0 end
        return orig_executable(name)
      end
      local notified
      local orig_notify = vim.notify
      vim.notify = function(msg) notified = msg end
      local wins_before = #vim.api.nvim_list_wins()
      feed('/')
      vim.wait(80)
      vim.fn.executable = orig_executable
      vim.notify = orig_notify
      assert_eq(notified ~= nil, true, 'should notify about the missing fd dependency')
      assert_eq(#vim.api.nvim_list_wins(), wins_before, 'no input window should open')
    ]], vim.inspect(dir)))

    T.eq(res.code, 0, 'child failed: ' .. (res.stderr or ''))
    T.rmrf(dir)
  end)

  T.it('/ recursively finds a filename with fd (nested, respecting matches) and opens it on Enter', function()
    if vim.fn.executable('fd') == 0 then return end -- fd 未導入環境ではスキップ

    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. '/sub/deep', 'p')
    T.write_file(dir .. '/sub/deep/target_file.txt', { 'x' })
    T.write_file(dir .. '/other.txt', { 'x' })

    local res = run_child(string.format([[
      vim.fn.chdir(%s)
      local explorer = require('config.explorer')
      explorer.open(false)
      vim.wait(80)
      local win = list_win()
      vim.api.nvim_set_current_win(win)

      -- / で再帰検索欄を開き、ファイル名を打って確定する（入力欄はインサートで開く）。
      -- 深くネストした一致ファイルだけが解決され、Enter で開かれる。
      feed('/target_file<CR>')
      vim.wait(200)

      assert_eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':t'), 'target_file.txt', 'the nested match should be opened')
      -- サイドバーの explorer は開いたまま
      local still_open = false
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == 'explorer' then still_open = true end
      end
      assert_eq(still_open, true, 'the sidebar explorer panel should remain open')
    ]], vim.inspect(dir)))

    T.eq(res.code, 0, 'child failed: ' .. (res.stderr or ''))
    T.rmrf(dir)
  end)

  T.it('/ recursively finds a file by a path fragment (not just its filename)', function()
    if vim.fn.executable('fd') == 0 then return end -- fd 未導入環境ではスキップ

    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. '/lua/config', 'p')
    vim.fn.mkdir(dir .. '/lua/other', 'p')
    T.write_file(dir .. '/lua/config/explorer.lua', { 'x' })
    T.write_file(dir .. '/lua/other/explorer.lua', { 'x' })

    local res = run_child(string.format([[
      vim.fn.chdir(%s)
      local explorer = require('config.explorer')
      explorer.open(false)
      vim.wait(80)
      vim.api.nvim_set_current_win(list_win())

      -- ディレクトリ名を含むクエリでパスに当てられる（ファイル名だけの検索ではない）
      feed('/config/explorer<CR>')
      vim.wait(300)

      local opened = vim.api.nvim_buf_get_name(0)
      assert_eq(vim.fn.fnamemodify(opened, ':t'), 'explorer.lua', 'a match should be opened')
      assert_eq(opened:find('/lua/config/', 1, true) ~= nil, true,
        'the path fragment should select the config/ one, not other/: ' .. opened)
    ]], vim.inspect(dir)))

    T.eq(res.code, 0, 'child failed: ' .. (res.stderr or ''))
    T.rmrf(dir)
  end)

  T.it('/ keeps the selection highlight on the explorer while the input has focus', function()
    if vim.fn.executable('fd') == 0 then return end -- fd 未導入環境ではスキップ

    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. '/lua/config', 'p')
    T.write_file(dir .. '/lua/config/explorer.lua', { 'x' })
    T.write_file(dir .. '/lua/config/search.lua', { 'x' })

    local res = run_child(string.format([[
      vim.fn.chdir(%s)
      require('config.panel_focus') -- 非フォーカスのパネルから cursorline を落とす本番の挙動
      local explorer = require('config.explorer')
      explorer.open(false)
      vim.wait(80)
      local ewin = list_win()
      vim.api.nvim_set_current_win(ewin)

      feed('/')
      vim.wait(50)
      -- 入力欄へフォーカスが移るので panel_focus が一度 cursorline を落とす
      assert_eq(vim.wo[ewin].cursorline, false, 'the prompt should take focus away from the panel')

      -- 打鍵の TextChangedI は headless の feed では飛ばないので、入力欄の中身を直接入れて発火させる
      local pbuf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
      vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, { 'lua/config/' })
      vim.api.nvim_exec_autocmds('TextChangedI', { buffer = pbuf })
      vim.wait(1000, function()
        return #vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(ewin), 0, -1, false) > 3
      end)

      local function row_text()
        local row = vim.api.nvim_win_get_cursor(ewin)[1]
        return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(ewin), row - 1, row, false)[1]
      end
      -- 検索中も選択行が見えていること（見えないと C-j/C-k で何を選んでいるのか分からない）
      assert_eq(vim.wo[ewin].cursorline, true, 'the selection highlight should be back while searching')
      assert_eq(row_text():find('lua/config/explorer.lua', 1, true) ~= nil, true,
        'the cursor should sit on the first result: ' .. tostring(row_text()))

      feed('<C-j>')
      vim.wait(100)
      assert_eq(vim.wo[ewin].cursorline, true, 'the highlight should survive moving the selection')
      assert_eq(row_text():find('lua/config/search.lua', 1, true) ~= nil, true,
        'C-j should move the visible selection down: ' .. tostring(row_text()))

      feed('<Esc>')
      vim.wait(100)
      assert_eq(vim.wo[ewin].cursorline, true, 'the panel keeps its highlight after leaving the search')
    ]], vim.inspect(dir)))

    T.eq(res.code, 0, 'child failed: ' .. (res.stderr or ''))
    T.rmrf(dir)
  end)

  T.it('search filtering: matches the cwd-relative path, ignores the cwd prefix, smart-case', function()
    -- 純粋関数のふるまいを直接確認する（fd・実ファイル非依存）。
    local res = run_child([[
      local explorer = require('config.explorer')
      local dbg = explorer._debug
      dbg.set_cwd('/home/User/myconfig')
      local paths = {
        '/home/User/myconfig/lua/config/explorer.lua',
        '/home/User/myconfig/lua/other/explorer.lua',
        '/home/User/myconfig/README.md',
      }
      local function names(list)
        local out = {}
        for _, p in ipairs(list) do table.insert(out, p:sub(#'/home/User/myconfig/' + 1)) end
        return out
      end

      assert_eq(names(dbg.filter_paths_by_query(paths, 'config/explorer')),
        { 'lua/config/explorer.lua' }, 'a path fragment should match the relative path')
      assert_eq(names(dbg.filter_paths_by_query(paths, 'explorer.lua')),
        { 'lua/config/explorer.lua', 'lua/other/explorer.lua' }, 'a filename query should still match')
      -- cwd 側（myconfig, User）に一致するだけの語は落とす。fd --full-path の取りこぼしではない副産物
      assert_eq(dbg.filter_paths_by_query(paths, 'myconfig'), {}, 'the cwd prefix should not be searched')
      assert_eq(dbg.filter_paths_by_query(paths, 'User'), {}, 'the cwd prefix should not be searched (case too)')
      -- smart-case: 小文字だけなら大小無視、大文字を含むなら区別する
      assert_eq(names(dbg.filter_paths_by_query(paths, 'readme')), { 'README.md' }, 'lowercase query is case-insensitive')
      assert_eq(dbg.filter_paths_by_query(paths, 'Readme'), {}, 'a query with uppercase is case-sensitive')
      assert_eq(dbg.filter_paths_by_query(paths, ''), {}, 'an empty query matches nothing')
    ]])

    T.eq(res.code, 0, 'child failed: ' .. (res.stderr or ''))
  end)

  T.it('build_search rows: list shows cwd-relative paths; tree keeps only matching ancestors', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    -- 純粋関数のふるまいを直接確認する（fd 非依存）。M._debug から検索状態を注入する。
    local res = run_child(string.format([[
      vim.fn.chdir(%s)
      local explorer = require('config.explorer')
      local dbg = explorer._debug
      dbg.set_cwd(%s)
      dbg.set_search_paths({
        %s .. '/sub/deep/target_file.txt',
        %s .. '/sub/other.txt',
      })

      local list_rows = dbg.build_search_list_rows()
      local names = {}
      for _, r in ipairs(list_rows) do table.insert(names, r.display_name) end
      table.sort(names)
      assert_eq(names, { 'sub/deep/target_file.txt', 'sub/other.txt' }, 'list rows should be cwd-relative paths')

      local tree_rows = dbg.build_search_tree_rows()
      -- sub(depth0) / deep(depth1) / target_file.txt(depth2) / other.txt(depth1) の構造になる
      local shape = {}
      for _, r in ipairs(tree_rows) do
        table.insert(shape, r.name .. '@' .. r.depth .. (r.isdir and '/' or ''))
      end
      assert_eq(shape, {
        'sub@0/',
        'deep@1/',
        'target_file.txt@2',
        'other.txt@1',
      }, 'tree rows should keep only matching ancestors, dirs before files, fully expanded')
    ]], vim.inspect(dir), vim.inspect(dir), vim.inspect(dir), vim.inspect(dir)))

    T.eq(res.code, 0, 'child failed: ' .. (res.stderr or ''))
    T.rmrf(dir)
  end)

  T.it('fullscreen: q key and native :q both quit Neovim; sidebar mode only closes the panel', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local cases = {
      { fullscreen = 'true', action = "vim.cmd('normal q')", expect_alive = false, label = 'fullscreen q-key' },
      { fullscreen = 'true', action = "vim.cmd('q')", expect_alive = false, label = 'fullscreen native :q' },
      { fullscreen = 'false', action = "vim.cmd('normal q')", expect_alive = true, label = 'sidebar q-key' },
    }
    for _, c in ipairs(cases) do
      local res = run_child(string.format([[
        vim.fn.chdir(%s)
        require('config.explorer').open(%s)
        vim.wait(150)
        %s
        vim.wait(150)
        io.stderr:write('STILL_ALIVE\n')
        vim.cmd('qa!')
      ]], vim.inspect(dir), c.fullscreen, c.action))
      local alive = (res.stderr or ''):find('STILL_ALIVE') ~= nil
      T.eq(alive, c.expect_alive, c.label .. ' aliveness')
    end
    T.rmrf(dir)
  end)
end)

T.summary()
