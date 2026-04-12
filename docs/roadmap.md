# Roadmap

Phased plan from initial scaffold to production-ready platform. Each phase has a concrete goal, deliverables, a success criterion, and an explicit exit condition. A phase is not "done" until the exit condition is met and the project is green.

Sessions should align with phase boundaries — start a new Claude Code session at each phase transition.

## Phase 0: Walking skeleton — DONE

**Goal**: validate that the basic end-to-end shape of the project compiles, runs, and tests across multiple Haxe targets.

**Deliverables**:
- Project scaffolding: `haxelib.json`, `LICENSE` (MIT), `README.md`, `.gitignore`.
- Three build configs: `test.hxml` (neko), `test-js.hxml` (js/node), `test-interp.hxml` (Haxe interpreter).
- Core Doc IR (`anyparse.core.Doc`, `anyparse.core.D`, `anyparse.core.Renderer`) — the Wadler-style pretty-printer foundation.
- Reference JSON implementation written by hand: `JValue` enum, `JEntry` typedef, `JsonParser`, `JsonWriter`, `JValueTools.equals`.
- Test suite on utest: unit tests for Doc/Renderer, JsonParser, JsonWriter, plus round-trip tests with a seeded random generator.

**Exit condition**: 288 tests pass on neko, js, and interp targets. Walking skeleton is committable.

## Phase 1: Macro foundation — DONE (2026-04-11)

**Goal**: stabilize the compile-time and runtime API surface that the macro will plug into, without writing the macro itself. This is design work in code form — we are writing interfaces, type declarations, and stub implementations to make sure the macro has a well-defined target.

**Deliverables**:
1. ✅ **CoreIR** (`anyparse.core.CoreIR`) as a Haxe enum with all primitives: Empty, Seq, Alt, Star, Opt, Ref, Lit, Re, And, Not, Capture, Backref, Bind, ExprRef, Build, plus binary primitives Bin/Count/Switch/Decode, plus Host as escape hatch. Each constructor documented with its semantics and lowering intent. Wrapped in `#if macro`.
2. ✅ **ShapeTree** (`anyparse.core.ShapeTree`) as the neutral intermediate between `haxe.macro.Type` analysis and CoreIR. `ShapeKind` enum plus `ShapeNode` class with `children` and namespaced `annotations` map. Wrapped in `#if macro`.
3. ✅ **Strategy interface** (`anyparse.core.Strategy`) declaring the plugin contract: `ownedMeta`, `runsAfter`, `runsBefore`, `appliesTo`, `annotate`, `lower`, `runtimeContribution`. Wrapped in `#if macro`.
4. ✅ **LoweringCtx** (`anyparse.core.LoweringCtx`) with skipStack, captures, indentMode, activeFormat, and `mode:Mode`. Wrapped in `#if macro`.
5. ✅ **RuntimeContrib** type (`anyparse.core.RuntimeContrib`) for what strategies contribute to the runtime Parser class. Wrapped in `#if macro`.
6. ✅ **Format interfaces**:
   - `anyparse.format.Format` — base (name, version, encoding).
   - `anyparse.format.text.TextFormat` — mapping/sequence/scalar model with literals, policies, escape handling; fields as `(default, null)` properties to allow final-like initializer assignment.
   - `anyparse.format.binary.BinaryFormat` — stub, declared so the interface hierarchy is visible.
   - `anyparse.format.text.JsonFormat` — first real `TextFormat` implementation with JSON literals extracted from `JsonWriter`, exposed via `JsonFormat.instance` singleton.
7. ✅ **Runtime types**:
   - `anyparse.runtime.Input` — byte/string stream abstraction. `StringInput` as first implementation.
   - `anyparse.runtime.Span` — byte offsets with lazy line/col resolution via `Position` typedef.
   - `anyparse.runtime.ParseError` — span, message, expected, severity; extends `haxe.Exception`.
   - `anyparse.runtime.ParseResult<T>` — wrapper for Tolerant mode.
   - `anyparse.runtime.Node<T>` — AST metadata wrapper for Tolerant mode (declared, unused in Phase 1).
   - `anyparse.runtime.Parser` — the runtime context that generated code threads through. Fields: input, pos, errors, cache, indentStack, captures, cancelled.
   - `anyparse.runtime.ParseCache` — interface plus `NoOpCache` singleton default.
8. ✅ **Refactor hand-written `JsonParser`** to use `Input`/`Parser`/`ParseError` from the new runtime. Hand-written behavior preserved; runtime types validated as usable.
9. ✅ **Refactor hand-written `JsonWriter`** to read literals and policies from `JsonFormat` instead of hardcoding. No behavior change, only source.
10. ✅ All 288 existing tests remain green after refactor (plus 27 new foundation tests; 328 passing assertions total on neko, js, and interp targets).
11. ✅ Project memory updated with session handoff notes for Phase 2 (`session_state.md` carries design decisions D1–D8).
12. ✅ First commit — initial public release at `AxGord/anyparse` on GitHub (commit `b1cdccf`).

**Non-deliverables for this phase** (explicitly deferred):
- The `@:build` macro itself — that is Phase 2.
- Strategy implementations (PEG descent, Pratt, Indent, Binary) — those come with the macro in Phase 2+.
- Family IRs — those appear when we have 2+ grammars.
- Cross-family round-trip test — contract is documented, implementation waits for family IRs.
- Recovery, cache, cancellation runtime behaviors — interfaces exist, behavior is no-op in Phase 1.

**Exit condition**: the hand-written JSON parser runs on the new runtime, the hand-written JSON writer reads from JsonFormat, all 288 tests pass on neko/js/interp, and the macro foundation is ready to be plugged into. First commit made.

## Phase 2: First macro-generated parser — DONE (2026-04-11)

**Goal**: write the `@:build` macro and use it to regenerate the JSON parser from the existing `JValue` enum definition. The hand-written version remains in the repo as a regression baseline. Writer regeneration is deferred (see Phase 3).

**Deliverables**:
- ✅ The macro entry point — `anyparse.macro.Build.buildParser(TargetType)` applied to a marker class `JValueFastParser`. Placing `@:build` on the enum itself was attempted first but Haxe's enum-constructor information is not available at `@:build` time on the enum — the marker-class pattern bypasses that.
- ✅ `ShapeBuilder` — worklist-based `haxe.macro.Type → ShapeTree` pass covering enum / typedef-to-anon / abstract with `@:re` / `Array<T>` / named-type Ref / std-primitive Terminal.
- ✅ `Lit` strategy — owns `@:lit` / `@:lead` / `@:trail` / `@:wrap` / `@:sep`. Multi-literal `@:lit("true","false")` for a single `Bool` field is recognised and lowered to an `Alt` of Lit nodes that map matched literal → identifier-named Bool value.
- ✅ `Re` strategy — owns `@:re`. Pairs with a per-underlying-type decoder table (`Float → Std.parseFloat`, `Int → Std.parseInt`) in Lowering. String terminals require an explicit `@:unescape`, `@:decode`, or `@:rawString` annotation.
- ✅ `Skip` strategy — owns `@:ws`. Turns on inline `skipWs(ctx)` insertion before every literal and regex match in the grammar.
- ✅ `StrategyRegistry` — topological sort by `runsAfter` / `runsBefore` with duplicate-meta detection. Runs the annotate pass in deterministic order.
- ✅ `Lowering` + `Codegen` — directly emit Haxe `Expr` for each rule's function body (using the `Empty`, `Seq`, `Alt`, `Star`, `Opt`, `Ref`, `Lit`, `Re` primitives conceptually without going through a serialized CoreIR IR) and wrap into `Field`s plus the runtime helpers (`skipWs`, `matchLit`, `expectLit`) and static `EReg` fields.
- ✅ Fast-mode-only codegen. Tolerant mode is stubbed — the Phase-1 `ParseResult`/`Node` types remain unused in generated code.
- ✅ `JValue` annotated with `@:peg` + `@:schema(JsonFormat)` + `@:ws` + per-ctor `@:lit` / `@:lead` / `@:trail` / `@:sep`. `JString(v:JStringLit)` / `JNumber(v:JNumberLit)` use transparent abstracts over `String` / `Float` so existing test literals compile unchanged.
- ✅ `JEntry` rewritten with explicit `var`-form typedef fields so that field-level `@:lead(':')` is accepted.
- ✅ `JsonParserTestBase` extracted as an abstract base; `JsonParserTest` and `JsonMacroParserTest` are thin subclasses differing only in the `parseJson` hook. `JsonMacroRoundTripTest` mirrors `JsonRoundTripTest` but parses through `JValueFastParser`.
- ✅ 585 tests green on neko, js, and interp (the original 328 plus the macro parity and macro round-trip suites).

