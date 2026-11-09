package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import utest.Assert;
import utest.Test;

/**
 * A type body ending in orphan comments takes its end-edge blanks (`endType` / `endTypeIfDocComments`) after the last
 * comment, in front of `}`, for every kind that reads them; the blank in front of the comments stays the comment
 * run's own. Expected texts are the fork's output on the same source and config.
 */
@:nullSafety(Strict)
class HxTypeEndOrphanCommentTest extends Test {

	public function new(): Void {
		super();
	}

	@:pin('control') @:killer('M-ENDTYPE-BLOCK-TRAIL')
	public function testClassEndTypeAfterTrailingDoc(): Void {
		assertWrites('class C {\n\tvar a:Int;\n\t/** x */\n}\n', cfg('classEmptyLines', 1), 'class C {\n\tvar a:Int;\n\t/** x */\n\n}\n');
		assertWrites('class C {\n\tvar a:Int;\n\t/** x */\n}\n', cfg('classEmptyLines', 0), 'class C {\n\tvar a:Int;\n\t/** x */\n}\n');
	}

	@:pin('control') @:killer('M-ENDTYPE-BLOCK-TRAIL')
	public function testClassEndTypeAfterTrailingLineComment(): Void {
		final src: String = 'class C {\n\tfunction e() {\n\t\ta();\n\t}\n\n\tfunction f() {\n\t\ta();\n\t}\n\t// x\n}\n';
		assertWrites(
			src, cfg('classEmptyLines', 1),
			'class C {\n\tfunction e() {\n\t\ta();\n\t}\n\n\tfunction f() {\n\t\ta();\n\t}\n\n\t// x\n\n}\n'
		);
		assertWrites(
			src, cfg('classEmptyLines', 0), 'class C {\n\tfunction e() {\n\t\ta();\n\t}\n\n\tfunction f() {\n\t\ta();\n\t}\n\n\t// x\n}\n'
		);
	}

	@:pin('control') @:killer('M-ENDTYPE-BLOCK-TRAIL')
	public function testEnumEndTypeAfterTrailingComment(): Void {
		assertWrites('enum E {\n\tA;\n\t/** x */\n}\n', cfg('enumEmptyLines', 1), 'enum E {\n\tA;\n\t/** x */\n\n}\n');
		assertWrites('enum E {\n\tA;\n\t/** x */\n}\n', cfg('enumEmptyLines', 0), 'enum E {\n\tA;\n\t/** x */\n}\n');
		assertWrites('enum E {\n\tA;\n\t// x\n}\n', cfg('enumEmptyLines', 1), 'enum E {\n\tA;\n\t// x\n\n}\n');
		assertWrites('enum E {\n\tA;\n\t// x\n}\n', cfg('enumEmptyLines', 0), 'enum E {\n\tA;\n\t// x\n}\n');
	}

	@:pin('control') @:killer('M-ENDTYPE-BLOCK-TRAIL')
	public function testEnumAbstractEndTypeAfterTrailingComment(): Void {
		assertWrites(
			'enum abstract A(Int) {\n\tvar X = 1;\n\t/** x */\n}\n', cfg('enumAbstractEmptyLines', 1),
			'enum abstract A(Int) {\n\tvar X = 1;\n\t/** x */\n\n}\n'
		);
		assertWrites(
			'enum abstract A(Int) {\n\tvar X = 1;\n\t// x\n}\n', cfg('enumAbstractEmptyLines', 1),
			'enum abstract A(Int) {\n\tvar X = 1;\n\t// x\n\n}\n'
		);
	}

	@:pin('control') @:killer('M-ENDABS-ORPHAN-LINE-BLANK')
	public function testEnumAbstractForcesNoBlankBeforeTrailingLineComment(): Void {
		assertWrites(
			'enum abstract A(Int) {\n\tvar X = 1;\n\tvar Y = 2;\n\t// x\n}\n', cfg('enumAbstractEmptyLines', 0),
			'enum abstract A(Int) {\n\tvar X = 1;\n\tvar Y = 2;\n\t// x\n}\n'
		);
	}

