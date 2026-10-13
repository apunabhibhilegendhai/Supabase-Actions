-- OpenDrive initial metadata schema.
--
-- Scope: METADATA ONLY. File contents never live in Postgres — they belong to a storage
-- provider, referenced by an opaque locator in `storage_objects`. Anything that would
-- require bytes here (thumbnails, checksum previews of content) is out of scope.
--
-- Security posture encoded below:
--   * Private by default (`files.visibility` defaults to 'private').
--   * Bearer credentials (share tokens, deletion tokens, API keys) are stored ONLY as
--     SHA-256 hashes. The plaintext is returned once, at creation, and never persisted.
--   * Row Level Security is enabled on every table with no permissive default: the server
--     uses the service role and enforces authorization in application code, while the
--     anon/authenticated roles get only narrowly scoped access.
--
-- Verification status: execution-verified against a local PostgreSQL 17.6 instance by
-- `supabase/tests/run-local.sh`, which applies this file to an empty database followed by three
-- assertion suites (structure/defaults/grants, constraints/referential actions, RLS behaviour).
-- 152 assertions pass, including: every table has RLS enabled with no permissive default; `anon`
-- holds no table privilege; `authenticated` cannot read a row it does not own (cross-tenant reads
-- return 0 rows) and cannot write files, shares, keys or audit data at all; `service_role`
-- bypasses RLS as intended; and each constraint rejects what it claims to, naming the constraint.
--
-- Still NOT verified: this has never been applied to a real Supabase instance. The shim in
-- supabase/tests/00_local_supabase_shim.sql reproduces the Supabase-provided surface this file
-- depends on (roles, auth.users, auth.uid()) and mirrors Supabase's own definition of auth.uid(),
-- but it is a reconstruction, not the platform. Confirm against a development Supabase project
-- before trusting it in production, and see the Phase 1 prerequisites in docs/ROADMAP.md.

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

create type file_visibility as enum ('private', 'public', 'unlisted');

create type file_status as enum (
  'pending',      -- metadata row exists, no bytes yet
  'uploading',    -- bytes arriving
  'scanning',     -- stored, awaiting malware scan
  'available',    -- downloadable
  'quarantined',  -- failed scanning or reported
  'failed',       -- upload or storage failure
  'deleted'       -- soft-deleted; storage cleanup may still be pending
);

create type upload_state as enum ('initiated', 'in_progress', 'finalized', 'aborted', 'expired', 'failed');

create type share_kind as enum ('public', 'unlisted');

create type actor_kind as enum ('anonymous', 'user', 'service', 'admin');

create type abuse_reason as enum ('copyright', 'malware', 'illegal_content', 'spam', 'other');

create type moderation_state as enum ('open', 'triaged', 'actioned', 'rejected');

-- ---------------------------------------------------------------------------
-- Profiles: application-side view of an authenticated identity
-- ---------------------------------------------------------------------------

create table profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text check (char_length(display_name) between 1 and 80),
  storage_quota_bytes bigint not null default 5368709120 check (storage_quota_bytes > 0),
  max_file_size_bytes bigint not null default 2147483648 check (max_file_size_bytes > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  disabled_at timestamptz
);

comment on table profiles is
  'Per-user application data. Identity itself lives in auth.users (Supabase Auth). A user may exist here with no uploads.';
comment on column profiles.storage_quota_bytes is
  'Quota is a policy value, not an enforced counter: enforcement compares SUM(files.size_bytes) against it.';

-- ---------------------------------------------------------------------------
-- Files
-- ---------------------------------------------------------------------------

