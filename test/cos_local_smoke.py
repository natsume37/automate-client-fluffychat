#!/usr/bin/env python3
"""Tencent COS smoke test using env.json or environment variables.

This script performs:
1. PUT a small object
2. GET the same object
3. DELETE the object

It uploads a temporary small object and deletes it after verification.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


def _percent_encode(value: str) -> str:
    return urllib.parse.quote(value, safe="-_.~")


def _canonical_kv(items: dict[str, str]) -> tuple[str, str]:
    normalized = {
        _percent_encode(str(key).lower()): _percent_encode(str(value).strip())
        for key, value in items.items()
    }
    ordered = sorted(normalized.items())
    names = ";".join(key for key, _ in ordered)
    content = "&".join(f"{key}={value}" for key, value in ordered)
    return names, content


def _build_auth(
    *,
    secret_id: str,
    secret_key: str,
    method: str,
    path: str,
    query: dict[str, str],
    headers: dict[str, str],
    expires: int = 600,
) -> str:
    start = int(time.time()) - 5
    end = start + expires
    sign_time = f"{start};{end}"

    header_list, http_headers = _canonical_kv(headers)
    param_list, http_parameters = _canonical_kv(query)
    format_string = (
        f"{method.lower()}\n"
        f"{path}\n"
        f"{http_parameters}\n"
        f"{http_headers}\n"
    )
    hashed_format = hashlib.sha1(format_string.encode("utf-8")).hexdigest()
    string_to_sign = f"sha1\n{sign_time}\n{hashed_format}\n"
    sign_key = hmac.new(
        secret_key.encode("utf-8"),
        sign_time.encode("utf-8"),
        hashlib.sha1,
    ).hexdigest()
    signature = hmac.new(
        sign_key.encode("utf-8"),
        string_to_sign.encode("utf-8"),
        hashlib.sha1,
    ).hexdigest()
    return (
        f"q-sign-algorithm=sha1&q-ak={secret_id}&q-sign-time={sign_time}"
        f"&q-key-time={sign_time}&q-header-list={header_list}"
        f"&q-url-param-list={param_list}&q-signature={signature}"
    )


def _request(
    *,
    secret_id: str,
    secret_key: str,
    bucket: str,
    region: str,
    method: str,
    object_key: str,
    body: bytes | None = None,
    query: dict[str, str] | None = None,
) -> tuple[int, bytes]:
    query = query or {}
    host = f"{bucket}.cos.{region}.myqcloud.com"
    path = "/" + object_key.lstrip("/")
    url = f"https://{host}{path}"
    if query:
        url += "?" + urllib.parse.urlencode(query)

    headers = {"Host": host}
    authorization = _build_auth(
        secret_id=secret_id,
        secret_key=secret_key,
        method=method,
        path=path,
        query=query,
        headers=headers,
    )
    req = urllib.request.Request(url=url, method=method, data=body)
    req.add_header("Host", host)
    req.add_header("Authorization", authorization)
    if body is not None:
        req.add_header("Content-Length", str(len(body)))

    with urllib.request.urlopen(req, timeout=20) as response:
        return response.status, response.read()


def main() -> int:
    env_path = Path("env.json")
    if env_path.exists():
        config = json.loads(env_path.read_text(encoding="utf-8"))
        secret_id = config["secretId"]
        secret_key = config["secretKey"]
        bucket = config["Bucket"]
        region = config["Region"]
    else:
        secret_id = os.environ.get("COS_SECRET_ID", "").strip()
        secret_key = os.environ.get("COS_SECRET_KEY", "").strip()
        bucket = os.environ.get("COS_BUCKET", "").strip()
        region = os.environ.get("COS_REGION", "").strip()
        missing = [
            name
            for name, value in (
                ("COS_SECRET_ID", secret_id),
                ("COS_SECRET_KEY", secret_key),
                ("COS_BUCKET", bucket),
                ("COS_REGION", region),
            )
            if not value
        ]
        if missing:
            print(
                "Missing COS config. Provide env.json or env vars: "
                + ", ".join(missing),
                file=sys.stderr,
            )
            return 1

    stamp = int(time.time())
    prefix = os.environ.get("COS_TEST_PREFIX", "codex-local-test").strip("/") or "codex-local-test"
    object_key = f"{prefix}/{stamp}.txt"
    payload = f"bucket smoke test {stamp}\n".encode("utf-8")

    print(f"Bucket: {bucket}")
    print(f"Region: {region}")
    print(f"Object key: {object_key}")

    try:
        put_status, _ = _request(
            secret_id=secret_id,
            secret_key=secret_key,
            bucket=bucket,
            region=region,
            method="PUT",
            object_key=object_key,
            body=payload,
        )
        print(f"PUT ok: HTTP {put_status}")

        get_status, get_body = _request(
            secret_id=secret_id,
            secret_key=secret_key,
            bucket=bucket,
            region=region,
            method="GET",
            object_key=object_key,
        )
        print(f"GET ok: HTTP {get_status}, bytes={len(get_body)}")
        if get_body != payload:
            print("Downloaded payload mismatch", file=sys.stderr)
            return 2

        delete_status, _ = _request(
            secret_id=secret_id,
            secret_key=secret_key,
            bucket=bucket,
            region=region,
            method="DELETE",
            object_key=object_key,
        )
        print(f"DELETE ok: HTTP {delete_status}")
        return 0
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        print(f"HTTP error: {exc.code}", file=sys.stderr)
        print(body[:1000], file=sys.stderr)
        return 3
    except Exception as exc:  # pragma: no cover - local smoke diagnostics
        print(f"Request failed: {exc}", file=sys.stderr)
        return 4


if __name__ == "__main__":
    raise SystemExit(main())
