REBOL [
    Title:   {Tests for subagent-runner}
    Name:    'test-subagent-runner
    Purpose: {Unit tests for task splitting, workspace management, and parallel execution.}
]

; ═══════════════════════════════════════════════════════════
;  Test Framework Helpers
; ═══════════════════════════════════════════════════════════

test-count: 0
pass-count: 0
fail-count: 0
current-suite: ""

test-suite: func [name [string!] code [block!]] [
    current-suite: name
    print [newline "═══════════════════════════════════════"]
    print [{  } name]
    print "═══════════════════════════════════════"
    do code
]

assert-equal: func [
    expected [any-type!]
    actual   [any-type!]
    label    [string!]
][
    test-count: test-count + 1
    either equal? expected actual [
        pass-count: pass-count + 1
        print [{  ✓ } label]
    ][
        fail-count: fail-count + 1
        print [{  ✗ } label]
        print [{    Expected: } mold expected]
        print [{    Actual:   } mold actual]
    ]
]

assert-true: func [cond [logic!] label [string!]] [
    assert-equal true cond label
]

assert-false: func [cond [logic!] label [string!]] [
    assert-equal false cond label
]

assert-not-none: func [val [any-type!] label [string!]] [
    test-count: test-count + 1
    either not none? val [
        pass-count: pass-count + 1
        print [{  ✓ } label]
    ][
        fail-count: fail-count + 1
        print [{  ✗ } label]
        print [{    Expected: not none}]
        print [{    Actual:   none}]
    ]
]

assert-none: func [val [any-type!] label [string!]] [
    test-count: test-count + 1
    either none? val [
        pass-count: pass-count + 1
        print [{  ✓ } label]
    ][
        fail-count: fail-count + 1
        print [{  ✗ } label]
        print [{    Expected: none}]
        print [{    Actual:   } mold val]
    ]
]

assert-block: func [val [any-type!] label [string!]] [
    test-count: test-count + 1
    either block? val [
        pass-count: pass-count + 1
        print [{  ✓ } label]
    ][
        fail-count: fail-count + 1
        print [{  ✗ } label]
        print [{    Expected: block!}]
        print [{    Actual:   } mold type? val]
    ]
]

assert-string: func [val [any-type!] label [string!]] [
    test-count: test-count + 1
    either string? val [
        pass-count: pass-count + 1
        print [{  ✓ } label]
    ][
        fail-count: fail-count + 1
        print [{  ✗ } label]
        print [{    Expected: string!}]
        print [{    Actual:   } mold type? val]
    ]
]

assert-string-contains: func [
    haystack [string!]
    needle   [string!]
    label    [string!]
][
    test-count: test-count + 1
    either find haystack needle [
        pass-count: pass-count + 1
        print [{  ✓ } label]
    ][
        fail-count: fail-count + 1
        print [{  ✗ } label]
        print [{    Expected string containing: } mold needle]
        print [{    Actual: } mold copy/part haystack 100]
    ]
]

assert-greater: func [
    val1 [number!]
    val2 [number!]
    label [string!]
][
    test-count: test-count + 1
    either val1 > val2 [
        pass-count: pass-count + 1
        print [{  ✓ } label]
    ][
        fail-count: fail-count + 1
        print [{  ✗ } label]
        print [{    Expected: } val1 { > } val2]
    ]
]

; ═══════════════════════════════════════════════════════════
;  Load Module Under Test
; ═══════════════════════════════════════════════════════════

do %./subagent-runner.reb

; ═══════════════════════════════════════════════════════════
;  Test Suite: Task Splitter — H1
; ═══════════════════════════════════════════════════════════

