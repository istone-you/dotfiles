local M = {}

local function notify(msg, level, title)
  vim.notify(msg, level or vim.log.levels.INFO, { title = title or 'Browser' })
end

function M.local_config()
  local path = vim.fn.stdpath('config') .. '/local.lua'
  if vim.fn.filereadable(path) ~= 1 then return {} end
  local ok, result = pcall(dofile, path)
  if not ok or type(result) ~= 'table' then return {} end
  return result
end

function M.config(namespace)
  local local_cfg = M.local_config()
  local browser_cfg = type(local_cfg.browser) == 'table' and local_cfg.browser or {}
  local base = {}
  for k, v in pairs(browser_cfg) do
    if type(v) ~= 'table' then base[k] = v end
  end
  local scoped = namespace and type(browser_cfg[namespace]) == 'table' and browser_cfg[namespace] or {}
  return vim.tbl_extend('force', base, scoped)
end

-- 既定 opener の探索順。Linux は xdg-open、macOS は open。
local DEFAULT_OPENERS = { 'xdg-open', 'open' }

-- opener にこの値を指定すると、terminal-browser も OS の opener も使わず URL を通知するだけにする。
M.NO_OPEN = 'none'

function M.find_opener(namespace)
  local cfg = M.config(namespace)
  if cfg.opener == M.NO_OPEN then return nil end
  if type(cfg.opener) == 'string' and cfg.opener ~= '' then
    if vim.fn.executable(cfg.opener) == 1 then return cfg.opener end
    return nil
  end
  for _, opener in ipairs(DEFAULT_OPENERS) do
    if vim.fn.executable(opener) == 1 then return opener end
  end
end

function M.build_opener_cmd(opener, url)
  return { opener, url }
end

--- OS の opener (xdg-open / open) で開く。開けなければ URL を通知して false。
local function open_with_os(url, opts)
  local opener = M.find_opener(opts.namespace)
  local title = opts.title or 'Browser'
  if not opener then
    notify((opts.fallback_message or 'Browser URL: ') .. url .. ' (opener not found)', vim.log.levels.WARN, title)
    return false
  end

  local job = vim.fn.jobstart(M.build_opener_cmd(opener, url), { detach = true })
  if job <= 0 then
    notify((opts.fallback_message or 'Browser URL: ') .. url .. ' (failed to start ' .. opener .. ')', vim.log.levels.WARN, title)
    return false
  end
  return url
end

--- プレビュー URL を開く。
--- herdr セッションの中で terminal-browser があるときは、別アプリのブラウザではなく
--- 右ペインの terminal-browser で開く(あれば再利用、無ければ右に split して起動)。
--- terminal-browser 側は非同期なので、その経路に倒した時点で url を返す。
--- local.lua で opener を明示している場合はその指定を優先する。
--- opener が 'none' のときは何も起動せず URL を通知するだけにする。
function M.open_url(url, opts)
  opts = opts or {}
  local title = opts.title or 'Browser'
  local cfg = M.config(opts.namespace)

  if cfg.opener == M.NO_OPEN then
    notify((opts.fallback_message or 'Browser URL: ') .. url, vim.log.levels.INFO, title)
    return url
  end

  if type(cfg.opener) ~= 'string' or cfg.opener == '' then
    local tb = require('config.browser.terminal_browser')
    if tb.available() then
      tb.open(url, function(ok, err)
        if ok then return end
        notify('terminal-browser で開けませんでした: ' .. (err or ''), vim.log.levels.WARN, title)
        open_with_os(url, opts)
      end)
      return url
    end
  end

  return open_with_os(url, opts)
end

