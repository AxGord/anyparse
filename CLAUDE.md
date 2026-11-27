# anyparse — project context for Claude

## What this project is

anyparse is a **platform** for building parsers, writers, pretty-printers and AST transformers for arbitrary formats and languages. It is implemented as a Haxe library with macro-based code generation.

The fundamental claim: describe a format or language declaratively (grammar as Haxe types with metadata) and the macro generates a specialized, fast, thread-safe parser and writer for it. Adding a new format or language is a plugin package, not a core change.

## Non-negotiable architectural invariants

Every code decision must respect these; the motivating pain point behind each lives in `docs/design-principles.md`:

1. **Zero global mutable state — in the GENERATED code, and only there.** Generated parsers, writers and strategies hold no `static var`; state lives in the `Parser` ctx. The runtime *around* them does keep process-scoped caches (`SharedParseTier`, `FormatConfigDiscovery.CACHE`, `HaxeQueryPlugin.extMethodsCache`, the walker memo), and they make a parallel parse inside ONE process silently corrupting (measured: 8 JVM threads lost half the nodes with zero exceptions; hxcpp segfaults at n≥4). **So parallelism = PROCESSES** (fan-out measured ~3.1x, knee at 4). Anything holding per-run state must be RUN-scoped; a new process-scoped cache is a regression even when it is faster. Full detail: `docs/design-principles.md` § 2.
2. **Pure Haxe, no JVM dependency** — targets are neko, js/node, and eventually hxcpp.
3. **One AST, one writer** — no two-pass pipelines where a writer's text is re-parsed and reformatted; writer and formatter are one component on typed AST through the Doc-based pretty printer.
4. **Grammar as plugin** — grammars live in their own packages, compile against the core without touching it; a new language is a new package, not a core change.
5. **Format and schema are separate** — a format describes what a file looks like; a schema describes what a document means; the macro combines format + schema into a specialized parser.
6. **Declarative format description, not hidden profiles** — `@:schema(JsonFormat)` points at a real Haxe class read at compile time; no metatags with hidden built-in meaning.
7. **Cross-family round-trip contract** — CoreIR must support structural round-trip between language families; any family-specific leakage into CoreIR is a bug. See `docs/cross-family-contract.md`.
8. **Two compilation modes per grammar: Fast and Tolerant** — Fast: bare types, throw on error, for batch parsing. Tolerant: wrapped types with spans and error collection, for IDE/refactor tools. Two generated parsers from one grammar, chosen at the call site.

## Deeper reference (in docs/)

[README.md](docs/README.md) maps every doc and where a new sentence goes. Most read: [testing.md](docs/testing.md) (test layers, registries, battery, slice gate), [cli-query-tool.md](docs/cli-query-tool.md) (apq/hxq contract), [design-principles.md](docs/design-principles.md) (each invariant), [architecture.md](docs/architecture.md), [strategies.md](docs/strategies.md), [formats.md](docs/formats.md), [cross-family-contract.md](docs/cross-family-contract.md), [roadmap.md](docs/roadmap.md), [guide/](docs/guide/README.md) (user reference; a feature is documented there). Readings: [journal/testing-log.md](docs/journal/testing-log.md), [journal/cli-query-log.md](docs/journal/cli-query-log.md). [decisions.md](docs/decisions.md): append only via `node bin/dev.js decision`, `grep -n`, never read whole.

Placement: where a new piece of knowledge goes (docs, memory, skills, workflows) — [docs/README.md](docs/README.md) § Where a new sentence goes.

**Scope, strategic framing, current phase, architecture at a glance, session handoff, references and the parent/curator commands** live in [project-context.md](docs/project-context.md). Read it before planning work, reviewing scope or proposing a queue line. The one-line rule: anyparse is a PLATFORM. A decision must serve a concrete validation case (ax3, haxe-formatter) AND generalize to the next ten formats; never narrow the scope.

## Working on this project

### Commands

