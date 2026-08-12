local M = {}

local win       = nil
local buf       = nil
local hl_ns     = vim.api.nvim_create_namespace('shortcuts_hl')
local augrp     = vim.api.nvim_create_augroup('shortcuts', { clear = true })
local query     = ''

-- ══════════════════════════════════════════════
-- データ定義
-- ══════════════════════════════════════════════

local SECTIONS = {
  { header = '🧭 移動（ノーマル）', color = 'ShortcutsNormal', rows = {
    { 'h j k l',         '左・下・上・右' },
    { 'w / W',           '次の単語の先頭へ' },
    { 'b / B',           '前の単語の先頭へ' },
    { 'e / E',           '次の単語の末尾へ' },
    { 'ge / gE',         '前の単語の末尾へ' },
    { '0 / ^ / $',       '行頭(列0) / 非空白 / 行末' },
    { 'g_',              '行末の非空白文字へ' },
    { '+ / -',           '次 / 前の行の非空白へ' },
    { '{N}|',            'N列目へ' },
    { 'gg / G',          'ファイル先頭 / 末尾' },
    { '{N}G',            'N行目へジャンプ' },
    { '{ / }',           '前 / 次の段落へ' },
    { '( / )',           '前 / 次の文へ' },
    { '[[ / ]]',         '前 / 次のセクションへ' },
    { '%',               '対応する括弧へ' },
    { '[( / [{',         '囲っている開き括弧へ' },
    { ']) / ]}',         '囲っている閉じ括弧へ' },
    { 'gj / gk',         '折り返し表示行で下 / 上へ' },
    { 'g0 / g^ / g$',    '表示行の行頭 / 非空白 / 行末' },
    { 'Ctrl-e / Ctrl-y', '1行下 / 上へスクロール' },
    { 'Ctrl-d / Ctrl-u', '半画面下 / 上' },
    { 'Ctrl-f / Ctrl-b', '1画面下 / 上' },
    { 'zz / zt / zb',    '現在行を中央/上部/下部に' },
    { 'H / M / L',       '画面上部・中央・下部へ' },
    { "'.",              '最後の変更行へ' },
    { '``',              '直前のカーソル位置へ' },
    { 'gi',              '最後にインサートした位置へ' },
  }},
  { header = '✏️  編集（ノーマル）', color = 'ShortcutsNormal', rows = {
    { 'x / X',           'カーソル下/前の文字を削除' },
    { 'dd / D',          '行削除 / 行末まで削除' },
    { 'yy / Y',          '行をヤンク' },
    { 'p / P',           'カーソル後/前にペースト' },
    { 'gp / gP',         'ペースト後カーソルを末尾へ' },
    { ']p',              'インデントを合わせてペースト' },
    { 'u / Ctrl-r',      'アンドゥ / リドゥ' },
    { 'g- / g+',         'アンドゥ履歴を時系列で前 / 次へ' },
    { ':earlier / :later', '時間・回数を指定してアンドゥ/リドゥ' },
    { '.',               '直前の変更を繰り返す' },
    { 'r{c} / R',        '1文字置換 / 置換モード' },
    { '~ / gu / gU',     '大小切替 / 小文字 / 大文字' },
    { 'g~~ / guu / gUU', '行全体を 大小切替 / 小 / 大' },
    { 'J / gJ',          '次の行を結合（gJ は空白を入れない）' },
    { 'cc / C / s / S',  '行/行末/1文字/行 削除→挿入' },
    { '>> / <<',         'インデント増やす/減らす' },
    { '==',              '行を自動インデント' },
    { 'gq{motion} / gw', 'textwidth で整形（gw はカーソル維持）' },
    { 'Ctrl-a / Ctrl-x', 'カーソル下の数値を増やす / 減らす' },
    { '& / g&',          '直前の :s を この行 / 全行 に繰り返す' },
    { 'gcc',             '現在行をコメントトグル' },
  }},
  { header = '📝 インサートモード', color = 'ShortcutsInsert', rows = {
    { 'i / I',           'カーソル前 / 行先頭から挿入' },
    { 'gI',              '列0から挿入（本設定では Peek に割当て）' },
    { 'a / A',           'カーソル後 / 行末から挿入' },
    { 'o / O',           '下 / 上に新規行を作り挿入' },
    { 'Esc / Ctrl-[',    'ノーマルモードへ戻る' },
    { 'Ctrl-w',          '直前の単語を削除' },
    { 'Ctrl-u',          '行先頭まで削除' },
    { 'Ctrl-t / Ctrl-d', 'インデントを増やす / 減らす' },
    { 'Ctrl-n / Ctrl-p', '補完候補を次/前へ' },
    { 'Ctrl-r{reg}',     'レジスタの内容を挿入' },
    { 'Ctrl-o{cmd}',     'ノーマルコマンドを1回実行' },
    { 'Ctrl-v{code}',    '文字コードを直接入力' },
    { 'Ctrl-k{c}{c}',    'ダイグラフで特殊文字を入力' },
    { 'Ctrl-a',          '直前に挿入したテキストを再挿入' },
  }},
  { header = '🔷 ビジュアルモード', color = 'ShortcutsVisual', rows = {
    { 'v / V / Ctrl-v',  '文字 / 行 / 矩形 選択' },
    { 'gv',              '前回の選択を再選択' },
    { 'o / O',           '選択範囲の反対端 / 反対角へ' },
    { 'd / y / c / p',   '削除/コピー/変更/ペースト' },
    { '> / <',           'インデント増やす/減らす' },
    { '~ / u / U',       '大小切替 / 小文字 / 大文字' },
    { 'I / A',           '矩形選択の各行先頭/末尾へ挿入' },
    { '$',               '矩形選択を各行の行末まで伸ばす' },
    { 'r{c}',            '選択範囲を{c}で埋める' },
    { 'g Ctrl-a',        '選択範囲の数値を連番にする' },
    { 'gc',              '選択範囲をコメントトグル' },
  }},
  { header = '📦 テキストオブジェクト', color = 'ShortcutsText', rows = {
    { 'iw / aw',         '単語の内側 / 外側' },
    { 'iW / aW',         'WORD の内側 / 外側' },
    { 'is / as',         '文の内側 / 外側' },
    { 'ip / ap',         '段落の内側 / 外側' },
    { 'i( / a(',         '() の内側 / 外側' },
    { 'i[ / a[',         '[] の内側 / 外側' },
    { 'i{ / a{',         '{} の内側 / 外側' },
    { 'i< / a<',         '<> の内側 / 外側' },
    { 'i" / a"',         '"" の内側 / 外側' },
    { "i' / a'",         "'' の内側 / 外側" },
    { 'i` / a`',         '`` の内側 / 外側' },
    { 'it / at',         'HTMLタグの内側 / 外側' },
  }},
  { header = '🔍 検索', color = 'ShortcutsSearch', rows = {
    { '/pattern',        '前方検索' },
    { '?pattern',        '後方検索' },
    { 'n / N',           '次 / 前のマッチへ' },
    { '* / #',           'カーソル下の単語を前/後方検索' },
    { 'g* / g#',         '* / # の部分一致版' },
    { 'gn / gN',         '次 / 前のマッチを選択（. と組むと強力）' },
    { ':noh',            'ハイライトを消去' },
    { 'f{c} / F{c}',     '行内を{c}で前/後方検索' },
    { 't{c} / T{c}',     '{c}の1文字前/後ろへ移動' },
    { '; / ,',           'f/t を繰り返す / 逆方向に' },
    { 'q/ / q?',         '検索履歴をウィンドウで開いて編集' },
  }},
  { header = '🪟 ウィンドウ操作', color = 'ShortcutsWindow', rows = {
    { 'Ctrl-w s / v',    '水平 / 垂直分割' },
    { 'Ctrl-w w / W',    '次 / 前のウィンドウへ' },
    { 'Ctrl-w h/j/k/l',  '左/下/上/右のウィンドウへ' },
    { 'Ctrl-w H/J/K/L',  'ウィンドウを端へ移動' },
    { 'Ctrl-w r',        'ウィンドウを回転' },
    { 'Ctrl-w q / o',    'ウィンドウを閉じる / 他を閉じる' },
    { 'Ctrl-w =',        'すべてのウィンドウを均等に' },
    { 'Ctrl-w +/- >/<',  '高さ増減 / 幅増減' },
    { 'Ctrl-w T',        'ウィンドウを新規タブに移動' },
  }},
  { header = '📑 タブ・バッファ', color = 'ShortcutsBuffer', rows = {
    { ':tabnew / :tabc', '新規タブ / タブを閉じる' },
    { 'gt / gT',         '次 / 前のタブへ' },
    { '{N}gt',           'N番目のタブへ' },
    { ':bn / :bp / :bd', '次/前のバッファ / 削除' },
    { ':ls',             'バッファ一覧を表示' },
    { 'Ctrl-^',          '直前のバッファへ切り替え' },
  }},
  { header = '💻 コマンドラインモード', color = 'ShortcutsCommand', rows = {
    { ':',               'コマンドラインモードへ' },
    { ':w / :w!',        '保存 / 強制保存' },
    { ':q / :q!',        '終了 / 強制終了' },
    { ':wq / :x',        '保存して終了' },
    { ':e {file} / :e!', 'ファイルを開く / 再読み込み' },
    { ':%s/old/new/gc',  '確認しながら置換' },
    { ':%s//new/g',      '直前の検索結果をそのまま置換' },
    { ':sort / :sort u', '行をソート / 重複を除いてソート' },
    { ':! {cmd}',        'シェルコマンドを実行' },
    { 'Ctrl-p / Ctrl-n', 'コマンド履歴を前 / 次へ' },
    { 'q:',              'コマンド履歴をウィンドウで開いて編集' },
    { 'Ctrl-f',          '入力中にコマンドライン窓へ切り替え' },
  }},
  { header = '📌 マーク・ジャンプ', color = 'ShortcutsSearch', rows = {
    { 'm{a-z} / m{A-Z}', 'ローカル / グローバルマーク' },
    { "'{mark}",         'マークの行先頭へジャンプ' },
    { '`{mark}',         'マークの正確な位置へジャンプ' },
    { ':marks',          'マーク一覧を表示' },
    { 'Ctrl-o / Ctrl-i', 'ジャンプリストを前 / 次へ（Ctrl-i は端末上 Tab と同一コードのため、本設定では効かないことがある）' },
    { ':jumps',          'ジャンプリストを表示' },
    { 'g; / g,',         '変更リストを前 / 次へ' },
  }},
  { header = '🔗 ファイル・タグジャンプ', color = 'ShortcutsSearch', rows = {
    { 'gf',              'カーソル下のパスのファイルを開く' },
    { 'gF',              '同上（path:12 の行番号も反映）' },
    { 'Ctrl-w f',        'カーソル下のファイルを分割して開く' },
    { 'Ctrl-w gf',       'カーソル下のファイルを新規タブで開く' },
    { 'gx',              'カーソル下のURL・パスをOSの既定アプリで開く' },
    { 'Ctrl-] / Ctrl-t', 'タグへジャンプ / 戻る（:help 内の移動に使う）' },
    { 'Ctrl-w ]',        'タグを分割して開く' },
  }},
  { header = '⚙️  マクロ・レジスタ', color = 'ShortcutsMacro', rows = {
    { 'q{a-z} → q',      'マクロの記録 開始 / 終了' },
    { '@{a-z} / @@',     'マクロを実行 / 直前を再実行' },
    { '{N}@{a-z}',       'マクロをN回実行' },
    { '"{reg}y / "{reg}p', '指定レジスタにヤンク / ペースト' },
    { '"+y / "+p',       'クリップボードにコピー / ペースト' },
    { '"0p',             'ヤンク専用レジスタからペースト' },
    { ':reg',            'レジスタ一覧を表示' },
  }},
  { header = '🗂️  折りたたみ', color = 'ShortcutsMisc', rows = {
    { 'zf{motion}',      'フォールドを作成' },
    { 'zo / zO',         '開く / カーソル下を再帰的に開く' },
    { 'zc / zC',         '閉じる / カーソル下を再帰的に閉じる' },
    { 'za / zA',         'トグル / 再帰的にトグル' },
    { 'zR / zM',         'ファイル全体を すべて開く / すべて閉じる' },
    { 'zr / zm',         '全体を1段階 開く / 閉じる' },
    { 'zj / zk',         '次 / 前のフォールドへ' },
    { 'zd / zE',         'フォールドを削除 / すべて削除' },
  }},
  { header = '📋 quickfix / location list', color = 'ShortcutsMisc', rows = {
    { ':copen / :cclose', 'quickfixを開く / 閉じる' },
    { ':cnext / :cprev', '次 / 前の項目へ' },
    { ':cfirst / :clast', '最初 / 最後の項目へ' },
    { ':cdo {cmd}',      '全項目に対してコマンドを実行' },
    { ':vimgrep /pat/ **', '再帰検索してquickfixへ入れる' },
    { ':lopen / :lnext', 'location list版（ウィンドウ単位）' },
  }},
  { header = '🔀 diffモード', color = 'ShortcutsMisc', rows = {
    { ':diffthis',       'このウィンドウをdiff対象にする' },
    { ':diffoff',        'diffモードを解除' },
    { '] c / [ c',       '次 / 前の差分へ' },
    { 'do / dp',         '差分を取り込む / 相手に反映' },
    { ':diffupdate',     '差分を再計算' },
  }},
  { header = '🔤 スペルチェック', color = 'ShortcutsMisc', rows = {
    { ':set spell',      '有効化（:set nospell で解除）' },
    { '] s / [ s',       '次 / 前のスペルミスへ' },
    { 'z=',              '修正候補を表示' },
    { 'zg / zw',         '正しい単語 / 誤りとして辞書登録' },
    { 'zug / zuw',       'zg / zw の登録を取り消す' },
  }},
  { header = '🛠️  その他・便利コマンド', color = 'ShortcutsMisc', rows = {
    { 'ZZ / ZQ',         '保存して終了 / 保存せず終了' },
    { 'K',               'man で調べる（LSP接続時はホバーに上書き）' },
    { 'ga',              'カーソル下の文字コードを表示' },
    { 'Ctrl-g',          'ファイル名と現在位置を表示' },
    { 'g Ctrl-g',        '文字数・単語数・行数を表示' },
    { ':help {topic}',   'ヘルプを開く' },
    { ':checkhealth',    'Neovimの健全性チェック' },
    { ':set {opt}?',     'オプションの現在値を確認' },
    { ':verbose map {k}', 'そのキーの定義元を調べる' },
  }},
  { header = '🔧 カスタムキーマップ', color = 'ShortcutsBuffer', rows = {
    { 'Space t',         'ターミナルを右に開く' },
    { 'Ctrl-h/j/k/l',    '通常: 左 / 下 / 上 / 右のウィンドウへ移動（ターミナルモードは Ctrl-h/j のみ）' },
    { 'Space e',         'explorerを開閉（右パネル、詳細は下のセクション）' },
    { 'Space g',         'gitパネルを開閉（自作、詳細は下のセクション）' },
    { 'Space d',         'dockerパネルを開閉（自作、詳細は下のセクション）' },
    { 'Space P',         'ポートパネルを開閉（自作、詳細は下のセクション）' },
    { 'Space R',         '差分レビューをブラウザで開く' },
    { 'Space B',         'Code Notesをブラウザで開く' },
    { 'Tab / Shift-Tab', '次 / 前のバッファへ' },
    { 'Space q',         '現在のバッファを閉じる（未保存なら s: 保存して閉じる / d: 破棄して閉じる / n・Esc: キャンセル）' },
    { 'Space Q',         'タブラインに出ているバッファをすべて閉じる（未保存なら s: 保存して閉じる / d: 破棄して閉じる / n・Esc: キャンセル）' },
    { ':q / :qa 等',     '通常の終了コマンド。Neovimを閉じる直前に確認が入る（:q! など ! 付きは確認なしで即終了）' },
    { 'g d / g r',       'Peek: 定義元 / 参照元' },
    { 'g y / g I',       'Peek: 型定義 / 実装' },
    { 'K',               'LSP: ホバードキュメント' },
    { 'Space r n',       'LSP: リネーム' },
    { 'Space c a',       'LSP: コードアクション' },
    { 'Space f',         'LSP: フォーマット' },
    { '[d / ]d',         'LSP: 前 / 次の診断へ' },
    { 'Space E',         'LSP: 診断の詳細を表示' },
    { 'Space p',         '問題パネルを開閉（全ファイルの診断一覧、詳細は下のセクション）' },
    { 'Space T',         'TODOツリーを右サイドバーで開閉（TODO/FIXME/BUG等の一覧、詳細は下のセクション）' },
    { ']t / [t',         '現在ファイルの次 / 前のTODOへ' },
    { 'Space k',         'LSP: シグネチャヘルプ（引数ヒント）を表示' },
    { 'Ctrl-s',          'LSP: シグネチャヘルプ（インサートモード。( や , で自動表示）' },
    { '補完 Tab/S-Tab',  '補完メニュー表示中: 次 / 前の候補へ' },
    { '補完 Enter',      '補完メニュー表示中: 選択中の候補を確定' },
    { '補完 Ctrl-n',     '補完メニューを手動で出す（インサートモード）' },
    { '補完 Ctrl-e',     '補完メニューを閉じる' },
    { 'Space s s',       'Symbols: ファイル内シンボルを開く' },
    { 'Symbols j/k',     'Symbols(リスト内): 次 / 前の候補へ（↓/↑、Ctrl-n/pでも移動）' },
    { 'Symbols Enter/Esc', 'Symbols(ポップアップ内): 選択位置へジャンプ / 閉じる（Ctrl-cでも閉じる）' },
    { 'Space /',         'search: 内容検索。置換 / include / exclude の欄が下に並ぶ（ファイル名検索は explorer の /）' },
    { 'Space *',         'search: カーソル単語で内容検索' },
    { '検索 Tab/S-Tab',  'search: fzf → 置換 → include → exclude を順に移動（Shift-Tab で逆順）' },
    { '検索 Enter',      'search: マッチした行のファイルを開く（置換ではない）' },
    { '検索 Ctrl-t',     'search: 置換対象の行を複数選択（Tab は欄移動に使うため Ctrl-t）' },
    { '検索 Ctrl-s',     'search: 選択中（未選択ならカーソル行）のファイルを置換。置換欄が空なら何も起きない' },
    { '検索 Ctrl-x',     'search: マッチした全ファイルを置換（確認なし）。置換欄が空なら何も起きない' },
    { '検索 Ctrl-r',     'search: 置換欄の表示トグル。隠すと置換キーは効かなくなる' },
    { '検索 Ctrl-g',     'search: include/exclude 欄をまとめて表示トグル。隠すと絞り込みも効かなくなる' },
    { '検索 Esc',        'search: insert を抜ける（クリックで欄を選べる）。ノーマルでもう一度 Esc で閉じる' },
    { '検索 include/exclude', 'search: カンマ区切りのグロブで絞り込み（裸の名前は **/名前/** に展開）' },
    { 'Space o',         'HTML / MarkdownをローカルHTTPサーバで開く' },
    { 'Space m',         'メモ帳（notes/ を本文検索。空で一覧、Enterで開く、Ctrl-nで新規。内容はローカル永続）' },
    { 'Space a c/x/a',   'herdr: 右ペインで claude/codex/agent を開く（右にエージェントがいれば再利用、無ければ右に開いて起動）。選択中は選択範囲の場所を入力欄へ挿入' },
    { 'Space a p',       'herdr: 起動中のエージェントを一覧から選ぶ（ノーマル=選んでフォーカス / 選択中=選択範囲の場所をそのエージェントへ挿入）' },
    { 'Space h r',       '.httpファイル: カーソル位置のリクエストを実行（詳細は下のセクション）' },
    { 'Space G',         'GitHubパーマリンクをコピー' },
    { 'Space x c/i/b',   'コンフリクト: 現在/入力側/両方を採用（大文字でファイル全体、詳細は下のセクション）' },
    { 'Space y',         'Code Notes用locationをコピー' },
    { 'Space Y',         'パス付きコードをコピー' },
    { 'Space A',         'ファイル全体をコピー' },
    { '( [ { " \' `',    'autopairs: 閉じを自動補完 / 閉じの上でスキップ / 空ペアで BS 両削除 / 括弧内 <CR> でインデント展開' },
    { 'Space s ( ) [ ] { } " \' `', 'surround: 単語(iw)/選択を囲む・再度で外す（トグル。開き括弧キー ( [ { はスペース付き）' },
    { 'Space ?',         'このショートカット一覧を開閉' },
  }},
  { header = '🩺 問題パネル（Space p で開閉）', color = 'ShortcutsBuffer', rows = {
    { 'j / k',           'カーソルを下 / 上へ（ヘッダやファイル見出しは飛ばして診断行だけを移動）' },
    { 'Enter / o',       'その診断の位置へジャンプ（パネルは開いたまま）' },
    { 'f',               'フィルタ切替（すべて → エラー+警告 → エラーのみ）' },
    { 'R',               '一覧を再取得' },
    { 'a',               'カーソル行の診断を herdr エージェントへ送る（送り先は picker）' },
    { 'A',               'カーソル行と同じファイルの診断（現フィルタ）をまとめて送る' },
    { 'gA',              '現フィルタで見えている診断をすべて送る' },
    { 'q / Esc',         '閉じる' },
  }},
  { header = '✅ TODOツリー（Space T で右サイドバー開閉）', color = 'ShortcutsBuffer', rows = {
    { 'j / k',           'カーソルを下 / 上へ（見出しは飛ばしてTODO行だけを移動）' },
    { 'Enter / Space / l','ファイル/タグを展開。TODO行では Enter/o でジャンプ' },
    { 'h',               'ファイル/タグを折り畳み' },
    { 'E / W',           'すべて展開 / すべて折り畳み' },
    { 'm',               '表示切替（tree → flat → tags）' },
    { 'f',               'タグ種別のチェックボックスpopup（Spaceで切替、a全選択、c全解除、Enter適用）' },
    { '/',               'パス / タグ / 本文でフィルタ' },
    { 'BS',              'フィルタ解除' },
    { 'R',               'workspace を再スキャン' },
    { 'q / Esc',         '閉じる' },
    { 'エディタ内 ]t/[t','現在ファイルの次 / 前のTODOへ' },
  }},
  { header = '🔀 コンフリクト解消（衝突マーカーのあるファイル内）', color = 'ShortcutsBuffer', rows = {
    { 'Space x c',       '現在の変更（HEAD側）を採用' },
    { 'Space x i',       '入力側の変更（取り込む側）を採用' },
    { 'Space x b',       '両方を採用（現在→入力側の順に残す）' },
    { 'Space x C/I/B',   'ファイル内すべての衝突を 現在/入力側/両方 で解消' },
    { 'Space x d',       '現在の変更と入力側を別タブでdiff比較（qで閉じる）' },
    { ']x / [x',         '次 / 前の衝突へ（端で回り込む）' },
    { 'gitパネル m',     'Filesパネル: 解消メニュー（ours/theirs一括・エディタで開く・続行・中断）' },
  }},
  { header = '🌐 .http リクエスト（.http / .rest ファイル内）', color = 'ShortcutsBuffer', rows = {
    { 'Space h r',       'カーソル位置のリクエストを実行（結果は右に縦分割で表示）' },
    { 'Space h e',       '環境を選択（http-client.env.json）。ポップアップで選ぶ' },
    { 'Space h j',       'ファイル内のリクエスト一覧からジャンプ（ポップアップ）' },
    { '一覧 Ctrl-j/k',   'リクエスト/環境の一覧: 次 / 前の候補へ（↓/↑も可。入力で絞り込み）' },
    { '一覧 Enter/Esc',  'リクエスト/環境の一覧: 決定 / 閉じる（Ctrl-cでも閉じる）' },
    { 'Space h c',       'カーソル位置のリクエストをcurlコマンドとしてコピー' },
    { ']] / [[',         '次 / 前のリクエストへ' },
    { ':HttpRun 等',     'コマンド版（:HttpRun / :HttpEnv / :HttpList）' },
    { 'レスポンス内 q',  'レスポンスパネルを閉じる' },
    { 'レスポンス内 R',  '直前のリクエストを再実行' },
    { 'レスポンス内 y',  'レスポンスボディをコピー' },
  }},
  { header = '🗂️  explorer（Space e で開閉）', color = 'ShortcutsBuffer', rows = {
    { 'j / k',           'カーソルを下 / 上へ' },
    { 'l / →',           'ディレクトリへ入る（ファイルには無反応）' },
    { 'h / ←',           '親ディレクトリへ（元の位置にカーソル復帰）' },
    { 'Enter',           'ディレクトリへ入る / ファイルを開く' },
    { 'o',               'カーソル上の HTML / Markdown をブラウザプレビューで開く' },
    { '.',               '隠しファイルの表示トグル' },
    { 'i',               'git管理外（.gitignore された node_modules / dist 等・.git 自体も含む）の表示トグル' },
    { 't',               'リスト表示 / 折りたたみツリー表示を切替' },
    { 'c',               'ツリー表示: 子がディレクトリ1つだけの連鎖を "a/b/c" と1行へ圧縮する表示を切替' },
    { 'F',               '現在エディタで開いているファイルへ移動（リスト / ツリー両対応）' },
    { 'E / W',           'ツリー表示: すべて展開 / すべて閉じる' },
    { 'R',               '一覧を再読み込み' },
    { 'Tab / S-Tab',     '選択トグル（複数選択可）＋1つ下/上へ' },
    { 'Ctrl-a / Ctrl-r', 'すべて選択 / 選択を反転' },
    { 'Esc',             '選択解除→フィルタ解除→（どちらも無ければ）閉じる' },
    { 'a',               'ファイル/ディレクトリを作成（末尾/でディレクトリ）' },
    { 'r',               '名前を変更' },
    { 'd / D',           'ゴミ箱へ移動 / 完全削除（複数選択可）' },
    { 'X',               '現在フォルダ配下の空ディレクトリをすべて削除（確認あり）' },
    { 'Ctrl-y / Ctrl-x', 'コピー / カットをクリップボードにセット' },
    { 'Ctrl-p / Ctrl-S-p', '貼り付け（衝突時リネーム） / 上書き貼り付け' },
    { 'y / Y',           'ファイル名 / 絶対パスをコピー' },
    { 'f',               '現在フォルダ内をファイル名でインクリメンタル絞り込み（Escでクリア）' },
    { '/',               'fdで再帰ファイル名検索（インクリメンタル・list/tree表示に追従・C-j/C-kで移動・Enterで開く・Escで解除）' },
    { 'v',               'プレビューの表示トグル（エディタ上に浮かべる。Enterで開くと閉じる。全画面は常時右に表示）' },
    { '< / >',           'サイドバーを左 / 右へ移動（位置は以降も維持）' },
    { 'q',               'explorerを閉じる' },
  }},
  { header = '🌱 gitパネル（Space g で開閉、1-6/←→/タブクリックでパネル切替）', color = 'ShortcutsBuffer', rows = {
    { '1-6',             'Files / Commits / Branches / Stash / Worktree / PR へ切替' },
    { '← / →',           '前後のパネルへ切替（タブバーはクリックでも切替可）' },
    { 'P / p',           'push / pull（どのパネルでも共通）' },
    { 'R',               '現在のパネルを再取得' },
    { 'z',               '直前のコミットを取り消す（soft reset、確認あり）' },
    { 'v',               'delta side-by-side表示をトグル（deltaがある場合）' },
    { '@',               'コマンドログを画面いっぱいに拡大 / 再度で元に戻す（拡大中は内容をビジュアル選択やマウスドラッグで選択→ヤンクでコピー可）' },
    { '+',               'Diffを拡大して全体diffストリームを表示 / 再度で元に戻す（@と排他、ファイルツリーは既定OFF）' },
    { '拡大中 t',        '左の変更ファイルツリーを表示 / 非表示' },
    { 'ツリー表示中 j / k','左の変更ファイルツリーで選択を下 / 上へ移動し、右の該当ファイルdiffへスクロール' },
    { 'q / Esc',         '閉じる（Filesで選択中ならEscは選択解除優先）' },
    { '[Files] Tab/S-Tab','選択トグル（複数選択可）＋1つ下/上へ' },
    { '[Files] C-a/C-r', '全選択 / 選択反転' },
    { '[Files] t',       'ツリー表示 / VSCode風のフラット一覧（Merge/Staged/Changes のセクション別）を切替' },
    { '[Files] Space',   'ステージ / アンステージ（ディレクトリ・セクション行は配下全て、複数選択可）' },
    { '[Files] Enter',   'ディレクトリ・セクションの折り畳み / ファイルはhunkステージへ' },
    { '[Files] a',       '全ステージ / 全アンステージ切替' },
    { '[Files] c / w',   'コミット / フックなしコミット' },
    { '[Files] A',       '直前コミットをamend（ステージ済み変更で）' },
    { '[Files] d',       '破棄メニュー（x: すべての変更を破棄 / u: 未ステージのみ破棄、複数選択可）' },
    { '[Files] s',       '全変更をスタッシュ' },
    { '[Files] S',       'スタッシュオプション（a:全て / u:未追跡含む / t:ステージ済み / k:keep-index）' },
    { '[Files] f',       'fetch（成功時はBranchesのPR状態も再取得）' },
    { '[Files] i / y',   'ignoreに追加 / パスをコピー' },
    { '[Files] e / o',   'ファイルを開いて編集（gitパネルを閉じる）' },
    { '[hunk] h/l, Tab', '前後のhunkへ, ステージ済み/未ステージを切替' },
    { '[hunk] Space/d',  'hunkをステージ/アンステージ / 破棄' },
    { '[hunk] Esc/q',    'hunk表示を抜けてファイル一覧へ戻る' },
    { '[Branches] Space','チェックアウト' },
    { '[Branches] n/d',  '新規作成 / 削除' },
    { '[Branches] D',    'PRがMergedのブランチを一括削除（force delete、確認あり）' },
    { '[Branches] M/r',  'マージ / リベース' },
    { '[Branches] R/f',  'リネーム / fast-forward' },
    { '[Branches] c/F/-','名前指定 / 強制チェックアウト / 直前のブランチへ' },
    { '[Branches] u',    '上流ブランチ(upstream)を設定' },
    { '[Branches] y',    'ブランチ名をコピー' },
    { '[Commits] g',     'resetメニュー（soft/mixed/hard）' },
    { '[Commits] t',     'revert' },
    { '[Commits] n',     'このコミットから新規ブランチ' },
    { '[Commits] y',     'SHAをコピー' },
    { '[Commits] c',     'cherry-pick' },
    { '[Commits] Space', 'detached HEADでチェックアウト' },
    { '[Stash] Space/g', 'apply / pop' },
    { '[Stash] d/n',     '削除 / このスタッシュから新規ブランチ' },
    { '[Worktree] Space','移動（cd）' },
    { '[Worktree] n/d',  '新規作成 / 削除' },
    { '[Worktree] w',    'カーソル行のworktreeをherdrワークスペースとして開く' },
    { '[PR] o / Enter',  'PRをブラウザで開く（開けなければURLをコピー）' },
    { '[PR] y',          'PRのURLをコピー' },
    { '[PR] d',          '詳細 ⇄ diff を切替（diff中はvでside-by-side）' },
    { '[PR] c',          'PRのブランチをcheckout' },
    { '[PR] f',          'フィルタ（既定=作成/レビュー依頼 / 全て / 作者 / 検索）' },
  }},
  { header = '🐳 dockerパネル（Space d で開閉、1-5/←→/タブクリックでパネル切替）', color = 'ShortcutsBuffer', rows = {
    { '1-5',             'Project / Containers / Images / Volumes / Networks へ切替' },
    { '← / →',           '前後のパネルへ切替（タブバーはクリックでも切替可）' },
    { '[ / ]',           '右ペインのタブを前 / 次へ切替（Logs / Stats / Config / Top など。タブはクリックでも切替可）' },
    { 'R',               '現在のパネルを再取得（2秒ごとの自動更新もあり）' },
    { '@',               'コマンドログを画面いっぱいに拡大 / 再度で元に戻す（拡大中は内容をビジュアル選択やマウスドラッグで選択→ヤンクでコピー可）' },
    { '+',               '右ペインを拡大 / 再度で元に戻す（@と排他）' },
    { 'q / Esc',         '閉じる' },
    { '[Project] b',     '一括削除メニュー（container/image/volume/network/builder/system prune）' },
    { '[Containers] Space','起動 / 停止をトグル' },
    { '[Containers] s / r','停止（確認あり） / 再起動' },
    { '[Containers] p',  '一時停止 / 再開をトグル' },
    { '[Containers] K',  '強制終了（kill、確認あり）' },
    { '[Containers] d',  '削除メニュー（d:通常 / f:強制 / v:ボリュームごと）' },
    { '[Containers] b',  '停止中のコンテナを一括削除（container prune）' },
    { '[Containers] E',  'コンテナ内でシェルを起動（パネルを閉じて右に開く。bashが無ければsh）' },
    { '[Images] d',      '削除メニュー（d:通常 / f:強制）' },
    { '[Images] b',      '一括削除（image prune --all / builder prune）' },
    { '[Volumes] d / b', '削除（使用中なら強制削除を提案） / 未使用を一括削除' },
    { '[Networks] d / b','削除（組み込みのbridge/host/noneは対象外） / 未使用を一括削除' },
  }},
  { header = '🔌 ポートパネル（Space P で開閉、1-2/←→/タブクリックでパネル切替）', color = 'ShortcutsBuffer', rows = {
    { '1-2',             'Listening（待ち受けポート） / Connections（確立済み接続）へ切替' },
    { '← / →',           '前後のパネルへ切替（タブバーはクリックでも切替可）' },
    { '[ / ]',           '右ペインのタブを前 / 次へ切替（Process / Sockets。タブはクリックでも切替可）' },
    { 'R',               '現在のパネルを再取得（2秒ごとの自動更新もあり）' },
    { '@',               'コマンドログを画面いっぱいに拡大 / 再度で元に戻す' },
    { '+',               '右ペインを拡大 / 再度で元に戻す（@と排他）' },
    { 'q / Esc',         '閉じる' },
    { 'd',               'ポートを掴んでいるプロセスを終了（SIGTERM、確認あり）' },
    { 'D',               '同じく強制終了（SIGKILL、確認あり）' },
    { 'o',               'そのポートを http://localhost:ポート でブラウザに開く' },
    { 'y',               'ポート番号をクリップボードにコピー' },
  }},
}

