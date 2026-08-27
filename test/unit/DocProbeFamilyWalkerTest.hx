package unit;

import anyparse.core.Doc;
import anyparse.format.wrap.BinaryChainEmit;
import anyparse.format.wrap.WrapList;
import utest.Assert;
import utest.Test;

/**
 * PROBE FAMILY walker sweep — the eight spine walkers that enumerated the
 * `If*` ctors by hand and fell through `case _` for the four width probes of
 * the family documented on the `Doc` enum header
 * (`IfArrowContinuationFits`, `IfIndentWidthExceeds`,
 * `IfNaturalFirstLineExceeds`, `IfGluedFirstLineExceeds`).
 *
 * `IfNaturalFirstLineExceeds` already had an arm everywhere; the other three
 * did not, so each walker silently answered its default (`false` / `null` /
 * "not visited") for any subtree sitting behind one. The hole predates the
 * family — before ω-inc5-cont the ctors appeared only on single-arg arrow
 * calls — but ω-case-sibling-symmetry and ω-glue-width put one on every
 * coordinated case body and every glued construct body, so the walkers now
 * meet them routinely.
 *
 * Both corpora are 0-diff across the sweep, which is the byte net but also
 * the reason nothing in the end-to-end suite pins the new arms (the same
 * situation `DocMeasureFirstVisibleTextTest` records for its own promotion).
 * These cases pin them directly: every walker × newly-covered ctor is asserted
 * both to REACH the arm (the answer moves off the old default) and to read the
 * side the walker's contract picks. Most pairs need two assertions — a fixture
 * and its mirror — but where the walker returns a VALUE rather than a Bool
 * (`lastVisibleText`, `firstVisibleText`) one assertion does both jobs, since
 * the opposite branch carries a different token.
 *
 * SIDE per walker, derived from each walker's own contract rather than
 * copied from a neighbour:
 *
 * | walker | `IfArrowContinuationFits` | `IfIndentWidthExceeds` / `IfGluedFirstLineExceeds` |
 * |---|---|---|
 * | `BinaryChainEmit.leadingOperandOpensDelim` | flat | flat |
 * | `MethodChainEmit.endsWithLineComment` | break | break |
 * | `WrapList.lastVisibleText` | break | break |
 * | `WrapList.firstVisibleText` | flat | flat |
 * | `WrapList.firstVisibleTextIsFunctionKw` | flat | flat |
 * | `WrapList.hasTopLevelElse` | flat | BREAK (diverges — see below) |
 * | `WrapList.isMethodChainItem` | break | FLAT (diverges — see below) |
 * | `WrapList.isTopLevelChain` | break | break |
 *
 * The two body-placement probes wrap the SAME body object on both sides,
 * differing only in the separator before it, so a walker asking about
 * subtree CONTENT gets one answer either way and keeps its own established
 * side. The two divergences are the walkers that ask about SHAPE:
 * `hasTopLevelElse` counts `Nest` depth and only the break branch is
 * `Nest`-wrapped by construction; `isMethodChainItem` looks for a hardline
 * followed by a `.`, which the break branch's body separator would forge.
 */
@:nullSafety(Strict)
@:access(anyparse.format.wrap.BinaryChainEmit)
@:access(anyparse.format.wrap.MethodChainEmit)
@:access(anyparse.format.wrap.WrapList)
final class DocProbeFamilyWalkerTest extends Test {

	public function new(): Void {
		super();
	}

