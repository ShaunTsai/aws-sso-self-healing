# aws-sso-self-healing

A self-healing AWS SSO session for headless Mac servers. A health-check script that accidentally became a keep-alive — the SSO session renews itself forever via the AWS CLI's built-in refresh token mechanism.

## Agent Prompt (paste this to your AI agent / IDE)

> 請閱讀這份文件，協助我在這台機器上配置 AWS SSO 自動續命（Self-Healing SSO），目標是讓 SSO session 在無人值守的情況下自動保持存活約 90 天，過期時自動發送通知提醒重新登入：
> https://github.com/ShaunTsai/aws-sso-self-healing

## Why Does This Work? (The Mechanism)

When you `aws sso login`, the AWS CLI stores **two** tokens in `~/.aws/sso/cache/`:

| Token | Type | Lifetime | Purpose |
|-------|------|----------|---------|
| `accessToken` | OAuth2 JWT | ~1 hour | Used by CLI to call AWS APIs |
| `refreshToken` | Opaque | ~90 days | Used to silently get a new accessToken |

The key insight: **every time the AWS CLI makes any API call**, it checks the accessToken first. If it's expired, the CLI silently performs an [OAuth2 refresh token exchange](https://datatracker.ietf.org/doc/html/rfc6749#section-6) — no browser, no human, no output. It sends the refreshToken to the SSO OIDC endpoint and gets back a fresh accessToken. This all happens internally before the actual API call.

So when our cron job runs `aws sts get-caller-identity` every 10 minutes:

```
┌─────────────────────────────────────────────────────────────────────┐
│  launchd / systemd (every 10 min)                                   │
│  sso-refresh.sh                                                     │
└──────────────────────┬──────────────────────────────────────────────┘
                       │
                       ▼
              ┌─────────────────┐
              │ Lock file exist? │
              │ Process alive?   │
              └────┬────────┬───┘
                   │YES     │NO
                   ▼        ▼
              ┌────────┐  ┌──────────────────────────────┐
              │ SKIP   │  │ aws sts get-caller-identity   │
              │ exit 0 │  │ --profile my-profile          │
              └────────┘  └──────────┬───────────────────┘
                                     │
                          ┌──────────┴──────────┐
                          │                     │
                        SUCCESS               FAIL
                          │                     │
                          ▼                     ▼
                    ┌──────────┐    ┌────────────────────┐
                    │ log "OK" │    │ Token expired?      │
                    │ exit 0   │    └───┬────────────┬───┘
                    └──────────┘        │YES         │NO
                                        ▼            ▼
                    ┌───────────────────────┐  ┌──────────────┐
                    │ aws sso login         │  │ log ERROR    │
                    │ --use-device-code     │  │ exit 1       │
                    │ --no-browser          │  └──────────────┘
                    │ (BACKGROUND, polling) │
                    └───────────┬───────────┘
                                │
                         ┌──────┴──────┐
                         │ Write lock  │
                         │ Sleep 5s    │
                         │ Extract URL │
                         └──────┬──────┘
                                │
                                ▼
                    ┌───────────────────────┐
                    │ Alert → phone/Slack   │
                    │ 🔑 Approve from phone │
                    │ https://...?user_code │
                    └───────────┬───────────┘
                                │
                                │  (background process keeps polling)
                                │
                    ┌───────────┴───────────┐
                    │                       │
                 APPROVED              TIMEOUT/FAIL
                    │                       │
                    ▼                       ▼
          ┌──────────────────┐   ┌────────────────────┐
          │ Tokens written   │   │ Lock removed        │
          │ to ~/.aws/sso/   │   │ Next cron run will  │
          │ cache/           │   │ retry fresh         │
          │                  │   └────────────────────┘
          │ Alert:           │
          │ ✅ SSO renewed   │
          │                  │
          │ Remove lock      │
          └──────────────────┘
                    │
                    │  (next cron run, 10 min later)
                    ▼
          ┌──────────────────┐
          │ STS probe → OK   │  ← silent refresh via refreshToken
          │ log "OK"         │    (repeats for ~90 days)
          └──────────────────┘
```

