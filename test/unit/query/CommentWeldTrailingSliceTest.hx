package unit.query;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.Patch;
import anyparse.query.RemoveElement;
import anyparse.query.ReplaceNode;

/**
 * `CommentOwnerGuard.detachedComment` on a TRAILING comment: `stmt; // c` belongs to the
 * statement on its own line, not to the own-line comment under it.
 *
 * The comment blocks were maximal whitespace-separated runs, so `a(); // c` and the `// doc` on
 * the next line read as ONE block. Deleting the statement between them then looked like a
 * weld of two source blocks that the deletion had merely made adjacent, and the edit was
 * refused although `// c` still sits on `a();` and `// doc` still leads `c();`. A trailing
 * comment now closes its block when the next comment is on a later line; two own-line comments
 * with a statement between them stay two blocks that a deletion must not weld.
 *
 * Asked through all three ops that reach the seam (`remove-element`, `replace-node`, `patch`), so
 * the fixture is the same for each and the acceptance cannot hold for one only.
 */
class CommentWeldTrailingSliceTest extends Test {

	/** A trailing comment, one statement, an own-line comment: the shape deleting `b();` used to be refused on. */
	private static final TRAILING: String = 'class C {\n\tfunction f(): Void {\n\t\ta(); // c\n\t\tb();\n\t\t// doc\n\t\tc();\n\t}\n}\n';

	/** The same shape with `// c` on its own line — the weld the guard exists to refuse. */
	private static final OWN_LINE: String =
		'class C {\n\tfunction f(): Void {\n\t\ta();\n\t\t// c\n\t\tb();\n\t\t// doc\n\t\tc();\n\t}\n}\n';

	/** A trailing comment, an own-line comment under it, then the statement and `// doc`. */
	private static final TRAILING_PAIR: String =
		'class C {\n\tfunction f(): Void {\n\t\ta(); // c\n\t\t// c2\n\t\tb();\n\t\t// doc\n\t\tc();\n\t}\n}\n';

	@:pin('control')
	@:killer('M-COMMENT-TRAILING-GROUPED')
	public function testRemoveElementDeletesBetweenTrailingAndOwnLineComment(): Void {
		assertKept(RemoveElement.removeElement(TRAILING, 4, 3, true, new HaxeQueryPlugin()));
	}

	@:pin('control')
	@:killer('M-COMMENT-TRAILING-GROUPED')
	public function testReplaceNodeDeletesBetweenTrailingAndOwnLineComment(): Void {
		assertKept(ReplaceNode.replaceNode(TRAILING, ByKindPosition(4, 3, 'ExprStmt'), '', true, new HaxeQueryPlugin()));
	}

	@:pin('control')
	@:killer('M-COMMENT-TRAILING-GROUPED')
	public function testPatchDeletesBetweenTrailingAndOwnLineComment(): Void {
		assertKept(Patch.patchNode(TRAILING, BySelector('FnMember:f'), 'b();', '', true, new HaxeQueryPlugin()));
	}

	/**
	 * The two-sided control, same three ops: with the first comment on its own line the deleted
	 * statement is what separated two blocks, so each op still refuses.
	 */
	@:pin('control')
	@:killer('M-COMMENT-WELD-BLIND')
	public function testOwnLineCommentsAroundTheDeletedStatementStayRefused(): Void {
		assertWelded(RemoveElement.removeElement(OWN_LINE, 5, 3, true, new HaxeQueryPlugin()));
		assertWelded(ReplaceNode.replaceNode(OWN_LINE, ByKindPosition(5, 3, 'ExprStmt'), '', true, new HaxeQueryPlugin()));
		assertWelded(Patch.patchNode(OWN_LINE, BySelector('FnMember:f'), 'b();', '', true, new HaxeQueryPlugin()));
	}

	/**
	 * An own-line comment right under a trailing one is a block of its own, so a deletion that
	 * welds it to the `// doc` below is still a weld.
	 */
	@:pin('control')
	@:killer('M-COMMENT-WELD-BLIND')
	public function testTrailingCommentWithItsOwnLineSiblingStillWeldsToTheNextBlock(): Void {
		assertWelded(RemoveElement.removeElement(TRAILING_PAIR, 5, 3, true, new HaxeQueryPlugin()));
	}

	/**
	 * A trailing comment followed by a comment on the SAME line is one block: deleting the code
	 * between the two on one line welds them, and splitting the block there would let that through.
	 */
	@:pin('control')
	@:killer('M-COMMENT-TRAILING-SPLITS-SAME-LINE')
	public function testSameLineCommentsAroundTheDeletedCodeStayRefused(): Void {
		final source: String = 'class C {\n\tfunction f(): Void {\n\t\tg(a, /* x */ b, /* y */ c);\n\t}\n}\n';
		switch Patch.patchNode(source, BySelector('FnMember:f'), 'b, /* y */ c', '/* y */ c', true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.fail('expected a weld refusal, got Ok:\n$text');
			case Err(message):
				Assert.isTrue(message.indexOf('"/* x */" welded to "/* y */"') >= 0, 'not the weld of the same-line pair: $message');
		}
	}

	/** The `Ok` text still carries both comments, each next to its code. */
	private function assertKept(result: EditResult): Void {
		switch result {
			case Ok(text):
				Assert.isTrue(text.indexOf('b()') < 0, 'the statement was not removed:\n$text');
				Assert.isTrue(text.indexOf('a(); // c') >= 0, 'the trailing comment left its statement:\n$text');
				Assert.isTrue(text.indexOf('// doc\n\t\tc();') >= 0, 'the doc comment left its statement:\n$text');
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	private function assertWelded(result: EditResult): Void {
		switch result {
			case Ok(text):
				Assert.fail('expected a weld refusal, got Ok:\n$text');
			case Err(message):
				Assert.isTrue(message.indexOf('welded to "// doc"') >= 0, 'not the weld onto "// doc": $message');
		}
	}

}
