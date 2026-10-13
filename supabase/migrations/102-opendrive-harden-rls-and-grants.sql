-- OpenDrive Phase 2 hardening: RLS + privilege cleanup after first live bring-up.
--
-- Builds on 20261010000001_initial_schema.sql and 20261011000001_phase1_identity_ownership_quota.sql.
-- That pair already enables RLS on every OpenDrive table, but three gaps were found on the first
-- real Supabase instance and are closed here:
--
--   1. public._schema_migrations was created by the migration runner (not by a migration), so
--      Supabase's default privileges granted ALL to anon/authenticated and RLS was left DISABLED.
--      It is exposed by PostgREST, which made the migration ledger world-readable and writable.
--   2. Supabase's ALTER DEFAULT PRIVILEGES re-granted ALL to `anon` on every table created AFTER
--      the initial migration's `revoke all ... from anon`, so the phase-1 tables were reachable
--      anonymously (RLS denied the rows, but the grant should not exist at all).
--   3. `authenticated` held table privileges on internal tables that have NO policy (api_keys,
--      anonymous_sessions, quota_*, usage_counters, ...). No policy means deny, but a table that
--      the API should never touch should not carry a client grant either.
--
-- Design: the trusted OpenDrive API connects directly as `opendrive_app`, which is given BYPASSRLS
-- (see supabase/volumes/db/init/zz-opendrive-role.sql) because it performs its own authorization.
-- RLS here exists to protect DIRECT PostgREST access by the `anon` / `authenticated` roles.
--
-- Idempotent: every statement is safe to re-run.
--
-- Verification status: execution-verified against the live self-hosted instance on 2026-10-11.

-- ---------------------------------------------------------------------------
-- 1. The migration ledger is bookkeeping, not an API resource.
--
--    `_schema_migrations` is created by the Supabase migration runner, not by a migration, so it
--    is absent when the SQL is applied by the plain-psql harness (and by `opendrive_app`, which
--    only exists on the self-hosted instance). Guard both, so the file is executable everywhere.
-- ---------------------------------------------------------------------------

do $$
declare
  grantees text := 'anon, authenticated';
begin
  if to_regclass('public._schema_migrations') is null then
    return;
  end if;
  if to_regrole('opendrive_app') is not null then
    grantees := grantees || ', opendrive_app';
  end if;
  execute format('revoke all on table public._schema_migrations from %s', grantees);
  execute 'alter table public._schema_migrations enable row level security';
end
$$;

-- ---------------------------------------------------------------------------
-- 2. No OpenDrive table is reachable by the anonymous role.
--    (Mirrors the initial migration's `revoke all on all tables ... from anon`, which only ran
--    against the tables that existed at that point.)
-- ---------------------------------------------------------------------------

revoke all on table
  public.profiles,
  public.files,
  public.folders,
  public.shares,
  public.storage_objects,
  public.upload_sessions,
  public.api_keys,
  public.audit_events,
  public.abuse_reports,
  public.moderation_actions,
  public.anonymous_sessions,
  public.quota_limits,
  public.quota_reservations,
  public.usage_counters
from anon;

-- ---------------------------------------------------------------------------
-- 3. `authenticated` keeps privileges only where RLS policies were written for it.
--    Everything else is server-only (opendrive_app / service_role).
--    NOTE: we revoke on ALL OpenDrive tables first, because Supabase's
--    ALTER DEFAULT PRIVILEGES handed `authenticated` the full ALL mask
--    (including TRUNCATE/TRIGGER/REFERENCES) at creation time.
-- ---------------------------------------------------------------------------

revoke all on table
  public.profiles,
  public.files,
  public.folders,
  public.shares,
  public.storage_objects,
  public.upload_sessions,
  public.api_keys,
  public.audit_events,
  public.abuse_reports,
  public.moderation_actions,
  public.anonymous_sessions,
  public.quota_limits,
  public.quota_reservations,
  public.usage_counters
from authenticated;

-- Re-grant exactly the intended `authenticated` surface. These match the RLS policies written in
-- the two prior migrations: profiles(id = auth.uid()), files/folders(owner_user_id = auth.uid()),
-- shares(created_by = auth.uid() OR owns the file).
grant select, update on table public.profiles to authenticated;
grant select, delete on table public.files to authenticated;
grant select, delete on table public.folders to authenticated;
grant select on table public.shares to authenticated;

-- ---------------------------------------------------------------------------
-- 4. PostgREST must not even advertise unreadable OpenDrive relations.
--    (RLS + revoked grants already deny access; this keeps the API surface honest.)
-- ---------------------------------------------------------------------------

-- The `anon` and `authenticated` roles need no object privileges on the internal tables above;
-- leaving them without grants means PostgREST answers 401/403 rather than leaking schema.
