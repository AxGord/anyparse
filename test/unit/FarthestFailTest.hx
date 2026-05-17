package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.runtime.ParseError;

/**
 * Covers the farthest-failure tracker (`Parser.maxFailPos`,
 * re-surfaced by the generated public entry). A syntax error deep
 * inside an otherwise-valid class must report a locus at the broken
 * token, not collapse to the file head as it did before the tracker
 * (recursive-descent rollback discarded inner positions).
 *
 * The success path must be byte-identical — the entry wrap only
 * rewrites the error path.
 */
class FarthestFailTest extends Test {

	public function testDeepErrorLocusNotFileHead():Void {
		final src:String = 'class Foo {\n\tfunction bar():Void {\n\t\tvar x:Int = ;\n\t}\n}';
		final badAt:Int = src.indexOf('= ;') + 2;
		try {
			HaxeParser.parse(src);
			Assert.fail('expected a ParseError on broken init expression');
		} catch (exception:ParseError) {
			// Locus must be deep in the method body, far past offset 0.
			Assert.isTrue(exception.span.from > 20,
				'span.from ${exception.span.from} should be deep, not file head');
			// And within a few chars of the offending `;`.
			Assert.isTrue(Math.abs(exception.span.from - badAt) <= 3,
				'span.from ${exception.span.from} should be near the bad token at $badAt');
		}
	}

	/**
	 * Regression for the entry-point try/catch wrap: a valid decl
	 * followed by garbage must still report the pre-existing
	 * "trailing data" locus at the garbage, not be swallowed or
	 * shifted by the farthest-failure rewrite.
	 */
	public function testTrailingDataLocus():Void {
		final src:String = 'class Foo { } @@@bogus';
		final badAt:Int = src.indexOf('@@@');
		try {
			HaxeParser.parse(src);
			Assert.fail('expected a ParseError on trailing garbage');
		} catch (exception:ParseError) {
			Assert.isTrue(Math.abs(exception.span.from - badAt) <= 3,
				'span.from ${exception.span.from} should pin the trailing garbage at $badAt');
		}
	}

	public function testValidSourceStillParses():Void {
		final src:String = 'class Foo { var x:Int; }';
		final decl:HxClassDecl = HaxeParser.parse(src);
		Assert.notNull(decl);
	}
}
