REBOL [
    Title:   {Tests for re-coder-sse (SSE streaming)}
    Name:    'test-re-coder-sse
    Purpose: {Unit tests for SSE line parsing, chunk extraction,
              tool call collector, and streaming HTTP client.}
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

assert-map: func [val [any-type!] label [string!]] [
    test-count: test-count + 1
    either map? val [
        pass-count: pass-count + 1
        print [{  ✓ } label]
    ][
        fail-count: fail-count + 1
        print [{  ✗ } label]
        print [{    Expected: map!}]
        print [{    Actual:   } mold type? val]
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

; Helper to build JSON strings safely
make-json: func [spec [block!] /local result key val][
    result: copy []
    foreach [key val] spec [
        ; key is already a set-word!, just append it
        append result key
        append/only result val
    ]
    to-json make map! result
]

; ═══════════════════════════════════════════════════════════
;  Load Module Under Test
; ═══════════════════════════════════════════════════════════

do %./re-coder-sse.reb

; ═══════════════════════════════════════════════════════════
;  Test Suite: SSE Line Parser
; ═══════════════════════════════════════════════════════════

test-suite "SSE Line Parser" [
    
    ; Test parsing a valid SSE data line with JSON
    test-parse-valid-json: does [
        ; Build JSON manually to avoid complex nesting
        json-str: rejoin [
            {{"id":"chatcmpl-123","choices":[{"delta":{"content":"Hello"}}]}}
        ]
        line: rejoin ["data: " json-str]
        result: sse-line-parser/parse-data-line line
        
        assert-map result "parse-data-line returns map for valid JSON"
        assert-equal "chatcmpl-123" select result 'id "JSON has correct id field"
    ]
    
    ; Test parsing [DONE] marker
    test-parse-done: does [
        line: "data: [DONE]"
        result: sse-line-parser/parse-data-line line
        
        assert-string result "parse-data-line returns string for DONE"
        assert-equal "DONE" result "Returns DONE string"
    ]
    
    ; Test parsing empty line
    test-parse-empty: does [
        result: sse-line-parser/parse-data-line ""
        assert-none result "parse-data-line returns none for empty line"
    ]
    
    ; Test parsing line without data prefix
    test-parse-no-prefix: does [
        result: sse-line-parser/parse-data-line "event: message"
        assert-none result "parse-data-line returns none for non-data line"
    ]
    
    ; Test parsing comment line
    test-parse-comment: does [
        result: sse-line-parser/parse-data-line "; this is a comment"
        assert-none result "parse-data-line returns none for comment"
    ]
    
    ; Test parsing invalid JSON
    test-parse-invalid-json: does [
        line: "data: {invalid json}"
        result: sse-line-parser/parse-data-line line
        assert-none result "parse-data-line returns none for invalid JSON"
    ]
    
    ; Test parsing buffer with multiple events
    test-parse-buffer: does [
        json1: {{"id":"1","choices":[{"delta":{"content":"Hi"}}]}}
        json2: {{"id":"2","choices":[{"delta":{"content":" there"}}]}}
        buffer: rejoin [
            "data: " json1 "^/^/"
            "data: " json2 "^/^/"
            "data: [DONE]^/^/"
        ]
        chunks: sse-line-parser/parse-buffer buffer
        
        assert-block chunks "parse-buffer returns block"
        assert-equal 3 length? chunks "Buffer has 3 chunks (2 data + DONE)"
    ]
    
    ; Run all tests
    test-parse-valid-json
    test-parse-done
    test-parse-empty
    test-parse-no-prefix
    test-parse-comment
    test-parse-invalid-json
    test-parse-buffer
]

; ═══════════════════════════════════════════════════════════
;  Test Suite: Chunk Content Extractor
; ═══════════════════════════════════════════════════════════

test-suite "Chunk Content Extractor" [
    
    ; Test extracting text delta
    test-extract-text-delta: does [
        chunk: make map! reduce [
            'id "1"
            'choices reduce [
                make map! reduce [
                    'delta make map! reduce ['content "Hello"]
                    'index 0
                ]
            ]
        ]
        result: sse-chunk-extractor/extract-delta chunk
        
        assert-string result "extract-delta returns string for text"
        assert-equal "Hello" result "Extracted text is correct"
    ]
    
    ; Test extracting empty delta (role marker)
    test-extract-role-delta: does [
        chunk: make map! reduce [
            'id "1"
            'object "chat.completion.chunk"
            'choices reduce [
                make map! reduce [
                    'delta make map! reduce ['role "assistant"]
                    'index 0
                ]
            ]
        ]
        result: sse-chunk-extractor/extract-delta chunk
        
        assert-none result "extract-delta returns none for role delta"
    ]
    
    ; Test extracting tool_calls delta
    test-extract-tool-calls-delta: does [
        tool-call: make map! reduce [
            'index 0
            'id "call_123"
            'type "function"
            'function make map! reduce [
                'name "write_file"
                'arguments ""
            ]
        ]
        chunk: make map! reduce [
            'id "1"
            'choices reduce [
                make map! reduce [
                    'delta make map! reduce [
                        'tool_calls reduce [tool-call]
                    ]
                    'index 0
                ]
            ]
        ]
        result: sse-chunk-extractor/extract-delta chunk
        
        assert-block result "extract-delta returns block for tool_calls"
        assert-equal 'tool_calls first result "First element is 'tool_calls"
    ]
    
    ; Test extracting usage from chunk
    test-extract-usage: does [
        chunk: make map! reduce [
            'id "1"
            'choices []
            'usage make map! reduce [
                'prompt_tokens 10
                'completion_tokens 20
                'total_tokens 30
            ]
        ]
        result: sse-chunk-extractor/extract-usage chunk
        
        assert-map result "extract-usage returns map"
        assert-equal 10 select result 'prompt_tokens "Usage has correct prompt_tokens"
        assert-equal 20 select result 'completion_tokens "Usage has correct completion_tokens"
    ]
    
    ; Test extracting finish_reason
    test-extract-finish-reason: does [
        chunk: make map! reduce [
            'id "1"
            'choices reduce [
                make map! reduce [
                    'delta #[]
                    'finish_reason "stop"
                    'index 0
                ]
            ]
        ]
        result: sse-chunk-extractor/extract-finish-reason chunk
        
        assert-string result "extract-finish-reason returns string"
        assert-equal "stop" result "Finish reason is 'stop'"
    ]
    
    ; Test chunk with no choices
    test-extract-no-choices: does [
        chunk: make map! reduce [
            'id "1"
            'choices []
        ]
        result: sse-chunk-extractor/extract-delta chunk
        
        assert-none result "extract-delta returns none for empty choices"
    ]
    
    ; Run all tests
    test-extract-text-delta
    test-extract-role-delta
    test-extract-tool-calls-delta
    test-extract-usage
    test-extract-finish-reason
    test-extract-no-choices
]

