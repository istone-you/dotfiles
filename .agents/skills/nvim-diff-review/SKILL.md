---
name: nvim-diff-review
description: >-
  Read and write inline review comments on a Neovim "Diff Review" session over its
  local HTTP API (curl + jq). Use when the user opened a diff review in their browser
  from Neovim (:DiffReview / <leader>R) and wants to discuss the diff with you — read
  the diff, read their comments, and leave/reply to inline comments on specific lines.
  差分レビュー(nvim の Diff Review)上で AI がコメントを読み書きしたいときに使う。
---

# Neovim Diff Review

Neovim の自作機能「Diff Review」は、作業ツリーの差分をブラウザ(difit 風)で開き、その差分上で
人間と AI が**双方向にコメント**をやりとりするためのもの。実体は nvim が立てるローカル HTTP
サーバで、コメントは JSON API で読み書きできる。ブラウザは自動でポーリングするので、AI が付けた
コメントは人間の画面にすぐ現れる。

The UI (the browser page) is for the human. Your job is to read the diff, read what the human
wrote, and leave focused inline comments through the HTTP API below.

If no session is found, ask the user to open one in Neovim with `:DiffReview` (or `<leader>R`).

## 1. Find the session (repo → port)

Sessions are advertised in a small registry file. Resolve the current repo and look up its port:

```bash
REPO=$(git rev-parse --show-toplevel)
REG="${XDG_CACHE_HOME:-$HOME/.cache}/nvim/diff-review/sessions.json"
PORT=$(jq -r --arg r "$REPO" '[.[] | select(.repoRoot==$r)] | sort_by(-.startedAt) | .[0].port // empty' "$REG")
BASE="http://localhost:$PORT"
echo "$BASE"
```

- If `PORT` is empty, list everything and pick by hand: `jq . "$REG"`.
- The same repo can be open in more than one nvim, so there may be several entries for it.
  The query above takes the most recently started one; if that turns out to be the wrong window,
  run `jq . "$REG"` and pick by `pid`.
- Confirm the session is live: `curl -s "$BASE/api/session" | jq` → `{repoRoot, source, port, version}`.
- `version` bumps on every diff rebuild and every comment change; poll it if you want to notice
  the human replying.

## 2. Read the diff

```bash
curl -s "$BASE/api/diff" | jq '.files[] | {path, status, added, deleted}'      # overview
curl -s "$BASE/api/diff" | jq '.files[] | select(.path=="web/src/App.tsx")'    # one file, full hunks
```

