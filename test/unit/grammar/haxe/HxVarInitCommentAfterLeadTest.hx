package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import utest.Assert;
import utest.Test;

/**
 * Trivia-mode round trip of a comment between a variable initializer's `=` and its value, for a local, a typed
 * local, a field and the second binding of a multi-var: the writer keeps it where the source wrote it. A block
 * comment stays inline; a line comment ends its line and the value goes below it one indent deeper.
 */
class HxVarInitCommentAfterLeadTest extends Test {

	private static final forceBuild: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	@:pin('control')
	@:killer('M-VAR-INIT-AFTER-LEAD-BUNDLED')
	public function testBlockCommentAfterLocalInitLeadKept(): Void {
		final source: String = wrap('\t\tvar x = /* c */ 1;');
		Assert.equals('$source\n', roundTrip(source));
	}

	@:pin('control')
	@:killer('M-VAR-INIT-AFTER-LEAD-BUNDLED')
	public function testBlockCommentAfterTypedLocalInitLeadKept(): Void {
		final source: String = wrap('\t\tvar x:Int = /* c */ 1;');
		Assert.equals('$source\n', roundTrip(source));
	}

	@:pin('control')
	@:killer('M-VAR-INIT-AFTER-LEAD-BUNDLED')
	public function testLineCommentAfterLocalInitLeadKept(): Void {
		final source: String = wrap('\t\tvar x = // c\n\t\t\t1;');
		Assert.equals('$source\n', roundTrip(source));
	}

	@:pin('control')
	@:killer('M-VAR-INIT-LINE-COMMENT-VALUE-UNNESTED')
	public function testLineCommentNestsBrokenObjectLiteral(): Void {
		final source: String = wrap(
			'\t\tvar p = // p\n\t\t\t{\n\t\t\t\txxx: 1,\n\t\t\t\tyyyyyyyyyyyyyyyyyyyyyyyyyyyy: 2,\n'
			+ '\t\t\t\tzzzzzzzzzzzzzzzzzzzzzzzzzz: 3,\n\t\t\t\twwwwwwwwwwwwwwwwwwwwwwwwwwwwwwww: 4\n\t\t\t};'
		);
		Assert.equals('$source\n', roundTrip(source));
	}

	@:pin('control')
	@:killer('M-VAR-INIT-LINE-COMMENT-VALUE-UNNESTED')
	public function testLineCommentNestsBrokenArrayLiteral(): Void {
		final source: String = wrap(
			'\t\tvar q = // q\n\t\t\t[\n\t\t\t\taaaaaaaaaaaaaaaaaaaaaaaa,\n\t\t\t\tbbbbbbbbbbbbbbbbbbbbbbbbbbbb,\n'
			+ '\t\t\t\tcccccccccccccccccccccccccc,\n\t\t\t\tddddddddddddddddddddddddddd\n\t\t\t];'
		);
		Assert.equals('$source\n', roundTrip(source));
	}

	@:pin('control')
	@:killer('M-VAR-INIT-LINE-COMMENT-VALUE-UNNESTED')
	public function testLineCommentNestsWrappedCallArgs(): Void {
		final source: String = wrap(
			'\t\tvar z = // z\n\t\t\tsomeFunctionCall(aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb, '
			+ 'cccccccccccccccccccccccccccccccc,\n\t\t\t\tdddddddddddddddddddddddddddddd, eeeeeeeeeeeeeeeeeeee);'
		);
		Assert.equals('$source\n', roundTrip(source));
	}

	@:pin('control')
	@:killer('M-VAR-INIT-MIXED-RUN-VALUE-UNNESTED')
	public function testLineThenInlineCommentNestsBrokenObjectLiteral(): Void {
		final source: String = wrap(
			'\t\tvar p = // a\n\t\t\t/* b */ {\n\t\t\t\txxx: 1,\n\t\t\t\tyyyyyyyyyyyyyyyyyyyyyyyyyyyy: 2,\n'
			+ '\t\t\t\tzzzzzzzzzzzzzzzzzzzzzzzzzz: 3,\n\t\t\t\twwwwwwwwwwwwwwwwwwwwwwwwwwwwwwww: 4\n\t\t\t};'
		);
		Assert.equals('$source\n', roundTrip(source));
	}

	@:pin('control')
	@:killer('M-VAR-INIT-AFTER-LEAD-BUNDLED')
	public function testBlockCommentAfterFieldInitLeadKept(): Void {
		final source: String = 'class Foo {\n\tvar f = /* c */ 1;\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	@:pin('control')
	@:killer('M-VAR-INIT-AFTER-LEAD-BUNDLED')
	public function testBlockCommentAfterSecondMultiVarInitLeadKept(): Void {
		final source: String = wrap('\t\tvar a = 1, b = /* d */ 2;');
		Assert.equals('$source\n', roundTrip(source));
	}

	private function wrap(body: String): String {
		return 'class Foo {\n\tfunction bar() {\n$body\n\t}\n}';
	}

	private function roundTrip(source: String): String {
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		return HaxeModuleTriviaWriter.write(ast);
	}

}