; ═══════════════════════════════════════════════════════════
;  Test Suite: Tool Call Collector
; ═══════════════════════════════════════════════════════════

test-suite "Tool Call Collector" [
    
    ; Setup
    setup: does [
        tool-call-collector/reset
    ]
    
    ; Test single tool call accumulation
    test-single-tool-call: does [
        setup
        
        ; First chunk: id and function name
        delta1: reduce [
            make map! reduce [
                'index 0
                'id "call_abc123"
                'type "function"
                'function make map! reduce [
                    'name "write"
                    'arguments ""
                ]
            ]
        ]
        tool-call-collector/update delta1
        
        ; Second chunk: more arguments
        delta2: reduce [
            make map! reduce [
                'index 0
                'function make map! reduce [
                    'name "_file"
                    'arguments "{"
                ]
            ]
        ]
        tool-call-collector/update delta2
        
        ; Third chunk: more arguments (use simple string without escaping)
        delta3: reduce [
            make map! reduce [
                'index 0
                'function make map! reduce [
                    'name ""
                    'arguments {"path":"test.py"}
                ]
            ]
        ]
        tool-call-collector/update delta3
        
        ; Fourth chunk: end of arguments
        delta4: reduce [
            make map! reduce [
                'index 0
                'function make map! reduce [
                    'name ""
                    'arguments rejoin [{,"content":"hello"} "}}"]
                ]
            ]
        ]
        tool-call-collector/update delta4
        
        calls: tool-call-collector/get-calls
        
        assert-block calls "get-calls returns block"
        assert-equal 1 length? calls "One tool call collected"
        
        first-call: pick calls 1
        assert-equal "call_abc123" select first-call 'id "Tool call has correct id"
        assert-equal "write_file" select first-call/function 'name "Tool call has accumulated name"
        assert-string-contains select first-call/function 'arguments "path" "Arguments contain path"
    ]
    
    ; Test multiple tool calls
    test-multiple-tool-calls: does [
        setup
        
        ; First tool call
        delta1: reduce [
            make map! reduce [
                'index 0
                'id "call_111"
                'type "function"
                'function make map! reduce [
                    'name "read_file"
                    'arguments {"path":"a.py"}
                ]
            ]
        ]
        tool-call-collector/update delta1
        
        ; Second tool call
        delta2: reduce [
            make map! reduce [
                'index 1
                'id "call_222"
                'type "function"
                'function make map! reduce [
                    'name "run_command"
                    'arguments {"command":"ls"}
                ]
            ]
        ]
        tool-call-collector/update delta2
        
        calls: tool-call-collector/get-calls
        
        assert-equal 2 length? calls "Two tool calls collected"
        assert-equal "call_111" select (pick calls 1) 'id "First call has correct id"
        assert-equal "call_222" select (pick calls 2) 'id "Second call has correct id"
    ]
    
    ; Test empty collection
    test-empty-collection: does [
        setup
        
        assert-false tool-call-collector/has-calls "has-calls returns false when empty"
        assert-equal 0 length? tool-call-collector/get-calls "get-calls returns empty block"
    ]
    
    ; Test reset
    test-reset: does [
        ; Add some data
        delta: reduce [
            make map! reduce [
                'index 0
                'id "call_999"
                'function make map! reduce ['name "test" 'arguments "{}"]
            ]
        ]
        tool-call-collector/update delta
        
        ; Reset
        tool-call-collector/reset
        
        assert-false tool-call-collector/has-calls "has-calls returns false after reset"
    ]
    
    ; Run all tests
    test-single-tool-call
    test-multiple-tool-calls
    test-empty-collection
    test-reset
]

