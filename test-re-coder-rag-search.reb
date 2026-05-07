REBOL [
    Title:   {Re Coder RAG Search Tests}
    Purpose: {Test suite for re-coder-rag-search.reb}
]

do %./re-coder-rag-search.reb

passed: 0
failed: 0

assert: func [condition description [string!]] [
    ; Use all: true? on a block is always true in R3/Ren-C — it does not evaluate inside.
    either all condition [
        print rejoin [{✓ PASS: } description]
        passed: passed + 1
    ][
        print rejoin [{✗ FAIL: } description]
        failed: failed + 1
    ]
]

; ═══════════════════════════════════════════════════════════
;  Create test fixtures
; ═══════════════════════════════════════════════════════════
test-dir: %./test-rag-fixtures/
make-dir/deep test-dir

write rejoin [test-dir %code.py] {
def quicksort(arr):
    if len(arr) <= 1:
        return arr
    pivot = arr[0]
    left = [x for x in arr[1:] if x <= pivot]
    right = [x for x in arr[1:] if x > pivot]
    return quicksort(left) + [pivot] + quicksort(right)

def hello():
    print("Hello, World!")
}

write rejoin [test-dir %config.reb] {
REBOL [
    Title: "Test Config"
]

database: make object! [
    host: "localhost"
    port: 5432
    name: "testdb"
]
}

write rejoin [test-dir %notes.md] {
# Project Notes

## Database Setup
The application uses PostgreSQL on port 5432.
Connection string: postgresql://localhost:5432/testdb

## Search
We implemented full-text search using pg_trgm.
}

; ═══════════════════════════════════════════════════════════
;  Test 1: Basic grep search
; ═══════════════════════════════════════════════════════════
results: rag-grep {quicksort} test-dir none none
print rejoin [{results: } mold results]
assert [(length? results) > 0] "grep finds quicksort in test files"
assert [find results/1/file {code.py}] "match is in code.py"

; ═══════════════════════════════════════════════════════════
;  Test 2: Grep with no results
; ═══════════════════════════════════════════════════════════
results: rag-grep {xyznonexistent123} test-dir none none
assert [empty? results] "grep empty for non-existent term"

; ═══════════════════════════════════════════════════════════
;  Test 3: Grep with extension filter
; ═══════════════════════════════════════════════════════════
results: rag-grep {database} test-dir [%.md] none
assert [(length? results) > 0] "grep with md filter finds database"
assert [find results/1/file {notes.md}] "match in notes.md"

results: rag-grep {database} test-dir [%.reb] none
assert [(length? results) > 0] "grep with reb filter finds database"

; ═══════════════════════════════════════════════════════════
;  Test 4: Grep returns file, line, and match
; ═══════════════════════════════════════════════════════════
results: rag-grep {PostgreSQL} test-dir none none
assert [(length? results) > 0] "grep finds PostgreSQL"
hit: results/1
assert [string? hit/file] "result has file field"
assert [integer? hit/line] "result has line field"
assert [string? hit/match] "result has match field"

; ═══════════════════════════════════════════════════════════
;  Test 5: rag-search returns enriched results
; ═══════════════════════════════════════════════════════════
results: rag-search {quicksort} test-dir none none
assert [(length? results) > 0] "search finds quicksort"
hit: results/1
assert [string? hit/snippet] "search result has snippet"
assert [find hit/snippet {>>>}] "snippet marks matching line"

; ═══════════════════════════════════════════════════════════
;  Test 6: rag-search with extension filter
; ═══════════════════════════════════════════════════════════
results: rag-search {port} test-dir [%.reb %.md] none
assert [(length? results) >= 2] "search with filters finds port"

; ═══════════════════════════════════════════════════════════
;  Test 7: rag-build-context formats results
; ═══════════════════════════════════════════════════════════
results: rag-search {quicksort} test-dir none none
ctx: rag-build-context results
assert [string? ctx] "build-context returns string"
assert [find ctx {code.py}] "context includes file name"
assert [find ctx {```}] "context includes code blocks"

; ═══════════════════════════════════════════════════════════
;  Test 8: rag-build-context with empty results
; ═══════════════════════════════════════════════════════════
ctx: rag-build-context copy []
assert [find ctx {No relevant}] "empty context returns message"

; ═══════════════════════════════════════════════════════════
;  Test 9: rag-index-files lists files
; ═══════════════════════════════════════════════════════════
files: rag-index-files test-dir none
assert [(length? files) >= 3] "index lists all test files"

; ═══════════════════════════════════════════════════════════
;  Test 10: rag-index-files with extension filter
; ═══════════════════════════════════════════════════════════
files: rag-index-files test-dir [%.py]
assert [(length? files) >= 1] "index with py filter finds code.py"

; ═══════════════════════════════════════════════════════════
;  Test 11: Search on re-coder project itself
; ═══════════════════════════════════════════════════════════
results: rag-search {rag-config} %. [%.reb] 3
assert [(length? results) > 0] "search in re-coder itself finds rag-config"

; ═══════════════════════════════════════════════════════════
;  Cleanup
; ═══════════════════════════════════════════════════════════
foreach f read test-dir [
;    delete rejoin [test-dir f]
]
;delete test-dir

; ═══════════════════════════════════════════════════════════
;  Results
; ═══════════════════════════════════════════════════════════
print rejoin [{=== } passed {/} (passed + failed) { tests passed ===}]
if failed > 0 [print rejoin [{*** } failed { TEST(S) FAILED ***}]]
if failed > 0 [quit/return 1]
