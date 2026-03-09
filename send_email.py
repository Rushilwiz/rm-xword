#!/usr/bin/env python3
"""Send a failure-notification email with the job log attached as the body."""

import smtplib
import sys
import os
from email.mime.text import MIMEText


def main():
    logfile = sys.argv[1] if len(sys.argv) > 1 else None
    output = ""
    if logfile:
        try:
            with open(logfile) as f:
                output = f.read()
        except Exception as e:
            output = f"(could not read log file {logfile}: {e})"

    today     = os.environ.get("TODAY", "unknown")
    smtp_host = os.environ.get("SMTP_HOST", "")
    smtp_port = int(os.environ.get("SMTP_PORT", "587"))
    smtp_user = os.environ.get("SMTP_USER", "")
    smtp_pass = os.environ.get("SMTP_PASS", "")
    mail_from = os.environ.get("MAIL_FROM", "")
    mail_to   = os.environ.get("MAIL_TO", "")

    subject = f"rm-xword seems to have failed on {today}"
    body = (
        f"The rm-xword job failed on {today}.\n\n"
        f"--- Full command output ---\n\n"
        f"{output}"
    )

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
        print(f"⚠  Could not send failure email: {e}", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
