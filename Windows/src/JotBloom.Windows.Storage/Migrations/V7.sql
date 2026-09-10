ALTER TABLE inspirations ADD COLUMN title_source TEXT NOT NULL DEFAULT 'fallback' CHECK(title_source IN ('ai','fallback','user'));
ALTER TABLE inspirations ADD COLUMN content_revision INTEGER NOT NULL DEFAULT 0;
ALTER TABLE inspirations ADD COLUMN title_revision INTEGER NOT NULL DEFAULT 0;
ALTER TABLE inspirations ADD COLUMN category_revision INTEGER NOT NULL DEFAULT 0;
ALTER TABLE inspirations ADD COLUMN lifecycle_token TEXT NOT NULL DEFAULT '';
ALTER TABLE chat_sessions ADD COLUMN system_prompt TEXT;
UPDATE inspirations SET body=CASE
    WHEN title='' OR substr(body,1,length(title))=title THEN body
    WHEN body='' THEN title ELSE title || char(10) || body END,
    title_source='user',lifecycle_token=lower(hex(randomblob(16)));
CREATE TRIGGER inspiration_lifecycle AFTER INSERT ON inspirations
    BEGIN UPDATE inspirations SET lifecycle_token=lower(hex(randomblob(16))) WHERE id=NEW.id; END;
PRAGMA user_version=7;
PRAGMA user_version=7;
