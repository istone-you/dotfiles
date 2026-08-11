-- .http / .rest ファイルのパーサ
--
-- 対応する記法（VSCode REST Client / JetBrains の .http に寄せている）:
--   ###                        リクエストの区切り。### の後ろの文字列はリクエスト名
--   @name = value              ファイル変数。定義行より後ろ（同じブロック内も可）で使える
--   {{name}}                   変数の展開。組み込みは $env.NAME / $uuid / $timestamp /
--                              $datetime / $randomInt min max
--   # @name xxx                ディレクティブ（コメント行に書く）
--   # @follow / @insecure / @timeout 60
--   GET https://example.com HTTP/1.1
--   Header: value
--   （空行）
--   body...            ボディ全体を `< ./body.json` と書くとファイルから読む（runner.lua）
--
-- 変数の優先順位は「ファイル変数 > 環境ファイル」。環境を切り替えても効くように、
-- 共通の既定値は環境ファイル側に置く想定。
-- 環境ファイルは .http から親方向に探した http-client.env.json（{ 環境名 = { 変数名 = 値 } }）。
-- $shared は全環境にマージされ、http-client.private.env.json が同名キーを上書きするので、
-- トークン類は private 側に置いて .gitignore する運用を想定している。

local M = {}

M.METHODS = {
  GET = true, POST = true, PUT = true, PATCH = true, DELETE = true,
  HEAD = true, OPTIONS = true, TRACE = true, CONNECT = true,
}

M.ENV_FILES = { 'http-client.env.json', 'http-client.private.env.json' }
M.SHARED_ENV = '$shared'

local function trim(s)
  return (s:gsub('^%s*(.-)%s*$', '%1'))
end
M.trim = trim

-- ══════════════════════════════════════════════
-- パース
-- ══════════════════════════════════════════════

--- `GET https://example.com HTTP/1.1` → 'GET', 'https://example.com'
--- メソッド省略時は GET 扱い
function M.parse_request_line(line)
  local s = trim(line)
  s = s:gsub('%s+HTTP/%d[%.%d]*%s*$', '')
  local method, rest = s:match('^(%a+)%s+(.+)$')
  if method and M.METHODS[method:upper()] then
    return method:upper(), trim(rest)
  end
  return 'GET', s
end

--- バッファの行リストをパースして { requests = {...}, variables = {...} } を返す。
--- requests の各要素: { name, method, url, headers = {{k, v}, ...}, body, directives,
---                      start_line, end_line }（すべて1始まりの行番号）
function M.parse(lines)
  local doc = { requests = {}, variables = {} }
  local cur, section, pending = nil, nil, {}

  local function finish()
    if cur then
      while #cur.body_lines > 0 and trim(cur.body_lines[#cur.body_lines]) == '' do
        table.remove(cur.body_lines)
      end
      while #cur.body_lines > 0 and trim(cur.body_lines[1]) == '' do
        table.remove(cur.body_lines, 1)
      end
      -- URL の無いブロック（コメントだけ等）はリクエストとして扱わない
      if cur.url and cur.url ~= '' then
        cur.body = #cur.body_lines > 0 and table.concat(cur.body_lines, '\n') or nil
        cur.body_lines = nil
        table.insert(doc.requests, cur)
      end
    end
    cur, section = nil, nil
  end

  local function start(lnum, name)
    finish()
    cur = {
      name = name,
      start_line = lnum,
      end_line = lnum,
      headers = {},
      body_lines = {},
      directives = pending,
    }
    pending = {}
    section = 'request'
  end

  local function apply_directive(text)
    local key, rest = text:match('^@([%w%-_]+)%s*(.*)$')
    if not key then return end
    local d = cur and cur.directives or pending
    key = key:lower()
    if key == 'name' then
      d.name = trim(rest)
    elseif key == 'follow' then
      d.follow = true
    elseif key == 'insecure' then
      d.insecure = true
    elseif key == 'timeout' then
      d.timeout = tonumber(trim(rest))
    end
  end

  for i, raw in ipairs(lines) do
    local line = raw:gsub('\r$', '')
    if line:match('^%s*###') then
      local name = trim(line:match('^%s*###+(.*)$') or '')
      start(i, name ~= '' and name or nil)
    else
      if cur then cur.end_line = i end
      local in_body = (section == 'body')
      -- リクエストの直後（ボディがまだ空）に置かれた @var は、次のリクエスト向けの
      -- 変数定義とみなす。`### 区切り` を挟まない書き方でも変数を拾えるようにするため
      local body_started = in_body and cur and #cur.body_lines > 0
      local comment = not in_body and (line:match('^%s*#%s?(.*)$') or line:match('^%s*//%s?(.*)$'))
      local var_name, var_value = nil, nil
      if not comment and not body_started then
        var_name, var_value = line:match('^@([%w_%-%.]+)%s*=%s*(.*)$')
      end

      if comment then
        apply_directive(trim(comment))
      elseif var_name then
        table.insert(doc.variables, { name = var_name, value = trim(var_value), line = i })
      elseif trim(line) == '' then
        if section == 'headers' then
          section = 'body' -- 空行でヘッダ終わり → 次からボディ
        elseif in_body then
          table.insert(cur.body_lines, line)
        end
      else
        if not cur then
          start(i, nil)
          cur.end_line = i
        end
        if section == 'request' then
          cur.method, cur.url = M.parse_request_line(line)
          cur.request_line = i
          section = 'headers'
        elseif section == 'headers' then
          local cont = line:match('^%s+([?&].*)$') -- クエリ文字列の折り返し
          local hk, hv = line:match('^([%a][%w%-_]*)%s*:%s*(.*)$')
          if cont then
            cur.url = (cur.url or '') .. trim(cont)
          elseif hk then
            table.insert(cur.headers, { hk, trim(hv) })
          else
            -- ヘッダに見えない行が来たら空行が無くてもボディ開始とみなす
            section = 'body'
            table.insert(cur.body_lines, line)
          end
        else
          table.insert(cur.body_lines, line)
        end
      end
    end
  end
  finish()

  return doc
