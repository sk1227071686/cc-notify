#!/usr/bin/env python3
"""Validate cc-notify configuration file. Exit 0 = valid, exit 1 = invalid."""
import json
import os
import sys

CONFIG_PATH = os.path.expanduser("~/.claude/cc-notify/config.json")

REQUIRED_FIELDS = ["corpid", "corpsecret", "agentid", "proxy_url", "userid"]


def validate():
    if not os.path.exists(CONFIG_PATH):
        print(f"Config not found: {CONFIG_PATH}", file=sys.stderr)
        return False

    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            d = json.load(f)
    except json.JSONDecodeError as e:
        print(f"Invalid JSON: {e}", file=sys.stderr)
        return False
    except OSError as e:
        print(f"Cannot read config: {e}", file=sys.stderr)
        return False

    for key in REQUIRED_FIELDS:
        if key not in d or not isinstance(d[key], str) or not d[key].strip():
            print(f"Missing or empty field: {key}", file=sys.stderr)
            return False

    if not d["proxy_url"].startswith("https://"):
        print("proxy_url must start with https://", file=sys.stderr)
        return False

    if not d["agentid"].isdigit():
        print("agentid must be numeric", file=sys.stderr)
        return False

    if len(d["userid"]) > 64:
        print("userid must be 64 characters or fewer", file=sys.stderr)
        return False

    return True


if __name__ == "__main__":
    if validate():
        print("Config OK")
        sys.exit(0)
    else:
        sys.exit(1)
