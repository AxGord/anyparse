package unit.check.common.expressions;

import anyparse.check.common.expressions.UnnecessaryBlock;

/** `unnecessary-block --fix` must not unwrap a block whose local would capture a later bare read of the same name. */
class UnnecessaryBlockLaterReadCaptureTest extends Test {

	/** `return t` reads the FIELD `t`; unwrapped, it would read the block's local. The finding stays, the unwrap is withheld. */
	@:pin('control')
	@:killer('M-UNNECESSARY-BLOCK-LATER-READ-GATE-OFF')
	public function testFixWithheldWhenLocalWouldCaptureALaterFieldRead(): Void {
		final src: String = wrap('foo(1);\n\t\t{\n\t\t\tvar t = 2;\n\t\t\tfoo(t);\n\t\t}\n\t\treturn t;');
		Assert.equals(1, CheckFixture.violations(new UnnecessaryBlock(), src).length);
		Assert.equals(src, CheckFixture.fixedSource(new UnnecessaryBlock(), src));
	}

	/** A later statement that never reads the block's name changes nothing by the unwrap. */
	@:pin('control')
	@:killer('M-UNNECESSARY-BLOCK-LATER-READ-GATE-ALWAYS')
	public function testFixUnwrapsWhenNoLaterStatementReadsTheLocal(): Void {
		final src: String = wrap('{\n\t\t\tvar t = 2;\n\t\t\tfoo(t);\n\t\t}\n\t\treturn 1;');
		Assert.notEquals(src, CheckFixture.fixedSource(new UnnecessaryBlock(), src));
	}

	/** A later read inside a function whose parameter is the name reads that parameter, never the lifted local. */
	@:pin('control')
	@:killer('M-TAILSCAN-PARAM-SHADOW-IGNORED')
	public function testFixUnwrapsWhenTheLaterReadIsShadowedByAnInnerFrame(): Void {
		final src: String = wrap('{\n\t\t\tvar t = 2;\n\t\t\tfoo(t);\n\t\t}\n\t\treturn bar(function(t:Int) return t);');
		Assert.notEquals(src, CheckFixture.fixedSource(new UnnecessaryBlock(), src));
	}

	/** A lambda BODY that is the bare name is a read, not a parameter, so it is still captured. */
	@:pin('guard')
	public function testFixWithheldWhenALambdaBodyReadsTheName(): Void {
		final src: String = wrap('{\n\t\t\tvar t = 2;\n\t\t\tfoo(t);\n\t\t}\n\t\treturn bar(x -> t);');
		Assert.equals(src, CheckFixture.fixedSource(new UnnecessaryBlock(), src));
	}

	/** The read sits beyond a `#if` region that wraps the block, in the frame the region's statements land in. */
	@:pin('control')
	@:killer('M-UNNECESSARY-BLOCK-LATER-READ-OUTER-DROPPED')
	public function testFixWithheldWhenTheLaterReadFollowsTheEnclosingCondRegion(): Void {
		final src: String = wrap('#if js\n\t\t{\n\t\t\tvar t = 2;\n\t\t\tfoo(t);\n\t\t}\n\t\t#end\n\t\treturn t;');
		Assert.equals(src, CheckFixture.fixedSource(new UnnecessaryBlock(), src));
	}

	private function wrap(body: String): String {
		return 'class C {\n\tvar t:Int = 0;\n\n\tfunction f(c:Bool):Int {\n\t\t$body\n\t}\n\n\tfunction foo(x:Int) {}\n\n'
			+ '\tfunction bar(g:Int->Int):Int return 0;\n}';
	}

}
