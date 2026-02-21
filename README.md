# aws-sso-self-healing

A self-healing AWS SSO session for headless Mac servers. A health-check script that accidentally became a keep-alive — the SSO session renews itself forever via the AWS CLI's built-in refresh token mechanism.

## How It Works

```
launchd (every 10 min)
   │
   ▼
sso-refresh.sh
   │  runs: aws sts get-caller-identity --profile <your-profile>
   ▼
AWS CLI v2
   │  "accessToken expired? I have a refreshToken."
   │  silently renews the accessToken via IAM Identity Center
   ▼
Logs "OK" — repeat forever
```

The AWS CLI stores two tokens in `~/.aws/sso/cache/`:
- `accessToken` — short-lived (1 hour)
- `refreshToken` — long-lived (~90 days)

When `aws sts get-caller-identity` runs, the CLI checks the accessToken. If expired, it silently uses the refreshToken to get a new one. Since the cron runs every 10 minutes, the accessToken never stays expired for more than a few minutes.

The refreshToken itself lasts ~90 days. When it finally expires, the script detects the failure and sends an alert (Telegram, Slack, email — your choice) with a device-code URL for re-authentication.

**Result:** One `aws sso login` gives you ~90 days of unattended SSO access.

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

## License

MIT
