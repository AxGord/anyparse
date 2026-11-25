package unit.grammar.haxe;

import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.format.HaxeFormatConfigLoader;
import utest.Assert;
import utest.Test;

/**
 * Members inside a member-level `#if` region take the blank lines the same members take in the type body around it;
 * the markers stay tight to their neighbours.
 */
final class HxCondRegionMemberGapsTest extends Test {

	private static final META_ON: String = '{"emptyLines":{"beforeDocCommentEmptyLines":"one","metadataCountsAsDocComment":true}}';
	private static final HOST_KNOBS: String =
		'{"emptyLines":{"interfaceEmptyLines":{"betweenFunctions":1},"classEmptyLines":{"existingBetweenFields":"remove"}}}';
	private static final GLUED_CLASS_FNS: String = '{"emptyLines":{"classEmptyLines":{"betweenFunctions":0}}}';
	private static final ENUM_ABSTRACT_ALTS: String = '{"emptyLines":{"afterFieldsWithDocComments":"one","metadataCountsAsDocComment":true,'
		+ '"beforeDocCommentEmptyLines":"one","enumAbstractEmptyLines":{"existingBetweenFields":"remove",'
		+ '"afterFieldsWithDocComments":"none","metadataCountsAsDocComment":false}}}';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-REGION-GAP-LINED')
	public function testRegionMembersTakeTheVarAndFunctionGaps(): Void {
		final src: String = 'class C {\n\t#if m\n\tvar a:Int;\n\tvar b:Int;\n\tfunction f() {}\n\tfunction g() {}\n\t#elseif n\n'
			+ '\tfunction h() {}\n\tfunction i() {}\n\t#else\n\tvar c:Int;\n\tfunction j() {}\n\t#end\n}';
		Assert.equals(
			'class C {\n\t#if m\n\tvar a:Int;\n\tvar b:Int;\n\n\tfunction f() {}\n\n\tfunction g() {}\n\t#elseif n\n'
			+ '\tfunction h() {}\n\n\tfunction i() {}\n\t#else\n\tvar c:Int;\n\n\tfunction j() {}\n\t#end\n}',
			write(src, '{}')
		);
	}

	@:pin('control')
	@:killer('M-REGION-GAP-LEAD')
	public function testARegionDocCommentedMemberIsSetOff(): Void {
		Assert.equals(
			'class C {\n\t#if m\n\tvar a:Int;\n\n\t/** d */\n\tvar b:Int;\n\t#end\n}',
			write('class C {\n\t#if m\n\tvar a:Int;\n\t/** d */\n\tvar b:Int;\n\t#end\n}', '{}')
		);
	}

	@:pin('control')
	@:killer('M-META-DOC-LED-ELEM')
	public function testRegionMetadataMembersCountAsDocLed(): Void {
		final src: String = 'class C {\n\t#if m\n\tvar a:Int;\n\t@:x\n\tvar b:Int;\n\t@:x\n\tvar c:Int;\n\tfunction f() {}\n\t#end\n}';
		Assert.equals(
			'class C {\n\t#if m\n\tvar a:Int;\n\n\t@:x\n\tvar b:Int;\n\n\t@:x\n\tvar c:Int;\n\n\tfunction f() {}\n\t#end\n}',
			write(src, META_ON)
		);
	}

	@:pin('control')
	@:killer('M-REGION-GAP-HANDOFF')
	public function testARegionReadsTheKnobsOfItsTypeBody(): Void {
		Assert.equals(
			'interface I {\n\t#if m\n\tfunction a():Void;\n\n\tfunction b():Void;\n\t#end\n}',
			write('interface I {\n\t#if m\n\tfunction a():Void;\n\tfunction b():Void;\n\t#end\n}', HOST_KNOBS)
		);
		Assert.equals(
			'class C {\n\t#if m\n\tvar a:Int;\n\tvar b:Int;\n\t#end\n}',
			write('class C {\n\t#if m\n\tvar a:Int;\n\n\tvar b:Int;\n\t#end\n}', HOST_KNOBS)
		);
	}

