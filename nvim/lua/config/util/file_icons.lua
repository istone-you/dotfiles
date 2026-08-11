-- ファイルアイコンの共通定義（Nerd Fonts）
--
-- explorer / git_panel / tabline がそれぞれ自前に持っていた拡張子→アイコンの
-- マッピングを一本化するモジュール。以前は3箇所に重複していて内容が食い違い、
-- 「explorerでyamlが出ない」「gitパネルでtfが出ない」等の抜けが発生していた。
-- 追加・変更はこのファイルだけで行うこと。

local M = {}

local function char(code) return vim.fn.nr2char(code) end

M.FOLDER  = 0xe5ff
M.DEFAULT = 0xf15b

-- 拡張子 → コードポイント
M.by_ext = {
  lua     = 0xe620,
  ts      = 0xe628,
  mts     = 0xe628,
  cts     = 0xe628,
  js      = 0xe74e,
  mjs     = 0xe74e,
  cjs     = 0xe74e,
  jsx     = 0xf0708,
  tsx     = 0xf0708,
  go      = 0xe65e,
  py      = 0xe606,
  pkl     = 0xf013,
  rs      = 0xe7a8,
  rb      = 0xe739,
  java    = 0xe738,
  kt      = 0xe634,
  swift   = 0xe755,
  html    = 0xe736,
  css     = 0xe749,
  scss    = 0xe603,
  json    = 0xe60b,
  jsonc   = 0xe60b,
  toml    = 0xe6b2,
  md      = 0xe73e,
  mdc     = 0xe73e,
  sh      = 0xe691,
  bash    = 0xe615,
  zsh     = 0xe615,
  zshrc   = 0xe615,
  vim     = 0xe62b,
  vimrc   = 0xe62b,
  shellcheckrc = 0xe691,
  cursorrules = 0xf0bf1,
  template = 0xf0613,
  txt     = 0xf15c,
  text    = 0xf15c,
  pdf     = 0xf0226,
  csv     = 0xeefc,
  -- 設定ファイル系はまとめて歯車（pkl と同じアイコン・同じ色になる）
  conf       = 0xf013,
  ini        = 0xf013,
  cfg        = 0xf013,
  properties = 0xf013,
  crt     = 0xf0124,
  rego    = 0xf0498,
  tf      = 0xe69a,
  tfvars  = 0xe69a,
  graphql = 0xe662,
  sql     = 0xe706,
  php     = 0xe73d,
  c       = 0xe61e,
  cpp     = 0xe61d,
  cs      = 0xe648,
  yaml    = 0xe6a8,
  yml     = 0xe6a8,
  xml     = 0xe619,
  png     = 0xe60d,
  jpeg    = 0xe60d,
  jpg     = 0xe60d,
  gif     = 0xf0d78,
  webp    = 0xe60d,
  avif    = 0xe60d,
  ico     = 0xe623,
  svg     = 0xe698,
  zip     = 0xe6aa,
  npmrc   = 0xe71e,
  hcl     = 0xf0c01,
  http    = 0xf0ac, -- fa-globe（.http / .rest のリクエストファイル）
  rest    = 0xf0ac,
  ghostty = 0xf165d, -- md-ghost-outline
}

-- 拡張子ではなくファイル名で判定する特殊ファイル
local SPECIAL = {
  dockerfile = 0xe650,
  gitignore  = 0xe65d,
  env        = 0xf462,
  lock       = 0xf023,
  vite       = 0xe8d7,
  sentry     = 0xe89f,
  yarn       = 0xe6a7,
  nodejs     = 0xf0399,
  readme     = 0xeda4,
  editorconfig = 0xe652,
  tsconfig     = 0xe69d,
  playwright   = 0xe863,
  claude       = 0xf0bf1,
  agents       = 0xf0beb,
  gomod        = 0xe65e,
  codeowners   = 0xf09b,
  license      = 0xf0fc3,
  githubactions = 0xe7e9, -- dev-githubactions
  vscode       = 0xe8da, -- dev-vscode
  codecov      = 0xe797, -- dev-codecov
  container    = 0xf4b7, -- oct-container
  coderabbit   = 0xf0907, -- md-rabbit
  wrangler     = 0xe792, -- dev-cloudflare
  ghostty      = 0xf165d, -- md-ghost-outline
  httpenv      = 0xf0ac, -- fa-globe（http-client.env.json）
}

