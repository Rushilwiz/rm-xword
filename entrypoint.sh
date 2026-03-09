#!/usr/bin/env bash
#
# Wrapper that runs the job, captures all output, and sends a
# failure email if anything goes wrong.  Output is always printed
# to stdout (for docker logs) AND saved to a temp file (for the email).
#

set -uo pipefail

export TODAY=$(date +%Y-%m-%d)
export SMTP_HOST="${SMTP_HOST:-mail.rushil.land}"
export SMTP_PORT="${SMTP_PORT:-587}"
export SMTP_USER="${SMTP_USER:-no-reply@rushil.land}"
export SMTP_PASS="${SMTP_PASS:-TEST}"
export MAIL_FROM="${MAIL_FROM:-no-reply@rushil.land}"
export MAIL_TO="${MAIL_TO:-no-reply@rushil.land}"

LOG=$(mktemp /tmp/rm-xword-log.XXXXXX)

# Run the real job; pipe output to both the terminal and the log file.
# `pipefail` ensures we get run_job.sh's exit code, not tee's.
/app/run_job.sh 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}

if [[ $RC -ne 0 ]]; then
    echo ""
    echo "-- Sending failure notification email..."
    python3 /app/send_email.py "$LOG"
fi

rm -f "$LOG"
exit $RC
