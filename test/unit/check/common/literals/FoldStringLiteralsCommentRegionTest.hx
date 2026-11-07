package unit.check.common.literals;

/**
 * Which `//` / `/*` marker the fold refuses an operand for: a comment the lexer reports, never text inside a string
 * literal. The refusal reads the lexical regions, so a marker in a URL or a path folds like any other literal.
 */
class FoldStringLiteralsCommentRegionTest extends FoldStringLiteralsCheckTestBase {

	@:pin('control') @:killer('M-REGIONS-COMMENT-OPENS-STRING-BLIND')
	public function testLineCommentMarkerInsideAStringDoesNotRefuseTheChain(): Void {
		final src: String = 'class C { function f() { final a = "http://x" + "/y"; } }';
		Assert.equals(1, violations(src).length);
		Assert.equals('"http://x/y"', foldOf(src));
	}

	@:pin('control') @:killer('M-REGIONS-COMMENT-OPENS-STRING-BLIND')
	public function testBlockCommentMarkerInsideAStringDoesNotRefuseTheChain(): Void {
		final src: String = 'class C { function f(p:String) { final a = "a/*" + p + "b"; } }';
		Assert.equals(1, violations(src).length);
	}

}
