# Testing approach

Testing a parser platform is not the same as testing application code. A grammar must behave correctly on inputs its author never thought of, and a writer must produce output that the parser can round-trip. Unit tests alone are insufficient. This document is the CONTRACT of the six-layer testing strategy anyparse adopts: what each layer and each gate proves, the rules the registries enforce, and how to run each one. It quotes no measurement — every reading taken while these rules were built lives in [`journal/testing-log.md`](journal/testing-log.md), under the section it was taken for. Where a contract is owned by a class, the class doc is the contract and this file says where to find it.

## The six layers

| # | Layer | Catches | When to add |
|---|---|---|---|
| 1 | **utest unit tests** | Known cases, regressions for specific bugs | From day one |
| 2 | **Golden file tests** | Regressions on large corpora | When a grammar has 20+ sample inputs |
| 3 | **Property round-trip tests** | Writer/parser asymmetries, edge cases no human thought of | With the first grammar |
| 4 | **Cross-family round-trip tests** | Curly-specific leakage into CoreIR | When family IRs exist (Phase 5+) |
| 5 | **Benchmarks** | Performance regressions between commits | When a grammar has a working macro-generated parser |
| 6 | **End-to-end integration tests** | Full pipeline on real-world data | After Phase 2 |

Layers 1, 2, 3 are required from Phase 1 onward. Layers 4, 5, 6 come online as their prerequisites mature.

## Layer 1: utest unit tests

The workhorse. Each test is a small assertion about a specific input-output behavior.

```haxe
function testParsesSimpleObject() {
  var result = JValueParser.parse('{"x":1}');
  Assert.isTrue(JValueTools.equals(
    JObject([{key: "x", value: JNumber(1)}]),
    result
  ));
}
```

**Catches**: regressions on cases that have been thought of. Each fixed bug becomes a test case, preventing regression.

**Does not catch**: cases that nobody considered. A parser can pass all hand-written tests and still fail on something the author never imagined.

Unit test files live in `test/unit/` with one file per component. Test runner is `test/RunTests.hx`,
and it registers nothing by hand — see "The registration layer is generated" below.

### Which package answers which layer

`test/unit/` mirrors `src/anyparse/*`: **a test class lives in the `unit.<pkg>` that mirrors the
`anyparse.<pkg>` it primarily exercises.** Per-package class counts are a reading of one tree —
take them off `node bin/test.js --list-classes`.

| package | mirrors | layer |
|---|---|---|
| `unit.grammar.haxe` | `anyparse/grammar/haxe` (+ `checkstyle`, `format`) | 1, 3 — the Haxe grammar, its trivia and its writer |
| `unit.check` | `anyparse/check` (+ `config`) | 1 — the analysis/check framework and every rule |
| `unit.query` | `anyparse/query` (+ `format`) | 1 — the hxq engine: ops, addressing, symbol index, resolution |
| `unit.cli` | `anyparse/query/Cli` | **6 — end-to-end**: a test that drives `Cli.run` on a temp file |
| `unit.format` | `anyparse/format` (+ `wrap`, `comment`, `text`, `binary`) | 1, 3 |
| `unit.lowering` | `anyparse/macro` (+ `strategy`) | 1 — `macro` is a Haxe keyword, so the package is `lowering` |
| `unit.grammar` | `anyparse/grammar/{json,ar,sexpr}` | 1, 3 — the small grammars |
| `unit.core` | `anyparse/core` | 1 — the Doc IR and its renderer |
| `unit.runtime` | `anyparse/runtime` | 1 |
| `unit` (root) | — | INTEGRATION and suite hygiene: the classes that answer to no single package |

`unit.miniblock` and `unit.miniblockstrict` carry no test class: they are the mini grammars the Star-primitive tests parse.

**The root is the residue, and it is named.** Suite hygiene (`DeadTestGuardTest`, `TestDiscoveryParityTest`, `MutationArmsTest`, `MutationArmAddressTest`, `ProseClaimCensusTest` — they read `test/` and the registries themselves), `DiscoveryOnlyProbeTest` (the pin that no hand-written line may name), the fixtures that assert two packages AGREE (`LexicalRegionAgreementTest`, `ExtensionMethodsExtractionTest`, `SpanModeProbe` — moving one to either side would name a side), plus the helper modules shared across packages (`SourceTree`, `BuildDefines`, `CheckFixture`, `QueryTestHelpers`, `SeamEdit`).

**What the layout buys.** `APQ_TEST` is a substring filter over the fully-qualified name, so the package prefix IS a selector: `APQ_TEST=unit.check. node bin/test.js` runs every check test and nothing else; `unit.cli.` runs the end-to-end layer alone. `apqlint.json` discovery folds the whole chain nearest-first, so a package may carry its own config relaxing a key for that family only.

**Where a new test class goes.** Ask which `src/anyparse/<pkg>` module it names in its assertions; that is its package. A class exercising two packages at once belongs in the root as integration — and the doc comment says which two, because the root is the one bucket nothing else explains.

## Layer 2: Golden file tests

For a grammar with many sample inputs, hand-writing unit test cases becomes tedious. Golden file tests replace assertions with input/output file pairs:

```
test/golden/json/
├── simple_object/
│   ├── input.json
│   └── expected.ast
├── nested/
│   ├── input.json
│   └── expected.ast
├── ...
```

A small test harness walks the directory, parses each `input.*`, serializes the AST, and compares against `expected.ast`. On first run, a `--update-goldens` flag generates `expected.ast` files. On subsequent runs, differences show as diffs in the test output.

**Catches**: regressions on any case in the corpus, even cases added by other developers or downloaded from the internet. Scales to hundreds or thousands of inputs without writing new test code.

**Does not catch**: bugs in cases nobody has added yet.

**Not yet in Phase 1.** Will be added when the first grammar has enough samples to justify the harness (~100 lines of Haxe on top of utest). The user's haxe-formatter fork test corpus is a natural first source of golden files when Phase 3 begins.

## Layer 3: Property round-trip tests

This is the most valuable single category for a parser project. The property is simple:

> For any valid AST, `parse(write(ast)) == ast`.

If this holds on a large number of randomly generated ASTs, the parser and writer are consistent with each other. If it fails, either the writer produces text the parser cannot read, or the parser reads text into a different AST than the writer intended, and the test shows you exactly which AST triggers the failure.

```haxe
function testRandomCases() {
  var rng = new SeededRng(42);
  for (i in 0...200) {
    var ast = randomValue(rng, depth: 4);
    var written = JValueWriter.write(ast);
    var reparsed = JValueParser.parse(written);
    Assert.isTrue(JValueTools.equals(ast, reparsed), 'round-trip failed: ast=$ast, written=$written');
  }
}
```

**Catches**: bugs nobody thought of. The random generator produces cases like "a string with a backslash immediately before a close quote inside an array that is itself the value of a key with special characters" — cases that are incredibly unlikely to be in any hand-written test.

**Does not catch**: bugs on input the writer would never produce. If the parser accepts malformed input that the writer never generates, the round-trip test cannot see it. Layer 1 and Layer 2 cover that gap.

**Seeded generator**: use a seeded PRNG so that failures are reproducible. A failure on seed 42 at iteration 137 should always fail the same way when rerun. No wall-clock-seeded randomness in tests.

**Every grammar gets one**. When a new grammar is added, a round-trip test is part of the pull request. No grammar is "done" until it has passing round-trip tests.

Already in place: `test/unit/grammar/JsonRoundTripTest.hx`, a curated set plus seeded random cases (both write and parse go through the macro-generated pipeline).

## Layer 4: Cross-family round-trip tests

Specific to the cross-family contract described in `cross-family-contract.md`. Validates that CoreIR has no family-specific assumptions by round-tripping programs through two different family IRs (curly ↔ Lisp) and asserting structural equivalence.

```haxe
function testCurlyLispRoundTrip() {
  var source = "class Point { public var x:Float; public var y:Float; }";
  var ast1 = HaxeParser.parse(source);
  var curlyIr = HaxeAst.toCurlyFamily(ast1);
  var lispIr = CurlyLispBridge.toLisp(curlyIr);
  var clojureAst = LispFamily.toClojure(lispIr);
  var clojureSource = ClojureWriter.write(clojureAst);

  var clojureAst2 = ClojureParser.parse(clojureSource);
  var lispIr2 = ClojureAst.toLispFamily(clojureAst2);
  var curlyIr2 = CurlyLispBridge.toCurly(lispIr2);
  var ast2 = CurlyFamily.toHaxe(curlyIr2);

  Assert.isTrue(AstEquivalence.semanticallyEqual(ast1, ast2));
}
```

**Catches**: any CoreIR primitive that encodes a curly-specific assumption. When the test fails, the bug is in CoreIR (or in one of the family IRs or the bridge), not in the grammar.

**Will be added in Phase 5+** when the first non-curly grammar ships. Until then, the contract is a design-time discipline — every CoreIR primitive proposal gets reviewed with "how does this project onto Lisp?" as a check.

## Layer 5: Benchmarks

Not unit tests. Separate binaries that measure throughput and memory on realistic inputs. The goal is to detect performance regressions between commits and to compare anyparse against the tools it is replacing (haxe-formatter, ax3, native `JSON.parse`).

Benchmarks target each Haxe backend separately because performance differs significantly:
- `tools/parse-prof.hxml` — Node.js, the target everything ships on today
- `tools/bench-hxcpp.hxml` — native, the same `tools/ParseProf.hx` over the same
  `src/` with the same `-D analyzer-optimize`, so the two arms differ only in
  the backend

Neko is not a benchmark target: the neko build of the CLI compiles but its artifact dies at module load. `--jvm` builds and runs the core fine, but it is a portability probe, not a delivery target.

Each benchmark outputs structured JSON with throughput, timing breakdowns, and memory usage. CI collects these and compares against a baseline.

**Benchmarks are not in Phase 1.** They matter starting from Phase 2 when a macro-generated parser has a baseline to measure against. Phase 3 (Haxe formatter) and Phase 4 (AS3 converter) are where benchmarks become critical.

### The profiling harness

`tools/ParseProf.hx` builds straight out of `src/` with the flags the shipped CLI uses, so what you profile is the codegen that ships:

```sh
haxe tools/parse-prof.hxml                                  # -> bin/parse-prof.js
node bin/parse-prof.js tparse src 1 hxformat.json
node --cpu-prof --cpu-prof-interval=200 bin/parse-prof.js rt src 3 hxformat.json
```

The native twin is `tools/bench-hxcpp.hxml`. Point `HXCPP_COMPILE_CACHE` at a persistent directory (or every build is cold), and pass the binary to `tools/bench-ab.sh` as any other arm — an arm path that does not end in `.js` is executed directly instead of under `node`:

```sh
HXCPP_COMPILE_CACHE=~/.hxcpp_cache haxe tools/bench-hxcpp.hxml   # -> bin/parse-prof-cpp/ParseProf
TM_SRC=<other-tree>/src tools/bench-ab.sh tparse tools/bench-corpus.txt 9 6 \
  js:bin/parse-prof.js cpp:bin/parse-prof-cpp/ParseProf
```

There is no `--cpu-prof` on a native binary; the equivalent is macOS `sample`, and it needs symbols the release link strips. Rebuild the SAME objects with `-D no_gcc_strip` into a scratch output (the compile cache makes it a relink, so the code being sampled is the code that was timed), then sample the run; read the capture per THREAD, since hxcpp's idle GC threads swamp the flat list, and resolve `??? + 0x<offset>` frames against `nm -n` with a `0x100000000` base:

```sh
haxe -cp src -cp tools -main ParseProf -D analyzer-optimize -D no_gcc_strip -cpp /tmp/pp-sym
/tmp/pp-sym/ParseProf tparse tools/bench-corpus.txt 90 hxformat.json & sample $! 30 1 -f /tmp/pp.sample
```

Arguments are `<mode> <dir-or-manifest> [reps] [hxformat.json]`; a directory is walked for `.hx`, anything else is read as a manifest of paths with `#` comments and `${NAME}` environment expansion (`tools/bench-corpus.txt` is the calibrated one). The modes stack from the IO floor upwards — `read`, `tparse` (Fast-mode parser), `walk` (plus the `QueryNode` projection), `write` (writer alone, with the feeding parse subtracted), `rt` (exactly what `hxq fmt` runs), `lint`, and `perfile` for a per-file TSV that feeds corpus stratification. Each workload runs inside its own `phaseXxx` function so a V8 `--cpu-prof` tree can be attributed by nearest phase ancestor.

Measurement hygiene lives in `tools/bench-ab.sh`, and the rule it exists to enforce is that a before/after pair timed minutes apart on a shared machine drifts by more than the effects being measured: arms are interleaved and the per-arm median is what gets quoted. Battery timings are the opposite kind of number — deliberately concurrent wall clock — and must never be quoted as benchmark results.

### Reading a capture: `tools/ProfTop.hx`

A `.cpuprofile` is a call tree, not a report. `ProfTop` rolls one up by SELF time per function and prints the top rows:

```sh
node --cpu-prof --cpu-prof-dir=/tmp/prof --cpu-prof-interval=200 \
  bin/parse-prof.js tparse tools/bench-corpus.txt 2 hxformat.json
haxe -cp tools --run ProfTop /tmp/prof/*.cpuprofile 20
haxe -cp tools --run ProfTop /tmp/prof/*.cpuprofile 10 --under phaseWrite
```

No build step — it is a `--run` script over the std library (`--interp` does not work: it eats the trailing arguments as its own). Self time comes from `samples` + `timeDeltas` rather than `hitCount`, so a custom `--cpu-prof-interval` still reports real microseconds. `--under <fn>` narrows the rollup to samples whose stack passes through a frame of that name; it matches the rendered row label, and Haxe class names do not survive into JS frame names, so `--under phaseWrite` works where `--under CompilerServer` matches nothing.

Two reading rules. **`spawnSync` and friends are BLOCKED WAIT, not CPU**: a profile samples whatever frame is on the stack, and a synchronous child-process call sits there for the whole child's lifetime, so a fat `spawnSync` row says "we waited on children" and optimising our own code cannot shrink it. And read a profile for SHARES, taking deltas from a separate unprofiled run: `--cpu-prof` overhead is not uniform across trees, so a profiled before/after pair is not a delta.

## Layer 6: End-to-end integration tests

