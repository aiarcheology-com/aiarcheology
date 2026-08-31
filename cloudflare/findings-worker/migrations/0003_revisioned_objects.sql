-- Revision-scoped R2 objects and reclaimable upload reservations (AIA-0753, AIA-0754).
--
-- A mutable `meta.json` / `image.jpg` path let a stale request replace a newer request's bytes in
-- R2 even though the compare-and-set correctly refused its index row. New objects now live under
-- their `modified_at` revision, and the finding row names exactly which metadata and image revision
-- is visible. The two references are deliberately separate: a metadata-only edit keeps the finding's
-- current screenshot rather than making it disappear.
ALTER TABLE finding ADD COLUMN meta_revision INTEGER;
ALTER TABLE finding ADD COLUMN meta_legacy INTEGER NOT NULL DEFAULT 1 CHECK (meta_legacy IN (0, 1));
ALTER TABLE finding ADD COLUMN image_revision INTEGER;
ALTER TABLE finding ADD COLUMN image_legacy INTEGER NOT NULL DEFAULT 1 CHECK (image_legacy IN (0, 1));

-- Existing committed objects stay at their old keys until the scheduled copy below has safely moved
-- them. An index row may legitimately point at a missing image, so `image_revision` is set only
-- when its storage record exists. Metadata retains the legacy reference even when a previous failed
-- write has already lost its object: returning 404 remains more truthful than naming invented bytes.
UPDATE finding
   SET meta_revision = CASE
                         WHEN deleted = 0
                           AND EXISTS (
                             SELECT 1 FROM object_bytes o
                              WHERE o.user_id = finding.user_id
                                AND o.finding_id = finding.id
                                AND o.kind = 'meta'
                           )
                         THEN modified_at
                         ELSE NULL
                       END,
       meta_legacy = 1,
       image_revision = CASE
                          WHEN deleted = 0
                            AND EXISTS (
                              SELECT 1 FROM object_bytes o
                               WHERE o.user_id = finding.user_id
                                 AND o.finding_id = finding.id
                                 AND o.kind = 'image'
                            )
                          THEN modified_at
                          ELSE NULL
                        END,
       image_legacy = 1;

-- One row now describes one immutable R2 object. `legacy` makes the old flat path an explicit
-- temporary layout, rather than a fallback guessed from a missing revision object. `created_at`
-- bounds a reservation that never reaches the finding commit; `reaping_at` is a lease that keeps a
-- late retry out while R2 deletion and D1 deletion complete in separate durable systems.
DROP INDEX object_bytes_by_user;
ALTER TABLE object_bytes RENAME TO legacy_object_bytes;

CREATE TABLE object_bytes (
  user_id    TEXT    NOT NULL,
  finding_id TEXT    NOT NULL,
  revision   INTEGER NOT NULL,
  kind       TEXT    NOT NULL,
  legacy     INTEGER NOT NULL DEFAULT 0 CHECK (legacy IN (0, 1)),
  bytes      INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  reaping_at INTEGER,
  PRIMARY KEY (user_id, finding_id, revision, kind, legacy)
);

CREATE INDEX object_bytes_by_user ON object_bytes (user_id);
CREATE INDEX object_bytes_reapable ON object_bytes (created_at) WHERE reaping_at IS NULL;

-- A row that is already committed inherits its finding's revision. An old interrupted image has no
-- finding to name it, so -1 intentionally cannot match a client `modifiedAt` (which is non-negative)
-- and is reclaimed after the staging lifetime.
INSERT INTO object_bytes (user_id, finding_id, revision, kind, legacy, bytes, created_at)
SELECT o.user_id,
       o.finding_id,
       COALESCE(f.modified_at, -1),
       o.kind,
       1,
       o.bytes,
       CAST(unixepoch() * 1000 AS INTEGER)
  FROM legacy_object_bytes o
  LEFT JOIN finding f ON f.user_id = o.user_id AND f.id = o.finding_id AND f.deleted = 0;

DROP TABLE legacy_object_bytes;
