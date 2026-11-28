package unit.grammar.haxe;

import anyparse.format.MetadataLineEndPolicy;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.grammar.haxe.format.HaxeFormatConfigLoader;
import utest.Assert;
import utest.Test;

/**
 * `lineEnds.metadataInlineMaxLength` caps the written width of the one simple metadata a `fit` site keeps on its
 * declaration's line: at the cap it stays, one character wider it takes a line of its own, on every metadata site.
 */
class MetadataInlineMaxLengthTest extends Test {

	private static final forceBuild: Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;

	/** The cap every fixture is written under: the width of `@:timeout(1)`. */
	private static final CAP: Int = 12;

	/** A function's metadata of the cap's width stays on its line; one character wider moves above it. */
	@:pin('control')
	@:killer('M-META-INLINE-MAX-RUN-IGNORED', 'M-META-INLINE-MAX-OFF-BY-ONE', 'M-META-INLINE-MAX-MEMBER-UNWIRED')
	public function testAFunctionKeepsMetadataOfTheCapAndLosesAWiderOne(): Void {
		Assert.equals(
			'class C {\n\t@:timeout(1) function f() {}\n\n\t@:timeout(10)\n\tfunction g() {}\n}\n',
			capped('class C {\n\t@:timeout(1) function f() {}\n\n\t@:timeout(10) function g() {}\n}\n')
		);
	}

	/** A var's metadata answers to the same cap. */
	@:pin('control')
	@:killer('M-META-INLINE-MAX-RUN-IGNORED', 'M-META-INLINE-MAX-OFF-BY-ONE', 'M-META-INLINE-MAX-MEMBER-UNWIRED')
	public function testAVarKeepsMetadataOfTheCapAndLosesAWiderOne(): Void {
		Assert.equals(
			'class C {\n\t@:timeout(1) var a:Int;\n\n\t@:timeout(10)\n\tvar b:Int;\n}\n',
			capped('class C {\n\t@:timeout(1) var a:Int;\n\n\t@:timeout(10) var b:Int;\n}\n')
		);
	}

	/** A type's metadata answers to the same cap. */
	@:pin('control')
	@:killer('M-META-INLINE-MAX-RUN-IGNORED', 'M-META-INLINE-MAX-OFF-BY-ONE', 'M-META-INLINE-MAX-TYPE-UNWIRED')
	public function testATypeKeepsMetadataOfTheCapAndLosesAWiderOne(): Void {
		Assert.equals(
			'@:timeout(1) class A {}\n\n@:timeout(10)\nclass B {}\n', capped('@:timeout(1) class A {}\n\n@:timeout(10) class B {}\n')
		);
	}

	/** An enum constructor's metadata answers to the same cap. */
	@:pin('control')
	@:killer('M-META-INLINE-MAX-RUN-IGNORED', 'M-META-INLINE-MAX-OFF-BY-ONE', 'M-META-INLINE-MAX-ENUM-UNWIRED')
	public function testAnEnumConstructorKeepsMetadataOfTheCapAndLosesAWiderOne(): Void {
		Assert.equals(
			'enum E {\n\t@:timeout(1) A;\n\t@:timeout(10)\n\tB;\n}\n', capped('enum E {\n\t@:timeout(1) A;\n\t@:timeout(10) B;\n}\n')
		);
	}

	/** An anon field's metadata answers to the same cap. */
	@:pin('control')
	@:killer('M-META-INLINE-MAX-RUN-IGNORED', 'M-META-INLINE-MAX-OFF-BY-ONE', 'M-META-INLINE-MAX-ANON-UNWIRED')
	public function testAnAnonFieldKeepsMetadataOfTheCapAndLosesAWiderOne(): Void {
		Assert.equals(
			'typedef T = {\n\t@:timeout(1) c:Int,\n\t@:timeout(10)\n\td:Int,\n}\n',
			capped('typedef T = {\n\t@:timeout(1) c:Int,\n\t@:timeout(10) d:Int,\n}\n')
		);
	}

	/** A local var's metadata answers to the same cap. */
	@:pin('control')
	@:killer('M-META-INLINE-MAX-CHAIN-IGNORED', 'M-META-INLINE-MAX-OFF-BY-ONE', 'M-META-INLINE-MAX-CHAIN-UNWIRED')
	public function testALocalVarKeepsMetadataOfTheCapAndLosesAWiderOne(): Void {
		Assert.equals(
			'class C {\n\tfunction f() {\n\t\t@:timeout(1) var x = 1;\n\t\t@:timeout(10)\n\t\tvar y = 1;\n\t}\n}\n',
			capped('class C {\n\tfunction f() {\n\t\t@:timeout(1) var x = 1;\n\t\t@:timeout(10) var y = 1;\n\t}\n}\n')
		);
	}

