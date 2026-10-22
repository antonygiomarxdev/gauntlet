# Initiatives

An initiative is one outcome worth its own PRD. Each one lives in `I-NN-<name>/` with its PRD, FRDs and implementation specs, plus a `tp/` folder when it needs a technical proposal of its own. The [VISION](../VISION.md), the [system architecture](../architecture/TP-01-gauntlet.md) and the [ADRs](../adr/README.md) are shared by all of them.

| ID | Initiative | Status | PRD |
|---|---|---|---|
| I-01 | Core: runner, gates and agent onboarding (v0.1, v0.2) | Active | [PRD](I-01-core/PRD.md) |
| I-02 | Origin-project migration: replace every hand-built ratchet and the pre-push gate with gauntlet, keeping the same counts, one ratchet per PR | Planned, after v0.1 | — |

A planned initiative gets its folder when its PRD is written. How documents flow inside an initiative: [Specification flow](../process/SPECIFICATION-FLOW.md).
