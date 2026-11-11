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
 * The `fit` value of the four `lineEnds.metadata*` keys places a metadata run by width and by the
 * simplicity the grammar's predicate reads off each metadata, never by the source layout.
 */
class MetadataLineEndFitTest extends Test {

	private static final forceBuild: Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;
	private static final MAX_LINE: Int = 140;

	/** One simple metadata stays on the line of the declaration it annotates when that line fits. */
	@:pin('control')
	@:killer('M-META-FIT-ONE-BREAKS', 'M-META-FIT-TYPE-UNWIRED', 'M-META-FIT-MEMBER-UNWIRED')
	public function testOneSimpleMetadataJoinsTheDeclarationLine(): Void {
		Assert.equals(
			'@:nullSafety final class X {\n\t@:from public static inline function f(v:Int):Int {}\n\n\t@:xml(\'a\') public var a:Int;\n\n'
			+ '\t@:describe(\'text\') function g() {}\n}\n',
			fit(
				'@:nullSafety final class X {\n\t@:from public static inline function f(v:Int):Int {}\n\n'
				+ '\t@:xml(\'a\') public var a:Int;\n\n\t@:describe(\'text\') function g() {}\n}\n'
			)
		);
	}

	/** One simple metadata whose declaration line would pass the maximum takes a line of its own. */
	@:pin('control')
	@:killer('M-META-FIT-ONE-GLUES')
	public function testOneSimpleMetadataPastTheMaximumTakesItsOwnLine(): Void {
		Assert.equals(
			'class X {\n\t@:from\n\tpublic static inline function veryLongFunctionNameToPushPastTheLimit(argumentNumberOne:Int, '
			+ 'argumentNumberTwo:String, third:Int):Int {}\n\n\t@:describe(\'${run(110)}\')\n\tfunction g() {}\n}\n',
			fit(
				'class X {\n\t@:from public static inline function veryLongFunctionNameToPushPastTheLimit(argumentNumberOne:Int, '
				+ 'argumentNumberTwo:String, third:Int):Int {}\n\n\t@:describe(\'${run(110)}\') function g() {}\n}\n'
			)
		);
	}

	/** A line of exactly the maximum width fits; one column more does not. */
	@:pin('control')
	@:killer('M-META-FIT-ONE-OFF-BY-ONE')
	public function testADeclarationLineOfExactlyTheMaximumKeepsItsMetadata(): Void {
		Assert.equals(
			'@:xml(\'${run(119)}\') class Y0 {}\n\n@:xml(\'${run(120)}\')\nclass Y1 {}\n',
			fit('@:xml(\'${run(119)}\') class Y0 {}\n\n@:xml(\'${run(120)}\') class Y1 {}\n')
		);
	}

	/** Several simple metadata that fit share one line of their own; they never join the declaration's line. */
	@:pin('control')
	@:killer('M-META-FIT-ROW-UNGROUPED', 'M-META-FIT-ROW-GLUES')
	public function testSeveralSimpleMetadataShareOneRowAboveTheDeclaration(): Void {
		Assert.equals(
			'@:access(a.B) @:nullSafety(Strict)\nabstract class C {\n\t@:describe(\'text\') @:access(pkg.Type)\n\tfunction g() {}\n}\n',
			fit('@:access(a.B) @:nullSafety(Strict) abstract class C {\n\t@:describe(\'text\') @:access(pkg.Type) function g() {}\n}\n')
		);
	}

	/** Several simple metadata whose row passes the maximum go one per line. */
	@:pin('control')
	@:killer('M-META-FIT-ROW-NEVER-BREAKS')
	public function testARowPastTheMaximumIsOneMetadataPerLine(): Void {
		Assert.equals(
			'@:access(some.very.long.package.path.TypeName)\n@:access(another.very.long.package.path.TypeName)\n'
			+ '@:access(third.very.long.pkg.TypeNameLonger)\nclass C {}\n',
			fit(
				'@:access(some.very.long.package.path.TypeName) @:access(another.very.long.package.path.TypeName) '
				+ '@:access(third.very.long.pkg.TypeNameLonger) class C {}\n'
			)
		);
	}

