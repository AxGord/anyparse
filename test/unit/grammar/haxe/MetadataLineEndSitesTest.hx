package unit.grammar.haxe;

import anyparse.format.MetadataLineEndPolicy;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxModuleWriter;
import utest.Assert;
import utest.Test;

/**
 * Each metadata site answers to its own `lineEnds.metadata*` knob, and the default `None` keeps
 * today's source-driven layout at every site.
 */
class MetadataLineEndSitesTest extends Test {

	private static final forceBuild: Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;
	private static final MEMBER_SRC: String = 'class C {\n\t@:a var x:Int;\n\n\t@:b function f() {}\n\n\t@:c final y:Int;\n}\n';
	private static final ANON_SRC: String = 'typedef T = {\n\t@:a var x:Int;\n\t@:b function f():Void;\n\t@:c y:Int\n}\n';
	private static final LOCAL_SRC: String = 'class C {\n\tfunction f() {\n\t\t@:a @:b var x = 1;\n\t\t@:c trace(1);\n\t}\n}\n';
	private static final MODULE_SRC: String = '@:a function main() {}\n\n@:b var g = 1;\n\n@:c final h = 2;\n\n@:d class C {}\n';

	@:pin('control')
	@:killer('M-META-TYPE-UNWIRED')
	public function testTheTypeKnobGovernsATypeDeclaration(): Void {
		Assert.equals('@:a\n@:b\nclass C {}\n', trivia('@:a @:b class C {}\n', o -> o.metadataTypeLineEnd = MetadataLineEndPolicy.After));
	}

	public function testAfterLastAndForceAfterLastOnAType(): Void {
		final src: String = '@:a @:b\n@:c class C {}\n';
		Assert.equals('@:a @:b\n@:c\nclass C {}\n', trivia(src, o -> o.metadataTypeLineEnd = MetadataLineEndPolicy.AfterLast));
		Assert.equals('@:a @:b @:c\nclass C {}\n', trivia(src, o -> o.metadataTypeLineEnd = MetadataLineEndPolicy.ForceAfterLast));
	}

	@:pin('control')
	@:killer('M-META-MEMBER-VAR-ARM-OFF')
	public function testTheVarKnobGovernsVarAndFinalMembers(): Void {
		Assert.equals(
			'class C {\n\t@:a\n\tvar x:Int;\n\n\t@:b function f() {}\n\n\t@:c\n\tfinal y:Int;\n}\n',
			trivia(MEMBER_SRC, o -> o.metadataVarLineEnd = MetadataLineEndPolicy.After)
		);
	}

	@:pin('control')
	@:killer('M-META-MEMBER-FN-ARM-OFF')
	public function testTheFunctionKnobGovernsOnlyFunctionMembers(): Void {
		Assert.equals(
			'class C {\n\t@:a var x:Int;\n\n\t@:b\n\tfunction f() {}\n\n\t@:c final y:Int;\n}\n',
			trivia(MEMBER_SRC, o -> o.metadataFunctionLineEnd = MetadataLineEndPolicy.After)
		);
	}

	@:pin('control')
	@:killer('M-META-ENUM-UNWIRED')
	public function testTheOtherKnobGovernsAnEnumConstructor(): Void {
		Assert.equals(
			'enum E {\n\t@:a\n\tA;\n}\n', trivia('enum E {\n\t@:a A;\n}\n', o -> o.metadataOtherLineEnd = MetadataLineEndPolicy.After)
		);
	}

	@:pin('control')
	@:killer('M-META-ANON-VAR-ARM-OFF')
	public function testTheVarKnobGovernsAnAnonVarField(): Void {
		Assert.equals(
			'typedef T = {\n\t@:a\n\tvar x:Int;\n\t@:b function f():Void;\n\t@:c y:Int\n}\n',
			trivia(ANON_SRC, o -> o.metadataVarLineEnd = MetadataLineEndPolicy.After)
		);
	}

