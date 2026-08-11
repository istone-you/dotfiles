-- git管理パネル（中央90%ポップアップ、複数パネル切替）
-- キー/挙動は lazygit の pkg/config/user_config.go のデフォルトキーバインドに合わせて検証済み
--
-- レイアウト・タブバー・コマンドログ・右ペインの描画（delta/ANSI/レビューツリー）といった
-- 「見た目と骨格」は config/panel/shell.lua に共通化してあり、dockerパネルと全く同じものを使う。
-- このファイルに残っているのは git 固有の部分だけ:
--   ・どのパネル(Files/Commits/...)を並べるか
--   ・コマンド実行層(git.lua)とのつなぎ込み
--   ・git固有のグローバルキー(P:push / p:pull / z:undo)

local git = require('config.git_panel.git')
local shell = require('config.panel.shell')

local M = {}

local PANELS = {
  { key = '1', name = 'files',    title = 'Files',    mod = 'config.git_panel.files' },
  { key = '2', name = 'commits',  title = 'Commits',  mod = 'config.git_panel.commits' },
  { key = '3', name = 'branches', title = 'Branches', mod = 'config.git_panel.branches' },
  { key = '4', name = 'stash',    title = 'Stash',    mod = 'config.git_panel.stash' },
  { key = '5', name = 'worktree', title = 'Worktree', mod = 'config.git_panel.worktree' },
  { key = '6', name = 'pr',       title = 'PR',       mod = 'config.git_panel.pr' },
}

local panel

-- ══════════════════════════════════════════════
-- git固有のグローバルキー（push/pull/undo）
-- ══════════════════════════════════════════════

--- lazygit(sync_controller.go pushAux/pullWithLock)と同じく、成功時は
--- 何も通知しない（パネルの再描画自体が結果を表す）。失敗時のみ通知する
local function notify_result(res, fail_prefix)
  if res.code ~= 0 then
    vim.notify(fail_prefix .. ': ' .. (res.stderr or ''), vim.log.levels.ERROR)
  end
end

-- lazygit(sync_controller.go)と同じ分岐:
-- ・追跡中でbehindと分かっていれば事前にforce push確認
-- ・そうでなければ通常push→rejectされたら事後にforce push確認（--force-with-lease）
--
-- modeはnil(通常push)|'lease'(behind事前検知からのforce-with-lease)|'force'(reject後の素のforce)。
-- lazygit(sync_controller.go pushAux)と同じく、reject後のリトライには--force-with-leaseではなく
-- 素の--forceを使う: force-with-leaseはローカルが知るリモートの状態が最新であることが前提の安全
-- 機構であり、rejectされる状況(=ローカルがリモートの現在地を知らない)ではその前提自体が崩れていて
-- 「stale info」で再度失敗するため
local function attempt_push(mode)
  local ctx = panel.ctx
  local function on_done(res)
    panel.clear_loading()
    ctx.render_cmdlog()
    if res.code == 0 then
      panel.refresh_current_panel()
      require('config.git_panel.branches').refresh_prs()
      return
    end
    local err = res.stderr or ''
    if not mode and err:find('rejected', 1, true) then
      ctx.confirm('リモートに新しいコミットがあり、通常のpushは拒否されました。\nforce pushしますか？(--force)', function(yes)
        if yes then attempt_push('force') end
      end)
      return
    end
    vim.notify('push失敗: ' .. err, vim.log.levels.ERROR)
  end
  panel.set_loading('Pushing')
  if mode == 'lease' then
    git.push_force_with_lease(on_done)
  elseif mode == 'force' then
    git.push_force(on_done)
  else
    git.push(on_done)
  end
end

local function do_push()
  local ctx = panel.ctx
  git.has_upstream(function(ok)
    if not ok then
      git.branch_name(function(branch)
        ctx.confirm('アップストリームが未設定です。\norigin/' .. branch .. ' を設定してpushしますか？', function(yes)
          if not yes then return end
          panel.set_loading('Pushing')
          git.push_set_upstream('origin', branch, function(res)
            panel.clear_loading()
            ctx.render_cmdlog()
            notify_result(res, 'push失敗')
            panel.refresh_current_panel()
            if res.code == 0 then require('config.git_panel.branches').refresh_prs() end
          end)
        end)
      end)
      return
    end
    git.branches(function(list)
      local current
      for _, b in ipairs(list) do
        if b.current then current = b end
      end
      local behind = current and current.track and current.track:match('behind (%d+)')
      if behind then
        ctx.confirm('リモートより ' .. behind .. ' コミット遅れています。\nforce pushしますか？(--force-with-lease)', function(yes)
          if yes then attempt_push('lease') end
        end)
        return
      end
      attempt_push()
    end)
  end)
