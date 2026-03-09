#!/usr/bin/env bash
set -euo pipefail

source /app/.env.runtime 2>/dev/null || true
exec /app/entrypoint.sh
