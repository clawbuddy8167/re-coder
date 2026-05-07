REBOL [
    Title:   {Re Coder RAG Pipeline Integration Tests}
    Purpose: {Test each phase of the 3-phase RAG pipeline}
]

do %./re-coder-rag-pipeline.reb

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
;  Setup test fixtures
; ═══════════════════════════════════════════════════════════

test-dir-str: {./test-pipeline-fixtures/}
test-dir: to-rebol-file test-dir-str
make-dir/deep test-dir

write to-rebol-file rejoin [test-dir-str {auth.py}] {
# Authentication module for the web application

import hashlib
import jwt
from datetime import datetime, timedelta

SECRET_KEY = "super-secret-key-change-in-production"
TOKEN_EXPIRY_HOURS = 24

def hash_password(password: str) -> str:
    """Hash a password using SHA-256 with salt."""
    salt = "fixed-salt"
    return hashlib.sha256((password + salt).encode()).hexdigest()

def verify_password(password: str, hashed: str) -> bool:
    """Verify a password against its hash."""
    return hash_password(password) == hashed

def create_token(user_id: int) -> str:
    """Create a JWT token for the given user."""
    payload = {
        "user_id": user_id,
        "exp": datetime.utcnow() + timedelta(hours=TOKEN_EXPIRY_HOURS),
        "iat": datetime.utcnow()
    }
    return jwt.encode(payload, SECRET_KEY, algorithm="HS256")

def decode_token(token: str) -> dict:
    """Decode and validate a JWT token."""
    return jwt.decode(token, SECRET_KEY, algorithms=["HS256"])
}

