-- tests/notes_web_spec.lua
local T = dofile(TESTS_DIR .. '/helpers.lua')
local notes = require('config.notes')
local web = require('config.notes_web')

-- パス比較を安定させるため normalize してから使う（.config/CLAUDE.md のパス方針）
local function tmpdir()
  local dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(dir, 'p')
  return dir
end

--- notes.dir() / notes.html_dir() を tmp に差し替えて fn を走らせる（実ディレクトリを汚さない）
local function with_dir(dir, fn, html)
  local orig, orig_html = notes.dir, notes.html_dir
  notes.dir = function() return dir end
  notes.html_dir = function() return html or (dir .. '/__nohtml') end
  local ok, err = pcall(fn)
  notes.dir, notes.html_dir = orig, orig_html
  if not ok then error(err, 0) end
end

T.describe('notes_web.title_from_lines', function()
  T.it('先頭の非空行を見出しにし、# は外す', function()
    T.eq(web.title_from_lines({ '', '# 買い物リスト', '牛乳' }, 'x.md'), '買い物リスト')
    T.eq(web.title_from_lines({ 'ただの本文' }, 'x.md'), 'ただの本文')
  end)

  T.it('空ファイルはファイル名（.md 抜き）で代替する', function()
    T.eq(web.title_from_lines({}, '20260101-000001.md'), '20260101-000001')
    T.eq(web.title_from_lines({ '', '   ' }, '20260101-000001.md'), '20260101-000001')
  end)
end)

T.describe('notes_web.valid_name', function()
  T.it('notes/ 直下の *.md だけ受け付ける', function()
    T.eq(web.valid_name('20260101-000001.md'), true)
    T.eq(web.valid_name('memo.txt'), false)
    T.eq(web.valid_name('sub/memo.md'), false)
    T.eq(web.valid_name('../secret.md'), false)
    T.eq(web.valid_name(''), false)
    T.eq(web.valid_name(nil), false)
  end)
end)

