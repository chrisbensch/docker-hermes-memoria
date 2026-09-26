#!/usr/bin/env python3
"""Validate an OpenAI-compatible embedding endpoint without exposing secrets."""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
import urllib.error
import urllib.parse
import urllib.request


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate a self-hosted OpenAI-compatible embedding model."
    )
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--dimensions", required=True, type=int)
    parser.add_argument("--api-key-file", type=pathlib.Path)
    parser.add_argument("--timeout", type=float, default=20.0)
    return parser.parse_args()


def embeddings_url(base_url: str) -> str:
    parsed = urllib.parse.urlparse(base_url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("base URL must be an absolute http:// or https:// URL")
    return base_url.rstrip("/") + "/embeddings"


def read_key(path: pathlib.Path | None) -> str:
    if path is None:
        return ""
    if not path.is_file():
        raise ValueError(f"API key file is not a regular file: {path}")
    return path.read_text(encoding="utf-8").strip()


def validate_response(payload: object, expected_dimensions: int) -> None:
    try:
        vector = payload["data"][0]["embedding"]  # type: ignore[index]
    except (KeyError, IndexError, TypeError) as exc:
        raise ValueError("response does not contain data[0].embedding") from exc
    if not isinstance(vector, list) or not all(
        isinstance(value, (int, float)) and not isinstance(value, bool)
        for value in vector
    ):
        raise ValueError("data[0].embedding is not a numeric vector")
    if len(vector) != expected_dimensions:
        raise ValueError(
            f"embedding dimension mismatch: expected {expected_dimensions}, got {len(vector)}"
        )


def main() -> int:
    args = parse_args()
    if args.dimensions <= 0:
        print("validation failed: dimensions must be a positive integer", file=sys.stderr)
        return 2
    try:
        url = embeddings_url(args.base_url)
        api_key = read_key(args.api_key_file)
        body = json.dumps(
            {"model": args.model, "input": ["gbrain setup validation"]}
        ).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        if api_key:
            headers["Authorization"] = f"Bearer {api_key}"
        request = urllib.request.Request(url, data=body, headers=headers, method="POST")
        with urllib.request.urlopen(request, timeout=args.timeout) as response:
            payload = json.load(response)
        validate_response(payload, args.dimensions)
    except urllib.error.HTTPError as exc:
        print(f"validation failed: embedding endpoint returned HTTP {exc.code}", file=sys.stderr)
        return 1
    except urllib.error.URLError as exc:
        print(f"validation failed: cannot reach embedding endpoint: {exc.reason}", file=sys.stderr)
        return 1
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"validation failed: {exc}", file=sys.stderr)
        return 1

    print(
        f"validated OpenAI-compatible embedding model {args.model} "
        f"at {args.dimensions} dimensions"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