Full pipeline tests on real-world data. Take a substantial input (the user's ax3 corpus, a large Haxe project, a corpus of JSON API responses), run it through the full pipeline (parse → transform → write), and compare against an expected output.

**Catches**: interactions between multiple parts of the platform that unit tests miss. Grammars, transforms, writers, and formatters interact in ways that are impossible to cover fully with unit tests.

**Added at Phase 4 onwards**, specifically for the AS3→Haxe conversion replacing ax3. The user's ~2000-file corpus is the canonical integration test: the new tool must produce equivalent Haxe output on every file, ideally faster than ax3 and without JVM.

## Proving a comment-only change inert: the build is NOT a byte oracle

A change that touches only comments should leave the compiled output alone, and the obvious way to show it is to build both revisions and `cmp` them. That does not work here, and the failure is silent: **the Haxe build is not reproducible** (§ "The JS build is not reproducible — a binary `cmp` needs the base built TWICE"), so an equal pair of revisions is one lucky draw, not a proof — and an unequal pair proves nothing either.

Two oracles that do hold, and the discipline both need:

- **Comment-stripped hash per file.** Strip comments with a string-aware scanner (a naive one eats a `//` inside a string literal), collapse whitespace, hash. Compare the touched files against their base revision.
- **The line MULTISET of the generated JS.** Count lines of `bin/test.js` on both revisions and diff the counters. Stable across rebuilds, because the non-determinism only regroups existing lines; a real code change still shows up.

**Self-test both.** Inject a one-token code mutation — flip a boolean argument, rename a ctor parameter — and confirm the method reports it; then edit a comment and confirm the method stays silent. A method that has not been shown to catch anything is not evidence. The other half of the discipline is the binary you compare against: after a self-test mutation, REBUILD before using that tree as a baseline again, or the "base" you compare with is the mutant.

Neither oracle sees prose, and prose is where such a slice actually breaks things: moving a documented table out of a source file leaves every comment that named its old home pointing at nothing, and no gate in this project reads a cross-reference. Scan the tree for the old location's name after any such move.

## Mutation checks: testing the tests

The six layers all answer the same question from different angles: does the code do what it is supposed to do? A mutation check asks the inverted question: if the code *stopped* doing it, would anything go red? A green suite is not evidence that the suite covers anything — a mechanism can be exercised by no fixture at all and still sit inside a passing run, and the only reliable way to find such a vacuum is to break the mechanism on purpose and watch what the suite does.

### The runner

```sh
tools/mutation-check.sh <manifest> [--jobs N]
```

Each *track* in the manifest is one deliberate breakage. The runner gives every track its own git worktree checked out from `HEAD`, applies the track's patch there, builds a private test runner into a private workdir (`tools/worker-build.sh`, see "Parallel tracks" below), runs the requested slice of the suite with the CWD set to that worktree, and classifies the transcript. Tracks run in parallel; `--jobs` defaults to `max(1, min(4, cores/2))`, and an explicit `--jobs` must be a positive integer (every spelling of zero is rejected rather than clamped, since `xargs -P 0` means unbounded).

Because worktrees come from `HEAD`, uncommitted work in the main tree is invisible to a track: a mutation aimed at uncommitted code has to be committed first, folded into the patch, or run under `--working-tree` (below). `ANYPARSE_HXFORMAT_FORK` is unset for the run on purpose: the corpus harness is not what a track measures, and a verdict must not depend on the caller's shell. Every worktree the runner created is removed on exit, including on `INT`/`TERM`/`HUP` (a stuck one can survive as a registered entry — `git worktree list` after a crashed run); the workroot is kept on a non-`KILLED` verdict with its path printed (§ "Scratch directories: every tool's, and who removes them").

### Manifest format

Line-oriented, `|`-separated, four fields, whitespace around fields trimmed. Blank lines and lines starting with `#` are ignored.

```
<name> | <patch-file> | <APQ_TEST filter> | <expected>[,<expected>...]
```

| Field | Meaning |
|---|---|
| `name` | Track id, `[A-Za-z0-9_.-]+`, unique in the manifest. Names the worktree directory and the report row. |
| `patch` | A git patch — literally `git diff` output — applied with `git apply` inside the worktree. Resolved relative to the **manifest's own directory** (absolute paths pass through), so a manifest and its patches move as one bundle. |
| `filter` | Required, non-empty. Passed as `APQ_TEST`. The literal word `ALL` runs the whole suite with `APQ_TEST` unset. |
| `expected` | Comma-separated substrings, may be empty. Each is matched against the collected failure names, which have the form `<fq.ClassName>.<testMethod>`. |

Break the mechanism in the main tree, `git diff > x.patch`, revert, add a manifest line. **Give every track a narrow `APQ_TEST` filter**: `ALL` pays the entire suite for one mutation and drags in cases whose outcome depends on the environment rather than on the mutation.

### Verdicts

| Verdict | Meaning |
|---|---|
| `SURVIVED` | The run came back **green** — utest's own `results: ALL TESTS OK (success: true)`. **This is the finding the tool exists for.** |
| `KILLED` | The run went red, and every expectation matched something. No expectations given means any red kills. |
| `MISMATCH` | The run went red, but at least one expectation matched nothing — the suite noticed, just not where the track claimed it would. |
| `NO-TESTS` | The filter matched no test class. Loud on purpose: a typo'd filter otherwise reads as `SURVIVED`. |
| `WT-FAIL` | `git worktree add` failed — there was nothing to patch or run. |
| `PATCH-FAIL` | `git apply` failed. Manifest or patch defect. |
| `BUILD-FAIL` | The patched tree does not compile. A mutation the compiler rejects proves nothing about the suite. |
| `RUN-FAIL` | No usable transcript, or a red header whose result rows the parser could not name. |

`SURVIVED` is deliberately stricter than "nothing failed": utest auto-adds a `Warning('no assertions')` to a method that completes without asserting and computes `isOk` over warnings too, so the verdict comes from the header line and the per-class rows only *name* what went red. A marker the classifier does not recognise surfaces as `RUN-FAIL`, never as `SURVIVED`.

**The classifier is `apq mutation-verdict`, not the script** (`apq mutation-verdict <transcript> [--expect <csv>]` — line 1 the verdict, line 2 the row detail). It is pure over `TestSummaryResult` and covered by `test/unit/query/MutationVerdictTest.hx`; a shell function is not testable, which is why no second transcript parser may grow inside a script. It runs from the **main** tree, never from the track's own build — a track's engine is compiled from the *mutated* source and would otherwise grade its own homework — so `mutation-check.sh` refuses to start when `bin/apq.js` is missing. Its `--expect` exit code answers *"could this be classified"*, not *"what was the verdict"*: every verdict, `RUN-FAIL` included, exits 0.

Failures *beyond* the expectations do not demote `KILLED` to `MISMATCH`; they are listed on the row as `+extra: …` — useful signal about coupling, not a defect. The script's exit code is 0 only when every track is `KILLED`, so a manifest can guard a mechanism in CI. The report is one row per track in manifest order, a summary and the workroot path:

```
KILLED     doc-blockonly        filter=SetDoc         2 tests failed / 40 assertions: unit.query.SetDocSliceTest.testX, unit.query.SetDocSliceTest.testY
SURVIVED   dead-branch          filter=HxLexer        0 tests failed / 85 assertions
MISMATCH   foo                  filter=Bar            2 tests failed / 9 assertions: … (missing: unit.BazTest)
3 tracks: 1 killed, 1 survived, 1 mismatch, 0 error
```

The two figures on a row are in different units on purpose: failing *test methods* against total *assertions*, since once a run goes red utest stops listing the passing tests and there is no test-level total. The name list is capped at ten with `…+N more`; the uncapped set is appended to the track's own transcript whenever the cap elided something.

### Declared arms — the pin metadata's other half

`@:pin('control')` names what a fixture is FOR and `@:killer('<arm>')` names the mutation that must break it; `testkit.TestDiscovery` refuses to build a control that names no arm. That checks the SHAPE. The registry is what makes the NAME mean something: an arm exists, still addresses live code, and still kills something.

`test/testkit/mutation-arms.json` is the registry — one record per arm, naming the type, the member and the cut. A cut is one of two shapes, and a record declares exactly one:

- **`force`** — `return <force>;` spliced directly after the member's signature, leaving the rest of the body as dead code.
- **`find`** / **`replace`** — a text fragment replaced inside the member, for a cut a constant cannot express. `replace` may be empty (deletes the fragment). Each is one string or a LIST of them of equal length: N `old ==== new` pairs applied in ONE `hxq patch` call, each located against the ORIGINAL member text, order-independent and all-or-nothing.

```json
{ "name": "M-ISSUBTYPE-FALSE", "type": "anyparse.query.SubtypeGraph", "method": "isSubtype",
  "force": "false",
  "note": "the subtype relation is empty, so redundant-upcast and unreachable-catch stop seeing the relation they report on" }
```

Both are `hxq patch --select 'FnMember:<method>'` payloads, which is the point: an arm survives every edit that does not rename its member. A stored line number, or a checked-in git patch, does not. The record contract field by field, and every refusal `MutationArms.rowErrors` answers at BUILD time (mismatched list lengths, a `replace` equal to its `find`, an empty array, a blank fragment, `force` beside `find`), is the `MutationArm` typedef and `MutationArms.rowErrors` in `test/testkit/MutationArms.hx`; overlapping matched ranges are the one refusal left to the run.

**Five build errors, all free.** `TestDiscovery` cross-checks the registry against the tree while it is already walking it: a `@:killer` naming no declared arm; a declared arm no `@:killer` names; a declared arm whose `type` no longer declares that `method`, asked of the COMPILER rather than of the file's text; a declared arm whose `type` names a module no classpath carries; the registry file itself gone. The third is the failure that happens in practice — a member the arm depends on is moved to another module during a refactor — and nothing but a build could catch it.

**A macro-time arm is DEFERRED, not refused.** `Context.getModule` types into the context being compiled, so a module whose every type sits behind `#if macro` contributes no type to the test build and the compiler cannot answer for it (there is no build-macro route around the typer). Such an arm is recorded in `TestRegistry.deferredArms()` and answered by `unit.MutationArmAddressTest`, which resolves the type to the file `tools/mutation-arm.sh` would patch and asks anyparse's own parser for a `FnMember:<method>` — a `#if` region is a `Conditional` node whose branches are ordinary children, so the parser has no blind spot there. An arm that spells a `kind` is deferred whatever its module (the build macro asks the typer for a METHOD), so declaring one costs a line in `testTheDeferredArmCensusNamesTheMacroModuleArms` too. The trade: the member check moves from a build ERROR to a suite failure, still machine-run on every suite run.

**Both cut shapes are walked on every suite run.** `unit.MutationArmAddressTest#testEveryFragmentArmStillCutsItsNode` asks `Patch.occurrences` whether each fragment arm's stored text occurs exactly once inside its member's node, per pair, naming the pair that rotted — the matcher has to be `Patch`'s, not a substring test, because fragments are copied out of `hxq show --select`, which DEDENTS. `testEveryForceArmStillOpensABodyToCutInto` asks of every force arm that the member resolves to one node, that node opens a `BlockBody`, nothing but whitespace follows its brace on that line, and the header up to it occurs exactly once — that header being the fragment `apq patch` is handed. It asks the TREE, not a brace balancer: the runner balances braces in a shell-embedded JS snippet, and a member the fixture accepts and the balancer misreads makes the runner refuse BY NAME, so the two cannot drift quietly. One shape neither walk can address: a member on a SUB-MODULE type, because a record's `type` is read both as the class the typer resolves and as the PATH of the file the runner patches, and for a sub-module type the two disagree by construction.

**Running one is one command.**

```sh
tools/mutation-arm.sh <ARM> [<ARM>...]   # each over the whole suite
tools/mutation-arm.sh --all              # every declared arm
tools/mutation-arm.sh --all --fast       # only the classes that pin each arm
tools/mutation-arm.sh <ARM> --check-apply  # apply the cut and BUILD only, no suite
tools/mutation-arm.sh --all --check-apply  # the same over the whole registry
tools/mutation-arm.sh --list             # the registry, one line per arm
node bin/test.js --list-arms             # the same list, out of the generated registry
```

It renders each record into a patch inside a scratch worktree at `HEAD`, derives the expectation set from the arm's OWN pins in the generated registry (one copy of that pairing is enough), writes a manifest, and hands it to `tools/mutation-check.sh`. Nothing new classifies a transcript.

**`HEAD` is a fixed point, and `--working-tree` is the escape hatch for authoring.** The registry is read live off disk, so an uncommitted arm RECORD is never the problem; what a `HEAD`-based run cannot see is uncommitted SOURCE the arm cuts. `--working-tree` builds both the render worktree and every track worktree from a `git stash create` snapshot (`mutation-arm.sh` passes it to `mutation-check.sh --base <ref>` so the two stay on one base — a track on plain `HEAD` against a snapshot patch reads as a misleading `PATCH-FAIL`, `SURVIVED` or `NO-TESTS`). It refuses on any UNTRACKED file (`stash create` drops those silently) and prints every included tracked change, because no predicate can tell a change that is part of the cut from one that is not.

**The contract is "kills its own pin", not "kills exactly one test".** An arm cuts shared engine code, so collateral is inherent:

| Row | Reading |
|---|---|
| `KILLED`, no `+extra` | Every fixture naming the arm went red and nothing else did. The narrowest reading — and a property some arms cannot have. |
| `KILLED … +extra: …` | Its own pins went red AND other fixtures did. The EXPECTED reading for an arm on shared code. |
| `MISMATCH` | Red, but at least one of the arm's own pins survived, and the row names which. The arm killed something ELSE. |
| `SURVIVED` | Green. The fixture that claims this arm breaks it does not notice. |

A `SURVIVED` or `MISMATCH` row is evidence about the FIXTURE, not noise to retry past: an arm that kills nothing is deleted or re-cut, and a fixture that does not discriminate is rewritten until it does. Two arm-record defects also produce those rows: a cut that ADDS a second read while leaving the original in place (the original still wins), and a `force` on an `inline` member (`Cannot inline a not final return` — `BUILD-FAIL`, and the reason `find`/`replace` exists). One constant row to subtract in whole-suite mode: applying a fragment cut deletes the stored text, so `testEveryFragmentArmStillCutsItsNode` appears as `+extra` on every fragment arm's row (never on a force arm's), never in an expectation set, and never under `--fast`; a dud fragment arm therefore reads `MISMATCH (missing: <its pins>)` in whole-suite mode and `SURVIVED` under `--fast`.

