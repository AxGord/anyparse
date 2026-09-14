# docs/ — what each file is for

Every file under `docs/` has ONE of five roles, and the role decides what may be written into it:

| role | what it holds | who reads it | numbers? |
|---|---|---|---|
| **reference** | a contract: what a component, gate or command proves, its rules, how to run it — current tense, short | agents, every session | never — a reading belongs in the commit message and the journal |
| **journal** | readings of one tree at one moment, slice narratives, campaign tables — moved verbatim out of a reference, under the heading they were written for | nobody by default; `git log -S` and the ledger's citations | yes, stamped with the tree they measured |
| **ledger** | one line per refuted hypothesis: what → why not → the commit with the detail | anyone about to have the same idea | the SHA only |
| **roadmap** | phases, deliverables, exit conditions | the session boundary | counts go stale within a slice — the authoritative counts are the gates' own output |
| **archive** | closed slice histories, kept whole | nobody by default | yes, cold |

A contract lives in ONE place. When a class doc owns it (a registry's record shape, a check's refusals, a command's flags), the reference names the class and says what the reader gets there; it does not retell it. Sizes below are `wc -c` readings of the tree this table was written on.

## The map

| file | role | size | overlaps with code | purpose |
|---|---|---:|---|---|
| [`architecture.md`](architecture.md) | reference | 37 KB | `anyparse.macro.*` (the five passes), `anyparse.core.CoreIR` (the primitive list), `anyparse.core.Doc` / `Renderer` (the probe-family table lives HERE, the class points at it), `anyparse.runtime.*` | the full technical model: CoreIR, strategies, formats, runtime, writer, the two compilation modes |
| [`design-principles.md`](design-principles.md) | reference | 13 KB | the invariants code comments link to (§ 2 for RUN-scoped state) | each non-negotiable invariant with the pain point that motivates it |
| [`cross-family-contract.md`](cross-family-contract.md) | reference | 7 KB | (Phase 5+ family IRs — none yet) | the structural round-trip invariant between language families |
| [`strategies.md`](strategies.md) | reference | 31 KB | `anyparse.core.Strategy` (the member contract lives on the interface), `anyparse.macro.strategy.*` (each tag's argument forms live on the class), `unit.lowering.FmtFlagOwnershipTest` (reads the `@:fmt` inventory block from this file) | the strategy plugin picture: which tags each strategy owns and where its slots are consumed, the `@:fmt` inventory and ownership table, what a macro-module split has to pass |
| [`formats.md`](formats.md) | reference | 12 KB | `anyparse.format.Format` / `text.TextFormat` / `binary.BinaryFormat` (the member lists live on the interfaces), `JsonFormat`, `SExprFormat`, `ArFormat` | the format plugin picture: families, literals and policies, separate from schema; one class per format |
| [`haxe-format-config.md`](haxe-format-config.md) | reference | 40 KB | `HaxeFormatConfigLoader`, `HxFormat*Section` (the schema), `HxModuleWriteOptions` / `WriteOptions` (a knob's contract lives on its field; the table here is the index) | the `hxformat.json` values the Haxe writer accepts, per key, and why an unknown one is silent |
| [`testing.md`](testing.md) | reference | 129 KB | `testkit.TestDiscovery` / `MutationArms` / `ProseClaims` (registry contracts), `tools/battery.sh`, `tools/suite-shard.sh`, `tools/mutation-check.sh`, `tools/mutation-arm.sh`, `tools/tmp-lifecycle.sh`, `tools/JvmPortability.hx`, `anyparse.check.OracleCache` / `OracleCoverage`, `LintFixSafePass` | the six test layers, the registries (pins → arms, claims, bases, dead-test guard), the battery, shards, parallel tracks, `resolutionRoots`, the jvm probe — what each proves and how to run it |
| [`cli-query-tool.md`](cli-query-tool.md) | reference | 86 KB | `anyparse.query.cli.CliRegistry` (the command list), every `cli/command/*.hx` (`--help` is the flag reference), `anyparse.query.Address` / `Selector` / `Pattern` / `Matcher`, `format/json/*` (the JSON schemas) | the `apq` / `hxq` contract: exit codes, every registered command with its synopsis and refusals, pattern / selector / addressing syntax, JSON schemas, the universalization invariant |
| [`cli-query-phase0-queries.md`](cli-query-phase0-queries.md) | reference | 10 KB | `anyparse.query.Pattern` (the frozen v1 syntax) | the ten hand-written queries the v1 syntax was frozen against |
| [`cli-query-roadmap.md`](cli-query-roadmap.md) | roadmap | 13 KB | — | the phased delivery plan of the CLI (phases 1–4 shipped; target lines are the original plan) |
| [`roadmap.md`](roadmap.md) | roadmap | 17 KB | — | the platform's phases, deliverables and exit conditions |
| [`decisions.md`](decisions.md) | ledger | 41 KB | — | one line per refuted hypothesis, with the merge SHA that holds the detail |
| [`journal/testing-log.md`](journal/testing-log.md) | journal | 321 KB | — | every reading and campaign narrative `testing.md` condensed, verbatim, under its origin section |
| [`journal/cli-query-log.md`](journal/cli-query-log.md) | journal | 125 KB | — | every reading and narrative `cli-query-tool.md` condensed, verbatim, under its origin section |
| [`journal/architecture-log.md`](journal/architecture-log.md) | journal | 11 KB | — | what `architecture.md` condensed: the `#if` raw-region census, the CLI migration chronicle, the superseded CoreIR / strategy / runtime listings |
| [`journal/strategies-log.md`](journal/strategies-log.md) | journal | 26 KB | — | what `strategies.md` condensed: the `@:fmt` census readings and the module-split narrative, the original per-strategy prose |
| [`journal/formats-log.md`](journal/formats-log.md) | journal | 8 KB | — | what `formats.md` condensed: the verbatim interface listings and the inheritance example the code refuted |
| [`journal/haxe-format-config-log.md`](journal/haxe-format-config-log.md) | journal | 28 KB | — | what `haxe-format-config.md` condensed: the per-slice measurements behind each key, the original key table |
| [`journal/design-principles-log.md`](journal/design-principles-log.md) | journal | 3 KB | — | what `design-principles.md` condensed: the JVM-thread and process-fan-out readings |
| [`archive/roadmap-phase3-slices.md`](archive/roadmap-phase3-slices.md) | archive | 211 KB | — | the Phase 3 slice history, closed |
| [`archive/cli-query-phase5-slices.md`](archive/cli-query-phase5-slices.md) | archive | 96 KB | — | the CLI Phase 5 dogfood history, closed |

## Where a new sentence goes

- A rule, a command, what a gate proves → the reference that owns the component; if a class doc already states it, link the class instead of restating. The split: an API's contract (what a class, field or handler does, its arguments, its refusals) lives in the code at the API; the architectural picture (how the pieces fit, the pipeline, the invariants, why) lives here. Where the two disagree, the code is the behaviour — fix the doc and put the refutation in `decisions.md`.
- A number, a duration, a tree SHA, a "measured on …" → the commit message, and the journal under the reference section it was taken for (`## From § <heading>`).
- "We tried X, measured Y, so no" → one line in `decisions.md`.
- A phase boundary → `roadmap.md`.
- A comment in code → an invariant, a contract, or a non-obvious "why", in one to three sentences; `doc-measurement-claim` and `doc-length` are the lint half of that rule (`cli-query-tool.md` § "The report-only rules that read comments").
