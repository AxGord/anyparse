package anyparse.grammar.haxe;

import anyparse.format.BodyPolicy;
import anyparse.format.BracePlacement;
import anyparse.format.CommentEmptyLinesPolicy;
import anyparse.format.EmptyCurly;
import anyparse.format.KeepEmptyLinesPolicy;
import anyparse.format.KeywordPlacement;
import anyparse.format.MetadataLineEndPolicy;
import anyparse.format.RightCurlyPlacement;
import anyparse.format.SameLinePolicy;
import anyparse.format.WhitespacePolicy;
import anyparse.format.WriteOptions;
import anyparse.format.wrap.WrapRules;
import anyparse.grammar.haxe.format.HxBetweenImportsLevel;

/**
 * Write options specific to the Haxe module grammar (`HxModule`).
 *
 * Haxe-specific knobs are mixed into the base `WriteOptions` shape via
 * struct intersection so the macro-generated writer sees a fully
 * populated struct at runtime.
 *
 * Fields added in slice τ₁ (same-line policies), promoted to
 * `SameLinePolicy` in slice ω-keep-policy so `Keep` can drive source-
 * shape preservation alongside the flat `Same`/`Next` choices:
 *  - `sameLineElse` — placement of `else` relative to the preceding
 *    `}`. `Same` emits `} else {` on one line. `Next` moves `else`
 *    to the next line at the current indent (`}\n\telse {`). `Keep`
 *    dispatches at runtime from the trivia-mode parser's captured
 *    `elseBodyBeforeKwNewline` slot; in plain mode `Keep` degrades
 *    to `Same`.
 *  - `sameLineCatch` — same three-way shape for `} catch (...)`.
 *  - `sameLineDoWhile` — same three-way shape for the closing
 *    `while (...)` of a `do … while (…)` loop.
 *  - `sameLineExpressionElse` (ω-expr-else-sameline) — placement of
 *    `else` relative to the preceding token when `else` is the
 *    optional kw of an expression-position `if` (`HxIfExpr.elseBranch`).
 *    Distinct from `sameLineElse`, which governs the statement-level
 *    construct's body. Default `Same` (space) preserves the pre-slice
 *    hardcoded behaviour. JSON `sameLine.expressionIf` fans the
 *    same value into both the BodyPolicy channel (gated to Keep/Same)
 *    AND this knob (ungated; Next maps to Keep, see loader doc). Keep
 *    consults the synth `elseBranchBeforeKwNewline` slot, which is
 *    computed against the preceding field's last non-whitespace
 *    position via `_prevEnd` scan-back (see `Lowering.hx`
 *    ω-prev-content-end) so trailing whitespace consumed by Pratt's
 *    tail loop does not falsify the slot.
 *
 * Fields added in slice τ₂ (trailing-comma policies):
 *  - `trailingCommaArrays` — when `true`, array literals that break
 *    across multiple lines emit a trailing `,` after the last element.
 *  - `trailingCommaArgs` — same policy for call argument lists
 *    (including `new T(...)` constructor calls).
 *  - `trailingCommaParams` — same policy for function / enum ctor /
 *    parenthesised-lambda parameter lists.
 *  - `trailingCommaObjectLits` (slice ω-objectlit-trailing-comma) —
 *    same policy for object literal field lists. Default `false`. JSON
 *    key `trailingCommas.objectLiteralDefault` mirrors the sibling
 *    `arrayLiteralDefault` / `callArgumentDefault` /
 *    `functionParameterDefault` keys; haxe-formatter upstream does not
 *    expose this knob (preserves source) so the JSON key is anyparse-
 *    specific. Capability foundation for future
 *    `metadata-prefixed objectLit` rules in `HxMetaExpr` writers.
 *
 * Trailing-comma flags have no effect when the list fits on one line:
 * the trailing `,` is emitted only when the enclosing Group lays out
 * in break mode (via the `IfBreak` Doc primitive).
 *
 * Fields added in slice ψ₄ (body-placement policies):
 *  - `ifBody` — placement of the then-branch body when it is not a
 *    `{}` block. `Same` keeps `if (cond) body;` on one line (the
 *    current behaviour). `Next` always pushes the body to the next
 *    line at one indent level deeper. `FitLine` keeps flat if it
 *    fits within `lineWidth`, otherwise breaks to the next line.
 *  - `elseBody` — same policy for the else-branch body.
 *  - `forBody` — same policy for `for (…) body`.
 *  - `whileBody` — same policy for `while (…) body`.
 *
 * Field added in slice ψ₅ (do-while body placement):
 *  - `doBody` — same three-way policy for the body of `do body while
 *    (…);`. Default is `Next` (matches haxe-formatter's
 *    `sameLine.doWhileBody` default) — non-block bodies move to the
 *    next line unless explicitly overridden via `hxformat.json`. The
 *    other `*Body` fields default to `Same` to preserve pre-ψ₄ byte-
 *    identical output; do-while diverges because the corpus reference
 *    (`sameLine.doWhileBody: next`) expects the break by default.
 *
 * Field added in slice ω-catch-body:
 *  - `catchBody` — same three-way `BodyPolicy` knob shape as
 *    `ifBody` / `forBody` / `whileBody` / `doBody`, gating the
 *    separator between the `)` of the catch clause's `(name:Type)`
 *    header and its body at `HxCatchClause.body`. `Same` keeps
 *    `} catch (e:T) body;` flat. `Next` always pushes the body to
 *    the next line at one indent level deeper. `FitLine` keeps it
 *    flat when it fits within `lineWidth`, otherwise breaks. Block
 *    bodies (`{ … }`) are shape-aware — the typical
 *    `} catch (e:T) { … }` keeps the inline space regardless of the
 *    policy.
 *
 * Field added in slice ω-tryBody:
 *  - `tryBody` — same three-way `BodyPolicy` knob shape as
 *    `catchBody`, gating the body-placement axis at
 *    `HxTryCatchStmt.body`. Default `Next` matches upstream
 *    haxe-formatter's `sameLine.tryBody: @:default(next)`. `Next`
 *    always pushes the non-block body to the next line; `Same`
 *    keeps it inline (`try a();`); `FitLine` fits-or-breaks;
 *    `Keep` preserves source. Architecturally orthogonal to `tryPolicy`:
 *    `tryPolicy` controls the inline whitespace right after the
 *    `try` keyword (`try{` vs `try {`), `tryBody` controls whether
 *    the body sits on the same line at all. They compose at runtime
 *    via the `kwOwnsInlineSpace` mode in `WriterLowering.bodyPolicyWrap`
 *    — `HxTryCatchStmt.body` carries `@:fmt(bodyPolicy('tryBody'),
 *    kwPolicy('tryPolicy'))` so the `Same` inline gap routes through
 *    `opt.tryPolicy` (after/both → space, none/before → empty) rather
 *    than the legacy fixed `_dt(' ')`. Block bodies (`{ … }`) are
 *    shape-aware — the leftCurly placement still wins for the brace
 *    position (`leftCurly=Next` → `try\n{` regardless of `tryBody`).
 *
 * Field added in slice ω-untyped-body-policy:
 *  - `untypedBody` — three-way `BodyPolicy` knob shape gating the
 *    parent→`untyped` separator at `HxFnBody.UntypedBlockBody`
 *    (`function f():T untyped { … }`). `Same` (default — matches
 *    haxe-formatter's `sameLine.untypedBody: @:default(Same)`) cuddles
 *    the kw inline (`function f():T untyped { … }`). `Next` pushes
 *    `untyped` to its own line at one indent level deeper
 *    (`function f():T\n\tuntyped { … }`). `FitLine` keeps it flat when
 *    it fits within `lineWidth`, otherwise breaks. `Keep` preserves
 *    the source layout. Consumed via branch-level
 *    `@:fmt(bodyPolicy('untypedBody'))` on `HxFnBody.UntypedBlockBody`;
 *    the wrap fires inside the single-Ref Case 3 path so the inner
 *    `HxUntypedFnBody` Seq (kw + `HxFnBlock`) provides `untyped { … }`
 *    as `subCall` and `bodyPolicyWrap` prepends the runtime-switched
 *    separator before it. The parent `HxFnDecl.body` Ref-field's
 *    leftCurly Case 5 routes `UntypedBlockBody` through
 *    `spacePrefixCtors` + `ctorHasBodyPolicy` (=> `_de()` separator)
 *    so the wrap is the sole source of the kw-leading transition.
 *    Mirrors haxe-formatter's `markUntyped` (MarkSameLine.hx:1024),
 *    which only applies the knob when `untyped`'s parent token is not
 *    a Block-typed `{`. The stmt-level form
 *    `HxStatement.UntypedBlockStmt` (incl. `try untyped { … }` and
 *    block-stmt `{ untyped { … } }`) deliberately does NOT consume
 *    this knob in this slice — a stmt-level wrap stacks with parent
 *    body-policy / block-stmt separators (double space, spurious
 *    blank line, trailing space before hardline). Stmt-context
 *    handling is a follow-up slice that suppresses the parent wrap
 *    when the inner ctor is `UntypedBlockStmt`.
 *
 * Field added in slice ω-functionBody-policy:
 *  - `functionBody` — three-way `BodyPolicy` knob shape gating the
 *    body-placement axis at `HxFnBody.ExprBody` (`function f() expr;`,
 *    excluding the brace-bearing `BlockBody` and the `;`-only `NoBody`).
 *    `Next` (default) pushes the body onto the next line at one
 *    indent level deeper, matching upstream haxe-formatter's
 *    `sameLine.functionBody: @:default(Next)`; `Same` keeps
 *    `function f() expr;` inline with a single space. `FitLine` and
 *    `Keep` degrade to `Next`. The knob is consumed via ctor-level
 *    `@:fmt(bodyPolicy('functionBody'))` on `HxFnBody.ExprBody`; the
 *    parent `HxFnDecl.body` Case 5 (Ref + `@:fmt(leftCurly)`)
 *    suppresses its fixed `_dt(' ')` separator for ctors carrying
 *    `@:fmt(bodyPolicy(...))` so the wrap inside the sub-rule writer
 *    fully owns the kw-to-body separator. Users opt into the inline
 *    form via `"sameLine": { "functionBody": "same" }`.
 *
 * Fields added in slice ω-expr-body-keep:
 *  - `expressionIfBody` / `expressionElseBody` / `expressionForBody`
 *    — `BodyPolicy` knobs gating the body-placement axis at the
 *    expression-position counterparts of `if`/`for` (the `HxIfExpr` /
 *    `HxForExpr` typedefs that drive array comprehensions and any
 *    value-position `if`/`for`). All three default to `Keep` so the
 *    writer preserves source layout — matching upstream haxe-formatter's
 *    `sameLine.expressionIf: @:default(Keep)` semantics. Statement-
 *    level forms keep their separate `ifBody` / `elseBody` / `forBody`
 *    knobs (default `Next`) — the divergence is intentional: stmt
 *    bodies almost always break to the next line, expression bodies
 *    almost always stay flat unless the source had them broken.
 *    `Keep` reads the source-shape signal off the existing
 *    `<field>BeforeNewline:Bool` synth slot (created on bare-non-first
 *    Refs by `TriviaTypeSynth`); plain mode (no slot) degrades to
 *    `Same`. `Same` / `Next` / `FitLine` work the same as on the
 *    statement-level knobs. JSON: a single `sameLine.expressionIf`
 *    key fans out into all three knobs (haxe-formatter exposes only
 *    one config key for the trio); programmatic users can set the
 *    three independently.
 *
 * Field added in slice ω-expression-if-with-blocks:
 *  - `expressionIfWithBlocks` — `Bool` knob (default `false`) gating
 *    inline collapse of `BlockExpr` bodies on `HxIfExpr.thenBranch` /
 *    `HxIfExpr.elseBranch`. When `true` AND the runtime body ctor is
 *    `BlockExpr`, the writer wraps the body's `Doc` in `D.flatten(…)`
 *    — collapsing `{<hardline>stmt;<hardline>}` to `{stmt;}` regardless
 *    of width. Mirrors fork's `sameLine.expressionIfWithBlocks: false`
 *    knob (`MarkSameLine.markBody(token, policy, includeBrOpen=true)`
 *    routing on `BrOpen` block bodies → `markBlockBody` collapse).
 *    Wired via `@:fmt(inlineBlockBodyIfFlag('expressionIfWithBlocks'))`
 *    on both branch fields; flag-false fall-through preserves the
 *    existing `bodyPolicy('expressionIfBody'/'expressionElseBody')`
 *    cascade unchanged.
 *
 * Fields added in slice ω-case-body-policy:
 *  - `caseBody` — `BodyPolicy` knob gating the body-placement axis at
 *    `HxCaseBranch.body` / `HxDefaultBranch.stmts` for switch-as-
 *    statement contexts. `Same` collapses a single-stmt body onto the
 *    case header line (`case X: foo();`); `Next` (default) keeps the
 *    multiline `case X:\n\tfoo();` shape. `Keep` (added in slice
 *    ω-case-body-keep) reads `Trivial<T>.newlineBefore` of the body's
 *    first element to flatten only when the source had the stmt on
 *    the same line as `:`. `FitLine` degrades to `Next`. Multi-stmt
 *    bodies always stay multiline regardless of the knob.
 *  - `expressionCase` — same shape, drives the same Star body but is
 *    a sibling JSON key in `hxformat.json`. Default flipped to `Keep`
 *    in slice ω-expression-case-keep-default (2026-05-03), matching
 *    the spirit of haxe-formatter's upstream `Same` default while
 *    avoiding the VarStmt `@:trailOpt(';')` cascade that an
 *    unconditional flatten would trigger. Conceptually distinguishes
 *    expression-context switches (`var x = switch ... { case Y: 1; }`)
 *    from statement-context switches; the runtime ORs both knobs (any
 *    non-`Next`/non-`FitLine` value can trigger flat) because no
 *    fixture sets diverging values for the two contexts. AST-level
 *    threading of expr-vs-stmt context is deferred until a fixture
 *    demands it.
 *
 * Field added in slice ω-throw-body:
 *  - `throwBody` — same `BodyPolicy` knob shape as `returnBody`,
 *    gating the separator between the `throw` keyword and its value
 *    expression at `HxStatement.ThrowStmt`. `Same` (default) keeps
 *    `throw value;` flat regardless of length; `Next` always pushes
 *    the value to the next line; `FitLine` keeps it flat when it
 *    fits within `lineWidth`, otherwise breaks; `Keep` preserves
 *    the source layout. Default flipped from `FitLine` to `Same` in
 *    slice ω-throw-body-same-default — haxe-formatter has no
 *    `throwBody` knob and leaves `throw <expr>` inline regardless of
 *    length, so `Same` matches upstream byte-for-byte while letting
 *    long chain/string-concat values wrap via their own internal
 *    fill rules instead of breaking at the kw boundary. The JSON
 *    loader still does not parse a `sameLine.throwBody` key from
 *    `hxformat.json`; the runtime knob exists for users constructing
 *    `HxModuleWriteOptions` programmatically.
 *
 * Field added in slice ω-return-body:
 *  - `returnBody` — same `BodyPolicy` knob shape as `ifBody` /
 *    `forBody` / `whileBody` / `doBody`, gating the separator between
 *    the `return` keyword and its value expression. Consumed by
 *    `HxStatement.ReturnStmt` only (the void-return variant has no
 *    value to wrap). `Same` keeps `return value;` flat. `Next` always
 *    pushes the value to the next line at one indent level deeper.
 *    `FitLine` (default) keeps it flat when it fits within `lineWidth`,
 *    otherwise breaks — corresponds to haxe-formatter's effective
 *    `sameLine.returnBody: @:default(Same)` semantics, where their
 *    `Same` wraps long values via a separate `wrapping.maxLineLength`
 *    pass. `Keep` preserves the source layout. `returnBodySingleLine`
 *    in `hxformat.json` (refining the policy for single-line bodies)
 *    is a separate axis not yet exposed; its 3-way value is silently
 *    dropped.
 *
 * Policies apply only to non-block bodies: a block body (`{ … }`)
 * carries its own hardlines from `blockBody`, so the separator before
 * `{` is always a single space regardless of the policy.
 *
 * Field added in slice ψ₆ (left-curly placement):
 *  - `leftCurly` — placement of block-opening `{` at every grammar
 *    site tagged with `@:fmt(leftCurly)`. `Same` keeps `{` on
 *    the same line as the preceding token separated by a single space
 *    (the current default). `Next` emits `{` on the next line at the
 *    current indent level, producing the Allman-style layout
 *    (`class Main\n{`). Only two values are exposed — haxe-formatter's
 *    `Before` / `Both` collapse to `Next` for our output, and the
 *    inline `None` shape is not yet supported.
 *
 * Field added in slice ω-empty-curly-break:
 *  - `emptyCurly` — `EmptyCurly` knob driving the empty-body
 *    layout at every grammar site tagged with `@:fmt(emptyCurlyBreak)`.
 *    `Same` (default) keeps empty bodies flat (`class C {}`,
 *    `function f() {}`). `Break` emits empty bodies across two lines
 *    with `}` on its own line at the parent's indent (`class C {\n}`).
 *    Mirrors haxe-formatter's `lineEnds.emptyCurly: same|break`.
 *    Override semantics, not floor: source-blank-line content between
 *    the open and close lit is irrelevant — the runtime decision is
 *    purely opt-driven for empty Stars.
 *
 * Field added in slice ω-objectlit-leftCurly:
 *  - `objectLiteralLeftCurly` — per-construct `BracePlacement` knob
 *    for `HxObjectLit.fields` (`@:fmt(leftCurly('objectLiteralLeftCurly'))`).
 *    Mirrors haxe-formatter's `lineEnds.objectLiteralCurly.leftCurly`
 *    sub-section. Default `Same` keeps object literal braces cuddled.
 *    The loader cascades global `lineEnds.leftCurly` into this knob
 *    (slice ω-objectlit-leftCurly-cascade — was rejected pre-cascade
 *    because of regressions on short literals; resolved by wiring
 *    leftCurly emission into `WrapList.emit`'s `(leadFlat, leadBreak)`
 *    so the wrap engine's flat/break decision picks cuddled vs Allman
 *    per literal). Per-construct sub-key
 *    `lineEnds.objectLiteralCurly.leftCurly` overrides the cascade.
 *
 * Field added in slice ω-anontype-left-curly:
 *  - `anonTypeLeftCurly` — per-construct `BracePlacement` knob for
 *    `HxType.Anon.fields` (`@:fmt(leftCurly('anonTypeLeftCurly'))`).
 *    Default `Same` keeps anon-type braces cuddled. The loader cascades
 *    global `lineEnds.leftCurly` into this knob (same pattern as
 *    `objectLiteralLeftCurly`). With `Next`, typedef RHS anon-types
 *    emit `typedef Foo =\n{ ... }` and inner var-type anons emit
 *    `var a:\n\t{ ... }`, matching haxe-formatter's
 *    `MarkLineEnds.getCurlyPolicy(AnonType)` precedence.
 *
 * Field added in slice ω-anonfunction-left-curly:
 *  - `anonFunctionLeftCurly` — per-construct `BracePlacement` knob for
 *    `HxFnExpr.body` (`@:fmt(leftCurly('anonFunctionLeftCurly'))`).
 *    Default `Same` keeps anon-function expression braces cuddled
 *    (`function() {…}`). With `Next`, the brace flips to Allman
 *    (`function()\n{…}`). The loader cascades global `lineEnds.leftCurly`
 *    into this knob (same pattern as `objectLiteralLeftCurly` /
 *    `anonTypeLeftCurly`); per-construct sub-key
 *    `lineEnds.anonFunctionCurly.leftCurly` overrides the cascade.
 *    Mirrors haxe-formatter's `MarkLineEnds.getCurlyPolicy(AnonymousFunction)`
 *    precedence. Arrow-lambda body (`() -> {…}`) is NOT covered by this
 *    knob — the lambda body is `HxExpr.BlockExpr` which uses the global
 *    `leftCurly`; per-context routing through the lambda parent is a
 *    follow-up slice (requires writer-side context propagation through
 *    `BlockExpr`, sister to `propagateExprPosition`).
 *
 * Field added in slice ω-anonfunction-empty-curly:
 *  - `anonFunctionEmptyCurly` — per-construct `EmptyCurly` knob for the
 *    empty-body emission inside an anonymous function expression
 *    (`function() {}` vs `function()\n{\n}`). `Same` (default) keeps the
 *    flat layout; `Break` emits the empty body across two lines with `}`
 *    on its own line at the parent's indent. The loader cascades global
 *    `lineEnds.emptyCurly` into this knob (sister pattern to
 *    `anonFunctionLeftCurly`); per-construct sub-key
 *    `lineEnds.anonFunctionCurly.emptyCurly` overrides the cascade.
 *    Routed at the `HxFnBlock.stmts` emit site via the per-call
 *    `opt._inAnonFnBody` flag — when true, the writer reads
 *    `opt.anonFunctionEmptyCurly` instead of `opt.emptyCurly` for the
 *    empty-body dispatch. `HxFnDecl` body keeps reading `opt.emptyCurly`
 *    because `_inAnonFnBody` is set ONLY by `HxFnExpr.body`'s writer
 *    call through `@:fmt(propagateAnonFnContext)` + `_setAnonFnBody`
 *    opt-fanout (sister to `propagateExprPosition` /
 *    `_setExprPosition`). Arrow-lambda body (`() -> {…}`) is NOT covered
 *    by this knob — same scope decision as `anonFunctionLeftCurly`.
 *
 * Field added in slice ω-blockcurly, broadened in slice
 * ω-blockcurly-broader:
 *  - `blockLeftCurly` — per-construct `BracePlacement` knob for plain
 *    block bodies. Consumed by `HxFnDecl.body`, `HxStatement.BlockStmt`,
 *    `HxExpr.BlockExpr`, `HxSwitchStmt.cases`, `HxSwitchStmtBare.cases`,
 *    `HxUntypedFnBody.block` — every site that fork's
 *    `MarkLineEnds.detectCurlyPolicy` classifies as `BrOpenType.Block`.
 *    Default `Same` keeps the cuddled `function f() { … }` /
 *    `if (cond) { … }` / `switch (e) { … }` layout. With `Next`,
 *    every block-brace flips to Allman (`function f()\n{`,
 *    `if (cond)\n{`, `switch (e)\n{`, etc.). The loader cascades
 *    global `lineEnds.leftCurly` into this knob (same pattern as the
 *    other per-construct leftCurly siblings); per-construct sub-key
 *    `lineEnds.blockCurly.leftCurly` overrides the cascade. Mirrors
 *    haxe-formatter's `detectCurlyPolicy(Block)` precedence —
 *    `anonFunctionCurly` (function-expression / arrow-lambda body) and
 *    the type-shape sub-categories (`anonTypeCurly`,
 *    `objectLiteralCurly`, `typedefCurly`) take precedence over
 *    `blockCurly` for their respective brace contexts.
 *
 * Field added in slice ω-blockempty:
 *  - `blockEmptyCurly` — per-construct `EmptyCurly` knob for the
 *    empty-body emission of plain block bodies (`if (x) {}`, an empty
 *    `{ }` block, `switch (e) {}`, etc.). `Same` (default) keeps
 *    the flat `{}` layout; `Break` emits the body across two lines with
 *    `}` on its own line at the parent's indent (`{\n}`). The loader
 *    cascades global `lineEnds.emptyCurly` into this knob (sister
 *    pattern to `anonFunctionEmptyCurly`); per-construct sub-key
 *    `lineEnds.blockCurly.emptyCurly` overrides the cascade. Consumed
 *    by `HxStatement.BlockStmt`, `HxExpr.BlockExpr`,
 *    `HxSwitchStmt.cases`, `HxSwitchStmtBare.cases` via the
 *    `@:fmt(emptyCurlyBreak('blockEmptyCurly'))` call-form flag — the
 *    bare `@:fmt(emptyCurlyBreak)` form keeps the pre-slice dispatch
 *    (`_inAnonFnBody` selecting between `anonFunctionEmptyCurly` and
 *    global `emptyCurly`) and remains the path used by `HxFnBlock.stmts`
 *    and class / interface / abstract member-Star bodies. Mirrors
 *    haxe-formatter's `MarkLineEnds.detectCurlyPolicy(Block).emptyCurly`
 *    precedence.
 *
 * Field added in slice ω-blockright-curly:
 *  - `blockRightCurly` — per-construct `RightCurlyPlacement` knob
 *    gating the hardline emitted immediately before `}` for plain
 *    block bodies. `Same` (default) keeps the standard layout with
 *    the close on its own line; `Inline` drops the before-close
 *    hardline so the brace glues to the last body token (`{ body }`).
 *    The loader cascades global `lineEnds.rightCurly` into this knob;
 *    per-construct sub-key `lineEnds.blockCurly.rightCurly` overrides
 *    the cascade. Consumed by `HxStatement.BlockStmt`,
 *    `HxExpr.BlockExpr`, `HxSwitchStmt.cases`, `HxSwitchStmtBare.cases`
 *    via the `@:fmt(rightCurly('blockRightCurly'))` call-form flag.
 *    Bare-flag callers and other Star sites untouched. Mirrors
 *    haxe-formatter's `MarkLineEnds.detectCurlyPolicy(Block).rightCurly`
 *    precedence — `"before"` / `"both"` collapse to `Same` (the
 *    after-`}` newline is contributed by the outer sibling sep, not
 *    by `blockBody`), `"after"` / `"none"` collapse to `Inline`.
 *
 * Field added in slice ω-anonfunction-right-curly:
 *  - `anonFunctionRightCurly` — per-construct `RightCurlyPlacement` knob
 *    gating the hardline emitted immediately before `}` for anonymous
 *    function expression bodies (`function() { ... }` reached via
 *    `HxFnExpr.body` carrying `@:fmt(propagateAnonFnContext)`). `Same`
 *    (default) keeps the standard layout with the close on its own
 *    line; `Inline` drops the before-close hardline so the brace glues
 *    to the last body token (`function() { body }`). The loader
 *    cascades global `lineEnds.rightCurly` into this knob alongside
 *    `blockRightCurly`; per-construct sub-key
 *    `lineEnds.anonFunctionCurly.rightCurly` overrides the cascade.
 *    Consumed by `HxFnBlock.stmts` via the
 *    `@:fmt(rightCurlyAnonFnOverride('anonFunctionRightCurly'))`
 *    call-form flag — the dispatch fires only when `_inAnonFnBody=true`
 *    (anon-fn descent path), preserving pre-slice `_dhl()` for
 *    `HxFnDecl.body` (function declarations) and `HxUntypedFnBody.block`
 *    (which share `HxFnBlock`). Mirrors haxe-formatter's
 *    `MarkLineEnds.detectCurlyPolicy(AnonymousFunction).rightCurly`
 *    precedence.
 *
 * Field added in slice ω-anontype-right-curly:
 *  - `anonTypeRightCurly` — per-construct `RightCurlyPlacement` knob
 *    gating the hardline emitted immediately before `}` for anonymous
 *    type braces (`HxType.Anon.fields`). `Same` (default) keeps the
 *    standard layout with the close on its own line; `Inline` drops
 *    the before-close hardline so the brace glues to the last field
 *    (`{x:Int, y:Int}` flat or `{\n\tx:Int,\n\ty:Int}` Inline). The
 *    loader cascades global `lineEnds.rightCurly` into this knob
 *    alongside `blockRightCurly` / `anonFunctionRightCurly`;
 *    per-construct sub-key `lineEnds.anonTypeCurly.rightCurly`
 *    overrides the cascade. Consumed by `HxType.Anon` via the
 *    `@:fmt(rightCurly('anonTypeRightCurly'))` call-form flag —
 *    dispatches in `triviaSepStarExpr`'s trivia branch only; the
 *    wrap-engine branch (no per-element trivia) continues to use
 *    `WrapList.emit`'s shapes (deferred to a separate slice if a
 *    fixture demands wrap-branch Inline). Mirrors haxe-formatter's
 *    `MarkLineEnds.detectCurlyPolicy(AnonType).rightCurly` precedence.
 *
 * Field added in slice ψ₇ (object-literal colon spacing):
 *  - `objectFieldColon` — whitespace around the `:` inside an
 *    anonymous object literal (`HxObjectField.value`'s lead). `After`
 *    (default) emits `{a: 0}`, matching haxe-formatter's
 *    `whitespace.objectFieldColonPolicy: @:default(After)`. `None`
 *    keeps the tight pre-ψ₇ layout (`{a:0}`). `Before` / `Both` are
 *    exposed for completeness but uncommon in practice. The knob is
 *    scoped to `HxObjectField.value` only — type-annotation `:` on
 *    `HxVarDecl.type` / `HxParam.type` / `HxFnDecl.returnType` has its
 *    own knob (`typeHintColon`, ω-E-whitespace).
 *
 * Fields added in slice ω-E-whitespace (type-hint + paren spacing):
 *  - `typeHintColon` — whitespace around the type-annotation `:` on
 *    `HxVarDecl.type`, `HxParam.type` and `HxFnDecl.returnType`.
 *    `None` (default) keeps the tight pre-slice layout
 *    (`x:Int`, `f():Void`, matching haxe-formatter's default
 *    `whitespace.typeHintColonPolicy: @:default(None)`). `Both`
 *    emits `x : Int`, `f() : Void` (matches
 *    `whitespace.typeHintColonPolicy: "around"`). `Before` / `After`
 *    are exposed for parity with the policy shape. The knob only
 *    applies at sites tagged with `@:fmt(typeHintColon)` in the
 *    grammar; the `:` inside an object literal (ψ₇) keeps its own
 *    `objectFieldColon` knob.
 *  - `typeCheckColon` — whitespace around the `:` inside a type-check
 *    expression `(expr : Type)` (`HxECheckType.type`'s `@:lead(':')`).
 *    `Both` (default) emits `("" : String)` with surrounding spaces,
 *    matching haxe-formatter's `whitespace.typeCheckColonPolicy:
 *    @:default(Around)`. `None` keeps the tight `("":String)` form.
 *    Separate from `typeHintColon` so the type-annotation default can
 *    stay `None` (idiomatic `x:Int`) while the type-check default
 *    stays `Both` — both sites use `:` but follow opposite conventions
 *    upstream.
 *  - `funcParamParens` — whitespace before the opening `(` of a
 *    function declaration's parameter list (`HxFnDecl.params`).
 *    `None` (default) keeps the tight pre-slice layout
 *    (`function main()`). `Before` / `Both` emit a single space
 *    before the paren (`function main ()`), matching haxe-formatter's
 *    `whitespace.parenConfig.funcParamParens.openingPolicy: "before"`.
 *    `After` is exposed for parity but has no effect yet — the
 *    writer's `sepList` does not expose a post-open-paren padding
 *    point. Only `HxFnDecl.params` carries the flag — call sites,
 *    `new T(...)` args, and `(expr)` ParenExpr stay tight regardless.
 *  - `anonFuncParens` — whitespace AFTER the `function` keyword (=
 *    BEFORE the opening `(`) of an anonymous-function expression
 *    (`HxExpr.FnExpr(fn:HxFnExpr)`). `None` (default) drops the
 *    pre-slice fixed `function ` trailing space, emitting tight
 *    `function(args)…` — matching haxe-formatter's
 *    `whitespace.parenConfig.anonFuncParamParens.openingPolicy:
 *    @:default(None)` (the `auto` enum collapses to `None` here, the
 *    upstream `auto` heuristic is not modelled). `Before` / `Both`
 *    keep the space (`function (args)…`), matching `"before"`. `After`
 *    is accepted for parity but produces no space — the kw-trailing
 *    slot is the only switchable axis. Independent of `funcParamParens`
 *    so callers can keep `HxFnDecl` declarations tight while flipping
 *    anon-fn expression spacing (or vice versa).
 *  - `anonFuncParamParensKeepInnerWhenEmpty` (slice
 *    ω-anon-fn-empty-paren-inner-space) — when `true`, an empty
 *    anonymous-function parameter list emits a single inside space
 *    (`function ( ) body`); default `false` keeps the tight
 *    `function()`. Driven by haxe-formatter's
 *    `whitespace.parenConfig.anonFuncParamParens.removeInnerWhenEmpty`
 *    (inverted at the loader: `false` in JSON → `true` in opt). Read
 *    by `HxFnExpr.params`'s `@:fmt(keepInnerWhenEmpty(...))` and
 *    routed through `sepList`'s `keepInnerWhenEmpty` arg — orthogonal
 *    to the `anonFuncParens` outside-before-open knob.
 *  - `callParens` — whitespace before the opening `(` of a call
 *    expression's argument list (`HxExpr.Call.args`).
 *    `None` (default) keeps the tight pre-slice layout (`trace(x)`).
 *    `Before` / `Both` emit a single space before the paren
 *    (`trace (x)`), matching haxe-formatter's
 *    `whitespace.parenConfig.callParens.openingPolicy: "before"`.
 *    `After` is exposed for parity but has no effect yet — the
 *    writer's `sepList` does not expose a post-open-paren padding
 *    point. Only `HxExpr.Call` carries the flag — `HxFnDecl.params`
 *    keeps its own `funcParamParens` knob, `new T(...)` args and
 *    `(expr)` ParenExpr stay tight regardless.
 *  - `ifPolicy` — whitespace between the `if` keyword and the opening
 *    `(` of its condition. Consumed by `HxStatement.IfStmt` and
 *    `HxExpr.IfExpr` via `@:fmt(ifPolicy)` on the ctor (slice
 *    ω-if-policy). `After` (default) emits `if (cond)`, matching the
 *    pre-slice fixed trailing space on the `if` keyword and
 *    haxe-formatter's effective default. `Before` / `None` (mapped
 *    from `"onlyBefore"` / `"none"`) collapse the gap to `if(cond)`,
 *    matching `whitespace.ifPolicy: "onlyBefore"`. `Both` emits the
 *    same after-space as `After` — the before-`if` slot is owned by
 *    the preceding token's separator (`return`, `else`, statement
 *    boundary), not by this knob.
 *
 * Fields added in slice ω-control-flow-policies:
 *  - `forPolicy` / `whilePolicy` / `switchPolicy` — same `WhitespacePolicy`
 *    knob shape as `ifPolicy`, gating the trailing space after the
 *    corresponding control-flow keyword. `forPolicy` is consumed by
 *    `HxStatement.ForStmt` and `HxExpr.ForExpr`; `whilePolicy` by
 *    `HxStatement.WhileStmt` and `HxExpr.WhileExpr`; `switchPolicy` by
 *    all four switch ctors (parens / bare × stmt / expr). `After`
 *    (default) emits `for (...)` / `while (...)` / `switch (cond)` /
 *    `switch cond`, matching haxe-formatter's
 *    `whitespace.forPolicy` / `whilePolicy` / `switchPolicy`
 *    `@:default(After)`. `Before` / `None` collapse to `for(...)` /
 *    `while(...)` / `switch(cond)` (parens form). For the bare switch
 *    form (`switch cond { ... }`), `Before` / `None` produce
 *    `switchcond` which is a syntax error — the knob is exposed for
 *    completeness/parity but the bare form should keep the default.
 *    `Both` is currently equivalent to `After` (the before-keyword slot
 *    belongs to the preceding token's separator).
 *
 * Field added in slice ω-try-policy:
 *  - `tryPolicy` — same `WhitespacePolicy` knob shape as `ifPolicy`,
 *    gating the trailing space after the `try` keyword. Consumed by
 *    `HxStatement.TryCatchStmt` only (block-body form) via
 *    `@:fmt(tryPolicy)`. `After` (default) emits `try {`, matching
 *    the pre-slice fixed trailing space and haxe-formatter's
 *    effective default. `Before` / `None` collapse to `try{`. The
 *    bare-body sibling `TryCatchStmtBare` does NOT carry the flag —
 *    its first field's `@:fmt(bareBodyBreaks)` triggers the
 *    `stripKwTrailingSpace` predicate which gates the slot to `null`
 *    regardless of policy. `Both` is currently equivalent to `After`
 *    (the before-keyword slot belongs to the preceding token's
 *    separator).
 *
 * Field added in slice ψ₈ (else-if keyword placement):
 *  - `elseIf` — placement of the nested `if` inside an `else` clause
 *    when the else branch is itself an if statement. `Same` (default,
 *    matching haxe-formatter's `sameLine.elseIf: @:default(Same)`)
 *    keeps the `else if (...)` idiom inline on the same line as
 *    `else`, overriding the `elseBody=Next` default for the `IfStmt`
 *    ctor. `Next` moves the nested `if` to the next line at one
 *    indent level deeper (`} else\n\tif (...) {`), producing the
 *    layout exercised by `issue_11_else_if_next_line.hxtest`. The
 *    knob only affects the `IfStmt` ctor of `elseBody` — non-if
 *    branches (`ExprStmt`, `ReturnStmt`, `BlockStmt`, ...) still
 *    route through `elseBody`'s `@:fmt(bodyPolicy(...))`.
 *
 * Field added in slice ψ₁₂ (fit-line gate when else is present):
 *  - `fitLineIfWithElse` — runtime gate on the `FitLine` body policy
 *    for `if`-statement bodies (both then- and else-branch) when the
 *    enclosing `if` has an `else` clause. When `false` (default —
 *    matches haxe-formatter's `sameLine.fitLineIfWithElse:
 *    @:default(false)`) an `ifBody=FitLine` / `elseBody=FitLine`
 *    degrades to the `Next` layout (hardline + indent + body) for any
 *    `if` that carries an `else`, because fitting the two halves on
 *    separate lines with one fitted and one broken reads as
 *    inconsistent. When `true`, the `FitLine` policy applies
 *    unconditionally. The knob is wired through sites tagged with
 *    `@:fmt(fitLineIfWithElse)` in the grammar — the writer gates at
 *    macro-lower time via sibling-field introspection, so future
 *    grammar nodes with a similar then/else pair can opt in by adding
 *    the same flag without further macro changes.
 *
 * Field added in slice ω-C-empty-lines-doc:
 *  - `afterFieldsWithDocComments` — blank-line policy for the slot
 *    adjacent to a class member whose leading trivia carries at least
 *    one doc comment (leading entry prefixed with `/**`). `One`
 *    (default, matches haxe-formatter's
 *    `emptyLines.afterFieldsWithDocComments: @:default(One)`) forces
 *    exactly one blank line after the doc-commented field regardless
 *    of source — so a class with a single doc-commented function
 *    followed by a plain-commented sibling gets a blank line inserted
 *    between them even when the source had none. `Ignore` honours the
 *    captured source blank-line count only (pre-slice behaviour).
 *    `None` strips any blank line between the doc-commented field and
 *    its successor, even if the source carried one. The knob only
 *    triggers at sites tagged with
 *    `@:fmt(afterFieldsWithDocComments)` in the grammar —
 *    `HxClassDecl.members` is the only current consumer; interface /
 *    abstract / enum member bodies fall under the same axis but ship
 *    in follow-up slices when their grammar nodes land the flag.
 *
 * Field added in slice ω-C-empty-lines-between-fields:
 *  - `existingBetweenFields` — two-way policy for the blank-line slot
 *    between class members when a blank line was present in the
 *    source. `Keep` (default, matches haxe-formatter's
 *    `emptyLines.classEmptyLines.existingBetweenFields:
 *    @:default(Keep)`) honours the captured source blank-line count
 *    (pre-slice behaviour). `Remove` strips every blank line between
 *    siblings, independent of source — producing compact, zero-gap
 *    member bodies. Composes with `afterFieldsWithDocComments` on the
 *    same slot: `existingBetweenFields=Remove` drops source blanks,
 *    while `afterFieldsWithDocComments=One` can still re-insert one
 *    after a doc-commented field. The knob only triggers at sites
 *    tagged with `@:fmt(existingBetweenFields)` in the grammar —
 *    `HxClassDecl.members` is the only current consumer; interface /
 *    abstract / enum member bodies fall under the same axis but ship
 *    in follow-up slices when their grammar nodes land the flag.
 *
 * Field added in slice ω-extern-existing-between-split-leading
 * (companion to `existingBetweenFields` for extern-class scope):
 *  - `externExistingBetweenFields` — `Keep` / `Remove` policy that takes
 *    over from `existingBetweenFields` when `_classExtern` is true.
 *    Default `Keep` matches the pre-slice behaviour where the same
 *    `existingBetweenFields` value applied to both regular and extern
 *    class members. Loaded from
 *    `emptyLines.externClassEmptyLines.existingBetweenFields`. Combined
 *    with the engine's split-leading detector: `Remove` strips the
 *    inter-member source blank only when the next member's leading
 *    cluster carries a trailing `/**` doc-comment preceded by `//`
 *    line-comments (the same shape that triggers
 *    `blankBeforeFinalDocCommentInLeading`). Source blanks adjacent to
 *    members with a regular leading cluster (single `/**` or none)
 *    survive untouched, mirroring fork's behaviour for the
 *    `existingBetweenFields=Remove + afterFieldsWithDocComments=Ignore`
 *    config combo.
 *
 * Field added in slice ω-C-empty-lines-before-doc:
 *  - `beforeDocCommentEmptyLines` — blank-line policy for the slot
 *    immediately preceding a class member whose leading trivia starts
 *    with a doc comment (`/**` prefix). `One` (default, matches haxe-
 *    formatter's `emptyLines.beforeDocCommentEmptyLines:
 *    @:default(One)`) forces exactly one blank line before the doc-
 *    commented field regardless of source — so a plain-commented
 *    sibling followed by a doc-commented field gets a blank line
 *    inserted between them even when the source had none. `Ignore`
 *    honours the captured source blank-line count only (pre-slice
 *    behaviour). `None` strips any blank line before the doc-commented
 *    field, even if the source carried one. Mirrors
 *    `afterFieldsWithDocComments` on the same slot but triggers on the
 *    next sibling (`_t.leadingComments[0]` starts with `/**`) rather
 *    than the previous sibling. The knob only triggers at sites tagged
 *    with `@:fmt(beforeDocCommentEmptyLines)` in the grammar —
 *    `HxClassDecl.members` is the only current consumer; interface /
 *    abstract / enum member bodies fall under the same axis but ship
 *    in follow-up slices when their grammar nodes land the flag.
 *
 * Fields added in slice ω-interblank (inter-member blank lines):
 *  - `betweenVars` — blank-line count between two consecutive var
 *    members. Consumed only when the grammar field carries
 *    `@:fmt(interMemberBlankLines('classifierField', 'VarCtorName', 'FnCtorName'))`.
 *  - `betweenFunctions` — blank-line count between two consecutive
 *    function members.
 *  - `afterVars` — blank-line count at a var→function or
 *    function→var boundary (the first member that switches kind).
 *
 * Defaults (post ω-interblank-defaults) match haxe-formatter:
 * `betweenFunctions: 1`, `afterVars: 1`, `betweenVars: 0`. One blank
 * line is inserted between sibling functions and at var↔function
 * transitions; consecutive vars stay tight. The plumbing for all
 * three knobs landed in ω-interblank with defaults of `0` so the
 * flip could be audited independently; this slice closes that gap.
 * Any positive value currently collapses to a single blank-line
 * contribution — the emission path accepts a boolean add-blank
 * contributor per site, not a count loop. Multi-blank support is a
 * future extension.
 *
 * Kind classification happens at write time via switch on the
 * element's member-variant field, configured per grammar through the
 * `@:fmt(interMemberBlankLines('classifierField', 'VarCtorName', 'FnCtorName'))` meta on the Star
 * field (see `HxClassDecl.members`). The variant names are supplied
 * per grammar so the macro stays shape-agnostic — a different
 * grammar can map its own enum constructors onto the same Var/Fn
 * kind pair without touching the macro.
 *
 * Fields added in slice ω-iface-interblank (interface-specific
 * inter-member blank-line counts):
 *  - `interfaceBetweenVars` — blank-line count between two consecutive
 *    interface var members.
 *  - `interfaceBetweenFunctions` — blank-line count between two
 *    consecutive interface function members.
 *  - `interfaceAfterVars` — blank-line count at a var↔function boundary
 *    inside an interface body.
 *
 * Defaults are `0 / 0 / 0`, matching haxe-formatter's
 * `InterfaceFieldsEmptyLinesConfig` defaults — interface bodies stay
 * tight unless explicitly overridden via `hxformat.json`. Routed
 * through `@:fmt(interMemberBlankLines('member', 'VarMember',
 * 'FnMember', 'interfaceBetweenVars', 'interfaceBetweenFunctions',
 * 'interfaceAfterVars'))` on `HxInterfaceDecl.members`. The 6-arg
 * form selects which `opt.*` field to read at runtime; the 3-arg form
 * keeps reading the shared `betweenVars` / `betweenFunctions` /
 * `afterVars` (used by class + abstract).
 *
 * Field added in slice ω-class-static-var-cascade (instance-vs-static
 * var subdivision in `interMemberBlankLines`):
 *  - `afterStaticVars` — blank-line count emitted between an instance
 *    var and a static var (or vice versa). Default `1`, matching
 *    haxe-formatter's `emptyLines.classEmptyLines.afterStaticVars:
 *    @:default(1)`. Fires only when the grammar Star ALSO carries
 *    `@:fmt(staticVarSubdivision)` — class and abstract members opt
 *    in, interface members do not (interface bodies stay tight at the
 *    instance↔static boundary by fork convention). The cascade arm
 *    is gated by `!opt._classExtern`, so extern-class members keep
 *    the existing zero-blank invariant from
 *    `ω-extern-class-no-blanks`.
 *
 * Fields added in slice ω-class-begin-end-type (head/tail blank lines
 * inside class/interface/abstract bodies):
 *  - `beginType` — exact blank-line count emitted between the opening
 *    `{` of a type body and its first member. `0` (default, matches
 *    haxe-formatter's `emptyLines.classEmptyLines.beginType:
 *    @:default(0)`) keeps the pre-slice tight layout. Positive values
 *    insert N blank lines regardless of source.
 *  - `endType` — exact blank-line count emitted between the last member
 *    of a type body and its closing `}`. `0` (default, matches haxe-
 *    formatter's `emptyLines.classEmptyLines.endType: @:default(0)`)
 *    keeps the pre-slice tight layout.
 *  - `afterLeftCurly` — two-way policy gating source-blank preservation
 *    after the opening `{` when `beginType` is `0`. `Remove` (default,
 *    matches haxe-formatter's `emptyLines.afterLeftCurly:
 *    @:default(Remove)`) strips source blanks. `Keep` honours the
 *    captured `_t.blankBefore` of the first member. `beginType > 0`
 *    overrides this knob — the explicit count wins.
 *  - `beforeRightCurly` — two-way policy gating source-blank preservation
 *    before the closing `}` when `endType` is `0`. `Remove` (default)
 *    strips. `Keep` honours the captured trail-blank-before-close
 *    signal. `endType > 0` overrides — the explicit count wins.
 *
 * The four knobs only fire at sites tagged with `@:fmt(beginEndType)`
 * in the grammar — `HxClassDecl.members`, `HxInterfaceDecl.members`,
 * `HxAbstractDecl.members` and (since ω-enum-empty-lines)
 * `HxEnumDecl.ctors` are the current consumers; macro classes ship in
 * follow-up slices.
 *
 * Field added in slice ω-enum-empty-lines (uniform inter-element blank
 * lines for Star fields whose element type is an Alt without a
 * var/fn split — primarily `HxEnumDecl.ctors`):
 *  - `betweenEnumCtors` — exact blank-line count emitted between every
 *    pair of adjacent enum constructors. `0` (default, matches haxe-
 *    formatter's `emptyLines.enumEmptyLines.betweenFields: @:default(0)`)
 *    keeps the pre-slice tight layout. The knob only applies at sites
 *    tagged with `@:fmt(uniformBetween('betweenEnumCtors'))` in the
 *    grammar; the meta is a generic uniform-between handler — a future
 *    Alt-Star Star (e.g. typedef field list, switch-case list) can
 *    reuse it by pointing at its own opt knob.
 *
 * Field added in slice ω-typedef-assign (typedef rhs `=` spacing):
 *  - `typedefAssign` — whitespace around the `=` joining a typedef
 *    name to its right-hand-side type (`HxTypedefDecl.type`'s lead).
 *    `Both` (default) emits `typedef Foo = Bar;`, matching haxe-
 *    formatter's `whitespace.binopPolicy: @:default(Around)` for the
 *    typedef-rhs site specifically. `None` keeps the pre-slice tight
 *    layout (`typedef Foo=Bar;`); `Before` / `After` are exposed for
 *    parity with the policy shape. The knob only applies at sites
 *    tagged with `@:fmt(typedefAssign)` in the grammar — the
 *    optional-Ref `=` leads on `HxVarDecl.init` and
 *    `HxParam.defaultValue` route through the bare-optional fallback
 *    path which already emits ` = `, so this slice does not touch
 *    them. A binop-wide knob covering all Pratt-emitted operators is
 *    a separate slice.
 *
 * Field added in slice ω-typeparam-default-equals (declare-site
 * type-parameter default `=` spacing):
 *  - `typeParamDefaultEquals` — whitespace around the `=` joining a
 *    type-parameter name (or constraint) to its default type
 *    (`HxTypeParamDecl.defaultValue`'s lead). `Both` (default) emits
 *    `<T = Int>` / `<T:Foo = Bar>`, matching haxe-formatter's
 *    `whitespace.binopPolicy: @:default(Around)` for the type-param-
 *    default site. `None` keeps the tight `<T=Int>` layout, matching
 *    the `_none` corpus variant; `Before` / `After` are exposed for
 *    parity. The knob only applies at sites tagged with
 *    `@:fmt(typeParamDefaultEquals)` in the grammar; sibling
 *    optional-Ref `=` leads (`HxVarDecl.init`, `HxParam.defaultValue`)
 *    keep their bare-optional fallback emission.
 *
 * Fields added in slice ω-typeparam-spacing (type-param `<>` interior
 * spacing):
 *  - `typeParamOpen` — whitespace around the opening `<` of a type-
 *    parameter list. Applied at every grammar site tagged
 *    `@:fmt(typeParamOpen, typeParamClose)`: `HxTypeRef.params` plus
 *    the declare-site `typeParams` fields on `HxClassDecl`,
 *    `HxInterfaceDecl`, `HxAbstractDecl`, `HxEnumDecl`, `HxTypedefDecl`
 *    and `HxFnDecl`. `None` (default, matches haxe-formatter's
 *    `whitespace.typeParamOpenPolicy: @:default(None)`) keeps the
 *    pre-slice tight layout (`Array<Int>`, `class Foo<T>`).
 *    `Before`/`Both` emit a space outside before `<` (`Array <Int>`);
 *    `After`/`Both` emit a space inside after `<` (`Array< Int>`). The
 *    inside-spacing path threads through `sepList`'s `openInside` Doc
 *    arg, so any future Star site adopting the flag picks up the same
 *    semantics without further macro changes.
 *  - `typeParamClose` — whitespace around the closing `>` of a type-
 *    parameter list. `None` (default) keeps the pre-slice tight
 *    layout. `Before`/`Both` emit a space inside before `>`
 *    (`Array<Int >`); `After`/`Both` are exposed for parity but have
 *    no effect yet — the writer's `sepList` shape concatenates the
 *    close delim against whatever follows, with no outside-after-close
 *    padding point. The combined fixture
 *    `typeParamOpen=After + typeParamClose=Before` produces
 *    `Array< Int >`, matching haxe-formatter's
 *    `issue_588_anon_type_param`.
 *
 * Fields added in slice ω-anontype-braces (anonymous-structure-type
 * `{}` interior spacing):
 *  - `anonTypeBracesOpen` — whitespace around the opening `{` of an
 *    anonymous structure type (`HxType.Anon`'s `@:lead('{')`). `None`
 *    (default) keeps the pre-slice tight layout (`{x:Int}`).
 *    `After`/`Both` emit a space inside after `{` (`{ x:Int}`).
 *    `Before`/`Both` are exposed for parity with the policy shape but
 *    have no effect yet — the `lowerEnumStar` Alt-branch path has no
 *    outside-before-open padding point, so the space between the
 *    preceding token and `{` stays governed by upstream knobs
 *    (`typeHintColon`, `objectFieldColon`, etc.).
 *  - `anonTypeBracesClose` — whitespace around the closing `}` of an
 *    anonymous structure type. `None` (default) keeps the pre-slice
 *    tight layout. `Before`/`Both` emit a space inside before `}`
 *    (`{x:Int }`); `After`/`Both` are exposed for parity but have no
 *    effect yet (no outside-after-close padding point). The combined
 *    `anonTypeBracesOpen=After + anonTypeBracesClose=Before` flip
 *    produces `{ x:Int }`, matching haxe-formatter's
 *    `space_inside_anon_type_hint` fixture.
 *
 * Fields added in slice ω-objectlit-braces (object-literal `{}`
 * interior spacing — symmetric infrastructure to anonTypeBraces but
 * for `HxObjectLit.fields`'s sep-Star path):
 *  - `objectLiteralBracesOpen` — whitespace around the opening `{` of
 *    an object-literal expression (`HxObjectLit`'s `@:lead('{')`).
 *    `None` (default) keeps `{a: 1}` tight. `After`/`Both` emit a
 *    space inside after `{` (`{ a: 1}`). `Before`/`Both` are exposed
 *    for parity but have no effect yet — the regular Star path has
 *    no outside-before-open padding point at the field-access
 *    boundary used by object literals.
 *  - `objectLiteralBracesClose` — whitespace around the closing `}`
 *    of an object literal. `None` (default) keeps the tight layout.
 *    `Before`/`Both` emit a space inside before `}` (`{a: 1 }`);
 *    `After`/`Both` are exposed for parity but have no effect yet
 *    (no outside-after-close padding point). The combined
 *    `objectLiteralBracesOpen=After + objectLiteralBracesClose=Before`
 *    flip produces `{ a: 1 }`, matching haxe-formatter's
 *    `bracesConfig.objectLiteralBraces` `around` policy pair.
 *
 * Field added in slice ω-wraprules-objlit (per-construct wrap-rules
 * cascade — first consumer is `HxObjectLit.fields`):
 *  - `objectLiteralWrap` — `WrapRules` cascade driving the multi-line
 *    layout decision for object-literal fields. The macro emits a
 *    `WrapList.emit` runtime call at the `HxObjectLit.fields` Star
 *    site (tagged with `@:fmt(wrapRules('objectLiteralWrap'))`), the
 *    helper measures item count + max/total flat width, evaluates the
 *    cascade twice (`exceeds=false` + `exceeds=true`) and emits one of
 *    `NoWrap` / `OnePerLine` / `OnePerLineAfterFirst` / `FillLine`
 *    shapes — wrapping the result in `Group(IfBreak(brkDoc, flatDoc))`
 *    when the two cascade runs disagree, so the renderer's flat/break
 *    decision selects the right mode at layout time. Defaults port
 *    haxe-formatter's `wrapping.objectLiteral` rules from
 *    `default-hxformat.json`: `noWrap` if `count <= 3 ∧ ¬exceeds`,
 *    else `onePerLine` if any item ≥ 30 cols, total ≥ 60 cols, count
 *    ≥ 4, or the line exceeds `lineWidth`; default mode `noWrap`.
 *    Architecturally orthogonal to `objectLiteralBracesOpen`/`Close`
 *    (interior-space policy) — the two compose: braces decide
 *    `{a:1}` vs `{ a:1 }` spacing; `objectLiteralWrap` decides
 *    single-line vs multi-line shape.
 *
 * Field added in slice ω-wraprules-callparam (per-construct wrap-rules
 * cascade extended to the postfix-Star branch — second consumer is
 * `HxExpr.Call.args`):
 *  - `callParameterWrap` — `WrapRules` cascade driving the multi-line
 *    layout decision for function-call argument lists. The macro emits a
 *    `WrapList.emit` runtime call at the `HxExpr.Call.args` postfix-Star
 *    site (tagged with `@:fmt(wrapRules('callParameterWrap'))`),
 *    superseding the previous `@:fmt(fill)` Wadler-fillSep path. Same
 *    twice-evaluated cascade machinery as `objectLiteralWrap` —
 *    `Group(IfBreak)` is emitted when the `exceeds=false` and
 *    `exceeds=true` runs disagree, so the renderer's flat/break decision
 *    selects the right mode at layout time. Defaults port haxe-formatter's
 *    `wrapping.callParameter` rules from `default-hxformat.json`:
 *    `fillLine` if any of `count ≥ 7`, `total ≥ 140`, `anyItem ≥ 80`,
 *    `line ≥ 160`, or `exceeds`; default mode `noWrap`. Architecturally
 *    orthogonal to `callParens` (which still drives the runtime-switched
 *    space before the open `(`); the two compose: `callParens` decides
 *    `f(a)` vs `f (a)`, `callParameterWrap` decides single-line vs
 *    multi-line shape of the args list. Function parameter lists
 *    (`HxParam` Star with `@:fmt(fill, fillDoubleIndent)`) keep their
 *    own Wadler-fillSep path — a future slice will wire
 *    `functionSignature` cascade through the same engine.
 *
 * Field added in slice ω-arraylit-wraprules (per-construct wrap-rules
 * cascade extended to the enum-Case sep-Star branch — third consumer is
 * `HxExpr.ArrayExpr.elems`):
 *  - `arrayLiteralWrap` — `WrapRules` cascade driving the multi-line
 *    layout decision for array-literal element lists. The macro emits a
 *    `WrapList.emit` runtime call at the `HxExpr.ArrayExpr.elems`
 *    sep-Star site (tagged with `@:fmt(wrapRules('arrayLiteralWrap'))`).
 *    Same twice-evaluated cascade machinery as `objectLiteralWrap` /
 *    `callParameterWrap`. Defaults port haxe-formatter's
 *    `wrapping.arrayWrap` rules from `default-hxformat.json`, including
 *    the leading `hasMultilineItems → OnePerLine` rule (slice
 *    ω-flatlength-decouple-tokenwidth introduced the
 *    `HasMultilineItems` cond and decoupled item-multiline detection
 *    from width measurement). The `equalItemLengths` cond and its
 *    gated `fillLineWithLeadingBreak` rule remain skipped — none of
 *    the current corpus fixtures depend on it. Architecturally
 *    orthogonal to `trailingCommaArrays` (which still drives the
 *    optional trailing `,` after the last element on multi-line); the
 *    two compose.
 *
 * Field added in slice ω-anontype-wraprules (fourth per-construct
 * wrap-rules consumer):
 *  - `anonTypeWrap` — `WrapRules` cascade driving the multi-line layout
 *    decision for anonymous-type field lists (`{a:Int, b:String}`). The
 *    macro emits a `WrapList.emit` runtime call at the `HxType.Anon.fields`
 *    sep-Star site (tagged with `@:fmt(wrapRules('anonTypeWrap'))`).
 *    Same twice-evaluated cascade machinery as the other three
 *    per-construct wraps. Defaults port haxe-formatter's
 *    `wrapping.anonType` rules from `default-hxformat.json` — the full
 *    rule set is encodable: `itemCount<=3` + `exceedsMaxLineLength==0`
 *    keeps short anon types flat, `anyItemLength>=30` /
 *    `totalItemLength>=60` / `itemCount>=4` cascade to `OnePerLine`,
 *    `exceedsMaxLineLength==1` falls through to `FillLine`. Architecturally
 *    orthogonal to `anonTypeBracesOpen` / `anonTypeBracesClose` (which
 *    still drive the inner-brace whitespace policy on flat layout).
 *
 * Field added in slice ω-methodchain-wraprules-capability (capability/parity
 * step — knob + JSON loader only, no writer wiring yet):
 *  - `methodChainWrap` — `WrapRules` cascade describing the multi-line
 *    layout decision for `.method(args).method(args)…` postfix chains.
 *    Architecturally distinct from the four existing per-construct
 *    consumers (`objectLiteralWrap`, `callParameterWrap`, `arrayLiteralWrap`,
 *    `anonTypeWrap`): chain segments aren't a flat `Star` field on a
 *    grammar struct — they're a nested left-assoc tree
 *    `Call(FieldAccess(Call(FieldAccess(...))))` over `HxExpr`, so
 *    `WrapList.emit` can't be wired via `@:fmt(wrapRules('<field>'))` the
 *    way the other four are. This slice ships the knob + loader so a
 *    follow-up slice can wire the writer-time chain extractor + emit.
 *    No grammar `@:fmt` site reads it yet; runtime behaviour is unchanged.
 *    Defaults port haxe-formatter's `wrapping.methodChain` rules from
 *    `default-hxformat.json`, minus the leading `lineLength >= 160` rule
 *    which `WrapConditionType` does not yet model — same skip-precedent
 *    as `defaultArrayLiteralWrap`'s `hasMultilineItems` /
 *    `equalItemLengths` omissions (the runtime cascade then routes
 *    through the supported conditions: `itemCount<=3` +
 *    `exceedsMaxLineLength==0` OR `totalItemLength<=80` +
 *    `exceedsMaxLineLength==0` keeps short chains flat;
 *    `anyItemLength>=30` + `itemCount>=4`, `itemCount>=7`, or
 *    `exceedsMaxLineLength==1` cascade to `OnePerLineAfterFirst`).
 *
 * Fields added in slice ω-binop-wraprules:
 *  - `opBoolChainWrap` — `WrapRules` cascade for `||` / `&&` (haxe-
 *    formatter `opBoolChain` class). Drives multi-line break shape on
 *    long boolean chains (assignment RHS chains like `dirty = dirty
 *    \n\t|| (X) \n\t|| (Y)` — issue_187 default). The macro fires
 *    `BinaryChainEmit.emit` on the outermost `Or` / `And` ctor; the
 *    chain extractor (inlined into `WriterLowering`'s infix Pratt
 *    branch via a local `_gather` recursion over `case Or(_,_) | case
 *    And(_,_) | case _:` so the patterns resolve against the writer's
 *    paired type — `HxExpr` plain mode, `HxExprT` trivia mode) collects
 *    all same-class operands into a flat `(items, ops)` pair before
 *    one cascade evaluation per top-level chain.
 *  - `opAddSubChainWrap` — `WrapRules` cascade for `+` / `-` (haxe-
 *    formatter `opAddSubChain` class). Drives multi-line break shape
 *    on long arithmetic / string-concat chains (issue_179 long throw
 *    string concat). Same dispatch flow via the inlined `_gather`
 *    walking `case Add(_,_) | case Sub(_,_) | case _:`.
 *
 * Defaults are minimal:
 *  - `opBoolChainWrap`: single rule
 *    `ExceedsMaxLineLength → OnePerLineAfterFirst` over `defaultMode:
 *    NoWrap` (BeforeLast op placement — `\n+indent || operand`).
 *  - `opAddSubChainWrap`: single rule
 *    `ExceedsMaxLineLength → FillLine` over `defaultMode: NoWrap`
 *    (BeforeLast op placement — pack inline up to line budget, soft-
 *    line break before overflow). Different mode reflects haxe-
 *    formatter's per-class default — bool chains canonically place
 *    each operator on its own line; add/sub chains canonically pack
 *    multiple operands per line (long string concat, arithmetic).
 *
 * Mirrors haxe-formatter's fallback behaviour (the upstream WrapConfig
 * has 6 rules per cascade with `lineLength >= 140/160` + `anyItem
 * Length >= 40/60` — currently unmodelled by `WrapConditionType` —
 * but for default-config fixtures the `exceedsMaxLineLength` cond
 * fires identically to upstream's final rule). User `hxformat.json`
 * `wrapping.opBoolChain` / `opAddSubChain` configs override the
 * cascade through the loader (defaultWrap + rules).
 *
 * Slice ω-line-comment-space adds the `addLineCommentSpace:Bool` knob
 * — but to the base `WriteOptions` typedef, not here. The knob drives a
 * format-neutral writer helper (`leadingCommentDoc` /
 * `trailingCommentDoc{,Verbatim}`) that every text writer emits, so the
 * field has to live on the base struct or non-Haxe writers wouldn't
 * compile. Default `true`. Matches haxe-formatter's
 * `whitespace.addLineCommentSpace: @:default(true)`.
 *
 * Field added in slice ω-expression-try (expression-position try-catch
 * separator):
 *  - `expressionTry` — three-way same-line policy for the separator
 *    between the body of an expression-position `try` and each of its
 *    `catch` clauses (`var x = try foo() catch (_:Any) null;`).
 *    Independent of `sameLineCatch` (which keeps driving the
 *    statement-form `try { ... } catch (...)`). `Same` (default —
 *    matches haxe-formatter's `sameLine.expressionTry: @:default(Same)`)
 *    keeps the expression form on one line. `Next` pushes the body
 *    onto its own line and each `catch` keyword onto its own line as
 *    well, producing the multi-line layout exercised by
 *    `issue_509_try_catch_expression_next.hxtest`. `Keep` defers to
 *    captured source shape; in plain mode it degrades to `Same`. The
 *    knob only applies at sites tagged with
 *    `@:fmt(sameLine('expressionTry'))` in the grammar —
 *    `HxTryCatchExpr.catches` is the only current consumer; statement-
 *    form `try` keeps reading `sameLineCatch`.
 *
 * Field added in slice ω-indent-case-labels (case-label indentation
 * inside switch):
 *  - `indentCaseLabels` — when `true` (default) the `case` / `default`
 *    labels and their bodies are nested one indent level inside the
 *    `switch` body's `{ ... }`, producing
 *    `switch (e) {\n\tcase A:\n\t\tbody;\n}`. When `false` the labels
 *    are kept flush with the `switch` keyword and only the case body
 *    receives the per-case `nestBody` indent, producing
 *    `switch (e) {\ncase A:\n\tbody;\n}`. Matches haxe-formatter's
 *    `indentation.indentCaseLabels: @:default(true)`. The knob only
 *    applies at sites tagged with `@:fmt(indentCaseLabels)` in the
 *    grammar — `HxSwitchStmt.cases` and `HxSwitchStmtBare.cases`.
 *
 * Field added in slice ω-indent-objectliteral (object-literal RHS
 * indent):
 *  - `indentObjectLiteral` — when `true` (default) AND
 *    `objectLiteralLeftCurly` is `Next` (Allman), an `ObjectLit` value
 *    on the right-hand side of `=`/`:`/`(`/`[`/keyword is wrapped in
 *    `Nest(_cols, val)` so its hardlines pick up one extra indent
 *    step (`var x =\n\t{...}` instead of `var x =\n{...}`). Matches
 *    haxe-formatter's `indentation.indentObjectLiteral: @:default(true)`
 *    rule, which only fires when `{` lands on its own line. Under
 *    `Same` (cuddled) leftCurly the wrap is inert — `{` already sits on
 *    the parent line, so the inner content's existing nest is enough.
 *    When `indentObjectLiteral=false` the wrap is unconditionally inert.
 *    The knob only applies at sites tagged with
 *    `@:fmt(indentValueIfCtor('ObjectLit', 'indentObjectLiteral',
 *    'objectLiteralLeftCurly'))` in the grammar — currently
 *    `HxVarDecl.init` (var/final `=` RHS) and `HxObjectField.value`
 *    (`:` RHS inside an enclosing object literal). Other RHS positions
 *    (return/throw/assign/call-arg/array-element) intentionally do not
 *    opt in yet — generalising is a follow-up slice once the corpus
 *    delta is verified.
 *
 * Field added in slice ω-indent-complex-value-expr (extra indent on
 * `if`-as-RHS value expression):
 *  - `indentComplexValueExpressions` — when `true`, an `IfExpr` value
 *    on the right-hand side of `=`/`:`/`(`/`[`/keyword is wrapped in
 *    `Nest(_cols, val)` so its hardlines (the `{ … } else { … }` block
 *    bodies) pick up one extra indent step. Matches haxe-formatter's
 *    `indentation.indentComplexValueExpressions: @:default(false)` rule
 *    for the `var x = if (cond) { … } else { … };` shape. Default is
 *    `false` — the wrap is inert and existing layouts are unchanged.
 *    Independent of leftCurly placement: the `{` after `if (cond)` is
 *    grammatically tied to the same line, so no leftCurly gate. The knob
 *    only applies at sites tagged with
 *    `@:fmt(indentValueIfCtor('IfExpr', 'indentComplexValueExpressions'))`
 *    in the grammar — currently `HxVarDecl.init` only. Future RHS sites
 *    (`HxObjectField.value`, return/call-arg) and value ctors (`SwitchExpr`,
 *    `TryExpr`) opt in by adding their own entry.
 *
 * Field added in slice ω-arrow-fn-type (new-form arrow function type
 * `->` spacing):
 *  - `functionTypeHaxe4` — whitespace around the `->` separator in a
 *    new-form (Haxe 4) arrow function type `(args) -> ret`
 *    (`HxArrowFnType.ret`'s `@:lead('->')`). `Both` (default) emits
 *    `(Int) -> Bool`, matching haxe-formatter's
 *    `whitespace.functionTypeHaxe4Policy: @:default(Around)`. `None`
 *    keeps the tight pre-slice layout `(Int)->Bool`. `Before` / `After`
 *    are exposed for parity with the policy shape. The knob only
 *    applies at sites tagged with `@:fmt(functionTypeHaxe4)` in the
 *    grammar — `HxArrowFnType.ret` is the only consumer; the old-form
 *    curried arrow `Int->Bool` keeps its own `@:fmt(tight)` on
 *    `HxType.Arrow` and is unaffected.
 *
 * Field added in slice ω-arrow-fn-expr (parenthesised arrow lambda
 * expression `->` spacing):
 *  - `arrowFunctions` — whitespace around the `->` separator in a
 *    parenthesised arrow lambda expression `(params) -> body`
 *    (`HxThinParenLambda.body`'s `@:lead('->')`). `Both` (default)
 *    emits `(arg) -> body`, matching haxe-formatter's
 *    `whitespace.arrowFunctionsPolicy: @:default(Around)`. `None`
 *    keeps the tight pre-slice layout `(arg)->body`. `Before` /
 *    `After` are exposed for parity with the policy shape. The knob
 *    only applies at sites tagged with `@:fmt(arrowFunctions)` in the
 *    grammar — `HxThinParenLambda.body` is the only consumer; the
 *    sibling single-ident infix form `arg -> body` (`HxExpr.ThinArrow`)
 *    rides the Pratt infix path which already adds surrounding spaces
 *    by default. Independent of `functionTypeHaxe4` (the type-position
 *    `(args) -> ret`) so a config can space one form while keeping the
 *    other tight, mirroring upstream's separate JSON keys.
 *
 * Field added in slice ω-after-package (blank-line slot after the
 * top-level `package …;` directive):
 *  - `afterPackage` — exact number of blank lines the writer emits
 *    between a top-level `PackageDecl` / `PackageEmpty` element and the
 *    following decl in the same module. Override semantics, not floor:
 *    the source-captured blank-line count is always replaced with this
 *    value when the previous element is a package decl. `1` (default,
 *    matches haxe-formatter's
 *    `emptyLines.afterPackage: @:default(1)`) inserts one blank line
 *    after `package …;` even when the source had none. `0` strips any
 *    blank line after `package` even when the source carried one.
 *    Higher counts emit that many blank lines. The knob only triggers
 *    at sites tagged with
 *    `@:fmt(blankLinesAfterCtor('decl', 'PackageDecl', 'PackageEmpty', 'afterPackage'))`
 *    in the grammar — `HxModule.decls` is the only current consumer.
 *    The same `blankLinesAfterCtor` mechanism is open to future "blank
 *    line after `import`-group" / "blank line after `typedef`" slices
 *    by adding an analogous `@:fmt(...)` call against a different opt
 *    field.
 *
 * Field added in slice ω-before-package (blank-line slot at file head
 * before the top-level `package …;` directive):
 *  - `beforePackage` — exact number of blank lines the writer emits at
 *    the very START of a module when its first top-level decl is a
 *    `PackageDecl` / `PackageEmpty`. Override semantics, head-of-Star
 *    only: applies once per module, before any element is emitted.
 *    `0` (default, matches haxe-formatter's
 *    `emptyLines.beforePackage: @:default(0)`) keeps the file leading-
 *    edge tight against `package …;` even when the source had blank
 *    lines before it. `1` inserts one blank line before `package …;`
 *    so the file starts with a leading newline. The knob only triggers
 *    at sites tagged with
 *    `@:fmt(blankLinesAtHeadIfCtor('decl', 'PackageDecl', 'PackageEmpty', 'beforePackage'))`
 *    in the grammar — `HxModule.decls` is the only current consumer.
 *    The same `blankLinesAtHeadIfCtor` mechanism is reusable for any
 *    future "blank lines at head before ctor X" slice (e.g. before a
 *    file-leading typedef header) by pointing at a different opt field.
 *
 * Field added in slice ω-imports-using-blank (blank-line slot at
 * `import → using` transition):
 *  - `beforeUsing` — exact number of blank lines the writer emits when
 *    the current top-level decl is a `using` directive (`UsingDecl` /
 *    `UsingWildDecl`) and the previous decl is NOT a `using` directive.
 *    Override semantics, not floor: the source-captured blank-line count
 *    is always replaced with this value at the transition, so `0` strips
 *    any blank line between `import` and `using` even when the source
 *    had one and `2` doubles it regardless of source. Consecutive
 *    `using` decls fall through to the trivia channel's binary
 *    `blankBefore` flag (no override applied). `1` (default, matches
 *    haxe-formatter's `emptyLines.importAndUsing.beforeUsing:
 *    @:default(1)`) inserts one blank line between `import` and
 *    `using` even when the source had none. The knob only triggers at
 *    sites tagged with
 *    `@:fmt(blankLinesBeforeCtor('decl', 'UsingDecl', 'UsingWildDecl', 'beforeUsing'))`
 *    in the grammar — `HxModule.decls` is the only current consumer.
 *    The same `blankLinesBeforeCtor` mechanism is open to future
 *    "blank line before X-group" slices (e.g. `beforeType`) by adding
 *    an analogous `@:fmt(...)` call against a different opt field.
 *    Multi-info support (ω-after-typedecl) lets a Star carry multiple
 *    `blankLinesAfterCtor` / `blankLinesBeforeCtor` entries with
 *    independent ctor sets and opt fields, cascaded in source order.
 *
 * Fields added in slice ω-imports-using-between (blank-line slot
 * between two consecutive same-kind imports / usings, level-aware):
 *  - `betweenImports` — exact number of blank lines the writer emits
 *    when both the previous and current top-level decls are imports
 *    (`ImportDecl` / `ImportWildDecl`) or both usings (`UsingDecl` /
 *    `UsingWildDecl`) AND their dotted-ident paths fall into different
 *    groups at the configured level. Override semantics, not floor:
 *    the source-captured blank-line count is replaced with this value
 *    on a level-mismatch boundary. `0` (default, matches haxe-
 *    formatter's `emptyLines.importAndUsing.betweenImports:
 *    @:default(0)`) leaves consecutive same-kind imports glued; `1`
 *    inserts one blank line between groups. Same-level pairs (e.g.
 *    two `haxe.io.*` imports under `firstLevelPackage` policy) fall
 *    through to the trivia channel's binary `blankBefore` flag.
 *  - `betweenImportsLevel` — granularity of the level test. `All`
 *    treats every same-kind boundary as a level mismatch (one blank
 *    between every pair); `FirstLevelPackage` … `FifthLevelPackage`
 *    compare the first N dot-separated segments of the path;
 *    `FullPackage` compares the entire path. Default `All` matches
 *    haxe-formatter's `BetweenImportsEmptyLinesLevel: @:default(All)`.
 *    The knob only triggers at sites tagged with
 *    `@:fmt(blankLinesBetweenSameCtorByLevel('decl', Ctor1, [Ctor2, …],
 *    'betweenImportsLevel', 'betweenImports',
 *    'betweenImportsPathDiffers'))` in the grammar — `HxModule.decls`
 *    is the only current consumer (one entry per kind set: imports +
 *    usings). The 6th meta arg names the format-neutral
 *    `WriteOptions.betweenImportsPathDiffers` adapter slot, default-
 *    wired by the grammar plugin to its level-aware path-comparison
 *    helper (engine emits a pure `opt.betweenImportsPathDiffers(...)`
 *    EField call — see `endsWithCloseBrace` / `caseBodyRefusesFlat`
 *    precedent). The same `blankLinesBetweenSameCtorByLevel` mechanism
 *    is open to future same-kind, path-aware blank-line slices on any
 *    Star whose ctor set carries a String-shaped first arg.
 *
 * Field added in slice ω-imports-using-before-type (blank-line slot at
 * the import/using → type-decl transition):
 *  - `beforeType` — exact number of blank lines the writer emits when
 *    the current top-level decl is a type-bearing decl (`ClassDecl` /
 *    `InterfaceDecl` / `AbstractDecl` / `EnumDecl` / `TypedefDecl` /
 *    `FnDecl`) and the previous decl is an `import` / `using`
 *    directive (`ImportDecl` / `ImportWildDecl` / `UsingDecl` /
 *    `UsingWildDecl`). Override semantics, not floor: the source-
 *    captured blank-line count is replaced with this value at the
 *    transition, so `0` strips an existing blank line and `2` doubles
 *    one regardless of source. Pairs that don't span the
 *    import/using ↔ type boundary fall through to the next cascade
 *    layer (between-same-kind, source-driven). `1` (default, matches
 *    haxe-formatter's `emptyLines.importAndUsing.beforeType:
 *    @:default(1)`) inserts one blank line between the last
 *    `import` / `using` and the first type decl. The knob only
 *    triggers at sites tagged with
 *    `@:fmt(blankLinesOnTransitionAcross('decl', 'ImportDecl',
 *    'ImportWildDecl', 'UsingDecl', 'UsingWildDecl', '|', 'ClassDecl',
 *    'InterfaceDecl', 'AbstractDecl', 'EnumDecl', 'TypedefDecl',
 *    'FnDecl', 'beforeType'))` in the grammar — `HxModule.decls`,
 *    `HxConditionalDecl.body` / `elseBody`, and `HxElseifDecl.body`
 *    are the current consumers (mirrored cluster). Conditional
 *    transparency from the existing
 *    `betweenImportsTailLeafClassify` / `betweenImportsHeadLeafClassify`
 *    adapters extends to this transition automatically — they share
 *    the `'decl'` classifier, so `#if … import …` blocks are
 *    recognised as imports for the boundary test.
 *
 * Fields added in slice ω-after-multiline (predicate-gated blank-line
 * rules driven by the grammar-derived `multiline` predicate):
 *  - `afterMultilineDecl` — exact number of blank lines the writer emits
 *    after a top-level decl whose ctor is in the predicate-gated set
 *    (`ClassDecl` / `InterfaceDecl` / `AbstractDecl` / `EnumDecl` /
 *    `FnDecl`) AND whose grammar-derived multi-line shape predicate
 *    fires (non-empty `members` / `ctors` / `BlockBody.stmts`).
 *    Override semantics, not floor: replaces the source-captured blank-
 *    line count when the previous element matches. `1` (default,
 *    matches haxe-formatter's `emptyLines.betweenTypes: @:default(1)`)
 *    inserts one blank line after a multi-line type decl regardless of
 *    source. `0` strips one. Empty-body single-line decls (`class C {}`)
 *    fall through the predicate to kind=0 and the rule is inert — the
 *    surrounding `betweenSingleLineTypes`-style behaviour is the
 *    cascade's source-driven fallback.
 *  - `beforeMultilineDecl` — symmetric "before" counterpart, fires when
 *    the current top-level decl is multi-line AND the previous decl
 *    isn't (otherwise `afterMultilineDecl` already covered the gap).
 *    `1` (default) inserts one blank line before a multi-line decl
 *    regardless of source. Cascade picks `afterMultilineDecl` first when
 *    both rules would fire on the same gap (multi → multi transitions).
 *
 * The `multiline` predicate is resolved at compile time by
 * `WriterLowering.buildMultilinePredicate` from the grammar's typedef-
 * and ctor-level `@:fmt(multilineWhenFieldNonEmpty(...))` /
 * `@:fmt(multilineWhenFieldShape(...))` / `@:fmt(multilineCtor)` metas.
 * Zero runtime reflection.
 *
 * Field added in slice ω-string-interp-noformat (verbatim emit of
 * `${…}` interpolation expressions in single-quoted strings):
 *  - `formatStringInterpolation` — when `true` (default, matches haxe-
 *    formatter's `whitespace.formatStringInterpolation: @:default(true)`)
 *    the writer re-emits each `${expr}` segment by recursing into the
 *    parsed `HxExpr`, producing canonical `${a + b}` spacing regardless
 *    of source. When `false` the writer emits the parser-captured byte
 *    slice between `${` and `}` verbatim, preserving the author's
 *    spacing exactly (`${a+b}` stays `${a+b}`). The captured slice
 *    rides on the trivia-pair synth ctor `HxStringSegmentT.Block`'s
 *    positional `sourceText:String` arg, populated by Lowering Case 3
 *    when the ctor carries `@:fmt(captureSource)`. Plain-mode pipelines
 *    (no synth pair) do not capture and the knob has no effect there.
 *
 * Internal field added in slice ω-issue-423-mech-a (case-body context
 * dispatch):
 *  - `_inExprPosition` — write-time-only signal flagging that the
 *    current writer call is descending through an expression-position
 *    parent (currently set only by `HxCaseBranch.body` /
 *    `HxDefaultBranch.stmts` via `@:fmt(propagateExprPosition)`).
 *    Read by the dual-flag `bodyPolicy('caseBody', 'expressionCase')`
 *    flat-gate in `WriterLowering.triviaTryparseStarExpr` to dispatch
 *    between the statement-position `caseBody` policy (default
 *    `Next`, breaks) and the expression-position `expressionCase`
 *    policy (default `Keep`, flattens on same-line source). The
 *    underscore prefix marks it as an internal channel — not a user-
 *    facing knob, no JSON loader entry, no `hxformat.json` ingest.
 *    Default `false`. Mirrors fork's `isReturnExpression` parent-walk
 *    heuristic in `MarkSameLine.markCase`: outer `case X:` in a
 *    statement-position switch sees `false` and breaks per `caseBody`,
 *    while a case nested inside another case's body inherits `true`
 *    via opt-fanout and flattens per `expressionCase`.
 *
 * Internal field added in slice ω-anonfunction-empty-curly, extended in
 * slice ω-arrow-lambda-body-context:
 *  - `_inAnonFnBody` — write-time-only signal flagging that the current
 *    writer call is descending into an anonymous function body. Sources:
 *    `HxFnExpr.body` → `HxFnExprBody.BlockBody(HxFnBlock)` (function-kw
 *    anon-fn), `HxParenLambda.body` → `HxExpr` (`(params) => body`), and
 *    `HxThinParenLambda.body` → `HxExpr` (`(params) -> body`). Set via
 *    `@:fmt(propagateAnonFnContext)` + `_setAnonFnBody` opt-fanout on
 *    these Ref writer call sites. Consumers:
 *     - `emptyCurlyBreak` emit branch in `triviaBlockStarExpr` dispatches
 *       between `opt.emptyCurly` (global — class / interface / abstract /
 *       enum / `HxFnDecl.body`) and `opt.anonFunctionEmptyCurly`.
 *     - `HxExpr.BlockExpr.stmts` (opt-in via
 *       `@:fmt(leftCurlyAnonFnOverride('anonFunctionLeftCurly'))`)
 *       prepends a runtime-gated hardline before `{` when the flag is
 *       true AND the named knob is `Next`, placing the arrow-lambda body
 *       brace in Allman position. The flag is then cleared via
 *       `_clearAnonFnBody` on the per-element opt so nested statements /
 *       nested `BlockExpr` inside the body fall back to default
 *       `blockLeftCurly`.
 *    Sister channel to `_inExprPosition`. The underscore prefix marks it
 *    as internal — no JSON loader entry, no `hxformat.json` ingest.
 *    Default `false`.
 *
 * Internal field added in slice ω-extern-class-no-blanks
 * (extern-modifier-aware interMember suppression):
 *  - `_classExtern` — write-time-only signal flagging that the current
 *    writer call is descending into an `extern`-marked top-level
 *    declaration. Set by `HxTopLevelDecl.decl` via
 *    `@:fmt(setBoolFlagFromStarCtor('_classExtern', 'modifiers',
 *    'Extern'))` when the sibling `modifiers` Star contains an `Extern`
 *    ctor; descendants see the flag through the standard opt-fanout
 *    copy. Read by `triviaBlockStarExpr`'s `addByInterMemberExpr` to
 *    AND-out interMember-driven blank-line emission when the flag is
 *    set — `extern class Foo { var a; var b; function new(); function
 *    foo(); }` round-trips with zero blanks regardless of
 *    `betweenVars` / `betweenFunctions` / `afterVars` defaults. The
 *    underscore prefix marks it as an internal channel — not a user-
 *    facing knob, no JSON loader entry, no `hxformat.json` ingest.
 *    Default `false`. Mirrors fork's `externClassEmptyLines` config
 *    section (which swaps the entire `EmptyLines` policy block on
 *    extern-marked classes); the anyparse minimal gate covers the
 *    interMember subset only — wider knobs can join later if a fixture
 *    requires them.
 *
 * Fields added in slice ω-fileheader-multiline-comments (blank-line
 * policy within a decl's `leadingComments` chain — mirrors haxe-
 * formatter's `emptyLines.afterFileHeaderComment` /
 * `emptyLines.betweenMultilineComments` knobs):
 *  - `afterFileHeaderComment` — exact number of blank lines the writer
 *    emits AFTER the FIRST top-level block-style comment in a module
 *    when fileheader semantics apply. "Fileheader applies" iff the
 *    module either contains at least one `package` / `import` / `using`
 *    decl, OR the first decl carries 2+ leading comments at module
 *    head (so the second token is also a comment). Override semantics:
 *    replaces source-captured blank-line counts at the first→next slot
 *    regardless of source. `1` (default, matches haxe-formatter's
 *    `emptyLines.afterFileHeaderComment: @:default(1)`) inserts one
 *    blank between fileheader and the next thing. `0` keeps fileheader
 *    glued to next. The knob only triggers at sites tagged with
 *    `@:fmt(afterFileHeaderCommentBlanks)` in the grammar — `HxModule.decls`
 *    is the only consumer (concept is module-scope by definition).
 *  - `betweenMultilineComments` — exact number of blank lines the writer
 *    emits BETWEEN two consecutive block-style comments (`/* … *\/` or
 *    `/** … *\/`) wherever block-block boundaries occur in
 *    `leadingComments` arrays or in trailing-orphan comment arrays
 *    (`_trailLC`). Override semantics: replaces source-captured blank-
 *    line counts at every block-block boundary except the slot already
 *    claimed by `afterFileHeaderComment`. `0` (default, matches haxe-
 *    formatter's `emptyLines.betweenMultilineComments: @:default(0)`)
 *    leaves consecutive block comments glued; `1` inserts one blank.
 *    The knob only triggers at sites tagged with
 *    `@:fmt(betweenMultilineCommentsBlanks)` in the grammar —
 *    `HxModule.decls`, class / interface / abstract member Stars are
 *    the current consumers.
 *
 * Field added in slice ω-between-single-line-types:
 *  - `betweenSingleLineTypes` — number of blank lines the writer emits
 *    BETWEEN any consecutive pair of single-line top-level type decls
 *    (typedef / class / interface / abstract / enum where NEITHER matches
 *    the grammar-derived `multiline` predicate — i.e. empty-body
 *    `class C {}` / `interface I {}` / `enum E {}` / `abstract A() {}`
 *    AND any `typedef T = …;`). Insertion-only semantic: the override
 *    fires ONLY when this value is `> 0`, in which case it forces
 *    exactly that many blanks regardless of source. `0` (default,
 *    matches haxe-formatter's `emptyLines.betweenSingleLineTypes:
 *    @:default(0)`) leaves the slot source-driven — pre-slice behaviour
 *    is preserved when the source had a blank between two single-line
 *    type decls. `1` inserts one blank line between every same-shape
 *    pair (a typedef before a class follows the cascade priority —
 *    `afterMultilineDecl` / `beforeMultilineDecl` win when either side
 *    is multi-line). The `>0` gate is engine-level, not knob-level: the
 *    runtime cascade ternary short-circuits to source-driven when the
 *    knob reads 0, matching fork's
 *    `MarkEmptyLines.markBlankLinesAfter`-style "insertion only" pattern
 *    for the single-line slot (fork never strips blanks here; only fills
 *    when source had none). Driven by
 *    `@:fmt(blankLinesBetweenSameCtorIfNot('decl', 'multiline', 'ClassDecl',
 *    'InterfaceDecl', 'AbstractDecl', 'EnumDecl', 'TypedefDecl',
 *    'betweenSingleLineTypes'))` on `HxModule.decls`. The cascade gate
 *    consults BOTH prev and curr classifier kinds — fires only when both
 *    ends of the pair fall in the ctor set AND neither matches the
 *    predicate. Zero runtime reflection — the macro emits direct enum-
 *    switch + the same grammar-derived `multiline` predicate used by
 *    `afterMultilineDecl` (inverted polarity per the meta name's `IfNot`
 *    suffix).
 *
 * Field added in slice ω-metadata-line-end-function:
 *  - `metadataFunctionLineEnd` — line-end policy for the metadata
 *    `@:tryparse` Star on `HxMemberDecl.meta`. Mirrors haxe-formatter's
 *    `lineEnds.metadataFunction` (`AtLineEndPolicy`):
 *      `None` (default) — source-driven inter-element separator from
 *        per-element `newlineBefore` trivia; no forced gap after the
 *        last metadata.
 *      `After` — every inter-element separator becomes a hardline AND
 *        a hardline fires after the last element (one metadata per
 *        line, ignoring source layout).
 *      `AfterLast` — inter-element separator stays source-driven, but
 *        a hardline ALWAYS fires after the last metadata.
 *      `ForceAfterLast` — inter-element separator is forced to a
 *        single space (collapses any source newlines between metas)
 *        AND a hardline fires after the last metadata.
 *    Consumed by `@:fmt(metaLineEndPolicy('metadataFunctionLineEnd'))`
 *    on `HxMemberDecl.meta`. Per-construct sister knobs
 *    (`metadataType` / `metadataVar` / `metadataOther`) land with
 *    their own slices.
 */
