package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.DeadStore;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.check.Linter;

/**
 * The `dead-store` check: an assignment to a local / parameter whose value is
 * never read on any path (backward liveness, over-approximated — every
 * uncertainty makes more names live, so a report means dead-on-all-paths).
 * Partition with `unused-local`: a zero-reference binding is that check's
 * finding; a written-then-never-read one is this check's.
 */
class DeadStoreTest extends Test {

	public function testReassignedInitFlagged(): Void {
		// The initializer is overwritten before any read — one dead store (the init).
		Assert.equals(1, violations('class C { function f():Int { var x = 1; x = 2; return x; } }').length);
	}

	public function testMidChainStoreFlagged(): Void {
		// Init and the first reassignment both die before the only read.
		Assert.equals(2, violations('class C { function f(a:Int):Int { var w = a; w = a + 1; w = a + 2; return w; } }').length);
	}

	public function testTrailingStoreFlagged(): Void {
		// A store followed only by the function exit is dead.
		Assert.equals(1, violations('class C { function f(a:Int):Void { var x = a; trace(x); x = a + 1; } }').length);
	}

	public function testBothArmsOverwriteFlagged(): Void {
		// Both arms of the if overwrite before the read — the init is dead.
		Assert.equals(1, violations('class C { function f(a:Int):Int { var x = 1; if (a > 0) x = 2 else x = 3; return x; } }').length);
	}

	public function testParamStoreFlagged(): Void {
		// Parameters are own names — an overwritten param store is dead.
		Assert.equals(1, violations('class C { function f(a:Int):Int { a = 5; a = 6; return a; } }').length);
	}

	public function testWriteOnlyLocalBothFlagged(): Void {
		// A written-then-never-read local: `unused-local`'s text scan counts the write as a
		// reference, so both stores are this check's findings — the partition's other half.
		Assert.equals(2, violations('class C { function f():Void { var q = 1; q = 2; } }').length);
	}

	public function testSelfFeedingIncrementFlagged(): Void {
		// `x = x + 1` reads the old value (keeping the init alive) but its own result dies.
		Assert.equals(1, violations('class C { function f(a:Int):Void { var x = a; trace(x); x = x + 1; } }').length);
	}

	public function testShadowedNameExcluded(): Void {
		// A name bound more than once in the unit is excluded entirely — name-keyed
		// liveness cannot tell the bindings apart. The genuinely-dead outer init is a
		// deliberate safe miss (soundness over precision).
		Assert.equals(0, violations('class C { function f():Void { var x = 1; { var x = 2; trace(x); } } }').length);
	}

	public function testShadowTailReadNotFlagged(): Void {
		// Regression: the inner shadowing decl must not kill the OUTER binding's
		// liveness — the tail read keeps the outer init alive.
		Assert.equals(0, violations('class C { function f():Void { var x = 1; { var x = 2; trace(x); } trace(x); } }').length);
	}

	public function testParamShadowedByLocalExcluded(): Void {
		// A parameter shadowed by a local is the same collision — excluded.
		Assert.equals(0, violations('class C { function f(a:Int):Void { a = 1; { var a = 2; trace(a); } } }').length);
	}

	public function testSwitchSameBranchReassignFlagged(): Void {
		// Branchy conservatism seeds branch exits, but a kill WITHIN one branch still works.
		Assert.equals(
			1,
			violations('class C { function f(a:Int):Void { var x = 0; switch a { case 1: x = 1; x = 2; trace(x); case _: trace(x); } } }').length
		);
	}

	public function testBranchReadNotFlagged(): Void {
		// The init survives on the fall-through arm — not dead.
		Assert.equals(0, violations('class C { function f(a:Int):Int { var x = 1; if (a > 0) x = 2; return x; } }').length);
	}

	public function testInterpolationReadNotFlagged(): Void {
		// A simple `$x` inside a single-quoted string projects as a distinct identifier kind — counted as a read.
		Assert.equals(0, violations("class C { function f(a:Int):Void { var x = a; trace('$x'); x = 5; trace('$x'); } }").length);
	}

	public function testCompoundAssignNotFlagged(): Void {
		// `+=` reads the old value — never a dead store, and it keeps the init alive.
		Assert.equals(0, violations('class C { function f(a:Int):Int { var x = a; x += 1; return x; } }').length);
	}

	public function testClosureUseExcluded(): Void {
		// A name a nested function reads is excluded entirely — the closure may run later.
		Assert.equals(0, violations('class C { function f(a:Int):Void { var x = a; final g = () -> trace(x); x = a + 1; g(); } }').length);
	}

	public function testLoopBackEdgeNotFlagged(): Void {
		// A name read anywhere in the loop stays live throughout it — the back-edge is safe.
		Assert.equals(
			0, violations('class C { function f(n:Int):Int { var acc = 0; for (i in 0...n) acc = acc + i; return acc; } }').length
		);
	}

