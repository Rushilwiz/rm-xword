#!/usr/bin/env bash
set -uo pipefail
# NOTE: we intentionally do NOT use `set -e` — we check exit codes manually
# so we can always reach the failure-email logic.

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
export TODAY SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASS MAIL_FROM MAIL_TO
FAILED=0

# ── Capture all output to a log file ─────────────────────────────────────────
OUTPUT_LOG=$(mktemp)
exec > >(tee "$OUTPUT_LOG") 2>&1

# ── Helper: send failure email ───────────────────────────────────────────────
send_failure_email() {
    local logfile="$1"
    python3 <<'PYEOF' "$logfile"
import smtplib, sys, os
from email.mime.text import MIMEText

logfile = sys.argv[1]
with open(logfile) as f:
    output = f.read()

today     = os.environ.get("TODAY", "unknown")
smtp_host = os.environ.get("SMTP_HOST", "")
smtp_port = int(os.environ.get("SMTP_PORT", "587"))
smtp_user = os.environ.get("SMTP_USER", "")
smtp_pass = os.environ.get("SMTP_PASS", "")
mail_from = os.environ.get("MAIL_FROM", "")
mail_to   = os.environ.get("MAIL_TO", "")

subject = f"rm-xword seems to have failed on {today}"
body = f"The rm-xword job failed on {today}.\n\n--- Full command output ---\n\n{output}"

msg = MIMEText(body)
msg["Subject"] = subject
msg["From"]    = mail_from
msg["To"]      = mail_to

try:
    with smtplib.SMTP(smtp_host, smtp_port) as srv:
        srv.starttls()
        srv.login(smtp_user, smtp_pass)
        srv.sendmail(mail_from, mail_to, msg.as_string())
    print(f"✉  Failure email sent to {mail_to}")
except Exception as e:
    print(f"⚠  Could not send failure email: {e}")
PYEOF
}

# ── Helper: run a step, set FAILED=1 on non-zero exit ────────────────────────
run_step() {
    local label="$1"
    shift
    echo ""
    echo "▶ ${label}"
    if "$@"; then
        return 0
    else
        local rc=$?
        echo "✗ ${label} failed (exit code ${rc})"
        FAILED=1
        return $rc
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════"
echo "  rm-xword  •  ${TODAY}"
echo "═══════════════════════════════════════════════════════"

# --- Step 1: Download puzzle + solution ------------------------------------
run_step "Step 1/3  Downloading crossword…" \
    python3 /app/nyt-crossword-download/download.py \
        --no-print --solution \
        -o "$PUZZLE_DIR" \
        -b "$NYT_COOKIES"

if [[ $FAILED -eq 1 ]]; then
    echo ""
    echo "✗ Download failed — aborting."
    send_failure_email "$OUTPUT_LOG"
    rm -f "$OUTPUT_LOG"
    exit 1
fi

# Discover the files that were just downloaded
PUZZLE=$(ls -t "$PUZZLE_DIR"/*.pdf 2>/dev/null | grep -v '\.soln\.' | head -1)
SOLUTION=$(ls -t "$PUZZLE_DIR"/*.soln.pdf 2>/dev/null | head -1)

if [[ -z "$PUZZLE" || -z "$SOLUTION" ]]; then
    echo "✗ Could not find downloaded puzzle/solution files"
    send_failure_email "$OUTPUT_LOG"
    rm -f "$OUTPUT_LOG"
    exit 1
fi

echo "  puzzle:   $PUZZLE"
echo "  solution: $SOLUTION"

# --- Step 2: Upload puzzle -------------------------------------------------
UPLOAD_COOKIE_ARGS=()
if [[ -f "$RM_COOKIES" && -s "$RM_COOKIES" ]]; then
    UPLOAD_COOKIE_ARGS=(--cookie-file "$RM_COOKIES")
fi

run_step "Step 2/3  Uploading puzzle…" \
    python3 /app/rmupload/upload.py \
        "$PUZZLE" \
        --parent-id "$PARENT_ID_PUZZLE" \
        -f \
        "${UPLOAD_COOKIE_ARGS[@]}"

# --- Step 3: Upload solution -----------------------------------------------
run_step "Step 3/3  Uploading solution…" \
    python3 /app/rmupload/upload.py \
        "$SOLUTION" \
        --parent-id "$PARENT_ID_SOLUTION" \
        --cookie-file "$RM_COOKIES"

# ── Result ────────────────────────────────────────────────────────────────────
if [[ $FAILED -eq 1 ]]; then
    echo ""
    echo "✗ One or more steps failed – sending notification email…"
    send_failure_email "$OUTPUT_LOG"
    rm -f "$OUTPUT_LOG"
    exit 1
else
    echo ""
    echo "✓ All done!"
    rm -f "$OUTPUT_LOG"
    exit 0
fi
