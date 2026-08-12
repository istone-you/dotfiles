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
    vim.wait(30)
    feed('<CR>')
    vim.wait(50)
    vim.lsp.buf_request_all = orig_request_all

    T.eq(vim.loop.fs_realpath(vim.api.nvim_buf_get_name(0)), vim.loop.fs_realpath(dir .. '/b.lua'),
      '<CR> should jump into b.lua (the 2nd, j-selected result)')
    T.eq(vim.api.nvim_win_get_cursor(0)[1], 2, 'should land on line 2 (0-indexed line 1 + 1)')

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