test-suite "Task Splitter — H1" [
    
    test-split-single-task: does [
        content: {# Task One
This is task one content.}
        tasks: subagent-runner/split-by-h1 content
        
        assert-block tasks "split-by-h1 returns block"
        assert-equal 1 length? tasks "Single task detected"
        assert-equal "Task One" first first tasks "Task title is correct"
    ]
    
    test-split-multiple-tasks: does [
        content: {# Task One
Content for task one.

# Task Two
Content for task two.

# Task Three
Content for task three.}
        tasks: subagent-runner/split-by-h1 content
        
        assert-equal 3 length? tasks "Three tasks detected"
        assert-equal "Task One" first pick tasks 1 "First task title"
        assert-equal "Task Two" first pick tasks 2 "Second task title"
        assert-equal "Task Three" first pick tasks 3 "Third task title"
    ]
    
    test-split-with-multiline-content: does [
        content: {# Task One
Line 1 of task one.
Line 2 of task one.
Line 3 of task one.

# Task Two
Line 1 of task two.}
        tasks: subagent-runner/split-by-h1 content
        
        assert-equal 2 length? tasks "Two tasks detected"
        assert-string-contains second pick tasks 1 "Line 1" "First task has content"
        assert-string-contains second pick tasks 1 "Line 3" "First task has all lines"
    ]
    
    test-split-empty-content: does [
        content: ""
        tasks: subagent-runner/split-by-h1 content
        
        assert-equal 0 length? tasks "Empty content returns no tasks"
    ]
    
    test-split-no-headers: does [
        content: {Just some content
without any headers.}
        tasks: subagent-runner/split-by-h1 content
        
        assert-equal 1 length? tasks "No headers treated as single task"
        assert-equal "untitled" first first tasks "Default title is 'untitled'"
    ]
    
    ; Run all tests
    test-split-single-task
    test-split-multiple-tasks
    test-split-with-multiline-content
    test-split-empty-content
    test-split-no-headers
]

; ═══════════════════════════════════════════════════════════
;  Test Suite: Task Splitter — H2
; ═══════════════════════════════════════════════════════════

test-suite "Task Splitter — H2" [
    
    test-split-h2-multiple: does [
        content: {# Main Section

## Sub Task A
Content A.

## Sub Task B
Content B.

## Sub Task C
Content C.}
        tasks: subagent-runner/split-by-h2 content
        
        assert-block tasks "split-by-h2 returns block"
        assert-equal 3 length? tasks "Three subtasks detected"
        assert-equal "Sub Task A" first pick tasks 1 "First subtask title"
        assert-equal "Sub Task B" first pick tasks 2 "Second subtask title"
    ]
    
    test-split-h2-with-h1-ignored: does [
        content: {## Task A
Content A.

## Task B
Content B.}
        tasks: subagent-runner/split-by-h2 content
        
        assert-equal 2 length? tasks "Two tasks detected"
    ]
    
    ; Run all tests
    test-split-h2-multiple
    test-split-h2-with-h1-ignored
]

; ═══════════════════════════════════════════════════════════
;  Test Suite: Task Splitter — Delimiter
; ═══════════════════════════════════════════════════════════

test-suite "Task Splitter — Delimiter" [
    
    test-split-by-delimiter: does [
        content: {Task one content.

===

Task two content.

===

Task three content.}
        tasks: subagent-runner/split-by-delimiter content "==="
        
        assert-block tasks "split-by-delimiter returns block"
        assert-equal 3 length? tasks "Three tasks detected"
    ]
    
    test-split-by-custom-delimiter: does [
        content: {Part 1
---
Part 2
---
Part 3}
        tasks: subagent-runner/split-by-delimiter content "---"
        
        assert-equal 3 length? tasks "Three parts detected"
    ]
    
    ; Run all tests
    test-split-by-delimiter
    test-split-by-custom-delimiter
]

; ═══════════════════════════════════════════════════════════
;  Test Suite: Auto Split
; ═══════════════════════════════════════════════════════════

test-suite "Auto Split" [
    
    test-auto-split-h1: does [
        content: {# Task A
Content A.

# Task B
Content B.}
        tasks: subagent-runner/auto-split content
        
        assert-equal 2 length? tasks "Auto-split detects H1 structure"
    ]
    
    test-auto-split-h2: does [
        content: {# Main

## Sub A
Content A.

## Sub B
Content B.}
        tasks: subagent-runner/auto-split content
        
        assert-equal 2 length? tasks "Auto-split detects H2 structure"
    ]
    
    test-auto-split-single: does [
        content: {Just some content without headers.}
        tasks: subagent-runner/auto-split content
        
        assert-equal 1 length? tasks "Auto-split treats single doc as one task"
    ]
    
    ; Run all tests
    test-auto-split-h1
    test-auto-split-h2
    test-auto-split-single
]

; ═══════════════════════════════════════════════════════════
;  Test Suite: Workspace Manager
; ═══════════════════════════════════════════════════════════

