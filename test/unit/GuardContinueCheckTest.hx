package unit;

import anyparse.check.Check.Violation;
import anyparse.check.GuardContinue;
import anyparse.check.Linter;
import anyparse.check.LoopGuard;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `guard-continue` check: a loop (`for` / `while` / `do … while`) whose braced
 * body's LAST statement is a bare `if (cond) { … }` (no `else`) preceded by ≥1 other
 * statement is flagged `Info` and de-nested to an `if (!cond) continue;` guard. The
 * inversion pushes De Morgan inward through the shared `NegationScan.negateConditionText`
 * (backed by the grammar's `BooleanLogicSupport`): `a && b` → `!a || !b`, `==` / `!=`
 * flipped, but an ordered comparison (`< <= > >=`) kept wrapped `!(…)` (NaN-safe — `!(a <
 * b)` and `a >= b` differ under NaN); a `||` chain that would strand a null-safety
 * narrowing right-nests a parenthesised group at the stranded operand, and a comment
 * inside the condition falls back to the verbatim `!(cond)` wrap. A de-nested local whose
 * name clashes with a preceding sibling or the iterator is AUTO-RENAMED to a fresh `<name>2` (binder, plain reads and `$name`
 * interpolation reads together); a deeper redeclaration of that name, an inner lambda
 * mentioning it, or an unaccounted-for textual occurrence refuses instead. Plus a
 * glue-comment gate and the sole-`if` / else / empty / unbraced / non-tail exclusions. A
 * flow exit (`break` / `continue` / `return`) in the then-branch does NOT refuse: the
 * de-nested body stays in the same loop and function, so every jump target is unchanged.
 * Runs to a fixpoint, so a two-level chain flattens over successive passes.
 */
class GuardContinueCheckTest extends Test {

	// --- positives: flagged + fixed ------------------------------------------------

	public function testSingleGuardFlaggedAndFixed(): Void {
		final vs: Array<Violation> = v('for (x in xs) {\n\t\t\tpre();\n\t\t\tif (a != null) {\n\t\t\t\tbody(a);\n\t\t\t}\n\t\t}');
		Assert.equals(1, vs.length);
		Assert.equals('guard-continue', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this trailing if can de-nest to an if (!cond) continue; guard', vs[0].message);
		Assert.equals(
			wrap('for (x in xs) {\n\t\t\tpre();\n\t\t\tif (a == null) continue;\n\t\t\tbody(a);\n\t\t}'),
			fx('for (x in xs) {\n\t\t\tpre();\n\t\t\tif (a != null) {\n\t\t\t\tbody(a);\n\t\t\t}\n\t\t}')
		);
	}

	public function testTwoLevelChainConverges(): Void {
		// The outer `if` is flagged first; the inner surfaces after de-nesting (fixpoint).
		Assert.equals(
			1,
			v(
				'for (id in xs) {\n\t\t\tfinal a = load(id);\n\t\t\tif (a != null) {\n\t\t\t\tfinal b = find(a);\n'
				+ '\t\t\t\tif (b != null) {\n\t\t\t\t\tuse(b);\n\t\t\t\t}\n\t\t\t}\n\t\t}'
			).length
		);
		Assert.equals(
			wrap(
				'for (id in xs) {\n\t\t\tfinal a = load(id);\n\t\t\tif (a == null) continue;\n\t\t\tfinal b = find(a);\n'
				+ '\t\t\tif (b == null) continue;\n\t\t\tuse(b);\n\t\t}'
			),
			fx(
				'for (id in xs) {\n\t\t\tfinal a = load(id);\n\t\t\tif (a != null) {\n\t\t\t\tfinal b = find(a);\n'
				+ '\t\t\t\tif (b != null) {\n\t\t\t\t\tuse(b);\n\t\t\t\t}\n\t\t\t}\n\t\t}'
			)
		);
	}

	public function testWhileLoopFixed(): Void {
		Assert.equals(
			wrap('while (go()) {\n\t\t\tpre();\n\t\t\tif (!ok) continue;\n\t\t\tbody();\n\t\t}'),
			fx('while (go()) {\n\t\t\tpre();\n\t\t\tif (ok) {\n\t\t\t\tbody();\n\t\t\t}\n\t\t}')
		);
	}

	public function testDoWhileLoopFixed(): Void {
		Assert.equals(
			wrap('do {\n\t\t\tstep();\n\t\t\tif (!cond) continue;\n\t\t\twork();\n\t\t} while (more());'),
			fx('do {\n\t\t\tstep();\n\t\t\tif (cond) {\n\t\t\t\twork();\n\t\t\t}\n\t\t} while (more());')
		);
	}

	public function testNestedLoopTargetsInnerLoop(): Void {
		// An `if` that is the inner loop's tail is flagged for the INNER loop — the
		// inserted `continue` targets it, not the outer loop.
		Assert.equals(
			1,
			v('for (x in xs) {\n\t\t\tfor (y in ys) {\n\t\t\t\tmid();\n\t\t\t\tif (cond) {\n\t\t\t\t\tbody();\n\t\t\t\t}\n\t\t\t}\n\t\t}')
				.length
		);
		Assert.equals(
			wrap('for (x in xs) {\n\t\t\tfor (y in ys) {\n\t\t\t\tmid();\n\t\t\t\tif (!cond) continue;\n\t\t\t\tbody();\n\t\t\t}\n\t\t}'),
			fx('for (x in xs) {\n\t\t\tfor (y in ys) {\n\t\t\t\tmid();\n\t\t\t\tif (cond) {\n\t\t\t\t\tbody();\n\t\t\t\t}\n\t\t\t}\n\t\t}')
		);
	}

	// --- negation submatrix: each output == !(original), compiles -------------------

	public function testEqNullFlipped(): Void {
		Assert.isTrue(fx(cond('a == null')).indexOf('if (a != null) continue;') != -1);
	}

	public function testNotEqNullFlipped(): Void {
		Assert.isTrue(fx(cond('a != null')).indexOf('if (a == null) continue;') != -1);
	}

	public function testNotStripped(): Void {
		Assert.isTrue(fx(cond('!ready')).indexOf('if (ready) continue;') != -1);
	}

	public function testNestedNotStrippedAndParenUnwrapped(): Void {
		Assert.isTrue(fx(cond('!(a || b)')).indexOf('if (a || b) continue;') != -1);
	}

	public function testLessThanNotFlagged(): Void {
		// `q` is unbound, so the flip is not licensed; the guard would have to wrap `!(q < 10)`,
		// which reads worse than the nesting it removes — the site is left alone. NOT the loop
		// variable `x`: `wrap` declares `xs:Array<Int>`, and the for-binding element-type arm now
		// types `x` as `Int`, which WOULD license the flip. The operand has to be genuinely
		// unresolvable for this to pin the unproven -> refuse direction.
		Assert.equals(0, v(cond('q < 10')).length);
	}

	public function testLessEqNotFlagged(): Void {
		Assert.equals(0, v(cond('q <= 10')).length);
	}

	public function testGreaterThanNotFlagged(): Void {
		Assert.equals(0, v(cond('q > 10')).length);
	}

	public function testGreaterEqNotFlagged(): Void {
		Assert.equals(0, v(cond('q >= 10')).length);
	}

	public function testOrderedStringOperandsNotFlagged(): Void {
		// Unlike `q` above, both operands here RESOLVE — and are still refused. `String` carries
		// no NaN, but Haxe has no non-nullable string type, so a null operand makes `!(s < k)`
		// true where `s >= k` is false and the flip is unsound; `negationIsClean` therefore
		// declines and the site is not flagged. The `x < 10` twin below, over the `Int` loop
		// binder, is the same shape with a licensed nominal and IS flagged.
		final str: String = 'class C {\n\tfunction f(ss:Array<String>, k:String):Void {\n\t\tfor (s in ss) {\n\t\t\tpre();\n'
			+ '\t\t\tif (s < k) {\n\t\t\t\tbody();\n\t\t\t}\n\t\t}\n\t}\n}\n';
		Assert.equals(0, new GuardContinue().run([{ file: 'C.hx', source: str }], new HaxeQueryPlugin()).length);
		Assert.equals(1, v(cond('x < 10')).length);
	}

	public function testEqFlipped(): Void {
		Assert.isTrue(fx(cond('x == 10')).indexOf('if (x != 10) continue;') != -1);
	}

	public function testAndDeMorgan(): Void {
		Assert.isTrue(fx(cond('a && b')).indexOf('if (!a || !b) continue;') != -1);
	}

	public function testOrDeMorgan(): Void {
		Assert.isTrue(fx(cond('a || b')).indexOf('if (!a && !b) continue;') != -1);
	}

	public function testMixedDeMorgan(): Void {
		Assert.isTrue(fx(cond('a && (b || c)')).indexOf('if (!a || !b && !c) continue;') != -1);
	}

	public function testDeMorganFlipsEqOperands(): Void {
		Assert.isTrue(fx(cond('s != null && s.ok')).indexOf('if (s == null || !s.ok) continue;') != -1);
	}

	public function testDeMorganOrderedOperandNotFlagged(): Void {
		// One declined operand poisons the whole conjunction: `!(q < 10) || !ok` still wraps.
		// `q` is unbound on purpose — the loop variable `x` now types as `Int` (see
		// `testLessThanNotFlagged`) and would license the flip instead of declining it.
		Assert.equals(0, v(cond('q < 10 && ok')).length);
	}

	public function testDeMorganDoubleNegationOperands(): Void {
		Assert.isTrue(fx(cond('!a && !b')).indexOf('if (a || b) continue;') != -1);
	}

	public function testDeMorganParenOrOperand(): Void {
		Assert.isTrue(fx(cond('(a || b) && c')).indexOf('if (!a && !b || !c) continue;') != -1);
	}

	public function testDeMorganNullCoalOperandKeepsParens(): Void {
		Assert.isTrue(fx(cond('(a ?? b) && c')).indexOf('if (!(a ?? b) || !c) continue;') != -1);
	}

	public function testDeMorganStringNullGuard(): Void {
		Assert.isTrue(fx(cond('s != "" && s != null')).indexOf('if (s == "" || s == null) continue;') != -1);
	}

	public function testNullCoalesceWrappedWithParens(): Void {
		// `??` binds tighter than `?:` — the wrap MUST parenthesise, `!(a ?? b)` not `!a ?? b`.
		Assert.isTrue(fx(cond('a ?? b')).indexOf('if (!(a ?? b)) continue;') != -1);
	}

	public function testAtomicCallNoParens(): Void {
		Assert.isTrue(fx(cond('ready()')).indexOf('if (!ready()) continue;') != -1);
	}

	public function testAtomicFieldNoParens(): Void {
		Assert.isTrue(fx(cond('obj.flag')).indexOf('if (!obj.flag) continue;') != -1);
	}

	public function testDeMorganIsOperatorWrapped(): Void {
		// `is` binds looser than unary `!`, so a bare `!x is T` parses as `(!x) is T` — must wrap.
		Assert.isTrue(fx(cond('x is String')).indexOf('if (!(x is String)) continue;') != -1);
	}

	public function testDeMorganIsOperatorAsCompoundOperand(): Void {
		Assert.isTrue(fx(cond('ok && x is String')).indexOf('if (!ok || !(x is String)) continue;') != -1);
	}

	// --- the stranded-narrowing gate on the De Morgan path -------------------------

	public function testSafeNullChainKeepsDeMorgan(): Void {
		// No operand consumes a narrowing from a non-first operand, so De Morgan stands.
		Assert.isTrue(fx(cond('a != null && b != null && c != null')).indexOf('if (a == null || b == null || c == null) continue;') != -1);
	}

	public function testStrandedNarrowingRegroupsDeMorgan(): Void {
		// `b`'s fact would not survive a FLAT `||` chain (Haxe carries only the first
		// operand's narrowing that far), so the negation right-nests the tail: inside
		// the group `b == null` is first again and its fact reaches `p`.
		Assert.isTrue(
			fx(cond('a != null && b != null && p(a.length, b.length)'))
				.indexOf('if (a == null || (b == null || !p(a.length, b.length))) continue;') != -1
		);
	}

	public function testStrandedNarrowingFirstOperandStillDeMorgans(): Void {
		// The FIRST operand's fact does survive the `||` chain, so this one is safe.
		Assert.isTrue(fx(cond('a != null && q() && p(a.length, 0)')).indexOf('if (a == null || !q() || !p(a.length, 0)) continue;') != -1);
	}

	public function testParenNestedStrandedNarrowingRegroupsDeMorgan(): Void {
		// The negation DROPS the parens, so the flattened chain is the same three
		// operands as the unparenthesised shape — and regroups at the same seam.
		Assert.isTrue(
			fx(cond('a != null && (b != null && p(a.length, b.length))'))
				.indexOf('if (a == null || (b == null || !p(a.length, b.length))) continue;') != -1
		);
	}

	public function testTwoStrandedNarrowingsNestTwoGroups(): Void {
		// Each stranded null test opens its own group: within a group its null check is
		// first again, and the later `t` pair strands within THAT group, nesting once more.
		Assert.isTrue(
			fx(cond('ok && s != null && s.ready && t != null && t.live'))
				.indexOf('if (!ok || (s == null || !s.ready || (t == null || !t.live))) continue;') != -1
		);
	}

	public function testSharedIdentWithoutNullTestStaysFlat(): Void {
		// Only a null TEST sources a narrowing fact; mere ident sharing between later
		// operands opens no group — the flat chain compiles and reads cleaner.
		Assert.isTrue(fx(cond('a != null && b == c && p(b, a)')).indexOf('if (a == null || b != c || !p(b, a)) continue;') != -1);
	}

	// --- negatives: never flagged --------------------------------------------------

	public function testCodeAfterIfNotFlagged(): Void {
		Assert.equals(0, v('for (x in xs) {\n\t\t\tpre();\n\t\t\tif (cond) {\n\t\t\t\tbody();\n\t\t\t}\n\t\t\ttail();\n\t\t}').length);
	}

	public function testElseBranchNotFlagged(): Void {
		Assert.equals(
			0,
			v('for (x in xs) {\n\t\t\tpre();\n\t\t\tif (cond) {\n\t\t\t\tbody();\n\t\t\t} else {\n\t\t\t\tother();\n\t\t\t}\n\t\t}').length
		);
	}

	public function testSoleIfNotFlagged(): Void {
		// The combine form `for (…) if (cond) …` — left to loop-guard, not our concern.
		Assert.equals(0, v('for (x in xs) {\n\t\t\tif (cond) {\n\t\t\t\tbody();\n\t\t\t}\n\t\t}').length);
	}

	public function testEmptyBodyNotFlagged(): Void {
		Assert.equals(0, v('for (x in xs) {\n\t\t\tpre();\n\t\t\tif (cond) {}\n\t\t}').length);
	}

	public function testUnbracedThenNotFlagged(): Void {
		Assert.equals(0, v('for (x in xs) {\n\t\t\tpre();\n\t\t\tif (cond) body();\n\t\t}').length);
	}

	public function testBodyReturnFlagged(): Void {
		// A `return` in the then-branch is flow-equivalent after the de-nest: the body
		// still runs under the same condition, inside the same function.
		Assert.equals(1, v('for (x in xs) {\n\t\t\tpre();\n\t\t\tif (cond) {\n\t\t\t\treturn;\n\t\t\t}\n\t\t}').length);
	}

	public function testBodyBreakFlagged(): Void {
		// A `break` in the then-branch still targets this same loop after the de-nest.
		Assert.equals(1, v('for (x in xs) {\n\t\t\tpre();\n\t\t\tif (cond) {\n\t\t\t\tbreak;\n\t\t\t}\n\t\t}').length);
	}

	public function testBodyContinueFlagged(): Void {
		// A `continue` in the then-branch still targets this same loop after the de-nest.
		Assert.equals(1, v('for (x in xs) {\n\t\t\tpre();\n\t\t\tif (cond) {\n\t\t\t\tcontinue;\n\t\t\t}\n\t\t}').length);
	}

	public function testNestedLoopBreakFlaggedAndFixed(): Void {
		// A `break` inside a nested loop targets the nested loop; the de-nest keeps the
		// then-branch inside the same outer loop, so the jump target is unchanged.
		Assert.equals(
			1,
			v(
				'for (x in xs) {\n\t\t\tpre();\n\t\t\tif (cond) {\n\t\t\t\tfor (y in ys) {\n\t\t\t\t\tif (y == 0) break;\n\t\t\t\t}\n'
				+ '\t\t\t}\n\t\t}'
			).length
		);
		Assert.equals(
			wrap(
				'for (x in xs) {\n\t\t\tpre();\n\t\t\tif (!cond) continue;\n\t\t\tfor (y in ys) {\n\t\t\t\tif (y == 0) break;\n\t\t\t}\n'
				+ '\t\t}'
			),
			fx(
				'for (x in xs) {\n\t\t\tpre();\n\t\t\tif (cond) {\n\t\t\t\tfor (y in ys) {\n\t\t\t\t\tif (y == 0) break;\n\t\t\t\t}\n'
				+ '\t\t\t}\n\t\t}'
			)
		);
	}

	public function testBodyMidReturnFlaggedAndFixed(): Void {
		// A multi-statement then-branch with an interior return de-nests intact —
		// the real-code shape the retired flow gate used to refuse.
		Assert.equals(
			wrap('for (x in xs) {\n\t\t\tpre();\n\t\t\tif (a == null) continue;\n\t\t\tif (bad(a)) return;\n\t\t\tuse(a);\n\t\t}'),
			fx('for (x in xs) {\n\t\t\tpre();\n\t\t\tif (a != null) {\n\t\t\t\tif (bad(a)) return;\n\t\t\t\tuse(a);\n\t\t\t}\n\t\t}')
		);
	}

	public function testTailAssignHoistedAndFixed(): Void {
		// An independent literal assignment after the trailing if hoists above the
		// guard, making the if effectively trailing.
		final vs: Array<Violation> = v(
			'for (x in xs) {\n\t\t\tpre();\n\t\t\tif (a != null) {\n\t\t\t\tbody(a);\n\t\t\t}\n\t\t\tdone = true;\n\t\t}'
		);
		Assert.equals(1, vs.length);
		Assert.equals(
			wrap('for (x in xs) {\n\t\t\tpre();\n\t\t\tdone = true;\n\t\t\tif (a == null) continue;\n\t\t\tbody(a);\n\t\t}'),
			fx('for (x in xs) {\n\t\t\tpre();\n\t\t\tif (a != null) {\n\t\t\t\tbody(a);\n\t\t\t}\n\t\t\tdone = true;\n\t\t}')
		);
	}

	public function testTailMultipleAssignsHoistedInOrder(): Void {
		Assert.equals(
			wrap(
				'for (x in xs) {\n\t\t\tpre();\n\t\t\tdone = true;\n\t\t\tcount = 0;\n\t\t\tif (a == null) continue;\n\t\t\tbody(a);\n\t\t}'
			),
			fx(
				'for (x in xs) {\n\t\t\tpre();\n\t\t\tif (a != null) {\n\t\t\t\tbody(a);\n\t\t\t}\n\t\t\tdone = true;\n\t\t\tcount = 0;\n'
				+ '\t\t}'
			)
		);
	}

	public function testTailAssignBodyInnerBreakFlagged(): Void {
		// The real-code shape: a nested-loop break in the body does NOT escape the
		// iteration, so the tail assignment still hoists.
		Assert.equals(
			1,
			v(
				'for (x in xs) {\n\t\t\tpre();\n\t\t\tif (cond) {\n\t\t\t\twhile (go()) {\n\t\t\t\t\tif (x == 0) break;\n\t\t\t\t}\n'
				+ '\t\t\t}\n\t\t\tdone = true;\n\t\t}'
			).length
		);
	}

	public function testTailAssignVarReferencedInIfNotFlagged(): Void {
		// The body writes `done` — hoisting `done = true` above it would invert the
		// final value; refused.
		Assert.equals(
			0,
			v(
				'for (x in xs) {\n\t\t\tpre();\n\t\t\tif (cond) {\n\t\t\t\tdone = false;\n\t\t\t\tbody();\n\t\t\t}\n\t\t\tdone = true;\n'
				+ '\t\t}'
			).length
		);
	}

	public function testTailAssignBodyReturnNotFlagged(): Void {
		// A return in the body skips the tail assignment on that path; hoisting
		// would run it early — refused (contrast testBodyReturnFlagged: no tail).
		Assert.equals(
			0,
			v('for (x in xs) {\n\t\t\tpre();\n\t\t\tif (cond) {\n\t\t\t\tbody();\n\t\t\t\treturn;\n\t\t\t}\n\t\t\tdone = true;\n\t\t}')
				.length
		);
	}

	public function testTailAssignBodyOuterContinueNotFlagged(): Void {
		// A continue targeting THIS loop skips the tail on that path — refused.
		Assert.equals(
			0,
			v('for (x in xs) {\n\t\t\tpre();\n\t\t\tif (cond) {\n\t\t\t\tbody();\n\t\t\t\tcontinue;\n\t\t\t}\n\t\t\tdone = true;\n\t\t}')
				.length
		);
	}

	public function testTailCallNotFlagged(): Void {
		// Only side-effect-free literal assignments hoist; a call in the tail refuses.
		Assert.equals(0, v('for (x in xs) {\n\t\t\tpre();\n\t\t\tif (cond) {\n\t\t\t\tbody();\n\t\t\t}\n\t\t\tlog();\n\t\t}').length);
	}

	public function testBodyThrowFlagged(): Void {
		// A `throw` unconditionally exits regardless of position, so it does NOT block the de-nest.
		Assert.equals(1, v('for (x in xs) {\n\t\t\tpre();\n\t\t\tif (cond) {\n\t\t\t\tthrow "e";\n\t\t\t}\n\t\t}').length);
	}

	public function testNestedFunctionReturnFlagged(): Void {
		// A `return` inside a nested function belongs to that function, not this loop.
		Assert.equals(
			1,
			v(
				'for (x in xs) {\n\t\t\tpre();\n\t\t\tif (cond) {\n\t\t\t\tfinal g = function() { return 1; };\n\t\t\t\tuse(g);\n'
				+ '\t\t\t}\n\t\t}'
			).length
		);
	}

	public function testIfInSwitchNotFlagged(): Void {
		Assert.equals(
			0,
			v(
				'for (x in xs) {\n\t\t\tpre();\n\t\t\tswitch (x) {\n\t\t\t\tcase 0:\n\t\t\t\t\tif (cond) {\n\t\t\t\t\t\tbody();\n'
				+ '\t\t\t\t\t}\n\t\t\t\tdefault:\n\t\t\t}\n\t\t}'
			).length
		);
	}

	public function testIfInTryNotFlagged(): Void {
		Assert.equals(
			0,
			v(
				'for (x in xs) {\n\t\t\tpre();\n\t\t\ttry {\n\t\t\t\tif (cond) {\n\t\t\t\t\tbody();\n\t\t\t\t}\n'
				+ '\t\t\t} catch (e:Dynamic) {}\n\t\t}'
			).length
		);
	}

	public function testNameCollisionPrecedingAutoRenamed(): Void {
		// The colliding de-nested local is mechanically renamed to `b2`, not refused.
		Assert.equals(
			1,
			v('for (x in xs) {\n\t\t\tfinal b = pre();\n\t\t\tif (cond) {\n\t\t\t\tfinal b = other();\n\t\t\t\tuse(b);\n\t\t\t}\n\t\t}')
				.length
		);
		Assert.equals(
			wrap('for (x in xs) {\n\t\t\tfinal b = pre();\n\t\t\tif (!cond) continue;\n\t\t\tfinal b2 = other();\n\t\t\tuse(b2);\n\t\t}'),
			fx('for (x in xs) {\n\t\t\tfinal b = pre();\n\t\t\tif (cond) {\n\t\t\t\tfinal b = other();\n\t\t\t\tuse(b);\n\t\t\t}\n\t\t}')
		);
	}

	public function testNameCollisionIteratorAutoRenamed(): Void {
		Assert.equals(
			1, v('for (b in xs) {\n\t\t\tpre();\n\t\t\tif (cond) {\n\t\t\t\tfinal b = other();\n\t\t\t\tuse(b);\n\t\t\t}\n\t\t}').length
		);
		Assert.equals(
			wrap('for (b in xs) {\n\t\t\tpre();\n\t\t\tif (!cond) continue;\n\t\t\tfinal b2 = other();\n\t\t\tuse(b2);\n\t\t}'),
			fx('for (b in xs) {\n\t\t\tpre();\n\t\t\tif (cond) {\n\t\t\t\tfinal b = other();\n\t\t\t\tuse(b);\n\t\t\t}\n\t\t}')
		);
	}

	public function testCollisionRenameCoversInterpReads(): Void {
		// Every read moves with the declaration — plain identifiers AND `$name` reads
		// inside string interpolation (double-quoted here so the host string is literal).
		Assert.equals(
			wrap(
				"for (x in xs) {\n\t\t\tfinal p = pre();\n\t\t\tif (!cond) continue;\n\t\t\tvar p2 = start();\n\t\t\tp2 = 'a/$p2';\n"
				+ "\t\t\tuse('$p2-x');\n\t\t}"
			),
			fx(
				"for (x in xs) {\n\t\t\tfinal p = pre();\n\t\t\tif (cond) {\n\t\t\t\tvar p = start();\n\t\t\t\tp = 'a/$p';\n"
				+ "\t\t\t\tuse('$p-x');\n\t\t\t}\n\t\t}"
			)
		);
	}

	public function testCollisionDeeperRedeclarationNotFlagged(): Void {
		// A deeper re-declaration of the colliding name makes occurrence attribution
		// unsound — the rename is refused, and with it the de-nest.
		Assert.equals(
			0,
			v(
				'for (x in xs) {\n\t\t\tfinal b = pre();\n\t\t\tif (cond) {\n\t\t\t\tvar b = 1;\n\t\t\t\tif (q) {\n\t\t\t\t\tvar b = 2;\n'
				+ '\t\t\t\t\ttrace(b);\n\t\t\t\t}\n\t\t\t}\n\t\t}'
			).length
		);
	}

	public function testCollisionLambdaMentionNotFlagged(): Void {
		// An inner lambda could own the name (its params are invisible to the scan) — refused.
		Assert.equals(
			0,
			v('for (x in xs) {\n\t\t\tfinal b = pre();\n\t\t\tif (cond) {\n\t\t\t\tvar b = 1;\n\t\t\t\trun(() -> use(b));\n\t\t\t}\n\t\t}')
				.length
		);
	}

	public function testCollisionFreshNameSkipsTaken(): Void {
		// `b2` is already bound in the loop body, so the fresh name walks on to `b3`.
		Assert.equals(
			wrap(
				'for (x in xs) {\n\t\t\tfinal b = pre();\n\t\t\tfinal b2 = spare();\n\t\t\tif (!cond) continue;\n'
				+ '\t\t\tfinal b3 = other();\n\t\t\tuse(b3);\n\t\t}'
			),
			fx(
				'for (x in xs) {\n\t\t\tfinal b = pre();\n\t\t\tfinal b2 = spare();\n\t\t\tif (cond) {\n\t\t\t\tfinal b = other();\n'
				+ '\t\t\t\tuse(b);\n\t\t\t}\n\t\t}'
			)
		);
	}

	public function testCollisionInitializerReadsOuterNotFlagged(): Void {
		// The initializer reads the OUTER binding — not yet shadowed there — so renaming
		// would rebind that read to the fresh local. Refused.
		Assert.equals(
			0,
			v(
				'for (x in xs) {\n\t\t\tfinal path = pre();\n\t\t\tif (cond) {\n\t\t\t\tfinal path = path + "/sub";\n\t\t\t\tuse(path);\n'
				+ '\t\t\t}\n\t\t}'
			).length
		);
	}

	public function testCollisionReadBeforeDeclNotFlagged(): Void {
		// A read AHEAD of the shadowing declaration still resolves to the outer binding.
		Assert.equals(
			0,
			v(
				'for (x in xs) {\n\t\t\tfinal b = pre();\n\t\t\tif (cond) {\n\t\t\t\tuse(b);\n\t\t\t\tfinal b = other();\n'
				+ '\t\t\t\tuse(b);\n\t\t\t}\n\t\t}'
			).length
		);
	}

	public function testCollisionFreshNameSkipsClassField(): Void {
		// `b2` is a class FIELD — invisible to any loop-local scan, and an unqualified read
		// of it would bind silently. The fresh name must walk past it to `b3`.
		final field: String = 'var b2:Int = 99;';
		Assert.equals(
			canon(wrapField(
				field,
				'for (x in xs) {\n\t\t\tfinal b = pre();\n\t\t\tif (!cond) continue;\n\t\t\tfinal b3 = other();\n\t\t\tuse(b3);\n\t\t}'
			)),
			fxSource(wrapField(
				field,
				'for (x in xs) {\n\t\t\tfinal b = pre();\n\t\t\tif (cond) {\n\t\t\t\tfinal b = other();\n\t\t\t\tuse(b);\n\t\t\t}\n\t\t}'
			))
		);
	}

	public function testMetaWrappedDeclCollisionAutoRenamed(): Void {
		// `@:meta var b` parses as an expression-position declaration under a metadata
		// wrapper — the rename reaches its binder token through the wrapper.
		final code: String = 'for (x in xs) {\n\t\t\tfinal b = pre();\n\t\t\tif (cond) {\n'
			+ '\t\t\t\t@:nullSafety(Off) var b:String = other();\n\t\t\t\tuse(b);\n\t\t\t}\n\t\t}';
		Assert.equals(1, v(code).length);
		Assert.equals(
			canon(wrap(
				'for (x in xs) {\n\t\t\tfinal b = pre();\n\t\t\tif (!cond) continue;\n\t\t\t@:nullSafety(Off) var b2:String = other();\n'
				+ '\t\t\tuse(b2);\n\t\t}'
			)),
			fx(code)
		);
	}

	public function testMetaWrappedSiblingCollisionAutoRenamed(): Void {
		// The preceding-sibling scan reaches through the metadata wrapper too.
		final code: String = 'for (x in xs) {\n\t\t\t@:nullSafety(Off) var b:String = pre();\n\t\t\tif (cond) {\n'
			+ '\t\t\t\tfinal b = other();\n\t\t\t\tuse(b);\n\t\t\t}\n\t\t}';
		Assert.equals(1, v(code).length);
		Assert.equals(
			canon(wrap(
				'for (x in xs) {\n\t\t\t@:nullSafety(Off) var b:String = pre();\n\t\t\tif (!cond) continue;\n\t\t\tfinal b2 = other();\n'
				+ '\t\t\tuse(b2);\n\t\t}'
			)),
			fx(code)
		);
	}

	public function testNoCollisionFlagged(): Void {
		Assert.equals(
			1,
			v('for (x in xs) {\n\t\t\tfinal c = pre();\n\t\t\tif (cond) {\n\t\t\t\tfinal b = other();\n\t\t\t\tuse(b, c);\n\t\t\t}\n\t\t}')
				.length
		);
	}

	// --- comments ------------------------------------------------------------------

	public function testBodyCommentPreserved(): Void {
		Assert.equals(
			wrap('for (x in xs) {\n\t\t\tpre();\n\t\t\tif (!cond) continue;\n\t\t\t// explain\n\t\t\tbody();\n\t\t}'),
			fx('for (x in xs) {\n\t\t\tpre();\n\t\t\tif (cond) {\n\t\t\t\t// explain\n\t\t\t\tbody();\n\t\t\t}\n\t\t}')
		);
	}

	public function testConditionCommentPreservedInEdit(): Void {
		// A comment INSIDE the condition span rides along verbatim in the negation.
		final es: Array<{ span: Span, text: String }> = edits(
			wrap('for (x in xs) {\n\t\t\tpre();\n\t\t\tif (a /* keep */ && b) {\n\t\t\t\tbody();\n\t\t\t}\n\t\t}')
		);
		Assert.equals(1, es.length);
		Assert.isTrue(es[0].text.indexOf('/* keep */') != -1);
	}

	public function testGlueCommentNotFlagged(): Void {
		// A comment in the dropped `) {` glue would be lost — refused.
		Assert.equals(0, v('for (x in xs) {\n\t\t\tpre();\n\t\t\tif (cond) /* x */ {\n\t\t\t\tbody();\n\t\t\t}\n\t\t}').length);
	}

	// --- idempotence + robustness --------------------------------------------------

	public function testIdempotent(): Void {
		final fixed: String = fx('for (x in xs) {\n\t\t\tpre();\n\t\t\tif (a != null) {\n\t\t\t\tbody(a);\n\t\t\t}\n\t\t}');
		Assert.equals(fixed, applyFixOnce(fixed));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0,
			new GuardContinue().run(
				[{ file: 'C.hx', source: 'class Bad { function f() { for (x in xs) { if (a) {' }], new HaxeQueryPlugin()
			)
				.length
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('guard-continue'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('guard-continue'));
		Assert.equals(178, Linter.builtins().length);
	}

	/**
	 * The DISAGREEMENT pin, asserted from both sides in one test: a loop body that opens with a
	 * guard `loop-guard` lifts is reported by `loop-guard` and by NOBODY else. Before the shared
	 * claim both rules reported this body and told the reader opposite things, and which one won
	 * a `--fix` was decided by argument order (`--rule loop-guard --rule guard-continue` lifted
	 * the header; the two flags swapped produced the `continue` cascade — same input, same engine).
	 */
	public function testDefersALoopBodyLoopGuardWouldLift(): Void {
		final source: String = wrap(
			'for (x in xs) {\n\t\t\tif (a != null) continue;\n\t\t\tpre();\n\t\t\tif (b != null) {\n\t\t\t\tbody(b);\n\t\t\t}\n\t\t}'
		);
		Assert.equals(0, new GuardContinue().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin()).length);
		Assert.equals(1, new LoopGuard().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin()).length);
	}

	/**
	 * The other half of the same claim: a CASCADE of leading guards is one `loop-guard` refuses by
	 * its own rule (the user keeps sequential `continue` guards), so the trailing `if` stays THIS
	 * check's. Deferring on the leading guard's SHAPE alone would silence both rules here.
	 */
	public function testKeepsALeadingGuardCascadeLoopGuardRefuses(): Void {
		final source: String = wrap(
			'for (x in xs) {\n\t\t\tif (a != null) continue;\n\t\t\tif (c != null) continue;\n\t\t\tif (b != null) {\n\t\t\t\tbody(b);\n'
			+ '\t\t\t}\n\t\t}'
		);
		Assert.equals(1, new GuardContinue().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin()).length);
		Assert.equals(0, new LoopGuard().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin()).length);
	}

	/**
	 * A leading guard whose ORDERED comparison the inversion refuses to flip (an unresolvable
	 * operand type leaves `<` NaN-unsafe): `loop-guard` declines the lift, so this check must keep
	 * its finding. Shape-only deferral dropped 14 such sites across 13251 external files with
	 * nothing reporting them, which is what made the deferral ask for `loop-guard`'s whole claim.
	 */
	public function testKeepsASiteWhoseLeadingGuardInvertsUncleanly(): Void {
		final source: String = wrap(
			'for (x in xs) {\n\t\t\tif (x.lo < x.hi) continue;\n\t\t\tpre();\n\t\t\tif (b != null) {\n\t\t\t\tbody(b);\n\t\t\t}\n\t\t}'
		);
		Assert.equals(1, new GuardContinue().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin()).length);
		Assert.equals(0, new LoopGuard().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin()).length);
	}

	/**
	 * An UNSHIELDED loop — one whose trailing `else` would rebind to the header `loop-guard` emits,
	 * so its LIFT arm refuses on POSITION. This check keeps the site, and reads that position
	 * through the same `IfExpressionChain.childShielded` flag rather than a rule of its own.
	 */
	public function testKeepsASiteInAnUnshieldedPosition(): Void {
		final source: String = wrap(
			'if (p) for (x in xs) {\n\t\t\tif (a != null) continue;\n\t\t\tpre();\n\t\t\tif (b != null) {\n\t\t\t\tbody(b);\n\t\t\t}\n'
			+ '\t\t} else other();'
		);
		Assert.equals(1, new GuardContinue().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin()).length);
		Assert.equals(0, new LoopGuard().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin()).length);
	}

	/**
	 * A `do … while` whose body opens with a guard `loop-guard` WOULD lift if it visited do-while
	 * loops — which it does not: it reads `loopStatementKinds` only, while this check also reads
	 * `doWhileLoopKinds`. The first draft of the deferral asked a body-level predicate that cannot
	 * see the loop kind, and the site went unreported by BOTH rules. The identical `for` body is the
	 * discriminator beside it: there the deferral is right.
	 */
	public function testKeepsADoWhileLoopGuardNeverVisits(): Void {
		final body: String = '{\n\t\t\tif (a != null) continue;\n\t\t\tpre();\n\t\t\tif (b != null) {\n\t\t\t\tbody(b);\n\t\t\t}\n\t\t}';
		final doWhile: String = wrap('do $body while (ok);');
		Assert.equals(1, new GuardContinue().run([{ file: 'C.hx', source: doWhile }], new HaxeQueryPlugin()).length);
		Assert.equals(0, new LoopGuard().run([{ file: 'C.hx', source: doWhile }], new HaxeQueryPlugin()).length);
		final forLoop: String = wrap('for (x in xs) $body');
		Assert.equals(0, new GuardContinue().run([{ file: 'C.hx', source: forLoop }], new HaxeQueryPlugin()).length);
		Assert.equals(1, new LoopGuard().run([{ file: 'C.hx', source: forLoop }], new HaxeQueryPlugin()).length);
	}

	// --- helpers -------------------------------------------------------------------

	private function wrap(loopCode: String): String {
		return 'class C {\n\tfunction f(xs:Array<Int>):Void {\n\t\t$loopCode\n\t}\n}\n';
	}

	/** `wrap` with a class field ahead of the method — a scope no loop-local fresh-name scan can see. */
	private function wrapField(fieldCode: String, loopCode: String): String {
		return 'class C {\n\t$fieldCode\n\n\tfunction f(xs:Array<Int>):Void {\n\t\t$loopCode\n\t}\n}\n';
	}

	private function cond(c: String): String {
		return 'for (x in xs) {\n\t\t\tpre();\n\t\t\tif ($c) {\n\t\t\t\tbody();\n\t\t\t}\n\t\t}';
	}

	private function v(loopCode: String): Array<Violation> {
		return new GuardContinue().run([{ file: 'C.hx', source: wrap(loopCode) }], new HaxeQueryPlugin());
	}

	private function edits(source: String): Array<{ span: Span, text: String }> {
		final check: GuardContinue = new GuardContinue();
		return check.fix(source, check.run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

	/** Canonicalise the loop code then de-nest to a fixpoint, exactly as the `lint --fix` CLI does. */
	private function fx(loopCode: String): String {
		return fxSource(wrap(loopCode));
	}

	/** `fx` over a whole class source — for fixtures `wrap` cannot carry, such as a class field. */
	private function fxSource(source: String): String {
		var cur: String = canon(source);
		while (true) {
			final next: String = applyFixOnce(cur);
			if (next == cur) return cur;
			cur = next;
		}
	}

	private function applyFixOnce(source: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: GuardContinue = new GuardContinue();
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