	/** A call, several arguments, an object or a function in the arguments make a metadata complex: its run goes one per line. */
	@:pin('control')
	@:killer('M-META-FIT-ARGS-IGNORED')
	public function testAComplexMetadataPutsItsRunOnePerLine(): Void {
		Assert.equals(
			'class C {\n\t@:build(macros.X.build())\n\t@:a\n\tvar t:Int;\n\n\t@:overload(function(a:Int):Void {})\n\tfunction o() {}\n\n'
			+ '\t@:a(1, 2)\n\tvar u:Int;\n\t@:a({x: 1})\n\tvar v:Int;\n}\n',
			fit(
				'class C {\n\t@:build(macros.X.build()) @:a var t:Int;\n\t@:overload(function(a:Int):Void {}) function o() {}\n\n'
				+ '\t@:a(1, 2) var u:Int;\n\t@:a({x: 1}) var v:Int;\n}\n'
			)
		);
	}

	/** A single-quoted string that interpolates is no simple argument. */
	@:pin('control')
	@:killer('M-META-FIT-INTERP-PLAIN')
	public function testAnInterpolatedStringArgumentIsComplex(): Void {
		Assert.equals(
			'class C {\n\t@:describe(\'$$x text\')\n\tfunction h() {}\n}\n',
			fit('class C {\n\t@:describe(\'$$x text\') function h() {}\n}\n')
		);
	}

	/** A string argument that spans lines is no simple argument. */
	@:pin('control')
	@:killer('M-META-FIT-MULTILINE-PLAIN')
	public function testAStringArgumentSpanningLinesIsComplex(): Void {
		Assert.equals('@:cppFileCode(\'a\nb\')\nclass Q {}\n', fit('@:cppFileCode(\'a\nb\') class Q {}\n'));
	}

	/** A dotted path is a simple argument. */
	@:pin('control')
	@:killer('M-META-FIT-PATH-OFF')
	public function testADottedPathArgumentIsSimple(): Void {
		Assert.equals('@:access(pkg.sub.Type) class C {}\n', fit('@:access(pkg.sub.Type) class C {}\n'));
	}

	/** A number or a bool is a simple argument. */
	@:pin('control')
	@:killer('M-META-FIT-LITERAL-OFF')
	public function testALiteralArgumentIsSimple(): Void {
		Assert.equals(
			'class C {\n\t@:priority(1) function f() {}\n\n\t@:keep(true) var b:Bool;\n}\n',
			fit('class C {\n\t@:priority(1) function f() {}\n\n\t@:keep(true) var b:Bool;\n}\n')
		);
	}

	/** A comment between metadata or after the last one breaks the run as under `after`. */
	@:pin('control')
	@:killer('M-META-FIT-COMMENT-IGNORED')
	public function testACommentInTheRunBreaksItOnePerLine(): Void {
		Assert.equals(
			'class C {\n\t@:a /* c */\n\t@:b\n\tvar q:Int;\n\t@:a // c\n\t@:b\n\tvar r:Int;\n}\n',
			fit('class C {\n\t@:a /* c */ @:b var q:Int;\n\t@:a // c\n\t@:b var r:Int;\n}\n')
		);
	}

