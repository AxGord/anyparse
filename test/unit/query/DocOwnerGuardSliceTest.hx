package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit.EditResult;
import haxe.Exception;
import utest.Assert;
import utest.Test;

/**
 * `RefactorSupport.docSplittingEdit` — the doc-attribution half of the
 * writer-emit gate, asked from `canonicalize` next to `BodySlotGuard`.
 *
 * A doc comment is trivia OUTSIDE the declaration's node span, so an insert
 * addressed at that declaration lands BETWEEN the two and the doc silently
 * comes to document the insertion. Every gate this project owns passes on the
 * result: it re-parses, it is byte-canonical, `fmt --list` is clean, and no
 * lint rule reads a comment's owner. The loss is found by a human re-reading
 * the file — which is how it was found, a 30-line class doc at a time.
 *
 * Only a ZERO-WIDTH insert carrying a line break can do it, and the three
 * controls here are the reason the predicate is not wider: an edit that COVERS
 * text owns what it covers (`set-doc`, `comment-rewrite`, `replace-node`,
 * `rename`), an insert with no line break joins the owner's own line (the
 * shape a modifier-prepending fixer produces), and a block comment that is not
 * a `/**` opener is not documentation by this codebase's own rule — the same
 * rule `docExtendedSpan` applies on the delete side, which is why the guard
 * lives beside it.
 */
class DocOwnerGuardSliceTest extends Test {

	/** Two doc'd sibling typedefs — the module-level shape the campaign reported. */
	private static final TWO_TYPEDEFS: String =
		'/**\n * Doc A.\n */\ntypedef A = {\n\tvar a: Int;\n}\n\n/**\n * Doc B.\n */\ntypedef B = {\n\tvar b: Int;\n}\n';

	/** One doc'd member, its modifier omitted so a modifier insert is legal. */
	private static final DOCD_MEMBER: String = 'class C {\n\n\t/**\n\t * Doc m1.\n\t */\n\tfunction m1(): Int return 1;\n\n}\n';

	/** The whole element inserted by the refusal cases. */
	private static final MID: String = 'typedef Mid = { var m: Int; }\n';

	/**
	 * The reported corruption, at the seam. Flipped by deleting the
	 * `docSplittingEdit` call in `RefactorSupport.canonicalize`.
	 */
	public function testInsertBetweenDocAndTypeIsRefused(): Void {
		assertRefused(TWO_TYPEDEFS, 'typedef B', 'typedef B = {');
	}

	/** The same at MEMBER level — tight member spans hide nothing here. */
	public function testInsertBetweenDocAndMemberIsRefused(): Void {
		assertRefused(DOCD_MEMBER, 'function m1', 'function m1(): Int return 1;');
	}

	/**
	 * CONTROL. The correct anchor — above the doc — must stay accepted, and the
	 * doc must still lead its own declaration afterwards. Nothing in the guard
	 * flips this one; it is here because a guard that refused the FIX would be a
	 * worse regression than the bug.
	 */
	public function testInsertAboveTheDocIsAccepted(): Void {
		final text: String = assertOk(SeamEdit.insert(TWO_TYPEDEFS, '/**\n * Doc B.', MID));
		Assert.isTrue(text.indexOf('typedef Mid') < text.indexOf('Doc B'));
		Assert.isTrue(text.indexOf('*/\ntypedef B') >= 0);
	}

	/**
	 * CONTROL for the line-break half of the predicate: a fixer prepending a
	 * modifier inserts at the very same offset and must pass. Flipped by
	 * dropping the `edit.text.indexOf('\n') < 0` clause.
	 */
	public function testModifierInsertOnTheOwnersLineIsAccepted(): Void {
		final text: String = assertOk(SeamEdit.insert(DOCD_MEMBER, 'function m1', 'public '));
		Assert.isTrue(text.indexOf('public function m1') >= 0);
	}

	/**
	 * CONTROL for the zero-width half: `replace-node` / `rename` / `set-doc` all
	 * start their span at or before the owner and OWN what they cover. Flipped by
	 * dropping the `edit.span.to != edit.span.from` clause.
	 */
	public function testReplacementStartingAtTheOwnerIsAccepted(): Void {
		// The replacement text carries a line break on purpose: without one the
		// newline clause would reject the edit first and this control would pass
		// with the zero-width clause deleted.
		final text: String = assertOk(
			SeamEdit.replace(TWO_TYPEDEFS, 'typedef B = {\n\tvar b: Int;\n}', 'typedef B = {\n\tvar b: Int;\n\tvar z: Int;\n}')
		);
		Assert.isTrue(text.indexOf('var z:Int;') >= 0, 'the replacement did not land:\n$text');
		Assert.isTrue(text.indexOf('*/\ntypedef B') >= 0, 'the doc no longer leads its own type:\n$text');
	}

