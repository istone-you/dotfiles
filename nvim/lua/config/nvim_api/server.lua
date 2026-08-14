-- nvim_api の HTTP ルーティング。
--
-- ソケット層は browser/server.lua を共有する(diff_review と同じ)。違いは、こちらのハンドラが
-- vim.api / vim.lsp を触るためメインループ上で動く必要があること。libuv のコールバックは
-- fast event context なのでそこでは API を呼べない。そこで handler は必ず vim.schedule して
-- から response_for_request を呼ぶ。
--
-- response_for_request(req, respond) は 2 種類の応答経路を持つ:
--   * 文字列を返す … 診断 / バッファ一覧など、その場で答えられるもの
--   * nil を返す  … LSP のように待ちが要るもの。あとから respond(文字列) が呼ばれる
-- LSP を待つのに vim.wait を使わないのは、あれが打鍵を処理しないままメインループを占有し、
-- AI が問い合わせている間ずっと人間のエディタが固まって見えるため。
-- どちらの経路もソケット無しでテストできる(respond を渡すだけ)。

local M = {}
local browser = require('config.browser.util')
local http = require('config.browser.server')
local util = require('config.nvim_api.util')
local diagnostics = require('config.nvim_api.diagnostics')
local buffers = require('config.nvim_api.buffers')
local lsp = require('config.nvim_api.lsp')

local state = {
  server = nil,
  port = nil,
  host = nil,
  root = nil,
  started_at = nil,
}

M.state = state

-- 診断の既定上限。全部返すと AI のコンテキストが飛ぶので、まず summary を見る運用にしたい。
M.DEFAULT_MAX_DIAGNOSTICS = 200

-- 応答が返らないままソケットが残るのを防ぐ保険。個々の非同期ルートは自前のタイムアウトを
-- 持つので通常ここには到達しない。
M.RESPONSE_TIMEOUT_MS = 15000

function M.set_session(opts)
  opts = opts or {}
  if opts.root ~= nil then state.root = util.normalize_root(opts.root) end
end

local function root()
  return util.normalize_root(state.root)
end

local CAPABILITIES = {
  'diagnostics', 'lsp', 'buffers', 'servers',
}

-- ── GET ─────────────────────────────────────────────

