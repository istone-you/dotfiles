-- config/panel/diff/parse.lua（生のunified diffの構造化）の単体テスト。
-- ここがずれると行番号・ファイル名・追加/削除の判定が全部ずれるので、
-- git が実際に吐く形（新規/削除/リネーム/バイナリ/git show のヘッダ/複合diff）を通す。

local T = dofile(TESTS_DIR .. '/helpers.lua')
local P = require('config.panel.diff.parse')

local function joined(...)
  return table.concat({ ... }, '\n')
end

T.describe('panel diff parse', function()
  T.it('reads paths, hunk ranges and per-line numbers from a plain modification', function()
    local doc = P.parse(joined(
      'diff --git a/f.txt b/f.txt',
      'index de98044..685044e 100644',
      '--- a/f.txt',
      '+++ b/f.txt',
      '@@ -10,3 +10,4 @@ section text',
      ' a',
      '-b',
      '+B',
      '+extra',
      ' c'
    ))
    T.eq(#doc.files, 1)
    local f = doc.files[1]
    T.eq(f.path, 'f.txt')
    T.eq(f.status, 'M')
    T.eq(f.added, 2)
    T.eq(f.deleted, 1)
    T.eq(#f.hunks, 1)

    local h = f.hunks[1]
    T.eq(h.old_start, 10)
    T.eq(h.new_start, 10)
    T.eq(h.section, 'section text')

    local kinds, olds, news = {}, {}, {}
    for _, l in ipairs(h.lines) do
      table.insert(kinds, l.kind)
      table.insert(olds, l.old_no or '-')
      table.insert(news, l.new_no or '-')
    end
    T.eq(table.concat(kinds, ','), 'ctx,del,add,add,ctx')
    T.eq(table.concat(olds, ','), '10,11,-,-,12')
    T.eq(table.concat(news, ','), '10,-,11,12,13')
  end)

  T.it('treats a hunk header without a count as one line', function()
    local doc = P.parse(joined(
      'diff --git a/f.txt b/f.txt', '--- a/f.txt', '+++ b/f.txt',
      '@@ -1 +1 @@', '-old', '+new'
    ))
    local h = doc.files[1].hunks[1]
    T.eq(h.old_count, 1)
    T.eq(h.new_count, 1)
  end)

  T.it('marks a new file (--- /dev/null) as added', function()
    local doc = P.parse(joined(
      'diff --git a/n.txt b/n.txt',
      'new file mode 100644',
      '--- /dev/null',
      '+++ b/n.txt',
      '@@ -0,0 +1 @@',
      '+new'
    ))
    T.eq(doc.files[1].status, 'A')
    T.eq(doc.files[1].path, 'n.txt')
  end)

  T.it('marks a deleted file and keeps the old path', function()
    local doc = P.parse(joined(
      'diff --git a/d.txt b/d.txt',
      'deleted file mode 100644',
      '--- a/d.txt',
      '+++ /dev/null',
      '@@ -1 +0,0 @@',
      '-gone'
    ))
    T.eq(doc.files[1].status, 'D')
    T.eq(doc.files[1].path, 'd.txt')
  end)

  T.it('reads both sides of a rename', function()
    local doc = P.parse(joined(
      'diff --git a/old.txt b/new.txt',
      'similarity index 100%',
      'rename from old.txt',
      'rename to new.txt'
    ))
    local f = doc.files[1]
    T.eq(f.status, 'R')
    T.eq(f.old_path, 'old.txt')
    T.eq(f.new_path, 'new.txt')
  end)

  T.it('flags a binary file and keeps its message', function()
    local doc = P.parse(joined(
      'diff --git a/i.png b/i.png',
      'index 1..2 100644',
      'Binary files a/i.png and b/i.png differ'
    ))
    T.eq(doc.files[1].binary, true)
    T.contains(doc.files[1].binary_message, 'Binary files')
  end)

  T.it('keeps the git show commit header as preamble, outside of any file', function()
    local doc = P.parse(joined(
      'commit deadbeef',
      'Author: a <a@b>',
      '',
      '    subject',
      '',
      'diff --git a/f.txt b/f.txt', '--- a/f.txt', '+++ b/f.txt',
      '@@ -1 +1 @@', '-a', '+b'
    ))
    T.eq(doc.preamble[1], 'commit deadbeef')
    T.eq(#doc.preamble, 5)
    T.eq(#doc.files, 1)
  end)

  T.it('expands tabs so the gutter cannot shift the columns', function()
    local doc = P.parse(joined(
      'diff --git a/f.go b/f.go', '--- a/f.go', '+++ b/f.go',
      '@@ -1 +1 @@', '-\tx', '+\ty'
    ))
    T.eq(doc.files[1].hunks[1].lines[1].text, '    x')
  end)

  T.it('keeps "\\ No newline at end of file" as its own line kind', function()
    local doc = P.parse(joined(
      'diff --git a/f.txt b/f.txt', '--- a/f.txt', '+++ b/f.txt',
      '@@ -1 +1 @@', '-a', '\\ No newline at end of file', '+b'
    ))
    local kinds = {}
    for _, l in ipairs(doc.files[1].hunks[1].lines) do table.insert(kinds, l.kind) end
    T.eq(table.concat(kinds, ','), 'del,nonl,add')
  end)

  T.it('reads a combined (merge) diff, where the markers are two columns wide', function()
    local doc = P.parse(joined(
      'diff --cc f.txt',
      'index 1,2..3',
      '--- a/f.txt',
      '+++ b/f.txt',
      '@@@ -1,2 -1,2 +1,2 @@@',
      '  same',
      '- ours',
      ' +theirs'
    ))
    local f = doc.files[1]
    T.eq(f.combined, true)
    T.eq(f.parents, 2)
    local kinds = {}
    for _, l in ipairs(f.hunks[1].lines) do table.insert(kinds, l.kind) end
    T.eq(table.concat(kinds, ','), 'ctx,del,add')
    T.eq(f.hunks[1].lines[1].text, 'same')
  end)

  T.it('splits several files in one stream', function()
    local doc = P.parse(joined(
      'diff --git a/a.txt b/a.txt', '--- a/a.txt', '+++ b/a.txt', '@@ -1 +1 @@', '-a', '+A',
      'diff --git a/b.txt b/b.txt', '--- a/b.txt', '+++ b/b.txt', '@@ -1 +1 @@', '-b', '+B'
    ))
    T.eq(#doc.files, 2)
    T.eq(doc.files[1].path, 'a.txt')
    T.eq(doc.files[2].path, 'b.txt')
  end)

  T.it('returns nothing for empty input', function()
    local doc = P.parse('')
    T.eq(#doc.files, 0)
    T.eq(#doc.preamble, 0)
  end)
end)

T.summary()
