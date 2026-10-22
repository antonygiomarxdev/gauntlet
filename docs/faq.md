# FAQ

**Will gauntlet break my CI on day one?**
No. Existing debt is measured and accepted as the floor. New `block` rules start in shadow. The touched-file gate starts off. Only new violations fail, and only once you have promoted their rule.

**Will it touch my existing hooks?**
It adds one line inside them. It never replaces your hooks and never changes an existing `core.hooksPath`.

**My formatter just rewrote every file. Did I just add 2,000 violations?**
No. Violations are identified by fingerprint (rule + file + normalized line text), not by line number. gauntlet's own test suite includes "reformatting a whole file changes no verdict".

**Can the agent just raise the baseline?**
No. The baseline is derived: CI re-measures and requires an exact match. Loosening a rule needs a human-signed exception, and the runner checks for one in every harness, not only in harnesses with an adapter.

**What if the agent really needs an exception and I'm asleep?**
It stops, leaves the exact `gauntlet waive …` command with its reason, and notifies you. It does not work around the gate.

**Why bash and awk?**
They run everywhere git runs, including Windows' Git Bash. There is no toolchain to install, and the runner stays small enough to read.

**Why not just use my linter's baseline feature?**
If your project has one linter and no agents, that may be enough. gauntlet adds:
- one ratchet across all your linters and structural rules;
- the new-violation and touched-file checks;
- human-only exceptions;
- the agent onboarding.

**Does it work for an empty repo?**
Yes. Onboarding asks about your stack and architecture instead of inferring them. The baseline starts at zero, and every file is born clean.

**Is the case-study data from gauntlet?**
No. It comes from the hand-built process gauntlet was extracted from. The [case study](case-study.md) says so up front.
