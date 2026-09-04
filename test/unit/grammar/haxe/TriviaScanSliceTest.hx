package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SourceComments;
import utest.Assert;
import utest.Test;

/**
 * The forward trivia scan every span-splice consumer shares: `skipForwardTrivia` (skip to the
 * next code byte), `headerScan` (the body brace and last header token, through
 * `typeBodyBraceOffset` / `typeHeaderInsertOffset`) and `isReturnTypeSlot` (is the gap before a
 * body a return-type slot). Each held its own copy of the comment scan; these pin what every
 * consumer must still answer once they share one.
 *
 * The BOUND policy stays per consumer and is pinned here too, because that is where the copies
 * legitimately differed: `skipForwardTrivia` and `headerScan` treat an unterminated comment as
 * trivia running past the end (their callers then find no code and refuse), while
 * `isReturnTypeSlot` — whose `true` means "rewrite this" — must fail CLOSED on one.
 */
class TriviaScanSliceTest extends Test {

	/** Off a comment opener the scan reports absence, so the caller reads the byte as code. */
	public function testCommentRegionEndReportsNoCommentOffAnOpener(): Void {
		Assert.equals(-1, SourceComments.commentRegionEnd('ab', 0));
		Assert.equals(-1, SourceComments.commentRegionEnd('a/b', 1));
		Assert.equals(-1, SourceComments.commentRegionEnd('a/', 1));
	}

	/** A closed comment of either kind ends just past its own terminator. */
	public function testCommentRegionEndSpansAClosedComment(): Void {
		Assert.equals(7, SourceComments.commentRegionEnd('/* a */rest', 0));
		Assert.equals(5, SourceComments.commentRegionEnd('// a\nrest', 0));
	}

	/**
	 * An unterminated comment lands PAST every valid offset. That single answer is what lets each
	 * consumer keep its own bound policy: `isReturnTypeSlot` rejects it at any `bodyStart`, while a
	 * cursor-advancing caller simply runs out of source.
	 */
	public function testCommentRegionEndPutsAnUnterminatedCommentPastEveryOffset(): Void {
		final block: String = '/* a';
		Assert.isTrue(SourceComments.commentRegionEnd(block, 0) > block.length);
		final line: String = '// a';
		Assert.isTrue(SourceComments.commentRegionEnd(line, 0) > line.length);
	}

	public function testSkipForwardTriviaCrossesEveryTriviaKind(): Void {
		final src: String = '\t/* a */ // b\n  x';
		Assert.equals(src.indexOf('x'), SourceComments.skipForwardTrivia(src, 0));
	}

	/** A `/` that opens neither comment kind is CODE — the scan stops on it. */
	public function testSkipForwardTriviaStopsAtALoneSlash(): Void {
		final src: String = '  /x';
		Assert.equals(src.indexOf('/'), SourceComments.skipForwardTrivia(src, 0));
	}

	/** A block comment nothing closes swallows the rest: no code byte is reachable. */
	public function testSkipForwardTriviaFindsNoCodePastAnUnterminatedComment(): Void {
		final src: String = '  /* a';
		Assert.isTrue(SourceComments.skipForwardTrivia(src, 0) >= src.length);
	}

	/** A line comment closed only by the end of the source is the same answer. */
	public function testSkipForwardTriviaFindsNoCodePastATrailingLineComment(): Void {
		final src: String = '  // a';
		Assert.isTrue(SourceComments.skipForwardTrivia(src, 0) >= src.length);
	}

	public function testIsReturnTypeSlotSeesPastBothCommentKinds(): Void {
		final src: String = 'function f(): T /* n */ // n\n{}';
		Assert.isTrue(RefactorSupport.isReturnTypeSlot(src, src.indexOf('T') + 1, src.indexOf('{')));
	}

	/** The `(` a type-parameter constraint's parameter list leaves in the gap is the whole test. */
	public function testIsReturnTypeSlotRefusesAParenthesisOutsideAComment(): Void {
		final src: String = 'function f<T: Q>(): Int return 0;';
		Assert.isFalse(RefactorSupport.isReturnTypeSlot(src, src.indexOf('Q') + 1, src.indexOf('return')));
	}

