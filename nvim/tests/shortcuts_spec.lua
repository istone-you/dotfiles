local T = dofile(TESTS_DIR .. '/helpers.lua')
require('config.shortcuts')

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'x', false)
end

local function shortcuts_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == 'shortcuts' then return w end
  end
end

--- 前のitがassertion失敗で中断しパネルが開いたままでも次のテストへ
--- 汚染しないよう、開く前に必ずいったん閉じておく
local function open_fresh()
  local w = shortcuts_win()
  if w then
    vim.api.nvim_set_current_win(w)
    feed('q')
    vim.wait(50)
  end
  feed('<leader>?')
  vim.wait(80)
  return shortcuts_win()
end

T.describe('shortcuts', function()
  T.it('<leader>? opens the panel, toggles closed on a second press', function()
    local win = open_fresh()
    T.ok(win ~= nil, 'panel should open')
    local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), '\n')
    T.contains(text, '移動（ノーマル）')

    vim.api.nvim_set_current_win(win)
    feed('<leader>?')
    vim.wait(80)
    T.ok(shortcuts_win() == nil, 'panel should close on second toggle')
  end)

  T.it('renders all sections without error (basic SECTIONS integrity check)', function()
    local win = open_fresh()
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
    T.ok(#lines > 3, 'should render a non-trivial number of lines')
    local text = table.concat(lines, '\n')
    T.contains(text, 'Ctrl-h/j/k/l')
    T.contains(text, 'ターミナルモードは Ctrl-h/j のみ')
    vim.api.nvim_set_current_win(win)
    feed('q')
    vim.wait(50)
  end)

  T.it('covers the standard-key sections, including the ones added later', function()
    local win = open_fresh()
    local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), '\n')
    for _, header in ipairs({
      'ファイル・タグジャンプ', '折りたたみ', 'quickfix / location list',
      'diffモード', 'スペルチェック', 'その他・便利コマンド',
    }) do
      T.contains(text, header)
    end
    -- 標準キーの代表。gf は「パス先へのジャンプ」の入口なので特に落とさない
    for _, key in ipairs({ 'gf', 'gx', '{ / }', 'gn / gN', ']p', 'z=', 'do / dp' }) do
      T.contains(text, key)
    end
    vim.api.nvim_set_current_win(win)
    feed('q')
    vim.wait(50)
  end)

  T.it("lists '. (not the nonexistent '- mark) for the last-change jump", function()
    local win = open_fresh()
    local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), '\n')
    T.contains(text, "'.")
    T.ok(not text:find("'%-%s+最後の変更行へ"), "'- is not a real Vim mark and must not be listed")
    vim.api.nvim_set_current_win(win)
    feed('q')
    vim.wait(50)
  end)

  T.it('documents Peek on gI so the standard gi stays free', function()
    local win = open_fresh()
    local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), '\n')
    T.contains(text, 'g y / g I')
    T.contains(text, '最後にインサートした位置へ')
    vim.api.nvim_set_current_win(win)
    feed('q')
    vim.wait(50)
  end)

  T.it('panel window hides the number column and uses a transparent background', function()
    local win = open_fresh()
    T.ok(vim.wo[win].number == false, 'number column should be off')
    T.ok(vim.wo[win].relativenumber == false, 'relativenumber should be off')
    T.contains(vim.wo[win].winhighlight, 'Normal:ShortcutsBg')
    local bg = vim.api.nvim_get_hl(0, { name = 'ShortcutsBg' })
    T.ok(bg.bg == nil, 'ShortcutsBg should have no background (transparent)')
    vim.api.nvim_set_current_win(win)
    feed('q')
    vim.wait(50)
  end)

  T.it('/ filters rows by key or description substring, <BS> clears it', function()
    -- '/'はvim.ui.input()(既定実装はvim.fn.input()でコマンドラインの実対話入力を使う)
    -- 経由で、-lヘッドレス実行では実入力ストリームが無くブロックしてfeedkeysで駆動
    -- できない。vim.ui.input自体を差し替えて、ユーザーが"マクロ"と入力してEnterした
    -- 体をシミュレートする(このプロセス内だけの一時的な差し替え)
    local orig_input = vim.ui.input
    vim.ui.input = function(_, on_confirm) on_confirm('マクロ') end

    local win = open_fresh()
    vim.api.nvim_set_current_win(win)
    feed('/')
    vim.wait(50)
    vim.ui.input = orig_input

    local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), '\n')
    T.contains(text, 'マクロ')
    T.ok(not text:find('ビジュアルモード', 1, true), 'unrelated sections should be filtered out')

    feed('<BS>')
    vim.wait(50)
    text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), '\n')
    T.contains(text, 'ビジュアルモード', '<BS> should clear the filter and restore all sections')

    feed('q')
    vim.wait(50)
  end)
end)

T.summary()
