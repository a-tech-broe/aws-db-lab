-- IAM database authentication.
--
-- Phase 1 sets iam_database_authentication_enabled on the instance, which
-- makes RDS create the rds_iam role. That alone does nothing: a user must be
-- granted rds_iam before `aws rds generate-db-auth-token` will authenticate.
--
-- This is deliberately NOT granted to the master user. In PostgreSQL a role
-- holding rds_iam authenticates by IAM token *instead of* by password, so
-- granting it to dbadmin would break the Secrets Manager credential path and
-- lock the master account behind IAM.
--
--   psql ... -f sql/001-iam-auth-user.sql

\set ON_ERROR_STOP on

-- No password: this role can only ever authenticate with an IAM token.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_iam') THEN
    CREATE ROLE app_iam WITH LOGIN;
  END IF;
END
$$;

GRANT rds_iam TO app_iam;
GRANT CONNECT ON DATABASE appdb TO app_iam;
GRANT USAGE ON SCHEMA public TO app_iam;

-- Read/write on everything the application will create in Phase 2.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_iam;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO app_iam;

SELECT r.rolname AS member, g.rolname AS granted_role
FROM pg_auth_members m
JOIN pg_roles r ON r.oid = m.member
JOIN pg_roles g ON g.oid = m.roleid
WHERE g.rolname = 'rds_iam';
