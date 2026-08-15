-- config/panel/diff/words.lua（行内＝単語単位の差分）の単体テスト。
-- 「変わった部分だけが強調される」ことと、「似ていない行同士は対応付けない」ことが要。

local T = dofile(TESTS_DIR .. '/helpers.lua')
local W = require('config.panel.diff.words')

--- 範囲リストを "s-e,s-e" の文字列にして比較しやすくする
local function fmt(ranges)
  local out = {}
  for _, r in ipairs(ranges) do table.insert(out, r[1] .. '-' .. r[2]) end
  return table.concat(out, ',')
end

--- ranges が指す部分文字列
local function cut(s, ranges)
  local out = {}
  for _, r in ipairs(ranges) do table.insert(out, s:sub(r[1] + 1, r[2])) end
  return table.concat(out, '|')
end

T.describe('panel diff words: tokenize', function()
  T.it('splits into word runs, whitespace runs and single symbols', function()
    local toks = W.tokenize('a_b1 = foo(1)')
    T.eq(table.concat(toks, '/'), 'a_b1/ /=/ /foo/(/1/)')
  end)

  T.it('treats each multibyte character as its own token', function()
    local toks = W.tokenize('あiう')
    T.eq(table.concat(toks, '/'), 'あ/i/う')
  end)

  T.it('reports byte offsets that slice back to the token', function()
    local s = 'let x = 1'
    local toks, starts, ends = W.tokenize(s)
    T.eq(toks[1], 'let')
    T.eq(s:sub(starts[1] + 1, ends[1]), 'let')
    T.eq(s:sub(starts[#toks] + 1, ends[#toks]), '1')
  end)
end)

T.describe('panel diff words: pair_diff', function()
  T.it('marks only the token that changed, not the whole line', function()
    local a = 'local bbb = "old value"'
    local b = 'local bbb = "new value"'
    local ar, br, sim = W.pair_diff(a, b)
    T.eq(cut(a, ar), 'old')
    T.eq(cut(b, br), 'new')
    T.ok(sim > 0.8, 'one changed word out of many should stay highly similar')
  end)

  T.it('joins changes that are only separated by whitespace', function()
    local a = 'foo bar baz'
    local b = 'FOO BAR baz'
    local ar = W.pair_diff(a, b)
    T.eq(fmt(ar), '0-7', 'foo bar should become a single range, not two')
  end)

  T.it('returns no ranges for identical lines', function()
    local ar, br, sim = W.pair_diff('same', 'same')
    T.eq(#ar, 0)
    T.eq(#br, 0)
    T.eq(sim, 1)
  end)

  T.it('covers the whole line when one side is empty', function()
    local ar, br, sim = W.pair_diff('', 'added')
    T.eq(#ar, 0)
    T.eq(fmt(br), '0-5')
    T.eq(sim, 0)
  end)

  T.it('reports a low similarity for two unrelated lines', function()
    local _, _, sim = W.pair_diff('return nil', 'vim.api.nvim_set_hl(0, name, opts)')
    T.ok(sim < W.MIN_SIM, 'unrelated lines must fall below the pairing threshold, got ' .. sim)
  end)

  T.it('handles multibyte text without cutting a character in half', function()
    -- 日本語は語に割れないので文字単位で最小の差分になる（「い」以降は共通）
    local a = 'これは古い行です'
    local b = 'これは新しい行です'
    local ar, br = W.pair_diff(a, b)
    T.eq(cut(a, ar), '古')
    T.eq(cut(b, br), '新し')
  end)
end)

T.describe('panel diff words: align', function()
  T.it('pairs equal-length blocks by position', function()
    local pairs_out = W.align({ 'aaa 1', 'bbb 2' }, { 'aaa 9', 'bbb 8' })
    T.eq(#pairs_out, 2)
    T.eq(pairs_out[1][1] .. '->' .. pairs_out[1][2], '1->1')
    T.eq(pairs_out[2][1] .. '->' .. pairs_out[2][2], '2->2')
  end)

  T.it('drops pairs that are not similar enough to highlight', function()
    local pairs_out = W.align({ 'completely different content here' }, { 'x' })
    T.eq(#pairs_out, 0)
  end)

  T.it('finds the matching line when the blocks have different lengths', function()
    local dels = { 'local value = 1' }
    local adds = { 'local other = 99', 'local value = 2' }
    local pairs_out = W.align(dels, adds)
    T.eq(#pairs_out, 1)
    T.eq(pairs_out[1][2], 2, 'the del line should pair with the similar add line, not the first one')
  end)

  T.it('returns nothing when either side is empty', function()
    T.eq(#W.align({}, { 'a' }), 0)
    T.eq(#W.align({ 'a' }, {}), 0)
  end)
end)

T.summary()
