package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.LexicalRegions;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import utest.Assert;
import utest.Test;

/**
 * The forward trivia scan every span-splice consumer shares: `LexicalRegions.skipTrivia` (skip to the next code byte),
 * `headerScan` (the body brace and last header token, through `typeBodyBraceOffset` / `typeHeaderInsertOffset`) and
 * `isReturnTypeSlot` (is the gap before a body a return-type slot). All three read the lexer's regions, so a comment
 * opener inside a string is text and one in code is trivia.
 *
 * The BOUND policy stays per consumer: `skipTrivia` and `headerScan` treat an unterminated comment as trivia running
 * to the end (their callers then find no code and refuse), while `isReturnTypeSlot` — whose `true` means "rewrite
 * this" — must fail CLOSED on one.
 */
class TriviaScanSliceTest extends Test {

	public function testSkipTriviaCrossesEveryTriviaKind(): Void {
		final src: String = '\t/* a */ // b\n  x';
		Assert.equals(src.indexOf('x'), LexicalRegions.skipTrivia(src, 0, regionsOf(src)));
	}

	/** A `/` that opens neither comment kind is CODE — the scan stops on it. */
	public function testSkipTriviaStopsAtALoneSlash(): Void {
		final src: String = '  /x';
		Assert.equals(src.indexOf('/'), LexicalRegions.skipTrivia(src, 0, regionsOf(src)));
	}

	/** A block comment nothing closes swallows the rest: no code byte is reachable. */
	public function testSkipTriviaFindsNoCodePastAnUnterminatedComment(): Void {
		final src: String = '  /* a';
		Assert.equals(src.length, LexicalRegions.skipTrivia(src, 0, regionsOf(src)));
	}

	/** A line comment closed only by the end of the source is the same answer. */
	public function testSkipTriviaFindsNoCodePastATrailingLineComment(): Void {
		final src: String = '  // a';
		Assert.equals(src.length, LexicalRegions.skipTrivia(src, 0, regionsOf(src)));
	}

	public function testIsReturnTypeSlotSeesPastBothCommentKinds(): Void {
		final src: String = 'function f(): T /* n */ // n\n{}';
		Assert.isTrue(RefactorSupport.isReturnTypeSlot(src, src.indexOf('T') + 1, src.indexOf('{'), regionsOf(src)));
	}

	/** The `(` a type-parameter constraint's parameter list leaves in the gap is the whole test. */
	public function testIsReturnTypeSlotRefusesAParenthesisOutsideAComment(): Void {
		final src: String = 'function f<T: Q>(): Int return 0;';
		Assert.isFalse(RefactorSupport.isReturnTypeSlot(src, src.indexOf('Q') + 1, src.indexOf('return'), regionsOf(src)));
	}

	/** The same `(` written INSIDE a comment is no parameter list. */
	@:pin('control') @:killer('M-RETSLOT-COMMENT-OPAQUE')
	public function testIsReturnTypeSlotIgnoresAParenthesisInsideAComment(): Void {
		final src: String = 'function f(): Int /* (n) */ return 0;';
		Assert.isTrue(RefactorSupport.isReturnTypeSlot(src, src.indexOf('Int') + 3, src.indexOf('return'), regionsOf(src)));
	}

	/** A block comment that never closes leaves the slot unproven — fail closed. */
	@:pin('control') @:killer('M-RETSLOT-OPEN-COMMENT-NOT-CLOSED')
	public function testIsReturnTypeSlotRefusesAnUnterminatedBlockComment(): Void {
		final src: String = 'function f(): Int /* n\nreturn 0;';
		Assert.isFalse(RefactorSupport.isReturnTypeSlot(src, src.indexOf('Int') + 3, src.indexOf('return'), regionsOf(src)));
	}

	/** A line comment whose newline falls PAST the body start swallows the body — fail closed. */
	public function testIsReturnTypeSlotRefusesALineCommentReachingTheBody(): Void {
		final src: String = 'function f(): Int // n return 0;\n';
		Assert.isFalse(RefactorSupport.isReturnTypeSlot(src, src.indexOf('Int') + 3, src.indexOf('return'), regionsOf(src)));
	}

	/** A `{` written in a header comment is not the body brace. */
	@:pin('control') @:killer('M-HEADERSCAN-COMMENT-REGION')
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
	 * A string literal in the header is stepped over, so a comment opener written INSIDE it opens no comment. The window runs
	 * from just past the type NAME to the body `{`, yet a `@:const` type parameter puts a string there:
	 * `class X extends B<"//">` parses as a `ConstStringType`.
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
	@:pin('control') @:killer('M-HEADERSCAN-COMMENT-NOT-A-TOKEN')
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

	/**
	 * A `{` written inside a header string literal is text, not the body brace: taken for one, `extract-interface`
	 * would splice its clause INTO the literal, which re-parses clean and passes every gate the op has.
	 */
	@:pin('guard')
	public function testTypeBodyBraceOffsetIgnoresABraceInAHeaderStringLiteral(): Void {
		final src: String = 'class X extends B<"{"> {\n}\n';
		final decl: Null<TypeDeclMatch> = declOf(src);
		if (decl == null) {
			Assert.fail('uniqueTypeDeclNamed found no X');
			return;
		}
		Assert.equals(src.lastIndexOf('{'), RefactorSupport.typeBodyBraceOffset(src, decl, 'X', regionsOf(src)));
	}

	/** A body starting at the source end is itself unknown, and a comment that swallows the rest leaves the slot unproven. */
	@:pin('control') @:killer('M-RETSLOT-BODY-AT-SOURCE-END')
	public function testIsReturnTypeSlotRefusesAnUnterminatedBlockCommentRunningToTheSourceEnd(): Void {
		final src: String = 'function f(): Int /* n';
		Assert.isFalse(RefactorSupport.isReturnTypeSlot(src, src.indexOf('Int') + 3, src.length, regionsOf(src)));
	}

	private function regionsOf(src: String): Array<LexRegion> {
		return new HaxeQueryPlugin().lexicalRegions(src);
	}

	private function declOf(src: String): Null<TypeDeclMatch> {
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(src);
		return RefactorSupport.uniqueTypeDeclNamed(tree, 'X');
	}

}
