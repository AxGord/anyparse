package anyparse.grammar.haxe;

import anyparse.format.BodyPolicy;
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
 * Policies apply only to non-block bodies: a block body (`{ … }`)
 * carries its own hardlines from `blockBody`, so the separator before
 * `{` is always a single space regardless of the policy.
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
};
