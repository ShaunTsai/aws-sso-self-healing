#!/bin/bash
# =============================================================================
# sso-refresh.sh — Self-healing AWS SSO session keeper
# =============================================================================
# Run every 10 minutes via launchd (macOS) or systemd timer (Linux).
#
# What it does:
#   1. Probes AWS STS to check if the SSO session is alive
#   2. If alive: logs "OK" (the AWS CLI silently refreshes the accessToken)
#   3. If expired: initiates device-code login and sends alert
#
# The "self-healing" trick: the AWS CLI automatically uses the refreshToken
# to renew the accessToken on every STS call. So this health-check
# inadvertently keeps the session alive for ~90 days.
# =============================================================================

set -euo pipefail

# --- Configuration (edit these) ---
PROFILE="my-profile"                                    # Your AWS SSO profile name
LOG_DIR="$HOME/.config/sso-self-healing/logs"
LOG="$LOG_DIR/sso-refresh.log"

# Alert function — customize this for your notification method
# Examples: Telegram bot, Slack webhook, email, desktop notification
send_alert() {
    local message="$1"
    # --- Option 1: Telegram ---
    # curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    #   -d chat_id="${CHAT_ID}" -d text="${message}" > /dev/null

    # --- Option 2: Slack ---
    # curl -s -X POST "${SLACK_WEBHOOK_URL}" \
    #   -H 'Content-type: application/json' \
    #   -d "{\"text\": \"${message}\"}" > /dev/null

    # --- Option 3: macOS desktop notification ---
    # osascript -e "display notification \"${message}\" with title \"SSO Alert\""

    # --- Option 4: Just log it ---
    echo "ALERT: ${message}" >> "$LOG"
}
# --- End configuration ---

export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"

mkdir -p "$LOG_DIR"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

# Probe STS
PROBE=$(aws sts get-caller-identity --profile "$PROFILE" 2>&1)
if [ $? -eq 0 ]; then
    log "OK"
    exit 0
fi

# Check if it's a token expiry issue
if echo "$PROBE" | grep -qiE "token.*expired|refresh.*failed|UnauthorizedSSOToken|SSOTokenProviderFailure|expired.*token"; then
    log "WARN — SSO expired. Initiating re-auth..."

    # Try device-code login (non-interactive)
    LOGIN=$(aws sso login --profile "$PROFILE" --use-device-code --no-browser 2>&1)
    EXIT=$?
    URL=$(echo "$LOGIN" | grep -oE 'https://[^ ]+')

    if [ -n "$URL" ]; then
        send_alert "AWS SSO expired. Re-auth here: $URL"
        log "Device-code URL sent via alert."
    else
        send_alert "AWS SSO expired. Run: aws sso login --profile $PROFILE"
        log "ERROR — No auth URL extracted: $LOGIN"
    fi

    [ $EXIT -eq 0 ] && log "Device-code login initiated."
else
    log "ERROR — STS failed (not token-related): $PROBE"
    send_alert "AWS SSO health-check failed (non-token error). Check logs."
fi
