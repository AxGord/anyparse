## Standing principles of the slice workflows (the maintainer's decisions; they go into the brief of every slice, never re-asked)

1. **The work is done by hxq, not by hand.** Introducing `import.hx` = `hoist-common-import --fix` + `redundant-import --fix`; L0+ =
   `hxq move-member`/`patch`; moving modules = `hxq move`. A refusal or a corruption by an op is a TOOL DEFECT, fixed in the op
   (in the slice or as a backlog line); working around it by hand or with a python script is forbidden. The exit of an
   introduction: 0 manual edits in the diff.
2. The hoist threshold: an import in ≥ 50 % of a folder's files; the value lives in `apqlint.json`, not in a constant. Provisional —
   revisited by the readings.
3. `test/` is in scope from the start.
4. `using` in `import.hx` — only `StringTools` and `Lambda` (an allow-list in the rule's config); a project's own `using` stay explicit.
5. Nested `import.hx` are allowed; the threshold counts what the parent folder already inherits.
6. **Generalise**: ambient imports are not a Haxe special case (C# `global using`, Kotlin default imports, Rust/Scala prelude) → a seam in
   `GrammarPlugin`; no literals `'import.hx'` / Haxe kinds in `anyparse.query` / `anyparse.check` (invariant 4). No
   process-scoped caches (invariant 1): the chain of ambient files is RUN-scoped.
7. Types extracted from a scan are the scan's PUBLIC API, without `@:access`; the existing scans are not renamed; no package-wildcard
   imports; the L3 level is the maintainer's decision after a recount of its price on the current tree.
8. The earlier principles stay: a comment = an invariant / a contract / a "why", no numbers and no SHAs; a refuted hypothesis → one
   line of `docs/decisions.md`; a refactor does not change behaviour (suite Δ0 except the added tests, corpus Δ0, the linter's findings
   on `src` + `test` and on a sibling tree identical by name, fmt 0); a `control` pin carries a `@:killer` arm; NEVER PUSH; trees outside
   the repo are read-only; do not edit `~/.claude/skills/**`, `.claude/hooks/*` or the root `CLAUDE.md` (put the text in the report).
9. **Text of a language with a grammar is not parsed by hand** (the maintainer, 2026-11-08: "if the agents do not start using this idea, we will write parsers forever"): a char loop, indexOf/split or keyword test over source text to find what a construct is or where it ends is parsing outside the engine. Read the AST node or grammar declaration that knows it, or say in the report why none exists.
