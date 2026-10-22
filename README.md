# gauntlet

**A code-quality ratchet your agent can't argue with.**

gauntlet studies your repository, agrees a set of rules with you, measures every existing violation, and from then on lets that number only go down. A new violation is caught when it is committed, when it is pushed, and in CI, whichever agent or human wrote it.

> **Status: pre-release.** The specification is drafted: [vision, per-initiative PRD, FRDs and specs, and ADRs](docs/README.md). The runner and the skill are being built. The process itself is not new: it ran by hand in a large production monorepo before it became gauntlet. See the [case study](docs/guide/case-study.md).

[Getting started](docs/guide/getting-started.md) · [Concepts](docs/guide/concepts.md) · [Rules & detectors](docs/guide/rules-and-detectors.md) · [Gates](docs/guide/gates.md) · [Exceptions](docs/guide/exceptions.md) · [Agents](docs/guide/agents.md) · [Comparison](docs/guide/comparison.md) · [FAQ](docs/guide/faq.md)

---

## The problem

You write the rules down: `AGENTS.md`, an engineering-standards page, ADRs, review checklists. The agent reads them and agrees. Three PRs later the rules are broken again, every test is green, and nobody noticed. **A rule nobody counts is a suggestion.**

The usual fixes miss in two ways:

- **A fixed threshold** ("lint must be clean", "coverage ≥ 80 %") fails on day one in a real codebase. So it gets turned off, or set to whatever the code scores today, and it rots there.
- **A diff filter** ("only flag changed lines") forgets. Reformat a file and every old violation looks new. Move code, and new debt slips in looking old.

A **ratchet** does neither. It accepts today's debt as the floor and refuses to let the floor rise. gauntlet is a ratchet built for repositories where agents write most of the code:

- **It onboards itself.** An agent infers your stack, researches each technology's own guidance, and proposes rules one at a time for you to accept or reject. It never imposes a standard.
- **Every rule has a detector.** A rule that cannot be counted is not admitted. Detectors are declarative: a linter rule, an `ast-grep` rule or an `rg` pattern. No one writes a bespoke script "their own way".
- **The agent cannot loosen it.** The baseline is derived and only the runner writes it. Exceptions are human-only. Loosening a rule fails CI unless a person signed for it.
- **It coexists.** gauntlet adds one line to the hooks you already have and never takes them over.
- **It is agnostic** to language, agent harness and model. The runner is bash + awk + git.

## What it looks like

```console
$ git commit -m "feat: add invoice export"
gauntlet  commit · 6 rules · 0.8 s

  src/export/invoice.ts:42   silent-catch   catch block neither handles, logs nor rethrows
      fix: log the error with context and rethrow, or handle it; never leave the catch empty
  src/export/invoice.ts:88   raw-status     status compared to a string literal; use the InvoiceStatus enum
      fix: import { InvoiceStatus } from "@/domain/invoice" and compare to its members

  2 new violations · baseline unchanged · commit blocked
  waiver: ask a human to run `gauntlet waive src/export/invoice.ts "<reason>"`
```

```console
$ git commit -m "refactor: handle export errors"
gauntlet  commit · 6 rules · 0.7 s
  silent-catch  51 → 49   baseline lowered and staged into this commit
  ok
```

## How it works

```mermaid
flowchart LR
  A[onboard<br/>infer stack · research · propose] -->|owner approves each rule| B[rules<br/>.gauntlet/rules/*.md]
  B --> C[measure<br/>baseline.tsv]
  C --> D{gates}
  D --> E[pre-commit<br/>staged files · under 5 s]
  D --> F[pre-push<br/>everything CI runs]
  D --> G[CI<br/>same command]
  E & F & G -->|debt fell| H[baseline lowered<br/>in the same commit]
  E & F & G -->|new violation| I[blocked<br/>with the fix]
```

1. **Onboard.** Run once per repository, existing or empty. Each proposed rule comes with its rationale, a primary source, the current count, the worst files, a detector and a fix hint. You pick `block`, `track` or reject. New `block` rules start in **shadow**: they report "would have failed" until you promote them.
2. **Measure.** Every violation gets a **fingerprint** (rule + file + normalized line text), so moving or reformatting code changes nothing.
3. **Gate.** In order of what is checked:
   - no new `block` fingerprint;
   - no rule total rises;
   - optionally, every touched file comes out lower than it went in;
   - the baseline equals what the code measures;
   - no rule was loosened.
4. **Tighten.** When a commit lowers the debt, the new baseline travels in that same commit, so nobody has to remember to commit it.