test-suite "Workspace Manager" [
    
    ; Use a test-specific workdir
    setup: does [
        subagent-runner/workdir: %./test-subagent-workdir/
        subagent-runner/cleanup: true
        subagent-runner/verbose: false
    ]
    
    test-safe-dir-name: does [
        assert-equal "hello-world" subagent-runner/safe-dir-name "hello world" "Spaces become hyphens"
        assert-equal "task-1" subagent-runner/safe-dir-name "task-1" "Hyphens preserved"
        assert-equal "TestTask" subagent-runner/safe-dir-name "TestTask" "Alphanumeric preserved"
        assert-equal "my_task" subagent-runner/safe-dir-name "my_task" "Underscores preserved"
    ]
    
    test-create-workspace: does [
        setup
        ws: subagent-runner/create-workspace "test-task"
        
        assert-string to-string ws "create-workspace returns path"
        assert-not-none exists? ws "Workspace directory exists"
        
        ; Cleanup
        subagent-runner/cleanup-workspace "test-task"
    ]
    
    test-cleanup-workspace: does [
        setup
        ws: subagent-runner/create-workspace "cleanup-test"
        assert-not-none exists? ws "Workspace created"
        
        subagent-runner/cleanup-workspace "cleanup-test"
        assert-none exists? ws "Workspace cleaned up"
    ]
    
    ; Run all tests
    test-safe-dir-name
    test-create-workspace
    test-cleanup-workspace
]

; ═══════════════════════════════════════════════════════════
;  Test Suite: Task Executor
; ═══════════════════════════════════════════════════════════

test-suite "Task Executor" [
    
    setup: does [
        subagent-runner/workdir: %./test-subagent-workdir/
        subagent-runner/verbose: false
    ]
    
    test-generate-script: does [
        setup
        ws: subagent-runner/create-workspace "script-test"
        script: subagent-runner/generate-script "script-test" {print "hello"}
        
        assert-string script "generate-script returns string"
        assert-string-contains script "print" "Script contains code"
        assert-string-contains script "script-test" "Script contains task id"
        
        subagent-runner/cleanup-workspace "script-test"
    ]
    
    test-execute-task: does [
        setup
        
        ; 创建一个简单的测试任务
        pair: subagent-runner/execute-task "exec-test" {print "Task executed"}
        
        assert-block pair "execute-task returns block"
        assert-equal 4 length? pair "Result has 4 elements"
        assert-equal "exec-test" first pair "Task id matches"
        
        ; 等待任务完成
        marker-file: fourth pair
        wait 2  ; Give it time to complete
        
        ; Cleanup
        subagent-runner/cleanup-workspace "exec-test"
    ]
    
    ; Run all tests
    test-generate-script
    test-execute-task
]

; ═══════════════════════════════════════════════════════════
;  Test Suite: Parallel Execution (Integration)
; ═══════════════════════════════════════════════════════════

test-suite "Parallel Execution (Integration)" [
    
    setup: does [
        subagent-runner/workdir: %./test-subagent-workdir/
        subagent-runner/max-parallel: 3
        subagent-runner/cleanup: true
        subagent-runner/verbose: true
    ]
    
    test-run-parallel-simple: does [
        setup
        
        print [newline "  Running 3 simple tasks in parallel..."]
        
        results: subagent-runner/run-parallel [
            "task-a" {print "Task A done"}
            "task-b" {print "Task B done"}
            "task-c" {print "Task C done"}
        ]
        
        assert-block results "run-parallel returns block"
        assert-equal 3 length? results "All 3 tasks completed"
        
        ; Check each result
        foreach result results [
            assert-block result "Result is a block"
            assert-equal 3 length? result "Result has 3 elements"
        ]
    ]
    
    test-run-parallel-with-output: does [
        setup
        
        print [newline "  Running tasks that produce output..."]
        
        results: subagent-runner/run-parallel [
            "output-1" {print "Hello from task 1"}
            "output-2" {print "Hello from task 2"}
        ]
        
        assert-equal 2 length? results "Two tasks completed"
        
        ; Check outputs contain expected text
        found-1: false
        found-2: false
        foreach result results [
            output: pick result 2
            if find output "Hello from task 1" [found-1: true]
            if find output "Hello from task 2" [found-2: true]
        ]
        assert-true found-1 "Output contains task 1 result"
        assert-true found-2 "Output contains task 2 result"
    ]
    
    test-run-parallel-with-error: does [
        setup
        
        print [newline "  Running task that produces error..."]
        
        results: subagent-runner/run-parallel [
            "good-task" {print "I'm fine"}
            "bad-task" {1 / 0}  ; Division by zero
        ]
        
        assert-equal 2 length? results "Both tasks completed"
        
        ; Check that error task has non-zero exit code
        foreach result results [
            either (pick result 1) = "good-task" [
                assert-equal 0 pick result 3 "Good task exits with 0"
            ][
                assert-greater pick result 3 0 "Bad task exits with non-zero"
            ]
        ]
    ]
    
    test-run-tasks-convenience: does [
        setup
        
        print [newline "  Testing run-tasks convenience function..."]
        
        results: subagent-runner/run-tasks [
            {print "Task 1"}
            {print "Task 2"}
            {print "Task 3"}
            {print "Task 4"}
        ]
        
        assert-equal 4 length? results "Four tasks completed"
    ]
    
    ; Run all tests
    test-run-parallel-simple
    test-run-parallel-with-output
    test-run-parallel-with-error
    test-run-tasks-convenience
]

