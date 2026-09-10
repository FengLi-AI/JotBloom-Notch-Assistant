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
);
CREATE INDEX idx_prompts_created_at ON prompts(created_at_utc_ms DESC, id DESC);
ALTER TABLE inspirations ADD COLUMN origin_kind TEXT NOT NULL DEFAULT 'manual';
ALTER TABLE inspirations ADD COLUMN source_clipboard_id INTEGER REFERENCES clipboard_items(id) ON DELETE SET NULL;
ALTER TABLE inspirations ADD COLUMN source_application_name TEXT;
ALTER TABLE inspirations ADD COLUMN source_bundle_identifier TEXT;
CREATE UNIQUE INDEX idx_inspirations_clipboard ON inspirations(source_clipboard_id);
UPDATE clipboard_items SET is_favorited_to_prompt = 0;
CREATE TRIGGER prompt_insert_flag AFTER INSERT ON prompts BEGIN
    UPDATE clipboard_items SET is_favorited_to_prompt = 1 WHERE id = NEW.source_clipboard_id;
END;
CREATE TRIGGER prompt_delete_flag AFTER DELETE ON prompts BEGIN
    UPDATE clipboard_items SET is_favorited_to_prompt = 0 WHERE id = OLD.source_clipboard_id;
END;
PRAGMA user_version=3;
