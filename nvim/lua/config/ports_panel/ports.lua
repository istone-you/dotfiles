-- 非同期のポート情報取得レイヤー（vim.system + on_exitコールバック、UIをブロックしない）。
-- docker_panel/docker.lua・git_panel/git.lua と同じ作りにしてある。
--
-- 一覧は lsof のフィールド出力（-F）を使う。列を空白で割る通常出力と違い、
-- コマンド名に空白が入っていても壊れず、IPv6 のアドレスもそのまま取れる。

local M = {}

--- テストや特殊環境から差し替えられるようにフィールドで持つ（既定は PATH 上の lsof）
M.bin = 'lsof'

M.command_log = {}
local MAX_LOG = 200
--- パネル側がrender_cmdlog相当を差し込むためのフック（コマンドログに変化があるたびに呼ぶ）
M.on_log_update = function() end

--- docker.lua と同じく、古い→新しいの順で末尾に追記する。
--- コマンドログは1エントリ1行として描画されるため、引数に改行を含むコマンド
--- （curl -w '\n%{http_code}' など）はエスケープしてから積む
local function push_log(text)
  text = tostring(text):gsub('\r', '\\r'):gsub('\n', '\\n')
  table.insert(M.command_log, text)
  if #M.command_log > MAX_LOG then
    table.remove(M.command_log, 1)
  end
  vim.schedule(M.on_log_update)
end

--- 状態を変えないコマンド（lsof/ps）はコマンドログに出さない。状態を変えるコマンド
--- （kill）は出す。opts.dont_log=true で前者を指定する
function M.run(cmd, cb, opts)
  if not (opts and opts.dont_log) then
    push_log(table.concat(cmd, ' '))
  end
  -- ポート情報はカレントディレクトリに依存しないので cwd は渡さない
  -- （渡すと削除済みディレクトリにいる時に ENOENT で起動自体が失敗する）
  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function()
      if cb then cb(res) end
    end)
  end)
end

--- 読み取り専用コマンドの糖衣（stdoutをそのまま返す）。
--- lsof は「一部のプロセスを覗けなかった」場合に警告付きで exit 1 を返すことがあり、
--- その時も stdout には見えた分の一覧が入っている。捨てると root 権限が無い環境で
--- 常に空になるため、code は見ずに stdout をそのまま使う
local function read(cmd, cb)
  M.run(cmd, function(res)
    cb(res.stdout or '', res)
  end, { dont_log = true })
end
M.read = read

-- ══════════════════════════════════════════════
-- 前提チェック
-- ══════════════════════════════════════════════

--- cb(ok, message) … okがfalseならmessageに理由
function M.check(cb)
  if vim.fn.executable(M.bin) ~= 1 then
    cb(false, 'lsof コマンドが見つかりません')
    return
  end
  cb(true, '')
end

-- ══════════════════════════════════════════════
-- パース
-- ══════════════════════════════════════════════

--- lsof の n フィールド（`*:8000` `127.0.0.1:5432->127.0.0.1:1234`
--- `[fe80::1]:59500->[fe80::2]:59470`）をローカルアドレス・ポート・相手先に分ける。
---@return string addr   ホスト部（IPv6 の角括弧は外す。全アドレスなら `*`）
---@return string|nil port ポート（`-P` 前提で数字文字列。未束縛の UDP は `*`）
---@return string|nil peer 接続相手（`->` が無ければ nil）
function M.split_name(name)
  name = name or ''
  local local_part, peer = name:match('^(.-)%->(.+)$')
  if not local_part then
    local_part, peer = name, nil
  end
  -- 末尾の `:ポート` を剥がす。ポート側に `:` `]` は入らないので、
  -- IPv6 の `[fe80::1]:80` でも host=`[fe80::1]` / port=`80` に割れる
  local addr, port = local_part:match('^(.*):([^:%]]*)$')
  if not addr then return local_part, nil, peer end
  addr = addr:gsub('^%[', ''):gsub('%]$', '')
  return addr, port, peer
end

