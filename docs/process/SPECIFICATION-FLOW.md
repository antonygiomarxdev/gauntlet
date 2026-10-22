# Specification flow

How work on gauntlet is decided before it is built. Each document has one job, and each one fits in an agent's context window.

## The chain

```
VISION                  why gauntlet exists, for whom; shared by every initiative
  ↓
PRD (one per initiative)  what outcome this initiative delivers, and how it is released
  ↓
FRD (one per capability)  what one capability must do, as Given/When/Then
  ↓
Technical Proposal      how the FRDs fit together as one architecture
  ↓
Implementation Spec     how one cohesive slice is built
  ↓
GitHub issue (brief)    one deliverable, opened by a maintainer
  ↓
Pull request
```

The links between levels are many-to-many where they need to be. One FRD may need several specs, and one spec may cover criteria from several FRDs. Each link is written down explicitly:
- the PRD indexes its FRDs;
- the Technical Proposal lists the FRDs it covers and decomposes into specs;
- each spec maps FRD criteria to tests;
- each issue names its spec and criteria.

**ADRs are not a stage in the chain.** They record a durable decision found or applied while writing a proposal or a spec. If a spec contradicts an accepted ADR, the ADR is superseded first. A spec never silently overrides an ADR.

## Where things live

| Artifact | Path | Template |
|---|---|---|
| Vision | `docs/VISION.md` | — |
| Initiative index | `docs/initiatives/README.md` | — |
| PRD | `docs/initiatives/I-NN-<name>/PRD.md` | [prd.md](templates/prd.md) |
| FRDs | `docs/initiatives/I-NN-<name>/frd/FRD-NN-<capability>.md` | [frd.md](templates/frd.md) |
| Technical Proposals | `docs/initiatives/I-NN-<name>/TP-NN-<topic>.md` | [technical-proposal.md](templates/technical-proposal.md) |
| Implementation Specs | `docs/initiatives/I-NN-<name>/specs/IS-NN-<slice>.md` | [implementation-spec.md](templates/implementation-spec.md) |
| Spikes | `docs/initiatives/I-NN-<name>/spikes/SP-NN-<question>.md` | [spike.md](templates/spike.md) |
| ADRs | `docs/adr/NNNN-<slug>.md`, shared by all initiatives | [adr.md](templates/adr.md) |

FRD, TP, IS and SP numbers are global across initiatives, so an ID never needs its folder to be unambiguous. Release criteria use the initiative's key (`CORE-PA1`).
| User guide | `docs/guide/` | — |
| Briefs | GitHub issues, opened by a maintainer from a spec (see [CONTRIBUTING](../../CONTRIBUTING.md)) | — |

## Fast paths

The full chain is for new capabilities. Smaller work takes a shorter path, and the issue's first line names it: `Path: brief-only | small | full | technical | spike`.

| Path | When | Documents |
|---|---|---|
| brief-only | The behaviour is already decided, the change is local, and nothing new is decided. | Issue only. |
| small | A small isolated capability. | FRD and Implementation Spec. They may share one file in two parts with separate approvals. |
| full | A new or cross-cutting capability. | The whole chain. |
| technical | No behaviour a user can observe changes. | Implementation Spec, or a Technical Proposal if the change is cross-cutting. "No change" is proven by tests, never asserted. |
| spike | A question only throwaway code can answer. | A spike document. The code never merges. |

## Lifecycle

Every document starts with one machine-readable line:

`Status: Draft | Approved by <name> on <YYYY-MM-DD> | Superseded by <document>`

Who approves what:

| Document | Approved by |
|---|---|
| Vision, PRD, FRDs | the owner |
| Technical Proposal | the owner, once the alternatives and trade-offs are explicit |
| Implementation Spec | the maintainer who will merge it. The owner also approves when the spec changes FRD-visible behaviour, an approved proposal or an ADR. |
| ADR | the owner |

Approval is recorded where it happened (a PR review or comment) and in the status line.

**Editing an approved document returns it to Draft.** The editor:
1. says what changed and why;
2. lists the downstream criteria, specs and issues it affects;
3. gets the same approval again.

**A worker never edits an approved upstream document.** New evidence that contradicts one means stop and escalate.

## Three gates for every delivery

A PR is accepted only when all three gates pass. Passing one never compensates for failing another.

1. **Functional.** The FRD criteria it covers are shown with observable scenarios: fixture repos that run the real binary.
2. **Technical.** The applicable ADRs, the spec's design and the full test suite pass, and gauntlet's own gate passes once gauntlet dogfoods itself.
3. **Runtime.** It runs where users run it: Linux and macOS in CI, and a real git repo with real hooks. Anything that could not be exercised is named, with its residual risk.

## Size guardrails

These are split triggers, not page counts:

- **PRD:** short. Functional detail moves to FRDs.
- **FRD:** one capability. About 15 acceptance criteria is a warning sign.
- **Technical Proposal:** system level only.
- **Implementation Spec:** must fit in a worker's context along with the code it touches.

## Writing rules

- **Measure before asserting.** Claims about behaviour are checked against the code or a reproduction. Example: the commit-msg spike in [ADR-0007](../adr/0007-commit-time-check-in-pre-commit.md).
- **Open questions carry a proposed default,** so the owner accepts or changes it instead of answering from scratch.
- **Research brings facts and options, never the verdict.** The owner decides.
- **Cross-cutting concerns are decided, not skipped.** Every proposal and spec records each concern in the registry below as Required, Not required or Deferred, with a reason. Silence is not a decision.

## Cross-cutting concerns registry

| ID | Concern | The question to answer |
|---|---|---|
| CC-PERF | Performance | Does it stay within the 5 s commit budget and avoid repeated tool runs? |
| CC-REL | Reliability | Does it fail closed? Can anything be skipped silently? |
| CC-COMPAT | Portability | bash 3.2, BWK awk, macOS, Git Bash on Windows? |
| CC-COEXIST | Coexistence | Can it break an existing hook, linter config or CI? |
| CC-TAMPER | Agent tamper resistance | Can an agent loosen, bypass or rewrite what binds it? |
| CC-SEC | Security | It runs shell commands from repo files: what can a malicious rule or path do? |
| CC-OBS | Observability | Does the output show what failed, where, why, the fix and the time it took? |
| CC-MIG | Migration | Does an existing repo or baseline keep working across versions? |
| CC-ROLL | Rollout | Can it be adopted gradually, without known debt breaking CI? |
| CC-DEPS | Dependencies | Does it add a runtime dependency to the runner? |
| CC-PRIV | Privacy | Does anything leave the machine? (The default answer is no; there is no telemetry.) |