**Cadence: `--check-apply` while AUTHORING, `--all --fast` per WAVE, one arm on demand.** A cut is compiled BEFORE it is claimed — `--check-apply` runs before the arm has a `@:killer` (§ "The five arm-authoring blind spots"). `--all --fast` is the per-wave sweep; the whole-suite `--all` is for a release or a refactor that is supposed to have preserved a coupling, never a routine gate. Per-arm cost is flat (a track is one `haxe test-js.hxml` build plus a filtered run), so a sweep grows linearly in the arm count and not at all in the suite's size, and doubling `--jobs` buys well under 2× because the builds contend. Run a single arm when you add or edit a pin — the moment its claim is made.

**Every suite process claims a PRIVATE temp root** (`unit.cli.CliFixture.isolateTempDir`, called by `RunTests.main` before the first fixture is written, removed on completion). Fixture names are unique within ONE process only (a static counter plus a millisecond clock), so two suite processes started together under one `$TMPDIR` generate the SAME names and delete each other's files mid-test — what concurrent whole-suite tracks used to read as a flake in the oracle-driven CLI e2e family. A per-process ROOT rather than per-process NAMES because the naming is not in one place (`hxq search 'Sys.time()' test/` lists every producer). The root is CLAIMED in `tools/tmp-lifecycle.sh`'s shape, and the teardown goes through `CliFixture.removeScratchRoot`, which refuses any path that is not a claimed root. `unit.cli.ScratchIsolationGateTest` gates the `TMPDIR` half; nothing gates the per-USER `$HOME/.config/anyparse/fork_path` cache, the same defect one layer out.

### Authoring an arm

The campaign that built the registry is in the journal, slice by slice; what it settled:

- **Pick the seam by MEASUREMENT, never by list.** Render the candidate cuts, run each over the WHOLE suite, and let the blast decide: the fixture that dies first and alone is the pin; a diffuse blast says the seam has no single owner, and annotating the widest file anyway puts the pin back where the problem started. A 200-line helper is not a seam — the GATES inside it are, each one `find`/`replace` fragment away; cut one gate at a time before concluding a helper has no owner. Forcing a predicate BOTH ways can partition a class exactly.
- **A cut whose tree does not compile is not evidence** (`BUILD-FAIL`, dropped rather than re-aimed). **A blast of ZERO is a statement about the TESTS, not proof the code is dead** — record it, or write the discriminating fixture; some such gates are corpus-only, reached by one shape the suite had nothing of.
- **What does NOT earn a second arm:** a callee with one caller (one cut spelled at two depths — `hxq refs <name> src` is the whole check); a cut whose blast is a strict SUBSET of an existing arm's; a cut killing "most of the suite" (a total veto, a global width off-by-one — every pin naming it would say the same thing). Two arms with IDENTICAL blasts are kept only when they cut different MODULES. Before rendering a cut for a `control` claim, run the arms the registry already declares against it — a control an existing arm already kills needs a `@:killer`, not a registry row.
- **Two arms may share a member, and a `find` is matched against the member's own text.** A replacement that deletes or merges lines can delete the text a sibling arm stores, and the sibling then comes back `BUILD-FAIL` rather than saying anything about a fixture. Check the sibling's `find` against your replacement, or keep the replacement line-for-line.
- **Never classify an unexplained extra row by verdict kind.** The load-driven extra rows that once made an `ERROR`-vs-`FAILURE` tell look plausible were the temp-root collision above, and it is fixed; re-run the same patch alone before treating an extra row as a finding, and quote the serial number.

### The five arm-authoring blind spots

Four are named by the TREE on every suite run (`testEveryForceArmStillOpensABodyToCutInto`); the fifth needs a compile of the cut.

| zone | who can name it | where |
|---|---|---|
| a trailing `// noqa` on the signature line | the tree | nothing but whitespace after the body's brace |
| a return type opening its own brace (`Null<{ … }>`) | the tree | the body's `BlockBody` span, never a brace hunt |
| an unbalanceable body / an expression body | the tree | the body node's KIND |
| an `inline` member | the tree | the modifier group ahead of the member node (an inline member nobody calls compiles with a leading `return`, and has no behaviour to remove) |
| a narrowed nullable in a structure literal | **the COMPILER, and nothing else** | `tools/mutation-arm.sh --check-apply` |

The fifth is a TYPE question at a program point: a replacement that reads a `Null<T>` local an enclosing `if (x != null && …)` narrows types fine as text and fails `Null safety: Cannot unify` only when compiled. `TypeResolver` / `SymbolIndex` answer what a name is DECLARED as, never what it is narrowed to at one position, and Haxe's narrowing lattice decides one syntactic shape several ways, so no static predicate over the record and the tree is sound in either direction. For that zone a RUN is the only net:

```sh
tools/mutation-arm.sh <ARM> --check-apply           # does this cut compile?
tools/mutation-arm.sh --all --check-apply --jobs 8  # the whole registry, one pass
```

`--check-apply` reuses the track machinery — `tools/mutation-check.sh --build-only` creates the worktree, applies the rendered patch, runs `tools/worker-build.sh <dir> test` and stops. It needs no `@:killer` (an arm is authored cut-first); a `BUILD-FAIL` row NAMES the cause out of `apq mutation-verdict --build <log>` (`null-safety-structure` · `null-safety` · `inline-return` · `arm-registry` · `syntax` · `type` · `other` · `no-error` — `anyparse.query.BuildFailure`, covered by `unit.query.BuildFailureTest`); and an arm whose cut cannot be RENDERED is a row, not an abort (outside `--check-apply` it still exits 2). `arm-registry` is not exotic: an arm added before its `@:killer` exists fails `TestDiscovery`'s cross-check, a build failure of the tree rather than of the cut. What the mode buys is NOT speed — the build IS the cost of a track in every mode — but that a cut is checked before it is claimed.

## Macro-specific tests

anyparse is a macro-heavy project. Macros have three test shapes:

### Compile-time smoke test

