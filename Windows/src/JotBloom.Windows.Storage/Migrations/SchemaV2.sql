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
);

CREATE INDEX idx_clipboard_items_copied_at
    ON clipboard_items(copied_at_utc_ms DESC, id DESC);

CREATE INDEX idx_clipboard_items_image_dedupe
    ON clipboard_items(
        content_type,
        content_byte_count,
        image_sha256
    );

CREATE INDEX idx_inspirations_updated_at
    ON inspirations(updated_at_utc_ms DESC, id DESC);
PRAGMA user_version=2;
