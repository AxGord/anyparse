# Testing approach

Testing a parser platform is not the same as testing application code. A grammar must behave correctly on inputs its author never thought of, and a writer must produce output that the parser can round-trip. Unit tests alone are insufficient. This document describes the six-layer testing strategy that anyparse adopts.

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

Unit test files live in `test/unit/` with one file per component. Test runner is `test/RunTests.hx`.

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

Already in place: `test/unit/JsonRoundTripTest.hx` with ~30 curated cases plus 200 randomly generated ones (both write and parse go through the macro-generated pipeline).

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

Neko is not a benchmark target: the neko build of the CLI compiles but its
artifact dies at module load (measured 2026-08-17). `--jvm` builds and runs
the core fine, but it is a portability probe, not a delivery target.

Each benchmark outputs structured JSON with throughput, timing breakdowns, and memory usage. CI collects these and compares against a baseline.

**Benchmarks are not in Phase 1.** They matter starting from Phase 2 when a macro-generated parser has a baseline to measure against. Phase 3 (Haxe formatter) and Phase 4 (AS3 converter) are where benchmarks become critical.

### The profiling harness

`tools/ParseProf.hx` is the one that exists today. It builds straight out of
`src/` with the flags the shipped CLI uses, so what you profile is the codegen
that ships:

```sh
haxe tools/parse-prof.hxml                                  # -> bin/parse-prof.js
node bin/parse-prof.js tparse src 1 hxformat.json
node --cpu-prof --cpu-prof-interval=200 bin/parse-prof.js rt src 3 hxformat.json
```

The native twin is `tools/bench-hxcpp.hxml`. Point `HXCPP_COMPILE_CACHE` at a
persistent directory or every build is a cold ~40 s instead of an incremental
~12 s, and pass the binary to `tools/bench-ab.sh` as any other arm — an arm
path that does not end in `.js` is executed directly instead of under `node`:

```sh
HXCPP_COMPILE_CACHE=~/.hxcpp_cache haxe tools/bench-hxcpp.hxml   # -> bin/parse-prof-cpp/ParseProf
TM_SRC=<other-tree>/src tools/bench-ab.sh tparse tools/bench-corpus.txt 9 6 \
  js:bin/parse-prof.js cpp:bin/parse-prof-cpp/ParseProf
```

There is no `--cpu-prof` on a native binary; the equivalent is macOS `sample`,
and it needs symbols the release link strips. Rebuild the SAME objects with
`-D no_gcc_strip` into a scratch output — the compile cache makes it a relink,
so the code being sampled is the code that was timed — then sample the run:

```sh
haxe -cp src -cp tools -main ParseProf -D analyzer-optimize -D no_gcc_strip -cpp /tmp/pp-sym
/tmp/pp-sym/ParseProf tparse tools/bench-corpus.txt 90 hxformat.json & sample $! 30 1 -f /tmp/pp.sample
```

Read the capture per THREAD: hxcpp runs parallel GC threads whose idle
`__psynch_cvwait` swamps the flat "sort by top of stack" list, so self time has
to come from the main thread's call-graph subtree (node count minus the sum of
its children). Frames inside the executable print as `??? + 0x<offset>`; resolve
them against `nm -n` with a `0x100000000` base.

Arguments are `<mode> <dir-or-manifest> [reps] [hxformat.json]`; a directory is
walked for `.hx`, anything else is read as a manifest of paths with `#` comments
and `${NAME}` environment expansion (`tools/bench-corpus.txt` is the calibrated
one). The modes stack from the IO floor upwards — `read`, `tparse` (Fast-mode
parser), `walk` (plus the `QueryNode` projection), `write` (writer alone, with
the feeding parse subtracted), `rt` (exactly what `hxq fmt` runs), `lint`, and
`perfile` for a per-file TSV that feeds corpus stratification. Each workload
runs inside its own `phaseXxx` function so a V8 `--cpu-prof` tree can be
attributed by nearest phase ancestor.

Measurement hygiene lives in `tools/bench-ab.sh`, and the rule it exists to
enforce is that a before/after pair timed minutes apart on a shared machine
drifts by more than the effects being measured: arms are interleaved and the
per-arm median is what gets quoted. Battery timings are the opposite kind of
number — deliberately concurrent wall clock — and must never be quoted as
benchmark results.

### Reading a capture: `tools/ProfTop.hx`

A `.cpuprofile` is a call tree, not a report. `ProfTop` rolls one up by SELF
time per function and prints the top rows:

```sh
node --cpu-prof --cpu-prof-dir=/tmp/prof --cpu-prof-interval=200 \
  bin/parse-prof.js tparse tools/bench-corpus.txt 2 hxformat.json
haxe -cp tools --run ProfTop /tmp/prof/*.cpuprofile 20
haxe -cp tools --run ProfTop /tmp/prof/*.cpuprofile 10 --under phaseWrite
```

No build step — it is a `--run` script over the std library, which is where the
language policy puts standalone logic. (`--interp` does not work: it eats the
trailing arguments as its own.) Self time comes from `samples` + `timeDeltas`
rather than `hitCount`, so a capture taken with a custom `--cpu-prof-interval`
still reports real microseconds. `--under <fn>` narrows the rollup to samples
whose stack passes through a frame of that name, which is how one phase of a
multi-phase harness gets attributed; it matches the rendered row label
(`functionName  [file]`), and Haxe class names do not survive into JS frame
names, so `--under phaseWrite` works where `--under CompilerServer` matches
nothing.

**`spawnSync` and friends are BLOCKED WAIT, not CPU.** A profile samples
whatever frame is on the stack, and a synchronous child-process call sits there
for the whole child's lifetime — `spawnSync` at 54.6% means "we waited on
children for 54.6% of the run". That is worth knowing and it is not our CPU:
optimising our own code cannot shrink it. Both of the largest wins of
2026-08-18 came from reading it that way (the warm compiler server bought
nothing; a single-file lint was paying for a project-wide typecheck), and
reading it as CPU would have sent the work into the analyser instead.

Read a profile for SHARES and take deltas from a separate unprofiled run:
`--cpu-prof` overhead is not uniform across trees (+7% anyparse, +15% TM), so a
profiled before/after pair is not a delta.

## Layer 6: End-to-end integration tests

