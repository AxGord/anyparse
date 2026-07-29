package unit;

import haxe.Exception;
import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

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
 * thing the Star emitted is a line comment, adds a forward-looking
 * `OptHardlineSkipBeforeHardline` guard for the arms that emit no pad at
 * all, and folds the same signal into the field's `padTrailing` so the
 * PARENT drops the leading separator it would otherwise put before the next
 * field (that space lands after the new break and indents `#elseif` one
 * column). Block-style comments do not terminate at a newline, so their
 * same-line glue is legal and stays.
 *
 * SCOPE. Adjacent pre-existing defects this class deliberately does NOT
 * cover, because they are comment LOSS rather than directive glue and need
 * parser work, not a writer break:
 *  - a comment-only `#if` arm at STATEMENT scope drops its comment entirely
 *    (`#if a` + `// only` + `#end` re-emits as `#if a` + `#end`), as does a
 *    trailing comment after a statement inside such an arm;
 *  - the same at cond-PARAM scope (`function f(#if a b:Int, // t` + `#end`).
 * Both are identical before and after this fix.
 */
class HxCondCommentDirectiveSeamTest extends Test {

	private static final forceBuild: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	private static final EMPTY_IF_MEMBER: String = 'class Foo {\n\t#if a\n\t// only\n\t#end\n\tvar v:Int;\n}';
	private static final EMPTY_ELSE_MEMBER: String = 'class Foo {\n\t#if a\n\tvar w:Int;\n\t#else\n\t// only else\n\t#end\n}';
	private static final EMPTY_IF_BEFORE_ELSEIF: String = 'class Foo {\n\t#if a\n\t// only if\n\t#elseif b\n\tvar w:Int;\n\t#end\n}';
	private static final EMPTY_ELSEIF_MEMBER: String = 'class Foo {\n\t#if a\n\tvar w:Int;\n\t#elseif b\n\t// only elseif\n\t#end\n}';
	private static final EMPTY_IF_DECL: String = '#if a\n// only decl\n#end\nclass Foo {}';
	private static final EMPTY_ELSE_DECL: String = '#if a\nclass Foo {}\n#else\n// only decl else\n#end';
	private static final EMPTY_ELSE_STMT: String =
		'class Foo {\n\tfunction bar():Void {\n\t\t#if a\n\t\ttrace(1);\n\t\t#else\n\t\t// only else\n\t\t#end\n\t}\n}';
	private static final DOC_PLUS_LINE_MEMBER: String =
		'class Foo {\n\t#if false\n\t/**\n\t\tdoc\n\t**/\n\t// public var soundTrans:SoundTrans;\n\t#end\n\tvar v:Int;\n}';
	private static final SAME_LINE_MEMBER: String = 'class Foo {\n\t#if a var q:Int; // t\n\t#end\n}';
	private static final SAME_LINE_MODIFIER: String = 'class Foo {\n\t#if a public // c\n\t#end function f():Void {}\n}';
	private static final SAME_LINE_STMT: String = 'class Foo {\n\tfunction bar():Void {\n\t\t#if a trace(1); // t\n\t\t#end\n\t}\n}';

	/** Every shape the fix recovers - each must re-parse and be a fixed point. */
	private static final RECOVERED_SHAPES: Array<String> = [
		EMPTY_IF_MEMBER,
		EMPTY_ELSE_MEMBER,
		EMPTY_IF_BEFORE_ELSEIF,
		EMPTY_ELSEIF_MEMBER,
		EMPTY_IF_DECL,
		EMPTY_ELSE_DECL,
		EMPTY_ELSE_STMT,
		DOC_PLUS_LINE_MEMBER,
		SAME_LINE_MEMBER,
		SAME_LINE_MODIFIER,
		SAME_LINE_STMT,
	];

	// --- 1. empty arm, comment only ------------------------------------

	/** The named defect, member scope: `#if` arm holding only a comment. */
	public function testMemberEmptyIfArmCommentKeepsEndOnOwnLine(): Void {
		Assert.equals('$EMPTY_IF_MEMBER\n', roundTrip(EMPTY_IF_MEMBER));
	}

	/** `#else` arm holding only a comment. */
	public function testMemberEmptyElseArmCommentKeepsEndOnOwnLine(): Void {
		Assert.equals('$EMPTY_ELSE_MEMBER\n', roundTrip(EMPTY_ELSE_MEMBER));
	}

	/**
	 * Comment-only `#if` arm followed by `#elseif`. Different sub-shape from
	 * the `#end` cases: there the arm emitted NO pad, here the parent also put
	 * its own leading separator (a space) before `#elseif`.
	 */
	public function testMemberEmptyIfArmCommentKeepsElseifOnOwnLine(): Void {
		Assert.equals('$EMPTY_IF_BEFORE_ELSEIF\n', roundTrip(EMPTY_IF_BEFORE_ELSEIF));
	}

