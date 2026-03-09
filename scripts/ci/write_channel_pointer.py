#!/usr/bin/env python3
"""Write channel pointer file for dev/test/release."""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--channel", required=True, choices=["dev", "test", "release"])
    parser.add_argument("--app-name", required=True)
    parser.add_argument("--build-version", required=True)
    parser.add_argument("--git-sha", required=True)
    parser.add_argument("--manifest-key", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--source-run-id", required=True)
    parser.add_argument("--source-ref", required=True)
    args = parser.parse_args()

    pointer = {
        "channel": args.channel,
        "app": args.app_name,
        "build_version": args.build_version,
        "git_sha": args.git_sha,
        "manifest_key": args.manifest_key,
        "source_run_id": args.source_run_id,
        "source_ref": args.source_ref,
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(pointer, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