Full pipeline tests on real-world data. Take a substantial input (the user's ax3 corpus, a large Haxe project, a corpus of JSON API responses), run it through the full pipeline (parse → transform → write), and compare against an expected output.

**Catches**: interactions between multiple parts of the platform that unit tests miss. Grammars, transforms, writers, and formatters interact in ways that are impossible to cover fully with unit tests.

**Added at Phase 4 onwards**, specifically for the AS3→Haxe conversion replacing ax3. The user's ~2000-file corpus is the canonical integration test: the new tool must produce equivalent Haxe output on every file, ideally faster than ax3 and without JVM.

## Mutation checks: testing the tests

The six layers all answer the same question from different angles: does the code do what it is supposed to do? A mutation check asks the inverted question: if the code *stopped* doing it, would anything go red?

That question has to be asked separately, because a green suite is not evidence that the suite covers anything. A mechanism can be exercised by no fixture at all and still sit inside a passing run — every test that touches the file happens to take another branch, or asserts on a property the mechanism does not affect. The suite reports success, the coverage number looks fine, and the mechanism is a vacuum: it can be deleted, inverted, or quietly broken by an unrelated refactor and nothing will say so. The only reliable way to find such a vacuum is to break the mechanism on purpose and watch what the suite does.

### The runner

```sh
tools/mutation-check.sh <manifest> [--jobs N]
```

Each *track* in the manifest is one deliberate breakage. The runner gives every track its own git worktree checked out from `HEAD`, applies the track's patch there, builds a private test runner into a private workdir (`tools/worker-build.sh`, see "Parallel tracks" below), runs the requested slice of the suite with the CWD set to that worktree, and classifies the transcript. Tracks run in parallel; `--jobs` defaults to `max(1, min(4, cores/2))`, and an explicit `--jobs` must evaluate to a positive integer (`0` — and `00`, and any other spelling of zero — is rejected rather than clamped, since `xargs -P 0` means unbounded).

Because worktrees come from `HEAD`, uncommitted work in the main tree is invisible to a track. That is deliberate — a track measures a named commit plus one patch, not whatever happens to be lying around — but it means a mutation aimed at uncommitted code has to be committed first, or folded into the patch.

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

The patch is a `git diff` rather than a script or a sed expression because the worktree is created from `HEAD`: a diff taken against `HEAD` applies there deterministically, and authoring a track needs no new tooling. Break the mechanism in the main tree, `git diff > x.patch`, revert, add a manifest line.

**Give every track a narrow `APQ_TEST` filter.** A track with `ALL` pays the entire suite for one mutation, and drags in cases whose outcome depends on the environment rather than on the mutation — most notably the corpus harness, which only runs when `ANYPARSE_HXFORMAT_FORK` is set. A filter naming the one or two classes that are supposed to catch the breakage keeps a track at seconds and keeps its verdict about the mutation.

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

`SURVIVED` is deliberately stricter than "nothing failed". utest computes `isOk = !(hasFailures || hasErrors || hasWarnings)`, and it auto-adds a `Warning('no assertions')` to any test method that completes without asserting. So a mutation that makes a test stop asserting produces `failures: 0, warnings: 3` and a red run — which a scan for `FAILURE`/`ERROR` rows alone would have reported as a survivor, in the one direction where a wrong answer costs the most. The verdict therefore comes from the header line, and the per-class rows are used only to *name* what went red. A marker the classifier does not recognise leaves a red run unnamed, which surfaces as `RUN-FAIL`, never as `SURVIVED`.

**The classifier is `apq mutation-verdict`, not the script.** `tools/mutation-check.sh` shells out to it and does nothing with the transcript itself:

```sh
apq mutation-verdict <transcript> [--expect <csv>]   # line 1: verdict, line 2: row detail
```

It used to carry its own ~130-line awk implementation, which was a *second* utest transcript parser — `apq test-summary` had done that job for longer than the script has existed, and `tools/suite-shard.sh` reuses it precisely so a divergent copy cannot grow. One grew anyway, and the price is on record: both fixes `fdb44864` ("a red run can no longer be reported `SURVIVED`") and `ff3f20ae` ("find the utest header by *shape*") were bugs in the duplicate, 316 changed lines apart, and neither was reachable by a test, because a shell function is not testable. The Haxe classifier is pure over `TestSummaryResult` and covered by `test/unit/MutationVerdictTest.hx`.

Two consequences worth knowing. The classifier runs from the **main** tree, never from the track's own build — a track's engine is compiled from the *mutated* source, so a mutation reaching the transcript parser would otherwise grade its own homework; `mutation-check.sh` therefore refuses to start when `bin/apq.js` is missing. And the `--expect` exit code answers *"could this be classified"*, not *"what was the verdict"*: every verdict, `RUN-FAIL` included, exits 0.

Failures *beyond* the expectations do not demote `KILLED` to `MISMATCH`; they are listed on the row as `+extra: …`. A track asks whether the suite notices, and a wider blast radius still answers yes — the extras are reported because they are useful signal about coupling, not because they are a defect.

Exit code: 0 only when every track is `KILLED`. Any other verdict exits 1, so a manifest can guard a mechanism in CI.

The report is one row per track in manifest order, followed by a summary and the workroot path:

```
KILLED     doc-blockonly        filter=SetDoc         2 tests failed / 40 assertions: unit.SetDocSliceTest.testX, unit.SetDocSliceTest.testY
SURVIVED   dead-branch          filter=HxLexer        0 tests failed / 85 assertions
MISMATCH   foo                  filter=Bar            2 tests failed / 9 assertions: … (missing: unit.BazTest)
3 tracks: 1 killed, 1 survived, 1 mismatch, 0 error
```

The two figures on a row are in different units on purpose: the count of failing *test methods* against the total *assertions* utest reported, since that total is the only run-size figure the header carries — once a run goes red utest stops listing the passing tests, so there is no test-level total to divide by. The name list is capped at the first ten, with `…+N more`; the full set is in the track's transcript, which the workroot path points at.

Every worktree the runner created is removed on exit, including on `INT`/`TERM`/`HUP`. A `worktree remove` that itself fails is swallowed so one bad entry cannot strand the rest — which does mean a stuck worktree can survive as a registered entry, so `git worktree list` is worth a glance after a crashed run. The workroot itself is never deleted: its transcripts, build logs and verdict files are the post-mortem. They accumulate in `TMPDIR` across a long campaign, so a campaign that runs for days is worth sweeping by hand.

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

### The runner is quiet by default, and one of the two arguments is load-bearing

`RunTests.main` calls `utest.ui.Report.create(runner, NeverShowSuccessResults,
AlwaysShowHeader)` and installs a per-test stdout capture. Both halves exist for
one reason: a raw suite run printed **807 979 bytes** where every gate in this
project reads **six lines**, and for a delegated agent that difference dominates
the whole cost of a slice.

- `NeverShowSuccessResults` drops the per-method `: OK` listing — 13 488 lines.
  It drops only PASSING lines: `ReportTools.skipResult` returns `false` for
  `!stats.isOk` before it ever reads the mode, so failures, errors and warnings
  still print in full with message and stack.
- **`AlwaysShowHeader` is load-bearing, not decoration.** Under the default
  `ShowHeaderWithResults`, `ReportTools.hasHeader` returns FALSE for a green run
  once success results are hidden — the `successes:` / `errors:` / `failures:`
  summary would vanish along with the noise and every gate that greps it would
  silently pass on nothing. Never drop that argument.
- **The runner prints its own `tests executed: N` line**, counted off
  `runner.onTestComplete` and emitted from `runner.onComplete`. utest's summary
  block carries assertions but no test total, and with the per-method rows gone
  a green transcript had no countable test count at all: `apq test-summary` read
  `0 tests / 0 assertions` off every quiet log, and `tools/suite-shard.sh`
  hard-failed on that zero for eighteen slices while reporting
  `parity: counts not cross-checked`. The listener is registered BEFORE
  `Report.create` on purpose — the report's own `onComplete` handler calls
  `process.exit` from inside the dispatch, so anything added after it never
  runs — and it is counted rather than read off `runner.length`, so a run that
  dies mid-way prints neither this line nor utest's block and the transcript
  stays visibly uncountable. The line is read only ALONGSIDE utest's block,
  because the two are printed together and every test's output comes first:
  read on its own it is forgeable, and a transcript that died after a failing
  test whose flushed stdout carried the phrase reported `999 tests` at exit 0.
  `apq test-summary` now EXITS 1 when it finds no report at all — no header
  block, no result row, no tink reporter output — naming what it could not
  find instead of printing four zeros that read exactly like a clean count.
  The question is whether a report was FOUND, never whether its numbers are
  zero: a utest "No tests executed." run and a tink suite that ran nothing
  (`0 Assertions 0 Success 0 Failures 0 Errors`) are both all-zero ANSWERS,
  and an all-zero test refused the second one outright.
- The **per-test stdout capture** buffers what each test prints and discards it
  when the test passes; any non-`Success`/`Ignore` assertation flushes the
  buffer verbatim first. The CLI e2e tests drive `Cli.run`, which is chatty, and
  a passing run's chatter explains nothing.

Measured: stdout **807 979 → 359 bytes**.

⚠️ **Only stdout is interceptable, and the asymmetry is measured, not assumed.**
Patching both `process.stdout.write` and `process.stderr.write` captured
**118 706 bytes of stdout and ZERO of stderr**, while 74 514 bytes still reached
the terminal — `Sys.stderr()` on hxnodejs writes a raw fd and bypasses the JS
stream entirely (the same fact that makes an fd-2-only line unassertable by any
in-process test). Drop that half at the shell with `2>/dev/null`; no code in the
runner can do it.

`APQ_TEST_VERBOSE=1` restores both the per-method listing and the captured
output for a human reading one run.

## Guidelines for new tests

### A guard on `#if sys` is a test that does not run

`sys` is NOT defined by an hxnodejs build, and js/node is the only runner the suite has.
So a test method whose body sits inside a bare `#if sys` compiles to its `#else` arm — by
local convention `Assert.pass('non-sys target')` — and reports a success while asserting
nothing. It compiles, it is green, and it is dead. Guard anything that needs a filesystem
or a process with `#if (sys || nodejs)`.

The rule was written down years before anything enforced it, and the pre-existing
population was never swept: at `1514f108` the tree carried **218 bare `#if sys` guard
sites across 23 test classes — 167 whole test methods**, and the emitted `bin/test.js`
held exactly **178** `Assert.pass('non-sys target')` calls (a preprocessor simulation over
`test/` and a text count over the bundle agreed on that number). Widening every guard took
the bundle's count to 0 and the real assertions in those 23 classes from 76 to 318.

`unit.DeadTestGuardTest` is what makes the return loud. It walks `test/`, reads every
directive through `CondDirectives.scan` (the shared reader, so a `#if` inside a comment or
a string fixture is not a guard) and evaluates each condition with
`CondRegionLiveness.evaluate` against the flag set `unit.BuildDefines` reads out of the
running build via `#if <flag>`. Any guard the build cannot prove LIVE fails the suite,
naming the file, the line and the remedy — with one disclosed exception, `BuildDefines`'
own `#if <flag>` probes, which are unprovable by construction because they ARE the
question. Note "cannot prove live", not "is dead": a condition the reader cannot delimit
(`#if (a` continued on the next line is legal Haxe that still compiles its body out)
carries no condition span, and is reported rather than skipped.

Two design points worth keeping: it is a suite gate rather than a lint check because
"`sys` is dead" is a property of ONE build, not of the language — `src/` carries
`#elseif sys` on purpose at six sites for the neko/hxcpp targets — so a rule would need a
`deadDefines` config key, which is the original defect one level up: a claim about the
build that nothing verifies. And `BuildDefines` is a separate module holding no test
method, because asking `#if sys` is unprovable by construction and therefore has to be
exempt; keeping the exemption in a module with nothing to swallow keeps it from becoming a
hiding place.

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

## Running tests

```sh
haxe test-js.hxml           # compile the runner to bin/test.js
node bin/test.js            # the whole suite, one process (~30s)
tools/suite-shard.sh -n 4   # the same suite across 4 processes (~14s)
APQ_TEST=RemoveParam node bin/test.js   # one class, for the edit loop
```

Those two figures were ~21s and ~9s until the `#if sys` guard sweep above revived 167
test methods that had been compiling to `Assert.pass`. The 23 revived classes cost 7.5s
together, of which `ApqAstIntegrationTest` — a whole-tree engine walk that nothing had
run since it was written — is 6.0s. `DeadTestGuardTest` itself is 0.06s.

js/node is the only runner. The suite itself is not target-independent —
`CompilerOracleE2ETest` calls `js.node.Fs` directly to pin fixture mtimes —
so there is no neko or `--interp` build of `RunTests`, and the neko/interp
hxml files that used to sit beside `test-js.hxml` were deleted rather than
left as runners that no longer compile.

Both `test-js-common.hxml` and `bin/apq-js-common.hxml` pass
`-D analyzer-optimize`, so the suite exercises the codegen that ships.

### The core stays target-independent

The runner being js-only says nothing about the library. Parser, writer and
the whole `apq lint` check set compile straight out of `src/` for a static
target — no copies, no stubs — and that is design principle 3 ("Pure Haxe
delivery, no JVM dependency") in practice:

```sh
haxe -cp src -main <harness> -D analyzer-optimize --jvm out.jar
```

Two things break this quietly, and both did:

- **A bare `import js.node.…` at module scope.** The *uses* were already
  behind `#if nodejs`; the import was not, and an import is resolved
  unconditionally. Guard the import with the same condition as its uses.
- **A `final` field in a structure `typedef` that a bare object literal has
  to be inferred INTO.** A `final` structure field lowers to a `never`
  setter. Where the expected type is written at the literal (a declared
  local, field, parameter or return type) that costs nothing — `GrammarPlugin.LayoutMetrics`
  keeps its `final` fields and builds for every target. The error appears
  where the literal's own anonymous type is inferred FIRST and the typedef
  then has to unify with it, typically through a type parameter: a lambda
  returning `{ nodes: …, certain: … }` binds `fold`'s `S` to the plain
  anon `{ nodes, certain }`, and a `MemberRun -> MemberRun -> MemberRun`
  join no longer fits (`Inconsistent setter for field certain : never
  should be default`).

  Measured on `MemberBranchScan.MemberRun`, one variable — same source,
  same flags, target swapped: `--jvm` rejects it; `-js` and `-neko` both
  accept it. Not measured on hxcpp. So this is not "js versus static
  targets": it is `--jvm` being strict where the others are lax, which is
  exactly what makes a `--jvm` build worth running. The reverse also
  holds — a shape where the join is a top-level function rather than a
  lambda is rejected on `-js` too, so `final` here is not a
  target-conditional style choice but a real unification constraint.

A `--jvm` build of a minimal parse+lint harness is the cheapest way to
re-check this after a slice that touches `src/anyparse/query` or
`src/anyparse/check`. That harness is committed:

```sh
haxe tools/jvm-portability.hxml     # ~9s; parser + writer + every builtin check
java -jar bin/jvm-portability.jar   # prints the counts it parsed and linted
```

It is a portability PROBE, not a dependency: nothing anyparse ships needs a
JVM. It exists so the invariant above is something a slice can fail on
instead of a paragraph nothing can flip.

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

The previous section parallelises *workers*. This one parallelises a *single* suite run. `tools/suite-shard.sh` splits the registered test classes into N `APQ_TEST` filters and runs one `node bin/test.js` per shard. The split itself is not the script's — `apq shard-plan --runner test/RunTests.hx --shards N [--format lines|filters]` reads the registrations, applies every gate below, and prints the plan; the script spawns processes and waits. That division is the reason the gates are testable at all (`test/unit/ShardPlanTest.hx`), which they were not while they were awk:

```sh
tools/suite-shard.sh                      # 4 shards (default)
tools/suite-shard.sh -n 6                 # the measured knee on a 16-core box
tools/suite-shard.sh --verify             # + a monolith run, counts compared
tools/suite-shard.sh --expect <T>/<A>     # + compare to YOUR last known-good pair
tools/suite-shard.sh --plan-only          # print the plan, run nothing
tools/suite-shard.sh --bin /tmp/w1/test.js  # a private worker build (previous section)
tools/suite-shard.sh --keep               # keep the work directory even on success
```

`--verify` and `--expect` are mutually exclusive — the first measures the pair the second asserts. Do not copy a literal into `--expect` out of this document: the totals move with every slice, and a stale pair fails a run that is fine.

Measured on Mac15,9 / 16 CPU at `11423 tests / 24066 assertions`, wall time of the parallel region (end-to-end including planning in brackets):

| shards | wall | speedup |
|---:|---:|---:|
| 1 | 21.8 s (22.4 s) | 1.0x |
| 2 | 13.8–14.1 s (14.5–14.9 s) | 1.6x |
| 4 | 8.5–8.9 s (9.5–9.9 s) | 2.5x |
| 6 | 6.8–6.9 s (8.2–8.3 s) | 3.2x |
| 8 | 6.9 s (8.5–8.6 s) | 3.2x |

Past six shards the curve is flat: what remains is the sticky group below plus the per-process warm-up each shard re-pays (roughly 2.4 s of std/haxelib resolution parsing that a single process pays once). The default stays at 4 because the extra shards buy ~1.5 s at the price of that warm-up multiplied again — worth asking for explicitly on a many-core machine, not worth defaulting to on a small one.

**The sticky group.** Most tests write unique per-run temp directories and pick random compiler-server ports, so they parallelise freely. Two paths are fixed constants and are *not* safe to split: `/tmp/anyparse-last-probe.hx` (`Cli.STAGE_PROBE_PATH` — a single slot that `apq probe` overwrites and the Tier-5 tests read back byte-for-byte) and `bin/.last-sweep.json` (the corpus Δ-baseline, rewritten by `HxFormatterCorpusTest` and read by `ApqDxTier5CliTest`). The eight classes that touch them are pinned to shard 0 as one block.

That list is derived, not remembered: `hxq lit 'probe' test/ --kind Literal` finds every class holding an exact `'probe'` string leaf (read each hit — one of them is a fixture *method* named `probe`, not the subcommand), and `hxq lit '.last-sweep.json' test/` finds the baseline's users. Re-derive it when adding a test that stages a probe or touches the sweep baseline. A writer left outside the group does not fail the run: it races the read-back assertion in a window of well under a millisecond, so it shows up weeks later as an unreproducible flake. Better still is to make the path configurable so the block can shrink.

**Parity is a gate, not a hope.** A sharded run that silently drops a class still reports green, so `apq shard-plan` refuses to emit a plan unless the union of the shard lists equals the registration list exactly. Three specifics worth knowing:

- The class list is read structurally out of `test/RunTests.hx` — `addCase(new X())` as an AST shape, never a name heuristic. Nine registered classes do not end in `Test` — five end in `Probe`, four *begin* with it — so both a `*Test` suffix filter and a `*Probe` glob drop tests silently; the suffix filter loses 43 of them, and nothing else notices. Because the read is structural, constructor arity and dotted-vs-bare names are structure too: a `NewExpr` carrying arguments, more than one argument, or an argument that is not `new` at all is a REFUSAL naming the line. The predecessor was a search pattern plus a regex strip, and it dropped `addCase(prebuilt)` and `addCase(new A(), new B())` in silence — a class registered either way ran in no shard while class parity still passed.
- `APQ_TEST` is a **substring** match over the fully-qualified class name. A name that is a substring of another would run in two shards and inflate the totals, so the generator hard-fails on any such pair rather than producing a plausible-looking wrong number.
- The sticky list is hand-maintained (`ShardPlan.STICKY_CLASSES`), so every pinned name must still be registered — otherwise a rename un-pins a class in silence and the race comes back. The per-class weights next to it only balance the split; no gate reads them, so a stale weight costs balance and never correctness.
- Test and assertion totals grow with every slice, so no literal is pinned in the script. Class parity plus the no-collision gate plus a non-empty, green shard is what makes the totals trustworthy; `--verify` (pays for a monolith run, and fails on a monolith that is red as well as on one that disagrees) and `--expect T/A` are the explicit cross-checks when you want the totals proved rather than argued.

Exit status is 0 only when every shard is green *and* parity holds. A red shard, an empty shard, a collision, an unnameable registration, an un-pinned sticky class, a misplaced class or a count mismatch all exit non-zero and keep the work directory — the shard logs when the run got that far, the plan files when it refused earlier.

**When to shard, when not.** Shard the full battery during a slice — after the `APQ_TEST`-filtered edit loop, when you want the whole suite as a checkpoint. Run the **monolith** for the final pre-commit run of a slice or campaign, and any time the shard plan itself changed (a new sticky-state test, a new fixed shared path, a new class whose name overlaps another).

Sharding moves the suite along two axes at once, and they fail in opposite directions. It changes **ordering** — cross-class effects like a warm cache one class leaves for the next, or a first-in-pays-the-warm-up cost, appear or vanish depending on which classes share a process, so a bug that only fires when A runs before B is invisible to a run that puts them in different processes. And it adds **concurrency** that the monolith never had: classes that used to be merely sequential now run simultaneously against one working tree, one `/tmp`, one `$HOME`. The monolith is the insurance against the first; the sticky group is the insurance against the second. One monolith per slice buys the first cheaply — nothing buys the second except keeping the shared-path inventory honest.

## The per-slice battery

Every slice ends with the same checks, and running them by hand is not only
slow — the step most often skipped under time pressure is the one with no
cached "before" arm to make it cheap, and a skipped step reads exactly like a
passed one in a summary. `tools/battery.sh` is that sequence as one command
with one verdict:

```sh
tools/battery.sh                    # build, suite + monolith cross-check, corpus,
                                    #   fmt, jvm probe if the core moved, lint, blast
tools/battery.sh --quick            # mid-slice: drop the monolith cross-check
tools/battery.sh --base 29011103    # compare the blast radius against a named snapshot
tools/battery.sh --snapshot         # on green, cache this HEAD as the next "before" arm
tools/battery.sh --allow-blast      # accept the blast movement it printed last run
```

`ANYPARSE_HXFORMAT_FORK` must be set: without it the corpus layer skips in
silence, and a battery that cannot tell "corpus clean" from "corpus not run"
is worse than no corpus gate, so the script refuses rather than warns.

### The move family: the one op family with its own byte capture

`lint --all`, a `--fix` tree, `fmt --list` and the refs / rename / safe-delete
fixtures between them run every check and every fixer — and not one of them ever
calls `move`, `move-member`, `pull-up` or `push-down`. A seam refactor across 109
files therefore shipped a `MoveSymbol` scan reading the CURSOR file's comment
regions while scanning the DESTINATION's text, with the whole suite green; it was
caught by the author's own forwarding audit, not by a gate.

`test/unit/MoveFamilyCaptureTest.hx` is that gate: five fixtures — a doc block on
the moved declaration, a `using` line to carry, an importer to repoint, a
`#if`-guarded member, a cross-package static move, plus comments and string
literals spelling the moved names — driven through the four ops with the FULL
bytes of every changed file pinned. Pure and in-memory (no temp directory), 5
tests / 17 assertions in 0.02 s, so it costs the suite nothing measurable.

```sh
APQ_TEST=MoveFamilyCapture node bin/test.js   # the move family alone, ~0.3 s
```

Run it before and after any refactor that touches the shared lexical seam, the
`RefactorSupport` scans, or `MoveSymbol` / `MoveMember` / `InheritanceMove`. When
it fails, read the diff and decide: bytes that are an improvement get re-captured,
bytes that are a regression get the op fixed. Re-capturing to make it green
without reading it is the one way the class stops working.

### The step graph: four branches, one join

The checks read like a sequence, but their dependencies are far sparser than
their order, so they run as four concurrent branches:

```
build ──┬─ suite ── corpus          build = apq.js + test.js + a recon typecheck
        │                           corpus reads the snapshot the suite wrote
        ├─ fmt
        ├─ jvm probe                only when the core moved
        └─ oracle ── lint ── blast  lint reuses the oracle's verdict;
                                    blast diffs lint's own output
```

`build` stays sequential because everything else executes what it produces. Its
third compile is a TYPECHECK, not a build: `haxe recon.hxml --no-output` is the
only gate that reaches `test/_ReconSkipParse.hx`. `-main RunTests` types what the
suite references and no test references the corpus drill's harness, so that module
had no gate at all and could rot against any `src/` signature it calls — measured
by planting `private static function s17PlantedDefect(): Int { return 'not an Int'; }`
in it: `haxe test-js.hxml` and `haxe bin/apq-js.hxml` both stayed exit 0, the new
step failed the run with `recon.hxml did not typecheck`. `--no-output` writes no
`/tmp/recon.js`, so concurrent workers do not share one artifact, and it costs
~2.6s inside a stretch the ~25s test compile already owns.

Inside a branch the order is a real dependency; across branches there is none
that matters: all four read `src`, and each branch's writes are read only by
itself. The suite branch is not read-only — it rewrites `bin/.last-sweep.json`,
rotates `.prev-sweep.json` and stages `/tmp/anyparse-last-probe.hx` — but its
own corpus step is the only consumer, and the jvm probe's
`bin/jvm-portability.jar` has none. Check that again before adding a fifth
branch rather than inheriting the claim: `tools/suite-shard.sh`'s shared-path
inventory was written for shard-vs-shard, not for branch-vs-branch. `HXQ_QUIET=1` is exported
between the build and the fork, and that ordering is load-bearing in both
directions: set earlier it would let a stale binary through the launcher's
own probe, set later a branch would decide to rebuild `bin/apq.js` while
three others are executing it.

Concurrency must not cost a result, so two properties are built in rather
than hoped for.

**Every branch is collected.** A red suite no longer stops the run: it fails
the verdict and the other three branches still report. Three broken things
are reported as three, because "one step failed and three never ran" is the
summary this script exists to prevent. Each branch queues its failures to a
file that the driver replays after the join — a branch subshell's own
`verdict` variable is a copy that would be thrown away.

**A step has three outcomes, never two.** The driver writes down, at launch,
the step labels each branch PROMISES to record; after the join a promised
label with no row becomes `not run` — printed as such in the timing table and
failing the verdict on its own. That covers the anticipated case (corpus
after a red suite: the sweep snapshot proves nothing) and, more importantly,
the unanticipated one, where a branch aborts somewhere its author never
considered. `skipped` is the only benign third state, and only where the
script decided the step does not apply — the jvm probe on an untouched core,
which prints `skipped  neither src/ nor the probe moved since <base>`. The trigger diffs
`src` plus the probe's own two files, because that is what it COMPILES; an earlier
trigger naming only `src/anyparse/query` and `src/anyparse/check` — the packages the
probe LINTS by default — self-skipped on a slice that added a field to a `@:peg`
structure typedef, which is precisely the structure-unification regression this probe
exists to catch.

No branch prints while they run (the driver announces the fork, and that is
the only line): interleaved stdout from four concurrent steps is unusable. Each branch writes its own `.out`/`.err` pair
and the driver replays them, stream by stream, in a fixed order — so the
transcript reads exactly like the old sequential one, with the same
`=== step ===` headers.

One consequence is worth stating, because the transcript hides it. The
`--verify` monolith now runs beside three CPU-heavy branches, up to nine
`node`/`haxe` processes deep. It still buys what it is for — a monolith is one
in-order process, so the ordering insurance survives — but it is no longer
ISOLATED. A suite failure that reproduces under the battery and not under a
bare `tools/suite-shard.sh --verify` is a load artefact, not a slice
regression; re-run the suite alone before believing it.

### The cross-config `--one-pass` arm

The `fmt` branch's first two arms pair each tree with its own
`hxformat.json` — this repo's sources under this repo's config, the fork's
sources under the fork's. Between them they cover two (tree, config) pairs
and no third, and the third is where the writer's convergence tail lives: a
file settles in one rewrite under one config and needs two under another, so
"`--one-pass` is green here" says nothing about any config but ours. Measured
on `a3cc4999`: under a second real-world config, three files of THIS repo
(`check/DuplicateCase.hx`, `check/UnnecessarySwitch.hx`, `macro/Lowering.hx`)
need a second rewrite, and neither the battery, the suite nor the corpus
could see them.

The third arm closes that. It formats `src test tools` under
`tools/xconfig-hxformat.json` — a vendored, fully specified 751-line config
kept in the repo so the arm is hermetic and its baseline stays meaningful
when the tree it came from moves. Vendoring is not a convenience: the source
tree's working copy of that file already differs from its committed one in
four wrap knobs, so reading it live would have made the baseline
non-deterministic. Re-vendor from a commit. The arm runs on a scratch root of
SYMLINKS (`$work/xconfig/src -> $repo/src`, with the vendored config at that
root) rather than by swapping this repo's own `hxformat.json`: config
discovery walks up from each file's directory lexically, so the symlink root
supplies the config, and an interrupted battery cannot leave the repo holding
a foreign config the way a swap could. The symlinks are not themselves a write
barrier — what keeps the tree untouched is that the arm only ever reads.

What it gates is narrow on purpose. `--list` is NOT a gate here — under a
foreign config the whole tree legitimately drifts, 301 of 1529 files at the
time of writing, and that number carries no verdict. The gate is the
`--one-pass` SET, compared for EQUALITY against a baseline written into
`branch_fmt`. Equality rather than a ceiling, because a file leaving the set
is progress in the convergence tail and belongs in the list just as much as a
file joining it.

A set comparison alone would be satisfiable by a PARTIAL run — `check/` and
`macro/` are walked early, so an abort after them leaves exactly the three
baseline paths behind — so the arm additionally requires the run's own
`apq fmt --list:` summary line, which is printed last and is therefore the
completion proof. Both of `fmt`'s summary lines are replayed to stderr rather
than re-derived, so no count is hardcoded here to drift, and every other
stderr line is replayed too: this arm silences the config advisory
(`APQ_NO_CONFIG_WARN=1`, since the vendored config's unimplemented-key list is
pure noise) and would otherwise have no stderr visibility at all.

Cost: 14.7s inside the `fmt` branch, which runs 25s against the `lint`
branch's 131s — the battery's wall time went 173.1s to 173.7s, i.e. nothing.

### Why `compilerOracleServer` is off here

Lint is the battery's largest branch — about 70s of its own, both trees — and
`apqlint.json` sets `"compilerOracleServer": false` on purpose. Measured
2026-08-18 on this project, BEFORE it declared `resolutionRoots` (2026-08-25).
The comparison between the two arms still holds; the absolute seconds and the
finding count do not. `lint src --all` does not contain the `test` root, so that
root is no longer deduped away — it is read and parsed on every such run. See
"The project declares its own sources as `resolutionRoots`" below.

| | lint `src --all` |
|---|---|
| `compilerOracleServer: true` | 57.95 / 58.39 / 57.75 s |
| `compilerOracleServer: false` | 43.45 / 43.79 / 42.83 s |

Three interleaved rounds, non-overlapping — **25 % (14.5 s) of every lint run**,
for findings that are byte-identical: `apq lint-diff` over the two
`--format json` snapshots reports `1407 findings (base 1407) — 0 added /
0 removed`, and that includes all 41 `explicit-local-type` findings, the
oracle-assisted rule.

Two independent reasons, both measured rather than assumed:

- **The warm path is not warm here.** A `haxe --connect` typecheck of
  `test-js.hxml` takes 15.2 s and 16.0 s on consecutive runs against a cold
  16.1 s — no speedup at all. A macro-heavy build re-runs its `@:build` macros
  on the server too, so there is little left for it to restore.
- **Its verdict is rejected every run.** The server re-emits stale null-safety
  diagnostics for two `FileSystem.fullPath` sites the cold compiler accepts
  (`CompilerServer.realPath`, `StdResolver.resolveSymlink` — both already
  bridged through an explicit `Null<String>`, and both still red off the
  cache). By design a warm REJECTION is never believed on its own, so
  `Cli.reportOracleVerdict` re-runs it cold — which is where the second full
  typecheck comes from.

Neither is a defect in `CompilerServer`: the class is written so it can only
change what a verdict COSTS, and here that cost is negative. It stays for
projects whose modules a server can actually keep. To see the warm diagnostics
yourself, read the port out of `$TMPDIR/apq-oracle-*.json` and run
`haxe --connect <port> test-js.hxml --no-output`.

### `--no-oracle` for the edit loop

What remains after that is the cold typecheck itself, and it is PROJECT-WIDE
regardless of how narrow the lint scope is. It is the largest single cost in the
edit loop — the "lint the file I just touched" call, run dozens of times a slice.

```sh
hxq lint <file> --all --no-oracle    # ~5s instead of ~25s
```

Measured 2026-08-25 — this tree's sources at `0f931d2d`, its `apqlint.json`
carrying the `resolutionRoots` the next section explains — on
`src/anyparse/check/ReflectionScan.hx` (11 KB), medians of three interleaved
runs:

| | `--no-oracle` | oracle, cold | oracle, verdict reused |
|---|---|---|---|
| single-file lint | 5.1 s | 24.5 s | 5.5 s |

`haxe test-js.hxml --no-output` on its own is 18.0 s / 17.9 s — 18.0 of the
19.4 s difference, so nearly all of it. The "verdict reused" column is the
`OracleCache` hit and it only survives while NOTHING on the classpath changed —
in an edit loop every run after an edit is the cold column, so read the middle
one as the real cost.

Read the dateline as part of the table. Both halves moved since they were first
written down, for unrelated reasons: the typecheck grew with the tree (16.1 s
when the sections below measured it, 18.0 s here), and the lint half got slower
on PURPOSE on 2026-08-25, when the project declared its own sources as
`resolutionRoots` (1.05 s → 5.1 s — next section). The three figures this
section used to quote — 2.2 s, 18.7 s, 16.1 s — are all stale, and only the
first two are stale for the `resolutionRoots` reason.

Findings are byte-identical (`lint-diff` over `src/anyparse/check`:
`468 findings (base 468) — 0 added / 0 removed`); the flag changes what the run
can PROVE, not what it finds, and it says so on stderr rather than pretending a
verdict. **Do not use it for a gate** — the battery, a pre-commit lint, or
anything whose output is a verdict runs the oracle, because declining a gate can
only ever weaken one.

**With `--fix` the flag means MORE than it does in report mode.** It used to
mean less: the fix path read the configured `compilerOracle` regardless, so
`--fix --no-oracle` still spawned the project-wide typecheck and still reverted
its own wave — reported twice as "the output is byte-identical with and without
the flag", which it was, because the flag reached nothing. It now means what its
name says, in both modes: the compiler is not asked anything, so the safe-pass
revert net is OFF (a fix that breaks the build STAYS on disk, which is the only
way an iteration loop can see the fixer raw), `RiskyFix` rules stay report-only
and `OracleAssisted` rules are inert. The run says so on a dedicated stderr line
of its own (`compiler oracle SKIPPED (--no-oracle)`), which is also why the
report-only tails now read "no compiler oracle for this run" rather than "no
compilerOracle configured" — with the flag the project HAS one. That is strictly
more dangerous than the report-mode flag, and the same rule applies with more
force: never in a gate. The workaround the old behaviour forced — temporarily
deleting `compilerOracle` from the project's own `apqlint.json` — is unnecessary now,
and was always the worse spelling of the same thing: it edits a TRACKED file, so it
outlives the one run that wanted it and shows up in the next `git status`.

### The project declares its own sources as `resolutionRoots`

`apqlint.json` declares `"resolutionRoots": ["src", "test"]` — the project's OWN
tree, not a library. That reads like a no-op (those are the files the gate lints
anyway) and is anything but: the roots are the RESOLUTION scope, and the report
scope is whatever the caller typed on the command line. Five checks refuse a
rewrite when a name could be spelled by a runtime `Reflect` / `Type.resolveClass`
call, and that refusal is only as wide as the strings the run was given. Without
the roots, `hxq lint <one-file>` answers "nothing in this project reflects that
name" from ONE file.

The two-file probe that shows it, run in this tree with the key removed and then
restored (`Alpha.hx` declares `public static final PROBE_TOKEN`, `Beta.hx` calls
`Reflect.field(o, "PROBE_TOKEN")`; `Gamma.hx` / `Delta.hx` are the same pair
under `test/`, spelling `PROBE_TOKEN2`, so the nested config answers for them):

| `--rule inline-constant` on | no `resolutionRoots` | roots declared |
|---|---|---|
| `src/t102probe/Alpha.hx` alone | reports the finding | silent |
| `src/t102probe` (both files) | silent | silent |
| `test/t102probe/Gamma.hx` alone | reports the finding | silent |
| `test/t102probe` (both files) | silent | silent |
| `--fix` on `Alpha.hx` alone | `fixed 1 issue(s)`, writes `inline` | `fixed 0 issue(s)` |

The base column contradicts itself: the one-file answer is the opposite of the
two-file answer over the same code. Changing `Beta.hx`'s literal to a name no
constant carries makes BOTH columns report the finding, which is what pins the
literal — rather than anything incidental about the config — as the
discriminator. `test/unit/LintScopeGateTest` asserts the roots COVER the paths
the gate lints, so the config cannot silently drift back.

What it costs, interleaved base/roots arms, medians of three:

| | no roots | roots | note |
|---|---|---|---|
| `lint ReflectionScan.hx --all --no-oracle` (11 KB) | 1.06 s | 4.85 s | a second round of the same pair read 1.05 / 5.13 |
| `lint InlineConstant.hx --all --no-oracle` (41 KB) | 1.22 s | 5.18 s | |
| `lint RefactorSupport.hx --all --no-oracle` (282 KB) | 2.51 s | 6.16 s | |
| `lint test/unit/LintScopeGateTest.hx --all --no-oracle` | 0.69 s | 4.61 s | the nested config, below |
| `lint <file> --rule prefer-single-quotes --no-oracle` | 0.12 s | 0.10 s | no whole-scope check runs |
| `lint src test --all --no-oracle` | 92.97 s | 92.92 s | 2256 findings, `lint-diff` 0 added / 0 removed |
| `refs` / `fmt --list` / `source` on one file | 0.10–0.13 s | 0.10–0.13 s | not a lint path |

Run-to-run drift on the roots arm is a few per cent of a four-second number, so
read the ratio (~4.5x) rather than the second decimal.

So the tax is a flat ~4 s, flat because it is one thing: reading and parsing the
1490 `.hx` the run is not already reporting on. A `--cpu-prof` of the roots arm
puts ~40 % of its 4.9 s in the generated `parseHx*` atoms, 5.2 % in
`ReflectionScan.collect` and 4.2 % in `unused-public-member`'s `countTokens` —
nothing redundant to remove, and the scope stays LAZY, which is what the
`--rule prefer-single-quotes` row proves.

**What escapes the tax is not "project-wide runs", it is the exact `src test`
spelling.** A library entry is deduped against the REPORT paths by absolute path
before its source is read, so a report scope that already contains both roots
pays nothing — and `lint src test` is the only such spelling this project uses
(`tools/battery.sh`, `branch_lint`). Every narrower scope pays in full, directory
scopes included: `lint src/anyparse/runtime --all --no-oracle` (15 files) is
1.17 s → 5.60 s, and it drops the same class of false positive the single-file
row does — three `unused-public-member` warnings on members the rest of the tree
calls (`ParseReport.recordFail`, `ParseReport.recordUnknownField`,
`Span.offsetOf`). `lint src --all` is in that group too, which is why the two
`compilerOracleServer` / `OracleCache` sections above now carry a
pre-`resolutionRoots` stamp.

The single-file lint also gets more accurate, not just slower — the report-scope
gates were producing false positives at the same time the reflection gates were
producing false permissions. `lint RefactorSupport.hx --all` drops from 64
findings to 15; all 49 are `unused-public-member` on members the rest of the tree
calls. The roots arm's findings came back a strict SUBSET everywhere they were
checked — 64 → 15 on that file, 12 → 9 on `src/anyparse/runtime`, 1 → 0 on
`ReflectionScan.hx`, and 0 added in every arm-to-arm `lint-diff`. The mechanism
guarantees that direction for the five reflection gates and for the whole-scope
occurrence scans (`unused-public-member`, `unused-private`): a wider file set can
only ADD evidence of use, hence only remove findings and add refusals. It is not
a proof for the resolution scope's other consumers — `redundant-this`,
`prefer-index-access`, `map-keys-lookup` — where more resolution could in
principle let a check fire that used to bail; nothing was measured firing that
way, but read the subset property as an observation there rather than a law.

`["src"]` alone would cost 3.27 s instead of 5.13 s (both from the second round),
and was rejected on measurement: with `test/` out of the resolution scope,
`lint src --all` reports 3 `unused-public-member` findings that
`lint src test --all` does not — deletion candidates whose only callers are
tests. Half-closing the hole in exactly the shape being closed is not a saving.

**`test/apqlint.json` USED to have to declare them too, and the reason it no
longer does is the interesting half.** Config discovery once stopped at the FIRST
`apqlint.json` above the linted file and took it WHOLESALE — a nested document
inherited nothing — so the root key governed `src/` and nothing else: with it
declared only there, the `Gamma.hx` / `Delta.hx` pair under `test/` still reported
the finding for `Gamma.hx` alone and refused over both, and a one-file lint under
`test/` ran in 0.69 s because it had no project scope at all. Declaring
`"resolutionRoots": ["../src", "../test"]` in the nested document closed it and
took a one-file lint there to 4.61 s.

It was the fourth key copied down into that document in six weeks
(`compilerOracle`, `compilerOracleServer`, then the two resolution keys), each
added the day somebody noticed another absence, and the root's 38 opt-in RULES
were never noticed at all — a missing rule does not fail, it silently finds
nothing, so 741 files under `test/` were linted by a reduced set from 2026-07-14
to 2026-08-26. `discover` now folds the whole CHAIN of documents, nearest first,
and a nested one overrides only the keys it names (per key at the top level, per
rule inside `rules`, per key inside one rule entry; arrays replace wholesale;
`"inherit": false` ends the chain at that document). The walk also stops at a
PROJECT ROOT — the first ancestor holding `.git` or `haxelib.json`, that
directory's own document included: a nearest-only lookup reaches a stray
`apqlint.json` in `/tmp` or `$HOME` only when the project ships none of its own,
but a CHAIN folds it in regardless, and `compilerOracle` names an hxml
`CompilerOracle.typecheck` EXECUTES. `test/apqlint.json` is back to the four
relaxations it was written as, and `LintScopeGateTest` +
`LintConfigInheritanceTest` assert that both documents still answer the same
resolution scope — now because it is inherited, not because it was copied.

Turning the 38 rules on over `test/` moved the finding count there from 740 to
2102 (`hxq lint --format json --all test --no-oracle`), the bulk of it
`import-order` 620, `redundant-trailing-comma` 388 and `prefer-typed-throw` 223 —
all genuine and all mechanically fixable, none of them a false positive on test
code. Fixing them is not this slice's business; knowing that the number moved
because a rule set arrived, not because the code changed, is.

A second edge that turns out NOT to exist, since a stated mechanism outlived its
code: discovery starts at the DIRECTORY of the path it is given, so the
command-line argument `test` looks like it should resolve the ROOT document (its
directory is the repo root) while `test/unit/Foo.hx` resolves the nested one. It
does not. `Cli.runLint` expands every spec to `.hx` FILES first and resolves a
config per file, so `hxq lint test`, `hxq lint test/unit`, `hxq lint 'test/**/*.hx'`
and `hxq lint src test` all answer `test/apqlint.json` for a file under `test/` —
measured by rule histogram, where `magic-number` / `doc-coverage` /
`string-literal-dup` (disabled only by the nested document) are absent from every
spelling. What IS still spelling-dependent is narrower and worth knowing: the
whole-run project settings — `compilerOracle`, its compile dir, and
`compilerOracleServer` — come from `resolveConfig(paths[0])`, the config of the
FIRST expanded path. Two commands over the same files can therefore differ in
which oracle transport they use if a nested document overrides those keys. With
the chain in place this project's nested document overrides none of them, so
every spelling agrees; a project whose nested document DOES override an oracle
key would still see it.

### The safe pass reverts the file the compiler blames, not the wave

`lint --fix`'s safe pass is applied under a net (`LintFixSafePass`): typecheck
before the writes, write, typecheck again, and a green-then-red transition is
the fixes' own doing. The rollback used to be ALL-OR-NOTHING, and the message

```
apq lint --fix: the safe fixes broke a build that was green — REVERTED N file(s), nothing was written
```

did not name which file did it. On the campaign that motivated this, one bad
edit hid 227 good files, and each bad edit MASKED the next — a queue of defects
could only be found one round-trip at a time, which is how that wave came to be
bisected by hand across six root causes.

The net now ATTRIBUTES before it reverts. A compiler diagnostic carries its
position as `<path>:<line>: `, so the files it blames are one parse away
(`LintFixSafePass.errorFiles`); matched against the files this run wrote by
segment-aligned path suffix (the compiler spells positions relative to the
hxml's directory, the lint knows them by whatever path the caller passed), that
is the implicated set. Those files revert, the oracle is asked again, and a
green answer keeps everything else.

**Which diagnostic shapes the parser claims** — each one has a test, and each
was measured on Haxe 4.3.7 rather than assumed:

- the classic one-line form, `src/A.hx:20: characters 3-8 : Type not found : Foo`;
- `-D message.reporting=pretty`, which Pony's own `tools/build.hxml` sets: the
  header is `<ESC>[30;41m ERROR <ESC>[0m src/A.hx:3: characters 3-31` and the
  block continues over an excerpt and a caret line. The badge means the path is
  NOT the line's first token, which is why the parser anchors on the
  `:<digits>:` shape and strips ANSI CSI sequences instead of reading column 0.
  A project's `lint-oracle.hxml` need not set pretty (Pony's does not), so a
  parser tested only against the oracle looks correct and then fails on the
  project that does;
- warnings in BOTH spellings (` : Warning :` and the pretty `WARNING` badge) are
  skipped — a deprecation notice in an untouched library is not why a build
  failed, and treating it as one would implicate a file this run wrote;
- a colon-digit run with no second colon is a message, not a position
  (`Could not process argument foo:1`), and a candidate with no extension is not
  a file.

Anything the parser does not recognise yields NO implicated file, and that
degrades to the old whole-wave revert **with the reason printed** — never to
"nothing to revert". The three fallback reasons a run can print are
`the compiler blames no file this run wrote`, `every file this run wrote is
implicated`, and `the errors still blamed new files after 4 narrowing round(s)`.

Two shapes the attribution has to respect:

- **A cross-file fix is one unit.** `applyCrossFileRenames` commits a rename's
  whole component together; reverting half of it is worse than reverting all of
  it. Each committed component is recorded, and an implicated file pulls its
  whole component back with it — transitively, since two passes can couple
  overlapping sets.
- **The error can name a file the wave never wrote** — the broken thing is the
  CALLER of an edited declaration. There is nothing to narrow to, so the run
  falls back to the whole-wave revert, says that is what happened, and names the
  files the compiler blamed instead of leaving the reader to guess. When that
  surrender comes AFTER a round has already run, the notice reports the errors
  from the round that gave up, not the ones the wave started with: the round-1
  text would name files the narrowing had already rolled back and hide the one
  that actually blocked it.

Either way the run still exits `EXIT_RUNTIME` and still skips the risky-fix and
oracle-assisted passes — a partially-kept wave is a failure that wrote files,
not a success, and the notice says how many stayed on disk.

Cost is why this attributes rather than bisects: ONE oracle spawn per round, and
a round only happens when the previous round's errors blamed new files —
`LintFixSafePass.NARROW_ROUNDS` (4) caps it, so the granular path costs 1 extra
project-wide typecheck in the common single-culprit case and at most 4. A
per-file bisect over the same wave is O(log n) spawns at best and O(n) when the
failures are scattered, on a typecheck that costs seconds each. Measured on the
853-file Pony tree with one deliberately-broken file, against the pre-change
binary on the same tree:

| | result | wall clock |
|---|---|---|
| all-or-nothing | `REVERTED 192 file(s), nothing was written`, culprit unnamed | 40.5 s |
| attribute-first | `REVERTED 1 of 192 file(s), KEPT the other 191 on disk`, culprit named | 44.9 s |

The 4.4 s difference is accounted for by the one extra project-wide typecheck
the narrowing spent (3.6 s cold on that tree). On a wave that does NOT break the
build the path is not entered at all: the same tree with no broken file gives
`fixed 658 issue(s) in 228 file(s)` on both binaries (the wording the line carried
at the time; the number is the edit count it still reports).

### The `--fix` summary counts EDITS, and is not a verdict about a rule

The line reads

```
apq lint --fix: 4 edit(s) in 1 file(s) over 3 pass(es)
```

and its number is EDIT SPANS applied. A check answers with one span per site it
rewrites, so ONE `naming` finding on a local read three times is four spans, and
a fix whose result exposes a further finding adds that pass's spans on top. It
used to print as `fixed N issue(s)`, which read as a finding count and did not
match the number the reader had just counted in the plain `lint` report —
measured at 4 for 3 findings on a cascading fold, and at 4 for exactly ONE
finding with no cascade anywhere in the run. Only the label changed; every
number in the transcripts quoted below was printed by the run that produced it,
under the older wording.

**The finding total is deliberately not beside it**, and the reason is the same
defect one level up. The edit count sums the safe fixed-point loop AND the risky
and oracle-assisted phases, while the only finding count the run holds — the
`ledger` — is filled by the safe loop alone: `applyLintPass` records it,
`verifyRiskyFixes` never receives it, and with no `compilerOracle` that phase
does not even RUN its checks. Measured on one file with one `prefer-null-coalescing`
finding: `lint` prints `1 info(s)` and `lint --fix --no-oracle` would have printed
`0 finding(s) reported on pass 1` beside its own edit count. Two numbers on one
line measured over two rule sets is exactly the shape this wording was fixed to
stop making, so the line carries one. The finding total belongs to a plain
`lint`, which runs every rule; what each rule DECLINED is the block below.

A finding `lint --fix` reports and does not fix has several different causes,
and the run used to report them all the same way — with silence. Its one
sentence on the subject spelled the ambiguity out instead of resolving it:

```
A reported finding stays unfixed when the check has no autofix, or when its
fix declined here …
```

and it printed **only when `fixedCount == 0`**, so the full-ruleset Pony run —
`fixed 668 issue(s) in 234 file(s)` — said nothing whatever about the 2746
findings it left alone. Three readers took the first branch of that `or`; two
of them filed work on it, and **both rules had a working fix**:

- `import-order` — its four Pony findings are correct refusals by a guard that
  already existed with two regression tests (two imports in the block bind the
  same simple name, which Haxe resolves to the LAST one, so permuting them
  rebinds the name);
- `prefer-typed-throw` — 161 findings, every one degraded by the project-wide
  catch-clause gate (86 blocking clauses on that tree). The reason was on each
  finding's MESSAGE, and a `--fix` run prints no findings at all.

The engine could not tell the two apart either: `Check.fix` answers an empty
array for a rule that has no autofix and for a rule whose gate closed, and
nothing on the interface said which. Two opt-in seams close that, and neither
is required before the output improves:

- **`Check.NoAutofix`** — a marker plus `noAutofixReason()`, for a rule that is
  report-only BY DESIGN. Answers *could this rule ever fix?*
- **`Violation.declineReason`** — an optional field the check writes AT the site
  that declined: in `run` for a whole-scope gate, inside `fix` for a per-site one
  (`fix` receives the caller's own violation objects, so a note set there reaches
  the reporter). Answers *why did it decline HERE* — the question that cost the
  two tasks, and the one a marker interface cannot answer.

**The default carries the honest answer, because the driver measures instead of
guessing.** `computeFileLintEdits` is the one place in the tool that knows what a
check answered for a given set of its own findings, so per rule the run records
first-pass findings reported, findings handed to `fix` that came back with no edit
at all, and edits produced anywhere in the run. That last number needs no
declaration behind it: a rule that produced an edit somewhere HAS an autofix, so
its silence elsewhere is a decline whatever it says about itself.

The block prints after — never appended to — the summary line, which every gate
and doc quotes and which stays one sentence. On the 851-file Pony scope:

```
apq lint --fix: fixed 668 issue(s) in 234 file(s) over 10 pass(es), risky-fix verified: 61 file(s) applied, 0 reverted to report-only, oracle-assisted: 3 file(s) applied, 3 reverted to report-only (compiler rejected)
apq lint --fix: 2746 reported finding(s) in 44 rule(s) got NO edit from their own check:
  magic-number 417: no autofix by design — the finding asks for a NAME, and only the author knows it — an auto-hoisted CONST_7 restates the digit behind an indirection
  explicit-local-type 367: fix DECLINED, 3 distinct reason(s) over 367 finding(s) — and this rule has an oracle-assisted pass besides, counted on the summary line above
      357× no structural rule names the initializer type — the ladder spells a literal, a bare `new` of a PROVABLY non-generic type, a homogeneous array literal, and a call / index / identifier whose declared type this run can read; …
      7× the declaration carries no initializer, and every rule this check has infers the type FROM one
      3× the only type on offer is `Dynamic` / `Any` / `Void`, which an annotation must not spell — …
  naming 231: fix DECLINED, 6 distinct reason(s) over 231 finding(s)
      198× the naming policy in force states a FORMAT this name fails but no mechanical normalizer that could produce a conforming one — a policy adapted from a project `checkstyle.json` carries the regex only, so the check can say the name is wrong and not what it should be
      15× the cross-file rename cannot enumerate who reaches the owner — the scope holds a file the grammar could not parse, or the declaring file carries an `@:allow` granting an unenumerable type, or the owner's simple name is not declared in exactly one file
      7× the method is an `override`, so its name is the SUPERTYPE declaration's — renaming this one alone would leave it overriding nothing
      ... +3 more reason(s), 11 finding(s)
  doc-coverage 223: no autofix by design — a generated doc restates the member name; the sentence a reader needs is the one only its author can write
  unused-import 204 of 205: fix DECLINED, 4 distinct reason(s) over 204 finding(s)
      110× declaration not in lint scope, cannot verify unused (lint with its source module included) — the module is declared in no file this run read, so a SECONDARY top-level type or a bare enum constructor of it could be the reference that keeps the import alive; …
      54× `#if`-guarded, so advisory only: delete it by hand — the verdict holds in every branch, but the canonicaliser normalises the module-level import block ONLY, so deleting a span inside a `#if` region leaves the emptied line behind as a second blank
      25× extension use not tracked — the module's extension methods are known neither to the std probe nor to the report index, so a `.method(` call on any receiver could be resolving through it
      ... +1 more reason(s), 15 finding(s)
  duplicate-code 202: no autofix by design — whether the copies are one idea or a coincidence — and where the shared factor belongs — is a design judgement
  ... +38 more rule(s), 1102 finding(s)
apq lint --fix: 12 rule(s) never enter this ledger — the risky-fix path owns them (avoid-dynamic, dead-null-guard, hoist-embedded-assignment, prefer-case-guard, prefer-enum-abstract, prefer-exists, prefer-inline, prefer-interpolation, prefer-map-type, prefer-null-coalescing, redundant-import, shorten-type-ref); the summary line above is their whole verdict.
apq lint --fix: a rule above that declared NOTHING is not thereby a rule that CANNOT fix — a decline most often needs a WIDER scope than this run (a member rename must see every file that could collide). Re-run over the project root, and see `Check.NoAutofix` / `Violation.declineReason` for what a rule owes its reader here.
```

Six verdicts, ordered by how strong the evidence behind them is:

| the row says | what it means |
|---|---|
| `no autofix by design — <reason>` | the rule implements `NoAutofix` |
| `fix DECLINED — <reason>` | the rule wrote ONE `declineReason`, and it covers every declined finding |
| `fix DECLINED, N distinct reason(s) over M finding(s)` + `<count>× <reason>` lines | the rule declines per ARM, and each arm's share is counted |
| `fix declined here, yet the rule produced N edit(s) elsewhere` | measured; no declaration needed |
| `its fix was called … and returned no edit; the check declares neither` | the honest default |
| `… and this rule has an oracle-assisted pass besides` | appended for an `OracleAssisted` rule, which has a second fix path this ledger never sees |

A `RiskyFix` rule is the one case with no row at all — it is excluded from the
safe loop, so no `fix` of its own is ever called there. Those are named once at
the end rather than shown as silent zeroes; on Pony `avoid-dynamic` alone reports
470 findings, and a "what did not get fixed" block that simply omitted the
largest rule on the tree would invite its own misreading. An `OracleAssisted`
rule is the opposite case and easy to get wrong: unless it is ALSO risky it does
run in the safe loop, so it has a row, and its extra pass is noted on that row.

**The conversion is deliberately partial.** Four report-only rules declare
`NoAutofix` — `magic-number`, `doc-coverage`, `duplicate-code`, `complexity` —
and five declare their decline — `prefer-typed-throw`, `import-order`,
`unused-import`, `explicit-local-type`, `naming`. A measured 20 more report-only
builtins are left on the default arm, which reads strictly better than the
sentence it replaces and never claims what it cannot prove. A rule that always
fixes needs no conversion at all: a rule whose findings all got an edit is not
listed.

#### A rule that declines for several DIFFERENT reasons gets one line per reason

The first three conversions each had one gate, so the ledger recorded the first
`declineReason` it saw and printed it as the rule's whole verdict. The three
biggest undeclared declines on Pony do not: `unused-import` declines through
four arms, `explicit-local-type` three, `naming` six. Naming whichever the file
walk reached first states a quarter of an answer with the confidence of the
whole, so `RuleFixOutcome.reasons` counts them, sorted by share, capped at three
with the tail totalled. Two properties the block keeps:

- a rule with ONE reason covering every declined finding keeps the exact
  single-line `fix DECLINED — <reason>` bytes it always printed;
- a rule that spoke for only SOME of its declines prints
  `<k>× — the check declared no reason for these` rather than letting the
  reasons it gave stand for the rest. The reason totals and `declined` are
  counted over the same findings, at the same call site, so they compare.

#### What the three biggest declines turned out to be

All three are legitimate refusals, and the sentence each owed its reader is now
attached at the gate that closes. Measured on the 851-file Pony scope, and each
share verified against the source rather than counted:

| rule | 100% of its declines |
|---|---|
| `unused-import` 204 | 110 the declaring module is outside the lint scope · 54 the import is `#if`-guarded (the `ac539d13` Info cap) · 25 a `using` whose extension set is unknown · 15 a wildcard whose symbol set is unknown. `fix` deletes exactly the `Warning`s, so every `Info` the check emits IS a decline; each arm's reason OPENS with the same constant its reported message is built from, so the two cannot drift. |
| `explicit-local-type` 367 | 357 no structural rule names the initializer type · 7 no initializer at all · 3 `Dynamic` / `Any` / `Void`. Not a gate closing wrongly: on a synthetic file the ladder annotates 5 of 7 ordinary shapes, and Pony's 367 are the residue previous `--fix` passes left, and not one of them is a bare literal — 76 generic-or-unindexed `new`, 18 array literals (empty or comprehension), 138 calls whose return type this scope cannot read, and 125 other unpinnable initializers. |
| `naming` 231 | 198 the policy states a FORMAT and carries no `normalize` · 15 an unprovable cross-file hierarchy · 7 `override` · 5 not a member (a type / enum value) · 3 grammar-marked rename-unsafe · 3 an unconfined private member. |

`naming`'s dominant cause is worth its own queue item, because it is a
capability gap rather than a refusal. `HaxeNamingSupport.policyFor` prefers a
discovered `checkstyle.json`, and `CheckstyleConfigLoader.load` maps each naming
check's `format` regex onto a rule and attaches **no `normalize`** — so
`correctedName` has nothing to return and every finding on such a project
declines. One-variable matrix, same file and the SAME regex
(`MethodName` `^[a-z][a-zA-Z0-9_]*$`), only the policy's origin differing:

```
checkstyle.json present  →  fixed 0 issue(s) in 0 file(s)   (naming 1: fix DECLINED — …no mechanical normalizer…)
checkstyle.json absent   →  fixed 2 issue(s) in 1 file(s)   (declaration and call site both renamed)
```

The fix is not "invent a normalizer per regex": `correctedName` already verifies
its candidate against the rule's OWN format, so attaching the built-in
normalizer for the category would be self-checking. Wiring one in as a
three-line mutation flips the first arm immediately, which is what
`LintFixFixedPointCliTest.testCheckstyleDerivedPolicyDeclinesTheRenameItsOwnFormatDemands`
pins — landing the widening means retiring that assertion on purpose, and
measuring what the rename set gains on a real tree. Note also that the loader
DROPS each check's `tokens` (`MemberName` is configured twice on Pony, once for
`CLASS/PUBLIC/PRIVATE/TYPEDEF` and once for `ENUM`, and only the first rule can
ever apply) — the same widening has to decide what `tokens` means first.

### The oracle answers for what it COMPILED, not for what you linted

`haxe <compilerOracle> --no-output` exiting 0 is the strongest gate this project
has, and it is authoritative only over the files that compile ran through. That
set is NOT the lint scope, and on a real multi-target tree the gap is large and
completely silent.

Measured on Pony. Its `lint-oracle.hxml` has two arms, neko and nodejs, and each
ends in `--macro include('pony', true, [ … ])` — whose third argument is an
IGNORE list, 47 entries long. `pony.unity3d` and `pony.pixi` are both on it, on
both arms, so no configuration in that repo typechecks either package. Nor could
one: `haxe -cp src --no-output -neko … --macro include('pony.unity3d', true)`
stops at

    src/pony/unity3d/ui/TextureButton.hx:3: characters 8-22 :
    You cannot access the cs package while targeting neko (for cs.NativeArray)

and the externs those packages need — `unityhx` / `hugs` for `pony.unity3d`,
`pixijs` for `pony.pixi` — are not installed haxelibs at all. The ignore list is
not laziness; it is the only way an hxml that types the rest of the library can
exist.

The size of the hole, on the campaign's own full-ruleset `--fix` run over the
851-file Pony lint scope: 234 files written, **32 of them (13.7 %) under
`pony.unity3d.*` / `pony.pixi.*`** — a write set the green oracle says nothing
about. The run's own summary is worded in exactly those terms and it is easy to
over-read: `risky-fix verified: 61 file(s) applied` and `oracle-assisted: 3
file(s) applied, 3 reverted to report-only (compiler rejected)` count the files
the compiler could SEE. Nothing there is false; it simply does not extend to a
subtree the compile never entered.

**The risky-fix path now MEASURES that set instead of assuming it.**
`anyparse.check.OracleCoverage` runs one `haxe -v --each <hxml> --no-output` from
the oracle's own directory and reads its `Parsed <path>` lines. That is the
compiled set, named by the compiler itself — across `--next` arms, through
include chains, through a `--macro include(…)` ignore list and through whatever
a future hxml invents, none of which the engine has to model. `--each` is what
makes it whole: without it exactly one arm answers — on Pony's two-arm hxml a
leading `-v` reported 175 distinct `src` files and a trailing one 196 (194 and
215 raw `Parsed` lines; a module is parsed again for the macro context), and
which arm you get depends on where the flag sits rather than on what the oracle
compiles. `FixVerifier` then DECLINES a risky edit set whose file falls outside
the set — before writing anything — and the summary says which:

    apq lint --fix: fixed 20 issue(s) in 11 file(s) over 2 pass(es), risky-fix verified: 11 file(s) applied, 0 reverted to report-only, 28 file(s) DECLINED unverifiable (40 edit(s) the oracle does not typecheck)
    apq lint --fix: risky-fix DECLINED src/pony/net/http/WebServer.hx (prefer-null-coalescing): the compiler oracle does not compile this file (its hxml reads 915 source file(s), this one not among them) — 1 edit(s) left report-only

(915 is every source the compile READS — std and haxelibs included. The
project's own share of it is 196, which is the number that matters against the
679 files under `src`.)

Measured on Pony `b6b94e37`, `--rule prefer-null-coalescing` over the whole
`src`, same tree both arms: the base binary wrote 39 files and reported all 39
as `risky-fix verified`; the gated one writes 11. The 28 files it stops writing
are EXACTLY the 28 the oracle never compiles, and the difference in the other
direction is 0 — the gate does not buy its honesty by refusing everything. It
is also 2.9x faster (141.0 s -> 48.0 s), because those 28 whole-project
typechecks are no longer spawned: here the honest answer is the cheap one. The
probe costs one compile (17.45 s against 17.37 s for the plain oracle typecheck
of this project — `-v` is a print flag, not extra work) and is taken lazily,
only once some risky check actually has a candidate. It also needs a spawn
buffer far past Node's 1 MiB default: 815 KB of `-v` output for Pony's two arms,
2.1 MB for this project's own `test-js.hxml`. An overflow costs the whole risky
phase, not a wrong decline — node reports it as a spawn error with a null status,
which the probe reads as an unknown compiled set.

The PREMISE is measured too, in `OracleCoverageTest`, because everything above
rests on it: the identical `var x:Int = "not an int"` leaves
`haxe lint-oracle.hxml --no-output` at exit 0 from `src/pony/unity3d/UTools.hx`
and fails it from `src/pony/Byte.hx`. One variable, opposite verdicts.

**The same hole exists one level down, inside a compiled file, and is measured
the same way.** A `#if` branch the arm's defines exclude is skipped at lex time,
so the file still earns its `Parsed` line while that branch is typechecked by
nothing: `final _planted: Int = 'not an int';` in the native-sys `#elseif sys`
branch of `HaxeSpawn.run` leaves `haxe test-js.hxml --no-output` at exit 0, and
the same line in the `#if nodejs` branch above it fails with
`String should be Int` — while `covers` answers TRUE for the file either way and
`uncovered` declines only the second, naming the branch. So the probe splits its transcript into ARMS — one per
`Defines:` line, each owning the files parsed after it and the defines it
declares (that line's names plus the `--macro define(...)` calls that follow,
which is the only way `nodejs` is visible at all) — and `OracleCoverage.uncovered`
asks `CondRegionLiveness` whether the edit's own span is in a branch some
compiling arm proves live. Arms are never unioned: `#if (a && b)` with an `a`
from one arm and a `b` from another is live under neither.

The define list is POSITIVE-ONLY, and that asymmetry is the whole soundness
argument: a listed flag is proved, an unlisted one is UNKNOWN and never false,
so `#if !whatever` can never claim a region no compile produced and every doubt
costs a decline instead of a permission.

That makes the honest number much lower than the file answer implied, which is
the point of measuring it. Conditional branch openings in files the oracle DOES
compile — every one of them previously counted as covered:

| tree | branch openings | provably live |
|---|---|---|
| anyparse (`test-js.hxml`, 1522 of 1525 scope files compiled) | 1267 | 483 |
| Pony (`lint-oracle.hxml`, 196 of 868 scope files compiled) | 1056 | 37 |

Pony's figure is dominated by 399 `#if (haxe_ver >= x)` comparisons and the 447
`#else` branches whose openers those comparisons leave unknown. Deciding them
needs a second implementation of the compiler's own version comparison, and a
wrong one claims coverage that does not exist — so they stay unknown.

The `--each` flag ORDER is part of the claim. `--each` pushes what precedes it
into every arm, so `-v --no-output --each <hxml>` suppresses output in arms the
oracle's own `haxe <hxml> --no-output` lets EMIT (that flag joins the last arm
only). Measured on a two-arm hxml whose first arm names a `-js` output: the
oracle emits that file, the old probe spelling emitted nothing. The probe has to
run the compile it is describing, so `--no-output` sits after the hxml.