	/** The plain writer reads the same cap. */
	@:pin('control')
	@:killer('M-META-INLINE-MAX-RUN-IGNORED', 'M-META-INLINE-MAX-OFF-BY-ONE')
	public function testThePlainWriterReadsTheCap(): Void {
		final opt: HxModuleWriteOptions = options(CAP);
		Assert.equals('@:timeout(1) class A {}\n', HxModuleWriter.write(HaxeModuleParser.parse('@:timeout(1) class A {}\n'), opt));
		Assert.equals('@:timeout(10)\nclass B {}\n', HxModuleWriter.write(HaxeModuleParser.parse('@:timeout(10) class B {}\n'), opt));
	}

	/** Without the key a lone simple metadata stays on its declaration's line however wide it is. */
	@:pin('control')
	@:killer('M-META-INLINE-MAX-ZERO-CAPS')
	public function testNoCapKeepsAWideMetadataOnTheDeclarationLine(): Void {
		final src: String = '@:access(pkg.sub.SomeLongTypeName) class A {\n\t@:describe(\'A sentence in plain words\') function f() {}\n\n'
			+ '\t@:access(pkg.sub.SomeLongTypeName) var a:Int;\n\n\tfunction g() {\n\t\t@:access(pkg.sub.SomeLongTypeName) var x = 1;\n'
			+ '\t}\n}\n\nenum E {\n\t@:access(pkg.sub.SomeLongTypeName) A;\n}\n';
		Assert.equals(src, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), options(0)));
	}

	/**
	 * Each metadata of a run is measured by the cap: a wider one is long and stands on its own line, while a short one
	 * after it keeps the declaration's line. A local var's row is not measured.
	 */
	@:pin('control')
	@:killer('M-META-INLINE-MAX-SHORT-UNCAPPED', 'M-META-FIT-SHORT-PAIR-JOINS', 'M-META-FIT-LAST-NEVER-GLUES')
	public function testEachMetadataOfARunIsMeasured(): Void {
		Assert.equals(
			'@:timeout(10)\n@:timeout(20)\nclass R {\n\t@:timeout(10)\n\t@:timeout(20)\n\tvar r:Int;\n\n\tfunction h() {\n'
			+ '\t\t@:timeout(10) @:timeout(20)\n\t\tvar z = 1;\n\t}\n}\n',
			capped(
				'@:timeout(10) @:timeout(20) class R {\n\t@:timeout(10) @:timeout(20) var r:Int;\n\n\tfunction h() {\n'
				+ '\t\t@:timeout(10) @:timeout(20) var z = 1;\n\t}\n}\n'
			)
		);
		Assert.equals(
			'class S {\n\t@SuppressWarnings(\'checkstyle:InnerAssignment\')\n\t@:op(A -= B) public function sub():Void {}\n}\n',
			capped('class S {\n\t@SuppressWarnings(\'checkstyle:InnerAssignment\') @:op(A -= B) public function sub():Void {}\n}\n')
		);
		final wide: String = [ for (_ in 0...70) 'a' ].join('');
		Assert.equals('@:a(\'$wide\')\n@:b(\'$wide\')\nclass L {}\n', capped('@:a(\'$wide\') @:b(\'$wide\') class L {}\n'));
	}

	/** The key reaches the writer option from a config; a config without it leaves no cap. */
	@:pin('control')
	@:killer('M-META-INLINE-MAX-UNMAPPED')
	public function testTheKeyReachesTheWriterOption(): Void {
		Assert.equals(32, HaxeFormatConfigLoader.loadHxFormatJson('{"lineEnds": {"metadataInlineMaxLength": 32}}').metadataInlineMaxLength);
		Assert.equals(0, HaxeFormatConfigLoader.loadHxFormatJson('{"lineEnds": {"metadataType": "fit"}}').metadataInlineMaxLength);
	}

	/** A second write over a capped output changes nothing. */
	@:pin('guard')
	public function testASecondWriteChangesNothing(): Void {
		for (src in [
			'@:timeout(1) class A {}\n\n@:timeout(10) class B {}\n',
			'class C {\n\t@:timeout(1) function f() {}\n\n\t@:timeout(10) function g() {}\n\n\t@:timeout(10) @:timeout(20) var r:Int;\n}\n',
			'class C {\n\tfunction f() {\n\t\t@:timeout(1) var x = 1;\n\t\t@:timeout(10) var y = 1;\n\t}\n}\n',
			'enum E {\n\t@:timeout(1) A;\n\t@:timeout(10) B;\n}\n'
		]) {
			final once: String = capped(src);
			Assert.equals(once, capped(once));
		}
	}

	/** The trivia writer with every metadata knob at `Fit` under `CAP`. */
	private static function capped(src: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), options(CAP));
	}

	private static function options(cap: Int): HxModuleWriteOptions {
		final opt: HxModuleWriteOptions = new HxModuleWriteOptions(HaxeFormat.instance.defaultWriteOptions);
		opt.lineWidth = 140;
		opt.metadataFunctionLineEnd = MetadataLineEndPolicy.Fit;
		opt.metadataTypeLineEnd = MetadataLineEndPolicy.Fit;
		opt.metadataVarLineEnd = MetadataLineEndPolicy.Fit;
		opt.metadataOtherLineEnd = MetadataLineEndPolicy.Fit;
		opt.metadataInlineMaxLength = cap;
		return opt;
	}

}
