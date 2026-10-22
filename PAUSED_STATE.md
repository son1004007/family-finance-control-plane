# Family Finance implementation — paused

**Owner decision:** 2026-10-22. Development and deployment automation is paused for practical-value reassessment. This public repository is preserved; no code is deleted.

All **13** GitHub Actions workflows on `main` had their **automatic** push/pull-request/other triggers removed and now declare only `workflow_dispatch`. This was verified by re-reading each current workflow. A deliberate manual workflow dispatch remains technically possible but is **not authorized** as a project resumption while paused.

Initial pre-pause `main` baseline: `8048b6b08b9be162279f6a2d0be284e5e5914822`. Git history preserves the original triggers, tests and releases. Do not restore automatic triggers, run builds/releases or restart deployment without a new explicit owner instruction.

The private runtime overlay records the NAS application shutdown and preservation requirements in its own `PAUSED_STATE.md`. Do not copy private household data, credentials or runtime details into this public repository. Public synthetic examples, schemas and existing source remain available for later reassessment.

When the owner eventually requests resumption, begin with a narrow manually verified use case rather than reactivating all automation. Compare the then-current source against the pre-pause baseline and restore only approved workflows, without overwriting intervening changes.
