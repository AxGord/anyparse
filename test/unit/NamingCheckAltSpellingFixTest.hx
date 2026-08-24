package unit;

/**
 * omega-naming-alt-spelling: the `naming` autofix falling back to a rule's SECOND conforming
 * spelling when the first correction cannot be applied.
 *
 * A `format` may admit more than one convention — the built-in constant rule accepts UPPER_SNAKE
 * or camelCase — and until this arm existed, a constant whose stripped spelling was already bound
 * was reported wrong with no correction anyone could apply. The fallback is asked for ONLY after
 * the primary correction is refused, and its answer passes the same inherited / collision gates.
 *
 * The first case here supersedes `testFixSkipsStaticFinalNameCollision`, which pinned the refusal
 * this arm replaces.
 */
class NamingCheckAltSpellingFixTest extends NamingCheckTestBase {

	/**
	 * The shape that found it: a private constant beside a `height` the owner already binds. The
	 * stripped spelling collides, so the rule's other branch answers.
	 */
	public function testFixFallsBackToUpperSnakeWhenStrippedNameCollides(): Void {
		final src: String = 'package pkg;\nclass C {\n\tprivate static final _height:Int = 50;\n\tpublic var height:Int = 0;\n'
			+ '\tpublic function f():Int return _height + height;\n}';
		assertFixCanonicalWithIndex(src, 'final HEIGHT:Int', '_height');
	}

	/** With the stripped spelling FREE the primary correction still wins — the alternative is a fallback, not a preference. */
	public function testFixPrefersStrippedNameOverUpperSnake(): Void {
		final src: String =
			'package pkg;\nclass C {\n\tprivate static final _height:Int = 50;\n\tpublic function f():Int return _height;\n}';
		assertFixCanonicalWithIndex(src, 'final height:Int', 'HEIGHT');
	}

	/** Both spellings taken — the refusal stands rather than the fallback inventing a third name. */
	public function testFixRefusesWhenBothSpellingsCollide(): Void {
		final src: String = 'package pkg;\nclass C {\n\tprivate static final HEIGHT:Int = 60;\n\tprivate static final _height:Int = 50;\n'
			+ '\tpublic var height:Int = 0;\n\tpublic function f():Int return _height + height + HEIGHT;\n}';
		assertNotRenamed(src);
	}

	/** A rule that states no second spelling is unaffected: the private-field collision stays a refusal. */
	public function testFixRefusesCollisionForRuleWithoutAlternative(): Void {
		final src: String = 'package pkg;\nclass C {\n\tprivate var __shape:Int = 0;\n\tprivate var _shape:Int = 0;\n'
			+ '\tpublic function f():Int return __shape + _shape;\n}';
		assertNotRenamed(src);
	}

}
