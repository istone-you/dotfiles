local T = dofile(TESTS_DIR .. '/helpers.lua')
local server = require('config.nvim_api.server')
local util = require('config.nvim_api.util')

local S = vim.diagnostic.severity
local ns = vim.api.nvim_create_namespace('nvim_api_server_spec')

-- 生の HTTP レスポンス文字列から {status, json} を取り出す
local function parse_response(raw)
  local status = raw:match('^HTTP/1%.1 (%d+)')
  local body = raw:match('\r\n\r\n(.*)$') or ''
  local ok, decoded = pcall(vim.json.decode, body)
  return tonumber(status), (ok and decoded or nil), body
end

-- response_for_request は文字列(同期)か nil(非同期・あとから respond)を返す。
-- テストからは両方を同じ形で扱いたいので、respond を捕まえて待ち合わせる。
local function call(req)
  local captured = nil
  local resp = server.response_for_request(req, function(r) captured = r end)
  if resp == nil then
    vim.wait(5000, function() return captured ~= nil end, 10)
    resp = captured
  end
  return parse_response(resp or '')
end

local function get(path, query)
  return call({ method = 'GET', path = path, query = query or '', body = '' })
end

local function post(path, tbl)
  return call({
    method = 'POST', path = path, query = '',
    body = type(tbl) == 'string' and tbl or vim.json.encode(tbl or {}),
  })
end

