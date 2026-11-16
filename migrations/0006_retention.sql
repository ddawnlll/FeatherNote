-- FeatherNote schema v6: explicit history retention floors.
--
-- Purge is an operator action, never automatic. When old unlabelled revisions
-- are removed, the first retained revision is recorded here so the doctor can
-- distinguish a deliberate retention floor from a corrupt chain. Labelled
-- checkpoints are never purged and therefore always sit at or above the floor.
CREATE TABLE note_history_retention (
    note_id        INTEGER PRIMARY KEY REFERENCES notes(id) ON DELETE CASCADE,
    floor_revision INTEGER NOT NULL CHECK (floor_revision > 0),
    purged_at      INTEGER NOT NULL,
    purged_count   INTEGER NOT NULL CHECK (purged_count >= 0)
);
