package unit.grammar.haxe;

import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.format.HaxeFormatConfigLoader;
import utest.Assert;
import utest.Test;

/** `metadataCountsAsDocComment`: a member whose head carries metadata takes the blank lines a doc-commented member takes. */
final class HxMetadataCountsAsDocTest extends Test {

	private static final TYPEDEF_ON: String = '{"emptyLines":{"typedefEmptyLines":{"metadataCountsAsDocComment":true}}}';

	public function new(): Void {
		super();
	}

	@:pin('control')
	@:killer('M-META-DOC-LED-ELEM')
	public function testAMetadataFieldTakesTheBlankBeforeADoc(): Void {
		Assert.equals(
			'typedef T = {\n\tvar a:Int;\n\n\t@:x\n\tvar b:Int;\n}',
			write('typedef T = {\n\tvar a:Int;\n\t@:x\n\tvar b:Int;\n}', TYPEDEF_ON)
		);
	}

	@:pin('control')
	@:killer('M-META-DOC-LED-FORCE-MULTI')
	public function testAOneLineMetadataFieldBreaksTheBody(): Void {
		Assert.equals(
			'typedef T = {\n\tvar a:Int;\n\n\t@:x\n\tvar b:Int;\n}', write('typedef T = {\n\tvar a:Int;\n\t@:x var b:Int;\n}', TYPEDEF_ON)
		);
	}

	@:pin('guard')
	public function testOffByDefault(): Void {
		Assert.equals(
			'typedef T = {\n\tvar a:Int;\n\t@:x\n\tvar b:Int;\n}', write('typedef T = {\n\tvar a:Int;\n\t@:x\n\tvar b:Int;\n}', '{}')
		);
		Assert.equals('enum E {\n\tA;\n\t@:x\n\tB;\n}', write('enum E {\n\tA;\n\t@:x\n\tB;\n}', '{}'));
		Assert.equals('class C {\n\tvar a:Int;\n\t@:x\n\tvar b:Int;\n}', write('class C {\n\tvar a:Int;\n\t@:x\n\tvar b:Int;\n}', '{}'));
	}

	@:pin('guard')
	public function testABodyWithoutMetadataIsUnchanged(): Void {
		Assert.equals('typedef T = {var a:Int; var b:Int;}', write('typedef T = {\n\tvar a:Int;\n\tvar b:Int;\n}', TYPEDEF_ON));
	}

	@:pin('control')
	@:killer('M-META-DOC-LED-BODY')
	public function testAMetadataFieldAtTheTopTakesTheDocEdges(): Void {
		Assert.equals(
			'typedef T = {\n\n\t@:x\n\tvar a:Int;\n\tvar b:Int;\n\n}',
			write(
				'typedef T = {\n\t@:x\n\tvar a:Int;\n\tvar b:Int;\n}',
				'{"emptyLines":{"typedefEmptyLines":{"metadataCountsAsDocComment":true,"beginTypeIfDocComments":1,'
				+ '"endTypeIfDocComments":1}}}'
			)
		);
	}

	@:pin('guard')
	public function testADocAndMetadataFieldTakesOneBlank(): Void {
		Assert.equals(
			'typedef T = {\n\tvar a:Int;\n\n\t/** d */\n\t@:x\n\tvar b:Int;\n}',
			write('typedef T = {\n\tvar a:Int;\n\t/** d */\n\t@:x\n\tvar b:Int;\n}', TYPEDEF_ON)
		);
	}

	@:pin('control')
	@:killer('M-META-DOC-LED-ELEM')
	public function testAnEnumCtorAndAClassVarWithMetadata(): Void {
		Assert.equals(
			'enum E {\n\tA;\n\n\t@:x\n\tB;\n}',
			write('enum E {\n\tA;\n\t@:x\n\tB;\n}', '{"emptyLines":{"enumEmptyLines":{"metadataCountsAsDocComment":true}}}')
		);
		Assert.equals(
			'class C {\n\tvar a:Int;\n\n\t@:x\n\tvar b:Int;\n}',
			write('class C {\n\tvar a:Int;\n\t@:x\n\tvar b:Int;\n}', '{"emptyLines":{"metadataCountsAsDocComment":true}}')
		);
	}

	@:pin('control')
	@:killer('M-META-DOC-CONFIG-TYPEDEF')
	public function testTheTypedefKeyReachesItsKnob(): Void {
		Assert.isTrue(HaxeFormatConfigLoader.loadHxFormatJson(TYPEDEF_ON).typedefMetadataCountsAsDocComment);
		Assert.isFalse(HaxeFormatConfigLoader.loadHxFormatJson('{}').typedefMetadataCountsAsDocComment);
	}

	@:pin('guard')
	public function testTheLayoutIsAFixedPoint(): Void {
		final src: String = 'typedef T = {\n\t@:x\n\tvar a:Int;\n\tvar b:Int;\n\t@:y\n\tvar c:Int;\n}';
		final once: String = write(src, TYPEDEF_ON);
		Assert.equals(once, write(once, TYPEDEF_ON));
	}

	@:pin('control')
	@:killer('M-META-DOC-LED-ELEM')
	public function testTheUsersTypedefTakesBlanksAroundItsMetadataFields(): Void {
		final json: String = '{"emptyLines":{"beforeDocCommentEmptyLines":"one","typedefEmptyLines":{"existingBetweenFields":"remove",'
			+ '"beginTypeIfDocComments":1,"endTypeIfDocComments":1,"afterFieldsWithDocComments":"none",'
			+ '"metadataCountsAsDocComment":true}}}';
		final src: String = 'typedef N = {\n\tvar cond:C;\n\t@:fmt(padTrailing)\n\tvar name:I;\n\t@:trivia\n\t@:tryparse\n'
			+ '\t@:fmt(padTrailing)\n\tvar elseifs:Array<E>;\n\t@:optional\n\t@:kw(\'#else\')\n\t@:fmt(padTrailing)\n'
			+ '\tvar elseName:Null<I>;\n}';
		Assert.equals(
			'typedef N = {\n\n\tvar cond:C;\n\n\t@:fmt(padTrailing)\n\tvar name:I;\n\n\t@:trivia\n\t@:tryparse\n\t@:fmt(padTrailing)\n'
			+ '\tvar elseifs:Array<E>;\n\n\t@:optional\n\t@:kw(\'#else\')\n\t@:fmt(padTrailing)\n\tvar elseName:Null<I>;\n\n}',
			write(src, json)
		);
	}

	private static function write(src: String, json: String): String {
		final opt: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(json);
		return HxWriteFixture.triviaWrite(src, opt);
	}

}
