-- スクロールバー。窓の右端に 1 列幅の float を重ねて描く。
-- extmark(virt_text)ではなく float なのは、extmark が文字の並びに差し込まれるため、
-- 全角文字が右端 2 セルを占める行では 1 セル分の置き場が無く描画ごと落ちるから。
-- float は画面セル単位で合成されるので文字幅の影響を受けない。
--
-- 下の文字を隠さないために winblend を使う。ハイライトの blend 属性は
-- winblend が 0 でない float の中でだけ効く(:h highlight-blend)。
--   ・トラック(バーの下地)  … blend=100 で完全透過。文字はそのまま見える
--   ・ハンドル              … 半透過。文字は残り、色だけ乗る
--   ・マーク(診断/git/検索) … 不透明。その行の右端 1 文字とは引き換え
local M = {}

local ns = vim.api.nvim_create_namespace('scrollbar')
local scrollbar_bufs = {}
local scrollbar_wins = {}
local scrollbar_win_ids = {}
local updating = false

local HANDLE_BG = '#3b4261'
local WINBLEND = 30
local HANDLE_BLEND = 30
local TRACK_BLEND = 100
local MARK_BLEND = 0

local MARKS = {
  Search = { text = { '-', '=' }, hl = 'ScrollbarSearch', priority = 1 },
  Error = { text = { '-', '=' }, hl = 'ScrollbarError', priority = 2 },
  Warn = { text = { '-', '=' }, hl = 'ScrollbarWarn', priority = 3 },
  Info = { text = { '-', '=' }, hl = 'ScrollbarInfo', priority = 4 },
  Hint = { text = { '-', '=' }, hl = 'ScrollbarHint', priority = 5 },
  GitAdd = { text = '┆', hl = 'ScrollbarGitAdd', priority = 7 },
  GitChange = { text = '┆', hl = 'ScrollbarGitChange', priority = 7 },
  GitDelete = { text = '▁', hl = 'ScrollbarGitDelete', priority = 7 },
}

