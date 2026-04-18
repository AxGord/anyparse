package anyparse.format;

/**
 * Two-way placement policy for a keyword whose position relative to
 * preceding content varies between "inline after the previous token"
 * and "on the next line at the same indent level".
 *
 * `Same` — keyword sits on the same line as the preceding token,
 * separated by a single space (`} else if (...)`). This is the
 * default for `sameLine.elseIf` in haxe-formatter and the value that
 * preserves the traditional `else if` idiom in our generated output.
 *
 * `Next` — keyword moves to the next line at the current (outer)
 * indent level, with the keyword's own body emitted by whatever
 * bodyPolicy applies to it. Produces the `} else\n\tif (...)` layout
 * that issue_11_else_if_next_line exercises.
 *
 * Consumed by the `@:fmt(elseIf)` writer flag: presence of the flag
 * on an optional `@:kw` body field switches the emission to a
 * ctor-specific override — when the runtime value matches the `IfStmt`
 * ctor (the `else if` idiom), the separator between the keyword and
 * the nested statement is picked from `opt.elseIf`, bypassing the
 * field's own `@:fmt(bodyPolicy(...))`. For non-`IfStmt` ctors the
 * behaviour falls through to the normal bodyPolicy-driven layout.
 *
 * Two values are sufficient because the `else if` idiom only makes
 * sense inline or on the next line — `FitLine` would duplicate the
 * `elseBody=FitLine` case the bodyPolicy already handles, and `Keep`
 * would require per-node source-shape tracking the parser does not
 * yet carry. Additional values can be appended here once a fixture
 * makes them necessary.
 *
 * Format-neutral — lives in `anyparse.format` so grammars for other
 * languages (AS3, C-family, ...) can reuse the same shape for their
 * own keyword-placement knobs (future `ifElse`, `tryCatch`, `doWhile`
 * will each get their own `@:fmt(<name>)` flag with its own
 * `KeywordPlacement` options field, per the ψ₆ principle of one flag =
 * one options field).
 */
enum abstract KeywordPlacement(Int) from Int to Int {

	final Same = 0;

	final Next = 1;
}
