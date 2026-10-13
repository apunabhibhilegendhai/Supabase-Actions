-- OpenDrive Phase 1: identity, ownership, quota and lifecycle.
--
-- Builds on 20261010000001_initial_schema.sql. That migration is NOT edited: this file evolves it.
-- Additive and evolving statements only — no data is destroyed, and no column is dropped.
--
-- What this migration establishes:
--   * Ownership is a PRINCIPAL: a file or folder belongs to exactly one registered user OR one
--     anonymous session, enforced by `num_nonnulls(...) = 1`. A generated `owner_key` column gives
--     both kinds a single comparable identity, which lets composite foreign keys enforce
--     same-owner parents and folders — something a nullable uuid column alone cannot do.
--   * Anonymous sessions are first-class rows with a hashed credential, never fake auth users.
--   * Folders are a tree with the parent/child ownership invariant and cycle prevention in SQL,
--     so a cross-owner or circular parent is rejected by the database, not only by the API.
--   * File lifecycle states gain `uploaded` and `deleting`, and `ready` replaces `available`.
--   * Quota is enforced by SQL functions that lock the limit row, so concurrent uploads cannot
--     both pass a check-then-act race; reservations are released or committed explicitly.
--
-- Transaction note: `alter type ... add value` cannot be *used* in the same transaction that adds
-- it (PostgreSQL >= 12). Nothing in this file uses the newly added `uploaded`/`deleting`/`expired`
-- values; renamed values are safe because they keep their OIDs. Do not add a statement here that
-- references a value added by an `add value` above it: `supabase db push` runs the file in a
-- transaction, and such a statement would fail there but pass under plain psql, which does not.
--
-- Verification status: execution-verified by supabase/tests/run-local.sh (see docs/DEVELOPMENT.md).
-- Never applied to a real Supabase instance.

-- ---------------------------------------------------------------------------
-- Enumerations
-- ---------------------------------------------------------------------------

-- Distinguishes the two kinds of owner a resource can have.
create type principal_kind as enum ('user', 'anonymous');

create type account_status as enum ('active', 'suspended', 'closed');

create type session_status as enum ('active', 'revoked');

create type share_status as enum ('active', 'revoked', 'expired');

create type quota_period as enum ('day', 'month', 'lifetime');

create type reservation_state as enum ('held', 'committed', 'released', 'expired');

-- Lifecycle: pending_upload -> uploading -> uploaded -> scanning -> ready, with failure and
-- deletion paths. `available` becomes `ready`, and two states are added. Renaming keeps the OIDs,
-- so existing defaults, check constraints and the partial index predicate follow automatically.
alter type file_status rename value 'pending' to 'pending_upload';
alter type file_status rename value 'available' to 'ready';
alter type file_status add value if not exists 'uploaded' before 'scanning';
alter type file_status add value if not exists 'deleting' after 'failed';

comment on type file_status is
  'File lifecycle. Only `ready` (and, when scanning is disabled, `uploaded`) may be served; see packages/shared/src/domain/file-states.ts for the authoritative transition table, which the application enforces.';

-- ---------------------------------------------------------------------------
-- Profiles: account status and the per-user effective limits
-- ---------------------------------------------------------------------------

alter table profiles add column status account_status not null default 'active';

-- Effective per-user file-count ceiling. Quota byte limits already exist on this table; a
-- per-user value overrides the `quota_limits` policy row of the same name.
alter table profiles add column max_files integer not null default 100000 check (max_files > 0);

comment on column profiles.status is
  'Account state. `suspended` and `closed` accounts must be refused by the authorization layer; the value is never trusted from a client.';

-- ---------------------------------------------------------------------------
-- Anonymous sessions
-- ---------------------------------------------------------------------------

