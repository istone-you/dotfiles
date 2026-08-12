-- config.completion は LSP 補完（IntelliSense 相当）。実サーバーは立てず、
-- 検証するのは: completeopt 等の設定、自動トリガー判定、メニュー表示中だけ働く
-- <Tab>/<S-Tab>、LspAttach でクライアントが取れない場合に落ちないこと。
local T = dofile(TESTS_DIR .. '/helpers.lua')
local completion = require('config.completion')

T.describe('completion: 設定', function()
  T.it('completeopt に menuone/noinsert/popup が入る', function()
    T.eq(vim.o.completeopt, completion.COMPLETEOPT)
    T.contains(vim.o.completeopt, 'menuone')
    T.contains(vim.o.completeopt, 'noinsert') -- 確定するまでバッファに入れない
    T.contains(vim.o.completeopt, 'popup')    -- 候補のドキュメントを出す
  end)

  T.it('pumheight を絞ってメニューが画面を覆わないようにする', function()
    T.eq(vim.o.pumheight, 12)
  end)
end)

T.describe('completion.should_trigger', function()
  T.it('単語を打っている途中なら true', function()
    T.eq(completion.should_trigger('local foo'), true)
    T.eq(completion.should_trigger('  vim.ap'), true)
    T.eq(completion.should_trigger('x'), true)
  end)

  T.it('単語文字以外で終わっていれば false（トリガー文字は組み込み側の担当）', function()
    T.eq(completion.should_trigger(''), false)
    T.eq(completion.should_trigger('local '), false)
    T.eq(completion.should_trigger('vim.'), false)
    T.eq(completion.should_trigger('foo('), false)
  end)
end)

T.describe('completion.can_complete', function()
  T.it('特殊バッファ（explorer 等）では補完しない', function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = 'nofile'
    vim.api.nvim_set_current_buf(buf)
    T.eq(completion.can_complete(), false)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  T.it('メニューが既に出ているときは重ねて出さない', function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    local orig = vim.fn.pumvisible
    vim.fn.pumvisible = function() return 1 end
    T.eq(completion.can_complete(), false)
    vim.fn.pumvisible = orig
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  T.it('ノーマルモード（インサート中でない）なら出さない', function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    T.eq(vim.fn.mode(), 'n')
    T.eq(completion.can_complete(), false)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

T.describe('completion: <Tab>/<S-Tab>', function()
  local function expr_of(lhs)
    -- nvim は <C-n> を <C-N> のように正規化して返すので大文字小文字を無視して照合する
    for _, m in ipairs(vim.api.nvim_get_keymap('i')) do
      if m.lhs:lower() == lhs:lower() then return m.callback end
    end
  end

  T.it('メニュー非表示なら素の Tab / S-Tab を返す', function()
    T.eq(expr_of('<Tab>')(), '<Tab>')
    T.eq(expr_of('<S-Tab>')(), '<S-Tab>')
  end)

  T.it('メニュー表示中は候補移動になる', function()
    local orig = vim.fn.pumvisible
    vim.fn.pumvisible = function() return 1 end
    T.eq(expr_of('<Tab>')(), '<C-n>')
    T.eq(expr_of('<S-Tab>')(), '<C-p>')
    vim.fn.pumvisible = orig
  end)

  T.it('手動トリガー <C-n> が張られている', function()
    T.ok(expr_of('<C-n>') ~= nil, '<C-n> should be mapped in insert mode')
  end)
end)

T.describe('completion.attach', function()
  T.it('クライアントが取れなければ何もせず false', function()
    local buf = vim.api.nvim_create_buf(false, true)
    T.eq(completion.attach(nil, buf), false)
    T.eq(completion.attach(99999, buf), false) -- 存在しない client_id
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  T.it('LspAttach が飛んでも（クライアント不在でも）エラーにならない', function()
    local buf = vim.api.nvim_create_buf(false, true)
    local ok = pcall(vim.api.nvim_exec_autocmds, 'LspAttach',
      { buffer = buf, data = { client_id = 99999 } })
    T.eq(ok, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

T.describe('completion.trigger', function()
  T.it('補完できない状況では LSP リクエストを投げない', function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = 'nofile'
    vim.api.nvim_set_current_buf(buf)

    local called = false
    local orig = vim.lsp.completion.get
    vim.lsp.completion.get = function() called = true end
    completion.trigger()
    vim.lsp.completion.get = orig

    T.eq(called, false)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

T.summary()
