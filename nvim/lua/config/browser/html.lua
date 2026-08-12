local M = {}
local browser = require('config.browser.util')
local http = require('config.browser.server')

local state = {
  source_buf = nil,
  html = nil,
  version = 0,
  server = nil,
  port = nil,
  host = nil,
  root_dir = nil,
  entry_name = nil,
}

local augrp = vim.api.nvim_create_augroup('browser_html', { clear = true })
local exiting = false

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'HTML Browser Preview' })
end

local function parse_port(input)
  input = vim.trim(tostring(input or ''))
  if input == '' then return nil, nil end
  if not input:match('^%d+$') then return nil, 'port must be a number' end
  local port = tonumber(input)
  if not port or port < 1 or port > 65535 then
    return nil, 'port must be between 1 and 65535'
  end
  return port
end

local function is_html_path(path)
  local ext = vim.fn.fnamemodify(path or '', ':e'):lower()
  return ext == 'html' or ext == 'htm'
end

local function set_preview_html(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' then
    notify('HTML preview requires a named .html file', vim.log.levels.WARN)
    return false
  end
  if not is_html_path(name) and vim.bo[buf].filetype ~= 'html' then
    notify('HTML preview is only for .html files', vim.log.levels.WARN)
    return false
  end

  state.source_buf = buf
  state.root_dir = vim.fn.fnamemodify(name, ':p:h')
  state.entry_name = vim.fn.fnamemodify(name, ':t')
  state.version = state.version + 1
  state.html = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
  return true
end

local function server_url()
  if not state.port then return nil end
  return 'http://localhost:' .. tostring(state.port) .. '/'
end

local function file_response(rel_path)
  if not state.root_dir then return browser.http_response('404 Not Found', 'text/plain', 'not found') end
  rel_path = browser.url_decode(rel_path or ''):gsub('%?.*$', ''):gsub('#.*$', '')
  if rel_path == '' or rel_path:find('%z') or rel_path:match('^/') or rel_path:match('%.%.') then
    return browser.http_response('403 Forbidden', 'text/plain', 'forbidden')
  end

  -- `./` を含んだまま `:p` に渡すと macOS では symlink が解決されて
  -- /var/... が /private/var/... になり、root との前方一致が誤って外れる。
  -- 先に normalize して root と同じパス表現に揃える（`..` は上で弾き済み）
  local full = vim.fn.fnamemodify(vim.fs.normalize(state.root_dir .. '/' .. rel_path), ':p')
  local root = vim.fn.fnamemodify(vim.fs.normalize(state.root_dir), ':p')
  if full:sub(1, #root) ~= root then
    return browser.http_response('403 Forbidden', 'text/plain', 'forbidden')
  end
  if vim.fn.filereadable(full) ~= 1 then
    return browser.http_response('404 Not Found', 'text/plain', 'not found')
  end

  local f = io.open(full, 'rb')
  if not f then return browser.http_response('404 Not Found', 'text/plain', 'not found') end
  local body = f:read('*a')
  f:close()
  return browser.http_response('200 OK', browser.content_type_for(full), body)
end

-- 配信するのはユーザーが書いた HTML そのものなので、markdown 側のように生成時へ
-- リロード用スクリプトを混ぜ込めない。配信の直前に差し込む。
-- 比較用の version は「そのページを返した時点の値」を文字列として焼き込むだけで、
-- markdown のように <meta> を経由しない(ユーザーの <head> を触らずに済ませるため)。
local function live_reload_script(version)
  return table.concat({
    '<script>',
    '(function(){var v="' .. tostring(version) .. '";',
    'setInterval(function(){fetch("/__version").then(function(r){return r.text();})',
    '.then(function(n){if(n.trim()!==v)location.reload();}).catch(function(){});},1000);})();',
    '</script>',
  })
end

local function last_index_of(haystack, needle)
  local idx, from = nil, 1
  while true do
    local s = haystack:find(needle, from, true)
    if not s then break end
    idx, from = s, s + 1
  end
  return idx
end

-- 閉じタグの「最後の」出現の直前へ入れる(</body> を優先、無ければ </html>)。
-- どちらも持たない断片 HTML はブラウザが暗黙に body を作るので末尾に足すだけでよい。
local function inject_live_reload(html, version)
  local script = live_reload_script(version)
  local pos = last_index_of(html:lower(), '</body>') or last_index_of(html:lower(), '</html>')
  if not pos then return html .. script end
  return html:sub(1, pos - 1) .. script .. html:sub(pos)
end

local function response_for_path(path)
  path = (path or '/'):gsub('%?.*$', ''):gsub('#.*$', '')
  if path == '/__version' then
    return browser.http_response('200 OK', 'text/plain', tostring(state.version))
  end
  if path == '/' or path == '/index.html' or path == '/' .. tostring(state.entry_name or '') then
    local body = state.html or '<!doctype html><title>HTML Preview</title>'
    return browser.http_response('200 OK', 'text/html', inject_live_reload(body, state.version))
  end
  return file_response(path:gsub('^/', ''))
end

local function stop_server(opts)
  opts = opts or {}
  local port = state.port
  local had_server = state.server ~= nil
  http.stop(state) -- state.server/port/host をクリア
  -- ポートの付け替え(start_server 経由)では紐付けを残す。ここで無条件に nil にすると
  -- BufWritePost の `state.source_buf == ev.buf` が二度と成立せず、
  -- 保存してもプレビューが開いた時点のまま固まる。
  if not opts.keep_source_buf then state.source_buf = nil end
  if had_server and opts.notify ~= false and not exiting then
    local suffix = port and (': http://localhost:' .. tostring(port) .. '/') or ''
    vim.schedule(function()
      if not exiting then notify('HTML previewを停止しました' .. suffix) end
    end)
  end
end

local function start_server(port)
  if state.server and state.port == port then return true end
  if state.server and state.port ~= port then stop_server({ keep_source_buf = true }) end
  return http.start(state, port, {
    namespace = 'html',
    default_host = '0.0.0.0',
    handler = function(req) return response_for_path(req.path) end,
  })
end

function M.open_on_port(port)
  local source_buf = vim.api.nvim_get_current_buf()
  if not set_preview_html(source_buf) then return end
  local ok, err = start_server(port)
  if not ok then
    notify(err or 'failed to start html preview server', vim.log.levels.ERROR)
    return
  end
  local url = server_url()
  browser.open_url(url, {
    fallback_message = 'HTML preview URL: ',
    namespace = 'html',
    title = 'HTML Browser Preview',
  })
  notify('HTML preview URL: ' .. url)
end

function M.open()
  vim.ui.input({
    prompt = 'HTML preview port: ',
  }, function(input)
    if input == nil then return end
    local port, err = parse_port(input)
    if not port then
      notify(err, vim.log.levels.ERROR)
      return
    end
    M.open_on_port(port)
  end)
end

function M.refresh(opts)
  opts = opts or {}
  local source_buf = state.source_buf
  if not source_buf or not vim.api.nvim_buf_is_valid(source_buf) then
    source_buf = vim.api.nvim_get_current_buf()
  end
  if not set_preview_html(source_buf) then return end
  if not opts.silent then
    local url = server_url()
    notify(url and ('Updated HTML preview: ' .. url) or 'Updated HTML preview')
  end
end

vim.api.nvim_create_autocmd('BufWritePost', {
  group = augrp,
  pattern = { '*.html', '*.htm' },
  callback = function(ev)
    if state.source_buf == ev.buf and state.server then M.refresh({ silent = true }) end
  end,
})

vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
  group = augrp,
  callback = function(ev)
    if state.source_buf == ev.buf and state.server then stop_server() end
  end,
})

vim.api.nvim_create_autocmd('VimLeavePre', {
  group = augrp,
  callback = function()
    exiting = true
  end,
})

M._private = {
  file_response = file_response,
  inject_live_reload = inject_live_reload,
  parse_port = parse_port,
  response_for_path = response_for_path,
  server_url = server_url,
  set_preview_html = set_preview_html,
  start_server = start_server,
  state = state,
  stop_server = stop_server,
}

return M