create table anonymous_sessions (
  id text primary key check (id ~ '^sess_[0-9a-hjkmnp-tv-z]{26}$'),
  -- SHA-256 of the session credential. The credential itself is returned once, at creation.
  credential_hash text not null unique check (credential_hash ~ '^[0-9a-f]{64}$'),
  status session_status not null default 'active',
  -- HMAC of the creating address with a server-side key; never the address itself, and never a
  -- device fingerprint. This is the minimum needed to triage abuse of anonymous uploads.
  created_ip_hash text check (created_ip_hash is null or created_ip_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  last_used_at timestamptz,
  revoked_at timestamptz,
  constraint anonymous_sessions_revoked_consistency check ((status = 'revoked') = (revoked_at is not null)),
  constraint anonymous_sessions_expires_after_creation check (expires_at > created_at)
);

comment on table anonymous_sessions is
  'Anonymous upload identity. A session is a row here, never a synthetic Supabase auth user. Expiry is evaluated as `now() > expires_at` on every use: an expired session cannot regain access because status alone is never sufficient. Sessions are revoked, not deleted, so their files stay attributable.';

comment on column anonymous_sessions.credential_hash is
  'SHA-256 of the `ods_` credential. Lookup is by this hash; the plaintext exists only in the creation response.';

create index anonymous_sessions_expiry_idx on anonymous_sessions (expires_at) where status = 'active';

-- ---------------------------------------------------------------------------
-- Folders
-- ---------------------------------------------------------------------------

create table folders (
  id text primary key check (id ~ '^fold_[0-9a-hjkmnp-tv-z]{26}$'),
  -- ON DELETE RESTRICT, not SET NULL or CASCADE: deleting a principal must not silently orphan
  -- (or silently destroy) a folder tree. Deleting an account is an application workflow that
  -- removes or re-homes the user's resources first.
  owner_user_id uuid references profiles (id) on delete restrict,
  owner_session_id text references anonymous_sessions (id) on delete restrict,
  -- One comparable identity for both owner kinds, so composite foreign keys can enforce that a
  -- parent folder has the same owner. Nullable columns cannot do this: a composite key with a NULL
  -- component is not checked at all under MATCH SIMPLE.
  owner_key text generated always as (coalesce(owner_user_id::text, owner_session_id)) stored,
  parent_id text,
  name text not null check (char_length(name) between 1 and 255),
  -- Maintained by the guard trigger: 0 for a root folder, otherwise parent depth + 1.
  depth integer not null default 0 check (depth between 0 and 32),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  constraint folders_one_owner check (num_nonnulls(owner_user_id, owner_session_id) = 1),
  constraint folders_no_self_parent check (parent_id is null or parent_id <> id),
  -- Referenced by the composite foreign keys below; PostgreSQL requires a unique constraint on
  -- exactly the referenced column list.
  constraint folders_id_owner_unique unique (id, owner_key),
  constraint folders_parent_same_owner foreign key (parent_id, owner_key)
    references folders (id, owner_key) on delete restrict
);

comment on table folders is
  'Folder tree. A root folder is represented by a NULL parent_id, so there is exactly one root level per owner and no synthetic root row to keep consistent. Same-owner parenting is enforced by the folders_parent_same_owner composite foreign key; cycles are refused by the guard trigger.';
comment on column folders.depth is
  'Cached depth, recomputed from the parent on every write. Bounded at 32 so the cycle-detection walk and any recursive query are both finite.';
comment on column folders.deleted_at is
  'Soft deletion. A folder may only be soft-deleted once it has no live children and no live files (application rule, exercised by the repository tests); hard deletion is not exposed.';

create index folders_owner_parent_idx on folders (owner_user_id, parent_id) where deleted_at is null;
create index folders_session_parent_idx on folders (owner_session_id, parent_id) where deleted_at is null;
-- Sibling names are unique per parent. `coalesce(parent_id, '')` is required because a unique index
-- treats NULLs as distinct, which would let root folders share a name.
create unique index folders_sibling_name_unique
  on folders (owner_key, coalesce(parent_id, ''), lower(name))
  where deleted_at is null;

-- Parent ownership and depth, with cycle detection. The composite foreign key already guarantees
-- that a parent exists and belongs to the same owner; this trigger adds the two things a foreign
-- key cannot express: that the parent chain never returns to the row itself, and a bounded depth.
create function folders_guard_hierarchy() returns trigger
language plpgsql
as $$
declare
  v_ancestor text := new.parent_id;
  v_parent_depth integer;
  v_hops integer := 0;
begin
  if new.parent_id is null then
    new.depth := 0;
    return new;
  end if;

  select depth into v_parent_depth from folders where id = new.parent_id;
  if not found then
    raise exception 'parent folder % does not exist', new.parent_id using errcode = '23503';
  end if;

  while v_ancestor is not null loop
    v_hops := v_hops + 1;
    if v_hops > 32 then
      raise exception 'folder hierarchy is deeper than the 32 level limit'
        using errcode = '23514', constraint = 'folders_max_depth';
    end if;
    if v_ancestor = new.id then
      raise exception 'folder % cannot be its own ancestor', new.id
        using errcode = '23514', constraint = 'folders_no_cycles';
    end if;
    select parent_id into v_ancestor from folders where id = v_ancestor;
  end loop;

  new.depth := v_parent_depth + 1;
  return new;
end;
$$;

comment on function folders_guard_hierarchy is
  'Refuses a folder move that would create a cycle and keeps `depth` consistent with the parent chain. Both refusals set a constraint name (folders_no_cycles, folders_max_depth) so the API can map them to a conflict instead of a generic check violation.';

create trigger folders_guard_hierarchy before insert or update of parent_id on folders
  for each row execute function folders_guard_hierarchy();

-- The guard above keeps the *moved* folder's depth correct. Its descendants would be left with a
-- stale depth unless someone recomputes them, and "someone" would then have to be every caller.
-- This trigger walks the subtree after a re-parent and fixes every descendant, so `depth` is
-- correct no matter who writes: the repository, a migration, or an operator at a psql prompt.
--
-- It intentionally ignores a NULL row (return value is unused by AFTER triggers) and does nothing
-- when the parent is unchanged, so ordinary updates do not pay for a subtree walk.
create function folders_repair_subtree_depths() returns trigger
language plpgsql
as $$
begin
  if new.parent_id is not distinct from old.parent_id then
    return null;
  end if;

  with recursive subtree as (
    select f.id, new.depth as depth from folders f where f.id = new.id
    union all
    select c.id, s.depth + 1
      from folders c
      join subtree s on c.parent_id = s.id
  )
  update folders f
     set depth = s.depth
    from subtree s
   where f.id = s.id and f.id <> new.id and f.depth <> s.depth;

  return null;
end;
$$;

comment on function folders_repair_subtree_depths is
  'Keeps cached depths truthful for a whole subtree after a folder is re-parented; the walk terminates because cycles are already refused by folders_guard_hierarchy.';

create trigger folders_repair_subtree_depths after update of parent_id on folders
  for each row execute function folders_repair_subtree_depths();

create trigger folders_set_updated_at before update on folders
  for each row execute function set_updated_at();

-- ---------------------------------------------------------------------------
-- Files: principal ownership, folder placement, scan timestamp
-- ---------------------------------------------------------------------------

-- `owner_id` said "user", which is only half the model. The rename is atomic and leaves the
-- existing RLS policies, indexes and the foreign key pointing at the same column.
alter table files rename column owner_id to owner_user_id;

alter table files add column owner_session_id text references anonymous_sessions (id) on delete restrict;
alter table files add column owner_key text generated always as (coalesce(owner_user_id::text, owner_session_id)) stored;
alter table files add column folder_id text;
alter table files add column scanned_at timestamptz;

-- Exactly one principal: never both, never neither. An anonymous upload without a session is
-- exactly the unattributable row that abuse handling cannot act on.
alter table files add constraint files_one_owner
  check (num_nonnulls(owner_user_id, owner_session_id) = 1);

-- A file may only sit in a folder its own owner owns.
alter table files add constraint files_folder_same_owner foreign key (folder_id, owner_key)
  references folders (id, owner_key) on delete restrict;

-- Ownership loss must be an explicit workflow, not a side effect of deleting a profile.
alter table files drop constraint files_owner_id_fkey;
alter table files add constraint files_owner_user_id_fkey foreign key (owner_user_id)
  references profiles (id) on delete restrict;

-- A servable file cannot simultaneously be deleted or infected. This is the database half of
-- "never allow a pending, failed, quarantined or deleted file to become downloadable".
alter table files add constraint files_ready_is_servable check (
  status <> 'ready' or (deleted_at is null and scan_state is distinct from 'infected')
);

-- `provider_id`/`provider_ref` live in storage_objects rather than here: a file may move between
-- providers, and exactly one row per file may be `active` (enforced by a partial unique index).
-- Nothing in the schema treats a provider identifier — a Telegram message id, for example — as an
-- identifier: provider ids are repeated freely across rows and never appear in an API response.

create index files_owner_session_created_idx
  on files (owner_session_id, created_at desc)
  where deleted_at is null and owner_session_id is not null;
create index files_folder_created_idx on files (folder_id, created_at desc) where deleted_at is null;

comment on column files.owner_key is
  'Principal identity used by the quota functions and by composite ownership foreign keys.';
comment on column files.folder_id is
  'Optional parent folder. A file at the root has NULL, which is also what makes the composite ownership check skippable for root files — and only for root files.';

-- ---------------------------------------------------------------------------
-- Shares: explicit status
-- ---------------------------------------------------------------------------

alter table shares add column status share_status not null default 'active';

alter table shares add constraint shares_revoked_consistency
  check ((status = 'revoked') = (revoked_at is not null));

comment on column shares.status is
  '`revoked` and `expired` are both terminal for resolution. Revocation is recorded in revoked_at as well, and resolution must check status, revoked_at and expires_at together: a revocation that only edited one of them would be a silent authorization bug.';

-- ---------------------------------------------------------------------------
-- Quota policy, usage counters and reservations
-- ---------------------------------------------------------------------------

-- Policy defaults per principal kind. Deliberately a table rather than constants in code: the
-- limits are part of the data model, are auditable, and can be changed without a deploy.
create table quota_limits (
  principal_kind principal_kind primary key,
  storage_bytes bigint not null check (storage_bytes > 0),
  max_file_size_bytes bigint not null check (max_file_size_bytes > 0 and max_file_size_bytes <= 2147483648),
  max_files integer not null check (max_files > 0),
  upload_bytes_per_day bigint check (upload_bytes_per_day is null or upload_bytes_per_day > 0),
  download_bytes_per_day bigint check (download_bytes_per_day is null or download_bytes_per_day > 0),
  -- Retention: uploaded files expire this many hours after creation. NULL means keep indefinitely.
  file_expires_after_hours integer check (file_expires_after_hours is null or file_expires_after_hours > 0),
  updated_at timestamptz not null default now()
);

comment on table quota_limits is
  'Default limits per principal kind. A registered user''s effective limits come from profiles (which are seeded from the `user` row here); an anonymous session always uses the `anonymous` row. No floating point: every size is an integer count of bytes.';

insert into quota_limits
  (principal_kind, storage_bytes, max_file_size_bytes, max_files, upload_bytes_per_day, download_bytes_per_day, file_expires_after_hours)
values
  ('user', 5368709120, 2147483648, 100000, null, null, null),
  ('anonymous', 268435456, 2147483648, 200, 1073741824, 2147483648, 168);

-- Aggregated usage, per principal and period. Advisory for reporting, and the source for the
-- daily bandwidth checks; the authoritative "bytes currently stored" figure is derived from the
-- files table at reservation time (a counter can drift, a sum of live rows cannot).
create table usage_counters (
  owner_user_id uuid references profiles (id) on delete restrict,
  owner_session_id text references anonymous_sessions (id) on delete restrict,
  owner_key text generated always as (coalesce(owner_user_id::text, owner_session_id)) stored,
  period quota_period not null,
  -- Start of the period. `lifetime` rows use the epoch, which keeps the natural key total.
  period_start timestamptz not null,
  storage_bytes bigint not null default 0 check (storage_bytes >= 0),
  file_count integer not null default 0 check (file_count >= 0),
  upload_bytes bigint not null default 0 check (upload_bytes >= 0),
  download_bytes bigint not null default 0 check (download_bytes >= 0),
  updated_at timestamptz not null default now(),
  constraint usage_counters_one_owner check (num_nonnulls(owner_user_id, owner_session_id) = 1),
  constraint usage_counters_unique_period unique (owner_key, period, period_start)
);

comment on table usage_counters is
  'Per-principal usage aggregates. Integer byte counts only. Kept as a counter table because the alternative — summing every file row on every request — degrades as an account grows.';

-- One in-flight upload's worth of reserved quota. This is what makes concurrent uploads safe:
-- the check and the reservation happen under a lock on the limit row, and the reservation is
-- visible to the next check before any bytes arrive.
create table quota_reservations (
  id text primary key check (id ~ '^resv_[0-9a-hjkmnp-tv-z]{26}$'),
  file_id text not null references files (id) on delete cascade,
  owner_user_id uuid references profiles (id) on delete restrict,
  owner_session_id text references anonymous_sessions (id) on delete restrict,
  owner_key text generated always as (coalesce(owner_user_id::text, owner_session_id)) stored,
  requested_bytes bigint not null check (requested_bytes > 0),
  state reservation_state not null default 'held',
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '1 hour',
  released_at timestamptz,
  committed_at timestamptz,
  constraint quota_reservations_one_owner check (num_nonnulls(owner_user_id, owner_session_id) = 1),
  constraint quota_reservations_expires_after_creation check (expires_at > created_at),
  constraint quota_reservations_state_timestamps check (
    (state = 'committed') = (committed_at is not null)
    and (state in ('released', 'expired')) = (released_at is not null)
    and (state <> 'held' or (released_at is null and committed_at is null))
  )
);

comment on table quota_reservations is
  'Quota held for an in-flight upload. A reservation that is neither committed nor released expires and is swept, so a crashed upload cannot wedge an account''s quota forever.';

-- At most one outstanding hold per file: a retried request must reuse or release, not double-book.
create unique index quota_reservations_one_held_per_file
  on quota_reservations (file_id) where state = 'held';
create index quota_reservations_expiry_idx on quota_reservations (expires_at) where state = 'held';
create index quota_reservations_owner_idx on quota_reservations (owner_key, state);

create trigger quota_limits_set_updated_at before update on quota_limits
  for each row execute function set_updated_at();
create trigger usage_counters_set_updated_at before update on usage_counters
  for each row execute function set_updated_at();

-- ---------------------------------------------------------------------------
-- Quota enforcement functions
-- ---------------------------------------------------------------------------
-- These functions are the single authoritative implementation of "may this upload proceed?".
-- They are SECURITY INVOKER (the default) and EXECUTE is revoked from PUBLIC below: only the
-- service role may call them.

-- Sums the principal's live bytes: durably stored files plus unexpired held reservations.
--
-- Only states that imply durable bytes count as "stored": `uploaded` and later, minus the deleted
-- and failed paths. A `pending_upload` row holds no bytes, and an `uploading` row's partial bytes
-- are already covered by its hold — counting either as stored would let an abandoned metadata row
-- consume an account's quota forever and would double-count a live upload.
--
-- `p_exclude_file_id` lets the caller omit the very file being reserved. The file row is created
-- before the reservation (so the upload has somewhere to record progress), which means its
-- declared size would otherwise already be in the sum.
create function opendrive_used_storage(
  p_owner_user_id uuid,
  p_owner_session_id text,
  p_exclude_file_id text default null
) returns bigint
language sql
stable
as $$
  with principal as (
    select coalesce(p_owner_user_id::text, p_owner_session_id) as owner_key
  ),
  stored as (
    select coalesce(sum(f.size_bytes), 0)::bigint as bytes
    from files f, principal p
    where f.owner_key = p.owner_key
      and f.deleted_at is null
      and f.status not in ('pending_upload', 'uploading', 'failed', 'deleted')
      and (p_exclude_file_id is null or f.id <> p_exclude_file_id)
  ),
  held as (
    select coalesce(sum(r.requested_bytes), 0)::bigint as bytes
    from quota_reservations r, principal p
    where r.owner_key = p.owner_key
      and r.state = 'held'
      and r.expires_at > now()
      and (p_exclude_file_id is null or r.file_id <> p_exclude_file_id)
  )
  select stored.bytes + held.bytes from stored, held;
$$;

comment on function opendrive_used_storage is
  'Live bytes for a principal: files that still exist plus unexpired holds. Expired holds are ignored, so a crashed upload stops consuming quota on its own.';

-- Marks this principal's stale holds as expired. Called at the start of a reservation so an
-- abandoned upload cannot block the account until a scheduled sweep runs.
create function opendrive_expire_stale_reservations(
  p_owner_user_id uuid,
  p_owner_session_id text
) returns integer
language plpgsql
as $$
declare
  v_owner_key text := coalesce(p_owner_user_id::text, p_owner_session_id);
  v_count integer;
begin
  if v_owner_key is null then
    return 0;
  end if;
  with expired as (
    update quota_reservations
       set state = 'expired', released_at = now()
     where owner_key = v_owner_key
       and state = 'held'
       and expires_at <= now()
    returning 1
  )
  select count(*) into v_count from expired;
  return v_count;
end;
$$;

-- Reserves quota for one upload. Returns a jsonb result rather than raising, so the API can map
-- a refusal onto the right HTTP status and still show the caller the limit it hit.
create function opendrive_reserve_storage(
  p_id text,
  p_owner_user_id uuid,
  p_owner_session_id text,
  p_file_id text,
  p_bytes bigint,
  p_ttl interval default interval '1 hour'
) returns jsonb
language plpgsql
as $$
declare
  v_owner_key text;
  v_limit bigint;
  v_max_file bigint;
  v_max_files integer;
  v_status account_status;
  v_session_status session_status;
  v_session_expires timestamptz;
  v_used bigint;
  v_file_size bigint;
  v_file_owner text;
  v_file_status file_status;
  v_file_deleted timestamptz;
  v_file_count integer;
  v_daily_limit bigint;
  v_daily_used bigint;
  v_held_today bigint;
begin
  if num_nonnulls(p_owner_user_id, p_owner_session_id) <> 1 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_principal',
      'message', 'Exactly one of a user id or an anonymous session id is required.');
  end if;
  v_owner_key := coalesce(p_owner_user_id::text, p_owner_session_id);

  -- Lock the principal's own row. This is what makes check-then-act atomic: a second concurrent
  -- upload by the same principal blocks here until the first has inserted its reservation, while
  -- two different principals never block each other. Registered users lock their profile row and
  -- anonymous sessions lock their session row, so the lock is always one row wide.
  if p_owner_user_id is not null then
    select storage_quota_bytes, max_file_size_bytes, max_files, status
      into v_limit, v_max_file, v_max_files, v_status
      from profiles where id = p_owner_user_id for update;
    if not found then
      return jsonb_build_object('ok', false, 'reason', 'owner_unknown',
        'message', 'No profile exists for this user.');
    end if;
    if v_status <> 'active' then
      return jsonb_build_object('ok', false, 'reason', 'owner_not_active',
        'message', 'This account is not active.');
    end if;
  else
    -- An expired or revoked session must not be able to start new work. Enforcing that here, in the
    -- one place every upload goes through, means the rule holds even if a caller forgets to check.
    select s.status, s.expires_at into v_session_status, v_session_expires
      from anonymous_sessions s where s.id = p_owner_session_id for update;
    if not found then
      return jsonb_build_object('ok', false, 'reason', 'owner_unknown',
        'message', 'No anonymous session exists with this id.');
    end if;
    if v_session_status <> 'active' then
      return jsonb_build_object('ok', false, 'reason', 'session_revoked',
        'message', 'This anonymous session has been revoked.');
    end if;
    if v_session_expires <= now() then
      return jsonb_build_object('ok', false, 'reason', 'session_expired',
        'message', 'This anonymous session has expired.');
    end if;

    -- Policy rows are reference data, read without a lock: locking them would serialize every
    -- anonymous upload in the system behind one row for no benefit.
    select l.storage_bytes, l.max_file_size_bytes, l.max_files
      into v_limit, v_max_file, v_max_files
      from quota_limits l where l.principal_kind = 'anonymous';
    if not found then
      return jsonb_build_object('ok', false, 'reason', 'policy_missing',
        'message', 'No quota policy is configured for anonymous uploads.');
    end if;
  end if;

  -- Stale holds are cleared before anything else looks at reservations, so a retried upload for a
  -- file whose earlier attempt died is not told "already_reserved" by its own corpse.
  perform opendrive_expire_stale_reservations(p_owner_user_id, p_owner_session_id);

  -- The file row must exist and agree with the request. `p_bytes` is never trusted on its own:
  -- it is compared against the persisted size of the file it claims to be for, so a caller cannot
  -- under-declare to slip past the quota.
  select owner_key, size_bytes, status, deleted_at
    into v_file_owner, v_file_size, v_file_status, v_file_deleted
    from files where id = p_file_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'file_not_found',
      'message', 'No metadata row exists for this file.');
  end if;
  if v_file_owner is distinct from v_owner_key then
    return jsonb_build_object('ok', false, 'reason', 'owner_mismatch',
      'message', 'This file belongs to a different owner.');
  end if;
  if v_file_deleted is not null or v_file_status = 'deleted' then
    return jsonb_build_object('ok', false, 'reason', 'file_deleted',
      'message', 'A deleted file cannot reserve quota.');
  end if;
  if v_file_size <> p_bytes then
    return jsonb_build_object('ok', false, 'reason', 'size_mismatch',
      'message', 'The requested size does not match the recorded size of this file.');
  end if;

  if exists (select 1 from quota_reservations where file_id = p_file_id and state = 'held' and expires_at > now()) then
    return jsonb_build_object('ok', false, 'reason', 'already_reserved',
      'message', 'This file already holds a live quota reservation.');
  end if;

  if p_bytes > v_max_file then
    return jsonb_build_object('ok', false, 'reason', 'file_too_large',
      'message', format('A single file may be at most %s bytes.', v_max_file),
      'maxFileSizeBytes', v_max_file);
  end if;

  select count(*) into v_file_count
    from files
   where owner_key = v_owner_key and id <> p_file_id
     and deleted_at is null and status <> 'deleted';
  if v_file_count + 1 > v_max_files then
    return jsonb_build_object('ok', false, 'reason', 'file_count_exceeded',
      'message', format('This account may hold at most %s files.', v_max_files),
      'maxFiles', v_max_files, 'fileCount', v_file_count);
  end if;

  v_used := opendrive_used_storage(p_owner_user_id, p_owner_session_id, p_file_id);
  if v_used + p_bytes > v_limit then
    return jsonb_build_object('ok', false, 'reason', 'storage_quota_exceeded',
      'message', format('This upload would exceed the %s byte storage quota.', v_limit),
      'storageLimitBytes', v_limit, 'storageUsedBytes', v_used,
      'storageRemainingBytes', greatest(v_limit - v_used, 0));
  end if;

  -- Daily upload bandwidth, from the policy the principal kind uses.
  select l.upload_bytes_per_day into v_daily_limit
    from quota_limits l
   where l.principal_kind = case when p_owner_user_id is not null then 'user'::principal_kind else 'anonymous'::principal_kind end;
  if v_daily_limit is not null then
    select u.upload_bytes into v_daily_used
      from usage_counters u
     where u.owner_key = v_owner_key and u.period = 'day'
       and u.period_start = date_trunc('day', now());
    -- Count today's outstanding holds too, otherwise parallel uploads could each pass the daily
    -- check before any of them commits and increments the counter.
    select coalesce(sum(r.requested_bytes), 0) into v_held_today
      from quota_reservations r
     where r.owner_key = v_owner_key and r.state = 'held' and r.expires_at > now()
       and r.created_at >= date_trunc('day', now());
    v_daily_used := coalesce(v_daily_used, 0) + coalesce(v_held_today, 0);
    if v_daily_used + p_bytes > v_daily_limit then
      return jsonb_build_object('ok', false, 'reason', 'upload_bandwidth_exceeded',
        'message', format('This upload would exceed the %s byte daily upload allowance.', v_daily_limit),
        'uploadBytesPerDay', v_daily_limit, 'uploadBytesUsedToday', v_daily_used);
    end if;
  end if;

  insert into quota_reservations
    (id, file_id, owner_user_id, owner_session_id, requested_bytes, state, expires_at)
  values
    (p_id, p_file_id, p_owner_user_id, p_owner_session_id, p_bytes, 'held', now() + p_ttl);

  return jsonb_build_object(
    'ok', true,
    'reservationId', p_id,
    'storageLimitBytes', v_limit,
    'storageUsedBytes', v_used + p_bytes,
    'storageRemainingBytes', v_limit - v_used - p_bytes,
    'expiresAt', (now() + p_ttl)
  );
