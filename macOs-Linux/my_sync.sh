#!/bin/bash

# =============================================================================
# rclone_sync.sh — Local ↔ Wasabi bisync with email notifications
# v1.8 — Configurable working directory, lockfile age check,
#         Trap, OS/Host detect, Log Rotation, Recovery email
# =============================================================================

# --- AUTO-DETECT OS, MACHINE NAME AND PATH ---
OS_TYPE=$(uname)
HOST_NAME=$(hostname)
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

if [ "$OS_TYPE" = "Darwin" ]; then
    RCLONE_CMD="/opt/homebrew/bin/rclone"
    PING_CMD=(/sbin/ping -c 1 -t 2)
    STAT_MTIME="stat -f %m"
else
    RCLONE_CMD="/usr/bin/rclone"
    PING_CMD=(ping -c 1 -W 2)
    STAT_MTIME="stat -c %Y"
fi

# --- WORKING DIRECTORY ---
# This is where the log, lockfile, fail counter and bisync marker are written.
#
# Three ways to set it (in order of priority):
#
# 1. Environment variable in the crontab (most flexible, no need to edit the script):
#    RCLONE_SYNC_DIR=/opt/rclone_data */5 * * * * /path/to/rclone_sync.sh
#
# 2. Export in your .zshrc / .bashrc (applies to all manual terminal runs):
#    export RCLONE_SYNC_DIR="/opt/rclone_data"
#
# 3. Uncomment and edit the line below (hardcoded in the script):
#    RCLONE_SYNC_DIR="/opt/rclone_data"
#
# If none of the three is set, the default is the user's home directory ($HOME).
WORK_DIR="${RCLONE_SYNC_DIR:-$HOME}"

# Create the directory only if it does not exist
if [ ! -d "$WORK_DIR" ]; then
    mkdir -p "$WORK_DIR" 2>/dev/null || {
        echo "ERROR: cannot create working directory $WORK_DIR" >&2
        exit 1
    }
fi

LOGFILE="$WORK_DIR/rclone_sync.log"
FAIL_FILE="$WORK_DIR/rclone_fail_count.txt"
ALERT_FLAG="$WORK_DIR/.rclone_alert_sent"
LOCKFILE="$WORK_DIR/rclone_sync.lock"
BISYNC_MARKER="$WORK_DIR/.rclone_bisync_initialized"

# --- DEBUG (1=enabled, 0=silent) ---
DEBUG=1

# --- RCLONE SETTINGS ---
# LOCAL: path to the local folder you want to sync (e.g. your Cryptomator vault mount point)
# REMOTE: rclone remote in the form "<remote-name>:<bucket>/<path>"
LOCAL="$HOME/YourVault"
REMOTE="wasabi-remote:your-bucket/your-folder"

# --- EMAIL SETTINGS (Resend API) ---
# Get your API key at https://resend.com
RESEND_API_KEY="re_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
EMAIL_FROM="noreply@example.com"
EMAIL_TO="your-email@example.com"
MAX_FAILS=3

# --- LOCKFILE: maximum age in seconds (default 4 hours) ---
LOCK_MAX_AGE=14400

# =============================================================================
# FUNCTIONS
# =============================================================================

log() {
    if [ "$DEBUG" -eq 1 ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$HOST_NAME|$OS_TYPE] $1" >> "$LOGFILE"
    fi
}

send_alert() {
    local REASON="$1"
    local SUBJECT="$2"
    local BODY="$3"
    log "Sending email: $SUBJECT"

    # Build JSON safely (avoids injection from quotes/newlines in the body)
    local PAYLOAD
    PAYLOAD=$(EMAIL_FROM="$EMAIL_FROM" EMAIL_TO="$EMAIL_TO" SUBJECT="$SUBJECT" BODY="$BODY" \
        python3 -c 'import json,os; print(json.dumps({"from":os.environ["EMAIL_FROM"],"to":os.environ["EMAIL_TO"],"subject":os.environ["SUBJECT"],"html":os.environ["BODY"]}))' 2>/dev/null)
    if [ -z "$PAYLOAD" ]; then
        log "WARNING: cannot build JSON payload (python3 not available?)"
        return 1
    fi

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST 'https://api.resend.com/emails' \
        -H "Authorization: Bearer $RESEND_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD")
    log "Email sent — HTTP: $HTTP_CODE"
    if [ "$HTTP_CODE" -eq 200 ] || [ "$HTTP_CODE" -eq 201 ]; then
        return 0
    else
        log "WARNING: email not sent (HTTP $HTTP_CODE)"
        return 1
    fi
}

