package unit.check.common.loops;

import anyparse.check.Check;
import anyparse.check.Severity;
import anyparse.check.common.loops.PreferModuloWrap;
import anyparse.check.common.loops.RedundantIfBeforeWhile;
import anyparse.query.CanonicalEdit;

/**
 * The `prefer-modulo-wrap` check: two adjacent loops wrapping a local into `[0, N)` one step at a time are
 * `v %= N; if (v < 0) v += N;`. The fix applies to a local declared `Int`; a Float or a type nothing declares is
 * reported only, because the rewrite turns a negative multiple of `N` from `+0` into `-0`.
 */
class PreferModuloWrapCheckTest extends Test {

	private static final UPPER: String = 'while (v >= 360) v -= 360;';
	private static final LOWER: String = 'while (v < 0) v += 360;';
	private static final WRAPPED: String = 'v %= 360;\n\t\tif (v < 0) v += 360;';

	public function testUpperThenLowerIsFlaggedAndFixed(): Void {
		final src: String = wrap('$UPPER\n\t\t$LOWER');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('prefer-modulo-wrap', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.isTrue(fixed(src).indexOf(WRAPPED) >= 0);
	}

	@:pin('control')
	@:killer('M-PMW-FIX-TEXT')
	public function testFixSpellsTheModuloWrap(): Void {
		final text: String = fixed(wrap('$UPPER\n\t\t$LOWER'));
		Assert.isTrue(text.indexOf(WRAPPED) >= 0);
		Assert.isTrue(text.indexOf('while') == -1);
	}

	@:pin('control')
	@:killer('M-PMW-FIX-TEXT')
	public function testLowerThenUpperIsFixedInTheSameShape(): Void {
		Assert.isTrue(fixed(wrap('$LOWER\n\t\t$UPPER')).indexOf(WRAPPED) >= 0);
	}

	public function testBracedBodiesAreTheSameLoops(): Void {
		final text: String = fixed(wrap('while (v >= 360) { v -= 360; }\n\t\twhile (v < 0) { v += 360; }'));
		Assert.isTrue(text.indexOf(WRAPPED) >= 0);
	}

	public function testNamedBoundIsKept(): Void {
		final text: String = fixed(wrap('while (v >= DEG) v -= DEG;\n\t\twhile (v < 0) v += DEG;'));
		Assert.isTrue(text.indexOf('v %= DEG;\n\t\tif (v < 0) v += DEG;') >= 0);
	}

	public function testParameterBoundIsKept(): Void {
		final src: String = wrap('while (v >= n) v -= n;\n\t\twhile (v < 0) v += n;');
		Assert.equals(1, violations(src).length);
		Assert.isTrue(fixed(src).indexOf('v %= n;') >= 0);
	}

	@:pin('control')
	@:killer('M-PMW-STABLE-NAME')
	public function testBoundANestedFunctionWritesIsNotFlagged(): Void {
		final src: String = wrap('final bump = () -> n++;\n\t\twhile (v >= n) v -= n;\n\t\twhile (v < 0) v += n;\n\t\tbump();');
		Assert.equals(0, violations(src).length);
	}

	@:pin('control')
	@:killer('M-PMW-STEP-EQUAL')
	public function testDifferentStepIsNotFlagged(): Void {
		Assert.equals(0, violations(wrap('$UPPER\n\t\twhile (v < 0) v += 180;')).length);
	}

	@:pin('control')
	@:killer('M-PMW-ZERO-LOWER')
	public function testLowerBoundOtherThanZeroIsNotFlagged(): Void {
		Assert.equals(0, violations(wrap('$UPPER\n\t\twhile (v < 1) v += 360;')).length);
	}

	@:pin('control')
	@:killer('M-NUMLIT-HEX')
	public function testHexadecimalLowerBoundIsNotZero(): Void {
		Assert.equals(0, violations(wrap('$UPPER\n\t\twhile (v < 0x10) v += 360;')).length);
	}

	@:pin('control')
	@:killer('M-PMW-POSITIVE')
	public function testZeroStepIsNotFlagged(): Void {
		Assert.equals(0, violations(wrap('while (v >= 0) v -= 0;\n\t\twhile (v < 0) v += 0;')).length);
	}

	@:pin('control')
	@:killer('M-PMW-OPPOSITE')
	public function testTwoUpperLoopsAreNotAWrap(): Void {
		Assert.equals(0, violations(wrap('$UPPER\n\t\t$UPPER')).length);
	}

	@:pin('control')
	@:killer('M-PMW-LOCAL')
	public function testFieldIsNotFlagged(): Void {
		final src: String = 'class C {\n\tvar angle:Int = 0;\n\tfunction f():Void {\n\t\twhile (angle >= 360) angle -= 360;\n'
			+ '\t\twhile (angle < 0) angle += 360;\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

	@:pin('guard')
	public function testStatementBetweenTheLoopsIsNotFlagged(): Void {
		Assert.equals(0, violations(wrap('$UPPER\n\t\ttrace(v);\n\t\t$LOWER')).length);
	}

	@:pin('control')
	@:killer('M-PMW-FLOAT-FIX')
	public function testFloatIsReportedButNotFixed(): Void {
		final src: String = 'class C {\n\tfunction f(v:Float):Void {\n\t\t$UPPER\n\t\t$LOWER\n\t}\n}';
		final check: PreferModuloWrap = new PreferModuloWrap();
		final vs: Array<Violation> = CheckFixture.violations(check, src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('not declared Int') >= 0);
		Assert.equals(0, CheckFixture.fixOf(check, src, vs).length);
	}

	@:pin('control')
	@:killer('M-PMW-FLOAT-FIX')
	public function testUndeclaredTypeIsReportedButNotFixed(): Void {
		final src: String = 'class C {\n\tfunction f(x:Int):Void {\n\t\tvar v = x;\n\t\t$UPPER\n\t\t$LOWER\n\t}\n}';
		final check: PreferModuloWrap = new PreferModuloWrap();
		final vs: Array<Violation> = CheckFixture.violations(check, src);
		Assert.equals(1, vs.length);
		Assert.equals(0, CheckFixture.fixOf(check, src, vs).length);
	}

	@:pin('control')
	@:killer('M-PMW-COMMENT')
	public function testCommentBetweenTheLoopsKeepsTheFindingReportOnly(): Void {
		final src: String = wrap('$UPPER // keep\n\t\t$LOWER');
		final check: PreferModuloWrap = new PreferModuloWrap();
		final vs: Array<Violation> = CheckFixture.violations(check, src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('comment') >= 0);
		Assert.equals(0, CheckFixture.fixOf(check, src, vs).length);
	}

	public function testIfLeftBehindTheUpperLoopIsFixedToo(): Void {
		final text: String = fixed(wrap('if (v >= 360) $UPPER\n\t\t$LOWER'));
		Assert.isTrue(text.indexOf(WRAPPED) >= 0);
		Assert.isTrue(text.indexOf('if (v >= 360)') == -1);
	}

	@:pin('control')
	@:killer('M-PMW-IF-SAME')
	public function testIfWithAnotherConditionIsNotTheLoop(): Void {
		Assert.equals(0, violations(wrap('if (v >= 100) $UPPER\n\t\t$LOWER')).length);
	}

	@:pin('control')
	@:killer('M-PMW-FIX-TEXT')
	public function testComposesWithRedundantIfBeforeWhileInEitherOrder(): Void {
		final src: String = wrap('if (v >= 360) $UPPER\n\t\t$LOWER');
		final ifFirst: String = applied(applied(src, new RedundantIfBeforeWhile()), new PreferModuloWrap());
		final wrapFirst: String = applied(applied(src, new PreferModuloWrap()), new RedundantIfBeforeWhile());
		Assert.isTrue(ifFirst.indexOf(WRAPPED) >= 0);
		Assert.equals(ifFirst, wrapFirst);
	}

	private function wrap(body: String): String {
		return 'class C {\n\tstatic final DEG:Int = 360;\n\tfunction f(v:Int, n:Int):Void {\n\t\t$body\n\t}\n}';
	}

	private function violations(source: String): Array<Violation> {
		return CheckFixture.violations(new PreferModuloWrap(), source);
	}

	private function fixed(src: String): String {
		return applied(src, new PreferModuloWrap());
	}

	/** The source after `check`'s fix, canonicalized; `ERR: …` when the edit does not round-trip. */
	private function applied(src: String, check: Check): String {
		final vs: Array<Violation> = CheckFixture.violations(check, src);
		return switch CanonicalEdit.canonicalize(src, CheckFixture.fixOf(check, src, vs), true, new HaxeQueryPlugin()) {
			case Ok(text): text;
			case Err(message): 'ERR: $message';
		};
	}

}