end;
$$;

comment on function opendrive_reserve_storage is
  'Atomically reserves storage for one upload. Returns {ok:false, reason} for a refusal instead of raising, so callers can map refusals to 413/429 without parsing messages.';

-- Commits a hold once bytes are durable. Idempotent: committing twice does not double-count.
create function opendrive_commit_reservation(p_id text) returns jsonb
language plpgsql
as $$
declare
  v_reservation quota_reservations;
  v_day_start timestamptz := date_trunc('day', now());
  v_epoch timestamptz := '1970-01-01 00:00:00+00'::timestamptz;
begin
  select * into v_reservation from quota_reservations where id = p_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'reservation_not_found');
  end if;
  if v_reservation.state = 'committed' then
    return jsonb_build_object('ok', true, 'alreadyCommitted', true, 'fileId', v_reservation.file_id);
  end if;
  if v_reservation.state <> 'held' then
    return jsonb_build_object('ok', false, 'reason', 'reservation_not_held', 'state', v_reservation.state::text);
  end if;
  if v_reservation.expires_at <= now() then
    -- Invalidate first so a late commit cannot pass on the next attempt.
    update quota_reservations set state = 'expired', released_at = now() where id = p_id;
    return jsonb_build_object('ok', false, 'reason', 'reservation_expired');
  end if;

  update quota_reservations set state = 'committed', committed_at = now() where id = p_id;

  insert into usage_counters (owner_user_id, owner_session_id, period, period_start,
                              storage_bytes, file_count, upload_bytes, download_bytes)
  values (v_reservation.owner_user_id, v_reservation.owner_session_id, 'lifetime', v_epoch,
          v_reservation.requested_bytes, 1, 0, 0),
         (v_reservation.owner_user_id, v_reservation.owner_session_id, 'day', v_day_start,
          0, 0, v_reservation.requested_bytes, 0)
  on conflict (owner_key, period, period_start) do update
     set storage_bytes = usage_counters.storage_bytes + excluded.storage_bytes,
         file_count = usage_counters.file_count + excluded.file_count,
         upload_bytes = usage_counters.upload_bytes + excluded.upload_bytes,
         download_bytes = usage_counters.download_bytes + excluded.download_bytes,
         updated_at = now();

  return jsonb_build_object('ok', true, 'alreadyCommitted', false, 'fileId', v_reservation.file_id,
    'committedBytes', v_reservation.requested_bytes);
