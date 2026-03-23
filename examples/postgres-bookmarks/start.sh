#!/bin/sh
set -e

# PGDATA lives inside the container's own filesystem (not the virtiofs-mounted
# volume) because Apple Virtualization Framework's virtiofs does not support
# chmod for non-root users, and PostgreSQL's initdb requires it.
# Persistence is handled by pg_dump → /data/bookmarks.sql (dump-on-exit +
# background save every 60s). On startup the dump is restored if present.
export PGDATA=/var/lib/postgresql/data
PGDUMP=/data/bookmarks.sql

mkdir -p /data
mkdir -p /run/postgresql && chown postgres:postgres /run/postgresql

echo "[bookmarks] Installing PostgreSQL..."
# Skip caching — the cached APKINDEX may be stale and resolve to a different
# major version than the running Alpine image.
apk add --quiet postgresql postgresql-client 2>&1

echo "[bookmarks] Initializing PostgreSQL database cluster..."
mkdir -p "$PGDATA"
chown postgres:postgres "$PGDATA"
# --no-sync: skip fsync during initdb — safe for a demo, meaningfully faster
su -s /bin/sh postgres -c \
  "initdb -D $PGDATA -U postgres --auth=trust --auth-local=trust --encoding=UTF8 --locale=C --no-sync"

echo "[bookmarks] Starting PostgreSQL..."
# fsync=off + synchronous_commit=off: avoid slow fsync (only safe for a demo)
su -s /bin/sh postgres -c \
  "pg_ctl -D $PGDATA start -W -o '-c listen_addresses=127.0.0.1 -c fsync=off -c synchronous_commit=off'"

echo "[bookmarks] Waiting for PostgreSQL to be ready..."
i=0
while [ $i -lt 60 ]; do
  pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 && break
  sleep 2
  i=$((i + 1))
done

if ! pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then
  echo "[bookmarks] ERROR: PostgreSQL failed to start within 120s"
  cat "$PGDATA/server.log" 2>/dev/null || true
  exit 1
fi

psql -h 127.0.0.1 -U postgres -c "CREATE DATABASE bookmarks;" 2>/dev/null || true

# Restore saved data (written by previous run)
if [ -f "$PGDUMP" ]; then
  echo "[bookmarks] Restoring saved bookmarks..."
  psql -h 127.0.0.1 -U postgres bookmarks < "$PGDUMP" 2>/dev/null || true
fi

# Background saver: dump database to /data every 60s so data survives restarts
(while true; do
  sleep 60
  pg_dump -h 127.0.0.1 -U postgres bookmarks > "$PGDUMP.tmp" 2>/dev/null \
    && mv "$PGDUMP.tmp" "$PGDUMP"
done) &

# Cache node_modules in the data volume — restores on subsequent starts
# instead of re-fetching from npm.
echo "[bookmarks] Installing Node.js dependencies..."
if [ -d /data/node_modules ]; then
  cp -r /data/node_modules /app/node_modules
else
  cd /app && npm install --prefer-offline --no-fund --no-audit 2>&1
  cp -r /app/node_modules /data/node_modules
fi

echo "[bookmarks] Starting web server..."
cd /app
exec node server.js