**Exit condition**: met. Hand-written and macro-generated JSON parsers produce identical results across the full existing corpus and the seeded-random round-trip corpus on all three targets.

**Non-deliverables for this phase** (explicitly deferred):
- Writer regeneration (`JValueFastWriter`) — Phase 2b or Phase 3, driven by real pain points from Phase 3.
- Tolerant-mode codegen.
- Pratt / Indent / Binary / Capture / Recovery strategies.
- Cross-family IR work.
- `@:decode` metadata — replaced by the closed decoder table in Phase 2; can be generalised later.
- `Build`/`Bind`/`Host`/`ExprRef`/`Decode` CoreIR primitives in the codegen path — present in `core/CoreIR.hx` as types but not consumed by the Phase 2 emitter; adopted when Phase 3 needs them.

## Phase 3: Haxe grammar and formatter replacement — in progress (2026-04-11 skeleton landed)

**Goal**: write the Haxe language grammar on anyparse and use it to build a formatter. This is the first real programming-language grammar and the first practical user-facing tool from this project.

**Deliverables**:
- 🔶 `anyparse.grammar.haxe` package (currently `src/anyparse/grammar/haxe/`, may split to a separate haxelib later) containing the Haxe grammar as `@:peg` types with metadata. **Skeleton landed**: single class declaration with `var name:Type;` and `function name():Type {}` members; `HaxeFormat` singleton; `HaxeFastParser` marker class driving the macro pipeline.
- ⬜ Haxe formatter CLI binary (hxcpp or neko) that takes a `.hx` file and outputs formatted Haxe.
- ⬜ Test corpus from the user's haxe-formatter fork: every regression case in that fork's commit history becomes a test case here.
- ⬜ Performance benchmark against haxe-formatter on a real Haxe codebase.

**Phase 3 skeleton — what landed (2026-04-11)**:
- `anyparse.macro.strategy.Kw` — new strategy for `@:kw("word")` with word-boundary enforcement; runs before `Lit`, writes `kw.leadText` annotation slot.
- `Codegen` — new `expectKw` helper (matchLit + word-boundary check) alongside `expectLit`.
- `Lowering` — Case 3 (single-Ref enum branch) extended with optional kw/lit lead and lit trail; Case 4 (Star enum branch) gained a no-separator loop variant; `lowerStruct` learned per-field `@:kw`/`@:trail` and a `Star<Ref>` field case that delegates to a new `emitStarFieldSteps` helper; `lowerTerminal` recognises `@:rawString` on String terminals to skip the JSON unescape path.
- `ShapeBuilder.shapeTypedef` — now sorts `AnonType.fields` by source position so typedef Seq child order matches declaration order regardless of the compiler's hash iteration (JSON happened to be alphabetically sorted in source order; HxClassDecl revealed the ordering bug).
- Grammar package `src/anyparse/grammar/haxe/`: `HaxeFormat` (TextFormat stub, known debt pending `LanguageFormat` interface), `HxIdentLit` (identifier terminal with `@:rawString`), `HxTypeRef`, `HxVarDecl`, `HxFnDecl`, `HxClassMember`, `HxClassDecl` (root typedef), `HaxeFastParser` marker class.
- `test/unit/HaxeFirstSliceTest.hx` — 10 tests covering empty/single/multi/mixed members, irregular whitespace, word-boundary rejection of `classy`, and other rejection cases. 621 tests green on neko/js/interp.

**Phase 3 multi-decl slice — what landed (2026-04-11, after skeleton)**:
- `anyparse.grammar.haxe.HxDecl` — single-branch enum (ClassDecl) for top-level declarations; future typedef/enum/abstract/interface branches hang off it.
- `anyparse.grammar.haxe.HxModule` — module root typedef wrapping `Array<HxDecl>` with no wrappers; drives the EOF-terminated Star loop variant in `Lowering.emitStarFieldSteps`.
- `anyparse.grammar.haxe.HaxeModuleFastParser` — second marker class alongside `HaxeFastParser`, validating that the pattern scales to multiple grammar roots in a single package.
- `Lowering.emitStarFieldSteps` — three termination modes now coexist: close-peek (trail only), sep-peek with empty-list precheck (trail + sep), and EOF (no trail). `@:sep` without `@:trail` is rejected at compile time.
- `test/unit/HaxeModuleSliceTest.hx` — 10 tests covering empty/single/multi/mixed modules, whitespace variance, and trailing-garbage / incomplete-last-decl rejections. 650 tests green.

**Phase 3 expression-atom slice — what landed (2026-04-11, after multi-decl)**:
- `anyparse.grammar.haxe.HxIntLit` — positive-integer terminal (`@:re('[0-9]+')`), Int underlying.
- `anyparse.grammar.haxe.HxExpr` — atom enum with four constructors in source order: `IntLit(HxIntLit)`, `@:lit('true','false') BoolLit(Bool)`, `@:lit('null') NullLit`, `IdentExpr(HxIdentLit)`. Operators, calls, field access, FloatLit, and StringLit are deferred.
- `ShapeBuilder.shapeFieldType` — unwraps `Null<T>` on typedef fields into a `base.optional=true` annotation on the inner node; `shapeField` enforces bidirectional `@:optional` ↔ `Null<T>` consistency via `Context.fatalError`.
- `Lowering.lowerStruct` — new `case Ref if (isOptional):` branch emits a `matchLit` peek + conditional `parseX(ctx)` call, wrapping the result in `final _f_x:Null<T> = if (matchLit(...)) { skipWs; parseX(ctx); } else null;`. Per-field lead and trail emission skipped for optional fields; `@:optional @:kw` and `@:optional @:trail` rejected at compile time as deferred.
- `Lowering.lowerTerminal` — decoder switch gained an `Int` row via `Std.parseInt` with an explicit null guard. Third entry alongside `Float` and `String`; meets D20's exit trigger for the closed decoder table.
- `anyparse.grammar.haxe.HxVarDecl` — third field `@:optional @:lead('=') var init:Null<HxExpr>;` wires expression atoms into the class-member grammar.
- `test/unit/HxExprSliceTest.hx` — 12 tests covering absent init, each atom type, whitespace around `=`, empty-init rejection, missing-semicolon rejection, mixed class members, and multi-decl through the module root. 691 assertions green on neko/js/interp.

