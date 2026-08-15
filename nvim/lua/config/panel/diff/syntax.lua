-- diff 本文へのシンタックスハイライト。treesitter を使い、エディタ本体と全く同じクエリ・
-- 同じハイライトグループを通るので、diff の中のコードがファイルを開いた時と同じ色になる。
--
-- 対象にするのは hunk の中身だけなので、渡すソースはファイル全体ではなく
-- 「hunk の本文を上から繋いだ断片」になる。構文的には途中で切れた不完全なコードだが、
-- treesitter は誤りを含む木でも部分的に正しい構文木を返すので、行単位の色付けには足りる。

local M = {}

--- これより行数が多い差分ではハイライトを諦める（パース待ちでパネルが固まるのを防ぐ）
M.MAX_LINES = 4000
--- 断片ごとの結果を持っておくキャッシュ。幅を変えても内容が同じなら再パースしない
local cache = {}
local cache_keys = {}
local MAX_CACHE = 64

local function cache_get(key)
  return cache[key]
end

local function cache_put(key, value)
  if cache[key] == nil then
    table.insert(cache_keys, key)
    if #cache_keys > MAX_CACHE then
      local old = table.remove(cache_keys, 1)
      cache[old] = nil
    end
  end
  cache[key] = value
end

--- パスから treesitter の言語名を求める。判定できなければ nil
---@param path string|nil
---@return string|nil
function M.lang_for_path(path)
  if not path or path == '' then return nil end
  local ok, ft = pcall(vim.filetype.match, { filename = path })
  if not ok or not ft or ft == '' then return nil end
  local lang = require('config.treesitter').lang_for(ft)
  if not lang then return nil end
  -- パーサが無い言語（未ビルド・対象外）はここで諦める
  if not pcall(vim.treesitter.language.add, lang) then return nil end
  return lang
end

--- キャプチャ名 → ハイライトグループ。コアの treesitter ハイライタと同じ命名で、
--- `@keyword.lua` のように言語名を足したグループを引く（未定義なら `@keyword` に落ちる）
local function group_for(capture, lang)
  return '@' .. capture .. '.' .. lang
end

--- ソース断片を treesitter で色分けし、行ごとのハイライト範囲を返す。
--- 戻り値: { [行番号(1始まり)] = { { 開始バイト, 終了バイト, グループ }, ... } }
--- 範囲は0始まり半開区間。パーサやクエリが無ければ空テーブル
---@param text string
---@param lang string|nil
---@return table
function M.spans(text, lang)
  if not lang or text == '' then return {} end
  local key = lang .. '\0' .. text
  local hit = cache_get(key)
  if hit then return hit end

  local result = {}
  local ok = pcall(function()
    local query = vim.treesitter.query.get(lang, 'highlights')
    if not query then return end
    local parser = vim.treesitter.get_string_parser(text, lang)
    local tree = parser:parse()[1]
    if not tree then return end
    for id, node in query:iter_captures(tree:root(), text) do
      local group = group_for(query.captures[id], lang)
      local sr, sc, er, ec = node:range()
      -- 複数行にまたがるノード（コメント・文字列）は行ごとに切り分ける
      for row = sr, er do
        local list = result[row + 1]
        if not list then
          list = {}
          result[row + 1] = list
        end
        local s = (row == sr) and sc or 0
        local e = (row == er) and ec or -1
        list[#list + 1] = { s, e, group }
      end
    end
  end)
  if not ok then result = {} end

  cache_put(key, result)
  return result
end

--- parse.lua が返した1ファイルぶんの hunk 群にシンタックスハイライトを付ける。
--- 各 line に `.spans`（本文に対する 0始まり半開のバイト範囲＋グループ）を生やす。
--- 削除行は変更前の内容、追加行と文脈行は変更後の内容として色を決める
---@param file table parse.lua の file
function M.annotate(file)
  if file.binary then return end
  local lang = M.lang_for_path(file.path)
  if not lang then return end

  local old_lines, new_lines = {}, {}
  local total = 0
  for _, hunk in ipairs(file.hunks) do
    for _, line in ipairs(hunk.lines) do
      if line.kind == 'ctx' then
        old_lines[#old_lines + 1] = line.text
        new_lines[#new_lines + 1] = line.text
        line.syn_row, line.syn_side = #new_lines, 'new'
      elseif line.kind == 'del' then
        old_lines[#old_lines + 1] = line.text
        line.syn_row, line.syn_side = #old_lines, 'old'
      elseif line.kind == 'add' then
        new_lines[#new_lines + 1] = line.text
        line.syn_row, line.syn_side = #new_lines, 'new'
      end
      total = total + 1
      if total > M.MAX_LINES then return end
    end
  end

  local old_spans = M.spans(table.concat(old_lines, '\n'), lang)
  local new_spans = M.spans(table.concat(new_lines, '\n'), lang)
  for _, hunk in ipairs(file.hunks) do
    for _, line in ipairs(hunk.lines) do
      if line.syn_row then
        local src = (line.syn_side == 'old') and old_spans or new_spans
        local spans = src[line.syn_row]
        if spans then
          -- 行末までのキャプチャ(-1)は実際の長さへ直しておく（描画側で切り出すため）
          local fixed = {}
          for _, sp in ipairs(spans) do
            local e = (sp[2] < 0) and #line.text or sp[2]
            if e > sp[1] then fixed[#fixed + 1] = { sp[1], e, sp[3] } end
          end
          line.spans = fixed
        end
      end
    end
  end
end

return M
