REBOL [
    Title:   {Re Coder RAG Cache Tests}
    Purpose: {Test suite for re-coder-rag-cache.reb}
]

do %./re-coder-rag-cache.reb

passed: 0
failed: 0

assert: func [condition description [string!]] [
    either all condition [
        print rejoin [{✓ PASS: } description]
        passed: passed + 1
    ][
        print rejoin [{✗ FAIL: } description]
        failed: failed + 1
    ]
]

; ═══════════════════════════════════════════════════════════
;  Setup
; ═══════════════════════════════════════════════════════════

test-dir-str: {./test-cache-fixtures/}
test-dir: to-rebol-file test-dir-str
make-dir/deep test-dir

write to-file rejoin [test-dir-str {a.py}] {def hello(): return "world"}
write to-file rejoin [test-dir-str {b.py}] {x = 42}
write to-file rejoin [test-dir-str {notes.md}] {# Notes}

to-file: func [s [string!]] [to-rebol-file s]

; ═══════════════════════════════════════════════════════════
;  Test 1: Init creates .cache dir, loads empty
; ═══════════════════════════════════════════════════════════

rag-cache-init test-dir
rag-cache-clear
assert [exists? to-file rejoin [test-dir-str {.cache/}]] "init creates .cache directory"
paths: rag-cache-paths
assert [empty? paths] "fresh cache has no entries"

; ═══════════════════════════════════════════════════════════
;  Test 2: Put and get
; ═══════════════════════════════════════════════════════════

path-a: rejoin [test-dir-str {a.py}]
rag-cache-put to-file path-a {def hello(): return "world"}
entry: rag-cache-get to-file path-a
assert [map? entry] "get returns map after put"
assert [(select entry 'md5) <> none] "entry has md5"
assert [(select entry 'content) = {def hello(): return "world"}] "entry has correct content"

; ═══════════════════════════════════════════════════════════
;  Test 3: Get returns none for uncached file
; ═══════════════════════════════════════════════════════════

entry: rag-cache-get to-file rejoin [test-dir-str {nonexistent.py}]
assert [none? entry] "get returns none for uncached file"

; ═══════════════════════════════════════════════════════════
;  Test 4: Get returns none when file changed (MD5 mismatch)
; ═══════════════════════════════════════════════════════════

path-b: rejoin [test-dir-str {b.py}]
rag-cache-put to-file path-b {x = 42}
write to-file path-b {y = 99}
entry: rag-cache-get to-file path-b
assert [none? entry] "get returns none when file changed (MD5 mismatch)"

; ═══════════════════════════════════════════════════════════
;  Test 5: Invalidate removes entry
; ═══════════════════════════════════════════════════════════

rag-cache-put to-file path-a {def hello(): return "world again"}
rag-cache-invalidate to-file path-a
entry: rag-cache-get to-file path-a
assert [none? entry] "get returns none after invalidate"

; ═══════════════════════════════════════════════════════════
;  Test 6: Scan populates cache
; ═══════════════════════════════════════════════════════════

rag-cache-clear
rag-cache-init test-dir
count: rag-cache-scan/dir test-dir
n-paths: length? rag-cache-paths
assert [n-paths >= 3] "scan finds all test files"
print rejoin [{  Scan updated } count { files, } n-paths { total}]

; ═══════════════════════════════════════════════════════════
;  Test 7: Re-scan with no changes = 0 updates
; ═══════════════════════════════════════════════════════════

count: rag-cache-scan/dir test-dir
assert [count = 0] "re-scan with no changes updates 0 files"

; ═══════════════════════════════════════════════════════════
;  Test 8: Scan with extension filter
; ═══════════════════════════════════════════════════════════

rag-cache-clear
rag-cache-init/exts test-dir [%.py]
count: rag-cache-scan/dir test-dir
n-paths: length? rag-cache-paths
assert [n-paths = 2] "scan with .py filter finds only 2 files"

; ═══════════════════════════════════════════════════════════
;  Test 9: Save and reload preserves entries
; ═══════════════════════════════════════════════════════════

rag-cache-clear
rag-cache-init test-dir
rag-cache-scan/dir test-dir
path-count-before: length? rag-cache-paths
rag-cache-save

; Re-init to simulate reload
rag-cache-init test-dir
assert [(length? rag-cache-paths) = path-count-before] "reload preserves all entries"

; ═══════════════════════════════════════════════════════════
;  Test 10: Scan ignores .git, node_modules, __pycache__
; ═══════════════════════════════════════════════════════════

make-dir/deep to-file rejoin [test-dir-str {.git/}]
make-dir/deep to-file rejoin [test-dir-str {node_modules/}]
make-dir/deep to-file rejoin [test-dir-str {__pycache__/}]
write to-file rejoin [test-dir-str {.git/config}] {[core]}
write to-file rejoin [test-dir-str {node_modules/pkg.js}] {module.exports = {}}
write to-file rejoin [test-dir-str {__pycache__/a.pyc}] {compiled}

rag-cache-clear
rag-cache-init test-dir
rag-cache-scan/dir test-dir
paths: rag-cache-paths
found-git: false  foreach p paths [if find p {.git} [found-git: true]]
found-nm:  false  foreach p paths [if find p {node_modules} [found-nm: true]]
found-pyc: false  foreach p paths [if find p {__pycache__} [found-pyc: true]]
assert [not found-git] "scan ignores .git"
assert [not found-nm] "scan ignores node_modules"
assert [not found-pyc] "scan ignores __pycache__"

; ═══════════════════════════════════════════════════════════
;  Cleanup
; ═══════════════════════════════════════════════════════════

rag-cache-clear

cleanup-dir: func [d [file!] /local f] [
    either dir? d [
        foreach f read d [cleanup-dir rejoin [d f]]
        attempt [delete d]
    ][
        attempt [delete d]
    ]
]
cleanup-dir test-dir

; ═══════════════════════════════════════════════════════════
;  Results
; ═══════════════════════════════════════════════════════════

print rejoin [{=== } passed {/} (passed + failed) { tests passed ===}]
if failed > 0 [print rejoin [{*** } failed { TEST(S) FAILED ***}]]
if failed > 0 [quit/return 1]
