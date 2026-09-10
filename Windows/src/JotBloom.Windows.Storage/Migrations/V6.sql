ALTER TABLE chat_sessions RENAME TO chat_sessions_v5;
ALTER TABLE chat_messages RENAME TO chat_messages_v5;
DROP INDEX chat_message_order;
CREATE TABLE chat_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    slot INTEGER UNIQUE CHECK(slot=1),
    token TEXT NOT NULL UNIQUE, updated_at_utc_ms INTEGER NOT NULL,
    title TEXT NOT NULL DEFAULT '', draft TEXT NOT NULL DEFAULT ''
);
INSERT INTO chat_sessions(id,slot,token,updated_at_utc_ms)
    SELECT id,slot,token,updated_at_utc_ms FROM chat_sessions_v5;
CREATE TABLE chat_messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id INTEGER NOT NULL REFERENCES chat_sessions(id) ON DELETE CASCADE,
    role TEXT NOT NULL CHECK(role IN ('user','assistant')),
    content TEXT NOT NULL, created_at_utc_ms INTEGER NOT NULL,
    turn_token TEXT NOT NULL, attempt_token TEXT NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('waiting','streaming','complete','stopped','failed','interrupted','length')),
    error_code TEXT, UNIQUE(session_id,turn_token,role)
);
INSERT INTO chat_messages SELECT * FROM chat_messages_v5;
UPDATE sqlite_sequence SET seq=MAX(seq,COALESCE((SELECT seq FROM sqlite_sequence WHERE name='chat_messages_v5'),0)) WHERE name='chat_messages';
UPDATE sqlite_sequence SET seq=MAX(seq,COALESCE((SELECT seq FROM sqlite_sequence WHERE name='chat_sessions_v5'),0)) WHERE name='chat_sessions';
DROP TABLE chat_messages_v5;
DROP TABLE chat_sessions_v5;
CREATE INDEX chat_message_order ON chat_messages(session_id,id DESC);
CREATE INDEX chat_session_order ON chat_sessions(updated_at_utc_ms DESC,id DESC);
PRAGMA user_version=6;
PRAGMA user_version=6;