-- ══════════════════════════════════════════════
-- レンダリング
-- ══════════════════════════════════════════════

local function render()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end

  local sections = SECTIONS
  local q = query:lower()
  local lines    = {}
  local hl_queue = {}

  local function hl(lnum, group, cs, ce)
    table.insert(hl_queue, { lnum, group, cs or 0, ce or -1 })
  end

  -- 検索バー
  local shint = query == '' and '絞り込む…' or query
  table.insert(lines, ' 🔍 ' .. shint)
  hl(0, query == '' and 'ShortcutsSearchHint' or 'ShortcutsSearchQuery')

  table.insert(lines, '')

  for _, section in ipairs(sections) do
    local visible = {}
    for _, row in ipairs(section.rows) do
      if q == '' or row[1]:lower():find(q, 1, true) or row[2]:lower():find(q, 1, true) then
        table.insert(visible, row)
      end
    end
    if #visible == 0 then goto continue end

    local lnum = #lines
    table.insert(lines, ' ' .. section.header)
    hl(lnum, section.color)

    for _, row in ipairs(visible) do
      local key     = row[1]
      local desc    = row[2]
      local pad     = math.max(1, 24 - vim.fn.strdisplaywidth(key))
      local line    = ' ' .. key .. string.rep(' ', pad) .. desc
      lnum = #lines
      table.insert(lines, line)
      hl(lnum, 'ShortcutsKey',  1, 1 + #key)
      hl(lnum, 'ShortcutsDesc', 1 + #key + pad, -1)
    end

    table.insert(lines, '')
    ::continue::
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)
  for _, h in ipairs(hl_queue) do
    vim.api.nvim_buf_add_highlight(buf, hl_ns, h[2], h[1], h[3], h[4])
  end
end

-- ══════════════════════════════════════════════
-- 開閉
-- ══════════════════════════════════════════════

local PANEL_WIDTH = 56

local function close()
  vim.api.nvim_clear_autocmds({ group = augrp })
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  win, buf = nil, nil
  query = ''
end

local function open()
  if win and vim.api.nvim_win_is_valid(win) then
    close()
    return
  end

  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype    = 'nofile'
  vim.bo[buf].buflisted  = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype   = 'shortcuts'

  -- 右端に垂直スプリット
  vim.cmd('botright ' .. PANEL_WIDTH .. 'vsplit')
  win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  require('config.hidden_cursor').mark_buffer(buf)
  require('config.util.win_util').mark_sidebar(win, buf)

  -- 番号列・余白オフと背景を適用する。他モジュールの autocmd がフォーカス時などに
  -- 番号を復活させることがあるため、関数化して WinEnter 等でも再適用する
  local function apply_win_opts()
    if not (win and vim.api.nvim_win_is_valid(win)) then return end
    vim.wo[win].wrap           = false
    vim.wo[win].number         = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn     = 'no'
    vim.wo[win].foldcolumn     = '0'
    vim.wo[win].statuscolumn   = ''
    vim.wo[win].cursorline     = false
    vim.wo[win].winfixwidth    = true
    -- 地の背景は透明（ターミナル背景を透かす）。非フォーカス時(NormalNC)と
    -- バッファ末尾(~)も同じ透明地に揃える
    vim.wo[win].winhighlight   = 'Normal:ShortcutsBg,NormalNC:ShortcutsBg,EndOfBuffer:ShortcutsBg'
    vim.wo[win].statusline     = '%#ShortcutsBg#' -- ステータスラインを隠す（パネル背景に溶け込ませる）
  end
  apply_win_opts()

  -- フォーカス移動などで番号列が復活しても、このパネルでは常にオフへ戻す
  vim.api.nvim_create_autocmd({ 'WinEnter', 'BufWinEnter', 'BufEnter' }, {
    group    = augrp,
    buffer   = buf,
    callback = apply_win_opts,
  })

  render()

  local function map(key, fn)
    vim.keymap.set('n', key, fn, { buffer = buf, nowait = true, silent = true })
  end

  map('/',       function()
    vim.ui.input({ prompt = '絞り込む: ', default = query }, function(input)
      if input ~= nil then query = input; render() end
      if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
      end
    end)
  end)
  map('<BS>',    function() query = ''; render() end)
  map('q',       close)
  map('<Esc>',   close)

  -- パネルを閉じられたら状態をリセット
  vim.api.nvim_create_autocmd('WinClosed', {
    group    = augrp,
    pattern  = tostring(win),
    once     = true,
    callback = function()
      if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      win, buf = nil, nil
      query = ''
      vim.api.nvim_clear_autocmds({ group = augrp })
    end,
  })

  -- フォーカスを元のウィンドウに戻す
  vim.cmd('wincmd p')
end

-- ══════════════════════════════════════════════
-- ハイライト
-- ══════════════════════════════════════════════

local function setup_hl()
  vim.api.nvim_set_hl(0, 'ShortcutsBg',          { bg = 'none' })
  vim.api.nvim_set_hl(0, 'ShortcutsKey',          { fg = '#e0af68', bold = true })
  vim.api.nvim_set_hl(0, 'ShortcutsDesc',         { fg = '#9aa5ce' })
  vim.api.nvim_set_hl(0, 'ShortcutsSearchHint',   { fg = '#565f89', italic = true })
  vim.api.nvim_set_hl(0, 'ShortcutsSearchQuery',  { fg = '#2ac3de' })
  vim.api.nvim_set_hl(0, 'ShortcutsNormal',       { bg = '#2d3250', fg = '#7aa2f7', bold = true })
  vim.api.nvim_set_hl(0, 'ShortcutsInsert',       { bg = '#2d3b2d', fg = '#9ece6a', bold = true })
  vim.api.nvim_set_hl(0, 'ShortcutsVisual',       { bg = '#3b2d3b', fg = '#bb9af7', bold = true })
  vim.api.nvim_set_hl(0, 'ShortcutsCommand',      { bg = '#3b302d', fg = '#ff9e64', bold = true })
  vim.api.nvim_set_hl(0, 'ShortcutsSearch',       { bg = '#2d3a3b', fg = '#2ac3de', bold = true })
  vim.api.nvim_set_hl(0, 'ShortcutsWindow',       { bg = '#3b3a2d', fg = '#e0af68', bold = true })
  vim.api.nvim_set_hl(0, 'ShortcutsBuffer',       { bg = '#2d3b3b', fg = '#73daca', bold = true })
  vim.api.nvim_set_hl(0, 'ShortcutsText',         { bg = '#3b2d36', fg = '#f7768e', bold = true })
  vim.api.nvim_set_hl(0, 'ShortcutsMacro',        { bg = '#2d2d3b', fg = '#9d7cd8', bold = true })
  vim.api.nvim_set_hl(0, 'ShortcutsMisc',         { bg = '#2d2d2d', fg = '#a9b1d6', bold = true })
  vim.api.nvim_set_hl(0, 'ShortcutsGit',          { bg = '#3b2d28', fg = '#ff9e64', bold = true })
  vim.api.nvim_set_hl(0, 'ShortcutsHerdr',        { bg = '#2d2d3b', fg = '#cba6f7', bold = true })
end

setup_hl()
vim.api.nvim_create_autocmd('ColorScheme', { callback = setup_hl })

vim.keymap.set('n', '<leader>?', open, { desc = 'キーボードショートカット一覧' })

return M
