package anyparse.grammar.haxe;

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
 */
typedef HxModuleWriteOptions = WriteOptions & {
	sameLineElse:Bool,
	sameLineCatch:Bool,
	sameLineDoWhile:Bool,
};
