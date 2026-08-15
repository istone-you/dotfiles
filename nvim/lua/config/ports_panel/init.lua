-- ポート管理パネル（中央90%ポップアップ）
--
-- 「このポート、何が使ってる？」を nvim から引けるようにするパネル。
-- 見た目と骨格（レイアウト・タブバー・コマンドログ・右ペイン・拡大トグル・自動更新）は
-- config/panel/shell.lua を git / docker パネルと共有しているので、UIは全く同じになる。
-- ここに残っているのは ports 固有の部分だけ:
--   ・どのパネル(Listening/Connections)を並べるか
--   ・コマンド実行層(ports.lua)とのつなぎ込み

local ports = require('config.ports_panel.ports')
local shell = require('config.panel.shell')

local M = {}

local PANELS = {
  { key = '1', name = 'listening',   title = 'Listening',   mod = 'config.ports_panel.listening' },
  { key = '2', name = 'connections', title = 'Connections', mod = 'config.ports_panel.connections' },
}

local panel = shell.new({
  id = 'ports',
  augroup = 'ports_panel',
  hl_namespace = 'ports_panel_hl',
  panels = PANELS,
  left_filetype = 'portspanel',
  right_win_var = 'portspanel_right',
  command_log = function() return ports.command_log end,
  set_log_hook = function(fn) ports.on_log_update = fn end,
  start = function(cb)
    ports.check(function(ok, message)
      if not ok then
        vim.notify(message, vim.log.levels.ERROR)
        cb(false)
        return
      end
      cb(true)
    end)
  end,
  -- ポート一覧に diff 表示は無いため diff は渡さない
  -- ＝ + は素直に右ペインを拡大するだけになり、v(side-by-side)キーも生えない
})

function M.open(fullscreen) panel.open(fullscreen) end
--- opts.keep_nvim=true でパネルだけ閉じる（全画面表示でもnvimを終了しない）
function M.close(opts) panel.close(opts) end
function M.toggle(fullscreen) panel.toggle(fullscreen) end

vim.keymap.set('n', '<leader>P', function() M.toggle() end, { desc = 'ポートパネルを開閉', nowait = true })
vim.api.nvim_create_user_command('Ports', function(cmd_opts) M.toggle(cmd_opts.bang) end,
  { bang = true, desc = 'ポートパネルを開閉（!で全画面表示）' })

return M
