-- パス付きコードコピー: 選択コードをファイルパス(行番号付き)とともにクリップボードへ

local ft_to_lang = {
  typescript      = 'ts',
  javascript      = 'js',
  typescriptreact = 'tsx',
  javascriptreact = 'jsx',
  go              = 'go',
  python          = 'python',
  lua             = 'lua',
  sh              = 'sh',
  bash            = 'bash',
  json            = 'json',
  yaml            = 'yaml',
  toml            = 'toml',
  markdown        = 'md',
  html            = 'html',
  css             = 'css',
  rust            = 'rs',
  ruby            = 'rb',
}

local function rel_path_for(buf)
  local file = vim.api.nvim_buf_get_name(buf)
  if file == '' then return nil end

  local rel_path = file
  local root_out = vim.fn.systemlist('git rev-parse --show-toplevel 2>/dev/null')
  if vim.v.shell_error == 0 and #root_out > 0 then
    rel_path = file:sub(#root_out[1] + 2)
  end
  return rel_path
end

local function set_clipboard(text)
  vim.fn.setreg('"', text)
  if vim.g.clipboard ~= nil then
    vim.fn.setreg('+', text)
  end
end

local function location_text(start_line, end_line, col)
  local buf = vim.api.nvim_get_current_buf()
  local rel_path = rel_path_for(buf)

  if not rel_path then
    vim.notify('未保存のファイルです', vim.log.levels.WARN)
    return nil
  end

  local range = start_line == end_line
    and tostring(start_line)
    or  (tostring(start_line) .. '-' .. tostring(end_line))
  local suffix = col and col > 0 and (':' .. tostring(col)) or ''
  return rel_path .. ':' .. range .. suffix
end

local function copy_location(start_line, end_line, col)
  local location = location_text(start_line, end_line, col)
  if not location then return end
  set_clipboard(location)
  vim.notify('コピー: ' .. location, vim.log.levels.INFO)
end

local function copy_code_with_path(start_line, end_line)
  local buf  = vim.api.nvim_get_current_buf()
  local location = location_text(start_line, end_line)
  if not location then return end

  local code  = table.concat(vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false), '\n')
  local lang  = ft_to_lang[vim.bo[buf].filetype] or vim.bo[buf].filetype
  local result = location .. '\n```' .. lang .. '\n' .. code .. '\n```'

  set_clipboard(result)
  vim.notify('コピー: ' .. location, vim.log.levels.INFO)
end

vim.keymap.set('n', '<leader>y', function()
  local pos = vim.api.nvim_win_get_cursor(0)
  copy_location(pos[1], pos[1], pos[2] + 1)
end, { desc = '場所（相対パス:行:列）をコピー（現在行）' })

vim.keymap.set('v', '<leader>y', function()
  local s = vim.fn.line('v')
  local e = vim.fn.line('.')
  local c = vim.fn.col('v')
  if s > e then
    s, e = e, s
    c = vim.fn.col('.')
  end
  copy_location(s, e, c)
  vim.schedule(function()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
  end)
end, { desc = '場所（相対パス:行:列）をコピー（選択範囲）' })

vim.keymap.set('n', '<leader>Y', function()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  copy_code_with_path(line, line)
end, { desc = 'パス付きコードをコピー（現在行）' })

vim.keymap.set('v', '<leader>Y', function()
  local s = vim.fn.line('v')
  local e = vim.fn.line('.')
  if s > e then s, e = e, s end
  copy_code_with_path(s, e)
  vim.schedule(function()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
  end)
end, { desc = 'パス付きコードをコピー（選択範囲）' })