	/**
	 * `leadingOperandOpensDelim` reads the FLAT side of all three, its side for the
	 * whole conditional table. Both `IfArrowContinuationFits` layouts open with the
	 * list's own `Text(open)`, and the body probes' separators are leading layout
	 * atoms this walk skips, so the flat read is answer-identical — but it must be a
	 * read, not the old `false`.
	 */
	public function testLeadingOperandOpensDelimReadsFlatSide(): Void {
		Assert.isTrue(BinaryChainEmit.leadingOperandOpensDelim(IfArrowContinuationFits(1, 4, 140, Text('x'), Text('(a)'))));
		Assert.isFalse(BinaryChainEmit.leadingOperandOpensDelim(IfArrowContinuationFits(1, 4, 140, Text('(a)'), Text('x'))));
		Assert.isTrue(BinaryChainEmit.leadingOperandOpensDelim(IfIndentWidthExceeds(4, 140, bodyBreak(Text('x')), bodyGlue(Text('(a)')))));
		Assert.isFalse(BinaryChainEmit.leadingOperandOpensDelim(IfIndentWidthExceeds(4, 140, bodyBreak(Text('(a)')), bodyGlue(Text('x')))));
		Assert.isTrue(
			BinaryChainEmit.leadingOperandOpensDelim(IfGluedFirstLineExceeds(140, 1, bodyBreak(Text('x')), bodyGlue(Text('(a)'))))
		);
		Assert.isFalse(
			BinaryChainEmit.leadingOperandOpensDelim(IfGluedFirstLineExceeds(140, 1, bodyBreak(Text('(a)')), bodyGlue(Text('x'))))
		);
	}

	/**
	 * `WrapList.endsWithLineComment` reads the BREAK side of all three — its side
	 * for the whole conditional table — plus the two `Concat` shapes that decide
	 * WHICH walker is behind it. The last two assertions are the ones the
	 * now-deleted `MethodChainEmit` copy failed: reverting this predicate to that
	 * copy's `Concat` scan leaves the first six green and turns exactly those two
	 * red, which is what proves the veto is one answer and not two.
	 */
	public function testEndsWithLineCommentReadsBreakSide(): Void {
		Assert.isTrue(WrapList.endsWithLineComment(IfArrowContinuationFits(1, 4, 140, Text(' // c'), Text('x'))));
		Assert.isFalse(WrapList.endsWithLineComment(IfArrowContinuationFits(1, 4, 140, Text('x'), Text(' // c'))));
		Assert.isTrue(WrapList.endsWithLineComment(IfIndentWidthExceeds(4, 140, bodyBreak(Text(' // c')), bodyGlue(Text('x')))));
		Assert.isFalse(WrapList.endsWithLineComment(IfIndentWidthExceeds(4, 140, bodyBreak(Text('x')), bodyGlue(Text(' // c')))));
		Assert.isTrue(WrapList.endsWithLineComment(IfGluedFirstLineExceeds(140, 1, bodyBreak(Text(' // c')), bodyGlue(Text('x')))));
		Assert.isFalse(WrapList.endsWithLineComment(IfGluedFirstLineExceeds(140, 1, bodyBreak(Text('x')), bodyGlue(Text(' // c')))));
		// ω-item-close-trail: the WHOLE point of there being one predicate. This is
		// the shape `MethodChainEmit`'s own walker got wrong — its `Concat` scan
		// committed on the last non-LAYOUT child, so an `OptSpace` (or a
		// whitespace-only `Text`) parked after the comment made it answer `false`
		// while `WrapList` answered `true` about the identical Doc.
		Assert.isTrue(WrapList.endsWithLineComment(Concat([Text(' // c'), OptSpace(' ')])));
		Assert.isTrue(WrapList.endsWithLineComment(Concat([Text(' // c'), Text('   ')])));
	}

	/** `lastVisibleText` reads the BREAK side of all three — its side for the whole conditional table. */
	public function testLastVisibleTextReadsBreakSide(): Void {
		Assert.equals('}', WrapList.lastVisibleText(IfArrowContinuationFits(1, 4, 140, Text('}'), Text(')'))));
		Assert.equals('}', WrapList.lastVisibleText(IfIndentWidthExceeds(4, 140, bodyBreak(Text('}')), bodyGlue(Text(')')))));
		Assert.equals('}', WrapList.lastVisibleText(IfGluedFirstLineExceeds(140, 1, bodyBreak(Text('}')), bodyGlue(Text(')')))));
	}

