package unit.grammar.haxe;

import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.format.HaxeFormatConfigLoader;
import utest.Assert;
import utest.Test;

/**
 * `glueCommentedGroups`: a run of `//` comments heads a subgroup, and the same-kind members the source holds glued
 * under it take no counted between-members blank.
 */
final class HxGlueCommentedGroupsTest extends Test {

	private static final CLASS_ON: String =
		'{"emptyLines":{"beforeCommentedFields":1,"glueCommentedGroups":true,"classEmptyLines":{"betweenVars":1}}}';
	private static final CLASS_OFF: String = '{"emptyLines":{"beforeCommentedFields":1,"classEmptyLines":{"betweenVars":1}}}';
	private static final COLOURS: String = 'class C {\n\tvar x:Int;\n\t// colours\n\tvar r:Int;\n\tvar g:Int;\n\tvar b:Int;\n}';
	private static final COLOURS_GLUED: String = 'class C {\n\tvar x:Int;\n\n\t// colours\n\tvar r:Int;\n\tvar g:Int;\n\tvar b:Int;\n}';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-GROUP-GLUE-GATE')
	public function testAHeadedGroupStaysGlued(): Void {
		Assert.equals(COLOURS_GLUED, write(COLOURS, CLASS_ON));
		Assert.equals(
			'class C {\n\tvar x:Int;\n\n\t// colours\n\tvar r:Int;\n\n\tvar g:Int;\n\n\tvar b:Int;\n}', write(COLOURS, CLASS_OFF)
		);
	}

	@:pin('control')
	@:killer('M-GROUP-OPEN-CONTINUES')
	public function testTheGroupRunsToItsLastGluedMember(): Void {
		Assert.equals(COLOURS_GLUED, write(COLOURS_GLUED, CLASS_ON));
	}

	@:pin('control')
	@:killer('M-GROUP-SOURCE-BLANK')
	public function testASourceBlankStaysAndEndsTheGroup(): Void {
		final src: String = 'class C {\n\t// colours\n\tvar r:Int;\n\tvar g:Int;\n\n\tvar b:Int;\n\tvar a:Int;\n}';
		Assert.equals('class C {\n\t// colours\n\tvar r:Int;\n\tvar g:Int;\n\n\tvar b:Int;\n\n\tvar a:Int;\n}', write(src, CLASS_ON));
	}

	@:pin('control')
	@:killer('M-GROUP-GLUE-GATE')
	public function testFunctionsAndEnumConstructors(): Void {
		final fns: String = 'class C {\n\tvar x:Int;\n\n\t// handlers\n\tfunction a():Void {}\n\tfunction b():Void {}\n}';
		Assert.equals(fns, write(fns, '{"emptyLines":{"glueCommentedGroups":true}}'));
		Assert.equals(
			'enum E {\n\tA;\n\n\t// g\n\tB;\n\tC;\n}',
			write(
				'enum E {\n\tA;\n\t// g\n\tB;\n\tC;\n}', '{"emptyLines":{"enumEmptyLines":{"betweenFields":1,"glueCommentedGroups":true}}}'
			)
		);
		final iface: String = 'interface I {\n\t// g\n\tfunction a():Void;\n\tfunction b():Void;\n}';
		Assert.equals(iface, write(iface, '{"emptyLines":{"glueCommentedGroups":true,"interfaceEmptyLines":{"betweenFunctions":1}}}'));
		final abs: String = 'abstract P(Int) {\n\t// g\n\tvar a:Int;\n\tvar b:Int;\n}';
		Assert.equals(abs, write(abs, '{"emptyLines":{"glueCommentedGroups":true,"abstractEmptyLines":{"betweenVars":1}}}'));
	}

	/** Metadata ends the group only where it counts as a doc comment (`metadataCountsAsDocComment`). */
	@:pin('control')
	@:killer('M-GROUP-DOC-LED')
	public function testAMemberCountedDocLedEndsTheGroup(): Void {
		final src: String = 'class C {\n\t// g\n\tvar a:Int;\n\t@:keep\n\tvar c:Int;\n}';
		final ignoreDoc: String = '"beforeDocCommentEmptyLines":"ignore","afterFieldsWithDocComments":"ignore"';
		Assert.equals(
			'class C {\n\t// g\n\tvar a:Int;\n\n\t@:keep\n\tvar c:Int;\n}',
			write(
				src,
				'{"emptyLines":{$ignoreDoc'
				+ ',"glueCommentedGroups":true,"metadataCountsAsDocComment":true,"classEmptyLines":{"betweenVars":1}}}'
			)
		);
		Assert.equals(src, write(src, '{"emptyLines":{$ignoreDoc,"glueCommentedGroups":true,"classEmptyLines":{"betweenVars":1}}}'));
	}