create table files (
  -- Internal prefixed identifier (file_…). Never a provider identifier.
  id text primary key check (id ~ '^file_[0-9a-hjkmnp-tv-z]{26}$'),
  owner_id uuid references profiles (id) on delete set null,
  original_filename text not null check (char_length(original_filename) between 1 and 255),
  -- Sanitised name used in Content-Disposition. Kept separate from the original so a
  -- hostile filename can never be reflected into a response header.
  download_filename text check (char_length(download_filename) between 1 and 255),
  size_bytes bigint not null check (size_bytes > 0 and size_bytes <= 2147483648),
  mime_type text not null check (char_length(mime_type) between 1 and 255),
  detected_mime_type text,
  checksum_sha256 text check (checksum_sha256 is null or checksum_sha256 ~ '^[0-9a-f]{64}$'),
  visibility file_visibility not null default 'private',
  status file_status not null default 'pending',
  -- Hash of the anonymous deletion bearer token. Plaintext exists only in the upload response.
  deletion_token_hash text check (deletion_token_hash is null or deletion_token_hash ~ '^[0-9a-f]{64}$'),
  scan_state text check (scan_state in ('not_scanned', 'pending', 'clean', 'infected', 'error')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz,
  deleted_at timestamptz,
  constraint files_deleted_consistency check ((status = 'deleted') = (deleted_at is not null)),
  constraint files_quarantine_reason check (
    status <> 'quarantined' or scan_state in ('infected', 'error')
  )
);

comment on table files is
  'Metadata for one stored object. `size_bytes` is capped at the 2 GiB product target; the effective cap is also limited by the storage provider and by the API configuration.';
comment on column files.visibility is
  'Private by default. Every read of a private file requires a server-side authorization decision.';
comment on column files.deletion_token_hash is
  'SHA-256 of the anonymous deletion token. Compared in constant time. A database leak must not yield a usable token.';

create index files_owner_created_idx on files (owner_id, created_at desc) where deleted_at is null;
create index files_status_idx on files (status) where deleted_at is null;
create index files_visibility_created_idx on files (visibility, created_at desc) where status = 'available';
create index files_expires_idx on files (expires_at) where expires_at is not null and deleted_at is null;

-- ---------------------------------------------------------------------------
-- Storage objects: the mapping from internal ids to provider-specific references
-- ---------------------------------------------------------------------------

create table storage_objects (
  id text primary key check (id ~ '^sobj_[0-9a-hjkmnp-tv-z]{26}$'),
  file_id text not null references files (id) on delete cascade,
  provider_id text not null check (char_length(provider_id) between 1 and 64),
  -- Opaque provider handle (for example a chat/message pair for the experimental Telegram
  -- backend). Kept in one jsonb column so provider details never leak into other tables or
  -- public API responses.
  provider_ref jsonb not null,
  size_bytes bigint not null check (size_bytes > 0),
  checksum_sha256 text check (checksum_sha256 is null or checksum_sha256 ~ '^[0-9a-f]{64}$'),
  state text not null default 'active' check (state in ('active', 'orphaned', 'deleting', 'deleted')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

comment on table storage_objects is
  'Where a file''s bytes actually live. A file may have several rows over time (provider migration, failed deletion, re-upload); exactly one row per file should be in state ''active''.';
comment on column storage_objects.provider_ref is
  'Provider-specific locator. Server-side only: it must never appear in an API response, a log line or an error message shown to a client.';

create unique index storage_objects_one_active_per_file
  on storage_objects (file_id)
  where state = 'active';
create index storage_objects_provider_idx on storage_objects (provider_id, state);
create index storage_objects_orphan_idx on storage_objects (state, updated_at) where state <> 'active';

-- ---------------------------------------------------------------------------
-- Upload sessions: stateful upload workflows with recoverable intermediate states
-- ---------------------------------------------------------------------------

create table upload_sessions (
  id text primary key check (id ~ '^upl_[0-9a-hjkmnp-tv-z]{26}$'),
  file_id text not null references files (id) on delete cascade,
  state upload_state not null default 'initiated',
  declared_size_bytes bigint not null check (declared_size_bytes > 0 and declared_size_bytes <= 2147483648),
  chunk_size_bytes integer not null check (chunk_size_bytes between 1048576 and 67108864),
  parts_expected integer check (parts_expected is null or parts_expected > 0),
  parts_received integer not null default 0 check (parts_received >= 0),
  bytes_received bigint not null default 0 check (bytes_received >= 0),
  provider_session_ref text,
  last_error text,
  initiated_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '24 hours',
  finalized_at timestamptz,
  constraint upload_sessions_received_within_declared check (bytes_received <= declared_size_bytes)
);

comment on table upload_sessions is
  'A resumable upload. Interrupted sessions are recoverable: parts_* and bytes_received describe exactly how far the client got, and rows past expires_at are aborted by the retention job so staged bytes are not leaked.';

create index upload_sessions_file_idx on upload_sessions (file_id);
create index upload_sessions_open_idx on upload_sessions (state, expires_at)
  where state in ('initiated', 'in_progress');

-- ---------------------------------------------------------------------------
-- Share links
-- ---------------------------------------------------------------------------

create table shares (
  id text primary key check (id ~ '^shr_[0-9a-hjkmnp-tv-z]{26}$'),
  file_id text not null references files (id) on delete cascade,
  kind share_kind not null default 'unlisted',
  -- SHA-256 of the share token. The token itself is returned once, at creation time.
  token_hash text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  created_by uuid references profiles (id) on delete set null,
  max_downloads integer check (max_downloads is null or max_downloads > 0),
  download_count integer not null default 0 check (download_count >= 0),
  created_at timestamptz not null default now(),
  expires_at timestamptz,
  revoked_at timestamptz
);

comment on table shares is
  'Public and unlisted share links, including anonymous ones created at upload time. Expiry is user-controlled and enforced server-side on every resolution.';
comment on column shares.token_hash is
  'Unique, so token lookups are a single index hit. Only hashes are stored: an unguessable token cannot be recovered from a database dump.';

create index shares_file_idx on shares (file_id, created_at desc);
create index shares_active_idx on shares (expires_at)
  where revoked_at is null and expires_at is not null;

-- ---------------------------------------------------------------------------
-- API keys
-- ---------------------------------------------------------------------------

create table api_keys (
  id text primary key check (id ~ '^key_[0-9a-hjkmnp-tv-z]{26}$'),
  owner_id uuid not null references profiles (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 80),
  -- Public prefix shown in the UI and in logs; the secret part is never stored.
  key_prefix text not null unique check (key_prefix ~ '^odk_[0-9a-hjkmnp-tv-z]{8}$'),
  key_hash text not null unique check (key_hash ~ '^[0-9a-f]{64}$'),
  scopes text[] not null default '{}',
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  expires_at timestamptz,
  revoked_at timestamptz,
  constraint api_keys_scopes_known check (
    scopes <@ array['files:read', 'files:write', 'shares:write', 'account:read']::text[]
  )
);

comment on table api_keys is
  'Scoped, revocable API keys. Only the hash is stored; revocation is immediate because authorization reads this row on every request.';
comment on column api_keys.scopes is
  'Explicit capability list. Empty means the key can do nothing, which is the safe default.';

create index api_keys_owner_idx on api_keys (owner_id) where revoked_at is null;

-- ---------------------------------------------------------------------------
-- Audit events
-- ---------------------------------------------------------------------------

create table audit_events (
  id text primary key check (id ~ '^evt_[0-9a-hjkmnp-tv-z]{26}$'),
  occurred_at timestamptz not null default now(),
  actor_kind actor_kind not null,
  actor_user_id uuid references profiles (id) on delete set null,
  -- Salted hash of the client address, never the raw address: audit data must not become a
  -- location trail.
  actor_ip_hash text check (actor_ip_hash is null or actor_ip_hash ~ '^[0-9a-f]{64}$'),
  action text not null check (char_length(action) between 1 and 64),
  subject_type text not null check (subject_type in ('file', 'share', 'upload', 'api_key', 'abuse_report', 'system')),
  subject_id text,
  request_id text,
  metadata jsonb not null default '{}'::jsonb,
  constraint audit_events_actor_consistency check (
    (actor_kind = 'user' or actor_kind = 'admin') or actor_user_id is null
  )
);

comment on table audit_events is
  'Append-only record of security-relevant actions: uploads, downloads, share creation, deletion, key use, administrative actions. Partition by month once volume justifies it (Phase 3).';
comment on column audit_events.actor_ip_hash is
  'HMAC of the client address with a server-side key. Raw addresses are never stored.';

create index audit_events_occurred_idx on audit_events (occurred_at desc);
create index audit_events_subject_idx on audit_events (subject_type, subject_id, occurred_at desc);
create index audit_events_actor_idx on audit_events (actor_user_id, occurred_at desc)
  where actor_user_id is not null;

-- ---------------------------------------------------------------------------
-- Abuse reports and moderation
-- ---------------------------------------------------------------------------

create table abuse_reports (
  id text primary key check (id ~ '^rpt_[0-9a-hjkmnp-tv-z]{26}$'),
  file_id text not null references files (id) on delete cascade,
  reason abuse_reason not null,
  details text check (details is null or char_length(details) <= 4000),
  -- Reporter identity is optional and hashed where possible.
  reporter_user_id uuid references profiles (id) on delete set null,
  reporter_email_hash text check (reporter_email_hash is null or reporter_email_hash ~ '^[0-9a-f]{64}$'),
  reporter_ip_hash text check (reporter_ip_hash is null or reporter_ip_hash ~ '^[0-9a-f]{64}$'),
  state moderation_state not null default 'open',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table abuse_reports is
  'Reported files awaiting triage. Reports are rate limited per IP by the API, and reporter addresses are hashed rather than stored.';

create index abuse_reports_queue_idx on abuse_reports (state, created_at);
create index abuse_reports_file_idx on abuse_reports (file_id);

create table moderation_actions (
  id text primary key check (id ~ '^mod_[0-9a-hjkmnp-tv-z]{26}$'),
  report_id text references abuse_reports (id) on delete set null,
  file_id text not null references files (id) on delete cascade,
  action text not null check (action in ('none', 'quarantine', 'unquarantine', 'disable_shares', 'delete')),
  actor_user_id uuid references profiles (id) on delete set null,
  note text check (note is null or char_length(note) <= 2000),
  created_at timestamptz not null default now()
);

comment on table moderation_actions is
  'Every administrative decision about a file, with who made it and when. Takedowns are reversible decisions recorded here, not silent deletions.';

create index moderation_actions_file_idx on moderation_actions (file_id, created_at desc);

-- ---------------------------------------------------------------------------
-- updated_at maintenance
-- ---------------------------------------------------------------------------

create function set_updated_at() returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

comment on function set_updated_at is
  'Keeps updated_at truthful without relying on application code to remember it.';

create trigger profiles_set_updated_at before update on profiles
  for each row execute function set_updated_at();
create trigger files_set_updated_at before update on files
  for each row execute function set_updated_at();
create trigger storage_objects_set_updated_at before update on storage_objects
  for each row execute function set_updated_at();
create trigger upload_sessions_set_updated_at before update on upload_sessions
  for each row execute function set_updated_at();
create trigger abuse_reports_set_updated_at before update on abuse_reports
  for each row execute function set_updated_at();

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------

alter table profiles enable row level security;
alter table files enable row level security;
alter table storage_objects enable row level security;
alter table upload_sessions enable row level security;
alter table shares enable row level security;
alter table api_keys enable row level security;
alter table audit_events enable row level security;
alter table abuse_reports enable row level security;
alter table moderation_actions enable row level security;

-- Default position: no policy grants access. The API connects with the service role (which
-- bypasses RLS) and performs authorization itself, so a missing or wrong application check is
-- the only way to expose data — not a mis-scoped policy. The policies below are the narrow
-- exception for direct client access to a user's own rows.
--
-- storage_objects, api_keys, audit_events, abuse_reports and moderation_actions deliberately
-- have NO client-facing policies: those rows are server-side only.

create policy profiles_select_own on profiles
  for select to authenticated
  using (id = auth.uid());

create policy profiles_update_own on profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

create policy files_select_own on files
  for select to authenticated
  using (owner_id = auth.uid());

create policy files_delete_own on files
  for delete to authenticated
  using (owner_id = auth.uid());

create policy shares_select_own on shares
  for select to authenticated
  using (created_by = auth.uid() or exists (
    select 1 from files f where f.id = shares.file_id and f.owner_id = auth.uid()
  ));

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

-- The service role is used by the API and the worker; it bypasses RLS by design.
grant usage on schema public to anon, authenticated, service_role;
grant select, insert, update, delete on all tables in schema public to service_role;

-- Authenticated users get only what the policies above allow.
grant select, update on profiles to authenticated;
grant select, delete on files to authenticated;
grant select on shares to authenticated;

-- Anonymous clients get nothing directly: public downloads are served by the API, which
-- applies share-token checks, expiry and counters that a database policy cannot express.
revoke all on all tables in schema public from anon;
