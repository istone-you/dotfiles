-- herdr 連携: <leader>ac/ax/aa (c=claude / x=codeX / a=agent) で右ペインにエージェントを開く。
--   右にエージェントがいれば再利用(そこへフォーカス)、いなければ右に split して起動。
--   ビジュアルで押したときは、選択範囲の場所 (相対パス:行) をそのペインの入力欄へ挿入する
--   (確定せず挿入だけ = 場所を起点にユーザーが続けて指示を打てる)。
local M = {}

local picker = require('config.util.picker')
local herdr_cli = require('config.util.herdr_cli')
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

local herdr_async = herdr_cli.async
local decode_result = herdr_cli.decode_result

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
local focus_right = herdr_cli.focus_right

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

  herdr_cli.right_neighbor(function(neighbor_id)
    if not neighbor_id then
      spawn(cmd, location) -- 右に何も無い → 右に新規起動
      return
    end
    herdr_async({ 'pane', 'get', neighbor_id }, function(got)
      local r = decode_result(got)
      local agent = r and r.pane and r.pane.agent
      if type(agent) == 'string' and agent ~= '' then
        reveal(neighbor_id, location) -- エージェントがいる → 再利用
      else
        spawn(cmd, location) -- ただのシェル等 → 右に新規起動
      end
    end)
  end)
end

-- ── 送り先を選ぶ版: 起動中のエージェント一覧から選んで送る/フォーカスする ──

-- agent_status ごとのアイコンと色（picker の tag に使う）
local STATUS_ICON = { idle = '○', working = '●', blocked = '!', done = '✓', unknown = '·' }
local STATUS_HL =
  { idle = 'DiagnosticOk', working = 'DiagnosticWarn', blocked = 'DiagnosticError', done = 'DiagnosticInfo', unknown = 'Comment' }

--- `herdr agent list` の JSON を picker 用の項目に変換する(workspace/tab ラベルは decorate で付与)。
--- target は agent コマンドに渡せる terminal_id(無ければ pane_id)。
local function parse_agents(stdout)
  local ok, data = pcall(vim.json.decode, stdout or '')
  local agents = (ok and type(data) == 'table' and data.result and data.result.agents) or {}
  local items = {}
  for _, a in ipairs(agents) do
    -- pane_id を send-text にもフォーカス(agent focus)にも使う。
    -- terminal_id はこのサーバの agent focus では通らない(agent_not_found)ので使わない。
    if type(a.pane_id) == 'string' and a.pane_id ~= '' then
      items[#items + 1] = {
        pane_id = a.pane_id,
        agent = a.agent or 'agent',
        status = a.agent_status or 'unknown',
        title = a.terminal_title_stripped or a.terminal_title or '',
        workspace_id = a.workspace_id or '',
        tab_id = a.tab_id or '',
      }
    end
  end
  return items
end

--- workspace/tab list の JSON から id→label のマップを作る。
local function parse_label_map(stdout, list_key, id_field)
  local ok, data = pcall(vim.json.decode, stdout or '')
  local list = (ok and type(data) == 'table' and data.result and data.result[list_key]) or {}
  local map = {}
  for _, e in ipairs(list) do
    if type(e[id_field]) == 'string' and type(e.label) == 'string' then
      map[e[id_field]] = e.label
    end
  end
  return map
end

--- workspace/tab のラベルを各 item に付ける(herdr サイドバーと同じ workspace/tab 表示にするため)。
--- ラベルが引けなければ id をそのまま使う。
local function decorate(items, wmap, tmap)
  for _, it in ipairs(items) do
    it.workspace = wmap[it.workspace_id] or it.workspace_id
    it.tab = tmap[it.tab_id] or it.tab_id
  end
  return items
end

