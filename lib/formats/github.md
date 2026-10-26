---
match: ^::(error|warning|notice) file=([^,]+),line=([0-9]+)[^:]*::(.*)$
path: 2
line: 3
message: 4
---
Built-in format for GitHub annotation lines, the default for `ast-grep`.

```sample
::error file=x.ts,line=1,endLine=1,title=silent-catch::empty catch
```

```expected
x.ts	1	empty catch
```