The limits, stated in full because a gate that overstates its own reach is the
thing this section is about.

- **Coverage the probe cannot establish is not coverage.** A `haxe -v` that will
  not run, exits non-zero, or names no parsed file stops the whole risky phase
  and puts its reason on the summary line — the same outcome as a project with
  no `compilerOracle` key at all, which is the honest reading of an oracle whose
  reach is unknown.
- **A define the probe cannot SEE costs a decline.** An arm's define list is the
  compiler's `Defines:` line plus the `--macro define(...)` calls the same
  transcript reports; a define set from inside a BUILD macro appears in neither,
  and a condition comparing a define's VALUE (`haxe_ver >= 4.2`) has nothing to
  compare against. Both leave the region unknown and the edit report-only. Never
  the other way round: absence is never read as "not defined", so no amount of
  nesting can turn a flag the probe missed into a coverage claim.
- **The set is a snapshot**, probed once per run. A fix that removes the last
  reference to a module can drop it out of the compiled set afterwards; the
  common direction (a fix that adds a reference) only leaves the snapshot
  conservative.
- **The oracle-assisted path is deliberately NOT gated this way.** It annotates
  files the compile never enters on purpose (the display server answers for
  them, and does so correctly), its safety resting on the annotator's own
  abstentions instead — `ExplicitLocalTypeOracleAbstainTest` is that scenario end
  to end, over a file outside the hxml's `-cp`. Its `oracle-assisted: N file(s)
  applied, M reverted` line therefore still counts only what the compiler could
  see, exactly as described above.

**A second, sharper instance: the deleted code COMPILED.** The oracle's blind
spot above is a subtree it never entered. This one is inside the subtree it did
enter, and the exit code is still 0 — because the rewrite is a behaviour change
the type system has no opinion about. `unnecessary-null-check` read
`public var esVersion: Int = null;` in `pony`'s `create.section.Build`, called
the operand non-null on the strength of the written `Int`, and `--fix` deleted
`if (esVersion != null)` from around the line that emits the `js-es$esVersion`
compiler flag. The result typechecks on every target the oracle builds, so the
run reported green; the emitted hxml simply started carrying `js-esnull`
unconditionally. The user found it in a code review, not in a build.

The rule this adds to the one above: **the oracle can only ever confirm that a
fix still compiles, never that it still means the same thing.** A rule whose
edit DELETES a guard has to prove the guard is dead from the source itself,
because the only gate downstream of it agrees with any well-typed program. Two
proofs of that kind carry the fix that closed this defect, and both are local
syntax rather than a project setting: a declaration whose own initialiser is the
literal `null` is nullable whatever its written type says, and a comparison
against `null` on a value-typed operand does not COMPILE on a static target
(`On static platforms, null can't be used as basic type Int`), so its presence
proves the file's target is one where `Int` is nullable. Measured over 18 882
files (Pony, the Haxe std, `~/dev/haxelib`), the value-type arm those two gates
withdrew produced 115 findings; 14 distinct sites read, 13 were load-bearing
dynamic-target guards — five of them inside an explicit `#if neko` /
`#if js` / `#if (js && html5)` region.

