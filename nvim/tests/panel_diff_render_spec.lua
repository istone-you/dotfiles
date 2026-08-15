-- config/panel/diff/render.lua（桁組みとハイライトの組み立て）の単体テスト。
-- 行番号ガター・差分の帯・語単位の強調・折り返し・side-by-side・treesitterの色が
-- 意図どおり出ているかをここで見る。

local T = dofile(TESTS_DIR .. '/helpers.lua')
local R = require('config.panel.diff.render')
local D = require('config.panel.diff')

local function joined(...)
  return table.concat({ ... }, '\n')
end

local SIMPLE = joined(
  'diff --git a/f.txt b/f.txt',
  '--- a/f.txt',
  '+++ b/f.txt',
  '@@ -1,3 +1,3 @@',
  ' keep',
  '-before',
  '+after',
  ' tail'
)

--- グループ名を持つマークだけ抜き出す
local function marks_of(result, group)
  local out = {}
  for _, m in ipairs(result.marks) do
    if m[4] == group then table.insert(out, m) end
  end
  return out
end

local function line_with(result, needle)
  for i, l in ipairs(result.lines) do
    if l:find(needle, 1, true) then return i, l end
  end
end

T.describe('panel diff render: unified', function()
  T.it('puts the old and new line numbers side by side in the gutter, keeping +/- markers', function()
    local r = R.render(SIMPLE, { width = 60 })
    local _, ctx = line_with(r, ' keep')
    local _, del = line_with(r, '-before')
    local _, add = line_with(r, '+after')
    T.contains(ctx, '1 ⋮  1 │ keep')
    T.contains(del, '2 ⋮    │-before')
    T.contains(add, '⋮  2 │+after')
  end)

  T.it('draws a file header with the path, the counts and a rule the width of the pane', function()
    local r = R.render(SIMPLE, { width = 40 })
    local hi, header = line_with(r, 'f.txt')
    T.contains(header, '+1 -1')
    T.eq(vim.api.nvim_strwidth(r.lines[hi + 1]), 40, 'the rule under the header should span the pane')
    T.eq(#marks_of(r, R.HL.file), 1)
  end)

  T.it('bands the changed rows with a full-line background, leaving context rows alone', function()
    local r = R.render(SIMPLE, { width = 60 })
    local fills = {}
    for _, g in pairs(r.fills) do fills[g] = (fills[g] or 0) + 1 end
    T.eq(fills[R.HL.del_bg], 1)
    T.eq(fills[R.HL.add_bg], 1)
    T.eq(vim.tbl_count(r.fills), 2, 'context rows must not be banded')
  end)

  T.it('highlights only the part of the line that actually changed', function()
    local diff = joined(
      'diff --git a/f.txt b/f.txt', '--- a/f.txt', '+++ b/f.txt',
      '@@ -1 +1 @@',
      '-local bbb = "old value"',
      '+local bbb = "new value"'
    )
    local r = R.render(diff, { width = 60 })
    local del = marks_of(r, R.HL.del_word)
    local add = marks_of(r, R.HL.add_word)
    T.eq(#del, 1)
    T.eq(#add, 1)
    local row, s, e = del[1][1], del[1][2], del[1][3]
    T.eq(r.lines[row + 1]:sub(s + 1, e), 'old')
    row, s, e = add[1][1], add[1][2], add[1][3]
    T.eq(r.lines[row + 1]:sub(s + 1, e), 'new')
  end)

  T.it('shows the hunk header with its section text', function()
    local diff = joined(
      'diff --git a/f.txt b/f.txt', '--- a/f.txt', '+++ b/f.txt',
      '@@ -5,2 +5,2 @@ func main() {', '-a', '+b'
    )
    local r = R.render(diff, { width = 60 })
    local _, head = line_with(r, '@@')
    T.eq(head, '@@ -5,2 +5,2 @@ func main() {')
    T.eq(#marks_of(r, R.HL.section), 1)
  end)

  T.it('renders a binary file as a header plus its message, with no gutter', function()
    local r = R.render(joined(
      'diff --git a/i.png b/i.png',
      'Binary files a/i.png and b/i.png differ'
    ), { width = 60 })
    T.contains(table.concat(r.lines, '\n'), '[バイナリ]')
    T.contains(table.concat(r.lines, '\n'), 'Binary files')
  end)

  T.it('keeps the commit header of git show above the diff', function()
    local r = R.render(joined(
      'commit deadbeef', 'Author: a <a@b>', '', '    subject', '',
      'diff --git a/f.txt b/f.txt', '--- a/f.txt', '+++ b/f.txt',
      '@@ -1 +1 @@', '-a', '+b'
    ), { width = 60 })
    T.eq(r.lines[1], 'commit deadbeef')
    T.eq(#marks_of(r, R.HL.commit), 1)
  end)

  T.it('shows the "no newline at end of file" note without a gutter', function()
    local r = R.render(joined(
      'diff --git a/f.txt b/f.txt', '--- a/f.txt', '+++ b/f.txt',
      '@@ -1 +1 @@', '-a', '\\ No newline at end of file', '+b'
    ), { width = 60 })
    local _, note = line_with(r, 'No newline')
    T.eq(note, '  \\ No newline at end of file')
  end)

  T.it('renders a combined (merge) diff without losing the two-column markers', function()
    local r = R.render(joined(
      'diff --cc f.txt',
      '--- a/f.txt',
      '+++ b/f.txt',
      '@@@ -1,2 -1,2 +1,2 @@@',
      '  same',
      '- ours',
      ' +theirs'
    ), { width = 60 })
    local body = table.concat(r.lines, '\n')
    T.contains(body, '-ours')
    T.contains(body, '+theirs')
    T.contains(body, ' same')
  end)

  T.it('produces nothing at all for empty input', function()
    local r = R.render('', { width = 60 })
    T.eq(#r.lines, 0)
  end)
end)

T.describe('panel diff render: wrapping', function()
  T.it('wraps a long line instead of letting it run past the pane', function()
    local long = string.rep('abcdefghij', 12)
    local r = R.render(joined(
      'diff --git a/f.txt b/f.txt', '--- a/f.txt', '+++ b/f.txt',
      '@@ -1 +1 @@', '-x', '+' .. long
    ), { width = 40 })
    for i, l in ipairs(r.lines) do
      T.ok(vim.api.nvim_strwidth(l) <= 40, 'line ' .. i .. ' is wider than the pane: ' .. l)
    end
    local body = table.concat(r.lines, '')
    T.contains(body, 'abcdefghij', 'the wrapped text should still be present')
  end)

  T.it('bands every row of a wrapped change, not just the first', function()
    local long = string.rep('abcdefghij', 12)
    local r = R.render(joined(
      'diff --git a/f.txt b/f.txt', '--- a/f.txt', '+++ b/f.txt',
      '@@ -1 +1 @@', '-x', '+' .. long
    ), { width = 40 })
    local add_rows = 0
    for _, g in pairs(r.fills) do
      if g == R.HL.add_bg then add_rows = add_rows + 1 end
    end
    T.ok(add_rows > 1, 'a wrapped added line should stay banded across its rows')
  end)

  T.it('cuts off with … once the wrap limit is reached', function()
    local long = string.rep('abcdefghij', 60)
    local r = R.render(joined(
      'diff --git a/f.txt b/f.txt', '--- a/f.txt', '+++ b/f.txt',
      '@@ -1 +1 @@', '-x', '+' .. long
    ), { width = 40, wrap_max = 2 })
    T.contains(table.concat(r.lines, '\n'), '…')
  end)

  T.it('never splits a multibyte character across two rows', function()
    local long = string.rep('日本語', 40)
    local r = R.render(joined(
      'diff --git a/f.txt b/f.txt', '--- a/f.txt', '+++ b/f.txt',
      '@@ -1 +1 @@', '-x', '+' .. long
    ), { width = 30, wrap_max = 10 })
    for _, l in ipairs(r.lines) do
      T.ok(vim.fn.strchars(l) >= 0 and l == vim.fn.strcharpart(l, 0), 'row must stay valid utf-8: ' .. l)
      T.ok(vim.api.nvim_strwidth(l) <= 30, 'row must fit the pane: ' .. l)
    end
  end)
end)

T.describe('panel diff render: side-by-side', function()
  T.it('places the removed line on the left and the added line on the right of one row', function()
    local r = R.render(SIMPLE, { width = 60, side_by_side = true })
    local _, row = line_with(r, '-before')
    T.contains(row, '-before')
    T.contains(row, '+after')
  end)

  T.it('pads both columns so every row fills the pane exactly', function()
    local r = R.render(SIMPLE, { width = 61, side_by_side = true })
    local _, row = line_with(r, '-before')
    T.eq(vim.api.nvim_strwidth(row), 61)
  end)

  T.it('bands the two columns separately, so one row can be both removed and added', function()
    local r = R.render(SIMPLE, { width = 60, side_by_side = true })
    local row = select(1, line_with(r, '-before')) - 1
    local seen = {}
    for _, m in ipairs(r.marks) do
      if m[1] == row then seen[m[4]] = true end
    end
    T.ok(seen[R.HL.del_bg], 'the left half should carry the removed band')
    T.ok(seen[R.HL.add_bg], 'the right half should carry the added band')
    T.eq(vim.tbl_count(r.fills), 0, 'side-by-side must not band whole rows')
  end)

  T.it('shows a context line on both sides', function()
    local r = R.render(SIMPLE, { width = 60, side_by_side = true })
    local _, row = line_with(r, 'keep')
    local _, count = row:gsub('keep', '')
    T.eq(count, 2)
  end)
end)

T.describe('panel diff render: syntax', function()
  T.it('colors the code with treesitter, using the same groups as the editor', function()
    local r = R.render(joined(
      'diff --git a/f.lua b/f.lua', '--- a/f.lua', '+++ b/f.lua',
      '@@ -1,2 +1,2 @@',
      ' local kept = 1',
      '-local removed = 2',
      '+local added = 3'
    ), { width = 60 })
    local keywords = marks_of(r, '@keyword.lua')
    T.eq(#keywords, 3, 'every code row (context/removed/added) should get its keyword colored')
    for _, m in ipairs(keywords) do
      T.eq(r.lines[m[1] + 1]:sub(m[2] + 1, m[3]), 'local')
    end
  end)

  T.it('leaves the code plain when the file has no parser', function()
    local r = R.render(joined(
      'diff --git a/f.unknownext b/f.unknownext', '--- a/f.unknownext', '+++ b/f.unknownext',
      '@@ -1 +1 @@', '-a', '+b'
    ), { width = 60 })
    for _, m in ipairs(r.marks) do
      T.ok(not tostring(m[4]):match('^@'), 'no treesitter group should be applied, got ' .. tostring(m[4]))
    end
  end)

  T.it('can be turned off', function()
    local r = R.render(joined(
      'diff --git a/f.lua b/f.lua', '--- a/f.lua', '+++ b/f.lua',
      '@@ -1 +1 @@', '-local a = 1', '+local a = 2'
    ), { width = 60, syntax = false })
    T.eq(#marks_of(r, '@keyword.lua'), 0)
  end)
end)

T.describe('panel diff render: concat', function()
  T.it('stacks several renders and reports where each one starts', function()
    local a = R.render(SIMPLE, { width = 40 })
    local b = R.render(SIMPLE, { width = 40 })
    local merged, offsets = R.concat({ a, b })
    T.eq(offsets[1], 1)
    T.eq(offsets[2], #a.lines + 2, 'the second render starts after one blank separator line')
    T.eq(#merged.lines, #a.lines + 1 + #b.lines)
    T.eq(#merged.marks, #a.marks + #b.marks)
  end)

  T.it('shifts marks and bands of later renders by the offset', function()
    local a = R.render(SIMPLE, { width = 40 })
    local merged = R.concat({ a, a })
    local last_a = a.marks[#a.marks]
    local last_m = merged.marks[#merged.marks]
    T.eq(last_m[1], last_a[1] + #a.lines + 1)
    T.eq(vim.tbl_count(merged.fills), vim.tbl_count(a.fills) * 2)
  end)
end)

T.describe('panel diff render: apply', function()
  T.it('writes the lines and highlights into a buffer, leaving it read-only', function()
    local r = R.render(SIMPLE, { width = 60 })
    local buf = vim.api.nvim_create_buf(false, true)
    local ns = vim.api.nvim_create_namespace('diff_render_spec')
    D.setup_hl()
    D.apply(buf, ns, r)

    T.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1], r.lines[1])
    T.eq(vim.bo[buf].modifiable, false)
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    T.ok(#marks > 0, 'highlights should land as extmarks')

    local banded = false
    for _, m in ipairs(marks) do
      if m[4].line_hl_group then banded = true end
    end
    T.ok(banded, 'the changed rows should be banded with line_hl_group')
  end)

  T.it('replaces the previous content instead of appending to it', function()
    local buf = vim.api.nvim_create_buf(false, true)
    local ns = vim.api.nvim_create_namespace('diff_render_spec2')
    D.apply(buf, ns, R.render(SIMPLE, { width = 60 }))
    local first = vim.api.nvim_buf_line_count(buf)
    D.apply(buf, ns, R.render(SIMPLE, { width = 60 }))
    T.eq(vim.api.nvim_buf_line_count(buf), first)
  end)
end)

T.summary()
