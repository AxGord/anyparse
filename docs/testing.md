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
  var result = JsonParser.parse('{"x":1}');
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
    var written = JsonWriter.write(ast);
    var reparsed = JsonParser.parse(written);
    Assert.isTrue(JValueTools.equals(ast, reparsed), 'round-trip failed: ast=$ast, written=$written');
  }
}
```

**Catches**: bugs nobody thought of. The random generator produces cases like "a string with a backslash immediately before a close quote inside an array that is itself the value of a key with special characters" — cases that are incredibly unlikely to be in any hand-written test.

**Does not catch**: bugs on input the writer would never produce. If the parser accepts malformed input that the writer never generates, the round-trip test cannot see it. Layer 1 and Layer 2 cover that gap.

**Seeded generator**: use a seeded PRNG so that failures are reproducible. A failure on seed 42 at iteration 137 should always fail the same way when rerun. No wall-clock-seeded randomness in tests.

**Every grammar gets one**. When a new grammar is added, a round-trip test is part of the pull request. No grammar is "done" until it has passing round-trip tests.

Already in Phase 0: `test/unit/JsonRoundTripTest.hx` with 30 curated cases plus 200 randomly generated ones.

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
- `bench-neko.hxml` — neko baseline
- `bench-js.hxml` — Node.js
- `bench-hxcpp.hxml` — native

Each benchmark outputs structured JSON with throughput, timing breakdowns, and memory usage. CI collects these and compares against a baseline.

**Benchmarks are not in Phase 1.** They matter starting from Phase 2 when a macro-generated parser has a baseline to measure against. Phase 3 (Haxe formatter) and Phase 4 (AS3 converter) are where benchmarks become critical.

## Layer 6: End-to-end integration tests

Full pipeline tests on real-world data. Take a substantial input (the user's ax3 corpus, a large Haxe project, a corpus of JSON API responses), run it through the full pipeline (parse → transform → write), and compare against an expected output.

**Catches**: interactions between multiple parts of the platform that unit tests miss. Grammars, transforms, writers, and formatters interact in ways that are impossible to cover fully with unit tests.

**Added at Phase 4 onwards**, specifically for the AS3→Haxe conversion replacing ax3. The user's ~2000-file corpus is the canonical integration test: the new tool must produce equivalent Haxe output on every file, ideally faster than ax3 and without JVM.

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

## Guidelines for new tests

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
haxe test.hxml          # neko, fastest compile+run (default)
haxe test-js.hxml       # js/node, for cross-platform validation
haxe test-interp.hxml   # Haxe macro interpreter, no compile step
```

When Phase 2 adds hxcpp as a target:

```sh
haxe test-hxcpp.hxml    # native binary, slowest compile but closest to production
```

All targets must pass before a commit. Cross-target failures usually indicate a platform-specific issue that should be fixed, not ignored.
