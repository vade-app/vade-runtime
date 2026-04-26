# Vendored: skill-creator

This skill is vendored from upstream Anthropic. Distributed under the
Apache License 2.0 (see `LICENSE.txt` in this directory).

## Maintenance rule

**Do not modify in-place.** If a fix or enhancement is needed,
either:

1. Open an upstream PR and re-vendor once it lands; or
2. Fork into a sibling skill (e.g. `.claude/skills/skill-creator-vade/`)
   that depends on the vendored version, leaving the vendored copy
   pristine.

Inline edits make future re-vendoring expensive and silently desync
this copy from upstream.

## Origin

See git history for the vendoring commit. Upstream: Anthropic
skill-creator (search the public skill-creator repository for the
canonical source).

## Why a separate file

`.claude/skills/skill-creator/` mixes Anthropic-authored content with
project-local files (e.g. anything VADE adds alongside). This banner
makes the vendored boundary explicit so future maintainers know which
files are upstream and which are ours.
