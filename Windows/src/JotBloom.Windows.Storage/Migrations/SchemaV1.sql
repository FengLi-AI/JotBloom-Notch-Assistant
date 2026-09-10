CREATE TABLE drafts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL UNIQUE
        CHECK (kind IN ('inspiration', 'ai_chat')),
    content TEXT NOT NULL,
    updated_at_utc_ms INTEGER NOT NULL
);

CREATE TABLE inspirations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    category TEXT NOT NULL
        CHECK (category IN ('文章类', '作品类', '产品类', 'idea')),
    category_source TEXT NOT NULL
        CHECK (category_source IN ('ai', 'fallback', 'user')),
    created_at_utc_ms INTEGER NOT NULL,
    updated_at_utc_ms INTEGER NOT NULL,
    source TEXT NOT NULL
        CHECK (source IN ('manual', 'ai_chat'))
);

CREATE INDEX idx_inspirations_updated_at
    ON inspirations(updated_at_utc_ms DESC, id DESC);
PRAGMA user_version=1;
