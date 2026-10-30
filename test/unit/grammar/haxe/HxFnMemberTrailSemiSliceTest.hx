package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import utest.Assert;
import utest.Test;

/**
 * Stray `;` after a member function body — legal Haxe
 * (`function f():Void {};`, found live in dogfood sources) — parses as an
 * `HxClassMember.EmptySemiMember` (literal-only ctor, twin of
 * `HxStatement.EmptyStmt`), keeping sibling member spans untouched.
 * A `@:trailOpt(';')` on `FnMember` was rejected: the trail probe
 * extended the member span over trailing trivia and broke
 * span-dependent ops (member reorder, inline-method, line bounds).
 *
 * The trivia writer glues the stray `;` back onto the body it follows
 * (`};`, `@:fmt(glueToPrevious)`); removing it is the `empty-statement`
 * lint's job. The plain writer keeps it as an empty member on its own
 * line; neither doubles the `NoBody` signature form's own terminator.
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

	@:pin('control')
	@:killer('M-GLUE-TO-PREVIOUS-OFF')
	public function testTriviaGluesStraySemiToBody(): Void {
		final glued: String = 'class C {\n\tfunction f():Void {};\n}';
		Assert.equals(glued, triviaWrite(glued));
		Assert.equals(glued, triviaWrite('class C {\n\tfunction f():Void {}\n\t;\n}'));
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
		return HxWriteFixture.triviaWrite(src, '{}');
	}

	private inline function plainWrite(src: String): String return HxWriteFixture.plainWrite(src, '{}');

}