**Phase 3 Pratt slice — what landed (2026-04-11, after expression-atom)**:
- `anyparse.macro.strategy.Pratt` — new annotate-only strategy owning `@:infix("op", prec)`. Writes `pratt.op`, `pratt.prec`, and `pratt.assoc` onto enum-branch ShapeNodes. Associativity defaults to `Left` — right-associative operators deferred.
- `Lowering.lowerRule` — now returns `Array<GeneratedRule>` so a single Pratt-enabled enum emits two sibling functions: `parseXxx(ctx, minPrec = 0)` (the precedence-climbing loop, flagged `hasMinPrec`) and `parseXxxAtom(ctx)` (the atoms-only dispatcher). Non-Pratt enums still emit exactly one rule, so every other grammar path is unchanged.
- `Lowering.lowerPrattLoop` — new function that folds the Pratt branches into a nested `if / else if` operator dispatch. Each branch checks `precValue < minPrec` for rollback, recurses into the loop at `prec + 1` for the right operand, and rebuilds `left` as the branch's ctor call.
- `Lowering.lowerEnum` — gained an `atomsOnly` flag that filters out branches with `pratt.prec` so the atom function sees only leaves.
- `Lowering.lowerEnumBranch` Cases 1 and 2 — word-boundary aware: when a `@:lit` literal ends with a word character the generator emits `expectKw` / `matchKw` instead of `expectLit` / `matchLit`. Closes known debt #7. Multi-`@:lit` sets that mix word-like and symbolic literals are now a compile-time error.
- `Codegen` — new `matchKw(ctx, keyword):Bool` runtime helper (peek + word-boundary check with rollback on failure). `ruleField` now emits an additional `minPrec:Int = 0` parameter on rules flagged `hasMinPrec`; the default-value-only form (no `opt: true`) keeps the parameter as non-nullable `Int` under strict null safety.
- `GeneratedRule` — new `hasMinPrec:Bool` field so Codegen knows which rules need the Pratt parameter.
- `anyparse.grammar.haxe.HxFloatLit` — new Float terminal with `@:re('[0-9]+\\.[0-9]+(?:[eE][-+]?[0-9]+)?')`. Reuses the existing `Float` decoder row in `Lowering.lowerTerminal`; no new row needed.
- `anyparse.grammar.haxe.HxExpr` — five atom branches (`FloatLit` before `IntLit`, then BoolLit / NullLit / IdentExpr) plus four binary-infix branches (`Add`/`Sub` at prec 6, `Mul`/`Div` at prec 7). Branch source order drives both atom dispatch and operator precedence-mixing: FloatLit before IntLit lets `3.14` land correctly without leaving a stray `.14`.
- `test/unit/HxPrattSliceTest.hx` — 19 tests: each operator alone, precedence mixing (`1 + 2 * 3`, `2 * 3 + 1`, `1 + 2 * 3 + 4`), left-associativity (`1 + 2 + 3`, `10 - 3 - 2`), FloatLit with and without exponent, float-plus-int, bare-int after FloatLit rollback, `trueish` / `nullable` / `falsey` word-boundary rejections, trailing-operator rejection, ident + int, and end-to-end via HaxeModuleFastParser. 746 assertions green on neko/js/interp (691 baseline + 55 new).

**Phase 3 bitwise + shift + arithmetic compound-assign slice — what landed (2026-04-12, after parens + right-assoc)**:
- `anyparse.grammar.haxe.HxExpr` — 9 new binary-infix ctors added on top of the 16-operator baseline from the prior Pratt / operator-expansion / parens+right-assoc slices. Two new precedence levels inserted (shifts at prec 7, bitwise at prec 6) between the existing additive and comparison levels, forcing a mechanical renumber of `* / %` (7 → 9) and `+ -` (6 → 8). New ctors: `Shl` (`<<`), `Shr` (`>>`), `UShr` (`>>>`) at prec 7 left-assoc; `BitOr` (`|`), `BitAnd` (`&`), `BitXor` (`^`) at prec 6 left-assoc; `MulAssign` (`*=`), `DivAssign` (`/=`), `ModAssign` (`%=`) at prec 1 right-assoc. `Bit*` prefix is required because the `And` / `Or` ctor names are already claimed by `&&` / `||`.
- The slice is purely additive in the macro pipeline — zero changes to `Pratt.hx`, `Lowering.hx`, `Build.hx`, `Codegen.hx`, `ShapeBuilder.hx`. Every new ctor flows through the existing Pratt annotate + `lowerPrattLoop` path, and every shared-prefix conflict (`<<`/`<`/`<=`, `>>>`/`>>`/`>`/`>=`, `||`/`|`, `&&`/`&`, `*=`/`*`, `/=`/`/`, `%=`/`%`) is resolved by the longest-match sort (D33) already shipped in the Pratt operator expansion slice.
- `test/unit/HxBitwiseSliceTest.hx` — 20 new tests: 6 per-operator smoke, 4 cross-level precedence (add/shift, shift/bitwise, bitwise/eq, bitwise/bitwise same-level), 5 longest-match disambiguation regression guards (`<`/`<=` after adding `<<`, `>`/`>=` after adding `>>`, `>>>` vs `>>`), 2 left-assoc chains at the new prec levels, 2 rejection tests, and 1 end-to-end module through `HaxeModuleFastParser`.
- `test/unit/HxAssignSliceTest.hx` — 5 new tests extending the existing right-assoc corpus: 3 smoke (`*=`, `/=`, `%=`), 1 second-wave right-fold chain (`a *= b /= 1`), 1 cross-wave compound chain (`a *= b += 1`) proving the two shipping waves compose inside a single Pratt chain.
- Stale `prec 6` / `prec 7` references in doc-comments across `HxPrattSliceTest`, `HxPrattOpsTest`, and `HxAssignSliceTest` updated to the renumbered values. 946 assertions green on neko (870 baseline + 76 new).

**Phase 3 postfix slice (slice δ) — what landed (2026-04-12, after slice γ)**:
- `anyparse.macro.strategy.Postfix` — new annotate-only strategy owning `@:postfix`. Accepts both one-arg (`@:postfix('.')`) and two-arg (`@:postfix('[', ']')`) forms. Writes `postfix.op` (always) and, for the two-arg form, `postfix.close` onto the branch `ShapeNode`. Returns `null` from `lower`. Registered in `Build.hx` alongside the existing strategies. Empty `runsBefore` / `runsAfter` — `postfix.*` is a unique namespace.
- `anyparse.macro.Lowering` — three-function split when an enum has both Pratt and postfix branches. `lowerRule` now returns `[loopRule, wrapperRule, coreRule]` for such enums: `parseXxx` (Pratt loop, unchanged), `parseXxxAtom` (NEW: wrapper that calls `parseXxxAtomCore` and runs `lowerPostfixLoop` on the result), `parseXxxAtomCore` (the old `parseHxExprAtom` body — pure leaf + prefix dispatcher, renamed). For postfix-only enums (no Pratt), a two-function split emits `parseXxx` (wrapper, public entry) + `parseXxxCore`. Prefix's `recurseFnName` now targets the wrapper in both cases, so `-a.b` parses as `Neg(FieldAccess(a, b))` — postfix is applied to the prefix operand before the prefix ctor wraps it.
- `anyparse.macro.Lowering.lowerPostfixLoop` — new helper parallel to `lowerPrattLoop`. Emits `var left = coreCall; while(true) { skipWs; _matched=true; <chain>; if(!_matched) break; } return left;`. The chain dispatches on `postfix.op` via `matchLit`, sorted longest-first (D33 pattern). Three branch shapes recognised at macro time: (1) **pair-lit (call-no-args)** — one child, `postfix.close` set, emits `expectLit(close); left = Ctor(left);`; (2) **single-Ref-suffix (field access)** — two children, no `postfix.close`, emits `parseSuffix; left = Ctor(left, _suffix);`; (3) **wrap-with-recurse (index access)** — two children, `postfix.close` set, emits `parseSuffix; expectLit(close); left = Ctor(left, _suffix);`. Wrap-with-recurse calls `parseXxx` (the Pratt loop entry) when the suffix type is the same enum, so `a[b + 1]` allows arbitrary infix operators inside the brackets.
- `anyparse.macro.Lowering.lowerEnum` — signature gained explicit `recurseFnName:String` parameter (was computed internally from `atomsOnly`); the three-function split path needs to pass different names for Pratt+postfix vs postfix-only. The `atomsOnly=true` filter now excludes BOTH `pratt.prec` and `postfix.op` branches — both are operator-shaped forms owned by their respective loops.
- `anyparse.grammar.haxe.HxExpr` — three new ctors after the prefix section and before `Mul`: `@:postfix('.') FieldAccess(operand:HxExpr, field:HxIdentLit)`, `@:postfix('[', ']') IndexAccess(operand:HxExpr, index:HxExpr)`, `@:postfix('(', ')') CallNoArgs(operand:HxExpr)`. `Call(operand, args:Array<HxExpr>)` with real argument list is deliberately deferred to slice δ2 — it adds a fourth concept ("Array<Ref> suffix inside an enum-branch postfix shape") that is cleanest as a follow-up after δ1's infrastructure ships.
- `test/unit/HxPostfixSliceTest.hx` — 19 new tests: 3 per-op smoke (field/index/call), 3 left-recursion chains (`a.b.c`, `a[1][2]`, `f()()`), 4 mixed chains (`a.b[c]`, `a[b].c`, `f().x`, `a.b()` — the idiomatic method-call-on-member case), 2 prefix-over-postfix binding-tightness (`-a.b`, `!f()`), 2 postfix-over-Pratt binding-tightness (`a.b + c`, `c + a.b`), 1 nested infix inside index (`a[b + 1]`), 1 parens + postfix (`(a + b).c`), 1 end-to-end through `HaxeModuleFastParser`, 2 rejection (`a.;`, `a[1;`).
- **D40**: data-driven `OperatorDispatch` extraction **rejected** in slice δ. The three dispatcher shapes (prefix Case 5 in `lowerEnumBranch`, atom Cases 1-4 in the same function, postfix loop in `lowerPostfixLoop`) live at structurally different call-sites with different concerns — per-branch body inside a try/catch wrapper versus a loop over all branches operating on an accumulator. A unified abstraction would force one shape to fit three different sites. Exit criterion for revisiting: a fourth dispatcher shape landing adjacent to these three (most likely `new T(...)` or ternary `? :` in a future slice).
- **1088 assertions green on neko / js / interp** (1029 baseline + 59 new from the 19 new tests in `HxPostfixSliceTest` — most tests assert on multiple components of the parsed subtree). Non-deliverables: argument lists inside calls (δ2), ternary `? :`, `??`, `=>`, `new T(...)`.

