#!/bin/sh
set -e
npm install --prefer-offline --no-fund --no-audit 2>&1
exec node server.js
