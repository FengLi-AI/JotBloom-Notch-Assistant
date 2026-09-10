CREATE TABLE chat_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    slot INTEGER NOT NULL UNIQUE CHECK(slot=1),
    token TEXT NOT NULL UNIQUE, updated_at_utc_ms INTEGER NOT NULL
);
CREATE TABLE chat_messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id INTEGER NOT NULL REFERENCES chat_sessions(id) ON DELETE CASCADE,
    role TEXT NOT NULL CHECK(role IN ('user','assistant')),
    content TEXT NOT NULL, created_at_utc_ms INTEGER NOT NULL,
    turn_token TEXT NOT NULL, attempt_token TEXT NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('waiting','streaming','complete','stopped','failed','interrupted','length')),
    error_code TEXT,
    UNIQUE(session_id,turn_token,role)
);
CREATE INDEX chat_message_order ON chat_messages(session_id,id DESC);
CREATE INDEX inspiration_category_order ON inspirations(category,sort_order DESC,id DESC);
PRAGMA user_version = 5;
PRAGMA user_version=5;
