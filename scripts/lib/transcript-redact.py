#!/usr/bin/env python3
"""
Redact a Claude Code session transcript jsonl in preparation for
commit/upload. Streams line-by-line; emits redacted jsonl on stdout
and a hit-count summary JSON on stderr (readable by the export hook
for inclusion in the meta.json sidecar).

Usage:
    transcript-redact.py [--config PATH] < input.jsonl > output.jsonl 2> hits.json

Design notes:
  - Order of operations per line:
      1. Parse as JSON; on parse failure, fall back to raw-text regex
         pipeline (defensive).
      2. Walk the JSON tree and replace any {type: "thinking", text: ...}
         text field with the configured placeholder; preserves the
         event structure and any signature field.
      3. Re-serialize and run the regex pipeline (in config order) over
         the serialized string. This catches secrets in any field —
         tool-result bodies, env-var dumps, Bash stdout, etc.
      4. Apply the entropy fallback last, but only outside replacement
         markers we just inserted (so we don't re-redact our own
         REDACTED tokens).
  - Hit counts are per-pattern + entropy + thinking; surface non-zero
    entropy hits in the next morning's Watch briefing as 24h-leak
    detection.
  - Failure mode: if the engine itself raises, exit non-zero with no
    output written. The export hook is expected to detect this and
    write {sessionId}.export-error.txt rather than fall back to
    unredacted output.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
from collections import Counter
from typing import Any


DEFAULT_CONFIG = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "transcript-redaction.json",
)


def load_config(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


def compile_patterns(cfg: dict) -> list[tuple[str, re.Pattern, str]]:
    out = []
    for entry in cfg.get("patterns", []):
        out.append((entry["id"], re.compile(entry["regex"]), entry["replacement"]))
    return out


def shannon_entropy_bits_per_char(s: str) -> float:
    if not s:
        return 0.0
    counts = Counter(s)
    n = len(s)
    return -sum((c / n) * math.log2(c / n) for c in counts.values())


def redact_thinking_in_place(node: Any, hits: Counter, replacement_template: str) -> None:
    """Walk a parsed JSON tree, replace text in {type: 'thinking', text: ...}."""
    if isinstance(node, dict):
        if node.get("type") == "thinking" and isinstance(node.get("text"), str):
            length = len(node["text"])
            node["text"] = replacement_template.format(length=length)
            hits["thinking-block"] += 1
        for v in node.values():
            redact_thinking_in_place(v, hits, replacement_template)
    elif isinstance(node, list):
        for v in node:
            redact_thinking_in_place(v, hits, replacement_template)


def apply_regex_pipeline(text: str, patterns: list[tuple[str, re.Pattern, str]], hits: Counter) -> str:
    for pid, regex, replacement in patterns:
        # Use subn to count hits per pattern.
        text, n = regex.subn(replacement, text)
        if n:
            hits[pid] += n
    return text


# A redaction marker we will not re-redact: [REDACTED:<label>...]
_MARKER_RE = re.compile(r"\[REDACTED:[^\]]+\]")
# Char classes inside an entropy-eligible run.
def _entropy_substitute(text: str, cfg: dict, hits: Counter) -> str:
    if not cfg.get("enabled", False):
        return text
    min_len = int(cfg.get("min_length", 32))
    min_ent = float(cfg.get("min_entropy_bits_per_char", 4.5))
    charset = cfg.get("charset", "A-Za-z0-9_/+=.\\-")
    replacement = cfg.get("replacement", "[REDACTED:high-entropy]")
    run_re = re.compile(rf"[{charset}]{{{min_len},}}")

    # Carve out marker spans we must not touch.
    spans: list[tuple[int, int, str | None]] = []
    cursor = 0
    for m in _MARKER_RE.finditer(text):
        if cursor < m.start():
            spans.append((cursor, m.start(), None))
        spans.append((m.start(), m.end(), text[m.start():m.end()]))
        cursor = m.end()
    if cursor < len(text):
        spans.append((cursor, len(text), None))

    out_parts: list[str] = []
    for start, end, marker in spans:
        if marker is not None:
            out_parts.append(marker)
            continue
        segment = text[start:end]

        def repl(m: re.Match) -> str:
            run = m.group(0)
            ent = shannon_entropy_bits_per_char(run)
            if ent >= min_ent:
                hits["high-entropy"] += 1
                return replacement
            return run

        out_parts.append(run_re.sub(repl, segment))
    return "".join(out_parts)


def redact_line(line: str, patterns: list, cfg: dict, hits: Counter, parser_warnings: list) -> str:
    line_stripped = line.rstrip("\n")
    if not line_stripped:
        return line

    # Stage 1: parse JSON, redact thinking blocks structurally.
    parsed = None
    try:
        parsed = json.loads(line_stripped)
    except json.JSONDecodeError as e:
        parser_warnings.append({"error": "json-decode", "detail": str(e)[:200]})

    if parsed is not None and cfg.get("thinking_block", {}).get("enabled", False):
        tpl = cfg["thinking_block"]["replacement_template"]
        redact_thinking_in_place(parsed, hits, tpl)
        serialized = json.dumps(parsed, ensure_ascii=False, separators=(",", ":"))
    else:
        serialized = line_stripped

    # Stage 2: regex pipeline.
    serialized = apply_regex_pipeline(serialized, patterns, hits)

    # Stage 3: entropy fallback.
    serialized = _entropy_substitute(serialized, cfg.get("entropy_fallback", {}), hits)

    return serialized + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=DEFAULT_CONFIG)
    ap.add_argument("--input", default=None, help="path to jsonl (default: stdin)")
    ap.add_argument("--output", default=None, help="path to redacted jsonl (default: stdout)")
    ap.add_argument("--hits", default=None, help="path to hit-count JSON (default: stderr)")
    args = ap.parse_args()

    cfg = load_config(args.config)
    patterns = compile_patterns(cfg)
    hits: Counter = Counter()
    parser_warnings: list = []

    in_stream = open(args.input, "r") if args.input else sys.stdin
    out_stream = open(args.output, "w") if args.output else sys.stdout

    bytes_pre = 0
    bytes_post = 0
    events = 0
    try:
        for line in in_stream:
            bytes_pre += len(line.encode("utf-8"))
            redacted = redact_line(line, patterns, cfg, hits, parser_warnings)
            bytes_post += len(redacted.encode("utf-8"))
            events += 1
            out_stream.write(redacted)
    finally:
        if args.input:
            in_stream.close()
        if args.output:
            out_stream.close()

    summary = {
        "redaction_hits": dict(hits),
        "events_processed": events,
        "events_with_unparseable_json": len(parser_warnings),
        "parser_warnings_sample": parser_warnings[:5],
        "bytes_pre": bytes_pre,
        "bytes_post": bytes_post,
        "engine_version": 1,
    }
    summary_text = json.dumps(summary, indent=2) + "\n"
    if args.hits:
        with open(args.hits, "w") as f:
            f.write(summary_text)
    else:
        sys.stderr.write(summary_text)

    return 0


if __name__ == "__main__":
    sys.exit(main())
