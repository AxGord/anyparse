package unit;

import anyparse.check.Check;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.WhileTrueCondition;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `while-true-condition` check: a `while (true)` whose ONLY exit is a `break` dominating the
 * top of the body has that exit condition lifted into the loop header. Three forms of one rewrite
 * — (a) a leading `if (C) break;` guard, (b) `if (C) { A } else { B; break; }`, and (c) its mirror.
 *
 * The REFUSALS carry the census the rule was measured against, and they outnumber the target. Of
 * the seven `while (true)` in the reference corpus, five are LOOP-AND-A-HALF loops whose condition
 * is COMPUTED in the body before the break (or which exit by `return` and never break at all);
 * every one of them is rejected by the position gate alone — the break-carrying `if` is not the
 * first statement of the body — and `testLoopAndAHalf*` reproduce those shapes.
 *
 * The other refusals are the flow gates: a `break` of this loop in the KEPT branch (which would
 * newly run the lifted statements), a second jump in the exiting branch, an `else if` chain in the
 * exiting position, and both branches breaking. The `break`-in-a-`switch` case is the one that
 * cannot be reasoned out from C / JS habits: in Haxe that `break` leaves the LOOP, so it must
 * refuse exactly as a bare one does — while a `break` in a nested loop binds there and does not.
 */
class WhileTrueConditionCheckTest extends Test {

