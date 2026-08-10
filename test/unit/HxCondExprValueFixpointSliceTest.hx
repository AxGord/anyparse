package unit;

import utest.Assert;
import utest.Test;

using StringTools;

/**
 * A line break the parser consumed INSIDE an expression must not be reported as
 * a line break before whatever follows the expression.
 *
 * A Pratt / postfix loop that exits on no-match over a newline stashes it into
 * `pendingTrivia` so the next SIBLING's `collectTrivia` still sees it
 * (`ω-untyped-keep`). An operator matching right after that proves the newline
 * is interior — but the stash used to stand, and the next `collectTrivia`,
 * however far away, drained it. On a `@:fmt(padTrailing,
 * captureSourceNewlineAfter)` boundary that phantom signal emits a HARDLINE
 * where the source has a space.
 *
 * Two costs, one per test group below. The `#elseif` seams of a conditional
 * VALUE gain a break the source never had — and, worse, the writer stops being
 * its own fixed point on the shape `cond-assign-merge --fix` emits: pass 1
 * breaks the ternary (no stash yet), pass 2 reads those very `?`/`:` breaks
 * back in, leaks the signal onto the `#elseif` after the ternary and breaks
 * THERE instead. A fix whose output is not writer-canonical makes the next
 * writer-emit op refuse the file it just wrote.
 */
@:nullSafety(Strict)
final class HxCondExprValueFixpointSliceTest extends Test {

	private static final CONFIG: String = '{"indentation":{"character":"tab","tabWidth":4},"wrapping":{"maxLineLength":140}}';

	/** TM `src/api/APIDevice.hx` `get_deviceTypeId()` merged by `cond-assign-merge --fix`, verbatim. */
	private static final FLAT_RETURN: String = 'class Min {\n\tstatic function retArm():RegisteredDeviceTypeId {\n'
		+ '\t\treturn #if ios DEVICETYPE_IPAD #elseif android ChromebookUtils.isChromebook() ? DEVICETYPE_WINDOWSPC : DEVICETYPE_TABLET #elseif macos DEVICETYPE_MACOSXPC #elseif (windows || linux) DEVICETYPE_WINDOWSPC #else DEVICETYPE_WEB #end;\n'
		+ '\t}\n}';

	/** The same values on the pre-existing assignment arm — the divergence is the VALUE's, not the exit's. */
	private static final FLAT_ASSIGN: String = 'class Min {\n\tstatic function assignArm():Void {\n'
		+ '\t\tv = #if ios DEVICETYPE_IPAD #elseif android ChromebookUtils.isChromebook() ? DEVICETYPE_WINDOWSPC : DEVICETYPE_TABLET #elseif macos DEVICETYPE_MACOSXPC #elseif (windows || linux) DEVICETYPE_WINDOWSPC #else DEVICETYPE_WEB #end;\n'
		+ '\t}\n}';

	/**
	 * `FLAT_RETURN`'s one-pass layout: every `#elseif` seam glued, the
	 * over-wide ternary broken — and the `return` keyword glued to the value.
	 *
	 * ω-natural-trailwidth moved the break off the keyword: the probe that
	 * used to strand a bare `return` on its own line measured the value
	 * WITHOUT the statement's `;`, so the value resolved flat and its natural
	 * first line came out as the whole width. The `return` body now emits the
	 * rest-aware probe ctor, which counts that terminator, and the value
	 * breaks inside itself instead.
	 */
	private static final BROKEN_RETURN: String = 'class Min {\n\tstatic function retArm():RegisteredDeviceTypeId {\n'
		+ '\t\treturn #if ios DEVICETYPE_IPAD #elseif android ChromebookUtils.isChromebook()\n\t\t\t? DEVICETYPE_WINDOWSPC\n'
		+ '\t\t\t: DEVICETYPE_TABLET #elseif macos DEVICETYPE_MACOSXPC #elseif (windows || linux) DEVICETYPE_WINDOWSPC #else DEVICETYPE_WEB #end;\n'
		+ '\t}\n}';

