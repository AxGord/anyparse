package unit.core;

import anyparse.core.Doc;
import anyparse.core.DocMeasure;
import utest.Assert;
import utest.Test;

/**
 * `DocMeasure.firstVisibleTextStartsWith` — the left-spine walker promoted out of
 * `WrapList` for the omega-arrow-block-body-open slice.
 *
 * The promotion completed its ctor table: `WrapList`'s private copy ended in
 * `case _: false`, which silently answered `false` for `Fill` and its two variants,
 * `CollapseBoolProbe`, `CollapseChainProbe` and `IfArrowContinuationFits`. Those six
 * now descend like their siblings. The widening is monotone (`false` becomes a real
 * verdict) and no existing consumer's fixture reaches them, so neither the suite nor
 * the formatter corpus can pin it — these cases do, one per newly-covered ctor.
 */
@:nullSafety(Strict)
final class DocMeasureFirstVisibleTextTest extends Test {

	public function new(): Void {
		super();
	}

	/** The base contract: the first visible `Text` leaf decides, and its FIRST char is what is compared. */
	public function testTextLeaf(): Void {
		Assert.isTrue(DocMeasure.firstVisibleTextStartsWith(Text('{'), '{'.code));
		Assert.isTrue(DocMeasure.firstVisibleTextStartsWith(Text('{ a: 1 }'), '{'.code));
		Assert.isFalse(DocMeasure.firstVisibleTextStartsWith(Text('a {'), '{'.code));
		Assert.isFalse(DocMeasure.firstVisibleTextStartsWith(Text(''), '{'.code));
	}

	/** Whitespace-only leaves carry no visible text: as the probed node they answer false, as list items they are skipped. */
	public function testWhitespaceOnlyLeavesAreTransparent(): Void {
		for (d in ([
			Empty,
			Line('\n'),
			OptSpace(' '),
			OptSpaceSkipAfterHardline,
			OptHardline,
			OptHardlineSkipAtOpenDelim,
			OptHardlineSkipBeforeHardline
		]: Array<Doc>)) Assert.isFalse(DocMeasure.firstVisibleTextStartsWith(d, '{'.code));
		Assert.isTrue(DocMeasure.firstVisibleTextStartsWith(Concat([Empty, Line('\n'), OptSpace(' '), Text('{')]), '{'.code));
	}

	/** The first NON-transparent item is final: a later `{` never rescues a leading non-`{` token. */
	public function testFirstNonTransparentItemDecides(): Void {
		Assert.isFalse(DocMeasure.firstVisibleTextStartsWith(Concat([Text('f('), Text('{')]), '{'.code));
		// An empty `Text` is not transparent — it stops the scan with a `false`.
		Assert.isFalse(DocMeasure.firstVisibleTextStartsWith(Concat([Text(''), Text('{')]), '{'.code));
	}

	/** Newly covered: all three `Fill` ctors are item lists whose separator never precedes item 0, so they scan like `Concat`. */
	public function testFillVariantsDescend(): Void {
		final items: Array<Doc> = [Text('{'), Text('a')];
		final sep: Doc = Text(', ');
		Assert.isTrue(DocMeasure.firstVisibleTextStartsWith(Fill(items, sep), '{'.code));
		Assert.isTrue(DocMeasure.firstVisibleTextStartsWith(FillWithRestProbe(items, sep), '{'.code));
		Assert.isTrue(DocMeasure.firstVisibleTextStartsWith(FillBreakAfterWrap(items, sep), '{'.code));
		Assert.isFalse(DocMeasure.firstVisibleTextStartsWith(Fill([Text('a'), Text('{')], sep), '{'.code));
	}

	/** Newly covered: the two collapse probes missing from the old table descend like their four already-covered siblings. */
	public function testCollapseProbesDescend(): Void {
		Assert.isTrue(DocMeasure.firstVisibleTextStartsWith(CollapseBoolProbe(Text('{')), '{'.code));
		Assert.isTrue(DocMeasure.firstVisibleTextStartsWith(CollapseChainProbe(Text('{')), '{'.code));
		Assert.isFalse(DocMeasure.firstVisibleTextStartsWith(CollapseBoolProbe(Text('a')), '{'.code));
	}

	/** Newly covered: `IfArrowContinuationFits` reads its FLAT side, like every other conditional in the table. */
	public function testArrowContinuationFitsReadsFlatSide(): Void {
		Assert.isTrue(DocMeasure.firstVisibleTextStartsWith(IfArrowContinuationFits(1, 4, 140, Text('a'), Text('{')), '{'.code));
		Assert.isFalse(DocMeasure.firstVisibleTextStartsWith(IfArrowContinuationFits(1, 4, 140, Text('{'), Text('a')), '{'.code));
	}

	/** Wrappers and the other conditionals: transparent / flat-side, unchanged by the move. */
	public function testWrappersAndConditionals(): Void {
		Assert.isTrue(DocMeasure.firstVisibleTextStartsWith(Group(Nest(1, BodyGroup(WrapBoundary(Text('{'))))), '{'.code));
		Assert.isTrue(DocMeasure.firstVisibleTextStartsWith(IfBreak(Text('a'), Text('{')), '{'.code));
		Assert.isTrue(DocMeasure.firstVisibleTextStartsWith(IfResidualLineExceeds(140, Text('a'), Text('{')), '{'.code));
	}

	/** The char code is a parameter, not a hardcoded `{` — `isMethodChainItem` asks the same walker for `.`. */
	public function testCharCodeIsParameterised(): Void {
		Assert.isTrue(DocMeasure.firstVisibleTextStartsWith(Concat([OptHardline, Text('.link(')]), '.'.code));
		Assert.isFalse(DocMeasure.firstVisibleTextStartsWith(Concat([OptHardline, Text('.link(')]), '{'.code));
	}

}
