local T = dofile(TESTS_DIR .. '/helpers.lua')
local search = require('config.search')

-- 全トグル OFF（＝既定）の条件。検索側は rg のフラグ文字列、置換側は opts テーブルで渡す
local FLAGS_OFF = search.build_flag_args({})
local OPTS_OFF = { flags = FLAGS_OFF }

--- search.M.open()/M.replace() は fzf を使わず nvim のフロート窓で作った自作ピッカー。
--- ヘッドレスでも窓の生成・非同期検索の結果反映・プレビューは検証できる（rg があれば）。
--- ここでは依存チェック(rg 不在時の notify)、ネイティブ窓が開くこと、
--- 検索結果がリストとプレビューに載ることを確認する。
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

-- ピッカーを開いて fn(floats) に「今開いているフロート窓の情報」を渡し、後始末する。
-- floats は { {win=, buf=, title=, ft=}, ... }。title でどの窓か見分ける。
local function with_picker(open_fn, wait_ms, fn)
  local before = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do before[w] = true end
  open_fn()
  vim.wait(wait_ms or 800, function() return false end)
  local floats = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(w)
    if cfg.relative ~= '' then
      local buf = vim.api.nvim_win_get_buf(w)
      floats[#floats + 1] =
        { win = w, buf = buf, title = T.win_title_text(w), ft = vim.bo[buf].filetype,
          bt = vim.bo[buf].buftype }
    end
  end
  local ok, err = pcall(fn, floats)
  -- 後始末: 新しく開いた窓を閉じる
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if not before[w] then pcall(vim.api.nvim_win_close, w, true) end
  end
  if not ok then error(err, 0) end
end

local function find_float(floats, needle)
  for _, f in ipairs(floats) do
    if f.title:find(needle, 1, true) then return f end
  end
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

  T.it('M.open() no longer requires fzf (opens even when fzf is absent)', function()
    if vim.fn.executable('rg') == 0 then
      print('  (skipped: rg not installed)')
      return
    end
    local prev_cwd = vim.fn.getcwd()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    vim.fn.chdir(dir)
    local notified
    with_fake_executable('fzf', function()
      notified = capture_notify(function()
        with_picker(function() search.open('') end, 200, function(floats)
          T.ok(#floats > 0, 'native picker should open without fzf')
        end)
      end)
    end)
    T.ok(notified == nil, 'should not report any missing dependency for fzf')
    vim.fn.chdir(prev_cwd)
    T.rmrf(dir)
  end)

  T.it('M.replace() is gated by the same dependency check', function()
    local notified
    with_fake_executable('rg', function()
      notified = capture_notify(function() search.replace('x', 'y') end)
    end)
    T.ok(notified ~= nil, 'should notify')
    T.contains(notified.msg, 'rg')
  end)

  -- 欄・トグルの見た目だけ見たいテスト用。空クエリで開けば rg は走らない（launch_rg が即 return）。
  -- ensure_deps は rg を要求するので executable だけ 1 に差し替える。
  local function open_ui(state, fn)
    local orig = vim.fn.executable
    vim.fn.executable = function() return 1 end
    local before = {}
    for _, w in ipairs(vim.api.nvim_list_wins()) do before[w] = true end
    search.open('', state)
    local ok, err = pcall(fn)
    vim.fn.executable = orig
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if not before[w] and vim.api.nvim_win_get_config(w).relative ~= '' then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    if not ok then error(err, 0) end
  end

  -- 今開いているピッカーのフロート窓に載ったバッファのキーマップを引く
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

  T.it('M.open() は fzf ではなくネイティブのフロート窓を開き、端末は使わない', function()
    if vim.fn.executable('rg') == 0 then
      print('  (skipped: rg not installed)')
      return
    end
    local prev_cwd = vim.fn.getcwd()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    -- 200 行を超えたヒットも扱えることを一緒に確認する（今回の発端の不具合）
    local big = {}
    for i = 1, 300 do big[i] = 'line ' .. i end
    big[250] = 'hello at 250'
    T.write_file(dir .. '/big.txt', big)
    vim.fn.chdir(dir)

    with_picker(function() search.open('hello') end, 1500, function(floats)
      -- 端末バッファは無い
      for _, f in ipairs(floats) do
        T.eq(f.bt, 'nofile', 'ピッカーの窓に terminal buftype があってはいけない')
      end
      local results = find_float(floats, 'results:')
      local search_win = find_float(floats, 'search:')
      T.ok(results ~= nil, 'results 窓が要る')
      T.ok(search_win ~= nil, 'search(プロンプト)窓が要る')
      -- 結果に big.txt:250 が並ぶ
      local rlines = table.concat(vim.api.nvim_buf_get_lines(results.buf, 0, -1, false), '\n')
      T.contains(rlines, 'big.txt:250')
      -- プレビュー窓はヒットファイルを実バッファで載せ、200 行超でも全体が読める
      local preview = find_float(floats, 'big.txt:250')
      T.ok(preview ~= nil, 'プレビュー窓のタイトルにヒット位置(path:lnum)が出る')
      local plines = vim.api.nvim_buf_get_lines(preview.buf, 0, -1, false)
      T.ok(#plines >= 300, 'プレビューはファイル全体を持つ（200 行で切れない）')
      T.eq(plines[250], 'hello at 250', '250 行目のヒットがプレビューに載る')
    end)

    vim.fn.chdir(prev_cwd)
    T.rmrf(dir)
  end)

  T.it('結果リストは path / 行番号 / ヒット箇所 を別々の色で見せる', function()
    if vim.fn.executable('rg') == 0 then
      print('  (skipped: rg not installed)')
      return
    end
    local prev_cwd = vim.fn.getcwd()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/a.txt', { 'aaa hello bbb' })
    vim.fn.chdir(dir)

    with_picker(function() search.open('hello') end, 1500, function(floats)
      local results = find_float(floats, 'results:')
      T.ok(results ~= nil, 'results 窓が要る')
      local buf_lines = vim.api.nvim_buf_get_lines(results.buf, 0, -1, false)
      local ns = vim.api.nvim_get_namespaces()['search_results']
      T.ok(ns ~= nil, 'search_results namespace が要る')
      -- 下寄せで空行 pad が入るので行位置は固定しない。extmark の行から本文を引く。
      local by_group = {}
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(results.buf, ns, 0, -1, { details = true })) do
        by_group[m[4].hl_group] = (buf_lines[m[2] + 1] or ''):sub(m[3] + 1, m[4].end_col)
      end
      T.eq(by_group.SearchResultPath, 'a.txt', 'パス部分に専用の色')
      T.eq(by_group.SearchResultLine, '1', '行番号に専用の色')
      T.eq(by_group.SearchResultMatch, 'hello', 'ヒット箇所に専用の色')
    end)

    vim.fn.chdir(prev_cwd)
    T.rmrf(dir)
  end)

  T.it('結果は下寄せ＝最良マッチがプロンプト直上（最下段）に来る（旧 fzf 既定の向き）', function()
    if vim.fn.executable('rg') == 0 then
      print('  (skipped: rg not installed)')
      return
    end
    local prev_cwd = vim.fn.getcwd()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/a.txt', { 'hello A' })
    T.write_file(dir .. '/b.txt', { 'hello B' })
    vim.fn.chdir(dir)

    with_picker(function() search.open('hello') end, 1500, function(floats)
      local results = find_float(floats, 'results:')
      T.ok(results ~= nil, 'results 窓が要る')
      local lines = vim.api.nvim_buf_get_lines(results.buf, 0, -1, false)
      local cursor = vim.api.nvim_win_get_cursor(results.win)[1]
      T.eq(cursor, #lines, 'カーソル（最良マッチ）は最下段にある')
      T.eq(lines[1], '', '件数が窓より少なければ上を空行で詰めて下寄せする')
      T.ok(lines[#lines] ~= '', '最下段は実際の結果行（プロンプト直上）')
    end)

    vim.fn.chdir(prev_cwd)
    T.rmrf(dir)
  end)

  T.it('既定では置換 / include / exclude の3欄がすべて出ている', function()
    open_ui(nil, function()
      local titles = float_titles()
      T.contains(titles, 'replace')
      T.contains(titles, 'include')
      T.contains(titles, 'exclude')
      T.contains(titles, 'search:')  -- プロンプト
      T.contains(titles, 'results:') -- 結果リスト
    end)
  end)

  T.it('shown で置換欄 / 絞り込み欄(include+exclude)をそれぞれ隠せる', function()
    open_ui({ shown = { replace = false } }, function()
      local titles = float_titles()
      T.eq(titles:find('replace:', 1, true), nil)
      T.contains(titles, 'include')
      T.contains(titles, 'exclude')
    end)
    open_ui({ shown = { globs = false } }, function()
      local titles = float_titles()
      T.contains(titles, 'replace:')
      T.eq(titles:find('include:', 1, true), nil)
      T.eq(titles:find('exclude:', 1, true), nil)
    end)
  end)

  T.it('検索欄トグルは search 窓のタイトルに出て、ON のものだけ [] で囲まれる', function()
    open_ui(nil, function()
      local titles = float_titles()
      T.contains(titles, ' Aa ')
      T.contains(titles, ' ab ')
      T.contains(titles, ' .* ')
      T.eq(titles:find('[Aa]', 1, true), nil)
    end)
    open_ui({ toggles = { case = true, regex = true } }, function()
      local titles = float_titles()
      T.contains(titles, '[Aa]')
      T.contains(titles, ' ab ') -- word だけ OFF のまま
      T.contains(titles, '[.*]')
    end)
  end)

  T.it('Preserve Case(AB) は検索欄ではなく置換欄のタイトルに出る', function()
    open_ui(nil, function()
      local titles = float_titles()
      T.contains(titles, ' AB ') -- 既定 OFF
      T.eq(titles:find('[AB]', 1, true), nil)
    end)
    open_ui({ toggles = { preserve = true } }, function()
      T.contains(float_titles(), '[AB]')
    end)
  end)

  T.it('Alt-h でキー説明とプレースホルダをまとめて消せる', function()
    open_ui(nil, function()
      T.contains(float_footers(), 'Alt-h')
      T.contains(float_footers(), 'Ctrl-s') -- 置換欄フッタのキー説明

      local map = picker_keymap('i', '<M-h>')
      T.ok(map and map.callback, '<M-h> のコールバックが要る')
      map.callback()

      T.eq(float_footers(), '', 'どのフッタのキー説明も消えること')
      -- 欄そのものは残る（消えるのは説明だけ）
      T.contains(float_titles(), 'replace')
      T.contains(float_titles(), 'include')
    end)
  end)

  T.it('キー説明はタイトルではなくフッタに出す（ラベルとトグルはタイトル）', function()
    open_ui(nil, function()
      local titles = float_titles()
      T.contains(titles, 'replace:')
      T.contains(titles, ' AB ')
      T.eq(titles:find('Ctrl-s', 1, true), nil, 'タイトルにキー説明を混ぜない')

      -- 置換のキーと Alt-p は置換欄のフッタ側
      T.contains(float_footers(), 'Ctrl-s:replace selected')
      T.contains(float_footers(), 'Alt-p:PreserveCase')

      for _, w in ipairs(vim.api.nvim_list_wins()) do
        local cfg = vim.api.nvim_win_get_config(w)
        if cfg.relative ~= '' and cfg.footer then
          T.eq(cfg.footer_pos, 'center')
        end
      end
    end)
  end)

  T.it('検索欄トグルは Alt-c/w/r で、入力欄側(i と n)で押せる', function()
    open_ui(nil, function()
      for _, lhs in ipairs({ '<M-c>', '<M-w>', '<M-r>' }) do
        T.ok(picker_keymap('i', lhs) ~= nil, '入力欄(insert)に ' .. lhs .. ' が要る')
        T.ok(picker_keymap('n', lhs) ~= nil, '入力欄(normal)に ' .. lhs .. ' が要る')
      end
    end)
  end)

  T.it('トグルを押すとタイトルの表示が切り替わる', function()
    open_ui(nil, function()
      local map = picker_keymap('i', '<M-c>')
      T.ok(map and map.callback, '<M-c> のコールバックが要る')
      map.callback()
      T.contains(float_titles(), '[Aa]') -- OFF → ON で囲みが付く
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

T.describe('search native picker: rg command / preview render', function()
  T.it('rg_search_cmd は色なし・set -f 付き・limit を head で打ち切る', function()
    local cmd = search._private.rg_search_cmd(
      'foo', '--ignore-case --fixed-strings', '--glob *.lua', '', 2000)
    T.contains(cmd, 'set -f')                 -- glob をシェルに展開させない
    T.contains(cmd, '--column')
    T.contains(cmd, '--line-number')
    T.contains(cmd, '--color=never')          -- 色付けはプレビュー側でネイティブに行う
    T.contains(cmd, '--ignore-case --fixed-strings')
    T.contains(cmd, '--glob *.lua')
    T.contains(cmd, "-- 'foo'")               -- クエリは shellescape される
    T.contains(cmd, '| head -n 2001')         -- 超過検知のため +1 行多く取る
  end)

  T.it('rg_search_cmd は limit 未指定なら head を付けない', function()
    local cmd = search._private.rg_search_cmd('foo', '', '', '')
    T.eq(cmd:find('| head', 1, true), nil) -- --no-heading と紛れないよう `| head` で見る
  end)

  T.it('render_preview は実バッファを載せ、ヒット行にカーソルと Visual 強調を付ける', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local f = dir .. '/a.lua'
    -- 200 行超のヒットも扱えること（発端の不具合）
    local lines = {}
    for i = 1, 260 do lines[i] = 'local x' .. i .. ' = ' .. i end
    T.write_file(f, lines)

    local win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
      relative = 'editor', width = 40, height = 20, col = 0, row = 0,
      style = 'minimal', border = 'single', focusable = false,
    })

    local buf = search._private.render_preview(win, f, 250)
    T.ok(buf ~= nil, 'プレビューバッファが返る')
    local got = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    T.eq(#got, 260, 'ファイル全体を持つ（200 行で切れない）')
    T.eq(got[250], 'local x250 = 250')
    T.eq(vim.bo[buf].filetype, 'lua', 'ファイル名から filetype を判定する')
    T.eq(vim.api.nvim_win_get_cursor(win)[1], 250, 'カーソルはヒット行')

    -- ヒット行(0-based 249)に Visual の extmark が付く
    local ns = vim.api.nvim_get_namespaces()['search_preview']
    T.ok(ns ~= nil, 'search_preview namespace が要る')
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    local found = false
    for _, m in ipairs(marks) do
      if m[2] == 249 and m[4] and m[4].hl_group == 'Visual' then found = true end
    end
    T.ok(found, 'ヒット行に Visual の強調が付く')

    pcall(vim.api.nvim_win_close, win, true)
    T.rmrf(dir)
  end)

  T.it('render_preview は読めないパスに nil を返す', function()
    local win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
      relative = 'editor', width = 40, height = 20, col = 0, row = 0,
      style = 'minimal', border = 'single', focusable = false,
    })
    T.eq(search._private.render_preview(win, '/no/such/file.xyz', 1), nil)
    pcall(vim.api.nvim_win_close, win, true)
  end)
end)

T.summary()
