package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferSafeNavComparison;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `prefer-safe-nav-comparison` check: a null-check conjunction
 * `x != null && x.b != null` (and its `||` / `==` dual) is flagged `Info` and
 * rewritten to the safe-navigation comparison `x?.b != null`. Runs of three
 * (`x != null && x.b != null && x.b.c != null` -> `x?.b?.c != null`), the
 * multi-access extension (`x != null && x.b.c != null` -> `x?.b.c != null`),
 * FIELD / `this.`-qualified receivers, a call in the LAST conjunct's tail and
 * two disjoint runs in one chain are all flagged; a run the gates reject leaves
 * a shorter sub-run starting one conjunct later still flaggable. An intermediate
 * operand carrying a call or a `new` (its evaluation count would change),
 * different receivers, mixed operators, an index / already-safe-nav junction, a
 * comment between conjuncts and any mention of the first operand AFTER the run
 * are safe misses — the last group because such a mention would have relied on
 * the conjunction's null-safety narrowing, and it is caught across both
 * `this.`-qualification styles and past ANY depth of plain block nesting (one,
 * two or three braces, and a block expression) that the run sits inside, while a
 * lambda still bounds the scan so a run in its body fires. A comment sitting
 * between a receiver and its junction dot blocks only the FIX.
 */
class PreferSafeNavComparisonCheckTest extends Test {