T.describe('notes_web.list_notes', function()
  T.it('*.md を更新の新しい順に、見出し付きで返す', function()
    local dir = tmpdir()
    vim.fn.writefile({ '# old memo' }, dir .. '/20260101-000001.md')
    vim.fn.writefile({ '# new memo' }, dir .. '/20260101-000002.md')
    vim.fn.writefile({ 'not markdown' }, dir .. '/note.txt')
    -- mtime を明示して並び順を決める（同秒だと名前順に落ちるため）
    vim.fn.system({ 'touch', '-t', '202601010000', dir .. '/20260101-000001.md' })
    vim.fn.system({ 'touch', '-t', '202601020000', dir .. '/20260101-000002.md' })

    local list = web.list_notes(dir)
    T.eq(#list, 2, '*.md 以外は含めない')
    T.eq(list[1].name, '20260101-000002.md')
    T.eq(list[1].title, 'new memo')
    T.eq(list[2].title, 'old memo')
  end)

  T.it('ディレクトリが無ければ空', function()
    T.eq(web.list_notes(tmpdir() .. '/missing'), {})
  end)
end)

T.describe('notes_web.version', function()
  T.it('中身が変わると印も変わる（ブラウザの再読込トリガ）', function()
    local dir = tmpdir()
    vim.fn.writefile({ '# a' }, dir .. '/a.md')
    local before = web.version(dir)
    vim.fn.writefile({ '# a', '追記' }, dir .. '/a.md')
    T.ok(web.version(dir) ~= before, '書き換えで印が変わること')

    local with_new_file = web.version(dir)
    vim.fn.writefile({ '# b' }, dir .. '/b.md')
    T.ok(web.version(dir) ~= with_new_file, 'ファイル追加で印が変わること')
  end)

  T.it('メモが無いディレクトリは empty', function()
    T.eq(web.version(tmpdir()), 'empty')
  end)
end)

T.describe('notes_web.html_title_from_lines', function()
  T.it('<title> → <h1> → ファイル名 の順で拾う', function()
    T.eq(web.html_title_from_lines({ '<html><head><title>売上レポート</title></head>' }, 'a.html'), '売上レポート')
    T.eq(web.html_title_from_lines({ '<body>', '<h1>見出し <span>だけ</span></h1>' }, 'a.html'), '見出し だけ')
    T.eq(web.html_title_from_lines({ '<div>本文</div>' }, 'report.html'), 'report')
    T.eq(web.html_title_from_lines({ '<title>  </title>', '<h1>H</h1>' }, 'a.html'), 'H', '空タイトルは次へ')
  end)
end)

T.describe('notes_web.list_html', function()
  T.it('*.html を更新の新しい順に、タイトル付きで返す', function()
    local dir = tmpdir()
    vim.fn.writefile({ '<title>古い</title>' }, dir .. '/old.html')
    vim.fn.writefile({ '<title>新しい</title>' }, dir .. '/new.html')
    vim.fn.writefile({ '# md' }, dir .. '/memo.md')
    vim.fn.system({ 'touch', '-t', '202601010000', dir .. '/old.html' })
    vim.fn.system({ 'touch', '-t', '202601020000', dir .. '/new.html' })

    local list = web.list_html(dir)
    T.eq(#list, 2, 'html 以外は含めない')
    T.eq(list[1].title, '新しい')
    T.eq(list[2].title, '古い')
  end)
end)

T.describe('notes_web.version', function()
  T.it('html 側の変化も同じ印に混ぜる（両ページが 1 本の /__version を見る）', function()
    local md = tmpdir()
    local html = tmpdir()
    vim.fn.writefile({ '# a' }, md .. '/a.md')
    local before = web.version(md, html)
    vim.fn.writefile({ '<title>x</title>' }, html .. '/x.html')
    T.ok(web.version(md, html) ~= before, 'html 追加で印が変わること')
  end)
end)

T.describe('notes_web.note_payload', function()
  T.it('1 件のメモを見出し + レンダリング済み HTML で返す', function()
    local dir = tmpdir()
    vim.fn.writefile({ '# タイトル', '', '本文 **強調**' }, dir .. '/a.md')
    local payload = web.note_payload(dir, 'a.md')
    T.eq(payload.name, 'a.md')
    T.eq(payload.title, 'タイトル')
    T.contains(payload.html, '<h1 id="タイトル">タイトル</h1>')
    T.contains(payload.html, '<strong>強調</strong>')
  end)

  T.it('名前が不正 / 見つからない場合はエラーを返す', function()
    local dir = tmpdir()
    local ok, err = web.note_payload(dir, '../secret.md')
    T.eq(ok, nil)
    T.contains(err, 'invalid')

    ok, err = web.note_payload(dir, 'missing.md')
    T.eq(ok, nil)
    T.eq(err, 'note not found')
  end)
end)

T.describe('notes_web.response_for_request', function()
  T.it('/ は一覧ページ（本文スタイルは markdown プレビューと共有）', function()
    local dir = tmpdir()
    with_dir(dir, function()
      local res = web.response_for_request({ method = 'GET', path = '/', query = '' })
      T.contains(res, 'HTTP/1.1 200 OK')
      T.contains(res, 'Content-Type: text/html')
      T.contains(res, '<title>Notes</title>')
      T.contains(res, 'id="list"')
      T.contains(res, '/api/note?name=')
      T.contains(res, 'width:100%', 'CSS の % が gsub で壊れていないこと')
      T.contains(res, 'href="/html"', 'html 一覧への導線があること')
    end)
  end)

  T.it('/html は html 一覧ページ（行は /html/<name> へのリンク）', function()
    local md, html = tmpdir(), tmpdir()
    vim.fn.writefile({ '<title>売上 レポート</title>' }, html .. '/report file.html')
    with_dir(md, function()
      local res = web.build_response({ method = 'GET', path = '/html', query = '' })
      T.contains(res, 'HTTP/1.1 200 OK')
      T.contains(res, 'Content-Type: text/html')
      T.contains(res, '売上 レポート')
      T.contains(res, 'href="/html/report%20file.html"', 'ファイル名はURLエンコードする')
      T.contains(res, 'href="/"', 'メモ一覧へ戻る導線があること')

      local slash = web.build_response({ method = 'GET', path = '/html/', query = '' })
      T.contains(slash, 'HTTP/1.1 200 OK')
    end, html)
  end)

  T.it('/html は html が無ければ空表示', function()
    local md, html = tmpdir(), tmpdir()
    with_dir(md, function()
      T.contains(web.build_response({ method = 'GET', path = '/html', query = '' }), 'html はありません')
    end, html)
  end)

  T.it('/html/<name> は html をそのまま返し、root の外は弾く', function()
    local md, html = tmpdir(), tmpdir()
    vim.fn.writefile({ '<h1>そのまま</h1><script>alert(1)</script>' }, html .. '/a.html')
    with_dir(md, function()
      local res = web.build_response({ method = 'GET', path = '/html/a.html', query = '' })
      T.contains(res, 'HTTP/1.1 200 OK')
      T.contains(res, 'Content-Type: text/html')
      T.contains(res, '<script>alert(1)</script>', 'サニタイズせず素で返すこと')

      local blocked = web.build_response({ method = 'GET', path = '/html/../secret.html', query = '' })
      T.contains(blocked, 'HTTP/1.1 403 Forbidden')
      local missing = web.build_response({ method = 'GET', path = '/html/none.html', query = '' })
      T.contains(missing, 'HTTP/1.1 404 Not Found')
    end, html)
  end)

  T.it('/api/notes は一覧 JSON', function()
    local dir = tmpdir()
    vim.fn.writefile({ '# alpha' }, dir .. '/a.md')
    with_dir(dir, function()
      local res = web.response_for_request({ method = 'GET', path = '/api/notes', query = '' })
      T.contains(res, 'HTTP/1.1 200 OK')
      T.contains(res, 'application/json')
      local body = res:match('\r\n\r\n(.*)$')
      local data = vim.json.decode(body)
      T.eq(#data.notes, 1)
      T.eq(data.notes[1].title, 'alpha')
      T.ok(data.version ~= nil, 'version を返すこと')
    end)
  end)

  T.it('/api/note?name= は選んだメモの HTML', function()
    local dir = tmpdir()
    vim.fn.writefile({ '# alpha', '', 'body' }, dir .. '/a.md')
    with_dir(dir, function()
      local res = web.response_for_request({ method = 'GET', path = '/api/note', query = 'name=a.md' })
      T.contains(res, 'HTTP/1.1 200 OK')
      local data = vim.json.decode(res:match('\r\n\r\n(.*)$'))
      T.eq(data.title, 'alpha')
      T.contains(data.html, '<p>body</p>')

      local missing = web.response_for_request({ method = 'GET', path = '/api/note', query = 'name=none.md' })
      T.contains(missing, 'HTTP/1.1 404 Not Found')
      local bad = web.response_for_request({ method = 'GET', path = '/api/note', query = 'name=..%2Fsecret.md' })
      T.contains(bad, 'HTTP/1.1 400 Bad Request')
    end)
  end)

  T.it('/__version は notes/ の印', function()
    local dir = tmpdir()
    vim.fn.writefile({ '# a' }, dir .. '/a.md')
    with_dir(dir, function()
      local res = web.response_for_request({ method = 'GET', path = '/__version', query = '' })
      T.contains(res, 'HTTP/1.1 200 OK')
      T.eq(res:match('\r\n\r\n(.*)$'), web.version(dir))
    end)
  end)

  T.it('/__asset は notes/ を root に配り、外へは出さない', function()
    local dir = tmpdir()
    vim.fn.mkdir(dir .. '/images', 'p')
    vim.fn.writefile({ 'fakepng' }, dir .. '/images/logo.png', 'b')
    with_dir(dir, function()
      local ok_res = web.response_for_request({ method = 'GET', path = '/__asset/images/logo.png', query = '' })
      T.contains(ok_res, 'HTTP/1.1 200 OK')
      T.contains(ok_res, 'image/png')
      T.contains(ok_res, 'fakepng')

      local blocked = web.response_for_request({ method = 'GET', path = '/__asset/../secret.png', query = '' })
      T.contains(blocked, 'HTTP/1.1 403 Forbidden')
    end)
  end)

  T.it('同梱アセットはホワイトリストのみ、未知のパスは 404', function()
    with_dir(tmpdir(), function()
      local vendor = web.response_for_request({ method = 'GET', path = '/__vendor/highlight.min.js', query = '' })
      T.contains(vendor, 'HTTP/1.1 200 OK')
      local other = web.response_for_request({ method = 'GET', path = '/__vendor/evil.js', query = '' })
      T.contains(other, 'HTTP/1.1 404 Not Found')
      local unknown = web.response_for_request({ method = 'GET', path = '/nope', query = '' })
      T.contains(unknown, 'HTTP/1.1 404 Not Found')
    end)
  end)
end)

--- 実 TCP でリクエストを投げる。ハンドラは libuv のコールバック（fast event context）で走るため、
--- response_for_request を直接呼ぶテストでは readdir / readfile の呼び出し制限を踏めない。
local function tcp_request(port, raw, cb)
  local uv = vim.uv or vim.loop
  local client = uv.new_tcp()
  local chunks = {}
  client:connect('127.0.0.1', port, function(err)
    if err then cb(nil, err); return end
    client:read_start(function(read_err, chunk)
      if read_err then cb(nil, read_err); return end
      if chunk then
        chunks[#chunks + 1] = chunk
      else
        pcall(function() client:close() end)
        cb(table.concat(chunks))
      end
    end)
    client:write(raw)
  end)
end

local function tcp_get(port, target)
  local done, raw = false, nil
  tcp_request(port, table.concat({
    'GET ' .. target .. ' HTTP/1.1', 'Host: 127.0.0.1', '', '',
  }, '\r\n'), function(resp) raw = resp; done = true end)
  T.ok(vim.wait(2000, function() return done end), 'tcp response should arrive: ' .. target)
  return raw or ''
end

T.describe('notes_web: 実 TCP 経由', function()
  T.it('一覧と本文を配る（fast event context から readdir / readfile を呼ばない）', function()
    local dir = tmpdir()
    vim.fn.writefile({ '# alpha', '', '本文' }, dir .. '/a.md')
    with_dir(dir, function()
      local port
      for p = 28810, 28900 do
        if web.start(p) then port = p; break end
      end
      T.ok(port, 'server should start on some port')

      local ok, err = pcall(function()
        local list = tcp_get(port, '/api/notes')
        T.contains(list, 'HTTP/1.1 200 OK')
        T.eq(#vim.json.decode(list:match('\r\n\r\n(.*)$')).notes, 1)

        local note = tcp_get(port, '/api/note?name=a.md')
        T.contains(note, 'HTTP/1.1 200 OK')
        T.contains(vim.json.decode(note:match('\r\n\r\n(.*)$')).html, '<p>本文</p>')

        T.contains(tcp_get(port, '/__version'), 'HTTP/1.1 200 OK')
        T.contains(tcp_get(port, '/'), '<title>Notes</title>')
        T.contains(tcp_get(port, '/html'), 'HTTP/1.1 200 OK')
        -- 生ソケットは `..` を正規化せずに送れる（curl 等は送る前に畳んでしまう）
        T.contains(tcp_get(port, '/html/../secret.html'), 'HTTP/1.1 403 Forbidden')
      end)
      web.stop()
      if not ok then error(err, 0) end
    end)
  end)
end)

T.describe('notes_web.open', function()
  T.it('未起動ならポートを聞き、起動済みなら聞かずに同じ URL を開く', function()
    local orig_input = vim.ui.input
    local orig_open_on_port = web.open_on_port
    local orig_open_url = require('config.browser.util').open_url
    local prompts, opened, urls = 0, {}, {}

    vim.ui.input = function(_, cb)
      prompts = prompts + 1
      cb('6401')
    end
    web.open_on_port = function(port) opened[#opened + 1] = port end
    require('config.browser.util').open_url = function(url) urls[#urls + 1] = url; return url end

    web.open()
    T.eq(prompts, 1)
    T.eq(opened, { 6401 })

    -- 起動済みの状態を作る（ソケットは張らず state だけ差し替える）
    web._private.state.server = {}
    web._private.state.port = 6401
    web.open()

    web._private.state.server = nil
    web._private.state.port = nil
    vim.ui.input = orig_input
    web.open_on_port = orig_open_on_port
    require('config.browser.util').open_url = orig_open_url

    T.eq(prompts, 1, '起動済みならポートを聞き直さない')
    T.eq(urls, { 'http://localhost:6401/' })
  end)
end)

T.describe('notes.open (picker)', function()
  T.it('Ctrl-o でブラウザ一覧を開くことを案内する', function()
    if vim.fn.executable('rg') == 0 then
      print('  (skipped: rg not installed)')
      return
    end
    local dir = tmpdir()
    vim.fn.writefile({ '# alpha memo' }, dir .. '/20260101-000001.md')

    local before = {}
    for _, w in ipairs(vim.api.nvim_list_wins()) do before[w] = true end

    with_dir(dir, function()
      local ok, err = pcall(function()
        notes.open()
        local found = false
        for _, w in ipairs(vim.api.nvim_list_wins()) do
          local cfg = vim.api.nvim_win_get_config(w)
          for _, chunk in ipairs(cfg.footer or {}) do
            if tostring(chunk[1]):find('Ctrl-o', 1, true) then found = true end
          end
        end
        T.ok(found, 'プロンプト窓の footer に Ctrl-o の案内が出ること')
      end)
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if not before[w] and vim.api.nvim_win_get_config(w).relative ~= '' then
          pcall(vim.api.nvim_win_close, w, true)
        end
      end
      if not ok then error(err, 0) end
    end)
  end)
end)

T.summary()
