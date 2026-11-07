-- FeatherNote schema v3: per-owner theme and note attachments.
ALTER TABLE owner ADD COLUMN theme TEXT NOT NULL DEFAULT 'feather';

CREATE TABLE attachments (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    note_id    INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    filename   TEXT    NOT NULL,
    mime       TEXT    NOT NULL,
    size       INTEGER NOT NULL,
    sha256     TEXT    NOT NULL,
    data       BLOB    NOT NULL,
    created_at INTEGER NOT NULL
);

CREATE INDEX attachments_note ON attachments(note_id, id);