increment_fail() {
    local REASON="$1"
    log "ERROR: $REASON"

    if [ -f "$FAIL_FILE" ]; then
        read -r RAW_COUNT < "$FAIL_FILE"
    else
        RAW_COUNT=0
    fi

    if [[ "$RAW_COUNT" =~ ^[0-9]+$ ]]; then
        COUNT=$RAW_COUNT
    else
        COUNT=0
    fi

    COUNT=$((COUNT + 1))
    echo $COUNT > "$FAIL_FILE"
    log "Consecutive failures: $COUNT / $MAX_FAILS"

    # Send alert email only the first time we cross the threshold
    # (counter keeps growing until sync recovers, but no spam every cron cycle)
    if [ "$COUNT" -ge "$MAX_FAILS" ] && [ ! -f "$ALERT_FLAG" ]; then
        local SUBJECT="KO Wasabi alert on $HOST_NAME ($OS_TYPE)"
        local BODY="<p>Hi there,</p><p>Rclone has failed on <strong>$HOST_NAME</strong> ($OS_TYPE) <strong>$MAX_FAILS consecutive times</strong>.<br>Last error reason: <code>$REASON</code></p>"
        if send_alert "$REASON" "$SUBJECT" "$BODY"; then
            touch "$ALERT_FLAG"
            log "Alert email sent — flag created (recovery email will fire on next successful sync)"
        else
            log "Alert email NOT delivered — will retry next cycle"
        fi
    fi
}

reset_fail_with_recovery_email() {
    # Send recovery only if an alert was previously fired
    if [ -f "$ALERT_FLAG" ]; then
        local PREV_COUNT=0
        if [ -f "$FAIL_FILE" ]; then
            read -r RAW_COUNT < "$FAIL_FILE"
            if [[ "$RAW_COUNT" =~ ^[0-9]+$ ]]; then
                PREV_COUNT=$RAW_COUNT
            fi
        fi
        local SUBJECT="OK Wasabi on $HOST_NAME: sync restored"
        local BODY="<p>Hi there,</p><p>Wasabi sync on <strong>$HOST_NAME</strong> is back to working correctly after <strong>$PREV_COUNT consecutive errors</strong>.</p>"
        if send_alert "recovery" "$SUBJECT" "$BODY"; then
            /bin/rm -f "$ALERT_FLAG"
            log "Recovery email sent (was at $PREV_COUNT failures)"
        else
            log "Recovery email NOT sent — will retry on next successful sync"
        fi
    fi
    echo 0 > "$FAIL_FILE"
}

clean_exit() {
    trap - EXIT
    /bin/rm -f "$LOCKFILE"
    log "Clean exit"
    exit 0
}

# =============================================================================
# GLOBAL TRAP
# =============================================================================
# Capture the line of the failing command (ERR fires before EXIT)
ERR_LINE=0
trap 'ERR_LINE=$LINENO' ERR
trap 'EXIT_CODE=$?; /bin/rm -f "$LOCKFILE"; if [ $EXIT_CODE -ne 0 ]; then increment_fail "crash or abnormal exit (line $ERR_LINE, exit $EXIT_CODE)"; fi' EXIT

# =============================================================================
# LOG ROTATION — if > 1MB keep last 1000 lines and save .old backup
# =============================================================================
if [ -f "$LOGFILE" ]; then
    FILESIZE=$(stat -f "%z" "$LOGFILE" 2>/dev/null || stat -c "%s" "$LOGFILE" 2>/dev/null || echo 0)
    if [ "$FILESIZE" -gt 1048576 ]; then
        cp "$LOGFILE" "${LOGFILE}.old"
        tail -n 1000 "$LOGFILE" > "${LOGFILE}.tmp" && mv "${LOGFILE}.tmp" "$LOGFILE"
        log "Log rotation performed (backup saved to ${LOGFILE}.old)"
    fi
