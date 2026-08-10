local T = dofile(TESTS_DIR .. '/helpers.lua')
local server = require('config.diff_review.server')
local comments = require('config.diff_review.comments')
local util = require('config.nvim_api.util')

local P = server._private

T.describe('diff_review/server.lua request parsing', function()
  T.it('returns nil until headers are complete', function()
    T.eq(P.parse_request('GET /api/diff HTTP/1.1\r\nHost: x'), nil)
  end)

  T.it('parses a GET with query string', function()
    local req = P.parse_request('GET /api/comments?file=a.txt&author=claude HTTP/1.1\r\nHost: x\r\n\r\n')
    T.eq(req.method, 'GET')
    T.eq(req.path, '/api/comments')
    T.eq(req.query, 'file=a.txt&author=claude')
  end)

  T.it('waits for the full body per Content-Length', function()
    local raw = 'POST /api/comments HTTP/1.1\r\nContent-Length: 10\r\n\r\n{"a":1}'
    T.eq(P.parse_request(raw), nil) -- only 7 of 10 bytes
    local full = 'POST /api/comments HTTP/1.1\r\nContent-Length: 7\r\n\r\n{"a":1}'
    local req = P.parse_request(full)
    T.eq(req.method, 'POST')
    T.eq(req.body, '{"a":1}')
  end)

  T.it('parses query pairs with url-decoding', function()
    T.eq(P.parse_query('file=src%2Fa.txt&x=hi%20there'), { file = 'src/a.txt', x = 'hi there' })
  end)

  T.it('decodes JSON bodies and rejects garbage', function()
    T.eq(P.decode_body('{"x":1}'), { x = 1 })
    T.eq(P.decode_body(''), {})
    T.eq(P.decode_body('not json'), nil)
  end)
end)

