# Comparison

gauntlet borrows freely from the tools below. This page says what each does well, and why gauntlet still exists. The facts were checked against each project's README and source in October 2026; corrections are welcome.

## Two near-misses

- **A fixed threshold is not a ratchet.** "Lint must be clean" fails on day one in a real codebase, so it gets disabled. "Coverage ≥ 80 %" gets set to whatever the code scores today and never moves again.
- **A diff filter has no memory.** "Only flag changed lines" (`reviewdog -filter-mode=added`, Trunk's hold-the-line) forgets what was there. Reformat a file and every old violation looks new. Move a function and new debt hides among the old.

## Tools

| | Language | Rules | Baseline | New-violation check | Touched-file check | Auto-tighten | Exceptions | Agent integration | Runtime |
|---|---|---|---|---|---|---|---|---|---|
| **gauntlet** | any | owner-approved; linter / ast-grep / rg | fingerprints with multiplicity | ✅ by fingerprint | ✅ optional | ✅ same commit | human-only file | onboarding skill, adapters, runner-enforced | bash + awk |
| [pawl](https://github.com/tiangong-dev/pawl) | any | any command, regex-parsed | counts per file / key | ✅ added lines | — | manual `record` | `Pawl-Accept` trailer + `guard` | writes an `AGENTS.md` block | Go binary |
| [cleat](https://github.com/svetdev/cleat) | 9 languages | built-in gates + regex conventions | findings keyed by file + line text | partial | — | `--tighten`; `--strict` in CI | none; only a human raises it | Stop hook, policy-edit block | Python |
| [betterer](https://github.com/phenomnomnominal/betterer) | JS/TS | tests in `.betterer.ts` | results file, per issue hash | — | — | ✅ | — | — | Node |
| ESLint bulk suppressions | JS/TS | ESLint | `eslint-suppressions.json` | — | — | prune unused | — | — | Node |
| PHPStan / Psalm / detekt / RuboCop | one each | native | per file / issue | — | — | partial | — | — | PHP / JVM / Ruby |
| [reviewdog](https://github.com/reviewdog/reviewdog) | any | any linter | none | ✅ added lines | — | n/a | — | — | Go |
| [Semgrep](https://github.com/semgrep/semgrep) | any | YAML patterns | `--baseline-commit` | ✅ | — | n/a | inline comments | — | binary |
| [lefthook](https://github.com/evilmartians/lefthook) / [prek](https://github.com/j178/prek) | any | — (hook runners) | — | `{staged_files}` | — | — | — | — | Go / Rust |

## What only gauntlet does

- **A touched-file check.** A file you change must come out better than you found it. Teams can opt into this to pay debt down steadily.
- **Rules as files**, each with a rationale, a primary source, a fix hint and test cases, rather than lines in a config.
- **Onboarding that researches and proposes.** The agent studies your stack and the technology's own guidance, then asks rule by rule.
- **Rules learned from mistakes.** A repeated correction becomes a rule proposal.
- **Human-only exceptions in a file**, with path waivers that expire with their branch.
- **Coexistence.** gauntlet adds one line to your existing hooks instead of owning them.

## When to use something else

- **You want a mature, single-binary engine and no agent layer.** Use pawl.
- **You want a batteries-included quality-gate kit for agents, with built-in gates for coverage, complexity and duplication.** Look at cleat.
- **You are JS-only and want ratchets as code.** betterer fits, though its activity has slowed.
- **You only need hooks.** Use lefthook or prek. gauntlet runs inside them happily.
