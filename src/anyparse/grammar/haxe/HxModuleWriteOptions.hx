package anyparse.grammar.haxe;

import anyparse.format.BodyPolicy;
import anyparse.format.BracePlacement;
import anyparse.format.CommentEmptyLinesPolicy;
import anyparse.format.KeepEmptyLinesPolicy;
import anyparse.format.KeywordPlacement;
import anyparse.format.SameLinePolicy;
import anyparse.format.WhitespacePolicy;
import anyparse.format.WriteOptions;

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
 * Field added in slice ω-throw-body:
 *  - `throwBody` — same `BodyPolicy` knob shape as `returnBody`,
 *    gating the separator between the `throw` keyword and its value
 *    expression at `HxStatement.ThrowStmt`. `Same` keeps
 *    `throw value;` flat; `Next` always pushes the value to the
 *    next line; `FitLine` (default) keeps it flat when it fits
 *    within `lineWidth`, otherwise breaks. `Keep` preserves the
 *    source layout. There is no upstream haxe-formatter
 *    `throwBody` knob — the JSON loader does not parse a
 *    `sameLine.throwBody` key from `hxformat.json`. The runtime
 *    knob exists for parity with `returnBody` and for users
 *    constructing `HxModuleWriteOptions` programmatically.
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
 */
typedef HxModuleWriteOptions = WriteOptions & {
	sameLineElse:SameLinePolicy,
	sameLineCatch:SameLinePolicy,
	sameLineDoWhile:SameLinePolicy,
	trailingCommaArrays:Bool,
	trailingCommaArgs:Bool,
	trailingCommaParams:Bool,
	ifBody:BodyPolicy,
	elseBody:BodyPolicy,
	forBody:BodyPolicy,
	whileBody:BodyPolicy,
	doBody:BodyPolicy,
	returnBody:BodyPolicy,
	throwBody:BodyPolicy,
	leftCurly:BracePlacement,
	objectFieldColon:WhitespacePolicy,
	typeHintColon:WhitespacePolicy,
	typeCheckColon:WhitespacePolicy,
	funcParamParens:WhitespacePolicy,
	callParens:WhitespacePolicy,
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
	expressionTry:SameLinePolicy,
	indentCaseLabels:Bool,
	functionTypeHaxe4:WhitespacePolicy,
	arrowFunctions:WhitespacePolicy,
	afterPackage:Int,
	beforeUsing:Int,
};