--- `lsof -F pcLPnTf` の出力をエントリ配列にする。
--- フィールド出力は状態を持つ形式で、`p`(プロセス)行のあとに `f`(ソケット)行が続き、
--- 次の `f`/`p` が来るまでがひとつのソケットの情報になる。
--- `f` は必須。`-F` から外すとソケット境界が取れず一覧が常に空になる。
---@return table[] { pid, command, user, fd, proto, state, addr, port, peer, name }
function M.parse(text)
  local out = {}
  local proc = {}
  local sock = nil

  local function flush()
    if sock and sock.name then
      local addr, port, peer = M.split_name(sock.name)
      table.insert(out, {
        pid = proc.pid,
        command = proc.command or '',
        user = proc.user or '',
        fd = sock.fd,
        proto = sock.proto or '',
        state = sock.state,
        addr = addr,
        port = port,
        peer = peer,
        name = sock.name,
      })
    end
    sock = nil
  end

  for _, line in ipairs(vim.split(text or '', '\n', { plain = true })) do
    if line ~= '' then
      local tag, val = line:sub(1, 1), line:sub(2)
      if tag == 'p' then
        flush()
        proc = { pid = tonumber(val) }
      elseif tag == 'c' then
        proc.command = val
      elseif tag == 'L' then
        proc.user = val
      elseif tag == 'f' then
        flush()
        sock = { fd = val }
      elseif sock then
        if tag == 'P' then
          sock.proto = val
        elseif tag == 'n' then
          sock.name = val
        elseif tag == 'T' then
          -- TST=LISTEN / TQR=0 / TQS=0 のうち状態は ST= だけ
          local st = val:match('^ST=(.+)$')
          if st then sock.state = st end
        end
      end
    end
  end
  flush()
  return out
end

--- 同じポートを複数の fd で束ねているプロセス（lsof は fd ごとに1件出す）を1件にまとめる。
--- keys はエントリを識別するフィールド名の配列
local function dedupe(entries, keys)
  local seen, out = {}, {}
  for _, e in ipairs(entries) do
    local parts = {}
    for _, k in ipairs(keys) do table.insert(parts, tostring(e[k] or '')) end
    local key = table.concat(parts, '\0')
    if not seen[key] then
      seen[key] = true
      table.insert(out, e)
    end
  end
  return out
end
M.dedupe = dedupe

--- ポート番号昇順（数字にならないものは末尾）、同じならプロセス名順
local function sort_by_port(entries)
  table.sort(entries, function(a, b)
    local ap, bp = tonumber(a.port) or math.huge, tonumber(b.port) or math.huge
    if ap ~= bp then return ap < bp end
    if a.proto ~= b.proto then return a.proto < b.proto end
    if a.command ~= b.command then return a.command < b.command end
    return (a.pid or 0) < (b.pid or 0)
  end)
  return entries
end
M.sort_by_port = sort_by_port

--- 待ち受け中のソケット。TCP は LISTEN、UDP は状態を持たないので
--- 「接続相手がいない＝ポートに束ねられているだけ」のものを待ち受け扱いにする
function M.listening(entries)
  local out = {}
  for _, e in ipairs(entries) do
    if e.state == 'LISTEN' or (e.proto == 'UDP' and not e.peer) then
      table.insert(out, e)
    end
  end
  return sort_by_port(dedupe(out, { 'pid', 'proto', 'addr', 'port' }))
end

--- 確立済みの接続
function M.established(entries)
  local out = {}
  for _, e in ipairs(entries) do
    if e.state == 'ESTABLISHED' then table.insert(out, e) end
  end
  return sort_by_port(dedupe(out, { 'pid', 'proto', 'addr', 'port', 'peer' }))
end

-- ══════════════════════════════════════════════
-- 取得
-- ══════════════════════════════════════════════

--- ネットワークソケット全件。cb(entries)
function M.sockets(cb)
  read({ M.bin, '-nP', '-i', '-F', 'pcLPnTf' }, function(text)
    cb(M.parse(text))
  end)
end