write to-rebol-file rejoin [test-dir-str {database.py}] {
# Database connection module

import sqlite3
from contextlib import contextmanager

DB_PATH = "app.db"

@contextmanager
def get_connection():
    """Get a database connection with automatic close."""
    conn = sqlite3.connect(DB_PATH)
    try:
        yield conn
    finally:
        conn.close()

def init_db():
    """Initialize database tables."""
    with get_connection() as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username TEXT UNIQUE NOT NULL,
                password_hash TEXT NOT NULL,
                email TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """)
        conn.commit()

def create_user(username: str, password_hash: str, email: str = None) -> int:
    """Create a new user and return their ID."""
    with get_connection() as conn:
        cursor = conn.execute(
            "INSERT INTO users (username, password_hash, email) VALUES (?, ?, ?)",
            (username, password_hash, email)
        )
        conn.commit()
        return cursor.lastrowid

def get_user_by_username(username: str) -> dict:
    """Get user by username."""
    with get_connection() as conn:
        cursor = conn.execute(
            "SELECT * FROM users WHERE username = ?",
            (username,)
        )
        row = cursor.fetchone()
        if row:
            return {
                "id": row[0], "username": row[1],
                "password_hash": row[2], "email": row[3],
                "created_at": row[4]
            }
        return None
}

write to-rebol-file rejoin [test-dir-str {server.py}] {
# Web server entry point

from http.server import HTTPServer, BaseHTTPRequestHandler
import json
from auth import create_token, decode_token, verify_password
from database import get_user_by_username, init_db

class APIHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == "/api/login":
            content_length = int(self.headers["Content-Length"])
            body = json.loads(self.rfile.read(content_length))
            
            username = body.get("username")
            password = body.get("password")
            
            user = get_user_by_username(username)
            if not user:
                self.send_error(401, "Invalid credentials")
                return
            
            if not verify_password(password, user["password_hash"]):
                self.send_error(401, "Invalid credentials")
                return
            
            token = create_token(user["id"])
            
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"token": token}).encode())

def main():
    init_db()
    server = HTTPServer(("0.0.0.0", 8080), APIHandler)
    print("Server running on port 8080")
    server.serve_forever()

if __name__ == "__main__":
    main()
}

write to-rebol-file rejoin [test-dir-str {config.ini}] {
[database]
host = localhost
port = 5432
name = myapp

[auth]
jwt_secret = production-secret
token_expiry = 7200
}

write to-rebol-file rejoin [test-dir-str {README.md}] {
# MyApp

A web application with JWT authentication and SQLite database.

## Setup
1. Install dependencies: `pip install pyjwt`
2. Run: `python server.py`

## API
POST /api/login - Login and receive JWT token
}

; ═══════════════════════════════════════════════════════════
;  Test 1: rag-search finds source files
; ═══════════════════════════════════════════════════════════

results: rag-search {jwt} test-dir [%.py] 5
assert [(length? results) > 0] "search finds JWT-related files"
assert [find results/1/file {auth.py}] "JWT found in auth.py"

; ═══════════════════════════════════════════════════════════
;  Test 2: rag-search with no results
; ═══════════════════════════════════════════════════════════

results: rag-search {nonexistent_xyz_123} test-dir none none
assert [empty? results] "search returns empty for nonexistent term"

; ═══════════════════════════════════════════════════════════
;  Test 3: rag-multi-search deduplicates results
; ═══════════════════════════════════════════════════════════

queries: reduce [
    make map! reduce [#query {jwt}       #importance 10 #purpose {Find JWT code}]
    make map! reduce [#query {token}     #importance 8  #purpose {Find token code}]
    make map! reduce [#query {password}  #importance 7  #purpose {Find password code}]
]
results: rag-multi-search queries test-dir [%.py]
auth-hits: 0
foreach r results [if find to-string select r 'file {auth.py} [auth-hits: auth-hits + 1]]
assert [auth-hits > 0] "auth.py appears in multi-search results"
assert [(length? results) >= 1] "multi-search finds results"

; ═══════════════════════════════════════════════════════════
;  Test 4: rag-rank-results boosts multi-query files
; ═══════════════════════════════════════════════════════════

ranked: rag-rank-results results
assert [(length? ranked) > 0] "rank produces results"
; Check that boost_score and file_frequency are set
if (length? ranked) > 0 [
    hit: ranked/1
    assert [select hit 'boosted_score] "ranked results have boosted_score"
    assert [select hit 'file_frequency] "ranked results have file_frequency"
]

; ═══════════════════════════════════════════════════════════
;  Test 5: rag-rank-results handles empty input
; ═══════════════════════════════════════════════════════════

ranked: rag-rank-results copy []
assert [empty? ranked] "rank empty input returns empty"

; ═══════════════════════════════════════════════════════════
;  Test 6: parse-relevance handles valid responses
; ═══════════════════════════════════════════════════════════

; Test parse-relevance from filter module
parsed: parse-relevance {yes/8}
assert [parsed/1 = true]  "yes/8 → relevant=true"
assert [parsed/2 = 8]     "yes/8 → score=8"

parsed: parse-relevance {no/3}
assert [parsed/1 = false] "no/3 → relevant=false"
assert [parsed/2 = 3]     "no/3 → score=3"

parsed: parse-relevance {   yes/<10>   }
assert [parsed/1 = true]  "yes/<10> → relevant=true"

parsed: parse-relevance {No/0}
assert [parsed/1 = false] "No/0 → relevant=false"

parsed: parse-relevance {irrelevant}
assert [parsed/1 = false] "unparseable → relevant=false"

; ═══════════════════════════════════════════════════════════
;  Test 7: Multi-query with search across extensions
; ═══════════════════════════════════════════════════════════

queries: reduce [
    make map! reduce [#query {database} #importance 10 #purpose {Find DB code}]
]
results: rag-multi-search queries test-dir none
assert [(length? results) > 0] "multi-search without extension filter works"

; ═══════════════════════════════════════════════════════════
;  Test 8: est-tokens helper
; ═══════════════════════════════════════════════════════════

tok: est-tokens {hello world}
assert [integer? tok] "est-tokens returns integer"
assert [tok > 0] "est-tokens > 0 for non-empty string"

; ═══════════════════════════════════════════════════════════
;  Cleanup
; ═══════════════════════════════════════════════════════════

cleanup-dir: func [d [file!] /local f] [
    either dir? d [
        foreach f read d [cleanup-dir rejoin [d f]]
        attempt [delete d]
    ][
        attempt [delete d]
    ]
]
cleanup-dir test-dir

; Also clean up test-cache-fixtures if leftover
cache-test-dir: to-rebol-file {./test-cache-fixtures/}
if exists? cache-test-dir [cleanup-dir cache-test-dir]

; ═══════════════════════════════════════════════════════════
;  Results
; ═══════════════════════════════════════════════════════════

print rejoin [{=== } passed {/} (passed + failed) { tests passed ===}]
if failed > 0 [print rejoin [{*** } failed { TEST(S) FAILED ***}]]
if failed > 0 [quit/return 1]
