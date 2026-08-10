-- herdr 連携: <leader>ac/ax/aa (c=claude / x=codeX / a=agent) で右ペインにエージェントを開く。
--   右にエージェントがいれば再利用(そこへフォーカス)、いなければ右に split して起動。
--   ビジュアルで押したときは、選択範囲の場所 (相対パス:行) をそのペインの入力欄へ挿入する
--   (確定せず挿入だけ = 場所を起点にユーザーが続けて指示を打てる)。
local M = {}

local levels = vim.log.levels

local function notify(msg, level)
  vim.notify(msg, level or levels.INFO, { title = 'herdr' })
end

--- herdr の中で、かつ herdr コマンドが使えるか。使えないときは警告して false。
local function herdr_ready()
  if vim.env.HERDR_ENV ~= '1' then
    notify('herdr の中で実行してください (HERDR_ENV=1)', levels.WARN)
    return false
  end
  if vim.fn.executable('herdr') ~= 1 then
    notify('herdr コマンドが見つかりません', levels.ERROR)
    return false
  end
  return true
end

--- herdr サブコマンドを非同期実行し、完了時に cb(res) を main loop 上で呼ぶ。
--- (idle 待ちで nvim を固めないよう同期 :wait() は使わない)
local function herdr_async(args, cb)
  local cmd = { 'herdr' }
  vim.list_extend(cmd, args)
  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function() cb(res) end)
  end)
end

--- 成功応答 (code==0 かつ JSON) の result を返す。それ以外は nil。
local function decode_result(res)
  if not res or res.code ~= 0 then return nil end
  local ok, data = pcall(vim.json.decode, res.stdout or '')
  if not ok or type(data) ~= 'table' then return nil end
  return data.result
end

--- 選択範囲の場所文字列 (相対パス:開始-終了)。copy_with_path と同じ流儀。
--- 未保存バッファなら警告して nil。
local function location_text(start_line, end_line)
  local file = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  if file == '' then
    notify('未保存のファイルです', levels.WARN)
    return nil
  end
  local rel = file
  local root = vim.fn.systemlist('git rev-parse --show-toplevel 2>/dev/null')
  if vim.v.shell_error == 0 and #root > 0 then
    rel = file:sub(#root[1] + 2)
  end
  local range = start_line == end_line
    and tostring(start_line)
    or (tostring(start_line) .. '-' .. tostring(end_line))
  return rel .. ':' .. range
end

--- 右ペイン (nvim の右隣) へフォーカスする。id 指定フォーカスは無いので direction で寄せる。
local function focus_right()
  herdr_async({ 'pane', 'focus', '--direction', 'right', '--current' }, function() end)
end

--- pane_id のエージェントを開く。location があれば入力欄へ挿入する。
--- どちらの場合も最後に右ペインへフォーカスする。
local function reveal(pane_id, location)
  if not location then
    focus_right() -- 未選択: そのペインへ移動するだけ
    return
  end
  -- 場所は起点なので確定しない。続けて打てるよう末尾に空白を足す。
  herdr_async({ 'pane', 'send-text', pane_id, location .. ' ' }, function(res)
    if not res or res.code ~= 0 then
      notify('herdr pane send-text に失敗しました: ' .. ((res and res.stderr) or ''), levels.ERROR)
      return
    end
    focus_right()
    notify('エージェントに挿入: ' .. location)
  end)
end

--- 右に新しくペインを split して cmd を起動する。
--- location があれば idle になってから挿入、無ければ起動してフォーカスするだけ。
local function spawn(cmd, location)
  herdr_async({ 'pane', 'split', '--current', '--direction', 'right', '--no-focus' }, function(res)
    local result = decode_result(res)
    local pane_id = result and result.pane and result.pane.pane_id
    if type(pane_id) ~= 'string' then
      notify('herdr pane split の応答を解釈できませんでした', levels.ERROR)
      return
    end
    herdr_async({ 'pane', 'run', pane_id, cmd }, function(ran)
      if not ran or ran.code ~= 0 then
        notify('herdr pane run に失敗しました: ' .. ((ran and ran.stderr) or ''), levels.ERROR)
        return
      end
      if not location then
        focus_right()
        return
      end
      -- エージェントの TUI が立ち上がって idle になるまで待ってから挿入する
      herdr_async({ 'wait', 'agent-status', pane_id, '--status', 'idle', '--timeout', '30000' }, function()
        reveal(pane_id, location)
      end)
    end)
  end)
end

--- 右ペインでエージェントを開く。location(相対パス:行) は選択時のみ渡す(未選択は nil)。
--- 右にエージェントがいれば再利用、いなければ右に split して起動する。
function M.open_agent(cmd, label, location)
  if not herdr_ready() then return end

  herdr_async({ 'pane', 'neighbor', '--direction', 'right', '--current' }, function(res)
    local result = decode_result(res)
    local neighbor = result and result.neighbor
    -- 実際の右隣 id は neighbor_pane_id。右隣が無いときは null。
    -- (neighbor.pane_id は問い合わせ元=自分自身なので使わない)
    local neighbor_id = neighbor and neighbor.neighbor_pane_id

    if type(neighbor_id) == 'string' and neighbor_id ~= '' then
      herdr_async({ 'pane', 'get', neighbor_id }, function(got)
        local r = decode_result(got)
        local agent = r and r.pane and r.pane.agent
        if type(agent) == 'string' and agent ~= '' then
          reveal(neighbor_id, location) -- エージェントがいる → 再利用
        else
          spawn(cmd, location) -- ただのシェル等 → 右に新規起動
        end
      end)
      return
    end

    spawn(cmd, location) -- 右に何も無い → 右に新規起動
  end)
end

-- 2キー目: c=claude / x=codeX / a=agent(cursor-cli)
local agents = {
  { key = '<leader>ac', cmd = 'claude', label = 'claude' },
  { key = '<leader>ax', cmd = 'codex', label = 'codex' },
  { key = '<leader>aa', cmd = 'agent', label = 'agent' },
}

for _, a in ipairs(agents) do
  -- ノーマル: 右ペインでエージェントを開く (あれば再利用)。場所は渡さない。
  vim.keymap.set('n', a.key, function()
    M.open_agent(a.cmd, a.label)
  end, { desc = 'herdr: 右ペインで ' .. a.cmd .. ' を開く (あれば再利用)' })

  -- ビジュアル: 選択範囲の場所を右のエージェントへ挿入 (あれば再利用)
  vim.keymap.set('x', a.key, function()
    local s = vim.fn.line('v')
    local e = vim.fn.line('.')
    if s > e then s, e = e, s end
    local location = location_text(s, e)
    if location then
      M.open_agent(a.cmd, a.label, location)
    end
    vim.schedule(function()
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
    end)
  end, { desc = 'herdr: 選択範囲の場所を ' .. a.cmd .. ' へ挿入 (右パネル・あれば再利用)' })
end

M._private = {
  agents = agents,
  open_agent = M.open_agent,
  location_text = location_text,
}

return M
