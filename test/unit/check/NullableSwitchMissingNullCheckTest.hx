package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.NullableSwitchMissingNull;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

/**
 * The `nullable-switch-missing-null` check: a `switch` over a provably-nullable ENUM subject
 * that carries neither a wildcard nor a `case null` is flagged `Warning` — the wildcard-less
 * enum switch reads the constructor tag off the subject before any pattern is tried, so a
 * null subject faults (hxcpp SIGSEGV, js `_hx_index` of null, eval `Null Access`).
 *
 * Each of the three trigger conditions is necessary, and each has its own not-flagged
 * fixture, all three measured on hxcpp / js / eval: a wildcard arm (guarded or not) makes the
 * compiler emit a null check first, a non-enum subject compiles to plain comparisons null
 * merely fails to match, and an `enum abstract` is its underlying primitive. Flow narrowing,
 * `??`-coalescing, precondition asserts and a `case null` arm are safe misses as before.
 * REPORT-ONLY: there is no catch-all body to route null into, so `fix` yields no edits.
 */
class NullableSwitchMissingNullCheckTest extends Test {

	public function testNullEnumParamNoWildcardFlagged(): Void {
		final vs: Array<Violation> =
			violations(mod('function f(e:Null<Colour>):Void { switch e { case Red: trace(1); case Green: trace(2); } }'));
		Assert.equals(1, vs.length);
		Assert.equals('nullable-switch-missing-null', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals(
			'switch subject is a nullable enum and no arm matches null — reading the constructor tag off null'
			+ ' dereferences it; add case null or narrow the subject',
			vs[0].message
		);
	}

	public function testOptionalEnumParamFlagged(): Void {
		Assert.equals(1, violations(mod('function f(?e:Colour):Void { switch e { case Red: trace(1); case Green: trace(2); } }')).length);
	}

	public function testLocalAssignedNullFlagged(): Void {
		Assert.equals(
			1,
			violations(mod('function f():Void { var e:Null<Colour> = null; switch e { case Red: trace(1); case Green: trace(2); } }'))
				.length
		);
	}

	public function testSwitchExpressionFlagged(): Void {
		Assert.equals(1, violations(mod('function f(e:Null<Colour>):Int { return switch e { case Red: 1; case Green: 2; }; }')).length);
	}

	/** A wildcard makes the compiler emit the null check — measured surviving on hxcpp / js / eval. */
	public function testWildcardNotFlagged(): Void {
		Assert.equals(0, violations(mod('function f(e:Null<Colour>):Void { switch e { case Red: trace(1); case _: trace(0); } }')).length);
	}

	public function testDefaultBranchNotFlagged(): Void {
		Assert.equals(0, violations(mod('function f(e:Null<Colour>):Void { switch e { case Red: trace(1); default: trace(0); } }')).length);
	}

	/** A GUARDED wildcard also survives — the arm's presence, not its guard, drives the null check. */
	public function testGuardedWildcardNotFlagged(): Void {
		Assert.equals(
			0,
			violations(mod(
				'function f(e:Null<Colour>):Void { switch e { case Red: trace(1); case Green: trace(2); case _ if (false): trace(0); } }'
			)).length
		);
	}

	public function testCaseNullNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				mod('function f(e:Null<Colour>):Void { switch e { case null: trace(9); case Red: trace(1); case Green: trace(2); } }')
			).length
		);
	}

	/** A non-enum subject compiles to plain comparisons — null matches nothing and control falls past. */
	public function testNonEnumSubjectNotFlagged(): Void {
		Assert.equals(0, violations(mod('function f(x:Null<Int>):Void { switch x { case 1: trace(1); case 2: trace(2); } }')).length);
	}

	/** An `enum abstract` value IS its underlying primitive — measured surviving on hxcpp. */
	public function testEnumAbstractSubjectNotFlagged(): Void {
		Assert.equals(0, violations(mod('function f(m:Null<Mode>):Void { switch m { case On: trace(1); case Off: trace(2); } }')).length);
	}

	public function testNonNullableEnumNotFlagged(): Void {
		Assert.equals(0, violations(mod('function f(e:Colour):Void { switch e { case Red: trace(1); case Green: trace(2); } }')).length);
	}

	public function testFlowNarrowedNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				mod('function f(e:Null<Colour>):Void { if (e == null) return; switch e { case Red: trace(1); case Green: trace(2); } }')
			).length
		);
	}

	/**
	 * A PRE-TEST loop header narrows its body exactly as an `if` narrows its then-arm, so the
	 * classic `while ((task = pop()) != null)` drain loop is a safe miss. Was a false positive
	 * until `NullFlow.handleLoop` learned the header (found on a real tree, not in fixtures).
	 */
	public function testWhileHeaderNarrowedNotFlagged(): Void {
		Assert.equals(
			0,
			violations(mod(
				'function f(next:Void -> Null<Colour>):Void { var e:Null<Colour> = next(); while (e != null) {'
				+ ' switch e { case Red: trace(1); case Green: trace(2); } e = next(); } }'
			)).length
		);
	}

	/** A POST-TEST loop runs its body BEFORE the test, so the header proves nothing inside it. */
	public function testDoWhileHeaderStillFlagged(): Void {
		Assert.equals(
			1,
			violations(mod(
				'function f(next:Void -> Null<Colour>):Void { var e:Null<Colour> = next(); do {'
				+ ' switch e { case Red: trace(1); case Green: trace(2); } e = next(); } while (e != null); }'
			)).length
		);
	}

	/** The header's fact does not survive a write later in the same body — the write re-decides it. */
	public function testSwitchAfterLoopBodyWriteFlagged(): Void {
		Assert.equals(
			1,
			violations(mod(
				'function f(next:Void -> Null<Colour>):Void { var e:Null<Colour> = next(); while (e != null) { e = next();'
				+ ' switch e { case Red: trace(1); case Green: trace(2); } } }'
			)).length
		);
	}

	public function testCoalescedSubjectNotFlagged(): Void {
		Assert.equals(
			0,
			violations(mod('function f(e:Null<Colour>):Void { switch (e ?? Red) { case Red: trace(1); case Green: trace(2); } }')).length
		);
	}

	public function testAssertedNonNullNotFlagged(): Void {
		Assert.equals(
			0,
			violations(mod('function f(e:Null<Colour>):Void { Assert.notNull(e); switch e { case Red: trace(1); case Green: trace(2); } }'))
				.length
		);
	}

	/** A bare field never narrows, so it stays out of the flow engine's scope. */
	public function testBareFieldSubjectNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				mod('var fld:Null<Colour> = null;\n\tfunction f():Void { switch fld { case Red: trace(1); case Green: trace(2); } }')
			).length
		);
	}

	/**
	 * An enum the `SymbolIndex` cannot see (declared outside the lint scope) fails the
	 * runtime-tagged gate — the check fails CLOSED rather than guessing from the pattern names.
	 */
	public function testUnresolvableEnumTypeNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tfunction f(e:Null<Offsite>):Void { switch e { case Red: trace(1); case Green: trace(2); } }\n}').length
		);
	}

	/**
	 * A subject with no declared type — a local bound from a map read — carries no type to
	 * resolve the enum with, so gate 4 refuses it. A documented miss, not a safe shape.
	 */
	public function testUndeclaredLocalSubjectNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				mod('function f(m:Map<String, Colour>):Void { final u = m[\'k\']; switch u { case Red: trace(1); case Green: trace(2); } }')
			).length
		);
	}

	public function testFixIsReportOnly(): Void {
		final src: String = mod('function f(e:Null<Colour>):Void { switch e { case Red: trace(1); case Green: trace(2); } }');
		final check: NullableSwitchMissingNull = new NullableSwitchMissingNull();
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
		Assert.equals(0, violations('class Bad { function f(e:Null<Colour>):Void { switch e { case Red: trace(0);').length);
	}

	private function violations(source: String): Array<Violation> {
		return new NullableSwitchMissingNull().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	/** The fixture module: the two subject types the gates discriminate, plus `body` inside class `C`. */
	private function mod(body: String): String {
		return 'enum Colour { Red; Green; }\n\nenum abstract Mode(Int) {\n\tvar On = 1;\n\tvar Off = 2;\n}\n\nclass C {\n\t$body\n}';
	}

}
