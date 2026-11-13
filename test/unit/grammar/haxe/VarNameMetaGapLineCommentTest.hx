package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import utest.Assert;
import utest.Test;

/**
 * A comment in the gap between a `var`'s metadata and its name keeps the line it was written on:
 * an own-line line comment stays own-line, a trailing one stays trailing, a block comment stays inline.
 */
class VarNameMetaGapLineCommentTest extends Test {

	private static final forceBuild: Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;

	@:pin('control')
	@:killer('M-GAP-LINE-COMMENT-JOINS')
	public function testAnOwnLineLineCommentStaysOnItsOwnLine(): Void {
		assertKeptAndOnePass('class C {\n\tfunction f() {\n\t\tvar @:e\n\t\t// c3\n\t\tx = 1;\n\t}\n}\n');
	}

	@:pin('guard')
	public function testATrailingLineCommentStaysTrailing(): Void {
		assertKeptAndOnePass('class C {\n\tfunction f() {\n\t\tvar @:e // c\n\t\ty = 1;\n\t}\n}\n');
	}

	@:pin('guard')
	public function testASameLineBlockCommentStaysInline(): Void {
		assertKeptAndOnePass('class C {\n\tfunction f() {\n\t\tvar @:e /* c */ z = 1;\n\t}\n}\n');
	}

	/** The metadata keeps only the block comment as its trailing one, so the line comment after it is the gap's. */
	@:pin('control')
	@:killer('M-GAP-LINE-COMMENT-ALWAYS-BREAKS')
	public function testALineCommentAfterATrailingBlockCommentStaysTrailing(): Void {
		assertKeptAndOnePass('class C {\n\tfunction f() {\n\t\tvar @:e /* b */ // l2\n\t\tt = 1;\n\t}\n}\n');
	}

	@:pin('control')
	@:killer('M-GAP-LINE-COMMENT-ALWAYS-BREAKS')
	public function testAnOwnLineBlockThenLineCommentJoinsTheMetadataLineInOnePass(): Void {
		final once: String = defaults('class C {\n\tfunction f() {\n\t\tvar @:e\n\t\t/* b */ // l3\n\t\ts = 1;\n\t}\n}\n');
		Assert.equals('class C {\n\tfunction f() {\n\t\tvar @:e /* b */ // l3\n\t\ts = 1;\n\t}\n}\n', once);
		Assert.equals(once, defaults(once));
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
