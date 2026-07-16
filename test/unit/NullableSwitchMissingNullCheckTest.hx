package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.NullableSwitchMissingNull;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The `nullable-switch-missing-null` check: a `switch` over a provably-nullable
 * subject whose branches carry an unguarded wildcard (`case _:` / `default:`) but
 * no `case null` is flagged `Warning`, report-only — `case _` does not match null,
 * so a null subject falls through every arm (a segfault on hxcpp for a null enum).
 * Nullable sources covered: a declared `Null<T>` local / param (source 1a), an
 * optional `?param` (source 1b), a local bound from a nullable source via `NullFlow`
 * (source 2), and a direct nullable-source subject like `map[key]` (source 3). A
 * flow-narrowed subject (`if (x == null) return; switch x`), a `case null` arm
 * (guarded or not), a `case null, _:` combo, a guarded wildcard, a `?`-coalesced
 * subject, a non-nullable subject, and a wildcard-free switch are all safe misses.
 */
class NullableSwitchMissingNullCheckTest extends Test {

	public function testNullParamWildcardFlagged(): Void {
		final vs: Array<Violation> = violations(cls('function f(x:Null<Int>):Void { switch x { case 1: trace(1); case _: trace(0); } }'));
		Assert.equals(1, vs.length);
		Assert.equals('nullable-switch-missing-null', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals(
			'switch subject is nullable but case _ / default does not match null — add case null (case null, _:) or narrow the subject',
			vs[0].message
		);
	}

	public function testCaseNullNotFlagged(): Void {
		Assert.equals(
			0,
			violations(cls('function f(x:Null<Int>):Void { switch x { case null: trace(9); case 1: trace(1); case _: trace(0); } }')).length
		);
	}

	public function testCaseNullWildcardComboNotFlagged(): Void {
		Assert.equals(0, violations(cls('function f(x:Null<Int>):Void { switch x { case 1: trace(1); case null, _: trace(0); } }')).length);
	}

	public function testOptionalParamFlagged(): Void {
		Assert.equals(1, violations(cls('function f(?x:Int):Void { switch x { case 1: trace(1); case _: trace(0); } }')).length);
	}

	public function testNonNullableSubjectNotFlagged(): Void {
		Assert.equals(0, violations(cls('function f(x:Int):Void { switch x { case 1: trace(1); case _: trace(0); } }')).length);
	}

	public function testNoWildcardNotFlagged(): Void {
		Assert.equals(0, violations(cls('function f(x:Null<Int>):Void { switch x { case 1: trace(1); case 2: trace(2); } }')).length);
	}

	public function testDefaultBranchFlagged(): Void {
		Assert.equals(1, violations(cls('function f(x:Null<Int>):Void { switch x { case 1: trace(1); default: trace(0); } }')).length);
	}

	public function testCoalescedSubjectNotFlagged(): Void {
		Assert.equals(
			0, violations(cls('function f(x:Null<Int>):Void { switch (x ?? 5) { case 1: trace(1); default: trace(0); } }')).length
		);
	}

	public function testLocalFromMapFlagged(): Void {
		Assert.equals(
			1,
			violations(cls('function f(m:Map<String, Int>):Void { final u = m[\'k\']; switch u { case 1: trace(1); case _: trace(0); } }')).length
		);
	}

	public function testSwitchExpressionFlagged(): Void {
		Assert.equals(1, violations(cls('function f(x:Null<Int>):Int { return switch x { case 1: 1; case _: 0; }; }')).length);
	}

	public function testGuardedCaseNullNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				cls('function f(x:Null<Int>):Void { switch x { case 1: trace(1); case null if (true): trace(9); case _: trace(0); } }')
			).length
		);
	}

	public function testGuardedWildcardNotFlagged(): Void {
		Assert.equals(
			0, violations(cls('function f(x:Null<Int>):Void { switch x { case 1: trace(1); case _ if (x != null): trace(0); } }')).length
		);
	}

	public function testFlowNarrowedNotFlagged(): Void {
		Assert.equals(
			0,
			violations(cls('function f(x:Null<Int>):Void { if (x == null) return; switch x { case 1: trace(1); case _: trace(0); } }')).length
		);
	}

	public function testLocalAssignedNullFlagged(): Void {
		Assert.equals(
			1, violations(cls('function f():Void { var x:Null<Int> = null; switch x { case 1: trace(1); case _: trace(0); } }')).length
		);
	}

	public function testAssertedNonNullNotFlagged(): Void {
		Assert.equals(
			0,
			violations(cls('function f(x:Null<Int>):Void { Assert.notNull(x); switch x { case 1: trace(1); case _: trace(0); } }')).length
		);
	}

	public function testLengthGuardedPopNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				cls(
					'function f(stack:Array<Int>):Void { while (stack.length > 0) { final node = stack.pop(); switch node { case 1: trace(1); case _: trace(0); } } }'
				)
			).length
		);
	}

	public function testFixIsReportOnly(): Void {
		final check: NullableSwitchMissingNull = new NullableSwitchMissingNull();
		final src: String = cls('function f(x:Null<Int>):Void { switch x { case 1: trace(1); case _: trace(0); } }');
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('nullable-switch-missing-null'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('nullable-switch-missing-null'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f(x:Null<Int>):Void { switch x { case _: trace(0);').length);
	}

	private function cls(body: String): String {
		return 'class C {\n\t' + body + '\n}';
	}

	private function violations(source: String): Array<Violation> {
		return new NullableSwitchMissingNull().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

}
