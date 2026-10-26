---
match: ^([^:]+):([0-9]+)(:[0-9]+)?(: ?(.*))?$
path: 1
line: 2
message: 5
ignore: ^[^:]+: binary file matches \(found
---
Built-in format for `path:line[:col][: message]` output: `eslint --format unix`, `ruff --output-format concise`, `golangci-lint` and most compilers. The line `rg` prints for a binary file it matched (`<path>: binary file matches (found "\0" byte around offset N)`) is ignored.

```sample
src/a.ts:7:3: bad thing
data.bin: binary file matches (found "\0" byte around offset 8)
src/lib/x.ts:12: no unused
```

```expected
src/a.ts	7	bad thing
src/lib/x.ts	12	no unused
```
