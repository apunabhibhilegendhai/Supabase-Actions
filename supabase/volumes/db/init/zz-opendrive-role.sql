-- =============================================================================
-- OpenDrive application role  created once the postgres container has booted
-- and run its init scripts (roles.sql etc.). Run via:
--   docker compose exec -T db psql -U postgres -f opendrive_role.sql (see repo root) and this zz-opendrive-role.sql
-- or paste into ./run.sh psql.
--
-- Dedicated, least-privilege role for the OpenDrive API. It is a normal
-- login role, not a superuser, and is never granted rights to the supabase
-- system schemas. Its password is a GitHub secret injected at deploy time.
-- =============================================================================
DO
$$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'opendrive_app') THEN
    CREATE ROLE opendrive_app WITH LOGIN PASSWORD :'OPENDRIVE_APP_PASSWORD';
  END IF;
END
$$;

GRANT CONNECT ON DATABASE postgres TO opendrive_app;
GRANT CONNECT ON DATABASE _supabase TO opendrive_app;

GRANT USAGE ON SCHEMA public TO opendrive_app;
GRANT CREATE ON SCHEMA public TO opendrive_app;

-- OpenDrive owns its own tables; revoke any accidental rights to supabase
-- system namespaces (idempotent where supported; ignore errors on PG 15+).
-- REVOKE ALL ON SCHEMA supabase_migrations FROM opendrive_app;
