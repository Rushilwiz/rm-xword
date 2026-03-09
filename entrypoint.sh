#!/usr/bin/env bash
set -euo pipefail

# ── Configuration (from environment) ─────────────────────────────────────────
PUZZLE_DIR="/app/puzzles"
NYT_COOKIES="/app/nyt_cookies.txt"
RM_COOKIES="/app/rm_cookies.txt"
PARENT_ID_PUZZLE="${PARENT_ID_PUZZLE:-f765283d-cd3f-4828-b13c-be7243d8c29a}"
PARENT_ID_SOLUTION="${PARENT_ID_SOLUTION:-585073dd-e08e-4696-a21b-0fc960cfef41}"

# SMTP settings
SMTP_HOST="${SMTP_HOST:-mail.rushil.land}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:-no-reply@rushil.land}"
SMTP_PASS="${SMTP_PASS:-TEST}"
MAIL_FROM="${MAIL_FROM:-no-reply@rushil.land}"
MAIL_TO="${MAIL_TO:-no-reply@rushil.land}"

TODAY=$(date +%Y-%m-%d)

# ── Helper: send failure email ───────────────────────────────────────────────
send_failure_email() {
    local output="$1"
    local subject="rm-xword seems to have failed on ${TODAY}"

    python3 - <<PYEOF
import smtplib
from email.mime.text import MIMEText

body = """The rm-xword job failed on ${TODAY}.

--- Full command output ---

${output}
"""

msg = MIMEText(body)
msg["Subject"] = "${subject}"
msg["From"]    = "${MAIL_FROM}"
msg["To"]      = "${MAIL_TO}"

try:
    with smtplib.SMTP("${SMTP_HOST}", ${SMTP_PORT}) as srv:
        srv.starttls()
        srv.login("${SMTP_USER}", "${SMTP_PASS}")
        srv.sendmail("${MAIL_FROM}", "${MAIL_TO}", msg.as_string())
    print("✉  Failure email sent to ${MAIL_TO}")
except Exception as e:
    print(f"⚠  Could not send failure email: {e}")
PYEOF
}

# ── Main ─────────────────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════"
echo "  rm-xword  •  ${TODAY}"
echo "═══════════════════════════════════════════════════════"

# Capture all output so we can email it on failure
OUTPUT_LOG=$(mktemp)
exec > >(tee "$OUTPUT_LOG") 2>&1

run() {
    # --- Step 1: Download puzzle + solution --------------------------------
    echo ""
    echo "▶ Step 1/3  Downloading crossword…"
    python3 /app/nyt-crossword-download/download.py \
        --no-print --solution \
        -o "$PUZZLE_DIR" \
        -b "$NYT_COOKIES"

    # Discover the files that were just downloaded (today's date pattern)
    PUZZLE=$(ls -t "$PUZZLE_DIR"/*.pdf 2>/dev/null | grep -v '\.soln\.' | head -1)
    SOLUTION=$(ls -t "$PUZZLE_DIR"/*.soln.pdf 2>/dev/null | head -1)

    if [[ -z "$PUZZLE" || -z "$SOLUTION" ]]; then
        echo "✗ Could not find downloaded puzzle/solution files"
        return 1
    fi

    echo "  puzzle:   $PUZZLE"
    echo "  solution: $SOLUTION"

    # --- Step 2: Upload puzzle ---------------------------------------------
    echo ""
    echo "▶ Step 2/3  Uploading puzzle…"
    UPLOAD_COOKIE_ARGS=()
    if [[ -f "$RM_COOKIES" ]]; then
        UPLOAD_COOKIE_ARGS=(--cookie-file "$RM_COOKIES")
    fi

    python3 /app/rmupload/upload.py \
        "$PUZZLE" \
        --parent-id "$PARENT_ID_PUZZLE" \
        -f \
        "${UPLOAD_COOKIE_ARGS[@]}"

    # --- Step 3: Upload solution -------------------------------------------
    echo ""
    echo "▶ Step 3/3  Uploading solution…"
    python3 /app/rmupload/upload.py \
        "$SOLUTION" \
        --parent-id "$PARENT_ID_SOLUTION" \
        --cookie-file "$RM_COOKIES"

    echo ""
    echo "✓ All done!"
}

if ! run; then
    echo ""
    echo "✗ Job failed – sending notification email…"
    send_failure_email "$(cat "$OUTPUT_LOG")"
    rm -f "$OUTPUT_LOG"
    exit 1
fi

rm -f "$OUTPUT_LOG"
