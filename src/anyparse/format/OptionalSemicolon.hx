package anyparse.format;

/**
 * Three-way policy for a statement terminator the grammar declares as
 * `@:trailOpt(';')` — a token the language permits omitting, not
 * whitespace and not a node of its own.
 *
 * `Preserve` — re-emit the terminator exactly where the source had one.
 * The default everywhere, so a writer that adopts the knob stays
 * byte-inert until a config asks otherwise.
 *
 * `Always` — emit the terminator on every participating slot. The
 * reader never has to hold the "the value ends in `}`, so the `;` may
 * be omitted" rule, and a fixer that swaps a brace-terminated value for
 * a non-brace one can no longer land on a site that has no `;` to
 * inherit.
 *
 * `Never` — drop the terminator wherever the slot's shape gate proves
 * it optional, and keep it everywhere else. The gate is mandatory: for
 * Haxe, `return 42` before `}` is `Missing ;`, so an ungated drop would
 * emit unparseable source.
 *
 * Consumed by the `@:fmt(optionalSemicolon('<gatePredicate>'[,
 * '<argFieldPath>']))` writer flag on a `@:trailOpt` Alt ctor: presence
 * of the flag routes the trivia-mode trail emission through
 * `opt.optionalSemicolon` instead of the recorded source presence. A
 * `@:trailOpt` ctor WITHOUT the flag keeps preserving, so the whitelist
 * is positive — a slot participates only when someone has checked that
 * both directions are legal there.
 *
 * Format-neutral: lives in `anyparse.format` so any grammar with an
 * optional statement terminator can reuse the shape.
 */
enum abstract OptionalSemicolon(Int) from Int to Int {

	final Preserve = 0;

	final Always = 1;

	final Never = 2;

}