end

--- 指定行にカーソルがあるときに実行すべきリクエストを返す。
--- ブロック外（先頭の変数定義部など）にいる場合は直前 → 先頭の順でフォールバックする
function M.request_at(doc, lnum)
  local fallback = nil
  for _, req in ipairs(doc.requests) do
    if lnum >= req.start_line and lnum <= req.end_line then
      return req
    end
    if req.start_line <= lnum then
      fallback = req
    end
  end
  return fallback or doc.requests[1]
end

--- リクエストの表示名（### の見出し → # @name → METHOD URL の順）
function M.request_label(req)
  local name = (req.directives and req.directives.name) or req.name
  if name and name ~= '' then
    return name
  end
  return (req.method or 'GET') .. ' ' .. (req.url or '')
end

--- そのリクエストから見えるファイル変数（リクエスト行より前に定義されたもの）。
--- 同名を再定義した場合は、その定義より後ろのリクエストにだけ効く
function M.vars_for(doc, request)
  local limit = (request and (request.request_line or request.end_line)) or math.huge
  local out = {}
  for _, v in ipairs(doc.variables) do
    if v.line < limit then
      out[v.name] = v.value
    end
  end
  return out
end

-- ══════════════════════════════════════════════
-- 変数展開
-- ══════════════════════════════════════════════

function M.uuid()
  return (string.gsub('xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx', '[xy]', function(c)
    local v = (c == 'x') and math.random(0, 15) or math.random(8, 11)
    return string.format('%x', v)
  end))
end

--- 組み込み変数を解決する。第2戻り値が false なら組み込みではない（or 解決できない）
function M.dynamic_value(name)
  local env_name = name:match('^%$env%.(.+)$') or name:match('^%$env%s+(.+)$')
  if env_name then
    local v = os.getenv(trim(env_name))
    if v then return v, true end
    return nil, false
  end
  if name == '$uuid' then return M.uuid(), true end
  if name == '$timestamp' then return tostring(os.time()), true end
  if name == '$datetime' then return os.date('!%Y-%m-%dT%H:%M:%SZ'), true end
  local lo, hi = name:match('^%$randomInt%s+(%-?%d+)%s+(%-?%d+)$')
  if lo then
    return tostring(math.random(tonumber(lo), tonumber(hi))), true
  end
  return nil, false
end

