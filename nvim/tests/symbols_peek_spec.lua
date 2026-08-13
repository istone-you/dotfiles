local T = dofile(TESTS_DIR .. '/helpers.lua')
local symbols = require('config.symbols')
local peek = require('config.peek')

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'x', false)
end

--- 実LSPサーバーを立てずにvim.lsp側を差し替えて「クライアントが繋がっている」体で
--- テストする。差し替えはこのプロセス内だけの一時的なもの
local function fake_one_client()
  vim.lsp.get_clients = function() return { { offset_encoding = 'utf-16' } } end
end

T.describe('symbols (file outline picker)', function()
  T.it('warns and does nothing when no LSP client is attached', function()
    local notified
    local orig_notify = vim.notify
    vim.notify = function(msg, level) notified = { msg = msg, level = level } end
    vim.lsp.get_clients = function() return {} end

    symbols.open()

    vim.notify = orig_notify
    T.ok(notified ~= nil, 'should notify')
    T.contains(notified.msg, 'LSP')
    T.eq(#vim.tbl_filter(function(w)
      return vim.api.nvim_win_get_config(w).relative ~= ''
    end, vim.api.nvim_list_wins()), 0, 'no floating window should open')
  end)

  T.it('flattens nested DocumentSymbols (indented) and jumps to the selected one on <CR>', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/f.lua', { 'local M = {}', 'function M.foo() end', 'function M.bar() end', 'return M' })
    vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/f.lua'))

    fake_one_client()
    local orig_request_all = vim.lsp.buf_request_all
    vim.lsp.buf_request_all = function(_, _, _, cb)
      cb({
        [1] = { result = {
          {
            name = 'M', kind = 5, range = { start = { line = 0, character = 0 } },
            children = {
              { name = 'foo', kind = 6, range = { start = { line = 1, character = 0 } } },
              { name = 'bar', kind = 6, range = { start = { line = 2, character = 0 } } },
            },
          },
        } },
      })
    end

    symbols.open()
    vim.wait(100)

    local results_win
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local cfg = vim.api.nvim_win_get_config(w)
      local buf = vim.api.nvim_win_get_buf(w)
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
      if cfg.relative ~= '' and text:find('M', 1, true) and text:find('foo', 1, true) then results_win = w end
    end
    T.ok(results_win ~= nil, 'a results window should be showing')
    local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(results_win), 0, -1, false), '\n')
    T.contains(text, 'M')
    T.contains(text, 'foo')
    T.contains(text, 'bar')
    T.contains(text, '├─')
    T.contains(text, '└─')

    -- filter down to "bar"。TextChangedI/TextChangedはheadlessの合成feedkeysだと
    -- 確実に発火しないため、明示的に発火させてapply_filter()を確実に走らせる
    local prompt_buf = vim.api.nvim_get_current_buf()
    feed('ibar')
    vim.wait(30)
    vim.api.nvim_exec_autocmds('TextChangedI', { buffer = prompt_buf })
    vim.wait(30)
    local filtered_text = table.concat(
      vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(results_win), 0, -1, false), '\n')
    T.contains(filtered_text, 'bar')
    T.ok(not filtered_text:find('foo', 1, true), 'filter should narrow the list down to just "bar"')

    -- 前段のフィルタ確認で開いたsymbolsセッションをまだ閉じていないので、先に閉じる
    -- (閉じないと次のsymbols.open()のoriginal_winがf.luaではなく前のsymbolsウィンドウ
    -- を指してしまう)
    feed('i<Esc>')
    vim.wait(30)

    -- <CR>でのジャンプは(フィルタと同一フローに依存させず)別途、素の状態で確認する
    symbols.open()
    vim.wait(100)
    vim.lsp.buf_request_all = orig_request_all
    -- startinsert!はheadless(-l)実行では実際には持続しない(vim.waitを挟むとNormalに
    -- 戻る)ため、'i'で明示的に入りつつ同じfeedkeys呼び出し内で<CR>まで送る
    feed('i<CR>')
    vim.wait(50)
    -- macOSでは/var -> /privaite/varのsymlinkがあり、nvim側は解決済みパスを返すため、
    -- 比較前に双方を実パスへ揃える
    T.eq(vim.loop.fs_realpath(vim.api.nvim_buf_get_name(0)), vim.loop.fs_realpath(dir .. '/f.lua'),
      '<CR> should jump back into the source file')
    T.eq(vim.api.nvim_win_get_cursor(0)[1], 1, '<CR> on the unfiltered list jumps to the first symbol (M, line 1)')

    T.rmrf(dir)
  end)

  T.it('uses TreeSitter definitions for JavaScript instead of ts_ls callback outlines', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/app.js', {
      "const express = require('express');",
      'const app = express();',
      'app.use((req, res, next) => {',
      "  const tracer = trace.getTracer('service');",
      '  next();',
      '});',
      "app.get('/api/v1/:apiEndpoint', async (req, res, next) => handler(req, res).catch(next));",
      'const writeContentsById = async ({ openSearchClient, contentIds }) => {',
      '  await bulkIndex(openSearchClient, contentIds);',
      '};',
      'class ApiClient {',
      '  request() { return true; }',
      '}',
      'module.exports = app;',
    })
    vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/app.js'))
    vim.bo.filetype = 'javascript'

    vim.lsp.get_clients = function() return {} end
    symbols.open()
    vim.wait(100)

    local results_win
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local cfg = vim.api.nvim_win_get_config(w)
      local buf = vim.api.nvim_win_get_buf(w)
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
      if cfg.relative ~= '' and text:find('writeContentsById', 1, true) then results_win = w end
    end
    T.ok(results_win ~= nil, 'a symbols results window should be showing')
    local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(results_win), 0, -1, false), '\n')
    T.contains(text, 'writeContentsById')
    T.contains(text, 'ApiClient')
    T.contains(text, 'request')
    T.contains(text, 'GET /api/v1/:apiEndpoint')
    T.ok(not text:find('app%.use%(%) callback'), 'ts_ls callback outline should not be used for JavaScript')
    T.ok(not text:find('openSearchClient', 1, true), 'function parameters should not be listed as symbols')
    T.ok(not text:find('tracer', 1, true), 'local constants inside callbacks should not be listed as symbols')

    feed('<Down>')
    vim.wait(30)
    T.eq(vim.api.nvim_win_get_cursor(results_win)[1], 2, '<Down> from the prompt should move selection')

    vim.cmd('stopinsert')
    vim.api.nvim_set_current_win(results_win)
    feed('k')
    vim.wait(30)
    T.eq(vim.api.nvim_win_get_cursor(results_win)[1], 1, 'k should move to the previous symbol')
    feed('k')
    vim.wait(30)
    T.eq(vim.api.nvim_win_get_cursor(results_win)[1], #vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(results_win), 0, -1, false),
      'k on the first symbol should wrap to the last symbol')

    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= '' then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
    T.rmrf(dir)
  end)
