---
match: ^(.+):([0-9]+)(:[0-9]+)?(: ?(.*))?$
path: 1
line: 2
message: 5
---
Built-in format for `path:line[:col][: message]` output: `eslint --format unix`, `ruff --output-format concise`, `golangci-lint` and most compilers.

```sample
src/a.ts:7:3: bad thing
src/lib/x.ts:12: no unused
```

```expected
src/a.ts	7	bad thing
src/lib/x.ts	12	no unused
```