**Phase 3 call-with-args slice (slice δ2) — what landed (2026-04-12, after slice δ)**:
- `anyparse.grammar.haxe.HxExpr` — `CallNoArgs(operand:HxExpr)` replaced with `@:postfix('(', ')') @:sep(',') Call(operand:HxExpr, args:Array<HxExpr>)`. Handles both zero-arg `f()` (empty args array) and N-arg `f(a, b, c)` through a single ctor. The `@:sep(',')` on the ctor feeds `lit.sepText` on the branch node via the Lit strategy.
- `anyparse.macro.Lowering.lowerPostfixLoop` — fourth shape variant: **Star-suffix with sep-loop**. Detects `children.length == 2 && children[1].kind == Star && close != null`. Reads `branch.annotations.get('lit.sepText')` for the separator (same source as Case 4 in `lowerEnumBranch`). Emits sep-peek array loop: peek close-char for empty list, push first element, then while-sep-consume-push-next, then `expectLit(close)`. Both sep and no-sep paths supported. Branch inserted before the existing `children.length == 2` Ref handling so Star is checked first.
- `test/unit/HxPostfixSliceTest.hx` — 5 existing tests updated (`CallNoArgs` → `Call` with empty args check), 10 new tests: single-arg, two-arg, three-arg, expression args (`f(a + 1, b * 2)`), chained calls with args (`f(1)(2)`), method call with args (`a.b(1, 2)`), whitespace tolerance, call inside index, trailing-comma rejection, and end-to-end through `HaxeModuleFastParser`.
- **D42**: `@:sep` on a postfix branch feeds `lowerPostfixLoop`'s Star-suffix variant. Sep literal comes from `lit.sepText` on the branch node. Third sep-loop emitter site (debt #5 at triggering threshold).
- **1143 assertions green on neko / js** (1088 baseline + 55 new from 10 new + 5 updated tests). Non-deliverables: ternary `? :`, `??`, `=>`, `new T(...)`.

**Phase 3 unary-prefix slice (slice γ) — what landed (2026-04-12, after slice β)**:
- `anyparse.macro.strategy.Prefix` — new annotate-only strategy owning `@:prefix('op')`. Single-argument form only: no precedence value, no associativity. Writes `prefix.op` onto the branch `ShapeNode` and returns `null` from `lower`. Mirrors `Pratt.hx` in structure; declares empty `runsBefore` / `runsAfter` because the namespace is unique and the strategy reads nothing other strategies produce. Registered in `Build.hx` alongside `Kw`/`Lit`/`Pratt`/`Re`/`Skip`.
- `anyparse.macro.Lowering.lowerEnum` — now computes `recurseFnName = atomsOnly ? 'parse${simple}Atom' : 'parse${simple}'` and threads it through `tryBranch` → `lowerEnumBranch` as a third parameter. Carries the name of the function currently being generated (atom for Pratt enums, whole rule for plain enums) so the new classifier case can emit a self-recursive call for prefix operands.
- `anyparse.macro.Lowering.lowerEnumBranch` — new **Case 5** at the top of the classifier, running BEFORE the existing Cases 1/2/4/3. Detects `prefix.op`, validates the branch shape (exactly one `Ref` child referencing the same enum as the rule, operator literal must not end in a word character — word-like prefix ops rejected via `Context.fatalError`). Emits `skipWs; expectLit(ctx, op); skipWs; final _operand:$returnCT = $recurseFnName(ctx); return Ctor(_operand);`. Must run before Case 3 because a prefix branch structurally matches "single `Ref`, no `@:lit`" and Case 3 would emit a body with no `expectLit`, infinite-looping. Recursion targets the current function — for Pratt-enabled enums this is the atom function, which gives `-x * 2` the correct `Mul(Neg(x), 2)` shape without any precedence parameter on `@:prefix` (prefix binds tighter than every binary by construction, not by numeric prec).
- `anyparse.grammar.haxe.HxExpr` — three new ctors after `IdentExpr` and before `Mul`: `@:prefix('-') Neg(operand:HxExpr)`, `@:prefix('!') Not(operand:HxExpr)`, `@:prefix('~') BitNot(operand:HxExpr)`. Naming follows the file's existing `Bit*` convention for bitwise-family ctors (`BitOr`/`BitAnd`/`BitXor`/`BitNot`). Atom branches remain in source order with the three prefix branches sitting after the pure atoms so regex/literal atoms (`FloatLit`/`IntLit`/`BoolLit`/`NullLit`/`ParenExpr`/`IdentExpr`) all get first attempt on input like `5` and only fall through to the prefix branches when a leading `-` / `!` / `~` blocks every leaf regex.
- `test/unit/HxPrefixSliceTest.hx` — 15 new tests: 3 per-op smoke with identifier operand (`-x`, `!x`, `~x`), 3 prefix + terminal atoms (`-5`, `-3.14`, `!true`), 3 load-bearing binding-tightness tests (`-x + 1 → Add(Neg(x), 1)`, `!x && y → And(Not(x), y)`, `~x | 1 → BitOr(BitNot(x), 1)` — these lock in the recurse-into-atom property), 2 nested same-op prefix (`--x`, `!!x`), 1 mixed-prefix (`-!x`), 1 prefix + parens (`-(x + 1)`), 1 end-to-end through `HaxeModuleFastParser`, 1 rejection (`var x:Int = - ;`). Helpers `parseSingleVarDecl` / `expectVarMember` remain duplicated from sibling `Hx*SliceTest` files — debt #5b tracks the extraction into a shared base.
- **1029 assertions green on neko/js/interp** (995 baseline + 34 new assertions from 15 test methods — some tests assert on multiple components of the parsed tree). Zero changes to `Pratt.hx`, `Build.hx` beyond the one-line registration, `ShapeBuilder.hx`, `Codegen.hx`, `StrategyRegistry.hx`, or the runtime — slice γ is purely a new strategy + one new classifier case in `Lowering.lowerEnumBranch`.
- **D40**: data-driven dispatch still deferred. Case 5 and `lowerPrattLoop` now sit at different sites with one row each — shallow inline duplication, not a table problem. Three sibling dispatchers in the same function reading heterogeneously is the true trigger; that fires when postfix lands in slice δ. Until then, the two inline bodies are the simplest correct code.

