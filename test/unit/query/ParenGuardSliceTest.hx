package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.Rewrite;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * Probe for `ParenGuard` through its one consumer, `apq rewrite`.
 *
 * The defect it closes: a replacement template is written in AST terms (`$A * 2`
 * reads "the capture, times two") but expands as TEXT, and text has no
 * precedence. Over the Haxe grammar, 400 of 1530 (capture shape x template
 * context) pairs used to come out meaning something else — silently, and
 * re-parseably.
 *
 * Each test below is one arm of that grid, plus the two directions the guard
 * must NOT take: a pair where none is needed, and a pair where none is legal.
 */
class ParenGuardSliceTest extends Test {

	/**
	 * The canonical case: a capture whose root binds looser than the template's
	 * operator. `v + 1 * 2` is `v + 2`; the template said `(v + 1) * 2`.
	 */
	public function testLooseCaptureGetsThePair(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfinal a = v + 1;\n\t}\n}';
		final text: String = okText(Rewrite.rewrite(src, "final a = $A;", "final a = $A * 2;", true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('final a = (v + 1) * 2;'), 'expected the capture parenthesised - got:\n$text');
	}

	/** An identifier binds tighter than anything, so `(v) * 2` must NOT happen. */
	public function testAtomicCaptureStaysBare(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfinal a = v;\n\t}\n}';
		final text: String = okText(Rewrite.rewrite(src, "final a = $A;", "final a = $A * 2;", true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('final a = v * 2;'), 'expected no pair around an identifier - got:\n$text');
	}

	/**
	 * `-1` is not an atom but still binds tighter than `*`: `-1 * 2` re-parses
	 * with `Neg` spanning exactly the capture, so the pair buys nothing. The
	 * minimality rule is per-CONTENT, not per-kind.
	 */
	public function testTighterOperatorCaptureStaysBare(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfinal a = -1;\n\t}\n}';
		final text: String = okText(Rewrite.rewrite(src, "final a = $A;", "final a = $A * 2;", true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('final a = -1 * 2;'), 'expected no pair around `-1` - got:\n$text');
	}

	/**
	 * The mirror hazard, and it needs no metavariable at all: the whole
	 * replacement lands in an operator context the PATTERN matched inside.
	 * `q * f(1)` rewritten by `f($A)` -> `$A + 1` used to emit `q * 1 + 1`.
	 */
	public function testReplacementRootIsGuardedAgainstTheSourceContext(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfinal a = q * f(1);\n\t}\n}';
		final text: String = okText(Rewrite.rewrite(src, "f($A)", "$A + 1", true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('final a = q * (1 + 1);'), 'expected the replacement parenthesised - got:\n$text');
	}

	/** A postfix context takes the whole receiver: `f(3).len` -> `(3 + 1).len`, never `3 + 1.len`. */
	public function testReplacementRootIsGuardedAgainstAPostfixContext(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfinal a = f(3).len;\n\t}\n}';
		final text: String = okText(Rewrite.rewrite(src, "f($A)", "$A + 1", true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('final a = (3 + 1).len;'), 'expected the replacement parenthesised - got:\n$text');
	}

	/**
	 * Both the root and the hole are unfaithful bare, but ONE pair fixes both:
	 * `q * ((v + 2) + 1)` is correct and `q * (v + 2 + 1)` is the same tree with
	 * one pair fewer. Pins the minimisation pass, not just the safety.
	 */
	public function testNestedSitesCollapseToOnePair(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfinal a = q * f(v + 2);\n\t}\n}';
		final text: String = okText(Rewrite.rewrite(src, "f($A)", "$A + 1", true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('final a = q * (v + 2 + 1);'), 'expected ONE pair, not two - got:\n$text');
	}

	/**
	 * A metavariable in a NAME position cannot take parentheses — `final (x) = 1`
	 * is not Haxe. The guard finds that out by parsing, not by knowing which
	 * positions are name positions.
	 */
	public function testNamePositionMetavarIsLeftAlone(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfinal abc:Int = 1;\n\t}\n}';
		final text: String = okText(Rewrite.rewrite(src, "final $x:Int = 1;", "final $x:Int = 2;", true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('final abc:Int = 2;'), 'a name must not be parenthesised - got:\n$text');
	}

	/**
	 * A TYPE position is the harder half of the same question: `final x:(Int)`
	 * does parse, so a "wrap whenever the tree changes" rule would write it. The
	 * content still spans `Int` bare, so the site is faithful and stays bare.
	 */
	public function testTypePositionMetavarIsLeftAlone(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfinal abc:Int = 1;\n\t}\n}';
		final text: String = okText(Rewrite.rewrite(src, "final abc:$t = 1;", "final abc:$t = 2;", true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('final abc:Int = 2;'), 'a type must not be parenthesised - got:\n$text');
	}

	/**
	 * Damage OUTSIDE the hole. `a is C` keeps its own `Is` node when `[0]` is
	 * appended — the `[0]` is what gets orphaned — so only the statement-level
	 * site notices, and a statement cannot take a pair. The repair pass answers
	 * by parenthesising the splice INSIDE the failing site instead.
	 */
	public function testDamageOutsideTheHoleIsRepairedFromInside(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfinal a = b is C;\n\t}\n}';
		final text: String = okText(Rewrite.rewrite(src, "final a = $A;", "final a = $A[0];", true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('final a = (b is C)[0];'), 'expected the capture parenthesised - got:\n$text');
	}

	/**
	 * A raw splice that does not parse at all is today's LOUD failure, not a
	 * silent one — `b is C < 5` reads `C < 5` as a type parameter. The pairs are
	 * its remedy too, so the rewrite now succeeds instead of refusing.
	 */
	public function testUnparseableRawSpliceIsRescued(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfinal a = b is C;\n\t}\n}';
		final text: String = okText(Rewrite.rewrite(src, "final a = $A;", "final a = $A < 5;", true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('final a = (b is C) < 5;'), 'expected the capture parenthesised - got:\n$text');
	}

	/**
	 * A call argument is bounded on both sides, so nothing can bind across it
	 * however loose the capture is. The guard must add nothing here — this is
	 * the shape every pre-existing `rewrite` test uses.
	 */
	public function testDelimitedPositionsAddNothing(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfoo(a + b, c ? d : e);\n\t}\n}';
		final text: String = okText(Rewrite.rewrite(src, "foo($x, $y)", "bar($y, $x)", true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('bar(c ? d : e, a + b)'), 'a delimited slot needs no pair - got:\n$text');
	}

	/** The `${x+N}` shift still expands, and its result is a splice site like any other. */
	public function testIntegerShiftStillExpands(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tg(3, 12);\n\t}\n}';
		final text: String = okText(Rewrite.rewrite(src, "g($l, $c)", "g($l, ${c+1})", true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('g(3, 13)'), 'expected the shifted literal - got:\n$text');
	}

	/**
	 * The one residual, pinned so a grammar fix flips it VISIBLY rather than
	 * quietly: the guard's oracle is this parser, and this parser models a bare
	 * `cast e` as bounded while the compiler binds it to the right. Measured
	 * against Haxe 4.3.7: `final s:String = cast o * 2;` compiles (the cast takes
	 * the product) and `(cast o) * 2` is "Int should be String". So the splice
	 * below is faithful to the TREE and not to the compiler, and stays bare.
	 * `@:meta e` — the other kind named alongside it in
	 * `rightGreedyExprKinds` — is NOT affected: this parser models it greedily,
	 * so the pair is added there.
	 */
	public function testBareCastIsTheKnownResidual(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tfinal a = cast o;\n\t\tfinal b = @:privateAccess o;\n\t}\n}';
		final text: String = okText(Rewrite.rewrite(src, "final $n = $A;", "final $n = $A * 2;", true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('final a = cast o * 2;'), 'the cast residual moved - got:\n$text');
		Assert.isTrue(text.contains('final b = (@:privateAccess o) * 2;'), 'metadata must take the pair - got:\n$text');
	}

	private function okText(res: EditResult): String {
		return switch res {
			case Ok(text): text;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				'';
		};
	}

}
