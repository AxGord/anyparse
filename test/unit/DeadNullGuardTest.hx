package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.DeadNullGuard;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;

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

	public function testFixUnwrapBody(): Void {
		assertFixContains(wrapFoo('if (x != null) x.g();'), 'x.g();', 'if (x != null)');
	}

	public function testFixDeleteAlwaysFalse(): Void {
		assertFixContains(wrapFoo('if (x == null) x.g();\n\t\ttrace("keep");'), 'trace("keep")', 'x.g()');
	}

	public function testFixDropConjunct(): Void {
		assertFixContains(wrapFoo('if (x != null && cond()) x.g();'), 'if (cond())', 'x != null');
	}

	public function testFixDropDisjunct(): Void {
		assertFixContains(wrapFoo('if (x == null || cond()) x.g();'), 'if (cond())', 'x == null');
	}

	public function testFixChainConjunct(): Void {
		assertFixContains(wrapFoo('if (cond() && x != null && cond()) x.g();'), 'if (cond() && cond())', 'x != null');
	}

	public function testFixBlockBodyKeepsBraces(): Void {
		assertFixContains(wrapFoo('if (x != null) {\n\t\t\tx.g();\n\t\t\tx.g();\n\t\t}'), 'x.g();', 'if (x != null)');
	}

	public function testFixNestedNarrowKeepsOuterGuard(): Void {
		// The dead INNER guard is unwrapped; the load-bearing OUTER guard on the nullable
		// param survives — exactly one `if (x != null)` remains, control flow intact.
		final out: String = fixText(
			'class C {\n\tfunction f(?x:String):Void {\n\t\tif (x != null) {\n\t\t\tif (x != null) trace(x);\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, countStr(out, 'if (x != null)'));
		Assert.isTrue(out.indexOf('trace(x)') >= 0);
	}

	public function testFixDeleteAsBranchBodyToEmptyBlock(): Void {
		// A no-else `if (x == null)` that is the single-statement body of an enclosing `if`
		// becomes `{}` (a bare delete would orphan the branch and swallow the next statement).
		assertFixContains(wrapFoo('if (cond()) if (x == null) x.g();\n\t\ttrace("keep");'), 'if (cond()) {}', 'x.g()');
	}

	public function testFixRefusesElse(): Void {
		assertFixRefused(wrapFoo('if (x != null) x.g(); else cond();'));
	}

	public function testFixRefusesTernary(): Void {
		assertFixRefused(wrapFoo('final b:Int = x != null ? 1 : 2;\n\t\ttrace(b);'));
	}

	public function testFixRefusesExprPosition(): Void {
		assertFixRefused(wrapFoo('final b:Bool = x != null;\n\t\ttrace(b);'));
	}

	public function testFixRefusesAbsorbingTrueInOr(): Void {
		// `true || cond()` is constantly true — dropping the disjunct would change the value.
		assertFixRefused(wrapFoo('if (x != null || cond()) x.g();'));
	}

	public function testFixRefusesAbsorbingFalseInAnd(): Void {
		// `false && cond()` is constantly false — dropping the conjunct would change the value.
		assertFixRefused(wrapFoo('if (x == null && cond()) x.g();'));
	}

	public function testFixRefusesMixedNesting(): Void {
		assertFixRefused(wrapFoo('if (cond() || (x != null && cond())) x.g();'));
	}

	public function testFixRefusesParenWrapped(): Void {
		assertFixRefused(wrapFoo('if ((x != null) && cond()) x.g();'));
	}

	public function testFixRefusesCommentBetweenIfAndBody(): Void {
		assertFixRefused(wrapFoo('if (x != null) /* keep */ x.g();'));
	}

	public function testFixRefusesCommentInDeletedBody(): Void {
		assertFixRefused(wrapFoo('if (x == null) {\n\t\t\t// note\n\t\t\tx.g();\n\t\t}'));
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
			1, violations('class C { function f(?x:Foo) { if (c()) x = new Foo(); else x = new Foo(); if (x != null) trace(x); } }').length
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
			0, violations('class C { function f(?x:String) { if (x != null && (x = null) == null) { if (x != null) trace(x); } } }').length
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

	public function testLaunderedGuardFlagged(): Void {
		// `var ok = u != null; if (ok)` narrows u non-null in the then-arm — the inner re-check is dead (feature 1).
		Assert.equals(
			1, violations('class C { function f(?u:String) { var ok = u != null; if (ok) { if (u != null) trace(u); } } }').length
		);
	}

	public function testLaunderedGuardElseArmFlagged(): Void {
		// `var ok = u == null; if (ok) {} else` narrows u non-null in the else-arm (De Morgan).
		Assert.equals(
			1, violations('class C { function f(?u:String) { var ok = u == null; if (ok) {} else { if (u != null) trace(u); } } }').length
		);
	}

	public function testLaunderedGuardShortCircuitConjunct(): Void {
		// The laundered fact also feeds the `&&` right side: the second conjunct is dead.
		Assert.equals(1, violations('class C { function f(?u:String) { var ok = u != null; if (ok && u != null) trace(u); } }').length);
	}

	public function testLaunderedGuardWriteTargetKills(): Void {
		// A reassignment of the compared value after the predicate is captured makes the fact stale.
		Assert.equals(
			0,
			violations(
				'class C { function f(?u:String) { var ok = u != null; u = mk(); if (ok) { if (u != null) trace(u); } } function mk():String return null; }'
			).length
		);
	}

	public function testLaunderedGuardWriteBoolKills(): Void {
		// Rewriting the Bool to another value drops the predicate.
		Assert.equals(
			0,
			violations(
				'class C { function f(?u:String) { var ok = u != null; ok = cond(); if (ok) { if (u != null) trace(u); } } function cond():Bool return true; }'
			).length
		);
	}

	public function testLaunderedGuardCaptureNotFlagged(): Void {
		// The compared value is mutated in a closure — never narrowable, so no predicate is formed.
		Assert.equals(
			0,
			violations(
				'class C { function f(?u:String) { var g = () -> u = null; var ok = u != null; if (ok) { if (u != null) trace(u); } g(); } }'
			).length
		);
	}

	public function testLaunderedTransitiveFlagged(): Void {
		// Feature 1: `var ok2 = ok` aliases the two Bools; the laundered predicate flows
		// transitively through the alias, so a guard on `ok2` narrows `u` — the inner check is dead.
		Assert.equals(
			1,
			violations('class C { function f(?u:String) { var ok = u != null; var ok2 = ok; if (ok2) { if (u != null) trace(u); } } }').length
		);
	}

	public function testLaunderedCompositeRhsNotFlagged(): Void {
		// A composite Bool (`u != null || c`) is not a pure null-comparison — no predicate.
		Assert.equals(
			0,
			violations(
				'class C { function f(?u:String) { var ok = u != null || cond(); if (ok) { if (u != null) trace(u); } } function cond():Bool return true; }'
			).length
		);
	}

	public function testAliasGuardFlagged(): Void {
		// `var v = u` aliases the two — a guard on v narrows u, so the inner check on u is dead (feature 2).
		Assert.equals(1, violations('class C { function f(?u:String) { var v = u; if (v != null) { if (u != null) trace(u); } } }').length);
	}

	public function testAliasReverseGuardFlagged(): Void {
		// The alias is bidirectional — a guard on u narrows v.
		Assert.equals(1, violations('class C { function f(?u:String) { var v = u; if (u != null) { if (v != null) trace(v); } } }').length);
	}

	public function testAliasWriteTargetKills(): Void {
		// A reassignment of either aliased side severs the pair.
		Assert.equals(
			0,
			violations(
				'class C { function f(?u:String) { var v = u; u = mk(); if (v != null) { if (u != null) trace(u); } } function mk():String return null; }'
			).length
		);
	}

	public function testAliasReAliasKills(): Void {
		// Reassigning v (a call result) severs the original (v, u) pair via the write kill.
		Assert.equals(
			0,
			violations(
				'class C { function f(?u:String) { var v = u; v = mk(); if (v != null) { if (u != null) trace(u); } } function mk():String return null; }'
			).length
		);
	}

	public function testAliasFieldRhsNotFlagged(): Void {
		// `var v = u.length` is a field access, not a plain ident copy — no alias, so u is not narrowed.
		Assert.equals(
			0, violations('class C { function f(?u:String) { var v = u.length; if (v != null) { if (u != null) trace(u); } } }').length
		);
	}

	public function testAliasNullCoalAssignKills(): Void {
		// `u ??= "x"` may reassign u, so the (v, u) alias is stale — the v guard is LIVE
		// (v keeps the old null while u becomes "x"). Reviewer-caught: the `??=` non-null
		// path must sever aux facts like every other write.
		Assert.equals(
			0,
			violations(
				'class C { function f(?u:String, cond:Bool) { var v = u; if (cond) { u ??= "x"; } if (u != null) { if (v != null) trace(v); } } }'
			).length
		);
	}

	public function testLaunderedTransitiveChainFlagged(): Void {
		// Feature 1: a 3-deep Bool alias chain (`ok3 = ok2 = ok`) still reaches the predicate.
		Assert.equals(
			1,
			violations(
				'class C { function f(?u:String) { var ok = u != null; var ok2 = ok; var ok3 = ok2; if (ok3) { if (u != null) trace(u); } } }'
			).length
		);
	}

	public function testLaunderedTransitiveReassignAliasKills(): Void {
		// Reassigning the alias Bool (`ok2 = cond()`) severs the (ok2, ok) pair — no transitive reach.
		Assert.equals(
			0,
			violations(
				'class C { function f(?u:String) { var ok = u != null; var ok2 = ok; ok2 = cond(); if (ok2) { if (u != null) trace(u); } } function cond():Bool return true; }'
			).length
		);
	}

	public function testLaunderedTransitiveWritePredicateBoolKills(): Void {
		// Rewriting the source Bool (`ok = cond()`) drops its predicate AND the (ok2, ok) alias.
		Assert.equals(
			0,
			violations(
				'class C { function f(?u:String) { var ok = u != null; var ok2 = ok; ok = cond(); if (ok2) { if (u != null) trace(u); } } function cond():Bool return true; }'
			).length
		);
	}

	public function testLaunderedTransitiveWriteTargetKills(): Void {
		// Writing the compared value `u` between seed and guard kills the predicate; the alias alone narrows nothing.
		Assert.equals(
			0,
			violations(
				'class C { function f(?u:String) { var ok = u != null; var ok2 = ok; u = mk(); if (ok2) { if (u != null) trace(u); } } function mk():String return null; }'
			).length
		);
	}

	public function testLaunderedTransitiveShadowKills(): Void {
		// An inner `var ok = cond()` shadows the outer laundered Bool and clears its predicate — no leak into the shadow.
		Assert.equals(
			0,
			violations(
				'class C { function f(?u:String) { var ok = u != null; if (cond()) { var ok = cond(); if (ok) { if (u != null) trace(u); } } } function cond():Bool return true; }'
			).length
		);
	}

	public function testCompoundPredicateFlagged(): Void {
		// Feature 2: `ok = u != null && cond()` ⇒ ok true implies u != null, so the then-arm narrows u.
		Assert.equals(
			1,
			violations(
				'class C { function f(?u:String) { var ok = u != null && cond(); if (ok) { if (u != null) trace(u); } } function cond():Bool return true; }'
			).length
		);
	}

	public function testCompoundPredicateMultipleConjunctsFlagged(): Void {
		// Feature 2: each null-check conjunct of the compound Bool narrows its own target.
		Assert.equals(
			2,
			violations(
				'class C { function f(?u:String, ?v:String) { var ok = u != null && v != null; if (ok) { if (u != null) trace(u); if (v != null) trace(v); } } }'
			).length
		);
	}

	public function testCompoundPredicateElseNotFlagged(): Void {
		// Feature 2 KEY negative: ok false ⇒ some conjunct false, but WHICH is unknown, so the
		// else-arm narrows nothing — the De Morgan mirror is unsound for a compound predicate.
		Assert.equals(
			0,
			violations(
				'class C { function f(?u:String) { var ok = u != null && cond(); if (ok) trace(0) else { if (u != null) trace(u); } } function cond():Bool return true; }'
			).length
		);
	}

	public function testCompoundPredicateNestedOrRefused(): Void {
		// Any `||` anywhere in the RHS refuses the whole compound predicate (conservative).
		Assert.equals(
			0,
			violations(
				'class C { function f(?u:String) { var ok = u != null && (cond() || cond()); if (ok) { if (u != null) trace(u); } } function cond():Bool return true; }'
			).length
		);
	}

	public function testCompoundPredicateWriteTargetKills(): Void {
		// Writing a conjunct target after the seed severs its predicate.
		Assert.equals(
			0,
			violations(
				'class C { function f(?u:String) { var ok = u != null && cond(); u = mk(); if (ok) { if (u != null) trace(u); } } function cond():Bool return true; function mk():String return null; }'
			).length
		);
	}

	public function testCompoundPredicateReassignBoolKills(): Void {
		// Reassigning the compound Bool drops all its predicates.
		Assert.equals(
			0,
			violations(
				'class C { function f(?u:String) { var ok = u != null && cond(); ok = cond(); if (ok) { if (u != null) trace(u); } } function cond():Bool return true; }'
			).length
		);
	}

	public function testCompoundPredicateCaptureNotFlagged(): Void {
		// A conjunct target mutated in a closure is never narrowable, so no compound predicate forms for it.
		Assert.equals(
			0,
			violations(
				'class C { function f(?u:String) { var g = () -> u = null; var ok = u != null && cond(); if (ok) { if (u != null) trace(u); } g(); } function cond():Bool return true; }'
			).length
		);
	}

	public function testCompoundPredicateLoopBackEdgeKills(): Void {
		// The loop reassigns u, so the compound predicate cannot survive the back-edge.
		Assert.equals(
			0,
			violations(
				'class C { function f(?u:String) { var ok = u != null && cond(); while (cond()) { if (ok) { if (u != null) trace(u); } u = mk(); } } function cond():Bool return true; function mk():String return null; }'
			).length
		);
	}

	public function testCompoundPredicateMultiBindingNotFlagged(): Void {
		// A multi-binding declaration cannot attribute its init to the name — no compound predicate.
		Assert.equals(
			0,
			violations(
				'class C { function f(?u:String) { var ok = u != null && cond(), junk = 1; if (ok) { if (u != null) trace(u); } } function cond():Bool return true; }'
			).length
		);
	}

	public function testCompoundPredicateConjunctSideEffect(): Void {
		// A side-effecting conjunct (`(v = mk()) != null`) is not a plain ident-null compare, so
		// only the plain `u != null` conjunct seeds the predicate — short-circuit order is sound.
		Assert.equals(
			1,
			violations(
				'class C { function f(?u:String, ?v:String) { var ok = (v = mk()) != null && u != null; if (ok) { if (u != null) trace(u); } } function mk():String return null; }'
			).length
		);
	}

	public function testNotWrappedEqNullThenFlagged(): Void {
		// Feature 3: `if (!(u == null))` — the then-arm proves u non-null (double-negated == null).
		Assert.equals(1, violations('class C { function f(?u:String) { if (!(u == null)) { if (u != null) trace(u); } } }').length);
	}

	public function testNotWrappedNeqNullElseFlagged(): Void {
		// Feature 3: `if (!(u != null))` — the ELSE-arm proves u non-null (negated != null).
		Assert.equals(
			1, violations('class C { function f(?u:String) { if (!(u != null)) trace(0) else { if (u != null) trace(u); } } }').length
		);
	}

	public function testDoubleNotFlagged(): Void {
		// Feature 3: `!(!(u != null))` collapses to `u != null` — the then-arm narrows u.
		Assert.equals(1, violations('class C { function f(?u:String) { if (!(!(u != null))) { if (u != null) trace(u); } } }').length);
	}

	public function testNotWrappedEqNullElseNotFlagged(): Void {
		// Feature 3 negative: the else-arm of `if (!(u == null))` proves u NULL, not non-null — not a dead != guard.
		Assert.equals(
			0, violations('class C { function f(?u:String) { if (!(u == null)) trace(0) else { if (u != null) trace(u); } } }').length
		);
	}

	public function testNotWrappedConjunctionNoNarrow(): Void {
		// Feature 3 soundness: `!(u == null && v == null)` = `u != null || v != null` — a disjunction
		// proves NEITHER operand non-null on the then-arm, so no narrowing.
		Assert.equals(
			0,
			violations('class C { function f(?u:String, ?v:String) { if (!(u == null && v == null)) { if (u != null) trace(u); } } }').length
		);
	}

	public function testCompoundPredicateSelfWriteTargetNotFlagged(): Void {
		// Adversarial-review hole (fixed): a conjunct target ALSO written elsewhere in the same
		// RHS (`u != null && (u = mk()) == null`) must NOT seed the compound predicate — `ok`
		// reflects the pre-write `u`. establishCompoundPredicates excludes RHS-written targets.
		Assert.equals(
			0,
			violations(
				'class C { function f(?u:String) { var ok = u != null && (u = mk()) == null; if (ok) { if (u != null) trace(u); } } function mk():String return null; }'
			).length
		);
	}

	/** A self-contained module: a non-null `Foo` local `x`, plus a `cond()` helper, wrapping `body`. */
	private function wrapFoo(body: String): String {
		return 'class Foo {\n\tpublic function new() {}\n\tpublic function g():Void {}\n}\n\n'
			+ '@:nullSafety(Strict)\nclass C {\n\tfunction cond():Bool\n\t\treturn true;\n\n'
			+ '\tfunction f():Void {\n\t\tvar x = new Foo();\n\t\t' + body + '\n\t}\n}\n';
	}

	/** Run + fix + canonicalise (whole-file reformat) `src`, returning the emitted text. */
	private function fixText(src: String): String {
		final check: DeadNullGuard = new DeadNullGuard();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		return switch RefactorSupport.canonicalize(src, check.fix(src, vs, new HaxeQueryPlugin()), true, new HaxeQueryPlugin()) {
			case Ok(text): text;
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
				src;
		};
	}

	/** The fixed text of `src` contains `present` and no longer contains `absent`. */
	private function assertFixContains(src: String, present: String, absent: String): Void {
		final out: String = fixText(src);
		Assert.isTrue(out.indexOf(present) >= 0, 'expected "$present" in: $out');
		Assert.isTrue(out.indexOf(absent) == -1, 'expected NOT "$absent" in: $out');
	}

	/** `src` is flagged by `run` but produces no fix edit — a conservative refusal. */
	private function assertFixRefused(src: String): Void {
		final check: DeadNullGuard = new DeadNullGuard();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.isTrue(vs.length > 0, 'expected a finding to exist');
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	/** Count non-overlapping occurrences of `needle` in `hay`. */
	private function countStr(hay: String, needle: String): Int {
		var n: Int = 0;
		var i: Int = 0;
		while (true) {
			final at: Int = hay.indexOf(needle, i);
			if (at < 0) break;
			n++;
			i = at + needle.length;
		}
		return n;
	}

	private function violations(src: String): Array<Violation> {
		return new DeadNullGuard().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
