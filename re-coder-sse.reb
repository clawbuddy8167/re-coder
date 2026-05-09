REBOL [
    Title:   {Re Coder SSE — Server-Sent Events streaming support}
    Name:    're-coder-sse
    Version: 1.0.0
    Author:  {Hermes Agent}
    Rights:  {MIT}
    Purpose: {SSE streaming HTTP client for OpenAI-compatible APIs.
              Provides real-time token streaming for LLM responses.}
]

; ═══════════════════════════════════════════════════════════
;  SSE Line Parser
;
;  SSE format:
;    data: {"chunk": "..."}\n\n
;    data: [DONE]\n\n
; ═══════════════════════════════════════════════════════════

sse-line-parser: make object! [
    ; Parse a single SSE data line
    ; Returns: [map! | "DONE" | none]
    parse-data-line: func [line [string!] /local data-str][
        ; Trim whitespace
        line: trim line
        
        ; Skip empty lines and comments
        if empty? line [return none]
        if (first line) = #";" [return none]
        
        ; Check for "data: " prefix
        unless find line "data: " [return none]
        
        ; Extract data after "data: "
        data-str: copy/part skip line 6 tail line
        data-str: trim data-str
        
        ; Check for [DONE]
        if data-str = "[DONE]" [return "DONE"]
        
        ; Parse JSON
        attempt [load-json data-str]
    ]
    
    ; Parse a buffer of SSE data into individual chunks
    ; Returns: block of [map! | "DONE"]
    ; Updates buffer position for partial reads
    parse-buffer: func [
        buffer [string!]
        /local chunks lines line result
    ][
        chunks: copy []
        
        ; Split by double newline (SSE event boundary)
        lines: split buffer "^/^/"
        
        foreach line lines [
            result: parse-data-line line
            if result [
                append/only chunks result
            ]
        ]
        
        chunks
    ]
]

; ═══════════════════════════════════════════════════════════
;  SSE Chunk Content Extractor
;
;  Extracts delta content from OpenAI-style streaming chunks
; ═══════════════════════════════════════════════════════════

sse-chunk-extractor: make object! [
    ; Extract delta content from a chunk
    ; Returns: [string! | block! | none]
    ;   string! - text content delta
    ;   block!  - tool_calls delta
    ;   none    - no content in this chunk
    extract-delta: func [chunk [map!] /local choices choice delta content][
        choices: select chunk 'choices
        unless all [block? choices  not empty? choices] [return none]
        
        choice: pick choices 1
        unless map? choice [return none]
        
        delta: select choice 'delta
        unless map? delta [return none]
        
        ; Check for text content
        content: select delta 'content
        if string? content [return content]
        
        ; Check for tool_calls delta
        tool-calls: select delta 'tool_calls
        if block? tool-calls [return reduce ['tool_calls tool-calls]]
        
        ; Check for role (first chunk)
        role: select delta 'role
        if string? role [return none]  ; Skip role markers
        
        none
    ]
    
    ; Extract usage info from chunk (usually last chunk with stream_options.include_usage)
    ; Returns: [map! | none]
    extract-usage: func [chunk [map!] /local usage][
        usage: select chunk 'usage
        if map? usage [return usage]
        none
    ]
    
    ; Extract finish_reason from chunk
    ; Returns: [string! | none]
    extract-finish-reason: func [chunk [map!] /local choices choice][
        choices: select chunk 'choices
        unless all [block? choices  not empty? choices] [return none]
        
        choice: pick choices 1
        unless map? choice [return none]
        
        select choice 'finish_reason
    ]
]

; ═══════════════════════════════════════════════════════════
;  Tool Call Stream Collector
;
;  Incrementally collects tool_calls from streaming chunks
; ═══════════════════════════════════════════════════════════

tool-call-collector: make object! [
    calls: []   ; Block of tool call maps, indexed by position
    
    ; Reset collector for new stream
    reset: func [][
        calls: copy []
    ]
    
    ; Update with new tool_calls delta
    ; delta-calls is a block of incremental tool call data
    update: func [delta-calls [block!] /local idx tc existing fn][
        foreach tc delta-calls [
            unless map? tc [continue]
            
            idx: select tc 'index
            unless integer? idx [continue]
            
            ; Ensure position exists (0-indexed in stream, 1-indexed in Rebol)
            while [idx >= length? calls] [
                append/only calls make map! reduce [
                    'id ""
                    'type "function"
                    'function make map! reduce ['name "" 'arguments ""]
                ]
            ]
            
            ; Get existing entry
            existing: pick calls (idx + 1)
            
            ; Update id if present
            if select tc 'id [
                put existing 'id select tc 'id
            ]
            
            ; Update type if present
            if select tc 'type [
                put existing 'type select tc 'type
            ]
            
            ; Update function fields
            fn: select tc 'function
            if map? fn [
                ; Append to name (incremental)
                if select fn 'name [
                    put existing/function 'name rejoin [
                        select existing/function 'name
                        select fn 'name
                    ]
                ]
                ; Append to arguments (incremental JSON string)
                if select fn 'arguments [
                    put existing/function 'arguments rejoin [
                        select existing/function 'arguments
                        select fn 'arguments
                    ]
                ]
            ]
        ]
    ]
    
    ; Get collected tool calls as block of maps
    ; Returns: block! (empty if no tool calls)
    get-calls: func [/local result tc][
        result: copy []
        foreach tc calls [
            ; Only include calls that have a name
            if all [
                string? select tc 'id
                not empty? select tc 'id
                string? select tc/function 'name
                not empty? select tc/function 'name
            ][
                append/only result tc
            ]
        ]
        result
    ]
    
    ; Check if any tool calls were collected
    has-calls: func [][
        not empty? get-calls
    ]
]