local function mark_text(mark)
  local text = MARKS[mark.type] and MARKS[mark.type].text or '-'
  if type(text) == 'table' then
    return text[mark.level or 1] or text[#text] or '-'
  end
  return text
end

local function mark_hl(mark, handle)
  local hl = MARKS[mark.type] and MARKS[mark.type].hl or 'ScrollbarMisc'
  return handle and (hl .. 'Handle') or hl
end

local function is_scrollbar_win(win)
  return scrollbar_win_ids[win] == true
end

local function close_scrollbar(win)
  local sb_win = scrollbar_wins[win]
  if sb_win then
    scrollbar_win_ids[sb_win] = nil
    if vim.api.nvim_win_is_valid(sb_win) then
      pcall(vim.api.nvim_win_close, sb_win, true)
    end
    scrollbar_wins[win] = nil
  end

  local sb_buf = scrollbar_bufs[win]
  if sb_buf and vim.api.nvim_buf_is_valid(sb_buf) then
    pcall(vim.api.nvim_buf_delete, sb_buf, { force = true })
  end
  scrollbar_bufs[win] = nil
end

local function add_mark(out, line, typ)
  if not MARKS[typ] then return end
  table.insert(out, {
    line = math.max(0, line),
    type = typ,
    level = 1,
    priority = MARKS[typ].priority,
  })
end

local function severity_type(severity)
  if not vim.diagnostic then return nil end
  return ({
    [vim.diagnostic.severity.ERROR] = 'Error',
    [vim.diagnostic.severity.WARN] = 'Warn',
    [vim.diagnostic.severity.INFO] = 'Info',
    [vim.diagnostic.severity.HINT] = 'Hint',
  })[severity]
end

local function diagnostic_marks(buf)
  local out = {}
  if not vim.diagnostic then return out end
  for _, diagnostic in ipairs(vim.diagnostic.get(buf)) do
    add_mark(out, diagnostic.lnum or 0, severity_type(diagnostic.severity))
  end
  return out
end

local function git_marks(buf)
  local out = {}
  local git_ns = vim.api.nvim_create_namespace('git_gutter')
  local map = {
    GitGutterAdd = 'GitAdd',
    GitGutterChange = 'GitChange',
    GitGutterDelete = 'GitDelete',
    GitGutterChangeDelete = 'GitDelete',
  }
  for _, extmark in ipairs(vim.api.nvim_buf_get_extmarks(buf, git_ns, 0, -1, { details = true })) do
    local details = extmark[4] or {}
    add_mark(out, extmark[2], map[details.sign_hl_group])
  end
  return out
end

local function search_marks(buf)
  local out = {}
  if vim.v.hlsearch == 0 then return out end
  local pattern = vim.fn.getreg('/')
  if pattern == '' then return out end
  local ok, regex = pcall(vim.regex, pattern)
  if not ok then return out end
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if regex:match_str(line) then
      add_mark(out, i - 1, 'Search')
    end
  end
  return out
end

local function bump_level(mark)
  local text = MARKS[mark.type] and MARKS[mark.type].text
  if type(text) ~= 'table' then return end
  mark.level = math.min((mark.level or 1) + 1, #text)
end

local function collect_marks(buf)
  local out = {}
  vim.list_extend(out, search_marks(buf))
  vim.list_extend(out, diagnostic_marks(buf))
  vim.list_extend(out, git_marks(buf))
  return out
end

local function sorted_rows(buf, total_lines, height)
  local rows = {}
  local marks = collect_marks(buf)
  table.sort(marks, function(a, b)
    local ar = math.floor(a.line * height / math.max(total_lines, 1))
    local br = math.floor(b.line * height / math.max(total_lines, 1))
    if ar == br then
      return a.priority < b.priority
    end
    return ar < br
  end)

  for _, mark in ipairs(marks) do
    if mark.line < total_lines then
      local row = math.max(0, math.min(math.floor(mark.line * height / math.max(total_lines, 1)), height - 1))
      local prev = rows[row]
      if prev then
        bump_level(prev)
      else
        rows[row] = mark
      end
    end
  end
  return rows
end

local function ensure_buf(win)
  local buf = scrollbar_bufs[win]
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].buflisted = false
    vim.bo[buf].swapfile = false
    scrollbar_bufs[win] = buf
  end
  return buf
end

local function render_buf(buf, lines, hls)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for row, hl in pairs(hls) do
    vim.api.nvim_buf_add_highlight(buf, ns, hl, row, 0, -1)
  end
end

function M.render(win)
  win = win or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) or is_scrollbar_win(win) then return end

  local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
  if not ok or cfg.relative ~= '' then return end

  local src_buf = vim.api.nvim_win_get_buf(win)
  local buftype = vim.bo[src_buf].buftype
  if buftype ~= '' and buftype ~= 'help' then
    close_scrollbar(win)
    return
  end

  local total_lines = vim.api.nvim_buf_line_count(src_buf)
  local height = vim.api.nvim_win_get_height(win)
  if total_lines <= 0 or height <= 0 then
    close_scrollbar(win)
    return
  end

  local mark_rows = sorted_rows(src_buf, total_lines, height)
  local show_handle = total_lines > height
  if not show_handle and vim.tbl_isempty(mark_rows) then
    close_scrollbar(win)
    return
  end

  local first_visible = vim.api.nvim_win_call(win, function()
    return vim.fn.line('w0')
  end)
  local handle_size = show_handle and math.max(1, math.floor(height * height / total_lines)) or 0
  local scrollable = math.max(total_lines - height, 1)
  local handle_start = show_handle
    and math.min(math.floor((first_visible - 1) * (height - handle_size) / scrollable), height - handle_size)
    or -1
  local handle_end = handle_start + handle_size - 1

  local lines, hls = {}, {}
  for row = 0, height - 1 do
    local mark = mark_rows[row]
    local on_handle = show_handle and row >= handle_start and row <= handle_end
    if mark then
      lines[row + 1] = mark_text(mark)
      hls[row] = mark_hl(mark, on_handle)
    else
      lines[row + 1] = ' '
      hls[row] = on_handle and 'ScrollbarHandle' or 'ScrollbarTrack'
    end
  end

  local sb_buf = ensure_buf(win)
  render_buf(sb_buf, lines, hls)

  local pos = vim.api.nvim_win_get_position(win)
  local width = vim.api.nvim_win_get_width(win)
  local win_cfg = {
    relative = 'editor',
    row = pos[1],
    col = pos[2] + width - 1,
    width = 1,
    height = height,
    style = 'minimal',
    focusable = false,
    noautocmd = true,
    zindex = 60,
  }

  local sb_win = scrollbar_wins[win]
  if sb_win and vim.api.nvim_win_is_valid(sb_win) then
    pcall(vim.api.nvim_win_set_config, sb_win, win_cfg)
    pcall(vim.api.nvim_win_set_buf, sb_win, sb_buf)
  else
    local open_ok, opened = pcall(vim.api.nvim_open_win, sb_buf, false, win_cfg)
    if not open_ok then return end
    sb_win = opened
    scrollbar_wins[win] = sb_win
    scrollbar_win_ids[sb_win] = true
  end
  -- ハイライトの blend はここが 0 でないときだけ効く(:h highlight-blend)。
  -- トラックは blend=100 で完全透過、ハンドルは半透過で下の文字を残す。
  vim.wo[sb_win].winblend = WINBLEND
  vim.wo[sb_win].winhighlight = 'Normal:ScrollbarTrack,NormalFloat:ScrollbarTrack'
