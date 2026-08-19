-- Code Notes HTTP server.

local M = {}
local browser = require('config.browser.util')
local http = require('config.browser.server')
local entries = require('config.code_notes.entries')
local web = require('config.code_notes.web')

local state = {
  server = nil,
  port = nil,
  host = nil,
  repo_root = nil,
}

M.state = state

local function json_response(status, tbl)
  return browser.http_response(status, 'application/json', vim.json.encode(tbl))
end

local function parse_query(query)
  local out = {}
  for pair in tostring(query or ''):gmatch('[^&]+') do
    local k, v = pair:match('^([^=]+)=?(.*)$')
    if k then out[browser.url_decode(k)] = browser.url_decode(v) end
  end
  return out
end

local function decode_body(body)
  if not body or body == '' then return {} end
  local ok, decoded = pcall(vim.json.decode, body)
  if not ok or type(decoded) ~= 'table' then return nil end
  return decoded
end

local VENDOR_FILES = {
  ['highlight.min.js'] = true,
  ['highlight-theme.css'] = true,
}

local function real(path)
  local p = vim.fs.normalize(tostring(path or ''))
  if p == '' then return nil end
  p = vim.fn.fnamemodify(p, ':p')
  local resolved = vim.fn.resolve(p)
  if resolved and resolved ~= '' then p = resolved end
  return (p:gsub('(.)/$', '%1'))
end

