#!/usr/bin/env bash
set -uo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
PUZZLE_DIR="/app/puzzles"
NYT_COOKIES="/app/nyt_cookies.txt"
RM_COOKIES="/app/rm_cookies.txt"
PARENT_ID_PUZZLE="${PARENT_ID_PUZZLE:-f765283d-cd3f-4828-b13c-be7243d8c29a}"
PARENT_ID_SOLUTION="${PARENT_ID_SOLUTION:-585073dd-e08e-4696-a21b-0fc960cfef41}"

TODAY=$(date +%Y-%m-%d)
FAILED=0

run_step() {
    local label="$1"; shift
    echo ""
    echo ">> ${label}"
    if "$@"; then
        return 0
    else
        local rc=$?
        echo "!! ${label} failed (exit code ${rc})"
        FAILED=1
        return $rc
    fi
}

echo "==============================================================="
echo "  rm-xword  |  ${TODAY}"
echo "==============================================================="

# --- Step 1: Download puzzle + solution ------------------------------------
run_step "Step 1/3  Downloading crossword..." \
    python3 /app/nyt-crossword-download/download.py \
        --no-print --solution \
        -o "$PUZZLE_DIR" \
        -b "$NYT_COOKIES"

if [[ $FAILED -eq 1 ]]; then
    echo ""
    echo "!! Download failed -- aborting."
    exit 1
fi

# Discover the most recently created files
PUZZLE=$(ls -t "$PUZZLE_DIR"/*.pdf 2>/dev/null | grep -v '\.soln\.' | head -1)
SOLUTION=$(ls -t "$PUZZLE_DIR"/*.soln.pdf 2>/dev/null | head -1)

if [[ -z "$PUZZLE" || -z "$SOLUTION" ]]; then
    echo "!! Could not find downloaded puzzle/solution files"
    exit 1
fi

echo "  puzzle:   $PUZZLE"
echo "  solution: $SOLUTION"

# --- Step 2: Upload puzzle -------------------------------------------------
UPLOAD_COOKIE_ARGS=()
if [[ -f "$RM_COOKIES" && -s "$RM_COOKIES" ]]; then
    UPLOAD_COOKIE_ARGS=(--cookie-file "$RM_COOKIES")
fi

run_step "Step 2/3  Uploading puzzle..." \
    python3 /app/rmupload/upload.py \
        "$PUZZLE" \
        --parent-id "$PARENT_ID_PUZZLE" \
        -f \
        "${UPLOAD_COOKIE_ARGS[@]}"

# --- Step 3: Upload solution -----------------------------------------------
run_step "Step 3/3  Uploading solution..." \
    python3 /app/rmupload/upload.py \
        "$SOLUTION" \
        --parent-id "$PARENT_ID_SOLUTION" \
        --cookie-file "$RM_COOKIES"

# ── Result ────────────────────────────────────────────────────────────────────
if [[ $FAILED -eq 1 ]]; then
    echo ""
    echo "!! One or more steps failed."
    exit 1
fi

echo ""
echo "All done!"
exit 0
