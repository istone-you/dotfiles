local T = dofile(TESTS_DIR .. '/helpers.lua')
local search = require('config.search')

-- 全トグル OFF（＝既定）の条件。検索側は rg のフラグ文字列、置換側は opts テーブルで渡す
local FLAGS_OFF = search.build_flag_args({})
local OPTS_OFF = { flags = FLAGS_OFF }

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
      -- 検索条件も同じく実行時に変わるので、rg のフラグはコマンドに直書きしない
      T.eq(shell:find('--smart-case', 1, true), nil)
      T.eq(shell:find('--fixed-strings', 1, true), nil)
      T.eq(shell:find('--ignore-case', 1, true), nil)
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

  --- 今開いているピッカーのキーマップを引く。キーはバッファローカルだが、閉じた
  --- ピッカーのバッファも残るので、フロート窓に載っているものだけを見る
  local function picker_keymap(mode, lhs)
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= '' then
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(vim.api.nvim_win_get_buf(w), mode)) do
          if map.lhs == lhs then return map end
        end
      end
    end
    return nil
  end

  --- フロートのフッタ（キー説明）をまとめて文字列で得る。title と同じチャンク形式
  local function float_footers()
    local out = {}
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local cfg = vim.api.nvim_win_get_config(w)
      if cfg.relative ~= '' and cfg.footer then
        for _, chunk in ipairs(cfg.footer) do out[#out + 1] = chunk[1] end
      end
    end
    return table.concat(out)
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

  T.it('検索欄トグルは fzf 窓のタイトルに出て、ON のものだけ [] で囲まれる', function()
    -- 既定は VSCode と同じく3つとも OFF（囲みなし）
    with_stub_picker(function()
      search.open('hello')
      local titles = float_titles()
      T.contains(titles, ' Aa ')
      T.contains(titles, ' ab ')
      T.contains(titles, ' .* ')
      T.eq(titles:find('[Aa]', 1, true), nil)
    end)

    -- state で復元でき、ON のものは [] 付きになる
    with_stub_picker(function()
      search.open('hello', { toggles = { case = true, regex = true } })
      local titles = float_titles()
      T.contains(titles, '[Aa]')
      T.contains(titles, ' ab ') -- word だけ OFF のまま
      T.contains(titles, '[.*]')
    end)
  end)

  T.it('Preserve Case(AB) は検索欄ではなく置換欄のタイトルに出る', function()
    with_stub_picker(function()
      search.open('hello')
      local titles = float_titles()
      T.contains(titles, ' AB ')            -- 既定 OFF
      T.eq(titles:find('[AB]', 1, true), nil)
    end)

    with_stub_picker(function()
      search.open('hello', { toggles = { preserve = true } })
      T.contains(float_titles(), '[AB]')
    end)
  end)

  T.it('Alt-h でキー説明とプレースホルダをまとめて消せる', function()
    with_stub_picker(function()
      search.open('hello')
      -- 既定では fzf 窓と置換欄のフッタにキー説明、include/exclude に薄い例示が出る
      T.contains(float_footers(), 'Alt-h')
      T.contains(float_footers(), 'Ctrl-t:select')

      local map = picker_keymap('t', '<M-h>')
      T.ok(map and map.callback, '<M-h> のコールバックが要る')
      map.callback()

      T.eq(float_footers(), '', 'どのフッタのキー説明も消えること')
      -- 欄そのものは残る（消えるのは説明だけ）
      T.contains(float_titles(), 'replace')
      T.contains(float_titles(), 'include')
    end)
  end)

  T.it('キー説明はタイトルではなく中央寄せのフッタに出す（ラベルとトグルはタイトル）', function()
    with_stub_picker(function()
      search.open('hello')
      -- タイトルはラベルとトグルだけ。キー説明は入れない
      local titles = float_titles()
      T.contains(titles, 'replace:')
      T.contains(titles, ' AB ')
      T.eq(titles:find('Ctrl-t', 1, true), nil, 'タイトルにキー説明を混ぜない')
      T.eq(titles:find('(', 1, true), nil, 'キー説明の括弧も残さない')

      -- 置換のキーと Alt-p は置換欄のフッタ側
      T.contains(float_footers(), 'Ctrl-s:replace selected')
      T.contains(float_footers(), 'Alt-p:PreserveCase')

      -- フッタはすべて中央寄せ
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        local cfg = vim.api.nvim_win_get_config(w)
        if cfg.relative ~= '' and cfg.footer then
          T.eq(cfg.footer_pos, 'center')
        end
      end
    end)
  end)

  T.it('キー説明は fzf の --header ではなく nvim 側のフッタで出す', function()
    local prev_cwd = vim.fn.getcwd()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/a.txt', { 'hello world' })
    vim.fn.chdir(dir)

    -- fzf の --header は起動時に固定されるので使わない（Alt-h で即座に消せなくなる）
    local shell = capture_term_shell(function() search.open('hello') end)
    T.eq(shell:find('--header', 1, true), nil)

    vim.fn.chdir(prev_cwd)
    T.rmrf(dir)
  end)

  T.it('検索欄トグルは Alt-c/w/r で、欄側でも fzf(ターミナル)側でも押せる', function()
    with_stub_picker(function()
      search.open('hello')

      for _, lhs in ipairs({ '<M-c>', '<M-w>', '<M-r>' }) do
        T.ok(picker_keymap('t', lhs) ~= nil, 'fzf(ターミナル)側に ' .. lhs .. ' が要る')
        T.ok(picker_keymap('i', lhs) ~= nil, '入力欄側に ' .. lhs .. ' が要る')
      end
    end)
  end)

  T.it('トグルを押すとタイトルの表示が切り替わる', function()
    with_stub_picker(function()
      search.open('hello')

      -- fzf(ターミナル)側の <M-c> を実際に叩く。ターミナルモードのまま fzf 窓の
      -- 設定を触るので、ここが落ちないことも含めて確認する
      local map = picker_keymap('t', '<M-c>')
      T.ok(map and map.callback, '<M-c> のコールバックが要る')
      map.callback()

      -- OFF → ON で囲みが付く
      T.contains(float_titles(), '[Aa]')
    end)
  end)
end)

