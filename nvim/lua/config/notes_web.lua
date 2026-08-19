-- メモ帳（config.notes）をブラウザで読むための単一サーバ。ポートは 1 つで 2 ページを配る。
--   /      notes/md/ の *.md 一覧。左で選んだメモを右に Markdown レンダリングして表示する
--   /html  notes/html/ の *.html 一覧。クリックすると /html/<name> でその html 自体を開く
-- 上部のリンクで行き来する。メモ 1 件ごとにサーバを立てるとポートを食うので、両方ここに載せる。
--
-- Markdown → HTML の変換とスタイルは config.browser.markdown を共有する。
-- 更新は /__version（両ディレクトリの名前・サイズ・mtime から作る印）をブラウザが毎秒見て検知する。

local M = {}
local browser = require('config.browser.util')
local http = require('config.browser.server')

local state = {
  server = nil,
  port = nil,
  host = nil,
}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'Notes Browser' })
end

-- config.notes からは起動時にこのモジュールを読むので、require は関数内で行い循環を避ける。
local function notes_dir()
  return require('config.notes').dir()
end

local function html_dir()
  return require('config.notes').html_dir()
end

local function markdown()
  return require('config.browser.markdown')
end

local function html_escape(s)
  return (tostring(s or ''):gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'))
end

--- メモの表示名。本文の先頭の非空行（先頭の # は外す）、無ければファイル名（.md 抜き）。
function M.title_from_lines(lines, name)
  for _, line in ipairs(lines or {}) do
    if not line:match('^%s*$') then
      local title = vim.trim(line:gsub('^%s*#+%s*', ''))
      if title ~= '' then return title end
    end
  end
  return (tostring(name or ''):gsub('%.md$', ''))
end

--- html の表示名。<title> → 最初の <h1> → ファイル名（.html 抜き）の順で拾う。
function M.html_title_from_lines(lines, name)
  local body = table.concat(lines or {}, '\n')
  for _, pattern in ipairs({ '<title[^>]*>(.-)</title>', '<h1[^>]*>(.-)</h1>' }) do
    local found = body:match(pattern)
    if found then
      local title = vim.trim(found:gsub('<[^>]*>', ''):gsub('%s+', ' '))
      if title ~= '' then return title end
    end
  end
  return (tostring(name or ''):gsub('%.html?$', ''))
end

--- ディレクトリ直下の *.md だけを扱う（notes/md/ はフラット）。`/` を含む名前は受け付けない。
function M.valid_name(name)
  name = tostring(name or '')
  if name == '' or name:find('/', 1, true) or name:find('%z') then return false end
  if name:find('..', 1, true) then return false end
  return name:match('%.md$') ~= nil
end

local function read_lines(path)
  if vim.fn.filereadable(path) ~= 1 then return nil end
  return vim.fn.readfile(path)
end

--- ディレクトリ直下の該当ファイルを { name, title, mtime } にして更新の新しい順に返す。
local function list_dir(dir, pattern, title_of)
  if not dir or vim.fn.isdirectory(dir) ~= 1 then return {} end
  local uv = vim.uv or vim.loop
  local out = {}
  for _, name in ipairs(vim.fn.readdir(dir)) do
    if name:match(pattern) then
      local st = uv.fs_stat(dir .. '/' .. name)
      if st and st.type == 'file' then
        local lines = read_lines(dir .. '/' .. name) or {}
        out[#out + 1] = {
          name = name,
          title = title_of(lines, name),
          mtime = (st.mtime or {}).sec or 0,
        }
      end
    end
  end
  table.sort(out, function(a, b)
    if a.mtime ~= b.mtime then return a.mtime > b.mtime end
    return a.name > b.name
  end)
  return out
end

--- メモ一覧。
function M.list_notes(dir)
  return list_dir(dir, '%.md$', M.title_from_lines)
end

--- html 一覧。
function M.list_html(dir)
  return list_dir(dir, '%.html?$', M.html_title_from_lines)
end

--- ディレクトリの状態を表す印。ファイルの増減・書き換えで変わる（ブラウザ側の再読込トリガ）。
--- 両ページが同じ /__version を見るので、md と html の両方を混ぜて 1 本の印にする。
local function dir_stamp(dir, pattern)
  if not dir or vim.fn.isdirectory(dir) ~= 1 then return '' end
  local uv = vim.uv or vim.loop
  local names = vim.fn.readdir(dir)
  table.sort(names)
  local parts = {}
  for _, name in ipairs(names) do
    if name:match(pattern) then
      local st = uv.fs_stat(dir .. '/' .. name)
      if st then
        local mtime = st.mtime or {}
        parts[#parts + 1] = table.concat({
          name, tostring(st.size or 0), tostring(mtime.sec or 0), tostring(mtime.nsec or 0),
        }, ':')
      end
    end
  end
  return table.concat(parts, '\n')
