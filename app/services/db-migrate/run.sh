#!/bin/sh
# Applies the ordered schema/seed SQL to RDS. Idempotent: if the schema is
# already present (users table exists) it exits cleanly, so re-runs are safe.
# Connection comes from PG* env vars (PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE).
set -e

echo "[db-migrate] connecting to ${PGHOST}:${PGPORT}/${PGDATABASE} as ${PGUSER}"

# wait for RDS to accept connections (it is usually up, but be defensive)
for i in $(seq 1 30); do
  if pg_isready -q; then break; fi
  echo "[db-migrate] waiting for database... ($i)"
  sleep 5
done

if [ "$(psql -tAc "SELECT to_regclass('public.users') IS NOT NULL")" = "t" ]; then
  echo "[db-migrate] schema already present — nothing to do"
  exit 0
fi

for f in /sql/*.sql; do
  echo "[db-migrate] applying $f"
  psql -v ON_ERROR_STOP=1 -f "$f"
done

echo "[db-migrate] migration complete"
