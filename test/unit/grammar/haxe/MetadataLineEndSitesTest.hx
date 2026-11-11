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
		Assert.equals('@:a @:b @:c\nclass C {}\n', trivia(src, o -> o.metadataTypeLineEnd = MetadataLineEndPolicy.AfterLast));
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
	@:killer('M-META-CHAIN-NO-SOURCE')
	public function testTheVarKnobGovernsALocalVarAndLeavesOtherStatements(): Void {
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\t@:a\n\t\t@:b\n\t\tvar x = 1;\n\t\t@:c trace(1);\n\t}\n}\n',
			trivia(LOCAL_SRC, o -> o.metadataVarLineEnd = MetadataLineEndPolicy.After)
		);
	}

	@:pin('control')
	@:killer('M-META-CHAIN-NO-PEEL')
	@:killer('M-META-CHAIN-NO-SOURCE')
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
			'class C {\n\tfunction f() {\n\t\t@:a @:b\n\t\tvar x = 1;\n\t}\n}\n',
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
	@:killer('M-META-AFTER-SOURCE-SEP')
	public function testTheDefaultDropsABlankBetweenMetadata(): Void {
		Assert.equals('class C {\n\t@:a\n\t@:b\n\tvar x:Int;\n}\n', defaults('class C {\n\t@:a\n\n\t@:b\n\tvar x:Int;\n}\n'));
		Assert.equals('@:a\n@:b\nclass C {}\n', defaults('@:a\n\n@:b\nclass C {}\n'));
	}

	@:pin('control')
	@:killer('M-META-SOURCE-SEP-BACK')
	public function testNoneJoinsMetadataWithASpaceWhateverTheSource(): Void {
		Assert.equals('@:a @:b\nclass C {}\n', trivia('@:a\n\n@:b\nclass C {}\n', o -> {}));
		Assert.equals('class C {\n\t@:a @:b\n\tvar x:Int;\n}\n', trivia('class C {\n\t@:a\n\t@:b\n\tvar x:Int;\n}\n', o -> {}));
	}

	@:pin('control')
	@:killer('M-META-ORPHAN-PADS')
	public function testARegionThatAnnotatesNothingOwesNoBreak(): Void {
		for (src in [
			'enum E {\n\t#if sys\n\t#end\n}\n',
			'typedef T = {\n\t#if sys\n\t#end\n}\n',
			'class C {}\n\n#if sys\n#else\n#end\n'
		]) Assert.equals(src, defaults(src));
	}

	@:pin('control')
	@:killer('M-META-PAD-DROPS-GAP-COMMENT')
	public function testTheGapAfterTheLastMetadataKeepsItsCommentsAndBlank(): Void {
		for (src in [
			'@:a\n// c\nclass K {}\n',
			'#if sys\n#end\n\n/** doc */\nclass K {}\n',
			'class C {\n\t#if sys\n\t#end\n\n\tpublic var x:Int;\n}\n'
		]) Assert.equals(src, defaults(src));
	}

	@:pin('control')
	@:killer('M-META-CHAIN-NO-SOURCE')
	public function testAnAnnotationOnAnExpressionKeepsItsSourceLine(): Void {
		for (src in [
			'class C {\n\tfunction f() {\n\t\tg([\n\t\t\t@doc("c")\n\t\t\t1 => 2\n\t\t]);\n\t}\n}\n',
			'class C {\n\tfunction f() {\n\t\tg([@doc("c") 1 => 2]);\n\t}\n}\n'
		]) Assert.equals(src, defaults(src));
	}

	@:pin('control')
	@:killer('M-META-DEFAULT-NONE')
	public function testTheDefaultPutsEveryMetadataOnItsOwnLine(): Void {
		final src: String =
			'@:a @:b class C {\n\t@:c var x:Int;\n\n\t@:d function f() {\n\t\t@:e var y = 1;\n\t}\n}\n\nenum E {\n\t@:f A;\n}\n';
		Assert.equals(
			'@:a\n@:b\nclass C {\n\t@:c\n\tvar x:Int;\n\n\t@:d\n\tfunction f() {\n\t\t@:e\n\t\tvar y = 1;\n\t}\n}\n\nenum E {\n\t@:f\n'
			+ '\tA;\n}\n',
			defaults(src)
		);
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
		Assert.equals(MetadataLineEndPolicy.ForceAfterLast, configured('metadataType').metadataTypeLineEnd);
	}

	@:pin('control')
	@:killer('M-META-CONFIG-VAR')
	public function testTheConfigKeyMetadataVarReachesItsOption(): Void {
		Assert.equals(MetadataLineEndPolicy.ForceAfterLast, configured('metadataVar').metadataVarLineEnd);
	}

	@:pin('control')
	@:killer('M-META-CONFIG-OTHER')
	public function testTheConfigKeyMetadataOtherReachesItsOption(): Void {
		Assert.equals(MetadataLineEndPolicy.ForceAfterLast, configured('metadataOther').metadataOtherLineEnd);
	}

	/** A config naming `forceAfterLast` for `key`: a value no default holds, so a dropped key shows. */
	private static function configured(key: String): HxModuleWriteOptions {
		return HaxeFormatConfigLoader.loadHxFormatJson('{"lineEnds": {"$key": "forceAfterLast"}}');
	}

	/** The trivia writer with every metadata knob at `None` before `configure`, so one site moves alone. */
	private static function trivia(src: String, configure: HxModuleWriteOptions -> Void): String {
		final opt: HxModuleWriteOptions = new HxModuleWriteOptions(HaxeFormat.instance.defaultWriteOptions);
		opt.metadataFunctionLineEnd = MetadataLineEndPolicy.None;
		opt.metadataTypeLineEnd = MetadataLineEndPolicy.None;
		opt.metadataVarLineEnd = MetadataLineEndPolicy.None;
		opt.metadataOtherLineEnd = MetadataLineEndPolicy.None;
		configure(opt);
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opt);
	}

	private static function defaults(src: String): String {
		return HaxeModuleTriviaWriter.write(
			HaxeModuleTriviaParser.parse(src), new HxModuleWriteOptions(HaxeFormat.instance.defaultWriteOptions)
		);
	}

	private static function plain(src: String, configure: HxModuleWriteOptions -> Void): String {
		final opt: HxModuleWriteOptions = new HxModuleWriteOptions(HaxeFormat.instance.defaultWriteOptions);
		configure(opt);
		return HxModuleWriter.write(HaxeModuleParser.parse(src), opt);
	}

}
