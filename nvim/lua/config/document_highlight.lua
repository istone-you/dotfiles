-- カーソル下のシンボルと同じものを、そのファイル内でハイライトする（VS Code 相当）。
-- grep と違い LSP がスコープを解決するので、同名の別変数やコメント中の同じ語は光らない。
--
-- textDocument/documentHighlight は「読み取り(Read) / 書き込み(Write) / それ以外(Text)」を
-- kind で返してくるので、色を分けて代入箇所が一目で分かるようにしている。
--
-- ハイライトの適用/消去は組み込みの vim.lsp.util.buf_highlight_references /
-- buf_clear_references に任せる。LSP の character は utf-16 単位で、バイト列への
-- 変換をサーバーごとの offset_encoding に合わせて自前で書くと壊れやすいため。
-- 色は自前で定義する（この2つが使う LspReference* を上書きする）。

local M = {}

local timer   = nil
local enabled = true

-- 120ms。git_blame（250ms）より短くしているのは、blame と違って
-- 外部プロセスを起動せず LSP に投げるだけで、カーソル移動に追従して光ってほしいため
local DEBOUNCE_MS = 120

local function setup_hl()
  -- 読み取りと「それ以外」は青灰、書き込み（代入）だけ色を変えて目立たせる
  vim.api.nvim_set_hl(0, 'LspReferenceText',  { bg = '#3b4261' })
  vim.api.nvim_set_hl(0, 'LspReferenceRead',  { bg = '#3b4261' })
  vim.api.nvim_set_hl(0, 'LspReferenceWrite', { bg = '#4b3a4e' })
end
setup_hl()
vim.api.nvim_create_autocmd('ColorScheme', { callback = setup_hl })

---@param buf integer|nil 省略時はカレントバッファ
local function clear(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then return end
  vim.lsp.util.buf_clear_references(buf)
end

--- documentHighlight を返せるクライアントを1つ返す（無ければ nil）
---@param buf integer
local function highlight_client(buf)
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
    if client:supports_method('textDocument/documentHighlight') then
      return client
    end
  end
  return nil
end

local function show()
  if not enabled then return end
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= '' then return end

  local client = highlight_client(buf)
  if not client then return end

  -- 応答は非同期で返るので、投げた時点の位置を覚えておいて
  -- 戻ってきたときに動いていたら捨てる（カーソルを動かし続けても取り違えない）
  local win = vim.api.nvim_get_current_win()
  local pos = vim.api.nvim_win_get_cursor(win)

  local params = vim.lsp.util.make_position_params(win, client.offset_encoding)
  client:request('textDocument/documentHighlight', params, function(err, result)
    if err or not result or vim.tbl_isempty(result) then return end
    if not vim.api.nvim_buf_is_valid(buf) then return end
    if vim.api.nvim_get_current_buf() ~= buf then return end
    if not vim.api.nvim_win_is_valid(win) then return end
    local now = vim.api.nvim_win_get_cursor(win)
    if now[1] ~= pos[1] or now[2] ~= pos[2] then return end

    vim.lsp.util.buf_clear_references(buf)
    vim.lsp.util.buf_highlight_references(buf, result, client.offset_encoding)
  end, buf)
end

local function on_moved()
  clear()
  if timer then
    timer:stop()
    timer = nil
  end
  if not enabled then return end
  timer = vim.defer_fn(show, DEBOUNCE_MS)
end

vim.api.nvim_create_autocmd({ 'CursorMoved', 'BufEnter' }, { callback = on_moved })
vim.api.nvim_create_autocmd({ 'InsertEnter', 'BufLeave' }, { callback = function() clear() end })

--- 表示のON/OFF（colorizer と同じくコマンドで切り替える）
function M.toggle()
  enabled = not enabled
  if enabled then
    on_moved()
  else
    if timer then
      timer:stop()
      timer = nil
    end
    -- 開いている全バッファぶん消す（別バッファに残ったハイライトが取り残されないように）
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then clear(buf) end
    end
  end
  vim.notify('[document_highlight] ' .. (enabled and 'ON' or 'OFF'))
end

function M.is_enabled()
  return enabled
end

vim.api.nvim_create_user_command('DocumentHighlightToggle', M.toggle,
  { desc = 'カーソル下シンボルのハイライトをON/OFF' })

return M