local function handle_get(req, respond)
  local path = req.path
  local q = util.parse_query(req.query)

  if path == '/api/session' then
    return util.ok({
      root = root(),
      port = state.port,
      pid = vim.fn.getpid(),
      nvim = tostring(vim.version()),
      startedAt = state.started_at,
      capabilities = CAPABILITIES,
    })
  end

  if path == '/api/diagnostics' then
    if q.file and q.file ~= '' then
      local _, path_err = util.client_path(q.file, root())
      if path_err then return util.bad_request(path_err) end
    end
    local function build()
      local items, truncated = diagnostics.collect({
        file = q.file,
        severity = q.severity,
        root = root(),
        max = util.to_number(q.max, M.DEFAULT_MAX_DIAGNOSTICS),
      })
      return util.ok({ diagnostics = items, count = #items, truncated = truncated })
    end

    -- refresh=1 で先に外部編集を取り込む。LSP が診断を出し直すのは非同期なので、
    -- 直後に読むと古いままになりやすい。wait_ms のあいだ押し出しを待ってから答える。
    -- この待ちもタイマーで行う(vim.wait だとその間エディタが固まる)。
    if util.truthy(q.refresh, false) then
      buffers.checktime()
      local uv = vim.uv or vim.loop
      local timer = uv.new_timer()
      if timer then
        timer:start(math.max(util.to_number(q.wait_ms, 300), 0), 0, function()
          vim.schedule(function()
            pcall(function() timer:stop() end)
            pcall(function() timer:close() end)
            respond(build())
          end)
        end)
        return nil
      end
    end
    return build()
  end

  if path == '/api/diagnostics/summary' then
    local items = diagnostics.collect({ severity = q.severity, root = root() })
    return util.ok(diagnostics.summary(items))
  end

  if path == '/api/buffers' then
    return util.ok({ buffers = buffers.list(root()) })
  end

  return util.not_found()
end

-- ── POST: LSP ───────────────────────────────────────

--- ワークスペース単位のリクエスト用に、LSP が付いている適当なバッファを 1 つ選ぶ。
local function any_lsp_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and #vim.lsp.get_clients({ bufnr = b }) > 0 then
      return b
    end
  end
  return nil
end

local function lsp_position_request(body, method, extra_params, format, respond)
  lsp.prepare_async(body, root(), function(bufnr, params, err)
    if not bufnr or not params then return respond(util.bad_request(err)) end
    for k, v in pairs(extra_params or {}) do params[k] = v end
    lsp.request_async(bufnr, method, params, body.timeout_ms, function(results, req_err)
      if not results then return respond(util.json_response('409 Conflict', { error = req_err })) end
      respond(util.ok(format(results)))
    end)
  end)
end

--- LSP 系のルーティング。
---@return string|nil resp 同期で返せる場合のレスポンス(検証エラーなど)
---@return boolean handled このルートを扱ったか。true かつ resp が nil なら respond 待ち
local function handle_lsp(path, body, respond)
  if path == '/api/lsp/definition' then
    lsp_position_request(body, 'textDocument/definition', nil, function(results)
      local locs = lsp.format_locations(results, root())
      return { locations = locs, count = #locs }
    end, respond)
    return nil, true
  end

  if path == '/api/lsp/references' then
    local include = util.truthy(body.includeDeclaration, true)
    lsp_position_request(body, 'textDocument/references',
      { context = { includeDeclaration = include } },
      function(results)
        local locs = lsp.format_locations(results, root())
        return { locations = locs, count = #locs }
      end, respond)
    return nil, true
  end

  if path == '/api/lsp/hover' then
    lsp_position_request(body, 'textDocument/hover', nil, function(results)
      return { hover = util.or_null(lsp.hover_text(results)) }
    end, respond)
    return nil, true
  end

  if path == '/api/lsp/code_actions' then
    lsp.prepare_async(body, root(), function(bufnr, params, err)
      if not bufnr or not params then return respond(util.bad_request(err)) end
      local pos = params.position
      params.range = { start = pos, ['end'] = pos }
      params.position = nil
      -- code action は「その行の診断」を文脈として受け取る。渡さないと quickfix 系の
      -- アクション(未使用 import の削除など)を出さないサーバがある。
      local line_diags = vim.diagnostic.get(bufnr, { lnum = pos.line })
      local ok_conv, lsp_diags = pcall(vim.lsp.diagnostic.from, line_diags)
      params.context = { diagnostics = ok_conv and lsp_diags or {} }
      lsp.request_async(bufnr, 'textDocument/codeAction', params, body.timeout_ms, function(results, req_err)
        if not results then return respond(util.json_response('409 Conflict', { error = req_err })) end
        local actions = lsp.format_code_actions(results)
        respond(util.ok({ actions = actions, count = #actions }))
      end)
    end)
    return nil, true
  end

  if path == '/api/lsp/document_symbols' then
    if not body.file or body.file == '' then return util.bad_request('file is required'), true end
    buffers.ensure_loaded_async(body.file, root(), body.timeout_ms, function(bufnr, err)
      if not bufnr then return respond(util.bad_request(err)) end
      lsp.request_async(bufnr, 'textDocument/documentSymbol', {
        textDocument = { uri = vim.uri_from_bufnr(bufnr) },
      }, body.timeout_ms, function(results, req_err)
        if not results then return respond(util.json_response('409 Conflict', { error = req_err })) end
        local symbols = lsp.flatten_symbols(results, root())
        respond(util.ok({ symbols = symbols, count = #symbols }))
      end)
    end)
    return nil, true
  end

  if path == '/api/lsp/workspace_symbols' then
    local query = tostring(body.query or '')
    if query == '' then return util.bad_request('query is required'), true end

    local function ask(bufnr)
      if not bufnr then
        return respond(util.json_response('409 Conflict', {
          error = 'no LSP client is running yet (先に /api/buffers/load でこの言語のファイルを開かせること)',
        }))
      end
      lsp.request_async(bufnr, 'workspace/symbol', { query = query }, body.timeout_ms, function(results, req_err)
        if not results then return respond(util.json_response('409 Conflict', { error = req_err })) end
        local symbols = lsp.flatten_symbols(results, root())
        respond(util.ok({ symbols = symbols, count = #symbols }))
      end)
    end

    if body.file and body.file ~= '' then
      buffers.ensure_loaded_async(body.file, root(), body.timeout_ms, function(bufnr, err)
        -- err を捨てると、存在しないパスや root 外指定が「LSP がいない」と誤報告される
        if not bufnr then return respond(util.bad_request(err)) end
        ask(bufnr)
      end)
    else
      ask(any_lsp_buf())
    end
    return nil, true
  end

  return nil, false
end

local function handle_post(req, respond)
  local path = req.path
  local body = util.decode_body(req.body)
  if body == nil then return util.bad_request('invalid JSON body') end

  local lsp_response, handled = handle_lsp(path, body, respond)
  if handled then return lsp_response end

  if path == '/api/buffers/load' then
    local files = body.files
    if type(files) ~= 'table' or #files == 0 then
      if body.file and body.file ~= '' then
        files = { body.file }
      else
        return util.bad_request('files (array) or file is required')
      end
    end
    buffers.load_many_async(files, root(), body.timeout_ms, function(loaded, failed)
      respond(util.ok({ loaded = loaded, failed = failed }))
    end)
    return nil
  end

  if path == '/api/refresh' then
    local n = buffers.checktime()
    return util.ok({ ok = true, checked = n })
  end

  -- 自プロセスが listen している Diff Review / Code Notes 等をポート指定で止める。
  -- ports_panel が「nvim ごと kill せずサーバーだけ閉じる」ために叩く。
  -- nvim_api 自身を止める場合は応答を返したあとに schedule する（先に close すると書き戻せない）。
  if path == '/api/servers/stop' then
    local port = tonumber(body.port)
    if not port then return util.bad_request('port is required') end
    local owned = require('config.util.owned_servers')
    local provider = owned.find(port)
    if not provider then
      return util.not_found('no owned server on that port')
    end
    if provider.id == 'nvim_api' then
      vim.schedule(function() owned.stop(port) end)
      return util.ok({ stopped = true, id = provider.id, label = provider.label })
    end
    local stopped = owned.stop(port)
    return util.ok({ stopped = stopped, id = provider.id, label = provider.label })
  end

  return util.not_found()
end

--- ソケット非依存のルーティング本体。req = {method, path, query, body}
--- 文字列を返せば同期応答。nil を返した場合は respond(文字列) があとから呼ばれる。
function M.response_for_request(req, respond)
  respond = respond or function() end
  if req.method == 'GET' then return handle_get(req, respond) end
  if req.method == 'POST' then return handle_post(req, respond) end
  if req.method == 'OPTIONS' then
    return browser.http_response('204 No Content', 'text/plain', '')
  end
  return util.json_response('405 Method Not Allowed', { error = 'method not allowed' })
end

function M.is_running()
  return state.server ~= nil
end

function M.server_url()
  if not state.port then return nil end
  return 'http://localhost:' .. tostring(state.port) .. '/'
end

function M.stop()
  http.stop(state)
  state.started_at = nil
end

--- port で listen 開始。成功で true、失敗で false, err。
function M.start(port)
  if state.server and state.port == port then return true end
  if state.server then M.stop() end
  local ok, err = http.start(state, port, {
    namespace = 'nvim_api',
    default_host = '127.0.0.1', -- ローカルの AI からしか叩かせない(diff review と違い画面を出さない)
    handler = function(req, respond)
      local uv = vim.uv or vim.loop
      local watchdog = uv.new_timer()
      local answered = false

      -- 同期ルートも非同期ルートもここへ集約する。二重応答と応答漏れの両方をここで潰す。
      local function reply(resp)
        if answered then return end
        answered = true
        if watchdog then
          pcall(function() watchdog:stop() end)
          pcall(function() watchdog:close() end)
        end
        respond(resp)
      end

      if watchdog then
        watchdog:start(M.RESPONSE_TIMEOUT_MS, 0, function()
          vim.schedule(function()
            reply(util.json_response('504 Gateway Timeout', { error = 'request timed out inside nvim' }))
          end)
        end)
      end

      -- vim.api / vim.lsp を触るのでメインループへ戻してから処理する
      vim.schedule(function()
        local resp_ok, resp = pcall(M.response_for_request, req, reply)
        if not resp_ok then
          return reply(util.json_response('500 Internal Server Error', { error = tostring(resp) }))
        end
        if resp ~= nil then reply(resp) end
        -- resp が nil のときは非同期ルート。ハンドラ側が reply を呼ぶ。
      end)
      return nil
    end,
  })
  if ok then state.started_at = os.time() end
  return ok, err
end

M._private = {
  any_lsp_buf = any_lsp_buf,
  handle_lsp = handle_lsp,
}

return M
