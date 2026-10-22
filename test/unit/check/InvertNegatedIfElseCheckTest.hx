package unit.check;

import anyparse.check.Check;
import anyparse.check.InvertNegatedIfElse;
import anyparse.check.Linter;
import anyparse.check.PreferTernaryAssignment;
import anyparse.check.PreferTernaryExpression;
import anyparse.check.PreferTernaryReturn;
import anyparse.check.ReturnReassignTernary;
import anyparse.check.Severity;
import anyparse.query.CanonicalEdit;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The `invert-negated-if-else` check: an `if` STATEMENT with an `else` whose condition's
 * top-level node is a logical not (`if (!c) A else B`) is flagged `Info`. The autofix drops
 * the `!` and swaps the branches (`if (c) B else A`), a semantics-safe exact complement. A
 * no-`else` `if`, an else-if chain, a non-top-level `!`, and a condition-comment case are
 * not flagged.
 */
class InvertNegatedIfElseCheckTest extends Test {

	/** The most `--fix` passes `settle` runs before it calls the rules a ping-pong. */
	private static inline final MAX_SETTLE_PASSES: Int = 6;

	public function testNegatedIfElseFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Void {\n\t\tif (!a) x(); else y();\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('invert-negated-if-else', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this negated if-else can be inverted — drop the ! and swap the branches', vs[0].message);
	}

	public function testBracedIfElseFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tif (!a) { p(); } else { q(); }\n\t}\n}').length);
	}

	public function testParenWrappedConditionFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Void {\n\t\tif ((!a)) x(); else y();\n\t}\n}').length);
	}

	public function testNonNegatedNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (a) x(); else y();\n\t}\n}').length);
	}

	public function testNoElseNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (!a) x();\n\t}\n}').length);
	}

	public function testElseIfChainNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (!a) x(); else if (b) y(); else z();\n\t}\n}').length);
	}

	public function testTopLevelAndNotFlagged(): Void {
		// The `!` negates only `a`; the condition's top-level node is `&&`, not a not.
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (!a && b) x(); else y();\n\t}\n}').length);
	}

	public function testNotEqualNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (a != b) x(); else y();\n\t}\n}').length);
	}

	public function testConditionCommentNotFlagged(): Void {
		// A comment inside the condition would be dropped by the rebuilt condition, so skip.
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (!/* c */a) x(); else y();\n\t}\n}').length);
	}

	public function testFixInvertsAndSwaps(): Void {
		final es: Array<{ span: Span, text: String }> = edits('class C {\n\tfunction f():Void {\n\t\tif (!a) x(); else y();\n\t}\n}');
		Assert.equals(3, es.length);
		Assert.equals('a', es[0].text);
		Assert.equals('y();', es[1].text);
		Assert.equals('x();', es[2].text);
	}

	public function testFixUnwrapsOperandParen(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Void {\n\t\tif (!(a && b)) x(); else y();\n\t}\n}');
		Assert.equals('a && b', es[0].text);
	}

	public function testFixAppliedOutput(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (!a) x(); else y();\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tif (a) y(); else x();\n\t}\n}', CanonicalEdit.applyEdits(src, edits(src)));
	}

	public function testFixAppliedOutputBraced(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (!a) { p(); } else { q(); }\n\t}\n}';
		Assert.equals(
			'class C {\n\tfunction f():Void {\n\t\tif (a) { q(); } else { p(); }\n\t}\n}', CanonicalEdit.applyEdits(src, edits(src))
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('invert-negated-if-else'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('invert-negated-if-else'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	/** A comment INSIDE the kept operand travels with it, so the statement form is still inverted. */
	@:pin('control') @:killer('M-NEGCOND-COMMENT-WHOLE-COND')
	public function testStatementCommentInsideOperandTravels(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tif (!(a /* k */ && b)) x(); else y();\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tif (a /* k */ && b) y(); else x();\n\t}\n}', fixed(src));
	}

	public function testNegatedTernaryFlagged(): Void {
		final vs: Array<Violation> = violations(fn('final v = !a ? 1 : 2;'));
		Assert.equals(1, vs.length);
		Assert.equals('this negated ternary can be inverted — drop the ! and swap the branches', vs[0].message);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	@:pin('control') @:killer('M-INVERT-VALUE-LOOSE-SPAN')
	public function testNegatedTernaryFixed(): Void {
		Assert.equals(fn('final v = a ? 2 : 1;'), fixed(fn('final v = !a ? 1 : 2;')));
	}

	/** The client shape the task came from (`ThumbnailLoader`, anonymized): a call and a `null` swap places. */
	public function testNegatedTernaryReturnFixed(): Void {
		Assert.equals(fn('return d.has.t ? decode(d.node.t.data) : null;'), fixed(fn('return !d.has.t ? null : decode(d.node.t.data);')));
	}

	/** A redundant paren around the operand drops: `||` binds tighter than `?:`. */
	@:pin('control') @:killer('M-NEGCOND-PAREN-KEPT')
	public function testNegatedTernaryOperandParenDrops(): Void {
		Assert.equals(fn('final v = a || b ? 2 : 1;'), fixed(fn('final v = !(a || b) ? 1 : 2;')));
	}

	/** An operand that binds LOOSER than `?:` keeps its paren — the parse round-trip decides. */
	@:pin('control') @:killer('M-INVERT-VALUE-UNGUARDED')
	public function testNegatedTernaryAssignmentOperandKeepsParen(): Void {
		Assert.equals(fn('final v = (a = b) ? 2 : 1;'), fixed(fn('final v = !(a = b) ? 1 : 2;')));
	}

	/** A ternary moved into the else slot of another reads as a chain link; parenthesised, it is a plain value and swaps. */
	public function testNegatedTernaryParenthesisedNestedBranchSwaps(): Void {
		Assert.equals(fn('final v = a ? 3 : (b ? 1 : 2);'), fixed(fn('final v = !a ? (b ? 1 : 2) : 3;')));
	}

	@:pin('control') @:killer('M-INVERT-VALUE-CHAIN-SWAPPED')
	public function testTernaryChainNotFlagged(): Void {
		Assert.equals(0, violations(fn('final v = !a ? 1 : b ? 2 : 3;')).length);
		Assert.equals(0, violations(fn('final v = !a ? b ? 1 : 2 : 3;')).length);
	}

	/** Only a literal top-level `!`: a `!=`, and a `&&` whose operand is negated, keep their shape. */
	@:pin('control') @:killer('M-NEGCOND-ANY-KIND')
	public function testTernaryNonTopLevelNotNotFlagged(): Void {
		// A one-operand node that is not a not (`a.b` projects one child) is no negation either.
		Assert.equals(0, violations(fn('final v = a.b ? 1 : 2;')).length);
		Assert.equals(0, violations(fn('final v = -a ? 1 : 2;')).length);
		Assert.equals(0, violations(fn('final v = a != b ? 1 : 2;')).length);
		Assert.equals(0, violations(fn('final v = !a && b ? 1 : 2;')).length);
		Assert.equals(0, violations(fn('final v = a ? 1 : 2;')).length);
	}

	/** A comment the positive condition would drop leaves the ternary report-only. */
	@:pin('control') @:killer('M-NEGCOND-COMMENT-BEFORE-KEPT')
	public function testTernaryConditionCommentReportOnly(): Void {
		final src: String = fn('final v = !/* c */a ? 1 : 2;');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals(
			'this negated ternary can be inverted — drop the ! and swap the branches (a comment blocks the autofix)', vs[0].message
		);
		Assert.equals(0, edits(src).length);
	}

	/** A comment in the glue stays put while the branches move, so it would describe the other one: report-only. */
	@:pin('control') @:killer('M-INVERT-VALUE-GLUE-BEFORE-BLIND', 'M-INVERT-VALUE-GLUE-AFTER-BLIND')
	public function testTernaryGlueCommentReportOnly(): Void {
		for (src in [fn('final v = !a ? /* one */ 1 : 2;'), fn('final v = !a ? 1 /* one */ : 2;')]) {
			Assert.equals(1, violations(src).length);
			Assert.equals(0, edits(src).length);
		}
	}

	/** A comment inside the paren the positive condition drops, after the operand, is dropped too: report-only. */
	@:pin('control') @:killer('M-NEGCOND-COMMENT-AFTER-KEPT')
	public function testTernaryParenCommentReportOnly(): Void {
		final src: String = fn('final v = !(a /* k */) ? 1 : 2;');
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	/** A comment INSIDE a branch travels with it. */
	public function testTernaryBranchCommentTravels(): Void {
		Assert.equals(fn('final v = a ? 2 : f(/* one */ 1);'), fixed(fn('final v = !a ? f(/* one */ 1) : 2;')));
	}

	/** A report-only outer ternary is descended into: the inner one is rewritten. */
	@:pin('control') @:killer('M-INVERT-VALUE-NO-DESCEND')
	public function testReportOnlyTernaryDescended(): Void {
		Assert.equals(fn('final v = !/* c */a ? (b ? 2 : 1) : 3;'), fixed(fn('final v = !/* c */a ? (!b ? 1 : 2) : 3;')));
	}

	/** A fixable outer ternary stops the walk: the inner one surfaces on the next pass. */
	@:pin('control') @:killer('M-INVERT-VALUE-DESCEND-FIXED')
	public function testNestedNegatedTernaryOnePerPass(): Void {
		Assert.equals(1, violations(fn('final v = !a ? (!b ? 1 : 2) : 3;')).length);
	}

	public function testNegatedIfExpressionFixed(): Void {
		final src: String = fn('final v = if (!a) 1 else 2;');
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('this negated if-expression can be inverted — drop the ! and swap the branches', vs[0].message);
		Assert.equals(fn('final v = if (a) 2 else 1;'), fixed(src));
	}

	@:pin('control') @:killer('M-INVERT-VALUE-CHAIN-SWAPPED')
	public function testIfExpressionElseIfChainNotFlagged(): Void {
		Assert.equals(0, violations(fn('final v = if (!a) 1 else if (b) 2 else 3;')).length);
	}

	/**
	 * Under `keepDefaultElse` a negated ternary whose else arm is a default literal — each kind, in any
	 * zero spelling, in parentheses too — is neither reported nor rewritten: `!a ? x : null` keeps the
	 * fallback last. With the option off, and unset, each one inverts as before.
	 *
	 * RED under M-NEGCOND-KEEP-DEFAULT-BLIND (the gate never keeps), M-NEGCOND-KEEP-DEFAULT-NO-PAREN
	 * (`(null)`), and M-DEFLIT-NULL-DROPPED / M-DEFLIT-FALSE-DROPPED / M-DEFLIT-ZERO-DROPPED /
	 * M-DEFLIT-EMPTY-STRING-DROPPED (that literal is no default).
	 */
	@:pin('control')
	@:killer('M-NEGCOND-KEEP-DEFAULT-BLIND', 'M-NEGCOND-KEEP-DEFAULT-NO-PAREN', 'M-DEFLIT-NULL-DROPPED', 'M-DEFLIT-FALSE-DROPPED')
	@:killer('M-DEFLIT-ZERO-DROPPED', 'M-DEFLIT-EMPTY-STRING-DROPPED')
	public function testKeepDefaultElseKeepsADefaultTernaryElse(): Void {
		for (lit in ['null', 'false', '0', '0.0', '-0', '0x0', '""', "''", '(null)', '((0))']) {
			final src: String = fn('final v = !a ? x : $lit;');
			final kept: FixRun = keeping(src, true);
			Assert.equals(0, kept.violations.length, '$lit is a default else arm');
			Assert.equals(0, kept.edits.length, '$lit is not rewritten');
			Assert.equals(1, keeping(src, false).violations.length, 'option off: $lit inverts');
			Assert.equals(1, violations(src).length, 'option unset: $lit inverts');
		}
	}

	/** The value `if` reads the same gate as the ternary: its default else arm stays last. */
	@:pin('control')
	@:killer('M-NEGCOND-KEEP-DEFAULT-BLIND')
	public function testKeepDefaultElseKeepsADefaultIfExpressionElse(): Void {
		final src: String = fn('final v = if (!a) x else "";');
		Assert.equals(0, keeping(src, true).violations.length);
		Assert.equals(fn('final v = if (a) "" else x;'), keptFixed(src, false));
	}

	/**
	 * An `if` statement keeps its negation when its else branch returns a default literal, bare or as the
	 * sole statement of a block. Any other else statement — a default-valued assignment, a bare `null;`,
	 * a non-default return — is no default arm and still inverts.
	 *
	 * RED under M-NEGCOND-KEEP-DEFAULT-NO-RETURN (both returns) and M-NEGCOND-KEEP-DEFAULT-NO-BLOCK (the
	 * braced one).
	 */
	@:pin('control')
	@:killer('M-NEGCOND-KEEP-DEFAULT-NO-RETURN', 'M-NEGCOND-KEEP-DEFAULT-NO-BLOCK')
	public function testKeepDefaultElseKeepsAStatementReturningADefault(): Void {
		for (body in [
			'if (!a) return x; else return null;',
			'if (!a) { g(); return x; } else { return false; }'
		]) Assert.equals(0, keeping(fn(body), true).violations.length, body);
		for (body in [
			'if (!a) y = 1; else y = null;',
			'if (!a) g(); else null;',
			'if (!a) return x; else return y;'
		]) Assert.equals(1, keeping(fn(body), true).violations.length, body);
	}

	/**
	 * Only the CURRENT else arm counts. A non-default else still inverts under the option, and a default in
	 * the THEN arm moves last — exactly the inversion the option wants — in every shape.
	 *
	 * RED under M-NEGCOND-KEEP-DEFAULT-ANY-LITERAL (every value kept) and each M-INVERT-KEEP-DEFAULT-*-THEN-ARM
	 * (the gate asked about the then arm).
	 */
	@:pin('control')
	@:killer('M-NEGCOND-KEEP-DEFAULT-ANY-LITERAL', 'M-INVERT-KEEP-DEFAULT-STATEMENT-THEN-ARM', 'M-INVERT-KEEP-DEFAULT-VALUE-THEN-ARM')
	public function testKeepDefaultElseInvertsANonDefaultElse(): Void {
		for (lit in ['1', 'true', '"s"', '-1', '0.5', 'y', 'f()'])
			Assert.equals(1, keeping(fn('final v = !a ? x : $lit;'), true).violations.length, lit);
		Assert.equals(fn('final v = a ? x : null;'), keptFixed(fn('final v = !a ? null : x;'), true));
		Assert.equals(fn('final v = if (a) x else 0;'), keptFixed(fn('final v = if (!a) 0 else x;'), true));
		Assert.equals(fn('if (a) return x; else return null;'), keptFixed(fn('if (!a) return null; else return x;'), true));
	}

	/**
	 * `keepDefaultElse` is OFF unless a project sets it: no existing configuration changes behaviour.
	 *
	 * RED under M-NEGCOND-KEEP-DEFAULT-ON (the option read as on when unset).
	 */
	@:pin('control')
	@:killer('M-NEGCOND-KEEP-DEFAULT-ON')
	public function testKeepDefaultElseIsOffByDefault(): Void {
		final src: String = fn('final v = !a ? x : null;');
		Assert.equals(fn('final v = a ? null : x;'), CheckFixture.fixedUnder(new InvertNegatedIfElse(), src, '{"rules":{}}'));
		Assert.equals(fn('final v = a ? null : x;'), fixed(src));
	}

	/**
	 * Under `defaultLast` a choice whose THEN arm is a default literal and whose else arm is no literal is
	 * turned around so the default goes last: an atom gains a bare `!`, an `==` / `!=` flips, in a ternary,
	 * a value `if` and an `if` statement returning both values (bare or braced). An interpolating string computes
	 * its value, so it is no literal.
	 *
	 * RED under M-NEGCOND-SWAP-DEFAULT-LAST-DROPPED (the swap never asks the turn),
	 * M-NEGCOND-SWAP-DEFAULT-LAST-ARMS-SWAPPED (the turn asked about the else arm) and
	 * M-NEGCOND-DEFAULT-LAST-INTERPOLATION-AS-LITERAL (an interpolating string read as a literal).
	 */
	@:pin('control')
	@:killer('M-NEGCOND-SWAP-DEFAULT-LAST-DROPPED', 'M-NEGCOND-SWAP-DEFAULT-LAST-ARMS-SWAPPED')
	@:killer('M-NEGCOND-DEFAULT-LAST-INTERPOLATION-AS-LITERAL')
	public function testDefaultLastTurnsADefaultFirstChoice(): Void {
		for (pair in [
			['final v = hasNext ? null : e;', 'final v = !hasNext ? e : null;'],
			['final v = a != b ? null : x;', 'final v = a == b ? x : null;'],
			['final v = a == b ? 0 : f();', 'final v = a != b ? f() : 0;'],
			['final v = o.f(x) ? false : y;', 'final v = !o.f(x) ? y : false;'],
			['final v = (a) ? "" : y;', 'final v = !a ? y : "";'],
			['final v = a[0] ? (null) : y;', 'final v = !a[0] ? y : (null);'],
			["final v = a ? null : '${o.id}';", "final v = !a ? '${o.id}' : null;"],
			["final v = a ? '' : 'x$y';", "final v = !a ? 'x$y' : '';"],
			['final v = if (a) null else x;', 'final v = if (!a) x else null;'],
			['if (a) return null; else return x;', 'if (!a) return x; else return null;'],
			[
				'if (a.b) { return 0; } else { return x; }',
				'if (!a.b) { return x; } else { return 0; }'
			]
		]) Assert.equals(fn(pair[1]), lastFixed(fn(pair[0])), pair[0]);
	}

	/**
	 * The turn says which direction it is: the default-last messages, not the negation ones.
	 *
	 * RED under M-INVERT-DEFAULT-LAST-VALUE-MESSAGE and M-INVERT-DEFAULT-LAST-STATEMENT-MESSAGE.
	 */
	@:pin('control')
	@:killer('M-INVERT-DEFAULT-LAST-VALUE-MESSAGE', 'M-INVERT-DEFAULT-LAST-STATEMENT-MESSAGE')
	public function testDefaultLastMessages(): Void {
		Assert.equals(
			'this ternary puts the default first — invert the condition so the default goes last',
			lasting(fn('final v = a ? null : x;')).violations[0].message
		);
		Assert.equals(
			'this if-expression puts the default first — invert the condition so the default goes last',
			lasting(fn('final v = if (a) null else x;')).violations[0].message
		);
		Assert.equals(
			'this if-else returns the default first — invert the condition so the default goes last',
			lasting(fn('if (a) return null; else return x;')).violations[0].message
		);
		Assert.equals(
			'this negated ternary can be inverted — drop the ! and swap the branches',
			lasting(fn('final v = !a ? null : x;')).violations[0].message
		);
	}

	/**
	 * What is not turned: two literals (a mapping), a non-default then arm, a condition that would need a wrap
	 * or a De Morgan rewrite (a compound, an ordered comparison, an `is`), a bool-literal condition, a not the
	 * strip handles, and arms of which only one is a `return`.
	 *
	 * RED under M-NEGCOND-DEFAULT-LAST-BOTH-LITERALS, M-NEGCOND-DEFAULT-LAST-THEN-ANY,
	 * M-NEGCOND-DEFAULT-LAST-ANY-COND, M-NEGCOND-DEFAULT-LAST-BOOL-COND and M-NEGCOND-DEFAULT-LAST-RETURN-MISMATCH.
	 */
	@:pin('control')
	@:killer('M-NEGCOND-DEFAULT-LAST-BOTH-LITERALS', 'M-NEGCOND-DEFAULT-LAST-THEN-ANY', 'M-NEGCOND-DEFAULT-LAST-ANY-COND')
	@:killer('M-NEGCOND-DEFAULT-LAST-BOOL-COND', 'M-NEGCOND-DEFAULT-LAST-RETURN-MISMATCH')
	public function testDefaultLastLeavesWhatItCannotTurn(): Void {
		for (body in [
			'final v = a ? 0.0 : 1.0;',
			'final v = a ? null : "x";',
			"final v = a ? null : 'plain';",
			'final v = a ? 0 : -1;',
			'final v = a ? false : true;',
			'final v = a ? x : y;',
			'final v = a ? x : null;',
			'final v = a && b ? null : x;',
			'final v = a || b ? null : x;',
			'final v = a < b ? null : x;',
			'final v = (a is B) ? null : x;',
			'final v = true ? null : x;',
			'if (a) return null; else g();',
			'if (a) return null; else { g(); return x; }'
		]) Assert.equals(0, lasting(fn(body)).violations.length, body);
	}

	/**
	 * `defaultLast` is OFF unless a project sets it, and `keepDefaultElse` alone does not turn anything.
	 *
	 * RED under M-NEGCOND-DEFAULT-LAST-ON (the option read as on when unset).
	 */
	@:pin('control')
	@:killer('M-NEGCOND-DEFAULT-LAST-ON')
	public function testDefaultLastIsOffByDefault(): Void {
		final src: String = fn('final v = a ? null : x;');
		Assert.equals(0, violations(src).length);
		Assert.equals(0, CheckFixture.fixRunUnder(new InvertNegatedIfElse(), src, '{"rules":{}}').violations.length);
		Assert.equals(0, keeping(src, true).violations.length);
	}

	/**
	 * `defaultLast` implies `keepDefaultElse`: the form it writes is never inverted back, by the swap or by a
	 * ternary builder orienting a negated guard.
	 *
	 * RED under M-NEGCOND-DEFAULT-LAST-NO-KEEP.
	 */
	@:pin('control')
	@:killer('M-NEGCOND-DEFAULT-LAST-NO-KEEP')
	public function testDefaultLastImpliesKeepDefaultElse(): Void {
		for (body in [
			'final v = !a ? x : null;',
			'final v = if (!a) x else null;',
			'if (!a) return x; else return null;'
		]) Assert.equals(0, lasting(fn(body)).violations.length, body);
		Assert.equals(
			'return !a ? x : null;',
			CheckFixture.soleEditUnder(new PreferTernaryReturn(), fn('if (!a) return x;\n\t\treturn null;'), lastConfig())
		);
	}

	/**
	 * With `defaultLast` on, `--fix` over the swap and the four ternary builders settles: every pass after
	 * the last change makes no edit, and every shape ends default-last — the builders' default-first output
	 * is turned, and nothing turns it back.
	 */
	public function testDefaultLastFixReachesAFixedPoint(): Void {
		for (pair in [
			['final v = a ? null : x;', 'final v = !a ? x : null;'],
			['final v = !a ? x : null;', 'final v = !a ? x : null;'],
			['final v = !a ? null : x;', 'final v = a ? x : null;'],
			['final v = a != b ? null : x;', 'final v = a == b ? x : null;'],
			['final v = if (a) null else x;', 'final v = !a ? x : null;'],
			['if (a) return null;\n\t\treturn x;', 'return !a ? x : null;'],
			['if (!a) return x;\n\t\treturn null;', 'return !a ? x : null;'],
			['if (a) return null; else return x;', 'if (!a) return x; else return null;'],
			['if (a) y = null; else y = x;', 'y = !a ? x : null;'],
			[
				'var r:Null<Int> = g();\n\t\tif (a) r = null;\n\t\treturn r;',
				'var r:Null<Int> = g();\n\t\treturn !a ? r : null;'
			],
			[
				'final r:Null<Int> = if (a) null else x;\n\t\treturn r;',
				'final r:Null<Int> = !a ? x : null;\n\t\treturn r;'
			]
		]) {
			final settled: { text: String, passes: Int } = settle(fn(pair[0]));
			Assert.equals(fn(pair[1]), settled.text, pair[0]);
			Assert.isTrue(settled.passes <= 3, '${pair[0]}: settled in ${settled.passes} passes');
		}
	}

	/** `src` fixed by the swap and the four ternary builders under `defaultLast`, pass after pass until one changes nothing. */
	private function settle(src: String): { text: String, passes: Int } {
		final checks: Array<Check> = [
			new InvertNegatedIfElse(),
			new PreferTernaryReturn(),
			new ReturnReassignTernary(),
			new PreferTernaryAssignment(),
			new PreferTernaryExpression()
		];
		var text: String = src;
		for (pass in 1...MAX_SETTLE_PASSES + 1) {
			final before: String = text;
			for (check in checks) text = CheckFixture.fixedUnder(check, text, lastConfig());
			if (text == before) return { text: text, passes: pass };
		}
		Assert.fail('no fixed point in $MAX_SETTLE_PASSES passes: $text');
		return { text: text, passes: MAX_SETTLE_PASSES };
	}

	/** One `--fix` pass over `src` with `defaultLast` on. */
	private function lasting(src: String): FixRun {
		return CheckFixture.fixRunUnder(new InvertNegatedIfElse(), src, lastConfig());
	}

	/** `src` after one `--fix` pass with `defaultLast` on. */
	private function lastFixed(src: String): String {
		return CheckFixture.fixedUnder(new InvertNegatedIfElse(), src, lastConfig());
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new InvertNegatedIfElse(), src);
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: InvertNegatedIfElse = new InvertNegatedIfElse();
		return CheckFixture.edits(check, src);
	}

	private function fn(body: String): String {
		return 'class C {\n\tfunction f():Int {\n\t\t$body\n\t}\n}';
	}

	private function fixed(src: String): String {
		return CheckFixture.fixedSource(new InvertNegatedIfElse(), src);
	}

	/** One `--fix` pass over `src` with `keepDefaultElse` set to `on`. */
	private function keeping(src: String, on: Bool): FixRun {
		return CheckFixture.fixRunUnder(new InvertNegatedIfElse(), src, keepConfig(on));
	}

	/** `src` after one `--fix` pass with `keepDefaultElse` set to `on`. */
	private function keptFixed(src: String, on: Bool): String {
		return CheckFixture.fixedUnder(new InvertNegatedIfElse(), src, keepConfig(on));
	}

	/** The `apqlint.json` text setting `invert-negated-if-else` `keepDefaultElse` to `on`. */
	public static function keepConfig(on: Bool): String {
		return '{"rules":{"invert-negated-if-else":{"keepDefaultElse":$on}}}';
	}

	/** The `apqlint.json` text setting `invert-negated-if-else` `defaultLast`. */
	public static function lastConfig(): String {
		return '{"rules":{"invert-negated-if-else":{"defaultLast":true}}}';
	}

}
