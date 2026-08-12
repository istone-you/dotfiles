-- パス補完（VS Code の Path Intellisense 相当）。
-- カーソル直前がパス断片（./ ../ ~/ / や / を含む断片）のとき、
-- そのディレクトリ配下のファイル／フォルダを vim.fn.complete() で出す。
--
-- LSP 補完とは独立。パス文脈ならこちらを優先し、completion.lua 側は LSP を抑止する。

local M = {}

M.DEBOUNCE_MS = 80
M.SHOW_HIDDEN = false -- true にするとドットファイルも出す

local timer = nil

--- バッファの基準ディレクトリ（無名バッファは cwd）
---@param buf integer|nil
---@return string
function M.base_dir(buf)
  buf = buf or 0
  local name = vim.api.nvim_buf_get_name(buf)
  if name ~= '' then
    return vim.fn.fnamemodify(name, ':h')
  end
  return vim.fn.getcwd()
end

--- パス断片を絶対ディレクトリに解決する
---@param dir_part string 末尾スラッシュ付きでも可（空なら base）
---@param base string
---@return string|nil
function M.resolve_dir(dir_part, base)
  if dir_part == '' or dir_part == '.' then
    return vim.fn.fnamemodify(base, ':p')
  end
  local path = dir_part
  if path:sub(1, 1) ~= '/' and path:sub(1, 1) ~= '~' then
    path = base .. '/' .. path
  end
  -- `~` `./` `../` は vim.fs.normalize で先に畳んでおく。`/./` を含んだまま `:p` に
  -- 渡すと、実在パスのとき macOS では symlink まで解決され /var/... が
  -- /private/var/... になり、断片の書き方次第で返すパスが変わってしまう
  path = vim.fn.fnamemodify(vim.fs.normalize(path), ':p')
  if vim.fn.isdirectory(path) == 0 then return nil end
  return path
end

--- カーソル前テキスト末尾のパス断片を取り出す。
--- パスとみなす条件: `/` を含む、または `./` `../` `~/` `/` で始まる。
---@param before string
---@return string|nil fragment
---@return integer|nil start_byte 断片開始の1-based byte index
function M.path_fragment(before)
  -- 空白・引用符・一般的な区切りの直後から末尾までを候補にする
  local frag = before:match("([^%s'\"`=({[,]*)$")
  if not frag or frag == '' then return nil end

  local ok = frag:find('/', 1, true)
    or frag:match('^%./')
    or frag:match('^%.%./')
    or frag:match('^~/')
    or frag:match('^/')
  if not ok then return nil end
  -- `vim.` や `obj.method` のようなスラッシュ無しのメソッド連鎖は上の ok 判定
  -- （`/` を含む or `./ ../ ~/ /` 始まり）で既に弾かれている。

  local start_byte = #before - #frag + 1
  return frag, start_byte
end

--- パス文脈なら補完用の文脈を返す
---@param before string
---@param base string|nil
---@return { dir: string, prefix: string, start_col: integer, fragment: string }|nil
function M.parse(before, base)
  base = base or M.base_dir()
  local frag = M.path_fragment(before)
  if not frag then return nil end

  local dir_part, prefix
  if frag:sub(-1) == '/' then
    dir_part, prefix = frag, ''
  else
    dir_part = frag:match('^(.*)/') or ''
    prefix = frag:match('([^/]*)$') or ''
  end

  local abs = M.resolve_dir(dir_part, base)
  if not abs then return nil end

  return {
    dir = abs,
    prefix = prefix,
    start_col = #before - #prefix + 1,
    fragment = frag,
  }
end

function M.is_path_context(before)
  return M.parse(before) ~= nil
end

--- ディレクトリ一覧を補完アイテムにする
---@param dir string
---@param prefix string
---@param opts { show_hidden: boolean }|nil
---@return table[]
function M.list(dir, prefix, opts)
  opts = opts or {}
  local show_hidden = opts.show_hidden
  if show_hidden == nil then show_hidden = M.SHOW_HIDDEN end

  local entries = {}
  local ok, iter = pcall(vim.fs.dir, dir)
  if not ok or not iter then return entries end

  -- ドットを明示的に打っていれば隠しファイルも出す（VS Code の Path Intellisense と同じ）
  local reveal_hidden = show_hidden or prefix:sub(1, 1) == '.'

  for name, ftype in iter do
    if name ~= '.' and name ~= '..' then
      local hidden = name:sub(1, 1) == '.'
      if (reveal_hidden or not hidden)
        and (prefix == '' or vim.startswith(name, prefix) or vim.startswith(name:lower(), prefix:lower()))
      then
        local is_dir = ftype == 'directory'
        if ftype == 'link' then
          is_dir = vim.fn.isdirectory(dir .. '/' .. name) == 1
        end
        entries[#entries + 1] = {
          word = is_dir and (name .. '/') or name,
          abbr = name .. (is_dir and '/' or ''),
          menu = is_dir and '[dir]' or '[file]',
          kind = is_dir and 'Folder' or 'File',
        }
      end
    end
  end

  table.sort(entries, function(a, b)
    local ad = a.kind == 'Folder'
    local bd = b.kind == 'Folder'
    if ad ~= bd then return ad end
    return a.abbr:lower() < b.abbr:lower()
  end)
  return entries
end

--- パス補完を試みる。出したなら true
---@return boolean
function M.trigger()
  if vim.bo.buftype ~= '' then return false end
  if vim.fn.mode() ~= 'i' then return false end

  local col = vim.api.nvim_win_get_cursor(0)[2]
  local before = vim.api.nvim_get_current_line():sub(1, col)
  local ctx = M.parse(before, M.base_dir())
  if not ctx then return false end

  local items = M.list(ctx.dir, ctx.prefix)
  if #items == 0 then return false end

  vim.fn.complete(ctx.start_col, items)
  return true
end

function M.schedule_trigger()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  local uv = vim.uv or vim.loop
  local this = uv.new_timer()
  timer = this
  this:start(M.DEBOUNCE_MS, 0, vim.schedule_wrap(function()
    if timer == this then
      this:stop()
      this:close()
      timer = nil
    end
    if vim.fn.mode() ~= 'i' then return end
    if vim.bo.buftype ~= '' then return end
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local before = vim.api.nvim_get_current_line():sub(1, col)
    if not M.is_path_context(before) then return end
    M.trigger()
  end))
end

local function setup()
  vim.api.nvim_create_autocmd('TextChangedI', {
    group = vim.api.nvim_create_augroup('user_path_completion', { clear = true }),
    callback = function()
      if vim.bo.buftype ~= '' then return end
      M.schedule_trigger()
    end,
  })

  -- ディレクトリを確定したら続けて次階層の候補を出す
  vim.api.nvim_create_autocmd('CompleteDone', {
    group = vim.api.nvim_create_augroup('user_path_completion_done', { clear = true }),
    callback = function()
      local item = vim.v.completed_item
      if type(item) ~= 'table' or type(item.word) ~= 'string' then return end
      if item.word:sub(-1) ~= '/' then return end
      if vim.fn.mode() ~= 'i' then return end
      vim.schedule(function()
        M.trigger()
      end)
    end,
  })
end

setup()

return M
