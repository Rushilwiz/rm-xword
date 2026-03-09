FROM python:3.12-slim

# System deps
RUN apt-get update && \
    apt-get install -y --no-install-recommends cron && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Python deps
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Application code
COPY nyt-crossword-download/ nyt-crossword-download/
COPY rmupload/                rmupload/
COPY entrypoint.sh            entrypoint.sh
COPY cron-entry.sh            cron-entry.sh
RUN chmod +x entrypoint.sh cron-entry.sh

# Create puzzles dir (will be overridden by volume mount)
RUN mkdir -p /app/puzzles

# Default: start cron in foreground
COPY crontab /etc/cron.d/rm-xword
RUN chmod 0644 /etc/cron.d/rm-xword && \
    crontab /etc/cron.d/rm-xword

COPY start.sh start.sh
RUN chmod +x start.sh

CMD ["./start.sh"]
