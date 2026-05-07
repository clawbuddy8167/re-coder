REBOL [
    Title:   {Re Coder RAG Cache — Persistent JSONL Cache with MD5}
    Name:    're-coder-rag-cache
    Purpose: {Persistent file content cache for RAG. JSONL format with MD5
              change detection. Avoids re-reading unchanged files.}
]

; ═══════════════════════════════════════════════════════════
;  Shared state
; ═══════════════════════════════════════════════════════════

cache-data:        copy #[]       ; file-path-string → entry map
cache-file-path:   none           ; path to cache.jsonl
cache-project-root: none          ; root directory
cache-extensions:  none           ; file extensions to track (block or none)
cache-stats:       make map! reduce [#hits 0 #misses 0 #updates 0 #deletes 0]

; ═══════════════════════════════════════════════════════════
;  MD5 helpers
; ═══════════════════════════════════════════════════════════

file-md5: func [
    file-path [file! string!]
    /local cmd out
] [
    ; Use head -1 to strip trailing newline reliably
    cmd: rejoin [{md5 -q } mold to-string to-rebol-file file-path { 2>/dev/null | head -1}]
    out: copy {}
    either zero? call/wait/shell/output cmd out [
        trim to-string out
    ][
        none
    ]
]

text-md5: func [
    content [string!]
    /local tmpfile result r
] [
    tmpfile: rejoin [{./.tmp-md5-} random 999999]
    r: to-rebol-file tmpfile
    write r content
    result: file-md5 tmpfile
    attempt [delete r]
    result
]

; ═══════════════════════════════════════════════════════════
;  Internal helpers
; ═══════════════════════════════════════════════════════════

map-to-jsonl: func [m [map!]] [
    out: copy {}
    foreach [k v] m [
        line: to-json v
        if string? line [append out rejoin [line newline]]
    ]
    out
]

remove-map-key: func [m [map!] key [string!] /local new] [
    new: copy #[]
    foreach [k v] m [
        unless k = key [put new k v]
    ]
    new
]

; Path normalization
norm-path: func [p [file! string!]] [
    trim to-string to-rebol-file p
]

; Strip project root prefix for relative path
rel-path: func [fpath-str [string!]] [
    either all [
        cache-project-root
        find fpath-str to-string cache-project-root
    ] [
        rel: copy at fpath-str (1 + length? to-string cache-project-root)
        if all [not empty? rel  (first rel) = #"/"] [rel: copy next rel]
        rel
    ][
        fpath-str
    ]
]

; ═══════════════════════════════════════════════════════════
;  Public API
; ═══════════════════════════════════════════════════════════

rag-cache-init: func [
    dir-path    [file! string! none!]
    /exts exts-block [block!]
    /local cache-dir-str
] [
    dir-path:          any [dir-path  %.]
    cache-project-root: to-rebol-file dir-path
    cache-extensions:   either exts [exts-block] [none]

    cache-dir-str: rejoin [cache-project-root {.cache/}]
    unless exists? to-rebol-file cache-dir-str [
        make-dir/deep to-rebol-file cache-dir-str
    ]

    cache-file-path: to-rebol-file rejoin [cache-dir-str {cache.jsonl}]

    ; Load existing cache
    cache-data: copy #[]
    if exists? cache-file-path [
        raw: any [attempt [to-string read cache-file-path] {}]
        unless empty? raw [
            foreach line split raw newline [
                line: trim line
                if empty? line [continue]
                parsed: attempt [load-json line]
                if all [map? parsed  select parsed 'file_path] [
                    put cache-data to-string select parsed 'file_path parsed
                ]
            ]
        ]
    ]

    cache-stats: make map! reduce [#hits 0 #misses 0 #updates 0 #deletes 0]
    print rejoin [{Cache loaded: } (length? cache-data) { entries}]
    cache-data
]

rag-cache-save: does [
    unless all [cache-file-path  cache-data] [return false]
    ; Write with temp + rename for atomicity
    tmp: to-rebol-file rejoin [to-string cache-file-path {.tmp}]
    write tmp map-to-jsonl cache-data
    attempt [delete cache-file-path]
    rename tmp cache-file-path
    true
]

rag-cache-get: func [
    file-path [file! string!]
    /local key entry cur-md5 old-md5
] [
    key: norm-path file-path
    entry: select cache-data key
    unless map? entry [
        cache-stats/misses: cache-stats/misses + 1
        return none
    ]

    ; Verify MD5 hasn't changed
    cur-md5: file-md5 file-path
    old-md5: select entry 'md5
    either all [string? cur-md5  string? old-md5  cur-md5 = old-md5] [
        cache-stats/hits: cache-stats/hits + 1
        entry
    ][
        cache-data: remove-map-key cache-data key
        cache-stats/misses: cache-stats/misses + 1
        none
    ]
]

rag-cache-put: func [
    file-path [file! string!]
    content   [string!]
    /local key entry
] [
    key: norm-path file-path
    entry: make map! reduce [
        #file_path     key
        #relative_path rel-path key
        #content       content
        #modify_time   now/precise
        #md5           any [text-md5 content {unknown}]
    ]
    put cache-data key entry
    cache-stats/updates: cache-stats/updates + 1
    entry
]

rag-cache-invalidate: func [
    file-path [file! string!]
    /local key
] [
    key: norm-path file-path
    if select cache-data key [
        cache-data: remove-map-key cache-data key
        cache-stats/deletes: cache-stats/deletes + 1
        return true
    ]
    false
]

rag-cache-scan: func [
    /dir dir-path [file! string!]
    /local scan-root files f f-str ext-matched keep? full-path r cur-md5 cached-entry cached-md5 content count
] [
    scan-root: either dir [to-rebol-file dir-path] [
        any [cache-project-root  %.]
    ]
    if none? scan-root [scan-root: %.]

    files: attempt [read scan-root]
    if none? files [return 0]

    count: 0
    foreach f files [
        f-str: to-string f

        ; Skip dot-files and common ignore dirs
        if any [
            find f-str {.git}  find f-str {node_modules}
            find f-str {__pycache__}  find f-str {.cache}
            find f-str {.hermes}  find f-str {.tmp-md5-}
        ] [continue]

        ; Extension filter
        ext-matched: either cache-extensions [
            keep?: false
            foreach ext cache-extensions [
                if find f-str to-string ext [keep?: true break]
            ]
            keep?
        ][true]
        unless ext-matched [continue]

        full-path: rejoin [scan-root f]
        r: to-rebol-file full-path
        if dir? r [continue]

        ; Use norm-path for consistent key lookup
        npath: norm-path full-path

        ; Check cache
        cur-md5: file-md5 full-path
        if none? cur-md5 [continue]

        cached-entry: select cache-data npath
        cached-md5: either map? cached-entry [select cached-entry 'md5] [none]
        if all [string? cached-md5  cached-md5 = cur-md5] [continue]

        ; Read and cache
        content: attempt [to-string read r]
        if string? content [
            entry: make map! reduce [
                #file_path     npath
                #relative_path rel-path npath
                #content       content
                #modify_time   now/precise
                #md5           cur-md5
            ]
            put cache-data npath entry
            count: count + 1
        ]
    ]

    cache-stats/updates: cache-stats/updates + count
    if count > 0 [rag-cache-save]
    count
]

rag-cache-paths: does [
    out: copy []
    foreach [k v] cache-data [append out k]
    out
]

rag-cache-stats: does [
    rejoin [
        {Cache: } (length? cache-data) { entries | }
        cache-stats/hits { hits, } cache-stats/misses { misses | }
        cache-stats/updates { updates, } cache-stats/deletes { deletes}
    ]
]

rag-cache-clear: does [
    cache-data: copy #[]
    cache-stats: make map! reduce [#hits 0 #misses 0 #updates 0 #deletes 0]
    if all [cache-file-path  exists? cache-file-path] [attempt [delete cache-file-path]]
]

rag-cache-load-all-content: func [/local result] [
    result: copy []
    foreach [k v] cache-data [
        if select v 'content [
            append result make map! reduce [
                #file k
                #content select v 'content
            ]
        ]
    ]
    result
]

print {re-coder-rag-cache loaded. Available: rag-cache-init, rag-cache-get, rag-cache-put, rag-cache-save, rag-cache-scan, rag-cache-paths, rag-cache-stats, rag-cache-clear}
