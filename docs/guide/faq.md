# FAQ

**Will gauntlet break my CI on day one?**
No. Existing debt is measured and accepted as the floor. Write new rules as `shadow` first: a shadow rule reports what it would have failed and never blocks. The touched-file gate starts off. Only new violations of `block` rules fail, and only once you have promoted their rule.

**Will it touch my existing hooks?**
It adds one line to each existing shell hook, placed first, right after the shebang, so the gate runs before anything else in the hook. It never replaces your hooks and never writes `core.hooksPath`. For lefthook and prek, it prints a snippet for you to paste. See [Gates](gates.md#hooks-coexist-never-take-over).

**My formatter just rewrote every file. Did I just add 2,000 violations?**
No. Violations are identified by fingerprint (rule + file + normalized line text), not by line number. gauntlet's own test suite checks that reformatting a whole file keeps the fingerprints the same.

**Can the agent just raise the baseline?**
No. The baseline is derived: CI re-measures and requires an exact match. Loosening a rule needs an exception row that a human wrote, and the runner checks for it in every harness, not only in harnesses with an adapter.

**What if the agent really needs an exception and I'm asleep?**
The runner does not decide what an agent does. The gate stays red until a person runs `gauntlet waive …` on that branch (see [Exceptions](exceptions.md)). The agent's stop-and-notify behaviour is part of the skill, which is planned (IS-02).

**Why bash and awk?**
They need only git, bash and awk, so there is no toolchain to install, and the runner stays small enough to read. Windows is not tested yet.

**Why not just use my linter's baseline feature?**
If your project has one linter and no agents, that may be enough. gauntlet adds:
- one ratchet across all your linters and structural rules;
- the new-violation and touched-file checks;
- human-only exceptions;
- the agent onboarding (planned).

**Does it work for an empty repo?**
Yes. An empty baseline is the starting point, and every file is born clean. Add rules as you need them. The onboarding skill, when it ships, will ask about your stack and architecture first.

**Is the case-study data from gauntlet?**
No. It comes from the hand-built process gauntlet was extracted from. The [case study](case-study.md) says so up front.
