package unit.check;

import anyparse.check.MessageMask;
import utest.Assert;
import utest.Test;

/**
 * The two anchored masking primitives a `Check.VolatileMessage` builds its message identity
 * from. The rules' own declarations are pinned in each check's test, against a message that
 * check produced; what is locked here is the arithmetic those declarations lean on.
 *
 * Three properties matter and each has a case: a coordinate is masked as ONE unit even when it
 * is a `line:col` pair, an absent or unmatched anchor leaves the text byte-identical (the
 * failure direction — silent, and the reason the anti-drift pins exist), and neighbouring
 * numbers that are not at the anchor survive, since those are what the gate reads as findings.
 */
@:nullSafety(Strict)
class MessageMaskTest extends Test {

	public function testMaskAfterBlanksTheFollowingRun(): Void {
		Assert.equals('duplicated from line # — extract', MessageMask.maskAfter('duplicated from line 226 — extract', 'from line '));
	}

	public function testMaskAfterTakesALineColPairAsOneUnit(): Void {
		// `43:12` is one coordinate, not two numbers with a colon between them — masking it in
		// halves would leave a stray `:` in the key and read as two different findings for a
		// pair that only moved column.
		Assert.equals('re-declared at #, and', MessageMask.maskAfter('re-declared at 43:12, and', 're-declared at '));
	}

	public function testMaskAfterStopsAtANonDigitTail(): Void {
		Assert.equals('at #b and 7', MessageMask.maskAfter('at 12b and 7', 'at '), 'the run ends where the digits do');
		Assert.equals('at #b', MessageMask.maskAfter('at 12:3b', 'at '), 'a colon carries the run on only while digits follow it');
		Assert.equals('at #:x', MessageMask.maskAfter('at 12:x', 'at '), 'a colon with no digit after it is not part of the run');
	}

	public function testMaskBeforeBlanksThePrecedingRun(): Void {
		Assert.equals(
			'has 108 members (max 50) and # lines (max 2000) — a',
			MessageMask.maskBefore('has 108 members (max 50) and 4194 lines (max 2000) — a', ' lines (max ')
		);
	}

	public function testMaskBeforeLeavesTheNeighbouringCountAlone(): Void {
		// The whole reason the mask is anchored: the member count sits three words away from
		// the line extent and IS the finding this rule reports.
		Assert.equals(
			'has 108 members (max 50) and # lines (max 2000)',
			MessageMask.maskBefore('has 108 members (max 50) and 4194 lines (max 2000)', ' lines (max ')
		);
	}

	public function testMaskBeforeStopsAtANonDigitHead(): Void {
		Assert.equals(
			'src/B.hx:# — tail', MessageMask.maskBefore('src/B.hx:501 — tail', ' — tail'), 'a path is not part of the coordinate'
		);
	}

	public function testMaskBeforeDoesNotWalkBackThroughAColon(): Void {
		// The BEFORE direction masks ONE digit run, unlike the after direction. Walking back
		// over the `:` would swallow a partner path that ends in a digit, and then two clones
		// against DIFFERENT origin files would share a key — the disappearing-finding
		// direction the whole gate exists to catch.
		Assert.equals('src/v2:# — tail', MessageMask.maskBefore('src/v2:501 — tail', ' — tail'), 'the path digit is a different run');
		Assert.equals('src/v3:# — tail', MessageMask.maskBefore('src/v3:501 — tail', ' — tail'));
		Assert.notEquals(
			MessageMask.maskBefore('src/v2:501 — tail', ' — tail'), MessageMask.maskBefore('src/v3:501 — tail', ' — tail'),
			'two partners differing only in a trailing digit stay two keys'
		);
	}

	public function testMaskBeforeLeavesARunItAlreadyEmitted(): Void {
		// The `from < pos` guard, and the ONLY case that flips when it is removed. Without it
		// the second occurrence's run reaches back into text the first one already emitted and
		// `addSub` is handed a NEGATIVE length — silently empty on js, a throw on the jvm
		// target the portability probe builds.
		Assert.equals('#v1v1', MessageMask.maskBefore('9v1v1', 'v1'));
	}

	public function testAnAbsentAnchorIsANoOp(): Void {
		// The FAILURE direction, pinned on purpose: a reworded message orphans the anchor and
		// the text comes back untouched, silently. Nothing here can detect that — the per-check
		// pins are what do, by feeding in a message the check itself produced.
		final text: String = 'nothing to see here, 42 included';
		Assert.equals(text, MessageMask.maskAfter(text, 'at line '));
		Assert.equals(text, MessageMask.maskBefore(text, ' lines (max '));
	}

	public function testAnAnchorWithNoCoordinateIsANoOp(): Void {
		Assert.equals('at nowhere', MessageMask.maskAfter('at nowhere', 'at '));
		Assert.equals('abc tail', MessageMask.maskBefore('abc tail', ' tail'));
	}

	public function testAnEmptyAnchorIsANoOp(): Void {
		// Guards the scan's own termination as much as the semantics: an empty needle matches
		// at every position, so a loop that advanced by the anchor's length would not advance.
		Assert.equals('12 lines', MessageMask.maskAfter('12 lines', ''));
		Assert.equals('12 lines', MessageMask.maskBefore('12 lines', ''));
	}

	public function testEveryOccurrenceIsMasked(): Void {
		Assert.equals('at # then at #', MessageMask.maskAfter('at 5 then at 900', 'at '));
		Assert.equals('# px and # px', MessageMask.maskBefore('3 px and 40 px', ' px'));
	}

	public function testMaskingIsIdempotent(): Void {
		final once: String = MessageMask.maskAfter('from line 226 — x', 'from line ');
		Assert.equals(once, MessageMask.maskAfter(once, 'from line '));
		final twice: String = MessageMask.maskBefore('and 4194 lines (max 2000)', ' lines (max ');
		Assert.equals(twice, MessageMask.maskBefore(twice, ' lines (max '));
		// The shape that was NOT idempotent while the before direction walked back through a
		// colon: pass 1's guard blocked the second occurrence, pass 2's `#` freed it.
		final colon: String = MessageMask.maskBefore('1:1::a', ':');
		Assert.equals(colon, MessageMask.maskBefore(colon, ':'), 'an anchor this doc forbids is still stable');
	}

	public function testNonAsciiTextSurvivesTheCopy(): Void {
		// The masks copy non-coordinate stretches with `addSub` rather than one code unit at a
		// time: a per-character round trip reads ONE BYTE of a multi-byte character on a
		// byte-string target, and every real lint message carries an em dash.
		Assert.equals('от 5 до # — конец', MessageMask.maskAfter('от 5 до 900 — конец', 'до '));
	}

}
