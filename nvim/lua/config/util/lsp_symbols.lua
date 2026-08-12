-- LSP の textDocument/documentSymbol を「カーソル行を囲む宣言の並び」として配る共有モジュール。
--
-- 使う側は winbar.lua（パンくず）と context.lua（スティッキーヘッダ）の 2 つ。
-- どちらも「今どの関数/クラスの中にいるか」が欲しいだけなので、取得とキャッシュを
-- ここに集約している。
--
-- なぜ treesitter ではなく LSP か:
--   ノード型名から推測すると if / for / block まで「スコープ」に見えてしまい、
--   何の中にいるのかがぼやける。documentSymbol は SymbolKind が付いて返るので
--   宣言だけを正確に選べる。VSCode の breadcrumbs / Sticky Scroll(既定 outlineModel)も
--   同じ DocumentSymbolProvider の結果を使っている。
--
-- リクエストは非同期。結果は changedtick 付きでバッファごとにキャッシュし、
-- カーソル移動のたびにやるのはキャッシュ済みリストの範囲判定だけにする。

local M = {}

-- パンくず/ヘッダに載せる SymbolKind。宣言だけに絞る。
-- Variable / Constant / Field / Property / Object などは Outline には出るが、
-- 「今どの関数の中か」を見たいこの用途ではノイズなので載せない。
-- Package を入れていないのは、lua-language-server が if / for / while を
-- kind=Package で返してくるため（explorer.lua 一枚で 354 個返ってきた）。
M.KINDS = {
  Class       = true,
  Interface   = true,
  Struct      = true,
  Enum        = true,
  Module      = true,
  Namespace   = true,
  Method      = true,
  Function    = true,
  Constructor = true,
}

-- 種別アイコン。symbols.lua（Space ss のピッカー）と同じ字形を使い、
-- パンくず・ヘッダ・ピッカーで見た目を揃える
M.ICONS = {
  File = '󰈙',
  Module = '󰏗',
  Namespace = '󰌗',
  Package = '󰏖',
  Class = '󰌗',
  Method = '󰆧',
  Property = '󰜢',
  Field = '󰜢',
  Constructor = '󰆧',
  Enum = '󰒻',
  Interface = '󰕘',
  Function = '󰊕',
  Variable = '',
  Constant = '',
  Struct = '󰌗',
}

-- 種別 -> 色の系統。アイコンだけ色を変えて種類を見分けられるようにする
local KIND_GROUP = {
  Class = 'Type', Interface = 'Type', Struct = 'Type', Enum = 'Type',
  Function = 'Function', Method = 'Function', Constructor = 'Function',
  Module = 'Include', Namespace = 'Include', Package = 'Include',
}

--- 種別に対応する色の系統（'Type' / 'Function' / 'Include' / 'Identifier'）
function M.kind_group(kind)
  return KIND_GROUP[kind] or 'Identifier'
end

-- マークアップ系の filetype。ここでは要素そのものが構造なので、通常は落としている
-- Field も採用する。vscode-html-language-server は要素を `div#id.class` という名前・
-- kind=Field で返してくる（VS Code の breadcrumbs もこれを出している）。
local MARKUP_FILETYPES = {
  html = true,
  xml = true,
  svg = true,
  vue = true,
  svelte = true,
  astro = true,
}

-- マークアップで貼っても情報量がないタグ。VS Code でも「html が常に出るのが邪魔」と
-- 苦情が出ている（microsoft/vscode#163742）ので最初から外す
local SKIP_TAGS = { html = true, head = true, body = true }

-- kind を間違えて返すサーバ向けの保険。名前がそのまま制御構文キーワードなら捨てる
local KEYWORD_NAMES = {
  ['if'] = true, ['else'] = true, ['elseif'] = true, ['for'] = true,
  ['while'] = true, ['repeat'] = true, ['do'] = true, ['switch'] = true,
  ['case'] = true, ['try'] = true, ['catch'] = true, ['finally'] = true,
  ['loop'] = true, ['match'] = true,
}

-- バッファ番号 -> { tick = changedtick, symbols = DocumentSymbol[]|SymbolInformation[] }
local cache = {}
-- バッファ番号 -> 実行中の debounce タイマー
local timers = {}
-- 新しい結果が届いたときに呼ぶ購読者（winbar / context）
local subscribers = {}

-- ══════════════════════════════════════════════
-- 解決（純粋関数。テストはここを直接叩く）
-- ══════════════════════════════════════════════

local KIND_NAMES = nil

--- SymbolKind（数値 or 文字列）を名前へ
function M.kind_name(kind)
  if type(kind) == 'string' then return kind end
  if not KIND_NAMES then
    KIND_NAMES = {}
    for name, value in pairs(vim.lsp.protocol.SymbolKind) do
      if type(value) == 'number' then KIND_NAMES[value] = name end
    end
  end
  return KIND_NAMES[kind]
end

--- DocumentSymbol / SymbolInformation のどちらでも範囲を取る
local function range_of(sym)
  return sym.range or (sym.location and sym.location.range)
end

--- row（0始まり）がその範囲に入っているか
local function contains(sym, row)
  local r = range_of(sym)
  if not r or not r.start or not r['end'] then return false end
  return r.start.line <= row and row <= r['end'].line
end