	@:pin('control')
	@:killer('M-META-ANON-FN-ARM-OFF')
	public function testTheFunctionKnobGovernsAnAnonFunctionField(): Void {
		Assert.equals(
			'typedef T = {\n\t@:a var x:Int;\n\t@:b\n\tfunction f():Void;\n\t@:c y:Int\n}\n',
			trivia(ANON_SRC, o -> o.metadataFunctionLineEnd = MetadataLineEndPolicy.After)
		);
	}

	@:pin('control')
	@:killer('M-META-ANON-OTHER-OFF')
	public function testTheOtherKnobGovernsAnAnonFieldWithoutAKeyword(): Void {
		Assert.equals(
			'typedef T = {\n\t@:a var x:Int;\n\t@:b function f():Void;\n\t@:c\n\ty:Int\n}\n',
			trivia(ANON_SRC, o -> o.metadataOtherLineEnd = MetadataLineEndPolicy.After)
		);
	}

	@:pin('control')
	@:killer('M-META-CHAIN-UNWIRED')
	public function testTheVarKnobGovernsALocalVarAndLeavesOtherStatements(): Void {
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\t@:a\n\t\t@:b\n\t\tvar x = 1;\n\t\t@:c trace(1);\n\t}\n}\n',
			trivia(LOCAL_SRC, o -> o.metadataVarLineEnd = MetadataLineEndPolicy.After)
		);
	}

	@:pin('control')
	@:killer('M-META-CHAIN-NO-PEEL')
	public function testAChainSharesThePolicyOfItsTail(): Void {
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\t@:a @:b\n\t\tvar x = 1;\n\t\t@:c trace(1);\n\t}\n}\n',
			trivia(LOCAL_SRC, o -> o.metadataVarLineEnd = MetadataLineEndPolicy.ForceAfterLast)
		);
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\t@:a\n\t\t@:b\n\t\tvar x = 1;\n\t\t@:c trace(1);\n\t}\n}\n',
			trivia(LOCAL_SRC, o -> o.metadataVarLineEnd = MetadataLineEndPolicy.After)
		);
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\t@:a\n\t\t@:b\n\t\tvar x = 1;\n\t}\n}\n',
			trivia(
				'class C {\n\tfunction f() {\n\t\t@:a\n\t\t@:b var x = 1;\n\t}\n}\n',
				o -> o.metadataVarLineEnd = MetadataLineEndPolicy.AfterLast
			)
		);
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\t@:c @:d\n\t\tvar y = 1;\n\t}\n}\n',
			trivia(
				'class C {\n\tfunction f() {\n\t\t@:c @:d var y = 1;\n\t}\n}\n',
				o -> o.metadataVarLineEnd = MetadataLineEndPolicy.AfterLast
			)
		);
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\t@:e @:f\n\t\tfinal z = 1;\n\t}\n}\n',
			trivia(
				'class C {\n\tfunction f() {\n\t\t@:e @:f final z = 1;\n\t}\n}\n',
				o -> o.metadataVarLineEnd = MetadataLineEndPolicy.AfterLast
			)
		);
	}

	@:pin('control')
	@:killer('M-META-TOP-FN-ARM-OFF')
	public function testTheFunctionKnobGovernsAModuleLevelFunction(): Void {
		Assert.equals(
			'@:a\nfunction main() {}\n\n@:b var g = 1;\n\n@:c final h = 2;\n\n@:d class C {}\n',
			trivia(MODULE_SRC, o -> o.metadataFunctionLineEnd = MetadataLineEndPolicy.After)
		);
	}

	@:pin('control')
	@:killer('M-META-TOP-VAR-ARM-OFF')
	public function testTheVarKnobGovernsAModuleLevelVarAndNotAModuleLevelFinal(): Void {
		Assert.equals(
			'@:a function main() {}\n\n@:b\nvar g = 1;\n\n@:c final h = 2;\n\n@:d class C {}\n',
			trivia(MODULE_SRC, o -> o.metadataVarLineEnd = MetadataLineEndPolicy.After)
		);
	}

	public function testTheTypeKnobKeepsModuleLevelFinalAndLeavesFunctionAndVar(): Void {
		Assert.equals(
			'@:a function main() {}\n\n@:b var g = 1;\n\n@:c\nfinal h = 2;\n\n@:d\nclass C {}\n',
			trivia(MODULE_SRC, o -> o.metadataTypeLineEnd = MetadataLineEndPolicy.After)
		);
	}

	@:pin('control')
	@:killer('M-META-VARDECL-UNWIRED')
	public function testTheOtherKnobGovernsMetadataAfterTheVarKeyword(): Void {
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\tvar @:e\n\t\tz = 1;\n\t}\n}\n',
			trivia('class C {\n\tfunction f() {\n\t\tvar @:e z = 1;\n\t}\n}\n', o -> o.metadataOtherLineEnd = MetadataLineEndPolicy.After)
		);
	}

	@:pin('control')
	@:killer('M-META-COLLAPSE-IGNORED')
	public function testNoneDropsABlankBetweenMemberMetadata(): Void {
		Assert.equals('class C {\n\t@:a\n\t@:b\n\tvar x:Int;\n}\n', trivia('class C {\n\t@:a\n\n\t@:b\n\tvar x:Int;\n}\n', o -> {}));
	}

	@:pin('control')
	@:killer('M-META-COLLAPSE-FOR-ALL')
	public function testNoneKeepsABlankBetweenTypeMetadata(): Void {
		Assert.equals('@:a\n\n@:b\nclass C {}\n', trivia('@:a\n\n@:b\nclass C {}\n', o -> {}));
	}

	public function testDefaultsKeepEverySiteAsWritten(): Void {
		final src: String =
			'@:a @:b class C {\n\t@:c var x:Int;\n\n\t@:d function f() {\n\t\t@:e var y = 1;\n\t}\n}\n\nenum E {\n\t@:f A;\n}\n';
		Assert.equals(src, trivia(src, o -> {}));
	}

	@:pin('control')
	@:killer('M-META-PLAIN-NO-BREAK')
	public function testThePlainWriterBreaksAfterTheLastMetadata(): Void {
		Assert.equals('@:a\n@:b\nclass C {}\n', plain('@:a @:b class C {}\n', o -> o.metadataTypeLineEnd = MetadataLineEndPolicy.After));
		Assert.equals('@:a @:b\nclass C {}\n', plain('@:a @:b class C {}\n', o -> o.metadataTypeLineEnd = MetadataLineEndPolicy.AfterLast));
	}

	@:pin('control')
	@:killer('M-META-CONFIG-TYPE')
	public function testTheConfigKeyMetadataTypeReachesItsOption(): Void {
		Assert.equals(MetadataLineEndPolicy.After, configured('metadataType').metadataTypeLineEnd);
	}

	@:pin('control')
	@:killer('M-META-CONFIG-VAR')
	public function testTheConfigKeyMetadataVarReachesItsOption(): Void {
		Assert.equals(MetadataLineEndPolicy.After, configured('metadataVar').metadataVarLineEnd);
	}

	@:pin('control')
	@:killer('M-META-CONFIG-OTHER')
	public function testTheConfigKeyMetadataOtherReachesItsOption(): Void {
		Assert.equals(MetadataLineEndPolicy.After, configured('metadataOther').metadataOtherLineEnd);
	}

	private static function configured(key: String): HxModuleWriteOptions {
		return HaxeFormatConfigLoader.loadHxFormatJson('{"lineEnds": {"$key": "after"}}');
	}

	private static function trivia(src: String, configure: HxModuleWriteOptions -> Void): String {
		final opt: HxModuleWriteOptions = new HxModuleWriteOptions(HaxeFormat.instance.defaultWriteOptions);
		configure(opt);
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opt);
	}

	private static function plain(src: String, configure: HxModuleWriteOptions -> Void): String {
		final opt: HxModuleWriteOptions = new HxModuleWriteOptions(HaxeFormat.instance.defaultWriteOptions);
		configure(opt);
		return HxModuleWriter.write(HaxeModuleParser.parse(src), opt);
	}

}
