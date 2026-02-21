#!/bin/bash
# =============================================================================
# sso-kill-switch.sh — Emergency SSO session revocation
# =============================================================================
# Run this immediately if you suspect token leakage.
# It invalidates local tokens, kills the server-side SSO session,
# and stops the self-healing cron to prevent re-activation.
#
# Usage:
#   ./sso-kill-switch.sh                    # uses default profile (my-profile)
#   ./sso-kill-switch.sh bedrock-only       # specify profile
# =============================================================================

set -euo pipefail

PROFILE="${1:-my-profile}"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo ""
echo -e "${RED}╔══════════════════════════════════════════════╗${NC}"
echo -e "${RED}║  🚨 SSO EMERGENCY KILL SWITCH               ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════╝${NC}"
echo ""

# Step 1: Stop the self-healing cron (prevent it from refreshing)
echo -e "${YELLOW}[1/5] Stopping self-healing cron...${NC}"
if launchctl list | grep -q sso-self-healing 2>/dev/null; then
    launchctl unload ~/Library/LaunchAgents/com.sso-self-healing.plist 2>/dev/null && \
        echo -e "  ${GREEN}✓ launchd job unloaded${NC}" || \
        echo -e "  ${YELLOW}⚠ Could not unload (may need manual removal)${NC}"
elif systemctl --user is-active sso-refresh.timer &>/dev/null; then
    systemctl --user stop sso-refresh.timer && \
        echo -e "  ${GREEN}✓ systemd timer stopped${NC}" || \
        echo -e "  ${YELLOW}⚠ Could not stop timer${NC}"
else
    echo -e "  ${YELLOW}⚠ No cron job found (already stopped or different name)${NC}"
fi

# Step 2: Invalidate local tokens + server-side session
echo -e "${YELLOW}[2/5] Logging out of SSO (invalidates server-side session)...${NC}"
aws sso logout 2>/dev/null && \
    echo -e "  ${GREEN}✓ SSO logout successful${NC}" || \
    echo -e "  ${YELLOW}⚠ SSO logout failed (tokens may already be invalid)${NC}"

# Step 3: Nuke local token cache
echo -e "${YELLOW}[3/5] Deleting local SSO token cache...${NC}"
CACHE_DIR="$HOME/.aws/sso/cache"
if [ -d "$CACHE_DIR" ]; then
    TOKEN_COUNT=$(find "$CACHE_DIR" -name "*.json" | wc -l | tr -d ' ')
    rm -f "$CACHE_DIR"/*.json
    echo -e "  ${GREEN}✓ Deleted $TOKEN_COUNT cached token files${NC}"
else
    echo -e "  ${YELLOW}⚠ Cache directory not found${NC}"
fi

# Step 4: Verify session is dead
echo -e "${YELLOW}[4/5] Verifying session is terminated...${NC}"
if aws sts get-caller-identity --profile "$PROFILE" &>/dev/null; then
    echo -e "  ${RED}✗ WARNING: Session still active! STS credentials may be cached.${NC}"
    echo -e "  ${RED}  → Go to IAM Identity Center console and revoke active sessions${NC}"
    echo -e "  ${RED}  → Existing role sessions persist until permission set duration expires${NC}"
else
    echo -e "  ${GREEN}✓ Session is dead${NC}"
fi

# Step 5: Guidance
echo ""
echo -e "${YELLOW}[5/5] Manual steps required:${NC}"
echo ""
echo "  1. Go to AWS Console → IAM Identity Center → Users"
echo "     → [your user] → Active sessions → Revoke all"
echo ""
echo "  2. If the attacker already exchanged tokens for STS credentials,"
echo "     those persist until the permission set session duration expires."
echo "     Check: IAM Identity Center → Permission sets → [your set] → Session duration"
echo ""
echo "  3. Check CloudTrail for unauthorized API calls:"
echo "     aws cloudtrail lookup-events \\"
echo "       --lookup-attributes AttributeKey=EventSource,AttributeValue=bedrock.amazonaws.com \\"
echo "       --start-time \$(date -u -v-24H '+%Y-%m-%dT%H:%M:%SZ') \\"
echo "       --region us-east-1 --profile admin"
echo ""
echo "  4. When ready to restore access:"
echo "     aws sso login --profile $PROFILE"
echo "     launchctl load ~/Library/LaunchAgents/com.sso-self-healing.plist"
echo ""
echo -e "${GREEN}Kill switch complete.${NC}"
echo ""
