package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit.EditResult;
import haxe.Exception;
import utest.Assert;
import utest.Test;

/**
 * `CommentOwnerGuard.detachedComment` — the comment-attachment half of the writer-emit gate,
 * asked from `canonicalize` next to `BodySlotGuard` and `docSplittingEdit`.
 *
 * The clause: an autofix must preserve more than "the result re-parses", and this is the third
 * thing the parse gate cannot see. `BodySlotGuard` pins which statements a brace-less construct
 * governs; `docSplittingEdit` pins whose declaration a doc block documents; this pins that a
 * comment keeps the code it stands above.
 *
 * The measured incident is `prefer-ternary-return` marching up the six-gate cascade in this
 * repo's own `MemberOrder.reorderRefusal` — 10 edits over 7 passes that welded two per-gate
 * explanations into one block above a seven-level ternary pyramid, one of them the note warning
 * against exactly that transformation. It re-parsed, it was byte-canonical, `fmt --list` was
 * clean and every lint rule was silent, so the only thing that could have caught it was a human
 * re-reading the file.
 *
 * The criterion is positive and textual: two comment BLOCKS are two blocks because code stands
 * between them, so an edit that leaves both in ONE block has deleted that code from between them
 * and at least one of the two no longer leads what it documented. It says nothing about an edit
 * that REWRITES the code under a single block, which is the shape every ordinary autofix has —
 * `testInPlaceRewriteUnderOneCommentIsAccepted` is that control, and a criterion built on "the
 * text after the comment changed" would have failed it.
 *
 * NOT pinned here, deliberately: the pre-filter (`removesGapCode`, the `before.length < 2`
 * early-out) is a COST gate and nothing else — a pure insertion cannot weld two source blocks
 * together, so removing the filter changes no verdict and no test can kill it. Saying so is
 * worth more than a control that would pass either way.
 */
class CommentOwnerGuardSliceTest extends Test {

	/** Two own-line comments with one statement between them — the minimum shape a weld needs. */
	private static final TWO_BLOCKS: String =
		'class C {\n\tfunction f(): Void {\n\t\ta();\n\t\t// why b\n\t\tb();\n\t\t// why c\n\t\tc();\n\t}\n}\n';

	/**
	 * The run-of-ONE fold, with the comment BETWEEN the guard and the return — one comment block,
	 * so the weld criterion is structurally unable to speak about it. Every token the carry tests
	 * declare (`gate()`, `11`, `22`) occurs exactly once, which is what lets a fixture state a
	 * span as the text it is written as.
	 */
	private static final CARRY_SOURCE: String =
		'class C {\n\tfunction f(): Int {\n\t\tif (gate()) return 11;\n\t\t// why zero\n\t\treturn 22;\n\t}\n}\n';

	/** The region `prefer-ternary-return` replaces for `CARRY_SOURCE`. */
	private static final FOLDED_REGION: String = 'if (gate()) return 11;\n\t\t// why zero\n\t\treturn 22;';

	/** What that rule writes there: the comment stacked in front of the three ranges it quotes. */
	private static final HOISTED: String = '// why zero\n\t\treturn gate() ? 11 : 22;';

	/** The same region rewritten AROUND the comment, which must stay accepted. */
	private static final REWRITTEN_IN_PLACE: String = 'if (gate()) return 11;\n\t\t// why zero\n\t\treturn 22 + 1;';

	/** One comment leading a pair the ternary fold rewrites in place. */
	private static final ONE_BLOCK: String =
		'class C {\n\tfunction f(a: Bool): Int {\n\t\t// why the guard\n\t\tif (a) return 1;\n\t\treturn 0;\n\t}\n}\n';

