package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PreferFinal;
import anyparse.check.ReturnReassignTernary;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;

/**
 * The `return-reassign-ternary` check: a function-tail `if (cond) x = e; return x;`
 * whose `x` is a proven LOCAL or PARAM collapses to `return cond ? e : x;`. Only a
 * no-else `if` whose body is exactly one plain `=` assignment to the bare identifier
 * the very next statement returns qualifies; a field target, a compound operator, an
 * `else`, an intervening statement, a lambda capture, or a write to `x` inside the
 * condition / r-value all refuse. A comment the rebuild would drop keeps the site
 * report-only. Default OFF (a `DefaultOff` marker).
 */
class ReturnReassignTernaryCheckTest extends Test {

	public function testBasicFlagged(): Void {
		final vs: Array<Violation> = violations(fn('var x = 1;\n\t\tif (a) x = 2;\n\t\treturn x;'));
		Assert.equals(1, vs.length);
		Assert.equals('return-reassign-ternary', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this conditional reassignment and its next-line return can be a single ternary return', vs[0].message);
	}

	public function testBasicFixed(): Void {
		final es: Array<{ span: Span, text: String }> = edits(fn('var x = 1;\n\t\tif (a) x = 2;\n\t\treturn x;'));
		Assert.equals(1, es.length);
		Assert.equals('return a ? 2 : x;', es[0].text);
	}

	/** The TM reference shape (`src/api/API.hx`): the tail guard on an accumulator string. */
	public function testReferenceShapeFixed(): Void {
		final es: Array<{ span: Span, text: String }> = edits(fn(
			'var errorMessages = g();\n\t\tif (errorMessages.length == 0) errorMessages = unknownErrorMessage(localize);\n\t\treturn errorMessages;'
		));
		Assert.equals(1, es.length);
		Assert.equals('return errorMessages.length == 0 ? unknownErrorMessage(localize) : errorMessages;', es[0].text);
	}

	public function testParamTargetFixed(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f(x:Int):Int {\n\t\tif (a) x = 2;\n\t\treturn x;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('return a ? 2 : x;', es[0].text);
	}

	public function testBracedBodyFixed(): Void {
		final es: Array<{ span: Span, text: String }> = edits(fn('var x = 1;\n\t\tif (a) {\n\t\t\tx = 2;\n\t\t}\n\t\treturn x;'));
		Assert.equals(1, es.length);
		Assert.equals('return a ? 2 : x;', es[0].text);
	}

	/** A FIELD write may run a property setter -- never merged. */
	public function testFieldTargetNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tvar x:Int = 0;\n\tfunction f():Int {\n\t\tif (a) x = 2;\n\t\treturn x;\n\t}\n}').length);
	}

	public function testMemberPathTargetNotFlagged(): Void {
		// The RETURN is a bare identifier, so only the l-value kind gate can reject this.
		Assert.equals(0, violations(fn('var x = 1;\n\t\tif (a) o.x = 2;\n\t\treturn x;')).length);
	}

	public function testCompoundAssignNotFlagged(): Void {
		Assert.equals(0, violations(fn('var x = 1;\n\t\tif (a) x += 2;\n\t\treturn x;')).length);
	}

	public function testNullCoalAssignNotFlagged(): Void {
		Assert.equals(0, violations(fn('var x = 1;\n\t\tif (a) x ??= 2;\n\t\treturn x;')).length);
	}

	public function testElseBranchNotFlagged(): Void {
		// The else branch must NOT write `x`, or the second-write gate rejects the fixture
		// first and this one proves nothing. `g()` is the real hazard: the merge drops it.
		Assert.equals(0, violations(fn('var x = 1;\n\t\tif (a) x = 2;\n\t\telse g();\n\t\treturn x;')).length);
	}

	public function testStatementBetweenNotFlagged(): Void {
		Assert.equals(0, violations(fn('var x = 1;\n\t\tif (a) x = 2;\n\t\tg();\n\t\treturn x;')).length);
	}

	public function testDifferentNameNotFlagged(): Void {
		Assert.equals(0, violations(fn('var x = 1;\n\t\tvar y = 0;\n\t\tif (a) x = 2;\n\t\treturn y;')).length);
	}

	public function testMultiStatementBodyNotFlagged(): Void {
		// The assignment comes FIRST, so `children[0]` is the assignment and only the
		// one-statement gate can reject this -- the merge would drop the trailing `g()`.
		Assert.equals(0, violations(fn('var x = 1;\n\t\tif (a) {\n\t\t\tx = 2;\n\t\t\tg();\n\t\t}\n\t\treturn x;')).length);
	}

	/** A write to `x` inside the CONDITION runs before the conceptual store -- fail closed. */
	public function testConditionWritesTargetNotFlagged(): Void {
		Assert.equals(0, violations(fn('var x = 1;\n\t\tif ((x = g()) > 0) x = 2;\n\t\treturn x;')).length);
	}

	public function testRhsWritesTargetNotFlagged(): Void {
		Assert.equals(0, violations(fn('var x = 1;\n\t\tif (a) x = (x = 3) + 1;\n\t\treturn x;')).length);
	}

