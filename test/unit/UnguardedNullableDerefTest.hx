package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.UnguardedNullableDeref;
import anyparse.grammar.haxe.HaxeQueryPlugin;

/**
 * The `unguarded-nullable-deref` check (mechanism A): a local bound from a nullable
 * source (`map[key]`, `Array` / `List` `pop` / `shift`, a `Null<T>`-returning call)
 * and dereferenced with no null check on the path is flagged `Warning`. The
 * flow-sensitive sibling of the point-wise `possible-null-dereference` — it catches
 * the binding-then-use `var u = m[k]; ...; u.f` that the point-wise check is blind to,
 * while a guard (`if (u != null)`, early return, `&&`, non-null reassignment, `??=`)
 * narrows the fact away. A non-nullable source, a direct-expression receiver, a
 * closure body, a plain param, and a multi-binding declaration are safe misses.
 */
class UnguardedNullableDerefTest extends Test {

	public function testMapBindingFieldFlagged(): Void {
		final vs: Array<Violation> = violations('class C { function f(m:Map<String,Int>) { var u = m[k]; g(); u.foo; } function g() {} }');
		Assert.equals(1, vs.length);
		Assert.equals('unguarded-nullable-deref', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	public function testArrayPopBindingNotFlagged(): Void {
		// Array.pop / shift, List.pop / first / last are excluded from the flow seed:
		// their dominant `while (c.length > 0) c.pop()` idiom is length-guarded, a guard
		// flow cannot model, so seeding them would be a systematic false positive. The
		// point-wise `possible-null-dereference` still flags them at `Info`.
		Assert.equals(0, violations('class C { function f(arr:Array<Int>) { var u = arr.pop(); u.bar(); } }').length);
	}

	public function testLengthGuardedPopNotFlagged(): Void {
		Assert.equals(
			0, violations('class C { function f(arr:Array<Int>) { while (arr.length > 0) { var u = arr.pop(); u.foo; } } }').length
		);
	}

	public function testMapGetBindingFlagged(): Void {
		Assert.equals(1, violations('class C { function f(m:Map<String,Foo>) { var u = m.get(k); u.bar(); } }').length);
	}

	public function testCrossFileInstanceReturnFlagged(): Void {
		Assert.equals(1, violationsFiles([
			{ file: 'Helper.hx', source: 'class Helper { public function findUser(s:String):Null<Foo> return null; }' },
			{ file: 'Caller.hx', source: 'class Caller { function f(h:Helper) { var u = h.findUser(k); u.name; } }' }
		]).length);
	}

	public function testCrossFileStaticReturnFlagged(): Void {
		Assert.equals(1, violationsFiles([
			{ file: 'Helper.hx', source: 'class Helper { public static function make():Null<Foo> return null; }' },
			{ file: 'Caller.hx', source: 'class Caller { function g() { var u = Helper.make(); u.name; } }' }
		]).length);
	}

	public function testCrossFileNonNullReturnNotFlagged(): Void {
		Assert.equals(0, violationsFiles([
			{ file: 'Helper.hx', source: 'class Helper { public function plain():Foo return null; }' },
			{ file: 'Caller.hx', source: 'class Caller { function f(h:Helper) { var u = h.plain(); u.name; } }' }
		]).length);
	}

	public function testCrossFileAmbiguousReturnNotFlagged(): Void {
		Assert.equals(0, violationsFiles([
			{ file: 'A.hx', source: 'class Helper { public function findUser(s:String):Null<Foo> return null; }' },
			{ file: 'B.hx', source: 'class Helper { public function findUser(s:String):Foo return null; }' },
			{ file: 'Caller.hx', source: 'class Caller { function f(h:Helper) { var u = h.findUser(k); u.name; } }' }
		]).length);
	}

	public function testInferredLocalNotMisresolvedAsType(): Void {
		// A bound local whose type is inferred (unannotated `var Box = new Safe()`) must NOT be
		// reinterpreted as a same-named indexed class — the static-fallback collision (R1).
		Assert.equals(0, violationsFiles([
			{ file: 'Box.hx', source: 'class Box { public function get():Null<Foo> return null; }' },
			{
				file: 'Main.hx',
				source: 'class Safe { public function get():Foo return null; } class Main { function run() { var Box = new Safe(); var v = Box.get(); v.name; } }'
			}
		]).length);
	}

	public function testSwitchNullCaseThenWildcardNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C { function f(m:Map<String,Foo>) { var u = m[k]; switch (u) { case null: return; case _: u.foo; } } }').length
		);
	}

	public function testSwitchNullCaseNonExitingNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C { function f(m:Map<String,Foo>) { var u = m[k]; switch (u) { case null: trace(0); case _: u.foo; } } }').length
		);
	}

	public function testCaseGuardNarrowsNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C { function f(m:Map<String,Foo>, x:Int) { var u = m[k]; switch (x) { case _ if (u != null): u.foo; } } }').length
		);
	}

	public function testNullAssertionNarrowsNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(m:Map<String,Foo>) { var u = m[k]; Assert.notNull(u); u.foo; } }').length);
	}

	public function testSwitchNoNullCaseFlagged(): Void {
		Assert.equals(1, violations('class C { function f(m:Map<String,Foo>) { var u = m[k]; switch (u) { case _: u.foo; } } }').length);
	}

	public function testNullReturnBindingFlagged(): Void {
		Assert.equals(
			1,
			violations('class C { function findUser(s:String):Null<Foo> { return null; } function g() { var u = findUser("x"); u.baz; } }').length
		);
	}

	public function testForceNavFlagged(): Void {
		Assert.equals(1, violations('class C { function f(m:Map<String,Foo>) { var u = m[k]; u!.foo; } }').length);
	}

	public function testIndexDerefFlagged(): Void {
		Assert.equals(1, violations('class C { function f(m:Map<String,Foo>) { var u = m[k]; u[0]; } }').length);
	}

	public function testBareCallFlagged(): Void {
		Assert.equals(
			1,
			violations('class C { function findUser(s:String):Null<Foo> { return null; } function g() { var u = findUser("x"); u(); } }').length
		);
	}

	public function testReassignBindingFlagged(): Void {
		Assert.equals(1, violations('class C { function f(m:Map<String,Int>) { var u = 0; u = m[k]; u.foo; } }').length);
	}

	public function testGuardedNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(m:Map<String,Int>) { var u = m[k]; if (u != null) u.foo; } }').length);
	}

	public function testEarlyReturnNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(m:Map<String,Int>) { var u = m[k]; if (u == null) return; u.foo; } }').length);
	}

	public function testShortCircuitNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(m:Map<String,Int>) { var u = m[k]; var ok = u != null && u.foo > 0; } }').length);
	}

	public function testReassignNonNullNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(m:Map<String,Foo>) { var u = m[k]; u = new Foo(); u.foo; } }').length);
	}

	public function testNullCoalesceAssignNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(m:Map<String,Foo>) { var u = m[k]; u ??= new Foo(); u.foo; } }').length);
	}

	public function testArrayIndexBindingNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(arr:Array<Int>) { var u = arr[i]; u.foo; } }').length);
	}

	public function testNonNullReturnBindingNotFlagged(): Void {
		Assert.equals(
			0, violations('class C { function getFoo():Foo { return null; } function g() { var u = getFoo(); u.bar(); } }').length
		);
	}

	public function testReassignUnknownNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C { function f(m:Map<String,Int>) { var u = m[k]; u = compute(); u.foo; } function compute() { return null; } }'
			).length
		);
	}

	public function testDerefInClosureNotFlagged(): Void {
		Assert.equals(
			0, violations('class C { function f(m:Map<String,Foo>) { var u = m[k]; var g = function() { return u.foo; }; } }').length
		);
	}

	public function testDirectExprReceiverNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(m:Map<String,Int>) { m[k].foo; } }').length);
	}

	public function testMultiBindingNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(m:Map<String,Int>) { var u = m[k], v = 1; u.foo; } }').length);
	}

	public function testParamNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(u:Foo) { u.foo; } }').length);
	}

	public function testFixReturnsEmpty(): Void {
		final src: String = 'class C { function f(m:Map<String,Int>) { var u = m[k]; u.foo; } }';
		final check: UnguardedNullableDeref = new UnguardedNullableDeref();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('unguarded-nullable-deref'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('unguarded-nullable-deref'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testExistsGuardSuppressed(): Void {
		// A `var u = m[k]` inside `if (m.exists(k))` is proven present — not seeded MaybeNull (feature 3).
		Assert.equals(
			0, violations('class C { function f(m:Map<String,Foo>, k:String) { if (m.exists(k)) { var u = m[k]; u.foo; } } }').length
		);
	}

	public function testExistsGuardKeyRewrittenFlagged(): Void {
		// Rewriting the key between the guard and the binding invalidates the present fact.
		Assert.equals(
			1,
			violations(
				'class C { function f(m:Map<String,Foo>, k:String) { if (m.exists(k)) { k = other(); var u = m[k]; u.foo; } } function other():String return ""; }'
			).length
		);
	}

	public function testExistsGuardMapRewrittenFlagged(): Void {
		// Rewriting the map between the guard and the binding invalidates the present fact.
		Assert.equals(
			1,
			violations(
				'class C { function f(m:Map<String,Foo>, k:String) { if (m.exists(k)) { m = other(); var u = m[k]; u.foo; } } function other():Map<String,Foo> return null; }'
			).length
		);
	}

	public function testExistsGuardWrongKeyFlagged(): Void {
		// The guard proves `k` present, not `k2` — a different-key binding is still seeded.
		Assert.equals(
			1,
			violations('class C { function f(m:Map<String,Foo>, k:String, k2:String) { if (m.exists(k)) { var u = m[k2]; u.foo; } } }').length
		);
	}

	public function testExistsGuardWrongMapFlagged(): Void {
		// The guard proves membership in `m`, not `m2` — a different-map binding is still seeded.
		Assert.equals(
			1,
			violations(
				'class C { function f(m:Map<String,Foo>, m2:Map<String,Foo>, k:String) { if (m.exists(k)) { var u = m2[k]; u.foo; } } }'
			).length
		);
	}

	// --- Relational assert narrowing (feature 1): Assert.isTrue(u != null) / Assert.isFalse(u == null) ---

	public function testAssertIsTrueBareNarrowsNotFlagged(): Void {
		// The truth-asserted `u != null` clears u's MaybeNull fact (maybe-only) — sibling of Assert.notNull.
		Assert.equals(0, violations('class C { function f(m:Map<String,Foo>) { var u = m[k]; Assert.isTrue(u != null); u.foo; } }').length);
	}

	public function testAssertIsFalseBareNarrowsNotFlagged(): Void {
		// `Assert.isFalse(u == null)` proves u non-null on the false outcome (the else-arm polarity).
		Assert.equals(
			0, violations('class C { function f(m:Map<String,Foo>) { var u = m[k]; Assert.isFalse(u == null); u.foo; } }').length
		);
	}

	public function testAssertIsTrueParenNarrowsNotFlagged(): Void {
		Assert.equals(
			0, violations('class C { function f(m:Map<String,Foo>) { var u = m[k]; Assert.isTrue((u != null)); u.foo; } }').length
		);
	}

	public function testAssertIsTrueNotWrapNarrowsNotFlagged(): Void {
		// `!(u == null)` = `u != null` via the De-Morgan `!` unwind in collectNarrow.
		Assert.equals(
			0, violations('class C { function f(m:Map<String,Foo>) { var u = m[k]; Assert.isTrue(!(u == null)); u.foo; } }').length
		);
	}

	public function testAssertUnknownMethodStillFlagged(): Void {
		// A method NOT in assertTrueCalls/assertFalseCalls narrows nothing (method-name gate).
		Assert.equals(1, violations('class C { function f(m:Map<String,Foo>) { var u = m[k]; Assert.thing(u != null); u.foo; } }').length);
	}

	public function testAssertIsTrueWrongPolarityStillFlagged(): Void {
		// `Assert.isTrue(u == null)` proves u IS null, not non-null — narrows nothing on the truth path.
		Assert.equals(1, violations('class C { function f(m:Map<String,Foo>) { var u = m[k]; Assert.isTrue(u == null); u.foo; } }').length);
	}

	public function testAssertIsFalseWrongPolarityStillFlagged(): Void {
		// `Assert.isFalse(u != null)` proves u IS null — narrows nothing.
		Assert.equals(
			1, violations('class C { function f(m:Map<String,Foo>) { var u = m[k]; Assert.isFalse(u != null); u.foo; } }').length
		);
	}

	public function testAssertIsTrueOrDisjunctStillFlagged(): Void {
		// A disjunction (`x || u != null`) in a truth assert proves no single operand — narrows nothing.
		Assert.equals(
			1,
			violations('class C { function f(m:Map<String,Foo>, x:Bool) { var u = m[k]; Assert.isTrue(x || u != null); u.foo; } }').length
		);
	}

	public function testAssertIsTrueReassignedStillFlagged(): Void {
		// A write after the assert re-seeds the nullable-source fact.
		Assert.equals(
			1, violations('class C { function f(m:Map<String,Foo>) { var u = m[k]; Assert.isTrue(u != null); u = m[k2]; u.foo; } }').length
		);
	}

	public function testAssertIsTrueInClosureNotLeaked(): Void {
		// An assert inside a nested function value never narrows the outer local.
		Assert.equals(
			1,
			violations(
				'class C { function f(m:Map<String,Foo>) { var u = m[k]; var g = function() { Assert.isTrue(u != null); return 0; }; u.foo; } }'
			).length
		);
	}

	public function testAssertIsTrueInTryNotLeakedToCatch(): Void {
		// The throw may fire before the assert, so its narrowing must not reach the catch clause.
		Assert.equals(
			1,
			violations(
				'class C { function f(m:Map<String,Foo>) { var u = m[k]; try { Assert.isTrue(u != null); } catch (e:Dynamic) { u.foo; } } }'
			).length
		);
	}

	public function testAssertIsTrueShadowConfined(): Void {
		// A shadow local's assert (`w`) narrows only w — the outer u, never asserted, stays flagged.
		Assert.equals(
			1,
			violations(
				'class C { function f(m:Map<String,Foo>) { var u = m[k]; { var w = m[k2]; Assert.isTrue(w != null); w.foo; } u.foo; } }'
			).length
		);
	}

	private function violations(src: String): Array<Violation> {
		return new UnguardedNullableDeref().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function violationsFiles(files: Array<{ file: String, source: String }>): Array<Violation> {
		return new UnguardedNullableDeref().run(files, new HaxeQueryPlugin());
	}

}
