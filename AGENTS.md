# AGENTS.md

Global control: son1004007/ai-agent-workflow-playbook/CONTROL.md

## Purpose

This is the **public, reusable** implementation repository for Family Finance Control Plane.

## Public-only rule

This repository must never contain household-specific private financial or identifying data.

Forbidden examples:

- exact personal salary or household income
- exact current assets, liabilities, balances or spending
- real family-member names
- exact home, relative or workplace locations
- raw bank/card/security transactions
- account/card identifiers
- credentials, tokens, keys or private connection strings

Use synthetic data, placeholders, generic role names and non-identifying examples in all code, tests, docs and blog posts.

## Private overlay

Household-specific policy and planning context belongs in the private companion repository registered in global Control. Dynamic financial facts belong in PostgreSQL/NAS and secrets infrastructure, not Git.

Do not copy files wholesale from the private repository into this repository. Create a sanitized public-derived artifact and review the diff before committing.

## AI publication check

Before every public commit involving finance examples or generated documentation:

1. search the staged/generated content for exact private numbers, names and locations;
2. replace them with synthetic values or placeholders;
3. confirm no raw financial files or secrets are included;
4. prefer generated sample datasets that are clearly fictional.