local function with_root(fn)
  local root = util.real(vim.fn.tempname())
  vim.fn.mkdir(root, 'p')
  vim.fn.writefile({ 'local M = {}', 'function M.open() end', 'return M' }, root .. '/a.lua')
  vim.fn.writefile({ 'x = 1' }, root .. '/b.lua')
  server.set_session({ root = root })
  local ok, err = pcall(fn, root)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(b)
    if name ~= '' and name:sub(1, #root) == root then
      vim.diagnostic.reset(ns, b)
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  vim.fn.delete(root, 'rf')
  if not ok then error(err) end
end

T.describe('nvim_api/server.lua ルーティング', function()
  T.it('reports the session and its capabilities', function()
    with_root(function(root)
      local status, json = get('/api/session')
      T.eq(status, 200)
      T.eq(json.root, root)
      T.eq(json.pid, vim.fn.getpid())
      T.contains(json.capabilities, 'diagnostics')
      T.contains(json.capabilities, 'lsp')
      T.contains(json.capabilities, 'buffers')
    end)
  end)

  T.it('serves diagnostics, filtered and summarized', function()
    with_root(function(root)
      local bufnr = vim.fn.bufadd(root .. '/a.lua')
      vim.fn.bufload(bufnr)
      vim.diagnostic.set(ns, bufnr, {
        { lnum = 0, col = 0, severity = S.ERROR, message = 'boom', source = 'test' },
        { lnum = 1, col = 2, severity = S.HINT, message = 'nit', source = 'test' },
      })

      local status, json = get('/api/diagnostics')
      T.eq(status, 200)
      T.eq(json.count, 2)
      T.eq(json.truncated, false)
      T.eq(json.diagnostics[1].file, 'a.lua')
      T.eq(json.diagnostics[1].line, 1)
      T.eq(json.diagnostics[1].severity, 'error')

      local _, only_errors = get('/api/diagnostics', 'severity=error')
      T.eq(only_errors.count, 1)

      local _, capped = get('/api/diagnostics', 'max=1')
      T.eq(capped.count, 1)
      T.eq(capped.truncated, true)

      local _, other_file = get('/api/diagnostics', 'file=b.lua')
      T.eq(other_file.count, 0)

      -- refresh=1 は外部編集の取り込み待ちを挟むが、その待ちでエディタを固めないこと
      local started = vim.uv.hrtime()
      local captured = nil
      local immediate = server.response_for_request(
        { method = 'GET', path = '/api/diagnostics', query = 'refresh=1&wait_ms=200', body = '' },
        function(r) captured = r end)
      local elapsed_ms = (vim.uv.hrtime() - started) / 1e6
      T.eq(immediate, nil, 'refresh 付きは非同期で返す')
      T.ok(elapsed_ms < 150, string.format('待ちは呼び出しを塞がない(実測 %.1fms)', elapsed_ms))
      vim.wait(5000, function() return captured ~= nil end, 10)
      local _, refreshed = parse_response(captured)
      T.eq(refreshed.count, 2)

      local _, summary = get('/api/diagnostics/summary')
      T.eq(summary.total, 2)
      T.eq(summary.totals.error, 1)
      T.eq(summary.files[1].file, 'a.lua')
    end)
  end)

  T.it('lists loaded buffers', function()
    with_root(function(root)
      local bufnr = vim.fn.bufadd(root .. '/a.lua')
      vim.fn.bufload(bufnr)
      local status, json = get('/api/buffers')
      T.eq(status, 200)
      local found = false
      for _, b in ipairs(json.buffers) do
        if b.file == 'a.lua' then found = true end
      end
      T.ok(found, 'a.lua が /api/buffers に出る')
    end)
  end)

  T.it('loads files on demand and separates failures', function()
    with_root(function()
      local status, json = post('/api/buffers/load', { files = { 'a.lua', 'missing.lua' }, timeout_ms = 50 })
      T.eq(status, 200)
      T.eq(#json.loaded, 1)
      T.eq(json.loaded[1].file, 'a.lua')
      T.eq(#json.failed, 1)
      T.contains(json.failed[1].error, 'file not readable')

      -- 単数形 file でも受ける
      local _, single = post('/api/buffers/load', { file = 'b.lua', timeout_ms = 50 })
      T.eq(#single.loaded, 1)

      local bad_status, bad = post('/api/buffers/load', {})
      T.eq(bad_status, 400)
      T.contains(bad.error, 'files (array) or file is required')
    end)
  end)

  T.it('refreshes buffers from disk', function()
    with_root(function(root)
      local bufnr = vim.fn.bufadd(root .. '/a.lua')
      vim.fn.bufload(bufnr)
      vim.fn.writefile({ '外から書き換えた' }, root .. '/a.lua')
      local status, json = post('/api/refresh', {})
      T.eq(status, 200)
      T.eq(json.ok, true)
      T.eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { '外から書き換えた' })
    end)
  end)

  T.it('validates LSP requests before reaching the language server', function()
    with_root(function()
      local status, json = post('/api/lsp/definition', { line = 1 })
      T.eq(status, 400)
      T.contains(json.error, 'file is required')

      local status2, json2 = post('/api/lsp/references', { file = 'a.lua' })
      T.eq(status2, 400)
      T.contains(json2.error, 'line must be a positive integer')

      local status3, json3 = post('/api/lsp/document_symbols', {})
      T.eq(status3, 400)
      T.contains(json3.error, 'file is required')

      local status4, json4 = post('/api/lsp/workspace_symbols', {})
      T.eq(status4, 400)
      T.contains(json4.error, 'query is required')
    end)
  end)

  T.it('explains itself when no language server is attached', function()
    with_root(function()
      -- headless では言語サーバが起動しない。空配列で「参照ゼロ」と誤読させず、理由を返すこと
      local status, json = post('/api/lsp/definition', { file = 'a.lua', line = 2, col = 12, timeout_ms = 50 })
      T.eq(status, 409)
      T.contains(json.error, 'no LSP client attached')

      local status2, json2 = post('/api/lsp/workspace_symbols', { query = 'open', timeout_ms = 50 })
      T.eq(status2, 409)
      T.contains(json2.error, 'no LSP client is running yet')
    end)
  end)

  T.it('answers LSP routes asynchronously without blocking the caller', function()
    with_root(function()
      -- 同期ルートはその場で文字列を返す
      local sync = server.response_for_request(
        { method = 'GET', path = '/api/session', query = '', body = '' }, function() end)
      T.ok(type(sync) == 'string', '同期ルートは文字列を返す')

      -- LSP ルートは nil を返し、待ちはコールバック側に逃がす。
      -- ここが文字列を返す(= 呼び出し中に待っている)実装だと、AI が問い合わせている間
      -- 人間のエディタが固まる。契約としてピン留めしておく。
      local captured = nil
      local started = vim.uv.hrtime()
      local async = server.response_for_request({
        method = 'POST', path = '/api/lsp/definition', query = '',
        body = vim.json.encode({ file = 'a.lua', line = 2, col = 12, timeout_ms = 200 }),
      }, function(r) captured = r end)
      local elapsed_ms = (vim.uv.hrtime() - started) / 1e6

      T.eq(async, nil, 'LSP ルートは nil を返す(あとから respond)')
      T.eq(captured, nil, '呼び出しから戻る時点ではまだ応答していない')
      T.ok(elapsed_ms < 150, string.format('呼び出しは待たずに戻る(実測 %.1fms)', elapsed_ms))

      vim.wait(5000, function() return captured ~= nil end, 10)
      T.ok(captured, 'あとから応答が来る')
      T.eq(select(1, parse_response(captured)), 409) -- headless なので言語サーバは付かない
    end)
  end)

  T.it('refuses client-supplied paths outside the repository root', function()
    with_root(function()
      local status, json = post('/api/lsp/definition', { file = '/etc/hosts', line = 1 })
      T.eq(status, 400)
      T.contains(json.error, 'outside the repository root')

      T.eq(select(1, post('/api/buffers/load', { files = { '../../../../etc/hosts' } })), 200)
      local _, load_json = post('/api/buffers/load', { files = { '/etc/hosts' } })
      T.eq(#load_json.loaded, 0)
      T.contains(load_json.failed[1].error, 'outside the repository root')

      local diag_status, diag_json = get('/api/diagnostics', 'file=/etc/hosts')
      T.eq(diag_status, 400)
      T.contains(diag_json.error, 'outside the repository root')
    end)
  end)

  T.it('reports why a file-scoped workspace symbol lookup failed', function()
    with_root(function()
      -- err を捨てると「LSP がいない」と誤報告され、パスの誤りに気づけない
      local status, json = post('/api/lsp/workspace_symbols',
        { query = 'open', file = 'missing.lua', timeout_ms = 50 })
      T.eq(status, 400)
      T.contains(json.error, 'file not readable')
    end)
  end)

  T.it('rejects a malformed body and unknown routes', function()
    with_root(function()
      local status, json = post('/api/buffers/load', '{壊れている')
      T.eq(status, 400)
      T.contains(json.error, 'invalid JSON body')

      T.eq(select(1, get('/api/nope')), 404)
      T.eq(select(1, post('/api/nope', {})), 404)

      T.eq(select(1, call({ method = 'PUT', path = '/api/session', query = '', body = '' })), 405)
      T.eq(select(1, call({ method = 'OPTIONS', path = '/api/session', query = '', body = '' })), 204)
    end)
  end)
end)

T.describe('nvim_api/server.lua 実サーバ', function()
  T.it('answers a real HTTP request through the async handler', function()
    with_root(function(root)
      -- ハンドラは vim.schedule 経由でメインループへ戻ってから応答する(fast event context では
      -- vim.api / vim.lsp を触れないため)。その往復が実際に成立することを生ソケットで確かめる。
      local port
      for p = 45301, 45400 do
        if server.start(p) then port = p break end
      end
      T.ok(port, 'テスト用ポートに listen できた')

      local uv = vim.uv or vim.loop
      local client = uv.new_tcp()
      local received = ''
      local done = false
      client:connect('127.0.0.1', port, function(err)
        if err then done = true return end
        client:read_start(function(rerr, chunk)
          if rerr or not chunk then done = true return end
          received = received .. chunk
          if received:match('\r\n\r\n') then done = true end
        end)
        client:write('GET /api/session HTTP/1.1\r\nHost: localhost\r\n\r\n')
      end)

      vim.wait(3000, function() return done end, 20)
      pcall(function() client:close() end)
      server.stop()

      local status, json = parse_response(received)
      T.eq(status, 200)
      T.eq(json.root, root)
      T.eq(json.port, port)
    end)
  end)
end)

T.summary()
