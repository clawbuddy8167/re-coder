REBOL []
; Detailed bracket balance checker
data: to-string read %subagent-runner.reb
count: 0
in-brace: false
brace-depth: 0
in-dquote: false
line-num: 1
last-count: 0

foreach c data [
    either in-brace [
        either c = #"}" [
            either brace-depth > 0 [brace-depth: brace-depth - 1][in-brace: false]
        ][
            if c = #"{" [brace-depth: brace-depth + 1]
        ]
    ][
        case [
            c = #"^"" [in-dquote: not in-dquote]
            in-dquote [true]
            c = #"[" [count: count + 1]
            c = #"]" [count: count - 1]
            c = #"{" [in-brace: true brace-depth: 0]
            c = #"^/" [
                if count <> last-count [
                    print rejoin ["Line " line-num ": " last-count " -> " count]
                    last-count: count
                ]
                line-num: line-num + 1
            ]
        ]
    ]
]
print rejoin ["Final: " count " at line " line-num]