-- ファイル名（+ ディレクトリか否か・任意でフルパス）からアイコンのコードポイントを返す
function M.code(name, isdir, path)
  if isdir then return M.FOLDER end
  local lower = name:lower()
  -- Docker（Dockerfile / .dockerignore / docker-compose.*.yml）
  if lower == 'dockerfile' or lower == '.dockerignore' then return SPECIAL.dockerfile end
  -- docker-compose.yml / docker-compose.yaml（および *.override.yml 等）は
  -- yaml ではなく Docker アイコンで表示する
  if lower:match('docker%-compose.*%.ya?ml$') then return SPECIAL.dockerfile end
  -- .github/workflows 配下の yaml/yml は GitHub Actions
  do
    local p = (path or ''):lower():gsub('\\', '/')
    if lower:match('%.ya?ml$') and (p:match('/%.github/workflows/') or p:match('^%.github/workflows/')) then
      return SPECIAL.githubactions
    end
    -- .vscode/settings.json は VS Code
    if lower == 'settings.json' and (p:match('/%.vscode/settings%.json$') or p:match('^%.vscode/settings%.json$')) then
      return SPECIAL.vscode
    end
    -- .devcontainer/devcontainer.json
    if lower == 'devcontainer.json' and (p:match('/%.devcontainer/devcontainer%.json$') or p:match('^%.devcontainer/devcontainer%.json$')) then
      return SPECIAL.container
    end
    -- ghostty の設定は拡張子が無くファイル名も config なので、ghostty/ 配下かで判定する
    if p:match('/ghostty/[^/]*$') or p:match('^ghostty/[^/]*$') then
      return SPECIAL.ghostty
    end
  end
  -- http-client.env.json / http-client.private.env.json（汎用 json / .env より優先）
  if lower:match('^http%-client%..*env%.json$') then return SPECIAL.httpenv end
  if lower == 'codecov.yml' or lower == '.codecov.yml' or lower == 'codecov.yaml' or lower == '.codecov.yaml' then
    return SPECIAL.codecov
  end
  if lower == '.coderabbit.yml' or lower == '.coderabbit.yaml' then
    return SPECIAL.coderabbit
  end
  if lower == 'wrangler.toml' or lower == 'wrangler.json' or lower == 'wrangler.jsonc' then
    return SPECIAL.wrangler
  end
  -- .gitignore / .gitattributes / .cursorignore は同じアイコン
  if lower:match('gitignore') or lower == '.gitattributes' or lower == '.cursorignore' then
    return SPECIAL.gitignore
  end
  -- vite.config.ts / .mts / .js など
  if lower:match('^vite%.config%.') then return SPECIAL.vite end
  if lower:match('^playwright%.config%.') then return SPECIAL.playwright end
  if lower:match('sentry%.properties$') then return SPECIAL.sentry end
  if lower == '.editorconfig' then return SPECIAL.editorconfig end
  -- tsconfig.json / tsconfig.app.json など（.jsonc は対象外）
  if lower:match('^tsconfig.*%.json$') then return SPECIAL.tsconfig end
  if lower == 'package.json' then return SPECIAL.nodejs end
  if lower == 'package-lock.json' then return SPECIAL.nodejs end
  if lower == 'claude.md' then return SPECIAL.claude end
  if lower == 'agents.md' then return SPECIAL.agents end
  if lower == 'go.mod' or lower == 'go.sum' or lower == 'go.work' or lower == 'go.work.sum' then
    return SPECIAL.gomod
  end
  if lower:match('^readme') then return SPECIAL.readme end
  if lower == 'yarn.lock' then return SPECIAL.yarn end
  if lower == 'codeowners' then return SPECIAL.codeowners end
  if lower == 'license' or lower == 'licence' then return SPECIAL.license end
  if lower:match('%.env') then return SPECIAL.env end
  if lower:match('%.lock$') then return SPECIAL.lock end
  local ext = name:match('%.([^%.]+)$')
  return (ext and M.by_ext[ext]) or M.DEFAULT
end

-- コードポイント → 文字
function M.char(code) return char(code) end

