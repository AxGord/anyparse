# Design principles journal

> **Journal, not contract.** Every number here is a reading of one tree at one moment; the
> contract lives in [`docs/design-principles.md`](../design-principles.md). Each block is the ORIGINAL text of a paragraph
> that the reference condensed or dropped, moved verbatim under the section it was written in
> (`From § …` names that section by its heading at the time), in the original order, so
> `git log -S` and the ledger's citations still resolve (the one edit: a link to a sibling doc
> gains `../`, and a same-file `#anchor` gains `../design-principles.md`, since this file lives one
> directory down). A `§` pointer inside moved text names a heading of the reference
> (`docs/design-principles.md`), not of this file. Nothing here is a norm, and nothing here is auto-loaded.

## From § 2. Zero global mutable state — in the generated code, and only there

**What does NOT hold — measured, and the reason this principle was rewritten**: the runtime *around* the generated code keeps process-scoped caches, and they make a parallel parse inside one process unsafe. The offenders are named rather than described: `SharedParseTier` (five static vars), `FormatConfigDiscovery.CACHE`, `HaxeQueryPlugin.extMethodsCache`, and the one-entry root memo the query walker generates (`_memoSource` / `_memoRoot`). Evidence: eight JVM threads produced 247 228 of 479 415 nodes with 132 parse failures and **zero exceptions** — silent corruption, not a crash — while hxcpp segfaults at four threads or more. Handing each thread its own plugin instance does **not** help, because the state is static, not per-instance.

**Consequence**: parallelism is **processes**, not threads. That is a deliberate position, not a defeat — process fan-out is measured at 3.15x with bit-exact output on the target benchmark, and independently at 3.06x on the round-trip workload (2026-08-18), with the knee at four processes and saturation near 3.1x. Note what that is *not*: the earlier claim here read "an 8-core machine gets 8x throughput, not 1x". It does not. Anything that keeps per-run state must therefore be **run-scoped** — an instance field on a wrapper created per lint run or fix run — and adding a fourth process-scoped cache is a regression against this principle even when it is faster.

## From § 6. Parsing loses formatting; writing is `format(ast, options)`

**Rule**: the parser does not preserve whitespace, comments, or stylistic choices (quote styles, trailing commas). The writer regenerates output from AST + FormatOptions. If byte-identical round-trip matters, an optional pass detects options from a sample and passes them to the writer.

**Consequence**: "I parsed this file, modified one line, and want to write it back with minimal diff" is handled by configuring the writer with options that match the original file's style. The detector pass to infer those options from a sample is a small utility, not a core feature.