end;
$$;

comment on function opendrive_commit_reservation is
  'Commits a hold and updates usage counters. Idempotent by construction: only the held -> committed transition writes counters.';

create function opendrive_release_reservation(p_id text) returns jsonb
language plpgsql
as $$
declare
  v_reservation quota_reservations;
begin
  select * into v_reservation from quota_reservations where id = p_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'reservation_not_found');
  end if;
  if v_reservation.state in ('released', 'expired') then
    return jsonb_build_object('ok', true, 'alreadyReleased', true);
  end if;
  if v_reservation.state = 'committed' then
    return jsonb_build_object('ok', false, 'reason', 'already_committed');
  end if;
  update quota_reservations set state = 'released', released_at = now() where id = p_id;
  return jsonb_build_object('ok', true, 'alreadyReleased', false, 'releasedBytes', v_reservation.requested_bytes);
end;
$$;

comment on function opendrive_release_reservation is
  'Releases a hold after a failed or cancelled upload. Idempotent, so a retried failure path is safe.';

-- Sweeps every principal's expired holds. The worker calls this on a schedule.
create function opendrive_sweep_expired_reservations() returns integer
language plpgsql
as $$
declare
  v_count integer;
begin
  with expired as (
    update quota_reservations
       set state = 'expired', released_at = now()
     where state = 'held' and expires_at <= now()
    returning 1
  )
  select count(*) into v_count from expired;
  return v_count;
