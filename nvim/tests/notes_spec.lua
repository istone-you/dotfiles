-- tests/notes_spec.lua
local T = dofile(TESTS_DIR .. '/helpers.lua')
local notes = require('config.notes')

-- テスト用の一時ディレクトリ。パス比較を安定させるため normalize してから使う
-- （.config/CLAUDE.md のパス方針。両辺を同じ作り方で組み立てる）。
local function tmpdir()
  local dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(dir, 'p')
  return dir
end

local function read(path)
  local f = assert(io.open(path, 'r'))
  local body = f:read('a')
  f:close()
  return body
end

T.describe('notes.new_note_path', function()
  T.it('衝突が無ければ <dir>/<stamp>.md', function()
    local dir = tmpdir()
    T.eq(notes.new_note_path(dir, '20260812-100000'), dir .. '/20260812-100000.md')
  end)

  T.it('同名があれば -2, -3 と連番で避ける', function()
    local dir = tmpdir()
    local f1 = assert(io.open(dir .. '/20260812-100000.md', 'w')); f1:close()
    T.eq(notes.new_note_path(dir, '20260812-100000'), dir .. '/20260812-100000-2.md')
    local f2 = assert(io.open(dir .. '/20260812-100000-2.md', 'w')); f2:close()
    T.eq(notes.new_note_path(dir, '20260812-100000'), dir .. '/20260812-100000-3.md')
  end)
end)

T.describe('notes.create_blank', function()
  T.it('空ファイルを作り、そのパスを返す（見出しは付けない）', function()
    local dir = tmpdir()
    local path = notes.create_blank(dir, '20260812-120000')
    T.eq(path, dir .. '/20260812-120000.md')
    T.ok(vim.fn.filereadable(path) == 1, 'ファイルが作られること')
    T.eq(read(path), '', '中身は空であること')
  end)

  T.it('ディレクトリが無くても作成する', function()
    local dir = tmpdir() .. '/sub/notes'
    T.ok(vim.fn.isdirectory(dir) == 0, '事前に存在しないこと')
    local path = notes.create_blank(dir, '20260812-130000')
    T.ok(vim.fn.filereadable(path) == 1, 'ディレクトリごと作られること')
  end)

  T.it('連続作成で上書きせず別ファイルになる', function()
    local dir = tmpdir()
    local a = notes.create_blank(dir, '20260812-140000')
    local b = notes.create_blank(dir, '20260812-140000')
    T.ok(a ~= b, '同じ stamp でも別パスになること')
    T.eq(b, dir .. '/20260812-140000-2.md')
  end)
end)

T.describe('notes.parse_result_line', function()
  local dir = '/notes'

  T.it('本文ヒット行（path:line:col:text）を分解し、相対パスを絶対化する', function()
    local r = notes.parse_result_line('20260812-100000.md:3:5:本文テキスト', dir)
    T.eq(r, { path = '/notes/20260812-100000.md', lnum = 3, col = 5 })
  end)

  T.it('一覧行（path:1:1:先頭行）も同じ形として分解できる', function()
    local r = notes.parse_result_line('20260812-100000.md:1:1:買い物リスト', dir)
    T.eq(r, { path = '/notes/20260812-100000.md', lnum = 1, col = 1 })
  end)

  T.it('rg --color=always の ANSI を除去してから分解する', function()
    local line = '\27[35mmemo.md\27[0m:\27[32m12\27[0m:\27[32m1\27[0m:x'
    local r = notes.parse_result_line(line, dir)
    T.eq(r, { path = '/notes/memo.md', lnum = 12, col = 1 })
  end)

  T.it('絶対パスはそのまま使う', function()
    local r = notes.parse_result_line('/abs/x.md:2:1:t', dir)
    T.eq(r, { path = '/abs/x.md', lnum = 2, col = 1 })
  end)

  T.it('空行は nil', function()
    T.eq(notes.parse_result_line('', dir), nil)
    T.eq(notes.parse_result_line(nil, dir), nil)
  end)
end)

T.summary()
