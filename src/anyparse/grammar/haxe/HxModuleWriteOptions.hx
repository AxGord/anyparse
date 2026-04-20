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
	leftCurly:BracePlacement,
	objectFieldColon:WhitespacePolicy,
	typeHintColon:WhitespacePolicy,
	funcParamParens:WhitespacePolicy,
	elseIf:KeywordPlacement,
	fitLineIfWithElse:Bool,
	afterFieldsWithDocComments:CommentEmptyLinesPolicy,
	existingBetweenFields:KeepEmptyLinesPolicy,
};
