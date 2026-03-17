set -e

echo "[leaderboard] Installing Redis..."
apk add --no-cache redis 2>&1

echo "[leaderboard] Starting Redis with persistence..."
redis-server --dir /data --save 30 1 --appendonly yes --appendfsync everysec --daemonize yes --logfile /data/redis.log

echo "[leaderboard] Waiting for Redis to be ready..."
for i in $(seq 1 10); do
  redis-cli ping 2>/dev/null | grep -q PONG && break
  echo "[leaderboard] Redis not ready yet (attempt $i/10), retrying..."
  sleep 0.5
done

cd /app && npm install --prefer-offline --no-fund --no-audit 2>&1

exec node server.js