	/**
	 * The reported corruption, at the seam: the code between two comments goes, the comments meet,
	 * and `// why b` now stands above `c()`. Flipped by deleting the `CommentOwnerGuard` call in
	 * `CanonicalEdit.canonicalize`.
	 */
	public function testWeldingTwoCommentBlocksIsRefused(): Void {
		switch SeamEdit.replace(TWO_BLOCKS, 'b();', '') {
			case Ok(text):
				Assert.fail('expected a refusal, got Ok:\n$text');
			case Err(message):
				Assert.isTrue(message.indexOf('welded to') >= 0, 'unexpected message: $message');
				Assert.isTrue(message.indexOf('why b') >= 0, 'the refusal does not name the first comment: $message');
				Assert.isTrue(message.indexOf('why c') >= 0, 'the refusal does not name the second comment: $message');
		}
	}

	/**
	 * The same weld reached by a REPLACEMENT that hoists rather than deletes — the actual
	 * `prefer-ternary-return` shape, where the fix quotes the code it keeps and stacks the
	 * comments in front of it. The statement survives; what does not survive is its position
	 * between the two comments.
	 */
	public function testHoistingACommentPastSurvivingCodeIsRefused(): Void {
		switch SeamEdit.replace(TWO_BLOCKS, '// why b\n\t\tb();\n\t\t// why c\n\t\tc();', '// why b\n\t\t// why c\n\t\tb();\n\t\tc();') {
			case Ok(text):
				Assert.fail('expected a refusal, got Ok:\n$text');
			case Err(message):
				Assert.isTrue(message.indexOf('welded to') >= 0, 'unexpected message: $message');
		}
	}

	/**
	 * CONTROL, and the reason the criterion is about BLOCKS rather than about the text that
	 * follows a comment: an in-place rewrite replaces the very code the comment leads, and the
	 * comment goes on leading it. A guard that compared the following text would refuse every
	 * autofix in the project.
	 */
	public function testInPlaceRewriteUnderOneCommentIsAccepted(): Void {
		final text: String = assertOk(SeamEdit.replace(ONE_BLOCK, 'if (a) return 1;\n\t\treturn 0;', 'return a ? 1 : 0;'));
		Assert.isTrue(text.indexOf('// why the guard\n\t\treturn a ? 1 : 0;') >= 0, 'the comment no longer leads the rewrite:\n$text');
	}

	/** CONTROL: code still stands between the two comments, so neither lost anything. */
	public function testReplacingTheSeparatingCodeIsAccepted(): Void {
		final text: String = assertOk(SeamEdit.replace(TWO_BLOCKS, 'b();', 'd();'));
		Assert.isTrue(text.indexOf('// why b\n\t\td();\n\t\t// why c') >= 0, 'the separation did not survive:\n$text');
	}

	/** CONTROL: an edit nowhere near the gap must not pay for the guard, nor be refused by it. */
	public function testEditOutsideTheGapIsAccepted(): Void {
		final text: String = assertOk(SeamEdit.replace(TWO_BLOCKS, 'a();', 'z();'));
		Assert.isTrue(text.indexOf('z();') >= 0, 'the replacement did not land:\n$text');
	}

	/**
	 * CONTROL for the direction the criterion must NOT read: deleting the statement a comment
	 * leads, where no second block stands behind it, leaves the comment attached to nothing in
	 * particular but welds no two blocks — and refusing it would block every fixer that removes a
	 * commented statement. The line the guard draws is the weld, and this is the far side of it.
	 */
	public function testDeletingTheLastCommentedStatementIsAccepted(): Void {
		final text: String = assertOk(SeamEdit.replace(TWO_BLOCKS, 'c();', ''));
		Assert.isTrue(text.indexOf('// why c') >= 0, 'the comment was not kept:\n$text');
	}