Two consequences worth carrying to any project, not just this one:

- **Read the oracle's own exclusion list before trusting its exit code.** Any
  tree with per-target packages — flash-only, cpp-only, an engine binding — has
  the same shape, and the excluded packages are usually the ones with the most
  foreign coupling, which is to say the ones where a bad rewrite is least likely
  to be a compile error. `OracleCoverage` now reads that list for you on the
  risky-fix path, and by asking the compiler rather than by parsing the hxml —
  but it is one consumer of the exit code, not all of them, so the reflex still
  belongs to anyone quoting a green oracle at a file.
- **A rule whose failure mode inside such a subtree is SILENT has to gate
  itself.** A rewrite the compiler would reject is caught eventually, in the
  worst case by the next real build; a rewrite that compiles and changes what
  the emitted code does is caught by nothing. `inline-constant`'s
  native-interop gate (`RefShape.nativeInteropDeclMetaName`, Haxe
  `@:nativeGen`) is the worked example: `inline` bakes a constant into every
  read site while leaving the field a foreign consumer still writes, and the
  types that consumer holds are precisely the ones no oracle here compiles. The
  same file also records the measurement that scoped the gate to `inline` alone
  — `var` -> `final` and `var` -> `var(default, null)` emit byte-identical C#
  on a `@:nativeGen` class, so the neighbouring field rules took no gate.