; ═══════════════════════════════════════════════════════════
;  Test Suite: Convenience Functions
; ═══════════════════════════════════════════════════════════

test-suite "Convenience Functions" [
    
    setup: does [
        subagent-runner/workdir: %./test-subagent-workdir/
        subagent-runner/cleanup: true
        subagent-runner/verbose: false
    ]
    
    test-parallel-function: does [
        setup
        
        results: parallel [
            {print "P1"}
            {print "P2"}
        ]
        
        assert-block results "parallel() returns block"
        assert-equal 2 length? results "Two tasks completed"
    ]
    
    test-parallel-with-max: does [
        setup
        
        results: parallel/max [
            {print "M1"}
            {print "M2"}
            {print "M3"}
            {print "M4"}
        ] 2
        
        assert-equal 4 length? results "Four tasks completed with max-parallel=2"
    ]
    
    ; Run all tests
    test-parallel-function
    test-parallel-with-max
]

; ═══════════════════════════════════════════════════════════
;  Test Suite: File Operations
; ═══════════════════════════════════════════════════════════

test-suite "File Operations" [
    
    setup: does [
        subagent-runner/workdir: %./test-subagent-workdir/
        subagent-runner/cleanup: true
        subagent-runner/verbose: false
    ]
    
    test-run-from-file: does [
        setup
        
        ; Create test markdown file
        test-file: %./test-subagent-tasks.md
        write test-file {# Task Alpha
print "Alpha executed"

# Task Beta
print "Beta executed"}
        
        results: subagent-runner/run-from-file test-file
        
        assert-block results "run-from-file returns block"
        assert-equal 2 length? results "Two tasks from file"
        
        ; Cleanup
        attempt [delete test-file]
    ]
    
    test-run-from-file-with-h2: does [
        setup
        
        test-file: %./test-subagent-tasks-h2.md
        write test-file {# Main Section

## Sub A
print "Sub A executed"

## Sub B
print "Sub B executed"}
        
        results: subagent-runner/run-from-file test-file
        
        assert-equal 2 length? results "Two subtasks from H2 split"
        
        ; Cleanup
        attempt [delete test-file]
    ]
    
    ; Run all tests
    test-run-from-file
    test-run-from-file-with-h2
]

; ═══════════════════════════════════════════════════════════
;  Cleanup Test Workspace
; ═══════════════════════════════════════════════════════════

; Final cleanup
subagent-runner/workdir: %./test-subagent-workdir/
subagent-runner/cleanup-all
attempt [delete-dir %./test-subagent-workdir/]

; ═══════════════════════════════════════════════════════════
;  Test Summary
; ═══════════════════════════════════════════════════════════

print [newline "═══════════════════════════════════════"]
print [{  TEST SUMMARY}]
print "═══════════════════════════════════════"
print [{  Total:  } test-count]
print [{  Passed: } pass-count]
print [{  Failed: } fail-count]
print "═══════════════════════════════════════"

either fail-count > 0 [
    print [{❌ } fail-count { test(s) FAILED}]
    quit/return 1
][
    print [{✅ All } test-count { tests passed}]
    quit/return 0
]
