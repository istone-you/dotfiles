-- 差分レビューのコメント置き場(揮発・nvim メモリ内のみ)。
--
-- 人間(ブラウザ)と AI(skill 経由の HTTP API)の双方向スレッドを扱う。
-- コメントは file + side('old'|'new') + line で差分上の1行に紐づく。
-- さらに view('uncommitted'|'committed')でどのビューの差分に対するコメントかを持つ(difit の
-- 「差分選択ごとに別のコメント集合」に相当)。uncommitted=作業ツリー vs HEAD、committed=デフォルト
-- ブランチとの merge-base 差分。アンカー(行内容の再解決)も各ビューのモデルに対して行う。
-- 返信は parent_id を持ち、対象行(と view)は親から継承する。
-- version はミューテーションごとに増え、/__version ポーリングでブラウザが再取得する。
--
-- 純粋なストアなので server / init から共有シングルトンとして使いつつ、テストは reset() で
-- 状態を初期化して隔離する。

local M = {}

local state = {
  items = {},   -- 追加順の配列
  by_id = {},
  seq = 0,
  version = 0,
}

function M.reset()
  state.items = {}
  state.by_id = {}
  state.seq = 0
  state.version = 0
end

function M.version()
  return state.version
end

local function bump()
  state.version = state.version + 1
end

-- コメントが属するビュー。'committed' 以外(未指定・旧名 'all' 含む)はすべて既定の 'uncommitted' に丸める。
local function normalize_view(v)
  return (v == 'committed') and 'committed' or 'uncommitted'
end

-- new_line / old_line の短縮指定を side+line に正規化する(hunk-review skill と同じ操作感)。
local function normalize_target(input)
  local side = input.side
  local line = input.line
  if side == nil and input.new_line ~= nil then
    side, line = 'new', input.new_line
  elseif side == nil and input.old_line ~= nil then
    side, line = 'old', input.old_line
  end
  if side ~= 'old' and side ~= 'new' then
    return nil, "side must be 'old' or 'new' (or pass new_line/old_line)"
  end
  line = tonumber(line)
  if not line or line < 1 or line ~= math.floor(line) then
    return nil, 'line must be a positive integer'
  end
  return { side = side, line = line }
end

--- トップレベルコメントを追加する。
--- input = { file, side|new_line|old_line, line, body, author }
--- 成功: comment を返す / 失敗: nil, err
function M.add(input)
  input = input or {}
  local file = input.file
  if type(file) ~= 'string' or file == '' then
    return nil, 'file is required'
  end
  local body = input.body
  if type(body) ~= 'string' or vim.trim(body) == '' then
    return nil, 'body is required'
  end
  local target, err = normalize_target(input)
  if not target then return nil, err end

  -- 範囲コメント(複数行選択)の終端行。省略可。あれば line 以上の整数。
  local line_end = input.line_end or input.new_line_end or input.old_line_end
  if line_end ~= nil then
    line_end = tonumber(line_end)
    if not line_end or line_end ~= math.floor(line_end) or line_end < target.line then
      return nil, 'line_end must be an integer >= line'
    end
  end

  state.seq = state.seq + 1
  local comment = {
    id = 'c' .. tostring(state.seq),
    file = file,
    view = normalize_view(input.view),
    side = target.side,
    line = target.line,
    line_end = line_end or vim.NIL,
    anchor = vim.NIL,   -- サーバが作成時に fingerprint を付ける(anchor.lua)
    outdated = false,   -- 差分更新で本文が見つからなくなると true
    body = body,
    author = (type(input.author) == 'string' and input.author ~= '') and input.author or 'human',
    created_at = os.time(),
    parent_id = vim.NIL,
  }
  state.items[#state.items + 1] = comment
  state.by_id[comment.id] = comment
  bump()
  return comment
end

--- 既存コメントへの返信。対象行(file/side/line)は親から継承する。
--- input = { parent_id, body, author }
function M.reply(input)
  input = input or {}
  local parent = state.by_id[input.parent_id]
  if not parent then
    return nil, 'parent comment not found: ' .. tostring(input.parent_id)
  end
  -- 返信への返信もフラットに親スレッドへぶら下げる(スレッドは1階層)。
  local root_id = (parent.parent_id ~= vim.NIL and parent.parent_id) or parent.id
  local root = state.by_id[root_id] or parent
  local body = input.body
  if type(body) ~= 'string' or vim.trim(body) == '' then
    return nil, 'body is required'
  end

  state.seq = state.seq + 1
  local comment = {
    id = 'c' .. tostring(state.seq),
    file = root.file,
    view = normalize_view(root.view),
    side = root.side,
    line = root.line,
    line_end = root.line_end,
    anchor = vim.NIL,   -- 返信は親スレッドに追従するので独自アンカーは持たない
    outdated = false,
    body = body,
    author = (type(input.author) == 'string' and input.author ~= '') and input.author or 'human',
    created_at = os.time(),
    parent_id = root.id,
  }
  state.items[#state.items + 1] = comment
  state.by_id[comment.id] = comment
  bump()
  return comment
end

local function matches(comment, filter)
  if not filter then return true end
  if filter.file and comment.file ~= filter.file then return false end
  if filter.author and comment.author ~= filter.author then return false end
  if filter.view and normalize_view(comment.view) ~= normalize_view(filter.view) then return false end
  return true
end

--- filter = { file, author, view } いずれも任意。追加順の配列を返す。
function M.list(filter)
  local out = {}
  for _, c in ipairs(state.items) do
    if matches(c, filter) then out[#out + 1] = c end
  end
  return out
end

function M.get(id)
  return state.by_id[id]
end

--- スレッド構造(トップレベル + replies)にまとめて返す。
function M.threads(filter)
  local roots, children = {}, {}
  for _, c in ipairs(state.items) do
    if c.parent_id == vim.NIL then
      if matches(c, filter) then
        local t = vim.tbl_extend('keep', { replies = {} }, c)
        roots[#roots + 1] = t
        children[c.id] = t.replies
      end
    end
  end
  for _, c in ipairs(state.items) do
    if c.parent_id ~= vim.NIL and children[c.parent_id] then
      table.insert(children[c.parent_id], c)
    end
  end
  return roots
end

--- コメントを1件削除する。トップレベルなら返信も一緒に消す。
function M.remove(id)
  local target = state.by_id[id]
  if not target then return false end
  local removing = { [id] = true }
  if target.parent_id == vim.NIL then
    for _, c in ipairs(state.items) do
      if c.parent_id == id then removing[c.id] = true end
    end
  end
  local kept = {}
  for _, c in ipairs(state.items) do
    if removing[c.id] then
      state.by_id[c.id] = nil
    else
      kept[#kept + 1] = c
    end
  end
  state.items = kept
  bump()
  return true
end

--- filter に合致するコメントを全消去(filter 省略で全件)。
function M.clear(filter)
  if not filter then
    state.items = {}
    state.by_id = {}
    bump()
    return
  end
  local kept = {}
  for _, c in ipairs(state.items) do
    if matches(c, filter) then
      state.by_id[c.id] = nil
    else
      kept[#kept + 1] = c
    end
  end
  state.items = kept
  bump()
end

M._private = {
  state = state,
  normalize_target = normalize_target,
  normalize_view = normalize_view,
}

return M
