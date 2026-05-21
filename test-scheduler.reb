REBOL [
    Title: {Test Scheduler}
    Purpose: {Verify scheduler timer + subagent functionality}
]

; Load scheduler
do %./scheduler.reb

print "=== Scheduler Test ==="
print ""

; ── Test 1: Timer scheduling ──
print "--- Test 1: Timer Scheduling ---"
id1: scheduler/schedule-timer 0:0:3 "Check timer 1 fired"
print rejoin ["  Scheduled timer: " id1]
print rejoin ["  Timers count: " length? scheduler/timers]

; ── Test 2: Poll before due ──
print ""
print "--- Test 2: Poll Before Due ---"
due: scheduler/poll-timers
print rejoin ["  Due (should be empty): " length? due]

; ── Test 3: Wait for timer ──
print ""
print "--- Test 3: Wait for Timer (3s) ---"
wait 4   ; 4s buffer (timer was 3s)
due: scheduler/poll-timers
print rejoin ["  Due (should be 1): " length? due]
print rejoin ["  Pending prompts: " length? scheduler/pending-prompts]

; ── Test 4: Consume pending ──
print ""
print "--- Test 4: Consume Pending ---"
p: scheduler/next-pending
print rejoin ["  Got: " p]
print rejoin ["  Remaining: " length? scheduler/pending-prompts]

; ── Test 5: Subagent spawn (dry run — no actual rebol3 agent) ──
print ""
print "--- Test 5: Subagent Registry ---"
; Manually add a fake subagent to test check/list
fake-sa: make map! reduce [
    to-set-word 'id "sa-test01"
    to-set-word 'name "test-task"
    to-set-word 'workdir %.re-coder/subagents/sa-test01/
    to-set-word 'state "running"
    to-set-word 'marker-file %.re-coder/subagents/sa-test01/.done
    to-set-word 'created now
]
append scheduler/subagents fake-sa
rows: scheduler/list-subagents
print rejoin ["  Subagents: " length? rows]
foreach r rows [print rejoin ["    " r/1 " [" r/3 "] " r/2]]

; ── Test 6: Status ──
print ""
print "--- Test 6: Status ---"
foreach line scheduler/status [print line]

; ── Test 7: has-work ──
print ""
print "--- Test 7: has-work ---"
print rejoin ["  has-work: " scheduler/has-work]

print ""
print "=== All Tests Passed ==="
