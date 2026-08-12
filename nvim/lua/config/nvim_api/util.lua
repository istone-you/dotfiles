-- nvim_api 共通の小物。HTTP レスポンス生成・クエリ/ボディの解釈・パス正規化。
--
-- パスの扱いは CLAUDE.md のルールに従う。ここでは「実体パスへ寄せる」側を選び、
-- vim.fn.resolve() を **両辺に等しく** かけている(M.real)。
-- 理由: この API はパスの片側を nvim(バッファ名)、もう片側を外部の AI から受け取る。
-- macOS では nvim がバッファ名を /private/var/... に解決して持つのに対し、AI が渡してくる
-- パスや vim.fn.tempname() は /var/... のままなので、resolve しないと同じファイルが
-- 別物に見えて「診断が空で返る」という分かりにくい失敗になる。

local M = {}
local browser = require('config.browser.util')

function M.json_response(status, tbl)
  return browser.http_response(status, 'application/json', vim.json.encode(tbl))
end

function M.ok(tbl) return M.json_response('200 OK', tbl) end
function M.bad_request(msg) return M.json_response('400 Bad Request', { error = msg }) end
function M.not_found(msg) return M.json_response('404 Not Found', { error = msg or 'not found' }) end

--- ANSI 付きプレビューなど、JSON でなく生テキストで返す用。
function M.text(body) return browser.http_response('200 OK', 'text/plain', body or '') end

-- "a=1&b=hi%20there" -> { a='1', b='hi there' }
function M.parse_query(query)
  local out = {}
  for pair in tostring(query or ''):gmatch('[^&]+') do
    local k, v = pair:match('^([^=]+)=?(.*)$')
    if k then out[browser.url_decode(k)] = browser.url_decode(v) end
  end
  return out
end

--- JSON ボディを table へ。空ボディは {}、壊れていれば nil(呼び出し側で 400 にする)。
function M.decode_body(body)
  if not body or body == '' then return {} end
  local ok, decoded = pcall(vim.json.decode, body)
  if not ok or type(decoded) ~= 'table' then return nil end
  return decoded
end

--- "1"/"true"/"yes" を true とみなす。nil のときは default。
function M.truthy(v, default)
  if v == nil or v == '' then return default end
  if type(v) == 'boolean' then return v end
  local s = tostring(v):lower()
  return s == '1' or s == 'true' or s == 'yes' or s == 'on'
end

function M.to_number(v, default)
  local n = tonumber(v)
  if n == nil then return default end
  return n
end

--- タイマーに渡すミリ秒。AI から来る JSON はどんな型でも来るので、必ずここを通すこと。
--- 数値でない/負の値をそのまま uv タイマーや比較に渡すと、実行時エラーがコールバックの
--- 中で毎 tick 起き続け、finish() にも close() にも到達しないループになる。
function M.timeout_ms(v, default)
  local n = tonumber(v)
  if n == nil or n < 0 then return default end
  return n
end

--- root の外を許すか。既定は禁止。
--- この API はローカルの AI から叩かれる前提で、サンドボックスされたエージェントが
--- リポジトリ外のファイルを nvim に読ませる抜け道にならないようにするため。
--- 意図的に外を触りたい場合だけ vim.g.nvim_api_allow_outside_root = true にする。
function M.allow_outside_root()
  return vim.g.nvim_api_allow_outside_root == true
end

--- クライアントが指定したパスを検証しつつ絶対パスへ。
--- 既定では root の外(絶対パス指定・../ による脱出のどちらも)を拒否する。
--- LSP が返してきたパス(定義元が GOPATH や stdlib にある等)はここを通さない。
--- あれは結果であって入力ではないので、root 外でもそのまま返してよい。
---@return string|nil abs
---@return string|nil err
function M.client_path(file, root)
  local abs = M.abs_path(file, root)
  if not abs then return nil, 'file is required' end
  if M.allow_outside_root() then return abs end
  local base = M.normalize_root(root)
  if abs ~= base and abs:sub(1, #base + 1) ~= base .. '/' then
    return nil, 'path is outside the repository root: ' .. abs
  end
  return abs
end

--- パス比較の唯一の正規形。normalize -> :p -> resolve の順に通し、末尾の / を落とす。
--- 比較する両辺を必ずこれに通すこと(片方だけだと macOS で /var と /private/var に割れる)。
function M.real(path)
  local p = vim.fs.normalize(tostring(path or ''))
  if p == '' then return nil end
  p = vim.fn.fnamemodify(p, ':p')
  local resolved = vim.fn.resolve(p)
  if resolved ~= nil and resolved ~= '' then p = resolved end
  return (p:gsub('(.)/$', '%1'))
end

--- リポジトリ root(なければ cwd)。起動時に一度解決して init 側から与える。
--- 与えられていないときは cwd に倒す。
function M.normalize_root(root)
  local base = (root and root ~= '') and root or vim.fn.getcwd()
  return M.real(base)
end

--- API で受け取ったパス(root 相対 or 絶対)を絶対パスへ。
function M.abs_path(file, root)
  local p = vim.fs.normalize(tostring(file or ''))
  if p == '' then return nil end
  if p:sub(1, 1) ~= '/' then
    p = vim.fs.normalize(M.normalize_root(root) .. '/' .. p)
  end
  return M.real(p)
end

--- 絶対パスを root 相対へ(root 外ならそのまま絶対で返す)。
function M.rel_path(path, root)
  local abs = M.real(path)
  if not abs then return '' end
  local prefix = M.normalize_root(root) .. '/'
  if abs:sub(1, #prefix) == prefix then return abs:sub(#prefix + 1) end
  return abs
end

--- ファイルの指定行(1-based)を読む。バッファに載っていればそちらを、無ければディスクから。
--- 位置だけ返しても AI 側で結局読みに行くことになるので、locations には行テキストを添える。
function M.line_text(abs_path, lnum)
  if not abs_path or not lnum or lnum < 1 then return nil end
  local bufnr = vim.fn.bufnr(abs_path)
  if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) then
    local lines = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)
    if lines and lines[1] then return vim.trim(lines[1]) end
    return nil
  end
  if vim.fn.filereadable(abs_path) ~= 1 then return nil end
  local ok, lines = pcall(vim.fn.readfile, abs_path, '', lnum)
  if not ok or type(lines) ~= 'table' or not lines[lnum] then return nil end
  return vim.trim(lines[lnum])
end

--- vim.NIL にしておくと JSON では null になる(キーごと消えるより AI が読みやすい)。
function M.or_null(v)
  if v == nil then return vim.NIL end
  return v
end

return M
