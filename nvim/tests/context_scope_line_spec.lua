local T = dofile(TESTS_DIR .. '/helpers.lua')
local symbols = require('config.util.lsp_symbols')
local context = require('config.context')
require('config.scope_line')

local K = vim.lsp.protocol.SymbolKind

local function new_win_with_lines(lines, height)
  -- context.lua/scope_line.luaはbuftype ~= ''のバッファ(scratch=trueで作った'nofile'含む)
  -- を意図的に無視するため、通常の(buftype='')バッファを使う必要がある
  local buf = vim.api.nvim_create_buf(false, false)
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = 'lua'
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor', width = 40, height = height or 5, row = 0, col = 0,
  })
  return win, buf
end

--- documentSymbol の返り値を作る（s_line/e_line は0始まり）
local function sym(name, kind, s_line, e_line, children)
  return {
    name = name,
    kind = kind,
    range = { start = { line = s_line, character = 0 }, ['end'] = { line = e_line, character = 0 } },
    children = children,
  }
end

--- LSP を起こさずに済むよう、シンボル取得だけ差し替えて実行する
local function with_symbols(list, fn)
  local orig = symbols.symbols_for
  symbols.symbols_for = function() return list end
  local ok, err = pcall(fn)
  symbols.symbols_for = orig
  if not ok then error(err) end
end

local function find_ctx_win(src_win)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if w ~= src_win and vim.api.nvim_win_get_config(w).relative == 'win' then return w end
  end
end

