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
- ✅ The macro entry point — `anyparse.macro.Build.buildParser(TargetType)` applied to a marker class `JValueParser`. Placing `@:build` on the enum itself was attempted first but Haxe's enum-constructor information is not available at `@:build` time on the enum — the marker-class pattern bypasses that.
- ✅ `ShapeBuilder` — worklist-based `haxe.macro.Type → ShapeTree` pass covering enum / typedef-to-anon / abstract with `@:re` / `Array<T>` / named-type Ref / std-primitive Terminal.
- ✅ `Lit` strategy — owns `@:lit` / `@:lead` / `@:trail` / `@:wrap` / `@:sep`. Multi-literal `@:lit("true","false")` for a single `Bool` field is recognised and lowered to an `Alt` of Lit nodes that map matched literal → identifier-named Bool value.
- ✅ `Re` strategy — owns `@:re`. Pairs with a per-underlying-type decoder table (`Float → Std.parseFloat`, `Int → Std.parseInt`) in Lowering. String terminals require an explicit `@:unescape`, `@:decode`, or `@:rawString` annotation.
- ✅ `Skip` strategy — owns `@:ws`. Turns on inline `skipWs(ctx)` insertion before every literal and regex match in the grammar.
- ✅ `StrategyRegistry` — topological sort by `runsAfter` / `runsBefore` with duplicate-meta detection. Runs the annotate pass in deterministic order.
- ✅ `Lowering` + `Codegen` — directly emit Haxe `Expr` for each rule's function body (using the `Empty`, `Seq`, `Alt`, `Star`, `Opt`, `Ref`, `Lit`, `Re` primitives conceptually without going through a serialized CoreIR IR) and wrap into `Field`s plus the runtime helpers (`skipWs`, `matchLit`, `expectLit`) and static `EReg` fields.
- ✅ Fast-mode-only codegen. Tolerant mode is stubbed — the Phase-1 `ParseResult`/`Node` types remain unused in generated code.
- ✅ `JValue` annotated with `@:peg` + `@:schema(JsonFormat)` + `@:ws` + per-ctor `@:lit` / `@:lead` / `@:trail` / `@:sep`. `JString(v:JStringLit)` / `JNumber(v:JNumberLit)` use transparent abstracts over `String` / `Float` so existing test literals compile unchanged.
- ✅ `JEntry` rewritten with explicit `var`-form typedef fields so that field-level `@:lead(':')` is accepted.
- ✅ `JsonParserTestBase` extracted as an abstract base; `JsonParserTest` and `JsonMacroParserTest` are thin subclasses differing only in the `parseJson` hook. `JsonMacroRoundTripTest` mirrors `JsonRoundTripTest` but parses through `JValueParser`. *(Later removed in Phase 3 slice ρ₂ when the hand-written baseline was retired; the macro parity suite was flattened into `JsonParserTest` and `JsonRoundTripTest`.)*
- ✅ 585 tests green on neko, js, and interp (the original 328 plus the macro parity and macro round-trip suites).

**Exit condition**: met. Hand-written and macro-generated JSON parsers produce identical results across the full existing corpus and the seeded-random round-trip corpus on all three targets. *(In Phase 3 slice ρ₂ the hand-written `JsonParser` was removed — the macro pipeline is the sole implementation and carries its own round-trip regression corpus.)*

**Non-deliverables for this phase** (explicitly deferred):
- Writer regeneration (`JValueWriter`) — shipped in Phase 3 slice ρ₂ together with the removal of `JsonWriter`.
- Tolerant-mode codegen.
- Pratt / Indent / Binary / Capture / Recovery strategies.
- Cross-family IR work.
- `@:decode` metadata — replaced by the closed decoder table in Phase 2; can be generalised later.
- `Build`/`Bind`/`Host`/`ExprRef`/`Decode` CoreIR primitives in the codegen path — present in `core/CoreIR.hx` as types but not consumed by the Phase 2 emitter; adopted when Phase 3 needs them.

## Phase 3: Haxe grammar and formatter replacement — in progress (2026-04-11 skeleton landed)

**Goal**: write the Haxe language grammar on anyparse and use it to build a formatter. This is the first real programming-language grammar and the first practical user-facing tool from this project.

**Deliverables**:
- 🔶 `anyparse.grammar.haxe` package (currently `src/anyparse/grammar/haxe/`, may split to a separate haxelib later) containing the Haxe grammar as `@:peg` types with metadata. **Skeleton landed**: single class declaration with `var name:Type;` and `function name():Type {}` members; `HaxeFormat` singleton; `HaxeParser` marker class driving the macro pipeline.
- ⬜ Haxe formatter CLI binary (hxcpp or neko) that takes a `.hx` file and outputs formatted Haxe.
- ⬜ Test corpus from the user's haxe-formatter fork: every regression case in that fork's commit history becomes a test case here.
- ⬜ Performance benchmark against haxe-formatter on a real Haxe codebase.

**Phase 3 skeleton — what landed (2026-04-11)**:
- `anyparse.macro.strategy.Kw` — new strategy for `@:kw("word")` with word-boundary enforcement; runs before `Lit`, writes `kw.leadText` annotation slot.
- `Codegen` — new `expectKw` helper (matchLit + word-boundary check) alongside `expectLit`.
- `Lowering` — Case 3 (single-Ref enum branch) extended with optional kw/lit lead and lit trail; Case 4 (Star enum branch) gained a no-separator loop variant; `lowerStruct` learned per-field `@:kw`/`@:trail` and a `Star<Ref>` field case that delegates to a new `emitStarFieldSteps` helper; `lowerTerminal` recognises `@:rawString` on String terminals to skip the JSON unescape path.
- `ShapeBuilder.shapeTypedef` — now sorts `AnonType.fields` by source position so typedef Seq child order matches declaration order regardless of the compiler's hash iteration (JSON happened to be alphabetically sorted in source order; HxClassDecl revealed the ordering bug).
- Grammar package `src/anyparse/grammar/haxe/`: `HaxeFormat` (TextFormat stub, known debt pending `LanguageFormat` interface), `HxIdentLit` (identifier terminal with `@:rawString`), `HxTypeRef`, `HxVarDecl`, `HxFnDecl`, `HxClassMember`, `HxClassDecl` (root typedef), `HaxeParser` marker class.
- `test/unit/HaxeFirstSliceTest.hx` — 10 tests covering empty/single/multi/mixed members, irregular whitespace, word-boundary rejection of `classy`, and other rejection cases. 621 tests green on neko/js/interp.

**Phase 3 multi-decl slice — what landed (2026-04-11, after skeleton)**:
- `anyparse.grammar.haxe.HxDecl` — single-branch enum (ClassDecl) for top-level declarations; future typedef/enum/abstract/interface branches hang off it.
- `anyparse.grammar.haxe.HxModule` — module root typedef wrapping `Array<HxDecl>` with no wrappers; drives the EOF-terminated Star loop variant in `Lowering.emitStarFieldSteps`.
- `anyparse.grammar.haxe.HaxeModuleParser` — second marker class alongside `HaxeParser`, validating that the pattern scales to multiple grammar roots in a single package.
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
- `test/unit/HxPrattSliceTest.hx` — 19 tests: each operator alone, precedence mixing (`1 + 2 * 3`, `2 * 3 + 1`, `1 + 2 * 3 + 4`), left-associativity (`1 + 2 + 3`, `10 - 3 - 2`), FloatLit with and without exponent, float-plus-int, bare-int after FloatLit rollback, `trueish` / `nullable` / `falsey` word-boundary rejections, trailing-operator rejection, ident + int, and end-to-end via HaxeModuleParser. 746 assertions green on neko/js/interp (691 baseline + 55 new).

