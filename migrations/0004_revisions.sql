-- FeatherNote schema v4: immutable note revisions and history-safe assets.
--
-- note_revisions is append-only. Each acknowledged meaningful edit stores a
-- full snapshot of the note so recovery never depends on a delta chain. The
-- baseline row (action='baseline') is the migration point: no earlier history
-- is fabricated for notes that existed before v4.
--
-- Attachments are soft-deleted instead of removed so revisions that referenced
-- them keep working. revision_assets records the live attachment manifest at
-- each revision boundary.

ALTER TABLE attachments ADD COLUMN deleted_at INTEGER;
CREATE INDEX attachments_live ON attachments(note_id, deleted_at, id);

CREATE TABLE note_revisions (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    note_id      INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    revision_no  INTEGER NOT NULL CHECK (revision_no > 0),
    note_version INTEGER NOT NULL CHECK (note_version > 0),
    title        TEXT    NOT NULL,
    body         TEXT    NOT NULL,
    is_pinned    INTEGER NOT NULL CHECK (is_pinned IN (0, 1)),
    deleted_at   INTEGER,
    created_at   INTEGER NOT NULL,
    origin       TEXT    NOT NULL CHECK (origin IN ('web', 'mcp', 'import', 'admin', 'system')),
    action       TEXT    NOT NULL,
    summary      TEXT    NOT NULL DEFAULT '',
    checksum     TEXT    NOT NULL CHECK (length(checksum) = 64),
    UNIQUE(note_id, revision_no)
);
CREATE INDEX note_revisions_timeline ON note_revisions(note_id, revision_no DESC);
CREATE INDEX note_revisions_origin ON note_revisions(origin, created_at);

CREATE TABLE revision_assets (
    revision_id   INTEGER NOT NULL REFERENCES note_revisions(id) ON DELETE CASCADE,
    attachment_id INTEGER NOT NULL,
    filename      TEXT    NOT NULL,
    mime          TEXT    NOT NULL,
    size          INTEGER NOT NULL,
    sha256        TEXT    NOT NULL,
    PRIMARY KEY(revision_id, attachment_id)
);
CREATE INDEX revision_assets_attachment ON revision_assets(attachment_id);