end;
$$;

-- One call for the API's quota summary: limits, live usage and today's uploads.
create function opendrive_quota_summary(
  p_owner_user_id uuid,
  p_owner_session_id text
) returns jsonb
language plpgsql
stable
as $$
declare
  v_owner_key text := coalesce(p_owner_user_id::text, p_owner_session_id);
  v_kind principal_kind := case when p_owner_user_id is not null then 'user'::principal_kind else 'anonymous'::principal_kind end;
  v_limit bigint;
  v_max_file bigint;
  v_max_files integer;
  v_daily_upload_limit bigint;
  v_daily_download_limit bigint;
  v_expires_after integer;
  v_used bigint;
  v_file_count integer;
  v_upload_today bigint;
  v_download_today bigint;
  v_status account_status;
begin
  if v_owner_key is null then
    return jsonb_build_object('ok', false, 'reason', 'invalid_principal');
  end if;

  select l.storage_bytes, l.max_file_size_bytes, l.max_files,
         l.upload_bytes_per_day, l.download_bytes_per_day, l.file_expires_after_hours
    into v_limit, v_max_file, v_max_files, v_daily_upload_limit, v_daily_download_limit, v_expires_after
    from quota_limits l where l.principal_kind = v_kind;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'policy_missing');
  end if;

  -- Only a registered user has per-row overrides. Running this select for an anonymous principal
  -- would find nothing and, crucially, would overwrite the policy values above with NULL.
  if p_owner_user_id is not null then
    select p.status, p.storage_quota_bytes, p.max_file_size_bytes, p.max_files
      into v_status, v_limit, v_max_file, v_max_files
      from profiles p where p.id = p_owner_user_id;
    if not found then
      return jsonb_build_object('ok', false, 'reason', 'owner_unknown');
    end if;
  else
    v_status := 'active';
  end if;

  v_used := opendrive_used_storage(p_owner_user_id, p_owner_session_id);
  select count(*) into v_file_count
    from files where owner_key = v_owner_key and deleted_at is null and status <> 'deleted';
  select coalesce(u.upload_bytes, 0), coalesce(u.download_bytes, 0)
    into v_upload_today, v_download_today
    from usage_counters u
   where u.owner_key = v_owner_key and u.period = 'day' and u.period_start = date_trunc('day', now());

  return jsonb_build_object(
    'ok', true,
    'principalKind', v_kind::text,
    'accountStatus', coalesce(v_status::text, 'active'),
    'storageLimitBytes', v_limit,
    'storageUsedBytes', v_used,
    'storageRemainingBytes', greatest(v_limit - v_used, 0),
    'fileCount', v_file_count,
    'maxFiles', v_max_files,
    'maxFileSizeBytes', v_max_file,
    'uploadBytesPerDay', v_daily_upload_limit,
    'uploadBytesUsedToday', coalesce(v_upload_today, 0),
    'downloadBytesPerDay', v_daily_download_limit,
    'downloadBytesUsedToday', coalesce(v_download_today, 0),
    'fileExpiresAfterHours', v_expires_after,
    'heldReservationBytes', coalesce((
      select sum(r.requested_bytes) from quota_reservations r
       where r.owner_key = v_owner_key and r.state = 'held' and r.expires_at > now()), 0)
  );