	@:pin('control')
	@:killer('M-GROUP-SAME-KIND')
	public function testAnotherKindEndsTheGroup(): Void {
		Assert.equals(
			'class C {\n\t// g\n\tvar a:Int;\n\n\tfunction f():Void {}\n\n\tfunction g():Void {}\n}',
			write(
				'class C {\n\t// g\n\tvar a:Int;\n\tfunction f():Void {}\n\tfunction g():Void {}\n}',
				'{"emptyLines":{"glueCommentedGroups":true}}'
			)
		);
	}

	@:pin('control')
	@:killer('M-GROUP-OWN-COMMENT')
	public function testAMemberWithItsOwnCommentEndsTheGroup(): Void {
		final on: String = '{"emptyLines":{"glueCommentedGroups":true,"classEmptyLines":{"betweenVars":1}}}';
		Assert.equals(
			'class C {\n\t// g\n\tvar a:Int;\n\n\t/* note */\n\tvar b:Int;\n}',
			write('class C {\n\t// g\n\tvar a:Int;\n\t/* note */\n\tvar b:Int;\n}', on)
		);
		Assert.equals(
			'class C {\n\t// g\n\tvar a:Int;\n\n\t// h\n\tvar b:Int;\n\tvar c:Int;\n}',
			write('class C {\n\t// g\n\tvar a:Int;\n\t// h\n\tvar b:Int;\n\tvar c:Int;\n}', on)
		);
	}

	/** An `enum abstract` reads its own key; one `abstractRulesUnlessValueList` hands to the abstract rules reads the level key. */
	@:pin('control')
	@:killer('M-GROUP-CONFIG-ENUM-ABSTRACT')
	public function testAnEnumAbstractReadsItsKey(): Void {
		final src: String = 'enum abstract A(Int) {\n\tvar X = 1;\n\t// g\n\tvar Y = 2;\n\tvar Z = 3;\n}';
		final glued: String = 'enum abstract A(Int) {\n\tvar X = 1;\n\n\t// g\n\tvar Y = 2;\n\tvar Z = 3;\n}';
		Assert.equals(glued, write(src, '{"emptyLines":{"enumAbstractEmptyLines":{"betweenVars":1,"glueCommentedGroups":true}}}'));
		Assert.equals(
			glued,
			write(
				src,
				'{"emptyLines":{"glueCommentedGroups":true,"abstractEmptyLines":{"betweenVars":1},'
				+ '"enumAbstractEmptyLines":{"abstractRulesUnlessValueList":true}}}'
			)
		);
		Assert.isTrue(
			HaxeFormatConfigLoader.loadHxFormatJson('{"emptyLines":{"enumEmptyLines":{"glueCommentedGroups":true}}}')
				.enumGlueCommentedGroups
		);
		Assert.isTrue(HaxeFormatConfigLoader.loadHxFormatJson('{"emptyLines":{"glueCommentedGroups":true}}').glueCommentedGroups);
	}

	/** The multi-line rule is measured on the rendered member, so a group does not hold back its blank lines. */
	@:pin('guard')
	public function testAMultilineMemberKeepsItsBlankLines(): Void {
		Assert.equals(
			'class C {\n\t// fns\n\tfunction f1() {}\n\tfunction f2() {}\n\n\tfunction f3() {\n\t\ttrace(1);\n\t}\n\n\tfunction f4() {}\n}',
			write(
				'class C {\n\t// fns\n\tfunction f1() {}\n\tfunction f2() {}\n\tfunction f3() {\n\t\ttrace(1);\n\t}\n\tfunction f4() {}\n}',
				'{"emptyLines":{"glueCommentedGroups":true,"aroundMultilineFields":1,"classEmptyLines":{"betweenFunctions":1}}}'
			)
		);
	}

	@:pin('guard')
	public function testOffByDefault(): Void {
		final opt: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.isFalse(opt.glueCommentedGroups || opt.enumGlueCommentedGroups || opt.enumAbstractGlueCommentedGroups);
		Assert.equals(COLOURS, write(COLOURS, '{}'));
	}

	@:pin('guard')
	public function testTheLayoutIsAFixedPoint(): Void {
		final once: String = write(COLOURS, CLASS_ON);
		Assert.equals(once, write(once, CLASS_ON));
	}

	private static function write(src: String, json: String): String {
		final opt: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(json);
		return HxWriteFixture.triviaWrite(src, opt);
	}

}