99% of runs just hit the "OK" path — the STS probe triggers the AWS CLI's internal refresh token exchange silently. You only see an alert when the refresh token dies (~every 90 days).

**This is NOT creating new IAM access keys.** It's refreshing an OAuth2 access token — a completely different mechanism. The refreshToken acts like a long-lived "remember me" cookie that lets the CLI get new short-lived tokens without human interaction.

**When does it actually die?** When the refreshToken expires (~90 days). At that point, the CLI can't refresh anymore, the STS call fails, and the script sends you an alert to re-login.

**Result:** One `aws sso login` → ~90 days of unattended SSO access.

## Prerequisites

- macOS (uses launchd; adapt for systemd on Linux)
- AWS CLI v2
- An AWS SSO (IAM Identity Center) configuration in `~/.aws/config`
- A notification method for expiry alerts (examples use a generic webhook)

## Setup

### 1. Configure AWS SSO Profile

Add to `~/.aws/config`:

```ini
[sso-session my-sso]
sso_start_url = https://YOUR_SSO_START_URL
sso_region = us-east-1
sso_registration_scopes = sso:account:access

[profile my-profile]
sso_session = my-sso
sso_account_id = YOUR_ACCOUNT_ID
sso_role_name = YOUR_ROLE_NAME
region = us-east-1
```

### 2. Login Once

```bash
# If you have a browser on the machine:
aws sso login --profile my-profile

# If headless / remote (no browser) — use device-code flow:
aws sso login --profile my-profile --use-device-code --no-browser
```