; ═══════════════════════════════════════════════════════════
;  SSE Stream Reader
;
;  Core streaming HTTP client using curl
; ═══════════════════════════════════════════════════════════

sse-reader: make object! [
    ; Configuration
    config: #[
        connect-timeout: 15    ; seconds
        max-time: 300          ; seconds (5 minutes for long streams)
        buffer-size: 4096      ; read buffer size
    ]
    
    ; State
    buffer: ""
    partial-line: ""
    
    ; Reset state
    reset: func [][
        buffer: copy ""
        partial-line: copy ""
    ]
    
    ; Build curl command for SSE streaming
    build-curl-cmd: func [
        url     [url! string!]
        headers [map!]
        body    [string!]
        /local cmd auth-h ct-h
    ][
        auth-h: select headers 'Authorization
        ct-h: any [select headers 'Content-Type "application/json"]
        
        rejoin [
            {curl -N --no-buffer }
            {--connect-timeout } config/connect-timeout { }
            {--max-time } config/max-time { }
            {-X POST }
            {-H "Content-Type: } ct-h {" }
            {-H "Authorization: } auth-h {" }
            {-H "Accept: text/event-stream" }
            {-d '} body {' }
            url
        ]
    ]
    
    ; Read SSE stream with callback
    ; callback receives: [map! chunk | "DONE" | string! error]
    ; Returns: collected full response map
    read-stream: func [
        url      [url! string!]
        headers  [map!]
        body     [string!]
        callback [function!]
        /local cmd port chunk chunks result usage
    ][
        reset
        
        cmd: build-curl-cmd url headers body
        
        ; Open pipe to curl
        port: attempt [
            open/direct/binary rejoin [pipe:// cmd]
        ]
        
        unless port [
            callback "ERROR: Failed to start curl process"
            return none
        ]
        
        ; Initialize result accumulator
        result: make map! reduce [
            'id ""
            'role "assistant"
            'content ""
            'tool_calls []
            'usage none
            'finish_reason none
        ]
        
        ; Initialize tool call collector
        tool-call-collector/reset
        
        ; Read loop
        while [true] [
            chunk: attempt [copy/part port config/buffer-size]
            
            unless chunk [
                ; End of stream or error
                break
            ]
            
            if empty? chunk [continue]
            
            ; Append to buffer
            append buffer to-string chunk
            
            ; Process complete lines
            while [newline-pos: find buffer newline] [
                line: copy/part buffer newline-pos
                buffer: copy next newline-pos
                
                ; Handle partial lines from previous read
                if not empty? partial-line [
                    line: rejoin [partial-line line]
                    partial-line: copy ""
                ]
                
                ; Skip empty lines (SSE event separators)
                if empty? trim/with line whitespace [continue]
                
                ; Skip SSE comments
                if (first line) = #";" [continue]
                
                ; Parse SSE data line
                if find line "data: " [
                    data-str: copy/part skip line 6 tail line
                    
                    ; Check for [DONE]
                    if data-str = "[DONE]" [
                        callback "DONE"
                        break
                    ]
                    
                    ; Parse JSON chunk
                    parsed: attempt [load-json data-str]
                    if map? parsed [
                        ; Extract content
                        delta: sse-chunk-extractor/extract-delta parsed
                        case [
                            string? delta [
                                append result/content delta
                                callback delta  ; Stream text to callback
                            ]
                            block? delta [
                                ; Tool calls delta
                                if equal? first delta 'tool_calls [
                                    tool-call-collector/update second delta
                                ]
                            ]
                        ]
                        
                        ; Extract usage (last chunk)
                        usage: sse-chunk-extractor/extract-usage parsed
                        if usage [
                            put result 'usage usage
                        ]
                        
                        ; Extract finish reason
                        finish: sse-chunk-extractor/extract-finish-reason parsed
                        if finish [
                            put result 'finish_reason finish
                        ]
                    ]
                ]
            ]
            
            ; Save any remaining partial line
            if not empty? buffer [
                partial-line: copy buffer
                buffer: copy ""
            ]
        ]
        
        ; Close port
        attempt [close port]
        
        ; Collect tool calls
        if tool-call-collector/has-calls [
            put result 'tool_calls tool-call-collector/get-calls
        ]
        
        result
    ]
]

