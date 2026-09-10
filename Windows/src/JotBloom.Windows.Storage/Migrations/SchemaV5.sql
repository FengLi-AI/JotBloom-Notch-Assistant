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

CREATE TABLE chat_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    slot INTEGER NOT NULL UNIQUE CHECK(slot=1),
    token TEXT NOT NULL UNIQUE, updated_at_utc_ms INTEGER NOT NULL
);

CREATE TABLE clipboard_items (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    content_type TEXT NOT NULL
        CHECK (content_type IN ('text', 'link', 'image')),
    text_content TEXT,
    image_file_name TEXT,
    thumbnail_file_name TEXT,
    content_byte_count INTEGER NOT NULL
        CHECK (content_byte_count >= 0),
    image_sha256 TEXT,
    image_width_px INTEGER,
    image_height_px INTEGER,
    copied_at_utc_ms INTEGER NOT NULL,
    source_application_name TEXT,
    source_bundle_identifier TEXT,
    is_favorited_to_prompt INTEGER NOT NULL DEFAULT 0
        CHECK (is_favorited_to_prompt IN (0, 1)),
    CHECK (
        (
            content_type IN ('text', 'link')
            AND text_content IS NOT NULL
            AND image_file_name IS NULL
            AND thumbnail_file_name IS NULL
            AND image_sha256 IS NULL
            AND image_width_px IS NULL
            AND image_height_px IS NULL
        )
        OR
        (
            content_type = 'image'
            AND text_content IS NULL
            AND image_file_name IS NOT NULL
            AND thumbnail_file_name IS NOT NULL
            AND image_sha256 IS NOT NULL
            AND image_width_px IS NOT NULL
            AND image_width_px > 0
            AND image_height_px IS NOT NULL
            AND image_height_px > 0
        )
    )
);

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
, origin_kind TEXT NOT NULL DEFAULT 'manual', source_clipboard_id INTEGER REFERENCES clipboard_items(id) ON DELETE SET NULL, source_application_name TEXT, source_bundle_identifier TEXT, sort_order INTEGER NOT NULL DEFAULT 0);

CREATE TABLE prompts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL, content TEXT NOT NULL,
    title_source TEXT NOT NULL CHECK(title_source IN ('ai','fallback','user')),
    created_at_utc_ms INTEGER NOT NULL,
    origin_kind TEXT NOT NULL CHECK(origin_kind IN ('clipboard','input')),
    source_clipboard_id INTEGER UNIQUE REFERENCES clipboard_items(id) ON DELETE SET NULL,
    source_application_name TEXT, source_bundle_identifier TEXT,
    submission_token TEXT NOT NULL UNIQUE,
    lifecycle_token TEXT NOT NULL,
    title_revision INTEGER NOT NULL DEFAULT 0
, sort_order INTEGER NOT NULL DEFAULT 0, is_favorite INTEGER NOT NULL DEFAULT 0 CHECK(is_favorite IN (0,1)));

CREATE INDEX chat_message_order ON chat_messages(session_id,id DESC);

CREATE INDEX idx_clipboard_items_copied_at
    ON clipboard_items(copied_at_utc_ms DESC, id DESC);

CREATE INDEX idx_clipboard_items_image_dedupe
    ON clipboard_items(
        content_type,
        content_byte_count,
        image_sha256
    );

CREATE UNIQUE INDEX idx_inspirations_clipboard ON inspirations(source_clipboard_id);

CREATE INDEX idx_inspirations_updated_at
    ON inspirations(updated_at_utc_ms DESC, id DESC);

CREATE INDEX idx_prompts_created_at ON prompts(created_at_utc_ms DESC, id DESC);

CREATE INDEX inspiration_category_order ON inspirations(category,sort_order DESC,id DESC);

CREATE INDEX inspirations_manual_order ON inspirations(sort_order DESC,id DESC);

CREATE INDEX prompts_manual_order ON prompts(sort_order DESC,id DESC);

CREATE TRIGGER prompt_delete_flag AFTER DELETE ON prompts BEGIN
    UPDATE clipboard_items SET is_favorited_to_prompt = 0 WHERE id = OLD.source_clipboard_id;
END;

CREATE TRIGGER prompt_insert_flag AFTER INSERT ON prompts BEGIN
    UPDATE clipboard_items SET is_favorited_to_prompt = 1 WHERE id = NEW.source_clipboard_id;
END;
PRAGMA user_version=5;