The `--use-device-code` flag uses the [OAuth 2.0 Device Authorization Grant](https://datatracker.ietf.org/doc/html/rfc8628) instead of the default PKCE flow. This prints a URL like:

```
https://your-sso.awsapps.com/start/#/device?user_code=ABCD-EFGH
```

You can open this URL on **any device** (phone, tablet, another computer) to complete the login. See [Remote Login from Phone](#remote-login-from-phone-device-code-flow) for the full workflow.

This creates both the accessToken and refreshToken in `~/.aws/sso/cache/`.

### 3. Install the Refresh Script

```bash
mkdir -p ~/.config/sso-self-healing/logs
curl -o ~/.config/sso-self-healing/sso-refresh.sh \
  https://raw.githubusercontent.com/ShaunTsai/aws-sso-self-healing/main/sso-refresh.sh
chmod +x ~/.config/sso-self-healing/sso-refresh.sh
```

Edit `~/.config/sso-self-healing/sso-refresh.sh` and set `PROFILE` to your profile name.

### 4. Install the launchd Plist (macOS)

```bash
curl -o ~/Library/LaunchAgents/com.sso-self-healing.plist \
  https://raw.githubusercontent.com/ShaunTsai/aws-sso-self-healing/main/com.sso-self-healing.plist
```

Edit the plist and replace `YOUR_USERNAME` with your macOS username.

Load it:

```bash
launchctl load ~/Library/LaunchAgents/com.sso-self-healing.plist
```

### 5. Verify

```bash
# Check it's running
launchctl list | grep sso-self-healing

# Check the log
tail -5 ~/.config/sso-self-healing/logs/sso-refresh.log
```


## For Linux (systemd)

Use the included `sso-refresh.service` and `sso-refresh.timer` instead of launchd:

```bash
mkdir -p ~/.config/sso-self-healing/logs
cp sso-refresh.sh ~/.config/sso-self-healing/
chmod +x ~/.config/sso-self-healing/sso-refresh.sh

cp sso-refresh.service sso-refresh.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now sso-refresh.timer
```

## Check Session Status

```bash
# Quick check
aws sts get-caller-identity --profile my-profile

# Detailed token info
python3 check-sso-session.py
```

## How Long Does It Last?

| Token | Lifetime | Renewed By |
|-------|----------|------------|
| accessToken | ~1 hour | AWS CLI (automatic, using refreshToken) |
| refreshToken | ~90 days | Human login (`aws sso login`) |

The self-healing loop keeps the accessToken alive indefinitely. You only need to re-login when the refreshToken expires (~90 days).

## Alert Customization

The script calls a `send_alert` function when SSO expires. Edit `sso-refresh.sh` to use your preferred notification method:

- OpenClaw Telegram (`openclaw message send`)
- Telegram bot API
- Slack webhook
- Email via `sendmail` / `msmtp`
- Any HTTP webhook
- Desktop notification (`osascript` on macOS, `notify-send` on Linux)

### Background Polling (Critical Design Decision)

When the refresh token expires, the script starts `aws sso login --use-device-code --no-browser` as a **background process**. This is critical because:

1. The device-code flow prints a URL, then **polls** the SSO OIDC endpoint every few seconds waiting for user approval
2. If the process is killed (e.g., by a timeout), the polling stops and the approval URL becomes a dead link
3. The background process keeps polling for up to ~10 minutes (aligned with the cron interval)
4. A **lock file** prevents the next cron run from starting a duplicate login flow
5. Once approved, the background process writes tokens to cache and sends a success alert

Previous versions of this script used a timeout that killed the login process after 20 seconds — this caused the script to spam a new (dead) URL every 10 minutes because the approval never completed.

## Remote Login from Phone (Device Code Flow)

When the SSO refresh token expires (~90 days), you need to re-authenticate. On a headless server with no monitor, you can't open a browser locally. The `--use-device-code` flag solves this.

### How It Works

The default `aws sso login` uses PKCE (Proof Key for Code Exchange), which redirects to `http://localhost:PORT/...` — this only works if you have a browser on the same machine. The `--use-device-code` flag switches to the [Device Authorization Grant (RFC 8628)](https://datatracker.ietf.org/doc/html/rfc8628), which generates a URL that works from **any device on any network**.

```
┌─────────────────────────────────────────────────────────────────┐
│  Headless Mac Server                                            │
│                                                                 │
│  sso-refresh.sh detects expired token                           │
│       │                                                         │
│       ▼                                                         │
│  aws sso login --use-device-code --no-browser                   │
│       │                                                         │
│       ▼                                                         │
│  Prints: https://your-sso.awsapps.com/start/#/device?user_code=XXXX │
│       │                                                         │
│       ▼                                                         │
│  Sends URL to Telegram / Slack / email                          │
└───────────────────────┬─────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────────┐
│  Your Phone (anywhere in the world)                             │
│                                                                 │
│  1. Receive notification with URL                               │
│  2. Long-press URL → Open in Safari/Chrome                      │
│  3. Browser auto-fills saved SSO password (Face ID / Touch ID)  │
│  4. Tap "Approve"                                               │
│  5. Done — SSO session renewed on the server                    │
└─────────────────────────────────────────────────────────────────┘
```

### PKCE vs Device Code

| | PKCE (default) | Device Code (`--use-device-code`) |
|---|---|---|
| Redirect URL | `http://localhost:PORT/...` | `https://sso.awsapps.com/start/#/device?user_code=XXXX` |
| Requires local browser | Yes | No |
| Works from phone | No | Yes |
| Works remotely | No | Yes |
| AWS CLI flag | (none) | `--use-device-code --no-browser` |
| OAuth2 spec | [RFC 7636](https://datatracker.ietf.org/doc/html/rfc7636) | [RFC 8628](https://datatracker.ietf.org/doc/html/rfc8628) |

### Phone Setup (iOS / Android)

For the smoothest experience, save your SSO credentials in your phone's password manager:

1. Open `https://your-sso.awsapps.com/start` in Safari (iOS) or Chrome (Android) on your phone
2. Log in manually once and save the password when prompted
3. Enable Face ID / Touch ID for autofill in Settings → Passwords

Now when you receive a device-code URL via Telegram:
1. Long-press the URL → "Open in Safari"
2. Face ID auto-fills your SSO credentials
3. Tap "Allow" to approve the device
4. The server's SSO session is renewed — no need to touch the server

### sso-refresh.sh Integration

The included `sso-refresh.sh` already handles this automatically. When the SSO session expires:

1. The script detects the failure via `aws sts get-caller-identity`
2. Runs `aws sso login --profile PROFILE --use-device-code --no-browser`
3. Extracts the device URL (the one with `user_code=` parameter)
4. Sends it via your configured alert method (Telegram, Slack, etc.)
5. Waits for you to approve on your phone

Customize the `send_alert()` function in `sso-refresh.sh` for your notification method.

### Requirements

- AWS CLI v2.22.0+ (device code flow support)
- `--no-browser` flag prevents the CLI from trying to open a local browser
- Your SSO IdP must support the device authorization grant (AWS IAM Identity Center does by default)

## Files

| File | Description |
|------|-------------|
| `sso-refresh.sh` | The refresh/health-check script |
| `sso-kill-switch.sh` | Emergency token revocation (run if tokens leaked) |
| `alert-poller.sh` | GuardDuty finding poller → Telegram/Slack (every 15 min) |
| `ip-sync.sh` | Auto-update EventBridge rule when public IP changes (every 30 min) |
| `com.sso-self-healing.plist` | macOS launchd config (every 10 min) |
| `sso-refresh.service` | Linux systemd service unit |
| `sso-refresh.timer` | Linux systemd timer (every 10 min) |
| `check-sso-session.py` | Token expiry checker (optional diagnostic) |

## Use Case: OpenClaw + AWS Bedrock (Headless AI Agent Server)

This project was originally built to solve a specific security problem with [OpenClaw](https://github.com/openclaw/openclaw) — an open-source AI agent that runs as a daemon on a home server, connecting to AWS Bedrock for model inference.

### The Problem

OpenClaw is an AI agent with full shell access. Security researchers have demonstrated that AI agents can be tricked via prompt injection into reading `~/.aws/credentials` and leaking static IAM access keys:

- [Cisco Blog — AI agents security nightmare](https://blogs.cisco.com/ai/personal-ai-agents-like-openclaw-are-a-security-nightmare)
- [Cyera Research — OpenClaw security saga](https://www.cyera.com/research-labs/the-openclaw-security-saga-how-ai-adoption-outpaced-security-boundaries)

If you store static IAM keys (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`) on the same machine as OpenClaw, a prompt injection attack could exfiltrate those keys. Static keys never expire — the attacker has permanent access until you manually rotate them.

### The Solution

Replace static IAM keys with AWS SSO + self-healing refresh:

1. **No static keys on disk** — SSO uses short-lived OAuth2 tokens, not permanent IAM credentials
2. **Scoped role** — The SSO role only has `bedrock:InvokeModel*` permissions (no admin, no S3, no EC2)
3. **Auto-expiring** — Even if tokens are leaked, the accessToken dies in 1 hour and the refreshToken in ~90 days
4. **Self-healing** — The cron job keeps the session alive so the agent never loses Bedrock access
5. **Revocable** — You can kill all sessions instantly from the AWS Console

### How OpenClaw Uses It

```
┌──────────────────────────────────────────────────────────────┐
│  Mac Home Server                                             │
│                                                              │
│  ┌─────────────┐     ┌──────────────────┐                    │
│  │  OpenClaw    │     │  launchd cron    │                    │
│  │  Gateway     │     │  (every 10 min)  │                    │
│  │             │     │        │         │                    │
│  │  AWS_PROFILE │     │        ▼         │                    │
│  │  =bedrock-   │     │  sso-refresh.sh  │                    │
│  │   only       │     │  (health-check   │                    │
│  │             │     │   = keep-alive)  │                    │
│  └──────┬──────┘     └────────┬─────────┘                    │
│         │                     │                              │
│         │  ~/.aws/sso/cache/  │                              │
│         │  (OAuth2 tokens)    │                              │
│         └─────────┬───────────┘                              │
│                   │                                          │
└───────────────────┼──────────────────────────────────────────┘
                    │
                    ▼
          AWS Bedrock (us-east-1)
          └─ InvokeModel (Qwen, Claude, etc.)
```

The OpenClaw gateway's `start-gateway.sh` sets `AWS_PROFILE=bedrock-only`, which tells the AWS CLI to use SSO credentials. The self-healing cron runs alongside the gateway, ensuring the SSO session never expires while the server is running.

### OpenClaw Configuration

In `~/.openclaw/openclaw.json`, configure Bedrock as the model provider:

```json
{
  "models": {
    "providers": {
      "bedrock": {
        "baseUrl": "https://bedrock-runtime.us-east-1.amazonaws.com",
        "api": "bedrock-converse-stream",
        "models": [
          {
            "id": "your-model-id",
            "name": "Your Model Name"
          }
        ]
      }
    }
  }
}
```

In the gateway start script, export the SSO profile:

```bash
#!/bin/bash
export AWS_PROFILE=bedrock-only
exec openclaw gateway start
```

No `AWS_ACCESS_KEY_ID`. No `AWS_SECRET_ACCESS_KEY`. Just SSO.

## Security: Pros and Cons

### Pros — No Static API Keys

This approach uses AWS SSO (IAM Identity Center) exclusively. There are **zero long-lived IAM access keys** anywhere:

- No `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` stored on disk
- No static credentials in environment variables, `.env` files, or config
- No Keychain / secrets manager needed for AWS credentials
- All credentials are short-lived OAuth2 tokens managed by the AWS CLI
- If the machine is compromised, there are no permanent keys to steal — only tokens that expire

Compare this to the traditional approach of storing IAM access keys in `~/.aws/credentials`, which never expire and give persistent access until manually rotated.

### Cons — Tokens Can Still Be Leaked

The OAuth2 tokens stored in `~/.aws/sso/cache/` can be extracted if an attacker gains access to the machine:

| Token | If Leaked | Severity | Lifetime |
|-------|-----------|----------|----------|
| `accessToken` | Attacker can call AWS APIs with your role's permissions | Medium | ~1 hour (then useless) |
| `refreshToken` | Attacker can silently generate new accessTokens without login | High | ~90 days |

**However, the damage is controllable:**

1. **Scoped role:** Use a least-privilege IAM role (e.g., only `bedrock:InvokeModel*`). Even if tokens leak, the attacker can only do what the role allows — no admin access, no infrastructure changes.

2. **Time-limited:** Unlike static IAM keys (which last forever), the refreshToken expires in ~90 days and the accessToken in ~1 hour. The blast window is finite.

3. **Revocable:** You can instantly kill a leaked session from the AWS Console:
   - IAM Identity Center → Users → [your user] → Active sessions → **Revoke**
   - Or locally: `aws sso logout` to invalidate cached tokens

4. **No lateral movement:** SSO tokens are scoped to a single role in a single account. They can't be used to assume other roles or access other accounts (unless the role explicitly allows it).

5. **Auditable:** All API calls made with SSO credentials show up in CloudTrail with the SSO user identity, making it easy to detect unauthorized usage.

### If You Suspect a Token Leak — Kill Switch

Use the included `sso-kill-switch.sh` for immediate emergency revocation:

```bash
# Download and run
curl -o /tmp/sso-kill-switch.sh \
  https://raw.githubusercontent.com/ShaunTsai/aws-sso-self-healing/main/sso-kill-switch.sh
chmod +x /tmp/sso-kill-switch.sh
/tmp/sso-kill-switch.sh my-profile
```

The kill switch does 5 things in order:

1. **Stops the self-healing cron** — prevents the refresh loop from re-activating the session
2. **Calls `aws sso logout`** — invalidates the server-side SSO session
3. **Deletes local token cache** — removes all `~/.aws/sso/cache/*.json` files
4. **Verifies the session is dead** — confirms STS calls fail
5. **Prints manual steps** — for revoking active IAM role sessions in the console

> **Important:** Even after killing the SSO session, any IAM role sessions that were already created (via STS AssumeRole) will persist until the permission set's session duration expires (default: 1 hour). To kill those too, you must revoke active sessions in the IAM Identity Center console.

### Proactive Leak Detection

You don't have to wait until you notice a leak. AWS offers several services that can detect compromised credentials automatically:

#### Option 1: Amazon GuardDuty (recommended — easiest)

GuardDuty monitors CloudTrail logs and detects anomalous credential usage automatically. Relevant finding types:

| Finding | What It Detects |
|---------|-----------------|
| `AttackSequence:IAM/CompromisedCredentials` | Sequence of suspicious API calls using potentially compromised credentials |
| `UnauthorizedAccess:IAMUser/ConsoleLoginSuccess.B` | Successful console login from unusual location |
| `Discovery:IAMUser/AnomalousBehavior` | API calls that deviate from the user's established baseline |

Enable it:
```bash
aws guardduty create-detector --enable --profile admin
```

GuardDuty sends findings to EventBridge, so you can route alerts to SNS → email/Slack/Telegram.

#### Option 2: CloudTrail + EventBridge (DIY — IP-based)

Create an EventBridge rule that fires when Bedrock API calls come from an IP that isn't your home server:

```json
{
  "source": ["aws.bedrock"],
  "detail-type": ["AWS API Call via CloudTrail"],
  "detail": {
    "eventSource": ["bedrock.amazonaws.com"],
    "sourceIPAddress": [{ "anything-but": ["YOUR_HOME_IP"] }]
  }
}
```

Route this to an SNS topic → Telegram/Slack/email. Any Bedrock call from a non-home IP triggers an alert.

#### Option 3: CloudTrail Insights (anomaly detection)

CloudTrail Insights automatically detects unusual API call volume. If someone starts hammering InvokeModel with your leaked tokens, Insights will flag the spike:

```bash
# Enable Insights on your trail
aws cloudtrail put-insight-selectors \
  --trail-name my-trail \
  --insight-selectors '[{"InsightType": "ApiCallRateInsight"}, {"InsightType": "ApiErrorRateInsight"}]' \
  --profile admin
```

#### Option 4: Local file integrity monitoring

Monitor the SSO cache files for unexpected reads by other processes:

```bash
# macOS: use OpenBSM audit or fs_usage
sudo fs_usage -f filesys | grep sso/cache

# Linux: use inotifywait
inotifywait -m -r ~/.aws/sso/cache/ -e access
```

This catches a compromised agent or process trying to read your tokens in real-time.

### Best Practices

- Use a **least-privilege role** — only grant the permissions your automation actually needs
- Keep `~/.aws/sso/cache/` readable only by your user (`chmod 700 ~/.aws/sso/cache`)
- **Enable GuardDuty** — it's the lowest-effort way to detect compromised credentials
- Monitor CloudTrail for unexpected API calls from your SSO role
- Set up CloudWatch alarms for unusual Bedrock/AgentCore usage patterns
- Consider IP-based conditions in your IAM role's trust policy if your server has a static IP
- Shorten the permission set session duration (default 1h) to minimize the window after revocation

## Real-Time Leak Alerting (EventBridge + SNS)

GuardDuty batches findings every 15 minutes and needs days to build baselines. For instant detection, use CloudTrail → EventBridge → SNS:

```
Bedrock API call from non-home IP
  → CloudTrail event (seconds)
  → EventBridge rule match
  → SNS notification
  → Email / Telegram / Slack
```

### Setup

1. Create an SNS topic and EventBridge rule:

```bash
# Create SNS topic
aws sns create-topic --name sso-leak-alert --region us-east-1 --profile admin

# Subscribe your email
aws sns subscribe \
  --topic-arn arn:aws:sns:us-east-1:YOUR_ACCOUNT_ID:sso-leak-alert \
  --protocol email \
  --notification-endpoint your@email.com \
  --region us-east-1 --profile admin
# Confirm via the email link

# Create EventBridge rule (replace YOUR_HOME_IP)
aws events put-rule \
  --name bedrock-unusual-ip-alert \
  --event-pattern '{
    "source": ["aws.bedrock"],
    "detail-type": ["AWS API Call via CloudTrail"],
    "detail": {
      "eventSource": ["bedrock.amazonaws.com"],
      "sourceIPAddress": [{"anything-but": ["YOUR_HOME_IP"]}]
    }
  }' \
  --state ENABLED \
  --region us-east-1 --profile admin

# Attach SNS as target
aws events put-targets \
  --rule bedrock-unusual-ip-alert \
  --targets '[{"Id":"sns-leak-alert","Arn":"arn:aws:sns:us-east-1:YOUR_ACCOUNT_ID:sso-leak-alert"}]' \
  --region us-east-1 --profile admin
```

2. For Telegram alerts, install `alert-poller.sh` — it polls GuardDuty every 15 minutes and forwards HIGH/CRITICAL findings via your notification method.

### Telegram / Slack Integration

The `alert-poller.sh` script checks GuardDuty for new high-severity findings and sends them to your preferred channel. Edit the `send_notification()` function at the top of the script:

```bash
# Telegram via OpenClaw
send_notification() { openclaw message send --channel telegram -m "$1"; }

# Slack webhook
send_notification() { curl -s -X POST "$SLACK_WEBHOOK_URL" -H 'Content-type: application/json' -d "{\"text\": \"$1\"}"; }

# macOS desktop notification
send_notification() { osascript -e "display notification \"$1\" with title \"GuardDuty Alert\""; }
```

## Dynamic IP Handling (ip-sync)

If your ISP assigns a dynamic public IP (most residential connections), the EventBridge rule needs to track your current IP. The `ip-sync.sh` script handles this automatically:

```
Every 30 minutes:
  1. Check current public IP (via checkip.amazonaws.com)
  2. Compare with stored IP
  3. If changed → update EventBridge rule + notify via Telegram
```

### How Dynamic IPs Work

Your public IP is assigned by your ISP to your router's WAN interface. It doesn't matter if your Mac connects via Wi-Fi or Ethernet — the public IP is the same (it's your router's external address). Dynamic IPs typically change when:

- Your router reboots
- The ISP's DHCP lease expires (varies: hours to months)
- ISP maintenance or network changes

Most residential IPs are "sticky dynamic" — they change infrequently but unpredictably.

### Setup

```bash
mkdir -p ~/.config/sso-self-healing/logs
curl -o ~/.config/sso-self-healing/ip-sync.sh \
  https://raw.githubusercontent.com/ShaunTsai/aws-sso-self-healing/main/ip-sync.sh
chmod +x ~/.config/sso-self-healing/ip-sync.sh
```

Edit the script and set `PROFILE`, `REGION`, and `RULE_NAME`. Then add to launchd (macOS) or systemd (Linux) to run every 30 minutes.

### Verify

```bash
# Check current stored IP
cat ~/.config/sso-self-healing/.current-home-ip

# Check logs
tail -5 ~/.config/sso-self-healing/logs/ip-sync.log

# Force a check
~/.config/sso-self-healing/ip-sync.sh
```

## License

MIT
