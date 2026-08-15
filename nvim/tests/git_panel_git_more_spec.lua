-- git.luaの低レイヤ部分でcodexの独立調査が指摘していた機能単位の穴:
-- コマンドログ(dont_log/ストリーミングの部分行flush/MAX_LOG切り詰め)、
-- render_diff(空diff/side-by-side)、
-- github_repo_info(URL形式ごとの判定)、fetch_prs(空branch_names/DRAFT変換/API失敗)、
-- ref_candidates(remote HEADの除外)

local T = dofile(TESTS_DIR .. '/helpers.lua')
local GP = dofile(TESTS_DIR .. '/git_panel_helpers.lua')
local git = require('config.git_panel.git')

T.describe('git.lua: command log', function()
  T.it('dont_log=true suppresses the "git ..." entry, but the command still runs', function()
    local dir = T.tmp_git_repo()
    git.root = dir
    local before = #git.command_log
    local done = false
    git.run({ 'status' }, function() done = true end, { dont_log = true })
    T.wait_until(function() return done end)
    T.eq(#git.command_log, before, 'a dont_log command should not add a log entry')
  end)

  T.it('without dont_log, the command is logged as "git <args>"', function()
    local dir = T.tmp_git_repo()
    git.root = dir
    local done = false
    git.run({ 'branch', '--list' }, function() done = true end)
    T.wait_until(function() return done end)
    T.eq(git.command_log[#git.command_log], 'git branch --list')
  end)

  T.it('stream_output=true flushes partial (non-newline-terminated) output as its own log line on completion', function()
    local dir = T.tmp_git_repo()
    git.root = dir
    local done = false
    -- 改行無しでstdoutへ何か出すコマンド(printf経由でgit名を騙るのは無理なので、
    -- M.runの引数をgit以外に変えられないため、改行が入らないstderrを出すコマンドで代用)
    git.run({ 'rev-parse', 'not-a-real-ref' }, function() done = true end, { stream_output = true })
    T.wait_until(function() return done end)
    local found = false
    for _, l in ipairs(git.command_log) do
      if l:find('not-a-real-ref', 1, true) or l:find('unknown revision', 1, true) or l:find('bad revision', 1, true) then
        found = true
      end
    end
    T.ok(found, 'the error output (no trailing newline) should still be flushed into the command log')
  end)

  T.it('keeps at most 200 entries, dropping the oldest first (FIFO)', function()
    local dir = T.tmp_git_repo()
    git.root = dir
    for i = 1, 210 do
      local done = false
      git.run({ 'branch', '--list', 'nonexistent-' .. i }, function() done = true end)
      T.wait_until(function() return done end)
    end
    T.eq(#git.command_log, 200)
    T.contains(git.command_log[#git.command_log], 'nonexistent-210', 'the most recent entry should be present')
    for _, l in ipairs(git.command_log) do
      T.ok(not l:find('nonexistent%-1$'), 'the oldest entry (1) should have been dropped')
    end
  end)
end)

T.describe('git.lua: render_diff', function()
  T.it('returns an empty render for empty input', function()
    local r = git.render_diff('', 80)
    T.eq(#r.lines, 0)
    T.eq(#r.marks, 0)
  end)

  T.it('renders a diff into lines with highlights, without spawning any process', function()
    local diff = table.concat({
      'diff --git a/f.txt b/f.txt', '--- a/f.txt', '+++ b/f.txt',
      '@@ -1 +1 @@', '-old', '+new',
    }, '\n')
    local r = git.render_diff(diff, 80)
    T.ok(#r.lines > 0, 'the diff should produce buffer lines')
    T.ok(#r.marks > 0, 'the diff should produce highlight marks')
    local body = table.concat(r.lines, '\n')
    T.contains(body, 'f.txt')
    T.contains(body, '-old')
    T.contains(body, '+new')
  end)

  T.it('side_by_side puts the removed and added line on the same row', function()
    local diff = table.concat({
      'diff --git a/f.txt b/f.txt', '--- a/f.txt', '+++ b/f.txt',
      '@@ -1 +1 @@', '-old', '+new',
    }, '\n')
    local orig = git.side_by_side
    git.side_by_side = true
    local r = git.render_diff(diff, 80)
    git.side_by_side = orig

    local found = false
    for _, l in ipairs(r.lines) do
      if l:find('-old', 1, true) and l:find('+new', 1, true) then found = true end
    end
    T.ok(found, 'side-by-side should place -old and +new on one line')
  end)

  T.it('toggle_side_by_side flips the flag that the renderer reads', function()
    local orig = git.side_by_side
    git.side_by_side = false
    T.eq(git.toggle_side_by_side(), true)
    T.eq(git.side_by_side, true)
    T.eq(git.toggle_side_by_side(), false)
    git.side_by_side = orig
  end)
end)

T.describe('git.lua: diff_untracked_file', function()
  T.it('produces a real unified diff (diff --git/--- /dev/null/+++/@@), not a headerless "+line" pseudo-diff', function()
    -- 回帰テスト: 以前はfiles.luaが"+++ path\n\n+line1\n+line2"という自作の
    -- 疑似diffを作っていたが、diff --git等のヘッダーが無いため本物のdiffと
    -- 認識できず、新規ファイルのプレビューが無色のまま表示されていた
    local dir = T.tmp_git_repo()
    T.write_file(dir .. '/new.txt', { 'hello', 'world' })
    git.root = dir

    local diff_text
    git.diff_untracked_file('new.txt', function(text) diff_text = text end)
    T.wait_until(function() return diff_text ~= nil end)

    T.contains(diff_text, 'diff --git')
    T.contains(diff_text, '--- /dev/null')
    T.contains(diff_text, '+++ b/new.txt')
    T.contains(diff_text, '@@ -0,0 +1,2 @@')
    T.contains(diff_text, '+hello')
    T.contains(diff_text, '+world')

    T.rmrf(dir)
  end)

  T.it('feeding it through render_diff actually produces colored output (the bug this fixes)', function()
    local dir = T.tmp_git_repo()
    T.write_file(dir .. '/new.txt', { 'hello', 'world' })
    git.root = dir

    local diff_text
    git.diff_untracked_file('new.txt', function(text) diff_text = text end)
    T.wait_until(function() return diff_text ~= nil end)

    local r = git.render_diff(diff_text, 80)
    local added = 0
    for _, m in ipairs(r.marks) do
      if m[4] == 'GitPanelDiffAddMark' then added = added + 1 end
    end
    T.eq(added, 2, 'a new/untracked file diff should be colorized like any other diff')

    T.rmrf(dir)
  end)

  T.it('reports "Binary files ... differ" for a binary untracked file instead of crashing', function()
    local dir = T.tmp_git_repo()
    local f = io.open(dir .. '/bin.dat', 'wb')
    f:write('foo\0bar')
    f:close()
    git.root = dir

    local diff_text
    git.diff_untracked_file('bin.dat', function(text) diff_text = text end)
    T.wait_until(function() return diff_text ~= nil end)
    T.contains(diff_text, 'Binary files')

    T.rmrf(dir)
  end)
end)

T.describe('git.lua: expanded review diff helpers', function()
  T.it('diff_files extracts file sections in raw diff order with add/delete counts', function()
    local diff = table.concat({
      'diff --git a/src/a.txt b/src/a.txt',
      '--- a/src/a.txt',
      '+++ b/src/a.txt',
      '@@ -1 +1,2 @@',
      '-old',
      '+new',
      '+more',
      'diff --git a/src/nested/b.txt b/src/nested/b.txt',
      '--- a/src/nested/b.txt',
      '+++ b/src/nested/b.txt',
      '@@ -1 +1 @@',
      '-x',
      '+y',
    }, '\n')
    local files = git.diff_files(diff)
    T.eq(#files, 2)
    T.eq(files[1].path, 'src/a.txt')
    T.eq(files[1].status, 'M')
    T.eq(files[1].added, 2)
    T.eq(files[1].deleted, 1)
    T.eq(files[2].path, 'src/nested/b.txt')
  end)

  T.it('diff_files marks added and deleted files from /dev/null headers', function()
    local diff = table.concat({
      'diff --git a/added.txt b/added.txt',
      'new file mode 100644',
      '--- /dev/null',
      '+++ b/added.txt',
      '@@ -0,0 +1 @@',
      '+new',
      'diff --git a/deleted.txt b/deleted.txt',
      'deleted file mode 100644',
      '--- a/deleted.txt',
      '+++ /dev/null',
      '@@ -1 +0,0 @@',
      '-old',
    }, '\n')
    local files = git.diff_files(diff)
    T.eq(files[1].path, 'added.txt')
    T.eq(files[1].status, 'A')
    T.eq(files[2].path, 'deleted.txt')
    T.eq(files[2].status, 'D')
  end)

  T.it('diff_worktree_all returns one stream containing tracked and untracked file diffs', function()
    local dir = T.tmp_git_repo(function(d)
      T.write_file(d .. '/tracked.txt', { 'old' })
      GP.git(d, { 'add', '.' })
      GP.git(d, { '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', 'seed' })
    end)
    T.write_file(dir .. '/tracked.txt', { 'new' })
    T.write_file(dir .. '/untracked.txt', { 'fresh' })
    git.root = dir

    local diff_text
    git.diff_worktree_all(function(text) diff_text = text end)
    T.wait_until(function() return diff_text ~= nil end)
    T.contains(diff_text, 'diff --git a/tracked.txt b/tracked.txt')
    T.contains(diff_text, 'diff --git a/untracked.txt b/untracked.txt')
    T.contains(diff_text, '+fresh')

    T.rmrf(dir)
  end)
end)

T.describe('git.lua: github_repo_info URL variants', function()
  local function with_origin(url, fn)
    local dir = T.tmp_git_repo()
    GP.git(dir, { 'remote', 'add', 'origin', url })
    git.root = dir
    local result, called = 'unset', false
    git.github_repo_info(function(r) result = r; called = true end)
    T.wait_until(function() return called end)
    fn(result)
    T.rmrf(dir)
  end

  T.it('parses an SSH-style URL (git@github.com:owner/repo.git)', function()
    with_origin('git@github.com:my-org/my-repo.git', function(r)
      T.eq(r, { owner = 'my-org', repo = 'my-repo' })
    end)
  end)

  T.it('parses an HTTPS URL with a .git suffix', function()
    with_origin('https://github.com/my-org/my-repo.git', function(r)
      T.eq(r, { owner = 'my-org', repo = 'my-repo' })
    end)
  end)

  T.it('parses an HTTPS URL without a .git suffix', function()
    with_origin('https://github.com/my-org/my-repo', function(r)
      T.eq(r, { owner = 'my-org', repo = 'my-repo' })
    end)
  end)

  T.it('strips embedded credentials from an HTTPS URL', function()
    with_origin('https://user:token@github.com/my-org/my-repo.git', function(r)
      T.eq(r, { owner = 'my-org', repo = 'my-repo' })
    end)
  end)

  T.it('returns nil for a non-GitHub remote', function()
    with_origin('https://gitlab.com/my-org/my-repo.git', function(r)
      T.eq(r, nil)
    end)
  end)

  T.it('returns nil when there is no origin remote at all', function()
    local dir = T.tmp_git_repo()
    git.root = dir
    local result, called = 'unset', false
    git.github_repo_info(function(r) result = r; called = true end)
    T.wait_until(function() return called end)
    T.eq(result, nil)
    T.rmrf(dir)
  end)
end)

T.describe('git.lua: fetch_prs', function()
  T.it('returns an empty list synchronously when branch_names is empty (no network call)', function()
    local orig_system = vim.system
    local called = false
    vim.system = function(...) called = true; return orig_system(...) end
    local result, cb_called = 'unset', false
    git.fetch_prs('o', 'r', 't', {}, function(r) result = r; cb_called = true end)
    vim.system = orig_system
    T.ok(cb_called)
    T.eq(result, {})
    T.ok(not called, 'no curl/network call should happen for an empty branch list')
  end)

  T.it('converts isDraft:true (and not CLOSED) into state=DRAFT', function()
    local orig_system = vim.system
    vim.system = function(_, _, cb)
      cb({ code = 0, stdout = vim.json.encode({
        data = { repository = { a1 = { edges = {
          { node = { title = 'x', headRefName = 'f', state = 'OPEN', number = 1, isDraft = true,
            headRepositoryOwner = { login = 'me' } } },
        } } } } }),
      })
    end
    local prs
    git.fetch_prs('me', 'repo', 'tok', { 'f' }, function(r) prs = r end)
    vim.system = orig_system
    T.wait_until(function() return prs ~= nil end)
    T.eq(#prs, 1)
    T.eq(prs[1].state, 'DRAFT')
  end)

  T.it('keeps state=CLOSED even if isDraft:true (closed drafts are not shown as drafts)', function()
    local orig_system = vim.system
    vim.system = function(_, _, cb)
      cb({ code = 0, stdout = vim.json.encode({
        data = { repository = { a1 = { edges = {
          { node = { title = 'x', headRefName = 'f', state = 'CLOSED', number = 1, isDraft = true,
            headRepositoryOwner = { login = 'me' } } },
        } } } } }),
      })
    end
    local prs
    git.fetch_prs('me', 'repo', 'tok', { 'f' }, function(r) prs = r end)
    vim.system = orig_system
    T.wait_until(function() return prs ~= nil end)
    T.eq(prs[1].state, 'CLOSED')
  end)

  T.it('returns an empty list (no crash) when curl fails', function()
    local orig_system = vim.system
    vim.system = function(_, _, cb) cb({ code = 1, stdout = '', stderr = 'connection failed' }) end
    local prs
    git.fetch_prs('me', 'repo', 'tok', { 'f' }, function(r) prs = r end)
    vim.system = orig_system
    T.wait_until(function() return prs ~= nil end)
    T.eq(prs, {})
  end)

  T.it('returns an empty list (no crash) when curl succeeds but the response is not valid JSON', function()
    local orig_system = vim.system
    vim.system = function(_, _, cb) cb({ code = 0, stdout = 'not json at all' }) end
    local prs
    git.fetch_prs('me', 'repo', 'tok', { 'f' }, function(r) prs = r end)
    vim.system = orig_system
    T.wait_until(function() return prs ~= nil end)
    T.eq(prs, {})
  end)

  T.it('keeps the auth token out of curl argv (passes it via -H @file)', function()
    local seen
    local orig_system = vim.system
    vim.system = function(cmd, _, cb)
      seen = cmd
      cb({ code = 1, stdout = '', stderr = 'fail' })
    end
    local token = 'SECRET_TOKEN_SHOULD_NOT_APPEAR_IN_ARGV'
    local prs
    git.fetch_prs('me', 'repo', token, { 'f' }, function(r) prs = r end)
    vim.system = orig_system
    T.wait_until(function() return prs ~= nil end)
    local joined = table.concat(seen, '\0')
    T.ok(not joined:find(token, 1, true), 'token must not appear in curl argv')
    local has_header_file = false
    for i, arg in ipairs(seen) do
      if arg == '-H' and seen[i + 1] and seen[i + 1]:sub(1, 1) == '@' then
        has_header_file = true
        break
      end
    end
    T.ok(has_header_file, 'Authorization should be supplied via -H @file')
  end)
end)

T.describe('git.lua: ref_candidates', function()
  T.it('excludes the symbolic "origin/HEAD" ref from remote-tracking candidates', function()
    local remote = vim.fn.tempname()
    vim.fn.mkdir(remote, 'p')
    GP.git(remote, { 'init', '-q', '--bare', '-b', 'main' })
    local dir = vim.fn.tempname()
    vim.system({ 'git', 'clone', '-q', remote, dir }):wait()
    GP.git(dir, { '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', 'seed', '--allow-empty' })
    GP.git(dir, { 'push', '-u', 'origin', 'main' })
    -- git cloneはorigin/HEADを自動設定する。念のため明示的にも張っておく
    GP.git(dir, { 'remote', 'set-head', 'origin', 'main' })
    T.contains(GP.git(dir, { 'for-each-ref', 'refs/remotes/' }).stdout, 'origin/HEAD',
      'sanity check: origin/HEAD should exist as a ref')

    git.root = dir
    local candidates
    git.ref_candidates(function(c) candidates = c end)
    T.wait_until(function() return candidates ~= nil end)
    T.ok(not vim.tbl_contains(candidates, 'origin/HEAD'), 'origin/HEAD should be excluded from suggestions')
    T.ok(vim.tbl_contains(candidates, 'origin/main'), 'the real remote branch should still be included')

    T.rmrf(dir); T.rmrf(remote)
  end)

  T.it('includes local branches, tags, and the special HEAD-ish refs', function()
    local dir = T.tmp_git_repo()
    GP.git(dir, { 'branch', 'feature' })
    GP.git(dir, { 'tag', 'v1.0' })
    git.root = dir

    local candidates
    git.ref_candidates(function(c) candidates = c end)
    T.wait_until(function() return candidates ~= nil end)
    T.ok(vim.tbl_contains(candidates, 'feature'))
    T.ok(vim.tbl_contains(candidates, 'v1.0'))
    T.ok(vim.tbl_contains(candidates, 'HEAD'))
    T.ok(vim.tbl_contains(candidates, 'FETCH_HEAD'))

    T.rmrf(dir)
  end)
end)

T.describe('git.lua: pr_check_state (statusCheckRollup畳み込み)', function()
  local function run(c) return git.pr_check_state(c) end
  T.it('チェックが無ければ nil', function()
    T.eq(run(nil), nil)
    T.eq(run({}), nil)
  end)
  T.it('全て成功なら success（SKIPPED/NEUTRALも成功扱い）', function()
    T.eq(run({
      { __typename = 'CheckRun', status = 'COMPLETED', conclusion = 'SUCCESS' },
      { __typename = 'CheckRun', status = 'COMPLETED', conclusion = 'SKIPPED' },
      { __typename = 'CheckRun', status = 'COMPLETED', conclusion = 'NEUTRAL' },
      { __typename = 'StatusContext', state = 'SUCCESS' },
    }), 'success')
  end)
  T.it('未完了(IN_PROGRESS/QUEUED)や PENDING があれば pending', function()
    T.eq(run({
      { __typename = 'CheckRun', status = 'COMPLETED', conclusion = 'SUCCESS' },
      { __typename = 'CheckRun', status = 'IN_PROGRESS', conclusion = '' },
    }), 'pending')
    T.eq(run({ { __typename = 'StatusContext', state = 'PENDING' } }), 'pending')
  end)
  T.it('失敗は pending より優先（GitHubと同じく赤を最優先）', function()
    T.eq(run({
      { __typename = 'CheckRun', status = 'IN_PROGRESS' },
      { __typename = 'CheckRun', status = 'COMPLETED', conclusion = 'FAILURE' },
    }), 'failure')
    T.eq(run({ { __typename = 'StatusContext', state = 'ERROR' } }), 'failure')
  end)
end)

T.summary()