```sh
haxe test-js.hxml && node bin/test.js   # build + run the whole suite (~10 min as one process; `dev shard` / the gate ~2–3 min); js/node is the ONLY runner
node bin/dev.js shard -n 4              # same suite across 4 processes, parity-gated; mid-slice only (build: haxe tools/dev.hxml)
haxe bin/apq-js.hxml                    # rebuild the apq/hxq CLI engine (bin/apq.js) + its code-cache launcher, then warm bin/apq.js.v8cache; HXQ_CODE_CACHE=0 bypasses it
node bin/dev.js jvm-portability          # static-target probe: BUILD + RUN, exits 1 unless its gate holds
node bin/dev.js worker-build <dir>       # private apq.js + test.js
node bin/dev.js tmp-lifecycle --list     # the tools' scratch directories (or --sweep)
node bin/dev.js slice-gate <worktree> [--baseline]   # a wave worker's ONLY gate: every check in one <=15-line table (docs/testing.md § "The slice gate")
hxq owner "<question>" src               # find the component that already answers a question
node bin/dev.js decision --slice <ID> "<text>"   # the ONLY way to add a docs/decisions.md line (appends, never reads the file)
APQ_CENSUS_RECORD=1 APQ_TEST=unit.check.BuiltinFixClassCensusTest node bin/test.js   # record an ADDED builtin rule
haxe tools/dev.hxml && node bin/dev.js --help   # developer CLI (tools/src/dev on tools/src/devkit): scrub-guard, clone-census
node bin/dev.js battery [--allow-blast] [--snapshot]   # end-of-slice gate; needs ANYPARSE_HXFORMAT_FORK
hxq lint <file> --all --no-oracle       # edit-loop lint (~5s); NEVER for a gate
hxq patch F.hx --select … --write --fix # write, then safe-fix the lines the write changed
hxq changed <base>..<tip> [paths]       # a change classed by meaning per file: layout / imports / renamed / declarations (+/−/~ by name)
apq get <file|-> <path>                 # value at a dotted path of a JSON document (`a.0.b`; `\.` a dot in a key)
```

Rules behind the commands (detail and measurements: `docs/testing.md`):

- Both hxml files pass `-D analyzer-optimize`; after editing macro-driven `src/`, rebuild **both** `bin/apq.js` and `bin/test.js` (and `bin/dev.js` after touching `ShardPlan`/`TestTranscript`/`MutationVerdict`/`BuildFailure`, which it compiles in) — a stale one makes probes lie.
- hxq runs the engine through `bin/apq-launch.js` and a V8 code cache beside the binary (worker builds too). The cache is keyed by the engine's bytes, real path, node build and flags, and checksummed, so a stale or damaged one is never used. A typecheck (`--no-output`) of `bin/apq-js.hxml` runs no warm step and writes nothing. Detail: `docs/cli-query-tool.md` § "Launch and the code cache".
- `--no-oracle` is for iteration only: with a `compilerOracle` configured every lint runs a project-wide build (~18s of ~24s). A gate (battery, pre-commit lint, anything whose output is a verdict) always runs with the oracle. `--fix` on a write op forces `--no-oracle` and applies only the SAFE half of the fixer.
- `apq.json` declares `"resolutionRoots": ["src", "test"]` so a narrow lint still answers over the whole project (the reflection guards need it; without it a one-file `--fix` erased a name a sibling read reflectively). Nested configs inherit the root's keys and declare only what changes.
- Developer scripts are Haxe on `tools/src/devkit`: `cmd('git log $range')` reads its template into argv at compile time — no shell, no quoting; every process goes through `HaxeSpawn`. python/jq/awk are leaving `tools/` (queue track TOOLS). A tool's tests are ordinary suite tests in `test/unit/devkit` / `test/unit/dev`.
- The core stays target-independent: run the `--jvm` probe after any slice touching `src/`. The probe **compiles** what `-main JvmPortability` reaches (`src/anyparse/query/cli` contributes nothing — a green probe after a `cli` slice proves it compiles for js only) and **lints** `src/anyparse/query` + `src/anyparse/check`. Its `gate:` line is the verdict (`wrote == files`, `threw == 0`; `lintdiff=1+0-` is its own self-test); its `census @ <commit>` line is a reading of THAT tree — measure it on your own base, never quote one.
- Prefer `node bin/dev.js shard` mid-slice; keep a plain `node bin/test.js` for the final pre-commit run (shards change class order and add concurrency).

### Code rules

- Don't store a constructor argument in a field only to convert it back later — use the parameter.
- Never `@:nullSafety(Off)` as a workaround; if stuck, ask the user.
- Text in a language this project has a grammar for is never parsed by hand: read the AST node, or declare the construct in the grammar and generate the reader. Merging hand scanners into one is not the fix.

