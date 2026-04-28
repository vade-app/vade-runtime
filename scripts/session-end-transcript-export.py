#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["boto3>=1.34,<2"]
# ///
"""
session-end-transcript-export.py — vade-app/vade-agent-logs#64 Batch 2.

Active component of the Stop-hook chain. Runs after a Claude Code
session ends; never blocks session end.

Pipeline per invocation:

  1. Resolve session id (CLAUDE_SESSION_ID > most-recent jsonl mtime).
  2. Locate the live transcript at ~/.claude/projects/<slug>/<id>.jsonl.
  3. Stream through scripts/lib/transcript-redact.py; on engine non-zero
     exit, drop <id>.export-error.txt and exit 0.
  4. gzip the redacted bytes (compression ~10× per spec).
  5. age-encrypt to scripts/lib/transcripts-recipient.age — at-rest
     encryption per BDFL approval (vade-agent-logs#64 security review).
  6. boto3 upload to Cloudflare R2 at
     transcripts/YYYY/MM/DD/<id>.jsonl.gz.age (date from first event
     timestamp, falling back to UTC-now).
  7. Write a sidecar at <vade-agent-logs>/transcripts/YYYY/MM/DD/<id>.meta.json
     with parser_version, exported_at, event count, byte sizes,
     redaction hits, ciphertext sha256, and the R2 object key. The
     sidecar is committed by the agent at session end (alongside the
     human session log).

Always exits 0. Any uncaught failure drops <id>.export-error.txt next
to where the meta.json would have gone, so the absence of meta.json +
presence of export-error.txt is the operator-visible "this hook
fired but couldn't complete" signal.

First-run cost note: on a fresh container the first invocation pays
~5–10s for uv to resolve+download boto3 (PEP 723 inline deps), plus
~1–2s for `op read` of endpoint+bucket and ~1–2s for the boto3 import.
Subsequent invocations in the same container hit the uv cache and
warm imports — typically sub-second beyond the redact-engine work.
Acceptable for a Stop hook (operator perceives session-end as already
"the slow part"); flagged here so an operator who notices the pause
on first session knows it's expected, not stuck.

Required env (sourced from ~/.vade/coo-env by the bash wrapper):
  R2_TRANSCRIPTS_ACCESS_KEY_ID      — R2 API token access key (32 hex)
  R2_TRANSCRIPTS_SECRET_ACCESS_KEY  — R2 API token secret key (64 hex)
Read at run time via `op read` (no env exposure):
  op://COO/r2-transcripts/endpoint  — R2 S3-compat URL
  op://COO/r2-transcripts/bucket    — bucket name
Optional:
  CLAUDE_SESSION_ID  — override session-id resolution
  VADE_AGENT_LOGS_DIR  — override vade-agent-logs working tree resolution
  VADE_TRANSCRIPT_EXPORT_DRY_RUN=1  — skip R2 upload (CI / smoke-test)
"""

from __future__ import annotations

import datetime
import gzip
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import traceback
from pathlib import Path

PARSER_VERSION = 1
SCRIPT_DIR = Path(__file__).resolve().parent
RUNTIME_ROOT = SCRIPT_DIR.parent
REDACT_PY = RUNTIME_ROOT / "scripts" / "lib" / "transcript-redact.py"
RECIPIENT_FILE = RUNTIME_ROOT / "scripts" / "lib" / "transcripts-recipient.age"
REDACTION_CONFIG = RUNTIME_ROOT / "scripts" / "lib" / "transcript-redaction.json"


def _stderr(msg: str) -> None:
    sys.stderr.write(f"[session-end-transcript-export] {msg}\n")