The [concepts page](docs/guide/concepts.md) explains each piece.

## Proven by hand first

Before gauntlet existed as a tool, its process ran by hand in a **large production monorepo** (mobile app, backend, shared packages; ~580 merged PRs over the period, largely written by AI agents). Over about six weeks:

| Measured debt | Start | Six weeks later | Change |
|---|---:|---:|---:|
| Type-check errors | 40 | 6 | **−85 %** |
| Duplicate definitions | 369 | 68 | **−82 %** |
| Lint errors | 44 | 9 | **−80 %** |
| String literals compared instead of enums | 870 | 200 | **−77 %** |
| Silent `catch` blocks | 173 | 51 | **−71 %** |
| Exported functions without a return type | 265 | 91 | **−66 %** |
| React compiler rule violations | 113 | 58 | **−49 %** |
| Layer-boundary violations | 35 | 22 | **−37 %** |

```mermaid
%%{init: {"themeVariables": {"xyChart": {"plotColorPalette": "#2f81f7"}}}}%%
xychart-beta
  title "Duplicate definitions, weekly (lower is better)"
  x-axis [W1, W2, W3, W4, W5, W6, W7]
  y-axis "definitions" 0 --> 400
  line [369, 222, 183, 167, 125, 110, 68]
```

Shipping did not slow down: merged PRs per week went *up* after the ratchets landed. The local gate stopped **71 of 519 pushes** (13.7 %) in its first logged week, before they reached CI.

**Disclaimer.** These numbers come from the origin project's git history, under the hand-built version of the process. gauntlet itself has not produced them yet. The [case study](docs/guide/case-study.md) covers the method, the caveats, where the hand-built version leaked, and how gauntlet's design answers each leak.

## Quick start

> Planned interface. It works once v0.1 ships; follow the [changelog](CHANGELOG.md).

Ask your agent, in any harness:

```text
Install gauntlet from https://github.com/antonygiomarxdev/gauntlet and onboard this repository.
```

Or by hand:

```sh
git clone --depth 1 --branch v0.1.0 https://github.com/antonygiomarxdev/gauntlet ~/.gauntlet
~/.gauntlet/bin/gauntlet install     # vendors the runner and the skill into this repo
# then ask your agent to run the gauntlet `onboard` skill
```

After onboarding:

```sh
.gauntlet/bin/gauntlet status        # debt per rule, worst files, trend
.gauntlet/bin/gauntlet check --ci    # exactly what CI runs
.gauntlet/bin/gauntlet fix           # apply linter / ast-grep autofixes
.gauntlet/bin/gauntlet doctor        # tools present, hooks wired, baseline exact
```

## Compared with

| | Rules from | Baseline | Language-agnostic | New-violation check | Touched-file check | Agent onboarding | Agent can't loosen |
|---|---|---|---|---|---|---|---|
| **gauntlet** | owner-approved, researched | fingerprints, in repo | ✅ | ✅ fingerprint | ✅ | ✅ | ✅ runner-enforced |
| [pawl](https://github.com/tiangong-dev/pawl) | any command | counts, in repo | ✅ | ✅ added lines | — | — | trailer + guard |
| [cleat](https://github.com/svetdev/cleat) | built-in gates | findings, in repo | ✅ | partial | — | partial | hook-enforced |
| [betterer](https://github.com/phenomnomnominal/betterer) | JS test files | results file | JS/TS | — | — | — | — |
| ESLint bulk suppressions | ESLint | suppressions file | JS/TS | — | — | — | — |
| [reviewdog](https://github.com/reviewdog/reviewdog) `-filter-mode=added` | any linter | none (diff only) | ✅ | ✅ added lines | — | — | — |
| [lefthook](https://github.com/evilmartians/lefthook) / [prek](https://github.com/j178/prek) | — (hook runners) | — | ✅ | — | — | — | — |

gauntlet runs inside lefthook, prek or husky rather than replacing them. The [full comparison](docs/guide/comparison.md) has the details.

## Scope

**In scope:** rules, detectors, baselines and gates for code quality, plus the agent skill that onboards and evolves them.

**Out of scope:**
- multi-agent orchestration;
- imposing an architecture or a standard;
- dashboards;
- package registries.

## Contributing

Start in [Discussions](https://github.com/antonygiomarxdev/gauntlet/discussions); maintainers open issues from confirmed discussions. Read [CONTRIBUTING.md](CONTRIBUTING.md) first. False positives have their own category, because a false positive is the fastest way to make people hate a gate.

## License

[MIT](LICENSE)