### The verdict cache: one tree, one typecheck

What the gates cannot decline they can at least stop paying twice. Before it
compiles anything, `Cli.reportOracleVerdict` derives a CONTENT fingerprint of
the whole compile input and reuses the recorded verdict only while that
fingerprint still matches (`anyparse.check.OracleCache`). Interleaved, three
rounds, `lint src --all` — again pre-`resolutionRoots` (2026-08-25), so the
−37 % holds while the absolute seconds and the 699-file finding line do not:

| | run |
|---|---|
| cold, no record | 40.7 s (base binary: 40.7 / 39.5 / 40.9 s) |
| unchanged tree | 25.2 / 25.4 s |

**−37 %**, and the cold arm is not measurably slower than the base — deriving
the fingerprint costs ~0.28 s against a 16.1 s typecheck (18.0 s when
re-measured 2026-08-25, so the ratio has only improved). Findings are
byte-identical between the two arms (`0 errors, 54 warnings, 1356 infos in 699
files`, same stdout to the byte).

The key covers the compiler's own `Defines:` line (Haxe version plus every
resolved library version), every hxml in the include chain, and every `.hx`
under every classpath directory — where the directory list is the hxml's `-cp`
roots, the compile directory itself (the compiler carries it implicitly, as the
empty entry of its `Classpath:` line), and the entries the COMPILER names for
the hxml's `-lib` set. That last part is what closes the haxelib hole: the
library directories are never guessed, so their sources, their transitive
dependencies, `extraLibs` and the Haxe std all enter the key by content. One
`haxe -v <-lib …> --interp Std` spawn buys it, measured at 0.12 s.

