local T = dofile(TESTS_DIR .. '/helpers.lua')
local http = require('config.browser.server')

T.describe('browser/server.lua parse_request', function()
  T.it('returns nil until headers are complete', function()
    T.eq(http.parse_request('GET /x HTTP/1.1\r\nHost: y'), nil)
  end)

  T.it('parses a GET with path and query, empty body', function()
    local req = http.parse_request('GET /api/comments?file=a&x=1 HTTP/1.1\r\nHost: y\r\n\r\n')
    T.eq(req.method, 'GET')
    T.eq(req.path, '/api/comments')
    T.eq(req.query, 'file=a&x=1')
    T.eq(req.body, '')
    T.eq(req.headers.host, 'y')
  end)

  T.it('waits for the full body per Content-Length', function()
    T.eq(http.parse_request('POST /p HTTP/1.1\r\nContent-Length: 10\r\n\r\n{"a":1}'), nil)
    local req = http.parse_request('POST /p HTTP/1.1\r\nContent-Length: 7\r\n\r\n{"a":1}')
    T.eq(req.method, 'POST')
    T.eq(req.body, '{"a":1}')
  end)
end)

T.describe('browser/server.lua start/stop', function()
  T.it('starts, serves the handler response, and reports an occupied port', function()
    local state = {}
    local port
    for p = 26100, 26200 do
      if http.start(state, p, { namespace = 'test', default_host = '127.0.0.1',
        handler = function(req) return 'HTTP/1.1 200 OK\r\nContent-Length: ' .. #req.path .. '\r\n\r\n' .. req.path end }) then
        port = p break
      end
    end
    T.ok(port, 'server should bind some port')
    T.eq(state.port, port)
    T.ok(state.server ~= nil)

    -- 同じポートを別 state で掴もうとすると "already in use" で失敗し、掴んだ側は残る。
    -- bind先ホストは default_host で決まるので、1回目と必ず揃える。揃えないと
    -- 2回目は 0.0.0.0 へbindしにいき、macOSでは 127.0.0.1 が埋まっていても成功してしまう
    local other = {}
    local ok, err = http.start(other, port, { namespace = 'test', default_host = '127.0.0.1',
      handler = function() return '' end })
    T.eq(ok, false)
    T.contains(err, 'already in use')
    T.eq(other.server, nil)

    local res = vim.system({ 'curl', '-s', 'http://127.0.0.1:' .. port .. '/hello' }, { text = true }):wait()
    T.eq(res.stdout, '/hello')

    local blocked = vim.system({
      'curl', '-s', '-i', '-X', 'POST',
      '-H', 'Origin: https://example.invalid',
      '-H', 'Host: 127.0.0.1:' .. tostring(port),
      '--data-binary', '{}',
      'http://127.0.0.1:' .. port .. '/mutate',
    }, { text = true }):wait()
    T.contains(blocked.stdout, 'HTTP/1.1 403 Forbidden')

    local same_origin = vim.system({
      'curl', '-s', '-X', 'POST',
      '-H', 'Origin: http://127.0.0.1:' .. tostring(port),
      '-H', 'Host: 127.0.0.1:' .. tostring(port),
      '--data-binary', '{}',
      'http://127.0.0.1:' .. port .. '/ok',
    }, { text = true }):wait()
    T.eq(same_origin.stdout, '/ok')

    http.stop(state)
    T.eq(state.server, nil)
    T.eq(state.port, nil)
    T.eq(state.host, nil)
  end)
end)

T.summary()