Does the macro compile a grammar without errors? This is a CI step that tries to compile tests/macro-samples/*.hx and fails if any do not compile. Catches macro regressions that break compilation.

### Generated code inspection

Does the macro generate the expected code for a given grammar? This is done by invoking the macro in test context and inspecting the output `haxe.macro.Expr`. Rarely needed, but essential when debugging a tricky codegen bug.

### Macro failure tests

Does the macro report a sensible error on invalid input? If a user writes `@:infix(prec=5)` without `@:op`, the macro should produce a specific error message, not a mysterious internal failure. A test asserts that compiling an invalid grammar fails with an expected error substring.

Not in Phase 1 since there is no macro yet. Will appear with Phase 2.

## Test framework: utest 1.13.x

Chosen over tink_unittest and buddy for reasons of:
- Being the most popular Haxe unit test framework, lowering friction for contributors.
- No tink dependency, keeping anyparse's dependency tree empty at runtime.
- Clean integration with Haxe macros and compile-time metadata.

Test cases extend `utest.Test`, assertions use `utest.Assert`. Each test method begins with `test`.

### The registration layer is generated

`test/RunTests.hx` carries no hand-written `addCase(new X())` line. A hand-written list has two costs: a class whose line was never added runs nowhere and says NOTHING, and every parallel worker conflicts on the same file by construction.

`testkit.TestRegistry` is an empty class built by `testkit.TestDiscovery`, which walks every package directory under the test classpath root and, for each class it finds, asks **utest's own two questions**: does it implement `utest.ITest` (what `Runner.addCase` dispatches on), and does it carry an instance method whose name starts with `test` or `spec` (what `TestBuilder` turns into a fixture — a PREFIX test blind to visibility, so a `private function testX` IS a fixture and a `static function testX` is NOT). Asking utest's questions rather than inventing a marker is the whole design: a forgotten marker is exactly as invisible as a forgotten `addCase`, and because the macro and utest ask the same thing, "discovered" and "run" cannot drift apart. The full discovery contract — what is registered, what is a build error, what is reported — is the class doc of `testkit.TestDiscovery`.

**A class that cannot be registered is a build ERROR, never a skip.** Private, abstract, sub-module and constructor-taking test classes each stop the build naming themselves and the fix. The one deliberate skip is a `utest.Test` subclass with NO fixture — a shared base such as `unit.NamingCheckTestBase` or `unit.grammar.haxe.HxTestHelpers`, whose `extends utest.Test` is what makes every `Hx*` test class a `utest.ITest` at all. Those are REPORTED through `TestRegistry.baseClasses()` and pinned, so "reports" cannot decay into "silently drops".

**Scope is a whitelist on both edges.** The walk covers every package directory under the test classpath root, minus the two modules asking for which would be circular (the macro and the registry it builds). Root-level modules are not walked either, but a root-level module that is not one of the declared entry points (`RunTests`, `_ReconSkipParse`) STOPS THE BUILD naming itself, so a test class dropped there is loud rather than invisible.

The runner prints the registries on demand and exits before any fixture runs:

```sh
node bin/test.js --list-classes   # every registered class, one per line
node bin/test.js --list-dead      # fixture-named methods utest will never run
node bin/test.js --list-bases     # utest.Test subclasses carrying no fixture
node bin/test.js --list-pins      # @:pin annotations with roles and killers
node bin/test.js --list-arms      # the declared mutation arms every @:killer resolves into
node bin/test.js --list-claims    # the prose census, LC_ALL=C sorted
```

`--list-classes` is what `tools/suite-shard.sh` feeds to `apq shard-plan --classes`, so a shard is filtered by exactly the list one process would have registered — nothing re-derives it from source text. (`shard-plan --runner <file>`, the older door that reads `addCase(new X())` as an AST shape, stays as a shipped CLI door with its own fixtures in `unit.query.ShardPlanTest`; nothing in the repo drives it.)

`unit.TestDiscoveryParityTest` pins the layer in the shape where the shrinkage IS the acceptance test: `REGISTERED_CLASSES` is a sorted literal, so narrowing the discovery predicate by one class turns the suite red instead of quietly running one fewer. A new test class needs the list regenerated (`node bin/test.js --list-classes | LC_ALL=C sort`), and the failure message says so. `unit.DiscoveryOnlyProbeTest` is the other half: a real test class that no hand-written line names, and none may ever name — a registration written for it would delete the only standing evidence that discovery, not a list, is what runs it.

**Machine-checkable test metadata.** `@:pin('<role>')` names what a fixture is FOR and `@:killer('<arm>')` names the mutation arm that must break it; `TestDiscovery` refuses to build a `@:pin('control')` that names no arm, so the reviewer's catch becomes a compile error, and every arm name resolves to a declared record the build checks and one command runs (§ "Declared arms — the pin metadata's other half"). An arm nobody ran is prose retyped as metadata — the registry is what answers that. What the metadata does NOT yet cover is counted by the census below.

### The prose census

Test doc comments make claims the metadata was designed to replace — an arm that must break the fixture, a sibling it is the control for, whether it was red at the base commit, whether an assertion could pass vacuously. The census counts those that no annotation records, so a slice that annotates as it goes can see what it retired.

**The predicate.** `testkit.ProseClaims.kindsOf` reads ONE fixture's doc comment, normalized to a single line, and answers which of four claim kinds it makes:

| kind | what the prose claims | what records it |
|---|---|---|
| `arm` | a mutation that must break this fixture — "Killed by arm M3" | `@:killer('<arm>')` |
| `control` | this fixture is the control for a sibling | `@:pin('control')` |
| `base` | it was RED / green at the base commit | *nothing* |
| `vacuity` | its assertions were audited for passing trivially | *nothing* |

`testkit.TestDiscovery` asks that of every fixture it discovers, drops the kinds an annotation already records, and emits the rest as `TestRegistry.claims()` — one line per fixture, `<class>#<method> :: <kinds>`. The phrase sets and exclusions are the class doc of `testkit.ProseClaims`; two are load-bearing: the code senses of `control` (control flow, a control-exit node, a control head, the role name in backticks) are blanked before the word is read, and a denial ("NOT killed by any arm in this slice") is a fixture stating it has NO arm. It cannot read DIRECTION ("its control is the fixture above" claims no role for the carrier, but the same words carry both readings), so those lines stay listed. It lets through, by construction, a claim in a `//` comment beside the assertions, and a claim in a CLASS doc — `ProseClaims` is asked of `ClassField.doc`, never of a `ClassType`'s, and a type-level `@:pin` would not shrink the census but open a second, uncounted population; the honest recording form for a class-doc claim is the member pins it summarises.

**Only a PURE `control` row can leave.** `ProseClaims.records` retires a `control` claim for `roles.contains('control')` and an `arm` claim for any killer, and `TestDiscovery` refuses a `control` with no `@:killer` and a `@:killer` with no `@:pin` — both gateable kinds terminate at a declared registry row; there is no bucket that needs no arm. The census is a LIST compared line by line, and a line carries every kind its fixture claims: a `control,base` fixture that gains `@:pin('control')` does not leave, its line becomes `:: base`. It costs roughly one registry row per claim (controls are controls for DIFFERENT clauses), and a pin wave that touches no listed class cannot move it — read the census for the classes about to be pinned first. Two rows can never leave: a fidelity guard whose own doc says it holds with the mechanism reverted (no arm can kill it, and `control` without a `@:killer` is a build error), and a pinned PAIR of deliberately redundant lines (an arm declares exactly one cut). The prose `control` claim means "the control for a sibling"; the `@:pin('control')` ROLE has broadened to any primary discriminating fixture, and a fixture whose role is genuinely not "control" takes another (`@:pin('guard')`) and still retires an `arm` claim.

**`base` and `vacuity` are censused, not gated, deliberately.** Neither "was this red at the base commit" nor "could this assertion pass trivially" is answerable at build time, so a `@:pin('red-at-base')` would assert what nothing checks — prose retyped as metadata, the exact failure `TestDiscovery`'s error message names. Those rows are the fixed floor a `control`-and-`arm` tranche leaves behind, a register of what is still prose rather than a queue.

**The gate is a ratchet, and it is the suite rather than the build.** `unit.ProseClaimCensusTest.BASELINE` holds the baseline list; the fixture compares it against `TestRegistry.claims()`. A new claim without an annotation fails the suite, and so does an annotated one still listed. It is a list and not a count on purpose (a scalar merges silently wrong across two branches). It is NOT a `Context.error` because the list is GENERATED, so regenerating it needs a working binary — a build error would refuse to produce the binary that prints its own answer:

```sh
haxe test-js.hxml && node bin/test.js --list-claims   # already LC_ALL=C sorted
```

`hxq lit '<phrase>' test/unit --include-comments` does NOT reproduce the census — `lit` counts comment nodes and string literals anywhere in a file, where the census counts DOC COMMENTS ON FIXTURES. A claim wrapped across a doc-comment line break is the one shape a line-oriented tool misses; `M-CLAIM-RAW-DOC` is the arm that removes the line-joining.

### The runner is quiet by default, and one of the two arguments is load-bearing

`RunTests.main` calls `utest.ui.Report.create(runner, NeverShowSuccessResults, AlwaysShowHeader)` and installs a per-test stdout capture: every gate in this project reads six lines of a transcript, and a raw suite run prints megabytes around them.

- `NeverShowSuccessResults` drops only PASSING lines: `ReportTools.skipResult` returns `false` for `!stats.isOk` before it reads the mode, so failures, errors and warnings still print in full.
- **`AlwaysShowHeader` is load-bearing, not decoration.** Under the default `ShowHeaderWithResults`, `ReportTools.hasHeader` returns FALSE for a green run once success results are hidden — the `successes:` / `errors:` / `failures:` summary would vanish and every gate that greps it would silently pass on nothing. Never drop that argument.
- **The runner prints its own `tests executed: N` line**, counted off `runner.onTestComplete` and emitted from `runner.onComplete` (utest's block carries assertions but no test total). The listener is registered BEFORE `Report.create` — the report's own `onComplete` calls `process.exit` from inside the dispatch — and counted rather than read off `runner.length`, so a run that dies mid-way prints neither line and stays visibly uncountable. Read it only ALONGSIDE utest's block (alone it is forgeable by a test's flushed stdout). `apq test-summary` EXITS 1 when it finds no report at all, naming what it could not find; the question is whether a report was FOUND, never whether its numbers are zero.
- The **per-test stdout capture** buffers what each test prints and discards it when the test passes; any non-`Success`/`Ignore` assertation flushes the buffer verbatim first.

⚠️ **Only stdout is interceptable.** `Sys.stderr()` on hxnodejs writes a raw fd and bypasses the JS stream (the same fact that makes an fd-2-only line unassertable by any in-process test). Drop that half at the shell with `2>/dev/null`. `APQ_TEST_VERBOSE=1` restores both the per-method listing and the captured output for a human reading one run.

## Guidelines for new tests

### A whole DEFECT CLASS gets a roster-driven differential, not one test per site

`unit.check.CrossScopeSoundnessTest` is the shape to copy when the same mistake keeps turning up in a new check. Its subject is not a check but an INVARIANT every check owes: a run whose REPORT scope is narrower than its declared resolution scope must not write an edit, or raise a finding, that the wider run would refuse. Three properties make it catch a class rather than a case:

- It iterates **`Linter.builtins()`**, the registry itself, so a check joins by being registered — no list to keep in sync.
- It is a **differential**: the same fixture twice, with only the report scope moved, and the assertion is a SUBSET relation (narrow edits ⊆ wide edits, narrow findings ⊆ wide findings). Nothing has to predict what a check should say — only that widening the scope cannot take an answer away.
- Divergences it tolerates live in an **explicit named constant**, not in a weakened assertion, so an accepted exception is readable and a new one fails loudly.

Its own floor is a non-vacuity guard: a differential over a roster is exactly the shape that passes by exercising nothing. Measure the write coverage when you widen it (which cells actually produce an edit), and select cells by the FORM of the evidence rather than by a label — a selector that reaches only the cells already covered reports a zero that is an artefact of the selector.

### A guard on `#if sys` is a test that does not run

`sys` is NOT defined by an hxnodejs build, and js/node is the only runner the suite has. A test method whose body sits inside a bare `#if sys` compiles to its `#else` arm — by local convention `Assert.pass('non-sys target')` — and reports a success while asserting nothing. Guard anything that needs a filesystem or a process with `#if (sys || nodejs)`.

`unit.DeadTestGuardTest` is what makes the return loud. It walks `test/`, reads every directive through `CondDirectives.scan` (the shared reader, so a `#if` inside a comment or a string fixture is not a guard) and evaluates each condition with `CondRegionLiveness.evaluate` against the flag set `unit.BuildDefines` reads out of the running build via `#if <flag>`. Any guard the build cannot prove LIVE fails the suite, naming the file, the line and the remedy — with one disclosed exception, `BuildDefines`' own `#if <flag>` probes, unprovable by construction because they ARE the question. "Cannot prove live", not "is dead": a condition the reader cannot delimit carries no condition span, and is reported rather than skipped.

It is a suite gate rather than a lint check because "`sys` is dead" is a property of ONE build, not of the language — `src/` carries `#elseif sys` on purpose for the neko/hxcpp targets — so a rule would need a `deadDefines` config key, a claim about the build that nothing verifies. `BuildDefines` is a separate module holding no test method, so the exemption has nothing to swallow.

### Test names describe what they assert

Bad: `testCase1`, `testParsing`.
Good: `testParsesSimpleObject`, `testRejectsUnclosedArray`.

The test name is the first thing a failure report shows. A name that communicates intent saves debugging time.

### One concept per test

A test method asserting five different things has five potential failure sites that all look the same in the report. Split into five tests with specific names.

### No test depends on another

Tests must be order-independent. utest may run them in any order. No shared mutable state between tests.

### Assertions include context

When `Assert.equals(expected, actual)` fails, the default message shows only the values. When context is useful, add a label:

```haxe
Assert.equals(expected, actual, 'failed at iteration $i with ast $ast');
```

Especially valuable in property tests where the failure is hidden in random data.

### New grammars get round-trip tests by default

When adding a grammar, the PR includes a round-trip test with at least 20 curated cases and a random generator that produces 100+ cases per run. A grammar without a round-trip test is not ready to merge.

### "Does the writer touch this shape?" is TWO measurements, not one

Feeding a reported layout back through the writer and getting the same bytes proves only that the shape is a fixed point. It does NOT prove the writer is neutral about it — the writer may be actively PRODUCING that shape from every other spelling. The second measurement decides: write the layout you WANT, format it, and see whether it survives.

The answer to any layout report is a 2x2 — {reported form, wanted form} x {knob off, knob on} — and a brief that quotes only the reported-form cell has measured a quarter of the question. The same grid is what a fixture pair should assert, which is why such a slice test carries a `@:pin('guard')` on the re-join direction: no arm of that slice can flip it (the knob's flag short-circuits ahead of the shape probe), and without it the re-join is a fact nothing in the suite records. When the second cell has NO knob behind it, the finding belongs in the report with its measurement, not in a fixture: assert what the writer does today, say in the doc which configurations are stuck with it, and let the absence be visible.

## Running tests

```sh
haxe test-js.hxml           # compile the runner to bin/test.js
node bin/test.js            # the whole suite, one process
tools/suite-shard.sh -n 4   # the same suite across 4 processes
APQ_TEST=RemoveParam node bin/test.js   # one class, for the edit loop
```

js/node is the only runner. The suite itself is not target-independent — `CompilerOracleE2ETest` calls `js.node.Fs` directly to pin fixture mtimes — so there is no neko or `--interp` build of `RunTests`. Both `test-js-common.hxml` and `bin/apq-js-common.hxml` pass `-D analyzer-optimize`, so the suite exercises the codegen that ships.

### The assertion count is a per-machine fact, not a build artifact

Two builds of one commit under identical preconditions print the same `tests executed:` and `assertations:` lines. What moves `assertations:` is the ambient environment: `unit.query.HaxelibResolverTest.testLibSourceDirResolvesRealInstalledLib` shells out to `haxelib libpath utest` and takes a documented one-assertion skip branch (instead of three) under a `$HOME` that has not run `haxelib setup`; `unit.query.PatchSliceTest.testCliPreviewAndWriteBothAnnounceThemselvesOnStderr` guards on `sys.FileSystem.exists('bin/apq.js')` relative to the CWD and takes a one-assertion branch (instead of five) when the engine is not built. Neither is a bug to fix — the alternative is a hard failure on every fresh clone. **Read `tests executed` as the number a gate can require exactly; read `assertations` as that number `±` up to 6 on an environment missing one of the two preconditions.**

### The core stays target-independent

The runner being js-only says nothing about the library. Parser, writer and the whole `apq lint` check set compile straight out of `src/` for a static target — no copies, no stubs — and that is design principle 3 ("Pure Haxe delivery, no JVM dependency") in practice:

```sh
haxe -cp src -main <harness> -D analyzer-optimize --jvm out.jar
```

Two things break this quietly, and both did:

- **A bare `import js.node.…` at module scope.** The *uses* were behind `#if nodejs`; the import was not, and an import is resolved unconditionally. Guard the import with the same condition as its uses.
- **A `final` field in a structure `typedef` that a bare object literal has to be inferred INTO.** A `final` structure field lowers to a `never` setter. Where the expected type is written at the literal that costs nothing — `GrammarPlugin.LayoutMetrics` keeps its `final` fields and builds for every target. The error appears where the literal's own anonymous type is inferred FIRST and the typedef then has to unify with it, typically through a type parameter (`Inconsistent setter for field certain : never should be default`). One variable — same source, same flags, target swapped — `--jvm` rejects it while `-js` and `-neko` accept it, which is exactly what makes a `--jvm` build worth running.

The committed harness is the cheapest way to re-check this:

```sh
haxe tools/jvm-portability.hxml     # BUILD: parser + writer + every builtin check; prints nothing
java -jar bin/jvm-portability.jar   # RUN: prints the gate line and a census line
```

It is a portability PROBE, not a dependency: nothing anyparse ships needs a JVM. It exists so the invariant above is something a slice can fail on instead of a paragraph nothing can flip.

#### What the probe actually covers — NOT a package

`src/anyparse/query` and `src/anyparse/check` are the probe's **default input** — the files it READS and lints (`JvmPortability.DEFAULT_SCOPE`), not a coverage claim. What it **compiles** is `-main JvmPortability` with `-cp src -cp tools`, and Haxe types only the modules that main reaches: `anyparse/query/cli` contributes **zero** entries to the jar, and the addressing/mutation family (`Address`, `Patch`, `ReplaceNode`, `Selector`, `Engine`, `NewFile`, `MoveSymbol`, `MutationVerdict`, …) and the oracle family (`OracleCache`, `CompilerServer`, `CompilerOracle`, `HaxeSpawn`, `FixVerifier`, `OracleCoverage`) are absent too. So a green probe after a slice in `query/cli` proves the slice's code compiles for **js**, and nothing more. `tools/battery.sh` gets the trigger right — it re-runs the probe when anything under `src`, `tools/JvmPortability.hx` or the hxml moved. Widening what the probe TYPES is a separate question (`--macro include('anyparse.query.cli')`, which would first have to survive `-lib hxnodejs` not being there).

#### Reading the two output lines

```
gate: files=N wrote=N threw=0 lintdiff=1+0-
census @ <sha>: checks=N findings=N — a reading of THIS tree, not an invariant — …
  phases: roundtrip=… lint=…
```

**The gate line is the verdict.** `wrote == files` and `threw == 0` are the invariant — `writeRoundTrip` throws only on a parse failure or a comment loss, never on a formatting difference. `lintdiff=1+0-` is fixed too: it is `JvmPortability.lintDiffProbe`'s own embedded self-test of `LintDiff`'s normalization (two hand-written JSON fixtures, nothing to do with `src/`), which forces the macro-generated `LintDiff` JSON parser to actually build under `--jvm`; `1+0-` is that helper's documented right answer, not a JS/JVM lint desync.

**The census line is a reading, stamped with the commit it was taken on.** `checks`, `findings` and `files` are functions of the whole tree, and this number has been copied from a queue header as a fixed expectation and been wrong every time. **Take the census on YOUR base with a freshly built jar; never copy one from a queue header, a brief or this file.** `findings` is config-aware (`Linter.run` with a per-file config resolver and `applyEnablement: true`, so it answers the rule set `apqlint.json` declares), and still NOT the same number as `apq lint src/anyparse/query src/anyparse/check --all`, which joins a `SymbolIndex` over the declared `resolutionRoots` that this probe has no business building — comparable in kind, not equal.

### Parallel tracks: per-worker build outputs

`bin/apq.js` and `bin/test.js` are single shared artifacts. That is fine for one person at a keyboard and actively hostile to several agents working the repo at once: every build truncates the binary the others are executing, so a second worker cannot even run a probe while the first is compiling. The parallelism is lost before it starts, and the failures it produces look like flaky tests rather than like a build race.

The fix is to stop sharing the artifact:

```sh
tools/worker-build.sh /tmp/w1              # builds /tmp/w1/apq.js and /tmp/w1/test.js
tools/worker-build.sh /tmp/w1 test         # just the test runner
node /tmp/w1/test.js                       # instead of node bin/test.js
APQ_TEST=RemoveParam node /tmp/w1/test.js
HXQ_BIN=/tmp/w1/apq.js hxq ast Foo.hx      # every hxq subcommand, queries and mutation ops alike
```

`HXQ_BIN` points the `hxq` shim at an explicit engine and, as a consequence, skips the shared stale-check and auto-rebuild entirely — the worker owns its own build, so the shim must not decide to rebuild `bin/apq.js` underneath it. The two builds inside `worker-build.sh` run concurrently, and it resolves the repo from its own location rather than from the CWD, so a copy of the script living inside a git worktree builds *that* worktree's `src/`.

Some tests read paths relative to the CWD (`bin/.last-sweep.json`, `test/` fixtures, `hxformat.json`, `apqlint.json`), so run a private `test.js` with the CWD set to the tree it was built from.

Two limits worth stating plainly, because a private engine invites more confidence than it earns:

- **Builds, test runs and probes become parallel; the source tree does not.** Two agents running mutating ops on the same files still need coordination — a private engine isolates the *tool*, not the files it edits. Genuine source isolation means a git worktree per worker, which is what `tools/mutation-check.sh` does.
- **A private engine is a snapshot.** It goes stale the moment another agent lands a `src/` change, and unlike the shared shim path nothing will warn you. Rebuild your own before trusting a probe.

The build flags live in `bin/apq-js-common.hxml` and `test-js-common.hxml`, with the output line split out into the leaf files `bin/apq-js.hxml` and `test-js.hxml`. That split exists because Haxe rejects a second `-js` with `Error: Multiple targets` — an hxml that already names an output cannot be retargeted by a later `-js` on the command line, so the shared part must not name one. Note that a bare hxml-include line is resolved against the CWD, not against the including file's directory: build from the repo root.

### Parallel shards: one suite, N processes

The previous section parallelises *workers*. This one parallelises a *single* suite run. `tools/suite-shard.sh` splits the registered test classes into N `APQ_TEST` filters and runs one `node bin/test.js` per shard. The split is not the script's — it asks the runner for its class list (`node bin/test.js --list-classes`) and hands it to `apq shard-plan --classes <list> --shards N [--format lines|filters]`, which applies every gate below and prints the plan; that division is what makes the gates testable (`test/unit/query/ShardPlanTest.hx`).

```sh
tools/suite-shard.sh                      # 4 shards (default)
tools/suite-shard.sh -n 6                 # more shards, for a many-core box
tools/suite-shard.sh --verify             # + a monolith run, counts compared
tools/suite-shard.sh --expect <T>/<A>     # + compare to YOUR last known-good pair
tools/suite-shard.sh --plan-only          # print the plan, run nothing
tools/suite-shard.sh --bin /tmp/w1/test.js  # a private worker build (previous section)
tools/suite-shard.sh --keep               # keep the work directory even on success
```

`--verify` and `--expect` are mutually exclusive — the first measures the pair the second asserts. Do not copy a literal into `--expect` out of this document: the totals move with every slice. The default stays at 4 because past the knee the curve is flat — what remains is the sticky group plus the per-process warm-up each shard re-pays.

**The sticky group.** Every shard process claims a PRIVATE temp root before it writes a fixture (§ "Declared arms"), so fixture paths cannot collide between shards. ONE path is still a fixed constant and is *not* safe to split: `bin/.last-sweep.json` (the corpus Δ-baseline, rewritten by `HxFormatterCorpusTest` and read by `ApqDxTier5CliTest`); the probe staging slot used to be a second one, now resolves per process, and the group has not been re-derived against that narrower reason. The list is derived, not remembered — `hxq lit 'probe' test/` and `hxq lit '.last-sweep.json' test/` find the users (read each hit: one is a fixture *method* named `probe`). Re-derive it when adding a test that stages a probe or touches the sweep baseline; a writer left outside the group races the read-back in a sub-millisecond window and shows up weeks later as an unreproducible flake.

**Parity is a gate, not a hope.** `apq shard-plan` refuses to emit a plan unless the union of the shard lists equals the registration list exactly. The class list comes from the RUNNER, not from a source file (registered classes do not all end in `Test` — a `*Test` suffix filter or a `*Probe` glob drops tests silently). `APQ_TEST` is a **substring** match, so a name that is a substring of another would run in two shards, and the generator hard-fails on any such pair. The sticky list is hand-maintained (`ShardPlan.STICKY_CLASSES`), so every pinned name must still be registered — a rename would un-pin a class in silence; the per-class weights beside it only balance the split. No literal total is pinned in the script: class parity plus the no-collision gate plus a non-empty, green shard is what makes the totals trustworthy, and `--verify` / `--expect T/A` are the explicit cross-checks.

Exit status is 0 only when every shard is green *and* parity holds; any refusal exits non-zero and keeps the work directory — the shard logs when the run got that far, the plan files when it refused earlier (§ "Scratch directories: every tool's, and who removes them").

**When to shard, when not.** Shard the full battery mid-slice as a checkpoint. Run the **monolith** for the final pre-commit run, and any time the shard plan itself changed. Sharding changes **ordering** (a bug that only fires when A runs before B is invisible to a run that puts them in different processes) and adds **concurrency** the monolith never had (one working tree, one `/tmp`, one `$HOME`). The monolith is the insurance against the first; the sticky group is the insurance against the second.

### The shard runner's last line is a verdict, and each shard is checked against its own exit code

The per-shard lines and the aggregate are MEASUREMENTS; the aggregate is their SUM, so a failing shard's own line carries its count and its `(exit N)`. A shard that DIES mid-run is the case the counts alone cannot show — `apq test-summary` parses whatever rows survived into a plausible green prefix — so the reporting layer reconciles counts with exit codes:

- **`apq test-summary --exit-status <N>`** hands the parser the status the run actually returned. A non-zero status with nothing failing in the report, or a zero status with failures in it, prints an `exit-status disagreement:` line after the counts and exits 1; the counts line is printed either way, so a disagreement is an extra line, never a withheld answer (`unit.cli.ApqTestSummaryExitStatusCliTest`, arm `M-EXIT-STATUS-AGREES`).
- **The shard line names a shard that did not finish** and marks its counts partial (`… (exit 1)  <-- did NOT finish: these counts are partial`), with `the totals above are a SUM OF WHAT RAN, not a total` on stderr.
- **The last line is always a verdict** — `suite-shard: PASS — … over 4 shards`, or `suite-shard: FAILED — shard 3 is red (…)`. Read that one; every line above it is a measurement. A red shard also gets its locus printed (`shard 3 first failure: <test>  line:N  <message>`).

`parity: counts not cross-checked (class parity OK: N placed)` is a statement about PLACEMENT — every registered class was dealt onto exactly one shard — and not about completeness; only `--verify` sees that. One trap worth knowing for any shell in this repo: **BSD `sed`'s BRE has no `\|`**. An alternation written that way matches nothing on macOS and prints nothing — silently, because a `sed -n` that matches nothing is a successful command.

### A span is a CODEPOINT offset — a census that slices bytes measures a different file

`Span.from`/`Span.to`, and therefore every `@from-to` in `hxq ast --spans`, count **codepoints**, not bytes. On a file whose earlier lines are pure ASCII the two agree, which is what makes this expensive: a census works on hundreds of files and gets a plausible number. This codebase makes the trap likelier than most: the `ω-` markers used in comments are multi-byte and sit ABOVE the members a census wants to read.

```
class C {

	// ω-ω-ω
	public function f(): Void {}

}
```

`hxq ast --spans` answers `(Public @22-28)`; `public` starts at **byte 25** — three `ω` at two bytes each. A byte-offset slice of that member starts three bytes early and picks up the tail of the comment.

The helper already exists: **`hxq source <file> --select '<Kind>:<name>'`** prints exactly that node's raw source. A census that slices the file itself is reimplementing it — and the unit conversion too. When a census genuinely needs its own slicing, decode to a string first (`bytes.decode('utf-8')` in Python, `File.getContent` in Haxe) and index THAT; never index the byte buffer.

## The per-slice battery

Every slice ends with the same checks, and running them by hand is not only slow — the step most often skipped under time pressure is the one with no cached "before" arm to make it cheap, and a skipped step reads exactly like a passed one in a summary. `tools/battery.sh` is that sequence as one command with one verdict:

```sh
tools/battery.sh                    # build, suite + monolith cross-check, corpus,
                                    #   fmt, jvm probe if the core moved, lint, blast
tools/battery.sh --quick            # mid-slice: drop the monolith cross-check
tools/battery.sh --base 29011103    # compare the blast radius against a named snapshot
tools/battery.sh --snapshot         # on green, cache this HEAD as the next "before" arm
tools/battery.sh --allow-blast      # accept the blast movement it printed last run
```

`ANYPARSE_HXFORMAT_FORK` must be set: without it the corpus layer skips in silence, and a battery that cannot tell "corpus clean" from "corpus not run" is worse than no corpus gate, so the script refuses rather than warns.

**A run fails on** a build error, a red or count-diverged suite, a non-empty `fmt --list`, a `fmt --verify` divergence, a `--jvm` probe that stops compiling, more corpus failures than the base, or any blast-radius change not explicitly waved through with `--allow-blast`. **It only reports** suite totals growing, corpus totals improving, and the lint findings a slice's own new files bring with them — those still print through `lint-diff`, and passing `--allow-blast` after reading them is the intended way to accept a slice that adds code.

The baseline is four plain files per commit in `$ANYPARSE_BLAST_CACHE` (`~/anyparse-blast-cache` by default) — two lint snapshots, the corpus sweep snapshot, and a two-integer suite line. They are machine-local measurement state, and a committed one would conflict on every slice. `--snapshot` writes them, and only on green.

Every format-aware step is delegated to the CLI this project already builds — `apq lint-diff` for the blast radius, `apq sweep` for the corpus, `apq test-summary` and `apq shard-plan` through `suite-shard.sh` — rather than reimplemented in shell. That is why the script needs neither `jq` nor `python`: anything that has to *understand* a file is a subcommand, testable in the suite and dogfooding our own JSON parser.

The battery prints where its own time went, and the rows marked `*` OVERLAP: they are the four branches' steps, running at once, so the table closes on two different numbers — `concurrent span` (the wall clock of the parallel region) and `TOTAL (wall)` — and neither is a measurement of the code. A benchmark arm runs ALONE and SEQUENTIALLY on an idle machine; a battery row runs beside three other branches. Never quote one as a benchmark result — see "The profiling harness" above.

### The step graph: four branches, one join

The checks read like a sequence, but their dependencies are far sparser than their order, so they run as four concurrent branches:

```
build ──┬─ suite ── corpus          build = apq.js + test.js + a recon typecheck
        │                           corpus reads the snapshot the suite wrote
        ├─ fmt
        ├─ jvm probe                only when the core moved
        └─ oracle ── lint ── blast  lint reuses the oracle's verdict;
                                    blast diffs lint's own output
```

`build` stays sequential because everything else executes what it produces. Its third compile is a TYPECHECK, not a build: `haxe recon.hxml --no-output` is the only gate that reaches `test/_ReconSkipParse.hx` — `-main RunTests` types every module in a package under `test/`, but `_ReconSkipParse` sits at the test ROOT, which discovery skips as an entry point, so without this step it can rot against any `src/` signature it calls. `recon.hxml` writes the repo-relative `bin/recon.js`, so a worker that builds it for real is isolated by its own worktree.

Inside a branch the order is a real dependency; across branches there is none that matters: all four read `src`, and each branch's writes are read only by itself (the suite rewrites `bin/.last-sweep.json` and rotates `.prev-sweep.json`; its own corpus step is the only consumer; the jvm jar has none). Check that again before adding a fifth branch — `tools/suite-shard.sh`'s shared-path inventory was written for shard-vs-shard, not branch-vs-branch. `HXQ_QUIET=1` is exported between the build and the fork, and that ordering is load-bearing in both directions: earlier lets a stale binary through the launcher's own probe, later lets a branch rebuild `bin/apq.js` while three others execute it.

Concurrency must not cost a result, so two properties are built in. **Every branch is collected**: a red suite fails the verdict and the other three branches still report — three broken things are reported as three, because "one step failed and three never ran" is the summary this script exists to prevent (each branch queues its failures to a file the driver replays after the join). **A step has three outcomes, never two**: the driver writes down at launch the step labels each branch PROMISES to record; a promised label with no row becomes `not run`, printed in the timing table and failing the verdict on its own. `skipped` is the only benign third state, and only where the script decided the step does not apply — the jvm probe on an untouched core (`skipped  neither src/ nor the probe moved since <base>`); its trigger diffs `src` plus the probe's own two files, because that is what it COMPILES, and a trigger narrowed to the two packages it LINTS once self-skipped on exactly the structure-unification regression the probe exists to catch.

No branch prints while they run; each writes its own `.out`/`.err` pair and the driver replays them, stream by stream, in a fixed order, so the transcript reads like the old sequential one with the same `=== step ===` headers. One consequence the transcript hides: the `--verify` monolith runs beside three CPU-heavy branches, so it is still one in-order process (the ordering insurance survives) but no longer ISOLATED. A suite failure that reproduces under the battery and not under a bare `tools/suite-shard.sh --verify` is a load artefact; re-run the suite alone before believing it.

### `apq oracle` — the battery's hand-off

The oracle LEADS the lint branch, so it overlaps the other branches and `lint` — the next step in the same branch — hits the cache instead of typechecking the same hxml twice. It sits in the branch rather than in the driver as a background job because a branch subshell cannot `wait` on a pid that is not its own child.

```sh
apq oracle src        # one COLD typecheck, verdict recorded under the fingerprint
```

It cannot lie. There is no flag that asserts "this already typechecked" — the compiler always runs, and only an observed verdict is stored, so a misuse (running it on a tree that does not build) records a rejection, which is the truth. A tree that moves between the two steps misses the fingerprint and is compiled again. Its exit status is not a battery gate: the `lint` step reads the same verdict and fails there, with the compiler's error text. The store is a single slot per (hxml, cwd) pair, so alternating between two tree states misses every time — the cost side of never keeping a verdict that could be wrong.

### The verdict cache: one tree, one typecheck

Before it compiles anything, `Cli.reportOracleVerdict` derives a CONTENT fingerprint of the whole compile input and reuses the recorded verdict only while that fingerprint still matches (`anyparse.check.OracleCache`); findings are byte-identical between a cold and a cached run. The key covers the compiler's own `Defines:` line (Haxe version plus every resolved library version), every hxml in the include chain, and every `.hx` under every classpath directory — the hxml's `-cp` roots, the compile directory itself, and the entries the COMPILER names for the hxml's `-lib` set (one `haxe -v <-lib …> --interp Std` spawn), so library sources, their transitive dependencies and the Haxe std enter the key by content rather than by guess.

**Content only — never mtime.** The compilation server's mtime rule at one-second granularity gives wrong verdicts, including a broken build reported as clean (§ "Why `compilerOracleServer` is off here" and the `CompilerServer` class doc). A content hash has no such failure mode — break a compiled file in the same second you read it and the very next `lint` reports `compiler oracle REJECTED`.

`--fix` never consults it, by construction: `FixVerifier` writes files and then asks whether the project still compiles, so it calls `CompilerOracle` directly. `APQ_NO_ORACLE_CACHE` declines the cache process-wide — a weakening-only switch. The residual holes it does NOT cover (non-`.hx` compile-time inputs, a classpath a `--macro` adds while typing, environment-supplied defines) are listed in the class doc; they are why this is a report-mode fast path and nothing more.

### `apq lint-diff` — the blast-radius gate

`apq lint-diff --old A.json --new B.json [--root <prefix>] [--label <name>]` compares two `apq lint --format json` reports as multisets of `(file, rule, severity, message)`. Line, column, span end and address are deliberately not part of the key — they move under any edit above them. `--root` strips a path prefix from whichever side carries it (a relative and an absolute snapshot of one tree otherwise disagree), and reaches the paths a message quotes as well as the `file` field, because `duplicate-code` names its partner block by path.

A rule that writes a source MEASUREMENT into its own prose re-keys on an edit that changed no finding (`oversized-type` quotes the type's line extent), and a gate waived by reflex has stopped being a gate. The fix is a declaration a check makes about ITSELF: `Check.VolatileMessage`, one method returning the message with its volatile parts masked, collected by `Linter.messageIdentities` and handed to `lint-diff` — `lint-diff` holds no list of rules. The masks are ANCHORED on a literal fragment the check itself wrote (`MessageMask.maskAfter` / `maskBefore`), so exactly one number leaves the key (`oversized-type`'s line extent goes, its member count stays); a blanket digit mask cannot express that split, and on `duplicate-code` it would eat the statement count and any digit in the partner filename. Both snapshots are normalized at COMPARE time, so adding a `VolatileMessage` needs no re-snapshot.

Its two non-zero exits are different on purpose: **1** means the comparison ran and the snapshots disagree, which `--allow-blast` waives; **2** means it could not run at all — a snapshot missing, unreadable or malformed — and that fails the battery whatever flags you pass. Waiving expected movement must never waive a gate that never executed.

### `tools/clone-census.py` — the clone-rule census

`tools/clone-census.py <label> <t2-report> <t1-report> <repo-root> [--after <t2> <t1>] [--removed FILE]` reads the `duplicate-code-renamed` and `duplicate-code` reports (`--flat` text or `--format json`, taken with the CWD at the repo root) and prints findings, families, occurrences, the purely-renamed and cross-file shares, and the bare-run share — the last one by a text regex that is deliberately NOT the engine's predicate (`DuplicateCode.isBareStmt` is structural), so that `--after` can print how the two readings agree on what a filter change removed and kept. Runs are resolved through `hxq ast --json`, so the tool needs `hxq` on the PATH and honours `HXQ_BIN`.

### Scratch directories: every tool's, and who removes them

Five tools create a directory under `TMPDIR`, and every one removes it or leaves it claimed for the startup sweep — a directory kept forever is how a disk fills.

| tool | prefix | success | failure / interrupt |
|---|---|---|---|
| `tools/battery.sh` | `apq-battery.` | removed | kept, path printed |
| `tools/suite-shard.sh` | `apq-suite-shard.` | removed | kept, path printed |
| `tools/mutation-check.sh` | `anyparse-mutcheck.` | removed when every track was KILLED | kept, path printed |
| `tools/mutation-arm.sh` | `anyparse-mutarm.` | removed | kept, path printed |
| `node bin/test.js` (the suite itself) | `apq-suite.` | removed | kept, swept once the pid is gone |

The suite's is `unit.cli.CliFixture.isolateTempDir` — `mkdtemp` plus the same `.apq-owner` stamp, so a SIGKILLed run is reaped by the sweep like the other four; nothing prints on failure because the directory holds only fixtures (why it exists: § "Declared arms", the private-temp-root paragraph). `mutation-arm.sh` runs `mutation-check.sh` as a child, never `exec`s into it — an `exec` takes the caller's EXIT trap out of the process. SIGKILL is the half no trap closes, and it is the common case under an agent harness, so every tool sweeps orphans at STARTUP through `tools/tmp-lifecycle.sh`.

`--keep` on any of the four keeps it past this process's own exit, not just past its own cleanup: a marker file (`tmpl_mark_keep`, `.apq-keep`) that `tmpl_is_orphan` treats as permanently NOT orphan, written only on an EXPLICIT `--keep` (or `suite-shard.sh --plan-only`'s internal equivalent) — never on a bare "kept because red", which ages out through the grace-period sweep, because a marker that fired on every non-green exit would reopen the kept-forever hole. `mutation-arm.sh --keep` forwards it to the `mutation-check.sh` it drives. `tmp-lifecycle.sh --list`'s STATE column reads `KEEP` for a marked directory.

**The sweep predicate, and why it is safe with siblings running.** A claimed directory carries a stamp naming its owner's pid, and a directory is swept only when all of: its basename is one of this project's prefixes plus mktemp's six template characters, **directly** under the scratch root (every other shape is refused out loud, the repo root and `$HOME` included); its stamped owner is gone (`kill -0` fails — a REUSED pid reads as alive, so pid reuse can only make the sweep keep too much); and nothing has written into it for `TMPL_GRACE_SECONDS` (300), read off the newest mtime among its **top-level entries**. A directory with no stamp predates the change and needs `TMPL_LEGACY_SECONDS` (6h) of silence. **Deregistration, not just deletion**: `git worktree prune` only forgets entries whose directory is GONE, so removal comes first and the prune second. `tools/tmp-lifecycle.sh --list` prints every scratch directory with its owner pid, ORPHAN/live verdict, idle seconds and size; `--sweep` runs the predicate by hand; `--help` is the whole rationale; `APQ_TMP_NO_SWEEP=1` turns the startup sweep off.

**Two shell facts, before editing any of these scripts.** A failing LAST command in an EXIT trap REPLACES the script's exit status (`exit 7` under such a trap exits 1, and so does `exit 0`), so every cleanup call inside a trap ends `|| true`. And an async child of a shell WITHOUT job control inherits SIGINT set to IGNORE, and a script cannot trap a signal ignored on entry: any A/B of the signal traps must run the target in the foreground or `set -m`, or both arms measure nothing.

### The shard plan's own producer is cross-checked against a hand-maintained count

`tools/suite-shard.sh` derives everything from ONE list, `node bin/test.js --list-classes`, so its `class parity OK` note is a statement about placement and NOT about completeness: a producer that silently dropped a class hands over a shorter list and every downstream check agrees with it. Only `--verify` could see that — and `tools/battery.sh` passes `--verify` on every non-`--quick` run. A plain `tools/suite-shard.sh -n 4`, the mid-slice form, compares the produced count against `REGISTERED_CLASSES` in `unit.TestDiscoveryParityTest` — a literal a human bumps, not derived from the generator under test — BEFORE any shard runs, and refuses on a mismatch naming both numbers. It is advisory only if the literal cannot be read, and the pin's own assertion inside the run stays the authority.

### The JS build is not reproducible — a binary `cmp` needs the base built TWICE

`haxe bin/apq-js.hxml` on an UNCHANGED tree does not always emit the same bytes: rebuilding the SAME tree twice moves the `-D analyzer-optimize` switch-arm grouping, so `bin/test.js` and `bin/apq.js` each differ from themselves. No gate in this project reads a binary hash — but the moment one does, the naive form is wrong: a single before/after pair says nothing, because the two builds could differ on an EMPTY change. Build the BASE arm at least twice, collect the set of hashes it produces, and require the patched build's hash to fall inside that set; a patched hash outside it is evidence. The same applies to `-D dump=pretty` output and to any "is the generated code unchanged" argument in a slice report — say which arm produced which hash and how many times each arm was built, or do not quote hashes at all. The line MULTISET of the generated JS is the stable alternative (§ "Proving a comment-only change inert").

### A file the oracle's hxml never compiles is permanently un-autofixable

`lint --fix` splits its rules into a safe set and a RISKY set, and the risky ones are applied only when a compiler oracle can typecheck the result. A file outside the oracle hxml's compile set — `test/_ReconSkipParse.hx`, a fixture whose whole purpose is to not compile — can therefore never receive a risky fix: reported every run, fixed by none. `--no-oracle` is NOT the escape: it does not relax the requirement, it removes the thing that satisfies it, so every risky rule goes report-only for the whole run. The two real escapes are to apply the edit with the op the rule's fixer would have used (`remove-import`, `remove-member`, `patch` — the op re-parses and canonicalises, so the file ends in the state the fixer would have left it in), or to bring the file into the oracle's compile set when its absence is the accident. Both are deliberate acts: a fix nothing can verify should not land silently.

### The move family: the one op family with its own byte capture

`lint --all`, a `--fix` tree, `fmt --list` and the refs / rename / safe-delete fixtures between them run every check and every fixer — and not one of them ever calls `move`, `move-member`, `pull-up` or `push-down`. `test/unit/query/MoveFamilyCaptureTest.hx` is that gate: fixtures (a doc block on the moved declaration, a `using` line to carry, an importer to repoint, a `#if`-guarded member, a cross-package static move, plus comments and string literals spelling the moved names) driven through the four ops with the FULL bytes of every changed file pinned, pure and in-memory.

```sh
APQ_TEST=MoveFamilyCapture node bin/test.js   # the move family alone
```

Run it before and after any refactor that touches the shared lexical seam, the `RefactorSupport` scans, or `MoveSymbol` / `MoveMember` / `InheritanceMove`. When it fails, read the diff and decide: bytes that are an improvement get re-captured, bytes that are a regression get the op fixed. Re-capturing to make it green without reading it is the one way the class stops working.

### The corpus is a gate for the WRITER, not for every input the writer reads

The reflex is to read a `sweep --diff` of `0 fixtures changed` as "nothing about layout moved". It does not carry that much: a comment-lexer mutation, and even a classifier broken outright, can leave every corpus verdict identical while the unit pins for the same mechanism fail. The snapshot the corpus writes is a per-fixture PASS/FAIL verdict, not the output bytes, so a fixture already failing can change what it emits and still count as unchanged; and no fixture happens to exercise every width policy. Treat a corpus Δ0 as evidence that the fixtures' VERDICTS held, and reach for a byte capture — a `fmt --write` tree diffed against the other arm, or the unit pins for the mechanism you touched — when the question is whether the bytes held.

### Reproducing the corpus census: `apq sweep --run`

The corpus line (`N pass / N fail / N skip-parse`) is quoted as a gate in every slice report, and a gate whose number nothing can re-derive is one bad refactor away from being decorative. `apq sweep` alone only READS the snapshot the suite's corpus harness wrote; `--run` re-derives it:

```sh
apq sweep --run                                # re-derive the census
apq sweep --run --diff bin/.last-sweep.json    # pair it against the snapshot
apq sweep --run --corpus <dir> --save <path>   # a census of any fixture tree
```

`--run` walks every `.hxtest` under `$ANYPARSE_HXFORMAT_FORK/test/testcases` (or `--corpus <dir>`) and prints the SAME six-counter line the snapshot reader prints, from one copy of the formatting code; `--save` writes the snapshot schema the harness writes, and `--diff` keys both sides through the same normaliser, per fixture. It is a SECOND driver over the same engine, deliberately not a shared one: if `SweepCorpus` and `HxFormatterCorpusTest` ever disagree, `--diff` names the fixtures. Four things a self-comparison has to normalise to agree with the harness: the trailing `\n` the `.hxtest` reader strips from `expected` while the writer emits `finalNewline`; the driver-level `disableFormatting` / `excludes` meta-config; the comment-loss guard (`writeRoundTrip` refuses output that dropped a comment where the harness compares the lossy bytes — both call it FAIL); and the harness's three error buckets against the CLI's one. `apq recon --probe <fixture> --writer-equals` is the single-fixture form.

**`apq fmt` refuses a `.hxtest` by name** rather than reporting a parse failure, and names both replacements: `fmt --write` on a fixture, had it learned to read the input section, would have overwritten the fixture with a third of itself.

### The cross-config `--one-pass` arm

The `fmt` branch's first two arms pair each tree with its own `hxformat.json`. Between them they cover two (tree, config) pairs and no third, and the third is where the writer's convergence tail lives: a file settles in one rewrite under one config and needs two under another, so "`--one-pass` is green here" says nothing about any config but ours. The third arm formats `src test tools` under `tools/xconfig-hxformat.json` — a vendored, fully specified config kept in the repo so the arm is hermetic (the source tree's working copy differs from its committed one; re-vendor from a commit). It runs on a scratch root of SYMLINKS with the vendored config at the root, because config discovery walks up from each file's directory lexically, so an interrupted battery cannot leave the repo holding a foreign config the way a swap could.

What it gates is narrow on purpose. `--list` is NOT a gate here — under a foreign config the whole tree legitimately drifts. The gate is the `--one-pass` SET, compared for EQUALITY against a baseline written into `branch_fmt` (a file leaving the set is progress in the convergence tail and belongs in the list as much as one joining it). A set comparison alone would be satisfiable by a PARTIAL run, so the arm additionally requires the run's own `apq fmt --list:` summary line, printed last, as the completion proof; both summary lines are replayed to stderr rather than re-derived, and the arm silences the config advisory (`APQ_NO_CONFIG_WARN=1`).

### Why `compilerOracleServer` is off here

`apqlint.json` sets `"compilerOracleServer": false` on purpose: on this project the warm server costs a quarter of every lint run for findings that are byte-identical. **The warm path is not warm here** — a `haxe --connect` typecheck of `test-js.hxml` is no faster than a cold one, because a macro-heavy build re-runs its `@:build` macros on the server too. **Its verdict is rejected every run** — the server re-emits stale null-safety diagnostics for two `FileSystem.fullPath` sites the cold compiler accepts (`CompilerServer.realPath`, `StdResolver.resolveSymlink`), and by design a warm REJECTION is never believed on its own, so `Cli.reportOracleVerdict` re-runs it cold. Neither is a defect in `CompilerServer`: the class can only change what a verdict COSTS, and it stays for projects whose modules a server can actually keep. To see the warm diagnostics yourself, read the port out of `$TMPDIR/apq-oracle-*.json` and run `haxe --connect <port> test-js.hxml --no-output`.

### `--no-oracle` for the edit loop

The cold typecheck is PROJECT-WIDE regardless of how narrow the lint scope is, and it is the largest single cost in the edit loop — the "lint the file I just touched" call, run dozens of times a slice.

```sh
hxq lint <file> --all --no-oracle    # the typecheck is most of a single-file run's wall time
```

An `OracleCache` hit only survives while NOTHING on the classpath changed, so in an edit loop every run after an edit pays the cold typecheck. Findings are byte-identical with and without the flag; it changes what the run can PROVE, not what it finds, and says so on stderr. **Never in a gate** — the battery, a pre-commit lint, anything whose output is a verdict runs the oracle, because declining a gate can only weaken one.

**With `--fix` the flag means MORE than in report mode.** The compiler is not asked anything, so the safe-pass revert net is OFF (a fix that breaks the build STAYS on disk — the only way an iteration loop can see the fixer raw), `RiskyFix` rules stay report-only and `OracleAssisted` rules are inert. The run says so on a dedicated stderr line (`compiler oracle SKIPPED (--no-oracle)`), which is why the report-only tails read "no compiler oracle for this run" rather than "no compilerOracle configured". Never in a gate, with more force. Temporarily deleting `compilerOracle` from `apqlint.json` is the worse spelling of the same thing: it edits a TRACKED file.

### The project declares its own sources as `resolutionRoots`

`apqlint.json` declares `"resolutionRoots": ["src", "test"]` — the project's OWN tree, not a library. That reads like a no-op and is anything but: the roots are the RESOLUTION scope, and the report scope is whatever the caller typed. Five checks refuse a rewrite when a name could be spelled by a runtime `Reflect` / `Type.resolveClass` call, and that refusal is only as wide as the strings the run was given: without the roots, `hxq lint <one-file> --fix` erases a name a sibling file spells to `Reflect`. `test/unit/LintScopeGateTest` asserts the roots COVER the paths the gate lints, so the config cannot silently drift back.

What it costs is one read+parse of every project `.hx` the run is not already reporting on, per lint process, only when a whole-scope check runs (the scope stays LAZY). **What escapes the tax is not "project-wide runs", it is the exact `src test` spelling**: a library entry is deduped against the REPORT paths by absolute path before its source is read, so a report scope that already contains both roots pays nothing (`tools/battery.sh`, `branch_lint`); every narrower scope pays in full, directory scopes included. The narrow lint also gets more accurate: the roots arm's findings are a strict SUBSET, guaranteed for the five reflection gates and the whole-scope occurrence scans (`unused-public-member`, `unused-private`), where a wider file set can only ADD evidence of use; for the other consumers of the resolution scope (`redundant-this`, `prefer-index-access`, `map-keys-lookup`) read the subset property as an observation rather than a law. `["src"]` alone was rejected on measurement: with `test/` out of the scope, `lint src --all` reports deletion candidates whose only callers are tests.

**Config discovery folds the whole CHAIN of documents, nearest first**, and a nested one overrides only the keys it names (per key at the top level, per rule inside `rules`, per key inside one rule entry; arrays replace wholesale; `"inherit": false` ends the chain). So `test/apqlint.json` does not re-declare the roots, the oracle keys or the root's opt-in RULES — a missing rule does not fail, it silently finds nothing, which is how a nested document taken WHOLESALE once linted `test/` by a reduced set. The walk stops at a PROJECT ROOT (the first ancestor holding `.git` or `haxelib.json`, that directory's own document included), because a chain that reached `/tmp` or `$HOME` would fold in a stray document whose `compilerOracle` names an hxml `CompilerOracle.typecheck` EXECUTES. `LintScopeGateTest` + `LintConfigInheritanceTest` assert that both documents answer the same resolution scope because it is inherited, not because it was copied.

**Which document answers is per FILE, not per spelling.** `Cli.runLint` expands every spec to `.hx` FILES first and resolves a config per file, so `hxq lint test`, `hxq lint test/unit` and `hxq lint src test` all answer `test/apqlint.json` for a file under `test/`. What IS spelling-dependent: the whole-run project settings (`compilerOracle`, its compile dir, `compilerOracleServer`) come from `resolveConfig(paths[0])`, the config of the FIRST expanded path; a project whose nested document overrides an oracle key would see it.

### A `resolutionLibs`-only config gets none of that, and the tool can only say so

The shape a real repository out there has: `apqlint.json` declaring `resolutionLibs` and NO `resolutionRoots`. The scope is DECLARED (`hasDeclaredResolutionScope()` answers yes) and holds installed libraries plus the std — and none of the project's OTHER sources, because only `resolutionRoots` carries the project's own tree. That key feeds BOTH halves of the scope (`ResolutionSources.projectRoots` directly, the library half through `LintCommand.resolutionThunk`), so leaving it out starves both while every consumer believes it asked the wider one. `CrossScopeSoundnessTest.LIBS_ONLY_REGRESSIONS` pins what a libs-only scope licenses that a full one refuses — a `naming` rename of a field other files reach, an `unused-parameter` drop cross-file callers still pass, an `unused-private` deletion of a live member. No name-keyed proof reads the narrow seam (`RefactorSupport.resolutionProjectSourcesOf`) any more; its two remaining consumers are field-WRITE proofs, where excluding third-party sources does hold.

**There is nothing to repair it with, which is why the fix is a sentence.** Source roots nobody declared cannot be invented — guessing them from the config's directory or the oracle hxml's `-cp` would silently widen every such project's scope. `ConfigDisagreement.warnMissingProjectRoots` prints one line, once per process, naming the shape, the report count and the key (`LintCommand.warnScopeNotices`; pinned by `LintScopeGateTest.testALibsOnlyScopeIsNamedAsAGap`, killed by `M-SCOPE-GAP-SILENT`). It is NOT gated on the run consulting a setting — the missing roots are a property of the scope every check shares, and a hand-kept roster of the checks that read the half would fail open the day a sixth joins. The count is per PATH (`N of M file(s)`): with a root document declaring roots and a sibling `inherit: false` document declaring only libs, the run resolves the UNION of every document's keys but not of their COVERAGE. It stays silent for a scope whose every path resolves a config declaring roots, and for a project that declares no resolution at all (the outcome there is identical, but firing on every config-less foreign repo would be noise).

**A config question cannot see a root that is declared and spelled wrong** — a typo, a moved directory. It expands to no `.hx`, `projectRoots` comes back empty, and the run is byte-identical to one that never declared the key. So there is a second sentence: `ConfigDisagreement.warnUnreachableProjectRoots`, called from `LintCommand.readResolutionRoots`, which expands each root SEPARATELY so the one that matched nothing can be named. It is lazy (a run whose checks never demand the index pays nothing, so a report-mode `--rule naming` stays quiet while `--rule unused-private` prints it), and not a "zero sources read" test (roots are deduped against the report set, so `lint src` under `["src"]` legitimately reads zero of them); the reader carries the `seen` map across roots, because two overlapping roots indexing one file twice trips the resolver's ambiguity gate.

Both notices are pinned at their message seam (`LintScopeGateTest`) AND at their wiring (`LintConfigCliTest.testTheScopeGapNoticesReachTheRun`, a real `Cli.run(['lint', ...])` reading stderr). Three arms cut the three places it can silently go wrong: `M-SCOPE-GAP-SILENT` (the message returns null), `M-SCOPE-GAP-UNWIRED` (the call disappears from `warnScopeNotices`), `M-SCOPE-GAP-ROOT-UNWIRED` (the same for the unreachable-root call).

### The safe pass reverts the file the compiler blames, not the wave

`lint --fix`'s safe pass is applied under a net (`LintFixSafePass`): typecheck before the writes, write, typecheck again, and a green-then-red transition is the fixes' own doing. The rollback used to be ALL-OR-NOTHING (`… REVERTED N file(s), nothing was written`), so one bad edit hid every good file and each bad edit MASKED the next.

The net ATTRIBUTES before it reverts. A compiler diagnostic carries its position as `<path>:<line>: `, so the files it blames are one parse away (`LintFixSafePass.errorFiles`); matched against the files this run wrote by segment-aligned path suffix (the compiler spells positions relative to the hxml's directory, the lint knows them by the caller's path), that is the implicated set. Those files revert, the oracle is asked again, and a green answer keeps everything else. The diagnostic shapes the parser claims each have a test: the classic one-line form; `-D message.reporting=pretty` (an ANSI badge ahead of the path, so the parser anchors on the `:<digits>:` shape and strips CSI sequences); warnings in both spellings, skipped; a colon-digit run with no second colon (a message, not a position) and a candidate with no extension (not a file). Anything unrecognised yields NO implicated file and degrades to the whole-wave revert **with the reason printed** — `the compiler blames no file this run wrote`, `every file this run wrote is implicated`, or `the errors still blamed new files after 4 narrowing round(s)`.

Two shapes the attribution respects. **A cross-file fix is one unit**: `applyCrossFileRenames` commits a rename's whole component together, and an implicated file pulls its whole component back — transitively. **The error can name a file the wave never wrote** (the CALLER of an edited declaration): nothing to narrow to, so the run falls back to the whole-wave revert, says so, and names the files the compiler blamed — from the round that gave up, not the round the wave started with. Either way the run exits `EXIT_RUNTIME` and skips the risky-fix and oracle-assisted passes: a partially-kept wave is a failure that wrote files, and the notice says how many stayed on disk. It attributes rather than bisects because a round is ONE oracle spawn, capped by `LintFixSafePass.NARROW_ROUNDS` (4), where a per-file bisect is O(log n) at best on a typecheck that costs seconds; on a wave that does not break the build the path is not entered at all.

### The `--fix` summary counts EDITS, and is not a verdict about a rule

`apq lint --fix: 4 edit(s) in 1 file(s) over 3 pass(es)` counts EDIT SPANS applied: a check answers with one span per site it rewrites, so ONE `naming` finding on a local read three times is four spans, and a fix whose result exposes a further finding adds that pass's spans. **The finding total is deliberately not beside it**: the edit count sums the safe fixed-point loop AND the risky and oracle-assisted phases, while the only finding count the run holds — the `ledger` — is filled by the safe loop alone. Two numbers on one line measured over two rule sets is exactly the shape this wording was fixed to stop making. The finding total belongs to a plain `lint`; what each rule DECLINED is the block below.

`Check.fix` answers an empty array for a rule that has no autofix and for a rule whose gate closed, and nothing on the interface says which. Two opt-in seams close that: **`Check.NoAutofix`** — a marker plus `noAutofixReason()`, for a rule that is report-only BY DESIGN (*could this rule ever fix?*); and **`Violation.declineReason`** — an optional field the check writes AT the site that declined, in `run` for a whole-scope gate or inside `fix` for a per-site one (*why did it decline HERE*). The default carries the honest answer without either: `computeFileLintEdits` records per rule the first-pass findings, the findings handed to `fix` that came back with no edit, and the edits produced anywhere in the run — a rule that produced an edit somewhere HAS an autofix, so its silence elsewhere is a decline whatever it declares.

The block prints after — never appended to — the summary line, which stays one sentence. Six verdicts, ordered by the strength of the evidence:

| the row says | what it means |
|---|---|
| `no autofix by design — <reason>` | the rule implements `NoAutofix` |
| `fix DECLINED — <reason>` | the rule wrote ONE `declineReason`, and it covers every declined finding |
| `fix DECLINED, N distinct reason(s) over M finding(s)` + `<count>× <reason>` lines | the rule declines per ARM, and each arm's share is counted |
| `fix declined here, yet the rule produced N edit(s) elsewhere` | measured; no declaration needed |
| `its fix was called … and returned no edit; the check declares neither` | the honest default |
| `… and this rule has an oracle-assisted pass besides` | appended for an `OracleAssisted` rule, whose second fix path this ledger never sees |

A `RiskyFix` rule has no row — it is excluded from the safe loop — and is named once at the end rather than shown as a silent zero. An `OracleAssisted` rule that is not also risky DOES run in the safe loop, has a row, and its extra pass is noted on it. A rule whose findings all got an edit is not listed.

#### A rule that declines for several DIFFERENT reasons gets one line per reason

A rule may decline through several arms, and naming whichever the walk reached first states a quarter of an answer with the confidence of the whole, so `RuleFixOutcome.reasons` counts them, sorted by share, capped at three with the tail totalled. A rule with ONE reason keeps the exact single-line `fix DECLINED — <reason>` bytes; a rule that spoke for only SOME of its declines prints `<k>× — the check declared no reason for these`. Each arm's reason OPENS with the constant its reported message is built from, so the two cannot drift. One capability gap behind a `naming` decline: `HaxeNamingSupport.policyFor` prefers a discovered `checkstyle.json`, and `CheckstyleConfigLoader.load` attaches **no `normalize`** to the `format` regex it maps (and DROPS each check's `tokens`), so `correctedName` has nothing to return; `LintFixFixedPointCliTest.testCheckstyleDerivedPolicyDeclinesTheRenameItsOwnFormatDemands` pins the decline, and landing the widening means retiring that assertion on purpose.

### The `--fix` run says which rules it EXERCISED

A campaign's closing proof is a `--fix` run reproduced byte-identically by two engines over a real tree, and that proof is evidence only about the rules the run actually exercised. So the run prints a rule census on stderr, on `--fix` only (a report run writes nothing and so proves nothing):

```
apq lint --fix: rule census — of the N rule(s) this run was given, A produced an edit, B reported and got none, C were never asked, D reported nothing at all. Comparing what this run wrote against another engine is evidence about the first group and about none of the other three.
  exercised: collapsible-else-if, collapsible-if, cond-assign-merge, dead-code, …
```

The denominator is `activeChecks` — the rules enabled for at least one file of the scope, not what `--list-rules` prints — and the four buckets partition it, so a reader can check the arithmetic on the line. Byte-identity across two engines proves the whole report → fix → gate → write path for the rules that produced an edit; that a DECLINE reproduced for the rules that reported and got none; and nothing at all for the never-asked (`RiskyFix` with no oracle) and the silent. A before/after finding-count diff is NOT this census: another rule's edit can delete the shape a rule was reporting on, and a rule can report nothing on the pre-fix tree and fix real sites on a later pass; only the driver knows which check answered with which edits (`RuleFixOutcome.edits`, accumulated over every pass, so a cascade-only rule lands in `exercised`). The NAMES printed are the exercised ones — the positive form of the claim. No fixture corpus is checked in for the rules a real tree never exercises (a second codebase whose only reader is a gate); a slice that edits such a check is covered by the unit suite and the pins below, and its report must say so.

### Rules the deciding arm cannot reach are pinned one fixture per rule

A rule the campaign's deciding `--fix` arm never exercises can be refactored under a green byte-identity proof that says nothing about it. The suite still covers such a rule — a fixture dies when a method the refactor moved stops answering — but nothing NAMED that coverage, so the record is `@:pin('control')` + `@:killer('<arm>')` on one fixture per rule, listed verbatim in `unit.TestDiscoveryParityTest#testThePilotPinsReachTheGeneratedRegistry`. Deleting or renaming a pinned fixture fails that assertion by name. The arm ids encode the constant they force (`-TRUE` / `-FALSE` / `-EMPTY` / `-NULL`) because several methods only discriminate in one direction.

**Half of the risk was never a test's job.** A pure move can go wrong two ways: the call is rewired to the wrong facet (cannot happen silently when the layers declare disjoint public names — `index.members.isSubtype` does not compile), or the method's body changed on the way (covered: each method the rules reach has a killing class). What is left at an UNCOVERED call site is two same-typed arguments swapped in the rewritten call, which compiles and no arm can see — which is why an uncovered site is worth closing rather than declaring.

**The uncovered sites share one shape**: the RIGHT-HAND operand of a short-circuiting `||` whose left operand every existing fixture already satisfied.

- `BackingFieldRefs.classifyOwnerBinding` — `typeDeclaresMember(c, field) || supertypeDeclaresMember(c, field)`. `TrivialGetterShapeCollapseTest#testForeignHierarchyBackingNameStaysAccountedFor` closes it: a class in the scanned file spells the backing name, is no subtype of the owner and does not declare the name — only the supertype half can account for it. The foreign supertype has to live in a file the scan does NOT read (`affectedSubtypeFiles` reads only subtype-declaring and `@:access` files while the index reads them all); declared beside the real subtype, its own `private var _label` lands in the walk and blocks for an unrelated reason.
- `PreferEnumAbstract.fixGrouped` — `hasSubtype(plan.name) || transitivelyCarriesRtti(plan.name)`. `PreferEnumAbstractCheckTest#testFixRefusesAnRttiHomonym` closes it. `@:rtti` ON the container is refused earlier (`conversionPlan` returns null when the preceding sibling is a metadata node) and a SUPERTYPE carrying it earlier still (`headEdit` demands the body opener immediately after the type name) — both would be fixtures that pass for the wrong reason. The one live route is the index's simple-name resolution: a HOMONYM in another module carries the meta, and the conversion is declined for a type that never carried it.

**These pins guard behaviour that already held.** They are red against no commit; what makes them evidence is the arm. Reproducing one: replace the named method's body in `src/anyparse/query/<Layer>.hx` with the constant the arm id spells, rebuild `test-js.hxml`, and the pinned fixture flips. Collateral across many classes is expected, because the arms mutate shared engine code.

### The oracle answers for what it COMPILED, not for what you linted

`haxe <compilerOracle> --no-output` exiting 0 is the strongest gate this project has, and it is authoritative only over the files that compile ran through. That set is NOT the lint scope, and on a real multi-target tree the gap is large and silent: an hxml that types a library with per-target packages has to IGNORE the packages whose externs are not installed (`--macro include('pkg', true, [ … ])`), so a whole subtree earns the green exit code without being typechecked, and `risky-fix verified: N file(s) applied` counts only the files the compiler could SEE.

**The risky-fix path MEASURES that set instead of assuming it.** `anyparse.check.OracleCoverage` runs one `haxe -v --each <hxml> --no-output` from the oracle's own directory and reads its `Parsed <path>` lines — the compiled set named by the compiler itself, across `--next` arms, include chains and ignore lists, none of which the engine models. `--each` is what makes it whole (without it exactly one arm answers, decided by where the flag sits), and its ORDER is part of the claim: `--each` pushes what precedes it into every arm, so `--no-output` sits after the hxml or the probe would suppress output in arms the oracle's own run lets EMIT. `FixVerifier` then DECLINES a risky edit set whose file falls outside the set — before writing anything — and the summary says which:

    apq lint --fix: fixed 20 issue(s) in 11 file(s) over 2 pass(es), risky-fix verified: 11 file(s) applied, 0 reverted to report-only, 28 file(s) DECLINED unverifiable (40 edit(s) the oracle does not typecheck)
    apq lint --fix: risky-fix DECLINED src/pony/net/http/WebServer.hx (prefer-null-coalescing): the compiler oracle does not compile this file (its hxml reads 915 source file(s), this one not among them) — 1 edit(s) left report-only

The files it stops writing are EXACTLY the ones the oracle never compiles — the gate does not buy its honesty by refusing everything — and it is faster, because those typechecks are no longer spawned. The probe costs one compile, taken lazily once some risky check has a candidate, and needs a spawn buffer far past Node's 1 MiB default: an overflow costs the whole risky phase, not a wrong decline. The PREMISE is measured in `OracleCoverageTest`: the identical type error leaves the oracle at exit 0 from an ignored file and fails it from a compiled one.

**The same hole exists one level down, inside a compiled file.** A `#if` branch the arm's defines exclude is skipped at lex time, so the file earns its `Parsed` line while that branch is typechecked by nothing. So the probe splits its transcript into ARMS — one per `Defines:` line, each owning the files parsed after it and the defines it declares (that line's names plus the `--macro define(...)` calls that follow, the only way `nodejs` is visible at all) — and `OracleCoverage.uncovered` asks `CondRegionLiveness` whether the edit's own span is in a branch some compiling arm proves live. Arms are never unioned. The define list is POSITIVE-ONLY, and that asymmetry is the whole soundness argument: a listed flag is proved, an unlisted one is UNKNOWN and never false, so `#if !whatever` can never claim a region no compile produced. A define set inside a BUILD macro, and a condition comparing a define's VALUE (`haxe_ver >= x`, with the `#else` branches it leaves undecided), stay unknown and cost a decline — deciding the latter needs a second implementation of the compiler's version comparison, and a wrong one claims coverage that does not exist.

The limits, in full: coverage the probe cannot establish is not coverage (a `haxe -v` that will not run, exits non-zero, or names no parsed file stops the whole risky phase, the same outcome as no `compilerOracle` key at all); the set is a snapshot probed once per run (a fix that removes the last reference to a module can drop it out afterwards; the common direction only leaves the snapshot conservative); and the oracle-assisted path is deliberately NOT gated this way — it annotates files the compile never enters on purpose, its safety resting on the annotator's own abstentions (`ExplicitLocalTypeOracleAbstainTest`), so its `oracle-assisted: N file(s) applied, M reverted` line still counts only what the compiler could see.

**A second, sharper instance: the deleted code COMPILED.** Inside the subtree the oracle did enter, `unnecessary-null-check` read a `public var esVersion: Int = null;`, called the operand non-null on the strength of the written `Int`, and `--fix` deleted the guard around the line that emits a compiler flag; the result typechecks on every target and the emitted hxml simply changed. **The oracle can only ever confirm that a fix still compiles, never that it still means the same thing.** A rule whose edit DELETES a guard has to prove the guard is dead from the source itself: a declaration whose own initialiser is the literal `null` is nullable whatever its written type says, and a comparison against `null` on a value-typed operand does not COMPILE on a static target, so its presence proves the file's target is one where `Int` is nullable. Two consequences for any project: read the oracle's own exclusion list before trusting its exit code (the excluded packages are the ones with the most foreign coupling, where a bad rewrite is least likely to be a compile error — `OracleCoverage` reads that list on the risky-fix path, but it is one consumer of the exit code, not all of them); and a rule whose failure mode inside such a subtree is SILENT has to gate itself — `inline-constant`'s native-interop gate (`RefShape.nativeInteropDeclMetaName`, `@:nativeGen`) is the worked example, scoped to `inline` alone because `var` -> `final` emits byte-identical C# on a `@:nativeGen` class.

### `fmt --verify` — the invariant the round trip cannot check

A correct formatter changes only WHITESPACE. `apq fmt --verify <paths>` formats each file in memory, strips every whitespace character from the input and from the output, and reports the first place the two disagree — file, source line, and a window of each side. It never writes. This catches a class the writer's own round-trip gate is blind to by construction: that gate asks "does the output re-parse to the same tree", so a writer defect whose output THIS parser still accepts passes it, and `apq self-status`, `fmt --list` and `lint` all stay green on a tree where `@:forward(a, #if f b, #end, c)` no longer compiles under `haxe`.

Read the count, not just the exit status. `--verify` can only speak about files the writer would actually REWRITE — an already-canonical tree gives it a denominator of zero and a clean audit for the wrong reason, which is why the battery points it at the fork tree rather than at `src test tools`. The line carries all three numbers: divergences, reformatted files, and files it could not format. Some policies change tokens on purpose (a trailing comma, braces around a single statement, an optional semicolon) and are reported too; the rule stays "whitespace only" rather than encoding a policy list, because the defect it exists to surface is by definition one nobody has classified yet.

### A comment interior and a string literal are outside every gate

`fmt --verify` bounds the WRITER. Nothing bounds an EDIT OP that splices text INTO a region the writer re-emits byte for byte — a block comment's interior, a string or a regex literal. There the indentation IS the content, and every gate reads past it: the writer re-emits the region verbatim, so `fmt --list` calls the file canonical; no lint rule reads a doc comment's ` * ` continuation prefix; `self-status` only asks whether the file parses; the compiler oracle never looks at comments. A patch that lands one space too deep inside a doc block — or that changes the VALUE of a multi-line string by shifting its lines — produces a green run in every column. `hxq patch`'s line-wise arm did exactly that once (it spliced at the matched line's first NON-whitespace byte, so the source's indentation stayed standing under the replacement's), and it was found by reading `git diff` by eye.

The fix went where such a fix belongs: a postcondition INSIDE the op (`Patch.verbatimSpliceIntact`), not a new lint rule — a rule over continuation prefixes would have to guess intent (a comment interior is legitimately free-form) and could only speak after the damage was committed. The op knows which bytes it synthesised and which region they landed in, so it compares the spliced block's RELATIVE per-line indentation across the writer round trip and refuses when it moved unevenly; a uniform shift is the writer re-basing the block onto its site, a first-line-only shift is the defect. **When an op writes into a region the writer COPIES rather than re-derives, the op is the last thing that can check it.**

The other direction has the same shape: `hxq comment-rewrite` FINDS its place against a normalized copy of the body (every line break plus its ` * ` continuation folded to one space), and a find copied out of that rendering with a boundary space used to map back to the raw break in FRONT of it, eating the break and running two bullets into one line while every gate stayed green. The fix is a POSITION mapping: a leading or trailing break run stays where it is and the replacement's own boundary space stands for it; only an EMPTY replacement — a deletion, which has to take its separator with it — still consumes the break. Both boundaries are pinned separately (`M-COMMENT-BOUNDARY-BREAK-KEPT`, `M-COMMENT-BOUNDARY-TRAIL-INDEX`), because a single-boundary fixture could not see the trailing half being dead while every leading fixture passed.

### `--list` and `--write` disagreed across runs, and only the tool could see it

`fmt --list` and `--write` decide from the SAME comparison — `writeRoundTrip(source) == source` — so within one run they cannot disagree. Across runs they did: `--write` rewrote a file and the very next `--list` reported it again, because the writer's output is not always its own fixed point. A wrap decision that reads the SOURCE line layout gets a different answer once the writer has rewritten that layout (a source-MULTILINE object literal is force-one-per-lined BEFORE the wrap cascade is consulted, and the leading break the cascade emits on pass 1 is what makes the literal multiline). Faithful to the fork, which converges the same way; what was NOT faithful is a `--write` whose result its own `--list` rejects. Several wrap knobs share the shape, so this is a bug SHAPE: any list whose layout can be decided from source newlines instead of from the cascade.

`fmt` therefore writes the FIXED POINT (`anyparse.query.FormatFixedPoint`), not one round trip — and neither swallows nor tolerates what it works around: a file that needed more than one rewrite is REPORTED on stderr with the count (a silent loop would turn a writer defect into a permanent tax nobody can see), and a file that never settles is a FAILURE in every mode with its bytes left alone (`--list` has to fail on exactly the files `--write` cannot fix). A canonical file answers `source` on the first round trip and nothing else runs, so a green tree pays zero extra round trips. The sister of the section above: **a gate that reads the same component the defect lives in cannot see the defect — make the component check its own postcondition.**

### A Pony writer blast pair needs all SIX roots, not `src` alone

A before/after byte comparison of the writer against the user's Pony fork — `cp -R` two copies, format both with the base engine and the slice engine, `diff -rq` — is complete only when it covers every root the fork ships `.hx` under: `src tools tests socketTests install docgen`. A `src`-only comparison answers a narrower question than the one it was asked, and a real writer-affecting file under another root stays outside either engine's reach with no wrong verdict showing. Copy the WHOLE repo (`cp -R /Users/axg/dev/libs/Pony /tmp/pony-SNNN`, never `.../Pony/src`): a `src`-only copy also loses the fork's root `apqlint.json` / `hxformat.json`, so it measures a DIFFERENT config than the fork runs under. `diff -rq` the two formatted copies afterward — a root-scoped file count is not a substitute.

### Every `fmt` summary that reports a count names BOTH quantities

```
apq fmt: rewrote 23 of 870 file(s), 3 failed
apq fmt --list: 0 of 1510 file(s) would be rewritten          # src test tools
apq fmt --verify: 0 of 6 reformatted file(s) changed more than whitespace (36 scanned, 0 could not be formatted)
apq fmt: rewrote 0 of 3 file(s), 1 failed, 2 could not be written
```

The `--write` line used to print the change count with no denominator, and `--list` printed nothing unless a file failed; both readings cost a measurement arm (a `formatted 0 file(s), 3 failed` over a whole tree read as "the run was inert"; `--list`'s silence made a whole-project scan and a three-file match look identical). The fourth mode still reports no count: `fmt <one-file>` with no flags writes the formatted source to stdout, and the output IS the answer. And the denominator alone was not enough: a file the run could not answer FOR (it did not parse, its re-emission would drop a comment) and a file the HOST refused to write are different facts, and the second used to be reported as the first — a `cp -R` copy that kept read-only mode bits made `fmt --write` write NOTHING and say `failed`, which let a before/after comparison be accepted while both sides were the same untouched copy. Only `--write` can produce an unwritable file, so the clause is absent by construction in every other mode; a write that THROWS is caught by `formatOneFile`, named, and counted under its own word rather than taking the run down with an uncaught host error. The exit status was never the half that lied: a write failure has always exited non-zero.

`unit.cli.ApqCountSummaryCliTest` pins all of it against the BYTES, never against `fmt --list`: the fixture directory is snapshotted before the run and re-read after, and the count line must equal the number of files whose bytes moved. The seam that makes it possible is `Cli.fmtRun`, which returns the summary instead of printing it — `Sys.stderr()` on hxnodejs is a raw fd, so a line that only ever reaches fd 2 can be asserted by no in-process test.
