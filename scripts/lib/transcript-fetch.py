#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["boto3>=1.34,<2"]
# ///
"""
transcript-fetch.py — vade-app/vade-agent-logs#64 Batch 3.

Pair to session-end-transcript-export.py. Given a session_id, fetches
the encrypted ciphertext from R2, verifies its sha256 against the
sidecar's ciphertext_sha256, decrypts via TRANSCRIPTS_AGE_IDENTITY,
gunzips, and prints the absolute path to the redacted jsonl on stdout.

Designed for the Stage-1 transcript-analyzer sub-agent
(`.claude/agents/transcript-analyzer.md` in vade-coo-memory) but
works as a standalone debugging CLI too.

Usage:
  bash scripts/lib/transcript-fetch.sh <session_id> [--meta <path>]
  bash scripts/lib/transcript-fetch.sh --cleanup <jsonl_path>

If --meta is omitted, walks vade-agent-logs/transcripts/**/<id>.meta.json
to locate the sidecar.

The decrypted jsonl is written to a per-invocation temp file under
$HOME/.vade/transcript-cache/. Callers should `--cleanup` it when
done — otherwise the OS rotates /tmp on its own schedule and the
cache directory can accumulate. Per the security review for #64,
decrypted jsonl is "strictly more revealing than session summaries"
and should not sit on disk indefinitely.

Required env (sourced from ~/.vade/coo-env by the bash wrapper):
  R2_TRANSCRIPTS_ACCESS_KEY_ID, R2_TRANSCRIPTS_SECRET_ACCESS_KEY
  TRANSCRIPTS_AGE_IDENTITY      — full AGE-SECRET-KEY-1... line
Read at run time via op (no env exposure):
  op://COO/r2-transcripts/endpoint, /bucket

Exits non-zero on any failure with a diagnostic to stderr. Unlike the
export hook (which never blocks session end), this script is invoked
synchronously by the analyzer and surfaces failure to the caller so
the caller can decide whether to retry or skip.
"""

from __future__ import annotations

import argparse
import datetime
import gzip
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

CACHE_DIR = Path.home() / ".vade" / "transcript-cache"


def _stderr(msg: str) -> None:
    sys.stderr.write(f"[transcript-fetch] {msg}\n")


def _resolve_agent_logs_dir() -> Path:
    """Mirror of session-end-transcript-export's resolver."""
    explicit = os.environ.get("VADE_AGENT_LOGS_DIR", "").strip()
    if explicit:
        p = Path(explicit)
        if p.is_dir():
            return p
        raise FileNotFoundError(f"VADE_AGENT_LOGS_DIR={p} does not exist")

    candidates = [
        Path.home() / "GitHub" / "vade-app" / "vade-agent-logs",
        Path("/home/user/vade-agent-logs"),
    ]
    for c in candidates:
        if c.is_dir():
            return c
    raise FileNotFoundError(
        "vade-agent-logs working tree not found; tried "
        + ", ".join(str(c) for c in candidates)
    )


def _find_meta(session_id: str) -> Path:
    """Walk vade-agent-logs/transcripts/**/<id>.meta.json."""
    root = _resolve_agent_logs_dir() / "transcripts"
    if not root.is_dir():
        raise FileNotFoundError(f"transcripts dir missing: {root}")
    matches = list(root.glob(f"**/{session_id}.meta.json"))
    if not matches:
        raise FileNotFoundError(
            f"no meta.json for session_id={session_id} under {root}"
        )
    if len(matches) > 1:
        # Should not happen — session_ids are UUIDs. Surface and pick newest.
        _stderr(f"WARN: {len(matches)} meta.json matches; picking newest by mtime")
        matches.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return matches[0]