--- {{...}} を展開する。ctx = { vars = ファイル変数, env = 環境ファイルの変数 }。
--- 戻り値は 展開後の文字列, 未解決だった変数名のリスト（未解決部分は {{name}} のまま残す）
function M.resolve(str, ctx, seen)
  ctx = ctx or {}
  seen = seen or {}
  local unresolved = {}
  local out = tostring(str):gsub('{{(.-)}}', function(token)
    local name = trim(token)
    local dyn, ok = M.dynamic_value(name)
    if ok then return dyn end

    if seen[name] then -- 循環参照
      table.insert(unresolved, name)
      return '{{' .. token .. '}}'
    end
    local val = (ctx.vars and ctx.vars[name])
    if val == nil then val = ctx.env and ctx.env[name] end
    if val == nil then
      table.insert(unresolved, name)
      return '{{' .. token .. '}}'
    end

    seen[name] = true
    local sub, errs = M.resolve(tostring(val), ctx, seen)
    seen[name] = nil
    vim.list_extend(unresolved, errs)
    return sub
  end)
  return out, unresolved
end

--- パース結果のリクエストを、変数展開済みの実行可能な形にする。
--- 戻り値は リクエスト, 未解決変数名のリスト（重複除去済み）
function M.build(request, ctx)
  local errors, seen_err = {}, {}
  local function res(s)
    local out, errs = M.resolve(s, ctx)
    for _, e in ipairs(errs) do
      if not seen_err[e] then
        seen_err[e] = true
        table.insert(errors, e)
      end
    end
    return out
  end

  local out = {
    label = M.request_label(request),
    method = request.method or 'GET',
    url = res(request.url or ''),
    headers = {},
    directives = request.directives or {},
    start_line = request.start_line,
  }
  for _, h in ipairs(request.headers or {}) do
    table.insert(out.headers, { h[1], res(h[2]) })
  end
  if request.body then
    out.body = res(request.body)
  end
  return out, errors
end

-- ══════════════════════════════════════════════
-- 環境ファイル（http-client.env.json）
-- ══════════════════════════════════════════════

-- シンボリックリンク（macOS の /var → /private/var 等）で表記がぶれると
-- 環境の選択状態を引けなくなるので、絶対パスに解決してから使う
local function normalize_dir(dir)
  local d = vim.fn.resolve(vim.fn.fnamemodify(dir or '.', ':p'))
  return (d:gsub('/+$', ''))
end

--- dir から上へ辿って環境ファイルのあるディレクトリを探す
function M.find_env_dir(dir)
  local d = normalize_dir(dir)
  for _ = 1, 30 do
    for _, f in ipairs(M.ENV_FILES) do
      if vim.fn.filereadable(d .. '/' .. f) == 1 then return d end
    end
    local parent = vim.fn.fnamemodify(d, ':h')
    if parent == d or parent == '' then break end
    d = parent
  end
  return nil
end

--- 環境ファイルを読む。戻り値は { dir = ..., envs = { 環境名 = { 変数名 = 値 } } }, エラー文字列
function M.load_env_file(dir)
  local env_dir = M.find_env_dir(dir)
  if not env_dir then return nil end

  local envs = {}
  for _, f in ipairs(M.ENV_FILES) do
    local path = env_dir .. '/' .. f
    if vim.fn.filereadable(path) == 1 then
      local text = table.concat(vim.fn.readfile(path), '\n')
      local ok, decoded = pcall(vim.json.decode, text)
      if not ok or type(decoded) ~= 'table' then
        return nil, path .. ' の JSON を読めませんでした'
      end
      for name, vars in pairs(decoded) do
        if type(vars) == 'table' then
          -- private 側が後勝ちで上書きする
          envs[name] = vim.tbl_extend('force', envs[name] or {}, vars)
        end
      end
    end
  end
  return { dir = env_dir, envs = envs }
end

--- 選択できる環境名（$shared を除いたソート済みリスト）
function M.env_names(dir)
  local loaded = M.load_env_file(dir)
  if not loaded then return {} end
  local names = {}
  for name in pairs(loaded.envs) do
    if name ~= M.SHARED_ENV then table.insert(names, name) end
  end
  table.sort(names)
  return names
end

--- 指定環境の変数（$shared にマージ）。値は文字列化して返す
function M.env_vars(dir, env_name)
  local loaded, err = M.load_env_file(dir)
  if not loaded then return {}, err end

  local out = {}
  local function merge(tbl)
    for k, v in pairs(tbl or {}) do
      if type(v) ~= 'table' then out[k] = tostring(v) end
    end
  end
  merge(loaded.envs[M.SHARED_ENV])
  if env_name then merge(loaded.envs[env_name]) end
  return out
end

return M
