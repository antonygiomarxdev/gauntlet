# Security

gauntlet runs shell commands from rule files inside your repository, and installs git hooks. Treat `.gauntlet/` like any other executable code in your repo, and review changes to it.

## Reporting a vulnerability

Please do not open a public issue. Use GitHub's [private vulnerability reporting](https://github.com/antonygiomarx/gauntlet/security/advisories/new). You will get an answer within 7 days.

## Scope

In scope:
- the runner executing something it should not;
- a way to bypass the gate that the docs say is closed;
- unsafe install or update behaviour.

Detectors that a repository's own owners wrote are that repository's responsibility.