--- プロセスの詳細（ps の1行表示）。cb(text)
function M.process_detail(pid, cb)
  M.run({ 'ps', '-o', 'pid,ppid,user,%cpu,%mem,lstart,command', '-p', tostring(pid) }, function(res)
    cb(res.stdout or '')
  end, { dont_log = true })
end

--- そのプロセスが掴んでいるソケット一覧（lsof の通常出力をそのまま見せる）。cb(text)
function M.process_sockets(pid, cb)
  read({ M.bin, '-nP', '-i', '-a', '-p', tostring(pid) }, function(text)
    cb(text)
  end)
end

--- シグナルを送る。signal は 'TERM' / 'KILL'
function M.kill(pid, signal, cb)
  M.run({ 'kill', '-' .. signal, tostring(pid) }, cb)
end

--- lsof の COMMAND が nvim か（ports_panel でサーバー停止とプロセス kill を切り替える判定）
function M.is_nvim_command(command)
  command = tostring(command or '')
  return command == 'nvim' or command:match('^nvim') ~= nil
end

--- pid が立てている nvim-api のポート。無ければ nil。
function M.find_nvim_api_port(pid)
  pid = tonumber(pid)
  if not pid then return nil end
  local registry = require('config.util.session_registry').new('nvim-api')
  for _, e in ipairs(registry.find()) do
    if e.pid == pid then return e.port end
  end
  return nil
end

--- JSON POST。cb(status_number|nil, decoded_json|nil, err_string|nil)
--- 状態を変える操作なのでコマンドログに残す。
function M.http_post_json(host, port, path, body, cb)
  local json = vim.json.encode(body or {})
  local url = string.format('http://%s:%d%s', host, tonumber(port), path)
  -- 本文のあとに改行＋HTTPステータスを付けてパースする（-f だと 4xx で stdout が空になる）
  M.run({
    'curl', '-sS', '-X', 'POST', url,
    '-H', 'Content-Type: application/json',
    '-d', json,
    '-w', '\n%{http_code}',
    '--max-time', '3',
  }, function(res)
    if (res.code or 0) ~= 0 and (not res.stdout or res.stdout == '') then
      cb(nil, nil, vim.trim(res.stderr or '') ~= '' and vim.trim(res.stderr) or ('curl exit ' .. tostring(res.code)))
      return
    end
    local out = res.stdout or ''
    local status_line = out:match('\n(%d%d%d)%s*$')
    local payload = out:gsub('\n%d%d%d%s*$', '')
    local status = tonumber(status_line)
    local decoded = nil
    if payload ~= '' then
      local ok, tbl = pcall(vim.json.decode, payload)
      if ok then decoded = tbl end
    end
    cb(status, decoded, nil)
  end)
end

--- nvim が掴んでいるポートの自前サーバだけ止める。
--- 自プロセスなら owned_servers を直接、別プロセスなら相手の nvim-api へ依頼する。
--- cb(ok, info) … ok 時の info は { id, label }、失敗時はエラー文字列
function M.stop_nvim_server(pid, port, cb)
  pid = tonumber(pid)
  port = tonumber(port)
  if not pid or not port then
    cb(false, 'pid/port が不正です')
    return
  end

  if pid == vim.fn.getpid() then
    local stopped, provider = require('config.util.owned_servers').stop(port)
    if not stopped or not provider then
      cb(false, 'この nvim に port ' .. tostring(port) .. ' の自前サーバはありません')
      return
    end
    cb(true, { id = provider.id, label = provider.label })
    return
  end

  local api_port = M.find_nvim_api_port(pid)
  if not api_port then
    cb(false, '対象 nvim の nvim-api が見つかりません（未起動かレジストリ未登録）')
    return
  end

  M.http_post_json('127.0.0.1', api_port, '/api/servers/stop', { port = port }, function(status, json, err)
    if err then
      cb(false, err)
      return
    end
    if status == 200 and json and json.stopped then
      cb(true, { id = json.id, label = json.label })
      return
    end
    local msg = (json and json.error) or ('HTTP ' .. tostring(status or '?'))
    cb(false, msg)
  end)
end

return M
