local T = dofile(TESTS_DIR .. '/helpers.lua')
local search = require('config.search')

--- search.M.open()/M.replace()は実際にfzfを対話的に起動する前提のツールで、
--- ヘッドレスにはfzf自身のUI操作までは検証できない(pty無しでは意味のある
--- 入出力ができない)。ここでは依存チェック(rg/fzf不在時のnotify)と、
--- 両方揃っている時にfloatingターミナルが起動することだけを確認する
local function with_fake_executable(missing, fn)
  local orig = vim.fn.executable
  vim.fn.executable = function(name)
    if name == missing then return 0 end
    return orig(name)
  end
  local ok, err = pcall(fn)
  vim.fn.executable = orig
  if not ok then error(err, 0) end
end

local function capture_notify(fn)
  local notified
  local orig_notify = vim.notify
  vim.notify = function(msg, level) notified = { msg = msg, level = level } end
  local ok, err = pcall(fn)
  vim.notify = orig_notify
  if not ok then error(err, 0) end
  return notified
end

local function capture_term_shell(fn)
  local before_wins = {}
  local before_bufs = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do before_wins[w] = true end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do before_bufs[b] = true end

  local shells = {}
  local orig_termopen = vim.fn.termopen
  local orig_executable = vim.fn.executable
  vim.fn.executable = function() return 1 end
  vim.fn.termopen = function(cmd)
    if type(cmd) == 'table' and cmd[1] == 'sh' and cmd[2] == '-c' then
      shells[#shells + 1] = cmd[3]
    else
      shells[#shells + 1] = vim.inspect(cmd)
    end
    return 1234
  end

  local ok, err = pcall(fn)
  vim.fn.termopen = orig_termopen
  vim.fn.executable = orig_executable

  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if not before_wins[w] then pcall(vim.api.nvim_win_close, w, true) end
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if not before_bufs[b] then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
  end

  if not ok then error(err, 0) end
  return table.concat(shells, '\n')
end

T.describe('search dependency check', function()
  T.it('M.open() reports an error and does not open anything when rg is missing', function()
    local opened_win_count_before = #vim.api.nvim_list_wins()
    local notified
    with_fake_executable('rg', function()
      notified = capture_notify(function() search.open('x') end)
    end)
    T.ok(notified ~= nil, 'should notify')
    T.contains(notified.msg, 'rg')
    T.eq(#vim.api.nvim_list_wins(), opened_win_count_before, 'no window should open')
  end)

  T.it('M.open() reports an error and does not open anything when fzf is missing', function()
    local opened_win_count_before = #vim.api.nvim_list_wins()
    local notified
    with_fake_executable('fzf', function()
      notified = capture_notify(function() search.open('x') end)
    end)
    T.ok(notified ~= nil, 'should notify')
    T.contains(notified.msg, 'fzf')
    T.eq(#vim.api.nvim_list_wins(), opened_win_count_before, 'no window should open')
  end)

  T.it('M.replace() is gated by the same dependency check', function()
    local notified
    with_fake_executable('rg', function()
      notified = capture_notify(function() search.replace('x', 'y') end)
    end)
    T.ok(notified ~= nil, 'should notify')
    T.contains(notified.msg, 'rg')
  end)

  T.it('M.open() opens a floating terminal running rg|fzf when both are installed', function()
    if vim.fn.executable('rg') == 0 or vim.fn.executable('fzf') == 0 then
      print('  (skipped: rg/fzf not installed on this machine)')
      return
    end
    local prev_cwd = vim.fn.getcwd()
    local missing_dep
    local orig_notify = vim.notify
    vim.notify = function(msg)
      if type(msg) == 'string' and msg:find('見つかりません', 1, true) then
        missing_dep = msg
      end
    end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/a.txt', { 'hello world' })
    vim.fn.chdir(dir)

    search.open('hello')
    vim.wait(150)

    local term_win
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local cfg = vim.api.nvim_win_get_config(w)
      if cfg.relative ~= '' and vim.bo[vim.api.nvim_win_get_buf(w)].buftype == 'terminal' then term_win = w end
    end
    T.ok(term_win ~= nil, 'a floating terminal window should have opened')
    T.ok(missing_dep == nil, 'should not report missing dependencies when rg/fzf are installed')

    local job = vim.b[vim.api.nvim_win_get_buf(term_win)].terminal_job_id
    if job then pcall(vim.fn.jobstop, job) end
    if term_win and vim.api.nvim_win_is_valid(term_win) then vim.api.nvim_win_close(term_win, true) end
    vim.notify = orig_notify
    vim.fn.chdir(prev_cwd)
    T.rmrf(dir)
  end)

  T.it('fzf previews use sed directly and never call bat', function()
    local prev_cwd = vim.fn.getcwd()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/a.txt', { 'hello world' })
    vim.fn.chdir(dir)

    local shell = table.concat({
      capture_term_shell(function() search.open('hello') end),
      capture_term_shell(function() search.replace('hello', 'world') end),
    }, '\n')

    T.contains(shell, 'sed -n')
    T.eq(shell:find('bat', 1, true), nil)

    vim.fn.chdir(prev_cwd)
    T.rmrf(dir)
  end)

  T.it('M.open / M.replace both wire include/exclude glob files into the rg reload command', function()
    local prev_cwd = vim.fn.getcwd()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/a.txt', { 'hello world' })
    vim.fn.chdir(dir)

    for _, fn in ipairs({
      function() search.open('hello') end,
      function() search.replace('hello', 'world') end,
    }) do
      local shell = capture_term_shell(fn)
      -- グロブは実行時に変わるので $(cat) で都度読み込む。set -f でパス名展開を止める
      T.contains(shell, 'set -f')
      T.contains(shell, '$(cat')
      -- グロブ変更を Lua 側から促すための reload バインド
      T.contains(shell, 'ctrl-]:reload')
    end

    vim.fn.chdir(prev_cwd)
    T.rmrf(dir)
  end)

  T.it('置換は Enter ではなく Ctrl-s / Ctrl-a（Enter はファイルを開く用のまま）', function()
    local prev_cwd = vim.fn.getcwd()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/a.txt', { 'hello world' })
    vim.fn.chdir(dir)

    local shell = capture_term_shell(function() search.open('hello') end)
    -- 印を一時ファイルへ書いてから accept し、Lua 側が置換する
    T.contains(shell, 'ctrl-s:transform')
    T.contains(shell, 'ctrl-x:transform')
    -- Ctrl-a は fzf 既定の行頭移動なので置換には使わない
    T.eq(shell:find('ctrl-a:', 1, true), nil)
    T.contains(shell, 'selected')
    T.contains(shell, '+accept')
    -- 置換欄が空(0バイト)なら transform が空アクションを返して何も起こらない
    T.contains(shell, 'test -s')
    -- Enter に置換を割り当てるバインドは無い（既定の accept のまま＝開く）
    T.eq(shell:find('enter:', 1, true), nil)
    -- 選択・クエリ取得のため multi と print-query が要る
    T.contains(shell, '--multi')
    T.contains(shell, '--print-query')

    vim.fn.chdir(prev_cwd)
    T.rmrf(dir)
  end)

  T.it('内容検索と置換は1つのピッカーに統合され、モード切替や欄トグルは fzf 側に無い', function()
    local prev_cwd = vim.fn.getcwd()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/a.txt', { 'hello world' })
    vim.fn.chdir(dir)

    local shell = table.concat({
      capture_term_shell(function() search.open('hello') end),
      capture_term_shell(function() search.replace('hello', 'world') end),
    }, '\n')

    -- 欄のトグル(Ctrl-r/Ctrl-g)と欄移動(Tab)は nvim 側のキーマップで扱う
    T.eq(shell:find('ctrl-r:', 1, true), nil)
    T.eq(shell:find('ctrl-g:', 1, true), nil)
    T.eq(shell:find('tab:', 1, true), nil)
    -- 置換対象の複数選択は Tab ではなく Ctrl-t
    T.contains(shell, 'ctrl-t:toggle')

    vim.fn.chdir(prev_cwd)
    T.rmrf(dir)
  end)

  --- 欄の表示状態だけを見たいので termopen はモックする（fzf は起動しない）
  local function with_stub_picker(fn)
    local orig_termopen = vim.fn.termopen
    local orig_executable = vim.fn.executable
    vim.fn.executable = function() return 1 end
    vim.fn.termopen = function() return 1234 end

    local ok, err = pcall(fn)

    vim.fn.termopen = orig_termopen
    vim.fn.executable = orig_executable
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= '' then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    if not ok then error(err, 0) end
  end

  local function float_titles()
    local titles = {}
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= '' then
        titles[#titles + 1] = T.win_title_text(w)
      end
    end
    return table.concat(titles, '\n')
  end

  T.it('既定では置換 / include / exclude の3欄がすべて出ている', function()
    local before = #vim.api.nvim_list_wins()
    with_stub_picker(function()
      search.open('hello')
      T.eq(#vim.api.nvim_list_wins() - before, 4, 'fzf窓 + 欄3つ')
      local titles = float_titles()
      T.contains(titles, 'replace')
      T.contains(titles, 'include')
      T.contains(titles, 'exclude')
    end)
  end)

  T.it('shown で置換欄 / 絞り込み欄(include+exclude)をそれぞれ隠せる', function()
    local before = #vim.api.nvim_list_wins()

    -- 置換欄だけ非表示
    with_stub_picker(function()
      search.open('hello', { shown = { replace = false } })
      T.eq(#vim.api.nvim_list_wins() - before, 3)
      local titles = float_titles()
      T.eq(titles:find('replace', 1, true), nil)
      T.contains(titles, 'include')
      T.contains(titles, 'exclude')
    end)

    -- include/exclude はまとめて非表示（VSCode の詳細検索トグル相当）
    with_stub_picker(function()
      search.open('hello', { shown = { globs = false } })
      T.eq(#vim.api.nvim_list_wins() - before, 2)
      local titles = float_titles()
      T.contains(titles, 'replace')
      T.eq(titles:find('include', 1, true), nil)
      T.eq(titles:find('exclude', 1, true), nil)
    end)
  end)
end)

--- fzf自体はptyが無いヘッドレスでは駆動できないが、その手前(rg出力行の解析・
--- 置換の実適用)は純粋なロジックなので直接呼んで検証する
T.describe('search pure logic (parse/replace, no fzf/pty needed)', function()
  T.it('open_match jumps to path:line:col from an rg --column match line, stripping ANSI codes', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/f.txt', { 'one', 'two needle', 'three' })
    local prev_cwd = vim.fn.getcwd()
    vim.fn.chdir(dir)
    vim.cmd('enew')

    search.open_match('\27[1mf.txt\27[0m:2:5:two needle')
    T.eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':t'), 'f.txt')
    T.eq(vim.api.nvim_win_get_cursor(0), { 2, 4 })

    vim.cmd('bwipeout!')
    vim.fn.chdir(prev_cwd)
    T.rmrf(dir)
  end)

  T.it('open_match falls back to column 1 for a path:line-only match (no column)', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/f.txt', { 'one', 'two' })
    local prev_cwd = vim.fn.getcwd()
    vim.fn.chdir(dir)
    vim.cmd('enew')

    search.open_match('f.txt:2:')
    T.eq(vim.api.nvim_win_get_cursor(0), { 2, 0 })

    vim.cmd('bwipeout!')
    vim.fn.chdir(prev_cwd)
    T.rmrf(dir)
  end)

  T.it('parse_path extracts the path from a match line, ignoring ANSI color codes', function()
    T.eq(search.parse_path('\27[1msrc/a.txt\27[0m:12:3:hello'), 'src/a.txt')
    T.eq(search.parse_path('src/a.txt:12:'), 'src/a.txt')
    T.eq(search.parse_path('not a match line'), nil)
  end)

  T.it('replace_literal replaces every literal (non-pattern) occurrence and reports the count', function()
    local out, count = search.replace_literal('foo.bar(foo, foo)', 'foo', 'baz')
    T.eq(out, 'baz.bar(baz, baz)')
    T.eq(count, 3)

    -- リテラル置換なので、Luaパターン文字は特殊文字として解釈されない
    out, count = search.replace_literal('a.b.c', '.', 'X')
    T.eq(out, 'aXbXc')
    T.eq(count, 2)

    out, count = search.replace_literal('nothing here', 'zzz', 'q')
    T.eq(out, 'nothing here')
    T.eq(count, 0)
  end)

  T.it('resolve_path passes through absolute paths and joins relative ones onto cwd', function()
    T.eq(search.resolve_path('/repo', 'src/a.txt'), '/repo/src/a.txt')
    T.eq(search.resolve_path('/repo', '/etc/hosts'), '/etc/hosts')
  end)

  T.it('build_glob_args turns comma-separated globs into rg --glob args (exclude prefixes !)', function()
    -- ワイルドカードを含むものはそのまま --glob へ。前後の空白は落とす
    T.eq(search.build_glob_args('*.lua, *.go', false), '--glob *.lua --glob *.go')
    -- スラッシュを含むパスもそのまま
    T.eq(search.build_glob_args('**/test/**', true), '--glob !**/test/**')
    T.eq(search.build_glob_args('src/foo.lua', false), '--glob src/foo.lua')
    -- 裸の名前（* ? / なし）は **/名前/** に展開。ドット始まりでも同様
    T.eq(search.build_glob_args('.github', false), '--glob **/.github/**')
    T.eq(search.build_glob_args('node_modules', true), '--glob !**/node_modules/**')
    -- exclude は先頭に ! を付ける（rg の除外グロブ表記）
    T.eq(search.build_glob_args('a, , b', true), '--glob !**/a/** --glob !**/b/**')
    -- 空・空要素は無視
    T.eq(search.build_glob_args('', false), '')
    T.eq(search.build_glob_args('  ,  ', false), '')
    T.eq(search.build_glob_args(nil, false), '')
  end)

  T.it('apply_replace_to_path rewrites an unopened file on disk and returns the replacement count', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/f.txt', { 'foo one', 'foo two' })

    local count = search.apply_replace_to_path(dir .. '/f.txt', 'foo', 'bar')
    T.eq(count, 2)
    T.eq(vim.fn.readfile(dir .. '/f.txt'), { 'bar one', 'bar two' })

    T.rmrf(dir)
  end)

  T.it('apply_replace_to_path rewrites an already-open buffer in place and writes it', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/f.txt', { 'foo one' })
    vim.cmd('edit ' .. dir .. '/f.txt')
    local bufnr = vim.api.nvim_get_current_buf()

    local count = search.apply_replace_to_path(dir .. '/f.txt', 'foo', 'bar')
    T.eq(count, 1)
    T.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'bar one' })
    T.eq(vim.bo[bufnr].modified, false, 'buffer should have been written to disk')
    T.eq(vim.fn.readfile(dir .. '/f.txt'), { 'bar one' }, 'the write should have reached disk too')

    vim.cmd('bwipeout!')
    T.rmrf(dir)
  end)

  T.it('apply_replace_to_path is a no-op (returns 0) on a binary file', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    -- vim.fn.writefileはNUL混じりの文字列をBlobとして扱ってしまい素の文字列
    -- リストと混在できないため、io.openで直接バイナリを書く
    local f = io.open(dir .. '/f.bin', 'wb')
    f:write('foo\0bar')
    f:close()

    local count = search.apply_replace_to_path(dir .. '/f.bin', 'foo', 'bar')
    T.eq(count, 0)

    T.rmrf(dir)
  end)

  T.it('rg_files_cmd asks rg for the matching file list with the same flags/globs as the picker', function()
    local cmd = search.rg_files_cmd('foo', '--glob *.lua', '--glob !**/node_modules/**')
    T.contains(cmd, '--files-with-matches')
    -- 検索欄と同じ条件（リテラル・smart-case・hidden・.git 除外）
    T.contains(cmd, '--fixed-strings')
    T.contains(cmd, '--smart-case')
    T.contains(cmd, '--hidden')
    T.contains(cmd, "--glob '!.git/*'")
    T.contains(cmd, '--glob *.lua')
    T.contains(cmd, '--glob !**/node_modules/**')
    -- グロブがパス名展開されないよう set -f、クエリは -- の後ろでクォート
    T.contains(cmd, 'set -f')
    T.contains(cmd, "-- 'foo'")
  end)

  T.it('match_files lists every file matching the query as an absolute path', function()
    if vim.fn.executable('rg') == 0 then
      print('  (skipped: rg not installed on this machine)')
      return
    end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. '/sub', 'p')
    T.write_file(dir .. '/a.txt', { 'foo here' })
    T.write_file(dir .. '/sub/b.txt', { 'foo there' })
    T.write_file(dir .. '/c.txt', { 'nothing' })

    local paths = search.match_files(dir, 'foo', '', '')
    table.sort(paths)
    T.eq(paths, { dir .. '/a.txt', dir .. '/sub/b.txt' })

    -- exclude グロブが効く
    local narrowed = search.match_files(dir, 'foo', '', '--glob !**/sub/**')
    T.eq(narrowed, { dir .. '/a.txt' })

    -- 空クエリは全置換の暴発になるので何も返さない
    T.eq(search.match_files(dir, '', '', ''), {})

    T.rmrf(dir)
  end)

  T.it('replace_paths applies the replacement to the given files and counts only the ones that changed', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/a.txt', { 'foo one', 'foo two' })
    T.write_file(dir .. '/b.txt', { 'no match here' })

    local file_count, replace_count = search.replace_paths(
      { dir .. '/a.txt', dir .. '/b.txt' }, 'foo', 'bar')

    T.eq(file_count, 1)
    T.eq(replace_count, 2)
    T.eq(vim.fn.readfile(dir .. '/a.txt'), { 'bar one', 'bar two' })
    T.eq(vim.fn.readfile(dir .. '/b.txt'), { 'no match here' })

    T.rmrf(dir)
  end)

  T.it('replace_selected applies the replacement across every distinct file among the selected match lines', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/a.txt', { 'foo in a' })
    T.write_file(dir .. '/b.txt', { 'foo in b', 'foo again' })
    T.write_file(dir .. '/c.txt', { 'untouched foo' }) -- 選択行に無いので変更されない

    local file_count, replace_count = search.replace_selected(dir, {
      'a.txt:1:1:foo in a',
      'b.txt:1:1:foo in b',
      'b.txt:2:1:foo again', -- 同じファイルが複数行にマッチしても1回だけ処理される
    }, 'foo', 'bar')

    T.eq(file_count, 2)
    T.eq(replace_count, 3)
    T.eq(vim.fn.readfile(dir .. '/a.txt'), { 'bar in a' })
    T.eq(vim.fn.readfile(dir .. '/b.txt'), { 'bar in b', 'bar again' })
    T.eq(vim.fn.readfile(dir .. '/c.txt'), { 'untouched foo' })

    T.rmrf(dir)
  end)
end)

T.summary()
