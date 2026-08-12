local T = dofile(TESTS_DIR .. '/helpers.lua')
local symbols = require('config.util.lsp_symbols')

local K = vim.lsp.protocol.SymbolKind

local function sym(name, kind, s_line, e_line, children)
  return {
    name = name,
    kind = kind,
    range = { start = { line = s_line, character = 0 }, ['end'] = { line = e_line, character = 0 } },
    children = children,
  }
end

local function names(chain)
  local out = {}
  for _, s in ipairs(chain) do out[#out + 1] = s.name end
  return out
end

T.describe('lsp_symbols.chain', function()
  T.it('returns the enclosing declarations from outermost to innermost', function()
    local list = {
      sym('Explorer', K.Class, 0, 49, {
        sym('render', K.Method, 9, 19),
        sym('close', K.Method, 24, 29),
      }),
    }
    T.eq(names(symbols.chain(list, 15)), { 'Explorer', 'render' },
      'the cursor inside a method should yield class then method')
    T.eq(names(symbols.chain(list, 27)), { 'Explorer', 'close' })
    T.eq(names(symbols.chain(list, 45)), { 'Explorer' },
      'inside the class but outside any method, only the class remains')
    T.eq(names(symbols.chain(list, 60)), {}, 'outside every symbol the chain is empty')
  end)

  T.it('reports 1-indexed start and end lines', function()
    local got = symbols.chain({ sym('run', K.Function, 4, 9) }, 6)
    T.eq(#got, 1)
    T.eq(got[1].lnum, 5, 'LSP の0始まりを1始まりに直して返す')
    T.eq(got[1].end_lnum, 10)
  end)

  T.it('carries the kind and its icon so callers can render them consistently', function()
    local got = symbols.chain({ sym('Explorer', K.Class, 0, 10) }, 5)[1]
    T.eq(got.kind, 'Class')
    T.eq(got.icon, symbols.ICONS.Class, 'アイコンは symbols.lua のピッカーと共有')
    T.eq(symbols.kind_group('Class'), 'Type', 'クラスは Type 系の色')
    T.eq(symbols.kind_group('Method'), 'Function')
    T.eq(symbols.kind_group('Module'), 'Include')
  end)

  T.it('keeps only declaration kinds, not variables or fields', function()
    -- Outline には出るが「今どの関数か」には邪魔なので載せない種別
    local list = {
      sym('config', K.Variable, 0, 20, { sym('timeout', K.Field, 3, 3) }),
      sym('setup', K.Function, 0, 20),
    }
    T.eq(names(symbols.chain(list, 4)), { 'setup' },
      'Variable / Field must be filtered out')
  end)

  T.it('drops control-flow entries that a server reports as symbols', function()
    -- lua-language-server は if / for / while を kind=Package で返してくる
    -- (explorer.lua 一枚で354個)。kind と名前の両方で弾く
    local list = {
      sym('walk', K.Function, 0, 40, {
        sym('if', K.Package, 5, 20, { sym('for', K.Package, 8, 12) }),
      }),
    }
    T.eq(names(symbols.chain(list, 10)), { 'walk' }, 'only the enclosing function should remain')

    -- kind を Function と偽って返された場合も名前で弾けること
    T.eq(names(symbols.chain({ sym('walk', K.Function, 0, 40, { sym('if', K.Function, 5, 20) }) }, 10)),
      { 'walk' })
  end)

  T.it('handles a flat SymbolInformation list (no children) in outer-to-inner order', function()
    local function flat(name, kind, s_line, e_line)
      return {
        name = name,
        kind = kind,
        location = { range = { start = { line = s_line, character = 0 }, ['end'] = { line = e_line, character = 0 } } },
      }
    end
    -- 平坦なリストは入れ子を表現しないので、範囲の広い順が親子順になる
    local list = { flat('inner', K.Function, 9, 19), flat('Outer', K.Class, 0, 49) }
    T.eq(names(symbols.chain(list, 12)), { 'Outer', 'inner' })
  end)

  T.it('strips the argument list some servers append to the symbol name', function()
    T.eq(names(symbols.chain({ sym('render(self, opts)', K.Function, 0, 10) }, 5)), { 'render' })
  end)

  T.it('keeps names that legitimately contain parentheses', function()
    -- gopls はメソッドをレシーバ付きの '(*Worker).Run' で返す。
    -- 最初の '(' から後ろを落とす実装だと名前が空になって丸ごと消えていた
    T.eq(names(symbols.chain({ sym('(*Worker).Run', K.Method, 18, 47) }, 25)), { '(*Worker).Run' })
    T.eq(names(symbols.chain({ sym('(Worker).Run(ctx)', K.Method, 18, 47) }, 25)), { '(Worker).Run' })
  end)

  T.it('is empty when the server returned nothing', function()
    T.eq(symbols.chain(nil, 1), {})
    T.eq(symbols.chain({}, 1), {})
  end)

  T.it('survives malformed entries without a range', function()
    local list = { { name = 'broken', kind = K.Function }, sym('ok', K.Function, 0, 10) }
    T.eq(names(symbols.chain(list, 5)), { 'ok' })
  end)
end)

T.describe('lsp_symbols.chain: markup', function()
  --- vscode-html-language-server が返す形（要素は名前 'div#id.class'、kind=Field）
  local function el(name, s_line, e_line, children)
    return sym(name, K.Field, s_line, e_line, children)
  end

  T.it('picks up elements only when markup is asked for', function()
    local list = { el('div#main.container', 0, 20, { el('table', 5, 15) }) }
    T.eq(names(symbols.chain(list, 10)), {},
      'markup でなければ Field は拾わない（他言語では変数・プロパティのノイズになる）')
    T.eq(names(symbols.chain(list, 10, { markup = true })), { 'div#main.container', 'table' })
  end)

  T.it('skips the structural tags that carry no information', function()
    -- VS Code でも html が常に貼り付くのは邪魔だと言われている(microsoft/vscode#163742)
    local list = {
      el('html', 0, 40, { el('body', 1, 39, { el('div#app', 5, 30) }) }),
    }
    T.eq(names(symbols.chain(list, 10, { markup = true })), { 'div#app' })
  end)

  T.it('still drops non-element kinds in markup files', function()
    local list = { sym('someVar', K.Variable, 0, 20), el('div', 0, 20) }
    T.eq(names(symbols.chain(list, 10, { markup = true })), { 'div' })
  end)

  T.it('treats html and friends as markup filetypes', function()
    local buf = vim.api.nvim_create_buf(false, false)
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = 'html'
    T.ok(symbols.is_markup(buf), 'html は markup')
    vim.bo[buf].filetype = 'lua'
    T.ok(not symbols.is_markup(buf), 'lua は markup ではない')
  end)
end)

T.describe('lsp_symbols cache', function()
  T.it('does not request symbols for a buffer without a language server', function()
    local buf = vim.api.nvim_create_buf(false, false)
    vim.bo[buf].swapfile = false
    T.eq(symbols.symbols_for(buf), nil, 'no LSP -> no symbols and no crash')
    T.eq(symbols.chain_at(buf, 1), {})
  end)
end)

T.summary()
