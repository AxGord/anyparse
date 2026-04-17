package anyparse.grammar.haxe;

/**
 * Closed set of values the haxe-formatter `sameLine` fields accept.
 * `Same` → `true`; every other value maps to `false` in the loader
 * because the writer currently has no way to recover `Keep` /
 * `FitLine` semantics (those require per-node source-shape tracking
 * the parser does not yet preserve).
 */
enum abstract HxFormatSameLinePolicy(String) to String {

	final Same = 'same';

	final Next = 'next';

	final Keep = 'keep';

	final FitLine = 'fitLine';
}
