#!/usr/bin/env python3
"""Generate immutable artifact manifest for COS uploads."""

from __future__ import annotations

import argparse
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path


def sha256_file(file_path: Path) -> str:
    digest = hashlib.sha256()
    with file_path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app-name", required=True)
    parser.add_argument("--build-version", required=True)
    parser.add_argument("--channel", default="none")
    parser.add_argument("--git-sha", required=True)
    parser.add_argument("--input-dir", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    input_dir = Path(args.input_dir)
    output = Path(args.output)

    if not input_dir.exists():
        raise SystemExit(f"Input directory not found: {input_dir}")

    artifacts: list[dict[str, object]] = []
    base_key = f"artifacts/{args.app_name}/{args.build_version}/{args.git_sha}"
    channel = args.channel.strip()
    channel_prefix = None
    if channel and channel != "none":
        channel_prefix = channel

    for platform_dir in sorted(p for p in input_dir.iterdir() if p.is_dir()):
        platform = platform_dir.name
        files = sorted(p for p in platform_dir.rglob("*") if p.is_file())
        for file_path in files:
            relative_name = file_path.relative_to(platform_dir).as_posix()
            cos_key = f"{base_key}/{platform}/{relative_name}"
            artifact: dict[str, object] = {
                "platform": platform,
                "file_name": relative_name,
                "size": file_path.stat().st_size,
                "sha256": sha256_file(file_path),
                "cos_key": cos_key,
            }
            if channel_prefix is not None:
                artifact["channel"] = channel
                artifact["channel_cos_key"] = (
                    f"{channel_prefix}/{platform}/{relative_name}"
                )
            artifacts.append(artifact)

    manifest = {
        "app": args.app_name,
        "build_version": args.build_version,
        "git_sha": args.git_sha,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "artifact_count": len(artifacts),
        "artifacts": artifacts,
    }
    if channel_prefix is not None:
        manifest["channel"] = channel
        manifest["channel_artifacts_prefix"] = channel_prefix

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
