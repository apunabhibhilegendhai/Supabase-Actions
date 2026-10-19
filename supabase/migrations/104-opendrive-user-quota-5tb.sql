-- Raise the registered-user storage quota to 5 TiB (5497558138880 bytes).
--
-- The Phase 1 migration seeded quota_limits.user with 5 GiB and
-- profiles.storage_quota_bytes defaulted to 5 GiB. Both now say 5 TiB:
--   * the policy row, so opendrive_quota_summary reads 5 TiB for users;
--   * the column default, so newly created profiles get 5 TiB;
--   * every existing profile row still holding the old 5 GiB default.
-- Idempotent: re-running on an already-raised database is a no-op.
update profiles set storage_quota_bytes = 5497558138880 where storage_quota_bytes = 5368709120;
alter table profiles alter column storage_quota_bytes set default 5497558138880;
update quota_limits set storage_bytes = 5497558138880 where principal_kind = 'user' and storage_bytes = 5368709120;