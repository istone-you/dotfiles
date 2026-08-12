-- LSP 補完（VSCode の IntelliSense 相当）
--
-- 土台は Neovim 0.11+ 組み込みの vim.lsp.completion。これを LspAttach で有効にすると
-- サーバーが申告した triggerCharacters（`.` や `::` など）では自動でメニューが出るが、
-- 「ふつうに単語を打っている最中」には出ない。VSCode はそこでも出るので、
-- TextChangedI を拾って自前でトリガーする層を足している。
--
-- キー: <Tab>/<S-Tab> で候補移動、<CR> で確定（確定は autopairs の on_cr が担当）、
--       <C-n> で手動トリガー、<C-e> でメニューを閉じる。

local M = {}

M.MIN_PREFIX  = 1   -- この文字数以上の単語を打っていたら自動でメニューを出す
M.DEBOUNCE_MS = 100 -- 連打中にリクエストを投げ続けないための待ち

-- menuone: 候補が1つでもメニューを出す（黙って確定されると何が入ったか分からない）
-- noinsert: 選択しても確定するまでバッファに入れない（VSCode と同じ挙動）
-- popup:    選択中の候補のドキュメントを横のポップアップに出す
-- fuzzy:    あいまい一致を許可する
M.COMPLETEOPT = 'menu,menuone,noinsert,popup,fuzzy'

local timer = nil

--- カーソル前のテキストから「自動でメニューを出すべきか」を判定する（純粋関数）
--- 単語文字を MIN_PREFIX 文字以上打っているときだけ true。トリガー文字（`.` 等）は
--- vim.lsp.completion の autotrigger 側が担当するのでここでは扱わない。
---@param before string カーソルより前の行テキスト
---@return boolean
function M.should_trigger(before)
  local word = before:match('[%w_]+$')
  return word ~= nil and #word >= M.MIN_PREFIX
end

--- 今このバッファで補完を出してよい状況か
---@return boolean
function M.can_complete()
  if vim.bo.buftype ~= '' then return false end      -- explorer / パネル等
  if vim.fn.pumvisible() == 1 then return false end  -- 既に出ている
  if vim.fn.mode() ~= 'i' then return false end
  return true
end

--- 補完リクエストを投げる（メニューが出せる状況なら）
--- パス文脈なら path_completion を優先し、それ以外は LSP 補完。
function M.trigger()
  if vim.bo.buftype ~= '' then return end
  if vim.fn.mode() ~= 'i' then return end
  local path = require('config.path_completion')
  if path.trigger() then return end
  if vim.fn.pumvisible() == 1 then return end
  local ok = pcall(vim.lsp.completion.get)
  if not ok then return end
end

--- デバウンス付きで M.trigger を呼ぶ
function M.schedule_trigger()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  local uv = vim.uv or vim.loop
  local this = uv.new_timer()
  timer = this
  -- schedule_wrap で実行が後回しになる間に次の入力が来て timer が差し替わることが
  -- ある。自分（this）が現役のときだけ後片付けする
  this:start(M.DEBOUNCE_MS, 0, vim.schedule_wrap(function()
    if timer == this then
      this:stop()
      this:close()
      timer = nil
    end
    local col  = vim.api.nvim_win_get_cursor(0)[2]
    local line = vim.api.nvim_get_current_line()
    local before = line:sub(1, col)
    -- パス文脈は path_completion 側の TextChangedI が担当するので LSP は出さない
    local path = require('config.path_completion')
    if path.is_path_context(before) then return end
    if M.should_trigger(before) then
      M.trigger()
    end
  end))
end

--- LspAttach 時にそのバッファで補完を有効化する
---@param client_id integer
---@param buf integer
function M.attach(client_id, buf)
  local client = vim.lsp.get_client_by_id(client_id)
  if not client then return false end
  if not client:supports_method('textDocument/completion') then return false end

  -- 組み込みの補完（triggerCharacters による自動発火つき）
  pcall(vim.lsp.completion.enable, true, client_id, buf, { autotrigger = true })

  -- 単語を打っている最中にもメニューを出す層
  vim.api.nvim_create_autocmd('TextChangedI', {
    group    = vim.api.nvim_create_augroup('user_completion_' .. buf, { clear = true }),
    buffer   = buf,
    callback = function() M.schedule_trigger() end,
  })
  return true
end

local function setup()
  vim.o.completeopt = M.COMPLETEOPT
  -- 補完メニューの高さ。0（無制限）だと画面いっぱいに広がって邪魔になる
  vim.o.pumheight = 12

  -- <Tab>/<S-Tab>: メニューが出ているときだけ候補移動に使う。出ていなければ素の挙動
  vim.keymap.set('i', '<Tab>', function()
    return vim.fn.pumvisible() == 1 and '<C-n>' or '<Tab>'
  end, { expr = true, silent = true, desc = '補完: 次の候補 / 素の Tab' })

  vim.keymap.set('i', '<S-Tab>', function()
    return vim.fn.pumvisible() == 1 and '<C-p>' or '<S-Tab>'
  end, { expr = true, silent = true, desc = '補完: 前の候補 / 素の S-Tab' })

  -- 手動トリガー。Ctrl-Space は mac で OS に奪われるため Ctrl-n。表示中は素の次候補。
  vim.keymap.set('i', '<C-n>', function()
    if vim.fn.pumvisible() == 1 then
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-n>', true, false, true), 'n', false)
    else
      M.trigger()
    end
  end, { silent = true, desc = '補完: 手動で候補を出す / 次の候補' })

  vim.api.nvim_create_autocmd('LspAttach', {
    group    = vim.api.nvim_create_augroup('user_completion', { clear = true }),
    callback = function(ev)
      M.attach(ev.data and ev.data.client_id, ev.buf)
    end,
  })
end

setup()

return M