typedef HxModuleWriteOptions = WriteOptions & {
	sameLineElse:SameLinePolicy,
	sameLineCatch:SameLinePolicy,
	sameLineDoWhile:SameLinePolicy,
	sameLineExpressionElse:SameLinePolicy,
	trailingCommaArrays:Bool,
	trailingCommaArgs:Bool,
	trailingCommaParams:Bool,
	trailingCommaObjectLits:Bool,
	ifBody:BodyPolicy,
	elseBody:BodyPolicy,
	forBody:BodyPolicy,
	whileBody:BodyPolicy,
	doBody:BodyPolicy,
	returnBody:BodyPolicy,
	throwBody:BodyPolicy,
	catchBody:BodyPolicy,
	tryBody:BodyPolicy,
	caseBody:BodyPolicy,
	expressionCase:BodyPolicy,
	functionBody:BodyPolicy,
	untypedBody:BodyPolicy,
	expressionIfBody:BodyPolicy,
	expressionElseBody:BodyPolicy,
	expressionForBody:BodyPolicy,
	expressionIfWithBlocks:Bool,
	leftCurly:BracePlacement,
	emptyCurly:EmptyCurly,
	objectLiteralLeftCurly:BracePlacement,
	anonTypeLeftCurly:BracePlacement,
	anonFunctionLeftCurly:BracePlacement,
	anonFunctionEmptyCurly:EmptyCurly,
	blockLeftCurly:BracePlacement,
	blockEmptyCurly:EmptyCurly,
	blockRightCurly:RightCurlyPlacement,
	anonFunctionRightCurly:RightCurlyPlacement,
	anonTypeRightCurly:RightCurlyPlacement,
	objectFieldColon:WhitespacePolicy,
	typeHintColon:WhitespacePolicy,
	typeCheckColon:WhitespacePolicy,
	funcParamParens:WhitespacePolicy,
	callParens:WhitespacePolicy,
	anonFuncParens:WhitespacePolicy,
	anonFuncParamParensKeepInnerWhenEmpty:Bool,
	ifPolicy:WhitespacePolicy,
	forPolicy:WhitespacePolicy,
	whilePolicy:WhitespacePolicy,
	switchPolicy:WhitespacePolicy,
	tryPolicy:WhitespacePolicy,
	elseIf:KeywordPlacement,
	fitLineIfWithElse:Bool,
	afterFieldsWithDocComments:CommentEmptyLinesPolicy,
	existingBetweenFields:KeepEmptyLinesPolicy,
	externExistingBetweenFields:KeepEmptyLinesPolicy,
	beforeDocCommentEmptyLines:CommentEmptyLinesPolicy,
	betweenVars:Int,
	betweenFunctions:Int,
	afterVars:Int,
	afterStaticVars:Int,
	interfaceBetweenVars:Int,
	interfaceBetweenFunctions:Int,
	interfaceAfterVars:Int,
	betweenEnumCtors:Int,
	beginType:Int,
	endType:Int,
	afterLeftCurly:KeepEmptyLinesPolicy,
	beforeRightCurly:KeepEmptyLinesPolicy,
	typedefAssign:WhitespacePolicy,
	typeParamDefaultEquals:WhitespacePolicy,
	typeParamOpen:WhitespacePolicy,
	typeParamClose:WhitespacePolicy,
	anonTypeBracesOpen:WhitespacePolicy,
	anonTypeBracesClose:WhitespacePolicy,
	objectLiteralBracesOpen:WhitespacePolicy,
	objectLiteralBracesClose:WhitespacePolicy,
	objectLiteralWrap:WrapRules,
	callParameterWrap:WrapRules,
	arrayLiteralWrap:WrapRules,
	anonTypeWrap:WrapRules,
	methodChainWrap:WrapRules,
	opBoolChainWrap:WrapRules,
	opAddSubChainWrap:WrapRules,
	expressionTry:SameLinePolicy,
	indentCaseLabels:Bool,
	indentObjectLiteral:Bool,
	indentComplexValueExpressions:Bool,
	functionTypeHaxe4:WhitespacePolicy,
	arrowFunctions:WhitespacePolicy,
	afterPackage:Int,
	beforePackage:Int,
	beforeUsing:Int,
	betweenImports:Int,
	betweenImportsLevel:HxBetweenImportsLevel,
	beforeType:Int,
	afterMultilineDecl:Int,
	beforeMultilineDecl:Int,
	afterFileHeaderComment:Int,
	betweenMultilineComments:Int,
	betweenSingleLineTypes:Int,
	formatStringInterpolation:Bool,
	metadataFunctionLineEnd:MetadataLineEndPolicy,
	_inExprPosition:Bool,
	_classExtern:Bool,
	_inAnonFnBody:Bool,
};
