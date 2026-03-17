#!/bin/sh
set -e

mkdir -p /data/apk-cache
echo "[leaderboard] Installing Redis..."
apk add --no-cache --cache-dir /data/apk-cache redis 2>&1

echo "[leaderboard] Starting Redis with persistence..."
redis-server --dir /data --save 30 1 --appendonly yes --appendfsync everysec --daemonize yes --logfile /data/redis.log

echo "[leaderboard] Waiting for Redis to be ready..."
for i in $(seq 1 10); do
  redis-cli ping 2>/dev/null | grep -q PONG && break
  sleep 0.5
done

echo "[leaderboard] Installing Node.js dependencies..."
if [ -d /data/node_modules ]; then
  cp -r /data/node_modules /app/node_modules
else
  cd /app && npm install --prefer-offline --no-fund --no-audit 2>&1
  cp -r /app/node_modules /data/node_modules
fi

cd /app
exec node server.js