	/** `#elseif c` is glued to the branch before it; only the interior gaps carry a newline. */
	private static final SEAM_GLUED: String =
		'class Min {\n\tstatic function f():Void {\n\t\tv = #if a XXXX #elseif b @BRANCH@ #elseif c ZZZZ #else WWWW #end;\n\t}\n}';

	public function new(): Void {
		super();
	}

	/**
	 * One pass reaches the fixed point, AND that point is the shape the flat
	 * source asks for: the `#elseif` seams stay glued (the source has no break
	 * at any of them) and only the over-wide android branch's ternary breaks.
	 * The un-fixed writer emitted exactly this on pass 1 and then re-flowed it
	 * on pass 2 to an `#elseif`-broken, ternary-flat shape — so idempotence is
	 * asserted alongside the layout rather than instead of it.
	 */
	public function testOverlongReturnValueSettlesInOnePass(): Void {
		final once: String = triviaWrite(FLAT_RETURN);
		Assert.equals(BROKEN_RETURN, once, 'return-arm value took the wrong layout');
		Assert.equals(once, triviaWrite(once), 'return-arm value is not a writer fixed-point');
	}

	/** Same, for the assignment arm. */
	public function testOverlongAssignedValueSettlesInOnePass(): Void {
		final once: String = triviaWrite(FLAT_ASSIGN);
		Assert.equals(once, triviaWrite(once), 'assignment-arm value is not a writer fixed-point');
	}

	/**
	 * INFIX arm: the left operand's own loop ate the gap before `==`, so the
	 * operator's span scan cannot see it and only the stash carries it. Un-fixed,
	 * `#elseif c` — glued in the source — came out on its own line.
	 */
	public function testInfixMatchDoesNotLeakAnInteriorNewline(): Void {
		Assert.equals(seam('foo == yy'), triviaWrite(seam('foo\n\t\t\t== yy')), 'infix operand newline leaked past the operator');
	}

	/**
	 * TERNARY arm, the `?` commit. Its leak lands one level deeper than the
	 * others: the then-branch's parse begins while the stash is still live, so
	 * the FIRST FIELD of an object literal there drains it and the literal breaks
	 * one field per line. (The `:` commit needs its own clear — the middle
	 * operand's loop exit re-stashes the gap before the separator; the two
	 * `#elseif`-seam fixed-point tests above cover that one.)
	 */
	public function testTernaryQuestionCommitDoesNotLeakIntoTheThenBranch(): Void {
		Assert.equals(
			seam('cc ? {k: 1, m: 2} : yy'), triviaWrite(seam('cc\n\t\t\t? {k: 1, m: 2} : yy')),
			'ternary condition newline leaked into the then-branch'
		);
	}

	/**
	 * The stash's `blankBefore` half travels with `newlineBefore` and has its own
	 * consumer, so the clear must drop both — otherwise the same leak survives
	 * every fixture above as a phantom BLANK line one field-list deeper.
	 */
	public function testInteriorBlankLineLeaksNoFurtherThanTheNewline(): Void {
		Assert.equals(
			seam('cc ? {k: 1, m: 2} : yy'), triviaWrite(seam('cc\n\n\t\t\t? {k: 1, m: 2} : yy')),
			'ternary condition blank line leaked into the then-branch'
		);
	}

	/**
	 * POSTFIX arm: the newline sits inside the suffix's RECEIVER (`(foo\n)`), and
	 * the matched `.bar` keeps the expression open.
	 */
	public function testSuffixMatchDoesNotLeakAnInteriorNewline(): Void {
		Assert.equals(seam('(foo).bar'), triviaWrite(seam('(foo\n\t\t\t).bar')), 'suffix receiver newline leaked past the suffix');
	}

	/** `SEAM_GLUED` with its `@BRANCH@` slot replaced by the branch body under test. */
	private inline function seam(branch: String): String {
		return SEAM_GLUED.replace('@BRANCH@', branch);
	}

	private inline function triviaWrite(src: String): String {
		return HxWriteFixture.triviaWrite(src, CONFIG);
	}

}
