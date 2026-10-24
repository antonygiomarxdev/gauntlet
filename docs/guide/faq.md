# FAQ

**Will gauntlet break my CI on day one?**
No. Existing debt is measured and accepted as the floor. Write new rules as `shadow` first: a shadow rule reports what it would have failed and never blocks. The touched-file gate starts off. Only new violations of `block` rules fail, and only once you have promoted their rule.

**Will it touch my existing hooks?**
It adds one line to each existing shell hook, placed first, right after the shebang, so the gate runs before anything else in the hook. It never replaces your hooks, never deletes a line from them and never writes `core.hooksPath`. For lefthook and prek, it prints a snippet for you to paste. See [Gates](gates.md#hooks-coexist-never-take-over).

**My formatter just rewrote every file. Did I just add 2,000 violations?**
Not if it only changes whitespace. A violation is identified by fingerprint (rule + file + normalized line text), not by line number, and only runs of spaces and tabs, line endings and the ends of the line are normalized. Re-indenting, tabs for spaces and CRLF keep every fingerprint; gauntlet's own test suite checks that. A formatter that changes the text of a flagged line (splits it, or changes quotes or punctuation) gives it a new fingerprint, and the gate reports it as new. So does moving a flagged line to another file.

**Can the agent just raise the baseline?**
No. The baseline is derived: CI re-measures and requires an exact match, so a raised baseline fails `check --ci`. A loosened rule fails the gate unless an exception row exists, and the gate checks that in every harness, not only in harnesses with an adapter. The runner cannot tell who wrote a row. Keeping agents from writing rows is the job of the skill and the Claude Code adapter, both planned (IS-02).

**Can the agent just edit the runner?**
A branch can, and the gate it runs is the branch's own copy, so the run cannot judge that edit. What gauntlet does is flag it: `check --ci` prints `note: the vendored runner changed in this branch (.gauntlet/bin or .gauntlet/lib differ from the base); review it`, locally and in CI. Put `.gauntlet/` under `CODEOWNERS` so a person reviews it. To judge a pull request with the runner of its base branch instead, use the optional job in [who CI trusts](gates.md#who-ci-trusts); it costs a mismatch with the hook when a PR upgrades gauntlet.

**What if the agent really needs an exception and I'm asleep?**
The runner does not decide what an agent does. The gate stays red until a person runs `gauntlet waive …` (a path), `gauntlet loosen …` or `gauntlet remove …` (a rule) on that branch (see [Exceptions](exceptions.md)). A waiver clears the new and touched-file lines of its path only: the rule's total must still not rise ([the file](exceptions.md#the-file)). The agent's stop-and-notify behaviour is part of the skill, which is planned (IS-02).

**Why bash and awk?**
They need only git, bash and awk, so there is no toolchain to install, and the runner stays small enough to read. Windows is not tested yet.

**Why not just use my linter's baseline feature?**
If your project has one linter and no agents, that may be enough. gauntlet adds:
- one ratchet across all your linters and structural rules;
- the new-violation and touched-file checks;
- exception rows, which show in the diff;
- the agent onboarding (planned).

**Does it work for an empty repo?**
Yes. An empty baseline is the starting point, and every file is born clean. Add rules as you need them. The onboarding skill, when it ships, will ask about your stack and architecture first.

**Is the case-study data from gauntlet?**
No. It comes from the hand-built process gauntlet was extracted from. The [case study](case-study.md) says so up front.