**Phase 3 bitwise/shift compound-assigns slice (slice β) — what landed (2026-04-12, after bitwise + shifts + arithmetic compound-assigns)**:
- `anyparse.grammar.haxe.HxExpr` — 6 new binary-infix ctors added at prec 1 right-assoc on top of the 25-operator baseline: `ShlAssign` (`<<=`), `ShrAssign` (`>>=`), `UShrAssign` (`>>>=`), `BitOrAssign` (`|=`), `BitAndAssign` (`&=`), `BitXorAssign` (`^=`). Names follow the existing `<Op>Assign` pattern; `Bit*` prefix on the bitwise compound assigns matches the base `BitOr` / `BitAnd` / `BitXor` names. Operator count goes 25 → 31 across nine populated precedence levels; prec 1 alone now carries twelve assignment ctors.
- The slice is **purely additive** — zero changes to any macro-pipeline file (`Pratt.hx`, `Lowering.hx`, `Build.hx`, `Codegen.hx`, `ShapeBuilder.hx` all untouched). Every new ctor flows through the shipped Pratt annotate + `lowerPrattLoop` path. The slice's load-bearing goal is validating the D33 longest-match sort against the densest prefix-conflict set in the grammar so far: `>>>=` (4) vs `>>>` (3) vs `>>=` (3) vs `>>` (2) vs `>=` (2) vs `>` (1); `<<=` (3) vs `<<` (2) vs `<=` (2) vs `<` (1); `|=` (2) vs `||` (2) vs `|` (1); `&=` (2) vs `&&` (2) vs `&` (1). The sort handles all conflicts without source-code changes.
- `test/unit/HxAssignSliceTest.hx` — 15 new tests extending the existing wave-1/wave-2 corpus: 6 per-op smoke (`<<=`, `>>=`, `>>>=`, `|=`, `&=`, `^=`), 3 base-op regression guards (`a << b`, `a >> b`, `a | b` still parse as the base shift/bitwise ctors after the compound ctors land), 2 wave-3 right-fold chains (bitwise `|= &=`, shift `<<= >>=`), 1 triple-wave compound chain (`a += b *= c ^= 1` proving waves 1+2+3 compose), 2 cross-prec interactions (`|=` with RHS shift, `>>=` with RHS additive), 1 rejection (`a >>>= ;` — missing RHS on the longest compound-assign literal).
- 995 assertions green on neko (946 baseline + 49 new from the 15 new tests). Operator count crosses the debt-#10 reassessment threshold (~30); evaluation of data-driven dispatch deferred until the first non-binary-infix branch (prefix or postfix) lands, so the decision can be made against a heterogeneous loop rather than a denser homogeneous one.

