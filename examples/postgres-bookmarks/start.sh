#!/bin/sh
set -e

# Cache apk packages in the data volume — avoids re-downloading on every start.
# On first run this fetches from the network; subsequent runs install from cache.
mkdir -p /data/apk-cache
echo "[bookmarks] Installing PostgreSQL..."
apk add --no-cache --cache-dir /data/apk-cache postgresql postgresql-client 2>&1

export PGDATA=/data/pgdata

mkdir -p /run/postgresql && chown postgres:postgres /run/postgresql

if [ ! -f "$PGDATA/PG_VERSION" ]; then
  echo "[bookmarks] Initializing PostgreSQL database cluster..."
  mkdir -p "$PGDATA"
  chown postgres:postgres "$PGDATA"
  su -s /bin/sh postgres -c "initdb -D $PGDATA -U postgres --auth=trust --auth-local=trust --encoding=UTF8 --locale=C"
fi

echo "[bookmarks] Starting PostgreSQL..."
su -s /bin/sh postgres -c "pg_ctl -D $PGDATA -l $PGDATA/server.log start -o '-c listen_addresses=127.0.0.1'"

echo "[bookmarks] Waiting for PostgreSQL to be ready..."
i=0
while [ $i -lt 30 ]; do
  pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 && break
  sleep 1
  i=$((i + 1))
done

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
