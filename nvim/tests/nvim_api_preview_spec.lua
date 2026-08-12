-- preview.lua（バッファのハイライト → ANSI 変換）と /api/preview エンドポイント、
-- および notes/search のプレビューコマンド生成（curl 版 / sed フォールバック）のテスト。
-- ここが「fzf プレビューをエディタと同じ色にする」機能の要。

local T = dofile(TESTS_DIR .. '/helpers.lua')

-- 色を決定的にするため truecolor + 実際に使う colorscheme を読む（VIMRUNTIME 同梱なので
-- -u NONE でもロードできる）。これが無いと @comment 等に gui fg が付かず色が出ない。
vim.o.termguicolors = true
vim.cmd.colorscheme('retrobox')

local P = require('config.nvim_api.preview')
local server = require('config.nvim_api.server')
local util = require('config.nvim_api.util')

local function strip(s)
  return (tostring(s or ''):gsub('\27%[[0-9;]*m', ''))
end

local function has_truecolor(s)
  return tostring(s or ''):find('\27%[[0-9;]*38;2;') ~= nil
end

local function make_buf(lines, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft
  return buf
end

T.describe('nvim_api preview: buffer -> ANSI', function()
  T.it('colorizes a known filetype and preserves the visible text', function()
    local buf = make_buf({ 'local x = 42', 'return x' }, 'lua')
    local out = P.render_buf(buf)
    T.ok(has_truecolor(out), 'lua should get truecolor SGR')
    -- ANSI を剥がすと元テキストに一致する（色は上乗せで文字を壊さない）
    T.eq(strip(out), 'local x = 42\nreturn x')
  end)

  T.it('returns plain text (no ANSI) when there is no treesitter parser', function()
    local buf = make_buf({ 'just some words', 'no parser here' }, 'text')
    local out = P.render_buf(buf)
    T.ok(not has_truecolor(out), 'unknown ft should not be colored')
    T.eq(out, 'just some words\nno parser here')
  end)

  T.it('highlights injected languages (markdown fenced code block)', function()
    local buf = make_buf({ '# h', '```go', 'func x() int { return 1 }', '```' }, 'markdown')
    local out = P.render_buf(buf)
    T.ok(has_truecolor(out), 'markdown with a go fence should be colored')
    T.ok(strip(out):find('func x() int', 1, true), 'the code text itself must survive')
  end)

  T.it('caps output at max_lines', function()
    local lines = {}
    for i = 1, 50 do lines[i] = 'line ' .. i end
    local buf = make_buf(lines, 'text')
    local out = P.render_buf(buf, { max_lines = 3 })
    T.eq(select(2, out:gsub('\n', '\n')), 2) -- 3 行 = 改行 2 個
    T.eq(strip(out), 'line 1\nline 2\nline 3')
  end)

  T.it('multibyte text keeps its bytes intact through coloring', function()
    local buf = make_buf({ '-- 日本語コメント' }, 'lua')
    local out = P.render_buf(buf)
    T.eq(strip(out), '-- 日本語コメント')
  end)
end)

T.describe('nvim_api preview: render_file', function()
  T.it('reads a file and colorizes it', function()
    local dir = util.real(vim.fn.tempname())
    vim.fn.mkdir(dir, 'p')
    local f = dir .. '/a.lua'
    vim.fn.writefile({ 'local ok = true', 'return ok' }, f)
    local out = P.render_file(f)
    T.ok(has_truecolor(out), 'file preview should be colored')
    T.eq(strip(out), 'local ok = true\nreturn ok')
  end)

  T.it('returns nil for an unreadable path', function()
    T.eq(P.render_file('/no/such/file/really.xyz'), nil)
  end)
end)

-- 生 HTTP レスポンスから status と body を取り出す
local function parse_response(raw)
  local status = raw:match('^HTTP/1%.1 (%d+)')
  local body = raw:match('\r\n\r\n(.*)$') or ''
  return tonumber(status), body
end

local function get_preview(query)
  local resp = server.response_for_request(
    { method = 'GET', path = '/api/preview', query = query, body = '' })
  return parse_response(resp or '')
end

T.describe('nvim_api preview: /api/preview endpoint', function()
  T.it('serves ANSI-colored preview for a file under the cwd', function()
    -- テストは nvim/ を cwd に走る。cwd 配下なら preview_allowed を通る。
    local abs = util.real(vim.fn.getcwd()) .. '/lua/config/nvim_api/preview.lua'
    local status, body = get_preview('path=' .. abs)
    T.eq(status, 200)
    T.ok(has_truecolor(body), 'endpoint body should carry truecolor SGR')
  end)

  T.it('rejects a path outside the allowed roots with 404', function()
    local status = get_preview('path=/etc/passwd')
    T.eq(status, 404)
  end)

  T.it('returns 400 when path is missing', function()
    local status = get_preview('')
    T.eq(status, 400)
  end)
end)

T.describe('notes/search preview command', function()
  local notes = require('config.notes')
  local search = require('config.search')
  local api = require('config.nvim_api')

  T.it('falls back to sed when the nvim_api server is not running', function()
    local saved = api.state.port
    api.state.port = nil
    local ok, err = pcall(function()
      T.eq(notes._private.preview_cmd(), [[sed -n '1,200p' -- {1}]])
      T.eq(search._private.preview_cmd(), [[sed -n '1,200p' -- {1}]])
    end)
    api.state.port = saved
    if not ok then error(err) end
  end)

  T.it('uses curl against the server port when available, with sed as fallback', function()
    if vim.fn.executable('curl') ~= 1 then return end -- curl 無し環境では curl 版に切り替わらない
    local saved = api.state.port
    api.state.port = 45123
    local ok, err = pcall(function()
      for _, cmd in ipairs({ notes._private.preview_cmd(), search._private.preview_cmd() }) do
        T.ok(cmd:find('curl', 1, true), 'should call curl')
        T.ok(cmd:find('45123', 1, true), 'should target the server port')
        T.ok(cmd:find([[|| sed -n '1,200p' -- {1}]], 1, true), 'should keep sed fallback')
      end
    end)
    api.state.port = saved
    if not ok then error(err) end
  end)
end)
