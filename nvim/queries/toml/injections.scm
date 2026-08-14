((comment) @injection.content
  (#set! injection.language "comment"))

; mise tasks ("run") — yaml/injections.scm の Taskfile/CI 向け bash 注入と同趣旨
(pair
  (bare_key) @_run
  (#eq? @_run "run")
  (string) @injection.content
  (#match? @injection.content "^[\"']{3}")
  (#offset! @injection.content 0 3 0 -3)
  (#set! injection.language "bash"))

(pair
  (bare_key) @_run
  (#eq? @_run "run")
  (string) @injection.content
  (#not-match? @injection.content "^[\"']{3}")
  (#offset! @injection.content 0 1 0 -1)
  (#set! injection.language "bash"))

(pair
  (bare_key) @_run
  (#eq? @_run "run")
  (array
    (string) @injection.content)
  (#not-match? @injection.content "^[\"']{3}")
  (#offset! @injection.content 0 1 0 -1)
  (#set! injection.language "bash"))

(pair
  (bare_key) @_run
  (#eq? @_run "run")
  (array
    (string) @injection.content)
  (#match? @injection.content "^[\"']{3}")
  (#offset! @injection.content 0 3 0 -3)
  (#set! injection.language "bash"))
