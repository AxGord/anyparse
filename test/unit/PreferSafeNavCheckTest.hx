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
 * The `prefer-safe-nav` check: a single-statement null guard
 * `if (x != null) x.m(...)` on a LOCAL / PARAM receiver is flagged `Info` and
 * rewritten to `x?.m(...);` (only the FIRST dot becomes `?.`). A field / `this.`
 * receiver, a multi-statement block, an `else` branch, an assignment l-value, a
 * compound condition, an already-safe-nav body and a comment in the removed `if`
 * region are all safe misses.
 */
class PreferSafeNavCheckTest extends Test {

	public function testLocalFlaggedBare(): Void {
		final vs: Array<Violation> = violations(local('if (x != null) x.command("a");'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-safe-nav', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this single null guard can be safe navigation (?.)', vs[0].message);
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

	public function testCompoundConditionNotFlagged(): Void {
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

	private function local(stmt: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\tvar x:Sys = mk();\n\t\t' + stmt + '\n\t}\n}';
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