local function abs_path(file)
  local p = vim.fs.normalize(tostring(file or ''))
  if p == '' then return nil, 'file is required' end
  if p:sub(1, 1) ~= '/' then p = vim.fs.normalize((state.repo_root or vim.fn.getcwd()) .. '/' .. p) end
  local abs = real(p)
  local root = real(state.repo_root or vim.fn.getcwd())
  if abs ~= root and abs:sub(1, #root + 1) ~= root .. '/' then
    return nil, 'path is outside the repository root: ' .. abs
  end
  return abs
end

local function validate_entry(body)
  if type(body) ~= 'table' then return 'entry item must be an object' end
  local line = tonumber(body.line)
  local line_end = tonumber(body.lineEnd) or tonumber(body.endLine) or tonumber(body.line_end)
  if line_end and not line then return 'line is required when lineEnd is given' end
  if line and line_end and line_end < line then return 'lineEnd must be greater than or equal to line' end
  if body.file and body.file ~= '' then
    local _, err = abs_path(body.file)
    if err then return err end
  end
  return nil
end

local function jump(body)
  local abs, err = abs_path(body.file)
  if not abs then return nil, err end
  if vim.fn.filereadable(abs) ~= 1 then return nil, 'file not readable: ' .. abs end
  local ok = pcall(function()
    local win_util = require('config.util.win_util')
    local bufnr = vim.fn.bufnr(abs)
    local target
    if bufnr > 0 then
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if win_util.is_editor(win) and vim.api.nvim_win_get_buf(win) == bufnr then
          target = win
          break
        end
      end
    else
      bufnr = nil
    end
    if target then
      vim.api.nvim_set_current_win(target)
    else
      win_util.focus_editor()
      vim.cmd('edit ' .. vim.fn.fnameescape(abs))
      bufnr = vim.api.nvim_get_current_buf()
    end
    vim.bo[bufnr].buflisted = true
    vim.api.nvim_win_set_cursor(0, {
      math.max(tonumber(body.line) or 1, 1),
      math.max((tonumber(body.col) or 1) - 1, 0),
    })
    vim.cmd('normal! zz')
  end)
  if not ok then return nil, 'failed to jump' end
  return true
end

local function code_context(entry)
  if type(entry) ~= 'table' or not entry.file or not entry.line then return vim.NIL end
  local abs = abs_path(entry.file)
  if not abs then return vim.NIL end
  local stat = (vim.uv or vim.loop).fs_stat(abs)
  if not stat or stat.type ~= 'file' or stat.size > 1024 * 1024 then return vim.NIL end
  local fh = io.open(abs, 'r')
  if not fh then return vim.NIL end
  local lines = {}
  for line in fh:lines() do
    lines[#lines + 1] = line
  end
  fh:close()
  local line = math.max(tonumber(entry.line) or 1, 1)
  if line > #lines then return vim.NIL end
  local line_end = math.max(tonumber(entry.lineEnd) or line, line)
  line_end = math.min(line_end, #lines)
  local start_line = math.max(line - 3, 1)
  local end_line = math.min(line_end + 3, #lines)
  return {
    startLine = start_line,
    endLine = end_line,
    highlightLine = line,
    highlightEndLine = line_end,
    text = table.concat(vim.list_slice(lines, start_line, end_line), '\n'),
  }
end

local function with_code(entry)
  local out = vim.deepcopy(entry)
  local ok, code = pcall(code_context, out)
  out.code = ok and code or vim.NIL
  return out
end

local function with_code_list(list)
  local out = {}
  for _, f in ipairs(list or {}) do
    out[#out + 1] = with_code(f)
  end
  return out
end

function M.set_session(opts)
  opts = opts or {}
  if opts.repo_root ~= nil then state.repo_root = opts.repo_root end
end

local function handle_get(req)
  if req.path == '/' or req.path == '/index.html' then
    return browser.http_response('200 OK', 'text/html', web.render({ repo_root = state.repo_root }))
  end
  local vf = req.path:match('^/__vendor/([%w._-]+)$')
  if vf and VENDOR_FILES[vf] then
    return browser.vendor_response(vf)
  end
  if req.path == '/__version' then
    return browser.http_response('200 OK', 'text/plain', tostring(entries.version()))
  end
  if req.path == '/api/session' then
    return json_response('200 OK', {
      repoRoot = state.repo_root,
      port = state.port,
      version = entries.version(),
    })
  end
  if req.path == '/api/entries' then
    local q = parse_query(req.query)
    return json_response('200 OK', {
      entries = with_code_list(entries.list({ file = q.file })),
      version = entries.version(),
    })
  end
  return json_response('404 Not Found', { error = 'not found' })
end

local function jump_response(body)
  local ok, err = jump(body)
  if not ok then return json_response('400 Bad Request', { error = err }) end
  return json_response('200 OK', { ok = true })
end

local function handle_post(req, respond)
  local body = decode_body(req.body)
  if body == nil then return json_response('400 Bad Request', { error = 'invalid JSON body' }) end

  if req.path == '/api/entries' then
    local err = validate_entry(body)
    if err then return json_response('400 Bad Request', { error = err }) end
    local entry, add_err = entries.add(body)
    if not entry then return json_response('400 Bad Request', { error = add_err }) end
    return json_response('200 OK', { entry = with_code(entry) })
  end
  if req.path == '/api/entries/set' then
    if type(body.items) ~= 'table' then return json_response('400 Bad Request', { error = 'items (array) is required' }) end
    for _, it in ipairs(body.items) do
      local err = validate_entry(it)
      if err then return json_response('400 Bad Request', { error = err }) end
    end
    local n = entries.set(body.items)
    return json_response('200 OK', { ok = true, count = n })
  end
  if req.path == '/api/entries/update' then
    local err = validate_entry(body)
    if err then return json_response('400 Bad Request', { error = err }) end
    local entry, update_err = entries.update(body)
    if not entry then return json_response('404 Not Found', { error = update_err }) end
    return json_response('200 OK', { entry = with_code(entry) })
  end
  if req.path == '/api/entries/status' then
    local entry, err = entries.set_status(body.id, body.status)
    if not entry then return json_response(err == 'entry not found' and '404 Not Found' or '400 Bad Request', { error = err }) end
    return json_response('200 OK', { entry = with_code(entry) })
  end
  if req.path == '/api/entries/comment' then
    local entry, comment_or_err = entries.add_comment(body)
    if not entry then
      local status = comment_or_err == 'entry not found' and '404 Not Found' or '400 Bad Request'
      return json_response(status, { error = comment_or_err })
    end
    return json_response('200 OK', { entry = with_code(entry), comment = comment_or_err })
  end
  if req.path == '/api/entries/comment/delete' then
    local entry, err = entries.remove_comment(body.id or body.entryId, body.commentId)
    if not entry then return json_response(err == 'entry not found' and '404 Not Found' or '400 Bad Request', { error = err }) end
    return json_response('200 OK', { entry = with_code(entry) })
  end
  if req.path == '/api/entries/delete' then
    if entries.remove(body.id) then return json_response('200 OK', { ok = true }) end
    return json_response('404 Not Found', { error = 'entry not found' })
  end
  if req.path == '/api/entries/clear' then
    entries.clear()
    return json_response('200 OK', { ok = true })
  end
  if req.path == '/api/jump' then
    if respond then
      vim.schedule(function() respond(jump_response(body)) end)
      return nil
    end
    return jump_response(body)
  end
  return json_response('404 Not Found', { error = 'not found' })
end

function M.response_for_request(req, respond)
  if req.method == 'GET' then return handle_get(req) end
  if req.method == 'POST' then return handle_post(req, respond) end
  if req.method == 'OPTIONS' then return browser.http_response('204 No Content', 'text/plain', '') end
  return json_response('405 Method Not Allowed', { error = 'method not allowed' })
end

function M.is_running()
  return state.server ~= nil
end

function M.server_url()
  if not state.port then return nil end
  return 'http://localhost:' .. tostring(state.port) .. '/'
end

function M.start(port)
  if state.server and state.port == port then return true end
  if state.server then M.stop() end
  return http.start(state, port, {
    namespace = 'code_notes',
    default_host = '127.0.0.1',
    handler = function(req, respond) return M.response_for_request(req, respond) end,
  })
end

function M.stop()
  http.stop(state)
end

M._private = {
  parse_query = parse_query,
  decode_body = decode_body,
  abs_path = abs_path,
  code_context = code_context,
  json_response = json_response,
}

return M
