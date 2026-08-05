package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferSafeNav;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `prefer-safe-nav` check: a null guard on a LOCAL / PARAM / `this` receiver is
 * flagged `Info` and rewritten to safe navigation (only the FIRST dot becomes `?.`) —
 * both the statement form `if (x != null) x.m(...)` → `x?.m(...);` and the ternary form
 * `x == null ? null : x.m(...)` / `x != null ? x.m(...) : null` → `x?.m(...)`. A field /
 * `this.`-qualified receiver, a multi-statement block, an `else` branch, an assignment
 * l-value, a compound condition, an already-safe-nav body and a comment in the removed
 * region are all safe misses; so is a ternary whose guarded branch is not itself the
 * chain (`x.f + 1`) or whose other branch is not `null`.
 */
class PreferSafeNavCheckTest extends Test {

	public function testLocalFlaggedBare(): Void {
		final vs: Array<Violation> = violations(local('if (x != null) x.command("a");'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-safe-nav', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this null guard can be safe navigation (?.)', vs[0].message);
	}

	public function testLocalFixedBare(): Void {
		Assert.equals(local('x?.command("a");'), applyFix(local('if (x != null) x.command("a");')));
	}

	public function testBracedSingleStmtFlaggedAndFixed(): Void {
		Assert.equals(1, violations(local('if (x != null) { x.command("b"); }')).length);
		Assert.equals(local('x?.command("b");'), applyFix(local('if (x != null) { x.command("b"); }')));
	}

	public function testChainFixed(): Void {
		Assert.equals(1, violations(local('if (x != null) x.a.b("c");')).length);
		Assert.equals(local('x?.a.b("c");'), applyFix(local('if (x != null) x.a.b("c");')));
	}

	public function testReversedConditionFlaggedAndFixed(): Void {
		Assert.equals(1, violations(local('if (null != x) x.command("r");')).length);
		Assert.equals(local('x?.command("r");'), applyFix(local('if (null != x) x.command("r");')));
	}

	public function testParamReceiverFlagged(): Void {
		final source: String = 'class C {\n\tfunction f(p:Sys):Void {\n\t\tif (p != null) p.command("k");\n\t}\n}';
		final vs: Array<Violation> = violations(source);
		Assert.equals(1, vs.length);
		Assert.isTrue(applyFix(source).indexOf('p?.command("k");') != -1);
	}

	public function testFieldReceiverNotFlagged(): Void {
		final source: String = 'class C {\n\tvar fld:Sys;\n\tfunction f():Void {\n\t\tif (fld != null) fld.command("z");\n\t}\n}';
		Assert.equals(0, violations(source).length);
	}

	public function testThisReceiverNotFlagged(): Void {
		final source: String = 'class C {\n\tvar fld:Sys;\n\tfunction f():Void {\n\t\tif (this.fld != null) this.fld.command("z");\n\t}\n}';
		Assert.equals(0, violations(source).length);
	}

	public function testMultiStatementBlockNotFlagged(): Void {
		Assert.equals(0, violations(local('if (x != null) { x.command("a"); x.command("b"); }')).length);
	}

	public function testElseBranchNotFlagged(): Void {
		Assert.equals(0, violations(local('if (x != null) x.command("a") else x.command("b");')).length);
	}

	public function testAssignmentLValueNotFlagged(): Void {
		Assert.equals(0, violations(local('if (x != null) x.f = 1;')).length);
	}

	public function testGuardFirstConjunctNotFlagged(): Void {
		Assert.equals(0, violations(local('if (x != null && ok) x.command("q");')).length);
	}

	public function testAlreadySafeNavBodyNotFlagged(): Void {
		Assert.equals(0, violations(local('if (x != null) x?.command("s");')).length);
	}

	public function testCommentInGapNotFlagged(): Void {
		Assert.equals(0, violations(local('if (x != null) /* why */ x.command("a");')).length);
	}

	public function testApplyFixByteExact(): Void {
		final input: String = 'class C {\n\tfunction f():Void {\n\t\tvar x:Sys = mk();\n\t\tif (x != null) x.a.b("c");\n\t}\n}';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tvar x:Sys = mk();\n\t\tx?.a.b("c");\n\t}\n}';
		Assert.equals(expected, applyFix(input));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-safe-nav'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-safe-nav'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { if (x != null) x.').length);
	}

