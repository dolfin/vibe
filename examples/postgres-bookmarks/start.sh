#!/bin/sh
set -e

# --- Virtiofs & initdb compatibility note ---
# Vibe's state volumes are virtiofs shares from macOS. Apple's virtiofsd
# does not support chmod for directories pre-created by a different user
# (initdb's case-1 path: "directory exists → chmod it" → EPERM).
#
# Fix: do NOT pre-create PGDATA. Let initdb create it via mkdir (case-0 path:
# "directory absent → mkdir with correct mode") which succeeds on virtiofs.
# We just need the parent (/data) to be world-writable so the postgres user
# can mkdir inside it.

export PGDATA=/data/pgdata

echo "[bookmarks] Installing PostgreSQL..."
apk add --quiet postgresql postgresql-client 2>&1

# /run/postgresql must be writable by the postgres server process.
mkdir -p /run/postgresql && chown postgres:postgres /run/postgresql

# Make the state volume world-writable so the postgres user can mkdir $PGDATA
# inside it without us pre-creating (and triggering the virtiofs chmod issue).
chmod 777 /data

if [ ! -f "$PGDATA/PG_VERSION" ]; then
  echo "[bookmarks] Initializing PostgreSQL database cluster..."
  # Remove any partial directory from a previous failed init attempt.
  rm -rf "$PGDATA"
  # initdb creates $PGDATA itself (mkdir path), so no chmod call is needed.
  # --no-sync: skip fsync during initdb — safe for demo, much faster on virtio-fs.
  su -s /bin/sh postgres -c \
    "initdb -D $PGDATA -U postgres --auth=trust --auth-local=trust --encoding=UTF8 --locale=C --no-sync"
fi

echo "[bookmarks] Starting PostgreSQL..."
# fsync=off + synchronous_commit=off: avoid slow fsync (safe for demo only)
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