	public function testBreakPathNotFlagged(): Void {
		// The store carried out through `break` (a jump this walk does not model) stays live.
		Assert.equals(
			0,
			violations(
				'class C { function f(n:Int):Int { var x = 0; var i = 0; while (i < n) { x = i; if (x > 3) break; x = 0; i = i + 1; } return x; } }'
			).length
		);
	}

	public function testTryCatchReadNotFlagged(): Void {
		// The catch arm reads the name — every store inside the construct stays live.
		Assert.equals(
			0, violations('class C { function f():Void { var x = 1; try { x = 2; risky(); } catch (e:Dynamic) { trace(x); } } }').length
		);
	}

	public function testShortCircuitRhsKillNotLeaked(): Void {
		// The `&&` right operand evaluates conditionally — its overwrite must not kill the skip path.
		Assert.equals(
			0,
			violations('class C { function f(a:Int):Int { var x = 1; final ok = a > 0 && (x = 2) > 0; return ok ? x : x + 1; } }').length
		);
	}

	public function testSafeNavCallArgNotLeaked(): Void {
		// A null-safe call's arguments evaluate conditionally — same guard as short-circuit.
		Assert.equals(0, violations('class C { function f(o:Null<Foo>):Int { var x = 1; o?.m(x = 2); return x; } }').length);
	}

	public function testMacroKeepsEverythingLive(): Void {
		// A reification subtree can splice a read of anything — every own name is live before it.
		Assert.equals(0, violations('class C { function f(b:Int):Dynamic { b = 5; final e = macro q(b); return e; } }').length);
	}

	public function testFinalInitNeverFlagged(): Void {
		// A `final` cannot be reassigned — a dead final init means zero reads, `unused-local`'s case.
		Assert.equals(0, violations('class C { function f():Void { final x = compute(); } }').length);
	}

	public function testZeroReferenceInitNotFlagged(): Void {
		// A binding never referenced at all is `unused-local`'s finding, not a dead store.
		Assert.equals(0, violations('class C { function f():Void { var x = 1; } }').length);
	}

	public function testAnonTypedDeclInitReadsCollected(): Void {
		// An anonymous-struct type annotation projects as a decl child BEFORE the init —
		// the initializer (and its reads) is the LAST child. Regression: the branch write
		// was flagged because the switch init (whose branches read the name) went unwalked.
		Assert.equals(
			0,
			violations(
				'class C { function f(s:Int, p:Null<String>):Dynamic { var c = mk(); if (!c && p != null) c = mk2(); final e:{ t:String } = switch s { case 1: { t: c ? "a" : "b" }; case _: { t: c ? "x" : "y" }; }; return e; } }'
			).length
		);
	}

	public function testMultiBindingInitReadsCollected(): Void {
		// `var a = q, b = 2` projects as ONE node; the first initializer's read of `q`
		// must still count — regression for the walked-only-last-child bug.
		Assert.equals(0, violations('class C { function f(p:Int):Int { var q = p; var a = q, b = 2; return a + b; } }').length);
	}

	public function testMultiBindingDeclNotReported(): Void {
		// A multi-binding decl's initializers cannot be attributed to its one projected
		// name — never reported, even when that name is overwritten before a read.
		Assert.equals(0, violations('class C { function f():Int { var a = 1, b = 2; a = 3; return a + b; } }').length);
	}

	public function testMultiBindingSingleChildNotReported(): Void {
		// `var a, b = 1` carries ONE init child that belongs to `b`, not to the
		// projected name `a` — the textual comma detection suppresses the report.
		Assert.equals(0, violations('class C { function f():Int { var a, b = 1; a = 2; trace(a); return a + b; } }').length);
	}

	public function testThrowKeepsCatchReadsLive(): Void {
		// A literal `throw` inside `try` continues at the (unmodeled) catch, which may
		// read anything — it must not clear liveness like a `return` does.
		Assert.equals(
			0,
			violations('class C { function f():Void { var x = 1; try { x = 2; throw mk(); } catch (e:Dynamic) { trace(x); } } }').length
		);
	}

	public function testSafeNavChainArgNotLeaked(): Void {
		// `o?.a.g(y = 1)` short-circuits the WHOLE chain — a `?.` anywhere in the
		// callee subtree makes the arguments conditional.
		Assert.equals(0, violations('class C { function f(o:Null<Foo>):Int { var y = 0; o?.a.g(y = 1); return y; } }').length);
	}

	public function testNestedFnDeclNotOwnName(): Void {
		// A local declared ONLY inside a nested function is that unit's binding — the
		// outer bare write goes to a same-named FIELD, which has unknowable readers.
		Assert.equals(
			0,
			violations(
				'class C { var x:Int; function f():Void { function g():Void { var x = 1; trace(x); } x = 5; g(); } function other():Int { return x; } }'
			).length
		);
	}

	public function testMetaArgWriteDoesNotKill(): Void {
		// A metadata argument never runs — `@:m(y = 2)` is not a store and must not
		// kill the initializer's liveness before the real read.
		Assert.equals(0, violations('class C { function f():Void { var y = 1; @:m(y = 2) trace(y); } }').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('dead-store'));
	}

	private function violations(src: String): Array<Violation> {
		return new DeadStore().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
