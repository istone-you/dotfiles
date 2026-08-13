local M = {}
local browser = require('config.browser.util')
local http = require('config.browser.server')

local state = {
  source_buf = nil,
  html = nil,
  version = 0,
  server = nil,
  port = nil,
  host = nil,
  root_dir = nil,
  watch_handle = nil,
  watch_debounce = nil,
  watch_poll = nil,
  watch_stamp = nil,
  watched_path = nil,
}

local WATCH_DEBOUNCE_MS = 150

local augrp = vim.api.nvim_create_augroup('browser_markdown', { clear = true })
local exiting = false

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'Markdown Browser Preview' })
end

local function find_opener()
  return browser.find_opener('markdown')
end

local function html_escape(s)
  return (s:gsub('&', '&amp;')
    :gsub('<', '&lt;')
    :gsub('>', '&gt;')
    :gsub('"', '&quot;'))
end

local function attr_escape(s)
  return html_escape(s):gsub("'", '&#39;')
end

local SAFE_HTML_TAGS = {
  a = true,
  abbr = true,
  b = true,
  br = true,
  code = true,
  del = true,
  details = true,
  div = true,
  em = true,
  i = true,
  img = true,
  ins = true,
  kbd = true,
  mark = true,
  p = true,
  pre = true,
  s = true,
  small = true,
  span = true,
  strong = true,
  sub = true,
  summary = true,
  sup = true,
  u = true,
}

local HTML_BLOCK_TAGS = {
  article = true,
  aside = true,
  blockquote = true,
  details = true,
  div = true,
  dl = true,
  fieldset = true,
  figcaption = true,
  figure = true,
  footer = true,
  form = true,
  h1 = true,
  h2 = true,
  h3 = true,
  h4 = true,
  h5 = true,
  h6 = true,
  header = true,
  hr = true,
  main = true,
  nav = true,
  ol = true,
  p = true,
  pre = true,
  section = true,
  summary = true,
  table = true,
  ul = true,
}

local function sanitize_attrs(attrs)
  attrs = attrs or ''
  attrs = attrs:gsub('%s+on[%w-]+%s*=%s*"[^"]*"', '')
  attrs = attrs:gsub("%s+on[%w-]+%s*=%s*'[^']*'", '')
  attrs = attrs:gsub('%s+on[%w-]+%s*=%s*[^%s>]+', '')
  attrs = attrs:gsub('%s+style%s*=%s*"[^"]*"', '')
  attrs = attrs:gsub("%s+style%s*=%s*'[^']*'", '')
  attrs = attrs:gsub('%s+style%s*=%s*[^%s>]+', '')
  attrs = attrs:gsub('%s+href%s*=%s*["\']?%s*javascript:[^%s>]*["\']?', '')
  attrs = attrs:gsub('%s+src%s*=%s*["\']?%s*javascript:[^%s>]*["\']?', '')
  return attrs
end

local function sanitize_html_tag(tag)
  local closing, name, attrs, self_close = tag:match('^<%s*(/?)%s*([%a][%w:-]*)(.-)(/?)%s*>$')
  if not name then return html_escape(tag) end
  name = name:lower()
  if not SAFE_HTML_TAGS[name] then return html_escape(tag) end
  if closing == '/' then return '</' .. name .. '>' end
  return '<' .. name .. sanitize_attrs(attrs) .. (self_close == '/' and ' />' or '>')
end