	/** `firstVisibleText` and its `function`-keyword sibling read the FLAT side of all three. */
	public function testFirstVisibleTextWalkersReadFlatSide(): Void {
		Assert.equals('for', WrapList.firstVisibleText(IfArrowContinuationFits(1, 4, 140, Text('while'), Text('for'))));
		Assert.equals('for', WrapList.firstVisibleText(IfIndentWidthExceeds(4, 140, bodyBreak(Text('while')), bodyGlue(Text('for')))));
		Assert.equals('for', WrapList.firstVisibleText(IfGluedFirstLineExceeds(140, 1, bodyBreak(Text('while')), bodyGlue(Text('for')))));
		Assert.isTrue(WrapList.firstVisibleTextIsFunctionKw(IfArrowContinuationFits(1, 4, 140, Text('x'), Text('function'))));
		Assert.isFalse(WrapList.firstVisibleTextIsFunctionKw(IfArrowContinuationFits(1, 4, 140, Text('function'), Text('x'))));
		Assert.isTrue(
			WrapList.firstVisibleTextIsFunctionKw(IfIndentWidthExceeds(4, 140, bodyBreak(Text('x')), bodyGlue(Text('function'))))
		);
		Assert.isTrue(
			WrapList.firstVisibleTextIsFunctionKw(IfGluedFirstLineExceeds(140, 1, bodyBreak(Text('x')), bodyGlue(Text('function'))))
		);
	}

	/**
	 * `hasTopLevelElse` diverges: the body-placement probes are read on their BREAK
	 * side (the only `Nest`-wrapped one, so the body's own `else` stays at depth 1
	 * where an inner `if` belongs), `IfArrowContinuationFits` on its FLAT side (the
	 * opened layout is the one that buries the argument in the wrap engine's `Nest`).
	 */
	public function testHasTopLevelElseSideChoice(): Void {
		Assert.isFalse(WrapList.hasTopLevelElse(IfArrowContinuationFits(1, 4, 140, Text('else'), Text('x')), 0));
		Assert.isTrue(WrapList.hasTopLevelElse(IfArrowContinuationFits(1, 4, 140, Text('x'), Text('else')), 0));
		Assert.isTrue(WrapList.hasTopLevelElse(IfIndentWidthExceeds(4, 140, Text('else'), Text('x')), 0));
		Assert.isFalse(WrapList.hasTopLevelElse(IfIndentWidthExceeds(4, 140, Text('x'), Text('else')), 0));
		Assert.isTrue(WrapList.hasTopLevelElse(IfGluedFirstLineExceeds(140, 1, Text('else'), Text('x')), 0));
		Assert.isFalse(WrapList.hasTopLevelElse(IfGluedFirstLineExceeds(140, 1, Text('x'), Text('else')), 0));
	}

	/**
	 * The depth contract that makes the break-side read answer-equivalent to the old
	 * `case _: false`: with the emitters' real shapes, an `else` inside the body sits
	 * behind the break branch's `Nest` and is correctly attributed to an inner `if`
	 * — while the FLAT branch of a non-nested glue would have leaked it at depth 0.
	 *
	 * It does NOT discriminate against the arm's absence — the old default answered
	 * `false` as well, and that equivalence is what makes the arm byte-inert on the
	 * corpora. It DOES discriminate against flipping the arm to the flat side, which
	 * turns both fixtures `true`. `testHasTopLevelElseSideChoice` above is the case
	 * that proves the arm is reached at all.
	 */
	public function testBodyPlacementProbeKeepsInnerElseBelowTopLevel(): Void {
		final withElse: Doc = Concat([Text('if'), Text('(c)'), Text('a'), Text('else'), Text('b')]);
		Assert.isFalse(WrapList.hasTopLevelElse(IfIndentWidthExceeds(4, 140, bodyBreak(withElse), bodyGlue(withElse)), 0));
		Assert.isFalse(WrapList.hasTopLevelElse(IfGluedFirstLineExceeds(140, 1, bodyBreak(withElse), bodyGlue(withElse)), 0));
	}