T.describe('context.lua (sticky scrolled-out declaration header)', function()
  T.it('shows the scrolled-out enclosing declaration, hides it when back at the top', function()
    local lines = { 'function outer()' }
    for i = 1, 15 do table.insert(lines, ('  print(%d)'):format(i)) end
    table.insert(lines, 'end')
    local win, buf = new_win_with_lines(lines, 5)

    with_symbols({ sym('outer', K.Function, 0, 16) }, function()
      -- 下の方まで移動してスクロールさせる(function outer()が画面外に出る)
      vim.api.nvim_win_set_cursor(win, { 12, 0 })
      vim.cmd('normal! zt') -- 現在行を画面最上部にしてスクロールさせる
      vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
      vim.wait(50)

      local ctx_win = find_ctx_win(win)
      T.ok(ctx_win ~= nil, 'a context overlay window should appear once the declaration scrolled out of view')
      local ctx_text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(ctx_win), 0, -1, false), '\n')
      T.contains(ctx_text, 'function outer()')
      T.eq(vim.api.nvim_win_get_config(ctx_win).width, vim.api.nvim_win_get_width(win) - 1)

      -- 先頭まで戻ればcontextは不要になり消える
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
      vim.cmd('normal! zt')
      vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
      vim.wait(50)
      T.ok(not vim.api.nvim_win_is_valid(ctx_win), 'context overlay should close once back at the top')
    end)

    vim.api.nvim_win_close(win, true)
  end)

  T.it('does not stick control-flow blocks, only declarations', function()
    -- lua-language-server は if / for を kind=Package で返してくる。
    -- これを貼り付けると「今どの関数か」が埋もれるので出さない
    local lines = { 'function outer()', '  if cond then' }
    for i = 1, 15 do table.insert(lines, ('    print(%d)'):format(i)) end
    local win, buf = new_win_with_lines(lines, 5)

    with_symbols({
      sym('outer', K.Function, 0, 16, { sym('if', K.Package, 1, 16) }),
    }, function()
      vim.api.nvim_win_set_cursor(win, { 12, 0 })
      vim.cmd('normal! zt')
      vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
      vim.wait(50)

      local ctx_win = find_ctx_win(win)
      T.ok(ctx_win ~= nil, 'the enclosing function should still be shown')
      local ctx_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(ctx_win), 0, -1, false)
      T.eq(#ctx_lines, 1, 'only the function line should stick, not the if')
      T.contains(ctx_lines[1], 'function outer()')
    end)

    vim.api.nvim_win_close(win, true)
  end)

  T.it('does not re-set filetype on every update (it would reload the syntax file each time)', function()
    -- 'filetype' は同じ値でも代入すると FileType -> Syntax が必ず発火する。
    -- CursorMoved ごとに走るこの関数でそれをやると1行スクロールごとに数msかかる
    local lines = { 'function outer()' }
    for i = 1, 15 do table.insert(lines, ('  print(%d)'):format(i)) end
    local win, buf = new_win_with_lines(lines, 5)

    local fired = 0
    local grp = vim.api.nvim_create_augroup('context_spec_ft', { clear = true })
    vim.api.nvim_create_autocmd('FileType', {
      group = grp,
      callback = function(ev)
        if vim.bo[ev.buf].buftype == 'nofile' then fired = fired + 1 end
      end,
    })

    with_symbols({ sym('outer', K.Function, 0, 16) }, function()
      vim.api.nvim_win_set_cursor(win, { 12, 0 })
      vim.cmd('normal! zt')
      for _ = 1, 20 do
        vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
      end
    end)

    T.ok(fired <= 1, ('FileType should fire at most once for the context buffer, fired %d times'):format(fired))

    vim.api.nvim_del_augroup_by_id(grp)
    vim.api.nvim_win_close(win, true)
  end)

  T.it('collects only declarations that are above the visible top line', function()
    local lines = {}
    for i = 1, 30 do lines[i] = 'line ' .. i end
    local _, buf = new_win_with_lines(lines, 5)

    with_symbols({ sym('outer', K.Function, 4, 25) }, function()
      -- 宣言行(5行目)が画面内に見えているなら貼り付ける必要がない
      T.eq(#context._collect_contexts(buf, lines, 5), 0)
      -- 画面最上部が10行目まで下がれば、5行目は画面外なので貼り付ける
      local got = context._collect_contexts(buf, lines, 10)
      T.eq(#got, 1)
      T.eq(got[1].lnum, 5)
      T.eq(got[1].text, 'line 5')
    end)
  end)
end)

T.describe('scope_line.lua (current-block indent guide)', function()
  --- treesitter を実際に起動した状態で作る。
  --- パーサを起動しないと fold_range が nil を返し、インデント経路しか通らないので
  --- 言語ごとのノードの流儀の違い（この機能が壊れていた原因）をテストが素通りする
  local function new_ts_win(ft, lines)
    local win, buf = new_win_with_lines(lines, 20)
    vim.bo[buf].filetype = ft
    local ok = pcall(function() vim.treesitter.get_parser(buf, ft):parse() end)
    return win, buf, ok
  end

  local function guide_rows(buf)
    local rows = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces()['scope_line'], 0, -1, {})) do
      rows[m[2]] = true
    end
    return rows
  end

  T.it('draws a guide on every line inside a lua if-block', function()
    -- Lua の tree-sitter は `if ... then` と `end` を含まない block を返す。
    -- 昔はそれをそのまま「開始行と終了行を除いて」描いていたので1本も出なかった
    local win, buf, ok = new_ts_win('lua', {
      'local function outer(a)',
      '  for i = 1, 10 do',
      '    if a == i then',
      '      print(i)',
      '      print(i)',
      '    end',
      '  end',
      'end',
    })
    T.ok(ok, 'lua パーサが起動できること（この前提が崩れるとテストの意味が無い）')

    vim.api.nvim_win_set_cursor(win, { 4, 6 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })

    local rows = guide_rows(buf)
    T.ok(rows[3], 'if の中の1行目にガイド')
    T.ok(rows[4], 'if の中の2行目にガイド')
    T.ok(not rows[2], '`if a == i then` の行には引かない')
    T.ok(not rows[5], '`end` の行には引かない')

    vim.api.nvim_win_close(win, true)
  end)

  T.it('draws the same guide for the same code in typescript', function()
    -- TypeScript の statement_block は波括弧の行を含む。流儀が違っても結果は揃うこと
    local win, buf, ok = new_ts_win('typescript', {
      'class Foo {',
      '  bar() {',
      '    if (x) {',
      '      doA();',
      '      doB();',
      '    }',
      '  }',
      '}',
    })
    if not ok then return end -- パーサ未ビルドの環境ではスキップ

    vim.api.nvim_win_set_cursor(win, { 4, 6 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })

    local rows = guide_rows(buf)
    T.ok(rows[3] and rows[4], 'if の中の2行にガイド')
    T.ok(not rows[2] and not rows[5], '開き行と閉じ行には引かない')

    vim.api.nvim_win_close(win, true)
  end)

  T.it('picks the innermost block, not the enclosing function', function()
    local win, buf, ok = new_ts_win('lua', {
      'local function outer()',
      '  local t = 1',
      '  if t then',
      '    print(t)',
      '  end',
      '  return t',
      'end',
    })
    T.ok(ok)

    vim.api.nvim_win_set_cursor(win, { 4, 4 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })

    local rows = guide_rows(buf)
    T.ok(rows[3], 'if の中の行にガイド')
    T.ok(not rows[1] and not rows[5], '関数側の行にまでは広げない')

    vim.api.nvim_win_close(win, true)
  end)

  T.it('falls back to indentation when the language has no folds query', function()
    -- html は folds.scm を持っていないのでインデント判定に落ちる
    local win, buf = new_win_with_lines({
      '<body>',
      '  <div>',
      '    <p>a</p>',
      '    <p>b</p>',
      '  </div>',
      '</body>',
    }, 20)
    vim.bo[buf].filetype = 'html'

    vim.api.nvim_win_set_cursor(win, { 3, 4 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })

    local rows = guide_rows(buf)
    T.ok(rows[2] and rows[3], 'div の中の2行にガイド')
    T.ok(not rows[1] and not rows[4], '開き行と閉じ行には引かない')

    vim.api.nvim_win_close(win, true)
  end)

  T.it('draws nothing at top-level indent (indent 0 == no enclosing block)', function()
    local win, buf = new_win_with_lines({
      'local a = 1',
      'local b = 2',
    })
    vim.bo[buf].filetype = 'text'
    vim.api.nvim_win_set_cursor(win, { 2, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })

    T.eq(#vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces()['scope_line'], 0, -1, {}), 0,
      'no guide at top level')

    vim.api.nvim_win_close(win, true)
  end)
end)

T.summary()