local function escape_markdown_text_keep_safe_html(s)
  local protected = {}
  s = s:gsub('</?[%a][^>]*>', function(tag)
    protected[#protected + 1] = sanitize_html_tag(tag)
    return '\0HTML' .. tostring(#protected) .. '\0'
  end)
  s = html_escape(s)
  s = s:gsub('%zHTML(%d+)%z', function(n)
    return protected[tonumber(n)] or ''
  end)
  return s
end

local function url_decode(s)
  return browser.url_decode(s)
end

local function url_encode_path(s)
  return browser.url_encode_path(s)
end

local function is_external_url(url)
  return url:match('^[%a][%w+.-]*:') ~= nil or url:sub(1, 2) == '//' or url:sub(1, 1) == '#'
end

local slugify_heading

local function preview_asset_url(url)
  if is_external_url(url) then return url end
  return '/__asset/' .. url_encode_path(url:gsub('^%./', ''))
end

local function normalize_fragment(fragment)
  local decoded = url_decode(fragment:gsub('^#', ''))
  return '#' .. slugify_heading(decoded)
end

local function inline_markdown(s)
  s = escape_markdown_text_keep_safe_html(s)
  s = s:gsub('&lt;([%w._%%+%-]+@[%w._%-]+%.[%a][%w._%-]*)&gt;', function(email)
    return string.format('<a href="mailto:%s">%s</a>', attr_escape(email), email)
  end)
  s = s:gsub('&lt;(https?://[^%s&]+)&gt;', function(url)
    return string.format('<a href="%s">%s</a>', attr_escape(url), url)
  end)
  s = s:gsub('!%[([^%]]*)%]%(([^%)]+)%)', function(alt, url)
    return string.format('<img alt="%s" src="%s">', attr_escape(alt), attr_escape(preview_asset_url(url)))
  end)
  s = s:gsub('%[([^%]]+)%]%(([^%)]+)%)', function(label, url)
    if url:sub(1, 1) == '#' then
      return string.format('<a href="%s">%s</a>', attr_escape(normalize_fragment(url)), label)
    end
    return string.format('<a href="%s">%s</a>', attr_escape(preview_asset_url(url)), label)
  end)
  s = s:gsub('`([^`]+)`', '<code>%1</code>')
  s = s:gsub('~~([^~]+)~~', '<del>%1</del>')
  s = s:gsub('%*%*([^%*]+)%*%*', '<strong>%1</strong>')
  s = s:gsub('__([^_]+)__', '<strong>%1</strong>')
  s = s:gsub('%*([^%*]+)%*', '<em>%1</em>')
  s = s:gsub('_([^_]+)_', '<em>%1</em>')
  return s
end

local function strip_inline_markup(s)
  return (s:gsub('!%[([^%]]*)%]%([^%)]+%)', '%1')
    :gsub('%[([^%]]+)%]%([^%)]+%)', '%1')
    :gsub('`([^`]+)`', '%1')
    :gsub('~~([^~]+)~~', '%1')
    :gsub('%*%*([^%*]+)%*%*', '%1')
    :gsub('__([^_]+)__', '%1')
    :gsub('%*([^%*]+)%*', '%1')
    :gsub('_([^_]+)_', '%1'))
end

slugify_heading = function(heading)
  local slug = strip_inline_markup(heading):lower()
  slug = slug:gsub('[%z\1-\31\127]', '')
  slug = slug:gsub('[!"#$%%&\'()*+,./:;<=>?@%[%]\\^`{|}~]', '')
  slug = slug:gsub('%s+', '-')
  slug = slug:gsub('%-+', '-')
  slug = slug:gsub('^%-', ''):gsub('%-$', '')
  if slug == '' then slug = 'section' end
  return slug
end

local function is_blank(s)
  return s:match('^%s*$') ~= nil
end

local function split_table_row(line)
  line = vim.trim(line)
  if line:sub(1, 1) == '|' then line = line:sub(2) end
  if line:sub(-1) == '|' then line = line:sub(1, -2) end
  local cells = {}
  local cur = {}
  local escaped = false
  for i = 1, #line do
    local c = line:sub(i, i)
    if c == '|' and not escaped then
      cells[#cells + 1] = vim.trim(table.concat(cur))
      cur = {}
    else
      cur[#cur + 1] = c
    end
    escaped = (c == '\\' and not escaped)
    if c ~= '\\' then escaped = false end
  end
  cells[#cells + 1] = vim.trim(table.concat(cur))
  return cells
end

local function parse_table_separator(line)
  if not line or not line:find('|', 1, true) then return nil end
  local cells = split_table_row(line)
  if #cells == 0 then return nil end
  local aligns = {}
  for _, cell in ipairs(cells) do
    local compact = cell:gsub('%s+', '')
    if not compact:match('^:?-+:?$') then return nil end
    local left = compact:sub(1, 1) == ':'
    local right = compact:sub(-1) == ':'
    aligns[#aligns + 1] = (left and right and 'center') or (right and 'right') or (left and 'left') or ''
  end
  return aligns
end

local function render_table(lines, start_i)
  local header = split_table_row(lines[start_i] or '')
  local aligns = parse_table_separator(lines[start_i + 1])
  if not aligns then return nil end

  local out = { '<table>', '<thead>', '<tr>' }
  for idx, cell in ipairs(header) do
    local align = aligns[idx] and aligns[idx] ~= '' and (' style="text-align:' .. aligns[idx] .. '"') or ''
    out[#out + 1] = '<th' .. align .. '>' .. inline_markdown(cell) .. '</th>'
  end
  out[#out + 1] = '</tr>'
  out[#out + 1] = '</thead>'
  out[#out + 1] = '<tbody>'

  local i = start_i + 2
  while i <= #lines and (lines[i] or ''):find('|', 1, true) and not is_blank(lines[i] or '') do
    local cells = split_table_row(lines[i] or '')
    out[#out + 1] = '<tr>'
    for idx, cell in ipairs(cells) do
      local align = aligns[idx] and aligns[idx] ~= '' and (' style="text-align:' .. aligns[idx] .. '"') or ''
      out[#out + 1] = '<td' .. align .. '>' .. inline_markdown(cell) .. '</td>'
    end
    out[#out + 1] = '</tr>'
    i = i + 1
  end

  out[#out + 1] = '</tbody>'
  out[#out + 1] = '</table>'
  return table.concat(out, '\n'), i
end

local function parse_list_marker(line)
  local indent, marker, text = line:match('^(%s*)([-*+])%s+(.+)$')
  if indent then return #indent, 'ul', text end
  indent, marker, text = line:match('^(%s*)(%d+[.)])%s+(.+)$')
  if indent then return #indent, 'ol', text end
end

-- GFM のタスクリスト( - [ ] / - [x] )。マーカーを剥がして disabled な checkbox にする。
local function render_list_item(text)
  local mark, rest = text:match('^%[([ xX])%]%s+(.*)$')
  if mark then
    local checked = (mark == 'x' or mark == 'X') and ' checked' or ''
    return '<input type="checkbox" disabled' .. checked .. '> ' .. inline_markdown(rest), true
  end
  return inline_markdown(text), false
end

local function render_list(lines, start_i)
  local root_indent, root_tag = parse_list_marker(lines[start_i] or '')
  if not root_indent then return nil end
  local out = {}
  local stack = {}
  local open_li = {}
  local i = start_i

  local function close_to(depth)
    while #stack > depth do
      if open_li[#stack] then
        out[#out] = (out[#out] or '') .. '</li>'
        open_li[#stack] = false
      end
      out[#out + 1] = '</' .. stack[#stack].tag .. '>'
      stack[#stack] = nil
      open_li[#stack + 1] = nil
    end
  end

  while i <= #lines do
    local indent, tag, text = parse_list_marker(lines[i] or '')
    if not indent then break end
    if indent < root_indent then break end

    local depth = 1
    while stack[depth] and indent > stack[depth].indent do depth = depth + 1 end
    while stack[depth] and indent < stack[depth].indent do
      close_to(#stack - 1)
      depth = depth - 1
    end
    if stack[depth] and indent == stack[depth].indent and #stack > depth then
      close_to(depth)
    end
    if not stack[depth] or stack[depth].indent ~= indent or stack[depth].tag ~= tag then
      if stack[depth] then close_to(depth - 1) end
      out[#out + 1] = '<' .. tag .. '>'
      stack[#stack + 1] = { indent = indent, tag = tag }
      depth = #stack
    elseif open_li[depth] then
      out[#out] = (out[#out] or '') .. '</li>'
      open_li[depth] = false
    end

    local li_inner, is_task = render_list_item(text)
    out[#out + 1] = (is_task and '<li class="task-list-item">' or '<li>') .. li_inner
    open_li[depth] = true
    i = i + 1
  end

  close_to(0)
  return table.concat(out, ''), i
end

local function is_html_block_line(s)
  local closing, name = s:match('^%s*<%s*(/?)%s*([%a][%w:-]*)')
  if not name then return false end
  name = name:lower()
  return closing == '/' or HTML_BLOCK_TAGS[name] == true
end

local function is_block_start(s)
  return is_blank(s)
    or s:match('^%s*```') ~= nil
    or s:match('^%s*#+%s+') ~= nil
    or is_html_block_line(s)
    or s:match('^%s*>') ~= nil
    or s:match('^%s*[-*+]%s+') ~= nil
    or s:match('^%s*%d+[.)]%s+') ~= nil
    or s:match('^%s*[-*_][%s%-*_]*$') ~= nil
end

-- markdown-preview.nvim (app/pages/mermaid.js) と同じ判定。
-- ```mermaid フェンスに加え、言語指定なしフェンスでも先頭行が
-- gantt / sequenceDiagram / erDiagram / graph (TB|BT|RL|LR|TD) のときは mermaid 図として扱う。
local function is_mermaid_fence(lang, raw_lines)
  if lang == 'mermaid' then return true end
  if lang ~= '' then return false end
  local first
  for _, l in ipairs(raw_lines) do
    if not is_blank(l) then
      first = vim.trim(l)
      break
    end
  end
  if not first then return false end
  if first == 'gantt' or first == 'sequenceDiagram' or first == 'erDiagram' then return true end
  local dir = first:match('^graph%s+(%u%u)%s*;?$')
  return dir == 'TB' or dir == 'BT' or dir == 'RL' or dir == 'LR' or dir == 'TD'
end

-- GitHub Alerts ( > [!NOTE] 等 )。アイコンは octicon(@primer/octicons)の SVG をインライン化し、
-- fill:currentColor でタイトル色に追従させる。Nerd Font 等ホスト環境のフォントに依存しないよう SVG を採用。
local function octicon(d)
  return '<svg class="octicon" width="16" height="16" viewBox="0 0 16 16" aria-hidden="true"><path d="'
    .. d .. '"/></svg>'
end

local ALERTS = {
  NOTE = { key = 'note', label = 'Note', icon = octicon(
    'M0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8Zm8-6.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM6.5 7.75A.75.75 0 0 1 7.25 7h1a.75.75 0 0 1 .75.75v2.75h.25a.75.75 0 0 1 0 1.5h-2a.75.75 0 0 1 0-1.5h.25v-2h-.25a.75.75 0 0 1-.75-.75ZM8 6a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z') },
  TIP = { key = 'tip', label = 'Tip', icon = octicon(
    'M8 1.5c-2.363 0-4 1.69-4 3.75 0 .984.424 1.625.984 2.304l.214.253c.223.264.47.556.673.848.284.411.537.896.621 1.49a.75.75 0 0 1-1.484.211c-.04-.282-.163-.547-.37-.847a8.456 8.456 0 0 0-.542-.68c-.084-.1-.173-.205-.268-.32C3.201 7.75 2.5 6.766 2.5 5.25 2.5 2.31 4.863 0 8 0s5.5 2.31 5.5 5.25c0 1.516-.701 2.5-1.328 3.259-.095.115-.184.22-.268.319-.207.245-.383.453-.541.681-.208.3-.33.565-.37.847a.751.751 0 0 1-1.485-.212c.084-.593.337-1.078.621-1.489.203-.292.45-.584.673-.848.075-.088.147-.173.213-.253.561-.679.985-1.32.985-2.304 0-2.06-1.637-3.75-4-3.75ZM5.75 12h4.5a.75.75 0 0 1 0 1.5h-4.5a.75.75 0 0 1 0-1.5ZM6 15.25a.75.75 0 0 1 .75-.75h2.5a.75.75 0 0 1 0 1.5h-2.5a.75.75 0 0 1-.75-.75Z') },
  IMPORTANT = { key = 'important', label = 'Important', icon = octicon(
    'M0 1.75C0 .784.784 0 1.75 0h12.5C15.216 0 16 .784 16 1.75v9.5A1.75 1.75 0 0 1 14.25 13H8.06l-2.573 2.573A1.458 1.458 0 0 1 3 14.543V13H1.75A1.75 1.75 0 0 1 0 11.25Zm1.75-.25a.25.25 0 0 0-.25.25v9.5c0 .138.112.25.25.25h2a.75.75 0 0 1 .75.75v2.19l2.72-2.72a.749.749 0 0 1 .53-.22h6.5a.25.25 0 0 0 .25-.25v-9.5a.25.25 0 0 0-.25-.25Zm7 2.25v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 9a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z') },
  WARNING = { key = 'warning', label = 'Warning', icon = octicon(
    'M6.457 1.047c.659-1.234 2.427-1.234 3.086 0l6.082 11.378A1.75 1.75 0 0 1 14.082 15H1.918a1.75 1.75 0 0 1-1.543-2.575Zm1.763.707a.25.25 0 0 0-.44 0L1.698 13.132a.25.25 0 0 0 .22.368h12.164a.25.25 0 0 0 .22-.368Zm.53 3.996v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 11a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z') },
  CAUTION = { key = 'caution', label = 'Caution', icon = octicon(
    'M4.47.22A.749.749 0 0 1 5 0h6c.199 0 .389.079.53.22l4.25 4.25c.141.14.22.331.22.53v6a.749.749 0 0 1-.22.53l-4.25 4.25A.749.749 0 0 1 11 16H5a.749.749 0 0 1-.53-.22L.22 11.53A.749.749 0 0 1 0 11V5c0-.199.079-.389.22-.53Zm.84 1.28L1.5 5.31v5.38l3.81 3.81h5.38l3.81-3.81V5.31L10.69 1.5ZM8 4a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0v-3.5A.75.75 0 0 1 8 4Zm0 8a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z') },
}

-- headings(任意) を渡すとトップレベル見出しを {level, slug, text} で収集する(目次生成用)。
-- 再帰(Alert 本文)では渡さないので、目次には本文直下の見出しだけが載る。
local function markdown_to_body(lines, headings)
  local out = {}
  local slugs = {}
  local i = 1

  while i <= #lines do
    local line = lines[i] or ''

    if is_blank(line) then
      i = i + 1
    elseif line:match('^%s*```') then
      local lang = line:match('^%s*```%s*([^%s`]*)') or ''
      local raw = {}
      i = i + 1
      while i <= #lines and not (lines[i] or ''):match('^%s*```') do
        raw[#raw + 1] = lines[i] or ''
        i = i + 1
      end
      if i <= #lines then i = i + 1 end
      local code = {}
      for k, l in ipairs(raw) do
        code[k] = html_escape(l)
      end
      if is_mermaid_fence(lang, raw) then
        -- 図の描画はブラウザ側の mermaid.js が担う。Lua はエスケープした
        -- ソースを .mermaid コンテナに入れるだけ(mermaid は textContent を読む)。
        out[#out + 1] = '<div class="mermaid">' .. table.concat(code, '\n') .. '</div>'
      else
        local class = lang ~= '' and string.format(' class="language-%s"', attr_escape(lang)) or ''
        out[#out + 1] = string.format('<pre><code%s>%s</code></pre>', class, table.concat(code, '\n'))
      end
    elseif is_html_block_line(line) then
      out[#out + 1] = escape_markdown_text_keep_safe_html(line)
      i = i + 1
    else
      local hashes, heading = line:match('^%s*(#+)%s+(.+)$')
      if hashes and #hashes <= 6 then
        local level = #hashes
        local base_slug = slugify_heading(heading)
        local slug = base_slug
        slugs[base_slug] = (slugs[base_slug] or 0) + 1
        if slugs[base_slug] > 1 then slug = base_slug .. '-' .. tostring(slugs[base_slug] - 1) end
        out[#out + 1] = string.format('<h%d id="%s">%s</h%d>', level, attr_escape(slug), inline_markdown(heading), level)
        if headings then
          headings[#headings + 1] = { level = level, slug = slug, text = html_escape(strip_inline_markup(heading)) }
        end
        i = i + 1
      elseif line:match('^%s*[-*_][%s%-*_]*$') then
        out[#out + 1] = '<hr>'
        i = i + 1
      elseif line:match('^%s*>') then
        local inner = {}
        while i <= #lines and (lines[i] or ''):match('^%s*>') do
          inner[#inner + 1] = (lines[i] or ''):gsub('^%s*>%s?', '')
          i = i + 1
        end
        -- 先頭行が [!TYPE] だけなら GitHub Alert(大文字のみ・GitHub と同じ判定)。
        -- 未知タイプや小文字は通常の引用にフォールバック。
        local atype = inner[1] and inner[1]:match('^%s*%[!(%u+)%]%s*$')
        local alert = atype and ALERTS[atype]
        if alert then
          local body_lines = {}
          for k = 2, #inner do
            body_lines[#body_lines + 1] = inner[k]
          end
          -- 本文はネストした段落/リスト/コードも活かすため markdown_to_body に再帰させる
          out[#out + 1] = string.format(
            '<div class="markdown-alert markdown-alert-%s">\n'
            .. '<p class="markdown-alert-title">%s%s</p>\n%s\n</div>',
            alert.key, alert.icon, alert.label, markdown_to_body(body_lines))
        else
          local parts = {}
          for _, l in ipairs(inner) do
            parts[#parts + 1] = inline_markdown(l)
          end
          out[#out + 1] = '<blockquote><p>' .. table.concat(parts, '<br>') .. '</p></blockquote>'
        end
      elseif line:find('|', 1, true) and parse_table_separator(lines[i + 1]) then
        local html, next_i = render_table(lines, i)
        out[#out + 1] = html
        i = next_i
      elseif line:match('^%s*[-*+]%s+') or line:match('^%s*%d+[.)]%s+') then
        local html, next_i = render_list(lines, i)
        out[#out + 1] = html
        i = next_i
      else
        local parts = { inline_markdown(line) }
        i = i + 1
        while i <= #lines and not is_block_start(lines[i] or '') do
          parts[#parts + 1] = inline_markdown(lines[i] or '')
          i = i + 1
        end
        out[#out + 1] = '<p>' .. table.concat(parts, '<br>') .. '</p>'
      end
    end
  end

  return table.concat(out, '\n')
end

-- 収集した見出しから目次 nav を組み立てる。最浅レベルを基準に相対インデント(lv0..lv5)。
local function build_toc(headings)
  local min_level = 6
  for _, h in ipairs(headings) do
    if h.level < min_level then min_level = h.level end
  end
  local out = { '<nav id="mp-toc"><div class="mp-toc-title">目次</div>' }
  for _, h in ipairs(headings) do
    local depth = math.min(h.level - min_level, 5)
    out[#out + 1] = string.format(
      '<a href="#%s" class="lv%d" data-slug="%s">%s</a>',
      attr_escape(h.slug), depth, attr_escape(h.slug), h.text)
  end
  out[#out + 1] = '</nav>'
  return table.concat(out, '\n')
end

-- プレビュー本文のスタイル。notes_web.lua の一覧ページでも同じ見た目を使うので定数に切り出す。
local PREVIEW_CSS = {
  'body{margin:0;background:#111827;color:#e5e7eb;font:16px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;}',
  'main{box-sizing:border-box;max-width:920px;margin:0 auto;padding:40px 48px 80px;}',
  -- 先頭/末尾要素の外側マージンを消して、padding との二重の余白をなくす(GitHub と同じ)
  'main>*:first-child{margin-top:0;} main>*:last-child{margin-bottom:0;}',
  'h1,h2,h3,h4,h5,h6{color:#f9fafb;line-height:1.25;margin:1.6em 0 .55em;font-weight:700;}',
  'h1{font-size:2.1rem;border-bottom:1px solid #374151;padding-bottom:.35em;} h2{font-size:1.55rem;border-bottom:1px solid #253044;padding-bottom:.25em;}',
  'p,ul,ol,blockquote,pre,table{margin:1em 0;} a{color:#93c5fd;}',
  'li>ul,li>ol{margin:.25em 0 .25em 1.4em;} li{margin:.2em 0;}',
  'blockquote{border-left:4px solid #4b5563;color:#cbd5e1;padding:.1rem 1rem;background:#172033;}',
  'code{background:#243044;color:#f8fafc;border-radius:4px;padding:.15em .35em;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:.92em;}',
  'pre{background:#0b1220;border:1px solid #253044;border-radius:8px;padding:16px;overflow:auto;} pre code{background:transparent;padding:0;}',
  'table{border-collapse:collapse;width:100%;display:block;overflow:auto;} th,td{border:1px solid #374151;padding:6px 13px;} th{background:#1f2937;font-weight:600;} tr:nth-child(2n) td{background:#172033;}',
  'img{max-width:100%;height:auto;border-radius:6px;} hr{border:0;border-top:1px solid #374151;margin:2rem 0;}',
  '.mermaid{margin:1em 0;overflow:auto;} .mermaid svg{max-width:100%;height:auto;}',
  -- highlight.js のトークン色は使いつつ、pre のコンテナ見た目(背景/余白)は既存スタイルを維持する
  'pre code.hljs{background:transparent;padding:0;}',
  '.task-list-item{list-style:none;} .task-list-item>input{margin:0 .5em 0 -1.3em;vertical-align:middle;} del{color:#9aa4b2;}',
  -- <kbd> のキーキャップ表示(markdown-preview.nvim の kbd を暗色パレットに合わせたもの)
  'kbd{display:inline-block;padding:3px 6px;font:.85em ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;line-height:1;color:#e5e7eb;background:#1f2937;border:1px solid #374151;border-radius:4px;box-shadow:inset 0 -1px 0 #374151;vertical-align:middle;}',
  -- GitHub Alerts ( > [!NOTE] 等 )。色調は暗色テーマに合わせた octicon カラー。
  '.markdown-alert{margin:1em 0;padding:.4rem 1rem;border-left:.25em solid;}',
  '.markdown-alert>:first-child{margin-top:0;} .markdown-alert>:last-child{margin-bottom:0;}',
  '.markdown-alert-title{display:flex;align-items:center;gap:.4em;margin:0 0 .4rem;font-weight:600;line-height:1;}',
  '.markdown-alert-title svg{fill:currentColor;flex:none;}',
  '.markdown-alert-note{border-color:#4493f8;} .markdown-alert-note .markdown-alert-title{color:#4493f8;}',
  '.markdown-alert-tip{border-color:#3fb950;} .markdown-alert-tip .markdown-alert-title{color:#3fb950;}',
  '.markdown-alert-important{border-color:#ab7df8;} .markdown-alert-important .markdown-alert-title{color:#ab7df8;}',
  '.markdown-alert-warning{border-color:#d29922;} .markdown-alert-warning .markdown-alert-title{color:#d29922;}',
  '.markdown-alert-caution{border-color:#f85149;} .markdown-alert-caution .markdown-alert-title{color:#f85149;}',
}

--- Markdown 本文(行配列)を HTML の本文断片に変換する。画像/相対リンクは /__asset/ を指す。
function M.render_body(lines, headings)
  return markdown_to_body(lines, headings)
end

--- プレビュー本文のスタイルシート(<style> の中身)。
function M.preview_css()
  return table.concat(PREVIEW_CSS, '\n')
end

local function document_html(lines, title, base_dir, version)
  local _ = base_dir
  local headings = {}
  local body = markdown_to_body(lines, headings)
  -- 見出しが 2 個以上あるときだけ目次を出す(短文は素直な 1 カラムのまま)。
  local has_toc = #headings >= 2
  local has_mermaid = body:find('class="mermaid"', 1, true) ~= nil
  local has_code = body:find('<pre><code', 1, true) ~= nil

  local parts = {
    '<!doctype html>',
    '<html>',
    '<head>',
    '<meta charset="utf-8">',
    '<meta name="viewport" content="width=device-width, initial-scale=1">',
    '<meta name="markdown-preview-version" content="' .. tostring(version or 0) .. '">',
    '<title>' .. html_escape(title or 'Markdown Preview') .. '</title>',
    '<style>',
    M.preview_css(),
    '</style>',
    '<script>',
    'const v=document.querySelector("meta[name=markdown-preview-version]").content;',
    'setInterval(()=>fetch("/__version").then(r=>r.text()).then(n=>{if(n.trim()!==v)location.reload();}).catch(()=>{}),1000);',
    '</script>',
  }

  -- 目次(サイドバー)。本文は常に中央 920px 固定で、目次はフロー外の position:fixed。
  -- そのため表示/非表示で本文の幅も位置も変わらない。色は既存パレットのみ(新規色を足さない)。
  if has_toc then
    parts[#parts + 1] = table.concat({
      '<style>',
      -- 常時見える上部バー(☰ の置き場)。地色 #111827・下罫線 #253044 で新規色なし。
      '.mp-topbar{position:sticky;top:0;z-index:6;display:flex;align-items:center;gap:10px;height:44px;box-sizing:border-box;padding:0 12px;background:#111827;border-bottom:1px solid #253044;}',
      '.mp-toc-btn{cursor:pointer;background:#1f2937;color:#e5e7eb;border:1px solid #374151;border-radius:6px;padding:3px 10px;font-size:15px;line-height:1;}',
      '.mp-toc-btn:hover{background:#243044;}',
      '.mp-name{color:#9aa4b2;font-size:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}',
      '#mp-layout{position:relative;}',
      -- 広い画面: 中央本文(半幅460)のすぐ左、gutter 内に右端を合わせて置く(722 = 460 + 幅262)。本文に被らない。
      -- position:fixed なので本文レイアウトに一切干渉しない。地色 #111827 で(狭い画面の重ね表示でも)透けない。
      '#mp-toc{position:fixed;top:44px;left:calc(50% - 722px);width:262px;box-sizing:border-box;height:calc(100vh - 44px);overflow-y:auto;overflow-x:hidden;background:#111827;border-right:1px solid #253044;z-index:5;display:none;font-size:13px;}',
      '#mp-layout.toc-open #mp-toc{display:block;}',
      '.mp-toc-title{color:#9aa4b2;font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.04em;padding:14px 10px 8px;}',
      -- 見出し名は列幅に対して … で省略(横幅は広げない)。現在地は左ボーダーで示す。
      '#mp-toc a{display:block;color:#9aa4b2;text-decoration:none;padding:3px 10px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;border-left:2px solid transparent;}',
      '#mp-toc a:hover{background:#172033;color:#e5e7eb;}',
      '#mp-toc a.active{color:#93c5fd;background:#172033;border-left-color:#93c5fd;}',
      '#mp-toc a.lv0{padding-left:10px;} #mp-toc a.lv1{padding-left:22px;} #mp-toc a.lv2{padding-left:34px;} #mp-toc a.lv3{padding-left:46px;} #mp-toc a.lv4{padding-left:58px;} #mp-toc a.lv5{padding-left:70px;}',
      -- アンカージャンプが上部バーに隠れないよう scroll-margin を確保。
      'h1,h2,h3,h4,h5,h6{scroll-margin-top:56px;}',
      -- 狭い画面(gutter に入りきらない 1460px 未満): Zenn のように目次を本文の上へ Z 軸で重ねる。
      -- left:0 のドロワー。開くのは ☰ のときだけ(下の JS で狭い画面は既定で閉じる)。影で浮いて見せる。
      '@media(max-width:1459px){#mp-toc{left:0;width:min(300px,84vw);box-shadow:2px 0 18px rgba(0,0,0,.45);}}',
      '</style>',
    }, '\n')
  end

  -- mermaid を含むページのときだけ、同梱した mermaid.js を読み込んで初期化する。
  -- 普通の Markdown プレビューには 3MB 超の JS を一切載せない。
  -- 読み込み方は markdown-preview.nvim と同じ: グローバル mermaid を <script src> で取り、
  -- initialize → 描画。バージョン固定なので /__vendor だけ immutable キャッシュ可(util 側で付与)。
  if has_mermaid then
    parts[#parts + 1] = '<script src="/__vendor/mermaid.min.js"></script>'
    parts[#parts + 1] = table.concat({
      '<script>',
      'document.addEventListener("DOMContentLoaded",function(){',
      '  if(!window.mermaid){return;}',
      '  try{',
      '    mermaid.initialize({startOnLoad:false,theme:"dark",securityLevel:"strict"});',
      '    if(typeof mermaid.run==="function"){mermaid.run({querySelector:".mermaid"});}',
      '    else{mermaid.init(undefined,document.querySelectorAll(".mermaid"));}',
      '  }catch(e){}',
      '});',
      '</script>',
    }, '\n')
  end

  -- コードブロックを含むときだけ、同梱した highlight.js とテーマを読み込んでハイライトする。
  -- mermaid ブロックは <div class="mermaid"> なので対象外(<pre><code> のみ)。
  if has_code then
    parts[#parts + 1] = '<link rel="stylesheet" href="/__vendor/highlight-theme.css">'
    parts[#parts + 1] = '<script src="/__vendor/highlight.min.js"></script>'
    parts[#parts + 1] = table.concat({
      '<script>',
      'document.addEventListener("DOMContentLoaded",function(){',
      '  if(!window.hljs){return;}',
      '  document.querySelectorAll("pre code").forEach(function(el){try{hljs.highlightElement(el);}catch(e){}});',
      '});',
      '</script>',
    }, '\n')
  end

  parts[#parts + 1] = '</head>'
  if has_toc then
    parts[#parts + 1] = string.format(
      '<body>\n'
      .. '<div class="mp-topbar"><button class="mp-toc-btn" id="mp-toc-btn" aria-expanded="false" title="目次">☰</button>'
      .. '<span class="mp-name">%s</span></div>\n'
      .. '<div id="mp-layout">\n%s\n<main>',
      html_escape(title or ''), build_toc(headings))
    parts[#parts + 1] = body
    parts[#parts + 1] = '</main></div>'
    -- 開閉(広い画面のみ localStorage 保持)＋ Zenn 風の狭い画面挙動(リンク/外側クリックで閉じる)＋現在地ハイライト。
    parts[#parts + 1] = table.concat({
      '<script>',
      '(function(){',
      '  var layout=document.getElementById("mp-layout"),btn=document.getElementById("mp-toc-btn"),side=document.getElementById("mp-toc");',
      '  if(!layout||!btn||!side){return;}',
      '  var KEY="mdpreview-toc-open",mq=window.matchMedia("(max-width:1459px)");',
      '  function narrow(){return mq.matches;}',
      '  function stored(){try{return localStorage.getItem(KEY)!=="0";}catch(e){return true;}}',
      '  function set(open){layout.classList.toggle("toc-open",open);btn.setAttribute("aria-expanded",open?"true":"false");}',
      -- 広い画面は保存値(既定は開)、狭い画面は常に閉じて開始(本文を覆わない)。
      '  var open=narrow()?false:stored();set(open);',
      '  btn.addEventListener("click",function(e){e.stopPropagation();open=!open;set(open);if(!narrow()){try{localStorage.setItem(KEY,open?"1":"0");}catch(e){}}});',
      -- 狭い画面: 目次リンクを押したら閉じる(ジャンプ後に本文を覆ったままにしない)。
      '  side.addEventListener("click",function(e){if(narrow()&&e.target.closest("a")){open=false;set(false);}});',
      -- 狭い画面: パネル外クリックで閉じる(Zenn と同じ)。
      '  document.addEventListener("click",function(e){if(narrow()&&open&&!side.contains(e.target)&&e.target!==btn){open=false;set(false);}});',
      -- 画面幅が境界をまたいだら整合を取る(広→狭で覆いっぱなしを防ぐ)。
      '  mq.addEventListener("change",function(){open=narrow()?false:stored();set(open);});',
      '  var links=[].slice.call(side.querySelectorAll("a")),map={};',
      '  links.forEach(function(a){map[a.getAttribute("data-slug")]=a;});',
      '  var heads=[].slice.call(document.querySelectorAll("main h1,main h2,main h3,main h4,main h5,main h6")).filter(function(h){return h.id&&map[h.id];});',
      '  function spy(){var cur=null;for(var i=0;i<heads.length;i++){if(heads[i].getBoundingClientRect().top<=80){cur=heads[i];}else{break;}}if(!cur&&heads.length){cur=heads[0];}links.forEach(function(a){a.classList.remove("active");});if(cur&&map[cur.id]){map[cur.id].classList.add("active");}}',
      '  window.addEventListener("scroll",spy,{passive:true});spy();',
      '})();',
      '</script>',
      '</body>',
    }, '\n')
  else
    parts[#parts + 1] = '<body><main>'
    parts[#parts + 1] = body
    parts[#parts + 1] = '</main></body>'
  end
  parts[#parts + 1] = '</html>'
  return table.concat(parts, '\n')
end

local function set_preview_html(lines, name)
  local title = name ~= '' and vim.fn.fnamemodify(name, ':t') or 'Markdown Preview'
  local base_dir = name ~= '' and vim.fn.fnamemodify(name, ':p:h') or vim.fn.getcwd()
  state.root_dir = base_dir
  state.version = state.version + 1
  state.html = document_html(lines, title, base_dir, state.version)
  return state.html
end

local function update_preview_html(source_buf)
  local name = vim.api.nvim_buf_get_name(source_buf)
  return set_preview_html(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), name)
end

-- ソースファイルはエディタの外(AI エージェント等)から書き換えられることがあり、
-- そのときは nvim のバッファ/checktime を経由しないので、ディスクを直接読んで反映する。
local function refresh_preview_from_disk(path)
  if not path or path == '' or vim.fn.filereadable(path) ~= 1 then return false end
  set_preview_html(vim.fn.readfile(path), path)
  return true
end

local function file_stamp(path)
  local uv = vim.uv or vim.loop
  local st = path and uv.fs_stat(path) or nil
  if not st then return nil end
  local mtime = st.mtime or {}
  return table.concat({
    tostring(st.size or 0),
    tostring(mtime.sec or 0),
    tostring(mtime.nsec or 0),
  }, ':')
end

local function server_url()
  if not state.port then return nil end
  return 'http://localhost:' .. tostring(state.port) .. '/'
end

local function build_opener_cmd(opener, url)
  return browser.build_opener_cmd(opener, url)
end

local function parse_port(input)
  return browser.parse_port(input)
end

local function http_response(status, content_type, body, cache_control)
  return browser.http_response(status, content_type, body, cache_control)
end

local function asset_response(asset_path)
  return browser.asset_response(state.root_dir, asset_path)
end

-- /__vendor で配信を許可する同梱アセットのホワイトリスト(パストラバーサル防止)。
local VENDOR_FILES = {
  ['mermaid.min.js'] = true,
  ['highlight.min.js'] = true,
  ['highlight-theme.css'] = true,
}

-- 同梱アセット解決/配信は browser/util.lua に共通化(diff_review と共有)。ホワイトリスト
-- 判定は response_for_path 側(VENDOR_FILES)で行う。
local function vendor_file(name) return browser.vendor_file(name) end
local function vendor_response(name) return browser.vendor_response(name) end

local function response_for_path(path)
  if path == '/__version' then
    return http_response('200 OK', 'text/plain', tostring(state.version))
  end
  if path == '/' or path == '/index.html' then
    return http_response('200 OK', 'text/html', state.html or '<!doctype html><title>Markdown Preview</title>')
  end
  local vf = path:match('^/__vendor/([%w._-]+)$')
  if vf and VENDOR_FILES[vf] then
    return vendor_response(vf)
  end
  local asset_path = path:match('^/__asset/(.*)$')
  if asset_path then
    return asset_response(asset_path)
  end
  return http_response('404 Not Found', 'text/plain', 'not found')
end

local function stop_watch()
  if state.watch_debounce then
    pcall(function() state.watch_debounce:stop() end)
    pcall(function() state.watch_debounce:close() end)
    state.watch_debounce = nil
  end
  if state.watch_poll then
    pcall(function() state.watch_poll:stop() end)
    pcall(function() state.watch_poll:close() end)
    state.watch_poll = nil
  end
  state.watch_stamp = nil
  if state.watch_handle then
    pcall(function() state.watch_handle:stop() end)
    pcall(function() state.watch_handle:close() end)
    state.watch_handle = nil
  end
  state.watched_path = nil
end

-- ファイル自体ではなく親ディレクトリを監視する。「一時ファイルに書いてrename」方式で
-- 保存するツールだとinodeが差し替わり、ファイル直接監視では以後イベントが来なくなるため
-- (explorer.lua のディレクトリ監視と同じ方針)。
local function start_watch(path)
  if state.watched_path == path and state.watch_handle then return end
  stop_watch()
  if not path or path == '' then return end
  local uv = vim.uv or vim.loop
  local dir = vim.fn.fnamemodify(path, ':p:h')
  local base = vim.fn.fnamemodify(path, ':t')
  local handle = uv.new_fs_event()
  if not handle then return end
  local ok = handle:start(dir, {}, function(err, filename)
    if err then return end
    -- filename はプラットフォームによっては nil。その場合は判定せず更新側に倒す
    if filename and filename ~= base then return end
    vim.schedule(function()
      if state.watched_path ~= path then return end
      if state.watch_debounce then
        pcall(function() state.watch_debounce:stop() end)
        pcall(function() state.watch_debounce:close() end)
      end
      state.watch_debounce = uv.new_timer()
      state.watch_debounce:start(WATCH_DEBOUNCE_MS, 0, function()
        if state.watch_debounce then
          pcall(function() state.watch_debounce:stop() end)
          pcall(function() state.watch_debounce:close() end)
          state.watch_debounce = nil
        end
        vim.schedule(function()
          if state.watched_path == path then refresh_preview_from_disk(path) end
        end)
      end)
    end)
  end)
  if not ok then
    pcall(function() handle:close() end)
    return
  end
  state.watch_handle = handle
  state.watched_path = path
  state.watch_stamp = file_stamp(path)
  state.watch_poll = uv.new_timer()
  if state.watch_poll then
    state.watch_poll:start(WATCH_DEBOUNCE_MS, WATCH_DEBOUNCE_MS, function()
      local stamp = file_stamp(path)
      if stamp and stamp ~= state.watch_stamp then
        state.watch_stamp = stamp
        vim.schedule(function()
          if state.watched_path == path then refresh_preview_from_disk(path) end
        end)
      end
    end)
  end
end

local function stop_server(opts)
  opts = opts or {}
  local port = state.port
  local had_server = state.server ~= nil
  stop_watch()
  http.stop(state) -- state.server/port/host をクリア
  -- ポートの付け替え(start_server 経由)では紐付けを残す。ここで無条件に nil にすると
  -- BufWritePost / BufDelete の `state.source_buf == ev.buf` が二度と成立せず、
  -- バッファを閉じてもサーバーが止まらなくなる(更新自体は監視が拾うので気づきにくい)。
  if not opts.keep_source_buf then state.source_buf = nil end
  if had_server and opts.notify ~= false and not exiting then
    local suffix = port and (': http://localhost:' .. tostring(port) .. '/') or ''
    vim.schedule(function()
      if not exiting then notify('Markdown previewを停止しました' .. suffix) end
    end)
  end
end

local function start_server(port)
  if state.server and state.port == port then return true end
  if state.server and state.port ~= port then stop_server({ keep_source_buf = true }) end
  return http.start(state, port, {
    namespace = 'markdown',
    default_host = '0.0.0.0',
    handler = function(req) return response_for_path(req.path) end,
  })
end

local function open_with_default_browser(url)
  return browser.open_url(url, {
    fallback_message = 'Markdown preview URL: ',
    namespace = 'markdown',
    title = 'Markdown Browser Preview',
  })
end

function M.open_on_port(port)
  local source_buf = vim.api.nvim_get_current_buf()
  state.source_buf = source_buf
  update_preview_html(source_buf)
  -- start_server は別ポートの既存サーバーを stop_server (= stop_watch) するので、
  -- 監視の開始はサーバー起動が確定した後に行う
  local ok, err = start_server(port)
  if not ok then
    notify(err or 'failed to start markdown preview server', vim.log.levels.ERROR)
    return
  end
  start_watch(vim.api.nvim_buf_get_name(source_buf))
  local url = server_url()
  open_with_default_browser(url)
  notify('Markdown preview URL: ' .. url)
end

function M.open()
  vim.ui.input({
    prompt = 'Markdown preview port: ',
  }, function(input)
    if input == nil then return end
    local port, err = parse_port(input)
    if not port then
      notify(err, vim.log.levels.ERROR)
      return
    end
    M.open_on_port(port)
  end)
end

function M.refresh(opts)
  opts = opts or {}
  local source_buf = state.source_buf
  if not source_buf or not vim.api.nvim_buf_is_valid(source_buf) then
    source_buf = vim.api.nvim_get_current_buf()
    state.source_buf = source_buf
  end
  update_preview_html(source_buf)
  start_watch(vim.api.nvim_buf_get_name(source_buf))
  if not opts.silent then
    local url = server_url()
    notify(url and ('Updated markdown preview: ' .. url) or 'Updated markdown preview')
  end
end

vim.api.nvim_create_autocmd('BufWritePost', {
  group = augrp,
  pattern = { '*.md', '*.markdown' },
  callback = function(ev)
    if state.source_buf == ev.buf and state.server then M.refresh({ silent = true }) end
  end,
})

vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
  group = augrp,
  callback = function(ev)
    if state.source_buf == ev.buf and state.server then stop_server() end
  end,
})

vim.api.nvim_create_autocmd('VimLeavePre', {
  group = augrp,
  callback = function()
    exiting = true
  end,
})

M._private = {
  build_opener_cmd = build_opener_cmd,
  build_toc = build_toc,
  document_html = document_html,
  find_opener = find_opener,
  http_response = http_response,
  inline_markdown = inline_markdown,
  markdown_to_body = markdown_to_body,
  asset_response = asset_response,
  preview_asset_url = preview_asset_url,
  response_for_path = response_for_path,
  vendor_file = vendor_file,
  vendor_response = vendor_response,
  server_url = server_url,
  state = state,
  parse_port = parse_port,
  start_server = start_server,
  stop_server = stop_server,
  start_watch = start_watch,
  stop_watch = stop_watch,
  refresh_preview_from_disk = refresh_preview_from_disk,
  slugify_heading = slugify_heading,
  url_decode = url_decode,
  url_encode_path = url_encode_path,
}

return M