fi

# =============================================================================
# EXECUTION START
# =============================================================================
log "=============================="
log "Script started (PID $$)"
log "Working directory: $WORK_DIR"
log "rclone: $($RCLONE_CMD version 2>/dev/null | head -1)"

# --- LOCKFILE WITH AGE CHECK ---
if [ -f "$LOCKFILE" ]; then
    PID=$(cat "$LOCKFILE")
    LOCK_MTIME=$($STAT_MTIME "$LOCKFILE" 2>/dev/null || echo 0)
    LOCK_AGE=$(( $(date +%s) - LOCK_MTIME ))
    if kill -0 "$PID" 2>/dev/null; then
        if [ "$LOCK_AGE" -gt "$LOCK_MAX_AGE" ]; then
            log "WARNING: rclone (PID $PID) running for ${LOCK_AGE}s — likely stuck, forcing kill"
            kill "$PID" 2>/dev/null
            sleep 2
            kill -9 "$PID" 2>/dev/null
            /bin/rm -f "$LOCKFILE"
            increment_fail "rclone stuck for ${LOCK_AGE}s — forced kill"
        else
            log "EXIT: rclone already running (PID $PID, age ${LOCK_AGE}s), skipping"
            clean_exit
        fi
    else
        log "Stale lockfile found (PID $PID does not exist, age ${LOCK_AGE}s), removing"
        /bin/rm -f "$LOCKFILE"
    fi
fi
# Atomic lockfile creation (noclobber): if two instances start in parallel,
# only one wins. The other exits without doing any damage.
if ! (set -o noclobber; echo $$ > "$LOCKFILE") 2>/dev/null; then
    log "EXIT: lockfile race lost, another instance won"
    trap - EXIT
    exit 0
fi
log "Lock acquired (PID $$)"

# --- LOCAL FOLDER CHECK ---
if [ ! -d "$LOCAL" ]; then
    log "EXIT: local folder not found ($LOCAL) — vault not mounted?"
    clean_exit
fi
log "Local folder OK ($LOCAL)"

# --- INTERNET CHECK ---
if ! "${PING_CMD[@]}" 1.1.1.1 &> /dev/null; then
    log "EXIT: no internet connection"
    clean_exit
fi
log "Internet connection OK"

# --- FIRST RUN: automatic --resync if never initialized ---
if [ ! -f "$BISYNC_MARKER" ]; then
    log "First run detected — performing initial bisync --resync..."
    "$RCLONE_CMD" bisync "$LOCAL" "$REMOTE" --resync --log-level INFO >> "$LOGFILE" 2>&1
    RESYNC_EXIT=$?
    if [ $RESYNC_EXIT -eq 0 ]; then
        touch "$BISYNC_MARKER"
        log "Initial resync completed — marker created"
    else
        increment_fail "initial resync failed (exit code $RESYNC_EXIT)"
        trap - EXIT
        /bin/rm -f "$LOCKFILE"
        log "Script terminated with error during initial resync"
        exit 1
    fi
fi

# --- RCLONE EXECUTION ---
START_TIME=$(date +%s)
log "Starting rclone bisync..."
RCLONE_ARGS=(bisync "$LOCAL" "$REMOTE" --contimeout 60s --timeout 5m)

if [ "$DEBUG" -eq 1 ]; then
    "$RCLONE_CMD" "${RCLONE_ARGS[@]}" --log-level INFO >> "$LOGFILE" 2>&1
else
    "$RCLONE_CMD" "${RCLONE_ARGS[@]}" --log-level ERROR 2>/dev/null
fi
RCLONE_EXIT=$?

END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))
log "rclone exit code: $RCLONE_EXIT — duration: ${DURATION}s"

# --- RESULT HANDLING ---
trap - EXIT
/bin/rm -f "$LOCKFILE"
log "Lock released"

if [ $RCLONE_EXIT -eq 0 ]; then
    log "Sync completed successfully"
    reset_fail_with_recovery_email
else
    increment_fail "rclone exit code $RCLONE_EXIT"
fi

log "Script finished"