--- 起動中エージェント一覧を workspace/tab ラベル付きで非同期に取り、cb(items) を呼ぶ。
--- ラベルは agent list に無いので workspace list / tab list から引く(サイドバーと表示を揃えるため)。
local function list_agents(cb)
  herdr_async({ 'agent', 'list' }, function(ares)
    local items = parse_agents(ares and ares.code == 0 and ares.stdout or '')
    herdr_async({ 'workspace', 'list' }, function(wres)
      local wmap = parse_label_map(wres and wres.code == 0 and wres.stdout or '', 'workspaces', 'workspace_id')
      herdr_async({ 'tab', 'list' }, function(tres)
        local tmap = parse_label_map(tres and tres.code == 0 and tres.stdout or '', 'tabs', 'tab_id')
        cb(decorate(items, wmap, tmap))
      end)
    end)
  end)
end

--- pane_id のエージェントペインへフォーカスする(別タブ/別ワークスペースでも寄る)。
--- agent focus は terminal_id だと通らないので pane_id を渡す。失敗時は通知する。
local function focus_pane(pane_id)
  herdr_async({ 'agent', 'focus', pane_id }, function(res)
    if not res or res.code ~= 0 then
      notify('herdr agent focus に失敗しました: ' .. ((res and res.stderr) or ''), levels.WARN)
    end
  end)
end

--- 通知用に長いテキストを短縮する。
local function preview_text(text)
  if #text <= 80 then return text end
  return text:sub(1, 77) .. '...'
end

--- item のエージェントにテキストを挿入してフォーカスする。text が無ければフォーカスのみ。
--- 挿入もフォーカスも pane_id で行う。
local function send_to(item, text)
  local pane_id = item.pane_id
  if not text then
    focus_pane(pane_id)
    return
  end
  -- send-text はリテラル挿入(Enterなし)。末尾に空白を足して続けて打てるようにする。
  herdr_async({ 'pane', 'send-text', pane_id, text .. ' ' }, function(res)
    if not res or res.code ~= 0 then
      notify('herdr pane send-text に失敗しました: ' .. ((res and res.stderr) or ''), levels.ERROR)
      return
    end
    focus_pane(pane_id)
    notify('エージェントに挿入: ' .. preview_text(text))
  end)
end

--- 起動中のエージェントを picker で選び、テキストを送る(text あり)/フォーカスする(text なし)。
--- text は場所文字列でも診断ペイロードでもよい。
function M.pick_agent(text)
  if not herdr_ready() then return end
  list_agents(function(items)
    if #items == 0 then
      notify('起動中のエージェントがいません', levels.WARN)
      return
    end
    picker.open({
      title = text and ' 送るエージェント ' or ' フォーカスするエージェント ',
      items = items,
      numbered = true, -- 左にラベル(1..9,a..z)を出し、そのキーで選べる
      filter = false, -- 打ち込み絞り込みは使わない(ラベル/Ctrl-j/k で選ぶ)

      -- herdr サイドバーの agents と同じ「状態アイコン + workspace + tab」で識別できるようにする。
      format = function(it)
        local title = it.title ~= '' and ('  ' .. it.title) or ''
        return {
          tag = STATUS_ICON[it.status] or STATUS_ICON.unknown,
          tag_hl = STATUS_HL[it.status] or 'Comment',
          text = it.workspace .. ' · ' .. it.tab .. title,
          right = it.agent,
        }
      end,
      on_select = function(it)
        send_to(it, text)
      end,
    })
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

-- <leader>ap: 送り先エージェントを一覧から選ぶ。ノーマル=選んでフォーカス、ビジュアル=選んで場所を送る。
vim.keymap.set('n', '<leader>ap', function()
  M.pick_agent(nil)
end, { desc = 'herdr: エージェントを選んでフォーカス' })

vim.keymap.set('x', '<leader>ap', function()
  local s = vim.fn.line('v')
  local e = vim.fn.line('.')
  if s > e then s, e = e, s end
  local location = location_text(s, e)
  if location then M.pick_agent(location) end
  vim.schedule(function()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
  end)
end, { desc = 'herdr: エージェントを選んで選択範囲の場所を送る' })

M._private = {
  agents = agents,
  open_agent = M.open_agent,
  location_text = location_text,
  pick_agent = M.pick_agent,
  parse_agents = parse_agents,
  parse_label_map = parse_label_map,
  decorate = decorate,
  send_to = send_to,
}

return M
