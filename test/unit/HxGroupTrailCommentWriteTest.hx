package unit;

import haxe.Exception;
import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;

/**
 * Trivia-mode round-trip tests for the group-closer seam: a same-line
 * `// comment` cuddled to the LAST element of a wrapped, comma-separated
 * group whose closing delimiter would otherwise land on the same emitted
 * line.
 *
 * A line comment terminates at `\n`, so the closer is swallowed by the
 * comment and the emitted source stops parsing:
 *
 * ```
 * g(
 *     a // trailing
 * );
 * ```
 *
 * used to re-emit as `g(a // trailing);` - the `);` became comment text
 * and the file no longer parsed. Sibling of the head -> body seam
 * (`HxHeadCommentSeamWriteTest`) and fixed with the same mechanism: the
 * captured comment is emitted through `trailingCommentDocGuarded`, whose
 * `OptHardlineSkipBeforeHardline` both forces the enclosing group to
 * break and drops whenever the next emit is already a hardline.
 *
 * The defect was confined to the postfix `Call` Star (`Call`, `super(...)`,
 * a chain segment's args, a call nested inside metadata) and its
 * method-chain twin. Every other comma-separated group - `new` args,
 * array literals, object/anon-struct literals, declaration parameter
 * lists, anon-type fields - already broke before its closer; those are
 * pinned here so the fix cannot regress them.
 */
class HxGroupTrailCommentWriteTest extends Test {

	private static final forceBuild: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	// --- 1. postfix Call Star: the corrupting seam ----------------------

	/**
	 * The named defect. `g(` + newline + `a // trailing` + newline + `);`
	 * collapsed onto one line, and the `);` was absorbed by the comment.
	 */
	public function testCallArgTrailingLineCommentKeepsCloser(): Void {
		final source: String = 'class C {\n\tfunction f(a:Int) {\n\t\tg(\n\t\t\ta // trailing\n\t\t);\n\t}\n}';
		assertSurvives(source, '// trailing');
		// The guard breaks the seam, it does not re-wrap the list: the argument
		// stays packed against the open paren (`callParameterWrap` fill shape)
		// and only the `)` moves to its own line. Same shape the fork emits for
		// a MULTI-argument list with the comment on the last one; for a SOLE
		// argument the fork additionally leading-breaks after `(` - a cosmetic
		// divergence no corpus fixture pins.
		Assert.equals('class C {\n\tfunction f(a:Int) {\n\t\tg(a // trailing\n\t\t);\n\t}\n}\n', roundTrip(source));
	}

	/** Same seam with the comment on the LAST of several arguments. */
	public function testCallLastOfManyArgsKeepsCloser(): Void {
		final source: String = 'class C {\n\tfunction f(a:Int, b:Int) {\n\t\tg(\n\t\t\ta,\n\t\t\tb // last\n\t\t);\n\t}\n}';
		assertSurvives(source, '// last');
	}

	/** A nested call: the inner closer AND the outer one are both at risk. */
	public function testNestedCallArgKeepsBothClosers(): Void {
		final source: String = 'class C {\n\tfunction f(a:Int) {\n\t\th(g(\n\t\t\ta // trailing\n\t\t));\n\t}\n}';
		assertSurvives(source, '// trailing');
	}

	/** `return g(...)` - the call sits in expression-return position. */
	public function testReturnCallArgKeepsCloser(): Void {
		final source: String = 'class C {\n\tfunction f():Int {\n\t\treturn g(\n\t\t\t1 // trailing\n\t\t);\n\t}\n}';
		assertSurvives(source, '// trailing');
	}

	/** `super(...)` is a `Call` on the `super` atom - same Star. */
	public function testSuperCallArgKeepsCloser(): Void {
		final source: String = 'class C extends B {\n\tfunction new() {\n\t\tsuper(\n\t\t\t1 // trailing\n\t\t);\n\t}\n}';
		assertSurvives(source, '// trailing');
	}

