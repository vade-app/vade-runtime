# `ci/mocks/`

Drop-in PATH-replacement mocks for `curl` and `op` used by
`scripts/ci/run-bootstrap-regression.sh` to exercise the bootstrap
pipeline in CI without real network or 1Password access.

## Contracts

- **`curl`** — intercepts requests to
  `https://api.github.com/user` (returns a canned `vade-coo`
  identity, used by `validate_coo_identity` and the cached-PAT
  recheck). Every other URL forwards to the real `curl` so the
  substrate stays representative.
- **`op`** — returns canned vade-coo-shaped responses for the
  1Password lookups the bootstrap exercises (PAT, SSH keys,
  AgentMail key, Mem0 API key).

## Invocation

The CI runner places this directory at the head of `$PATH`. Real
`curl` is preserved at `$VADE_CI_REAL_CURL` (default
`/usr/bin/curl`).

## Maintenance

Each mock honors specific input shapes documented in the script
headers. Deviations from those shapes are CI bugs (the mock is
load-bearing for the bootstrap-regression invariant). Update mocks
in lockstep with bootstrap-script changes that introduce new HTTP
endpoints or 1Password lookups.
