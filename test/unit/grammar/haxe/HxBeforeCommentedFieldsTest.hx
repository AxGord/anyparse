package unit.grammar.haxe;

import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.format.HaxeFormatConfigLoader;
import utest.Assert;
import utest.Test;

/** `beforeCommentedFields`: a member headed by a run of `//` comments takes one blank line in front of it. */
final class HxBeforeCommentedFieldsTest extends Test {

	private static final VALUE_LIST: String =
		'"betweenVars":0,"existingBetweenFields":"remove","beginType":0,"endType":0,"afterFieldsWithDocComments":"none"';
	private static final ENUM_ABSTRACT_ON: String =
		'{"emptyLines":{"beforeDocCommentEmptyLines":"ignore","enumAbstractEmptyLines":{$VALUE_LIST,"beforeCommentedFields":1}}}';
	private static final ENUM_ABSTRACT_OFF: String =
		'{"emptyLines":{"beforeDocCommentEmptyLines":"ignore","enumAbstractEmptyLines":{$VALUE_LIST}}}';
	private static final CLASS_ON: String = '{"emptyLines":{"beforeCommentedFields":1}}';
	private static final GROUPS: String = 'enum abstract A(String) {\n\t// first group\n\tfinal ONE = \'one\';\n\t// second group\n'
		+ '\tfinal TWO = \'two\';\n\tfinal THREE = \'three\';\n}';
	private static final GROUPS_SET_OFF: String = 'enum abstract A(String) {\n\t// first group\n\tfinal ONE = \'one\';\n\n'
		+ '\t// second group\n\tfinal TWO = \'two\';\n\tfinal THREE = \'three\';\n}';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-HEADING-ADDS-ELEM')
	public function testAGroupHeadingTakesOneBlankLine(): Void {
		Assert.equals(GROUPS_SET_OFF, write(GROUPS, ENUM_ABSTRACT_ON));
		Assert.equals(GROUPS, write(GROUPS_SET_OFF, ENUM_ABSTRACT_OFF));
	}

	@:pin('control')
	@:killer('M-HEADING-FIRST-MEMBER')
	public function testTheFirstMembersHeadingTakesNone(): Void {
		final src: String = 'enum abstract A(Int) {\n\t// only group\n\tfinal ONE = 1;\n\tfinal TWO = 2;\n}';
		Assert.equals(src, write(src, ENUM_ABSTRACT_ON));
	}

	@:pin('guard')
	public function testATrailingCommentIsNotAHeading(): Void {
		final src: String = 'enum abstract A(Int) {\n\tfinal ONE = 1; // note\n\tfinal TWO = 2;\n}';
		Assert.equals(src, write(src, ENUM_ABSTRACT_ON));
	}

	@:pin('control')
	@:killer('M-HEADING-LINE-RUN-ONLY')
	public function testADocOrBlockCommentIsNotAHeading(): Void {
		final src: String = 'enum abstract A(Int) {\n\tfinal ONE = 1;\n\t/** doc */\n\tfinal TWO = 2;\n\t/* block */\n\tfinal THREE = 3;\n'
			+ '\t/** doc */\n\t// line\n\tfinal FOUR = 4;\n}';
		Assert.equals(src, write(src, ENUM_ABSTRACT_ON));
		Assert.equals(src, write(src, ENUM_ABSTRACT_OFF));
	}

