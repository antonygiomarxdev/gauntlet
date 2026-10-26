# ADR-0006: gauntlet coexists with existing hooks

- **Status:** Accepted
- **Date:** 2026-10-22
- **Decision maker:** Owner (Antony Giomar Hernández)
- **Related:** [ADR-0007](0007-commit-time-check-in-pre-commit.md), [VISION](../VISION.md)

## Context

Most repositories already run something on commit and push: husky, lefthook, prek or the `pre-commit` framework, or hand-written hooks. Breaking a project's existing hooks or tooling is an anti-goal, and a tool that takes over the hooks will not be adopted. `core.hooksPath` also does not travel with a clone, so a teammate can end up unprotected without knowing.

## Decision

1. gauntlet adds **one line** that calls it. Where the line goes:
   - husky: in the existing hook files;
   - a custom `core.hooksPath`: in that directory's hook files;
   - otherwise: in the plain git hooks directory.

   It touches nothing else. In an existing hook the line goes first, right after the shebang line. An early `exit`, an `exec` or a failing last command cannot skip it, and the project's own hook then runs unchanged and keeps its own exit status.
2. gauntlet never sets or changes `core.hooksPath`.
3. Hook managers (lefthook, prek or the `pre-commit` framework) get a snippet **printed**, not an edit: YAML to paste for a YAML config, the two commands to translate for TOML or JSON. `doctor` fails until the snippet is present.
4. gauntlet installs its own hooks only when the project has none.
5. Onboarding wires the install into the setup step the project already has (`prepare`, `make setup`, …), so a fresh clone is protected.
6. Extra checks the project already runs are declared in gauntlet's config, not forbidden.

## Consequences

- Adoption does not disturb existing setups, and removal is one line per hook.
- YAML-managed hooks need one manual edit. That is an accepted cost, rather than rewriting files gauntlet does not own.
- Hook installation is idempotent: re-running it never duplicates the line.

## Alternatives considered

- **Own the hooks directory** (set `core.hooksPath`): it breaks husky and similar setups, the exact failure the owner feared.
- **Edit YAML configs automatically:** without a YAML parser that risks corrupting a file gauntlet does not own.
- **CI only, no hooks:** feedback comes too late, and it costs CI minutes. The non-negotiable is that nothing is pushed without knowing it passes CI.