; ═══════════════════════════════════════════════════════════
;  Test Suite: Curl Command Builder
; ═══════════════════════════════════════════════════════════

test-suite "Curl Command Builder" [
    
    ; Test building curl argv (block for call native — no shell)
    test-build-curl-args: does [
        url: "https://api.deepseek.com/v1/chat/completions"
        headers: make map! reduce [
            'Authorization "Bearer sk-test123"
            'Content-Type "application/json"
        ]
        body: to-json #[
            model: "deepseek-chat"
            stream: #(true)
        ]
        
        args: sse-reader/build-curl-args url headers body
        
        cmd: mold args
        assert-string cmd "build-curl-args returns block (molded for asserts)"
        assert-string-contains cmd "-N" "Curl uses -N for no-buffer"
        assert-string-contains cmd "--no-buffer" "Curl uses --no-buffer"
        assert-string-contains cmd "text/event-stream" "Accept header is SSE"
        assert-string-contains cmd "Authorization:" "Authorization header name present"
        assert-string-contains cmd "Bearer sk-test123" "Bearer token present"
        assert-string-contains cmd url "URL is included"
    ]
    
    ; Run test
    test-build-curl-args
]

; ═══════════════════════════════════════════════════════════
;  Test Suite: Stream LLM Client (requires API key)
; ═══════════════════════════════════════════════════════════

