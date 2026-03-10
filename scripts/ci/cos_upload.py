#!/usr/bin/env python3
"""Upload one file to Tencent COS via official Python SDK."""

from __future__ import annotations

import argparse
import os
import sys
import time
from typing import Callable


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Upload one file to Tencent COS")
    parser.add_argument("--secret-id", required=True)
    parser.add_argument("--secret-key", required=True)
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--region", required=True)
    parser.add_argument("--file", required=True, dest="local_file")
    parser.add_argument("--object-key", required=True)
    parser.add_argument("--timeout", type=int, default=300, help="HTTP timeout seconds")
    parser.add_argument(
        "--part-size-mb",
        type=int,
        default=10,
        help="Multipart chunk size in MB",
    )
    parser.add_argument(
        "--max-thread",
        type=int,
        default=8,
        help="Max worker threads for multipart upload",
    )
    parser.add_argument(
        "--retry",
        type=int,
        default=5,
        help="SDK-level retry count",
    )
    parser.add_argument(
        "--http-proxy",
        default=None,
        help="HTTP proxy endpoint (for example http://1.2.3.4:8080)",
    )
    parser.add_argument(
        "--https-proxy",
        default=None,
        help="HTTPS proxy endpoint (for example http://1.2.3.4:8080)",
    )
    parser.add_argument(
        "--use-env-proxy",
        action="store_true",
        help="Read HTTP(S)_PROXY from environment",
    )
    parser.add_argument(
        "--use-accelerate-endpoint",
        action="store_true",
        help="Use COS global acceleration endpoint (bucket must enable acceleration)",
    )
    return parser.parse_args()


def _read_env_proxy(*names: str) -> str | None:
    for name in names:
        value = os.environ.get(name)
        if value:
            return value
    return None


def _build_proxies(args: argparse.Namespace) -> dict[str, str]:
    if args.http_proxy or args.https_proxy:
        proxies: dict[str, str] = {}
        if args.http_proxy:
            proxies["http"] = args.http_proxy
        if args.https_proxy:
            proxies["https"] = args.https_proxy
        return proxies

    if not args.use_env_proxy:
        return {}

    http_proxy = _read_env_proxy("HTTP_PROXY", "http_proxy")
    https_proxy = _read_env_proxy("HTTPS_PROXY", "https_proxy")
    proxies = {}
    if http_proxy:
        proxies["http"] = http_proxy
    if https_proxy:
        proxies["https"] = https_proxy
    return proxies


def _progress_printer() -> Callable[[int, int], None]:
    last_percent = -1
    last_print_ts = 0.0

    def _callback(consumed: int, total: int) -> None:
        nonlocal last_percent, last_print_ts
        if total <= 0:
            return
        percent = int(consumed * 100 / total)
        now = time.time()
        if percent >= 100 or percent >= last_percent + 5 or now - last_print_ts >= 15:
            print(f"Upload progress: {percent}% ({consumed}/{total} bytes)")
            last_percent = percent
            last_print_ts = now

    return _callback


def main() -> int:
    args = _parse_args()
    if not os.path.isfile(args.local_file):
        print(f"Local file not found: {args.local_file}", file=sys.stderr)
        return 2

    try:
        from qcloud_cos import CosConfig, CosS3Client
        from qcloud_cos.cos_exception import CosClientError, CosServiceError
    except Exception as error:
        print(f"Missing dependency for COS SDK: {error}", file=sys.stderr)
        print(
            "Install with: python3 -m pip install -U cos-python-sdk-v5",
            file=sys.stderr,
        )
        return 5

    proxies = _build_proxies(args)
    endpoint = "cos.accelerate.myqcloud.com" if args.use_accelerate_endpoint else None

    try:
        config = CosConfig(
            Region=args.region,
            SecretId=args.secret_id,
            SecretKey=args.secret_key,
            Scheme="https",
            Timeout=args.timeout,
            Proxies=proxies if proxies else {},
            Endpoint=endpoint,
            AutoSwitchDomainOnRetry=True,
        )
        client = CosS3Client(config, retry=args.retry)

        file_size = os.path.getsize(args.local_file)
        print(
            f"Start upload: local={args.local_file} size={file_size} "
            f"bucket={args.bucket} key={args.object_key}"
        )
        print(
            f"upload_file settings: part_size_mb={args.part_size_mb} "
            f"max_thread={args.max_thread} retry={args.retry} timeout={args.timeout}"
        )
        if endpoint is not None:
            print("Using acceleration endpoint: cos.accelerate.myqcloud.com")
        if proxies:
            print(
                "Using proxies: " + ", ".join(f"{k}={v}" for k, v in proxies.items())
            )

        response = client.upload_file(
            Bucket=args.bucket,
            Key=args.object_key,
            LocalFilePath=args.local_file,
            PartSize=max(1, args.part_size_mb),
            MAXThread=max(1, args.max_thread),
            EnableMD5=False,
            progress_callback=_progress_printer(),
        )
        head = client.head_object(Bucket=args.bucket, Key=args.object_key)
    except CosServiceError as error:
        print(f"COS service error: {error}", file=sys.stderr)
        try:
            print(f"status={error.get_status_code()}", file=sys.stderr)
            print(f"code={error.get_error_code()}", file=sys.stderr)
            print(f"message={error.get_error_msg()}", file=sys.stderr)
            print(f"request_id={error.get_request_id()}", file=sys.stderr)
        except Exception:
            pass
        return 3
    except CosClientError as error:
        print(f"COS client error: {error}", file=sys.stderr)
        return 4
    except Exception as error:  # pragma: no cover - CI diagnostics
        print(f"Upload failed: {error}", file=sys.stderr)
        return 4

    etag = response.get("ETag")
    remote_size = head.get("Content-Length")
    print(f"ETag: {etag}")
    print(f"HEAD Content-Length: {remote_size}")
    print(f"cos://{args.bucket}/{args.object_key}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
