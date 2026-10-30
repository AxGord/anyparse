package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormatConfigDiagnostics;
import anyparse.grammar.haxe.HaxeFormatConfigIssues;
import utest.Assert;
import utest.Test;

/**
 * A type body's edges — the blank lines after its `{` and before its `}` — answer to that kind's OWN
 * `<kind>EmptyLines.beginType` / `endType`. A stated count, `0` included, wins over the source blank
 * `afterLeftCurly` / `beforeRightCurly: keep` would carry through; an unstated one leaves the source.
 */
@:nullSafety(Strict)
class HxTypeBodyEdgeEmptyLinesTest extends Test {

	private static inline final ENUM_BLANK: String = 'enum E {\n\n\tA;\n\tB;\n\n}';
	private static inline final ENUM_TIGHT: String = 'enum E {\n\tA;\n\tB;\n}';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-BODY-EDGE-STATED-IGNORED')
	public function testAStatedZeroStripsTheEnumBlanksKeepWouldCarry(): Void {
		Assert.equals(ENUM_TIGHT, write(ENUM_BLANK, ',"enumEmptyLines":{"beginType":0,"endType":0}'));
	}

	@:pin('guard')
	public function testAnUnstatedCountLeavesTheSourceBlanks(): Void {
		Assert.equals(ENUM_BLANK, write(ENUM_BLANK, ''));
		Assert.equals(ENUM_TIGHT, write(ENUM_TIGHT, ''));
	}

	@:pin('control')
	@:killer('M-TYPEDEF-EDGE-SOURCE-ADDED')
	public function testAStatedTypedefCountIsExactOverTheSourceBlank(): Void {
		final src: String = 'typedef T = {\n\n\tvar a:Int;\n\n}';
		Assert.equals('typedef T = {\n\tvar a:Int;\n}', write(src, ',"typedefEmptyLines":{"beginType":0,"endType":0}'));
		Assert.equals(src, write(src, ',"typedefEmptyLines":{"beginType":1,"endType":1}'));
	}

	@:pin('control')
	@:killer('M-TYPE-BODY-EDGE-NO-SWITCH')
	public function testAnEnumAbstractReadsItsOwnPairNotTheAbstractOne(): Void {
		final cfg: String = ',"abstractEmptyLines":{"beginType":1,"endType":1},"enumAbstractEmptyLines":{"beginType":0,"endType":0}';
		Assert.equals('enum abstract E(Int) {\n\tvar A = 1;\n}', write('enum abstract E(Int) {\n\n\tvar A = 1;\n\n}', cfg));
		Assert.equals('abstract A(Int) {\n\n\tvar a:Int;\n\n}', write('abstract A(Int) {\n\tvar a:Int;\n}', cfg));
	}

	@:pin('control')
	@:killer('M-TYPE-BODY-EDGE-NO-SWITCH')
	public function testAnExternClassReadsItsOwnPairNotTheClassOne(): Void {
		final cfg: String = ',"classEmptyLines":{"beginType":1,"endType":1},"externClassEmptyLines":{"beginType":0,"endType":0}';
		Assert.equals('extern class X {\n\tfunction f():Void;\n}', write('extern class X {\n\n\tfunction f():Void;\n\n}', cfg));
		Assert.equals('class C {\n\n\tvar a:Int;\n\n}', write('class C {\n\tvar a:Int;\n}', cfg));
		final tight: String = 'extern class X {\n\tfunction f():Void;\n}';
		Assert.equals(tight, write(tight, ',"classEmptyLines":{"beginType":1,"endType":1}'));
	}

	@:pin('control')
	@:killer('M-TYPE-BODY-EDGE-NO-INTERFACE')
	public function testAnInterfaceReadsItsOwnPairAndTheClassOneDoesNotLeak(): Void {
		final tight: String = 'interface I {\n\tfunction f():Void;\n}';
		Assert.equals(tight, write(tight, ',"classEmptyLines":{"beginType":1,"endType":1}'));
		Assert.equals('interface I {\n\n\tfunction f():Void;\n\n}', write(tight, ',"interfaceEmptyLines":{"beginType":1,"endType":1}'));
	}

	public function testAMacroClassBodyReadsMacroClassEmptyLines(): Void {
		final src: String = 'class M {\n\tstatic function f() {\n\t\tvar c = macro class X {\n\t\t\tvar a:Int;\n\t\t};\n\t}\n}';
		final out: String = write(src, ',"macroClassEmptyLines":{"beginType":1,"endType":1}');
		Assert.isTrue(out.indexOf('macro class X {\n\n\t\t\tvar a:Int;\n\n\t\t}') != -1, 'macro class body must gain its edges: <$out>');
	}

	public function testTheReportNamesOnlyTheSubKeysHxqDoesNotRead(): Void {
		final issues: HaxeFormatConfigIssues = HaxeFormatConfigDiagnostics.diagnose(
			'{"emptyLines":{"enumAbstractEmptyLines":{"beginType":0,"betweenVars":1},"macroClassEmptyLines":{"endType":0},'
			+ '"interfaceEmptyLines":{"beginType":1,"endType":1}}}'
		);
		Assert.equals(1, issues.keys.length, 'keys: ${issues.keys.join(', ')}');
		Assert.isTrue(issues.keys[0].indexOf('betweenVars') == 0, 'keys: ${issues.keys.join(', ')}');
	}

	private static function write(src: String, sections: String): String {
		return HxWriteFixture.triviaWrite(src, '{"emptyLines":{"afterLeftCurly":"keep","beforeRightCurly":"keep"$sections}}');
	}

}