**Content only — never mtime.** That is not a style preference: the compilation
server's mtime rule at one-second granularity gave 9 wrong verdicts in 10
iterations here, including a broken build reported as clean (see § "Why
`compilerOracleServer` is off here" and the `CompilerServer` class doc). A
content hash has no such failure mode — break a compiled file in the same second
you read it and the very next `lint` reports `compiler oracle REJECTED` with the
compiler's own error text.

`--fix` never consults it, by construction: `FixVerifier` writes files and then
asks whether the project still compiles, so it calls `CompilerOracle` directly.
`APQ_NO_ORACLE_CACHE` declines the cache process-wide — a weakening-only switch,
since declining a cache costs time and cannot change a verdict. The residual
holes it does NOT cover (non-`.hx` compile-time inputs, a classpath a `--macro`
adds while typing, environment-supplied defines) are listed in the class doc;
they are why this is a report-mode fast path and nothing more.

### `apq oracle` — the battery's hand-off

The battery used to typecheck the same hxml twice: its `build` step compiles
`test-js.hxml`, and its `lint` step then asked the compiler the same question a
minute later. The oracle now LEADS the lint branch, so it overlaps the
suite/corpus/fmt/jvm branches, and `lint` — the very next step in the same
branch — hits the cache. It sits there rather than in the driver as a
background job because a branch subshell cannot `wait` on a pid that is not
its own child; the wall-clock moment it starts is the same either way.

```sh
apq oracle src        # one COLD typecheck, verdict recorded under the fingerprint
```

It cannot lie. There is no flag that asserts "this already typechecked" — the
compiler always runs, and only an observed verdict is stored, so a misuse
(running it on a tree that does not build) records a rejection, which is the
truth. A tree that moves between the two steps simply misses the fingerprint and
is compiled again. Its exit status is not a battery gate: the `lint` step reads
the same verdict and fails there, with the compiler's error text.

One property worth knowing: the store is a single slot per (hxml, cwd) pair, so
alternating between two tree states misses every time. That is the cost side of
never keeping a verdict that could be wrong.

The baseline is four plain files per commit in `$ANYPARSE_BLAST_CACHE`
(`~/anyparse-blast-cache` by default) — two lint snapshots, the corpus sweep
snapshot, and a two-integer suite line. Keeping them outside the repo is
deliberate: they are machine-local measurement state, and a committed one would
conflict on every slice. `--snapshot` writes them, and only on green, so a red
or half-run tree cannot move the baseline under the next comparison.

**A run fails on** a build error, a red or count-diverged suite, a non-empty
`fmt --list`, a `fmt --verify` divergence, a `--jvm` probe that stops compiling,
more corpus failures than the base, or any blast-radius change not explicitly
waved through with `--allow-blast`. **It only reports** suite totals growing, corpus totals
improving, and the lint findings a slice's own new files bring with them —
those still print through `lint-diff`, and passing `--allow-blast` after
reading them is the intended way to accept a slice that adds code.

### `fmt --verify` — the invariant the round trip cannot check

A correct formatter changes only WHITESPACE. `apq fmt --verify <paths>` formats
each file in memory, strips every whitespace character from the input and from
the output, and reports the first place the two disagree — file, source line, and
a window of each side. It never writes.

This catches a class the writer's own round-trip gate is blind to by
construction. That gate asks "does the output re-parse to the same tree", so a
writer defect whose output THIS parser still accepts passes it: `apq
self-status`, `fmt --list` and `lint` all stayed green on a tree where
`@:forward(a, #if f b, #end, c)` no longer compiled under `haxe`. One `--verify`
pass over an 846-file tree found four such sites.

Read the count, not just the exit status. `--verify` can only speak about files
the writer would actually REWRITE — an already-canonical tree gives it a
denominator of zero and reports a clean audit for the wrong reason, which is why
the battery points it at the fork tree rather than at `src test tools`. The line
it prints carries all three numbers: divergences, reformatted files, and files it
could not format at all.

Some policies change tokens on purpose — a trailing comma, braces around a single
statement, an optional semicolon — and those are reported too. The rule stays
"whitespace only" rather than encoding a policy list, because the defect it exists
to surface is by definition one nobody has classified yet.

### A comment interior and a string literal are outside every gate

`fmt --verify` bounds the WRITER. Nothing bounds an EDIT OP that splices text
INTO a region the writer re-emits byte for byte — a block comment's interior, a
string or a regex literal. There the indentation IS the content, and every gate
this project has reads past it: the writer re-emits the region verbatim, so `fmt
--list` calls the file canonical; no lint rule reads a doc comment's ` * `
continuation prefix; `self-status` only asks whether the file parses; and the
compiler oracle type-checks a file whose comments it never looks at. A patch that
lands one space too deep inside a doc block — or that changes the VALUE of a
multi-line string by shifting its lines — produces a green run in every column.

`hxq patch`'s line-wise arm did exactly that until 2026-08-22. It spliced at the
matched line's first NON-whitespace byte, so the source's own indentation stayed
standing and the replacement's was added on top of it. Code hid the defect (the
writer re-indents code, so it never reached the file); comments and strings did
not. It was found by reading `git diff` by eye, which is the only reader it had.

