-- 生の unified diff（git diff / git show / git diff --no-index の出力）を構造化する。
-- ここは「何が書かれているか」だけを扱い、色・桁・折り返しといった見た目は render.lua が持つ。
--
-- 扱う入力:
--   ・git show のようにコミットヘッダが先頭に付くもの（最初の diff --git より前は preamble）
--   ・new file / deleted file / rename / mode 変更 / バイナリ
--   ・マージ中の複合 diff（diff --cc、@@@ -a,b -c,d +e,f @@@）
--
-- タブは読み込み時に幅4の空白へ展開する。ここで潰しておかないと、
-- 行番号ガターを左に足したぶんだけタブ位置がずれて桁が合わなくなる。

local M = {}

M.TABSTOP = 4

--- タブを TABSTOP 単位の空白へ展開する。
--- タブ位置の計算はバイト数で近似する（マルチバイト文字とタブが同じ行に混在すると
--- 1桁ぶんずれうるが、diff 本文でその組み合わせはまれで、実害が桁の見た目だけのため）
---@param s string
---@return string
function M.expand_tabs(s)
  if not s:find('\t', 1, true) then return s end
  local out, col = {}, 0
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == '\t' then
      local n = M.TABSTOP - (col % M.TABSTOP)
      out[#out + 1] = string.rep(' ', n)
      col = col + n
    else
      out[#out + 1] = c
      col = col + 1
    end
  end
  return table.concat(out)
end

--- "a/foo.lua" → "foo.lua" / "/dev/null" → nil
--- git は特殊文字を含むパスを "..." で括って出すので、その場合は引用を外す
---@param p string|nil
---@return string|nil
local function clean_path(p)
  if not p then return nil end
  p = p:gsub('\t.*$', ''):gsub('%s+$', '')
  if p:sub(1, 1) == '"' and p:sub(-1) == '"' and #p >= 2 then
    p = p:sub(2, -2)
    p = p:gsub('\\(.)', '%1')
  end
  if p == '/dev/null' then return nil end
  p = p:gsub('^[ab]/', '')
  if p == '' then return nil end
  return p
end

local function new_file(headline)
  return {
    headline = headline,
    old_path = nil,
    new_path = nil,
    path = nil,
    status = 'M', -- M(変更) / A(追加) / D(削除) / R(リネーム)
    binary = false,
    binary_message = nil,
    combined = false,
    parents = 1,
    hunks = {},
    added = 0,
    deleted = 0,
  }
end

--- @@ 行を読む。戻り値: hunk|nil
local function parse_hunk_header(l)
  local os_, oc, ns_, nc, section = l:match('^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@ ?(.*)$')
  if os_ then
    return {
      old_start = tonumber(os_), old_count = tonumber(oc) or 1,
      new_start = tonumber(ns_), new_count = tonumber(nc) or 1,
      section = section, header = l, lines = {},
    }
  end
  -- 複合 diff（diff --cc）。親が2つ以上ぶん "-a,b" が並び、最後が "+c,d"
  local at = l:match('^(@@+) ')
  if at and #at >= 3 then
    local nums = {}
    for sign, start, count in l:gmatch('([-+])(%d+),?(%d*)') do
      nums[#nums + 1] = { sign = sign, start = tonumber(start), count = tonumber(count) or 1 }
    end
    local last = nums[#nums]
    if not last then return nil end
    local first = nums[1]
    return {
      old_start = first.start, old_count = first.count,
      new_start = last.start, new_count = last.count,
      section = l:match('@@+ [^@]*@@+ ?(.*)$') or '',
      header = l, lines = {}, combined = true, parents = #at - 1,
    }
  end
  return nil
end

--- 本文1行を分類する。戻り値: kind('ctx'|'add'|'del'|'nonl'), content
local function classify(l, parents)
  if l:sub(1, 1) == '\\' then return 'nonl', l end
  if parents <= 1 then
    local c = l:sub(1, 1)
    if c == '+' then return 'add', l:sub(2) end
    if c == '-' then return 'del', l:sub(2) end
    if c == ' ' then return 'ctx', l:sub(2) end
    if l == '' then return 'ctx', '' end -- 末尾の空行を ' ' 無しで出すツール向け
    return nil, nil
  end
  -- 複合 diff は先頭 parents 文字ぶんが記号
  local sig = l:sub(1, parents)
  if not sig:match('^[-+ ]+$') then return nil, nil end
  local content = l:sub(parents + 1)
  if sig:find('+', 1, true) then return 'add', content end
  if sig:find('-', 1, true) then return 'del', content end
  return 'ctx', content
end

--- 生 diff を構造化する。
--- 戻り値: { preamble = {行...}, files = { file, ... } }
---   file  = { path, old_path, new_path, status, binary, hunks, added, deleted, ... }
---   hunk  = { old_start, new_start, section, header, lines = { line, ... } }
---   line  = { kind, text, old_no, new_no }
---@param text string|nil
---@return table
function M.parse(text)
  local lines = vim.split(text or '', '\n', { plain = true })
  -- 末尾の余分な空行は「diff の一部」ではないので落とす（描画で余白が増えるだけ）
  while #lines > 0 and lines[#lines] == '' do table.remove(lines) end

  local out = { preamble = {}, files = {} }
  local file, hunk = nil, nil
  local old_no, new_no = 0, 0

  local function start_hunk(h)
    hunk = h
    file.combined = h.combined or false
    file.parents = h.parents or 1
    old_no, new_no = h.old_start, h.new_start
    table.insert(file.hunks, h)
  end

  for _, l in ipairs(lines) do
    local is_head = l:match('^diff %-%-git ') or l:match('^diff %-%-cc ') or l:match('^diff %-%-combined ')
    local kind, content
    if file and hunk and not is_head then kind, content = classify(l, file.parents) end

    if is_head then
      file = new_file(l)
      hunk = nil
      -- --- / +++ が無い形（リネームのみ等）でもパスが分かるように見出しから拾っておく
      file.fallback_path = clean_path(l:match(' b/(.+)$'))
        or clean_path(l:match('^diff %-%-cc (.+)$'))
        or clean_path(l:match('^diff %-%-combined (.+)$'))
      table.insert(out.files, file)
    elseif not file then
      table.insert(out.preamble, l)
    elseif kind then
      local rec = { kind = kind, text = M.expand_tabs(content) }
      if kind == 'ctx' then
        rec.old_no, rec.new_no = old_no, new_no
        old_no, new_no = old_no + 1, new_no + 1
      elseif kind == 'del' then
        rec.old_no = old_no
        old_no = old_no + 1
        file.deleted = file.deleted + 1
      elseif kind == 'add' then
        rec.new_no = new_no
        new_no = new_no + 1
        file.added = file.added + 1
      end
      table.insert(hunk.lines, rec)
    else
      local h = parse_hunk_header(l)
      if h then
        start_hunk(h)
      elseif l:match('^new file mode ') then
        file.status = 'A'
      elseif l:match('^deleted file mode ') then
        file.status = 'D'
      elseif l:match('^rename from ') then
        file.status = 'R'
        file.old_path = clean_path(l:sub(#'rename from ' + 1))
      elseif l:match('^rename to ') then
        file.status = 'R'
        file.new_path = clean_path(l:sub(#'rename to ' + 1))
      elseif l:match('^Binary files ') or l:match('^GIT binary patch') then
        file.binary = true
        file.binary_message = l
      elseif l:match('^%-%-%- ') then
        file.old_path = clean_path(l:sub(5))
        if not file.old_path and file.status == 'M' then file.status = 'A' end
      elseif l:match('^%+%+%+ ') then
        file.new_path = clean_path(l:sub(5))
        if not file.new_path and file.status == 'M' then file.status = 'D' end
      end
      -- index / mode / similarity 行は表示しないので捨てる
    end
  end

  for _, f in ipairs(out.files) do
    f.path = f.new_path or f.old_path or f.fallback_path or '(unknown)'
  end
  return out
end

return M
