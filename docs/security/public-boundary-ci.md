# Public Boundary CI

The public repository is reproducible by design, but household-specific financial facts must never be published.

This repository therefore uses two complementary controls:

1. GitHub/Gitleaks secret detection for credentials and known secret formats.
2. `scripts/check_public_boundary.py` for project-specific privacy boundaries such as raw finance exports and household-specific denylist terms.

## What the custom scanner blocks

- non-example `.env*` files
- SQLite/database dumps/backups and private-key containers
- OFX/QIF exports
- CSV/XLS/XLSX outside explicit synthetic fixture directories
- top-level private/raw/backup/secrets directories
- Korean resident-registration-number shaped text
- private-key PEM headers
- exact household terms provided through the `PUBLIC_BOUNDARY_DENYLIST` repository secret

The exact denylist values are not committed to this repository. The scanner reports only a short SHA-256 fingerprint of a matched term.

## Synthetic data exception

Financial export fixtures are allowed only under paths explicitly indicating synthetic data:

- `examples/synthetic/`
- `fixtures/synthetic/`
- `tests/fixtures/synthetic/`

All such data must be fictional.

## CI workflow

`.github/workflows/public-boundary.yml` runs on push, pull request and manual dispatch.

It performs:

1. regression tests for the custom boundary scanner;
2. a full public-boundary scan;
3. Gitleaks history scanning.

Action dependencies are pinned to immutable commit SHAs.

## GitHub native protection

GitHub public repositories receive secret scanning coverage, and GitHub push protection can stop supported secret patterns before they enter repository history. Native secret scanning does not replace this project's custom privacy boundary because exact household facts are not necessarily recognizable as credentials.

## Optional private denylist

If the repository setting is available, define a repository Actions secret named:

`PUBLIC_BOUNDARY_DENYLIST`

with one exact private term per line. Examples of the *classes* of values to protect include:

- real family-member names
- exact private location strings
- exact current salary or asset values that should never appear in public material

Do not document the actual values in the public repository.

The system remains useful without this secret because file-boundary checks, PII-shape checks, Gitleaks and GitHub native scanning still run. The private denylist adds a project-specific final layer.