	/** The r-value may READ `x` -- it evaluates before the conceptual write. */
	public function testRhsReadsTargetFixed(): Void {
		final es: Array<{ span: Span, text: String }> = edits(fn('var x = 1;\n\t\tif (a) x = x + 1;\n\t\treturn x;'));
		Assert.equals(1, es.length);
		Assert.equals('return a ? x + 1 : x;', es[0].text);
	}

	/** A closure could observe the dropped store after the return -- any capture refuses. */
	public function testLambdaCaptureNotFlagged(): Void {
		Assert.equals(0, violations(fn('var x = 1;\n\t\tg(() -> x);\n\t\tif (a) x = 2;\n\t\treturn x;')).length);
	}

	/** A NAMED local function captures exactly as a lambda does -- `lambdaKinds` alone misses it. */
	public function testNamedLocalFunctionCaptureNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				fn('var x = 1;\n\t\tfunction inner():Int {\n\t\t\tif (a) x = 2;\n\t\t\treturn x;\n\t\t}\n\t\tinner();\n\t\treturn x;')
			).length
		);
	}

	public function testInlineLocalFunctionCaptureNotFlagged(): Void {
		Assert.equals(0, violations(fn('var x = 1;\n\t\tinline function g2():Int return x;\n\t\tif (a) x = 2;\n\t\treturn x;')).length);
	}

	/** The capture gate is SCOPE-aware: a binding declared INSIDE the nested function is not captured. */
	public function testBindingLocalToNestedFunctionFixed(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			fn('var h = function():Int {\n\t\t\tvar x = 1;\n\t\t\tif (a) x = 2;\n\t\t\treturn x;\n\t\t};\n\t\treturn h();')
		);
		Assert.equals(1, es.length);
		Assert.equals('return a ? 2 : x;', es[0].text);
	}

	/**
	 * An INFERRED enclosing return type drops the expected type the assignment gave the r-value,
	 * so `var x:Map<String, Int> = null; if (c) x = [];` would emit a `return c ? [] : x;` that
	 * does not typecheck -- refused wholesale.
	 */
	public function testInferredReturnTypeNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f() {\n\t\tvar x = 1;\n\t\tif (a) x = 2;\n\t\treturn x;\n\t}\n}').length);
	}

	/** The direct-block-child restriction: the trailing `return` is the OUTER statement's sibling. */
	public function testInlineNestedIfNotFlagged(): Void {
		Assert.equals(0, violations(fn('var x = 1;\n\t\tif (b) if (a) x = 2;\n\t\treturn x;')).length);
	}

	/** The `writeParentKinds` arm of the condition wrap -- an assignment binds looser than `?:`. */
	public function testAssignmentConditionWrapped(): Void {
		final es: Array<{ span: Span, text: String }> = edits(fn('var x = 1;\n\t\tif (y = g()) x = 2;\n\t\treturn x;'));
		Assert.equals(1, es.length);
		Assert.equals('return (y = g()) ? 2 : x;', es[0].text);
	}

	/** Two independent pairs in one file -- the `run` -> `fix` span-key round trip with N > 1. */
	public function testTwoPairsInOneFileFixed(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f():Int {\n\t\tvar x = 1;\n\t\tif (a) x = 2;\n\t\treturn x;\n\t}\n'
			+ '\n\tfunction g():Int {\n\t\tvar y = 1;\n\t\tif (b) y = 3;\n\t\treturn y;\n\t}\n}'
		);
		Assert.equals(2, es.length);
		Assert.equals('return a ? 2 : x;', es[0].text);
		Assert.equals('return b ? 3 : y;', es[1].text);
	}

	/** A MULTI-LINE r-value (the TM `CrashDumper` object literal) strands the `: x` tail after its closing brace -- not flagged. */
	public function testMultiLineRhsNotFlagged(): Void {
		Assert.equals(
			0,
			violations(fn('var x = null;\n\t\tif (a) {\n\t\t\tx = {\n\t\t\t\tone: 1,\n\t\t\t\ttwo: 2\n\t\t\t};\n\t\t}\n\t\treturn x;')).length
		);
	}

	public function testMultiLineConditionFixed(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(fn('var x = 1;\n\t\tif (aVeryLongCondition\n\t\t\t&& another) x = 2;\n\t\treturn x;'));
		Assert.equals(1, es.length);
		Assert.equals('return aVeryLongCondition\n\t\t\t&& another ? 2 : x;', es[0].text);
	}

	public function testTernaryConditionWrapped(): Void {
		final es: Array<{ span: Span, text: String }> = edits(fn('var x = 1;\n\t\tif (a ? b : c) x = 2;\n\t\treturn x;'));
		Assert.equals(1, es.length);
		Assert.equals('return (a ? b : c) ? 2 : x;', es[0].text);
	}

	public function testComparisonConditionNotWrapped(): Void {
		final es: Array<{ span: Span, text: String }> = edits(fn('var x = 1;\n\t\tif (n > 0) x = 2;\n\t\treturn x;'));
		Assert.equals(1, es.length);
		Assert.equals('return n > 0 ? 2 : x;', es[0].text);
	}

	/** A comment the rebuild would drop keeps the site REPORT-ONLY: flagged, no edit. */
	public function testDroppedCommentReportOnly(): Void {
		final src: String = fn('var x = 1;\n\t\tif (a) /* keep */ x = 2;\n\t\treturn x;');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals(
			'this conditional reassignment and its next-line return can be a single ternary return (a comment blocks the autofix)',
			vs[0].message
		);
		Assert.equals(0, edits(src).length);
	}

	/** A comment INSIDE a verbatim-copied span rides along, so the fix still applies. */
	public function testCommentInsideKeptSpanFixed(): Void {
		final es: Array<{ span: Span, text: String }> = edits(fn('var x = 1;\n\t\tif (a) x = g(/* keep */ 2);\n\t\treturn x;'));
		Assert.equals(1, es.length);
		Assert.equals('return a ? g(/* keep */ 2) : x;', es[0].text);
	}

	/** The merged ternary is emitted on ONE line and the WRITER lays it out -- no over-long line survives. */
	public function testLongMergedTernaryWrapsThroughWriter(): Void {
		final src: String = canon(
			'class C {\n\tfunction f():Int {\n\t\tvar someRatherLongLocalNameHere = computeDefault(alphaValue);\n'
			+ '\t\tif (conditionHolds(alphaValue, betaValue, gammaValue)) someRatherLongLocalNameHere = '
			+ 'computeAlternateValue(alphaValue, betaValue, gammaValue, deltaValue, epsilonValue);\n'
			+ '\t\treturn someRatherLongLocalNameHere;\n\t}\n}'
		);
		final out: String = applyFixOnce(src);
		Assert.notEquals(src, out);
		Assert.isTrue(out.indexOf('\t\t\t? computeAlternateValue(') >= 0);
		Assert.isTrue(out.indexOf('\t\t\t: someRatherLongLocalNameHere;') >= 0);
		Assert.equals(out, canon(out));
	}

	/**
	 * SYNERGY (two passes, two rules -- neither chains inside the other): once the tail
	 * merges, `x`'s only remaining write is its initializer, so `prefer-final` picks it
	 * up on the NEXT pass.
	 */
	public function testSynergyPreferFinalSecondPass(): Void {
		final merged: String = applyFixOnce(canon(fn('var x = 1;\n\t\tif (a) x = 2;\n\t\treturn x;')));
		Assert.isTrue(merged.indexOf('return a ? 2 : x;') >= 0);
		Assert.isTrue(merged.indexOf('var x = 1;') >= 0);
		final finalised: String = applyPreferFinalOnce(merged);
		Assert.isTrue(finalised.indexOf('final x = 1;') >= 0);
		Assert.isTrue(finalised.indexOf('return a ? 2 : x;') >= 0);
	}

	/**
	 * COUNTER-CASE (the TM `API.hx` accumulator): a `+=` in a loop keeps `x` a `var`, so
	 * only the tail merges -- `prefer-final` must NOT follow.
	 */
	public function testAccumulatorStaysVar(): Void {
		final merged: String = applyFixOnce(canon(
			'class C {\n\tfunction f(ms:Array<String>):String {\n\t\tvar x = \'\';\n\t\tfor (m in ms) x += m;\n'
			+ '\t\tif (x.length == 0) x = \'none\';\n\t\treturn x;\n\t}\n}'
		));
		Assert.isTrue(merged.indexOf('return x.length == 0 ? \'none\' : x;') >= 0);
		Assert.isTrue(merged.indexOf('var x = \'\';') >= 0);
		Assert.equals(merged, applyPreferFinalOnce(merged));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('return-reassign-ternary'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('return-reassign-ternary'));
	}

	private function fn(body: String): String {
		return 'class C {\n\tfunction f():Int {\n\t\t$body\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new ReturnReassignTernary().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: ReturnReassignTernary = new ReturnReassignTernary();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

	private function applyFixOnce(source: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: ReturnReassignTernary = new ReturnReassignTernary();
		final es: Array<{ span: Span, text: String }> = check.fix(source, check.run([{ file: 'C.hx', source: source }], plugin), plugin);
		return es.length == 0
			? source
			: switch RefactorSupport.canonicalize(source, es, false, plugin) {
				case Ok(text): text;
				case Err(message): throw message;
			};
	}

	private function applyPreferFinalOnce(source: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: PreferFinal = new PreferFinal();
		final es: Array<{ span: Span, text: String }> = check.fix(source, check.run([{ file: 'C.hx', source: source }], plugin), plugin);
		return es.length == 0
			? source
			: switch RefactorSupport.canonicalize(source, es, false, plugin) {
				case Ok(text): text;
				case Err(message): throw message;
			};
	}

	private function canon(source: String): String {
		return switch RefactorSupport.canonicalize(source, [], true, new HaxeQueryPlugin()) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

}