### What a comment may say

A code comment is an invariant, a contract, or a non-obvious "why", in one to three sentences.
No measurements: no durations, no tree SHAs, no slice or backlog ids, no before-and-after number
pairs, no counts against a total. A reading is of one tree at one moment — it belongs in the commit
message and in the campaign ledger; the comment keeps the conclusion in a phrase. A refuted
hypothesis goes as ONE line into `docs/decisions.md` (what → why not → slice id), never as a
paragraph in the code — added ONLY by `node bin/dev.js decision --slice <ID> "<text>"` (one line, its text ≤ 300
characters); the file is append-only and hundreds of KB, so search it with `grep -n`, never `Read`/`Edit` it whole; rationale for an invariant links to `docs/design-principles.md` instead of
restating it. Both halves are lint: `doc-measurement-claim` and `doc-length` (`Info`, report-only,
enabled in this project's `apq.json`) — see `docs/cli-query-tool.md`.

### Test framework

utest 1.13.x. Tests live in `test/unit/<pkg>/`, one package per `src/anyparse/*` package — and inside `check` one per subpackage (`test/unit/check/<sub>/` mirrors `src/anyparse/check/<sub>/`, so `APQ_TEST=unit.check.scan.` selects it; rules live in `check/common/<category>/`, their tests in `test/unit/check/common/<category>/`, so `APQ_TEST=unit.check.common.imports.` selects one category); a test's package is that of the SUBJECT it exercises, and `hxq move` carries a module's own test along (`apq.json` `move.mirrors`). Runner: `test/RunTests.hx`.

- **Registration is GENERATED**: `testkit.TestDiscovery` registers every `utest.ITest` class with a `test*`/`spec*` method — a new test needs NO runner edit and NO list: it is a file `*Test.hx` holding exactly one test class (its main type). Every `*Test.hx` must register a class and every registered class must live in its `*Test.hx`, else a BUILD ERROR naming the file; a helper or base never ends in `Test`. A private / abstract / sub-module / ctor-taking test class is a BUILD ERROR, never a silent skip. `--list-classes|--list-dead|--list-bases|--list-pins|--list-arms` print the registries.
- **Pins and arms**: `@:pin('control')` MUST carry a `@:killer('<ARM>')` naming a record in `test/testkit/arms/<package>.json` (one document per package of the arm's type) that kills it (`guard`/`seam` need not); a `control` naming no arm, a `@:killer` naming no declared arm, or an arm whose member is gone fails the build. An arm = type + member + cut (`force` or `find`/`replace`, both `hxq patch` payloads). `node bin/dev.js mutation-arm <NAME> | --all [--fast | --check-apply]`; a slice's gate runs its own arms plus every arm on a type it touched (`--fast`, chosen by `dev slice-gate`), `--all` is a release or overnight run. `find`/`replace` arms rot invisibly — only a RUN finds it. Details: `docs/testing.md` § "Declared arms".
- **Fast inner loop**: `APQ_TEST=<substring[,…]>` filters by fully-qualified class name (`APQ_TEST=unit.check.` runs a whole family, ~4s). Always run unfiltered before committing. The corpus harness runs only with `ANYPARSE_HXFORMAT_FORK` set and is not the bottleneck.
- **Parallel workers**: `docs/testing.md` § "Parallel tracks" — a worktree per worker, `node bin/dev.js worker-build` / private `bin/`, `HXQ_BIN` pinned (else the lint harness runs the main tree's engine and shows phantom findings).

### Compact instructions

When the conversation is compacted, keep — and drop everything else (it lives on disk):
- the user's standing decisions and prohibitions from this conversation (never push; no commits in a sibling project's tree; no client-project names in anything committed here; window of agents allowed; tokens matter more than time; any "do X / never Y" said today);
- the active workflow session ids with their workflow and state, and every sub-agent id with the slice it drives;
- the queue file `.claude/batch/queue.yaml` (YAML; edit only through the queue tools or `wf-queue`) and the backlog `.claude/batch/hxq-bugs.md` as the source of truth for what is done, running and next — re-read them instead of trusting the summary;
- what is in flight right now (a running gate, land or battery, a pending review verdict) and the one next step.
Drop: agent reports already folded into the queue, gate tables, diffs, file listings, exploration output.