end

local function do_pull()
  local ctx = panel.ctx
  panel.set_loading('Pulling')
  git.pull(function(res)
    panel.clear_loading()
    ctx.render_cmdlog()
    -- 衝突で止まった場合は「失敗」ではなく解消フローへ誘導する（VSCode が
    -- 衝突時に Source Control の Merge Changes へ寄せるのと同じ考え方）
    if res.code ~= 0 and git.is_conflict_result(res) then
      panel.switch_to(1) -- Files パネル
      vim.notify('コンフリクトが発生しました。m で解消メニュー', vim.log.levels.WARN)
      return
    end
    notify_result(res, 'pull失敗')
    panel.refresh_current_panel()
    if res.code == 0 then require('config.git_panel.branches').refresh_prs() end
  end)
end

-- Undo(z): 直前のコミット1つを取り消す（soft reset）。checkout/rebaseのUndoは対象外
local function do_undo()
  local ctx = panel.ctx
  ctx.confirm('直前のコミットを取り消しますか？\n（変更はステージ済みの状態に戻ります）', function(ok)
    if not ok then return end
    git.undo_last_commit(function(res)
      ctx.render_cmdlog()
      if res.code ~= 0 then vim.notify('undoに失敗しました: ' .. (res.stderr or ''), vim.log.levels.ERROR) end
      panel.refresh_current_panel()
    end)
  end)
end

-- ══════════════════════════════════════════════
-- シェルへの組み込み
-- ══════════════════════════════════════════════

panel = shell.new({
  id = 'git',
  augroup = 'git_panel',
  hl_namespace = 'git_panel_hl',
  panels = PANELS,
  left_filetype = 'gitpanel',
  right_win_var = 'gitpanel_right',
  review_tree_win_var = 'gitpanel_review_tree',
  command_log = function() return git.command_log end,
  set_log_hook = function(fn) git.on_log_update = fn end,
  get_root = function() return git.root end,
  start = function(cb)
    git.find_root(function(root)
      if not root then
        vim.notify('gitリポジトリではありません', vim.log.levels.ERROR)
        cb(false)
        return
      end
      cb(true)
    end)
  end,
  -- delta のANSI出力を通常バッファへ忠実に写す（端末バッファではなく通常バッファにするため、
  -- CursorLineの選択ハイライトや通常のカーソル移動が効く）。split_files を渡しているので
  -- + での拡大時にファイル単位のレビューツリーが出る
  -- git.run_delta 等はテストが実行時に差し替える（呼び出し回数や幅の検証）ため、
  -- ここでモジュールの関数を直接束縛せず、呼ぶたびに引き直す
  diff = {
    available = function() return git.delta_available end,
    run = function(text, width, cb) return git.run_delta(text, width, cb) end,
    split_files = function(raw) return git.diff_files(raw) end,
    toggle_side_by_side = function() return git.toggle_side_by_side() end,
  },
  global_keys = function()
    return {
      ['P'] = do_push,
      ['p'] = do_pull,
      ['z'] = do_undo,
    }
  end,
})

function M.open(fullscreen) panel.open(fullscreen) end
function M.close() panel.close() end
function M.toggle(fullscreen) panel.toggle(fullscreen) end

-- <leader>gg（ターミナル版lazygit）と接頭辞が被るため、timeoutlen待ちが起きないようnowaitで即時発火させる
vim.keymap.set('n', '<leader>g', function() M.toggle() end, { desc = 'gitパネルを開閉', nowait = true })
vim.api.nvim_create_user_command('Git', function(cmd_opts) M.toggle(cmd_opts.bang) end, { bang = true, desc = 'gitパネルを開閉（!で全画面表示）' })

return M
