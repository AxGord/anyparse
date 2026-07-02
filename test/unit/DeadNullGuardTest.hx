package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.DeadNullGuard;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `dead-null-guard` check: a null comparison whose operand is already
 * non-null **by flow** (a prior `!= null` guard narrowed it, or a non-null
 * assignment) on every path reaching it. Strictly the flow-only complement of
 * `unnecessary-null-check` — an operand the declared type already proves
 * non-null is left to that check. Conservative: a reassignment, a closure
 * capture, a loop back-edge, or a macro subtree all suppress the finding.
 */
class DeadNullGuardTest extends Test {

	public function testInnerGuardFlagged(): Void {
		// Outer guard narrows the optional `x`; the inner re-check is dead. Only the inner is flagged.
		Assert.equals(1, violations('class C { function f(?x:String) { if (x != null) { if (x != null) trace(x); } } }').length);
	}

	public function testEqNullAlsoFlagged(): Void {
		// `x == null` under a non-null path is constantly false — also dead.
		Assert.equals(1, violations('class C { function f(?x:String) { if (x != null) { if (x == null) trace(x); } } }').length);
	}

	public function testNonNullAssignmentFlagged(): Void {
		// A constructor assignment makes the nullable `x` non-null by flow.
		Assert.equals(1, violations('class C { function f(?x:Foo) { x = new Foo(); if (x != null) trace(x); } }').length);
	}

	public function testReassignmentKills(): Void {
		// A nullable reassignment between the narrowing guard and the inner check clears the fact.
		Assert.equals(0, violations('class C { function f(?x:String) { if (x != null) { x = mk(); if (x != null) trace(x); } } }').length);
	}

	public function testDeclaredNonNullNotFlagged(): Void {
		// `s:String` under `@:nullSafety` is non-null by declaration — owned by `unnecessary-null-check`, not this check.
		Assert.equals(
			0, violations('@:nullSafety(Strict) class C { function f(s:String) { if (s != null) { if (s != null) trace(s); } } }').length
		);
	}

	public function testClosureCaptureNotFlagged(): Void {
		// `x` is mutated inside a closure — never narrowable.
		Assert.equals(
			0,
			violations('class C { function f(?x:String) { var g = () -> x = null; if (x != null) { if (x != null) trace(x); } } }').length
		);
	}

	public function testLoopBackEdgeKills(): Void {
		// The loop reassigns `x`, so the narrowing from the outer guard cannot survive the back-edge.
		Assert.equals(
			0,
			violations('class C { function f(?x:String) { if (x != null) { while (cond()) { if (x != null) trace(x); x = mk(); } } } }').length
		);
	}

	public function testMacroSubtreeNotDescended(): Void {
		// A comparison inside a `macro { … }` reification is opaque — not analyzed.
		Assert.equals(
			0, violations('class C { function f(?x:String) { if (x != null) { var e = macro { if (x != null) trace(x); }; } } }').length
		);
	}

	public function testOuterGuardAloneNotFlagged(): Void {
		// A single legitimate guard on a nullable value is not redundant.
		Assert.equals(0, violations('class C { function f(?x:String) { if (x != null) trace(x); } }').length);
	}

