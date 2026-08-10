-- HTTP クライアント用 picker: 汎用 picker (util.picker) に、メソッド別の色付けを足しただけ。
-- open/filter/move/confirm/close/state は util.picker のものをそのまま公開する。

local picker = require('config.util.picker')

-- メソッドごとに色を変えて一覧を見分けやすくする
local METHOD_HL = {
  GET = 'HttpPickerGet',
  HEAD = 'HttpPickerGet',
  OPTIONS = 'HttpPickerGet',
  POST = 'HttpPickerWrite',
  PUT = 'HttpPickerWrite',
  PATCH = 'HttpPickerWrite',
  DELETE = 'HttpPickerDelete',
}

function picker.method_hl(method)
  return METHOD_HL[(method or ''):upper()] or 'HttpPickerGet'
end

local function setup_hl()
  local function link(name, target)
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
  link('HttpPickerGet', 'DiagnosticOk')
  link('HttpPickerWrite', 'DiagnosticWarn')
  link('HttpPickerDelete', 'DiagnosticError')
end

setup_hl()
vim.api.nvim_create_autocmd('ColorScheme', {
  group = vim.api.nvim_create_augroup('http_picker_hl', { clear = true }),
  callback = setup_hl,
})

return picker
