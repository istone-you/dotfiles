-- terminal-browser 連携: プレビュー URL を herdr の右ペインで開く。
--   右ペインで terminal-browser が動いていれば、そのブラウザに新しいタブを足す。
--   動いていない (右ペインが無い場合も含む) ときは右に split して起動し、そこで開く。
-- herdr.lua がエージェントに対してやっている「あれば再利用、無ければ右に split」と同じ流儀。
local M = {}

local herdr_cli = require('config.util.herdr_cli')

--- terminal-browser を非同期実行し、完了時に cb(res) を main loop 上で呼ぶ。
local function tb_async(args, cb)
  local cmd = { 'terminal-browser' }
  vim.list_extend(cmd, args)
  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function() cb(res) end)
  end)
end

--- この経路が使えるか。herdr セッションの中で terminal-browser があるときだけ。
--- 同期判定なので、呼び出し側は結果を見てから OS の opener と使い分けられる。
function M.available()
  return herdr_cli.ready() and vim.fn.executable('terminal-browser') == 1
end

--- `terminal-browser ls --all --json` の出力から、pane_id のペインで動いている
--- ブラウザの key を返す。いなければ nil。
---
--- ブラウザは自分が起動された herdr ペインの HERDR_PANE_ID を自己申告するため、
--- browsers[].pane.pane は herdr の pane_id (例 "w1:p2") と同じ文字列空間になる。
--- つまり `herdr pane neighbor` が返す右隣 id と直接突き合わせられる。
function M.browser_key_at(stdout, pane_id)
  if type(pane_id) ~= 'string' or pane_id == '' then return nil end
  local ok, data = pcall(vim.json.decode, stdout or '')
  if not ok or type(data) ~= 'table' then return nil end
  local list = type(data.browsers) == 'table' and data.browsers or {}
  for _, b in ipairs(list) do
    local pane = type(b.pane) == 'table' and b.pane.pane or nil
    if pane == pane_id and type(b.key) == 'string' and b.key ~= '' then
      return b.key
    end
  end
  return nil
end

--- pane_id のペインで前面にいるプロセスに name が含まれるか(cb(bool))。
---
--- ブラウザが名乗る pane id は起動時の HERDR_PANE_ID のままで、ペインを閉じても
--- 更新されない。プロセスが生きていれば `ls` にも残り続けるため、herdr を再起動して
--- pane id が振り直されると、生き残ったブラウザの古い id が実在する別のペインと
--- 衝突しうる。自称 id だけで再利用を決めると、見えないブラウザにタブを送ってしまう。
--- そこで再利用の前に「そのペインで本当に動いているか」をここで確かめる。
local function pane_runs(pane_id, name, cb)
  herdr_cli.async({ 'pane', 'process-info', '--pane', pane_id }, function(res)
    local result = herdr_cli.decode_result(res)
    local procs = result and result.process_info and result.process_info.foreground_processes
    if type(procs) ~= 'table' then
      cb(false)
      return
    end
    for _, p in ipairs(procs) do
      local hay = table.concat({ p.cmdline or '', p.argv0 or '', p.name or '' }, ' ')
      if hay:find(name, 1, true) then
        cb(true)
        return
      end
    end
    cb(false)
  end)
end

--- 右に split して terminal-browser を起動し、そこで url を開く。
--- split と起動は terminal-browser 側が herdr でやる
--- (`herdr pane split --direction right --focus` → `herdr pane run`)ので、
--- こちらでペインを作る必要はない。フォーカスもその --focus で右へ移る。
local function spawn(url, cb)
  tb_async({ 'open', url, '--split', 'right' }, function(res)
    if not res or res.code ~= 0 then
      cb(false, (res and res.stderr) or '')
      return
    end
    cb(true)
  end)
end

--- url を右ペインの terminal-browser で開く。完了時に cb(ok, err) を呼ぶ。
--- 失敗しても通知はしない(OS の opener へ倒すかは呼び出し側が決める)。
function M.open(url, cb)
  cb = cb or function() end
  herdr_cli.right_neighbor(function(neighbor_id)
    if not neighbor_id then
      spawn(url, cb) -- 右に何も無い → 右に新規起動
      return
    end
    pane_runs(neighbor_id, 'terminal-browser', function(running)
      if not running then
        spawn(url, cb) -- 右はエージェント等ブラウザ以外 → 右に新規起動
        return
      end
      tb_async({ 'ls', '--all', '--json' }, function(res)
        local key = res and res.code == 0 and M.browser_key_at(res.stdout, neighbor_id) or nil
        if not key then
          spawn(url, cb) -- 右で動いているのに一覧に無い → 右に新規起動
          return
        end
        tb_async({ 'new-tab', '--browser', key, url }, function(added)
          if not added or added.code ~= 0 then
            cb(false, (added and added.stderr) or '')
            return
          end
          herdr_cli.focus_right()
          cb(true)
        end)
      end)
    end)
  end)
end

return M