	public function testFlaggedAsInfo(): Void {
		final vs: Array<Violation> = violations('class C { function f(?x:String) { if (x != null) { if (x != null) trace(x); } } }');
		Assert.equals(1, vs.length);
		Assert.equals('dead-null-guard', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testFixIsNoop(): Void {
		final check: DeadNullGuard = new DeadNullGuard();
		final src: String = 'class C { function f(?x:String) { if (x != null) { if (x != null) trace(x); } } }';
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin());
		Assert.equals(0, edits.length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0, new DeadNullGuard().run([{ file: 'Bad.hx', source: 'class Bad { function f() { if (x != ' }], new HaxeQueryPlugin()).length
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('dead-null-guard'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('dead-null-guard'));
	}

	/**
	 * After `if (x == null) return;` the fall-through path has x non-null.
	 */
	public function testEarlyReturnNarrowing(): Void {
		Assert.equals(1, violations('class C { function f(?x:String) { if (x == null) return; if (x != null) trace(x); } }').length);
	}

	/**
	 * Both arms assign a non-null value, so x is non-null after the if/else (join).
	 */
	public function testIfElseJoinNarrowing(): Void {
		Assert.equals(
			1,
			violations('class C { function f(?x:Foo) { if (c()) x = new Foo(); else x = new Foo(); if (x != null) trace(x); } }').length
		);
	}

	public function testAnonTypedDeclNarrows(): Void {
		// An anonymous-struct type annotation projects as a decl child before the init —
		// `NullFlow.declInit` must still see the constructor init and narrow the name.
		Assert.equals(1, violations('class C { function f():Void { var x:{ f:Int } = new Foo(); if (x != null) trace(x); } }').length);
	}

	public function testMultiBindingDeclNotNarrowed(): Void {
		// `var a = null, b = 's'` projects as ONE node — no init can be attributed to
		// `a`, so its fact collapses to Unknown and neither polarity fires.
		Assert.equals(0, violations("class C { function f():Void { var a = null, b = 's'; if (a != null) trace(a); } }").length);
	}

	public function testNestedFnLocalDoesNotHijackFieldWrite(): Void {
		// `x` is declared only inside the nested function — the outer bare write goes
		// to a same-named FIELD, which a call could mutate; it must not be narrowed.
		Assert.equals(
			0,
			violations(
				'class C { var x:Foo; function f():Void { function g():Void { var x = null; trace(x); } x = new Foo(); if (x != null) trace(x); g(); } }'
			).length
		);
	}

	public function testTryWriteNotTrustedInCatch(): Void {
		// `x` is narrowed before the try; the try body rewrites it before the call that may throw — the catch must not trust any try-body write.
		Assert.equals(
			0,
			violations(
				'class C { function f(?x:String) { x = "a"; try { x = null; risky(); } catch (e:haxe.Exception) { if (x != null) trace(x); } } }'
			).length
		);
	}

	public function testTryJoinCatchExits(): Void {
		// The catch returns, so only the completed-body path falls through — its narrowing survives.
		Assert.equals(
			1,
			violations(
				'class C { function f(?x:String) { try { x = "a"; } catch (e:haxe.Exception) { return; } if (x != null) trace(x); } }'
			).length
		);
	}

	public function testSwitchJoinWildcardDefault(): Void {
		// One case exits, the wildcard case narrows — every fall-through path has `x` non-null.
		Assert.equals(
			1,
			violations(
				'class C { function f(k:Int, ?x:String) { switch k { case 1: return; case _: x = "a"; } if (x != null) trace(x); } }'
			).length
		);
	}

	public function testSwitchWithoutDefaultNotNarrowed(): Void {
		// No default and no wildcard: a subject matching no case falls through un-narrowed.
		Assert.equals(
			0,
			violations(
				'class C { function f(k:Int, ?x:String) { switch k { case 1: return; case 2: x = "a"; } if (x != null) trace(x); } }'
			).length
		);
	}

	public function testContinueExitNarrows(): Void {
		// `continue` exits the arm — the rest of the iteration only runs with `x` non-null.
		Assert.equals(
			1,
			violations('class C { function f(c:Bool, ?x:String) { while (c) { if (x == null) continue; if (x != null) trace(x); } } }').length
		);
	}

	public function testBreakStateDoesNotLeakPastLoop(): Void {
		// The engine never propagates loop-body facts outward (the body runs on a discarded copy) —
		// pinned because the break path escaping with `x` null is the semantic counter-example
		// against any future join of body-end state into the post-loop state.
		Assert.equals(
			0,
			violations('class C { function f(c:Bool, ?x:String) { while (c) { if (x == null) break; } if (x == null) trace(1); } }').length
		);
	}

	public function testNullCoalAssignNarrows(): Void {
		// `x ??= "d"` leaves `x` non-null whichever side survives.
		Assert.equals(1, violations('class C { function f(?x:String) { x ??= "d"; if (x != null) trace(x); } }').length);
	}

	public function testSwitchJoinDefaultKeyword(): Void {
		// The `default:` keyword branch is exhaustive like the wildcard — every fall-through path narrows.
		Assert.equals(
			1,
			violations(
				'class C { function f(k:Int, ?x:String) { switch k { case 1: return; default: x = "a"; } if (x != null) trace(x); } }'
			).length
		);
	}

	public function testSwitchBlockArmExitCounts(): Void {
		// A branch whose last statement is a nested block ending in `return` exits — armExits recurses into blocks.
		Assert.equals(
			1,
			violations(
				'class C { function f(k:Int, ?x:String) { switch k { case 1: { trace(1); return; } case _: x = "a"; } if (x != null) trace(x); } }'
			).length
		);
	}

	public function testBreakExitNarrows(): Void {
		// `break` exits the arm — the rest of the iteration only runs with `x` non-null.
		Assert.equals(
			1,
			violations('class C { function f(c:Bool, ?x:String) { while (c) { if (x == null) break; if (x != null) trace(x); } } }').length
		);
	}

	public function testGuardedWildcardNotExhaustive(): Void {
		// `case _ if (c):` can still fail to match — the no-branch-matched path stays in the join.
		Assert.equals(
			0,
			violations(
				'class C { function f(k:Int, c:Bool, ?x:String) { switch k { case 1: x = "a"; case _ if (c): x = "b"; } if (x != null) trace(x); } }'
			).length
		);
	}

	public function testGuardedCommaWildcardNotExhaustive(): Void {
		// `case _, 4 if (c):` carries a guard past the comma alternatives — still not exhaustive.
		Assert.equals(
			0,
			violations(
				'class C { function f(k:Int, c:Bool, ?x:String) { switch k { case 1: x = "a"; case _, 4 if (c): x = "b"; } if (x != null) trace(x); } }'
			).length
		);
	}

	public function testShortCircuitAndRhsWriteNotFlagged(): Void {
		// The `&&` right side runs only when c is true — its write is one path, so the guard after is live.
		Assert.equals(
			0,
			violations('class C { function f(c:Bool) { var x = null; var ok = c && (x = "v") != null; if (x != null) trace(x); } }').length
		);
	}

	public function testShortCircuitOrRhsWriteNotFlagged(): Void {
		// The `||` mirror: the right side runs only when c is false.
		Assert.equals(
			0,
			violations('class C { function f(c:Bool) { var x = null; var ok = c || (x = "v") != null; if (x != null) trace(x); } }').length
		);
	}

	public function testDuplicateConjunctFlagged(): Void {
		// The second conjunct sees the first one's narrowing — `x != null && x != null` is dead.
		Assert.equals(1, violations('class C { function f(?x:String) { if (x != null && x != null) trace(x); } }').length);
	}

	public function testCondWriteStaleNarrowingNotFlagged(): Void {
		// The condition writes x after comparing it — its narrowing is stale, the inner guard is live.
		Assert.equals(
			0,
			violations('class C { function f(?x:String) { if (x != null && (x = null) == null) { if (x != null) trace(x); } } }').length
		);
	}

	public function testNullCoalFallbackWriteIsConditional(): Void {
		// A `??` fallback runs only when the left side is null — its write is one path.
		Assert.equals(
			0,
			violations('class C { function f(a:Null<String>) { var x = null; var r = a ?? (x = "v"); if (x == null) trace(r); } }').length
		);
	}

	public function testMetaArgWriteNotExecuted(): Void {
		// A metadata argument never runs — `@:m(x = "v")` must not mark x non-null.
		Assert.equals(0, violations('class C { function f() { var x = null; @:m(x = "v") trace(1); if (x != null) trace(2); } }').length);
	}

	private function violations(src: String): Array<Violation> {
		return new DeadNullGuard().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