	/**
	 * A call that is a METHOD-CHAIN segment renders its arguments through
	 * `MethodChainEmit`, which builds its own per-argument Docs - a second
	 * copy of the same seam.
	 */
	public function testChainSegmentCallArgKeepsCloser(): Void {
		final source: String = 'class C {\n\tfunction f() {\n\t\tobj.m(\n\t\t\t1 // trailing\n\t\t).n();\n\t}\n}';
		assertSurvives(source, '// trailing');
	}

	/** An arrow body as the sole argument carries the comment on the arg. */
	public function testArrowArgBodyTrailingCommentKeepsCloser(): Void {
		final source: String = 'class C {\n\tfunction f() {\n\t\tg(x -> x // trailing\n\t\t);\n\t}\n}';
		assertSurvives(source, '// trailing');
	}

	/** A call nested inside metadata arguments reaches the same Star. */
	public function testMetadataNestedCallArgKeepsCloser(): Void {
		final source: String = 'class C {\n\t@:build(Macro.run(\n\t\t"x" // trailing\n\t))\n\tfunction f() {}\n}';
		assertSurvives(source, '// trailing');
	}

	// --- 2. block-comment glue is unchanged -----------------------------

	/** A block comment does not terminate at `\n`, so the glue is legal. */
	public function testCallArgTrailingBlockCommentStaysGlued(): Void {
		final source: String = 'class C {\n\tfunction f(a:Int) {\n\t\tg(\n\t\t\ta /* trailing */\n\t\t);\n\t}\n}';
		final expected: String = 'class C {\n\tfunction f(a:Int) {\n\t\tg(a /* trailing */);\n\t}\n}\n';
		Assert.equals(expected, roundTrip(source));
		Assert.equals(expected, roundTrip(expected), 'not idempotent');
	}

	// --- 3. sibling group kinds must not regress ------------------------

	/** `new` args break before `)` already - pinned. */
	public function testNewArgsKeepCloser(): Void {
		final source: String = 'class C {\n\tfunction f(a:Int) {\n\t\tvar v = new Thing(\n\t\t\ta // trailing\n\t\t);\n\t}\n}';
		assertSurvives(source, '// trailing');
		Assert.equals('$source\n', roundTrip(source));
	}

	/** Array literal. */
	public function testArrayLiteralKeepsCloser(): Void {
		final source: String = 'class C {\n\tfunction f(a:Int) {\n\t\tvar v = [\n\t\t\ta // trailing\n\t\t];\n\t}\n}';
		assertSurvives(source, '// trailing');
		Assert.equals('$source\n', roundTrip(source));
	}

	/** Object literal. */
	public function testObjectLiteralKeepsCloser(): Void {
		final source: String = 'class C {\n\tfunction f(a:Int) {\n\t\tvar v = {\n\t\t\tx: a // trailing\n\t\t};\n\t}\n}';
		assertSurvives(source, '// trailing');
		Assert.equals('$source\n', roundTrip(source));
	}

	/** Declaration parameter list. */
	public function testParamListKeepsCloser(): Void {
		final source: String = 'class C {\n\tfunction f(\n\t\ta:Int // trailing\n\t):Void {}\n}';
		assertSurvives(source, '// trailing');
		Assert.equals('$source\n', roundTrip(source));
	}

	/** Anon-type (typedef body) fields. */
	public function testAnonTypeFieldsKeepCloser(): Void {
		final source: String = 'typedef T = {\n\tx:Int // trailing\n}';
		assertSurvives(source, '// trailing');
		Assert.equals('$source\n', roundTrip(source));
	}

	/**
	 * The seam assertion: the emitted source must RE-PARSE (a swallowed
	 * closer does not), must still carry the comment, and must be a fixed
	 * point of a second pass.
	 */
	private function assertSurvives(source: String, comment: String): Void {
		final out: String = roundTrip(source);
		Assert.isTrue(out.indexOf(comment) >= 0, 'comment lost: <$out>');
		try {
			HaxeModuleTriviaParser.parse(out);
		} catch (exception: Exception) {
			Assert.fail('emitted source does not re-parse: <$out>, err=${exception.message}');
			return;
		}
		Assert.equals(out, roundTrip(out), 'not idempotent: <$out>');
	}

	private function roundTrip(source: String): String {
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		return HaxeModuleTriviaWriter.write(ast);
	}

}
