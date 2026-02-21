#!/bin/bash
# =============================================================================
# alert-poller.sh — Check GuardDuty findings and forward to Telegram/Slack
# =============================================================================
# Run every 15 minutes via launchd (macOS) or systemd timer (Linux).
# Checks for new HIGH/CRITICAL GuardDuty findings and sends alerts.
#
# Requires: aws cli, openclaw (or replace with your notification method)
# =============================================================================

export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"

# --- Configuration (edit these) ---
PROFILE="admin"
REGION="us-east-1"
LOG_DIR="$HOME/.config/sso-self-healing/logs"
LOG="$LOG_DIR/alert-poller.log"
STATE_FILE="$LOG_DIR/.last-finding-time"

# Notification command — replace with your method
# Option 1: OpenClaw Telegram
send_notification() {
    local message="$1"
    openclaw message send --channel telegram -m "$message" 2>> "$LOG" || \
        echo "ALERT (local): $message" >> "$LOG"
}
# Option 2: Slack webhook
# send_notification() {
#     curl -s -X POST "$SLACK_WEBHOOK_URL" \
#       -H 'Content-type: application/json' \
#       -d "{\"text\": \"$1\"}" > /dev/null
# }
# Option 3: Desktop notification (macOS)
# send_notification() {
#     osascript -e "display notification \"$1\" with title \"GuardDuty Alert\""
# }
# --- End configuration ---

mkdir -p "$LOG_DIR"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

# Get the last check time (or default to 1 hour ago)
if [ -f "$STATE_FILE" ]; then
    LAST_CHECK=$(cat "$STATE_FILE")
else
    # macOS date syntax; for Linux use: date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%SZ'
    LAST_CHECK=$(date -u -v-1H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%SZ')
fi

# Get detector ID
DETECTOR_ID=$(aws guardduty list-detectors --region "$REGION" --profile "$PROFILE" \
    --output text --query 'DetectorIds[0]' 2>/dev/null)

if [ -z "$DETECTOR_ID" ] || [ "$DETECTOR_ID" = "None" ]; then
    log "WARN — No GuardDuty detector found"
    exit 0
fi

# Convert timestamp to epoch milliseconds
if date -j -f '%Y-%m-%dT%H:%M:%SZ' "$LAST_CHECK" '+%s' &>/dev/null; then
    # macOS
    EPOCH_MS=$(( $(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$LAST_CHECK" '+%s') * 1000 ))
else
    # Linux
    EPOCH_MS=$(( $(date -d "$LAST_CHECK" '+%s') * 1000 ))
fi

# Query for new findings (HIGH and CRITICAL severity: >= 7.0)
FINDINGS=$(aws guardduty list-findings \
    --detector-id "$DETECTOR_ID" \
    --finding-criteria "{\"Criterion\":{\"severity\":{\"Gte\":7},\"updatedAt\":{\"GreaterThanOrEqual\":${EPOCH_MS}}}}" \
    --region "$REGION" --profile "$PROFILE" 2>/dev/null)

FINDING_IDS=$(echo "$FINDINGS" | python3 -c "
import sys, json
ids = json.load(sys.stdin).get('FindingIds', [])
print(' '.join(ids))
" 2>/dev/null)

if [ -n "$FINDING_IDS" ] && [ "$FINDING_IDS" != "" ]; then
    # Get finding details
    DETAILS=$(aws guardduty get-findings \
        --detector-id "$DETECTOR_ID" \
        --finding-ids $FINDING_IDS \
        --region "$REGION" --profile "$PROFILE" 2>/dev/null)

    # Format message
    MSG=$(echo "$DETAILS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
findings = data.get('Findings', [])
lines = ['🚨 GuardDuty Alert — {} new finding(s)'.format(len(findings))]
for f in findings:
    sev = f.get('Severity', 0)
    title = f.get('Title', 'Unknown')
    desc = f.get('Description', '')[:200]
    lines.append('  [{}] {}'.format(sev, title))
    lines.append('  {}'.format(desc))
    lines.append('')
print('\n'.join(lines))
" 2>/dev/null)

    if [ -n "$MSG" ]; then
        send_notification "$MSG"
        log "ALERT — Sent $(echo $FINDING_IDS | wc -w | tr -d ' ') finding(s)"
    fi
else
    log "OK — No new high-severity findings"
fi

# Update state
date -u '+%Y-%m-%dT%H:%M:%SZ' > "$STATE_FILE"
