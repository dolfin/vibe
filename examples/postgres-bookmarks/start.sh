#!/bin/sh
set -e

echo "[bookmarks] Installing PostgreSQL..."
apk add --no-cache postgresql postgresql-client 2>&1

export PGDATA=/data/pgdata

echo "[bookmarks] Setting up runtime directories..."
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

echo "[bookmarks] Ensuring database exists..."
psql -h 127.0.0.1 -U postgres -c "CREATE DATABASE bookmarks;" 2>/dev/null || true

echo "[bookmarks] Installing Node.js dependencies..."
cd /app && npm install --prefer-offline --no-fund --no-audit 2>&1

echo "[bookmarks] Starting web server..."
exec node server.js