end)

T.describe('peek (LSP go-to-definition/references peek)', function()
  T.it('warns and does nothing when no LSP client is attached', function()
    local notified
    local orig_notify = vim.notify
    vim.notify = function(msg, level) notified = { msg = msg, level = level } end
    vim.lsp.get_clients = function() return {} end

    peek.definition()

    vim.notify = orig_notify
    T.ok(notified ~= nil, 'should notify')
    T.contains(notified.msg, 'LSP')
  end)

  T.it('shows a list+preview of results, j/k navigate, <CR> jumps to the selected location', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/a.lua', { 'local a1 = 1', 'local a2 = 2' })
    T.write_file(dir .. '/b.lua', { 'local b1 = 1', 'local b2 = 2' })
    vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/a.lua'))

    fake_one_client()
    local orig_request_all = vim.lsp.buf_request_all
    vim.lsp.buf_request_all = function(_, _, _, cb)
      cb({
        [1] = { result = {
          { uri = vim.uri_from_fname(dir .. '/a.lua'), range = { start = { line = 0, character = 0 } } },
          { uri = vim.uri_from_fname(dir .. '/b.lua'), range = { start = { line = 1, character = 0 } } },
        } },
      })
    end

    peek.definition()
    vim.wait(80)

    local list_win
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local cfg = vim.api.nvim_win_get_config(w)
      if cfg.relative ~= '' and cfg.focusable ~= false then list_win = w end
    end
    T.ok(list_win ~= nil, 'a results list window should be showing')
    local list_text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(list_win), 0, -1, false), '\n')
    T.contains(list_text, 'a.lua:1')
    T.contains(list_text, 'b.lua:2')
    T.contains(list_text, '▶ ', 'first result should be marked as selected')

    vim.api.nvim_set_current_win(list_win)
    feed('j') -- move to the 2nd result (b.lua)
    -- 選択の追随はCursorMovedが担うが、headlessでは合成キー入力でこのイベントが
    -- 飛ばないため明示的に発火させる（helpers.lua冒頭の3.）
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = vim.api.nvim_win_get_buf(list_win) })
    vim.wait(30)
    feed('<CR>')
    vim.wait(50)
    vim.lsp.buf_request_all = orig_request_all

    T.eq(vim.loop.fs_realpath(vim.api.nvim_buf_get_name(0)), vim.loop.fs_realpath(dir .. '/b.lua'),
      '<CR> should jump into b.lua (the 2nd, j-selected result)')
    T.eq(vim.api.nvim_win_get_cursor(0)[1], 2, 'should land on line 2 (0-indexed line 1 + 1)')

    T.rmrf(dir)
  end)

  -- j/k だけをマッピングして選択を進める作りだと、<Down>やマウスクリック・gg/G で
  -- カーソルだけが動いて選択が1件目に取り残され、プレビューもジャンプ先も固定される。
  -- 「カーソル行こそが選択」になっていることを、キーマップを介さないカーソル移動で確かめる。
  T.it('preview and selection follow the cursor even when moved without j/k', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/a.lua', { 'A1', 'A2', 'A3' })
    T.write_file(dir .. '/b.lua', { 'B1', 'B2', 'B3' })
    T.write_file(dir .. '/c.lua', { 'C1', 'C2', 'C3' })
    vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/a.lua'))

    fake_one_client()
    local orig_request_all = vim.lsp.buf_request_all
    vim.lsp.buf_request_all = function(_, _, _, cb)
      cb({
        [1] = { result = {
          { uri = vim.uri_from_fname(dir .. '/a.lua'), range = { start = { line = 0, character = 0 } } },
          { uri = vim.uri_from_fname(dir .. '/b.lua'), range = { start = { line = 1, character = 0 } } },
          { uri = vim.uri_from_fname(dir .. '/c.lua'), range = { start = { line = 2, character = 0 } } },
        } },
      })
    end

    peek.references()
    vim.wait(80)
    vim.lsp.buf_request_all = orig_request_all

    local list_win, prev_win
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local cfg = vim.api.nvim_win_get_config(w)
      if cfg.relative ~= '' then
        if cfg.focusable == false then prev_win = w else list_win = w end
      end
    end
    T.ok(list_win ~= nil and prev_win ~= nil, 'both the list and preview windows should be showing')

    --- 選択行(▶)・プレビューのファイル・プレビューのカーソル行をまとめて見る
    local function state()
      local list_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(list_win), 0, -1, false)
      local marked
      for i, l in ipairs(list_lines) do
        if l:match('^▶') then marked = i end
      end
      local pbuf = vim.api.nvim_win_get_buf(prev_win)
      return {
        marked  = marked,
        preview = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(pbuf), ':t'),
        line    = vim.api.nvim_win_get_cursor(prev_win)[1],
      }
    end

    T.eq(state(), { marked = 1, preview = 'a.lua', line = 1 }, 'starts on the 1st result')

    -- <Down>/マウスクリック/gg/G と同じ「キーマップを通らないカーソル移動」
    vim.api.nvim_set_current_win(list_win)
    vim.api.nvim_win_set_cursor(list_win, { 3, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = vim.api.nvim_win_get_buf(list_win) })
    vim.wait(30)
    T.eq(state(), { marked = 3, preview = 'c.lua', line = 3 },
      'moving the cursor without j/k should still move the selection and preview')

    vim.api.nvim_win_set_cursor(list_win, { 2, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = vim.api.nvim_win_get_buf(list_win) })
    vim.wait(30)
    T.eq(state(), { marked = 2, preview = 'b.lua', line = 2 }, 'and back up again')

    -- カーソル行が選択なので、<CR> のジャンプ先もカーソル行と一致する
    feed('<CR>')
    vim.wait(50)
    T.eq(vim.loop.fs_realpath(vim.api.nvim_buf_get_name(0)), vim.loop.fs_realpath(dir .. '/b.lua'),
      '<CR> should follow the cursor, not the last j/k position')

    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= '' then pcall(vim.api.nvim_win_close, w, true) end
    end
    T.rmrf(dir)
  end)

  -- CLAUDE.md のルール: 新しいウィンドウを足したら SIDEBAR_FT に filetype を足し、
  -- 開いた直後に mark_sidebar を呼ぶ（両方）。加えて一覧選択窓なのでカーソルも隠す。
  T.it('marks the peek windows as sidebar utility windows and hides the text cursor', function()
    local win_util = require('config.util.win_util')
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/a.lua', { 'A1', 'A2' })
    vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/a.lua'))

    fake_one_client()
    local orig_request_all = vim.lsp.buf_request_all
    vim.lsp.buf_request_all = function(_, _, _, cb)
      cb({ [1] = { result = {
        { uri = vim.uri_from_fname(dir .. '/a.lua'), range = { start = { line = 0, character = 0 } } },
      } } })
    end
    peek.definition()
    vim.wait(80)
    vim.lsp.buf_request_all = orig_request_all

    local list_win, prev_win
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local cfg = vim.api.nvim_win_get_config(w)
      if cfg.relative ~= '' then
        if cfg.focusable == false then prev_win = w else list_win = w end
      end
    end
    T.ok(list_win ~= nil and prev_win ~= nil, 'both peek windows should be showing')
    local list_buf = vim.api.nvim_win_get_buf(list_win)

    T.eq(vim.bo[list_buf].filetype, 'peek', 'the list buffer needs a filetype to be matched by SIDEBAR_FT')
    T.eq(win_util.SIDEBAR_FT['peek'], true, 'peek must be registered in SIDEBAR_FT')
    T.eq(vim.w[list_win].sidebar, true, 'mark_sidebar must be called on the list window')
    T.eq(vim.w[prev_win].sidebar, true, 'mark_sidebar must be called on the preview window')
    -- 忘れると「Peek を開いている間だけ Space Q で終了しない」形で壊れる
    T.eq(win_util.is_editor(list_win), false, 'the list window must not count as an editor window')
    T.eq(win_util.is_editor(prev_win), false, 'the preview window must not count as an editor window')

    -- カーソル行の強調だけで現在地を示すので、テキストカーソルは隠す
    T.eq(vim.b[list_buf].hide_cursor, true, 'the list buffer must be marked for hidden_cursor')
    vim.api.nvim_set_current_win(list_win)
    vim.api.nvim_exec_autocmds('BufEnter', { buffer = list_buf })
    T.eq(vim.o.guicursor, 'a:HiddenCursor', 'the text cursor must be hidden while the list window is focused')

    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= '' then pcall(vim.api.nvim_win_close, w, true) end
    end
    T.rmrf(dir)
  end)

  -- プレビューには実ファイルのバッファをそのまま載せるので、消し忘れると
  -- Peek を閉じたあとも編集中のファイルに強調行が残ってしまう
  T.it('clears the previewed line highlight when the peek window closes', function()
    local peek_ns = vim.api.nvim_get_namespaces()['peek_hl']
    T.ok(peek_ns ~= nil, 'peek_hl namespace should exist')

    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    T.write_file(dir .. '/a.lua', { 'A1', 'A2', 'A3' })
    T.write_file(dir .. '/b.lua', { 'B1', 'B2', 'B3' })
    vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/a.lua'))

    fake_one_client()
    local orig_request_all = vim.lsp.buf_request_all
    vim.lsp.buf_request_all = function(_, _, _, cb)
      cb({ [1] = { result = {
        { uri = vim.uri_from_fname(dir .. '/a.lua'), range = { start = { line = 0, character = 0 } } },
        { uri = vim.uri_from_fname(dir .. '/b.lua'), range = { start = { line = 1, character = 0 } } },
      } } })
    end

    --- peek_hl namespace の extmark 数（= 強調が残っている行数）
    local function marks(path)
      local buf = vim.fn.bufnr(path)
      if buf == -1 or not vim.api.nvim_buf_is_valid(buf) then return 0 end
      return #vim.api.nvim_buf_get_extmarks(buf, peek_ns, 0, -1, {})
    end

    local function list_window()
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        local cfg = vim.api.nvim_win_get_config(w)
        if cfg.relative ~= '' and cfg.focusable ~= false then return w end
      end
    end

    -- 1件目(a.lua)を出したあと2件目(b.lua)へ動かすと、a.lua 側の強調は消えている
    peek.references()
    vim.wait(80)
    local list_win = list_window()
    T.eq(marks(dir .. '/a.lua'), 1, 'the previewed line in a.lua is highlighted')

    vim.api.nvim_set_current_win(list_win)
    vim.api.nvim_win_set_cursor(list_win, { 2, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = vim.api.nvim_win_get_buf(list_win) })
    vim.wait(30)
    T.eq(marks(dir .. '/b.lua'), 1, 'the previewed line in b.lua is highlighted')
    T.eq(marks(dir .. '/a.lua'), 0, 'moving to another file must not leave a.lua highlighted')

    -- q で閉じたら、残っていた b.lua 側の強調も消える
    feed('q')
    vim.wait(50)
    T.eq(marks(dir .. '/b.lua'), 0, 'closing the peek window must clear the highlight')

    -- <CR> でジャンプした場合も同じ（jump() は close() を通る）
    peek.references()
    vim.wait(80)
    list_win = list_window()
    vim.api.nvim_set_current_win(list_win)
    T.eq(marks(dir .. '/a.lua'), 1, 'highlighted again after reopening')
    feed('<CR>')
    vim.wait(50)
    T.eq(marks(dir .. '/a.lua'), 0, 'jumping must not leave the highlight behind')

    vim.lsp.buf_request_all = orig_request_all
    T.rmrf(dir)
  end)

  T.it('maps implementation to gI, leaving the standard gi (last insert position) alone', function()
    T.contains(vim.fn.maparg('gI', 'n', false, true).desc or '', 'implementation')
    T.ok(vim.tbl_isempty(vim.fn.maparg('gi', 'n', false, true)),
      'gi must stay unmapped so the standard "jump to last insert position" keeps working')
    for key, want in pairs({ gd = 'definition', gr = 'references', gy = 'type definition' }) do
      T.contains(vim.fn.maparg(key, 'n', false, true).desc or '', want)
    end
  end)
end)

T.summary()