; ═══════════════════════════════════════════════════════════
;  High-level SSE HTTP POST
;
;  Drop-in replacement for http-post-json with streaming
; ═══════════════════════════════════════════════════════════

http-post-stream: func [
    url      [url! string!]
    payload  [map!]
    headers  [map!]
    callback [function!]  ; func [chunk [string!]] for each token
    /local body tmpfile result
][
    ; Ensure stream: true in payload
    unless select payload 'stream [
        put payload 'stream true
    ]
    
    ; Add stream_options for usage tracking
    unless select payload 'stream_options [
        put payload 'stream_options #[
            include_usage: true
        ]
    ]
    
    ; Serialize payload to JSON
    body: to-json payload
    unless body [
        callback "ERROR: Failed to serialize payload"
        return none
    ]
    
    ; Write to temp file to avoid shell quoting issues
    tmpfile: %./.hermes-sse-body.tmp
    write tmpfile body
    
    ; Read stream
    result: sse-reader/read-stream url headers body callback
    
    ; Cleanup temp file
    attempt [delete tmpfile]
    
    result
]

; ═══════════════════════════════════════════════════════════
;  Streaming LLM Client
;
;  OpenAI-compatible streaming client
; ═══════════════════════════════════════════════════════════

stream-llm-client: make object! [
    ; Configuration
    model: "deepseek-chat"
    api-key: ""
    base-url: "https://api.deepseek.com"
    
    ; Debug flags
    print-input: true
    print-output: true
    
    ; Stream chat with callback for each token
    ; callback: func [token [string!]] — called for each text token
    ; Returns: full response map with accumulated content
    chat-stream: func [
        messages [block!]
        callback [function!]
        /with-tools tool-defs [block!]
        /local url payload headers result
    ][
        url: to-url rejoin [base-url "/chat/completions"]
        
        ; Build payload
        payload: make map! reduce [
            to-set-word 'model model
            to-set-word 'messages messages
            to-set-word 'stream true
            to-set-word 'stream_options #[
                include_usage: true
            ]
        ]
        
        if with-tools [
            put payload 'tools tool-defs
            put payload 'tool_choice "auto"
        ]
        
        ; Build headers
        headers: make map! reduce [
            to-set-word 'Content-Type "application/json"
            to-set-word 'Authorization rejoin ["Bearer " api-key]
        ]
        
        ; Debug output
        if print-input [
            print [newline "── SSE Stream Request ──"]
            print ["  URL: " url]
            print ["  Body: " to-json payload]
            print "──────────────────────────"
        ]
        
        ; Execute streaming request
        result: http-post-stream url payload headers callback
        
        ; Debug output
        if all [print-output  map? result] [
            print [newline "── SSE Stream Complete ──"]
            print ["  Content length: " length? select result 'content]
            print ["  Tool calls: " length? select result 'tool_calls]
            if select result 'usage [
                print ["  Usage: " to-json select result 'usage]
            ]
            print "──────────────────────────"
        ]
        
        result
    ]
    
    ; Non-streaming fallback (for comparison)
    chat: func [
        messages [block!]
        /with-tools tool-defs [block!]
        /local url payload headers body tmpfile cmd output parsed
    ][
        url: to-url rejoin [base-url "/chat/completions"]
        
        payload: make map! reduce [
            to-set-word 'model model
            to-set-word 'messages messages
        ]
        
        if with-tools [
            put payload 'tools tool-defs
            put payload 'tool_choice "auto"
        ]
        
        ; Use curl for non-streaming
        body: to-json payload
        tmpfile: %./.hermes-nonstream-body.tmp
        write tmpfile body
        
        cmd: rejoin [
            {curl -s --connect-timeout 15 --max-time 120 }
            {-X POST }
            {-H "Content-Type: application/json" }
            {-H "Authorization: Bearer } api-key {" }
            {-H "Accept: application/json" }
            {-d @"} tmpfile {" }
            url
        ]
        
        output: ""
        attempt [
            call/wait/shell/output cmd output
        ]
        
        attempt [delete tmpfile]
        
        parsed: attempt [load-json to-string output]
        if map? parsed [return parsed]
        
        none
    ]
]

; ═══════════════════════════════════════════════════════════
;  Convenience: Simple streaming print
; ═══════════════════════════════════════════════════════════

; Print stream tokens in real-time
stream-print: func [
    url      [url! string!]
    payload  [map!]
    headers  [map!]
    /local result
][
    result: http-post-stream url payload headers func [token [string!]] [
        if string? token [
            prin token  ; Print without newline
        ]
    ]
    print ""  ; Final newline
    result
]

print {re-coder-sse loaded. Available: sse-reader, stream-llm-client, http-post-stream, stream-print}