**Phase 3 function params slice (slice ζ) — what landed (2026-04-12, after slice ε)**:
- `anyparse.grammar.haxe.HxParam` — new `@:peg` typedef with `name:HxIdentLit`, `@:lead(':') type:HxTypeRef`, `@:optional @:lead('=') defaultValue:Null<HxExpr>`. Reuses the `@:optional @:lead` pattern from `HxVarDecl.init`.
- `anyparse.grammar.haxe.HxFnDecl` — `@:trail('()')` on name replaced with `@:lead('(') @:trail(')') @:sep(',') var params:Array<HxParam>`. First struct Star field in the Haxe grammar using the sep-peek termination mode in `emitStarFieldSteps`. Zero-param functions parse as `params: []`.
- Zero changes to `Lowering.hx`, `Codegen.hx`, `Build.hx`, `ShapeBuilder.hx` — all infrastructure existed.
- `test/unit/HxTestHelpers.hx` — new shared test base class with `parseSingleVarDecl`, `parseSingleFnDecl`, `expectVarMember`, `expectFnMember`, `expectClassDecl`. Extracted from 10 test files (debt #5b closed).
- `test/unit/HxParamSliceTest.hx` — 12 new tests: zero/single/two/three params, default values (int, bool, expression), mixed defaults, whitespace tolerance, trailing-comma rejection, missing-type rejection, module-root integration, params with modifiers.
- 1263 assertions green on neko/js (1196 baseline + 67 new).

**Phase 3 function bodies slice (slice η₁) — what landed (2026-04-12, after slice ζ)**:
- `anyparse.grammar.haxe.HxStatement` — new `@:peg` enum with three branches: `@:kw('var') @:trail(';') VarStmt(decl:HxVarDecl)`, `@:kw('return') @:trail(';') ReturnStmt(value:HxExpr)`, `@:trail(';') ExprStmt(expr:HxExpr)`. Keyword-dispatched branches first, expression-statement catch-all last. All three are Case 3 in `Lowering.lowerEnumBranch`.
- `anyparse.grammar.haxe.HxFnDecl` — `@:trail('{}')` on `returnType` replaced with a new `@:lead('{') @:trail('}') var body:Array<HxStatement>` field. Close-peek Star termination mode — same pattern as `HxClassDecl.members`. Empty function bodies `{}` parse as `body: []`.
- Zero changes to `Lowering.hx`, `Codegen.hx`, `Build.hx`, `ShapeBuilder.hx` — all patterns existed.
- `test/unit/HxBodySliceTest.hx` — 16 new tests: empty body, single expr-statement, return statement, var statement (with and without init), mixed statements, operators in body, method call, method call chain, assignment, multiple expr-statements, return expression, whitespace tolerance, missing-semicolon rejection, unclosed-brace rejection, module-root integration.
- 1329 assertions green on neko/js (1263 baseline + 66 new).

**Phase 3 top-level forms slice (slice θ) — what landed (2026-04-12, after slice η₁)**:
- `anyparse.grammar.haxe.HxTypedefDecl` — new `@:peg` typedef: `@:kw('typedef') name`, `@:lead('=') type`. Simplest top-level form — type alias binding.
- `anyparse.grammar.haxe.HxEnumCtor` — new `@:peg` typedef: `@:trail(';') name`. Zero-arg enum constructors only; constructors with parameters deferred.
- `anyparse.grammar.haxe.HxEnumDecl` — new `@:peg` typedef: `@:kw('enum') name`, `@:lead('{') @:trail('}') ctors:Array<HxEnumCtor>`. Structurally identical to `HxClassDecl` — close-peek Star field.
- `anyparse.grammar.haxe.HxInterfaceDecl` — new `@:peg` typedef: `@:kw('interface') name`, `@:lead('{') @:trail('}') members:Array<HxMemberDecl>`. Structural clone of `HxClassDecl` sharing `HxMemberDecl`.
- `anyparse.grammar.haxe.HxDecl` — three new branches: `@:trail(';') TypedefDecl(decl:HxTypedefDecl)`, `EnumDecl(decl:HxEnumDecl)`, `InterfaceDecl(decl:HxInterfaceDecl)`. TypedefDecl carries `@:trail(';')` because it has no closing brace. All three are Case 3 in `lowerEnumBranch`.
- Zero changes to `Lowering.hx`, `Codegen.hx`, `Build.hx`, `ShapeBuilder.hx` — all patterns existed.
- `test/unit/HxTopLevelSliceTest.hx` — 20 new tests: typedef (simple, whitespace, in-module, reject missing equals, reject missing semicolon), enum (empty, single/multiple ctors, whitespace, in-module, reject unclosed), interface (empty, with var, with function, with modifiers, in-module), mixed module, word-boundary rejection for all three keywords.
- 1390 assertions green on neko/js (1329 baseline + 61 new).

**Phase 3 ternary + null-coalescing slice (slice ι₁) — what landed (2026-04-12, after slice θ)**:
- `anyparse.macro.strategy.Ternary` — new annotate-only strategy owning `@:ternary('op', 'sep', prec)`. Writes `ternary.op`, `ternary.sep`, `ternary.prec` annotations. Returns null from `lower()`. Registered in `Build.hx` between Pratt and Prefix.
- `anyparse.macro.Lowering` — `hasPrattBranch` now also checks `ternary.op`. `lowerEnum` atomsOnly filter excludes `ternary.op` branches. `lowerPrattLoop` collects both `pratt.prec` and `ternary.op` branches into a unified operator dispatch chain via new `getOperatorText` helper. Ternary dispatch emits: `matchLit(op) → prec gate → parseMiddle(minPrec=0) → expectLit(sep) → parseRight(minPrec=0) → Ctor(left, middle, right)`. Binary dispatch unchanged.
- `anyparse.grammar.haxe.HxExpr` — two new ctors: `@:ternary('?', ':', 1) Ternary(cond, thenExpr, elseExpr)` and `@:infix('??', 2, 'Right') NullCoal(left, right)`. Twelve assignment ctors renumbered from prec 1 to prec 0 (D46). D33 longest-match sort resolves `??` (len 2) vs `?` (len 1).
- `test/unit/HxTernarySliceTest.hx` — 20 new tests: `??` smoke/right-assoc/precedence, ternary smoke/right-assoc/operators-in-branches, cross-operator interactions (`??` tighter than ternary, assignment in ternary right), integration (return stmt, module root), assignment renumber sanity, rejection tests (missing middle/colon/right).
- Zero changes to `Codegen.hx`, `ShapeBuilder.hx`, `StrategyRegistry.hx`, runtime.
- 1443 assertions green on neko (1390 baseline + 53 new).

**Phase 3 control-flow + ??= slice (slice κ₁) — what landed (2026-04-12, after slice ι₁)**:
- `anyparse.macro.Lowering` — `case Ref if (isOptional)` in `lowerStruct` extended to accept `@:kw` as a commit point via `matchKw` (D47). Guard changed from two separate checks to one: require at least one of `@:lead` or `@:kw`. Previous `@:optional @:kw` fatalError removed.
- `anyparse.grammar.haxe.HxIfStmt` — new `@:peg` typedef: `@:lead('(') @:trail(')') cond`, bare `thenBody:HxStatement`, `@:optional @:kw('else') elseBody:Null<HxStatement>`. First consumer of `@:optional @:kw`. Dangling else resolved by construction (greedy else on innermost if).
- `anyparse.grammar.haxe.HxWhileStmt` — new `@:peg` typedef: `@:lead('(') @:trail(')') cond`, bare `body:HxStatement`. Uses only existing patterns — zero Lowering changes.
- `anyparse.grammar.haxe.HxStatement` — three new branches: `@:kw('if') IfStmt(stmt:HxIfStmt)`, `@:kw('while') WhileStmt(stmt:HxWhileStmt)`, `@:lead('{') @:trail('}') BlockStmt(stmts:Array<HxStatement>)`. All before the `ExprStmt` catch-all. BlockStmt uses Case 4 (Array<Ref> with lead/trail, no sep, close-peek termination). Zero Lowering changes for WhileStmt and BlockStmt.
- `anyparse.grammar.haxe.HxExpr` — one new ctor: `@:infix('??=', 0, 'Right') NullCoalAssign`. Purely additive. D33 longest-match resolves `??=` (3) vs `??` (2) vs `?` (1).
- `test/unit/HxControlFlowSliceTest.hx` — 22 new tests: ??= smoke/right-assoc/regression, if with single/block body, if-else, if-else-if-else, expression condition, dangling else, whitespace tolerance, while single/block body, while whitespace, block/empty-block/nested-blocks, module integration, mixed statements, if-with-while body, word-boundary guards (ifx, whiled).
- 1523 assertions green on neko (1443 baseline + 80 new).

**Phase 3 for + enum ctor params + void return slice (slice λ₁) — what landed (2026-04-12, after slice κ₁)**:
- `anyparse.grammar.haxe.HxForStmt` — new `@:peg` typedef: `@:lead('(') varName`, `@:kw('in') @:trail(')') iterable`, bare `body:HxStatement`. Zero Lowering changes — `@:kw` + `@:trail` on the same struct field already works in `lowerStruct`.
- `anyparse.grammar.haxe.HxStatement` — two new branches: `@:kw('for') ForStmt(stmt:HxForStmt)` and `@:kw('return') @:trail(';') VoidReturnStmt`. ForStmt before BlockStmt (keyword-dispatched). VoidReturnStmt after ReturnStmt — tryBranch tries return-with-value first, rolls back to void on expr parse failure.
- `anyparse.grammar.haxe.HxEnumCtorDecl` — new `@:peg` typedef: `name:HxIdentLit`, `@:lead('(') @:trail(')') @:sep(',') params:Array<HxParam>`. Reuses `HxParam` from function parameters.
- `anyparse.grammar.haxe.HxEnumCtor` — rewritten from typedef to enum with `@:trail(';') ParamCtor(decl:HxEnumCtorDecl)` and `@:trail(';') SimpleCtor(name:HxIdentLit)`. Source order load-bearing: ParamCtor first (more specific, `(` disambiguates), SimpleCtor as fallback. Zero Lowering changes.
- `anyparse.macro.Lowering` — Case 0 (zero-arg `@:kw` branches) extended to read `lit.trailText` and emit `skipWs + expectLit(trail)` when trail is present (D48). Existing consumers (modifiers) unaffected — they have no trail. First consumer: `VoidReturnStmt`.
- `test/unit/HxForEnumVoidSliceTest.hx` — 23 new tests: for with ident/expr/block/nested/whitespace/call-iterable, word-boundary (format/forest), rejection (missing in/close-paren), module integration; enum ctor simple/single-param/multi-param/default-value/mixed/zero-param-vs-bare/whitespace/module; void return bare/before-other/in-block/return-with-value-still-works/module.
- 1605 assertions green on neko (1523 baseline + 82 new).

**Phase 3 switch + new expression slice (slice μ₁) — what landed (2026-04-12, after slice λ₁)**:
- `anyparse.grammar.haxe.HxSwitchStmt` — new `@:peg` typedef: `@:lead('(') @:trail(')') expr:HxExpr`, `@:lead('{') @:trail('}') cases:Array<HxSwitchCase>`.
- `anyparse.grammar.haxe.HxSwitchCase` — new `@:peg` enum: `@:kw('case') CaseBranch(branch:HxCaseBranch)`, `@:kw('default') DefaultBranch(branch:HxDefaultBranch)`.
- `anyparse.grammar.haxe.HxCaseBranch` — new `@:peg` typedef: `@:trail(':') pattern:HxExpr`, `@:tryparse body:Array<HxStatement>`. Pattern parsed as HxExpr (identifiers, literals, call-like patterns work without new types). Body uses `@:tryparse` for implicit termination.
- `anyparse.grammar.haxe.HxDefaultBranch` — new `@:peg` typedef: `@:lead(':') @:tryparse stmts:Array<HxStatement>`. Colon as `@:lead` on the Star field (not `@:trail` on the branch — branch trail fires after the sub-rule, but colon must precede the body).
- `anyparse.grammar.haxe.HxNewExpr` — new `@:peg` typedef: `type:HxIdentLit`, `@:lead('(') @:trail(')') @:sep(',') args:Array<HxExpr>`.
- `anyparse.grammar.haxe.HxExpr` — new atom branch `@:kw('new') NewExpr(expr:HxNewExpr)` before `IdentExpr`. Zero Lowering changes — Case 3 with `@:kw` already works.
- `anyparse.grammar.haxe.HxStatement` — new branch `@:kw('switch') SwitchStmt(stmt:HxSwitchStmt)` after `ForStmt`, before `BlockStmt`.
- `anyparse.macro.Lowering` — `emitStarFieldSteps` try-parse guard extended: `closeText == null && (!isLastField || hasMeta(starNode, ':tryparse'))` (D49). Existing consumers without `@:tryparse` unaffected.
- `test/unit/HxSwitchNewSliceTest.hx` — 23 new tests: switch empty/single-case/multiple-cases/default/case+default/empty-body-fall-through/multi-statement-body/nested/expression-subject/call-pattern/whitespace/word-boundary/module/default-multi-stmt/empty-default; new zero-args/multi-args/expr-arg/postfix-chain/in-switch-body/word-boundary/module/whitespace.
- 1707 assertions green on neko (1605 baseline + 102 new).

**Phase 3 do-while + throw + try-catch slice (slice μ₂) — what landed (2026-04-12, after slice μ₁)**:
- `anyparse.grammar.haxe.HxDoWhileStmt` — new `@:peg` typedef: `body:HxStatement`, `@:kw('while') @:lead('(') @:trail(')') cond:HxExpr`. First consumer of D50 (`@:kw` + `@:lead` on same struct field).
- `anyparse.grammar.haxe.HxTryCatchStmt` — new `@:peg` typedef: `body:HxStatement`, `@:tryparse catches:Array<HxCatchClause>`. D49 reuse for try-parse termination on last field.
- `anyparse.grammar.haxe.HxCatchClause` — new `@:peg` typedef: `@:kw('catch') @:lead('(') name:HxIdentLit`, `@:lead(':') @:trail(')') type:HxTypeRef`, `body:HxStatement`. Second consumer of D50.
- `anyparse.grammar.haxe.HxStatement` — three new branches: `@:kw('throw') @:trail(';') ThrowStmt(expr:HxExpr)` (Case 3 with kw + trail, zero Lowering changes), `@:kw('do') @:trail(';') DoWhileStmt(stmt:HxDoWhileStmt)`, `@:kw('try') TryCatchStmt(stmt:HxTryCatchStmt)`.
- `anyparse.macro.Lowering` — `lowerStruct` line 928: `else if (leadText != null)` → `if (leadText != null)` (D50). When both `@:kw` and `@:lead` are present on a non-Star, non-optional struct field, both emit sequentially. Existing consumers unaffected — no field previously combined both.
- `test/unit/HxDoWhileThrowTryCatchSliceTest.hx` — 19 new tests: throw smoke/expression/block/module/word-boundary; do-while smoke/single-statement/expression-cond/nested/whitespace/word-boundary; try-catch smoke/single-statement/multiple-catches/nested/module/whitespace/word-boundary-try/word-boundary-catch/throw-in-catch.
- 1800 assertions green on neko (1707 baseline + 93 new).

**Phase 3 abstract declarations slice (slice θ₂) — what landed (2026-04-12, after slice μ₂)**:
- `anyparse.grammar.haxe.HxAbstractDecl` — new `@:peg` typedef: `@:kw('abstract') name`, `@:lead('(') @:trail(')') underlyingType`, bare `clauses:Array<HxAbstractClause>` (positional try-parse — first bare Star consumer), `@:lead('{') @:trail('}') members:Array<HxMemberDecl>`.
- `anyparse.grammar.haxe.HxAbstractClause` — new `@:peg` enum: `@:kw('from') FromClause(type:HxTypeRef)`, `@:kw('to') ToClause(type:HxTypeRef)`. Both Case 3 with kw.
- `anyparse.grammar.haxe.HxDecl` — `AbstractDecl(decl:HxAbstractDecl)` branch added. All five top-level declaration forms now covered (class, typedef, enum, interface, abstract).
- Zero Lowering changes — bare Star field try-parse mode already existed.
- `test/unit/HxAbstractSliceTest.hx` — 17 new tests.
- 1859 assertions green on neko (1800 baseline + 59 new).

**Phase 3 string literals slice (slice ν₁) — what landed (2026-04-12, after slice θ₂)**:
- `anyparse.macro.Lowering` — `lowerTerminal` gains `@:decode` meta support (D51). `readMetaString(node, ':decode')` reads a fully-qualified static method path; split on `.`, emitted as `ECall(macro $p{parts}, [macro _matched])`. Priority chain: `@:decode` > `@:rawString` > closed decoder switch. First generalisation of the closed decoder table — grammar-side code names its own decoder function.
- `anyparse.grammar.haxe.HaxeFormat` — `unescapeChar` gained `case '\''.code` for single-quoted string escape support.
- `anyparse.grammar.haxe.HxDoubleStringLit` — new terminal abstract: `@:re('"(?:[^"\\\\]|\\\\.)*"') @:unescape`. Inline walk-and-unescape loop generated by the macro using `HaxeFormat.unescapeChar`.
- `anyparse.grammar.haxe.HxSingleStringLit` — new terminal abstract (later replaced by `HxInterpString` in slice ν₂).
- `anyparse.grammar.haxe.HxExpr` — two new atom branches: `DoubleStringExpr(v:HxDoubleStringLit)`, `SingleStringExpr(v:HxSingleStringLit)`. Both Case 3 (single-Ref, no lead/trail) — zero Lowering changes beyond `@:decode`.
- Two separate types (not one) so the AST preserves which quote style was used — needed for round-trip writers.
- `test/unit/HxStringSliceTest.hx` — 15 new tests: double-quoted (empty, simple, spaces, escapes), single-quoted (empty, simple, escapes, dollar sign), concatenation, function args, return statements, whitespace, module integration, rejection of unterminated strings.
- **D51**: `@:decode` generalises closed decoder table. Grammar-side decoder function, not macro-side. Existing terminals (`HxIdentLit` with `@:rawString`, `HxIntLit`, `HxFloatLit`) all unaffected. `JStringLit` migrated to `@:unescape` in slice ν₃.
- 1890 assertions green on neko (1859 baseline + 31 new).
- Non-deliverables: ~~string interpolation (`$var`, `${expr}`)~~ (shipped in slice ν₂), `\0`, `\xNN`, `\uNNNN` hex/unicode escapes, multi-line strings, raw strings.

**Phase 3 string interpolation slice (slice ν₂) — what landed (2026-04-12, after slice ν₁)**:
- `anyparse.macro.Lowering` — new `@:raw` annotation support (D52). `stripSkipWs(e:Expr):Expr` recursively replaces all `skipWs(ctx)` calls with empty blocks `{}` using `ExprTools.map`. Applied in `lowerRule` as post-processing when `hasMeta(node, ':raw')` is true. Avoids modifying 50+ `skipWs` emission sites. Referenced sub-rules (via Ref) are separate generated functions — unaffected by the stripping.
- `anyparse.macro.ShapeBuilder` — `shapeEnum` now stores `base.meta = e.meta.get()` on the `Alt` node (was missing — typedef `Seq` and abstract `Terminal` already did this). Required for `hasMeta(node, ':raw')` to find enum-level `@:raw`.
- `anyparse.macro.GeneratedRule` — `body` field changed from `final` to `var` to allow `@:raw` post-processing.
- `anyparse.grammar.haxe.HxSingleStringLit` — DELETED. Replaced by declarative grammar types.
- `anyparse.grammar.haxe.HxInterpString` — new `@:peg @:raw` typedef with `@:lead("'") @:trail("'") var parts:Array<HxStringSegment>`. The `@:raw` boundary between non-raw `HxExpr` and raw string content. Star loop uses close-peek termination on `'` char code.
- `anyparse.grammar.haxe.HxStringSegment` — new `@:peg @:raw` enum with four branches: `Literal(s:HxStringLitSegment)` (Case 3 Ref to raw terminal), `@:lit("$$") Dollar` (Case 1 zero-arg literal), `@:lead("${") @:trail("}") Block(expr:HxExpr)` (Case 3 recursive Ref — whitespace skipping resumes inside expressions), `@:lead("$") Ident(name:HxIdentLit)` (Case 3 Ref with lead). Branch order matters: Dollar before Block/Ident for `$$` disambiguation.
- `anyparse.grammar.haxe.HxStringLitSegment` — new `@:raw` terminal abstract with `@:re("(?:[^'\\\\$]|\\\\.)+") @:unescape("raw")`. Matches runs of literal chars + escape sequences. Inline unescape loop generated by macro using `HaxeFormat.unescapeChar`.
- `anyparse.grammar.haxe.HxExpr` — `SingleStringExpr(v:HxSingleStringLit)` changed to `SingleStringExpr(v:HxInterpString)`.
- `test/unit/HxStringSliceTest.hx` — 22 single-string tests (was 7): empty, simple, escapes, `$$`, `$ident` (5 variants), `${expr}` (2), mixed segments, `$$$name`, internal whitespace preservation, concatenation, module integration, rejections.
- **D52**: `@:raw` suppresses `skipWs` for whitespace-sensitive rules. Generalises to comments, regex literals, heredocs in future grammars. Post-processing approach (one function, one check) avoids modifying emission sites.
- **Gotcha**: metadata string arguments in Haxe are subject to interpolation — `@:lead('${')` triggers it. Must use double-quoted `@:lead("${")`.
- 1935 assertions green on neko (1890 baseline + 45 new).
- Non-deliverables: ~~`@:unescape` built-in decoder~~ (shipped in slice ν₃), `\0`/`\xNN`/`\uNNNN` hex/unicode escapes, `Block.raw` expression type annotation.

**Phase 3 @:unescape slice (slice ν₃) — what landed (2026-04-12, after slice ν₂)**:
- `anyparse.macro.FormatReader` — `FormatInfo` gains `schemaTypePath:String` field. `resolve()` stores the incoming `typePath` in the returned struct so `Lowering` can generate format-qualified `unescapeChar` calls.
- `anyparse.macro.Lowering` — `lowerTerminal` gains `@:unescape` meta support (D53). Two modes: bare `@:unescape` strips surrounding quotes via `substring(1, len-1)` then walks and unescapes; `@:unescape("raw")` skips the strip. Both emit an inline loop calling `FormatClass.instance.unescapeChar(body, pos)` where `FormatClass` is resolved from `formatInfo.schemaTypePath`. Conflict guards: `@:unescape` + `@:decode` and `@:unescape` + `@:rawString` both produce `fatalError`. The `case 'String': decodeJsonString(_matched)` fallback replaced by `fatalError` requiring explicit annotation.
- `anyparse.macro.Codegen` — `decodeJsonStringField()` removed. No longer needed — escape decoding is now inline in the generated rule body via `@:unescape`.
- `anyparse.grammar.json.JStringLit` — `@:unescape` replaces implicit `decodeJsonString` fallback.
- `anyparse.grammar.haxe.HxDoubleStringLit` — `@:unescape` replaces `@:decode('...HxStringDecoder.decode')`.
- `anyparse.grammar.haxe.HxStringLitSegment` — `@:unescape("raw")` replaces `@:decode('...HxStringDecoder.decodeLiteral')`.
- `anyparse.grammar.haxe.HxStringDecoder` — DELETED. Both methods (`decode`, `decodeLiteral`) replaced by `@:unescape` inline code generation.
- **D53**: `@:unescape` generates inline walk-and-unescape loop from the `@:schema` format's `unescapeChar`. Eliminates grammar-side decoder boilerplate. `@:decode` remains for non-unescape decoders (future hex/base64 terminals).
- 1935 assertions green on neko (zero new — all existing tests validate identical behavior through the new code path).

**Non-deliverables for the skeleton slice**:
- Expressions, operators, Pratt strategy.
- ~~Function parameters~~ (shipped in slice ζ), ~~function bodies with statements~~ (basic shipped in slice η₁; void return, control-flow statements deferred).
- Modifiers (`public`, `private`, `static`, `inline`, `override`, …), `extends`/`implements`, type parameters.
- Multi-declaration modules (root is a single class, not an array of top-level decls).
- Comments, `#if/#else`, `@:meta` on user code.
- Writer generation, formatter, CLI.
- haxe-formatter corpus integration.
- Tolerant-mode codegen.

**Exit condition**: the new formatter matches or exceeds haxe-formatter's output on the user's regression corpus, runs faster, and is thread-safe (validated by running N parallel formatter instances on different files with no data races).

## Phase 4: AS3 grammar and AS3→Haxe transform

**Goal**: write the AS3 grammar and build an AS3→Haxe conversion tool on anyparse's transform framework. This replaces the ax3 tool.

**Deliverables**:
- `anyparse-grammar-as3` package with full AS3 grammar including E4X via `@:capture`/`@:match`, ASI via `@:commit`, and namespaces.
- `anyparse.transform` framework with reusable helpers: visitor, query, scope tracking, import manager, type mapping registry, library mapping registry.
- AS3→Haxe transform written as pure functions on AST. Ports the ~59 filters from ax3's fork, each becoming a declarative transform.
- CLI tool that reads AS3 source (and optionally SWC or curated Haxe extern stubs for types) and emits Haxe code via the anyparse-generated Haxe writer.
- Integration test against the user's ax3 corpus (~2000 files): same semantic output as current ax3, or better, and measurably faster.

**Exit condition**: anyparse AS3→Haxe produces output equivalent to or improved over ax3 on the full corpus, runs parallel across cores (vs ax3's 5s for single thread == 5s for 8 threads), and does not require JVM.

## Phase 5: Cross-family foundation

**Goal**: add `CurlyBraceFamilyAst` as the first family IR, and write the structural round-trip test against it. Bring the cross-family contract from theoretical to enforced.

**Deliverables**:
- `anyparse.family.curly.CurlyBraceFamilyAst` package.
- Projection from Haxe native AST to curly family IR.
- Projection from AS3 native AST to curly family IR.
- Round-trip test: `Haxe → CurlyIR → Haxe` structural equivalence.
- Round-trip test: `AS3 → CurlyIR → AS3` structural equivalence.

**Exit condition**: both round-trip tests pass. CoreIR has no curly-specific leakage.

## Phase 6: LispFamilyAst and curly↔lisp bridge

**Goal**: add `LispFamilyAst` and the bridge between curly and Lisp families. Validate the full cross-family contract.

**Deliverables**:
- `anyparse.family.lisp.LispFamilyAst`.
- First Lisp grammar — likely Clojure-subset since it's closest to curly semantics.
- `anyparse.bridge.curly-lisp` bridge package.
- Round-trip test: `Haxe → CurlyIR → LispIR → Clojure → parse → LispIR → CurlyIR → Haxe` with semantic equivalence assertion.

**Exit condition**: the cross-family contract test passes on at least one non-trivial Haxe fragment.

## Phase 7+: Additional grammars and formats

Open-ended. Each new grammar is a package. Candidates in rough priority order:

- **TypeScript** grammar for TS↔Haxe migration scenarios.
- **YAML block** grammar for config tooling.
- **XML** grammar using `@:capture`/`@:match` for tag name matching, plus `TagTreeFormat` interface.
- **MessagePack** / **CBOR** / **protobuf** as binary format examples.
- **INI**, **TOML** as simple config format examples.
- **SQL** as an example of a language with a constrained subset.

Each one validates or stress-tests a specific axis of the platform:
- TypeScript stress-tests: generics and structural types.
- YAML block stress-tests: indent strategy in production.
- XML stress-tests: capture/match, attribute vs element handling.
- MessagePack/CBOR stress-test: binary strategy with tag masks and length prefixes.

## Long-term: Haxe-on-Haxe

The aspirational endpoint. A Haxe compiler implemented in Haxe, using anyparse for the parser/writer/formatter/codegen foundation. Not a planned deliverable — a north star that informs architectural decisions so that we do not accidentally close doors to it.

See the project memory entry `long_term_goal.md` for details.

## How to update this roadmap

When a phase is completed:

1. Change its status header from its current state to "DONE" and add a date.
2. If the next phase is starting in the same session, mark it "in progress" and add a starting date.
3. If significant pivots happened, add a note to the phase about what changed and why.

When a phase is in progress:

1. Check off deliverables as they land.
2. Do not mark the phase "DONE" until the exit condition is met and tests are green.
3. If a deliverable becomes obsolete, strike it through rather than deleting it, so future readers can see what was dropped and why.

When planning a new phase not yet on this list:

1. Add it at the appropriate position with goal, deliverables, and exit condition in the same shape as existing phases.
2. Do not add phases that depend on work we have not yet validated — be honest about what must come before.
