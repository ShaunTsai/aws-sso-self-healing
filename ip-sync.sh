#!/bin/bash
# =============================================================================
# ip-sync.sh — Auto-update EventBridge rule when public IP changes
# =============================================================================
# Run every 30 minutes via launchd (macOS) or systemd timer (Linux).
# Detects public IP changes (dynamic ISP) and updates the EventBridge
# rule so alerts only fire for non-home IPs.
# =============================================================================

export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"

# --- Configuration (edit these) ---
PROFILE="admin"
REGION="us-east-1"
RULE_NAME="bedrock-unusual-ip-alert"
STATE_DIR="$HOME/.config/sso-self-healing"
IP_FILE="$STATE_DIR/.current-home-ip"
LOG="$STATE_DIR/logs/ip-sync.log"

# Notification command — replace with your method
send_notification() {
    local message="$1"
    openclaw message send --channel telegram -m "$message" 2>> "$LOG" || \
        echo "NOTIFY: $message" >> "$LOG"
}
# --- End configuration ---

mkdir -p "$STATE_DIR/logs"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

# Get current public IP (try multiple sources)
CURRENT_IP=$(curl -s --max-time 10 https://checkip.amazonaws.com 2>/dev/null | tr -d '\n')
if [ -z "$CURRENT_IP" ]; then
    CURRENT_IP=$(curl -s --max-time 10 https://ifconfig.me 2>/dev/null | tr -d '\n')
fi
if [ -z "$CURRENT_IP" ]; then
    CURRENT_IP=$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null | tr -d '\n')
fi

if [ -z "$CURRENT_IP" ]; then
    log "ERROR — Could not determine public IP"
    exit 1
fi

# Get stored IP
STORED_IP=""
if [ -f "$IP_FILE" ]; then
    STORED_IP=$(cat "$IP_FILE")
fi

# Compare
if [ "$CURRENT_IP" = "$STORED_IP" ]; then
    log "OK — IP unchanged ($CURRENT_IP)"
    exit 0
fi

# IP changed — update the EventBridge rule
log "IP CHANGED — $STORED_IP → $CURRENT_IP"

EVENT_PATTERN=$(cat <<EOF
{
  "source": ["aws.bedrock"],
  "detail-type": ["AWS API Call via CloudTrail"],
  "detail": {
    "eventSource": ["bedrock.amazonaws.com"],
    "sourceIPAddress": [{"anything-but": ["$CURRENT_IP"]}]
  }
}
EOF
)

RESULT=$(aws events put-rule \
    --name "$RULE_NAME" \
    --event-pattern "$EVENT_PATTERN" \
    --state ENABLED \
    --description "Alert when Bedrock API called from non-home IP (not $CURRENT_IP)" \
    --region "$REGION" --profile "$PROFILE" 2>&1)

if [ $? -eq 0 ]; then
    echo "$CURRENT_IP" > "$IP_FILE"
    log "UPDATED — EventBridge rule now allows $CURRENT_IP"
    send_notification "🔄 Home IP changed: $STORED_IP → $CURRENT_IP. EventBridge rule updated."
else
    log "ERROR — Failed to update rule: $RESULT"
    send_notification "⚠️ IP changed ($STORED_IP → $CURRENT_IP) but EventBridge update FAILED. Check logs."
fi