	/**
	 * The CARRY criterion, on the shape the block criterion above provably cannot see: ONE comment
	 * block, so `detachedComment` has nothing to weld and returns before it looks at anything.
	 *
	 * This is the closure S84 wrote down as a backlog item and could not reach: "moved across code
	 * that survived" is undecidable from the two texts, because an in-place rewrite changes the
	 * same bytes a hoist does. The edit DECLARES the ranges it quotes verbatim, and the question
	 * becomes arithmetic — `// why zero` stood after `gate()` and `11` in the source and stands
	 * before both in the replacement.
	 *
	 * The message assertion is the discriminating half: it must be the carry sentence ("carries
	 * verbatim"), never the weld sentence, or the test would be passing on the older criterion.
	 * Killed by arm `F1` (`CommentOwnerGuard.hoistedComment` returning null on entry).
	 */
	public function testHoistingAcrossADeclaredCarryIsRefused(): Void {
		switch SeamEdit.replaceCarrying(CARRY_SOURCE, FOLDED_REGION, HOISTED, ['gate()', '11', '22']) {
			case Ok(text):
				Assert.fail('expected a refusal, got Ok:\n$text');
			case Err(message):
				Assert.isTrue(message.indexOf('carries verbatim') >= 0, 'this is not the carry refusal: $message');
				Assert.isTrue(message.indexOf('why zero') >= 0, 'the refusal does not name the comment: $message');
				Assert.isTrue(message.indexOf('gate()') >= 0, 'the refusal does not name the code it crossed: $message');
		}
	}

	/**
	 * The OPT-IN contract, and the reason every other caller of this seam is byte-inert: the SAME
	 * edit with no declaration is accepted, because nothing told the guard which bytes survived.
	 *
	 * NOT killed by any arm in this slice, and that is what it is here to say. It is not a tested
	 * invariant of the algorithm — it is the statement that the algorithm is never entered without
	 * a declaration, which is what let this land without re-judging the seventeen addressed ops,
	 * `FixVerifier`, and every check that does not implement `CarryingFix`.
	 */
	public function testTheSameEditWithNoCarryDeclaredIsAccepted(): Void {
		final text: String = assertOk(SeamEdit.replace(CARRY_SOURCE, FOLDED_REGION, HOISTED));
		Assert.isTrue(text.indexOf('// why zero\n\t\treturn gate() ? 11 : 22;') >= 0, 'the undeclared fold did not land:\n$text');
	}

	/**
	 * CONTROL, the carry-side twin of `testInPlaceRewriteUnderOneCommentIsAccepted`: the comment
	 * sits INSIDE the edited region and the region is rewritten around it, but it keeps its place
	 * between the same two carried ranges. A criterion that fired on "the edit covered the
	 * comment" rather than on "the comment changed sides" would refuse this, and with it every
	 * fixer that edits a commented region at all.
	 */
	public function testACommentThatKeepsItsPlaceUnderACarryIsAccepted(): Void {
		final text: String = assertOk(SeamEdit.replaceCarrying(CARRY_SOURCE, FOLDED_REGION, REWRITTEN_IN_PLACE, ['gate()', '11', '22']));
		Assert.isTrue(text.indexOf('return 11;\n\t\t// why zero\n\t\treturn 22 + 1;') >= 0, 'the comment did not keep its place:\n$text');
	}

	/**
	 * FAIL-OPEN, the direction a guard built on a producer's bookkeeping has to fail in: a
	 * declaration the replacement does not bear out yields NO verdict, not a refusal. Here the
	 * ranges are declared in the wrong order, so the left-to-right scan runs off the end of the
	 * replacement looking for `gate()` after `22`.
	 *
	 * The fixture is the HOISTING edit, so this is the one cell of the matrix where a
	 * mis-declaration turns a refusal into an acceptance — the price of the direction, stated
	 * rather than hidden. Killed by arm `F2` (`placedCarry` returning a refusal instead of being
	 * skipped when the declaration does not hold).
	 */
	public function testACarryDeclarationThatDoesNotHoldIsNotARefusal(): Void {
		final text: String = assertOk(SeamEdit.replaceCarrying(CARRY_SOURCE, FOLDED_REGION, HOISTED, ['22', 'gate()']));
		Assert.isTrue(text.indexOf('// why zero\n\t\treturn gate() ? 11 : 22;') >= 0, 'the fold did not land:\n$text');
	}

	/** The `Ok` text, proved to re-parse; an `Err` fails the test with its own message. */
	private function assertOk(result: EditResult): String {
		switch result {
			case Ok(text):
				try
					new HaxeQueryPlugin().parseFile(text)
				catch (exception: Exception)
					Assert.fail('the result failed to re-parse: ${exception.message}\n$text');
				return text;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				return '';
		}
	}

}