	@:pin('control')
	@:killer('M-HEADING-ADDS-ELEM')
	public function testAClassAnEnumAndAnAbstractBody(): Void {
		Assert.equals(
			'class C {\n\tvar a:Int;\n\n\t// g\n\tvar b:Int;\n}', write('class C {\n\tvar a:Int;\n\t// g\n\tvar b:Int;\n}', CLASS_ON)
		);
		Assert.equals(
			'enum E {\n\tA;\n\n\t// g\n\tB;\n\tC;\n}',
			write('enum E {\n\tA;\n\t// g\n\tB;\n\tC;\n}', '{"emptyLines":{"enumEmptyLines":{"beforeCommentedFields":1}}}')
		);
		Assert.equals(
			'abstract P(Int) {\n\tvar a:Int;\n\n\t// g\n\tvar b:Int;\n}',
			write('abstract P(Int) {\n\tvar a:Int;\n\t// g\n\tvar b:Int;\n}', CLASS_ON)
		);
		Assert.equals(
			'interface I {\n\tfunction a():Void;\n\n\t// g\n\tfunction b():Void;\n}',
			write('interface I {\n\tfunction a():Void;\n\t// g\n\tfunction b():Void;\n}', CLASS_ON)
		);
	}

	@:pin('control')
	@:killer('M-HEADING-TYPEDEF-FORCE-MULTI')
	public function testATypedefBody(): Void {
		Assert.equals(
			'typedef T = {\n\tvar a:Int;\n\n\t// g\n\tvar b:Int;\n}',
			write(
				'typedef T = {\n\tvar a:Int;\n\t// g\n\tvar b:Int;\n}', '{"emptyLines":{"typedefEmptyLines":{"beforeCommentedFields":1}}}'
			)
		);
	}

	/** A body `abstractRulesUnlessValueList` hands to the abstract rules reads the abstract body's key, not its own. */
	@:pin('control')
	@:killer('M-HEADING-ADDS-ELEM')
	public function testAnEnumAbstractUnderTheAbstractRulesReadsTheAbstractKey(): Void {
		Assert.equals(
			GROUPS_SET_OFF,
			write(GROUPS, '{"emptyLines":{"beforeCommentedFields":1,"enumAbstractEmptyLines":{"abstractRulesUnlessValueList":true}}}')
		);
		Assert.equals(
			GROUPS,
			write(GROUPS, '{"emptyLines":{"enumAbstractEmptyLines":{"abstractRulesUnlessValueList":true,"beforeCommentedFields":1}}}')
		);
	}

	@:pin('guard')
	public function testOffByDefault(): Void {
		Assert.equals(GROUPS, write(GROUPS, '{}'));
		Assert.equals(GROUPS, write(GROUPS, '{"emptyLines":{"enumAbstractEmptyLines":{"beforeCommentedFields":0}}}'));
		Assert.equals('class C {\n\tvar a:Int;\n\t// g\n\tvar b:Int;\n}', write('class C {\n\tvar a:Int;\n\t// g\n\tvar b:Int;\n}', '{}'));
		Assert.equals('enum E {\n\tA;\n\t// g\n\tB;\n}', write('enum E {\n\tA;\n\t// g\n\tB;\n}', '{}'));
		Assert.equals(
			'typedef T = {\n\tvar a:Int;\n\t// g\n\tvar b:Int;\n}', write('typedef T = {\n\tvar a:Int;\n\t// g\n\tvar b:Int;\n}', '{}')
		);
	}

	@:pin('control')
	@:killer('M-HEADING-CONFIG-ENUM-ABSTRACT')
	public function testTheKeysReachTheirKnobs(): Void {
		Assert.equals(1, HaxeFormatConfigLoader.loadHxFormatJson(ENUM_ABSTRACT_ON).enumAbstractBeforeCommentedFields);
		Assert.equals(0, HaxeFormatConfigLoader.loadHxFormatJson(ENUM_ABSTRACT_ON).beforeCommentedFields);
		Assert.equals(0, HaxeFormatConfigLoader.loadHxFormatJson('{}').enumAbstractBeforeCommentedFields);
	}

	@:pin('guard')
	public function testTheLayoutIsAFixedPoint(): Void {
		final once: String = write(GROUPS, ENUM_ABSTRACT_ON);
		Assert.equals(once, write(once, ENUM_ABSTRACT_ON));
	}

	private static function write(src: String, json: String): String {
		final opt: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(json);
		return HxWriteFixture.triviaWrite(src, opt);
	}

}
