package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * Stray `;` after a member function body — legal Haxe
 * (`function f():Void {};`, found live in dogfood sources) — parses as an
 * `HxClassMember.EmptySemiMember` (literal-only ctor, twin of
 * `HxStatement.EmptyStmt`), keeping sibling member spans untouched.
 * A `@:trailOpt(';')` on `FnMember` was rejected: the trail probe
 * extended the member span over trailing trivia and broke
 * span-dependent ops (member reorder, inline-method, line bounds).
 *
 * Both writers normalise the stray `;` onto its own line as an empty
 * member; neither doubles the `NoBody` signature form's own terminator.
 */
@:nullSafety(Strict)
final class HxFnMemberTrailSemiSliceTest extends Test {

	public function new(): Void {
		super();
	}

	public function testStraySemiAfterFnBodyParses(): Void {
		final src: String = 'class C {\n\tfunction f():Void {};\n}';
		Assert.notNull(HaxeModuleTriviaParser.parse(src));
	}

	public function testTriviaNormalizesStraySemiToOwnLine(): Void {
		final src: String = 'class C {\n\tfunction f():Void {};\n}';
		Assert.equals('class C {\n\tfunction f():Void {}\n\t;\n}', triviaWrite(src));
	}

	public function testTriviaKeepsSemiFreeBodySemiFree(): Void {
		final src: String = 'class C {\n\tfunction f():Void {}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	public function testPlainWriterKeepsStraySemiAsOwnMember(): Void {
		final out: String = plainWrite('class C {\n\tfunction f():Void {};\n}');
		Assert.equals('class C {\n\tfunction f():Void {}\n\t;\n}', out);
	}

	public function testPlainWriterNoBodySignatureKeepsSingleSemi(): Void {
		final out: String = plainWrite('interface I {\n\tfunction f():Void;\n}');
		Assert.isTrue(out.indexOf('f():Void;') != -1, 'expected NoBody terminator kept, got: <$out>');
		Assert.isTrue(out.indexOf(';;') == -1, 'expected no doubled terminator, got: <$out>');
	}

	private inline function triviaWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.finalNewline = false;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

	private inline function plainWrite(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.finalNewline = false;
		return HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
	}

}