Structure: `files[] → {path, old_path, new_path, status(A|M|D|R), added, deleted, binary, hunks[]}`,
each hunk `→ {header, old_start, old_lines, new_start, new_lines, lines[]}`, each line
`→ {type: "context"|"add"|"del", content, old_line, new_line}` (the side that doesn't apply is `null`).

Use `new_line` to point at added/changed code, `old_line` to point at removed code.

### Views (which diff you're looking at)

On `/api/diff`, `?view=` selects which diff to fetch (default `uncommitted`). On `/api/comments`,
`?view=` filters to one comment bucket (see below).

- `uncommitted` — working tree vs `HEAD` (staged + unstaged + untracked = not-yet-committed changes).
  **The default review surface.** (Old name `all` still works as an alias.)
- `committed` — **default branch vs `HEAD` via merge-base** = the commits this branch added on top of
  the default branch, *including already-pushed commits* (like a PR diff:
  `git diff $(git merge-base <base> HEAD) HEAD`). `uncommitted` and `committed` don't overlap — they
  meet at `HEAD` — so together they are the branch's whole delta vs the default branch.
- `unstaged` — working tree vs index. A read-only lens on `uncommitted` (no comment bucket of its own).
- `staged` — index vs `HEAD`. A read-only lens on `uncommitted` (no comment bucket of its own).

Only `uncommitted` and `committed` are comment surfaces; `unstaged`/`staged` just re-slice the working
tree for viewing. In the UI they are a small `All / Unstaged / Staged` switch above the file tree,
shown only while an `Uncommitted`-family view is selected.

```bash
curl -s "$BASE/api/session" | jq '{views, branchBase}'   # branchBase = {ref, merge_base} or null
curl -s "$BASE/api/diff?view=committed" | jq '.files[] | {path, status, added, deleted}'
```

`branchBase` is the base the `committed` view compares against (`{ref, merge_base}`); it is `null`
when no default branch resolves (`origin/HEAD` → `main`/`master`), and then the `committed` view is
empty and the UI's Committed tab is disabled.

## 3. Read comments

```bash
curl -s "$BASE/api/comments" | jq '.comments'                         # flat list
curl -s "$BASE/api/comments" | jq '.threads'                          # grouped: top-level + .replies[]
curl -s "$BASE/api/comments?file=web/src/App.tsx" | jq '.threads'     # one file
curl -s "$BASE/api/comments?author=human" | jq '.comments'            # only the human's notes
curl -s "$BASE/api/comments?view=committed" | jq '.comments'          # only the committed-view bucket
```

Each comment: `{id, file, view("uncommitted"|"committed"), side("old"|"new"), line, line_end?, body, author, created_at, parent_id, outdated}`.
Top-level comments have `parent_id: null`; replies carry their thread's `parent_id`.

`view` is the diff bucket the comment belongs to (see Views above): comments made on the `uncommitted`
surface and on the `committed` surface are **separate sets**, each anchored to its own diff. Filter by
`?view=` to read one bucket. `unstaged`/`staged` have no bucket of their own — they display the
`uncommitted` comments read-only. (A `?view=all` filter still resolves to the `uncommitted` bucket.)

`GET /api/comments` **without** `?view=` returns *every* bucket (no filter) — same semantics as the
`file`/`author` filters. Pass `?view=uncommitted` or `?view=committed` to read one bucket.

Comments are anchored by line content: when the diff changes, the server re-anchors each comment to
the line it was placed on (following it if it moved). If that line no longer exists in the diff, the
comment is kept but marked `"outdated": true` (it drops out of the inline view into an "outdated" list).
You don't manage this — just be aware a listed comment may be `outdated` after the code changed.

## 4. Add a comment

`file` is the path as shown in `/api/diff` (repo-relative). Give exactly one target — the convenient
`new_line` / `old_line`, or the explicit `side` + `line`. Use a stable `author` (e.g. `"claude"`) so
the human can tell your notes apart from theirs.

```bash
curl -s -X POST "$BASE/api/comments" -H 'Content-Type: application/json' -d '{
  "file": "web/src/App.tsx",
  "new_line": 128,
  "body": "This effect re-subscribes on every render; the deps array is missing `userId`.",
  "author": "claude"
}' | jq
```

Comment on a removed line instead:

```bash
curl -s -X POST "$BASE/api/comments" -H 'Content-Type: application/json' \
  -d '{"file":"api/handler.go","old_line":40,"body":"Was this guard intentional to drop?","author":"claude"}' | jq
```

Range (multi-line) comment — add `line_end` (must be >= the start line, same side):

```bash
curl -s -X POST "$BASE/api/comments" -H 'Content-Type: application/json' \
  -d '{"file":"web/src/App.tsx","new_line":40,"line_end":52,"body":"This whole block can be extracted into a hook.","author":"claude"}' | jq
```

On success you get `{ "comment": { "id": "c7", ... } }`. On bad input you get `400` with `{ "error": ... }`
(missing `file` / `body`, or no/invalid line target).

To comment on the **committed** diff (default-branch/PR review) instead of the working tree, add
`"view":"committed"` and target lines from `/api/diff?view=committed` (omit `view`, or pass
`"uncommitted"`, for the default working-tree surface):

```bash
curl -s -X POST "$BASE/api/comments" -H 'Content-Type: application/json' \
  -d '{"file":"api/handler.go","new_line":72,"view":"committed","body":"This landed in an earlier push but still leaks the connection.","author":"claude"}' | jq
```

## 5. Reply in a thread

Replies inherit the thread's file/side/line — you only pass the `parent_id`:

```bash
curl -s -X POST "$BASE/api/comments/reply" -H 'Content-Type: application/json' \
  -d '{"parent_id":"c3","body":"Good point — I will add the dependency and re-test.","author":"claude"}' | jq
```

## 6. Manage your own notes (optional)

```bash
curl -s -X POST "$BASE/api/comments/delete" -H 'Content-Type: application/json' -d '{"id":"c7"}' | jq
curl -s -X POST "$BASE/api/comments/clear"  -H 'Content-Type: application/json' -d '{"author":"claude"}' | jq   # clear only yours
curl -s -X POST "$BASE/api/comments/clear"  -H 'Content-Type: application/json' -d '{"view":"committed"}' | jq  # clear only the committed bucket
curl -s -X POST "$BASE/api/comments/clear"  -H 'Content-Type: application/json' -d '{}' | jq                    # clear all
```

## Reviewing well

- Read the whole diff first (`/api/diff`), then read any existing human comments before adding yours.
- Comment on the lines that matter — bugs, risks, unclear intent, missing tests — not every hunk.
- Keep each comment to one concrete point; put the target on the exact line it refers to.
- Prefer `new_line` for added/changed code and `old_line` for something that was removed.
- When the human replies (poll `/api/comments` or `/api/session` `version`), answer in the same thread
  with `reply`, don't open a new top-level comment.

## Troubleshooting

- **Empty `PORT`** — no session for this repo. Ask the user to run `:DiffReview` in that repo's Neovim.
- **`curl: connection refused`** — the session was closed (`:DiffReviewClose` or Neovim quit). The
  registry entry is pruned on quit; re-check `sessions.json`.
- **localhost blocked** — if the agent sandbox blocks localhost, retry with network/sandbox escalation.
- **`400 line must be a positive integer`** — you passed `new_line`/`old_line` as `null` (that side
  doesn't exist for the line). Point at the side that has a real number.