**Phase 3 bitwise + shift + arithmetic compound-assign slice — what landed (2026-04-12, after parens + right-assoc)**:
- `anyparse.grammar.haxe.HxExpr` — 9 new binary-infix ctors added on top of the 16-operator baseline from the prior Pratt / operator-expansion / parens+right-assoc slices. Two new precedence levels inserted (shifts at prec 7, bitwise at prec 6) between the existing additive and comparison levels, forcing a mechanical renumber of `* / %` (7 → 9) and `+ -` (6 → 8). New ctors: `Shl` (`<<`), `Shr` (`>>`), `UShr` (`>>>`) at prec 7 left-assoc; `BitOr` (`|`), `BitAnd` (`&`), `BitXor` (`^`) at prec 6 left-assoc; `MulAssign` (`*=`), `DivAssign` (`/=`), `ModAssign` (`%=`) at prec 1 right-assoc. `Bit*` prefix is required because the `And` / `Or` ctor names are already claimed by `&&` / `||`.
- The slice is purely additive in the macro pipeline — zero changes to `Pratt.hx`, `Lowering.hx`, `Build.hx`, `Codegen.hx`, `ShapeBuilder.hx`. Every new ctor flows through the existing Pratt annotate + `lowerPrattLoop` path, and every shared-prefix conflict (`<<`/`<`/`<=`, `>>>`/`>>`/`>`/`>=`, `||`/`|`, `&&`/`&`, `*=`/`*`, `/=`/`/`, `%=`/`%`) is resolved by the longest-match sort (D33) already shipped in the Pratt operator expansion slice.
- `test/unit/HxBitwiseSliceTest.hx` — 20 new tests: 6 per-operator smoke, 4 cross-level precedence (add/shift, shift/bitwise, bitwise/eq, bitwise/bitwise same-level), 5 longest-match disambiguation regression guards (`<`/`<=` after adding `<<`, `>`/`>=` after adding `>>`, `>>>` vs `>>`), 2 left-assoc chains at the new prec levels, 2 rejection tests, and 1 end-to-end module through `HaxeModuleParser`.
- `test/unit/HxAssignSliceTest.hx` — 5 new tests extending the existing right-assoc corpus: 3 smoke (`*=`, `/=`, `%=`), 1 second-wave right-fold chain (`a *= b /= 1`), 1 cross-wave compound chain (`a *= b += 1`) proving the two shipping waves compose inside a single Pratt chain.
- Stale `prec 6` / `prec 7` references in doc-comments across `HxPrattSliceTest`, `HxPrattOpsTest`, and `HxAssignSliceTest` updated to the renumbered values. 946 assertions green on neko (870 baseline + 76 new).

**Phase 3 postfix slice (slice δ) — what landed (2026-04-12, after slice γ)**:
- `anyparse.macro.strategy.Postfix` — new annotate-only strategy owning `@:postfix`. Accepts both one-arg (`@:postfix('.')`) and two-arg (`@:postfix('[', ']')`) forms. Writes `postfix.op` (always) and, for the two-arg form, `postfix.close` onto the branch `ShapeNode`. Returns `null` from `lower`. Registered in `Build.hx` alongside the existing strategies. Empty `runsBefore` / `runsAfter` — `postfix.*` is a unique namespace.
- `anyparse.macro.Lowering` — three-function split when an enum has both Pratt and postfix branches. `lowerRule` now returns `[loopRule, wrapperRule, coreRule]` for such enums: `parseXxx` (Pratt loop, unchanged), `parseXxxAtom` (NEW: wrapper that calls `parseXxxAtomCore` and runs `lowerPostfixLoop` on the result), `parseXxxAtomCore` (the old `parseHxExprAtom` body — pure leaf + prefix dispatcher, renamed). For postfix-only enums (no Pratt), a two-function split emits `parseXxx` (wrapper, public entry) + `parseXxxCore`. Prefix's `recurseFnName` now targets the wrapper in both cases, so `-a.b` parses as `Neg(FieldAccess(a, b))` — postfix is applied to the prefix operand before the prefix ctor wraps it.
- `anyparse.macro.Lowering.lowerPostfixLoop` — new helper parallel to `lowerPrattLoop`. Emits `var left = coreCall; while(true) { skipWs; _matched=true; <chain>; if(!_matched) break; } return left;`. The chain dispatches on `postfix.op` via `matchLit`, sorted longest-first (D33 pattern). Three branch shapes recognised at macro time: (1) **pair-lit (call-no-args)** — one child, `postfix.close` set, emits `expectLit(close); left = Ctor(left);`; (2) **single-Ref-suffix (field access)** — two children, no `postfix.close`, emits `parseSuffix; left = Ctor(left, _suffix);`; (3) **wrap-with-recurse (index access)** — two children, `postfix.close` set, emits `parseSuffix; expectLit(close); left = Ctor(left, _suffix);`. Wrap-with-recurse calls `parseXxx` (the Pratt loop entry) when the suffix type is the same enum, so `a[b + 1]` allows arbitrary infix operators inside the brackets.
- `anyparse.macro.Lowering.lowerEnum` — signature gained explicit `recurseFnName:String` parameter (was computed internally from `atomsOnly`); the three-function split path needs to pass different names for Pratt+postfix vs postfix-only. The `atomsOnly=true` filter now excludes BOTH `pratt.prec` and `postfix.op` branches — both are operator-shaped forms owned by their respective loops.
- `anyparse.grammar.haxe.HxExpr` — three new ctors after the prefix section and before `Mul`: `@:postfix('.') FieldAccess(operand:HxExpr, field:HxIdentLit)`, `@:postfix('[', ']') IndexAccess(operand:HxExpr, index:HxExpr)`, `@:postfix('(', ')') CallNoArgs(operand:HxExpr)`. `Call(operand, args:Array<HxExpr>)` with real argument list is deliberately deferred to slice δ2 — it adds a fourth concept ("Array<Ref> suffix inside an enum-branch postfix shape") that is cleanest as a follow-up after δ1's infrastructure ships.
- `test/unit/HxPostfixSliceTest.hx` — 19 new tests: 3 per-op smoke (field/index/call), 3 left-recursion chains (`a.b.c`, `a[1][2]`, `f()()`), 4 mixed chains (`a.b[c]`, `a[b].c`, `f().x`, `a.b()` — the idiomatic method-call-on-member case), 2 prefix-over-postfix binding-tightness (`-a.b`, `!f()`), 2 postfix-over-Pratt binding-tightness (`a.b + c`, `c + a.b`), 1 nested infix inside index (`a[b + 1]`), 1 parens + postfix (`(a + b).c`), 1 end-to-end through `HaxeModuleParser`, 2 rejection (`a.;`, `a[1;`).
- **D40**: data-driven `OperatorDispatch` extraction **rejected** in slice δ. The three dispatcher shapes (prefix Case 5 in `lowerEnumBranch`, atom Cases 1-4 in the same function, postfix loop in `lowerPostfixLoop`) live at structurally different call-sites with different concerns — per-branch body inside a try/catch wrapper versus a loop over all branches operating on an accumulator. A unified abstraction would force one shape to fit three different sites. Exit criterion for revisiting: a fourth dispatcher shape landing adjacent to these three (most likely `new T(...)` or ternary `? :` in a future slice).
- **1088 assertions green on neko / js / interp** (1029 baseline + 59 new from the 19 new tests in `HxPostfixSliceTest` — most tests assert on multiple components of the parsed subtree). Non-deliverables: argument lists inside calls (δ2), ternary `? :`, `??`, `=>`, `new T(...)`.

