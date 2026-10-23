---
match: ^(.+)\(([0-9]+),[0-9]+\): (error|warning) (.*)$
path: 1
line: 2
message: 4
ignore: ^Found [0-9]+ errors?
---
Built-in format for `tsc` diagnostics. The `Found N errors.` summary line is ignored.

```sample
a.ts(1,2): error TS2322: bad
b.ts(3,4): warning TS6133: unused
Found 1 error.
```

```expected
a.ts	1	TS2322: bad
b.ts	3	TS6133: unused
```