	@:pin('guard')
	public function testTheOutsideGapsAreTheReference(): Void {
		final src: String = 'class C {\n\tvar a:Int;\n\t@:x\n\tvar b:Int;\n\t@:x\n\tvar c:Int;\n\tfunction f() {}\n}';
		Assert.equals('class C {\n\tvar a:Int;\n\n\t@:x\n\tvar b:Int;\n\n\t@:x\n\tvar c:Int;\n\n\tfunction f() {}\n}', write(src, META_ON));
		Assert.equals(
			'interface I {\n\tfunction a():Void;\n\n\tfunction b():Void;\n}',
			write('interface I {\n\tfunction a():Void;\n\tfunction b():Void;\n}', HOST_KNOBS)
		);
	}

	@:pin('control')
	@:killer('M-REGION-GAP-HANDOFF')
	public function testAMacroClassRegionReadsTheMacroClassKnobs(): Void {
		final src: String = 'class M {\n\tstatic function m() {\n\t\treturn macro class {\n\t\t\tfunction f() {}\n\t\t\tfunction g() {}\n'
			+ '\t\t\t#if x\n\t\t\tfunction h() {}\n\t\t\tfunction i() {}\n\t\t\t#end\n\t\t};\n\t}\n}';
		Assert.equals(
			'class M {\n\tstatic function m() {\n\t\treturn macro class {\n\t\t\tfunction f() {}\n\n\t\t\tfunction g() {}\n'
			+ '\t\t\t#if x\n\t\t\tfunction h() {}\n\n\t\t\tfunction i() {}\n\t\t\t#end\n\t\t};\n\t}\n}',
			write(src, GLUED_CLASS_FNS)
		);
	}

	@:pin('control')
	@:killer('M-REGION-DOC-HANDOFF')
	public function testARegionAppliesNoDocGapItsTypeBodyDoesNot(): Void {
		final src: String = 'class M {\n\tstatic function m() {\n\t\treturn macro class {\n\t\t\tvar a:Int;\n\t\t\t/** d */\n\t\t\tvar '
			+ 'b:Int;\n\t\t\t#if x\n\t\t\tvar c:Int;\n\t\t\t/** d */\n\t\t\tvar e:Int;\n\t\t\t#end\n\t\t};\n\t}\n}';
		Assert.equals(src, write(src, META_ON));
	}

	@:pin('control')
	@:killer('M-REGION-KIND-HANDOFF')
	public function testARegionClassifiesMembersAsItsTypeBodyDoes(): Void {
		final src: String = 'abstract A(Int) {\n\tvar v:Int;\n\tfinal function f():Void {}\n\tfunction g():Void {}\n\t#if x\n\tvar w:Int;\n'
			+ '\tfinal function h():Void {}\n\tfunction i():Void {}\n\t#end\n}';
		Assert.equals(src, write(src, '{}'));
	}

	@:pin('control')
	@:killer('M-REGION-GAP-HANDOFF')
	public function testAnEnumAbstractRegionReadsTheEnumAbstractKnobs(): Void {
		final src: String = 'enum abstract E(Int) {\n\t#if x\n\tvar A = 1;\n\n\tvar B = 2;\n\t/** doc */\n\tvar C = 3;\n\tvar D = 4;\n'
			+ '\t@:m\n\tvar F = 5;\n\t#end\n}';
		Assert.equals(
			'enum abstract E(Int) {\n\t#if x\n\tvar A = 1;\n\tvar B = 2;\n\n\t/** doc */\n\tvar C = 3;\n\tvar D = 4;\n\t@:m\n\tvar F = 5;\n'
			+ '\t#end\n}',
			write(src, ENUM_ABSTRACT_ALTS)
		);
	}

	private static function write(src: String, json: String): String {
		final opt: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(json);
		return HxWriteFixture.triviaWrite(src, opt);
	}

}
