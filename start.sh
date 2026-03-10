#!/usr/bin/env bash
set -euo pipefail

echo "rm-xword container starting…"

# ── Persist env vars so cron jobs can see them ────────────────────────────
printenv | grep -E '^(RM_|PARENT_ID_|SMTP_|MAIL_|PATH=)' | \
    sed 's/^\(.*\)$/export \1/' > /app/.env.runtime

# ── Optionally run once immediately (e.g. docker run --env RUN_NOW=1) ─────
if [[ "${RUN_NOW:-0}" == "1" ]]; then
    echo "RUN_NOW=1 → executing job immediately…"
    /app/entrypoint.sh
fi

# ── Start cron in foreground ──────────────────────────────────────────────
if [[ "${RUN_NOW:-0}" == "0" ]]; then
    echo "Starting cron (next run: 01:00 daily)…"
    cron -f
fi
