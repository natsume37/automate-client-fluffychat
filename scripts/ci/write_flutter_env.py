#!/usr/bin/env python3
"""Write a safe dart-define JSON file for Flutter builds."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path


SAFE_KEYS = (
    "APP_NAME",
    "APP_ID_SUFFIX",
    "K8S_NAMESPACE",
    "API_BASE_URL",
    "MATRIX_HOMESERVER",
    "CHATBOT_BASE_URL",
    "PUSH_ANDROID_APP_KEY",
    "PUSH_ANDROID_APP_SECRET",
    "PUSH_IOS_APP_KEY",
    "PUSH_IOS_APP_SECRET",
)

OPTIONAL_TEST_SECRET_KEYS = (
    "ALIYUN_SECRET_KEY",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Generate a dart-define JSON file from allowlisted environment "
            "variables. Sensitive secrets are intentionally excluded."
        ),
    )
    parser.add_argument("--output", required=True, help="Output JSON file path")
    parser.add_argument(
        "--require",
        action="append",
        default=[],
        help="Environment variable name that must be present and non-empty",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    include_test_secrets = (
        os.environ.get("ALLOW_CLIENT_TEST_SECRETS", "").strip().lower() == "true"
    )

    allowed_keys = list(SAFE_KEYS)
    if include_test_secrets:
        allowed_keys.extend(OPTIONAL_TEST_SECRET_KEYS)

    values = {}
    for key in allowed_keys:
        value = os.environ.get(key, "").strip()
        if value:
            values[key] = value

    missing = [key for key in args.require if not values.get(key)]
    if missing:
        raise SystemExit(
            "Missing required Flutter build config: " + ", ".join(sorted(missing))
        )

    output_path = Path(args.output)
    output_path.write_text(
        json.dumps(values, indent=2, ensure_ascii=True) + "\n",
        encoding="utf-8",
    )

    key_list = ", ".join(sorted(values)) if values else "(none)"
    print(f"Wrote {len(values)} safe build config keys to {output_path}")
    print(f"Included keys: {key_list}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
