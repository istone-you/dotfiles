-- treesitter によるシンタックスハイライトと折りたたみを有効にする。
--
-- パーサは `nvim/parser/<lang>.so`、クエリは `nvim/queries/<lang>/*.scm` に置いてある。
-- 構文木に色を割り当てるのはクエリで、それを読んで実際に描画するのは Neovim コアなので、
-- このファイルには色の処理は無い。ここでやるのは filetype と言語名の対応付けと、
-- FileType での有効化だけ。
--
-- パーサが無い言語では start が失敗するが、その場合は従来の正規表現 syntax のまま
-- になる（pcall で握りつぶす）。nvim を上げて ABI が合わなくなった時も同じ経路を通る。

local M = {}

-- filetype -> tree-sitter の言語名。
-- 対象は lua/config/lsp.lua で LSP を設定している filetype に揃えている。
-- ここに書くのは名前がズレるものだけで、一致するもの（go, typescript, toml,
-- yaml, json, css, graphql, gomod, gowork, gotmpl, terraform, lua）は不要。
M.FT_LANG = {
  typescriptreact         = 'tsx',
  javascriptreact         = 'javascript', -- JSX は tree-sitter-javascript 本体が扱える
  jsonc                   = 'json',
  sh                      = 'bash',
  -- terraform 系はすべて tree-sitter-hcl の terraform 方言ひとつで賄う
  ['terraform-vars']      = 'terraform',
  opentofu                = 'terraform',
  ['opentofu-vars']       = 'terraform',
  -- 複合 filetype。下の base 判定でも拾えるが、context.lua など
  -- vim.treesitter.get_parser() を直接呼ぶ側のために register もしておきたいので明示する
  ['yaml.docker-compose'] = 'yaml',
  ['yaml.gitlab']         = 'yaml',
}

-- これより大きいバッファでは有効にしない。巨大な生成物やログを開いた時に
-- パース待ちで固まるのを防ぐ（この場合も従来 syntax にフォールバックする）
M.MAX_BYTES = 1024 * 1024

--- filetype に対応する tree-sitter の言語名を返す。
--- 対応表に無ければ filetype 名がそのまま言語名だとみなす（go, typescript など）。
--- `yaml.gitlab` のような複合 filetype は最初の `.` より前を見る。
---@param ft string
---@return string|nil
function M.lang_for(ft)
  if not ft or ft == '' then return nil end
  if M.FT_LANG[ft] then return M.FT_LANG[ft] end
  local base = ft:match('^([^.]+)%.')
  if base then return M.FT_LANG[base] or base end
  return ft
end

--- そのバッファで treesitter を有効にしてよいか。
--- パーサの有無はここでは見ない（start の失敗で判定する）。
---@param buf integer
---@return boolean
function M.should_start(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return false end
  -- 通常のファイルバッファのみ。terminal やパネル類（buftype=nofile）は対象外
  if vim.bo[buf].buftype ~= '' then return false end
  if not M.lang_for(vim.bo[buf].filetype) then return false end
  -- コアの ftplugin などで既に有効になっているなら何もしない
  if vim.treesitter.highlighter.active[buf] then return false end
  local bytes = vim.api.nvim_buf_get_offset(buf, vim.api.nvim_buf_line_count(buf))
  if bytes and bytes > M.MAX_BYTES then return false end
  return true
end

--- 折りたたみを構文木ベース（folds.scm）にする。有効にできたら true。
---
--- コアの ftplugin/lua.lua と同じく `vim.wo[0][0]` に入れる。これは「その窓の、
--- そのバッファに紐づく値」なので、別のファイルに切り替えても設定が残らない。
--- ただしコアは foldexpr しか設定しておらず、foldmethod は既定の manual のままで
--- 実際には折りたためない。ここでは foldmethod も expr にして実際に効かせる。
--- foldlevel を上げてあるのは、開いた直後に畳まれた状態だと読みにくいため
--- （`zc` / `za` で手動で畳む使い方になる）。
---@param buf integer
---@param lang string
---@return boolean
function M.enable_fold(buf, lang)
  -- folds.scm が無い言語（gomod / gowork / graphql 等）は対象外
  if #vim.api.nvim_get_runtime_file('queries/' .. lang .. '/folds.scm', false) == 0 then
    return false
  end
  -- 窓ローカルの設定なので、そのバッファが今の窓に出ている時だけ触る
  if vim.api.nvim_get_current_buf() ~= buf then return false end
  vim.wo[0][0].foldmethod = 'expr'
  vim.wo[0][0].foldexpr   = 'v:lua.vim.treesitter.foldexpr()'
  vim.wo[0][0].foldlevel  = 99
  return true
end

--- バッファで treesitter ハイライトを開始する。開始できたら true。
--- パーサが無い / クエリが壊れている場合は false を返し、従来 syntax のままにする。
---@param buf integer
---@return boolean
function M.start(buf)
  if not M.should_start(buf) then return false end
  local lang = M.lang_for(vim.bo[buf].filetype)
  if not pcall(vim.treesitter.start, buf, lang) then return false end
  M.enable_fold(buf, lang)
  return true
end

--- FileType で呼ぶ入口。
--- lua / markdown / help / query はコアの ftplugin が先に start しているので
--- M.start は false を返す。その場合でも折りたたみは設定されていないため、
--- ここで拾って有効にする（コアは foldexpr だけで foldmethod を変えないため）。
---@param buf integer
function M.on_filetype(buf)
  if M.start(buf) then return end
  local hl = vim.treesitter.highlighter.active[buf]
  if hl then M.enable_fold(buf, hl.tree:lang()) end
end

function M.setup()
  -- filetype 名と言語名がズレるものだけ登録する
  for ft, lang in pairs(M.FT_LANG) do
    pcall(vim.treesitter.language.register, lang, ft)
  end

  vim.api.nvim_create_autocmd('FileType', {
    group    = vim.api.nvim_create_augroup('config_treesitter', { clear = true }),
    callback = function(ev)
      M.on_filetype(ev.buf)
    end,
  })
end

M.setup()

return M
