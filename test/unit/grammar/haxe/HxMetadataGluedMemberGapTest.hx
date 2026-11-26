package unit.grammar.haxe;

import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.format.HaxeFormatConfigLoader;
import utest.Assert;
import utest.Test;

/** `metadataCountsAsDocComment` counts a member's metadata as a doc comment only where the writer puts it on its own line. */
final class HxMetadataGluedMemberGapTest extends Test {

	private static final ON: String = '{"emptyLines":{"metadataCountsAsDocComment":true,'
		+ '"typedefEmptyLines":{"metadataCountsAsDocComment":true},'
		+ '"enumEmptyLines":{"metadataCountsAsDocComment":true},'
		+ '"enumAbstractEmptyLines":{"metadataCountsAsDocComment":true}},"lineEnds":{"metadataVar":"none",'
		+ '"metadataOther":"none","metadataFunction":"none","metadataType":"none"}}';
	private static final FIT: String = '{"emptyLines":{"metadataCountsAsDocComment":true},"lineEnds":{"metadataVar":"fit"}}';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-META-OWN-LINE-UNREAD')
	public function testARunOfGluedMetadataFieldsStaysTight(): Void {
		final src: String = 'class C {\n\t@:auto public var a:S;\n\t@:auto public var b:S;\n\t@:auto public var c:S;\n}';
		Assert.equals(src, write(src, ON));
	}

	@:pin('control')
	@:killer('M-META-OWN-LINE-NONE-SOURCE')
	public function testAnOwnLineMetadataRunTakesBlanks(): Void {
		Assert.equals(
			'class C {\n\t@:x\n\tvar a:Int;\n\n\t@:x\n\tvar b:Int;\n}', write('class C {\n\t@:x\n\tvar a:Int;\n\t@:x\n\tvar b:Int;\n}', ON)
		);
		Assert.equals(
			'class C {\n\t@:x\n\tpublic var a:Int;\n\n\tpublic var b:Int;\n}',
			write('class C {\n\t@:x\n\tpublic var a:Int;\n\tpublic var b:Int;\n}', ON)
		);
	}

	@:pin('control')
	@:killer('M-META-OWN-LINE-UNREAD', 'M-META-OWN-LINE-NONE-SOURCE')
	public function testAMixedRunBlanksOnlyAroundTheOwnLineMember(): Void {
		Assert.equals(
			'class M {\n\t@:x var a:Int;\n\t@:x var b:Int;\n\n\t@:y\n\tvar c:Int;\n\n\tvar d:Int;\n}',
			write('class M {\n\t@:x var a:Int;\n\t@:x var b:Int;\n\t@:y\n\tvar c:Int;\n\tvar d:Int;\n}', ON)
		);
	}

	@:pin('guard')
	public function testADocCommentWithGluedMetadataKeepsTheDocRule(): Void {
		Assert.equals(
			'class D {\n\tvar a:Int;\n\n\t/** d */\n\t@:x var b:Int;\n\n\tvar c:Int;\n}',
			write('class D {\n\tvar a:Int;\n\t/** d */\n\t@:x var b:Int;\n\tvar c:Int;\n}', ON)
		);
	}

	@:pin('control')
	@:killer('M-META-OWN-LINE-UNREAD')
	public function testGluedTypedefEnumAndEnumAbstractBodiesStayTight(): Void {
		Assert.equals(
			'typedef T = {@:x var a:Int; @:x var b:Int; var c:Int;}',
			write('typedef T = {\n\t@:x var a:Int;\n\t@:x var b:Int;\n\tvar c:Int;\n}', ON)
		);
		final en: String = 'enum E {\n\t@:x A;\n\t@:x B;\n\tC;\n}';
		Assert.equals(en, write(en, ON));
		final ab: String = 'enum abstract K(Int) {\n\t@:x var A = 1;\n\t@:x var B = 2;\n\tvar C = 3;\n}';
		Assert.equals(ab, write(ab, ON));
	}

	@:pin('control')
	@:killer('M-META-OWN-LINE-FIT')
	public function testAFitJoinedMetadataFieldStaysTight(): Void {
		final src: String = 'class C {\n\t@:x var a:Int;\n\t@:x var b:Int;\n}';
		Assert.equals(src, write(src, FIT));
	}

	@:pin('guard')
	public function testTheLayoutIsAFixedPoint(): Void {
		final once: String = write('class M {\n\t@:x var a:Int;\n\t@:x var b:Int;\n\t@:y\n\tvar c:Int;\n\tvar d:Int;\n}', ON);
		Assert.equals(once, write(once, ON));
	}

	@:pin('control')
	@:killer('M-META-OWN-LINE-RUN-BREAK')
	public function testAnAnnotationOnItsOwnLineAboveAGluedOneTakesBlanks(): Void {
		Assert.equals(
			'class C {\n\tvar a:Int;\n\n\t@:keep\n\t@:x var b:Int;\n\n\tvar c:Int;\n}',
			write('class C {\n\tvar a:Int;\n\t@:keep\n\t@:x var b:Int;\n\tvar c:Int;\n}', ON)
		);
	}

	/** A `#if` region body decides its members' gaps by the same verdict: glued members stay tight, an own-line one is set off. */
	@:pin('control')
	@:killer('M-META-OWN-LINE-UNREAD')
	public function testARegionBodyKeepsGluedMetadataTight(): Void {
		final json: String = '{"emptyLines":{"metadataCountsAsDocComment":true},"lineEnds":{"metadataVar":"none"}}';
		final once: String = write(
			'class A {\n\tpublic var z:Int;\n\t#if js\n\t@:auto public var a:S;\n\t@:auto public var b:S;\n\t@:keep\n\tpublic var c:S;\n'
			+ '\tpublic var d:S;\n\t#end\n\tpublic var e:Int;\n}',
			json
		);
		Assert.equals(
			'class A {\n\tpublic var z:Int;\n\t#if js\n\t@:auto public var a:S;\n\t@:auto public var b:S;\n\n\t@:keep\n'
			+ '\tpublic var c:S;\n\n\tpublic var d:S;\n\t#end\n\tpublic var e:Int;\n}',
			once
		);
		Assert.equals(once, write(once, json));
	}

	/**
	 * Under `fit` a lone simple annotation counts as joined to its declaration even where the line overflows and the render
	 * breaks it onto its own line: the verdict is taken before any width is known, so no blank sets the member off.
	 */
	@:pin('control')
	@:killer('M-META-OWN-LINE-FIT')
	public function testAFitAnnotationBrokenByWidthStaysPlain(): Void {
		final json: String =
			'{"emptyLines":{"metadataCountsAsDocComment":true},"lineEnds":{"metadataVar":"fit"},"wrapping":{"maxLineLength":50}}';
		Assert.equals(
			'class C {\n\tpublic var a:Int;\n\t@:keep\n\tpublic var aVeryLongFieldNameThatOverflowsTheLine:Map<String, Int>;\n'
			+ '\tpublic var b:Int;\n}',
			write(
				'class C {\n\tpublic var a:Int;\n\t@:keep public var aVeryLongFieldNameThatOverflowsTheLine:Map<String, Int>;\n'
				+ '\tpublic var b:Int;\n}',
				json
			)
		);
	}

	private static function write(src: String, json: String): String {
		final opt: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(json);
		return HxWriteFixture.triviaWrite(src, opt);
	}

}
