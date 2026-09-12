-- Durable purge progress (AIA-0842).
--
-- The fence (0002) records that a purge was OWED; nothing recorded whether it FINISHED. The sweep
-- inferred that from the index rows still behind the fence, and the purge deleted those rows
-- before its confirming R2 listing -- so an account whose objects outlasted one invocation's batch
-- budget, or whose purge died between the row wipe and the listing, had a fence, R2 leftovers and
-- no rows: invisible to recovery, for ever, with the only credential that could name the data
-- already deleted at Clerk.
--
-- `purged` is that record. `deleting = 1 AND purged = 0` means "owed and not confirmed". A purge
-- sets it to 0 as its first statement and to 1 only in the same batch that confirms the prefix
-- empty, so a crash anywhere in between leaves the account discoverable.
--
-- EVERY EXISTING FENCE BACKFILLS AS PENDING. The default is deliberate: nothing recorded whether
-- those purges finished, so the safe reading is that they did not. The sweep re-confirms each one
-- with an idempotent purge (four subrequests when the prefix is already empty), which is the
-- recovery path for R2-only leftovers that predate this change.
--
-- `purge_attempted_at` orders the sweep least-recently-attempted first, so one account that fails
-- every day cannot hold every later deletion behind it. `purge_attempt_id` identifies that one
-- attempt: Date.now() has millisecond precision, so its timestamp alone cannot distinguish two
-- overlapping app/webhook purges. Both are nullable: a backfilled fence has never been attempted
-- under this scheme and sorts first.
ALTER TABLE user_state ADD COLUMN purged INTEGER NOT NULL DEFAULT 0 CHECK (purged IN (0, 1));
ALTER TABLE user_state ADD COLUMN purge_attempted_at INTEGER;
ALTER TABLE user_state ADD COLUMN purge_attempt_id TEXT;
