-- 差分レビューのブラウザ画面(difit を参考にした単一ページアプリ)。
--
-- ページ自体は静的で、/api/diff・/api/comments・/api/session を fetch して描画する。
-- 行をクリックするとその行にコメントを追加でき、スレッド(返信)も表示する。
-- unified / side-by-side(split) の表示切替を持ち、選択は localStorage に保存する(difit 相当)。
-- /__version を 1 秒間隔でポーリングし、AI が API 経由で足したコメントも自動で反映する。
-- 配色は browser/markdown.lua のプレビューと同系統の暗色テーマに揃えている。

local M = {}

local function html_escape(s)
  return (tostring(s or ''):gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'))
end

-- HTML/CSS/JS 本体。データは実行時に fetch するのでテンプレートは静的。
local PAGE = [==[<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__</title>
<style>
*{box-sizing:border-box;}
body{margin:0;background:#0d1117;color:#e6edf3;font:14px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;}
header{position:sticky;top:0;z-index:5;background:#161b22;border-bottom:1px solid #30363d;padding:10px 20px;display:flex;align-items:center;gap:14px;flex-wrap:wrap;}
header h1{font-size:15px;margin:0;font-weight:600;}
header .meta{color:#8b949e;font-size:12px;}
header .spacer{flex:1;}
header .pill{background:#21262d;border:1px solid #30363d;border-radius:999px;padding:2px 10px;font-size:12px;color:#8b949e;}
header button.pill{cursor:pointer;color:#c9d1d9;}
header button.pill:hover{background:#30363d;border-color:#8b949e;}
header button.pill.off{color:#6e7681;}
header button.pill.danger{color:#f85149;}
header button.pill.danger:hover{background:#da363322;border-color:#f85149;}
/* 押せないときは消さずに非活性にする。消すとヘッダーのボタン位置がまとめてずれるため。 */
header button.pill:disabled,header button.pill.danger:disabled{color:#484f58;border-color:#21262d;cursor:default;}
header button.pill:disabled:hover,header button.pill.danger:disabled:hover{background:#21262d;border-color:#21262d;}
.seg{display:inline-flex;border:1px solid #30363d;border-radius:999px;overflow:hidden;}
.seg button{background:#21262d;color:#8b949e;border:0;padding:3px 12px;font-size:12px;cursor:pointer;}
.seg button:hover{background:#30363d;}
.seg button.active{background:#388bfd33;color:#79c0ff;}
.seg button+button{border-left:1px solid #30363d;}
#layout{display:flex;align-items:flex-start;max-width:1500px;margin:0 auto;}
main{flex:1;min-width:0;padding:20px;}
/* 変更ファイルのツリー(サイドバー)。ヘッダー高さぶん下げてスティッキー表示。 */
nav.tree{position:sticky;top:44px;align-self:flex-start;flex:0 0 270px;width:270px;max-height:calc(100vh - 44px);overflow:auto;padding:14px 6px 40px;border-right:1px solid #30363d;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12.5px;}
nav.tree .tree-title{color:#8b949e;font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.04em;padding:0 6px 8px;}
/* ツリーを折りたたむと main(flex:1) が空いた幅いっぱいに広がる */
#layout.tree-collapsed nav.tree{display:none;}
.tnode{display:flex;align-items:center;gap:6px;padding:3px 6px;border-radius:6px;cursor:pointer;white-space:nowrap;}
.tnode:hover{background:#161b22;}
.tdir .tw{color:#8b949e;width:12px;flex:none;}
.tdir .tname{color:#c9d1d9;font-weight:600;overflow:hidden;text-overflow:ellipsis;}
.tfile .tname{color:#adbac7;overflow:hidden;text-overflow:ellipsis;}
.tbadge{font-size:10px;width:14px;flex:none;text-align:center;color:#8b949e;}
.tbadge.A{color:#3fb950;} .tbadge.D{color:#f85149;} .tbadge.R{color:#d29922;} .tbadge.M{color:#58a6ff;}
.tcount{margin-left:auto;background:#388bfd33;color:#79c0ff;border-radius:999px;padding:0 6px;font-size:11px;flex:none;}
/* コメント目次(ツリーのファイル配下)。本文は出さずジャンプ先だけ並べる。本文は title 属性へ。 */
.tcomment{display:flex;align-items:center;gap:6px;padding:2px 6px;border-radius:6px;cursor:pointer;white-space:nowrap;font-size:11.5px;color:#8b949e;}
.tcomment:hover{background:#161b22;}
.tcomment .cdot{flex:none;font-size:9px;}
.tcomment .cdot.ai{color:#d2a8ff;} .tcomment .cdot.human{color:#79c0ff;}
.tcomment .cline{color:#adbac7;}
.tcomment .creply{color:#6e7681;}
.tcomment .cout{color:#d29922;font-weight:600;}
@media(max-width:820px){nav.tree{display:none;}}
.empty{color:#8b949e;text-align:center;padding:60px 0;}
/* シンタックスハイライト(同梱 highlight.js)。トークン色だけ使い、背景/余白は付けない。 */
td.content .hljs,td.content code.hljs{background:transparent;padding:0;color:inherit;}
/* 範囲選択コメントの対象行(All ビューで shift+クリック中) */
td.content.range-sel{outline:1px solid #388bfd66;outline-offset:-1px;}
/* ファイル折りたたみ(lock/生成物/削除ファイルは既定で畳む) */
.file-head{cursor:pointer;}
.file-head .fchev{color:#8b949e;width:12px;flex:none;}
.file.collapsed .collapsed-note{color:#8b949e;font-size:12px;padding:10px 14px;}
.file{border:1px solid #30363d;border-radius:8px;margin:0 0 20px;overflow:hidden;background:#0d1117;}
.file-head{background:#161b22;border-bottom:1px solid #30363d;padding:8px 12px;display:flex;align-items:center;gap:10px;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:13px;}
.file-head .path{font-weight:600;}
.file-head .stat-add{color:#3fb950;} .file-head .stat-del{color:#f85149;}
.file-head .open-nvim{margin-left:auto;background:#21262d;color:#c9d1d9;border:1px solid #30363d;border-radius:6px;padding:2px 8px;font:12px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;cursor:pointer;}
.file-head .open-nvim:hover{background:#30363d;border-color:#8b949e;}
.badge{font-size:11px;padding:1px 6px;border-radius:4px;border:1px solid #30363d;color:#8b949e;}
.badge.A{color:#3fb950;border-color:#238636;} .badge.D{color:#f85149;border-color:#da3633;}
.badge.R{color:#d29922;border-color:#9e6a03;}
table.diff{width:100%;border-collapse:collapse;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12.5px;}
/* split は colgroup で列幅を固定する。hunk ヘッダー行が colspan=4 の 1 セルなので、
   table-layout:fixed の「先頭行から列幅を決める」だけだと均等割りされてしまう。colgroup なら効く。 */
table.diff.split{table-layout:fixed;}
table.diff.split col.c-ln{width:50px;}
table.diff.split col.c-code{width:calc(50% - 50px);}
table.diff td{padding:0 8px;vertical-align:top;white-space:pre-wrap;word-break:break-word;overflow-wrap:anywhere;}
td.ln{width:50px;text-align:right;color:#6e7681;user-select:none;background:#0d1117;border-right:1px solid #21262d;}
td.ln.jumpable{cursor:pointer;}
td.ln.jumpable:hover{color:#79c0ff;background:#11161d;}
td.content.left{border-right:1px solid #30363d;}
/* 追加・削除の色付けは unified では行(tr)に、split ではセル(td)に付く */
tr.add td.content,td.content.add{background:rgba(63,185,80,.15);}
tr.del td.content,td.content.del{background:rgba(248,81,73,.15);}
tr.add td.ln,td.ln.add{background:rgba(63,185,80,.10);}
tr.del td.ln,td.ln.del{background:rgba(248,81,73,.10);}
td.content.filler{background:#0b0f14;}
tr.hunk td{background:#161b22;color:#8b949e;padding:2px 8px;}
td.content{cursor:default;}
td.content .sign{display:inline-block;width:1ch;color:#6e7681;}
tr.add td.content .sign,td.content.add .sign{color:#3fb950;}
tr.del td.content .sign,td.content.del .sign{color:#f85149;}
.threadrow td{background:#0d1117;padding:0;}
.thread{margin:6px 10px;border-left:2px solid #388bfd;background:#11161d;border-radius:0 6px 6px 0;}
/* 目次からジャンプしてきた直後だけ光らせる(どこへ飛んだか分かるように) */
@keyframes threadflash{from{background:#388bfd44;}to{background:#11161d;}}
.thread.flash{animation:threadflash 1.4s ease-out;}
.comment{padding:9px 13px;border-bottom:1px solid #21262d;}
.comment:last-child{border-bottom:0;}
.comment .who{font-size:13px;font-weight:600;margin-bottom:3px;display:flex;gap:8px;align-items:center;}
.comment .who .author-ai{color:#d2a8ff;} .comment .who .author-human{color:#79c0ff;}
.comment .who .time{color:#6e7681;font-weight:400;}
.comment .who .del{margin-left:auto;color:#6e7681;cursor:pointer;font-weight:400;border:0;background:none;font-size:13px;}
.comment .who .del:hover{color:#f85149;}
.comment .who .crange{color:#8b949e;font-weight:400;font-size:12px;}
.comment .who .outdated{color:#d29922;font-weight:600;font-size:11px;border:1px solid #9e6a03;border-radius:4px;padding:0 5px;}
.cform .crange{color:#8b949e;font-size:12px;margin-bottom:6px;}
.comment .body{white-space:pre-wrap;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;font-size:15px;line-height:1.65;}
.cform{padding:9px 13px;background:#0d1117;}
.cform textarea{width:100%;min-height:60px;background:#0d1117;color:#e6edf3;border:1px solid #30363d;border-radius:6px;padding:9px;font:14.5px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;resize:vertical;}
.cform .actions{margin-top:6px;display:flex;gap:8px;}
button.btn{background:#238636;color:#fff;border:0;border-radius:6px;padding:5px 14px;font-size:13px;cursor:pointer;}
button.btn:hover{background:#2ea043;}
button.btn.ghost{background:#21262d;color:#c9d1d9;border:1px solid #30363d;}
button.btn.ghost:hover{background:#30363d;}
.orphans{padding:10px 12px;border-top:1px solid #30363d;background:#11161d;}
.orphans .h{color:#8b949e;font-size:12px;margin-bottom:6px;}
.orphans .gone-file{color:#adbac7;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12px;margin:10px 0 4px;}
</style>
<link rel="stylesheet" href="/__vendor/highlight-theme.css">
<script src="/__vendor/highlight.min.js"></script>
</head>
<body>
<header>
  <button class="pill" id="treebtn" title="ファイルツリーの表示を切り替え">☰</button>
  <h1>Diff Review</h1>
  <span class="meta" id="repo"></span>
  <span class="spacer"></span>
  <span class="seg" id="viewseg" title="差分ソースを切り替え。コメントは All のみ、Unstaged/Staged は閲覧専用">
    <button data-view="all">All</button>
    <button data-view="unstaged">Unstaged</button>
    <button data-view="staged">Staged</button>
  </span>
  <button class="pill" id="modebtn" title="表示を切り替え (unified / side-by-side)"></button>
  <button class="pill" id="cmtbtn" title="この画面でのコメント表示/非表示。API 経由の読み書きには影響しない"></button>
  <button class="pill danger" id="clearbtn" title="すべてのコメントを削除">Clear</button>
  <span class="pill" id="counts"></span>
  <span class="pill" id="status">Connecting…</span>
</header>
<div id="layout">
<nav id="tree" class="tree"></nav>
<main id="app"><div class="empty">読み込み中…</div></main>
</div>
<script>
const state = {
  session:null, diff:{files:[]}, comments:[], version:null,
  draft:'',
  mode: (localStorage.getItem('diffReviewMode')==='split') ? 'split' : 'unified',
  view: (['unstaged','staged'].indexOf(localStorage.getItem('diffReviewView'))>=0) ? localStorage.getItem('diffReviewView') : 'all',
  commentsHidden: localStorage.getItem('diffReviewCommentsHidden')==='1', // 差分だけに集中するモード
  collapsedDirs: new Set(),
  treeCollapsed: localStorage.getItem('diffReviewTreeCollapsed')==='1',
  fileCollapse: {},          // path -> bool（ユーザーが明示的に開閉した上書き）
  anchor: null,              // 直近クリック行（範囲選択の起点）
  pending: null,             // 編集中フォーム {file, side, start, end}（末尾行 end にフォームを出す）
  curLang: null,             // 描画中ファイルの hljs 言語
};
// コメントの表示アンカー行。範囲コメントは末尾行(line_end)に出す(GitHub と同じ)。
function anchorLine(c){ return (c.line_end!=null) ? c.line_end : c.line; }
function applyTreeCollapsed(){ document.getElementById('layout').classList.toggle('tree-collapsed', state.treeCollapsed); }

// 拡張子 -> highlight.js 言語
const HL_EXT = {lua:'lua',js:'javascript',jsx:'javascript',mjs:'javascript',cjs:'javascript',ts:'typescript',tsx:'typescript',py:'python',go:'go',rs:'rust',rb:'ruby',java:'java',kt:'kotlin',swift:'swift',c:'c',h:'c',cpp:'cpp',cc:'cpp',hpp:'cpp',cs:'csharp',php:'php',json:'json',md:'markdown',markdown:'markdown',html:'xml',htm:'xml',xml:'xml',vue:'xml',css:'css',scss:'scss',less:'less',sh:'bash',bash:'bash',zsh:'bash',sql:'sql',yaml:'yaml',yml:'yaml',toml:'ini',ini:'ini'};
function hlLang(path){
  if(!window.hljs) return null;
  const base = (path.split('/').pop()||'').toLowerCase();
  if(base==='dockerfile') return hljs.getLanguage('dockerfile') ? 'dockerfile' : null;
  if(base==='makefile') return hljs.getLanguage('makefile') ? 'makefile' : null;
  const ext = base.indexOf('.')>=0 ? base.split('.').pop() : '';
  const lang = HL_EXT[ext];
  return (lang && hljs.getLanguage(lang)) ? lang : null;
}

// 既定で畳むファイル（lock / 生成物 / minify / source map）。difit の auto-collapse 相当。
const GEN_RE = /(^|\/)(package-lock\.json|pnpm-lock\.yaml|yarn\.lock|Cargo\.lock|poetry\.lock|composer\.lock|Gemfile\.lock|flake\.lock|go\.sum)$|\.min\.(js|css)$|\.map$/i;
function isGenerated(path){ return GEN_RE.test(path); }
function shouldCollapse(f){
  if(Object.prototype.hasOwnProperty.call(state.fileCollapse, f.path)) return state.fileCollapse[f.path];
  return isGenerated(f.path) || f.status==='D';
}
// この画面でコメントを付けられるのは All ビューのみ。Unstaged/Staged は閲覧専用。
// 非表示中も付けられない(見えていないものに書き込めるとフォームだけ浮くため)。
// あくまで描画側の話で、API(POST /api/comments)はこれに関係なく常に受け付ける。
function commentable(){ return state.view==='all' && !state.commentsHidden; }

function el(tag, cls, text){ const e=document.createElement(tag); if(cls) e.className=cls; if(text!=null) e.textContent=text; return e; }
async function getJSON(p){ const r=await fetch(p); return r.json(); }
async function postJSON(p, body){
  const r = await fetch(p, {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body)});
  return {ok:r.ok, data: await r.json().catch(()=>({}))};
}
async function openInNvim(file, line, col){
  if(!file) return;
  await postJSON('/api/jump', {file, line:line||1, col:col||1});
}

function keyOf(file, side, line){ return file+' '+side+' '+line; }
function targetOf(line){
  if(line.type==='add') return {side:'new', line:line.new_line};
  if(line.type==='del') return {side:'old', line:line.old_line};
  return {side:'new', line:line.new_line};
}
// コメントを描画するときは必ずここを通す。Comments off の判定をこの1箇所に閉じ込めるため、
// 描画側から state.comments を直接読まないこと(読んでいいのは「隠していても全件が対象」の
// Clear ボタンだけ)。描画経路を増やしても非表示の効き忘れが起きないようにするための入口。
function visibleComments(){ return state.commentsHidden ? [] : state.comments; }
function topFor(file, side, line){
  // outdated（差分更新で本文が見つからなくなった）コメントはインライン配置しない → 末尾の一覧へ回す
  return visibleComments().filter(c=>c.parent_id==null && !c.outdated && c.file===file && c.side===side && Number(anchorLine(c))===Number(line));
}
function repliesFor(id){ return visibleComments().filter(c=>c.parent_id===id); }
function fmtTime(t){ if(!t) return ''; try{ return new Date(t*1000).toLocaleString(); }catch(e){ return ''; } }

async function loadAll(){
  try{
    const [session, diff, comments] = await Promise.all([
      getJSON('/api/session'), getJSON('/api/diff?view='+encodeURIComponent(state.view)), getJSON('/api/comments')
    ]);
    state.session=session; state.diff=diff||{files:[]}; state.comments=(comments&&comments.comments)||[];
    state.version = String(session.version);
    document.getElementById('status').textContent='Connected';
    render();
  }catch(e){
    document.getElementById('status').textContent='Disconnected';
  }
}

function render(){
  const app = document.getElementById('app');
  app.innerHTML='';
  const files = (state.diff && state.diff.files) || [];
  document.getElementById('repo').textContent = state.session ? (state.session.repoRoot||'') + ' · ' + (state.session.source||'') : '';
  document.getElementById('modebtn').textContent = state.mode==='split' ? '⇆ Side-by-side' : '≡ Unified';
  const cmtbtn = document.getElementById('cmtbtn');
  cmtbtn.textContent = state.commentsHidden ? 'Comments off' : 'Comments';
  cmtbtn.classList.toggle('off', state.commentsHidden);
  document.querySelectorAll('#viewseg button').forEach(b=>b.classList.toggle('active', b.dataset.view===state.view));
  // 全削除ボタンは All ビューでコメントがあるときだけ出す
  // Clear は隠れているものも含めて全消しするので、ここだけは visibleComments() ではなく実数を見る。
  // 押せないときも消さずに非活性のまま置く(消すとヘッダーのボタンが左に詰まって位置が動く)。
  document.getElementById('clearbtn').disabled = !(commentable() && state.comments.length);
  let add=0, del=0; files.forEach(f=>{add+=f.added||0; del+=f.deleted||0;});
  document.getElementById('counts').textContent = files.length+' files  +'+add+' -'+del;

  if(!files.length){ app.appendChild(el('div','empty','変更はありません')); }
  else { files.forEach((f,idx)=>app.appendChild(renderFile(f, idx))); }
  const gone = renderGoneSection(files);
  if(gone) app.appendChild(gone);
  renderTree(files);
  if(state.pending) restoreForm();
}

// 現在のビューの差分に出てこないファイルのコメントを、全体の末尾にまとめる。
// 「行だけ消えてファイルは残る」ケースは各ファイル末尾に出るのでここでは扱わない。
// All 以外でも出すのは、ツリーの目次から必ずジャンプ先(DOM)が引けるようにするため。
function goneComments(files){
  const present = {};
  files.forEach(f=>{ present[f.path]=true; });
  return visibleComments().filter(c=>c.parent_id==null && !present[c.file]);
}
function goneTitle(){ return state.view==='all' ? 'No longer in diff' : 'Not in this view'; }
function renderGoneSection(files){
  const gone = goneComments(files);
  if(!gone.length) return null;
  const box = el('div','file');
  const head = el('div','file-head');
  head.appendChild(el('span','path', goneTitle()));
  box.appendChild(head);
  const body = el('div','orphans');
  const byFile = {};
  gone.forEach(c=>{ (byFile[c.file]=byFile[c.file]||[]).push(c); });
  Object.keys(byFile).sort().forEach(path=>{
    body.appendChild(el('div','gone-file', path));
    byFile[path].forEach(c=>body.appendChild(renderThread(c)));
  });
  box.appendChild(body);
  return box;
}

// ── 変更ファイルのツリー(サイドバー) ─────────────────────────
// ツリーにぶら下げるコメント目次。行順に並べる。
function commentsOf(path){
  return visibleComments()
    .filter(c=>c.parent_id==null && c.file===path)
    .sort((a,b)=>Number(anchorLine(a))-Number(anchorLine(b)));
}
// 目次の1行。本文は出さず(ジャンプ先だけ)、識別用に title 属性へ入れる。
function commentIndexRow(c, pad){
  const row = el('div','tcomment');
  row.style.paddingLeft = pad+'px';
  const isAI = c.author && c.author!=='human';
  row.appendChild(el('span','cdot '+(isAI?'ai':'human'), '●'));
  // +/- も色も付けない。context 行は targetOf で side:new に寄るので記号は嘘になるし、
  // 目次で old/new を気にする場面はほぼ無い(飛んだ先を見れば分かる)。side は title に回す。
  let label = 'L' + c.line;
  if(c.line_end && c.line_end!==c.line) label += '–' + c.line_end;
  row.appendChild(el('span','cline', label));
  const rc = repliesFor(c.id).length;
  if(rc) row.appendChild(el('span','creply', '↩'+rc));
  if(c.outdated) row.appendChild(el('span','cout','!'));
  row.title = c.side + ' L' + c.line + '  ' + (isAI ? c.author : 'You') + ': ' + c.body;
  row.onclick = ()=>jumpToComment(c);
  return row;
}
// 目次からスレッド本体へ飛ぶ。ファイルが畳まれているとスレッドが描画されていないので開いてから。
// 行番号ではなく id で引くので、unified/split やビューを切り替えても、インライン表示できず
// ファイル末尾へ回されたコメントでも同じように当たる。
function jumpToComment(c){
  const files = (state.diff && state.diff.files) || [];
  const f = files.filter(x=>x.path===c.file)[0];
  if(f && shouldCollapse(f)){ state.fileCollapse[c.file] = false; render(); }
  const box = document.getElementById('c-'+c.id);
  if(!box) return;
  box.scrollIntoView({behavior:'smooth', block:'center'});
  box.classList.remove('flash');
  void box.offsetWidth; // アニメーションを再生し直すためのリフロー
  box.classList.add('flash');
}
function buildTree(files){
  const root = {dirs:{}, files:[]};
  files.forEach((f,idx)=>{
    const parts = f.path.split('/');
    let node = root;
    for(let i=0;i<parts.length-1;i++){ const d=parts[i]; node.dirs[d]=node.dirs[d]||{dirs:{},files:[]}; node=node.dirs[d]; }
    node.files.push({file:f, idx, name:parts[parts.length-1]});
  });
  return root;
}
function renderTreeNode(node, prefix, depth, out){
  Object.keys(node.dirs).sort().forEach(name=>{
    // compact folders (difit / VSCode 相当): 子が「ディレクトリ1つだけ・ファイル無し」の間は
    // a/b/c のように 1 行へ圧縮する。
    let label = name, path = prefix ? prefix+'/'+name : name, dnode = node.dirs[name];
    while(Object.keys(dnode.dirs).length===1 && dnode.files.length===0){
      const only = Object.keys(dnode.dirs)[0];
      label += '/' + only; path += '/' + only; dnode = dnode.dirs[only];
    }
    const collapsed = state.collapsedDirs.has(path);
    const row = el('div','tnode tdir'); row.style.paddingLeft = (6+depth*12)+'px';
    row.appendChild(el('span','tw', collapsed?'▸':'▾'));
    row.appendChild(el('span','tname', label));
    row.onclick = ()=>{ if(collapsed) state.collapsedDirs.delete(path); else state.collapsedDirs.add(path); renderTree((state.diff&&state.diff.files)||[]); };
    out.appendChild(row);
    if(!collapsed) renderTreeNode(dnode, path, depth+1, out);
  });
  node.files.sort((a,b)=>a.name.localeCompare(b.name)).forEach(item=>{
    const f = item.file;
    const row = el('div','tnode tfile'); row.style.paddingLeft = (6+depth*12+14)+'px';
    row.appendChild(el('span','tbadge '+(f.status||'M'), f.status||'M'));
    row.appendChild(el('span','tname', item.name));
    const cs = commentsOf(f.path);
    if(cs.length) row.appendChild(el('span','tcount', String(cs.length)));
    row.title = f.path + '  +' + (f.added||0) + ' -' + (f.deleted||0);
    row.onclick = ()=>{
      if(shouldCollapse(f)){ state.fileCollapse[f.path] = false; render(); } // 畳まれていたら開いてから
      const b=document.getElementById('file-'+item.idx); if(b) b.scrollIntoView({behavior:'smooth', block:'start'});
    };
    out.appendChild(row);
    cs.forEach(c=>out.appendChild(commentIndexRow(c, 6+depth*12+28)));
  });
}
// 現在のビューに出ていないファイルのコメントも目次から飛べるようにする(親ノードが無いため擬似ノード)。
function renderTreeGone(files, out){
  const gone = goneComments(files);
  if(!gone.length) return;
  out.appendChild(el('div','tree-title', goneTitle()));
  const byFile = {};
  gone.forEach(c=>{ (byFile[c.file]=byFile[c.file]||[]).push(c); });
  Object.keys(byFile).sort().forEach(path=>{
    const row = el('div','tnode tfile');
    row.style.paddingLeft = '6px';
    row.appendChild(el('span','tname', path)); // .tfile .tname 側で省略表示される
    row.title = path;
    row.onclick = ()=>jumpToComment(byFile[path][0]);
    out.appendChild(row);
    byFile[path]
      .sort((a,b)=>Number(anchorLine(a))-Number(anchorLine(b)))
      .forEach(c=>out.appendChild(commentIndexRow(c, 20)));
  });
}
function renderTree(files){
  const tree = document.getElementById('tree');
  tree.innerHTML='';
  if(files.length){
    tree.appendChild(el('div','tree-title', 'Changed files ('+files.length+')'));
    renderTreeNode(buildTree(files), '', 0, tree);
  }
  renderTreeGone(files, tree);
}

function firstLine(f){
  for(const h of (f.hunks||[])){
    for(const l of (h.lines||[])){
      if(l.new_line!=null) return l.new_line;
      if(l.old_line!=null) return l.old_line;
    }
  }
  return 1;
}

function fileHead(f){
  const head = el('div','file-head');
  head.appendChild(el('span','badge '+(f.status||'M'), f.status||'M'));
  head.appendChild(el('span','path', f.path));
  const st = el('span');
  st.appendChild(el('span','stat-add',' +'+(f.added||0)));
  st.appendChild(el('span','stat-del',' -'+(f.deleted||0)));
  head.appendChild(st);
  const open = el('button','open-nvim','Open in nvim');
  open.title = 'nvim で開く';
  open.onclick = (ev)=>{ ev.stopPropagation(); openInNvim(f.path, firstLine(f), 1); };
  head.appendChild(open);
  return head;
}

function lineCell(file, lineNo, cls){
  const td = el('td', cls || 'ln', lineNo!=null?String(lineNo):'');
  if(lineNo!=null){
    td.classList.add('jumpable');
    td.title = 'nvim で開く';
    td.onclick = (ev)=>{ ev.stopPropagation(); openInNvim(file, lineNo, 1); };
  }
  return td;
}

// 編集中フォームが範囲選択のとき、この行が範囲内か
function inPendingRange(file, side, lineNo){
  const p = state.pending;
  if(!p || p.file!==file || p.side!==side) return false;
  return lineNo>=p.start && lineNo<=p.end;
}

// content セル。side/lineNo があればクリックでコメント、shift+クリックで範囲コメント。
function contentCell(file, side, lineNo, type, content, extraClass){
  let cls = 'content';
  if(extraClass) cls += ' '+extraClass;
  if(type) cls += ' '+type;
  if(side && lineNo!=null && commentable() && inPendingRange(file, side, lineNo)) cls += ' range-sel';
  const td = el('td', cls);
  if(content==null && !type){ return td; } // filler(空セル)
  td.appendChild(el('span','sign', type==='add'?'+':(type==='del'?'-':' ')));
  if(content){
    const lang = state.curLang;
    if(lang && window.hljs){
      const span = document.createElement('span');
      try{ span.innerHTML = hljs.highlight(content, {language:lang, ignoreIllegals:true}).value; }
      catch(e){ span.textContent = content; }
      td.appendChild(span);
    }else{
      td.appendChild(document.createTextNode(content));
    }
  }else if(content===''){ /* 空行 */ }
  if(side && lineNo!=null && commentable()){
    td.style.cursor='pointer';
    td.onclick=(ev)=>{
      if(ev.target.closest('.thread,.cform')) return;
      if(ev.shiftKey && state.anchor && state.anchor.file===file && state.anchor.side===side){
        openForm(file, side, Math.min(state.anchor.line, lineNo), Math.max(state.anchor.line, lineNo));
      }else{
        state.anchor = {file, side, line:lineNo};
        openForm(file, side, lineNo);
      }
    };
  }
  return td;
}

function hunkHeaderRow(h, colspan){
  const tr = el('tr','hunk'); const td=el('td'); td.colSpan=colspan; td.textContent=h.header; tr.appendChild(td); return tr;
}

// 行の下に、該当する (side,line) のスレッド/フォームを差し込む。seen に描画済みキーを記録。
// staged はインライン表示しない(行番号が index 基準でズレるため全部まとめ送り)。
// unstaged は new 側のみ一致させる(new 側は作業ツリー基準で All と一致するため)。
function afterRowThreads(table, f, targets, colspan, seen){
  if(state.view==='staged') return;
  targets.forEach(t=>{
    if(!t || t.line==null) return;
    if(state.view==='unstaged' && t.side!=='new') return;
    const tops = topFor(f.path, t.side, t.line);
    const p = state.pending;
    // フォームは範囲の末尾行(p.end)に出す
    const formHere = commentable() && p && p.file===f.path && p.side===t.side && p.end===t.line;
    if(tops.length || formHere){
      seen[keyOf(f.path, t.side, t.line)] = true;
      table.appendChild(threadRow(f.path, t.side, t.line, tops, colspan, formHere ? p : null));
    }
  });
}

function renderFile(f, idx){
  const box = el('div','file');
  if(idx!=null) box.id = 'file-'+idx;
  const collapsed = shouldCollapse(f);
  if(collapsed) box.classList.add('collapsed');

  const head = fileHead(f);
  head.insertBefore(el('span','fchev', collapsed?'▸':'▾'), head.firstChild);
  head.onclick = ()=>{ state.fileCollapse[f.path] = !collapsed; render(); };
  box.appendChild(head);

  if(collapsed){
    box.appendChild(el('div','collapsed-note', '折りたたみ中（クリックで展開）  +'+(f.added||0)+' -'+(f.deleted||0)));
    return box;
  }
  // バイナリは表を出さないが、下の orphans まで通す。ここで return するとコメントの DOM が
  // 作られず、ツリーの目次から飛べない行になる。
  const seen = {};
  if(f.binary){
    const b = el('div','orphans');
    b.appendChild(el('div','h','バイナリファイル(差分表示なし)'));
    box.appendChild(b);
  }else{
    state.curLang = hlLang(f.path); // このファイルの diff 行に使う言語
    const table = el('table', state.mode==='split' ? 'diff split' : 'diff');
    if(state.mode==='split'){
      // colgroup で 4 列(行番号/コード/行番号/コード)の幅を固定する
      const cg = document.createElement('colgroup');
      ['c-ln','c-code','c-ln','c-code'].forEach(c=>{ const col=document.createElement('col'); col.className=c; cg.appendChild(col); });
      table.appendChild(cg);
    }
    (f.hunks||[]).forEach(h=>{
      if(state.mode==='split') renderHunkSplit(table, f, h, seen);
      else renderHunkUnified(table, f, h, seen);
    });
    box.appendChild(table);
  }

  // インライン表示できなかったコメントはファイル末尾にまとめる。
  // All では「行がずれた等で一致しないもの」、Unstaged/Staged では「All で付いた閲覧専用コメント」。
  const orphans = visibleComments().filter(c=>c.parent_id==null && c.file===f.path && !seen[keyOf(f.path,c.side,anchorLine(c))]);
  if(orphans.length){
    const ob = el('div','orphans');
    if(state.view!=='all'){ ob.appendChild(el('div','h', 'All のコメント（このビューでは閲覧のみ）')); }
    orphans.forEach(c=>ob.appendChild(renderThread(c)));
    box.appendChild(ob);
  }
  return box;
}

function renderHunkUnified(table, f, h, seen){
  table.appendChild(hunkHeaderRow(h, 3));
  (h.lines||[]).forEach(line=>{
    const tr = el('tr','line '+line.type);
    tr.appendChild(lineCell(f.path, line.old_line));
    tr.appendChild(lineCell(f.path, line.new_line));
    const tgt = targetOf(line);
    tr.appendChild(contentCell(f.path, tgt.side, tgt.line, line.type, line.content));
    table.appendChild(tr);
    afterRowThreads(table, f, [tgt], 3, seen);
  });
}

// side-by-side: 連続する del ブロックと add ブロックを行ごとにペアリングして左右に並べる。
function renderHunkSplit(table, f, h, seen){
  table.appendChild(hunkHeaderRow(h, 4));
  const lines = h.lines || [];
  let i = 0;
  while(i < lines.length){
    const line = lines[i];
    if(line.type==='context'){
      const tr = el('tr','line');
      tr.appendChild(lineCell(f.path, line.old_line));
      tr.appendChild(contentCell(f.path,'old',line.old_line,'context',line.content,'left'));
      tr.appendChild(lineCell(f.path, line.new_line));
      tr.appendChild(contentCell(f.path,'new',line.new_line,'context',line.content));
      table.appendChild(tr);
      afterRowThreads(table, f, [{side:'old',line:line.old_line},{side:'new',line:line.new_line}], 4, seen);
      i++;
    }else{
      const dels=[], adds=[];
      while(i<lines.length && lines[i].type==='del'){ dels.push(lines[i]); i++; }
      while(i<lines.length && lines[i].type==='add'){ adds.push(lines[i]); i++; }
      const n = Math.max(dels.length, adds.length);
      for(let k=0;k<n;k++){
        const d=dels[k], a=adds[k];
        const tr = el('tr','line');
        tr.appendChild(lineCell(f.path, d&&d.old_line, d?'ln del':'ln'));
        tr.appendChild(d ? contentCell(f.path,'old',d.old_line,'del',d.content,'left')
                         : contentCell(f.path,null,null,null,null,'left filler'));
        tr.appendChild(lineCell(f.path, a&&a.new_line, a?'ln add':'ln'));
        tr.appendChild(a ? contentCell(f.path,'new',a.new_line,'add',a.content)
                         : contentCell(f.path,null,null,null,null,'filler'));
        table.appendChild(tr);
        const targets=[];
        if(d) targets.push({side:'old',line:d.old_line});
        if(a) targets.push({side:'new',line:a.new_line});
        afterRowThreads(table, f, targets, 4, seen);
      }
    }
  }
}

function threadRow(file, side, line, tops, colspan, pending){
  const tr = el('tr','threadrow'); const td=el('td'); td.colSpan=colspan||3;
  tops.forEach(c=>td.appendChild(renderThread(c)));
  if(pending){ td.appendChild(commentForm({file, side, line: pending.start, lineEnd: (pending.end!==pending.start ? pending.end : null)})); }
  tr.appendChild(td);
  return tr;
}

function renderThread(top){
  const wrap = el('div','thread');
  wrap.id = 'c-'+top.id; // ツリーの目次からのジャンプ先
  wrap.appendChild(renderComment(top));
  repliesFor(top.id).forEach(r=>wrap.appendChild(renderComment(r)));
  if(commentable()) wrap.appendChild(replyForm(top.id)); // 閲覧専用ビューでは返信欄を出さない
  return wrap;
}

function renderComment(c){
  const box = el('div','comment');
  const who = el('div','who');
  const isAI = c.author && c.author!=='human';
  who.appendChild(el('span', isAI?'author-ai':'author-human', isAI ? c.author : 'You'));
  if(c.line_end && c.line_end!==c.line){ who.appendChild(el('span','crange', 'L'+c.line+'–'+c.line_end)); }
  if(c.outdated){ who.appendChild(el('span','outdated', 'outdated')); }
  who.appendChild(el('span','time', fmtTime(c.created_at)));
  if(commentable()){ // 閲覧専用ビューでは削除ボタンを出さない
    const del = el('button','del','✕'); del.title='削除';
    del.onclick = async ()=>{ await postJSON('/api/comments/delete', {id:c.id}); await loadAll(); };
    who.appendChild(del);
  }
  box.appendChild(who);
  box.appendChild(el('div','body', c.body));
  return box;
}

function commentForm(tgt){
  const form = el('div','cform');
  if(tgt.lineEnd){ form.appendChild(el('div','crange', '範囲コメント: '+tgt.side+' L'+tgt.line+'–'+tgt.lineEnd+'（shift+クリックで範囲変更）')); }
  const ta = el('textarea'); ta.placeholder='コメントを書く…（shift+クリックで複数行を選択）'; ta.id='cf-active'; ta.value=state.draft||'';
  ta.oninput = ()=>{ state.draft = ta.value; };
  const actions = el('div','actions');
  const submit = el('button','btn','コメント');
  submit.onclick = async ()=>{
    const body = ta.value.trim(); if(!body) return;
    const payload = {file:tgt.file, side:tgt.side, line:tgt.line, body, author:'human'};
    if(tgt.lineEnd) payload.line_end = tgt.lineEnd;
    closeForm();
    await postJSON('/api/comments', payload);
    await loadAll();
  };
  const cancel = el('button','btn ghost','キャンセル');
  cancel.onclick = ()=>{ closeForm(); render(); };
  actions.appendChild(submit); actions.appendChild(cancel);
  form.appendChild(ta); form.appendChild(actions);
  return form;
}

function replyForm(parentId){
  const form = el('div','cform');
  const ta = el('textarea'); ta.placeholder='返信…';
  const actions = el('div','actions');
  const submit = el('button','btn ghost','返信');
  submit.onclick = async ()=>{
    const body = ta.value.trim(); if(!body) return;
    await postJSON('/api/comments/reply', {parent_id:parentId, body, author:'human'});
    await loadAll();
  };
  actions.appendChild(submit);
  form.appendChild(ta); form.appendChild(actions);
  return form;
}

function openForm(file, side, line, lineEnd){
  const start = (lineEnd!=null) ? Math.min(line, lineEnd) : line;
  const end   = (lineEnd!=null) ? Math.max(line, lineEnd) : line;
  state.pending = {file, side, start, end};
  state.draft = '';
  render();
  restoreForm();
}
function closeForm(){ state.draft=''; state.pending=null; }
function restoreForm(){
  const ta = document.getElementById('cf-active');
  if(ta){ ta.focus(); ta.scrollIntoView({block:'center', behavior:'smooth'}); }
}

async function refresh(){
  const sy = window.scrollY;
  await loadAll();
  window.scrollTo(0, sy);
}

document.getElementById('modebtn').onclick = ()=>{
  state.mode = state.mode==='split' ? 'unified' : 'split';
  localStorage.setItem('diffReviewMode', state.mode);
  render();
};

document.getElementById('cmtbtn').onclick = ()=>{
  state.commentsHidden = !state.commentsHidden;
  localStorage.setItem('diffReviewCommentsHidden', state.commentsHidden ? '1' : '0');
  closeForm(); // 非表示にする瞬間に編集中フォームを残さない
  render();
};

document.getElementById('clearbtn').onclick = async ()=>{
  if(!state.comments.length) return;
  if(!window.confirm('すべてのコメントを削除します（'+state.comments.length+'件、元に戻せません）。よろしいですか？')) return;
  await postJSON('/api/comments/clear', {});
  closeForm();
  await loadAll();
};

document.getElementById('treebtn').onclick = ()=>{
  state.treeCollapsed = !state.treeCollapsed;
  localStorage.setItem('diffReviewTreeCollapsed', state.treeCollapsed ? '1' : '0');
  applyTreeCollapsed();
};
applyTreeCollapsed();

document.querySelectorAll('#viewseg button').forEach(b=>{
  b.onclick = ()=>{
    if(state.view===b.dataset.view) return;
    state.view = b.dataset.view;
    localStorage.setItem('diffReviewView', state.view);
    closeForm(); // ビューをまたぐ編集中フォームは畳む
    loadAll(); // 選択ビューの diff を取り直して再描画
  };
});

loadAll();
setInterval(async ()=>{
  try{
    const v = (await (await fetch('/__version')).text()).trim();
    if(state.version!==null && v!==state.version){ await refresh(); }
    state.version = v;
    document.getElementById('status').textContent='Connected';
  }catch(e){ document.getElementById('status').textContent='Disconnected'; }
}, 1000);
</script>
</body>
</html>]==]

--- 完全な HTML を返す。opts.repo_root はタイトルに使う。
function M.render(opts)
  opts = opts or {}
  local title = 'Diff Review'
  if opts.repo_root and opts.repo_root ~= '' then
    title = 'Diff Review · ' .. vim.fn.fnamemodify(opts.repo_root, ':t')
  end
  -- 関数置換にして、タイトルに `%` が含まれても gsub の置換パターンとして解釈されないようにする。
  return (PAGE:gsub('__TITLE__', function() return html_escape(title) end))
end

M._private = {
  html_escape = html_escape,
  PAGE = PAGE,
}

return M