T.describe('diff_review/server.lua routing', function()
  T.it('serves the web page at /', function()
    local resp = server.response_for_request({ method = 'GET', path = '/', query = '', body = '' })
    T.contains(resp, '200 OK')
    T.contains(resp, 'Diff Review')
  end)

  T.it('serves diff and session JSON', function()
    server.set_session({ repo_root = '/app', source = 'worktree' })
    server.set_diff({ files = {} })
    local resp = server.response_for_request({ method = 'GET', path = '/api/session', query = '', body = '' })
    T.contains(resp, 'application/json')
    T.contains(resp, '"repoRoot":"/app"')
  end)

  T.it('serves per-view diffs via ?view=', function()
    server.set_diff({
      uncommitted = { files = { { path = 'a.txt' } } },
      unstaged = { files = { { path = 'u.txt' } } },
      staged = { files = { { path = 's.txt' } } },
      committed = { files = { { path = 'br.txt' } } },
      branch_base = { ref = 'origin/main', merge_base = 'deadbeef' },
    })
    local unc = server.response_for_request({ method = 'GET', path = '/api/diff', query = 'view=uncommitted', body = '' })
    T.contains(unc, 'a.txt')
    local staged = server.response_for_request({ method = 'GET', path = '/api/diff', query = 'view=staged', body = '' })
    T.contains(staged, 's.txt')
    local unstaged = server.response_for_request({ method = 'GET', path = '/api/diff', query = 'view=unstaged', body = '' })
    T.contains(unstaged, 'u.txt')
    local committed = server.response_for_request({ method = 'GET', path = '/api/diff', query = 'view=committed', body = '' })
    T.contains(committed, 'br.txt')
    -- 未知/無指定ビューは uncommitted にフォールバック
    local dflt = server.response_for_request({ method = 'GET', path = '/api/diff', query = '', body = '' })
    T.contains(dflt, 'a.txt')
    -- 旧名 'all' は uncommitted のエイリアス(後方互換)
    local legacy = server.response_for_request({ method = 'GET', path = '/api/diff', query = 'view=all', body = '' })
    T.contains(legacy, 'a.txt')
  end)

  T.it('accepts the legacy all= key on set_diff as uncommitted', function()
    server.set_diff({ all = { files = { { path = 'legacy.txt' } } } })
    local resp = server.response_for_request({ method = 'GET', path = '/api/diff', query = 'view=uncommitted', body = '' })
    T.contains(resp, 'legacy.txt')
  end)

  T.it('exposes the committed view and branchBase in /api/session', function()
    server.set_session({ repo_root = '/app', source = 'worktree' })
    server.set_diff({
      uncommitted = { files = {} },
      committed = { files = {} },
      branch_base = { ref = 'origin/main', merge_base = 'cafebabe' },
    })
    local resp = server.response_for_request({ method = 'GET', path = '/api/session', query = '', body = '' })
    T.contains(resp, '"committed"')              -- views に committed が並ぶ
    T.contains(resp, '"ref":"origin/main"')      -- branchBase.ref
    T.contains(resp, 'cafebabe')                 -- branchBase.merge_base

    -- デフォルトブランチが無ければ branchBase は null
    server.set_diff({ uncommitted = { files = {} } })
    local resp2 = server.response_for_request({ method = 'GET', path = '/api/session', query = '', body = '' })
    T.contains(resp2, '"branchBase":null')
  end)

  T.it('anchors committed-view comments against the committed diff, per bucket', function()
    local diff = require('config.diff_review.diff')
    local function added(path, lines)
      local parts = { 'diff --git a/'..path..' b/'..path, 'new file mode 100644', '--- /dev/null', '+++ b/'..path,
        '@@ -0,0 +1,'..#lines..' @@' }
      for _, l in ipairs(lines) do parts[#parts+1] = '+'..l end
      return diff.parse(table.concat(parts, '\n'))
    end
    comments.reset()
    -- uncommitted と committed で別々の中身。'target' 行の位置がビューごとに違う。
    server.set_diff({
      uncommitted = added('a.lua', { 'target', 'x' }),   -- uncommitted では 1 行目
      committed = added('a.lua', { 'x', 'y', 'target' }), -- committed では 3 行目
      branch_base = { ref = 'origin/main', merge_base = 'sha' },
    })
    -- committed バケットへ、committed 差分の 3 行目('target')にコメント
    local post = server.response_for_request({ method='POST', path='/api/comments', query='',
      body = '{"file":"a.lua","new_line":3,"view":"committed","body":"on committed target","author":"claude"}' })
    T.contains(post, '200 OK')
    T.contains(post, '"view":"committed"')
    local id = vim.json.decode(post:match('\r\n\r\n(.*)$')).comment.id

    -- committed 差分が変わり 'target' が 2 行目へ動く → committed モデルで追従する(uncommitted では動かない)
    server.set_diff({
      uncommitted = added('a.lua', { 'target', 'x' }),
      committed = added('a.lua', { 'y', 'target' }),
      branch_base = { ref = 'origin/main', merge_base = 'sha' },
    })
    local c = comments.get(id)
    T.eq(c.line, 2, 'committed comment should follow its line within the committed diff')
    T.eq(c.outdated, false)

    -- ?view= でバケットを絞って読める
    local only = server.response_for_request({ method='GET', path='/api/comments', query='view=committed', body='' })
    T.contains(only, 'on committed target')
    local none = server.response_for_request({ method='GET', path='/api/comments', query='view=uncommitted', body='' })
    T.ok(not none:find('on committed target'), 'uncommitted bucket must not contain the committed comment')
  end)

  T.it('adds a comment via POST and lists it back', function()
    comments.reset()
    local before = server.version()
    local post = server.response_for_request({
      method = 'POST', path = '/api/comments', query = '',
      body = '{"file":"foo.txt","new_line":3,"body":"note","author":"claude"}',
    })
    T.contains(post, '200 OK')
    T.contains(post, '"author":"claude"')
    T.ok(server.version() > before, 'version should bump after adding a comment')

    local list = server.response_for_request({ method = 'GET', path = '/api/comments', query = '', body = '' })
    T.contains(list, '"body":"note"')
    T.contains(list, '"threads"')
  end)

  T.it('re-anchors a comment to follow its line, and marks it outdated when the line disappears', function()
    local diff = require('config.diff_review.diff')
    local function added(path, lines)
      local parts = { 'diff --git a/'..path..' b/'..path, 'new file mode 100644', '--- /dev/null', '+++ b/'..path,
        '@@ -0,0 +1,'..#lines..' @@' }
      for _, l in ipairs(lines) do parts[#parts+1] = '+'..l end
      return diff.parse(table.concat(parts, '\n'))
    end
    comments.reset()
    -- 初期差分: a.lua = [one, two, three]
    server.set_diff({ uncommitted = added('a.lua', {'one','two','three'}) })
    -- 'two'(2行目)にコメント
    local post = server.response_for_request({ method='POST', path='/api/comments', query='',
      body = '{"file":"a.lua","new_line":2,"body":"on two","author":"human"}' })
    T.contains(post, '200 OK')
    local id = vim.json.decode(post:match('\r\n\r\n(.*)$')).comment.id

    -- 差分更新: 先頭に2行挿入 → 'two' は 4行目へ
    server.set_diff({ uncommitted = added('a.lua', {'x','y','one','two','three'}) })
    local c = comments.get(id)
    T.eq(c.line, 4, 'comment followed its line to 4')
    T.eq(c.outdated, false)

    -- 差分更新: 'two' が消える → outdated
    server.set_diff({ uncommitted = added('a.lua', {'one','three'}) })
    c = comments.get(id)
    T.eq(c.outdated, true)
  end)

  T.it('rejects an invalid comment with 400', function()
    comments.reset()
    local resp = server.response_for_request({
      method = 'POST', path = '/api/comments', query = '', body = '{"body":"no target or file"}',
    })
    T.contains(resp, '400 Bad Request')
    T.contains(resp, '"error"')
  end)

  T.it('rejects a malformed JSON body', function()
    local resp = server.response_for_request({
      method = 'POST', path = '/api/comments', query = '', body = 'not json',
    })
    T.contains(resp, '400 Bad Request')
  end)

  T.it('jumps to a location in nvim', function()
    local root = util.real(vim.fn.tempname())
    vim.fn.mkdir(root, 'p')
    vim.fn.writefile({ 'one', 'two', 'three' }, root .. '/a.lua')
    server.set_session({ repo_root = root, source = 'worktree' })

    local resp = server.response_for_request({
      method = 'POST',
      path = '/api/jump',
      query = '',
      body = '{"file":"a.lua","line":2,"col":1}',
    })
    T.contains(resp, '200 OK')
    T.eq(util.real(vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())), root .. '/a.lua')
    T.eq(vim.api.nvim_win_get_cursor(0), { 2, 0 })
    T.eq(vim.bo[vim.api.nvim_get_current_buf()].buflisted, true)

    pcall(vim.api.nvim_buf_delete, vim.api.nvim_get_current_buf(), { force = true })
    vim.fn.delete(root, 'rf')
  end)

  T.it('rejects jump paths outside the repository root', function()
    server.set_session({ repo_root = vim.fn.getcwd(), source = 'worktree' })
    local resp = server.response_for_request({
      method = 'POST',
      path = '/api/jump',
      query = '',
      body = '{"file":"/etc/hosts","line":1}',
    })
    T.contains(resp, '400 Bad Request')
    T.contains(resp, 'outside the repository root')
  end)

  T.it('serves whitelisted vendor assets and rejects others', function()
    local ok = server.response_for_request({ method = 'GET', path = '/__vendor/highlight.min.js', query = '', body = '' })
    T.contains(ok, '200 OK')
    local themed = server.response_for_request({ method = 'GET', path = '/__vendor/highlight-theme.css', query = '', body = '' })
    T.contains(themed, '200 OK')
    -- 非ホワイトリストは 404(パストラバーサル防止)
    local nope = server.response_for_request({ method = 'GET', path = '/__vendor/secret.js', query = '', body = '' })
    T.contains(nope, '404')
  end)

  T.it('404s unknown paths and 405s unknown methods', function()
    T.contains(server.response_for_request({ method = 'GET', path = '/nope', query = '', body = '' }), '404')
    T.contains(server.response_for_request({ method = 'DELETE', path = '/', query = '', body = '' }), '405')
  end)
end)

T.describe('diff_review/server.lua live socket', function()
  T.it('round-trips a comment over a real TCP connection', function()
    comments.reset()
    server.set_session({ repo_root = '/app', source = 'worktree' })
    server.set_diff({ files = {} })

    local port
    for p = 27100, 27200 do
      if server.start(p) then port = p break end
    end
    T.ok(port, 'server should start on some port')
    local base = 'http://127.0.0.1:' .. port

    local function curl(args)
      local res = vim.system(vim.list_extend({ 'curl', '-s' }, args), { text = true }):wait()
      return res.stdout or ''
    end

    local post = curl({ '-X', 'POST', base .. '/api/comments',
      '-H', 'Content-Type: application/json',
      '-d', '{"file":"foo.txt","new_line":5,"body":"live note","author":"claude"}' })
    T.contains(post, '"body":"live note"')

    local list = curl({ base .. '/api/comments' })
    T.contains(list, 'live note')

    server.stop()
    T.ok(server.is_running() == false, 'server should be stopped')
  end)
end)

T.summary()