test-suite "Stream LLM Client (Live API)" [
    
    ; Check if API key is available
    api-key: get-env "DEEPSEEK_API_KEY"
    base-url: any [get-env "DEEPSEEK_BASE_URL" "https://api.deepseek.com"]
    model: any [get-env "DEEPSEEK_MODEL" "deepseek-chat"]
    
    either none? api-key [
        print [newline "  ⚠ SKIP: DEEPSEEK_API_KEY not set"]
    ][
        print [newline "  API Key: " copy/part api-key 8 "..."]
        print ["  Base URL: " base-url]
        print ["  Model: " model]
        
        ; Test basic streaming
        test-basic-streaming: does [
            print [newline "  Testing basic streaming..."]
            
            ; Configure client
            stream-llm-client/model: model
            stream-llm-client/api-key: api-key
            stream-llm-client/base-url: base-url
            stream-llm-client/print-input: false
            stream-llm-client/print-output: false
            
            messages: reduce [
                make map! reduce ['role "system" 'content "You are a helpful assistant. Be concise."]
                make map! reduce ['role "user" 'content "Say 'hello world' and nothing else."]
            ]
            
            tokens: copy []
            
            result: stream-llm-client/chat-stream messages func [token [string!]] [
                append tokens token
                prin token
            ]
            
            print ""
            
            assert-map result "chat-stream returns map"
            assert-string select result 'content "Result has content field"
            assert-true (length? select result 'content) > 0 "Content is not empty"
            assert-true (length? tokens) > 0 "Callback received tokens"
            
            ; Verify content matches accumulated tokens
            accumulated: copy ""
            foreach t tokens [append accumulated t]
            assert-equal accumulated select result 'content "Accumulated tokens match content"
        ]
        
        ; Test streaming with tool calls
        test-streaming-with-tools: does [
            print [newline "  Testing streaming with tools..."]
            
            stream-llm-client/model: model
            stream-llm-client/api-key: api-key
            stream-llm-client/base-url: base-url
            stream-llm-client/print-input: false
            stream-llm-client/print-output: false
            
            messages: reduce [
                make map! reduce ['role "system" 'content "You are a coding assistant. Use the read_file tool to read /tmp/test.txt"]
                make map! reduce ['role "user" 'content "Read the file /tmp/test.txt"]
            ]
            
            tool-defs: compose/deep [
                #[
                    type: "function"
                    function: #[
                        name: "read_file"
                        description: "Read a file's contents"
                        parameters: #[
                            type: "object"
                            properties: #[
                                path: #[type: "string" description: "File path"]
                            ]
                            required: ["path"]
                        ]
                    ]
                ]
            ]
            
            tokens: copy []
            
            result: stream-llm-client/chat-stream/with-tools messages func [token [string!]] [
                append tokens token
            ] tool-defs
            
            assert-map result "chat-stream with tools returns map"
            ; Note: Tool calls may or may not be present depending on model behavior
            
            if not empty? select result 'tool_calls [
                print "  ✓ Model requested tool calls"
                first-call: pick select result 'tool_calls 1
                assert-equal "read_file" select first-call/function 'name "Tool call is for read_file"
            ]
        ]
        
        ; Test non-streaming fallback
        test-non-streaming: does [
            print [newline "  Testing non-streaming fallback..."]
            
            stream-llm-client/model: model
            stream-llm-client/api-key: api-key
            stream-llm-client/base-url: base-url
            
            messages: reduce [
                make map! reduce ['role "user" 'content "Say 'test' and nothing else."]
            ]
            
            result: stream-llm-client/chat messages
            
            assert-map result "Non-streaming returns map"
            assert-not-none select result 'choices "Response has choices"
        ]
        
        ; Run live API tests
        test-basic-streaming
        test-streaming-with-tools
        test-non-streaming
    ]
]

; ═══════════════════════════════════════════════════════════
;  Test Suite: Mock Streaming (no API required)
; ═══════════════════════════════════════════════════════════