	/**
	 * `isMethodChainItem` diverges the other way: the body-placement probes are read
	 * FLAT, because the break branch's own `Nest(cols, Concat([Line('\n'), body]))` is
	 * exactly the hardline-then-sibling shape this walker's dot-scan matches on — a
	 * break-side read would report the BODY's placement as a chain dot-break.
	 * `IfArrowContinuationFits` keeps the break side (its glued layout is the item's
	 * own outermost shape when the probe fires break).
	 */
	public function testIsMethodChainItemSideChoice(): Void {
		Assert.isTrue(WrapList.isMethodChainItem(IfArrowContinuationFits(1, 4, 140, chainShape(), Text('x'))));
		Assert.isFalse(WrapList.isMethodChainItem(IfArrowContinuationFits(1, 4, 140, Text('x'), chainShape())));
		Assert.isTrue(WrapList.isMethodChainItem(IfIndentWidthExceeds(4, 140, Text('x'), chainShape())));
		Assert.isFalse(WrapList.isMethodChainItem(IfIndentWidthExceeds(4, 140, chainShape(), Text('x'))));
		Assert.isTrue(WrapList.isMethodChainItem(IfGluedFirstLineExceeds(140, 1, Text('x'), chainShape())));
		Assert.isFalse(WrapList.isMethodChainItem(IfGluedFirstLineExceeds(140, 1, chainShape(), Text('x'))));
	}

	/**
	 * The shape the flat-side choice protects: a body glued behind a real `Nest` break
	 * is not a dot-break, even when the body's own first token starts with `.`.
	 *
	 * It does NOT discriminate against the arm's absence — the old default answered
	 * `false` here too — but it DOES discriminate against reading the break side,
	 * which turns both fixtures `true`. `testIsMethodChainItemSideChoice` above is
	 * the case that proves the arm is reached at all.
	 */
	public function testBodyPlacementProbeIsNotADotBreak(): Void {
		final dotBody: Doc = Text('.b()');
		Assert.isFalse(WrapList.isMethodChainItem(IfIndentWidthExceeds(4, 140, bodyBreak(dotBody), bodyGlue(dotBody))));
		Assert.isFalse(WrapList.isMethodChainItem(IfGluedFirstLineExceeds(140, 1, bodyBreak(dotBody), bodyGlue(dotBody))));
	}

	/**
	 * `isTopLevelChain` is the walker whose new reach can actually move output — it
	 * has no depth argument making the arm inert, and `BinaryChainEmit.emit` builds
	 * an `IfArrowContinuationFits` INSIDE the chain's own `WrapBoundary`, i.e. at
	 * exactly the depth this walk counts operators at. This fixture reproduces that
	 * emit signature rather than a bare `Text` leaf: before the sweep the probe
	 * blinded the walk and the answer was `false`; now the `+` is found, which is
	 * the honest answer and flips `emitCondition`'s cond-paren route and
	 * `shapeSoleArrowContGlue`'s suppression gate for such a body.
	 */
	public function testIsTopLevelChainSeesChainEmitArrowContinuationShape(): Void {
		final chain: Doc = Concat([Text('a'), Line(' '), Text('+ '), Text('(b - c)')]);
		final brk: Doc = Group(IfBreak(CollapseAddProbe(chain), chain));
		final glueProbe: Doc = IfNaturalFirstLineFitsOpenDelim(140, brk, chain);
		final emitted: Doc = WrapBoundary(IfLineExceeds(140, IfArrowContinuationFits(1, 12, 140, glueProbe, chain), chain));
		Assert.isTrue(WrapList.isTopLevelChain(emitted));
	}

	/** `isTopLevelChain` reads the BREAK side of all three; its operator `Text` counts only past a `WrapBoundary`. */
	public function testIsTopLevelChainReadsBreakSide(): Void {
		Assert.isTrue(WrapList.isTopLevelChain(WrapBoundary(IfArrowContinuationFits(1, 4, 140, Text('&&'), Text('x')))));
		Assert.isFalse(WrapList.isTopLevelChain(WrapBoundary(IfArrowContinuationFits(1, 4, 140, Text('x'), Text('&&')))));
		Assert.isTrue(WrapList.isTopLevelChain(WrapBoundary(IfIndentWidthExceeds(4, 140, Text('+'), Text('x')))));
		Assert.isFalse(WrapList.isTopLevelChain(WrapBoundary(IfIndentWidthExceeds(4, 140, Text('x'), Text('+')))));
		Assert.isTrue(WrapList.isTopLevelChain(WrapBoundary(IfGluedFirstLineExceeds(140, 1, Text('||'), Text('x')))));
		Assert.isFalse(WrapList.isTopLevelChain(WrapBoundary(IfGluedFirstLineExceeds(140, 1, Text('x'), Text('||')))));
	}