	/** The same `(` written INSIDE a comment is no parameter list. */
	public function testIsReturnTypeSlotIgnoresAParenthesisInsideAComment(): Void {
		final src: String = 'function f(): Int /* (n) */ return 0;';
		Assert.isTrue(RefactorSupport.isReturnTypeSlot(src, src.indexOf('Int') + 3, src.indexOf('return')));
	}

	/** A block comment that never closes leaves the slot unproven — fail closed. */
	public function testIsReturnTypeSlotRefusesAnUnterminatedBlockComment(): Void {
		final src: String = 'function f(): Int /* n\nreturn 0;';
		Assert.isFalse(RefactorSupport.isReturnTypeSlot(src, src.indexOf('Int') + 3, src.indexOf('return')));
	}

	/** A line comment whose newline falls PAST the body start swallows the body — fail closed. */
	public function testIsReturnTypeSlotRefusesALineCommentReachingTheBody(): Void {
		final src: String = 'function f(): Int // n return 0;\n';
		Assert.isFalse(RefactorSupport.isReturnTypeSlot(src, src.indexOf('Int') + 3, src.indexOf('return')));
	}

	/** A `{` written in a header comment is not the body brace. */
	public function testTypeBodyBraceOffsetIgnoresABraceInAHeaderComment(): Void {
		final src: String = 'class X /* { */ {\n}\n';
		final decl: Null<TypeDeclMatch> = declOf(src);
		if (decl == null) {
			Assert.fail('uniqueTypeDeclNamed found no X');
			return;
		}
		final brace: Null<Int> = RefactorSupport.typeBodyBraceOffset(src, decl, 'X', new HaxeQueryPlugin().lexicalRegions(src));
		Assert.equals(src.lastIndexOf('{'), brace);
	}

	/**
	 * A string literal in the header is stepped over, so a comment opener written INSIDE it opens no
	 * comment.
	 *
	 * The arm was filed as unreachable dead code on the argument that the scan window runs from just
	 * past the type NAME to the body `{`, where no string literal can sit. It can:
	 * `class X extends B<"//">` is a `@:const` type parameter of an `@:generic` class, it parses here
	 * as a `ConstStringType` node, and the whole program compiles and runs on Haxe 4.3.7. Delete the
	 * arm and the `//` inside the literal opens a line comment that swallows the rest of the header —
	 * the insert offset lands at the quote and `extract-interface` splices its clause INSIDE the
	 * string, writing `class X extends B<" implements IX//">`, which re-parses clean and passes every
	 * gate the op has.
	 */
	public function testTypeHeaderInsertOffsetStepsOverAHeaderStringLiteral(): Void {
		final src: String = 'class X extends B<"//"> {\n}\n';
		final decl: Null<TypeDeclMatch> = declOf(src);
		if (decl == null) {
			Assert.fail('uniqueTypeDeclNamed found no X');
			return;
		}
		final at: Null<Int> = RefactorSupport.typeHeaderInsertOffset(src, decl, 'X', new HaxeQueryPlugin().lexicalRegions(src));
		Assert.equals(src.indexOf('>') + 1, at);
	}

	/** A header comment holds no tokens, so the insert offset stays right after the type name. */
	public function testTypeHeaderInsertOffsetStopsBeforeAHeaderComment(): Void {
		final src: String = 'class X /* implements Q */ {\n}\n';
		final decl: Null<TypeDeclMatch> = declOf(src);
		if (decl == null) {
			Assert.fail('uniqueTypeDeclNamed found no X');
			return;
		}
		final at: Null<Int> = RefactorSupport.typeHeaderInsertOffset(src, decl, 'X', new HaxeQueryPlugin().lexicalRegions(src));
		Assert.equals(src.indexOf('X') + 1, at);
	}

	private function declOf(src: String): Null<TypeDeclMatch> {
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(src);
		return RefactorSupport.uniqueTypeDeclNamed(tree, 'X');
	}

}