--- 末尾改行の有無まで見たいので、readfile()を通さず生バイトで読む
local function read_raw(path)
  local f = assert(io.open(path, 'rb'))
  local data = f:read('*a')
  f:close()
  return data
end

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

  T.it('parse_match also returns the line number (置換の選択粒度が行なので要る)', function()
    local path, lnum = search.parse_match('\27[1msrc/a.txt\27[0m:12:3:hello')
    T.eq(path, 'src/a.txt')
    T.eq(lnum, 12)

    path, lnum = search.parse_match('src/a.txt:7:')
    T.eq(path, 'src/a.txt')
    T.eq(lnum, 7)

    T.eq(search.parse_match('not a match line'), nil)
  end)

  T.it('build_flag_args maps the VSCode toggles (Aa / ab / .*) onto rg flags', function()
    -- 既定は VSCode と同じく3つとも OFF ＝ 大小無視のリテラル検索（smart-case ではない）
    T.eq(search.build_flag_args({}), '--ignore-case --fixed-strings')
    T.eq(search.build_flag_args(nil), '--ignore-case --fixed-strings')

    T.eq(search.build_flag_args({ case = true }), '--case-sensitive --fixed-strings')
    T.eq(search.build_flag_args({ word = true }), '--ignore-case --word-regexp --fixed-strings')
    -- regex ON は --fixed-strings を外すだけ（rg の既定が正規表現）
    T.eq(search.build_flag_args({ regex = true }), '--ignore-case')
    T.eq(search.build_flag_args({ case = true, word = true, regex = true }),
      '--case-sensitive --word-regexp')
  end)

  T.it('rg_replace_cmd escapes $ in the replacement unless regex is on', function()
    -- rg の --replace は -F でも $1 を後方参照として解釈するので、regex OFF では逃がす
    local literal = search.rg_replace_cmd('foo', 'a$1b', FLAGS_OFF)
    T.contains(literal, [['a$$1b']])
    -- regex ON のときは後方参照として使いたいのでそのまま渡す
    local regex = search.rg_replace_cmd('foo', 'a$1b', search.build_flag_args({ regex = true }))
    T.contains(regex, [['a$1b']])
    T.eq(regex:find('$$1', 1, true), nil)
    T.contains(regex, '--passthru')
  end)

  T.it('rg_replace_lines replaces through rg, honouring each toggle', function()
    if vim.fn.executable('rg') == 0 then
      print('  (skipped: rg not installed on this machine)')
      return
    end
    local lines = { 'foo Foo bar', 'foobar' }

    -- 既定(全OFF): 大小無視のリテラル置換
    local out, count = search.rg_replace_lines(lines, 'foo', 'X', OPTS_OFF)
    T.eq(out, { 'X X bar', 'Xbar' })
    T.eq(count, 3)

    -- match case ON: 小文字の foo だけ
    out, count = search.rg_replace_lines(lines, 'foo', 'X', { flags = search.build_flag_args({ case = true }) })
    T.eq(out, { 'X Foo bar', 'Xbar' })
    T.eq(count, 2)

    -- whole word ON: 語中の foobar は対象外
    out, count = search.rg_replace_lines(lines, 'foo', 'X', { flags = search.build_flag_args({ word = true }) })
    T.eq(out, { 'X X bar', 'foobar' })
    T.eq(count, 2)

    -- regex OFF ではメタ文字はリテラル。'.' は本物のドットだけに当たる
    out, count = search.rg_replace_lines({ 'a.b.c' }, '.', 'X', OPTS_OFF)
    T.eq(out, { 'aXbXc' })
    T.eq(count, 2)

    -- regex ON: パターンと $1 の後方参照が効く
    out, count = search.rg_replace_lines(
      { 'a1 b2' }, '([a-z])([0-9])', '$2$1', { flags = search.build_flag_args({ regex = true }) })
    T.eq(out, { '1a 2b' })
    T.eq(count, 2)
  end)

  T.it('preserve_case matches the replacement to how the hit was written', function()
    -- 全小文字 → 小文字、全大文字 → 大文字、先頭だけ大文字 → 先頭だけ大文字
    T.eq(search.preserve_case('foo', 'Bar'), 'bar')
    T.eq(search.preserve_case('FOO', 'bar'), 'BAR')
    T.eq(search.preserve_case('Foo', 'bar'), 'Bar')
    T.eq(search.preserve_case('Foo', 'BAR'), 'Bar')
    -- 1文字は「全大文字」として扱う（VSCode と同じ）
    T.eq(search.preserve_case('F', 'bar'), 'BAR')
    -- どの型にも当てはまらない書き方は置換文字列をそのまま使う
    T.eq(search.preserve_case('fooBar', 'baz Qux'), 'baz Qux')
    T.eq(search.preserve_case('', 'bar'), 'bar')
    T.eq(search.preserve_case('foo', ''), '')
  end)

  T.it('preserve=true で置換文字列がマッチの大小に寄る（VSCode の AB）', function()
    if vim.fn.executable('rg') == 0 then
      print('  (skipped: rg not installed on this machine)')
      return
    end
    local lines = { 'foo Foo FOO fooBar' }
    local on = { flags = FLAGS_OFF, preserve = true }

    local out, count = search.rg_replace_lines(lines, 'foo', 'bar', on)
    -- 4件目は fooBar の foo にマッチ（小文字）なので小文字のまま入る
    T.eq(out, { 'bar Bar BAR barBar' })
    T.eq(count, 4)

    -- OFF なら入力どおり
    out = search.rg_replace_lines(lines, 'foo', 'bar', OPTS_OFF)
    T.eq(out, { 'bar bar bar barBar' })

    -- 番兵は残さない
    T.eq(out[1]:find('\1', 1, true), nil)
    T.eq(out[1]:find('\2', 1, true), nil)
  end)

  T.it('preserve は正規表現の $1 展開と併用できる', function()
    if vim.fn.executable('rg') == 0 then
      print('  (skipped: rg not installed on this machine)')
      return
    end
    local on = { flags = search.build_flag_args({ regex = true }), preserve = true }
    -- 後方参照は rg 側で展開され、そのあと大小がマッチに寄せられる
    local out, count = search.rg_replace_lines({ 'ab AB' }, '(a)(b)', '$2$1', on)
    T.eq(out, { 'ba BA' })
    T.eq(count, 2)
  end)

  T.it('本文に番兵の制御文字が居るときは preserve を諦めて素の置換にする', function()
    if vim.fn.executable('rg') == 0 then
      print('  (skipped: rg not installed on this machine)')
      return
    end
    local lines = { 'foo \1 Foo' }
    local out, count = search.rg_replace_lines(
      lines, 'foo', 'bar', { flags = FLAGS_OFF, preserve = true })
    -- 大小は寄らないが、置換自体は正しく行われ、本文の制御文字も壊さない
    T.eq(out, { 'bar \1 bar' })
    T.eq(count, 2)
  end)

  T.it('rg_replace_lines is a no-op on no match, empty query, or a broken regex', function()
    if vim.fn.executable('rg') == 0 then
      print('  (skipped: rg not installed on this machine)')
      return
    end
    local lines = { 'nothing here' }
    local opts = OPTS_OFF

    local out, count = search.rg_replace_lines(lines, 'zzz', 'q', opts)
    T.eq(out, lines)
    T.eq(count, 0)

    out, count = search.rg_replace_lines(lines, '', 'q', opts)
    T.eq(out, lines)
    T.eq(count, 0)

    -- 壊れた正規表現は rg が exit 2 で落ちる。数える段で弾いて本文には触らない
    out, count = search.rg_replace_lines(lines, '(', 'q', { flags = search.build_flag_args({ regex = true }) })
    T.eq(out, lines)
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

    local count = search.apply_replace_to_path(
      dir .. '/f.txt', 'foo', 'bar', OPTS_OFF)
    T.eq(count, 2)
    T.eq(vim.fn.readfile(dir .. '/f.txt'), { 'bar one', 'bar two' })

    T.rmrf(dir)
  end)

  T.it('apply_replace_to_path keeps the file\'s trailing-newline convention', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local opts = OPTS_OFF

    -- 末尾改行あり
    local with_nl = dir .. '/with.txt'
    local f = io.open(with_nl, 'wb')
    f:write('foo one\nfoo two\n')
    f:close()
    T.eq(search.apply_replace_to_path(with_nl, 'foo', 'bar', opts), 2)
    T.eq(read_raw(with_nl), 'bar one\nbar two\n')

    -- 末尾改行なし。rg は行単位で出すので改行を足しがちだが、元の形を保つ
    local without_nl = dir .. '/without.txt'
    f = io.open(without_nl, 'wb')
    f:write('foo one\nfoo two')
    f:close()
    T.eq(search.apply_replace_to_path(without_nl, 'foo', 'bar', opts), 2)
    T.eq(read_raw(without_nl), 'bar one\nbar two')

    T.rmrf(dir)
  end)

  T.it('apply_replace_to_path rewrites an already-open buffer in place and writes it', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/f.txt', { 'foo one' })
    vim.cmd('edit ' .. dir .. '/f.txt')
    local bufnr = vim.api.nvim_get_current_buf()

    local count = search.apply_replace_to_path(
      dir .. '/f.txt', 'foo', 'bar', OPTS_OFF)
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

    local count = search.apply_replace_to_path(
      dir .. '/f.bin', 'foo', 'bar', OPTS_OFF)
    T.eq(count, 0)

    T.rmrf(dir)
  end)

  T.it('rg_files_cmd asks rg for the matching file list with the same flags/globs as the picker', function()
    local cmd = search.rg_files_cmd(
      'foo', '--glob *.lua', '--glob !**/node_modules/**', FLAGS_OFF)
    T.contains(cmd, '--files-with-matches')
    -- 検索欄と同じ条件（トグル由来のフラグ・hidden・.git 除外）
    T.contains(cmd, '--fixed-strings')
    T.contains(cmd, '--ignore-case')
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

    local flags = FLAGS_OFF
    local paths = search.match_files(dir, 'foo', '', '', flags)
    table.sort(paths)
    T.eq(paths, { dir .. '/a.txt', dir .. '/sub/b.txt' })

    -- exclude グロブが効く
    local narrowed = search.match_files(dir, 'foo', '', '--glob !**/sub/**', flags)
    T.eq(narrowed, { dir .. '/a.txt' })

    -- 空クエリは全置換の暴発になるので何も返さない
    T.eq(search.match_files(dir, '', '', '', flags), {})

    T.rmrf(dir)
  end)

  T.it('replace_paths applies the replacement to the given files and counts only the ones that changed', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/a.txt', { 'foo one', 'foo two' })
    T.write_file(dir .. '/b.txt', { 'no match here' })

    local file_count, replace_count = search.replace_paths(
      { dir .. '/a.txt', dir .. '/b.txt' }, 'foo', 'bar', OPTS_OFF)

    T.eq(file_count, 1)
    T.eq(replace_count, 2)
    T.eq(vim.fn.readfile(dir .. '/a.txt'), { 'bar one', 'bar two' })
    T.eq(vim.fn.readfile(dir .. '/b.txt'), { 'no match here' })

    T.rmrf(dir)
  end)

  T.it('rg_replace_at_lnums touches only the given lines', function()
    if vim.fn.executable('rg') == 0 then
      print('  (skipped: rg not installed on this machine)')
      return
    end
    local lines = { 'foo one', 'foo two', 'foo three' }
    local opts = OPTS_OFF

    local out, count = search.rg_replace_at_lnums(lines, { 1, 3 }, 'foo', 'bar', opts)
    T.eq(out, { 'bar one', 'foo two', 'bar three' })
    T.eq(count, 2)

    -- 1行に複数マッチがあれば、その行のぶんはまとめて置換される（rg の行は1件なので）
    out, count = search.rg_replace_at_lnums({ 'foo and foo', 'foo' }, { 1 }, 'foo', 'X', opts)
    T.eq(out, { 'X and X', 'foo' })
    T.eq(count, 2)

    -- 範囲外・マッチしない行を指しても何もしない
    out, count = search.rg_replace_at_lnums(lines, { 99 }, 'foo', 'bar', opts)
    T.eq(out, lines)
    T.eq(count, 0)
  end)

  T.it('replace_selected replaces only the selected lines, not the whole file', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/a.txt', { 'foo in a' })
    T.write_file(dir .. '/b.txt', { 'foo in b', 'foo again', 'foo unselected' })
    T.write_file(dir .. '/c.txt', { 'untouched foo' }) -- 選択行に無いので変更されない

    local file_count, replace_count = search.replace_selected(dir, {
      'a.txt:1:1:foo in a',
      'b.txt:1:1:foo in b',
      'b.txt:2:1:foo again',
      'b.txt:2:1:foo again', -- 同じ行が二重に来ても1回だけ数える
    }, 'foo', 'bar', OPTS_OFF)

    T.eq(file_count, 2)
    T.eq(replace_count, 3)
    T.eq(vim.fn.readfile(dir .. '/a.txt'), { 'bar in a' })
    -- 3行目は選んでいないので、同じファイル内でも残る（これが Ctrl-x との違い）
    T.eq(vim.fn.readfile(dir .. '/b.txt'), { 'bar in b', 'bar again', 'foo unselected' })
    T.eq(vim.fn.readfile(dir .. '/c.txt'), { 'untouched foo' })

    T.rmrf(dir)
  end)

  T.it('replace_selected と replace_paths(Ctrl-x) で同じファイルへの効き方が変わる', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local opts = OPTS_OFF

    -- Ctrl-s: 選んだ1行だけ
    T.write_file(dir .. '/sel.txt', { 'foo 1', 'foo 2' })
    local _, sel_count = search.replace_selected(
      dir, { 'sel.txt:1:1:foo 1' }, 'foo', 'bar', opts)
    T.eq(sel_count, 1)
    T.eq(vim.fn.readfile(dir .. '/sel.txt'), { 'bar 1', 'foo 2' })

    -- Ctrl-x: ファイル丸ごと
    T.write_file(dir .. '/all.txt', { 'foo 1', 'foo 2' })
    local _, all_count = search.replace_paths({ dir .. '/all.txt' }, 'foo', 'bar', opts)
    T.eq(all_count, 2)
    T.eq(vim.fn.readfile(dir .. '/all.txt'), { 'bar 1', 'bar 2' })

    T.rmrf(dir)
  end)

  T.it('選択置換は開いているバッファにも行単位で効く', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/f.txt', { 'foo one', 'foo two' })
    vim.cmd('edit ' .. dir .. '/f.txt')
    local bufnr = vim.api.nvim_get_current_buf()

    local file_count, replace_count = search.replace_selected(
      dir, { 'f.txt:2:1:foo two' }, 'foo', 'bar', OPTS_OFF)

    T.eq(file_count, 1)
    T.eq(replace_count, 1)
    T.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'foo one', 'bar two' })
    T.eq(vim.bo[bufnr].modified, false, 'buffer should have been written to disk')

    vim.cmd('bwipeout!')
    T.rmrf(dir)
  end)
end)

T.summary()