	/**
	 * Same sweep, second hole: eight `WrapList` walkers listed `CollapseProbe` and
	 * `CollapseAddProbe` among the render-transparent wrappers but not their two
	 * later siblings, contradicting both ctors' own doc ("all Doc walkers treat it
	 * as a transparent pass-through"). They descend now — including
	 * `bareArrowBodyBreaks` and `chainKeepFlatCandidate`, which the family sweep
	 * itself does not otherwise touch (`bareArrowBodyBreaks` already had an arm for
	 * every conditional; `chainKeepFlatCandidate` descends none of them by design)
	 * but which sit in the same file with the same marker gap —
	 * `chainKeepFlatCandidate` is evaluated as a PAIR with `isTopLevelChain` at both
	 * `emitCondition` sites, so leaving half the pair marker-blind is the drift this
	 * sweep exists to remove. `BinaryChainEmit` / `MethodChainEmit` already listed
	 * both markers, which is why no walker of theirs appears here.
	 */
	public function testLateCollapseProbesAreTransparent(): Void {
		Assert.equals('}', WrapList.lastVisibleText(CollapseBoolProbe(Text('}'))));
		Assert.equals('}', WrapList.lastVisibleText(CollapseChainProbe(Text('}'))));
		Assert.equals('for', WrapList.firstVisibleText(CollapseBoolProbe(Text('for'))));
		Assert.equals('for', WrapList.firstVisibleText(CollapseChainProbe(Text('for'))));
		Assert.isTrue(WrapList.firstVisibleTextIsFunctionKw(CollapseBoolProbe(Text('function'))));
		Assert.isTrue(WrapList.firstVisibleTextIsFunctionKw(CollapseChainProbe(Text('function'))));
		Assert.isTrue(WrapList.hasTopLevelElse(CollapseBoolProbe(Text('else')), 0));
		Assert.isTrue(WrapList.hasTopLevelElse(CollapseChainProbe(Text('else')), 0));
		Assert.isTrue(WrapList.isMethodChainItem(CollapseBoolProbe(chainShape())));
		Assert.isTrue(WrapList.isMethodChainItem(CollapseChainProbe(chainShape())));
		Assert.isTrue(WrapList.isTopLevelChain(WrapBoundary(CollapseBoolProbe(Text('&&')))));
		Assert.isTrue(WrapList.isTopLevelChain(WrapBoundary(CollapseChainProbe(Text('&&')))));
		Assert.isTrue(WrapList.bareArrowBodyBreaks(CollapseBoolProbe(Line('\n'))));
		Assert.isTrue(WrapList.bareArrowBodyBreaks(CollapseChainProbe(Line('\n'))));
		Assert.isTrue(WrapList.chainKeepFlatCandidate(WrapBoundary(CollapseBoolProbe(IfNaturalFirstLineFitsOpenDelim(140, Empty, Empty)))));
		Assert.isTrue(
			WrapList.chainKeepFlatCandidate(WrapBoundary(CollapseChainProbe(IfNaturalFirstLineFitsOpenDelim(140, Empty, Empty))))
		);
	}

	/** The emitters' break branch for both body-placement probes (`BodyFit`): the body one indent deeper after a hardline. */
	private static function bodyBreak(body: Doc): Doc {
		return Nest(1, Concat([Line('\n'), body]));
	}

	/** The emitters' flat branch for `BodyFit.glueLayout`: the body glued after the one-column separator, NO `Nest`. */
	private static function bodyGlue(body: Doc): Doc {
		return Concat([OptSpace(' '), body]);
	}

	/** A method-chain item shape — a hardline whose next sibling's first visible text starts with `.`. */
	private static function chainShape(): Doc {
		return Concat([Text('a'), Line('\n'), Text('.b()')]);
	}

}
