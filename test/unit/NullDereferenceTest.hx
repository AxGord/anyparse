package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.NullDereference;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `null-dereference` check: a field / method access whose receiver is
 * provably **null** by flow on every path reaching it — a guaranteed runtime
 * NPE. The headline bug-finder of the definite-null arc. Conservative: a
 * reassignment, a non-null path, a closure capture, or a non-local receiver all
 * suppress the finding; `?.` (a distinct kind) is never flagged.
 */
class NullDereferenceTest extends Test {

	public function testMethodCallOnKnownNullFlagged(): Void {
		// `var x = null` makes x known-null; `x.foo()` dereferences it.
		Assert.equals(1, violations('class C { function f() { var x = null; x.foo(); } }').length);
	}

	public function testFieldAccessOnKnownNullFlagged(): Void {
		// The bare `.field` form is the same FieldAccess node.
		Assert.equals(1, violations('class C { function f() { var x = null; var y = x.bar; } }').length);
	}

	public function testGuardThenDerefFlagged(): Void {
		// Inside the `== null` arm x is known-null — dereferencing it is dead-or-buggy.
		Assert.equals(1, violations('class C { function f(?x:Foo) { if (x == null) { x.foo(); } } }').length);
	}

	public function testEarlyReturnMakesSafe(): Void {
		// After `if (x == null) return;` the fall-through has x non-null.
		Assert.equals(0, violations('class C { function f(?x:Foo) { if (x == null) return; x.foo(); } }').length);
	}

	public function testReassignmentClears(): Void {
		// An unknown reassignment clears the known-null fact.
		Assert.equals(0, violations('class C { function f() { var x = null; x = mk(); x.foo(); } }').length);
	}

	public function testNonNullReceiverNotFlagged(): Void {
		// A constructor assignment makes the receiver non-null.
		Assert.equals(0, violations('class C { function f() { var x = new Foo(); x.foo(); } }').length);
	}

	public function testUnknownReceiverNotFlagged(): Void {
		// A plain nullable param with no flow evidence is Unknown, not null.
		Assert.equals(0, violations('class C { function f(?x:Foo) { x.foo(); } }').length);
	}

	public function testSafeNavNotFlagged(): Void {
		// `?.` short-circuits on null — a distinct node kind, never a dereference.
		Assert.equals(0, violations('class C { function f() { var x = null; var y = x?.foo; } }').length);
	}

	public function testStaticAccessNotFlagged(): Void {
		// A type-name receiver is never a flow-null local — static access is safe.
		Assert.equals(0, violations('class C { function f() { var x = null; Std.string(1); } }').length);
	}

	public function testClosureCaptureNotFlagged(): Void {
		// x is mutated inside a closure — never narrowed, so its access is not flagged.
		Assert.equals(0, violations('class C { function f() { var x = null; var g = () -> x = mk(); x.foo(); } }').length);
	}

	public function testWarningSeverity(): Void {
		final vs: Array<Violation> = violations('class C { function f() { var x = null; x.foo(); } }');
		Assert.equals(1, vs.length);
		Assert.equals('null-dereference', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	public function testFixIsNoop(): Void {
		final check: NullDereference = new NullDereference();
		final src: String = 'class C { function f() { var x = null; x.foo(); } }';
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin());
		Assert.equals(0, edits.length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0,
			new NullDereference().run([{ file: 'Bad.hx', source: 'class Bad { function f() { var x = null; x.' }], new HaxeQueryPlugin())
				.length
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('null-dereference'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('null-dereference'));
	}

	public function testCasePatternCaptureNotFlagged(): Void {
		// `case Some(x)` binds a fresh `x` shadowing the known-null outer local — its deref is fine.
		Assert.equals(
			0,
			violations(
				'enum E { Some(s:String); None; } class C { function f(k:E) { var x:Null<String> = null; switch k { case Some(x): trace(x.length); case None: } } }'
			).length
		);
	}

	public function testCatchVarShadowNotFlagged(): Void {
		// The catch variable `e` is a fresh binding shadowing the known-null outer `e`.
		Assert.equals(
			0,
			violations(
				'class C { function f() { var e:Null<String> = null; try { risky(); } catch (e:haxe.Exception) { trace(e.message); } } }'
			).length
		);
	}

	public function testSwitchSubjectWriteFlagged(): Void {
		// The subject expression assigns null on the running state — every branch sees it.
		Assert.equals(1, violations('class C { function f(?x:String) { switch (x = null) { case _: trace(x.length); } } }').length);
	}

	public function testShortCircuitRhsNullWriteNotFlagged(): Void {
		// The `&&` right side runs only when c is true — the null write is one path, not every path.
		Assert.equals(
			0, violations('class C { function f(c:Bool) { var y = "a"; var b = c && (y = null) == null; var n = y.length; } }').length
		);
	}

	public function testIndexAccessOnKnownNullFlagged(): Void {
		// Indexing a known-null receiver throws just like a field access.
		Assert.equals(1, violations('class C { function f() { var x = null; var y = x[0]; } }').length);
	}

	public function testForceNavOnKnownNullFlagged(): Void {
		// `x!.foo` forces a known-null — the exact crash the sigil promises away.
		Assert.equals(1, violations('class C { function f() { var x = null; var y = x!.foo; } }').length);
	}

	public function testBareCallOnKnownNullFlagged(): Void {
		// Calling a known-null function value throws.
		Assert.equals(1, violations('class C { function f() { var g = null; g(); } }').length);
	}

	public function testIndexAccessUnknownNotFlagged(): Void {
		// A plain nullable param with no flow evidence is Unknown, not null.
		Assert.equals(0, violations('class C { function f(?a:Array<Int>) { var y = a[0]; } }').length);
	}

	public function testIndexAccessAfterGuardNotFlagged(): Void {
		// After `if (a == null) return;` the fall-through has a non-null.
		Assert.equals(0, violations('class C { function f(?a:Array<Int>) { if (a == null) return; var y = a[0]; } }').length);
	}

	public function testLazyInitChainNotFlagged(): Void {
		// The chain writes x between the `== null` conjunct and the dereference — reaching it means the write ran.
		Assert.equals(
			0, violations('class C { function f(?x:String) { if (x == null && (x = "v") != null && x.length > 0) trace(x); } }').length
		);
	}

	public function testCommaPatternCtorNotFlagged(): Void {
		// `case a(v), b(v):` — the second alternative's ctor name collides with the
		// known-null local `b`; it is a pattern, not a call of that local.
		Assert.equals(
			0,
			violations(
				'enum E { a(v:Int); b(v:Int); } class C { function f(e:E) { var b = null; switch e { case a(v), b(v): trace(v); case _: trace(b); } } }'
			).length
		);
	}

	public function testMetaArgDerefNotFlagged(): Void {
		// A metadata argument is compile-time data — `@:m(x.foo)` never dereferences x.
		Assert.equals(0, violations('class C { function f(x:Dynamic) { if (x == null) { @:m(x.foo) trace(1); } } }').length);
	}

	public function testLaunderedKnownNullDerefFlagged(): Void {
		// `var ok = u == null; if (ok) u.charAt(0)` — u is KNOWN-null in the then-arm, so the deref is a guaranteed NPE (feature 1).
		Assert.equals(1, violations('class C { function f(?u:String) { var ok = u == null; if (ok) u.charAt(0); } }').length);
	}

	private function violations(src: String): Array<Violation> {
		return new NullDereference().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