	public function testAndPairFlagged(): Void {
		final vs: Array<Violation> = violations(local('final ok:Bool = x != null && x.b != null;'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-safe-nav-comparison', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this null-check chain can be safe navigation (?.)', vs[0].message);
	}

	public function testAndPairFixed(): Void {
		Assert.equals(local('final ok:Bool = x?.b != null;'), applyFix(local('final ok:Bool = x != null && x.b != null;')));
	}

	public function testReversedNullOperandFixed(): Void {
		Assert.equals(1, violations(local('final ok:Bool = null != x && x.b != null;')).length);
		Assert.equals(local('final ok:Bool = x?.b != null;'), applyFix(local('final ok:Bool = null != x && x.b != null;')));
	}

	public function testOrDualFixed(): Void {
		Assert.equals(1, violations(local('final ok:Bool = x == null || x.b == null;')).length);
		Assert.equals(local('final ok:Bool = x?.b == null;'), applyFix(local('final ok:Bool = x == null || x.b == null;')));
	}

	public function testFieldReceiverTernaryCondFixed(): Void {
		final input: String =
			'class C {\n\tvar fld:Sys;\n\tfunction f():Void {\n\t\tfinal h:Float = fld != null && fld.sub != null ? 1 : 0;\n\t}\n}';
		final expected: String = 'class C {\n\tvar fld:Sys;\n\tfunction f():Void {\n\t\tfinal h:Float = fld?.sub != null ? 1 : 0;\n\t}\n}';
		Assert.equals(1, violations(input).length);
		Assert.equals(expected, applyFix(input));
	}

	public function testThisQualifiedReceiverFixed(): Void {
		final input: String =
			'class C {\n\tvar fld:Sys;\n\tfunction f():Void {\n\t\tfinal ok:Bool = this.fld != null && this.fld.b != null;\n\t}\n}';
		final expected: String = 'class C {\n\tvar fld:Sys;\n\tfunction f():Void {\n\t\tfinal ok:Bool = this.fld?.b != null;\n\t}\n}';
		Assert.equals(1, violations(input).length);
		Assert.equals(expected, applyFix(input));
	}

	public function testThreeRunFixed(): Void {
		Assert.equals(1, violations(local('final ok:Bool = x != null && x.b != null && x.b.c != null;')).length);
		Assert.equals(
			local('final ok:Bool = x?.b?.c != null;'), applyFix(local('final ok:Bool = x != null && x.b != null && x.b.c != null;'))
		);
	}

	public function testMultiAccessExtensionFixed(): Void {
		Assert.equals(1, violations(local('final ok:Bool = x != null && x.b.c != null;')).length);
		Assert.equals(local('final ok:Bool = x?.b.c != null;'), applyFix(local('final ok:Bool = x != null && x.b.c != null;')));
	}

	public function testPrefixContextKept(): Void {
		Assert.equals(1, violations(local('final ok2:Bool = ok && x != null && x.b != null;')).length);
		Assert.equals(local('final ok2:Bool = ok && x?.b != null;'), applyFix(local('final ok2:Bool = ok && x != null && x.b != null;')));
	}

	public function testSuffixContextKept(): Void {
		Assert.equals(1, violations(local('final ok2:Bool = x != null && x.b != null && ok;')).length);
		Assert.equals(local('final ok2:Bool = x?.b != null && ok;'), applyFix(local('final ok2:Bool = x != null && x.b != null && ok;')));
	}

	public function testCallTailAllowed(): Void {
		Assert.equals(1, violations(local('final ok:Bool = x != null && x.b() != null;')).length);
		Assert.equals(local('final ok:Bool = x?.b() != null;'), applyFix(local('final ok:Bool = x != null && x.b() != null;')));
	}

	public function testCallInIntermediateOperandNotFlagged(): Void {
		Assert.equals(0, violations(local('final ok:Bool = x.b() != null && x.b().c != null;')).length);
	}

	public function testDifferentReceiversNotFlagged(): Void {
		Assert.equals(0, violations(local('final ok:Bool = x != null && y.b != null;')).length);
	}

	public function testMixedOperatorsNotFlagged(): Void {
		Assert.equals(0, violations(local('final ok:Bool = x != null && x.b == null;')).length);
		Assert.equals(0, violations(local('final ok:Bool = x == null || x.b != null;')).length);
	}

	public function testMentionAfterRunNotFlagged(): Void {
		Assert.equals(0, violations(local('final ok:Bool = x != null && x.b != null && f(x);')).length);
	}

	public function testMentionInIfBodyNotFlagged(): Void {
		Assert.equals(0, violations(local('if (x != null && x.b != null) x.b.c();')).length);
	}

	public function testGuardReturnIdiomNotFlagged(): Void {
		Assert.equals(0, violations(local('if (x == null || x.b == null) return;\n\t\tx.b.c();')).length);
	}

	public function testLambdaScopeFires(): Void {
		Assert.equals(1, violations(local('xs.filter(e -> e != null && e.b != null);')).length);
		Assert.equals(local('xs.filter(e -> e?.b != null);'), applyFix(local('xs.filter(e -> e != null && e.b != null);')));
	}

	public function testIndexJunctionNotFlagged(): Void {
		Assert.equals(0, violations(local('final ok:Bool = x != null && x[0] != null;')).length);
	}

	public function testAlreadySafeNavNotFlagged(): Void {
		Assert.equals(0, violations(local('final ok:Bool = x != null && x?.b != null;')).length);
	}

	public function testCommentBetweenConjunctsNotFlagged(): Void {
		Assert.equals(0, violations(local('final ok:Bool = x != null /* c */ && x.b != null;')).length);
	}

	public function testCommentInsideLastConjunctPreserved(): Void {
		Assert.equals(1, violations(local('final ok:Bool = x != null && x.b /* keep */ != null;')).length);
		Assert.equals(
			local('final ok:Bool = x?.b /* keep */ != null;'), applyFix(local('final ok:Bool = x != null && x.b /* keep */ != null;'))
		);
	}

	public function testTwoDisjointRunsBothFixed(): Void {
		final input: String = 'class C {\n\tfunction f():Void {\n\t\tvar a:Sys = mk();\n\t\tvar c:Sys = mk();\n'
			+ '\t\tfinal ok:Bool = a != null && a.b != null && c != null && c.d != null;\n\t}\n}';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tvar a:Sys = mk();\n\t\tvar c:Sys = mk();\n'
			+ '\t\tfinal ok:Bool = a?.b != null && c?.d != null;\n\t}\n}';
		Assert.equals(2, violations(input).length);
		Assert.equals(expected, applyFix(input));
	}

	public function testMentionInWhileBodyNotFlagged(): Void {
		Assert.equals(0, violations(local('while (x != null && x.next != null) x = x.next;')).length);
	}

	public function testSelfQualifiedRunBareMentionNotFlagged(): Void {
		final source: String = 'class C {\n\tvar fld:Sys;\n\tfunction f():Void {\n'
			+ '\t\tif (this.fld == null || this.fld.b == null) return;\n\t\tfld.b.c();\n\t}\n}';
		Assert.equals(0, violations(source).length);
	}

	public function testBareRunSelfQualifiedMentionNotFlagged(): Void {
		final source: String = 'class C {\n\tvar fld:Sys;\n\tfunction f():Void {\n'
			+ '\t\tif (fld == null || fld.b == null) return;\n\t\tthis.fld.b.c();\n\t}\n}';
		Assert.equals(0, violations(source).length);
	}

	public function testNestedBlockGuardReturnNotFlagged(): Void {
		Assert.equals(0, violations(local('{\n\t\t\tif (x == null || x.b == null) return;\n\t\t}\n\t\tx.b.c();')).length);
	}

	public function testNestedBlockWithoutLaterMentionFires(): Void {
		Assert.equals(1, violations(local('{\n\t\t\tif (x == null || x.b == null) return;\n\t\t}\n\t\ttrace(1);')).length);
	}

	public function testTwoNestedBlocksGuardReturnNotFlagged(): Void {
		final stmt: String = '{\n\t\t\t{\n\t\t\t\tif (x == null || x.b == null) return;\n\t\t\t}\n\t\t}\n\t\tx.b.c();';
		Assert.equals(0, violations(local(stmt)).length);
	}

	public function testThreeNestedBlocksGuardReturnNotFlagged(): Void {
		final stmt: String =
			'{\n\t\t\t{\n\t\t\t\t{\n\t\t\t\t\tif (x == null || x.b == null) return;\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\t\tx.b.c();';
		Assert.equals(0, violations(local(stmt)).length);
	}

	public function testBlockExprGuardReturnNotFlagged(): Void {
		final stmt: String = 'final v:Int = {\n\t\t\tif (x == null || x.b == null) return;\n\t\t\t1;\n\t\t};\n\t\tx.b.c();';
		Assert.equals(0, violations(local(stmt)).length);
	}

	public function testNewExprOperandNotFlagged(): Void {
		Assert.equals(0, violations(local('final ok:Bool = new B() != null && new B().b != null;')).length);
	}

	/**
	 * The TM shape that broke the compiler: an `inline` boolean guard whose body splices
	 * into every call site, where the `&&` form narrows the CALLER's binding after
	 * `if (!check(item)) return;`. The rewrite drops that narrowing at each site.
	 */
	public function testInlineMemberFunctionNotFlagged(): Void {
		final source: String = 'class C {\n\tprivate inline function check(item:Null<D>):Bool {\n'
			+ '\t\treturn item != null && item.cloudId != null;\n\t}\n}';
		Assert.equals(0, violations(source).length);
	}

	/** The `inline` keyword is the ONLY difference from `testInlineMemberFunctionNotFlagged`. */
	public function testNonInlineMemberFunctionFlagged(): Void {
		final source: String = 'class C {\n\tprivate function check(item:Null<D>):Bool {\n'
			+ '\t\treturn item != null && item.cloudId != null;\n\t}\n}';
		Assert.equals(1, violations(source).length);
	}

	public function testLocalInlineFunctionNotFlagged(): Void {
		Assert.equals(0, violations(local('inline function h():Bool {\n\t\t\treturn x != null && x.b != null;\n\t\t}')).length);
	}

	/**
	 * A lambda nested in an `inline` function still fires: the lambda is a closure VALUE,
	 * so its body never becomes a narrowing predicate in the inline function's callers —
	 * only the inline body's own statements do, and this run is not one of them.
	 */
	public function testLambdaInsideInlineFunctionFlagged(): Void {
		final source: String = 'class C {\n\tprivate inline function f():Bool {\n'
			+ '\t\treturn xs.exists(e -> e != null && e.b != null);\n\t}\n}';
		Assert.equals(1, violations(source).length);
	}

	/**
	 * The junction dot sits behind a comment, so the `?` would land INSIDE it — the edit
	 * is skipped and the source survives verbatim. The run is still REPORTED: the dropped
	 * region (everything before the last conjunct) is comment-free, so only the fixer bails.
	 */
	public function testCommentBeforeJunctionDotNotFixed(): Void {
		final input: String = local('final ok:Bool = x != null && x /* see B.b */.b != null;');
		Assert.equals(1, violations(input).length);
		Assert.equals(input, applyFix(input));
	}

	/**
	 * The greedy run [0..2] is rejected by the mention gate (`g(x)` reads `x` after it), and
	 * the scan resumes at the NEXT conjunct rather than past the whole rejected run — so the
	 * shorter [1..2] run, whose first operand `x.b` is not mentioned later, still fires.
	 */
	public function testRejectedRunYieldsShorterSubRun(): Void {
		final stmt: String = 'final ok:Bool = x != null && x.b != null && x.b.c != null && g(x);';
		Assert.equals(1, violations(local(stmt)).length);
		Assert.equals(local('final ok:Bool = x != null && x.b?.c != null && g(x);'), applyFix(local(stmt)));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-safe-nav-comparison'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-safe-nav-comparison'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { var ok = x != null &&').length);
	}

	public function testApplyFixByteExact(): Void {
		final input: String =
			'class C {\n\tfunction f():Void {\n\t\tvar x:Sys = mk();\n\t\tfinal ok:Bool = x != null && x.b.c != null;\n\t}\n}';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tvar x:Sys = mk();\n\t\tfinal ok:Bool = x?.b.c != null;\n\t}\n}';
		Assert.equals(expected, applyFix(input));
	}

	/**
	 * A parenthesized FIRST conjunct is unwrapped and fixed, not skipped: the
	 * shape test already reaches through `parenKind`, the parens carry no
	 * information the rewrite needs (`?.` binds tighter than `!=`), and the run
	 * span starts at the `(` so the whole pair is replaced. Skipping would leave
	 * the more common `(a != null) && a.b != null` (a hand-parenthesized guard)
	 * permanently unflagged for no soundness gain.
	 */
	public function testParenthesizedConjunctFixed(): Void {
		Assert.equals(1, violations(local('final ok:Bool = (x != null) && x.b != null;')).length);
		Assert.equals(local('final ok:Bool = x?.b != null;'), applyFix(local('final ok:Bool = (x != null) && x.b != null;')));
	}

	private function local(stmt: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\tvar x:Sys = mk();\n\t\t$stmt\n\t}\n}';
	}

	private function violations(source: String): Array<Violation> {
		return new PreferSafeNavComparison().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function applyFix(source: String): String {
		final check: PreferSafeNavComparison = new PreferSafeNavComparison();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			source, check.run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = source;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
