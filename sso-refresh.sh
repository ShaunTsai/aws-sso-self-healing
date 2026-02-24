#!/bin/bash
# =============================================================================
# sso-refresh.sh — Self-healing AWS SSO session keeper
# =============================================================================
# Run every 10 minutes via launchd (macOS) or systemd timer (Linux).
#
# What it does:
#   1. Probes AWS STS to check if the SSO session is alive
#   2. If alive: logs "OK" (the AWS CLI silently refreshes the accessToken)
#   3. If expired: starts device-code login in BACKGROUND, sends URL to alert
#
# The "self-healing" trick: the AWS CLI automatically uses the refreshToken
# to renew the accessToken on every STS call. So this health-check
# inadvertently keeps the session alive for ~90 days.
#
# IMPORTANT: The device-code login runs in the background and keeps polling
# until the user approves (up to ~10 min). A lock file prevents the next
# cron run from starting a duplicate login flow.
# =============================================================================

set -uo pipefail

# --- Configuration (edit these) ---
PROFILE="my-profile"                                    # Your AWS SSO profile name
LOG_DIR="$HOME/.config/sso-self-healing/logs"
LOG="$LOG_DIR/sso-refresh.log"
LOCK="$LOG_DIR/.sso-login.lock"

# Alert function — customize this for your notification method
# Examples: Telegram bot, Slack webhook, email, desktop notification
send_alert() {
    local message="$1"
    # --- Option 1: Telegram via OpenClaw ---
    # openclaw message send --channel telegram --target "$CHAT_ID" -m "$message"

    # --- Option 2: Telegram bot API ---
    # curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    #   -d chat_id="${CHAT_ID}" -d text="${message}" > /dev/null

    # --- Option 3: Slack ---
    # curl -s -X POST "${SLACK_WEBHOOK_URL}" \
    #   -H 'Content-type: application/json' \
    #   -d "{\"text\": \"${message}\"}" > /dev/null

    # --- Option 4: macOS desktop notification ---
    # osascript -e "display notification \"${message}\" with title \"SSO Alert\""

    # --- Option 5: Just log it (default) ---
    echo "ALERT: ${message}" >> "$LOG"
}
# --- End configuration ---

export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"

mkdir -p "$LOG_DIR"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

# --- Check if a background login is already running ---
if [ -f "$LOCK" ]; then
    pid=$(cat "$LOCK" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "SKIP — device-code login already polling (PID $pid)"
        exit 0
    fi
    rm -f "$LOCK"
fi

# --- Probe STS (this triggers silent accessToken refresh) ---
if aws sts get-caller-identity --profile "$PROFILE" &>/dev/null; then
    rm -f "$LOCK"
    log "OK"
    exit 0
fi

# --- Check if it's a token expiry issue ---
PROBE=$(aws sts get-caller-identity --profile "$PROFILE" 2>&1)
if echo "$PROBE" | grep -qiE "expired|refresh.*fail|UnauthorizedSSO|SSOTokenProvider|SSO session"; then
    log "WARN — SSO expired. Starting device-code login in background..."

    OUT=$(mktemp /tmp/sso-login.XXXXXX)

    # Run device-code login in background — polls until user approves or ~10 min
    (
        aws sso login --profile "$PROFILE" --use-device-code --no-browser >"$OUT" 2>&1
        rc=$?
        if [ $rc -eq 0 ]; then
            log "RENEWED ✅ — session restored"
            send_alert "✅ AWS SSO session renewed successfully"
        else
            log "LOGIN FAILED (exit $rc)"
        fi
        rm -f "$LOCK" "$OUT"
    ) &

    echo $! > "$LOCK"
    sleep 5

    # Extract the autofill device URL (with user_code= parameter)
    URL=$(grep -oE 'https://[^ ]*user_code=[^ ]*' "$OUT" 2>/dev/null | head -1)
    [ -z "$URL" ] && URL=$(grep -oE 'https://[^ ]+' "$OUT" 2>/dev/null | tail -1)

    if [ -n "$URL" ]; then
        send_alert "🔑 AWS SSO expired. Approve from any device: $URL"
        log "Alert sent: device-code URL"
    else
        send_alert "🔑 AWS SSO expired. Run: aws sso login --profile $PROFILE --use-device-code --no-browser"
        log "WARN — no URL extracted"
    fi
else
    log "ERROR — STS failed (not token-related): $PROBE"
    send_alert "AWS SSO health-check failed (non-token error). Check logs."
fi