	public function testParenthesizedConditionFlaggedAndFixed(): Void {
		Assert.equals(1, violations(local('if ((x != null)) x.command("p");')).length);
		Assert.equals(local('x?.command("p");'), applyFix(local('if ((x != null)) x.command("p");')));
	}

	public function testConjunctionGuardLastFlaggedAndFixed(): Void {
		Assert.equals(1, violations(local('if (ok && x != null) x.command("q");')).length);
		Assert.equals(local('if (ok) x?.command("q");'), applyFix(local('if (ok && x != null) x.command("q");')));
	}

	public function testThreeConjunctsGuardLastFixed(): Void {
		Assert.equals(1, violations(local('if (a && b && x != null) x.command("t");')).length);
		Assert.equals(local('if (a && b) x?.command("t");'), applyFix(local('if (a && b && x != null) x.command("t");')));
	}

	public function testConjunctionBracedFixed(): Void {
		Assert.equals(1, violations(local('if (ok && x != null) { x.command("b"); }')).length);
		Assert.equals(local('if (ok) x?.command("b");'), applyFix(local('if (ok && x != null) { x.command("b"); }')));
	}

	public function testOrderSensitiveGuardNotLastNotFlagged(): Void {
		Assert.equals(0, violations(local('if (x != null && x.n > 0) x.command("o");')).length);
	}

	public function testSoleGuardArgumentNotFlagged(): Void {
		Assert.equals(0, violations(local('if (x != null) x.command(x);')).length);
		Assert.equals(local('if (x != null) x.command(x);'), applyFix(local('if (x != null) x.command(x);')));
	}

	public function testConjunctionGuardArgumentNotFlagged(): Void {
		Assert.equals(0, violations(local('if (ok && x != null) x.command(x);')).length);
	}

	public function testGuardInReceiverChainArgNotFlagged(): Void {
		Assert.equals(0, violations(local('if (x != null) x.a(x).b();')).length);
		Assert.equals(local('if (x != null) x.a(x).b();'), applyFix(local('if (x != null) x.a(x).b();')));
	}

	public function testConjunctionArgumentStaysGuarded(): Void {
		final source: String =
			'class C {\n\tfunction f(c:Sys, axis:Sys):Void {\n\t\tif (c != null && axis != null) axis.setScrollPos(c, value, h());\n\t}\n}';
		final expected: String =
			'class C {\n\tfunction f(c:Sys, axis:Sys):Void {\n\t\tif (c != null) axis?.setScrollPos(c, value, h());\n\t}\n}';
		Assert.equals(1, violations(source).length);
		Assert.equals(expected, applyFix(source));
	}

	public function testCommentInDroppedConjunctNotFlagged(): Void {
		Assert.equals(0, violations(local('if (ok && /* c */ x != null) x.command("q");')).length);
	}

