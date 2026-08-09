package unit;

import haxe.Exception;
import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HxModuleWriteOptions;

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
 * (`HxHeadCommentSeamWriteTest`).
 *
 * Two cooperating mechanisms keep the closer:
 *
 *  - the captured comment is emitted through `trailingCommentDocGuarded`,
 *    which appends an `OptHardlineSkipBeforeHardline`. That atom forces a
 *    break at RENDER time - but only outside a force-flat region, and it
 *    drops whenever the next emit is already a hardline;
 *  - inside a force-flat region the renderer DROPS it (`Renderer`'s
 *    `f.forceFlat` arm), and `WrapList.shapeNoWrap` wraps its body in
 *    exactly such a region. So `shapeNoWrap` now skips the `Flatten`
 *    marker for a body carrying an `OptHardline*` atom.
 *
 * The second half matters only under a config whose cascade resolves to
 * `NoWrap` - e.g. a `callParameter` rule `itemCount <= 1 -> noWrap`, or
 * `defaultWrap: "noWrap"`. Tests at compiled defaults cannot see it, so
 * the sole-argument shapes are pinned twice: once at defaults and once
 * through `CFG_NOWRAP`.
 *
 * The corrupting seam was confined to the postfix `Call` Star (`Call`,
 * `super(...)`, a chain segment's args, a call nested inside metadata)
 * and its method-chain twin. Every other comma-separated group - `new`
 * args, array literals, object/anon-struct literals, declaration
 * parameter lists, anon-type fields - already breaks before its closer;
 * those are pinned here so the fix cannot regress them.
 */
class HxGroupTrailCommentWriteTest extends Test {

	private static final forceBuild: Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	/**
	 * A `callParameter` cascade that resolves to `NoWrap` for a sole
	 * argument - the shape whose flat body `WrapList.shapeNoWrap` wraps in
	 * a force-flat `Flatten` region. Copied verbatim from the block a real
	 * project ships; the second rule (`itemCount <= 1` + `totalItemLength
	 * <= 100`) is the one that pins the cascade flat.
	 */
	private static final CFG_NOWRAP: String =
		'{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, "callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}, {"conditions": [{"cond": "itemCount <= n", "value": 1}, {"cond": "totalItemLength <= n", "value": 100}], "type": "noWrap"}]}}}';

	/** The minimal reproducer: no rules at all, the DEFAULT is `noWrap`. */
	private static final CFG_DEFAULT_NOWRAP: String =
		'{"indentation": {"character": "tab", "tabWidth": 4}, "wrapping": {"maxLineLength": 140, "callParameter": {"defaultWrap": "noWrap", "rules": []}}}';

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
		// divergence no corpus fixture pins. `testSoleArgLayoutUnderNoWrap`
		// pins the SAME bytes under a `NoWrap`-resolving cascade: the two
		// paths converge, which is why `shapeNoWrap` drops its `Flatten`
		// wrapper instead of forcing the cascade off `NoWrap`.
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

	// --- 4. the same shapes under a `NoWrap`-resolving cascade ----------
	// Compiled defaults never resolve `callParameter` to `NoWrap` for these
	// inputs, so section 1 exercises only the render-time half of the guard.
	// A config whose cascade DOES resolve `NoWrap` routes the body through
	// `WrapList.shapeNoWrap`'s force-flat `Flatten`, where the renderer
	// drops the guard - every one of these corrupted until `shapeNoWrap`
	// learned to skip the marker for a guard-bearing body.

	/** The named defect under a sole-argument `noWrap` rule. */
	public inline function testSoleCallArgUnderNoWrap(): Void {
		assertSurvivesNoWrap('class C {\n\tfunction f(a:Int) {\n\t\tg(\n\t\t\ta // trailing\n\t\t);\n\t}\n}', '// trailing');
	}

	/**
	 * The layout is the SAME bytes the compiled-default cascade emits (see
	 * `testCallArgTrailingLineCommentKeepsCloser`): the argument stays
	 * packed against the open paren and only the `)` moves to its own line.
	 * Pinned so a future change cannot silently reroute the `NoWrap` path
	 * to a different recovery shape.
	 */
	public function testSoleArgLayoutUnderNoWrap(): Void {
		final source: String = 'class C {\n\tfunction f(a:Int) {\n\t\tg(\n\t\t\ta // trailing\n\t\t);\n\t}\n}';
		Assert.equals('class C {\n\tfunction f(a:Int) {\n\t\tg(a // trailing\n\t\t);\n\t}\n}\n', roundTripWith(source, CFG_NOWRAP));
	}

	/** `defaultWrap: "noWrap"` with no rules at all - the minimal reproducer. */
	public function testSoleCallArgUnderDefaultNoWrap(): Void {
		final source: String = 'class C {\n\tfunction f(a:Int) {\n\t\tg(\n\t\t\ta // trailing\n\t\t);\n\t}\n}';
		assertSeam(source, '// trailing', roundTripWith.bind(_, CFG_DEFAULT_NOWRAP));
	}

	/** A nested sole call: the inner closer AND the outer one are both at risk. */
	public inline function testNestedSoleCallUnderNoWrap(): Void {
		assertSurvivesNoWrap('class C {\n\tfunction f(a:Int) {\n\t\th(g(\n\t\t\ta // trailing\n\t\t));\n\t}\n}', '// trailing');
	}

	/** `return g(sole)`. */
	public inline function testReturnSoleCallUnderNoWrap(): Void {
		assertSurvivesNoWrap('class C {\n\tfunction f():Int {\n\t\treturn g(\n\t\t\t1 // trailing\n\t\t);\n\t}\n}', '// trailing');
	}

	/** `super(sole)`. */
	public inline function testSuperSoleCallUnderNoWrap(): Void {
		assertSurvivesNoWrap('class C extends B {\n\tfunction new() {\n\t\tsuper(\n\t\t\t1 // trailing\n\t\t);\n\t}\n}', '// trailing');
	}

	/** A method-chain segment's sole argument. */
	public inline function testChainSegmentSoleArgUnderNoWrap(): Void {
		assertSurvivesNoWrap('class C {\n\tfunction f() {\n\t\tobj.m(\n\t\t\t1 // trailing\n\t\t).n();\n\t}\n}', '// trailing');
	}

	/** An arrow body as the sole argument. */
	public inline function testArrowArgBodyUnderNoWrap(): Void {
		assertSurvivesNoWrap('class C {\n\tfunction f() {\n\t\tg(\n\t\t\tx -> x // trailing\n\t\t);\n\t}\n}', '// trailing');
	}

	/** A call nested inside metadata arguments. */
	public inline function testMetadataNestedSoleArgUnderNoWrap(): Void {
		assertSurvivesNoWrap('class C {\n\t@:build(Macro.run(\n\t\t"x" // trailing\n\t))\n\tfunction f() {}\n}', '// trailing');
	}

	/** `var x = g(sole)`. */
	public inline function testVarInitSoleCallUnderNoWrap(): Void {
		assertSurvivesNoWrap('class C {\n\tfunction f() {\n\t\tvar v = g(\n\t\t\t1 // trailing\n\t\t);\n\t}\n}', '// trailing');
	}

	/** A qualified static call `T.m(sole)`. */
	public inline function testStaticSoleCallUnderNoWrap(): Void {
		assertSurvivesNoWrap('class C {\n\tfunction f() {\n\t\tT.m(\n\t\t\t1 // trailing\n\t\t);\n\t}\n}', '// trailing');
	}

	/** `untyped g(sole)`. */
	public inline function testUntypedSoleCallUnderNoWrap(): Void {
		assertSurvivesNoWrap('class C {\n\tfunction f() {\n\t\tuntyped g(\n\t\t\t1 // trailing\n\t\t);\n\t}\n}', '// trailing');
	}

	/** `macro g(sole)` - a reification whose payload is a call. */
	public inline function testMacroSoleCallUnderNoWrap(): Void {
		assertSurvivesNoWrap(
			'class C {\n\tmacro static function f() {\n\t\treturn macro g(\n\t\t\t1 // trailing\n\t\t);\n\t}\n}', '// trailing'
		);
	}

	/** A sole call inside an array comprehension. */
	public inline function testComprehensionSoleCallUnderNoWrap(): Void {
		assertSurvivesNoWrap(
			'class C {\n\tfunction f() {\n\t\treturn [\n\t\t\tfor (i in a) g(\n\t\t\t\ti // trailing\n\t\t\t)\n\t\t];\n\t}\n}',
			'// trailing'
		);
	}

	/** A sole call in condition position - `if (g(sole))`. */
	public inline function testConditionSoleCallUnderNoWrap(): Void {
		assertSurvivesNoWrap('class C {\n\tfunction f() {\n\t\tif (g(\n\t\t\t1 // trailing\n\t\t)) act();\n\t}\n}', '// trailing');
	}

	/**
	 * GUARD: a block comment never terminates at a newline, so its glue is
	 * legal and the `NoWrap` body keeps its force-flat marker - the fully
	 * collapsed single line, byte-identical to the pre-fix output.
	 */
	public function testSoleArgBlockCommentStaysFlatUnderNoWrap(): Void {
		final source: String = 'class C {\n\tfunction f(a:Int) {\n\t\tg(\n\t\t\ta /* trailing */\n\t\t);\n\t}\n}';
		final expected: String = 'class C {\n\tfunction f(a:Int) {\n\t\tg(a /* trailing */);\n\t}\n}\n';
		Assert.equals(expected, roundTripWith(source, CFG_NOWRAP));
		Assert.equals(expected, roundTripWith(expected, CFG_NOWRAP), 'not idempotent');
	}

	/**
	 * GUARD: a comment-free sole argument still collapses flat under the
	 * `NoWrap` rule - the marker is skipped only for guard-bearing bodies.
	 */
	public function testSoleArgWithoutCommentStaysFlatUnderNoWrap(): Void {
		final source: String = 'class C {\n\tfunction f(a:Int) {\n\t\tg(\n\t\t\ta\n\t\t);\n\t}\n}';
		Assert.equals('class C {\n\tfunction f(a:Int) {\n\t\tg(a);\n\t}\n}\n', roundTripWith(source, CFG_NOWRAP));
	}

	/**
	 * The seam assertion: the emitted source must RE-PARSE (a swallowed
	 * closer does not), must still carry the comment, and must be a fixed
	 * point of a second pass. `emit` selects the writer configuration.
	 */
	private function assertSeam(source: String, comment: String, emit: String -> String): Void {
		final out: String = emit(source);
		Assert.isTrue(out.indexOf(comment) >= 0, 'comment lost: <$out>');
		try {
			HaxeModuleTriviaParser.parse(out);
		} catch (exception: Exception) {
			Assert.fail('emitted source does not re-parse: <$out>, err=${exception.message}');
			return;
		}
		Assert.equals(out, emit(out), 'not idempotent: <$out>');
	}

	/** Seam assertion at the COMPILED writer defaults. */
	private inline function assertSurvives(source: String, comment: String): Void {
		assertSeam(source, comment, roundTrip);
	}

	/** Seam assertion under a cascade that resolves `NoWrap` for a sole argument. */
	private inline function assertSurvivesNoWrap(source: String, comment: String): Void {
		assertSeam(source, comment, roundTripWith.bind(_, CFG_NOWRAP));
	}

	private function roundTrip(source: String): String {
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		return HaxeModuleTriviaWriter.write(ast);
	}

	private function roundTripWith(source: String, cfg: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(cfg);
		final ast: anyparse.grammar.haxe.trivia.Pairs.HxModuleT = HaxeModuleTriviaParser.parse(source);
		return HaxeModuleTriviaWriter.write(ast, opts);
	}

}
