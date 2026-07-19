package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.GuardContinue;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.query.RefactorSupport.EditResult;
import anyparse.runtime.Span;

/**
 * The `guard-continue` check: a loop (`for` / `while` / `do … while`) whose braced
 * body's LAST statement is a bare `if (cond) { … }` (no `else`) preceded by ≥1 other
 * statement is flagged `Info` and de-nested to an `if (!cond) continue;` guard. The
 * inversion pushes De Morgan inward through the shared `CheckScan.negateConditionText`
 * (backed by the grammar's `BooleanLogicSupport`): `a && b` → `!a || !b`, `==` / `!=`
 * flipped, but an ordered comparison (`< <= > >=`) kept wrapped `!(…)` (NaN-safe — `!(a <
 * b)` and `a >= b` differ under NaN), and a comment inside the condition falls back to the
 * verbatim `!(cond)` wrap. Guarded by a flow gate (no `break`/`continue`/`return` in the
 * body), a name-collision gate (a de-nested local must not clash with a preceding sibling /
 * the iterator), a glue-comment gate, and the sole-`if` / else / empty / unbraced /
 * non-tail exclusions. Runs to a fixpoint, so a two-level chain flattens over successive
 * passes.
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
				'for (id in xs) {\n\t\t\tfinal a = load(id);\n\t\t\tif (a != null) {\n\t\t\t\tfinal b = find(a);\n\t\t\t\tif (b != null) {\n\t\t\t\t\tuse(b);\n\t\t\t\t}\n\t\t\t}\n\t\t}'
			).length
		);
		Assert.equals(
			wrap(
				'for (id in xs) {\n\t\t\tfinal a = load(id);\n\t\t\tif (a == null) continue;\n\t\t\tfinal b = find(a);\n\t\t\tif (b == null) continue;\n\t\t\tuse(b);\n\t\t}'
			),
			fx(
				'for (id in xs) {\n\t\t\tfinal a = load(id);\n\t\t\tif (a != null) {\n\t\t\t\tfinal b = find(a);\n\t\t\t\tif (b != null) {\n\t\t\t\t\tuse(b);\n\t\t\t\t}\n\t\t\t}\n\t\t}'
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
			v('for (x in xs) {\n\t\t\tfor (y in ys) {\n\t\t\t\tmid();\n\t\t\t\tif (cond) {\n\t\t\t\t\tbody();\n\t\t\t\t}\n\t\t\t}\n\t\t}').length
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

	public function testLessThanWrappedNotFlipped(): Void {
		Assert.isTrue(fx(cond('x < 10')).indexOf('if (!(x < 10)) continue;') != -1);
	}

	public function testLessEqWrappedNotFlipped(): Void {
		Assert.isTrue(fx(cond('x <= 10')).indexOf('if (!(x <= 10)) continue;') != -1);
	}

	public function testGreaterThanWrappedNotFlipped(): Void {
		Assert.isTrue(fx(cond('x > 10')).indexOf('if (!(x > 10)) continue;') != -1);
	}

	public function testGreaterEqWrappedNotFlipped(): Void {
		Assert.isTrue(fx(cond('x >= 10')).indexOf('if (!(x >= 10)) continue;') != -1);
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

	public function testDeMorganKeepsOrderedWrapped(): Void {
		Assert.isTrue(fx(cond('x < 10 && ok')).indexOf('if (!(x < 10) || !ok) continue;') != -1);
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

	public function testBodyReturnNotFlagged(): Void {
		Assert.equals(0, v('for (x in xs) {\n\t\t\tpre();\n\t\t\tif (cond) {\n\t\t\t\treturn;\n\t\t\t}\n\t\t}').length);
	}

	public function testBodyBreakNotFlagged(): Void {
		Assert.equals(0, v('for (x in xs) {\n\t\t\tpre();\n\t\t\tif (cond) {\n\t\t\t\tbreak;\n\t\t\t}\n\t\t}').length);
	}

	public function testBodyContinueNotFlagged(): Void {
		Assert.equals(0, v('for (x in xs) {\n\t\t\tpre();\n\t\t\tif (cond) {\n\t\t\t\tcontinue;\n\t\t\t}\n\t\t}').length);
	}

	public function testNestedLoopBreakConservativelySkipped(): Void {
		// A `break` inside a nested loop targets the nested loop and is safe, but the flow
		// gate over-skips it (documented conservative limitation).
		Assert.equals(
			0,
			v(
				'for (x in xs) {\n\t\t\tpre();\n\t\t\tif (cond) {\n\t\t\t\tfor (y in ys) {\n\t\t\t\t\tif (y == 0) break;\n\t\t\t\t}\n\t\t\t}\n\t\t}'
			).length
		);
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
				'for (x in xs) {\n\t\t\tpre();\n\t\t\tif (cond) {\n\t\t\t\tfinal g = function() { return 1; };\n\t\t\t\tuse(g);\n\t\t\t}\n\t\t}'
			).length
		);
	}

	public function testIfInSwitchNotFlagged(): Void {
		Assert.equals(
			0,
			v(
				'for (x in xs) {\n\t\t\tpre();\n\t\t\tswitch (x) {\n\t\t\t\tcase 0:\n\t\t\t\t\tif (cond) {\n\t\t\t\t\t\tbody();\n\t\t\t\t\t}\n\t\t\t\tdefault:\n\t\t\t}\n\t\t}'
			).length
		);
	}

	public function testIfInTryNotFlagged(): Void {
		Assert.equals(
			0,
			v(
				'for (x in xs) {\n\t\t\tpre();\n\t\t\ttry {\n\t\t\t\tif (cond) {\n\t\t\t\t\tbody();\n\t\t\t\t}\n\t\t\t} catch (e:Dynamic) {}\n\t\t}'
			).length
		);
	}

	public function testNameCollisionPrecedingNotFlagged(): Void {
		Assert.equals(
			0,
			v('for (x in xs) {\n\t\t\tfinal b = pre();\n\t\t\tif (cond) {\n\t\t\t\tfinal b = other();\n\t\t\t\tuse(b);\n\t\t\t}\n\t\t}').length
		);
	}

	public function testNameCollisionIteratorNotFlagged(): Void {
		Assert.equals(
			0, v('for (b in xs) {\n\t\t\tpre();\n\t\t\tif (cond) {\n\t\t\t\tfinal b = other();\n\t\t\t\tuse(b);\n\t\t\t}\n\t\t}').length
		);
	}

	public function testNoCollisionFlagged(): Void {
		Assert.equals(
			1,
			v('for (x in xs) {\n\t\t\tfinal c = pre();\n\t\t\tif (cond) {\n\t\t\t\tfinal b = other();\n\t\t\t\tuse(b, c);\n\t\t\t}\n\t\t}').length
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
		Assert.equals(95, Linter.builtins().length);
	}

	// --- helpers -------------------------------------------------------------------

	private function wrap(loopCode: String): String {
		return 'class C {\n\tfunction f(xs:Array<Int>):Void {\n\t\t' + loopCode + '\n\t}\n}\n';
	}

	private function cond(c: String): String {
		return 'for (x in xs) {\n\t\t\tpre();\n\t\t\tif (' + c + ') {\n\t\t\t\tbody();\n\t\t\t}\n\t\t}';
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
		var cur: String = canon(wrap(loopCode));
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
