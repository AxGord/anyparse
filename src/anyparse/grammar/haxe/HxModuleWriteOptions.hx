package anyparse.grammar.haxe;

import anyparse.format.BodyPolicy;
import anyparse.format.BracePlacement;
import anyparse.format.CommentEmptyLinesPolicy;
import anyparse.format.KeepEmptyLinesPolicy;
import anyparse.format.KeywordPlacement;
import anyparse.format.SameLinePolicy;
import anyparse.format.WhitespacePolicy;
import anyparse.format.WriteOptions;
import anyparse.format.wrap.WrapRules;

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
 *    `wrapping.arrayWrap` rules from `default-hxformat.json`, minus the
 *    `hasMultilineItems` and `equalItemLengths` conditions (and their
 *    gated `fillLineWithLeadingBreak` rules) which `WrapConditionType`
 *    does not yet model — for the `hasMultilineItems` case the runtime
 *    already routes `anyHardline=true` items through the `exceeds=true`
 *    cascade run with `maxLen`/`total` set to `HARDLINE_LEN`, which
 *    fails the `total<80` rule and triggers `OnePerLine` via the
 *    `anyItemLength>=30` rule. Architecturally orthogonal to
 *    `trailingCommaArrays` (which still drives the optional trailing
 *    `,` after the last element on multi-line); the two compose.
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
 */
typedef HxModuleWriteOptions = WriteOptions & {
	sameLineElse:SameLinePolicy,
	sameLineCatch:SameLinePolicy,
	sameLineDoWhile:SameLinePolicy,
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
	leftCurly:BracePlacement,
	objectLiteralLeftCurly:BracePlacement,
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
	beforeDocCommentEmptyLines:CommentEmptyLinesPolicy,
	betweenVars:Int,
	betweenFunctions:Int,
	afterVars:Int,
	interfaceBetweenVars:Int,
	interfaceBetweenFunctions:Int,
	interfaceAfterVars:Int,
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
	beforeUsing:Int,
	afterMultilineDecl:Int,
	beforeMultilineDecl:Int,
	formatStringInterpolation:Bool,
};
