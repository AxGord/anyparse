package anyparse.grammar.haxe;

import anyparse.format.BodyPolicy;
import anyparse.format.BracePlacement;
import anyparse.format.KeywordPlacement;
import anyparse.format.WhitespacePolicy;
import anyparse.format.WriteOptions;

/**
 * Write options specific to the Haxe module grammar (`HxModule`).
 *
 * Haxe-specific knobs are mixed into the base `WriteOptions` shape via
 * struct intersection so the macro-generated writer sees a fully
 * populated struct at runtime.
 *
 * Fields added in slice τ₁ (same-line policies):
 *  - `sameLineElse` — when `true`, `else` sits on the same line as
 *    the preceding `}` (e.g. `} else {`); when `false`, `else` moves
 *    to the next line at the current indent level.
 *  - `sameLineCatch` — when `true`, `catch (...)` sits on the same
 *    line as the preceding `}`; when `false`, each `catch` moves to
 *    the next line at the current indent level.
 *  - `sameLineDoWhile` — when `true`, the closing `while (...)` of a
 *    `do … while (…)` loop sits on the same line as the body's
 *    closing `}`; when `false`, `while` moves to the next line.
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
 *    `HxVarDecl.type` / `HxParam.type` / `HxFnDecl.returnType` stays
 *    tight regardless, matching haxe-formatter's hard-coded
 *    `x:Int` / `f():Void` layout.
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
 */
typedef HxModuleWriteOptions = WriteOptions & {
	sameLineElse:Bool,
	sameLineCatch:Bool,
	sameLineDoWhile:Bool,
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
	elseIf:KeywordPlacement,
};
