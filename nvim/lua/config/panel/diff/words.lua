-- 行内（単語単位）の差分。1行のうち実際に変わった部分だけを強調するために使う。
--
-- やることは2段階:
--   1. hunk 内で連続する削除行の並びと追加行の並びを対応付ける（align）
--   2. 対応した1組の行をトークン列に割ってLCSを取り、一致しなかった範囲を返す（pair_diff）
--
-- 似ていない行同士を対応付けると行全体が塗られて逆に読みにくいので、
-- 類似度が MIN_SIM 未満の組は対応なしとして扱う。

local M = {}

--- 対応付けを許す類似度の下限
M.MIN_SIM = 0.4
--- LCS の DP を打ち切るトークン数の積。超えたら「中央は丸ごと変更」として扱う
local LCS_LIMIT = 40000
--- align で総当たりの類似度計算を許す行数の積。超えたら添字順の素朴な対応にする
local ALIGN_LIMIT = 400

local function is_word_byte(b)
  return (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95
end

local function is_space_byte(b)
  return b == 32 or b == 9
end

--- 行をトークンへ割る。英数字_の連なり／空白の連なり／その他は1文字ずつ。
--- 非ASCIIは1文字を1トークンにする（日本語などは語に割れないため）。
---@param s string
---@return string[] toks, integer[] starts, integer[] ends  starts/endsは0始まり半開区間
function M.tokenize(s)
  local toks, starts, ends = {}, {}, {}
  local i, n = 1, #s
  while i <= n do
    local b = s:byte(i)
    local j = i
    if b >= 0x80 then
      local len = (b >= 0xf0 and 4) or (b >= 0xe0 and 3) or (b >= 0xc0 and 2) or 1
      j = math.min(i + len - 1, n)
    elseif is_word_byte(b) then
      while j < n and s:byte(j + 1) < 0x80 and is_word_byte(s:byte(j + 1)) do j = j + 1 end
    elseif is_space_byte(b) then
      while j < n and is_space_byte(s:byte(j + 1)) do j = j + 1 end
    end
    toks[#toks + 1] = s:sub(i, j)
    starts[#starts + 1] = i - 1
    ends[#ends + 1] = j
    i = j + 1
  end
  return toks, starts, ends
end

--- 2つのトークン列のLCSを取り、各要素が一致に使われたかの真偽表を返す
---@return boolean[] ma, boolean[] mb, integer lcs_len
local function lcs_match(a, b, a_from, a_to, b_from, b_to)
  local na, nb = a_to - a_from + 1, b_to - b_from + 1
  local ma, mb = {}, {}
  if na <= 0 or nb <= 0 then return ma, mb, 0 end
  if na * nb > LCS_LIMIT then return ma, mb, 0 end

  -- dp は (na+1) x (nb+1) の表を1本の配列に畳んだもの。
  -- 末尾の番兵行ぶんまで0で埋めておく（i=na の行から dp[(i+1)*w + j] を読むため）
  local w = nb + 1
  local dp = {}
  for k = 0, (na + 2) * w - 1 do dp[k] = 0 end
  for i = na, 1, -1 do
    local ai = a[a_from + i - 1]
    local row, next_row = i * w, (i + 1) * w
    for j = nb, 1, -1 do
      if ai == b[b_from + j - 1] then
        dp[row + j - 1] = dp[next_row + j] + 1
      else
        local d, r = dp[next_row + j - 1], dp[row + j]
        dp[row + j - 1] = (d > r) and d or r
      end
    end
  end

  local i, j, len = 1, 1, 0
  while i <= na and j <= nb do
    if a[a_from + i - 1] == b[b_from + j - 1] then
      ma[a_from + i - 1] = true
      mb[b_from + j - 1] = true
      len = len + 1
      i, j = i + 1, j + 1
    elseif dp[(i + 1) * w + j - 1] >= dp[i * w + j] then
      i = i + 1
    else
      j = j + 1
    end
  end
  return ma, mb, len
end

--- 一致しなかったトークンをバイト範囲の並びへまとめる。
--- 変更の間に挟まった空白だけのトークンは繋げて、細切れの塗りが並ばないようにする
local function ranges_of(toks, starts, ends, matched)
  local out = {}
  local i, n = 1, #toks
  while i <= n do
    if not matched[i] then
      local s, e = starts[i], ends[i]
      local j = i + 1
      while j <= n do
        if not matched[j] then
          e = ends[j]
          j = j + 1
        elseif toks[j]:match('^[ \t]+$') and j < n and not matched[j + 1] then
          j = j + 1
        else
          break
        end
      end
      out[#out + 1] = { s, e }
      i = j
    else
      i = i + 1
    end
  end
  return out
end

--- 削除行1本と追加行1本を突き合わせ、変わった範囲（0始まり半開のバイト区間）と類似度を返す
---@param a string 削除行の本文
---@param b string 追加行の本文
---@return table a_ranges, table b_ranges, number sim
function M.pair_diff(a, b)
  if a == b then return {}, {}, 1 end
  local at, as, ae = M.tokenize(a)
  local bt, bs, be = M.tokenize(b)
  if #at == 0 then return {}, (#bt > 0 and { { 0, #b } } or {}), 0 end
  if #bt == 0 then return { { 0, #a } }, {}, 0 end

  -- 前後の共通部分を先に削っておく（LCSの対象を実際に変わったあたりだけに絞る）
  local head = 0
  while head < #at and head < #bt and at[head + 1] == bt[head + 1] do head = head + 1 end
  local tail = 0
  while tail < (#at - head) and tail < (#bt - head) and at[#at - tail] == bt[#bt - tail] do tail = tail + 1 end

  local ma, mb, len = lcs_match(at, bt, head + 1, #at - tail, head + 1, #bt - tail)
  for i = 1, head do ma[i] = true; mb[i] = true end
  for i = 0, tail - 1 do ma[#at - i] = true; mb[#bt - i] = true end

  local common = head + tail + len
  local sim = (2 * common) / (#at + #bt)
  return ranges_of(at, as, ae, ma), ranges_of(bt, bs, be, mb), sim
end

--- 削除行の並びと追加行の並びを、順序を保ったまま対応付ける。
--- 戻り値: { { di, ai, sim }, ... }（di/ai は dels/adds の添字）
---@param dels string[]
---@param adds string[]
---@return table
function M.align(dels, adds)
  local nd, na = #dels, #adds
  if nd == 0 or na == 0 then return {} end

  -- 行数が同じなら上から順に対応させる（実際の編集ではこれがほとんど）。
  -- 総当たりが重すぎる場合も同じ扱いにする
  if nd == na or nd * na > ALIGN_LIMIT then
    local pairs_out = {}
    for i = 1, math.min(nd, na) do
      local _, _, sim = M.pair_diff(dels[i], adds[i])
      if sim >= M.MIN_SIM then pairs_out[#pairs_out + 1] = { i, i, sim } end
    end
    return pairs_out
  end

  local sim = {}
  for i = 1, nd do
    sim[i] = {}
    for j = 1, na do
      local _, _, s = M.pair_diff(dels[i], adds[j])
      sim[i][j] = (s >= M.MIN_SIM) and s or nil
    end
  end

  -- 交差しない対応の中で、類似度の合計が最大になる組み合わせを取る
  local dp = {}
  for i = 0, nd do
    dp[i] = {}
    for j = 0, na do dp[i][j] = 0 end
  end
  for i = 1, nd do
    for j = 1, na do
      local best = math.max(dp[i - 1][j], dp[i][j - 1])
      local s = sim[i][j]
      if s and dp[i - 1][j - 1] + s > best then best = dp[i - 1][j - 1] + s end
      dp[i][j] = best
    end
  end

  local out = {}
  local i, j = nd, na
  while i > 0 and j > 0 do
    local s = sim[i][j]
    if s and dp[i][j] == dp[i - 1][j - 1] + s then
      table.insert(out, 1, { i, j, s })
      i, j = i - 1, j - 1
    elseif dp[i - 1][j] >= dp[i][j - 1] then
      i = i - 1
    else
      j = j - 1
    end
  end
  return out
end

return M
