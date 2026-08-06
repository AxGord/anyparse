package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.LoopGuard;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `loop-guard` check in both arms. LIFT: a `for` / `while` whose braced body opens with a
 * bare `if (g) continue;` guard is flagged `Info` and the guard moves into a NEW loop header
 * with an inverted condition (`for (x in xs) if (INV) { REST }`). MERGE: a loop whose body is
 * already a lifted header `if (c) { … }` gets the inversion joined onto that header with `&&`
 * (`for (x in xs) if (c && INV) { REST }`), each side parenthesised only when it binds looser
 * than `&&`. The inversion pushes De Morgan inward (`a && b` → `!a || !b`), flips `==` / `!=`
 * (NaN-safe), and keeps an ordered comparison (`< <= > >=`) wrapped `!(…)` (unflipped, since
 * `!(a < b)` and `a >= b` differ under NaN); a comment inside the condition — or a condition
 * whose flattened `||` chain would strand a null-safety narrowing — falls back to the verbatim
 * `!(cond)` wrap. A cascade of guards, a guard-only body, an unbraced body, an `else` branch
 * and a comment inside the guard are safe misses on both arms; a later `continue` deeper in the
 * body is preserved.
 */
class LoopGuardCheckTest extends Test {

	public function testForGuardFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('for (x in xs) {\n\t\t\tif (x == 0) continue;\n\t\t\ttrace(x);\n\t\t}'));
		Assert.equals(1, vs.length);
		Assert.equals('loop-guard', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this leading if-continue guard can move to the loop header (for/while … if)', vs[0].message);
	}

	public function testEqFlipFixed(): Void {
		Assert.equals(
			wrap('for (x in xs) if (x != 0) {\n\t\t\ttrace(x);\n\t\t}'),
			applyFix(wrap('for (x in xs) {\n\t\t\tif (x == 0) continue;\n\t\t\ttrace(x);\n\t\t}'))
		);
	}

	public function testNotEqFlipFixed(): Void {
		Assert.equals(
			wrap('for (x in xs) if (x == 0) {\n\t\t\ttrace(x);\n\t\t}'),
			applyFix(wrap('for (x in xs) {\n\t\t\tif (x != 0) continue;\n\t\t\ttrace(x);\n\t\t}'))
		);
	}

	public function testNotStripFixed(): Void {
		Assert.equals(
			wrap('for (x in xs) if (done) {\n\t\t\ttrace(x);\n\t\t}'),
			applyFix(wrap('for (x in xs) {\n\t\t\tif (!done) continue;\n\t\t\ttrace(x);\n\t\t}'))
		);
	}

	public function testNotStripUnwrapsParen(): Void {
		Assert.equals(
			wrap('for (x in xs) if (a && b) {\n\t\t\ttrace(x);\n\t\t}'),
			applyFix(wrap('for (x in xs) {\n\t\t\tif (!(a && b)) continue;\n\t\t\ttrace(x);\n\t\t}'))
		);
	}

	public function testLessThanNotFlagged(): Void {
		// The lifted header would read `if (!(q < 10))` — `q` is unbound, so its type does not
		// license the flip, the header buys nothing over the `continue` guard and the site is left
		// alone. Deliberately NOT the loop variable `x`: `wrap` declares `xs:Array<Int>` and the
		// for-binding element-type arm types `x` as `Int`, which licenses the flip.
		Assert.equals(0, violations(wrap('for (x in xs) {\n\t\t\tif (q < 10) continue;\n\t\t\ttrace(x);\n\t\t}')).length);
	}

	public function testOrderedStringGuardNotFlagged(): Void {
		// The sibling above leaves the operand UNRESOLVED; here both operands resolve and the site
		// is still refused. The lifted header would read `if (!(s < k))`, which buys nothing over
		// the `continue` guard: Haxe has no non-nullable string type, so the flip `s >= k` is not
		// licensed (a null operand makes the two disagree) and `negationIsClean` refuses. The `Int`
		// twin in the second assertion is the same fixture shape over a licensed nominal and IS
		// flagged, so what refuses the first is the type gate and not the loop shape.
		final str: String =
			'class C {\n\tfunction f(ss:Array<String>, k:String):Void {\n\t\tfor (s in ss) {\n\t\t\tif (s < k) continue;\n\t\t\ttrace(s);\n\t\t}\n\t}\n}';
		Assert.equals(0, violations(str).length);
		Assert.equals(1, violations(wrap('for (x in xs) {\n\t\t\tif (x < 0) continue;\n\t\t\ttrace(x);\n\t\t}')).length);
	}

	public function testComplexCondDeMorgan(): Void {
		Assert.equals(
			wrap('for (x in xs) if (!a || !b) {\n\t\t\ttrace(x);\n\t\t}'),
			applyFix(wrap('for (x in xs) {\n\t\t\tif (a && b) continue;\n\t\t\ttrace(x);\n\t\t}'))
		);
	}

	public function testAtomicIdentNoParens(): Void {
		Assert.equals(
			wrap('for (x in xs) if (!skip) {\n\t\t\ttrace(x);\n\t\t}'),
			applyFix(wrap('for (x in xs) {\n\t\t\tif (skip) continue;\n\t\t\ttrace(x);\n\t\t}'))
		);
	}

	public function testAtomicCallNoParens(): Void {
		Assert.equals(
			wrap('for (x in xs) if (!skip()) {\n\t\t\ttrace(x);\n\t\t}'),
			applyFix(wrap('for (x in xs) {\n\t\t\tif (skip()) continue;\n\t\t\ttrace(x);\n\t\t}'))
		);
	}

	public function testBracedSingleContinueFlaggedAndFixed(): Void {
		Assert.equals(1, violations(wrap('for (x in xs) {\n\t\t\tif (x == 0) { continue; }\n\t\t\ttrace(x);\n\t\t}')).length);
		Assert.equals(
			wrap('for (x in xs) if (x != 0) {\n\t\t\ttrace(x);\n\t\t}'),
			applyFix(wrap('for (x in xs) {\n\t\t\tif (x == 0) { continue; }\n\t\t\ttrace(x);\n\t\t}'))
		);
	}

	public function testWhileLoopFlaggedAndFixed(): Void {
		final src: String = wrap('while (xs.length > 0) {\n\t\t\tif (xs.length == 3) continue;\n\t\t\ttrace(xs);\n\t\t}');
		Assert.equals(1, violations(src).length);
		Assert.equals(wrap('while (xs.length > 0) if (xs.length != 3) {\n\t\t\ttrace(xs);\n\t\t}'), applyFix(src));
	}

	public function testSafeNullChainKeepsDeMorgan(): Void {
		// No operand consumes a narrowing from a non-first operand, so De Morgan stands.
		Assert.equals(
			wrap('for (x in xs) if (a == null || b == null || c == null) {\n\t\t\ttrace(x);\n\t\t}'),
			applyFix(wrap('for (x in xs) {\n\t\t\tif (a != null && b != null && c != null) continue;\n\t\t\ttrace(x);\n\t\t}'))
		);
	}

	public function testStrandedNarrowingFallsBackToVerbatimWrap(): Void {
		// `b`'s narrowing comes from operand 2 and would not reach operand 3 of the negated
		// `||` chain, so the lifted header wraps the whole condition verbatim instead.
		Assert.equals(
			wrap('for (x in xs) if (!(a != null && b != null && p(a.length, b.length))) {\n\t\t\ttrace(x);\n\t\t}'),
			applyFix(wrap('for (x in xs) {\n\t\t\tif (a != null && b != null && p(a.length, b.length)) continue;\n\t\t\ttrace(x);\n\t\t}'))
		);
	}

	public function testParenNestedStrandedNarrowingFallsBackToVerbatimWrap(): Void {
		// The negation DROPS the parens, so the emitted chain is the same flat three-operand
		// `||` as the unparenthesised shape — the gate must see through the parens too.
		Assert.equals(
			wrap('for (x in xs) if (!(a != null && (b != null && p(a.length, b.length)))) {\n\t\t\ttrace(x);\n\t\t}'),
			applyFix(
				wrap('for (x in xs) {\n\t\t\tif (a != null && (b != null && p(a.length, b.length))) continue;\n\t\t\ttrace(x);\n\t\t}')
			)
		);
	}

	public function testCascadeNotFlagged(): Void {
		Assert.equals(
			0, violations(wrap('for (x in xs) {\n\t\t\tif (x == 0) continue;\n\t\t\tif (x == 1) continue;\n\t\t\ttrace(x);\n\t\t}')).length
		);
	}

	public function testLaterContinueStillFlaggedAndPreserved(): Void {
		final src: String = wrap(
			'for (x in xs) {\n\t\t\tif (x == 0) continue;\n\t\t\ttrace(x);\n\t\t\tif (x == 5) continue;\n\t\t\ttrace(x + 1);\n\t\t}'
		);
		Assert.equals(1, violations(src).length);
		Assert.equals(
			wrap('for (x in xs) if (x != 0) {\n\t\t\ttrace(x);\n\t\t\tif (x == 5) continue;\n\t\t\ttrace(x + 1);\n\t\t}'), applyFix(src)
		);
	}

	public function testGuardOnlyBodyNotFlagged(): Void {
		Assert.equals(0, violations(wrap('for (x in xs) {\n\t\t\tif (x == 0) continue;\n\t\t}')).length);
	}

	public function testBareUnbracedBodyNotFlagged(): Void {
		Assert.equals(0, violations(wrap('for (x in xs) if (x == 0) continue;')).length);
	}

	public function testElseBranchNotFlagged(): Void {
		Assert.equals(0, violations(wrap('for (x in xs) {\n\t\t\tif (x == 0) continue; else trace(x);\n\t\t\ttrace(x);\n\t\t}')).length);
	}

	public function testCommentInsideGuardNotFlagged(): Void {
		Assert.equals(0, violations(wrap('for (x in xs) {\n\t\t\tif (x == 0) /* skip */ continue;\n\t\t\ttrace(x);\n\t\t}')).length);
	}

	public function testCommentBeforeGuardNotFlagged(): Void {
		Assert.equals(
			0, violations(wrap('for (x in xs) {\n\t\t\t// explain the guard\n\t\t\tif (x == 0) continue;\n\t\t\ttrace(x);\n\t\t}')).length
		);
	}

	public function testApplyFixByteExact(): Void {
		final input: String =
			'class C {\n\tfunction f(xs:Array<Int>):Void {\n\t\tfor (x in xs) {\n\t\t\tif (x == 0) continue;\n\t\t\ttrace(x);\n\t\t}\n\t}\n}';
		final expected: String =
			'class C {\n\tfunction f(xs:Array<Int>):Void {\n\t\tfor (x in xs) if (x != 0) {\n\t\t\ttrace(x);\n\t\t}\n\t}\n}';
		Assert.equals(expected, applyFix(input));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('loop-guard'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('loop-guard'));
		Assert.equals(143, Linter.builtins().length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { for (x in xs) { if (x) continue;').length);
	}

	public function testHeaderIfGuardFlagged(): Void {
		Assert.equals(1, violations(wrap('for (x in xs) if (x > 0) {\n\t\t\tif (x == 3) continue;\n\t\t\ttrace(x);\n\t\t}')).length);
	}

	public function testHeaderIfMergedFix(): Void {
		Assert.equals(
			wrap('for (x in xs) if (x > 0 && x != 3) {\n\t\t\ttrace(x);\n\t\t}'),
			applyFix(wrap('for (x in xs) if (x > 0) {\n\t\t\tif (x == 3) continue;\n\t\t\ttrace(x);\n\t\t}'))
		);
	}

	public function testHeaderIfOrNegationParenthesised(): Void {
		// De Morgan turns the `&&` guard into a top-level `||`, which binds looser than the
		// `&&` slot it lands in — without the pair the merged header would re-associate.
		Assert.equals(
			wrap('for (x in xs) if (c && (!a || !b)) {\n\t\t\ttrace(x);\n\t\t}'),
			applyFix(wrap('for (x in xs) if (c) {\n\t\t\tif (a && b) continue;\n\t\t\ttrace(x);\n\t\t}'))
		);
	}

	public function testHeaderIfLooseHeaderCondParenthesised(): Void {
		Assert.equals(
			wrap('for (x in xs) if ((a || b) && !skip) {\n\t\t\ttrace(x);\n\t\t}'),
			applyFix(wrap('for (x in xs) if (a || b) {\n\t\t\tif (skip) continue;\n\t\t\ttrace(x);\n\t\t}'))
		);
	}

	public function testHeaderIfTightNegationNotParenthesised(): Void {
		Assert.equals(
			wrap('for (x in xs) if (c && !skip) {\n\t\t\ttrace(x);\n\t\t}'),
			applyFix(wrap('for (x in xs) if (c) {\n\t\t\tif (skip) continue;\n\t\t\ttrace(x);\n\t\t}'))
		);
	}

	public function testHeaderIfNestedNotStripMerged(): Void {
		Assert.equals(
			wrap('for (x in xs) if (c && a && b) {\n\t\t\ttrace(x);\n\t\t}'),
			applyFix(wrap('for (x in xs) if (c) {\n\t\t\tif (!(a && b)) continue;\n\t\t\ttrace(x);\n\t\t}'))
		);
	}

	public function testWhileHeaderIfFlaggedAndFixed(): Void {
		final src: String = wrap('while (xs.length > 0) if (ok) {\n\t\t\tif (xs.length == 3) continue;\n\t\t\ttrace(xs);\n\t\t}');
		Assert.equals(1, violations(src).length);
		Assert.equals(wrap('while (xs.length > 0) if (ok && xs.length != 3) {\n\t\t\ttrace(xs);\n\t\t}'), applyFix(src));
	}

	public function testHeaderIfElseNotFlagged(): Void {
		// Merging the guard into the header would change WHEN the `else` runs: it fires on
		// `!c` today and would fire on `!c || g` after.
		Assert.equals(0, violations(wrap('for (x in xs) if (c) {\n\t\t\tif (g) continue;\n\t\t\ttrace(x);\n\t\t} else trace(0);')).length);
	}

	public function testHeaderIfCascadeNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap('for (x in xs) if (c) {\n\t\t\tif (x == 0) continue;\n\t\t\tif (x == 1) continue;\n\t\t\ttrace(x);\n\t\t}'))
				.length
		);
	}

	public function testHeaderIfGuardOnlyBodyNotFlagged(): Void {
		Assert.equals(0, violations(wrap('for (x in xs) if (c) {\n\t\t\tif (x == 0) continue;\n\t\t}')).length);
	}

	public function testHeaderIfUnbracedThenNotFlagged(): Void {
		Assert.equals(0, violations(wrap('for (x in xs) if (c) if (x == 0) continue;')).length);
	}

	public function testHeaderIfLaterContinuePreserved(): Void {
		// A `continue` deeper in REST still targets the same loop after the merge, so it rides along.
		final src: String = wrap(
			'for (x in xs) if (c) {\n\t\t\tif (x == 0) continue;\n\t\t\ttrace(x);\n\t\t\tif (x == 5) continue;\n\t\t\ttrace(x + 1);\n\t\t}'
		);
		Assert.equals(1, violations(src).length);
		Assert.equals(
			wrap('for (x in xs) if (c && x != 0) {\n\t\t\ttrace(x);\n\t\t\tif (x == 5) continue;\n\t\t\ttrace(x + 1);\n\t\t}'),
			applyFix(src)
		);
	}

	public function testHeaderIfNestedMergeCandidatesFixOuterFirst(): Void {
		// Two merge candidates, one inside the other. Both are reported, but the outer block edit
		// CONTAINS the inner pair, so `dropContainedEdits` keeps only the outer and the inner merges on
		// the next `--fix` pass — the same staging the LIFT arm already relies on.
		final inner: String = 'for (y in xs) if (d) {\n\t\t\t\tif (y == 1) continue;\n\t\t\t\ttrace(y);\n\t\t\t}';
		final src: String = wrap('for (x in xs) if (c) {\n\t\t\tif (x == 0) continue;\n\t\t\t$inner\n\t\t}');
		Assert.equals(2, violations(src).length);
		Assert.equals(wrap('for (x in xs) if (c && x != 0) {\n\t\t\t$inner\n\t\t}'), applyFix(src));
	}

	public function testHeaderIfNotStripOfLooseOperandParenthesised(): Void {
		// The STRIP shapes: `!( … )` hands its operand back VERBATIM, so whether the merged `&&` slot
		// needs a pair is decided by that operand OWN kind, not by anything the negation built.
		Assert.equals(
			wrap('for (x in xs) if (c && (p || q)) {\n\t\t\ttrace(x);\n\t\t}'),
			applyFix(wrap('for (x in xs) if (c) {\n\t\t\tif (!(p || q)) continue;\n\t\t\ttrace(x);\n\t\t}'))
		);
		Assert.equals(
			wrap('for (x in xs) if (c && (p ?? q)) {\n\t\t\ttrace(x);\n\t\t}'),
			applyFix(wrap('for (x in xs) if (c) {\n\t\t\tif (!(p ?? q)) continue;\n\t\t\ttrace(x);\n\t\t}'))
		);
		Assert.equals(
			wrap('for (x in xs) if (c && (p ? q : r)) {\n\t\t\ttrace(x);\n\t\t}'),
			applyFix(wrap('for (x in xs) if (c) {\n\t\t\tif (!(p ? q : r)) continue;\n\t\t\ttrace(x);\n\t\t}'))
		);
	}

	public function testHeaderIfCommentBeforeGuardNotFlagged(): Void {
		Assert.equals(
			0,
			violations(wrap('for (x in xs) if (c) {\n\t\t\t// explain the guard\n\t\t\tif (x == 0) continue;\n\t\t\ttrace(x);\n\t\t}'))
				.length
		);
	}

	public function testHeaderIfCommentInsideGuardNotFlagged(): Void {
		Assert.equals(0, violations(wrap('for (x in xs) if (c) {\n\t\t\tif (x == 0) /* skip */ continue;\n\t\t\ttrace(x);\n\t\t}'))
			.length);
	}

	public function testHeaderIfDeclinedFlipNotFlagged(): Void {
		Assert.equals(0, violations(wrap('for (x in xs) if (c) {\n\t\t\tif (q < 10) continue;\n\t\t\ttrace(x);\n\t\t}')).length);
	}

	public function testHeaderIfCanaryShapeMerged(): Void {
		final sig: String = 'os:Array<Obj>, allowedType:Bool, name:String';
		final input: String =
			'for (o in os) if (!o.locked) {\n\t\t\tif (o is PlayerBase && !(allowedType && name == o.type)) continue;\n\t\t\ttrace(o);\n\t\t}';
		final merged: String =
			'for (o in os) if (!o.locked && (!(o is PlayerBase) || allowedType && name == o.type)) {\n\t\t\ttrace(o);\n\t\t}';
		Assert.equals(wrapIn(sig, merged), applyFix(wrapIn(sig, input)));
	}

	private inline function wrap(loopCode: String): String {
		return wrapIn('xs:Array<Int>', loopCode);
	}

	private function violations(source: String): Array<Violation> {
		return new LoopGuard().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function applyFix(source: String): String {
		final check: LoopGuard = new LoopGuard();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			source, check.run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = source;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}


	private function wrapIn(signature: String, loopCode: String): String {
		return 'class C {\n\tfunction f($signature):Void {\n\t\t$loopCode\n\t}\n}';
	}

}
