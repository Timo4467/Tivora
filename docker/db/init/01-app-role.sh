#!/bin/sh
# ============================================================
# PostgreSQL Init — Community Edition
# Legt die NOBYPASSRLS-Runtime-Rolle an, mit der die Anwendung
# läuft (echte Row-Level-Security). Migrationen laufen dagegen mit
# der Owner-/Superuser-Rolle (POSTGRES_USER).
#
# Läuft EINMALIG beim ersten Start eines leeren Datenverzeichnisses
# (docker-entrypoint-initdb.d). Passwörter werden vom Installer als
# hex/base64url erzeugt (keine Sonderzeichen → sicher interpolierbar).
# ============================================================
set -e

: "${PG_APP_USER:?PG_APP_USER muss gesetzt sein}"
: "${PG_APP_PASSWORD:?PG_APP_PASSWORD muss gesetzt sein}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  DO \$do\$
  BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${PG_APP_USER}') THEN
      CREATE ROLE "${PG_APP_USER}" LOGIN PASSWORD '${PG_APP_PASSWORD}'
        NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
    END IF;
  END
  \$do\$;

  GRANT CONNECT ON DATABASE "${POSTGRES_DB}" TO "${PG_APP_USER}";
  GRANT USAGE ON SCHEMA public TO "${PG_APP_USER}";

  -- Bestehende Objekte (i.d.R. noch keine — Migrationen laufen später)
  GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "${PG_APP_USER}";
  GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO "${PG_APP_USER}";

  -- Künftige Objekte (von der Owner-Rolle via Migrationen erzeugt) automatisch freigeben
  ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "${PG_APP_USER}";
  ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO "${PG_APP_USER}";
EOSQL

echo "[db-init] Runtime-Rolle '${PG_APP_USER}' (NOBYPASSRLS) bereit."
