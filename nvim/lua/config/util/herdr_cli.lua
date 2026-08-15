-- herdr の socket API を CLI 越しに叩くための共通配管。
-- herdr.lua (右ペインでエージェントを開く) と browser/terminal_browser.lua
-- (右ペインでブラウザを開く) が同じ「右隣ペインを見て再利用するか決める」流儀を共有する。
local M = {}

--- herdr の中で、かつ herdr コマンドが使えるか。通知はしない(呼び出し側の判断に任せる)。
function M.ready()
  return vim.env.HERDR_ENV == '1' and vim.fn.executable('herdr') == 1
end

--- herdr サブコマンドを非同期実行し、完了時に cb(res) を main loop 上で呼ぶ。
--- (idle 待ちで nvim を固めないよう同期 :wait() は使わない)
function M.async(args, cb)
  local cmd = { 'herdr' }
  vim.list_extend(cmd, args)
  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function() cb(res) end)
  end)
end

--- 成功応答 (code==0 かつ JSON) の result を返す。それ以外は nil。
function M.decode_result(res)
  if not res or res.code ~= 0 then return nil end
  local ok, data = pcall(vim.json.decode, res.stdout or '')
  if not ok or type(data) ~= 'table' then return nil end
  return data.result
end

--- 現在ペインの右隣の pane_id を cb に渡す。右に何も無ければ nil。
--- 実際の右隣 id は neighbor_pane_id。右隣が無いときは null。
--- (neighbor.pane_id は問い合わせ元=自分自身なので使わない)
function M.right_neighbor(cb)
  M.async({ 'pane', 'neighbor', '--direction', 'right', '--current' }, function(res)
    local result = M.decode_result(res)
    local neighbor = result and result.neighbor
    local id = neighbor and neighbor.neighbor_pane_id
    if type(id) ~= 'string' or id == '' then
      cb(nil)
      return
    end
    cb(id)
  end)
end

--- 右ペインへフォーカスする。id 指定フォーカスは無いので direction で寄せる。
function M.focus_right()
  M.async({ 'pane', 'focus', '--direction', 'right', '--current' }, function() end)
end

return M
