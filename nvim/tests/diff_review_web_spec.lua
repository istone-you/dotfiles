local T = dofile(TESTS_DIR .. '/helpers.lua')
local web = require('config.diff_review.web')

T.describe('diff_review/web.lua', function()
  T.it('renders a self-contained page with the app mount point', function()
    local html = web.render({})
    T.contains(html, '<!doctype html>')
    T.contains(html, 'id="app"')
    T.eq(html:find('__TITLE__', 1, true), nil)
  end)

  T.it('fetches the diff and comment APIs and polls the version', function()
    local html = web.render({})
    T.contains(html, '/api/diff')
    T.contains(html, '/api/comments')
    T.contains(html, '/api/jump')
    T.contains(html, '/api/session')
    T.contains(html, '/__version')
    T.contains(html, '/api/comments/reply')
  end)

  T.it('ships nvim jump controls on file headers and line numbers', function()
    local html = web.render({})
    T.contains(html, 'Open in nvim')
    T.contains(html, 'function openInNvim')
    T.contains(html, 'function lineCell')
    T.contains(html, 'jumpable')
  end)

  T.it('ships the unified/side-by-side toggle persisted in localStorage', function()
    local html = web.render({})
    T.contains(html, 'id="modebtn"')
    T.contains(html, 'diffReviewMode')
    T.contains(html, 'renderHunkSplit')
    T.contains(html, 'renderHunkUnified')
  end)

  T.it('ships the all/unstaged/staged view toggle (comments only in all)', function()
    local html = web.render({})
    T.contains(html, 'id="viewseg"')
    T.contains(html, 'data-view="staged"')
    T.contains(html, 'diffReviewView')
    T.contains(html, 'function commentable')
    T.contains(html, '/api/diff?view=')
  end)

  T.it('ships a changed-file tree sidebar', function()
    local html = web.render({})
    T.contains(html, 'id="tree"')
    T.contains(html, 'function buildTree')
    T.contains(html, 'function renderTree')
    T.contains(html, 'scrollIntoView')
  end)

  T.it('loads syntax highlighting from vendored highlight.js', function()
    local html = web.render({})
    T.contains(html, '/__vendor/highlight.min.js')
    T.contains(html, '/__vendor/highlight-theme.css')
    T.contains(html, 'hljs.highlight')
  end)

  T.it('supports range (multi-line) comments and generated-file collapse', function()
    local html = web.render({})
    T.contains(html, 'function isGenerated')      -- lock/generated auto-collapse
    T.contains(html, 'shouldCollapse')
    T.contains(html, 'line_end')                  -- range comment payload
    T.contains(html, 'range-sel')
  end)

  T.it('has a bottom section for comments whose file left the diff', function()
    local html = web.render({})
    T.contains(html, 'function renderGoneSection')
    T.contains(html, 'No longer in diff')
    T.contains(html, 'Not in this view')   -- All 以外のビューでの見出し
  end)

  T.it('hangs a comment index (jump targets, not bodies) under the tree files', function()
    local html = web.render({})
    T.contains(html, 'function commentsOf')
    T.contains(html, 'function commentIndexRow')
    T.contains(html, 'tcomment')
    T.contains(html, 'commentIndexRow(c, 6+depth*12+28)')  -- ファイル行の下にぶら下げる
    T.contains(html, 'function renderTreeGone')            -- 差分に出ないファイル用の擬似ノード
  end)

  T.it('jumps from the index to the thread by comment id, expanding collapsed files', function()
    local html = web.render({})
    T.contains(html, 'function jumpToComment')
    T.contains(html, "wrap.id = 'c-'+top.id")              -- スレッド側のジャンプ先 id
    T.contains(html, "document.getElementById('c-'+c.id)")
    T.contains(html, 'state.fileCollapse[c.file] = false') -- 畳まれていたら開いてから飛ぶ
    T.contains(html, 'threadflash')                        -- 着地点を光らせる
  end)

  T.it('still renders comment threads on binary files (no table, but a jump target)', function()
    local html = web.render({})
    -- バイナリで早期 return すると目次から飛べない行ができるので、orphans まで通していること
    T.contains(html, 'if(f.binary){')
    T.contains(html, 'バイナリファイル(差分表示なし)')
    local binary_at = html:find('バイナリファイル(差分表示なし)', 1, true)
    local orphans_at = html:find('const orphans = visibleComments()', 1, true)
    T.ok(binary_at and orphans_at and binary_at < orphans_at, 'orphans block must follow the binary branch')
    T.eq(html:find('box.appendChild(b); return box;', 1, true), nil)
  end)

  T.it('can hide all comment UI to focus on the diff alone', function()
    local html = web.render({})
    T.contains(html, 'id="cmtbtn"')
    T.contains(html, 'diffReviewCommentsHidden')        -- localStorage に残す
    T.contains(html, 'state.commentsHidden')
    -- 非表示中は新規コメントもできない(見えないものにフォームだけ出さない)
    T.contains(html, "state.view==='all' && !state.commentsHidden")
    T.contains(html, 'function visibleComments')  -- 非表示判定の入口はここ1箇所
  end)

  T.it('has a delete-all-comments button guarded by a confirm dialog', function()
    local html = web.render({})
    T.contains(html, 'id="clearbtn"')
    T.contains(html, '/api/comments/clear')
    T.contains(html, 'window.confirm')
    -- 押せないときも消さない(消すとヘッダーのボタン位置がずれる)
    T.contains(html, "getElementById('clearbtn').disabled")
    T.eq(html:find('id="clearbtn" title="すべてのコメントを削除" style="display:none"', 1, true), nil)
  end)

  T.it('puts the repo basename in the title', function()
    local html = web.render({ repo_root = '/home/me/project' })
    T.contains(html, '<title>Diff Review · project</title>')
  end)

  T.it('escapes html in the title', function()
    local html = web.render({ repo_root = '/tmp/a<b' })
    T.contains(html, 'a&lt;b')
  end)
end)

T.summary()