	public function testFormBFlagged(): Void {
		final vs: Array<Violation> = violations(fn('while (true) if (c) {\n\t\t\tg();\n\t\t} else {\n\t\t\th();\n\t\t\tbreak;\n\t\t}'));
		Assert.equals(1, vs.length);
		Assert.equals('while-true-condition', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this while (true) can lift its break condition into the loop header', vs[0].message);
	}

	public function testFormBFixed(): Void {
		Assert.equals(
			fn('while (c) {\n\t\t\tg();\n\t\t}\nh();'),
			applyFix(fn('while (true) if (c) {\n\t\t\tg();\n\t\t} else {\n\t\t\th();\n\t\t\tbreak;\n\t\t}'))
		);
	}

	public function testFormAFixed(): Void {
		Assert.equals(fn('while (!c) {\n\t\t\tg();\n\t\t}'), applyFix(fn('while (true) {\n\t\t\tif (c) break;\n\t\t\tg();\n\t\t}')));
	}

	public function testFormAWithLiftedRunFixed(): Void {
		// The generalised (a): a braced guard whose statements before the `break` lift out too.
		Assert.equals(
			fn('while (!c) {\n\t\t\tg();\n\t\t}\nh();'),
			applyFix(fn('while (true) {\n\t\t\tif (c) {\n\t\t\t\th();\n\t\t\t\tbreak;\n\t\t\t}\n\t\t\tg();\n\t\t}'))
		);
	}

	public function testFormCFixed(): Void {
		Assert.equals(
			fn('while (!c) {\n\t\t\tg();\n\t\t}\nh();'),
			applyFix(fn('while (true) if (c) {\n\t\t\th();\n\t\t\tbreak;\n\t\t} else {\n\t\t\tg();\n\t\t}'))
		);
	}

	public function testBinarySearchIdiomFixed(): Void {
		// The corpus shape the rule exists for, anonymised: a bisect loop whose `else` finishes the
		// job and breaks, with the trailing comment on the `break` that the lift must carry.
		final before: String = 'while (true) if (Math.abs(hi - lo) > 2) {\n\t\t\tmid = Std.int((lo + hi) / 2);'
			+ '\n\t\t\tlines = render(mid);\n\t\t\tif (lines > max)\n\t\t\t\thi = mid;\n\t\t\telse\n\t\t\t\tlo = mid;'
			+ '\n\t\t} else {\n\t\t\tdo {\n\t\t\t\trender(hi);\n\t\t\t\thi--;'
			+ '\n\t\t\t} while (hi >= 0 && lines > max);\n\t\t\tcut = hi;\n\t\t\tbreak; // done\n\t\t}';
		final after: String = 'while (Math.abs(hi - lo) > 2) {\n\t\t\tmid = Std.int((lo + hi) / 2);\n\t\t\tlines = render(mid);\n'
			+ '\t\t\tif (lines > max)\n\t\t\t\thi = mid;\n\t\t\telse\n\t\t\t\tlo = mid;\n\t\t}\ndo {\n\t\t\t\trender(hi);\n'
			+ '\t\t\t\thi--;\n\t\t\t} while (hi >= 0 && lines > max);\n\t\t\tcut = hi; // done';
		Assert.equals(fn(after), applyFix(fn(before)));
	}

	public function testLoopAndAHalfNotFlagged(): Void {
		// The dominant corpus shape: the condition is COMPUTED in the body, so the guard `if` is not
		// the first statement and no header could evaluate it.
		Assert.equals(
			0, violations(fn('while (true) {\n\t\t\tfinal x = next();\n\t\t\tif (x == null) break;\n\t\t\tuse(x);\n\t\t}')).length
		);
	}

	public function testLoopAndAHalfUnderMutexNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				fn('while (true) {\n\t\t\tlock();\n\t\t\tfinal n = count;\n\t\t\tunlock();\n\t\t\tif (n < 8) break;\n\t\t\tsleep();\n\t\t}')
			).length
		);
	}

	public function testExitByReturnNotFlagged(): Void {
		// No `break` at all — the loop leaves through a `return`, which this rewrite cannot express.
		Assert.equals(
			0, violations(fn('while (true) {\n\t\t\tfinal h = hash(i++);\n\t\t\tif (seen(h)) continue;\n\t\t\treturn h;\n\t\t}')).length
		);
	}

	public function testBreakInKeptBranchNotFlagged(): Void {
		// That `break` SKIPPED the lifted statements in the original; after the lift they would run.
		Assert.equals(
			0,
			violations(fn('while (true) if (c) {\n\t\t\tif (d) break;\n\t\t\tg();\n\t\t} else {\n\t\t\th();\n\t\t\tbreak;\n\t\t}')).length
		);
	}

	public function testBreakInSwitchInKeptBranchNotFlagged(): Void {
		// In Haxe a `break` inside a `switch` inside a loop breaks the LOOP (measured on --interp),
		// so the scan must descend into switch bodies and refuse here exactly as for a bare break.
		Assert.equals(
			0,
			violations(fn(
				'while (true) if (c) {\n\t\t\tswitch v {\n\t\t\t\tcase 1: break;\n\t\t\t\tcase _:\n\t\t\t}\n\t\t} else {'
				+ '\n\t\t\th();\n\t\t\tbreak;\n\t\t}'
			)).length
		);
	}

	public function testBreakInNestedLoopInKeptBranchFlagged(): Void {
		// The mirror case: that `break` binds to the INNER loop and never reaches this one.
		Assert.equals(
			1,
			violations(fn('while (true) if (c) {\n\t\t\tfor (i in 0...3) if (d) break;\n\t\t} else {\n\t\t\th();\n\t\t\tbreak;\n\t\t}'))
				.length
		);
	}

	public function testContinueInKeptBranchFlagged(): Void {
		// Order-equivalent: originally top -> `true` -> C; afterwards straight to C.
		Assert.equals(
			1,
			violations(fn('while (true) if (c) {\n\t\t\tif (d) continue;\n\t\t\tg();\n\t\t} else {\n\t\t\th();\n\t\t\tbreak;\n\t\t}'))
				.length
		);
	}

	public function testContinueInExitBranchNotFlagged(): Void {
		Assert.equals(
			0, violations(fn('while (true) if (c) {\n\t\t\tg();\n\t\t} else {\n\t\t\tif (d) continue;\n\t\t\tbreak;\n\t\t}')).length
		);
	}

	public function testElseIfChainNotFlagged(): Void {
		// FAILS CLOSED: the else child is an `if`, not a block ending in `break`.
		Assert.equals(0, violations(fn('while (true) if (c) {\n\t\t\tg();\n\t\t} else if (d) {\n\t\t\th();\n\t\t\tbreak;\n\t\t}')).length);
	}

	public function testBothBranchesBreakNotFlagged(): Void {
		Assert.equals(
			0, violations(fn('while (true) if (c) {\n\t\t\tg();\n\t\t\tbreak;\n\t\t} else {\n\t\t\th();\n\t\t\tbreak;\n\t\t}')).length
		);
	}

	public function testStatementAfterIfNotFlagged(): Void {
		// Forms (b) and (c) must consume the whole body: the kept run would be two non-contiguous
		// source slices.
		Assert.equals(
			0,
			violations(
				fn('while (true) {\n\t\t\tif (c) {\n\t\t\t\tg();\n\t\t\t} else {\n\t\t\t\th();\n\t\t\t\tbreak;\n\t\t\t}\n\t\t\tk();\n\t\t}')
			).length
		);
	}

	public function testNonTrueConditionNotFlagged(): Void {
		Assert.equals(0, violations(fn('while (running) if (c) {\n\t\t\tg();\n\t\t} else {\n\t\t\th();\n\t\t\tbreak;\n\t\t}')).length);
	}

	public function testGlueCommentReportOnly(): Void {
		final src: String = fn('while (true) if (c) /* why */ {\n\t\t\tg();\n\t\t} else {\n\t\t\th();\n\t\t\tbreak;\n\t\t}');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('lift by hand') != -1, 'the dropped-comment note must be on the message');
		Assert.equals(0, edits(src).length);
	}

	public function testCommentInKeptBranchRidesAlong(): Void {
		Assert.equals(
			fn('while (c) {\n\t\t\t// keep me\n\t\t\tg();\n\t\t}\nh();'),
			applyFix(fn('while (true) if (c) {\n\t\t\t// keep me\n\t\t\tg();\n\t\t} else {\n\t\t\th();\n\t\t\tbreak;\n\t\t}'))
		);
	}

	public function testMacroReificationNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tmacro function f() {\n\t\treturn macro {\n\t\t\twhile (true) if (c) {\n\t\t\t\tg();\n\t\t\t} else {'
				+ '\n\t\t\t\th();\n\t\t\t\tbreak;\n\t\t\t}\n\t\t};\n\t}\n}'
			).length
		);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { while (true) if (c) { g(); } else { h(); break;').length);
	}

	public function testRegisteredAndDefaultOff(): Void {
		final check: Null<Check> = Linter.byId('while-true-condition');
		Assert.notNull(check);
		Assert.isTrue(Std.isOfType(check, DefaultOff), 'while-true-condition is opt-in');
	}

	private function fn(stmts: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\t$stmts\n\t}\n}';
	}

	private function violations(source: String): Array<Violation> {
		return new WhileTrueCondition().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function edits(source: String): Array<{ span: Span, text: String }> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: WhileTrueCondition = new WhileTrueCondition();
		return check.fix(source, check.run([{ file: 'C.hx', source: source }], plugin), plugin);
	}

	private function applyFix(source: String): String {
		return CheckFixture.fixedSource(new WhileTrueCondition(), source);
	}

}