The fix went where such a fix belongs: a postcondition INSIDE the op
(`Patch.verbatimSpliceIntact`), not a new lint rule. A rule over doc-comment
continuation prefixes would have to guess intent — a comment interior is
legitimately free-form (ASCII art, indented code samples, nested lists) — and it
could only ever speak after the damage was committed. The postcondition is exact
instead: the op knows which bytes it synthesised and which region they landed in,
so it compares the spliced block's RELATIVE per-line indentation across the writer
round trip and refuses when it moved unevenly. A uniform shift is the writer
re-basing the block onto its site, which is legal; a first-line-only shift is the
defect, and no uniform shift can explain it.

The general shape, worth asking of every new mutation op whose payload can reach a
comment or a literal: **when an op writes into a region the writer COPIES rather
than re-derives, the op is the last thing that can check it.**

Every format-aware step is delegated to the CLI this project already builds —
`apq lint-diff` for the blast radius, `apq sweep` for the corpus, `apq
test-summary` and `apq shard-plan` through `suite-shard.sh` — rather than
reimplemented in shell.
That is why the script needs neither `jq` nor `python`: anything that has to
*understand* a file is a subcommand, testable in the suite and dogfooding our
own JSON parser.

`apq lint-diff --old A.json --new B.json [--root <prefix>] [--label <name>]`
compares two `apq lint --format json` reports as multisets of
`(file, rule, severity, message)`. Line, column and address are deliberately not
part of the key — they move under any edit above them, so keying on them would
report half the tree after a one-line insertion. Two normalizations come from
measured false positives rather than anticipation.