	@:pin('control') @:killer('M-ENDTYPE-TYPEDEF-TRAIL')
	public function testTypedefEndTypeAfterTrailingDoc(): Void {
		assertWrites(
			'typedef T = {\n\tvar a:Int;\n\t/** x */\n}\n', cfg('typedefEmptyLines', 1), 'typedef T = {\n\tvar a:Int;\n\t/** x */\n\n}\n'
		);
		assertWrites(
			'typedef T = {\n\tvar a:Int;\n\t/** x */\n}\n', cfg('typedefEmptyLines', 0), 'typedef T = {\n\tvar a:Int;\n\t/** x */\n}\n'
		);
	}

	@:pin('control') @:killer('M-ENDTYPE-TYPEDEF-TRAIL')
	public function testTypedefEndTypeAfterTrailingLineComment(): Void {
		assertWrites('typedef T = {\n\tvar a:Int;\n\t// x\n}\n', cfg('typedefEmptyLines', 1), 'typedef T = {\n\tvar a:Int;\n\t// x\n\n}\n');
		assertWrites('typedef T = {\n\tvar a:Int;\n\t// x\n}\n', cfg('typedefEmptyLines', 0), 'typedef T = {\n\tvar a:Int;\n\t// x\n}\n');
	}

	@:pin('control') @:killer('M-ENDTYPE-TYPEDEF-EMPTY')
	public function testTypedefEndTypeOnACommentOnlyBody(): Void {
		assertWrites('typedef T = {\n\t// x\n}\n', cfg('typedefEmptyLines', 1), 'typedef T = {\n\t// x\n}\n');
	}

	@:pin('control') @:killer('M-ENDTYPE-BLOCK-TRAIL')
	public function testEndTypeIfDocCommentsReadsATrailingDoc(): Void {
		final json: String = '{"emptyLines":{"enumEmptyLines":{"endType":0,"endTypeIfDocComments":1}}}';
		assertWrites('enum E {\n\tA;\n\t/** x */\n}\n', json, 'enum E {\n\tA;\n\t/** x */\n\n}\n');
		assertWrites('enum E {\n\tA;\n\t// x\n}\n', json, 'enum E {\n\tA;\n\t// x\n}\n');
	}

	@:pin('control') @:killer('M-ENDTYPE-TYPEDEF-TRAIL')
	public function testTypedefEndTypeIfDocCommentsReadsATrailingDoc(): Void {
		final json: String = '{"emptyLines":{"typedefEmptyLines":{"endType":0,"endTypeIfDocComments":1}}}';
		assertWrites('typedef T = {\n\tvar a:Int;\n\t/** x */\n}\n', json, 'typedef T = {\n\tvar a:Int;\n\t/** x */\n\n}\n');
	}

	@:pin('control') @:killer('M-ENDTYPE-TRAIL-SRC-BLANK')
	public function testKeepPolicyDoesNotReadTheBlankBeforeTheCommentsAsTheEdge(): Void {
		assertWrites(
			'class C {\n\tvar a:Int;\n\n\t/** x */\n}\n', '{"emptyLines":{"beforeRightCurly":"keep"}}',
			'class C {\n\tvar a:Int;\n\n\t/** x */\n}\n'
		);
	}

	@:pin('control') @:killer('M-ENDTYPE-BLOCK-COMMENT-ONLY')
	public function testBlockEndTypeOnACommentOnlyBody(): Void {
		assertWrites('class C {\n\t/** x */\n}\n', cfg('classEmptyLines', 1), 'class C {\n\t/** x */\n}\n');
		assertWrites('class C {\n\t// x\n}\n', cfg('classEmptyLines', 1), 'class C {\n\t// x\n}\n');
		assertWrites('enum E {\n\t// x\n}\n', cfg('enumEmptyLines', 1), 'enum E {\n\t// x\n}\n');
	}

	private function cfg(section: String, endType: Int): String {
		return '{"emptyLines":{"afterLeftCurly":"keep","beforeRightCurly":"keep","$section":{"beginType":0,"endType":$endType}}}';
	}

	private function assertWrites(src: String, json: String, expected: String): Void {
		final once: String = write(src, json);
		Assert.equals(expected, once);
		Assert.equals(once, write(once, json), 'a second format moved it');
	}

	private function write(src: String, json: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HaxeFormatConfigLoader.loadHxFormatJson(json));
	}

}