test-suite "Mock Streaming Simulation" [
    
    ; Simulate SSE stream processing
    test-simulate-stream: does [
        ; Create mock SSE data using make map! instead of load-json
        json1: to-json make map! reduce [
            'id "chatcmpl-123"
            'object "chat.completion.chunk"
            'created 1234567890
            'model "deepseek-chat"
            'choices reduce [
                make map! reduce [
                    'index 0
                    'delta make map! reduce ['role "assistant" 'content ""]
                    'finish_reason none
                ]
            ]
        ]
        
        json2: to-json make map! reduce [
            'id "chatcmpl-123"
            'object "chat.completion.chunk"
            'created 1234567890
            'model "deepseek-chat"
            'choices reduce [
                make map! reduce [
                    'index 0
                    'delta make map! reduce ['content "Hello"]
                    'finish_reason none
                ]
            ]
        ]
        
        json3: to-json make map! reduce [
            'id "chatcmpl-123"
            'object "chat.completion.chunk"
            'created 1234567890
            'model "deepseek-chat"
            'choices reduce [
                make map! reduce [
                    'index 0
                    'delta make map! reduce ['content " world"]
                    'finish_reason none
                ]
            ]
        ]
        
        json4: to-json make map! reduce [
            'id "chatcmpl-123"
            'object "chat.completion.chunk"
            'created 1234567890
            'model "deepseek-chat"
            'choices reduce [
                make map! reduce [
                    'index 0
                    'delta make map! reduce ['content "!"]
                    'finish_reason "stop"
                ]
            ]
        ]
        
        json5: to-json make map! reduce [
            'id "chatcmpl-123"
            'object "chat.completion.chunk"
            'created 1234567890
            'model "deepseek-chat"
            'choices []
            'usage make map! reduce [
                'prompt_tokens 5
                'completion_tokens 3
                'total_tokens 8
            ]
        ]
        
        sse-data: rejoin [
            "data: " json1 "^/^/"
            "data: " json2 "^/^/"
            "data: " json3 "^/^/"
            "data: " json4 "^/^/"
            "data: " json5 "^/^/"
            "data: [DONE]^/^/"
        ]
        
        ; Parse the buffer
        chunks: sse-line-parser/parse-buffer sse-data
        
        assert-block chunks "Parsed chunks is block"
        assert-equal 6 length? chunks "Six chunks parsed (5 data + DONE)"
        
        ; Process chunks
        content: ""
        foreach chunk chunks [
            either equal? "DONE" chunk [
                ; Stream finished
                true
            ][
                delta: sse-chunk-extractor/extract-delta chunk
                if string? delta [append content delta]
            ]
        ]
        
        assert-equal "Hello world!" content "Content matches expected output"
    ]
    
    ; Simulate tool call stream
    test-simulate-tool-call-stream: does [
        ; Reset collector
        tool-call-collector/reset
        
        ; Mock tool call SSE chunks using make map!
        chunk1: make map! reduce [
            'id "chatcmpl-456"
            'choices reduce [
                make map! reduce [
                    'index 0
                    'delta make map! reduce [
                        'tool_calls reduce [
                            make map! reduce [
                                'index 0
                                'id "call_abc"
                                'type "function"
                                'function make map! reduce [
                                    'name "write"
                                    'arguments ""
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        
        chunk2: make map! reduce [
            'id "chatcmpl-456"
            'choices reduce [
                make map! reduce [
                    'index 0
                    'delta make map! reduce [
                        'tool_calls reduce [
                            make map! reduce [
                                'index 0
                                'function make map! reduce [
                                    'name "_file"
                                    'arguments {"pa}
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        
        chunk3: make map! reduce [
            'id "chatcmpl-456"
            'choices reduce [
                make map! reduce [
                    'index 0
                    'delta make map! reduce [
                        'tool_calls reduce [
                            make map! reduce [
                                'index 0
                                'function make map! reduce [
                                    'name ""
                                    'arguments {th":"}
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        
        chunk4: make map! reduce [
            'id "chatcmpl-456"
            'choices reduce [
                make map! reduce [
                    'index 0
                    'delta make map! reduce [
                        'tool_calls reduce [
                            make map! reduce [
                                'index 0
                                'function make map! reduce [
                                    'name ""
                                    'arguments rejoin [{test.py","content":"hello"} "}}"]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        
        chunks: reduce [chunk1 chunk2 chunk3 chunk4]
        
        ; Process each chunk
        foreach chunk chunks [
            delta: sse-chunk-extractor/extract-delta chunk
            if all [block? delta  equal? 'tool_calls first delta] [
                tool-call-collector/update second delta
            ]
        ]
        
        calls: tool-call-collector/get-calls
        
        assert-equal 1 length? calls "One tool call collected from mock stream"
        
        first-call: pick calls 1
        assert-equal "call_abc" select first-call 'id "Tool call has correct id"
        assert-equal "write_file" select first-call/function 'name "Tool call name accumulated correctly"
        assert-string-contains select first-call/function 'arguments "test.py" "Arguments contain expected path"
    ]
    
    ; Run mock tests
    test-simulate-stream
    test-simulate-tool-call-stream
]

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