`--root` strips a path prefix from whichever side carries it (a relative and an
absolute snapshot of one tree otherwise disagreed on 1812 of 2954 findings), and
it reaches the paths a message quotes as well as the `file` field, because
`duplicate-code` names its partner block by path.

The second is the same hazard one field over: a rule that writes a source
MEASUREMENT into its own prose re-keys on an edit that changed no finding.
`oversized-type` quotes the type's line extent, and one writer slice therefore
printed eight moves — `WrapList` 4184 against 4194, plus `WriterLowering`, `Cli`
and `SymbolIndex` — with total findings 2256 against a base of 2256. Every writer
slice in that campaign waived the blast gate for this reason alone, and a gate
waived by reflex has stopped being a gate.

The fix is a declaration a check makes about ITSELF (`Check.VolatileMessage`,
one method returning the message with its volatile parts masked), collected by
`Linter.messageIdentities` and handed to `lint-diff`. `lint-diff` holds no list
of rules: a new rule that quotes a coordinate joins by writing that method, and
the consumer never changes. The masks are ANCHORED on a literal fragment the
check itself wrote (`MessageMask.maskAfter` / `maskBefore`), so exactly one
number leaves the key — `oversized-type`'s line extent goes, its member count
stays, because that one moves only when a member is written. The blanket
digit mask this replaced could not express that split at all, and on
`duplicate-code` it also ate the statement count and any digit in the partner
filename: 57% (anyparse) and 78% (tm) of that rule's findings shared a key with a
sibling, where a substitution was invisible. The message keeps every number
either way — identity and prose come apart, the numbers do not leave the report.

Both snapshots are normalized at COMPARE time, so a baseline cached before a
declaration existed still compares clean against a run made after it: adding a
`VolatileMessage` needs no re-snapshot.

Its two non-zero exits are different on purpose, and the battery treats them
differently: **1** means the comparison ran and the snapshots disagree, which
`--allow-blast` waives; **2** means it could not run at all — a snapshot
missing, unreadable or malformed, or the flags wrong — and that fails the
battery whatever flags you pass. Waiving expected movement must never waive a
gate that never executed.

The battery prints where its own time went, and the rows marked `*` OVERLAP:
they are the four branches' steps, running at once, and they sum to far more
than the elapsed time. The table therefore closes on two different numbers —
`concurrent span`, the wall clock of the parallel region, and `TOTAL (wall)`,
the real end-to-end elapsed time — and neither is a measurement of the code.

Those numbers measure the battery. A benchmark arm runs ALONE and
SEQUENTIALLY on an otherwise idle machine; a battery row runs beside three
other branches, up to nine `node`/`haxe` processes deep, and moves by tens of
percent with ambient load. Never quote one as a benchmark result — see "The
profiling harness" above for how a real arm is measured.

### `--list` and `--write` disagreed across runs, and only the tool could see it

`apq fmt --list` is a gate this campaign runs after every slice. It and `--write`
decide from the SAME comparison — `writeRoundTrip(source) == source` — so within
one run they cannot disagree. Across runs they did: `--write` rewrote a file and
the very next `--list` reported that file again.

The reason is that the writer's output is not always its own fixed point. A wrap
decision that reads the SOURCE line layout gets a different answer once the writer
has rewritten that layout. Measured 2026-08-22 with
`wrapping.objectLiteral.defaultWrap` set to `fillLineWithLeadingBreak`: one `fmt
--write` over the Pony tree rewrote 173 of 854 files and the next `fmt --list`
still reported 163 of them; a second `--write` settled every one. The mechanism is
one early return — a source-MULTILINE object literal is force-one-per-lined BEFORE
the wrap cascade is consulted, and the leading break the cascade emits on pass 1
is exactly what makes the literal multiline. It is faithful to the fork, which
reproduces the same two-pass convergence on the same file under the same config;
what was NOT faithful is a `--write` whose result its own `--list` rejects.

Five other wrap knobs share the shape on the same corpus — `anonType` (33 files),
`callParameter` (2), `arrayWrap`, `anonFunctionSignature`, `typeParameter` (one
each) — so this is a bug SHAPE, not a bug: any list whose layout can be decided
from source newlines instead of from the cascade.

`fmt` therefore writes the FIXED POINT (`anyparse.query.FormatFixedPoint`), not
one round trip — and neither swallows nor tolerates what it works around:

- a file that needed more than one rewrite is REPORTED on stderr with the count.
  A silent loop would turn a writer defect into a permanent tax nobody can see;
- a file that never settles is a FAILURE in every mode and its bytes are left
  alone. Churning a file forever is worse than declining to format it, and
  `--list` has to fail on exactly the files `--write` cannot fix — otherwise the
  two disagree again at the other end.

It costs nothing where it does not apply: a canonical file answers `source` on the
first round trip and nothing else runs, so a green tree — the gate's normal case —
pays zero extra round trips. Measured 0 files needing a second rewrite over `src`,
`test`, and the whole Pony tree under every config this project ships.

The general shape is the sister of "A comment interior and a string literal are
outside every gate": **a gate that reads the same component the defect lives in
cannot see the defect — make the component check its own postcondition.**

### Every `fmt` summary that reports a count names BOTH quantities

Three real lines, each from the run named beside it — the two `fmt` runs are the
Pony tree under its own config, the `--verify` one is the fork tree the battery
audits:

```
apq fmt: rewrote 23 of 870 file(s), 3 failed
apq fmt --list: 0 of 1510 file(s) would be rewritten          # src test tools
apq fmt --verify: 0 of 6 reformatted file(s) changed more than whitespace (36 scanned, 0 could not be formatted)
```

The `--write` line used to print `formatted N file(s)` — the change count with
no denominator — and `--list` printed nothing at all unless a file failed. Both
readings cost a measurement arm in this campaign. `formatted 0 file(s), 3
failed` over a tree of 870 read as "the run was inert", and nothing on the line
separated that reading from the true one; `--list`'s silence made a run that
scanned a whole project and a run that matched three files look identical. The
fourth mode still reports no count: `fmt <one-file>` with no flags writes the
formatted source to stdout, gofmt-style, and the output IS the answer.

And the denominator alone was not enough, because one word still spoke for two
causes. A file the run could not answer FOR (it did not parse, its re-emission
would drop a comment) and a file the HOST refused to write are different facts,
and the second one was reported as the first:

```
apq fmt: rewrote 0 of 3 file(s), 1 failed, 2 could not be written
```

That cost a fourth measurement arm. A `cp -R` copy of the Haxe stdlib kept its
`444` mode bits, so `fmt --write` wrote NOTHING and said `rewrote 0 of 2625
file(s), 1692 failed` — read as a source-side verdict, which let a before/after
comparison be accepted while both of its sides were the same untouched copy. The
exit status was never the half that lied: a write failure rides in `failed` and
has always exited non-zero, and it stays that way — a `--write` run that could
write nothing did not leave the tree canonical. Only `--write` can produce an
unwritable file, so the clause is absent by construction in every other mode.

The counts themselves were re-measured over the Pony tree with the engine at
`0c2dbdfa`, in the context the reports came from — 870 files reached through
per-file config discovery, 3 of them unparseable — against a `cmp` of
before/after copies: 81 of 81, 0 of 0, and 23 of 23. Neither the over-report nor
the under-report reproduces; what did was the missing denominator, and one
direction nobody had filed: a write that THROWS (a read-only file) took the
whole run down with an uncaught host error, so a run that had already rewritten
part of the tree printed no summary at all. `formatOneFile` now catches it,
names the file, and counts it apart from a parse failure under its own word —
the read side had been caught from the start, and still shares `failed` with the
parse failures. The other 31 `writeFile` call sites in `Cli` still share the
hazard.

`unit.ApqCountSummaryCliTest` pins all of it against the BYTES, never against
`fmt --list`: the fixture directory is snapshotted before the run and re-read
after, and the count line must equal the number of files whose bytes moved. The
seam that makes it possible is `Cli.fmtRun`, which returns the summary instead
of printing it — `Sys.stderr()` on hxnodejs is a raw fd, so a line that only
ever reaches fd 2 can be asserted by no in-process test.
