package unit.check.scan;

import anyparse.check.scan.TailScan;
import anyparse.query.CondDirectives.CondDirective;

/**
 * `TailScan.hasConditionalCompilation` answers from the generated directive events, so a
 * directive-like spelling inside a string or a comment is not conditional compilation.
 */
class TailScanTest extends Test {

	private static final REAL: String = 'class C { function f() { helper(#if debug 1 #else 2 #end); } }';
	private static final IN_STRING: String = 'class C { function f() { helper("#if debug"); } }';
	private static final IN_COMMENT: String = 'class C { function f() { helper(); // #end\n } }';

	@:pin('control')
	@:killer('M-TAILSCAN-DIRECTIVES-IGNORED')
	public function testRealDirectiveRefuses(): Void {
		Assert.isTrue(held(REAL));
	}

	@:pin('control')
	@:killer('M-TAILSCAN-STRING-IS-DIRECTIVE')
	public function testDirectiveSpellingInStringOrCommentDoesNotRefuse(): Void {
		Assert.isFalse(held(IN_STRING));
		Assert.isFalse(held(IN_COMMENT));
	}

	private static function held(source: String): Bool {
		final directives: Array<CondDirective> = TailScan.directivesOf(source, new HaxeQueryPlugin());
		return TailScan.hasConditionalCompilation(directives, 0, source.length);
	}

}