**Phase 3 call-with-args slice (slice δ2) — what landed (2026-04-12, after slice δ)**:
- `anyparse.grammar.haxe.HxExpr` — `CallNoArgs(operand:HxExpr)` replaced with `@:postfix('(', ')') @:sep(',') Call(operand:HxExpr, args:Array<HxExpr>)`. Handles both zero-arg `f()` (empty args array) and N-arg `f(a, b, c)` through a single ctor. The `@:sep(',')` on the ctor feeds `lit.sepText` on the branch node via the Lit strategy.
- `anyparse.macro.Lowering.lowerPostfixLoop` — fourth shape variant: **Star-suffix with sep-loop**. Detects `children.length == 2 && children[1].kind == Star && close != null`. Reads `branch.annotations.get('lit.sepText')` for the separator (same source as Case 4 in `lowerEnumBranch`). Emits sep-peek array loop: peek close-char for empty list, push first element, then while-sep-consume-push-next, then `expectLit(close)`. Both sep and no-sep paths supported. Branch inserted before the existing `children.length == 2` Ref handling so Star is checked first.
- `test/unit/HxPostfixSliceTest.hx` — 5 existing tests updated (`CallNoArgs` → `Call` with empty args check), 10 new tests: single-arg, two-arg, three-arg, expression args (`f(a + 1, b * 2)`), chained calls with args (`f(1)(2)`), method call with args (`a.b(1, 2)`), whitespace tolerance, call inside index, trailing-comma rejection, and end-to-end through `HaxeModuleParser`.
- **D42**: `@:sep` on a postfix branch feeds `lowerPostfixLoop`'s Star-suffix variant. Sep literal comes from `lit.sepText` on the branch node. Third sep-loop emitter site (debt #5 at triggering threshold).
- **1143 assertions green on neko / js** (1088 baseline + 55 new from 10 new + 5 updated tests). Non-deliverables: ternary `? :`, `??`, `=>`, `new T(...)`.

**Phase 3 unary-prefix slice (slice γ) — what landed (2026-04-12, after slice β)**:
- `anyparse.macro.strategy.Prefix` — new annotate-only strategy owning `@:prefix('op')`. Single-argument form only: no precedence value, no associativity. Writes `prefix.op` onto the branch `ShapeNode` and returns `null` from `lower`. Mirrors `Pratt.hx` in structure; declares empty `runsBefore` / `runsAfter` because the namespace is unique and the strategy reads nothing other strategies produce. Registered in `Build.hx` alongside `Kw`/`Lit`/`Pratt`/`Re`/`Skip`.
- `anyparse.macro.Lowering.lowerEnum` — now computes `recurseFnName = atomsOnly ? 'parse${simple}Atom' : 'parse${simple}'` and threads it through `tryBranch` → `lowerEnumBranch` as a third parameter. Carries the name of the function currently being generated (atom for Pratt enums, whole rule for plain enums) so the new classifier case can emit a self-recursive call for prefix operands.
- `anyparse.macro.Lowering.lowerEnumBranch` — new **Case 5** at the top of the classifier, running BEFORE the existing Cases 1/2/4/3. Detects `prefix.op`, validates the branch shape (exactly one `Ref` child referencing the same enum as the rule, operator literal must not end in a word character — word-like prefix ops rejected via `Context.fatalError`). Emits `skipWs; expectLit(ctx, op); skipWs; final _operand:$returnCT = $recurseFnName(ctx); return Ctor(_operand);`. Must run before Case 3 because a prefix branch structurally matches "single `Ref`, no `@:lit`" and Case 3 would emit a body with no `expectLit`, infinite-looping. Recursion targets the current function — for Pratt-enabled enums this is the atom function, which gives `-x * 2` the correct `Mul(Neg(x), 2)` shape without any precedence parameter on `@:prefix` (prefix binds tighter than every binary by construction, not by numeric prec).
- `anyparse.grammar.haxe.HxExpr` — three new ctors after `IdentExpr` and before `Mul`: `@:prefix('-') Neg(operand:HxExpr)`, `@:prefix('!') Not(operand:HxExpr)`, `@:prefix('~') BitNot(operand:HxExpr)`. Naming follows the file's existing `Bit*` convention for bitwise-family ctors (`BitOr`/`BitAnd`/`BitXor`/`BitNot`). Atom branches remain in source order with the three prefix branches sitting after the pure atoms so regex/literal atoms (`FloatLit`/`IntLit`/`BoolLit`/`NullLit`/`ParenExpr`/`IdentExpr`) all get first attempt on input like `5` and only fall through to the prefix branches when a leading `-` / `!` / `~` blocks every leaf regex.
- `test/unit/HxPrefixSliceTest.hx` — 15 new tests: 3 per-op smoke with identifier operand (`-x`, `!x`, `~x`), 3 prefix + terminal atoms (`-5`, `-3.14`, `!true`), 3 load-bearing binding-tightness tests (`-x + 1 → Add(Neg(x), 1)`, `!x && y → And(Not(x), y)`, `~x | 1 → BitOr(BitNot(x), 1)` — these lock in the recurse-into-atom property), 2 nested same-op prefix (`--x`, `!!x`), 1 mixed-prefix (`-!x`), 1 prefix + parens (`-(x + 1)`), 1 end-to-end through `HaxeModuleParser`, 1 rejection (`var x:Int = - ;`). Helpers `parseSingleVarDecl` / `expectVarMember` remain duplicated from sibling `Hx*SliceTest` files — debt #5b tracks the extraction into a shared base.
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

**Phase 3 arrow operator + array/map literals slice (slice ξ₁) — what landed (2026-04-12, after slice ν₃)**:
- `anyparse.grammar.haxe.HxLambdaParam` — new `@:peg` typedef for lambda parameters: `name:HxIdentLit`, `@:optional @:lead(':') type:Null<HxTypeRef>`. Simpler than `HxParam` — type annotation is optional (lambda params use inference).
- `anyparse.grammar.haxe.HxParenLambda` — new `@:peg` typedef for parenthesised lambda: `@:lead('(') @:trail(')') @:sep(',') params:Array<HxLambdaParam>`, `@:lead('=>') body:HxExpr`. Sep-peek Star with close-char guard handles `()` (zero params). `expectLit('=>')` after `)` is the commit/rollback point for tryBranch.
- `anyparse.grammar.haxe.HxExpr` — three new branches:
  - `@:lead('[') @:trail(']') @:sep(',') ArrayExpr(elems:Array<HxExpr>)` — Case 4 atom for array and map literals. No conflict with postfix `IndexAccess` (`@:postfix('[', ']')`) — atom and postfix dispatch are separate loops.
  - `ParenLambdaExpr(lambda:HxParenLambda)` — Case 3 atom placed before `ParenExpr`. tryBranch tries lambda first; if `=>` absent after `)`, rolls back to ParenExpr. Handles `()`, `(x)`, `(x, y)`, `(x:Int)` forms.
  - `@:infix('=>', 0, 'Right') Arrow(left:HxExpr, right:HxExpr)` — prec-0 right-associative infix. Handles single-ident lambdas (`x => body`) and map entries (`[k => v]`). D33 longest-match sort resolves `=>` (2ch) vs `=` (1ch).
