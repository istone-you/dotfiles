-- プレビュー窓へ実ファイルを載せるための共通処理（peek / call_hierarchy が使う）。
--
-- bufadd + bufload だけでは filetype が付かないことがある。LSP は診断を受け取った
-- 時点で対象ファイルのバッファを vim.uri_to_bufnr() で先に作るため、まだ一度も
-- 開いていないファイルでも「名前だけの unloaded なバッファ」が既に存在する。
-- bufadd はその既存バッファを返し、bufload は中身を読むだけで filetype 検出
-- （新規作成時の BufNew 経路）を通らないので ft が空のままになる。
--
-- ft が空だと FileType が飛ばず treesitter も起動しないので、
--   ・プレビューがシンタックスハイライト無しの素のテキストになる
--   ・そのバッファは残るので、あとで実際にそのファイルを開いたときも色が付かない
-- という形で表に出る（後者は「開いたファイルだけ急に色が消える」ように見える）。

local M = {}

--- プレビュー用にファイルのバッファを用意する。filetype が付いていなければ補う。
---@param filepath string
---@return integer bufnr
function M.load(filepath)
  local buf = vim.fn.bufadd(filepath)
  if not vim.api.nvim_buf_is_loaded(buf) then
    -- 別プロセスが同じファイルを開いている / クラッシュ後のスワップが残っていると
    -- bufload は E325(ATTENTION) で例外を投げる。素通ししてしまうと呼び出し元の
    -- プレビュー更新ごと巻き添えで止まり、選択を動かしても中身が変わらなくなる。
    -- プレビューは読むだけなので、警告は握って続行する（中身は読めている）
    pcall(vim.fn.bufload, buf)
  end
  if vim.bo[buf].filetype == '' then
    -- 中身も見て判定させる（shebang だけで決まるファイルがあるため buf も渡す）
    local ok, ft = pcall(vim.filetype.match, { buf = buf, filename = filepath })
    if ok and ft then vim.bo[buf].filetype = ft end
  end
  return buf
end

return M
