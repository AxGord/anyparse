package unit;

import haxe.Exception;
import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;

/**
 * Trivia-mode round-trip tests for the conditional-compilation seam: a
 * `//` line comment that is the LAST thing a `#if` / `#elseif` / `#else`
 * arm emits, immediately before the region's next `#`-directive.
 *
 * A `//` comment terminates at `\n` by definition, so a `#end` glued onto
 * its line becomes comment TEXT. The region then never closes and the
 * emitted file no longer parses - corruption, strictly worse than losing
 * the comment. Observed live on `openfl/display/Sprite.hx`, where
 *
 *     #if false
 *     ...
 *     // @:noCompletion @:dox(hide) public var soundTransform:SoundTransform;
 *     #end
 *
 * came back as `...SoundTransform;#end`.
 *
 * Two emitter shapes produced the glue, both in the shared cond-comp
 * tryparse-Star assembly:
 *
 *  1. EMPTY arm - the arm holds only comments (`_arr.length == 0`), so the
 *     `padTrailing` newline before the close marker was skipped entirely
 *     and the marker landed on the last comment's line.
 *  2. SAME-LINE arm - the arm's first element had no source newline before
 *     it (`#if a var q:Int; // t`), so `padTrailing` resolved to a SPACE.
 *     A space before `#end` is right after code and wrong after a `//`
 *     comment.
 *
 * The fix keeps the pad decision but forces the hardline whenever the last
 * thing the Star emitted is a line comment, plus a forward-looking
 * `OptHardlineSkipBeforeHardline` guard for the arms that emit no pad at
 * all. Block-style comments do not terminate at a newline, so their
 * same-line glue is legal and stays.
 */
class HxCondCommentDirectiveSeamTest extends Test {

	private static final forceBuild: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	// --- 1. empty arm, comment only ------------------------------------

	/** The named defect, member scope: `#if` arm holding only a comment. */
	public function testMemberEmptyIfArmCommentKeepsEndOnOwnLine(): Void {
		final source: String = 'class Foo {\n\t#if a\n\t// only\n\t#end\n\tvar v:Int;\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	/** `#else` arm holding only a comment. */
	public function testMemberEmptyElseArmCommentKeepsEndOnOwnLine(): Void {
		final source: String = 'class Foo {\n\t#if a\n\tvar w:Int;\n\t#else\n\t// only else\n\t#end\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	/** Comment-only `#if` arm followed by `#elseif` - same glue, other marker. */
	public function testMemberEmptyIfArmCommentKeepsElseifOnOwnLine(): Void {
		final source: String = 'class Foo {\n\t#if a\n\t// only if\n\t#elseif b\n\tvar w:Int;\n\t#end\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	/** Comment-only `#elseif` arm before `#end`. */
	public function testMemberEmptyElseifArmCommentKeepsEndOnOwnLine(): Void {
		final source: String = 'class Foo {\n\t#if a\n\tvar w:Int;\n\t#elseif b\n\t// only elseif\n\t#end\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	/** Module scope (`HxConditionalDecl.body`). */
	public function testDeclEmptyIfArmCommentKeepsEndOnOwnLine(): Void {
		final source: String = '#if a\n// only decl\n#end\nclass Foo {}';
		Assert.equals('$source\n', roundTrip(source));
	}

	/** Module scope, `#else` arm. */
	public function testDeclEmptyElseArmCommentKeepsEndOnOwnLine(): Void {
		final source: String = '#if a\nclass Foo {}\n#else\n// only decl else\n#end';
		Assert.equals('$source\n', roundTrip(source));
	}

	/** The live openfl shape: doc comment + line comment, no members. */
	public function testMemberDocPlusLineCommentArmKeepsEndOnOwnLine(): Void {
		final source: String =
			'class Foo {\n\t#if false\n\t/**\n\t\tdoc\n\t**/\n\t// public var soundTrans:SoundTrans;\n\t#end\n\tvar v:Int;\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	// --- 2. same-line arm, trailing line comment -----------------------

	/**
	 * Non-empty arm whose element starts on the `#if` line: `padTrailing`
	 * resolved to a space, so `#end` was swallowed by `// t`.
	 */
	public function testMemberSameLineArmTrailingCommentKeepsEndOnOwnLine(): Void {
		final out: String = roundTrip('class Foo {\n\t#if a var q:Int; // t\n\t#end\n}');
		Assert.isTrue(out.indexOf('// t\n') > -1, 'directive glued onto the line comment: $out');
		assertParses(out);
	}

	/** Modifier scope (`HxConditionalMod.body`), same shape. */
	public function testModifierSameLineArmTrailingCommentKeepsEndOnOwnLine(): Void {
		final out: String = roundTrip('class Foo {\n\t#if a public // c\n\t#end function f():Void {}\n}');
		Assert.isTrue(out.indexOf('// c\n') > -1, 'directive glued onto the line comment: $out');
		assertParses(out);
	}

	// --- 3. block comments keep their legal glue -----------------------

	/** A block comment does not terminate at `\n`, so `#end` may cuddle. */
	public function testMemberEmptyArmBlockCommentStaysGlued(): Void {
		final source: String = 'class Foo {\n\t#if a\n\t/* only */\n\t#end\n\tvar v:Int;\n}';
		final expected: String = 'class Foo {\n\t#if a\n\t/* only */#end\n\tvar v:Int;\n}\n';
		Assert.equals(expected, roundTrip(source));
	}

	// --- 4. arms that already broke correctly stay byte-identical ------

	/** Non-empty multi-line arm with an orphan trail comment: unchanged. */
	public function testMemberMultiLineArmTrailingCommentUnchanged(): Void {
		final source: String = 'class Foo {\n\t#if a\n\tvar x:Int;\n\t// tail a\n\t#end\n}';
		Assert.equals('$source\n', roundTrip(source));
	}

	/** Heritage-scope arm that already emitted the hardline: unchanged. */
	public function testHeritageArmTrailingCommentUnchanged(): Void {
		final source: String = 'class Foo #if a\n\textends A // c\n\t#end {}';
		Assert.equals('$source\n', roundTrip(source));
	}

	// --- 5. every recovered shape re-parses and is a fixed point --------

	public function testRecoveredShapesParseAndAreIdempotent(): Void {
		final sources: Array<String> = [
			'class Foo {\n\t#if a\n\t// only\n\t#end\n\tvar v:Int;\n}',
			'class Foo {\n\t#if a\n\tvar w:Int;\n\t#else\n\t// only else\n\t#end\n}',
			'class Foo {\n\t#if a\n\t// only if\n\t#elseif b\n\tvar w:Int;\n\t#end\n}',
			'class Foo {\n\t#if a\n\tvar w:Int;\n\t#elseif b\n\t// only elseif\n\t#end\n}',
			'#if a\n// only decl\n#end\nclass Foo {}',
			'#if a\nclass Foo {}\n#else\n// only decl else\n#end',
			'class Foo {\n\t#if a var q:Int; // t\n\t#end\n}',
			'class Foo {\n\t#if a public // c\n\t#end function f():Void {}\n}',
		];
		for (source in sources) {
			final once: String = roundTrip(source);
			assertParses(once);
			Assert.equals(once, roundTrip(once), 'not idempotent: $source');
		}
	}

	private function assertParses(source: String): Void {
		try {
			HaxeModuleTriviaParser.parse(source);
			Assert.pass();
		} catch (exception: Exception) {
			Assert.fail('emitted source does not parse ($exception): $source');
		}
	}

	private function roundTrip(source: String): String {
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		return HaxeModuleTriviaWriter.write(ast);
	}

}