function M.url_decode(s)
  s = tostring(s or ''):gsub('+', ' ')
  return (s:gsub('%%(%x%x)', function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

function M.url_encode_path(s)
  return (tostring(s or ''):gsub('[^%w%-%._~/%#:%?&=]', function(c)
    return string.format('%%%02X', c:byte())
  end))
end

function M.http_response(status, content_type, body, cache_control)
  body = body or ''
  return table.concat({
    'HTTP/1.1 ' .. status,
    'Content-Type: ' .. content_type .. '; charset=utf-8',
    'Content-Length: ' .. tostring(#body),
    'Cache-Control: ' .. (cache_control or 'no-store'),
    'Connection: close',
    '',
    body,
  }, '\r\n')
end

--- ポート入力文字列を数値へ。空文字は「キャンセル」として nil, nil を返す。
--- 不正な入力は nil, エラーメッセージ。
function M.parse_port(input)
  input = vim.trim(tostring(input or ''))
  if input == '' then return nil, nil end
  if not input:match('^%d+$') then return nil, 'port must be a number' end
  local port = tonumber(input)
  if not port or port < 1 or port > 65535 then
    return nil, 'port must be between 1 and 65535'
  end
  return port
end

local CONTENT_TYPES = {
  css = 'text/css',
  gif = 'image/gif',
  htm = 'text/html',
  html = 'text/html',
  ico = 'image/x-icon',
  jpeg = 'image/jpeg',
  jpg = 'image/jpeg',
  js = 'application/javascript',
  json = 'application/json',
  map = 'application/json',
  png = 'image/png',
  svg = 'image/svg+xml',
  txt = 'text/plain',
  webp = 'image/webp',
  woff = 'font/woff',
  woff2 = 'font/woff2',
}

function M.content_type_for(path)
  local ext = tostring(path or ''):match('%.([%w]+)$')
  return (ext and CONTENT_TYPES[ext:lower()]) or 'application/octet-stream'
end

--- root_dir 配下のファイルを /__asset/<相対パス> として返す(画像などの相対リンク用)。
--- 絶対パス・`..`・NUL は 403。root の外に出る解決結果も 403。
---
--- `./` を含んだまま `:p` に渡すと macOS では symlink が解決されて
--- /var/... が /private/var/... になり、root との前方一致が誤って外れる。
--- 先に normalize して root と同じパス表現に揃える(`..` は上で弾き済み)。
function M.asset_response(root_dir, asset_path)
  if not root_dir then return M.http_response('404 Not Found', 'text/plain', 'not found') end
  asset_path = M.url_decode(asset_path or ''):gsub('%?.*$', ''):gsub('#.*$', '')
  if asset_path == '' or asset_path:find('%z') or asset_path:match('^/') or asset_path:match('%.%.') then
    return M.http_response('403 Forbidden', 'text/plain', 'forbidden')
  end

  local full = vim.fn.fnamemodify(vim.fs.normalize(root_dir .. '/' .. asset_path), ':p')
  local root = vim.fn.fnamemodify(vim.fs.normalize(root_dir), ':p')
  if full:sub(1, #root) ~= root then
    return M.http_response('403 Forbidden', 'text/plain', 'forbidden')
  end
  if vim.fn.filereadable(full) ~= 1 then
    return M.http_response('404 Not Found', 'text/plain', 'not found')
  end

  local f = io.open(full, 'rb')
  if not f then return M.http_response('404 Not Found', 'text/plain', 'not found') end
  local body = f:read('*a')
  f:close()
  return M.http_response('200 OK', M.content_type_for(full), body)
end

-- 同梱アセット(nvim/vendor/*)の絶対パスを、このファイルからの相対で解決する。
-- runtimepath に依存しないので、テストハーネス(require 経由)でも同じように解決できる。
-- .../nvim/lua/config/browser/util.lua -> .../nvim/vendor/<name>
function M.vendor_file(name)
  local src = (debug.getinfo(1, 'S').source or ''):gsub('^@', '')
  if src == '' then return nil end
  local dir = vim.fn.fnamemodify(src, ':p:h')
  return vim.fn.fnamemodify(dir .. '/../../../vendor/' .. name, ':p')
end

-- 同梱アセットを immutable キャッシュ付きで返す(バージョン固定なので再取得を避ける)。
-- ホワイトリスト判定は呼び出し側で行う(パストラバーサル防止)。ファイルは要求時にだけ読む。
function M.vendor_response(name)
  local path = M.vendor_file(name)
  if not path or vim.fn.filereadable(path) ~= 1 then
    return M.http_response('404 Not Found', 'text/plain', 'not found')
  end
  local f = io.open(path, 'rb')
  if not f then return M.http_response('404 Not Found', 'text/plain', 'not found') end
  local content = f:read('*a')
  f:close()
  return M.http_response('200 OK', M.content_type_for(path), content, 'public, max-age=31536000, immutable')
end

return M
