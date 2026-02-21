#!/usr/bin/env python3
"""
Check AWS SSO session age and token expiry from cache files.
Run: python3 check-sso-session.py [--profile PROFILE_NAME]
"""
import json
import os
import sys
import glob
import subprocess
from datetime import datetime, timezone

profile = "my-profile"
for i, arg in enumerate(sys.argv):
    if arg == "--profile" and i + 1 < len(sys.argv):
        profile = sys.argv[i + 1]

cache_dir = os.path.expanduser("~/.aws/sso/cache")
now = datetime.now(timezone.utc)

if not os.path.isdir(cache_dir):
    print(f"Cache directory not found: {cache_dir}")
    print("Run 'aws sso login --profile <profile>' first.")
    sys.exit(1)

print("=== AWS SSO Token Cache ===\n")

for f in sorted(glob.glob(os.path.join(cache_dir, "*.json"))):
    name = os.path.basename(f)
    try:
        with open(f) as fh:
            data = json.load(fh)
    except Exception:
        continue

    mtime = datetime.fromtimestamp(os.path.getmtime(f), tz=timezone.utc)
    age = now - mtime

    print(f"  {name}")
    print(f"    Modified:      {mtime.strftime('%Y-%m-%d %H:%M:%S UTC')} ({age.total_seconds()/3600:.1f}h ago)")

    if "expiresAt" in data:
        exp = data["expiresAt"].replace("Z", "+00:00")
        exp_dt = datetime.fromisoformat(exp)
        remaining = exp_dt - now
        if remaining.total_seconds() > 0:
            print(f"    Expires:       {exp_dt.strftime('%Y-%m-%d %H:%M:%S UTC')} ({remaining.total_seconds()/3600:.1f}h left)")
        else:
            print(f"    EXPIRED:       {exp_dt.strftime('%Y-%m-%d %H:%M:%S UTC')} ({-remaining.total_seconds()/3600:.1f}h ago)")

    has_access = "accessToken" in data
    has_refresh = "refreshToken" in data
    if has_access or has_refresh:
        tokens = []
        if has_access:
            tokens.append("accessToken")
        if has_refresh:
            tokens.append("refreshToken")
        print(f"    Tokens:        {', '.join(tokens)}")

    if "startUrl" in data:
        print(f"    SSO URL:       {data['startUrl']}")
    if "region" in data:
        print(f"    Region:        {data['region']}")
    print()

# STS probe
print("=== STS Identity Check ===\n")
result = subprocess.run(
    ["aws", "sts", "get-caller-identity", "--profile", profile],
    capture_output=True, text=True
)
if result.returncode == 0:
    ident = json.loads(result.stdout)
    print(f"  Status:  ACTIVE")
    print(f"  ARN:     {ident['Arn']}")
    print(f"  Account: {ident['Account']}")
else:
    print(f"  Status:  EXPIRED or INVALID")
    print(f"  Error:   {result.stderr.strip()}")
print()
