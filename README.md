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
┌──────────┐  every 10 min  ┌──────────────┐
│  launchd ├───────────────►│ sso-refresh.sh│
└──────────┘                └──────┬───────┘
                                   │
                    runs: aws sts get-caller-identity
                                   │
                                   ▼
                          ┌─────────────────┐
                          │   AWS CLI v2     │
                          │                 │
                          │ 1. Read cache   │
                          │ 2. accessToken  │◄─── expired?
                          │    expired?     │
                          │       │         │
                          │    YES│    NO   │
                          │       ▼         │
                          │ 3. Exchange     │
                          │    refreshToken │──► SSO OIDC endpoint
                          │    for new      │◄── new accessToken
                          │    accessToken  │
                          │       │         │
                          │ 4. Write new    │
                          │    token to     │
                          │    cache file   │
                          │       │         │
                          │ 5. Call STS     │──► AWS STS
                          │    with fresh   │◄── caller identity
                          │    token        │
                          └─────────────────┘
                                   │
                                   ▼
                            Logs "OK" ✅
                          (repeat forever)
```

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
aws sso login --profile my-profile
```

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

- Telegram bot API
- Slack webhook
- Email via `sendmail` / `msmtp`
- Any HTTP webhook
- Desktop notification (`osascript` on macOS, `notify-send` on Linux)

## Files

| File | Description |
|------|-------------|
| `sso-refresh.sh` | The refresh/health-check script |
| `com.sso-self-healing.plist` | macOS launchd config (every 10 min) |
| `sso-refresh.service` | Linux systemd service unit |
| `sso-refresh.timer` | Linux systemd timer (every 10 min) |
| `check-sso-session.py` | Token expiry checker (optional diagnostic) |

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

### If You Suspect a Token Leak

```bash
# 1. Invalidate local tokens immediately
aws sso logout

# 2. Go to AWS Console → IAM Identity Center → Users → Active sessions → Revoke all

# 3. Re-login
aws sso login --profile my-profile
```

### Best Practices

- Use a **least-privilege role** — only grant the permissions your automation actually needs
- Keep `~/.aws/sso/cache/` readable only by your user (`chmod 700 ~/.aws/sso/cache`)
- Monitor CloudTrail for unexpected API calls from your SSO role
- Set up CloudWatch alarms for unusual Bedrock/AgentCore usage patterns
- Consider IP-based conditions in your IAM role's trust policy if your server has a static IP

## License

MIT
