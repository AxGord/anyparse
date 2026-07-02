package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.AlwaysNullComparison;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `always-null-comparison` check: a null comparison whose operand is
 * provably **null** by flow on every path reaching it — `== null` is always
 * true, `!= null` always false. The mirror of `dead-null-guard` (the non-null
 * operand). Null-ness is established only by flow events (`x = null`, the
 * `== null` arm of a guard). Conservative: a reassignment, a closure capture, a
 * loop back-edge, or a macro subtree all suppress the finding.
 */
class AlwaysNullComparisonTest extends Test {

	public function testNullDeclThenEqFlagged(): Void {
		// `var x = null` makes x known-null; `x == null` is constantly true.
		Assert.equals(1, violations('class C { function f() { var x = null; if (x == null) trace(1); } }').length);
	}

	public function testNullDeclThenNeqFlagged(): Void {
		// `x != null` on a known-null x is constantly false.
		Assert.equals(1, violations('class C { function f() { var x = null; var y = x != null; } }').length);
	}

	public function testInnerGuardOnKnownNullFlagged(): Void {
		// The outer `== null` arm narrows x to null; the inner re-check is constant.
		Assert.equals(1, violations('class C { function f(?x:String) { if (x == null) { if (x == null) trace(1); } } }').length);
	}

	public function testReassignmentKills(): Void {
		// An unknown reassignment between the null decl and the check clears the fact.
		Assert.equals(0, violations('class C { function f() { var x = null; x = mk(); if (x == null) trace(1); } }').length);
	}

	public function testNonNullAssignmentNotFlagged(): Void {
		// A constructor assignment makes x non-null — owned by `dead-null-guard`, not this check.
		Assert.equals(0, violations('class C { function f() { var x = null; x = new Foo(); if (x == null) trace(1); } }').length);
	}

	public function testClosureCaptureNotFlagged(): Void {
		// x is mutated inside a closure — never narrowable on either polarity.
		Assert.equals(0, violations('class C { function f() { var x = null; var g = () -> x = mk(); if (x == null) trace(1); } }').length);
	}

	public function testLoopBackEdgeKills(): Void {
		// The loop reassigns x, so the known-null fact cannot survive the back-edge.
		Assert.equals(
			0, violations('class C { function f() { var x = null; while (cond()) { if (x == null) trace(1); x = mk(); } } }').length
		);
	}

	public function testMacroSubtreeNotDescended(): Void {
		// A comparison inside a `macro { … }` reification is opaque — not analyzed.
		Assert.equals(0, violations('class C { function f() { var x = null; var e = macro { if (x == null) trace(1); }; } }').length);
	}

	public function testUnknownOperandNotFlagged(): Void {
		// A plain nullable param with no flow evidence is neither null nor non-null.
		Assert.equals(0, violations('class C { function f(?x:String) { if (x == null) trace(1); } }').length);
	}

	public function testIfElseJoinNarrowing(): Void {
		// Both arms assign null, so x is known-null after the if/else (join).
		Assert.equals(1, violations('class C { function f(?x:Foo) { if (c()) x = null; else x = null; if (x == null) trace(1); } }').length);
	}

	public function testAlwaysTrueMessage(): Void {
		final vs: Array<Violation> = violations('class C { function f() { var x = null; if (x == null) trace(1); } }');
		Assert.equals(1, vs.length);
		Assert.equals('always-null-comparison', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.isTrue(StringTools.contains(vs[0].message, 'always true'));
	}

	public function testAlwaysFalseMessage(): Void {
		final vs: Array<Violation> = violations('class C { function f() { var x = null; var y = x != null; } }');
		Assert.equals(1, vs.length);
		Assert.isTrue(StringTools.contains(vs[0].message, 'always false'));
	}

	public function testFixIsNoop(): Void {
		final check: AlwaysNullComparison = new AlwaysNullComparison();
		final src: String = 'class C { function f() { var x = null; if (x == null) trace(1); } }';
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin());
		Assert.equals(0, edits.length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0,
			new AlwaysNullComparison().run(
				[{ file: 'Bad.hx', source: 'class Bad { function f() { var x = null; if (x == ' }], new HaxeQueryPlugin()
			)
				.length
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('always-null-comparison'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('always-null-comparison'));
	}

	public function testSwitchCaseWriteDoesNotLeak(): Void {
		// A `p = null` in one switch case must not narrow a sibling case's read —
		// switch branches are mutually exclusive. Regression: the bare switch kinds
		// were missing from the branchy set, so cases shared one running state.
		Assert.equals(
			0,
			violations(
				'class C { function f(p:Foo, x:Int):Int { switch x { case 0: p = null; case _: if (p != null) return 1; } return 0; } }'
			).length
		);
	}

	public function testCapturedVarNotNarrowed(): Void {
		// A captured outer variable mutated inside a nested function is never
		// narrowed in that function — a (recursive) call could change it. Regression
		// for the nested-walk false positive.
		Assert.equals(
			0,
			violations(
				'class C { function f(root:Node):Void { var result = null; function walk(n:Node):Void { if (result != null) return; if (n.match) { result = mk(); return; } for (c in n.kids) { if (result != null) return; walk(c); } } walk(root); } }'
			).length
		);
	}

	public function testTryWriteNotTrustedInCatch(): Void {
		// The body overwrote the known-null `x` before the call that may throw — the catch must not report always-true.
		Assert.equals(
			0,
			violations(
				'class C { function f() { var x:Null<String> = null; try { x = "a"; risky(); } catch (e:haxe.Exception) { if (x == null) trace(1); } } }'
			).length
		);
	}

	public function testCaseShadowDeclDoesNotLeak(): Void {
		// The case body is not block-wrapped — the inner shadow declaration's null fact must be dropped at branch exit.
		Assert.equals(
			0,
			violations(
				'class C { function f(o:Int) { var v:Null<String> = "s"; switch o { case 1: var v:Null<String> = null; trace(v); case _: v = null; } if (v == null) trace(1); } }'
			).length
		);
	}

	public function testCaptureWriteDoesNotLeak(): Void {
		// `case Some(v): v = null;` writes the INNER capture — the outer `v` is untouched on that path.
		Assert.equals(
			0,
			violations(
				'enum E { Some(s:String); None; } class C { function f(o:E) { var v:Null<String> = "s"; switch o { case Some(v): v = null; case _: v = null; } if (v == null) trace(1); } }'
			).length
		);
	}

	public function testCatchVarWriteDoesNotLeak(): Void {
		// A write to the catch variable inside the clause targets the inner binding, not the outer `e`.
		Assert.equals(
			0,
			violations(
				'class C { function f() { var e:Null<String> = null; try { e = "s"; mayThrow(); e = null; } catch (e:haxe.Exception) { trace(e); } if (e == null) trace(1); } }'
			).length
		);
	}

	public function testCoalAssignRhsIsConditional(): Void {
		// The `??=` right-hand side runs only when the target is null — its write to `y` may not have happened.
		Assert.equals(
			0,
			violations('class C { function f(?x:String) { var y:Null<String> = "s"; x ??= { y = null; "d"; }; if (y == null) trace(1); } }').length
		);
	}

	public function testUnbracedIfArmDeclDoesNotLeak(): Void {
		// `if (c) var v = null;` declares a shadow in an unbraced arm — its fact must not survive the join.
		Assert.equals(
			0,
			violations(
				'class C { function f(c:Bool) { var v:Null<String> = "s"; if (c) var v:Null<String> = null; else v = null; if (v == null) trace(1); } }'
			).length
		);
	}

	private function violations(src: String): Array<Violation> {
		return new AlwaysNullComparison().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