	/** Comment-only `#elseif` arm before `#end`. */
	public function testMemberEmptyElseifArmCommentKeepsEndOnOwnLine(): Void {
		Assert.equals('$EMPTY_ELSEIF_MEMBER\n', roundTrip(EMPTY_ELSEIF_MEMBER));
	}

	/** Module scope (`HxConditionalDecl.body`). */
	public function testDeclEmptyIfArmCommentKeepsEndOnOwnLine(): Void {
		Assert.equals('$EMPTY_IF_DECL\n', roundTrip(EMPTY_IF_DECL));
	}

	/** Module scope, `#else` arm. */
	public function testDeclEmptyElseArmCommentKeepsEndOnOwnLine(): Void {
		Assert.equals('$EMPTY_ELSE_DECL\n', roundTrip(EMPTY_ELSE_DECL));
	}

	/** The live openfl shape: doc comment + line comment, no members. */
	public function testMemberDocPlusLineCommentArmKeepsEndOnOwnLine(): Void {
		Assert.equals('$DOC_PLUS_LINE_MEMBER\n', roundTrip(DOC_PLUS_LINE_MEMBER));
	}

	// --- 2. same-line arm, trailing line comment -----------------------

	/**
	 * Non-empty arm whose element starts on the `#if` line: `padTrailing`
	 * resolved to a space, so `#end` was swallowed by `// t`.
	 */
	public function testMemberSameLineArmTrailingCommentKeepsEndOnOwnLine(): Void {
		Assert.equals('$SAME_LINE_MEMBER\n', roundTrip(SAME_LINE_MEMBER));
	}

	/** Modifier scope (`HxConditionalMod.body`), same shape. */
	public function testModifierSameLineArmTrailingCommentKeepsEndOnOwnLine(): Void {
		Assert.equals('$SAME_LINE_MODIFIER\n', roundTrip(SAME_LINE_MODIFIER));
	}

	/** Statement scope (`HxConditionalStmt.body`), same shape. */
	public function testStatementSameLineArmTrailingCommentKeepsEndOnOwnLine(): Void {
		Assert.equals('$SAME_LINE_STMT\n', roundTrip(SAME_LINE_STMT));
	}

	/** Statement scope, comment-only `#else` arm. */
	public function testStatementEmptyElseArmCommentKeepsEndOnOwnLine(): Void {
		Assert.equals('$EMPTY_ELSE_STMT\n', roundTrip(EMPTY_ELSE_STMT));
	}

	// --- 3. block comments keep their legal glue -----------------------

	/** A block comment does not terminate at `\n`, so `#end` may cuddle. */
	public function testMemberEmptyArmBlockCommentStaysGlued(): Void {
		final source: String = 'class Foo {\n\t#if a\n\t/* only */\n\t#end\n\tvar v:Int;\n}';
		final expected: String = 'class Foo {\n\t#if a\n\t/* only */#end\n\tvar v:Int;\n}\n';
		Assert.equals(expected, roundTrip(source));
	}

	/**
	 * The other half of the style gate: a non-empty arm whose LAST element
	 * carries a cuddled BLOCK trailing comment keeps its space pad. Without
	 * this the `_lastTrailComment` line-style test could be a constant `true`
	 * and every other test would still pass.
	 */
	public function testMemberSameLineArmCuddledBlockCommentStaysGlued(): Void {
		final source: String = 'class Foo {\n\t#if a var q:Int; /* t */\n\t#end\n}';
		final expected: String = 'class Foo {\n\t#if a var q:Int; /* t */ #end\n}\n';
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

	// --- 5. the AlignedIncrease close-marker channel --------------------

	/**
	 * Under `conditionalPolicy: alignedIncrease` the close marker's pad is
	 * held OUT of the body's Nest so `#end` renders at the surrounding indent.
	 * The break a line comment forces has to ride that same channel: pushed
	 * into the body it captures the Nest and lands `#end` one level too deep.
	 */
	public function testAlignedIncreaseKeepsEndAtMarkerIndent(): Void {
		final source: String = 'class Foo {\n\t#if a\n\tvar v:Int;\n\t#else\n\t// only else\n\t#end\n}';
		final expected: String = 'class Foo {\n\t#if a\n\t\tvar v:Int;\n\t#else\n\t\t// only else\n\t#end\n}\n';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"indentation": {"conditionalPolicy": "alignedIncrease"}}'
		);
		Assert.equals(expected, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(source), opts));
	}

	// --- 6. every recovered shape re-parses and is a fixed point --------

	public function testRecoveredShapesParseAndAreIdempotent(): Void {
		for (source in RECOVERED_SHAPES) {
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
		// Fully qualified on purpose: `Pairs` is macro-synthesised through
		// `Context.defineModule`, so its sub-module types are not importable.
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		return HaxeModuleTriviaWriter.write(ast);
	}

}