def _resolve_session_id_and_jsonl() -> tuple[str, Path]:
    """Locate the live session jsonl. Prefers CLAUDE_SESSION_ID; falls
    back to most-recent mtime under ~/.claude/projects/*/*.jsonl.

    Fallback safety: in current Claude Code releases the harness
    reliably sets CLAUDE_SESSION_ID for Stop hooks, so the mtime path
    is single-session-best-effort defensive code for older harness
    versions and odd surfaces. If two parallel sessions share $HOME
    (cloud cohabitation, multi-pane local Mac, the briefing-005
    dual-instance pattern), the fallback can pick the sibling's
    still-being-written transcript by mtime. The per-project glob
    narrows blast radius but doesn't eliminate it. If the harness
    drops CLAUDE_SESSION_ID guarantees, tighten this to "most recent
    jsonl in the same project slug as $PWD"."""
    projects = Path.home() / ".claude" / "projects"
    if not projects.is_dir():
        raise FileNotFoundError(f"~/.claude/projects not found at {projects}")

    sid = os.environ.get("CLAUDE_SESSION_ID", "").strip()
    if sid:
        candidates = list(projects.glob(f"*/{sid}.jsonl"))
        if not candidates:
            raise FileNotFoundError(
                f"CLAUDE_SESSION_ID={sid} but no matching jsonl under {projects}"
            )
        return sid, candidates[0]

    all_jsonl = sorted(
        projects.glob("*/*.jsonl"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if not all_jsonl:
        raise FileNotFoundError(f"no .jsonl found under {projects}")
    chosen = all_jsonl[0]
    return chosen.stem, chosen


def _resolve_agent_logs_dir() -> Path:
    """Resolve vade-agent-logs working tree (for sidecar drop-off)."""
    explicit = os.environ.get("VADE_AGENT_LOGS_DIR", "").strip()
    if explicit:
        p = Path(explicit)
        if p.is_dir():
            return p
        raise FileNotFoundError(f"VADE_AGENT_LOGS_DIR={p} does not exist")

    candidates = [
        Path.home() / "GitHub" / "vade-app" / "vade-agent-logs",
        Path("/home/user/vade-agent-logs"),
        RUNTIME_ROOT.parent / "vade-agent-logs",
    ]
    for c in candidates:
        if c.is_dir():
            return c
    raise FileNotFoundError(
        "vade-agent-logs working tree not found; tried "
        + ", ".join(str(c) for c in candidates)
    )


def _first_event_date(jsonl_path: Path) -> datetime.date:
    """Read the first parseable event and extract a date from its
    timestamp. Falls back to today UTC if no parseable timestamp."""
    try:
        with open(jsonl_path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                ts = obj.get("timestamp") or obj.get("ts")
                if isinstance(ts, str):
                    try:
                        # ISO-8601 with optional Z suffix.
                        return datetime.datetime.fromisoformat(
                            ts.replace("Z", "+00:00")
                        ).date()
                    except ValueError:
                        continue
                if isinstance(ts, (int, float)):
                    return datetime.datetime.fromtimestamp(
                        ts / 1000 if ts > 1e12 else ts,
                        tz=datetime.timezone.utc,
                    ).date()
    except OSError:
        pass
    return datetime.datetime.now(datetime.timezone.utc).date()


def _run_redact(input_path: Path, output_path: Path, hits_path: Path) -> None:
    """Subprocess the redact engine. Raises CalledProcessError on
    non-zero exit; the caller turns that into an export-error.txt."""
    if not REDACT_PY.is_file():
        raise FileNotFoundError(f"redact engine missing: {REDACT_PY}")
    if not REDACTION_CONFIG.is_file():
        raise FileNotFoundError(f"redaction config missing: {REDACTION_CONFIG}")
    subprocess.run(
        [
            sys.executable,
            str(REDACT_PY),
            "--config", str(REDACTION_CONFIG),
            "--input", str(input_path),
            "--output", str(output_path),
            "--hits", str(hits_path),
        ],
        check=True,
    )


def _gzip_file(src: Path, dst: Path) -> None:
    with open(src, "rb") as fin, gzip.open(dst, "wb", compresslevel=6) as fout:
        shutil.copyfileobj(fin, fout)


def _age_encrypt(src: Path, dst: Path) -> None:
    if not RECIPIENT_FILE.is_file():
        raise FileNotFoundError(f"age recipient file missing: {RECIPIENT_FILE}")
    if not shutil.which("age"):
        raise FileNotFoundError("age binary not on PATH")
    with open(src, "rb") as fin, open(dst, "wb") as fout:
        subprocess.run(
            ["age", "-R", str(RECIPIENT_FILE)],
            stdin=fin,
            stdout=fout,
            check=True,
        )


def _read_recipient_pubkey() -> str:
    """Slurp the X25519 pubkey from RECIPIENT_FILE for sidecar embedding.
    Returns the last non-comment, non-blank line — matches `age -R`'s
    own parser convention (one recipient per line, leading `#` is a
    comment). Embedded in sidecar so a reader holding only meta.json
    can verify which recipient encrypted the ciphertext without
    cloning vade-runtime at the same SHA the hook ran from."""
    try:
        for line in reversed(RECIPIENT_FILE.read_text().splitlines()):
            s = line.strip()
            if s and not s.startswith("#"):
                return s
    except OSError:
        pass
    return ""


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(64 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _op_read(ref: str) -> str:
    """Read a 1Password reference via the op CLI. Returns empty string
    on any failure (caller decides whether to abort or skip)."""
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


def _r2_upload(local: Path, key: str) -> dict:
    """Upload a local file to R2 at the given key. Returns a dict with
    bucket+key+endpoint for the sidecar; raises on failure."""
    access_key = os.environ.get("R2_TRANSCRIPTS_ACCESS_KEY_ID", "").strip()
    secret_key = os.environ.get("R2_TRANSCRIPTS_SECRET_ACCESS_KEY", "").strip()
    if not access_key or not secret_key:
        raise RuntimeError(
            "R2_TRANSCRIPTS_ACCESS_KEY_ID / R2_TRANSCRIPTS_SECRET_ACCESS_KEY "
            "missing — fetch_coo_secrets did not populate them"
        )
    endpoint = _op_read("op://COO/r2-transcripts/endpoint")
    bucket = _op_read("op://COO/r2-transcripts/bucket")
    if not endpoint or not bucket:
        raise RuntimeError(
            "R2 endpoint or bucket not readable from "
            "op://COO/r2-transcripts/{endpoint,bucket}"
        )

    import boto3  # imported lazily — uv resolves on first run
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
    s3.upload_file(str(local), bucket, key)
    return {"bucket": bucket, "key": key, "endpoint": endpoint}


def _emit_export_error(sidecar_dir: Path, session_id: str, exc: BaseException) -> None:
    sidecar_dir.mkdir(parents=True, exist_ok=True)
    err_path = sidecar_dir / f"{session_id}.export-error.txt"
    with open(err_path, "w") as f:
        f.write(f"# session-end-transcript-export.py failed\n")
        f.write(f"# generated: {datetime.datetime.now(datetime.timezone.utc).isoformat()}\n")
        f.write(f"# session_id: {session_id}\n")
        f.write(f"# script: {Path(__file__).resolve()}\n\n")
        f.write(str(exc))
        f.write("\n\n")
        traceback.print_exception(type(exc), exc, exc.__traceback__, file=f)
    _stderr(f"wrote export-error: {err_path}")


def main() -> int:
    session_id = "unknown"
    sidecar_dir_for_error: Path | None = None
    try:
        session_id, jsonl_path = _resolve_session_id_and_jsonl()
        _stderr(f"session_id={session_id} jsonl={jsonl_path}")

        agent_logs_dir = _resolve_agent_logs_dir()
        date = _first_event_date(jsonl_path)
        date_path = f"{date.year:04d}/{date.month:02d}/{date.day:02d}"
        sidecar_dir = agent_logs_dir / "transcripts" / date_path
        sidecar_dir.mkdir(parents=True, exist_ok=True)
        sidecar_dir_for_error = sidecar_dir

        bytes_pre = jsonl_path.stat().st_size

        with tempfile.TemporaryDirectory(prefix=f"transcript-export-{session_id}-") as tmp:
            tmp_path = Path(tmp)
            redacted = tmp_path / "redacted.jsonl"
            hits = tmp_path / "hits.json"
            gz = tmp_path / "redacted.jsonl.gz"
            ciphertext = tmp_path / f"{session_id}.jsonl.gz.age"

            try:
                _run_redact(jsonl_path, redacted, hits)
            except subprocess.CalledProcessError as e:
                # Engine failure: drop export-error per the design.
                _emit_export_error(
                    sidecar_dir,
                    session_id,
                    RuntimeError(f"redact engine exited rc={e.returncode}"),
                )
                return 0

            redaction_summary = json.loads(hits.read_text())

            _gzip_file(redacted, gz)
            _age_encrypt(gz, ciphertext)
            ciphertext_sha256 = _sha256(ciphertext)
            ciphertext_size = ciphertext.stat().st_size

            r2_key = f"transcripts/{date_path}/{session_id}.jsonl.gz.age"
            dry_run = os.environ.get("VADE_TRANSCRIPT_EXPORT_DRY_RUN", "").strip() == "1"
            if dry_run:
                r2_target = {
                    "bucket": "<dry-run>",
                    "key": r2_key,
                    "endpoint": "<dry-run>",
                    "uploaded": False,
                }
            else:
                upload = _r2_upload(ciphertext, r2_key)
                r2_target = {**upload, "uploaded": True}

            sidecar = {
                "schema_version": 1,
                "parser_version": PARSER_VERSION,
                "session_id": session_id,
                "exported_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "source_jsonl": str(jsonl_path),
                "events_processed": redaction_summary.get("events_processed", 0),
                "events_with_unparseable_json":
                    redaction_summary.get("events_with_unparseable_json", 0),
                "bytes_pre_redaction": bytes_pre,
                "bytes_post_redaction": redaction_summary.get("bytes_post", 0),
                "bytes_post_gzip": gz.stat().st_size,
                "bytes_ciphertext": ciphertext_size,
                "ciphertext_sha256": ciphertext_sha256,
                "redaction_hits": redaction_summary.get("redaction_hits", {}),
                "r2": r2_target,
                "age_recipient_file": str(RECIPIENT_FILE.relative_to(RUNTIME_ROOT)),
                "age_recipient_pubkey": _read_recipient_pubkey(),
            }
            sidecar_path = sidecar_dir / f"{session_id}.meta.json"
            with open(sidecar_path, "w") as f:
                json.dump(sidecar, f, indent=2)
                f.write("\n")
            _stderr(f"wrote sidecar: {sidecar_path}")

        return 0
    except BaseException as e:
        # Never block session end. Drop an export-error wherever we can.
        target = sidecar_dir_for_error
        if target is None:
            # Pre-resolution failure: best-effort fallback to ~/.vade/transcript-export-errors.
            target = Path.home() / ".vade" / "transcript-export-errors"
        try:
            _emit_export_error(target, session_id, e)
        except BaseException:
            traceback.print_exc(file=sys.stderr)
        return 0


if __name__ == "__main__":
    sys.exit(main())
