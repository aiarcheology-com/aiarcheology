-- The account write fence (AIA-728).
--
-- Set before a purge begins and never cleared. A purge is a list-and-delete loop, so without a
-- fence a device still holding a valid token can upload a finding after the final listing and leave
-- data behind a deletion that reported success. Clerk does not reuse user ids, so there is nothing
-- an un-fence would be for.
--
-- The row survives the purge on purpose, and that is what makes the endpoint idempotent: a second
-- call finds nothing to delete and answers `complete` again.
CREATE TABLE user_state (
  user_id  TEXT PRIMARY KEY,
  deleting INTEGER NOT NULL DEFAULT 0 CHECK (deleting IN (0, 1))
);
