-- docker管理パネル（中央90%ポップアップ、複数パネル切替）
-- パネル構成・キー/挙動は lazydocker (github.com/jesseduffield/lazydocker) を参照して合わせている。
--
-- 見た目と骨格（レイアウト・タブバー・コマンドログ・右ペイン・拡大トグル・自動更新）は
-- config/panel/shell.lua をgitパネルと共有しているため、gitパネルと全く同じUIになる。
-- このファイルに残っているのは docker 固有の部分だけ:
--   ・どのパネル(Project/Containers/...)を並べるか
--   ・コマンド実行層(docker.lua)とのつなぎ込み

local docker = require('config.docker_panel.docker')
local shell = require('config.panel.shell')

local M = {}

-- lazydocker のサイドパネル構成（Project / Containers / Images / Volumes / Networks）に合わせる
local PANELS = {
  { key = '1', name = 'project',    title = 'Project',    mod = 'config.docker_panel.project' },
  { key = '2', name = 'containers', title = 'Containers', mod = 'config.docker_panel.containers' },
  { key = '3', name = 'images',     title = 'Images',     mod = 'config.docker_panel.images' },
  { key = '4', name = 'volumes',    title = 'Volumes',    mod = 'config.docker_panel.volumes' },
  { key = '5', name = 'networks',   title = 'Networks',   mod = 'config.docker_panel.networks' },
}

local panel = shell.new({
  id = 'docker',
  augroup = 'docker_panel',
  hl_namespace = 'docker_panel_hl',
  panels = PANELS,
  left_filetype = 'dockerpanel',
  right_win_var = 'dockerpanel_right',
  command_log = function() return docker.command_log end,
  set_log_hook = function(fn) docker.on_log_update = fn end,
  start = function(cb)
    docker.check(function(ok, message)
      if not ok then
        vim.notify(message, vim.log.levels.ERROR)
        cb(false)
        return
      end
      cb(true)
    end)
  end,
  -- dockerにはdiff(delta)相当が無いため diff は渡さない。
  -- ＝ + は素直に右ペインを拡大するだけになり、v(side-by-side)キーも生えない
})

function M.open(fullscreen) panel.open(fullscreen) end
--- opts.keep_nvim=true でパネルだけ閉じる（全画面表示でもnvimを終了しない）
function M.close(opts) panel.close(opts) end
function M.toggle(fullscreen) panel.toggle(fullscreen) end

vim.keymap.set('n', '<leader>d', function() M.toggle() end, { desc = 'dockerパネルを開閉', nowait = true })
vim.api.nvim_create_user_command('Docker', function(cmd_opts) M.toggle(cmd_opts.bang) end,
  { bang = true, desc = 'dockerパネルを開閉（!で全画面表示）' })

return M
