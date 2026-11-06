package unit.check.common.control;

import anyparse.check.Severity;
import anyparse.check.common.control.HoistCommonBranchTail;
import anyparse.query.ParseGate;

/**
 * The `hoist-common-branch-tail` check: a statement-position `if` chain with a final `else` whose every branch ends
 * with the same statements is flagged `Info`, and `fix` writes those statements once after the chain. The gates covered
 * here: the tail must be token-identical in ALL branches, must not exit, declare a local or read a name a branch's own
 * statements bind, the `if` must stand as a block statement and carry no conditional compilation, and — for the FIX
 * only — no branch other than the final `else` may end up empty and no comment may sit in a removed region.
 */
class HoistCommonBranchTailTest extends Test {

	private static final TWO_BRANCHES: String = 'class C { function f(c:Bool) { if (c) { a(); t(); } else { b(); t(); } } }';

	public function testSharedTailMovesAfterTheIf(): Void {
		final vs: Array<Violation> = violations(TWO_BRANCHES);
		Assert.equals(1, vs.length);
		Assert.equals('hoist-common-branch-tail', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('every branch of this if ends with the same statement — move it after the if', vs[0].message);
		final fixed: String = CheckFixture.fixedSource(new HoistCommonBranchTail(), TWO_BRANCHES);
		Assert.equals('class C { function f(c:Bool) { if (c) { a(); } else { b(); }\nt(); } }', fixed);
		Assert.notNull(ParseGate.parseOrNull(new HaxeQueryPlugin(), fixed));
	}

	public function testElseIfChainTailMovesOnce(): Void {
		final src: String =
			'class C { function f(c:Bool, d:Bool) { if (c) { a(); t(); u(); } else if (d) { b(); t(); u(); } else { e(); t(); u(); } } }';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('every branch of this if ends with the same 2 statements — move them after the if', vs[0].message);
		final fixed: String = CheckFixture.fixedSource(new HoistCommonBranchTail(), src);
		Assert.equals('class C { function f(c:Bool, d:Bool) { if (c) { a(); } else if (d) { b(); } else { e(); }\nt(); u(); } }', fixed);
		Assert.equals(0, violations(fixed).length);
	}

	public function testOnlyTheSharedSuffixMoves(): Void {
		final src: String = 'class C { function f(c:Bool) { if (c) { t(); u(); } else { b(); u(); } } }';
		Assert.equals(1, violations(src).length);
		Assert.equals(
			'class C { function f(c:Bool) { if (c) { t(); } else { b(); }\nu(); } }',
			CheckFixture.fixedSource(new HoistCommonBranchTail(), src)
		);
	}

	public function testEmptiedFinalElseIsDropped(): Void {
		final src: String = 'class C { function f(c:Bool) { if (c) { a(); t(); } else { t(); } } }';
		Assert.equals(1, violations(src).length);
		Assert.equals(
			'class C { function f(c:Bool) { if (c) { a(); }\nt(); } }', CheckFixture.fixedSource(new HoistCommonBranchTail(), src)
		);
	}

	public function testBraceLessFinalElseIsDropped(): Void {
		final src: String = 'class C { function f(c:Bool) { if (c) { a(); t(); } else t(); } }';
		Assert.equals(1, violations(src).length);
		Assert.equals(
			'class C { function f(c:Bool) { if (c) { a(); }\nt(); } }', CheckFixture.fixedSource(new HoistCommonBranchTail(), src)
		);
	}

	public function testEmptiedThenBranchIsReportOnly(): Void {
		final src: String = 'class C { function f(c:Bool) { if (c) { t(); } else { a(); t(); } } }';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testEmptiedMiddleArmIsReportOnly(): Void {
		final src: String = 'class C { function f(c:Bool, d:Bool) { if (c) { a(); t(); } else if (d) { t(); } else { b(); t(); } } }';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	@:pin('control')
	@:killer('M-HCBT-PURE-CONDITION')
	public function testImpureConditionIdenticalBranchesAreReportOnly(): Void {
		final src: String = 'class C { function f(c:Bool) { if (g(c)) { t(); } else { t(); } } }';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('every branch of this if is the same — the condition chooses nothing, keep one copy', vs[0].message);
		Assert.equals(0, edits(src).length);
	}

	@:pin('control')
	@:killer('M-HCBT-FINAL-ELSE')
	public function testIfWithoutElseIsNeverFlagged(): Void {
		Assert.equals(0, violations('class C { function f(c:Bool) { if (c) { a(); t(); } t(); } }').length);
		Assert.equals(0, violations('class C { function f(c:Bool, d:Bool) { if (c) { a(); t(); } else if (d) { b(); t(); } } }').length);
	}

	@:pin('control')
	@:killer('M-HCBT-NO-EXIT')
	public function testTailThatExitsIsNoTail(): Void {
		Assert.equals(0, violations('class C { function f(c:Bool) { if (c) { a(); return; } else { b(); return; } } }').length);
		Assert.equals(0, violations('class C { function f(c:Bool):Int { if (c) { a(); throw 1; } else { b(); throw 1; } } }').length);
		Assert.equals(
			0,
			violations('class C { function f(c:Bool, w:Bool) { while (w) { if (c) { a(); continue; } else { b(); continue; } } } }').length
		);
	}

	public function testBranchThatMayLeaveEarlierStillHoists(): Void {
		final src: String = 'class C { function f(c:Bool, z:Bool) { if (c) { if (z) return; a(); t(); } else { b(); t(); } } }';
		Assert.equals(1, violations(src).length);
		Assert.equals(3, edits(src).length);
	}

	@:pin('control')
	@:killer('M-HCBT-NO-CAPTURE')
	public function testTailReadingABranchLocalIsNotMoved(): Void {
		Assert.equals(
			0, violations('class C { function f(c:Bool) { if (c) { var t = f1(); k(t); } else { var t = f2(); k(t); } } }').length
		);
	}

	@:pin('control')
	@:killer('M-HCBT-TAIL-DECL')
	public function testTailDeclaringALocalIsNotMoved(): Void {
		Assert.equals(0, violations('class C { function f(c:Bool) { if (c) { a(); var v = 1; } else { b(); var v = 1; } } }').length);
		Assert.equals(
			0, violations('class C { function f(c:Bool) { if (c) { a(); function g() {} } else { b(); function g() {} } } }').length
		);
	}

	@:pin('control')
	@:killer('M-HCBT-STATEMENT-POSITION')
	public function testOnlyABlockStatementIfIsAChainHead(): Void {
		Assert.equals(0, violations('class C { function f(c:Bool) { var x = if (c) { a(); t(); } else { b(); t(); }; } }').length);
		Assert.equals(
			0, violations('class C { function f(c:Bool, xs:Array<Int>) { for (x in xs) if (c) { a(); t(); } else { b(); t(); } } }').length
		);
	}

	public function testDifferentArgumentsAreNotTheSameTail(): Void {
		Assert.equals(0, violations('class C { function f(c:Bool) { if (c) { a(); t(1); } else { b(); t(2); } } }').length);
	}

	public function testConditionalCompilationNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(c:Bool) { if (c) { a(); t(); } else { #if x b(); #end t(); } } }').length);
	}

	public function testUniqueCommentInTailIsReportOnly(): Void {
		final src: String = 'class C { function f(c:Bool) { if (c) { a();\n// note\nt(); } else { b(); t(); } } }';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testTrailingCommentAfterTailIsReportOnly(): Void {
		final src: String = 'class C { function f(c:Bool) { if (c) { a(); t(); // done\n} else { b(); t(); } } }';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testMacroReificationNotWalked(): Void {
		Assert.equals(
			0, violations('class C { macro function f(c:Bool) { return macro { if (c) { a(); t(); } else { b(); t(); } }; } }').length
		);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		CheckFixture.assertRegistered('hoist-common-branch-tail');
	}

	@:pin('control')
	@:killer('M-HCBT-NESTED-ALL-OR-NOTHING')
	public function testNestedChainWaitsForTheOuterRewrite(): Void {
		final inKept: String =
			'class C { function f(c:Bool, d:Bool) { if (c) { if (d) { x(); t(); } else { y(); t(); } u(); } else { b(); u(); } } }';
		Assert.equals(
			'class C { function f(c:Bool, d:Bool) { if (c) { if (d) { x(); t(); } else { y(); t(); } } else { b(); }\nu(); } }',
			fixed(inKept)
		);
		Assert.equals(
			'class C { function f(c:Bool, d:Bool) { if (c) { if (d) { x(); } else { y(); }\nt(); } else { b(); }\nu(); } }',
			fixed(fixed(inKept))
		);
		final inElse: String =
			'class C { function f(c:Bool, d:Bool) { if (c) { b(); u(); } else { if (d) { x(); t(); } else { y(); t(); } u(); } } }';
		Assert.equals(
			'class C { function f(c:Bool, d:Bool) { if (c) { b(); } else { if (d) { x(); t(); } else { y(); t(); } }\nu(); } }',
			fixed(inElse)
		);
		Assert.equals(
			'class C { function f(c:Bool, d:Bool) { if (c) { b(); } else { if (d) { x(); } else { y(); }\nt(); }\nu(); } }',
			fixed(fixed(inElse))
		);
		final inTail: String = 'class C { function f(c:Bool, d:Bool) { if (c) { a(); if (d) { x(); t(); } else { y(); t(); } }'
			+ ' else { b(); if (d) { x(); t(); } else { y(); t(); } } } }';
		Assert.equals(
			'class C { function f(c:Bool, d:Bool) { if (c) { a(); } else { b(); }\nif (d) { x(); t(); } else { y(); t(); } } }',
			fixed(inTail)
		);
		Assert.equals(
			'class C { function f(c:Bool, d:Bool) { if (c) { a(); } else { b(); }\nif (d) { x(); } else { y(); }\nt(); } }',
			fixed(fixed(inTail))
		);
	}

	@:pin('control')
	@:killer('M-HCBT-CHAIN-TERMINATOR')
	public function testTerminatorAfterTheChainStaysOutsideTheMovedTail(): Void {
		Assert.equals(
			'class C { function f(c:Bool) { if (c) { a(); } else { b(); };\nt(); z(); } }',
			fixed('class C { function f(c:Bool) { if (c) { a(); t(); } else { b(); t(); }; z(); } }')
		);
		Assert.equals(
			'class C { function f(c:Bool) { if (c) { a(); }\nt(); z(); } }',
			fixed('class C { function f(c:Bool) { if (c) { a(); t(); } else { t(); }; z(); } }')
		);
	}

	public function testEmptiedElseWithACommentInItIsReportOnly(): Void {
		for (src in [
			'class C { function f(c:Bool) { if (c) { a(); t(); } /*c*/ else { t(); } } }',
			'class C { function f(c:Bool) { if (c) { a(); t(); } else { // why\n t(); } } }',
			'class C { function f(c:Bool) { if (c) { a(); t(); } else { t(); // why\n } } }'
		]) {
			Assert.equals(1, violations(src).length);
			Assert.equals(0, edits(src).length);
		}
	}

	@:pin('control')
	@:killer('M-HCBT-TERMINATOR-TRIVIA')
	public function testCommentBetweenTheChainAndItsTerminator(): Void {
		Assert.equals(
			'class C { function f(c:Bool) { if (c) { a(); } else { b(); } /* note */;\nt(); z(); } }',
			fixed('class C { function f(c:Bool) { if (c) { a(); t(); } else { b(); t(); } /* note */; z(); } }')
		);
		Assert.equals(
			'class C { function f(c:Bool) { if (c) { a(); } else { b(); } // note\n;\nt(); z(); } }',
			fixed('class C { function f(c:Bool) { if (c) { a(); t(); } else { b(); t(); } // note\n; z(); } }')
		);
		for (src in [
			'class C { function f(c:Bool) { if (c) { a(); t(); } else { t(); } /* note */; z(); } }',
			'class C { function f(c:Bool) { if (c) { a(); t(); } else { t(); } // note\n; z(); } }'
		]) {
			Assert.equals(1, violations(src).length);
			Assert.equals(0, edits(src).length);
		}
	}

	public function testCommentAfterAChainWithoutTerminatorTrailsTheMovedTail(): Void {
		Assert.equals(
			'class C { function f(c:Bool) { if (c) { a(); } else { b(); }\nt(); // note\n z(); } }',
			fixed('class C { function f(c:Bool) { if (c) { a(); t(); } else { b(); t(); } // note\n z(); } }')
		);
		Assert.equals(
			'class C { function f(c:Bool) { if (c) { a(); } else { b(); }\nt(); /* note */ z(); } }',
			fixed('class C { function f(c:Bool) { if (c) { a(); t(); } else { b(); t(); } /* note */ z(); } }')
		);
	}

	@:pin('control')
	@:killer('M-HCBT-REPORT-ONLY-OUTER')
	public function testReportOnlyOuterDoesNotHoldBackItsInnerChain(): Void {
		Assert.equals(
			'class C { function f(c:Bool, d:Bool) { if (g(c)) { if (d) { x(); } else { y(); }\n'
			+ 't(); } else { if (d) { x(); } else { y(); }\nt(); } } }',
			fixed(
				'class C { function f(c:Bool, d:Bool) { if (g(c)) { if (d) { x(); t(); } else { y(); t(); } } else { if (d) { x(); t(); } '
				+ 'else { y(); t(); } } } }'
			)
		);
		Assert.equals(
			'class C { function f(c:Bool, d:Bool) { if (c) { u(); } else { if (d) { x(); } else { y(); }\nt(); u(); } } }',
			fixed('class C { function f(c:Bool, d:Bool) { if (c) { u(); } else { if (d) { x(); t(); } else { y(); t(); } u(); } } }')
		);
	}

	@:pin('control')
	@:killer('M-HCBT-CAPTURE-EVERY-BRANCH')
	public function testNameBoundInAnyBranchBlocksTheMove(): Void {
		Assert.equals(0, violations('class C { function f(c:Bool) { if (c) { a(); k(v); } else { final v = 2; k(v); } } }').length);
		Assert.equals(
			0,
			violations(
				'class C { function f(c:Bool, d:Bool) { if (c) { a(); k(v); } else if (d) { b(); k(v); } else { final v = 2; k(v); } } }'
			).length
		);
		Assert.equals(0, violations('class C { function f(c:Bool) { if (c) { var w, v = 2; k(v); } else { a(); k(v); } } }').length);
	}

	@:pin('control')
	@:killer('M-HCBT-SHORTEN')
	public function testTailShortensFromItsFrontUntilTheGatesHold(): Void {
		final src: String = 'class C { function f(c:Bool) { if (c) { a(); var w = 1; k(w); t(); } else { b(); var w = 1; k(w); t(); } } }';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('every branch of this if ends with the same statement — move it after the if', vs[0].message);
		Assert.equals(
			'class C { function f(c:Bool) { if (c) { a(); var w = 1; k(w); } else { b(); var w = 1; k(w); }\nt(); } }', fixed(src)
		);
	}

	@:pin('control')
	@:killer('M-HCBT-SUPPRESSED')
	public function testSuppressedChainStaysWhileFreeChainMoves(): Void {
		final src: String = 'class C {\nfunction f(c:Bool) {\n// CHECKSTYLE:OFF\nif (c) { a(); t(); } else { b(); t(); }\n'
			+ '// CHECKSTYLE:ON\n}\nfunction g(c:Bool) { if (c) { a(); t(); } else { b(); t(); } }\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(
			'class C {\nfunction f(c:Bool) {\n// CHECKSTYLE:OFF\nif (c) { a(); t(); } else { b(); t(); }\n// CHECKSTYLE:ON\n}\n'
			+ 'function g(c:Bool) { if (c) { a(); } else { b(); }\nt(); }\n}',
			fixed(src)
		);
	}

	public function testIdenticalBranchesWithPlainConditionKeepOneCopy(): Void {
		Assert.equals(
			'class C { function f(j:Int) { { a(); b(); } } }',
			fixed('class C { function f(j:Int) { if (j == 0) { a(); b(); } else { a(); b(); } } }')
		);
		Assert.equals(
			'class C { function f(j:Int) { t(); } }', fixed('class C { function f(j:Int) { if (j == 0) { t(); } else { t(); } } }')
		);
		Assert.equals('class C { function f(j:Int) { t(); } }', fixed('class C { function f(j:Int) { if (j == 0) t(); else t(); } }'));
	}

	public function testElseIfChainOfPlainConditionsKeepsOneCopy(): Void {
		Assert.equals(
			'class C { function f(j:Int, c:Bool) { t(); } }',
			fixed('class C { function f(j:Int, c:Bool) { if (j == 0) t(); else if (j + 2 < 3 && !c) t(); else t(); } }')
		);
		Assert.equals(0, edits('class C { function f(j:Int, c:Bool) { if (j == 0) t(); else if (g(j)) t(); else t(); } }').length);
	}

	@:pin('control')
	@:killer('M-PURITY-PLAIN-VALUE-KINDS')
	public function testFieldOrIndexReadConditionIsReportOnly(): Void {
		for (cond in ['o.x > 0', 'xs[0] > 0', 'o.x.y']) {
			final src: String = 'class C { function f(o:{x:Int}, xs:Array<Int>) { if ($cond) t(); else t(); } }';
			Assert.equals(1, violations(src).length);
			Assert.equals(0, edits(src).length);
		}
	}

	@:pin('control')
	@:killer('M-PURITY-PLAIN-VALUE-GETTER')
	public function testGetterConditionIsReportOnly(): Void {
		final src: String = 'class C { var p(get, never):Bool; function get_p():Bool return true; function f() { if (p) t(); else t(); } }';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	@:pin('control')
	@:killer('M-HCBT-KEEP-BLOCK')
	public function testBodyDeclaringALocalKeepsItsBlock(): Void {
		Assert.equals(
			'class C { function f(c:Bool) { { var v = 1; k(v); } } }',
			fixed('class C { function f(c:Bool) { if (c) { var v = 1; k(v); } else { var v = 1; k(v); } } }')
		);
		Assert.equals(
			'class C { function f(c:Bool) { { var v = 1; } } }',
			fixed('class C { function f(c:Bool) { if (c) { var v = 1; } else { var v = 1; } } }')
		);
	}

	public function testIdenticalBranchesThatExitAreNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f(c:Bool) { if (c) { return; } else { return; } } }').length);
	}

	@:pin('control')
	@:killer('M-HCBT-WHOLE-COMMENT')
	public function testCommentInsideAnIdenticalChainIsReportOnly(): Void {
		final src: String = 'class C { function f(j:Int) { if (j == 0) { // keep\n t(); } else { // keep\n t(); } } }';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	@:pin('control')
	@:killer('M-HCBT-NESTED-ALL-OR-NOTHING')
	public function testIdenticalOuterChainCollapsesBeforeItsInnerTailMoves(): Void {
		final src: String = 'class C { function f(j:Int, d:Bool) { if (j == 0) { if (d) { x(); t(); } else { y(); t(); } } '
			+ 'else { if (d) { x(); t(); } else { y(); t(); } } } }';
		Assert.equals('class C { function f(j:Int, d:Bool) { if (d) { x(); t(); } else { y(); t(); } } }', fixed(src));
		Assert.equals('class C { function f(j:Int, d:Bool) { if (d) { x(); } else { y(); }\nt(); } }', fixed(fixed(src)));
	}

	@:pin('control')
	@:killer('M-HCBT-WHOLE-FIRST')
	public function testImpureChainWithIdenticalDeclaringBodiesIsReportedWhole(): Void {
		final src: String = 'class C { function f() { if (g()) { var v = 1; t(); } else { var v = 1; t(); } } }';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('every branch of this if is the same — the condition chooses nothing, keep one copy', vs[0].message);
		Assert.equals(0, edits(src).length);
	}

	private static function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new HoistCommonBranchTail(), src);
	}

	private static function edits(src: String): Array<{ span: Span, text: String }> {
		return CheckFixture.edits(new HoistCommonBranchTail(), src);
	}

	private static function fixed(src: String): String {
		return CheckFixture.fixedSource(new HoistCommonBranchTail(), src);
	}

}
