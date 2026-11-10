package unit.grammar.haxe;

import utest.Assert;
import utest.Test;

/**
 * A block comment leading the FIRST element of a list laid out by its wrap rules stays before that element, in one rewrite.
 */
final class HxFirstElementBlockLeadTest extends Test {

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-OPEN-GLUED-COMMENT-AS-TRAIL')
	public function testATypedefBodyTakesOneRewrite(): Void {
		// A body of two or more fields goes one per line, so the flat forms are a one-field body and an anon type argument.
		final once: String = HxWriteFixture.triviaWrite('typedef T = {\n\t/* Comment */ a: Float\n}', '{}');
		Assert.equals('typedef T = {/* Comment */ a:Float}', once);
		Assert.equals(once, HxWriteFixture.triviaWrite(once, '{}'));
		final single: String = HxWriteFixture.triviaWrite('typedef T = Array<{\n\t/* Comment */ a: Float,\n\tb: Float\n}>', '{}');
		Assert.equals('typedef T = Array<{/* Comment */ a:Float, b:Float}>', single);
		Assert.equals(single, HxWriteFixture.triviaWrite(single, '{}'));
	}

	@:pin('control')
	@:killer('M-OPEN-GLUED-COMMENT-AS-TRAIL')
	public function testAnInlineAnonTypeTakesOneRewrite(): Void {
		final once: String = HxWriteFixture.triviaWrite(
			'class C {\n\tvar x:{\n\t\t/* Comment */ a: Float,\n\t\t/* Comment */ b: Float\n\t};\n}', '{}'
		);
		Assert.equals('class C {\n\tvar x:{/* Comment */ a:Float, /* Comment */ b:Float};\n}', once);
		Assert.equals(once, HxWriteFixture.triviaWrite(once, '{}'));
	}

	@:pin('guard')
	public function testABlockCommentEndingTheOpenLineStaysThere(): Void {
		final src: String = 'class C {\n\tvar x = { /* c */\n\t\ta: 1,\n\t\tb: 2\n\t};\n}';
		Assert.equals(src, HxWriteFixture.triviaWrite(src, '{}'));
	}

}