- Zero Lowering changes — all three additions use existing patterns (Case 4, Case 3, infix Pratt).
- `test/unit/HxArrowArraySliceTest.hx` — 23 tests, 78 new assertions. Covers single-ident lambda, paren lambda (zero/single/multi/typed params), array literals (empty/single/multi), map literals, IndexAccess on arrays, right-associativity, assign-vs-arrow disambiguation, ParenExpr fallback, word boundary, module integration, error rejection.
- 2013 assertions green on neko (1935 baseline + 78 new).

**Phase 3 HaxeWriter slice (slice π₁) — what landed (2026-04-12, after slice ξ₁)**:
- `anyparse.grammar.haxe.HaxeWriter` — new static class converting `HxModule` AST → Doc IR → formatted Haxe text via `Renderer.render`. First programming-language writer in anyparse. Follows `JsonWriter` static-class pattern (D57). `HaxeWriteOptions` typedef: `indent:String` + `lineWidth:Int`, defaults `\t`/`120` (D56).
- Precedence-aware parenthesization (D55): `exprToDoc(expr, contextPrec, opt)` threads a precedence context. Binary operator at prec `p` with left-assoc: left operand gets `ctxPrec = p`, right gets `p + 1`. Right-assoc: inverted. When `operatorPrec < contextPrec`, expression wrapped in parens. Constants: `PREC_NONE = -1`, `PREC_TERNARY = 1`, `PREC_POSTFIX = 10`.
- Layout policy (D58): `D.hardline()` between declarations and statements. `D.group` with `D.softline` around comma-separated lists (params, args, arrays) via shared `sepList` helper — same pattern as `JsonWriter.arrayToDoc`. Binary operators flat (no line-break wrapping in v1).
- Idempotency round-trip testing (D54): `write(parse(write(parse(source)))) == write(parse(source))`. Avoids implementing deep structural equality on 48 AST types.
- All 48 AST types and 52 `HxExpr` constructors handled. Covers 5 declaration forms, members with modifiers, 11 statement types, all expression operators, string escaping and interpolation reconstruction.
- `test/unit/HaxeWriterTest.hx` — 56 golden-file assertions: each declaration type, expression precedence/parenthesization, all statement types, string handling.
- `test/unit/HaxeRoundTripTest.hx` — 51 curated idempotency round-trip tests covering every AST node type.
- Zero changes to `Lowering.hx`, `Codegen.hx`, `Build.hx`, `ShapeBuilder.hx` — writer is independent of the macro pipeline.
- 2123 assertions green on neko/js (2013 baseline + 110 new).