	/**
	 * CONTROL for the opener half: a bare `/*` block is a banner or a licence
	 * header, not documentation — `docExtendedSpan(docOnly)` refuses to delete
	 * one for the same reason, so the guard must not claim one either. Flipped by
	 * dropping the `isDocOpener` clause.
	 */
	public function testBannerCommentIsNotGuarded(): Void {
		final banner: String = '/*\n * Banner, not a doc.\n */\ntypedef A = {\n\tvar a: Int;\n}\n';
		final text: String = assertOk(SeamEdit.insert(banner, 'typedef A', MID));
		Assert.isTrue(text.indexOf('typedef Mid') >= 0, 'the insert did not land:\n$text');
	}

	/**
	 * CONTROL for the positive criterion: an ORPHANED doc left before the byte
	 * that closes the body documents nothing, so an append there steals nothing.
	 * Refusing it blocked `add-member` on a real file of this repo with a remedy
	 * that op cannot perform. Flipped by dropping the `isIdentStartChar` clause,
	 * which is what makes the test the closer rather than the end of the file.
	 */
	public function testAppendBeforeAClosingBraceIsAccepted(): Void {
		final orphan: String = 'class C {\n\n\tpublic function m(): Void {}\n\n\t/**\n\t * Orphan doc left behind.\n\t */\n}\n';
		// Anchored on the newline that precedes the FINAL brace: `{}` above has no
		// newline before its own closer, so this occurrence is the type's.
		final text: String = assertOk(SeamEdit.insert(orphan, '\n}', '\npublic function z(): Void {}'));
		Assert.isTrue(text.indexOf('function z') >= 0, 'the append did not land:\n$text');
	}

	/**
	 * The incident T554 reports, reduced to the two declarations it actually needed — and the
	 * reason this slice restored a paragraph rather than only writing a guard.
	 *
	 * `MemberKinds.FIELD_MEMBER_KINDS` carried a doc naming what its kinds MEAN and who asks
	 * (`Rename`, `Inline`). On 2026-07-26 commit `969ef368` inserted two newly-documented
	 * constants at that declaration, which is the zero-width-insert-with-a-line-break shape:
	 * the doc stayed put and the insert slid under it. From then on the paragraph led
	 * `TYPEDEF_DECL_KIND`, then `DOC_OPEN`, and travelled into `SourceComments` with `DOC_OPEN`
	 * in S72's module split, where a reader found it welded to a one-line doc about `/**`.
	 *
	 * So the mechanism was the doc-splitting INSERT, not the comment WELD the brief expected:
	 * `CommentOwnerGuard.detachedComment` cannot see this one at all, because an insert adds
	 * text and the two comments involved were only ever ONE block (whitespace between them).
	 * The half that could see it is `docSplittingEdit`, and it has refused this shape since
	 * S23 — so this test GUARDS PRE-EXISTING BEHAVIOUR and is not base-red. Its value is that
	 * the incident now has a fixture: the next reader who finds a stranded paragraph can check
	 * in one run whether the seam would still let it happen.
	 */
	public function testTheInsertThatStrandedFieldMemberKindsIsRefused(): Void {
		final kindSet: String = 'final class RefactorSupport {\n\n\t/**\n\t * Class-member declaration kinds (fields / methods).'
			+ ' A binding whose\n\t * decl node carries one of these kinds is a class member, not a local.\n\t */\n'
			+ '\tpublic static final FIELD_MEMBER_KINDS: Array<String> = [\'VarMember\', \'FnMember\'];\n\n}\n';
		final inserted: String =
			'\t/** The grammar kind a `typedef` projects as. */\n\tprivate static final TYPEDEF_DECL_KIND: String = \'TypedefDecl\';\n\n';
		switch SeamEdit.insert(kindSet, 'public static final FIELD_MEMBER_KINDS', inserted) {
			case Ok(text):
				Assert.fail('expected a refusal, got Ok:\n$text');
			case Err(message):
				Assert.isTrue(message.indexOf('between a doc comment') >= 0, 'unexpected message: $message');
				Assert.isTrue(message.indexOf('FIELD_MEMBER_KINDS') >= 0, 'the refusal does not name the list it protected: $message');
		}
	}

	/** The refusal must name the declaration it protected, not just complain. */
	private function assertRefused(source: String, before: String, owner: String): Void {
		switch SeamEdit.insert(source, before, MID) {
			case Ok(text):
				Assert.fail('expected a refusal, got Ok:\n$text');
			case Err(message):
				Assert.isTrue(message.indexOf('between a doc comment') >= 0, 'unexpected message: $message');
				Assert.isTrue(message.indexOf(owner) >= 0, 'the refusal does not name "$owner": $message');
		}
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
