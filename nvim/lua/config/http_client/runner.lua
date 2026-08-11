-- curl コマンドの組み立てと非同期実行
-- Requirements: curl

local M = {}

M.DEFAULT_TIMEOUT = 30

-- curl の -w は %{stderr} 以降を stderr へ書くので、ボディ（stdout）を汚さずに
-- ステータス・所要時間・サイズを受け取れる
local STATS_FORMAT = '%{stderr}\n__NVIM_HTTP_STATS__ %{http_code} %{time_total} %{size_download}\n'

local function shell_quote(s)
  if s:match("^[%w%._%-/:@=,%+]+$") then return s end
  return "'" .. s:gsub("'", [['\'']]) .. "'"
end

--- ボディが `< ./file.json` 形式ならファイルを読んで中身に置き換える。
--- 戻り値は ボディ, エラー文字列
function M.resolve_body(body, dir)
  if not body then return nil end
  local path = body:match('^%s*<%s*(%S+)%s*$')
  if not path then return body end

  if not path:match('^[/~]') then
    path = (dir or vim.fn.getcwd()) .. '/' .. path
  end
  path = vim.fn.fnamemodify(vim.fn.expand(path), ':p')
  if vim.fn.filereadable(path) ~= 1 then
    return nil, 'ボディのファイルを読めません: ' .. path
  end
  return table.concat(vim.fn.readfile(path, 'b'), '\n')
end

--- 実行する curl の引数リストを組み立てる
function M.build_curl(req, opts)
  opts = opts or {}
  local d = req.directives or {}
  local args = { 'curl', '-sS', '-g' } -- -g: URL の [] {} を curl のグロブとして解釈させない

  if req.method == 'HEAD' then
    table.insert(args, '-I') -- -X HEAD はボディ待ちで固まるため -I を使う
  else
    table.insert(args, '-i')
    table.insert(args, '-X')
    table.insert(args, req.method or 'GET')
  end
  if d.follow then table.insert(args, '-L') end
  if d.insecure then table.insert(args, '-k') end

  table.insert(args, '--max-time')
  table.insert(args, tostring(d.timeout or opts.timeout or M.DEFAULT_TIMEOUT))

  local has_content_type = false
  for _, h in ipairs(req.headers or {}) do
    if h[1]:lower() == 'content-type' then has_content_type = true end
    table.insert(args, '-H')
    table.insert(args, h[1] .. ': ' .. h[2])
  end

  local body = req.body
  if body and body ~= '' then
    -- JSON らしいボディで Content-Type が無いと curl が form 扱いのヘッダを付けるので補う
    if not has_content_type and body:match('^%s*[%[{]') then
      table.insert(args, '-H')
      table.insert(args, 'Content-Type: application/json')
    end
    table.insert(args, '--data-binary')
    table.insert(args, '@-') -- 標準入力から渡す（クォート事故を避ける）
  end

  table.insert(args, '-w')
  table.insert(args, STATS_FORMAT)
  table.insert(args, '--')
  table.insert(args, req.url)
  return args
end

--- コピー用の curl コマンド文字列（-w や @- は含めず、そのまま貼って使える形にする）
function M.curl_command(req)
  local args = M.build_curl(req, {})
  local out = {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == '-w' then
      i = i + 2
    elseif a == '--data-binary' then
      i = i + 2
    elseif a == '--' then
      i = i + 1
    else
      table.insert(out, shell_quote(a))
      i = i + 1
    end
  end
  table.insert(out, shell_quote(req.url))
  if req.body and req.body ~= '' then
    table.insert(out, '--data-binary')
    table.insert(out, shell_quote(req.body))
  end
  return table.concat(out, ' ')
end

--- curl -i の出力からヘッダとボディを切り出す。
--- -L でリダイレクトした場合はヘッダブロックが複数並ぶので最後のものを採用する
function M.parse_response(text)
  local rest = text or ''
  local status_line, headers = nil, {}
  while rest:match('^HTTP/') do
    local head, tail = rest:match('^(.-)\r?\n\r?\n(.*)$')
    if not head then
      head, tail = rest, ''
    end
    headers = {}
    local first = true
    for _, line in ipairs(vim.split(head, '\r?\n')) do
      line = line:gsub('\r$', '')
      if first then
        status_line = line
        first = false
      elseif line ~= '' then
        local k, v = line:match('^([^:]+):%s*(.*)$')
        if k then table.insert(headers, { k, v }) end
      end
    end
    rest = tail
  end

  local status_code, status_text
  if status_line then
    status_code, status_text = status_line:match('^HTTP/[%d%.]+%s+(%d+)%s*(.*)$')
    status_code = tonumber(status_code)
  end

  return {
    status_line = status_line,
    status_code = status_code,
    status_text = status_text and status_text ~= '' and status_text or nil,
    headers = headers,
    body = rest,
  }
end

--- curl の -w が stderr に書いたステータス行を取り出す。戻り値は stats, 残りの stderr
function M.parse_stats(stderr)
  if not stderr or stderr == '' then return nil, '' end
  local stats = nil
  local kept = {}
  for _, line in ipairs(vim.split(stderr, '\n')) do
    local code, time, size = line:match('^__NVIM_HTTP_STATS__%s+(%d+)%s+([%d%.]+)%s+(%d+)$')
    if code then
      stats = {
        status_code = tonumber(code),
        time_ms = math.floor(tonumber(time) * 1000 + 0.5),
        size = tonumber(size),
      }
    elseif line ~= '' then
      table.insert(kept, line)
    end
  end
  return stats, table.concat(kept, '\n')
end

--- ヘッダを名前で引く（大文字小文字を無視）
function M.header(result, name)
  for _, h in ipairs(result.headers or {}) do
    if h[1]:lower() == name:lower() then return h[2] end
  end
  return nil
end

--- リクエストを非同期実行する。on_done(result) は vim.schedule 済みで呼ばれる
function M.run(req, opts, on_done)
  opts = opts or {}
  if vim.fn.executable('curl') ~= 1 then
    on_done({ ok = false, request = req, error = 'curl が見つかりません' })
    return nil
  end

  local args = M.build_curl(req, opts)
  local sys_opts = { text = true }
  if req.body and req.body ~= '' then sys_opts.stdin = req.body end
  if opts.cwd then sys_opts.cwd = opts.cwd end

  return vim.system(args, sys_opts, function(res)
    local stats, stderr = M.parse_stats(res.stderr)
    local result
    if res.code ~= 0 then
      result = {
        ok = false,
        request = req,
        exit_code = res.code,
        error = (stderr ~= '' and stderr) or ('curl が終了コード ' .. res.code .. ' で失敗しました'),
      }
    else
      result = M.parse_response(res.stdout)
      result.ok = true
      result.request = req
      result.stats = stats
      result.status_code = result.status_code or (stats and stats.status_code)
      result.time_ms = stats and stats.time_ms
      result.size = stats and stats.size or #(result.body or '')
      result.content_type = M.header(result, 'content-type')
    end
    vim.schedule(function() on_done(result) end)
  end)
end

return M
