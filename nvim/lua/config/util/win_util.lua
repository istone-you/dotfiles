-- ウィンドウ種別の共通判定。「実編集ウィンドウ」か、explorer/gitパネル等の
-- ユーティリティ窓かを一箇所で判定する（auto_quit / quit_confirm / search /
-- tabline / buf_cycle 等で共用）。

local M = {}

-- スプリット型サイドバーの filetype。
-- 新しい窓を追加したら、ここに filetype を足し、かつ窓を開いた直後に
-- M.mark_sidebar(win, buf) を呼ぶ。両方やること:
--   ・mark_sidebar は自作モジュール経由で開いたときしか付かない
--     （:copen や :vimgrep など素のコマンドで開かれると漏れる）
--   ・SIDEBAR_FT だけだと filetype を持たない窓を拾えない
-- ※ git パネル等のフロートは is_float で既に非エディタ扱いなので登録不要。
--
-- 登録を忘れると is_editor が真になり、次の形で壊れる。症状が「そのパネルを
-- 開いているときだけ他の機能が効かない」と出るので、原因に気づきにくい。
--   ・auto_quit の「実編集ウィンドウが残っていない」判定が成立せず、
--     その窓を開いている間だけ Space Q（全バッファを閉じる）で終了しなくなる
--   ・focus_editor がその窓にフォーカスを移し、open_buf がその窓に
--     ファイルバッファを載せてしまう
-- qf（quickfix / location list は同じ filetype）で実際に踏んだ。
M.SIDEBAR_FT = { explorer = true, shortcuts = true, httpresult = true, problems = true, qf = true, picker = true }

function M.is_float(win)
  return vim.api.nvim_win_get_config(win).relative ~= ''
end

-- サイドバー窓としてマークする（buf を渡すとそのバッファ以外が載ったら自動で戻す）
function M.mark_sidebar(win, buf)
  if not vim.api.nvim_win_is_valid(win) then return end
  vim.w[win].sidebar = true
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.w[win].sidebar_buf = buf
  end
end

function M.is_sidebar(win)
  if not vim.api.nvim_win_is_valid(win) then return false end
  if vim.w[win].sidebar then return true end
  local ft = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
  return M.SIDEBAR_FT[ft] == true
end

-- 実編集ウィンドウか（フロート・サイドバーは除外。startscreen は主窓なので含む）
function M.is_editor(win)
  if not vim.api.nvim_win_is_valid(win) then return false end
  if M.is_float(win) then return false end
  if M.is_sidebar(win) then return false end
  return true
end

-- 実編集ウィンドウへフォーカスを移す（既に実編集窓なら何もしない）。
-- 見つからなければ現在の窓のまま。
function M.focus_editor()
  if M.is_editor(vim.api.nvim_get_current_win()) then return end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if M.is_editor(w) then
      vim.api.nvim_set_current_win(w)
      return
    end
  end
end

-- ファイルバッファを必ず編集窓で開く（タブクリック・バッファ巡回用）。
-- サイドバーにフォーカスがあっても、そちらへは載せず編集窓へ切り替えてから表示する。
function M.open_buf(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  M.focus_editor()
  vim.api.nvim_set_current_buf(bufnr)
end

-- サイドバーへ実ファイルが載ってしまったら、編集窓へ移してサイドバーを元バッファへ戻す。
-- タブクリック以外の経路（:buffer 等）でも防げるようにする。
local guarding = false
function M.setup_sidebar_guard()
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = vim.api.nvim_create_augroup('WinUtilSidebarGuard', { clear = true }),
    callback = function(ev)
      if guarding then return end
      local buf = ev.buf
      if not vim.api.nvim_buf_is_valid(buf) then return end
      if vim.bo[buf].buftype ~= '' then return end
      if vim.api.nvim_buf_get_name(buf) == '' then return end

      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        if not M.is_float(win) and M.is_sidebar(win) then
          local home = vim.w[win].sidebar_buf
          if not (home and home == buf) then
            guarding = true
            local ok, err = pcall(function()
              local editor
              for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
                if M.is_editor(w) then
                  editor = w
                  break
                end
              end
              if editor then
                vim.api.nvim_win_set_buf(editor, buf)
                vim.api.nvim_set_current_win(editor)
              end
              if home and vim.api.nvim_buf_is_valid(home) then
                vim.api.nvim_win_set_buf(win, home)
              end
            end)
            guarding = false
            if not ok then
              vim.notify('win_util sidebar guard: ' .. tostring(err), vim.log.levels.WARN)
            end
          end
        end
      end
    end,
  })
end

M.setup_sidebar_guard()

return M