end

local function update_all()
  if updating then return end
  updating = true
  vim.schedule(function()
    updating = false
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if not is_scrollbar_win(win) then
        pcall(M.render, win)
      end
    end
  end)
end

local function set_hl()
  vim.api.nvim_set_hl(0, 'ScrollbarHandle', { fg = 'NONE', bg = HANDLE_BG, blend = HANDLE_BLEND })
  -- bg を持たないハイライトは blend ごと捨てられるので、透過でも色を置く。
  -- blend=100 なので、この色自体は画面に出ない。
  vim.api.nvim_set_hl(0, 'ScrollbarTrack', { fg = 'NONE', bg = '#24283b', blend = TRACK_BLEND })
  vim.api.nvim_set_hl(0, 'ScrollbarSearch', { fg = '#ff9e64', bg = 'NONE', bold = true, blend = MARK_BLEND })
  vim.api.nvim_set_hl(0, 'ScrollbarError', { fg = '#ff5f7a', bg = 'NONE', bold = true, blend = MARK_BLEND })
  vim.api.nvim_set_hl(0, 'ScrollbarWarn', { fg = '#ffc777', bg = 'NONE', bold = true, blend = MARK_BLEND })
  vim.api.nvim_set_hl(0, 'ScrollbarInfo', { fg = '#82aaff', bg = 'NONE', bold = true, blend = MARK_BLEND })
  vim.api.nvim_set_hl(0, 'ScrollbarHint', { fg = '#c3e88d', bg = 'NONE', bold = true, blend = MARK_BLEND })
  vim.api.nvim_set_hl(0, 'ScrollbarMisc', { fg = '#c0caf5', bg = 'NONE', bold = true, blend = MARK_BLEND })
  vim.api.nvim_set_hl(0, 'ScrollbarGitAdd', { fg = '#9ece6a', bg = 'NONE', bold = true, blend = MARK_BLEND })
  vim.api.nvim_set_hl(0, 'ScrollbarGitChange', { fg = '#82aaff', bg = 'NONE', bold = true, blend = MARK_BLEND })
  vim.api.nvim_set_hl(0, 'ScrollbarGitDelete', { fg = '#ff5f7a', bg = 'NONE', bold = true, blend = MARK_BLEND })
  for _, name in ipairs({ 'Search', 'Error', 'Warn', 'Info', 'Hint', 'Misc', 'GitAdd', 'GitChange', 'GitDelete' }) do
    vim.api.nvim_set_hl(0, 'Scrollbar' .. name .. 'Handle', {
      fg = vim.api.nvim_get_hl(0, { name = 'Scrollbar' .. name }).fg,
      bg = HANDLE_BG,
      bold = true,
      blend = MARK_BLEND,
    })
  end
end

set_hl()
vim.api.nvim_create_autocmd('ColorScheme', { callback = set_hl })

vim.api.nvim_create_autocmd({
  'BufWinEnter',
  'BufEnter',
  'WinEnter',
  'WinScrolled',
  'TextChanged',
  'TextChangedI',
  'DiagnosticChanged',
  'VimResized',
  'CursorMoved',
  'CursorMovedI',
}, {
  callback = update_all,
})

vim.api.nvim_create_autocmd('WinClosed', {
  callback = function(args)
    local win = tonumber(args.match)
    if not win then return end
    if is_scrollbar_win(win) then
      scrollbar_win_ids[win] = nil
      for src, sb in pairs(scrollbar_wins) do
        if sb == win then
          scrollbar_wins[src] = nil
          break
        end
      end
    else
      close_scrollbar(win)
    end
  end,
})

M._namespace = ns
M._scrollbar_wins = scrollbar_wins
M._collect_marks = collect_marks

return M