def _op_read(ref: str) -> str:
    if not shutil.which("op"):
        return ""
    try:
        out = subprocess.run(
            ["op", "read", ref],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
        return out.stdout.strip()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return ""


def _r2_download(bucket: str, key: str, endpoint: str, dst: Path) -> None:
    access_key = os.environ.get("R2_TRANSCRIPTS_ACCESS_KEY_ID", "").strip()
    secret_key = os.environ.get("R2_TRANSCRIPTS_SECRET_ACCESS_KEY", "").strip()
    if not access_key or not secret_key:
        raise RuntimeError(
            "R2_TRANSCRIPTS_ACCESS_KEY_ID / R2_TRANSCRIPTS_SECRET_ACCESS_KEY "
            "missing — fetch_coo_secrets did not populate them"
        )

    import boto3
    from botocore.config import Config

    s3 = boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
        region_name="auto",
        config=Config(
            signature_version="s3v4",
            retries={"max_attempts": 3, "mode": "standard"},
        ),
    )
    s3.download_file(bucket, key, str(dst))


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(64 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _age_decrypt(ciphertext: Path, dst_gz: Path) -> None:
    identity = os.environ.get("TRANSCRIPTS_AGE_IDENTITY", "").strip()
    if not identity:
        raise RuntimeError(
            "TRANSCRIPTS_AGE_IDENTITY missing — op://COO/transcripts-age-key/credential "
            "may not have been provisioned (see fetch_coo_secrets WARN at bootstrap)"
        )
    if not identity.startswith("AGE-SECRET-KEY-1"):
        raise RuntimeError(
            "TRANSCRIPTS_AGE_IDENTITY does not look like an age identity "
            "(expected leading 'AGE-SECRET-KEY-1')"
        )
    if not shutil.which("age"):
        raise RuntimeError("age binary not on PATH")

    # Write identity to a per-invocation tempfile (chmod 0600), invoke age,
    # then explicitly remove. Identity must not leak via process listing
    # so we don't pass it on argv.
    fd, id_path_str = tempfile.mkstemp(prefix="transcript-age-id-", suffix=".key")
    id_path = Path(id_path_str)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(identity)
            if not identity.endswith("\n"):
                f.write("\n")
        subprocess.run(
            ["age", "-d", "-i", str(id_path), "-o", str(dst_gz), str(ciphertext)],
            check=True,
        )
    finally:
        try:
            id_path.unlink(missing_ok=True)
        except OSError:
            pass


def _gunzip(src: Path, dst: Path) -> None:
    with gzip.open(src, "rb") as fin, open(dst, "wb") as fout:
        shutil.copyfileobj(fin, fout)


def _fetch(session_id: str, meta_arg: str | None) -> Path:
    meta_path = Path(meta_arg) if meta_arg else _find_meta(session_id)
    if not meta_path.is_file():
        raise FileNotFoundError(f"meta.json not found at {meta_path}")
    meta = json.loads(meta_path.read_text())

    if meta.get("session_id") != session_id:
        raise RuntimeError(
            f"meta.session_id={meta.get('session_id')!r} does not match arg {session_id!r}"
        )

    r2 = meta.get("r2") or {}
    if not r2.get("uploaded"):
        raise RuntimeError(
            f"meta.r2.uploaded is false for session_id={session_id} "
            "— ciphertext was never pushed to R2; nothing to fetch"
        )

    bucket = r2.get("bucket", "").strip()
    key = r2.get("key", "").strip()
    if not bucket or not key:
        raise RuntimeError(f"meta.r2.bucket / key missing on {meta_path}")

    endpoint = _op_read("op://COO/r2-transcripts/endpoint")
    if not endpoint:
        raise RuntimeError(
            "R2 endpoint not readable from op://COO/r2-transcripts/endpoint "
            "(op CLI absent or 1Password slot empty)"
        )

    expected_sha = (meta.get("ciphertext_sha256") or "").strip().lower()
    if not expected_sha:
        raise RuntimeError(f"meta.ciphertext_sha256 missing on {meta_path}")

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=f"transcript-fetch-{session_id}-", dir=str(CACHE_DIR)
    ) as tmp:
        tmp_path = Path(tmp)
        ciphertext = tmp_path / f"{session_id}.jsonl.gz.age"
        gz = tmp_path / f"{session_id}.jsonl.gz"

        _r2_download(bucket, key, endpoint, ciphertext)

        actual_sha = _sha256(ciphertext)
        if actual_sha != expected_sha:
            raise RuntimeError(
                f"ciphertext_integrity_mismatch: meta sha256={expected_sha} "
                f"download sha256={actual_sha} key={key}"
            )

        _age_decrypt(ciphertext, gz)

        # Final destination: stable per-session cache path. Caller cleans up.
        out = CACHE_DIR / f"{session_id}.jsonl"
        _gunzip(gz, out)

    return out


def _cleanup(jsonl_arg: str) -> None:
    p = Path(jsonl_arg).resolve()
    cache = CACHE_DIR.resolve()
    if cache not in p.parents and p.parent != cache:
        raise RuntimeError(
            f"refusing to cleanup path outside cache dir: path={p} cache={cache}"
        )
    if p.exists():
        p.unlink()
        _stderr(f"removed {p}")
    else:
        _stderr(f"not present (already cleaned?): {p}")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="transcript-fetch",
        description="Fetch + decrypt + gunzip a redacted Claude Code session jsonl from R2.",
    )
    parser.add_argument(
        "session_id",
        nargs="?",
        help="Session UUID (matches the meta.json filename). Omit when using --cleanup.",
    )
    parser.add_argument(
        "--meta",
        help="Path to the meta.json sidecar (default: walk vade-agent-logs/transcripts/**).",
    )
    parser.add_argument(
        "--cleanup",
        help="Delete the named cached jsonl path (must live under ~/.vade/transcript-cache/).",
    )
    args = parser.parse_args(argv)

    if args.cleanup:
        try:
            _cleanup(args.cleanup)
        except Exception as e:
            _stderr(f"cleanup failed: {e}")
            return 1
        return 0

    if not args.session_id:
        parser.error("session_id is required unless --cleanup is given")

    try:
        out = _fetch(args.session_id, args.meta)
    except Exception as e:
        _stderr(f"fetch failed: {e}")
        return 1

    sys.stdout.write(f"{out}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