-- コードポイント → ブランドカラー（未定義はデフォルト文字色にフォールバック）
M.color_by_code = {
  [0xe620] = '#51a0cf',
  [0xe628] = '#519aba',
  [0xe74e] = '#cbcb41',
  [0xf0708] = '#61dafb',
  [0xe65e] = '#519aba',
  [0xe606] = '#ffbc03',
  [0xf013] = '#689f38',
  [0xe7a8] = '#dea584',
  [0xe739] = '#cc342d',
  [0xe738] = '#cc3e44',
  [0xe634] = '#a97bff',
  [0xe755] = '#f05138',
  [0xe736] = '#e34c26',
  [0xe749] = '#563d7c',
  [0xe603] = '#cd6799',
  [0xe60b] = '#cbcb41',
  [0xe6b2] = '#9c4221',
  [0xe73e] = '#dddddd',
  [0xe691] = '#89e051',
  [0xe615] = '#89e051',
  [0xe62b] = '#019833',
  [0xe69a] = '#7b42bc',
  [0xe662] = '#e535ab',
  [0xe706] = '#dad8d8',
  [0xe73d] = '#a074c4',
  [0xe61e] = '#599eff',
  [0xe61d] = '#f34b7d',
  [0xe648] = '#178600',
  [0xe6a8] = '#cb171e',
  [0xe619] = '#e37933',
  [0xe60d] = '#a074c4',
  [0xe623] = '#cbcb41',
  [0xf0d78] = '#00bfa5',
  [0xe698] = '#ffb13b',
  [0xe6aa] = '#eca517',
  [0xe71e] = '#cb3837',
  [0xf0c01] = '#eceff1',
  [0xe650] = '#2496ed',
  [0xe65d] = '#f54d27',
  [0xf462] = '#dfd545',
  [0xf023] = '#9c9c9c',
  [0xe8d7] = '#646cff',
  [0xe89f] = '#e1567c',
  [0xe6a7] = '#2c8ebb',
  [0xf0399] = '#8cc84b',
  [0xeda4] = '#519aba',
  [0xe652] = '#e0e0e0',
  [0xe69d] = '#519aba',
  [0xe863] = '#45ba4b',
  [0xf0bf1] = '#d97757',
  [0xf0beb] = '#a97bff',
  [0xf09b] = '#dddddd',
  [0xf0fc3] = '#e5c07b',
  [0xf15c] = '#6d8086',
  [0xf0226] = '#e5252a',
  [0xeefc] = '#89e051',
  [0xf0124] = '#e5c07b',
  [0xf0498] = '#5181b1',
  [0xf0613] = '#9c9c9c',
  [0xe7e9] = '#2088ff',
  [0xe8da] = '#007acc',
  [0xe797] = '#ec407a',
  [0xf4b7] = '#00b0ff',
  [0xf0907] = '#f4511e',
  [0xe792] = '#f57f17',
  [0xf0ac] = '#4db6ac',
  [0xf165d] = '#3551f3', -- ghostty.org の --brand-color
  [0xe5ff] = '#7aa2f7',
}

local COLOR_BY_NAME = {
  ['.cursorrules'] = '#dddddd',
  ['go.mod'] = '#ec407a',
  ['go.sum'] = '#ec407a',
  ['go.work'] = '#ec407a',
  ['go.work.sum'] = '#ec407a',
}

-- テストファイル（VSCode風にアイコンをオレンジにする）。path があればパス基準も判定。
M.TEST_COLOR = '#ff9e64'
function M.is_test_file(name, path)
  local l = name:lower()
  -- *.test./*.spec. + js,ts,jsx,tsx,mjs,cjs,mts,cts
  if l:match('%.test%.[cm]?[jt]sx?$') or l:match('%.spec%.[cm]?[jt]sx?$') then return true end
  if l:match('%.e2e%.ts$') then return true end -- *.e2e.ts
  if l:match('_test%.go$') then return true end -- *_test.go
  -- Rust: tests/ 配下（統合テストの慣習）
  local p = (path or ''):lower()
  if p:match('/tests/[^/]+%.rs$') or p:match('^tests/[^/]+%.rs$') then return true end
  return false
end

-- ファイル名（+ ディレクトリか否か・任意でフルパス）からブランドカラーを返す
function M.color(name, isdir, path)
  if not isdir and M.is_test_file(name, path) then return M.TEST_COLOR end
  if not isdir then
    local by_name = COLOR_BY_NAME[name:lower()]
    if by_name then return by_name end
  end
  return M.color_by_code[M.code(name, isdir, path)]
end

local hl_defined = {}

-- アイコンの色に対応するハイライトグループ名を返す（無ければnil）。
-- グループは遅延生成し、ColorScheme変更時に作り直す。
function M.icon_hl(name, isdir, path)
  local hex = M.color(name, isdir, path)
  if not hex then return nil end
  local grp = 'FileIcon_' .. hex:sub(2)
  if not hl_defined[grp] then
    vim.api.nvim_set_hl(0, grp, { fg = hex, default = true })
    hl_defined[grp] = true
  end
  return grp
end

vim.api.nvim_create_autocmd('ColorScheme', {
  callback = function() hl_defined = {} end,
})

-- ファイル名（+ ディレクトリか否か・任意でフルパス）からアイコン文字を返す
function M.get(name, isdir, path)
  return char(M.code(name, isdir, path))
end

return M