end

function M.version(dir, html)
  local raw = dir_stamp(dir, '%.md$') .. '\0' .. dir_stamp(html, '%.html?$')
  if raw == '\0' then return 'empty' end
  return tostring(vim.fn.sha256(raw))
end

--- 1 件のメモを { name, title, html } に。読めなければ nil, エラーメッセージ。
function M.note_payload(dir, name)
  if not M.valid_name(name) then return nil, 'invalid note name' end
  local lines = read_lines(dir .. '/' .. name)
  if not lines then return nil, 'note not found' end
  return {
    name = name,
    title = M.title_from_lines(lines, name),
    html = markdown().render_body(lines),
  }
end

local PAGE = [==[<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Notes</title>
<style>
__CSS__
/* 一覧（左）と本文（右）の 2 ペイン。本文だけがスクロールし、一覧は固定。 */
*{box-sizing:border-box}
body{overflow:hidden}
.topbar{display:flex;align-items:center;gap:10px;height:44px;padding:0 14px;background:#111827;border-bottom:1px solid #253044;}
.topbar strong{font-size:14px;font-weight:650;color:#f9fafb}
.topbar .meta{color:#9aa4b2;font-size:12px}
.topbar .spacer{flex:1}
.topbar .nav{color:#93c5fd;font-size:12.5px;text-decoration:none;border:1px solid #253044;border-radius:6px;padding:3px 9px}
.topbar .nav:hover{background:#172033}
#layout{display:grid;grid-template-columns:minmax(240px,330px) 1fr;height:calc(100vh - 44px);min-height:0}
#side{border-right:1px solid #253044;display:flex;flex-direction:column;min-height:0}
#filterbox{padding:10px}
#filter{width:100%;background:#0b1220;color:#e5e7eb;border:1px solid #253044;border-radius:6px;padding:6px 9px;font:13px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
#filter:focus{outline:none;border-color:#374151}
#list{overflow-y:auto;min-height:0;flex:1}
.row{padding:9px 12px;border-bottom:1px solid #1b2434;cursor:pointer}
.row:hover{background:#172033}
.row.active{background:#172033;border-left:2px solid #93c5fd;padding-left:10px}
.row .t{font-size:13.5px;color:#e5e7eb;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#pane{overflow:auto;min-height:0}
main{padding:32px 44px 80px}
.empty{color:#9aa4b2;padding:36px;text-align:center}
@media(max-width:760px){#layout{grid-template-columns:1fr;grid-template-rows:minmax(160px,34vh) 1fr}#side{border-right:0;border-bottom:1px solid #253044}main{padding:24px 20px 60px}}
</style>
<link rel="stylesheet" href="/__vendor/highlight-theme.css">
<script src="/__vendor/highlight.min.js"></script>
</head>
<body>
<div class="topbar"><strong>Notes</strong><span class="meta" id="count"></span><span class="spacer"></span><span class="meta" id="status"></span><a class="nav" href="/html">HTML →</a></div>
<div id="layout">
  <aside id="side">
    <div id="filterbox"><input id="filter" placeholder="絞り込み（タイトル）" autocomplete="off"></div>
    <div id="list"></div>
  </aside>
  <section id="pane"><main id="content"></main></section>
</div>
<script>
const state={notes:[],selected:localStorage.getItem('notesWebSelected')||null,version:null,filter:''};
const $=id=>document.getElementById(id);
function esc(s){return String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));}
async function getJSON(p){const r=await fetch(p);return r.json();}
function visible(){
  const q=state.filter.toLowerCase();
  if(!q) return state.notes;
  return state.notes.filter(n=>n.title.toLowerCase().includes(q));
}
// mermaid は 3MB 超あるので、図を含むメモを開いたときにだけ読み込む。
let mermaidLoad=null,mermaidReady=false;
function loadMermaid(){
  if(!mermaidLoad){
    mermaidLoad=new Promise((res,rej)=>{
      const s=document.createElement('script');
      s.src='/__vendor/mermaid.min.js';s.onload=res;s.onerror=rej;
      document.head.appendChild(s);
    });
  }
  return mermaidLoad;
}
async function renderExtras(root){
  if(window.hljs){
    root.querySelectorAll('pre code').forEach(el=>{try{hljs.highlightElement(el);}catch(e){}});
  }
  const nodes=root.querySelectorAll('.mermaid');
  if(!nodes.length) return;
  try{
    await loadMermaid();
    if(!window.mermaid) return;
    if(!mermaidReady){mermaid.initialize({startOnLoad:false,theme:'dark',securityLevel:'strict'});mermaidReady=true;}
    if(typeof mermaid.run==='function'){await mermaid.run({nodes:Array.from(nodes)});}
    else{mermaid.init(undefined,nodes);}
  }catch(e){}
}
function renderList(){
  const list=$('list'),items=visible();
  $('count').textContent=state.notes.length?`${items.length} / ${state.notes.length}`:'';
  list.innerHTML='';
  if(!items.length){list.innerHTML='<div class="empty">メモはありません</div>';return;}
  for(const n of items){
    const row=document.createElement('div');
    row.className='row'+(n.name===state.selected?' active':'');
    row.innerHTML=`<div class="t">${esc(n.title)}</div>`;
    row.onclick=()=>select(n.name);
    list.appendChild(row);
  }
}
async function showNote(name){
  const c=$('content');
  if(!name){c.innerHTML='<div class="empty">左からメモを選択</div>';return;}
  try{
    const d=await getJSON('/api/note?name='+encodeURIComponent(name));
    if(d.error){c.innerHTML='<div class="empty">'+esc(d.error)+'</div>';return;}
    c.innerHTML=d.html||'';
    document.title=d.title?d.title+' - Notes':'Notes';
    await renderExtras(c);
  }catch(e){c.innerHTML='<div class="empty">読み込めませんでした</div>';}
}
async function select(name){
  state.selected=name;
  localStorage.setItem('notesWebSelected',name);
  $('pane').scrollTop=0;
  renderList();
  await showNote(name);
}
async function load(){
  try{
    const d=await getJSON('/api/notes');
    state.notes=d.notes||[];state.version=String(d.version);
    $('status').textContent='';
    if(state.selected&&!state.notes.find(n=>n.name===state.selected)) state.selected=null;
    if(!state.selected&&state.notes[0]) state.selected=state.notes[0].name;
    renderList();
    await showNote(state.selected);
  }catch(e){$('status').textContent='接続できません';}
}
$('filter').addEventListener('input',e=>{state.filter=e.target.value;renderList();});
// j/k と ↑↓ で一覧を移動（絞り込み入力中は入力を優先）。
document.addEventListener('keydown',e=>{
  if(e.target===$('filter')&&e.key!=='ArrowDown'&&e.key!=='ArrowUp') return;
  let step=0;
  if(e.key==='j'||e.key==='ArrowDown') step=1;
  else if(e.key==='k'||e.key==='ArrowUp') step=-1;
  else if(e.key==='/'){e.preventDefault();$('filter').focus();return;}
  if(!step) return;
  const items=visible();if(!items.length) return;
  e.preventDefault();
  const i=items.findIndex(n=>n.name===state.selected);
  const next=items[Math.min(Math.max((i<0?0:i)+step,0),items.length-1)];
  if(next&&next.name!==state.selected) select(next.name);
});
setInterval(async()=>{
  try{
    const v=await fetch('/__version').then(r=>r.text());
    if(state.version!=null&&v!==state.version) await load();
  }catch(e){}
},1000);
load();
</script>
</body>
</html>]==]

--- メモ一覧ページ。プレビュー本文のスタイルは browser/markdown.lua と共有する。
function M.page()
  -- gsub の置換文字列は % が特別扱いなので、CSS（width:100% など）は関数で返す。
  return (PAGE:gsub('__CSS__', function() return markdown().preview_css() end))
end

-- html 一覧ページ。md 側と違い本文は出さない（端末でも読めない html を読むための画面ではなく、
-- 出来上がった html そのものを開くための入口）。行はただのリンクで、押すと /html/<name> へ遷移する。
local HTML_PAGE = [==[<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="notes-version" content="__VERSION__">
<title>HTML</title>
<style>
*{box-sizing:border-box}
body{margin:0;background:#111827;color:#e5e7eb;font:14px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
.topbar{display:flex;align-items:center;gap:10px;height:44px;padding:0 14px;background:#111827;border-bottom:1px solid #253044;position:sticky;top:0}
.topbar strong{font-size:14px;font-weight:650;color:#f9fafb}
.topbar .meta{color:#9aa4b2;font-size:12px}
.topbar .spacer{flex:1}
.topbar .nav{color:#93c5fd;font-size:12.5px;text-decoration:none;border:1px solid #253044;border-radius:6px;padding:3px 9px}
.topbar .nav:hover{background:#172033}
#wrap{max-width:760px;margin:0 auto;padding:18px 20px 60px}
#filter{width:100%;background:#0b1220;color:#e5e7eb;border:1px solid #253044;border-radius:6px;padding:8px 10px;font:13px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;margin-bottom:14px}
#filter:focus{outline:none;border-color:#374151}
.row{display:block;padding:11px 12px;border:1px solid #253044;border-radius:8px;margin-bottom:8px;color:#e5e7eb;text-decoration:none;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.row:hover{background:#172033;border-color:#374151}
.empty{color:#9aa4b2;padding:36px;text-align:center}
</style>
</head>
<body>
<div class="topbar"><strong>HTML</strong><span class="meta" id="count"></span><span class="spacer"></span><a class="nav" href="/">← Notes</a></div>
<div id="wrap">
  <input id="filter" placeholder="絞り込み（タイトル）" autocomplete="off">
  <div id="list">__ROWS__</div>
</div>
<script>
const rows=[].slice.call(document.querySelectorAll('#list .row'));
const count=document.getElementById('count');
function apply(){
  const q=document.getElementById('filter').value.toLowerCase();
  let n=0;
  for(const r of rows){
    const hit=!q||r.textContent.toLowerCase().includes(q);
    r.style.display=hit?'':'none';
    if(hit) n++;
  }
  count.textContent=rows.length?(n+' / '+rows.length):'';
}
document.getElementById('filter').addEventListener('input',apply);
apply();
const v=document.querySelector('meta[name=notes-version]').content;
setInterval(()=>fetch('/__version').then(r=>r.text()).then(n=>{if(n.trim()!==v)location.reload();}).catch(()=>{}),1000);
</script>
</body>
</html>]==]

function M.html_page(items, version)
  local rows = {}
  for _, it in ipairs(items or {}) do
    rows[#rows + 1] = string.format('<a class="row" href="/html/%s">%s</a>',
      browser.url_encode_path(it.name), html_escape(it.title))
  end
  local body = #rows > 0 and table.concat(rows, '\n') or '<div class="empty">html はありません</div>'
  return (HTML_PAGE
    :gsub('__VERSION__', function() return html_escape(version or '') end)
    :gsub('__ROWS__', function() return body end))
end

local VENDOR_FILES = {
  ['mermaid.min.js'] = true,
  ['highlight.min.js'] = true,
  ['highlight-theme.css'] = true,
}

local function json_response(status, tbl)
  return browser.http_response(status, 'application/json', vim.json.encode(tbl))
end

local function query_value(query, key)
  for pair in tostring(query or ''):gmatch('[^&]+') do
    local k, v = pair:match('^([^=]+)=?(.*)$')
    if k and browser.url_decode(k) == key then return browser.url_decode(v) end
  end
end

--- リクエスト 1 本ぶんのレスポンス文字列を組み立てる。
function M.build_response(req)
  local path = req.path
  local dir = notes_dir()
  local html = html_dir()

  if path == '/' or path == '/index.html' then
    return browser.http_response('200 OK', 'text/html', M.page())
  end
  if path == '/html' or path == '/html/' then
    return browser.http_response('200 OK', 'text/html',
      M.html_page(M.list_html(html), M.version(dir, html)))
  end
  -- html はそのまま開く（レンダリングも iframe も挟まない）。notes/html/ を root にして配るので、
  -- 相対パスのアセットを持つ html でもそのまま引ける。root 外は asset_response が弾く。
  local html_name = path:match('^/html/(.+)$')
  if html_name then
    return browser.asset_response(html, html_name)
  end
  if path == '/__version' then
    return browser.http_response('200 OK', 'text/plain', M.version(dir, html))
  end
  if path == '/api/notes' then
    return json_response('200 OK', { notes = M.list_notes(dir), version = M.version(dir, html) })
  end
  if path == '/api/note' then
    local payload, err = M.note_payload(dir, query_value(req.query, 'name'))
    if not payload then
      return json_response(err == 'note not found' and '404 Not Found' or '400 Bad Request', { error = err })
    end
    return json_response('200 OK', payload)
  end
  local vf = path:match('^/__vendor/([%w._-]+)$')
  if vf and VENDOR_FILES[vf] then
    return browser.vendor_response(vf)
  end
  -- メモから相対パスで貼った画像などは notes/ を root にして配る
  local asset = path:match('^/__asset/(.*)$')
  if asset then
    return browser.asset_response(dir, asset)
  end
  return browser.http_response('404 Not Found', 'text/plain', 'not found')
end

--- 一覧も本文も notes/ を読んで作るが、ハンドラが走る libuv のコールバックは fast event context で
--- readdir / readfile を呼べない。respond を受け取れるときはメインループへ戻してから答える
--- （code_notes の /api/jump と同じ手）。respond 無しの直接呼び出し（テスト）は同期のまま。
function M.response_for_request(req, respond)
  if respond then
    vim.schedule(function() respond(M.build_response(req)) end)
    return nil
  end
  return M.build_response(req)
end

function M.server_url()
  if not state.port then return nil end
  return 'http://localhost:' .. tostring(state.port) .. '/'
end

--- いま待ち受けているポート。止まっていれば nil。
function M.serving_port()
  return state.port
end

function M.start(port)
  if state.server and state.port == port then return true end
  if state.server then http.stop(state) end
  return http.start(state, port, {
    namespace = 'notes',
    default_host = '127.0.0.1',
    handler = function(req, respond) return M.response_for_request(req, respond) end,
  })
end

function M.stop()
  local port = state.port
  local had_server = state.server ~= nil
  http.stop(state)
  if had_server then
    notify('Notes browser を停止しました' .. (port and (': http://localhost:' .. tostring(port) .. '/') or ''))
  end
end

function M.open_on_port(port)
  local ok, err = M.start(port)
  if not ok then
    notify(err or 'failed to start notes browser server', vim.log.levels.ERROR)
    return
  end
  local url = M.server_url()
  browser.open_url(url, {
    fallback_message = 'Notes browser URL: ',
    namespace = 'notes',
    title = 'Notes Browser',
  })
  notify('Notes browser URL: ' .. url)
end

--- 一覧をブラウザで開く。起動済みならポートを聞き直さず同じ URL を開く。
function M.open()
  if state.server and state.port then
    local url = M.server_url()
    browser.open_url(url, {
      fallback_message = 'Notes browser URL: ',
      namespace = 'notes',
      title = 'Notes Browser',
    })
    notify('Notes browser URL: ' .. url)
    return
  end
  vim.ui.input({ prompt = 'Notes browser port: ' }, function(input)
    if input == nil then return end
    local port, err = browser.parse_port(input)
    if not port then
      if err then notify(err, vim.log.levels.ERROR) end
      return
    end
    M.open_on_port(port)
  end)
end

vim.api.nvim_create_user_command('NotesBrowser', function() M.open() end, {
  desc = 'メモ一覧をブラウザで開く（ポートは 1 つ）',
})

vim.api.nvim_create_user_command('NotesBrowserStop', function() M.stop() end, {
  desc = 'メモ一覧のブラウザサーバを止める',
})

M._private = {
  html_escape = html_escape,
  json_response = json_response,
  query_value = query_value,
  state = state,
}

return M
