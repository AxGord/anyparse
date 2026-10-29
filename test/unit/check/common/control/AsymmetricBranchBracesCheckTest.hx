package unit.check.common.control;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.NoAutofix;
import anyparse.check.Severity;
import anyparse.check.common.control.AsymmetricBranchBraces;

/**
 * The `asymmetric-branch-braces` check: an `if` / `else` pair with EXACTLY ONE braced branch,
 * reported `Info` and fixed by bracing the bare branch.
 *
 * It is the lint twin of the writer's `singleStatementBraces: "symmetric"` policy, and it
 * carries the SAME two exemptions for the same reason - an `else if` link and an `else switch`
 * are keyword-headed else bodies that already close on a `}` of their own, and bracing the first
 * would rebuild the `else { if … }` shape `collapsible-else-if` exists to remove. The exemption
 * is ELSE-side only, which `testASwitchInThenPositionIsStillFlagged` pins: a `switch` opposite a
 * braced `else` is a genuine asymmetry.
 *
 * `DefaultOff` is asserted, not assumed: brace symmetry is the project's taste, so the check may
 * not fire unasked. Once asked, its fix takes the writer's repair direction and its gates: a
 * branch with no terminator of its own and a declaration stay bare.
 */
@:nullSafety(Strict)
class AsymmetricBranchBracesCheckTest extends Test {

	public function testThenBracedElseBareIsFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('if (a) {\n\t\t\tp();\n\t\t} else\n\t\t\tq();'));
		Assert.equals(1, vs.length);
		Assert.equals('asymmetric-branch-braces', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('the then branch is braced and the else branch is not - brace both or neither', vs[0].message);
	}

	public function testThenBareElseBracedIsFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('if (a)\n\t\t\tp();\n\t\telse {\n\t\t\tq();\n\t\t}'));
		Assert.equals(1, vs.length);
		Assert.equals('the else branch is braced and the then branch is not - brace both or neither', vs[0].message);
	}

	public function testBothBracedIsNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) {\n\t\t\tp();\n\t\t} else {\n\t\t\tq();\n\t\t}')).length);
	}

	public function testBothBareIsNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a)\n\t\t\tp();\n\t\telse\n\t\t\tq();')).length);
	}

	/** No else at all: nothing to be symmetric with. Pony's `if (d.length != 4) throw …;` shape. */
	public function testAnIfWithNoElseIsNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (d.length != 4)\n\t\t\tthrow \'bad\';')).length);
	}

	/** An `else if` LINK is exempt as a pair: a chain whose branches are all braced is symmetric. */
	public function testAnElseIfLinkIsExempt(): Void {
		Assert.equals(0, violations(wrap('if (a) {\n\t\t\tp();\n\t\t} else if (b) {\n\t\t\tq();\n\t\t}')).length);
	}

	/**
	 * A chain with NO final `else` is still a chain: a braced link opposite a bare one is the asymmetry the writer's
	 * `chainForcesBraces` repairs (`fmt` under `singleStatementBraces: "symmetric"` braces `q();`). The finding spans
	 * the whole chain, since no single pair of it is the defect.
	 */
	@:pin('control')
	@:killer('M-ASYM-CHAIN-UNFLAGGED')
	public function testANoElseChainWithABracedLinkIsFlagged(): Void {
		final src: String = wrap('if (a) {\n\t\t\tp();\n\t\t} else if (b)\n\t\t\tq();');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('the if/else-if chain braces some branches and not others - brace all or none', vs[0].message);
		Assert.equals(src.indexOf('if (a)'), vs[0].span?.from);
		Assert.equals(src.lastIndexOf('q();') + 'q();'.length, vs[0].span?.to);
		Assert.equals(
			1, violations(wrap('if (a)\n\t\t\tp();\n\t\telse if (b) {\n\t\t\tq();\n\t\t}')).length, 'the mirror, braced in the tail'
		);
	}

	/** A final-else chain whose TAIL pair agrees but whose head does not is one too - `fmt` braces `p();`. */
	public function testAChainBareInItsHeadOnlyIsFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('if (a) p(); else if (b) {\n\t\t\tq();\n\t\t} else {\n\t\t\tr();\n\t\t}'));
		Assert.equals(1, vs.length);
		Assert.equals('the if/else-if chain braces some branches and not others - brace all or none', vs[0].message);
	}

	/** Every branch bare, or every branch braced: symmetric, final `else` or not. */
	public function testAnAgreeingChainIsNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (a) p(); else if (b) q();')).length);
		Assert.equals(0, violations(wrap('if (a) p(); else if (b) q(); else if (d == s) r();')).length);
		Assert.equals(
			0,
			violations(wrap('if (a) {\n\t\t\tp();\n\t\t} else if (b) {\n\t\t\tq();\n\t\t} else if (d == s) {\n\t\t\tr();\n\t\t}')).length
		);
	}

	/**
	 * ONE finding per chain, however many of its links disagree: the tail pair's own finding when that pair is the
	 * asymmetric one, else the chain's.
	 */
	@:pin('control')
	@:killer('M-ASYM-CHAIN-PER-LINK')
	@:killer('M-ASYM-CHAIN-PAIR-SKIPPED')
	public function testOneFindingPerChain(): Void {
		final chain: Array<Violation> = violations(wrap('if (a) {\n\t\t\tp();\n\t\t} else if (b) q(); else if (d == s) r();'));
		Assert.equals(1, chain.length, 'a three-link chain with no else');
		Assert.equals('the if/else-if chain braces some branches and not others - brace all or none', chain[0].message);
		final pair: Array<Violation> = violations(wrap('if (a) {\n\t\t\tp();\n\t\t} else if (b) q(); else {\n\t\t\tr();\n\t\t}'));
		Assert.equals(1, pair.length, 'the tail pair is the finding');
		Assert.equals('the else branch is braced and the then branch is not - brace both or neither', pair[0].message);
	}

	/**
	 * A terminal `else switch` is neither braced nor bare in a chain, as in a pair: `fmt` braces the chain's other
	 * branches and leaves the `switch` glued to its `else`. A chain that disagrees only through it is not a finding.
	 */
	@:pin('control')
	@:killer('M-ASYM-CHAIN-SWITCH-BRACED')
	public function testAnElseSwitchIsNeutralInAChain(): Void {
		final sw: String = 'switch s {\n\t\t\tcase _:\n\t\t\t\tr();\n\t\t}';
		Assert.equals(0, violations(wrap('if (a) p(); else if (b) q(); else $sw')).length);
		Assert.equals(0, violations(wrap('if (a) {\n\t\t\tp();\n\t\t} else if (b) {\n\t\t\tq();\n\t\t} else $sw')).length);
		final src: String = wrap('if (a) {\n\t\t\tp();\n\t\t} else if (b) q(); else $sw');
		Assert.equals(1, violations(src).length);
		Assert.equals(
			wrap('if (a) {\n\t\t\tp();\n\t\t} else if (b) { q(); } else $sw'), CheckFixture.fixedSource(new AsymmetricBranchBraces(), src)
		);
	}

	public function testAnElseSwitchIsExempt(): Void {
		Assert.equals(
			0, violations(wrap('if (a) {\n\t\t\tp();\n\t\t} else\n\t\t\tswitch s {\n\t\t\t\tcase _:\n\t\t\t\t\tq();\n\t\t\t}')).length
		);
	}

	/** The exemption is ELSE-side only — a `switch` in THEN position is a real asymmetry. */
	public function testASwitchInThenPositionIsStillFlagged(): Void {
		Assert.equals(
			1, violations(wrap('if (a)\n\t\t\tswitch s {\n\t\t\t\tcase _:\n\t\t\t\t\tp();\n\t\t\t}\n\t\telse {\n\t\t\tq();\n\t\t}')).length
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('asymmetric-branch-braces'));
		Assert.isTrue([for (c in Linter.builtins()) c.id()].contains('asymmetric-branch-braces'));
	}

	/**
	 * Opt-in, and it fixes: a project that enables it asked for symmetric braces, and the one direction
	 * that never changes what a branch means is the writer's own repair - brace the bare sibling.
	 */
	public function testItIsOptInAndFixes(): Void {
		final check: AsymmetricBranchBraces = new AsymmetricBranchBraces();
		Assert.isTrue((check: Dynamic) is DefaultOff, 'the check must be opt-in');
		Assert.isFalse((check: Dynamic) is NoAutofix, 'bracing the bare branch is mechanical');
	}

	/** The bare ELSE gains the braces its sibling has - the writer's `symmetric` repair, never the removal. */
	@:pin('control')
	@:killer('M-ASYM-FIX-NO-EDIT')
	public function testFixBracesTheBareElse(): Void {
		final src: String = wrap('if (a) {\n\t\t\tp();\n\t\t} else\n\t\t\tq();');
		final fixed: String = CheckFixture.fixedSource(new AsymmetricBranchBraces(), src);
		Assert.equals(wrap('if (a) {\n\t\t\tp();\n\t\t} else\n\t\t\t{ q(); }'), fixed);
		Assert.equals(0, violations(fixed).length, 'the fixed pair is symmetric');
	}

	/** The bare THEN takes its `;` inside the braces: the statement's own span carries its terminator. */
	public function testFixBracesTheBareThen(): Void {
		final src: String = wrap('if (a)\n\t\t\tp();\n\t\telse {\n\t\t\tq();\n\t\t}');
		Assert.equals(
			wrap('if (a)\n\t\t\t{ p(); }\n\t\telse {\n\t\t\tq();\n\t\t}'), CheckFixture.fixedSource(new AsymmetricBranchBraces(), src)
		);
	}

	/**
	 * The unit is the CHAIN the pair ends, as the writer's `chainForcesBraces` makes it: the finding is
	 * the tail pair only - every earlier link has an `if` as its else - and bracing that pair alone would
	 * leave the chain braced in its tail and bare in its head.
	 */
	@:pin('control')
	@:killer('M-ASYM-FIX-CHAIN-TAIL-ONLY')
	public function testFixBracesTheWholeElseIfChain(): Void {
		final src: String = wrap('if (a) p(); else if (b) q(); else {\n\t\t\tr();\n\t\t}');
		final run: FixRun = CheckFixture.fixRun(new AsymmetricBranchBraces(), [{ file: 'C.hx', source: src }]);
		Assert.equals(1, run.violations.length, 'only the tail pair is a finding');
		Assert.equals(
			wrap('if (a) { p(); } else if (b) { q(); } else {\n\t\t\tr();\n\t\t}'),
			CheckFixture.fixedSource(new AsymmetricBranchBraces(), src)
		);
	}

	/**
	 * A chain with no final `else` is braced whole, both ways round, as `fmt` under `singleStatementBraces: "symmetric"`
	 * braces it - and a head-only disagreement in a final-else chain the same.
	 */
	@:pin('control')
	@:killer('M-ASYM-CHAIN-UNFLAGGED')
	public function testFixBracesANoElseChain(): Void {
		Assert.equals(
			wrap('if (a) {\n\t\t\tp();\n\t\t} else if (b) { q(); } else if (d == s) { r(); }'),
			CheckFixture.fixedSource(
				new AsymmetricBranchBraces(), wrap('if (a) {\n\t\t\tp();\n\t\t} else if (b) q(); else if (d == s) r();')
			)
		);
		Assert.equals(
			wrap('if (a) { p(); } else if (b) {\n\t\t\tq();\n\t\t}'),
			CheckFixture.fixedSource(new AsymmetricBranchBraces(), wrap('if (a) p(); else if (b) {\n\t\t\tq();\n\t\t}'))
		);
		Assert.equals(
			wrap('if (a) { p(); } else if (b) {\n\t\t\tq();\n\t\t} else {\n\t\t\tr();\n\t\t}'),
			CheckFixture.fixedSource(
				new AsymmetricBranchBraces(), wrap('if (a) p(); else if (b) {\n\t\t\tq();\n\t\t} else {\n\t\t\tr();\n\t\t}')
			)
		);
		Assert.equals(
			wrap('if (a) { p(); } else if (b) {\n\t\t\tq();\n\t\t}'),
			CheckFixture.fixedSource(new AsymmetricBranchBraces(), wrap('if (a) p() else if (b) {\n\t\t\tq();\n\t\t}')),
			'an unterminated bare branch takes the terminator inside its braces'
		);
	}

	/**
	 * A bare branch's own comments - each on a line of its own between its header and its statement - go inside its
	 * braces: left outside they would sit between the header and the `{`. A comment trailing the header on its line is
	 * the header's and stays where it is.
	 */
	@:pin('control')
	@:killer('M-ASYM-FIX-COMMENT-OUTSIDE')
	@:killer('M-OWNLINE-COMMENT-TRAILING')
	public function testFixTakesTheBranchsOwnCommentsInside(): Void {
		Assert.equals(
			wrap('if (a) {\n\t\t\tp();\n\t\t} else if (b) {\n\t\t\t// note\n\t\t\t/* more */\n\t\t\tq(); }'),
			CheckFixture.fixedSource(
				new AsymmetricBranchBraces(), wrap('if (a) {\n\t\t\tp();\n\t\t} else if (b)\n\t\t\t// note\n\t\t\t/* more */\n\t\t\tq();')
			)
		);
		Assert.equals(
			wrap('if (a) {\n\t\t\tp();\n\t\t} else if (b) // the header\'s\n\t\t\t{ q(); }'),
			CheckFixture.fixedSource(
				new AsymmetricBranchBraces(), wrap('if (a) {\n\t\t\tp();\n\t\t} else if (b) // the header\'s\n\t\t\tq();')
			)
		);
	}

	/** A conditional-compilation region in a no-else chain stays bare, and the finding says why - the writer leaves it too. */
	public function testFixLeavesANoElseConditionalRegionBare(): Void {
		final src: String = wrap('if (a) {\n\t\t\tq();\n\t\t} else if (b) #if d p() #else r() #end;');
		final run: FixRun = CheckFixture.fixRun(new AsymmetricBranchBraces(), [{ file: 'C.hx', source: src }]);
		Assert.equals(1, run.violations.length);
		Assert.equals(0, run.edits.length);
		Assert.isTrue((run.violations[0].declineReason ?? '').indexOf('no terminator of its own') != -1);
	}

	/**
	 * A conditional-compilation region stays bare: its terminator belongs to the region although its
	 * parent's span owns it (`RefShape.statementTerminator`), so neither the region's own text nor that
	 * text plus a terminator is the branch's statement. The terminator gate is what declines it, and the
	 * reason says so: the reparse gate behind it would refuse the wrapped region too, so only the reason
	 * tells the two apart.
	 */
	@:pin('control')
	@:killer('M-ASYM-FIX-OPEN-TAIL-ANY')
	public function testFixLeavesAConditionalRegionBare(): Void {
		final src: String = wrap('if (a) {\n\t\t\tq();\n\t\t} else #if d b() #else c() #end;');
		final run: FixRun = CheckFixture.fixRun(new AsymmetricBranchBraces(), [{ file: 'C.hx', source: src }]);
		Assert.equals(1, run.violations.length);
		Assert.equals(0, run.edits.length);
		final reason: String = run.violations[0].declineReason ?? '';
		Assert.isTrue(reason.indexOf('no terminator of its own') != -1, 'the terminator gate must decide, got: $reason');
	}

	/**
	 * A bare EXPRESSION statement with no terminator - Haxe accepts `if (a) p() else { … }` - takes the
	 * terminator inside the braces: `{ p() }` is `Missing ;`, and `{ p(); }` is the same statement. An
	 * expression that merely ends in a brace (a `switch` value) is still an expression statement, and a
	 * loop over one ends in it: the terminator is the loop body's.
	 */
	@:pin('control')
	@:killer('M-ASYM-FIX-NO-TERMINATOR-ADDED')
	@:killer('M-ASYM-FIX-UNTERMINATED')
	public function testFixTerminatesAnUnterminatedExpression(): Void {
		Assert.equals(
			wrap('if (a) { p(); } else {\n\t\t\tq();\n\t\t}'),
			CheckFixture.fixedSource(new AsymmetricBranchBraces(), wrap('if (a) p() else {\n\t\t\tq();\n\t\t}'))
		);
		Assert.equals(
			wrap('if (a) { x = switch s {\n\t\t\tcase _: 1;\n\t\t}; } else {\n\t\t\tq();\n\t\t}'),
			CheckFixture.fixedSource(
				new AsymmetricBranchBraces(), wrap('if (a) x = switch s {\n\t\t\tcase _: 1;\n\t\t} else {\n\t\t\tq();\n\t\t}')
			)
		);
		Assert.equals(
			wrap('if (a) { for (c in s) p(); } else {\n\t\t\tq();\n\t\t}'),
			CheckFixture.fixedSource(new AsymmetricBranchBraces(), wrap('if (a) for (c in s) p() else {\n\t\t\tq();\n\t\t}'))
		);
	}

	/** A statement that closes on a block of its own — a loop over a braced body — is self-terminated, and is braced. */
	public function testFixBracesABareLoopWithABracedBody(): Void {
		final src: String = wrap('if (a) for (c in s) {\n\t\t\tp();\n\t\t} else {\n\t\t\tq();\n\t\t}');
		Assert.equals(
			wrap('if (a) { for (c in s) {\n\t\t\tp();\n\t\t} } else {\n\t\t\tq();\n\t\t}'),
			CheckFixture.fixedSource(new AsymmetricBranchBraces(), src)
		);
	}

	/** A declaration is never wrapped: braces would scope the binding — the writer's gate 3 excludes it the same way. */
	@:pin('control')
	@:killer('M-ASYM-FIX-DECL')
	public function testFixLeavesADeclarationBare(): Void {
		final src: String = wrap('if (a) {\n\t\t\tp();\n\t\t} else\n\t\t\tvar x = 1;');
		Assert.equals(src, CheckFixture.fixedSource(new AsymmetricBranchBraces(), src));
		final noElse: String = wrap('if (a) {\n\t\t\tp();\n\t\t} else if (b)\n\t\t\tvar x = 1;');
		final run: FixRun = CheckFixture.fixRun(new AsymmetricBranchBraces(), [{ file: 'C.hx', source: noElse }]);
		Assert.equals(1, run.violations.length, 'a no-else chain with a declaration is still reported');
		Assert.equals(0, run.edits.length);
		Assert.isTrue((run.violations[0].declineReason ?? '').indexOf('declaration') != -1);
	}

	/**
	 * A pair inside another finding's bare branch waits for the next pass: its edit would sit inside the
	 * outer one's, and the two cannot both land in one splice.
	 */
	@:pin('control')
	@:killer('M-ASYM-FIX-NESTED-OVERLAP')
	public function testFixLeavesANestedPairToTheNextPass(): Void {
		final src: String = wrap('if (a) {\n\t\t\tp();\n\t\t} else while (b) if (d == s) {\n\t\t\tq();\n\t\t} else\n\t\t\tr();');
		final run: FixRun = CheckFixture.fixRun(new AsymmetricBranchBraces(), [{ file: 'C.hx', source: src }]);
		Assert.equals(2, run.violations.length);
		Assert.equals(1, run.edits.length);
		final once: String = CheckFixture.fixedSource(new AsymmetricBranchBraces(), src);
		Assert.equals(1, violations(once).length, 'the inner pair is left for the next pass');
		Assert.equals(0, violations(CheckFixture.fixedSource(new AsymmetricBranchBraces(), once)).length);
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new AsymmetricBranchBraces(), src);
	}

	private function wrap(body: String): String {
		return 'class C {\n\tfunction f(a:Bool, b:Bool, d:String, s:String):Void {\n\t\t$body\n\t}\n}';
	}

}
