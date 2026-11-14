package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * A comment between a local metadata and the `var` it annotates keeps the line it was written on:
 * an own-line comment stays own-line, a same-line block comment stays inline.
 */
class LocalMetaGapCommentTest extends Test {

	private static final forceBuild: Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;

	@:pin('control')
	@:killer('M-META-EXPR-GAP-COMMENT-DROPPED')
	public function testAnOwnLineLineCommentStaysOnItsOwnLine(): Void {
		assertKeptAndOnePass('class C {\n\tfunction f() {\n\t\t@:a\n\t\t// c3\n\t\tvar x = 1;\n\t}\n}\n');
	}

	@:pin('control')
	@:killer('M-GAP-OWN-LINE-BLOCK-JOINS')
	public function testAnOwnLineBlockCommentStaysOnItsOwnLine(): Void {
		assertKeptAndOnePass('class C {\n\tfunction f() {\n\t\t@:a\n\t\t/* c */\n\t\tvar x = 1;\n\t}\n}\n');
	}

	@:pin('control')
	@:killer('M-META-EXPR-GAP-COMMENT-DROPPED')
	public function testASameLineBlockCommentStaysInline(): Void {
		assertKeptAndOnePass('class C {\n\tfunction f() {\n\t\t@:a /* c4 */ var y = 1;\n\t}\n}\n');
	}

	@:pin('control')
	@:killer('M-META-EXPR-GAP-FIRST-BREAKS')
	public function testASameLineLineCommentStaysTrailing(): Void {
		assertKeptAndOnePass('class C {\n\tfunction f() {\n\t\t@:a // c\n\t\tvar y = 1;\n\t}\n}\n');
	}

	/** The default policy breaks after each metadata; the comment stays where it was written after the last one. */
	@:pin('control')
	@:killer('M-META-EXPR-GAP-COMMENT-DROPPED')
	public function testTwoMetadataKeepAnOwnLineLineComment(): Void {
		assertKeptAndOnePass('class C {\n\tfunction f() {\n\t\t@:a\n\t\t@:b\n\t\t// c\n\t\tvar x = 1;\n\t}\n}\n');
	}

	@:pin('control')
	@:killer('M-META-EXPR-GAP-COMMENT-DROPPED')
	public function testTwoMetadataKeepASameLineBlockComment(): Void {
		assertKeptAndOnePass('class C {\n\tfunction f() {\n\t\t@:a\n\t\t@:b /* c */ var y = 1;\n\t}\n}\n');
	}

	@:pin('control')
	@:killer('M-META-EXPR-GAP-COMMENT-DROPPED')
	public function testAnExpressionMetadataKeepsItsBlockComment(): Void {
		assertKeptAndOnePass('class C {\n\tfunction f() {\n\t\tfoo(@:a /* c */ x);\n\t}\n}\n');
	}

	private static function assertKeptAndOnePass(src: String): Void {
		final once: String = defaults(src);
		Assert.equals(src, once);
		Assert.equals(once, defaults(once));
	}

	private static function defaults(src: String): String {
		return HaxeModuleTriviaWriter.write(
			HaxeModuleTriviaParser.parse(src), new HxModuleWriteOptions(HaxeFormat.instance.defaultWriteOptions)
		);
	}

}