	public function testTernaryEqLocalFlaggedAndFixed(): Void {
		final vs: Array<Violation> = violations(local('trace(x == null ? null : x.a.b("c"));'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-safe-nav', vs[0].rule);
		Assert.equals(local('trace(x?.a.b("c"));'), applyFix(local('trace(x == null ? null : x.a.b("c"));')));
	}

	public function testTernaryNotEqLocalFlaggedAndFixed(): Void {
		Assert.equals(1, violations(local('trace(x != null ? x.f : null);')).length);
		Assert.equals(local('trace(x?.f);'), applyFix(local('trace(x != null ? x.f : null);')));
	}

	public function testTernaryReversedNullOperandFixed(): Void {
		Assert.equals(local('trace(x?.f);'), applyFix(local('trace(null == x ? null : x.f);')));
		Assert.equals(local('trace(x?.f);'), applyFix(local('trace(null != x ? x.f : null);')));
	}

	public function testTernaryAbstractThisReceiverFlaggedAndFixed(): Void {
		final source: String = abstractSelf("return this == null ? null : this.map(p -> '${p.x}').join(',');");
		final expected: String = abstractSelf("return this?.map(p -> '${p.x}').join(',');");
		Assert.equals(1, violations(source).length);
		Assert.equals(expected, applyFix(source));
	}

	public function testTernaryFieldReceiverNotFlagged(): Void {
		final source: String =
			'class C {\n\tvar fld:Sys;\n\tfunction f():Void {\n\t\ttrace(fld == null ? null : fld.command("z"));\n\t}\n}';
		Assert.equals(0, violations(source).length);
	}

	public function testTernaryNonChainBranchNotFlagged(): Void {
		Assert.equals(0, violations(local('trace(x == null ? null : x.f + 1);')).length);
	}

	public function testTernaryOtherReceiverNotFlagged(): Void {
		Assert.equals(0, violations(local('trace(x == null ? null : y.f);')).length);
	}

	public function testTernaryNonNullBranchNotFlagged(): Void {
		Assert.equals(0, violations(local('trace(x == null ? 0 : x.f);')).length);
	}

	public function testTernaryGuardInArgumentNotFlagged(): Void {
		Assert.equals(0, violations(local('trace(x == null ? null : x.command(x));')).length);
	}

	public function testTernaryAlreadySafeNavNotFlagged(): Void {
		Assert.equals(0, violations(local('trace(x == null ? null : x?.f);')).length);
	}

	public function testTernaryIndexJunctionNotFlagged(): Void {
		Assert.equals(0, violations(local('trace(x == null ? null : x[0].f);')).length);
	}

	public function testTernaryCommentInDroppedRegionNotFlagged(): Void {
		Assert.equals(0, violations(local('trace(x == null ? null /* c */ : x.f);')).length);
	}

	/** The `!=` polarity puts the dropped `null` AFTER the kept branch — the suffix half of the comment gate. */
	public function testTernaryCommentAfterKeptBranchNotFlagged(): Void {
		Assert.equals(0, violations(local('trace(x != null ? x.f /* c */ : null);')).length);
	}

	public function testTernaryMidChainIndexFixed(): Void {
		Assert.equals(1, violations(local('trace(x == null ? null : x.arr[0].c);')).length);
		Assert.equals(local('trace(x?.arr[0].c);'), applyFix(local('trace(x == null ? null : x.arr[0].c);')));
	}

	public function testStatementThisReceiverFixed(): Void {
		final source: String = 'abstract A(Array<P>) {\n\tpublic function f():Void {\n\t\tif (this != null) this.m();\n\t}\n}';
		final expected: String = 'abstract A(Array<P>) {\n\tpublic function f():Void {\n\t\tthis?.m();\n\t}\n}';
		Assert.equals(1, violations(source).length);
		Assert.equals(expected, applyFix(source));
	}

	/** A `cast` on the receiver spine breaks the chain — `(cast x?.a).m()` dereferences null. */
	public function testStatementCastOnSpineNotFlagged(): Void {
		Assert.equals(0, violations(local('if (x != null) (cast x.a).m();')).length);
	}

	/** An operator on the receiver spine breaks the chain — `(x?.a + b).m()` adds to a `Null<T>`. */
	public function testStatementOperatorOnSpineNotFlagged(): Void {
		Assert.equals(0, violations(local('if (x != null) (x.a + b).m();')).length);
	}

	public function testStatementMidChainIndexFixed(): Void {
		Assert.equals(1, violations(local('if (x != null) x.arr[0].b();')).length);
		Assert.equals(local('x?.arr[0].b();'), applyFix(local('if (x != null) x.arr[0].b();')));
	}

	/** A comment between the receiver and its dot would swallow the inserted `?` — reported, left unfixed. */
	public function testCommentBeforeDotNotFixed(): Void {
		final source: String = local('trace(x == null ? null : x /* a.b */ .f);');
		Assert.equals(1, violations(source).length);
		Assert.equals(source, applyFix(source));
	}

	private function local(stmt: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\tvar x:Sys = mk();\n\t\t$stmt\n\t}\n}';
	}

	private function abstractSelf(stmt: String): String {
		return 'abstract A(Array<P>) {\n\t@:to public function toString():String {\n\t\t$stmt\n\t}\n}';
	}

	private function violations(source: String): Array<Violation> {
		return new PreferSafeNav().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function applyFix(source: String): String {
		final check: PreferSafeNav = new PreferSafeNav();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			source, check.run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = source;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