**Phase 3 macro writer slice (slice ρ₁) — what landed (2026-04-13, after slice π₁)**:
- `anyparse.macro.Build.buildWriter(RootType)` macro entry point — structural inverse of `buildParser`, driven by the same ShapeBuilder + StrategyRegistry passes.
- `anyparse.macro.WriterLowering` + `anyparse.macro.WriterCodegen` — pass 3W/4W of the pipeline. Walks the ShapeTree and emits `Doc`-building `haxe.macro.Expr` for each rule; wraps rules into `Field`s; emits Doc wrapper helpers (`_dt`/`_dc`/`_dn`/`_dg`/`_dhl`/`_dsl`/`_dl`/`_de`), layout helpers (`blockBody`/`sepList`), encoding helpers (`formatFloat`/`escapeString`).
- Covers every grammar shape already supported by the parser: struct fields (`@:kw`/`@:lead`/`@:trail`/`@:optional`), enum branches (all Cases 0–5 plus Pratt infix/prefix/postfix/ternary), Star fields (block / inline / EOF / try-parse), terminals (`@:unescape`/`@:rawString`/Int/Float).
- Precedence-aware parenthesization (D64) mirroring parser-side D33: `ctxPrec` threaded through the generated writer functions; inner operator at `prec < ctxPrec` wraps in `(...)`.
- `@:raw` handling: Star fields inside `@:raw` types concatenate segments without whitespace (mirrors the parser's whitespace-skipping suppression for string interpolation).
- `HxModuleWriter` marker class — first `buildWriter` consumer. Idempotency round-trip tests via `HaxeWriterRoundTripTest`.
- 2173 assertions green on neko/js (2123 baseline + 50 new).

**Phase 3 drop-hand-written slice (slice ρ₂) — what landed (2026-04-17, after ar-format binary slice and slice ρ₁)**:
- `anyparse.grammar.json.JValueWriter` — second `Build.buildWriter` consumer, now the only JSON writer in the project.
- Removed hand-written reference implementations and their mirror tests: `JsonParser`, `JsonWriter`, `HaxeWriter`, `JsonParserTest`, `JsonParserTestBase`, `JsonWriterTest`, `JsonRoundTripTest`, `HaxeWriterTest`, `HaxeRoundTripTest`. Every grammar in the project is now macro-driven — no parallel hand-written baseline.
- `JsonMacroParserTest` / `JsonMacroRoundTripTest` renamed to `JsonParserTest` / `JsonRoundTripTest` and flattened (the `JsonParserTestBase` abstract layer lost its second subclass and was removed with it). Round-trip suite now writes via `JValueWriter` and parses via `JValueParser`, so both directions of the macro pipeline ride on the same regression corpus.
- No changes to macro pipeline internals. `WriterCodegen.publicEntry`'s current `(value, indent:Int = 4, lineWidth:Int = 120)` signature is kept unchanged — upcoming slice σ introduces the `WriteOptions` typedef and threads it through the generated writer as the replacement.
- Rationale: the hand-written parsers/writers had served as regression baselines through Phase 2 and the first half of Phase 3. With the macro pipeline proven end-to-end on JSON, Haxe, and the ar binary format, the parallel hand-written copies were net cost: every grammar change needed double-maintenance, and the "library of hand-written reference implementations" framing conflicts with the project's platform positioning.

**Phase 3 `Fast` rename slice (slice ρ₃) — what landed (2026-04-18, after slice ρ₂)**:
- `JValueFastParser` / `JValueFastWriter` / `HaxeFastParser` / `HaxeModuleFastParser` / `HxModuleFastWriter` / `ArArchiveFastParser` / `ArArchiveFastWriter` renamed to drop the `Fast` suffix. Test files `JsonFastParserTest` / `JsonFastRoundTripTest` / `HaxeFastWriterRoundTripTest` followed suit.
- Rationale: the `Fast` suffix paired with the never-shipped `Tolerant` variant as a disambiguator, but with the hand-written baseline retired in ρ₂ the `Fast` variant is the only shipped variant and the default. `Fast` remains the compile-time *mode* name (`Mode.Fast`, design principle #8); only the class-name suffix was dropped. Tolerant, when it arrives, will take the explicit suffix — matching the common library convention "common case gets the short name".
- Mechanical rename: 10 file moves, 41 reference updates across `src/` / `test/` / `docs/`. No logic changes. 1805 assertions green on neko/js/interp, baseline unchanged.

**Phase 3 `WriteOptions` infrastructure slice (slice σ) — what landed (2026-04-18, after slice ρ₃)**:
- `anyparse.format.WriteOptions` typedef (base) — `indentChar:IndentChar` (`Tab` / `Space` enum abstract in `anyparse.format.IndentChar`), `indentSize:Int`, `tabWidth:Int`, `lineWidth:Int`, `lineEnd:String`, `finalNewline:Bool`. Per-grammar options extend via struct intersection: `JValueWriteOptions = WriteOptions & {}`, `HxModuleWriteOptions = WriteOptions & {}` (empty in σ — real knobs land in τ₁/τ₂).
- Format singletons own the defaults: `JsonFormat.instance.defaultWriteOptions` (4-space indent, no final newline), `HaxeFormat.instance.defaultWriteOptions` (tab indent, 4-column tab width, final newline). The format describes the target language → it owns its default style.
- Macro meta gains a second argument: `@:build(Build.buildWriter(RootT, OptionsT))`. Binary writers still take one argument (`ArArchiveWriter` — no options apply). `Build.extractTypePath` handles the quirk where Haxe passes a null-literal `Expr` for omitted optional `?options:Expr` macro args rather than a true `null`.
- `WriterCodegen.publicEntry` signature changed: `write(value:RootT, ?options:OptionsT):String`. Body resolves `options ?? FormatPath.instance.defaultWriteOptions` once at entry; internal `writeXxx(value, opt:OptionsT[, ctxPrec])` helpers see a fully resolved, non-nullable struct. `blockBody` / `sepList` helpers accept `opt:WriteOptions` and compute per-level nest columns as `opt.indentChar == Space ? opt.indentSize : opt.tabWidth`.
- `WriterLowering` — all `macro indent` references replaced with `macro opt` (recursive rule calls, Star field helpers, postfix suffix call, `makeWriteCall`). No behavioural changes inside rule bodies; they now pass `opt` to blockBody / sepList / recursive callees instead of the old `indent:Int` scalar.
- Scope discipline: σ is infra only — zero runtime branching on new option fields. Behaviour identical to current hard-coded defaults; debts filed: **D66** renderer still emits spaces even when `indentChar=Tab` (`Renderer.render` hardcodes `" "`; true tab emission needs renderer enhancement), **D68** `lineEnd` / `finalNewline` declared but not yet honored (renderer writes `\n` hard-coded). Real option branches (`sameLine:Bool`, `trailingComma:Bool`, per-group knobs) land in τ₁ / τ₂; dogfooding `hxformat.json` through the anyparse JSON pipeline lands in τ₃.
- `test/unit/WriteOptionsTest.hx` — 9 assertions across 4 tests: both writers accept explicit options and produce output identical to the defaults path; both formats expose the expected default values. Regression anchor for the σ surface.
- 1814 assertions green on neko / js / interp (1805 baseline + 9 new).

**Phase 3 `sameLine` policies slice (slice τ₁) — what landed (2026-04-18, after slice σ)**:
- `HxModuleWriteOptions` gains three Haxe-specific `Bool` knobs — `sameLineElse`, `sameLineCatch`, `sameLineDoWhile` — corresponding to haxe-formatter's `sameLine.ifElse` / `sameLine.tryCatch` / `sameLine.doWhile`. Defaults (all `true`) live on `HaxeFormat.instance.defaultWriteOptions`, whose declared type widened from the base `WriteOptions` to `HxModuleWriteOptions` so the Haxe-specific fields are present in the defaulted struct.
- New declarative meta **`@:sameLine("flagName")`** on struct fields — wired in `HxIfStmt.elseBody`, `HxDoWhileStmt.cond`, and the `@:tryparse`-Star `HxTryCatchStmt.catches`. When present, the writer's leading separator before the field's kw/lead token becomes runtime-conditional: `opt.flagName ? _dt(' ') : _dhl()`. Without the meta the separator is a plain space (the existing D61 behaviour).
- **`WriterLowering.sameLineSeparator(child)` helper** centralises the ternary emission at three sites in `lowerStruct` / `emitWriterStarField`: non-optional kw prefix (Path A — `HxDoWhileStmt.cond`), optional Ref leading space (Path B — `HxIfStmt.elseBody`), try-parse Star per-element separator (Path C — `HxTryCatchStmt.catches`). Path C moves the separator from *between* elements to *before every* element so the first catch's leading separator matches the body→catch boundary.
- Declarative (not procedural) wiring — the meta points at a bool field by name, grammar-side authors opt individual fields into the mechanism without touching `WriterLowering`. Same shape is reused for τ₂'s `@:trailingComma` (separate slice).
- Deferred from τ₁: ~~Renderer tab-emission~~ (D66), ~~`lineEnd` / `finalNewline` honoring~~ (D68), Tolerant-mode parser options (not in scope).
- `test/unit/HxSameLineOptionsTest.hx` — 10 tests × 19 assertions: each flag tested in both states, flag independence, multi-catch coverage, default-match, and all-flags-off idempotency. 1833 assertions green on neko / js (1814 baseline + 19 new).

**Phase 3 `trailingComma` policies slice (slice τ₂) — what landed (2026-04-18, after slice τ₁)**:
- New `Doc` primitive **`IfBreak(breakDoc, flatDoc)`** — emits `breakDoc` when the enclosing `Group` lays out in break mode, `flatDoc` otherwise. Handled in both `Renderer.render` (picks branch by frame mode) and `Renderer.fitsFlat` (measures `flatDoc` because fit simulation is always flat). Structural symmetry with `Line(flat)` — both are mode-sensitive Doc atoms, but `Line` emits text in flat mode while `IfBreak` emits text in break mode.
- `HxModuleWriteOptions` gains three Haxe-specific `Bool` knobs — `trailingCommaArrays`, `trailingCommaArgs`, `trailingCommaParams` — matching haxe-formatter's `trailingComma` defaults (all `false`). Defaults live on `HaxeFormat.instance.defaultWriteOptions` alongside the τ₁ `sameLine*` flags.
- New declarative meta **`@:trailingComma("flagName")`** on struct Star fields and enum Star / postfix-Star branches — wired on `HxExpr.ArrayExpr` (arrays), `HxExpr.Call` + `HxNewExpr.args` (args), and `HxFnDecl.params` + `HxEnumCtorDecl.params` + `HxParenLambda.params` (params). Reuses the τ₁ meta-by-name idiom — grammar authors opt fields in without touching `WriterLowering`.
- **`WriterLowering.trailingCommaExpr(node)` helper** returns the `Bool`-valued Expr passed as the new `trailingComma` argument of `sepList`: `macro false` when the node has no meta, `macro opt.<flagName>` when it does. Three `sepList` callers pass it through: `lowerPostfixStar` (reads on the postfix branch), `lowerEnumStar` (reads on the enum branch), `emitWriterStarField` (reads on the struct field).
- **`sepListField` extension** — the generated `sepList` helper now takes a `trailingComma:Bool` arg; when `true`, an `IfBreak(Text(sep), Empty)` is pushed inside the Nest before the closing soft line, so the trailing `,` appears only when the group actually breaks. Flat-mode output (short lists) is byte-for-byte unchanged because `IfBreak.flatDoc = Empty`.
- `test/unit/HxTrailingCommaOptionsTest.hx` — 10 tests × 15 assertions: each flag tested in both break states, flat-mode invariance, new-args sharing `trailingCommaArgs`, flag independence, and default-match. 1848 assertions green on neko / js / interp (1833 baseline + 15 new).
- Deferred from τ₂: rest of the haxe-formatter `trailingComma` surface (type params, anon structs, enum ctor field lists outside params) lands with the grammars that introduce those constructs.

**Phase 3 `hxformat.json` loader slice (slice τ₃) — what landed (2026-04-18, after slice τ₂)**:

- First consumer of the `WriteOptions` infrastructure — closes the dogfood loop: the project's own `JValueParser` reads a real-world `hxformat.json` and maps the recognised fields into `HxModuleWriteOptions` for the project's own `HxModuleWriter`. Own parser feeds own writer through the user-facing formatter-config shape.
- `anyparse.grammar.haxe.HaxeFormatConfigLoader.loadHxFormatJson(json:String):HxModuleWriteOptions` — all-static utility, no state. Copies `HaxeFormat.instance.defaultWriteOptions`, then overwrites only fields the config explicitly sets. Empty `{}` round-trips to defaults byte-for-byte.
- Recognised key paths (exactly the knobs `HxModuleWriteOptions` currently exposes):
  - `indentation.character` — `"tab"` → `(Tab, indentSize=1)`; any string composed entirely of spaces → `(Space, indentSize=length)`; other values ignored.
  - `indentation.tabWidth` — Int → `tabWidth`.
  - `wrapping.maxLineLength` — Int → `lineWidth`.
  - `sameLine.ifElse` / `sameLine.tryCatch` / `sameLine.doWhile` — enum string; `"same"` → `true`, every other value (`"next"` / `"keep"` / `"fitLine"`) → `false`.
  - `trailingCommas.arrayLiteralDefault` / `callArgumentDefault` / `functionParameterDefault` — enum string; `"yes"` → `true`, every other value (`"no"` / `"keep"` / `"ignore"`) → `false`.
- Everything not listed is silently ignored (forward-compat). Missing fields fall back to the format singleton's defaults — the loader never raises on valid JSON.
- Design decisions (from the τ₃ session brief):
  - Mapper lives in `HaxeFormatConfigLoader`, not as a method on `HaxeFormat` — the format singleton stays pure/readonly; loading is an I/O concern bound to JSON, not a property of the format itself.
  - Structure is an explicit nested switch over JObject entries (one `apply*` helper per top-level section). Macro-driven schema generation is overkill for ~9 fields and one config format.
  - `"keep"` / `"ignore"` `trailingCommas` modes map to `false` (lossy). Debt: a `keep` mode would need the writer to see per-node "did the source have a trailing comma" annotations, which require extending the parser's AST; logged against the parser, not the loader.
- `test/unit/HaxeFormatConfigLoaderTest.hx` — 13 tests × 47 assertions: empty-object defaults, each `sameLine` flag isolated, `keep`/`fitLine` mapping, each `trailingCommas` flag isolated, `keep`/`ignore` mapping, all-spaces indentation, tab-indent keeps tabWidth, `maxLineLength`, unknown-field ignore, end-to-end `parse → load → write` asserting the configured output differs from the defaulted output at the expected sites. 1895 assertions green on neko / js / interp (1848 baseline + 47 new).
- Smoke test against the AxGord/haxe-formatter fork's actual `hxformat.json`: only `sameLine.*Body` fields are set (body-placement, not keyword-transition — outside our recognised surface), so loader output == defaults. Parses cleanly; validates the silently-ignore-unknown contract against a real file.
- Deferred from τ₃: surfacing the rest of the haxe-formatter knobs (`wrapping.*` rules, `lineEnds.*`, `emptyLines.*`, `whitespace.*`, `baseTypeHints`, `disableFormatting`, `excludes`) — each will land together with the `HxModuleWriteOptions` field that represents it, plus any renderer debt that field demands.

**Phase 3 body-placement policies slice (slice ψ₄) — what landed (2026-04-18, after slice ψ₂)**:

- Three-way body-placement policy on non-block bodies of `if`, `for`, `while`. `anyparse.format.BodyPolicy` as a format-neutral enum abstract (`Same` / `Next` / `FitLine`) so future grammars (AS3, Python, …) can reuse the same three-way shape.
- `@:bodyPolicy("flagName")` meta on bare-Ref struct fields — names a `BodyPolicy` field on the grammar's `WriteOptions` typedef; the writer dispatches on the runtime value. `HxIfStmt.thenBody` → `ifBody`, `HxIfStmt.elseBody` → `elseBody`, `HxForStmt.body` → `forBody`, `HxWhileStmt.body` → `whileBody`.
- `WriterLowering.bodyPolicyWrap(flagName, writeCall)` replaces the pre-body separator with a three-way `ESwitch`:
  - `Same` → `_dc([_dt(' '), body])` (current behaviour, fully byte-compatible).
  - `Next` → `_dn(cols, _dc([_dhl(), body]))` — unconditional hardline + one level deeper, where `cols = indentChar == Space ? indentSize : tabWidth` (same indent logic as `blockBody`).
  - `FitLine` → `_dg(_dn(cols, _dc([_dl(), body])))` — Group lets the Renderer pick flat (space + body) or break (hardline + indent + body) against `lineWidth`. Uses `_dl()` (soft line flat-as-space) not `_dhl()`.
- Case patterns on the generated `switch opt.<flagName>` are built via `MacroStringTools.toFieldExpr` so macro-time enum resolution never fires against the `BodyPolicy` abstract (one of the `enum abstract(Int)` macro gotchas logged in `feedback_haxe_macro_gotchas.md`).
- Optional-Ref branch (`HxIfStmt.elseBody`) splits the existing `_dt("else ")` into `_dt("else")` + `bodyPolicyWrap`, so `@:sameLine('sameLineElse')` still controls the `}` → `else` transition while `@:bodyPolicy('elseBody')` controls the `else` → body transition. Both metas compose cleanly on one field.
- `HxModuleWriteOptions` gains `ifBody` / `elseBody` / `forBody` / `whileBody:BodyPolicy`. `HaxeFormat.instance.defaultWriteOptions` defaults them to `Same` (current behaviour). `HaxeFormatConfigLoader` maps `sameLine.ifBody` / `elseBody` / `forBody` / `whileBody` via new `HxFormatBodyPolicy` enum abstract (`"same"` / `"next"` / `"fitLine"` / `"keep"`) — `keep` degrades to `Same` (nearest no-surprise fallback until per-node source-shape tracking exists).
- `test/unit/HaxeWriterRoundTripTest.hx` — 8 new byte-exact tests cover all three policies across `if` / `for` / `while`, plus one `elseBody=Next` + `ifBody=Same` case that proves the two separators compose independently.
- Pre-slice JS debt closed: `test/unit/HxFormatterCorpusTest.hx` replaces `Std.downcast(exception, ParseError)` (broken under strict null safety once the `#if sys` wrap in ψ₂ exposed it) with `is` + `cast`. `test-js.hxml` green again.
- Corpus sameline: **7 → 8 pass / 13 → 12 fail / 112 skip-parse / 0 skip-write**. Single net unblock is `fitline_for_long.hxtest` (a long single-statement for-body that `forBody=FitLine` correctly wraps). Most other `sameLine.*Body` fixtures carry additional blockers beyond the body-placement axis — emptyLines preservation (ω), `fitLineIfWithElse` meta-policy, `elseIf` keyword-placement, `doBody` (separate mechanic from `sameLineDoWhile`) — so they require follow-up slices layered on top of this one. 1990 assertions green on neko / js / interp.
- Explicitly **not** shipped in this slice (each its own slice):
  - `doBody` on `HxDoWhileStmt` — do-while body placement has semantics distinct from `sameLineDoWhile` (body placement vs. `while` keyword placement relative to the closing `}`). Separate knob. **Shipped as slice ψ₅.**
  - `fitLineIfWithElse` mega-policy — when an if has an else, does `fitLine` on `ifBody` stay per-body or degrade to unconditional `next`? Two cases (`fitline_if_with_else*`) gated on this.
  - `elseIf` keyword-placement (`next` vs `same` — different axis from body placement). One case.
  - Nested-control-flow inside-out break ordering (`fitline_chained_for_if_long`): `for (…) if (…) body;` where only the innermost body should break — our Group algorithm breaks outer-first. Needs either a custom fit algorithm or reshape of the Group nesting. Partial progress in this slice (offset moved from 104 to 71); case stays failing.
  - Blank-line preservation between statements (ω) — one of the two blockers on `fitline_if`.

**Phase 3 do-while body placement slice (slice ψ₅) — what landed (2026-04-18, after slice ψ₄)**:

- `@:bodyPolicy('doBody')` wired on `HxDoWhileStmt.body` (the first field of the `HxDoWhileStmt` struct) + `doBody:BodyPolicy` field on `HxModuleWriteOptions`. Default `Next` on `HaxeFormat.instance.defaultWriteOptions` — matches haxe-formatter's `sameLine.doWhileBody: @:default(Next)`. Diverges from ψ₄'s `Same` defaults: the reference formatter breaks non-block `do` bodies to the next line by default, and the corpus fixtures (`issue_63_do_while_{same,next}.hxtest`) encode that convention.
- Two coordinated `WriterLowering` changes make `@:bodyPolicy` work on a first-field bare Ref (every ψ₄ `@:bodyPolicy` consumer was non-first, so this is a new axis):
  - `lowerStruct` drops the `!isFirstField` guard in the bodyPolicy branch — `bodyPolicyWrap` now applies regardless of field position.
  - Case 3 enum-branch lowering detects via `subStructStartsWithBodyPolicy(refName)` when a sub-struct's first field is a bare Ref annotated with `@:bodyPolicy` (and no `@:kw` / `@:lead` of its own), and strips the trailing space from the parent `@:kw` lead. Without this, the parent's `_dt('do ')` would layer on top of `bodyPolicyWrap` — doubling the space in `Same` and dangling a space before the hardline in `Next` / `FitLine`.
- `bodyPolicyWrap` made kind-aware. Block-bodied values bypass the policy: when the body type's rule is an `Alt` whose branches carry `@:lead(open) @:trail(close)` on a single `Star` child (the `blockBody`-rendered shape — e.g. `BlockStmt(@:lead('{') @:trail('}'))`), an outer runtime `switch` routes those ctors to a single-space layout. Matches haxe-formatter's convention that `{ … }` stays on the same line as `do` / `if` / `while` / `for` regardless of the policy knob. Also silently fixes ψ₄'s latent bug for user-set `ifBody` / `forBody` / `whileBody = Next` with block bodies.
- `bodyPolicyWrap` is now an instance method (was static) because block-ctor pattern collection needs `shape.rules` access. Block patterns are built as `case Ctor(_, _, …)` wildcards with arity inferred from the shape; zero-arg ctors emit bare `case Ctor`. Patterns use `MacroStringTools.toFieldExpr` (like ψ₄'s policy patterns) to skip macro-time enum resolution.
- `HxFormatSameLineSection` gains `@:optional var doWhileBody:HxFormatBodyPolicy` (JSON key matches haxe-formatter's `sameLine.doWhileBody`). `HaxeFormatConfigLoader.applySameLine` maps it onto `opt.doBody` via the existing `bodyPolicyToRuntime` helper.
- `test/unit/HaxeWriterRoundTripTest.hx` — 3 new byte-exact tests: `testDoBodyPolicySame` / `testDoBodyPolicyNextAlwaysBreaks` / `testDoBodyPolicyFitLineBreaksWhenTooLong`. Mirror the ψ₄ `ifBody` / `forBody` / `whileBody` tests. All four `writeWithXBody` helpers marked `private inline` (preferences-haxe rule on thin delegation wrappers — pre-existing violation that ψ₅ inherited and closed).
- `subStructStartsWithBodyPolicy` guards against an `@:optional` first field (returns `false`) — future-proofs against a grammar that declares optional leading body.
- 1993 assertions green on neko / js / interp.
- Corpus sameline: **8 → 10 pass / 12 → 10 fail / 112 skip-parse / 0 skip-write**. Both `issue_63_do_while_same.hxtest` and `issue_63_do_while_next.hxtest` flip. The `same_next` and `all_same` variants (which explicitly set `doWhileBody: "same"` in their config) were already passing under ψ₄'s Same default; they continue to pass now via explicit config override.
- Still not shipped: `fitLineIfWithElse`, `elseIf`, nested-control-flow inside-out break ordering, blank-line preservation (ω), object-literal `:` spacing, lossy `keep` config.

**Phase 3 left-curly placement slice (slice ψ₆) — what landed (2026-04-18, after slice ψ₅)**:

- `anyparse.format.BracePlacement{Same;Next}` — format-neutral two-value enum abstract. Only two values because the generated `blockBody` already emits hardline after `{` — haxe-formatter's `Before`/`Both` collapse to `Next` for our output, and the inline `None` shape is not yet representable (would need per-node source-shape tracking). Additional values can be appended once a fixture makes them necessary.
- `@:leftCurly` writer meta (no arguments) on the four Haxe grammar Star struct fields that emit `{` through `blockBody`: `HxClassDecl.members`, `HxInterfaceDecl.members`, `HxAbstractDecl.members`, `HxFnDecl.body`. The meta carries no flag name because haxe-formatter's `lineEnds.leftCurly` is a single global knob — the writer reads `opt.leftCurly` directly. Per-category overrides (`typedefCurly`, `blockCurly`, `objectLiteralCurly`, …) would each get their own meta tag (`@:typeBrace` / `@:blockBrace` / …) with their own runtime field; collapsing meta name and field name into one tag keeps each meta tied to exactly one option field and avoids the self-referential `@:leftCurly('leftCurly')` form.
- New `WriterLowering.leftCurlySeparator(starNode)` helper (sibling of `sameLineSeparator` / `bodyPolicyWrap`). When `@:leftCurly` is present on the starNode, emits `switch opt.leftCurly { case BracePlacement.Next: _dhl(); case _: _dt(' '); }`. When absent, returns plain `_dt(' ')` — pre-ψ₆ byte-identical for every other grammar.
- One call-site change in `emitWriterStarField`'s `closeText != null && sepText == null` (blockBody) branch: `parts.push(macro _dt(' '))` → `parts.push(leftCurlySeparator(starNode))`. Guard conditions (`!isFirstField`, `isSpacedLead(openText)`) preserved. `blockBody` helper itself unchanged — all the work happens before the block emission, so the outer `_dhl()` places `{` at the outer indent while the nest inside blockBody keeps body content indented one level deeper.
- `HxModuleWriteOptions` gains `leftCurly:BracePlacement` (default `Same` on `HaxeFormat.instance.defaultWriteOptions` — mirrors haxe-formatter's `lineEnds.leftCurly: @:default(After)` and keeps pre-ψ₆ output byte-identical without an explicit override).
- `HxFormatLeftCurlyPolicy(String)` enum abstract + `HxFormatLineEndsSection` typedef (one-field for now, `@:optional var leftCurly:HxFormatLeftCurlyPolicy`). `HxFormatConfig` gains `@:optional var lineEnds:HxFormatLineEndsSection`. `HaxeFormatConfigLoader.applyLineEnds` maps `"before"`/`"both"` → `BracePlacement.Next`, `"after"`/`"none"` → `BracePlacement.Same` (lossy on `None` — inline `{ ... }` falls back to nearest no-surprise).
- Object literals (`HxObjectLit.fields`, `@:sep(',')`) go through `sepList` not `blockBody` and are NOT affected — which happens to match haxe-formatter's inline-object-literal behaviour in `issue_178` / `issue_185` (the target fixtures keep `return {a: b}` inline even with global `leftCurly: "both"`).
- `HxEnumDecl.ctors`, `HxSwitchStmt.cases`, `HxStatement.BlockStmt` also route through the `blockBody` call site but do NOT carry `@:leftCurly` — by design. No corpus fixture exercises those with `leftCurly=Next`, and ψ₅'s `bodyPolicyWrap` block-ctor special case already forces single-space layout for `BlockStmt` inside `do`/`if`/`while`/`for` bodies regardless of policy. Wiring those additional sites is a future slice if a fixture demands it.
- `test/unit/HxLeftCurlyOptionsTest.hx` — 7 new byte-substring tests: `testLeftCurlyDefaultIsSame`, `testLeftCurlySameKeepsClassBraceInline`, `testLeftCurlyNextMovesClassBrace`, `testLeftCurlyNextMovesFunctionBodyBrace`, `testLeftCurlyNextMovesInterfaceBrace`, `testLeftCurlyNextMovesAbstractBrace`, `testLeftCurlyNextBodyOnNewLineAtDeeperIndent`.
- `test/unit/HaxeFormatConfigLoaderTest.hx` — 5 new config-loader tests covering all four `HxFormatLeftCurlyPolicy` values plus an end-to-end `{"lineEnds":{"leftCurly":"both"}}` round-trip.
- Mandatory struct-literal propagation to the five `HxModuleWriteOptions` literal sites (`HaxeFormat.defaultWriteOptions`, `HaxeFormatConfigLoader.loadHxFormatJson`, `HxSameLineOptionsTest.makeOpts`, `HxTrailingCommaOptionsTest.makeOpts`, `HaxeWriterRoundTripTest.writeWithOpts`) — same pain pattern as every previous WriteOptions slice.
- 2009 assertions green on neko / js / interp.
- Corpus sameline: **10 pass / 10 fail / 112 skip-parse / 0 skip-write** — count unchanged from ψ₅, but the two target fixtures (`issue_178_return_object_literal.hxtest`, `issue_185_function_call_object_literal.hxtest`) are compound: the class/function brace diff is closed (byte-diff offset moved from position 10 to ~66 in both) but the downstream object-literal `:` spacing (`{a:b}` vs `{a: b}`) blocks the visible flip. Both fixtures will pass once slice ψ₇ closes the object-literal colon spacing. The slice is still a real net win — the brace policy plus the WriteOptions surface it adds are load-bearing for any future `lineEnds.*` expansions, and it unblocks `issue_178`/`185` for ψ₇.
- Still not shipped: `fitLineIfWithElse`, `elseIf`, nested-control-flow inside-out break ordering, blank-line preservation (ω), object-literal `:` spacing, lossy `keep` config.

**Phase 3 fitLineIfWithElse gate slice (slice ψ₁₂) — what landed (2026-04-18, after slice ω₂)**:

- Runtime gate on the `FitLine` branch of `WriterLowering.bodyPolicyWrap`: when a sibling `@:optional` field with `@:fmt(bodyPolicy(...))` exists AND the current field carries `@:fmt(fitLineIfWithElse)`, the FitLine layout becomes a runtime ternary `(opt.fitLineIfWithElse || value.$elseFieldName == null) ? _dg(_dn(cols, _dc([_dl(), body]))) : _dn(cols, _dc([_dhl(), body]))`. When either the flag is absent OR no optional-bodyPolicy sibling is discovered, FitLine is byte-identical to pre-ψ₁₂ — zero regression risk for existing callers.
- Sibling discovery happens once per struct in `lowerStruct` via a new `optionalBodyFieldName:Null<String>` pre-scan that walks `node.children` and captures the first `base.optional == true` child with `fmtReadString(c, 'bodyPolicy') != null`. Shape-based generalisation: any grammar node with a required/optional bodyPolicy pair opts in just by adding the flag to the sites it wants gated. `bodyPolicyWrap` signature gained `elseFieldName:Null<String>` param (null when current field does not carry `@:fmt(fitLineIfWithElse)` OR no sibling was found).
- Grammar sites (both in `HxIfStmt`):
  - `thenBody` — `@:fmt(bodyPolicy('ifBody'), fitLineIfWithElse)`. Required field, runtime check `value.elseBody == null` is a real lookup — if the `if` has no else clause, FitLine still applies; if an else is present, FitLine degrades to Next unless `opt.fitLineIfWithElse` is true.
  - `elseBody` — `@:fmt(sameLine('sameLineElse'), shapeAware, bodyPolicy('elseBody'), elseIf, fitLineIfWithElse)`. Optional field; emission is inside the macro-generated `if (_optVal != null)` guard, so `value.elseBody == null` trivially resolves to false — the ternary collapses to `opt.fitLineIfWithElse`. Same runtime behaviour, different constant-folding path.
- `HxModuleWriteOptions.fitLineIfWithElse:Bool` default `false` on `HaxeFormat.instance.defaultWriteOptions` — matches haxe-formatter's `sameLine.fitLineIfWithElse: @:default(false)`. First boolean non-enum knob on the SameLine section.
- `HxFormatSameLineSection` gains `@:optional var fitLineIfWithElse:Bool`. `HaxeFormatConfigLoader.applySameLine` copies the Bool directly onto `opt.fitLineIfWithElse` (no enum-to-runtime mapping needed, unlike every prior SameLine knob). Unknown values in `sameLine.fitLineIfWithElse` (e.g. a string instead of a Bool) fall through the optional-field miss path and keep the default.
- Ten struct-literal propagation sites across seven files updated with `fitLineIfWithElse: base.fitLineIfWithElse` (`HaxeFormat.defaultWriteOptions`, `HaxeFormatConfigLoader.loadHxFormatJson`, `HxSameLineOptionsTest` × 2, `HxElseIfOptionsTest` × 2, `HxTrailingCommaOptionsTest`, `HxLeftCurlyOptionsTest`, `HxObjectFieldColonOptionsTest`, `HaxeWriterRoundTripTest`). Same σ/τ₁/τ₂/ψ₄/ψ₅/ψ₆/ψ₇/ψ₈ pain pattern persists.
- `test/unit/HaxeFormatConfigLoaderTest.hx` — 3 new config-loader tests covering the Bool knob: `testSameLineFitLineIfWithElseDefaultsToFalse`, `testSameLineFitLineIfWithElseTrueMapsToTrue`, `testSameLineFitLineIfWithElseFalseMapsToFalse`. No new end-to-end tests — existing corpus fixtures (`fitline_if_with_else.hxtest`, `fitline_if_with_else_allowed.hxtest`) already cover the integration path.
- 2063 assertions green on neko / js / interp.
- Corpus sameline: **16 pass / 4 fail / 112 skip-parse / 0 skip-write** — count unchanged from ω₂ baseline. The target fixture `fitline_if_with_else.hxtest` turned out to be compound with emptyLines preservation: the ψ₁₂ degradation half is closed (byte-diff offset advanced from the first-if fitting position to offset 82 where the blank line between two ifs is missing, `|exp.len - act.len| = 1` = one missing newline between the two `if`s) but the downstream blank-line-dropped-at-parse-time blocks the visible flip. The fixture will pass once ω-emptyLines lands. `fitline_if_with_else_allowed.hxtest` was already passing under the pre-ψ₁₂ default — `opt.fitLineIfWithElse=true` makes the gate trivially return fitLayout, byte-identical to pre-ψ₁₂ behaviour for that explicit-true config.
- Follow-up to `feedback_byte_diff_first_not_only.md`: the ω₂-era handoff brief predicted `fitline_if_with_else` would flip with ψ₁₂ alone — under-specified the compound nature. Post-implementation diff inspection confirmed two axes (fitLineIfWithElse + emptyLines), same compound-fixture pattern as ψ₆ on `issue_178`/`185`. Recorded as re-application of the existing lesson.
- Still not shipped: `elseIf.keep` lossy policy, nested-control-flow inside-out break ordering, blank-line preservation (ω), lossy `keep` config.

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
