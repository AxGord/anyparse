package unit.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.check.CondAssignMerge;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `cond-assign-merge` check: a statement-scope `#if … #else … #end` region whose every
 * arm is a single assignment to the SAME l-value (or a single declaration of the same local,
 * or a value `return` / `throw`) collapses into ONE statement whose value carries the
 * directives. `Info`, DEFAULT OFF.
 *
 * The EXIT arms additionally take a region with NO `#else` that is immediately followed by an
 * unconditional exit of the same keyword — the follower is the implicit else, dead inside the
 * region's conditions, and the merge consumes it. That shape is UNSOUND for the assignment and
 * declaration arms (both statements run, so the follower would win) and stays refused there.
 *
 * The gates all fail closed: a missing `#else` with no exit follower, an arm with zero or two
 * statements, a non-plain assignment, a chained `a = b = c`, a differing l-value / declaration
 * prefix, a `return` arm beside a `throw` one, a value-less `return;`, a value that itself holds
 * directives, a comment inside the merged span, and a region that is not a direct child of a
 * statement list are safe misses.
 */
class CondAssignMergeCheckTest extends Test {

	public function testAssignPairFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('#if mobile\n\t\tscale = 2;\n\t\t#else\n\t\tscale = 1.2;\n\t\t#end'));
		Assert.equals(1, vs.length);
		Assert.equals('cond-assign-merge', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals(
			'every branch of this conditional-compilation region assigns the same target - merge it into one assignment with a '
			+ 'conditional r-value',
			vs[0].message
		);
	}

	public function testFixAssignPair(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('#if mobile\n\t\tscale = 2;\n\t\t#else\n\t\tscale = 1.2;\n\t\t#end'));
		Assert.equals(1, es.length);
		Assert.equals('scale = #if mobile 2 #else 1.2 #end;', es[0].text);
	}

	/** An `#elseif` chain merges too, each clause keeping its own condition. */
	public function testFixElseifChain(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			wrap('#if mobile\n\t\tscale = 2;\n\t\t#elseif air\n\t\tscale = 3;\n\t\t#else\n\t\tscale = 1.2;\n\t\t#end')
		);
		Assert.equals(1, es.length);
		Assert.equals('scale = #if mobile 2 #elseif air 3 #else 1.2 #end;', es[0].text);
	}

	/** A dotted / indexed l-value merges as long as its text is identical in every arm. */
	public function testFixMemberLvalue(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('#if mobile\n\t\ta.b[0] = 2;\n\t\t#else\n\t\ta.b[0] = 3;\n\t\t#end'));
		Assert.equals(1, es.length);
		Assert.equals('a.b[0] = #if mobile 2 #else 3 #end;', es[0].text);
	}

	/** The declaration sibling: same keyword, name and type in every arm collapses to one declaration. */
	public function testFixVarDeclaration(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('#if mobile\n\t\tvar q: Int = 2;\n\t\t#else\n\t\tvar q: Int = 3;\n\t\t#end'));
		Assert.equals(1, es.length);
		Assert.equals('var q: Int = #if mobile 2 #else 3 #end;', es[0].text);
	}

	public function testFixFinalDeclaration(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('#if mobile\n\t\tfinal q = 2;\n\t\t#else\n\t\tfinal q = 3;\n\t\t#end'));
		Assert.equals(1, es.length);
		Assert.equals('final q = #if mobile 2 #else 3 #end;', es[0].text);
	}

	/** A missing `#else` leaves the assignment conditional — merging would make it unconditional. */
	public function testNoElseArmNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if mobile\n\t\tscale = 2;\n\t\t#end')).length);
	}

	/** An `#elseif` chain that never reaches `#else` is still a conditional assignment. */
	public function testElseifChainWithoutElseNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if mobile\n\t\tscale = 2;\n\t\t#elseif air\n\t\tscale = 3;\n\t\t#end')).length);
	}

	public function testEmptyArmNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if mobile\n\t\tscale = 2;\n\t\t#elseif air\n\t\t#else\n\t\tscale = 3;\n\t\t#end')).length);
	}

	public function testTwoStatementArmNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if mobile\n\t\tscale = 2;\n\t\tg();\n\t\t#else\n\t\tscale = 3;\n\t\t#end')).length);
	}

	public function testDifferentLvalueNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if mobile\n\t\tscale = 2;\n\t\t#else\n\t\tother = 3;\n\t\t#end')).length);
	}

	public function testCompoundAssignNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if mobile\n\t\tscale += 2;\n\t\t#else\n\t\tscale += 3;\n\t\t#end')).length);
	}

	/** `a = b = c` would leave the inner assignment inside the merged r-value. */
	public function testChainedAssignNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if mobile\n\t\ta = b = 2;\n\t\t#else\n\t\ta = b = 3;\n\t\t#end')).length);
	}

	/** A call statement is not a bare assignment. */
	public function testCallArmNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if mobile\n\t\tg(1);\n\t\t#else\n\t\tg(2);\n\t\t#end')).length);
	}

	/** A declaration with no initializer has no r-value to carry the directives. */
	public function testBareDeclarationNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if mobile\n\t\tvar q: Int;\n\t\t#else\n\t\tvar q: Int;\n\t\t#end')).length);
	}

	public function testDifferentDeclarationTypeNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if mobile\n\t\tvar q: Int = 2;\n\t\t#else\n\t\tvar q: Float = 3;\n\t\t#end')).length);
	}

	public function testDifferentDeclarationKeywordNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if mobile\n\t\tvar q = 2;\n\t\t#else\n\t\tfinal q = 3;\n\t\t#end')).length);
	}

	/** A multi-declarator arm (`var a = 1, b = 2;`) cannot be expressed as one conditional r-value. */
	public function testMultiDeclaratorNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if mobile\n\t\tvar a = 1, b = 2;\n\t\t#else\n\t\tvar a = 3, b = 4;\n\t\t#end')).length);
	}

	/** A declaration arm paired with an assignment arm is not one shape. */
	public function testMixedDeclarationAndAssignNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if mobile\n\t\tvar q = 2;\n\t\t#else\n\t\tq = 3;\n\t\t#end')).length);
	}

	/** An r-value that already carries directives would nest `#if` inside `#if`. */
	public function testNestedDirectiveRvalueNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if mobile\n\t\ta = #if air 1 #else 2 #end;\n\t\t#else\n\t\ta = 3;\n\t\t#end')).length);
	}

	/** A comment in the region cannot be placed in the merged form — the finding stays report-only. */
	public function testCommentInRegionReportOnly(): Void {
		final src: String = wrap('#if mobile\n\t\t// note\n\t\tscale = 2;\n\t\t#else\n\t\tscale = 1.2;\n\t\t#end');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.stringContains('comment', vs[0].message);
		Assert.equals(0, edits(src).length);
	}

	/** A block comment inside a branch is trivia too — same report-only outcome as a line comment. */
	public function testBlockCommentInRegionReportOnly(): Void {
		final src: String = wrap('#if mobile\n\t\tscale = 2; /* why */\n\t\t#else\n\t\tscale = 1.2;\n\t\t#end');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.stringContains('comment', vs[0].message);
		Assert.equals(0, edits(src).length);
	}

	/**
	 * A comment must not turn a header the SHAPE gate refuses into a report: the header is read
	 * with its comments removed, so the multi-line condition still refuses the whole region.
	 */
	public function testCommentWithMultiLineConditionNotFlagged(): Void {
		Assert.equals(
			0, violations(wrap('#if (mobile\n\t\t\t|| air)\n\t\t// note\n\t\tscale = 2;\n\t\t#else\n\t\tscale = 3;\n\t\t#end')).length
		);
	}

	/** A member-scope `#if` region wraps declarations, not statements — out of scope. */
	public function testMemberScopeRegionNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\t#if mobile\n\tvar a: Int = 1;\n\t#else\n\tvar a: Int = 2;\n\t#end\n}').length);
	}

	/** A `#`-carrying statement is refused outright — here a string that reads like a branch marker. */
	public function testDirectiveInStringLiteralNotFlagged(): Void {
		Assert.equals(0, violations(wrap("#if mobile\n\t\ta = '#else';\n\t\t#else\n\t\ta = 'x';\n\t\t#end")).length);
	}

	/**
	 * A marker inside the CONDITION diverts the scan before it can register the real `#else`,
	 * so the chain never ends in one and the region fails closed — verified to be the gate that
	 * fires first for this shape, not a later net.
	 */
	public function testMarkerInConditionNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if (v == "#if")\n\t\tx = 1;\n\t\t#else\n\t\tx = 2;\n\t\t#end')).length);
	}

	/**
	 * A `#if` in a COMMENT past the `#else` unbalances the scan, which then never reaches the
	 * region's own `#end` at depth 0 — the scan-termination gate, and the first one to fire
	 * here (no statement carries a `#`, and the comment gate would only have made it
	 * report-only).
	 */
	public function testUnbalancedMarkerInCommentNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if a\n\t\tx = 1;\n\t\t#else\n\t\t// #if looks nested\n\t\tx = 2;\n\t\t#end')).length);
	}

	/**
	 * A `#end` in a COMMENT is the first one the scan meets at depth 0, and the region text past
	 * it is more than that keyword — the terminator-identity gate, first to fire here.
	 */
	public function testEarlyEndMarkerInCommentNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if a\n\t\tx = 1;\n\t\t#else\n\t\t// #end looks final\n\t\tx = 2;\n\t\t#end')).length);
	}

	/**
	 * Two statements in one branch and an empty one BALANCE the arm count, so only the per-arm
	 * bounds check can reject this — the gate that pins each child to its own branch.
	 */
	public function testStatementOutsideItsBranchNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if a\n\t\tx = 1;\n\t\tx = 2;\n\t\t#elseif b\n\t\t#else\n\t\tx = 3;\n\t\t#end')).length);
	}

	/** A condition holding a STRING must survive verbatim — the header slice is never whitespace-normalised. */
	public function testFixStringInCondition(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			wrap('#if (haxe_ver >= "3.1.3")\n\t\ts = b.getString(0);\n\t\t#else\n\t\ts = b.readString(0);\n\t\t#end')
		);
		Assert.equals(1, es.length);
		Assert.equals('s = #if (haxe_ver >= "3.1.3") b.getString(0) #else b.readString(0) #end;', es[0].text);
	}

	/** A ternary r-value goes inline as written — the branch value is a whole expression, whatever its shape. */
	public function testFixTernaryRvalue(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			wrap('#if !html5\n\t\tloader = fast ? new A() : new B();\n\t\t#else\n\t\tloader = new C();\n\t\t#end')
		);
		Assert.equals(1, es.length);
		Assert.equals('loader = #if !html5 fast ? new A() : new B() #else new C() #end;', es[0].text);
	}

	/**
	 * A VALUE broken across lines merges too: it goes inline VERBATIM, newlines included, and the
	 * writer decides where the merged statement breaks — under `sameLine.conditionalExprFit` every
	 * branch gets its own directive line, so no continuation reads as part of a branch it does not
	 * belong to. Only the branch HEADERS still refuse a line break, having no such writer arm.
	 */
	public function testMultiLineValueFlagged(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap("#if a\n\t\ts = 'p'\n\t\t\t+ 'q';\n\t\t#else\n\t\ts = 'r';\n\t\t#end"));
		Assert.equals(1, es.length);
		Assert.equals("s = #if a 'p'\n\t\t\t+ 'q' #else 'r' #end;", es[0].text);
	}

	public function testMultiLineReturnValueFlagged(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap("#if a\n\t\treturn 'p'\n\t\t\t+ 'q';\n\t\t#end\n\t\treturn 'r';"));
		Assert.equals(1, es.length);
		Assert.equals("return #if a 'p'\n\t\t\t+ 'q' #else 'r' #end;", es[0].text);
	}

	/** A condition broken across lines cannot go inline verbatim. */
	public function testMultiLineConditionNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if (mobile\n\t\t\t|| air)\n\t\tscale = 2;\n\t\t#else\n\t\tscale = 3;\n\t\t#end')).length);
	}

	/** End-to-end through the canonical writer: the region is gone and the merged statement is there. */
	public function testFixOutputMerges(): Void {
		final out: String = applyFixOnce(wrap('#if mobile\n\t\tscale = 2;\n\t\t#else\n\t\tscale = 1.2;\n\t\t#end'));
		Assert.isTrue(out.indexOf('scale = #if mobile 2 #else 1.2 #end;') != -1);
		Assert.equals(-1, out.indexOf('#end\n'));
	}

	/** The merged inline form is a writer fixed point: a second canonicalize pass is byte-identical. */
	public function testMergedFormIsWriterIdempotent(): Void {
		final once: String = applyFixOnce(wrap('#if mobile\n\t\tscale = 2;\n\t\t#else\n\t\tscale = 1.2;\n\t\t#end'));
		Assert.equals(once, canonicalize(once, []));
		Assert.equals(once, canonicalize(canonicalize(once, []), []));
	}

	/** The RETURN shape: every branch a VALUE return collapses the same way, the keyword kept once. */
	public function testReturnPairFlagged(): Void {
		final vs: Array<Violation> = violations(wrap('#if release\n\t\treturn true;\n\t\t#else\n\t\treturn ssl();\n\t\t#end'));
		Assert.equals(1, vs.length);
		Assert.equals('cond-assign-merge', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals(
			'every branch of this conditional-compilation region exits with the same keyword - merge it into one statement with a '
			+ 'conditional value',
			vs[0].message
		);
	}

	public function testFixReturnPair(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('#if release\n\t\treturn true;\n\t\t#else\n\t\treturn ssl();\n\t\t#end'));
		Assert.equals(1, es.length);
		Assert.equals('return #if release true #else ssl() #end;', es[0].text);
	}

	public function testFixReturnElseifChain(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('#if a\n\t\treturn 1;\n\t\t#elseif b\n\t\treturn 2;\n\t\t#else\n\t\treturn 3;\n\t\t#end'));
		Assert.equals(1, es.length);
		Assert.equals('return #if a 1 #elseif b 2 #else 3 #end;', es[0].text);
	}

	/** The `throw` analog falls out of the same keyword-prefix split. */
	public function testFixThrowPair(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('#if a\n\t\tthrow new E(1);\n\t\t#else\n\t\tthrow new F(2);\n\t\t#end'));
		Assert.equals(1, es.length);
		Assert.equals('throw #if a new E(1) #else new F(2) #end;', es[0].text);
	}

	/** A value-less `return;` is a distinct kind with no value to carry the directives. */
	public function testVoidReturnArmNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if a\n\t\treturn;\n\t\t#else\n\t\treturn 1;\n\t\t#end')).length);
	}

	/** The merged statement carries ONE keyword, so a `return` arm beside a `throw` arm is refused. */
	public function testMixedExitKeywordsNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if a\n\t\treturn 1;\n\t\t#else\n\t\tthrow e;\n\t\t#end')).length);
	}

	public function testReturnBesideAssignNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if a\n\t\treturn 1;\n\t\t#else\n\t\tx = 2;\n\t\t#end')).length);
	}

	/**
	 * The IMPLICIT-else shape: a region with NO `#else` whose every present branch is a value
	 * return, immediately followed by an unconditional one — the follower is the else branch
	 * (dead inside the region's conditions, since the branch exits) and the merge consumes it.
	 */
	public function testImplicitElseReturnFlagged(): Void {
		final vs: Array<Violation> = violations(wrap("#if windows\n\t\treturn 'a';\n\t\t#end\n\t\treturn 'b';"));
		Assert.equals(1, vs.length);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.stringContains('implicit else', vs[0].message);
	}

	public function testFixImplicitElseReturn(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap("#if windows\n\t\treturn 'a';\n\t\t#end\n\t\treturn 'b';"));
		Assert.equals(1, es.length);
		Assert.equals("return #if windows 'a' #else 'b' #end;", es[0].text);
	}

	public function testFixImplicitElseElseifChain(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits(wrap('#if a\n\t\treturn 1;\n\t\t#elseif b\n\t\treturn 2;\n\t\t#end\n\t\treturn 3;'));
		Assert.equals(1, es.length);
		Assert.equals('return #if a 1 #elseif b 2 #else 3 #end;', es[0].text);
	}

	public function testFixImplicitElseThrow(): Void {
		final es: Array<{ span: Span, text: String }> = edits(wrap('#if a\n\t\tthrow new E();\n\t\t#end\n\t\tthrow new F();'));
		Assert.equals(1, es.length);
		Assert.equals('throw #if a new E() #else new F() #end;', es[0].text);
	}

	/** One keyword in the merged statement — a `return` region closed by a `throw` cannot use it. */
	public function testImplicitElseMixedExitKeywordsNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if a\n\t\treturn 1;\n\t\t#end\n\t\tthrow e;')).length);
	}

	/**
	 * The implicit-else shape is UNSOUND for the assignment arm: both statements execute and the
	 * follower — not the branch — wins. Only an EXITING branch makes the follower dead code.
	 */
	public function testImplicitElseAssignNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if a\n\t\tx = 1;\n\t\t#end\n\t\tx = 2;')).length);
	}

	/** Same unsoundness for the declaration arm. */
	public function testImplicitElseDeclarationNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if a\n\t\tvar q = 1;\n\t\t#end\n\t\tvar q = 2;')).length);
	}

	/** A follower that does not exit leaves the region's own exit conditional. */
	public function testImplicitElseNonExitFollowerNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if a\n\t\treturn 1;\n\t\t#end\n\t\tg();')).length);
	}

	/** A value-less `return;` follower has no value to carry into the merged statement. */
	public function testImplicitElseVoidReturnFollowerNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if a\n\t\treturn 1;\n\t\t#end\n\t\treturn;')).length);
	}

	/**
	 * A region that DOES reach `#else` never consumes the statement after it: the merged edit
	 * stops at `#end`, and the unconditional exit that follows survives.
	 */
	public function testExplicitElseDoesNotConsumeFollower(): Void {
		final src: String = wrap('#if a\n\t\treturn 1;\n\t\t#else\n\t\treturn 2;\n\t\t#end\n\t\treturn 3;');
		final es: Array<{ span: Span, text: String }> = edits(src);
		Assert.equals(1, es.length);
		Assert.equals('return #if a 1 #else 2 #end;', es[0].text);
		Assert.equals(src.indexOf('#end') + '#end'.length, es[0].span.to);
		Assert.isTrue(applyFixOnce(src).indexOf('return 3;') != -1);
	}

	/** The assignment analogue: an explicit-`#else` region leaves the assignment after it alone. */
	public function testExplicitElseAssignDoesNotConsumeFollower(): Void {
		final src: String = wrap('#if a\n\t\tx = 1;\n\t\t#else\n\t\tx = 2;\n\t\t#end\n\t\tx = 3;');
		final es: Array<{ span: Span, text: String }> = edits(src);
		Assert.equals(1, es.length);
		Assert.equals('x = #if a 1 #else 2 #end;', es[0].text);
		Assert.isTrue(applyFixOnce(src).indexOf('x = 3;') != -1);
	}

	/**
	 * The statement-list position gate is what keeps the implicit else in ONE statement list. A
	 * region under a BRACE-LESS `if` body is a child of that `if`, not of the enclosing block, so
	 * the exit after `#end` is not its follower — merging would delete a statement that runs
	 * whenever the `if` does not.
	 */
	public function testImplicitElseUnderBracelessIfNotFlagged(): Void {
		Assert.equals(0, violations(wrap('if (c)\n\t\t#if a\n\t\treturn 1;\n\t\t#end\n\t\treturn 2;')).length);
	}

	public function testImplicitElseUnderBracelessWhileNotFlagged(): Void {
		Assert.equals(0, violations(wrap('while (c)\n\t\t#if a\n\t\treturn 1;\n\t\t#end\n\t\treturn 2;')).length);
	}

	/** The exit keywords must agree in the other direction too. */
	public function testImplicitElseThrowRegionWithReturnFollowerNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if a\n\t\tthrow e;\n\t\t#end\n\t\treturn 2;')).length);
	}

	/** A comment INSIDE the region is in the merged span as much as one in the consumed gap. */
	public function testImplicitElseCommentInRegionReportOnly(): Void {
		final src: String = wrap('#if a\n\t\t// note\n\t\treturn 1;\n\t\t#end\n\t\treturn 2;');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.stringContains('comment', vs[0].message);
		Assert.equals(0, edits(src).length);
	}

	/** An exit region with an explicit `#else` obeys the same comment gate. */
	public function testCommentInExitRegionReportOnly(): Void {
		final src: String = wrap('#if a\n\t\treturn 1; // why\n\t\t#else\n\t\treturn 2;\n\t\t#end');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.stringContains('comment', vs[0].message);
		Assert.equals(0, edits(src).length);
	}

	/** A condition broken across lines refuses the exit arms too. */
	public function testMultiLineConditionExitArmNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if (a\n\t\t\t|| b)\n\t\treturn 1;\n\t\t#end\n\t\treturn 2;')).length);
	}

	/** With no statement after it the region has no implicit else at all. */
	public function testImplicitElseWithoutFollowerNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if a\n\t\treturn 1;\n\t\t#end')).length);
	}

	/**
	 * The implicit else is the IMMEDIATE next statement, never the first exit found by scanning
	 * forward. This shape trips the non-exit-follower gate as well, and cannot be made to trip
	 * adjacency alone: any intervening EXIT would itself be a sound follower.
	 */
	public function testImplicitElseFollowerNotAdjacentNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if a\n\t\treturn 1;\n\t\t#end\n\t\tg();\n\t\treturn 2;')).length);
	}

	/** A follower already carrying directives would nest them inside the merged statement. */
	public function testImplicitElseDirectiveInFollowerNotFlagged(): Void {
		Assert.equals(0, violations(wrap('#if a\n\t\treturn 1;\n\t\t#end\n\t\treturn #if b 2 #else 3 #end;')).length);
	}

	/** A comment between the region and its implicit else would be dropped — report-only. */
	public function testImplicitElseCommentBeforeFollowerReportOnly(): Void {
		final src: String = wrap('#if a\n\t\treturn 1;\n\t\t#end\n\t\t// note\n\t\treturn 2;');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.stringContains('comment', vs[0].message);
		Assert.equals(0, edits(src).length);
	}

	/** End-to-end through the canonical writer: the region AND the consumed follower are gone. */
	public function testFixOutputMergesImplicitElse(): Void {
		final out: String = applyFixOnce(wrap("#if windows\n\t\treturn 'a';\n\t\t#end\n\t\treturn 'b';"));
		Assert.isTrue(out.indexOf("return #if windows 'a' #else 'b' #end;") != -1);
		Assert.equals(-1, out.indexOf('#end\n'));
		Assert.equals(-1, out.indexOf("return 'b';"));
	}

	public function testMergedExitFormIsWriterIdempotent(): Void {
		final once: String = applyFixOnce(wrap("#if windows\n\t\treturn 'a';\n\t\t#end\n\t\treturn 'b';"));
		Assert.equals(once, canonicalize(once, []));
		Assert.equals(once, canonicalize(canonicalize(once, []), []));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testIsDefaultOff(): Void {
		Assert.isTrue(new CondAssignMerge() is DefaultOff);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('cond-assign-merge'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('cond-assign-merge'));
	}

	/** Wrap a statement body in a minimal parseable class + method. */
	private function wrap(body: String): String {
		return 'class C {\n\tfunction f() {\n\t\t$body\n\t}\n}';
	}

	private function violations(src: String): Array<Violation> {
		return new CondAssignMerge().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: CondAssignMerge = new CondAssignMerge();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

	/** Run `fix` and re-emit through the canonical writer — the `lint --fix` path in one pass. */
	private function applyFixOnce(src: String): String {
		return canonicalize(src, edits(src));
	}

	private function canonicalize(src: String, es: Array<{ span: Span, text: String }>): String {
		return switch RefactorSupport.canonicalize(src, es, true, new HaxeQueryPlugin(), null) {
			case Ok(text): text;
			case Err(message): throw message;
		};
	}

}