	/** A local var's simple metadata stays on its line; a complex one takes its own. */
	@:pin('control')
	@:killer('M-META-FIT-CHAIN-BREAKS', 'M-META-FIT-CHAIN-UNWIRED')
	public function testALocalVarKeepsOneSimpleMetadataOnItsLine(): Void {
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\t@:nullSafety(Off) var x = 1;\n\t\t@:build(x())\n\t\tvar y = 1;\n\t}\n}\n',
			fit('class C {\n\tfunction f() {\n\t\t@:nullSafety(Off) var x = 1;\n\t\t@:build(x()) var y = 1;\n\t}\n}\n')
		);
	}

	/** A comment between a lone simple metadata and its declaration keeps both on lines of their own, as under `after`. */
	@:pin('control')
	@:killer('M-META-FIT-GAP-COMMENT-IGNORED')
	public function testACommentBeforeTheDeclarationBreaksALoneMetadata(): Void {
		final src: String = '@:a\n// c1\nclass X {\n\t@:a\n\t// c2\n\tfunction f() {}\n\n\t@:a\n\t/* c3 */\n\tvar v:Int;\n}\n\n'
			+ '@:a\n/* c4 */\nclass Y {}\n\nenum E {\n\t@:a\n\t// c5\n\tA;\n\t@:a\n\t/* c6 */\n\tB;\n}\n';
		Assert.equals(src, fit(src));
	}

	/** Several simple metadata of a local var share one row above it and are never joined to the var. */
	@:pin('control')
	@:killer('M-META-FIT-CHAIN-CONTEXT-DROPPED', 'M-META-FIT-CHAIN-ROW-END-MEASURED')
	public function testSeveralLocalMetadataShareARowAboveTheVar(): Void {
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\t@:a @:b\n\t\tvar x = 1;\n\t\t@:a @:b\n\t\tfinal z = 3;\n\t\t@:a @:b @:c\n\t\tvar u = 6;\n'
			+ '\t}\n}\n',
			fit(
				'class C {\n\tfunction f() {\n\t\t@:a @:b var x = 1;\n\t\t@:a\n\t\t@:b\n\t\tfinal z = 3;\n\t\t@:a @:b @:c var u = 6;\n'
				+ '\t}\n}\n'
			)
		);
	}

	/** A local row of exactly the maximum width stays one row; one column more, or a complex metadata in it, is one per line. */
	@:pin('control')
	@:killer('M-META-FIT-CHAIN-ROW-UNGROUPED', 'M-META-FIT-CHAIN-COMPLEX-FORGOTTEN')
	public function testALocalRowPastTheMaximumIsOneMetadataPerLine(): Void {
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\t@:a(\'${run(121)}\') @:b\n\t\tvar x = 1;\n\t\t@:a(\'${run(122)}\')\n\t\t@:b\n\t\tvar y = 2;\n'
			+ '\t\t@:a(f())\n\t\t@:b\n\t\tvar w = 4;\n\t}\n}\n',
			fit(
				'class C {\n\tfunction f() {\n\t\t@:a(\'${run(121)}\') @:b var x = 1;\n\t\t@:a(\'${run(122)}\') @:b var y = 2;\n'
				+ '\t\t@:a(f()) @:b var w = 4;\n\t}\n}\n'
			)
		);
	}

	/** A chain's context ends at its var: a local inside the initializer decides its own metadata afresh. */
	@:pin('control')
	@:killer('M-META-FIT-CHAIN-TAIL-INHERITS')
	public function testALocalInsideAChainedVarDecidesItsOwnMetadata(): Void {
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\t@:a @:b\n\t\tvar t = () -> {\n\t\t\t@:c var s = 1;\n\t\t};\n\t\t@:a(f())\n\t\t@:b\n'
			+ '\t\tvar u = () -> {\n\t\t\t@:c var s = 1;\n\t\t};\n\t}\n}\n',
			fit(
				'class C {\n\tfunction f() {\n\t\t@:a @:b var t = () -> {\n\t\t\t@:c var s = 1;\n\t\t};\n'
				+ '\t\t@:a(f()) @:b var u = () -> {\n\t\t\t@:c var s = 1;\n\t\t};\n\t}\n}\n'
			)
		);
	}

	/** Enum constructors and anon fields answer to the same rules. */
	@:pin('control')
	@:killer('M-META-FIT-ENUM-UNWIRED', 'M-META-FIT-ANON-UNWIRED')
	public function testEnumConstructorsAndAnonFieldsFit(): Void {
		Assert.equals(
			'enum E {\n\t@:a A;\n\t@:a @:b(1)\n\tB;\n}\n\ntypedef T = {\n\t@:optional var a:Int;\n\t@:a @:b\n\tvar b:Int;\n}\n',
			fit('enum E {\n\t@:a A;\n\t@:a @:b(1) B;\n}\n\ntypedef T = {\n\t@:optional var a:Int;\n\t@:a @:b var b:Int;\n}\n')
		);
	}

	/** The four keys read `fit` from a config. */
	@:pin('control')
	@:killer('M-META-FIT-UNMAPPED')
	public function testTheFitValueReachesEveryMetadataKey(): Void {
		final opt: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"lineEnds": {"metadataType": "fit", "metadataFunction": "fit", "metadataVar": "fit", "metadataOther": "fit"}}'
		);
		Assert.equals(MetadataLineEndPolicy.Fit, opt.metadataTypeLineEnd);
		Assert.equals(MetadataLineEndPolicy.Fit, opt.metadataFunctionLineEnd);
		Assert.equals(MetadataLineEndPolicy.Fit, opt.metadataVarLineEnd);
		Assert.equals(MetadataLineEndPolicy.Fit, opt.metadataOtherLineEnd);
	}

	/** The plain writer reads the same rules. */
	@:pin('control')
	@:killer('M-META-FIT-PLAIN-BREAKS')
	public function testThePlainWriterFits(): Void {
		Assert.equals('@:a class C {}\n', plain('@:a class C {}\n'));
		Assert.equals('@:a @:b\nclass C {}\n', plain('@:a @:b class C {}\n'));
	}

	/** A second write over any fixture's output changes nothing. */
	@:pin('guard')
	public function testASecondWriteChangesNothing(): Void {
		for (src in [
			'@:nullSafety final class X {\n\t@:from public static inline function f(v:Int):Int {}\n\n\t@:xml(\'a\') public var a:Int;\n\n'
			+ '\t@:describe(\'text\') function g() {}\n}\n',
			'class X {\n\t@:from public static inline function veryLongFunctionNameToPushPastTheLimit(argumentNumberOne:Int, '
			+ 'argumentNumberTwo:String, third:Int):Int {}\n\n\t@:describe(\'${run(110)}\') function g() {}\n}\n',
			'@:xml(\'${run(119)}\') class Y0 {}\n\n@:xml(\'${run(120)}\') class Y1 {}\n',
			'@:access(a.B) @:nullSafety(Strict) abstract class C {\n\t@:describe(\'text\') @:access(pkg.Type) function g() {}\n}\n',
			'@:access(some.very.long.package.path.TypeName) @:access(another.very.long.package.path.TypeName) '
			+ '@:access(third.very.long.pkg.TypeNameLonger) class C {}\n',
			'class C {\n\t@:build(macros.X.build()) @:a var t:Int;\n\t@:overload(function(a:Int):Void {}) function o() {}\n\n'
			+ '\t@:a(1, 2) var u:Int;\n\t@:a({x: 1}) var v:Int;\n}\n',
			'class C {\n\t@:describe(\'$$x text\') function h() {}\n}\n',
			'@:cppFileCode(\'a\nb\') class Q {}\n',
			'@:access(pkg.sub.Type) class C {}\n',
			'class C {\n\t@:priority(1) function f() {}\n\n\t@:keep(true) var b:Bool;\n}\n',
			'class C {\n\t@:a /* c */ @:b var q:Int;\n\t@:a // c\n\t@:b var r:Int;\n}\n',
			'class C {\n\tfunction f() {\n\t\t@:nullSafety(Off) var x = 1;\n\t\t@:build(x()) var y = 1;\n\t}\n}\n',
			'@:a\n// c1\nclass X {\n\t@:a\n\t/* c2 */\n\tfunction f() {}\n}\n',
			'class C {\n\tfunction f() {\n\t\t@:a @:b var x = 1;\n\t\t@:a(\'${run(121)}\') @:b var y = 2;\n\t\t@:a(f()) @:b var w = 4;\n'
			+ '\t}\n}\n',
			'enum E {\n\t@:a A;\n\t@:a @:b(1) B;\n}\n\ntypedef T = {\n\t@:optional var a:Int;\n\t@:a @:b var b:Int;\n}\n'
		]) {
			final once: String = fit(src);
			Assert.equals(once, fit(once));
		}
	}

	/** A run of `n` letters, the filler that puts a line at a chosen width. */
	private static function run(n: Int): String {
		return [for (_ in 0...n) 'a'].join('');
	}

	/** The trivia writer with every metadata knob at `Fit` and the maximum at `MAX_LINE`. */
	private static function fit(src: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), options());
	}

	private static function plain(src: String): String {
		return HxModuleWriter.write(HaxeModuleParser.parse(src), options());
	}

	private static function options(): HxModuleWriteOptions {
		final opt: HxModuleWriteOptions = new HxModuleWriteOptions(HaxeFormat.instance.defaultWriteOptions);
		opt.lineWidth = MAX_LINE;
		opt.metadataFunctionLineEnd = MetadataLineEndPolicy.Fit;
		opt.metadataTypeLineEnd = MetadataLineEndPolicy.Fit;
		opt.metadataVarLineEnd = MetadataLineEndPolicy.Fit;
		opt.metadataOtherLineEnd = MetadataLineEndPolicy.Fit;
		return opt;
	}

}