end;
$$;

comment on function opendrive_quota_summary is
  'Limits plus live usage for one principal, in a single round trip. Reads the profile overrides for a user and the policy row for an anonymous session.';

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table anonymous_sessions enable row level security;
alter table folders enable row level security;
alter table quota_limits enable row level security;
alter table usage_counters enable row level security;
alter table quota_reservations enable row level security;

-- Same posture as the initial schema: no policy means no client access at all.
--   anonymous_sessions, quota_limits, usage_counters, quota_reservations: server-side only.
-- Anonymous sessions have NO client policy on purpose: the session credential is presented to the
-- API, which resolves it with the service role. A client that could read this table could enumerate
-- sessions, and a client that could write it could revive a revoked one.
create policy folders_select_own on folders
  for select to authenticated
  using (owner_user_id = auth.uid());

create policy folders_delete_own on folders
  for delete to authenticated
  using (owner_user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

-- The service role is the API and the worker: it needs full DML on every new table, including
-- folders. Omitting folders here would leave the API unable to create a folder at all.
grant select, insert, update, delete on anonymous_sessions, folders, quota_limits, usage_counters,
  quota_reservations to service_role;

-- Authenticated users get own-row reads and deletes only; creation and re-parenting go through the
-- API, which validates names, depth and ownership before writing. Nothing is granted to anon.
grant select, delete on folders to authenticated;

-- EXECUTE on a function is granted to PUBLIC by default, which would make every quota function
-- callable by `anon` and `authenticated` through PostgREST. Revoke, then grant deliberately.
revoke all on function opendrive_used_storage(uuid, text, text) from public;
revoke all on function opendrive_expire_stale_reservations(uuid, text) from public;
revoke all on function opendrive_reserve_storage(text, uuid, text, text, bigint, interval) from public;
revoke all on function opendrive_commit_reservation(text) from public;
revoke all on function opendrive_release_reservation(text) from public;
revoke all on function opendrive_sweep_expired_reservations() from public;
revoke all on function opendrive_quota_summary(uuid, text) from public;

grant execute on function opendrive_used_storage(uuid, text, text) to service_role;
grant execute on function opendrive_expire_stale_reservations(uuid, text) to service_role;
grant execute on function opendrive_reserve_storage(text, uuid, text, text, bigint, interval) to service_role;
grant execute on function opendrive_commit_reservation(text) to service_role;
grant execute on function opendrive_release_reservation(text) to service_role;
grant execute on function opendrive_sweep_expired_reservations() to service_role;
grant execute on function opendrive_quota_summary(uuid, text) to service_role;
