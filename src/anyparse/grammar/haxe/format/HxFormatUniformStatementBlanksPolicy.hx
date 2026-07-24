package anyparse.grammar.haxe.format;

/**
 * Closed set of values the anyparse-specific
 * `emptyLines.uniformStatementBlanks` field accepts. No haxe-formatter
 * counterpart exists — this knob is an anyparse extension, so it defaults
 * to `keep` (byte-inert) and never re-baselines at JSON-load entry the
 * way the fork-canonical `afterLeftCurly` / `beforeRightCurly` do.
 *
 * Mapped by `HaxeFormatConfigLoader` to
 * `anyparse.format.UniformStatementBlanksPolicy`:
 *
 * - `"keep"`     → `UniformStatementBlanksPolicy.Keep`
 * - `"collapse"` → `UniformStatementBlanksPolicy.Collapse`
 */
enum abstract HxFormatUniformStatementBlanksPolicy(String) to String {

	final Keep = 'keep';

	final Collapse = 'collapse';

}
