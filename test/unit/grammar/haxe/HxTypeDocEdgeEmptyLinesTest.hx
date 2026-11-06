package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import utest.Assert;
import utest.Test;

/**
 * `<kind>EmptyLines.beginTypeIfDocComments` / `endTypeIfDocComments` for an enum, a typedef and an `enum abstract`
 * body: the blank lines after `{` and before `}` of a body holding a doc comment. Every expected text is the fork's
 * output for the same input and config; the doc-commented member is the last one, so the blank
 * after a doc-commented member, which these keys do not govern, stays out of the comparison.
 */
@:nullSafety(Strict)
class HxTypeDocEdgeEmptyLinesTest extends Test {

	private static inline final DOC_EDGES: String = '{"emptyLines":{'
		+ '"enumEmptyLines":{"betweenFields":0,"existingBetweenFields":"remove","beginTypeIfDocComments":1,"endTypeIfDocComments":1},'
		+ '"typedefEmptyLines":{"betweenFields":0,"existingBetweenFields":"remove","beginTypeIfDocComments":1,"endTypeIfDocComments":1},'
		+ '"enumAbstractEmptyLines":{"betweenVars":0,"existingBetweenFields":"remove","beginTypeIfDocComments":1,"endTypeIfDocComments":1},'
		+ '"beforeDocCommentEmptyLines":"one"}}';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-BODY-HAS-DOC-ALWAYS')
	public function testAPackedEnumWithoutADocTakesNoEdgeBlanks(): Void {
		Assert.equals('enum E {\n\tA;\n\tB;\n}\n', write('enum E {\n\tA;\n\n\tB;\n}\n', DOC_EDGES));
	}

	@:pin('control')
	@:killer('M-DOC-EDGE-READS-OFF')
	public function testAnEnumWithADocTakesItsDocEdges(): Void {
		Assert.equals('enum F {\n\n\tA;\n\n\t/** doc */\n\tB;\n\n}\n', write('enum F {\n\tA;\n\t/** doc */\n\tB;\n}\n', DOC_EDGES));
	}

	@:pin('control')
	@:killer('M-TYPEDEF-DOC-EDGE-OFF')
	public function testATypedefWithADocTakesItsDocEdges(): Void {
		Assert.equals(
			'typedef U = {\n\n\tvar a:Int;\n\n\t/** doc */\n\tvar b:Int;\n\n}\n',
			write('typedef U = {\n\tvar a:Int;\n\t/** doc */\n\tvar b:Int;\n}\n', DOC_EDGES)
		);
	}

	@:pin('control')
	@:killer('M-ENUM-ABSTRACT-DOC-KEY-UNREAD')
	public function testAnEnumAbstractWithADocTakesItsDocEdges(): Void {
		Assert.equals(
			'enum abstract L(Int) {\n\n\tvar X = 1;\n\n\t/** doc */\n\tvar Y = 2;\n\n}\n',
			write('enum abstract L(Int) {\n\tvar X = 1;\n\t/** doc */\n\tvar Y = 2;\n}\n', DOC_EDGES)
		);
	}

	/** No `…TypeIfDocComments` knob exists for a class body and no cut gives it one: the config names the other kinds only. */
	@:pin('guard') // noqa: guard-pin-arm-reach
	public function testAClassWithADocIsUntouched(): Void {
		Assert.equals(
			'class C {\n\tvar x:Int;\n\n\t/** doc */\n\tvar y:Int;\n}\n',
			write('class C {\n\tvar x:Int;\n\n\t/** doc */\n\tvar y:Int;\n}\n', DOC_EDGES)
		);
	}

	@:pin('control')
	@:killer('M-DOC-EDGE-IFDOC-IGNORED')
	public function testAZeroDocCountReplacesAStatedEdge(): Void {
		final json: String = '{"emptyLines":{"enumEmptyLines":{"betweenFields":0,"existingBetweenFields":"remove",'
			+ '"beginType":1,"endType":1,"beginTypeIfDocComments":0,"endTypeIfDocComments":0},"beforeDocCommentEmptyLines":"one"}}';
		Assert.equals('enum E {\n\n\tA;\n\tB;\n\n}\n', write('enum E {\n\tA;\n\tB;\n}\n', json));
		Assert.equals('enum F {\n\tA;\n\n\t/** doc */\n\tB;\n}\n', write('enum F {\n\tA;\n\t/** doc */\n\tB;\n}\n', json));
		Assert.equals('enum G {\n\t/** doc */\n\tA;\n\tB;\n}\n', write('enum G {\n\t/** doc */\n\tA;\n\tB;\n}\n', json));
	}

	@:pin('control')
	@:killer('M-DOC-EDGE-ABSENT-KEY-NULLS')
	public function testAbsentDocKeysKeepTheStatedEdges(): Void {
		final json: String = '{"emptyLines":{"enumEmptyLines":{"betweenFields":0,"existingBetweenFields":"remove",'
			+ '"beginType":1,"endType":1},"beforeDocCommentEmptyLines":"one"}}';
		Assert.equals('enum F {\n\n\tA;\n\n\t/** doc */\n\tB;\n\n}\n', write('enum F {\n\tA;\n\t/** doc */\n\tB;\n}\n', json));
	}

	private function write(src: String, json: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HaxeFormatConfigLoader.loadHxFormatJson(json));
	}

}