--- カーソル行を含む宣言を外側から順に並べる
---@param symbols table[]|nil documentSymbol の結果（階層でも平坦でも可）
---@param lnum integer 1始まりの行番号
---@param opts { markup: boolean }|nil markup=true で HTML 等の要素(kind=Field)も拾う
---@return { name: string, kind: string, icon: string, lnum: integer, end_lnum: integer }[] 外側から内側へ
--- 階層(DocumentSymbol)と平坦(SymbolInformation)を同じ規則で扱うため、木を全部たどって
--- 「行を含むもの」を集め、範囲の広い順に並べている。階層ならこれは親→子の並びと一致する。
function M.chain(symbols, lnum, opts)
  local row = lnum - 1
  local markup = opts and opts.markup or false
  local hits = {}

  --- その種別・名前をパンくずに載せるか
  local function wanted(sym)
    local kind = M.kind_name(sym.kind) or ''
    if KEYWORD_NAMES[sym.name] then return false end
    if markup and kind == 'Field' then
      -- 'div#main.container' の先頭のタグ名だけ見て判定する
      return not SKIP_TAGS[tostring(sym.name):match('^[%w:-]+') or '']
    end
    return M.KINDS[kind] == true
  end

  local function walk(list)
    for _, sym in ipairs(list or {}) do
      if type(sym) ~= 'table' then goto continue end
      if sym.name and contains(sym, row) then
        if wanted(sym) then
          hits[#hits + 1] = sym
        end
        walk(sym.children)
      elseif sym.children then
        -- 自分は含まないが子が含む、という並びは通常無い。念のため潜っておく
        walk(sym.children)
      end
      ::continue::
    end
  end
  walk(symbols)

  table.sort(hits, function(a, b)
    local ra, rb = range_of(a), range_of(b)
    local sa, sb = ra['end'].line - ra.start.line, rb['end'].line - rb.start.line
    if sa ~= sb then return sa > sb end
    return ra.start.line < rb.start.line
  end)

  local out = {}
  for _, sym in ipairs(hits) do
    local r = range_of(sym)
    local kind = M.kind_name(sym.kind) or 'Function'
    -- 'foo(a, b)' のように引数まで名前に入れて返す LSP があるので、末尾の括弧組だけ落とす。
    -- 最初の '(' から後ろを全部落とすと、gopls が返す '(*Worker).Run' のような
    -- 正当な名前まで消えてしまう（レシーバが先頭に括弧で付く）
    local name = tostring(sym.name)
    local trimmed = name:gsub('%s*%b()$', '')
    if trimmed ~= '' then name = trimmed end
    if name ~= '' then
      out[#out + 1] = {
        name     = name,
        kind     = kind,
        icon     = M.ICONS[kind] or '󰌋',
        lnum     = r.start.line + 1,
        end_lnum = r['end'].line + 1,
      }
    end
  end
  return out
end

-- ══════════════════════════════════════════════
-- 取得（非同期・changedtick でキャッシュ）
-- ══════════════════════════════════════════════

local function has_symbol_client(buf)
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
    if client:supports_method('textDocument/documentSymbol') then return true end
  end
  return false
end

--- 新しい結果が届いたら呼ばれる関数を登録する
function M.on_update(fn)
  subscribers[#subscribers + 1] = fn
end

--- documentSymbol を投げてキャッシュを更新する
function M.refresh(buf)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  if vim.bo[buf].buftype ~= '' then return end
  if not has_symbol_client(buf) then return end

  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local params = { textDocument = vim.lsp.util.make_text_document_params(buf) }
  vim.lsp.buf_request_all(buf, 'textDocument/documentSymbol', params, function(results)
    local raw = {}
    for _, res in pairs(results or {}) do
      if res.result then vim.list_extend(raw, res.result) end
    end
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(buf) then return end
      cache[buf] = { tick = tick, symbols = raw }
      for _, fn in ipairs(subscribers) do pcall(fn, buf) end
    end)
  end)
end

--- 編集が続いている間に投げ続けないよう debounce する。
--- 予約済みのタイマーは延長しない。延長すると、カーソルを動かし続けている間
--- 何度も先送りされて結局一度も飛ばない。
function M.schedule_refresh(buf, delay)
  if timers[buf] then return end
  timers[buf] = vim.defer_fn(function()
    timers[buf] = nil
    M.refresh(buf)
  end, delay or 150)
end

--- キャッシュ済みのシンボル。古くなっていたら裏で取り直す
function M.symbols_for(buf)
  local c = cache[buf]
  if not c then
    -- LSP が付いていないバッファでタイマーを作り続けないよう、ここで弾く
    if has_symbol_client(buf) then M.schedule_refresh(buf) end
    return nil
  end
  if c.tick ~= vim.api.nvim_buf_get_changedtick(buf) then
    -- 古い結果でも「今どの関数か」はだいたい合っているので、貼り替えるまでは使い続ける
    M.schedule_refresh(buf)
  end
  return c.symbols
end

--- そのバッファがマークアップ系か（要素そのものを構造として扱う filetype か）
function M.is_markup(buf)
  return MARKUP_FILETYPES[vim.bo[buf].filetype] == true
end

--- そのバッファのカーソル行を囲む宣言の並び
function M.chain_at(buf, lnum)
  return M.chain(M.symbols_for(buf), lnum, { markup = M.is_markup(buf) })
end

-- テスト用
M._markup_filetypes = MARKUP_FILETYPES

local grp = vim.api.nvim_create_augroup('user_lsp_symbols', { clear = true })

vim.api.nvim_create_autocmd({ 'LspAttach', 'BufWritePost', 'InsertLeave' }, {
  group = grp,
  callback = function(ev) M.schedule_refresh(ev.buf) end,
})

vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete' }, {
  group = grp,
  callback = function(ev)
    cache[ev.buf] = nil
    if timers[ev.buf] then timers[ev.buf]:stop(); timers[ev.buf] = nil end
  end,
})

-- テスト用
M._cache = cache

return M
