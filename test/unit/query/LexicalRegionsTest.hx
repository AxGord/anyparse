package unit.query;

import anyparse.grammar.haxe.HaxeLexicalRegions;
import anyparse.query.LexicalRegions;

/**
 * `LexicalRegions` — the byte-level scan that decides which source is code.
 *
 * It was private inside `RefactorSupport` and had no test of its own, which is how a
 * quote-pairing defect survived: a wrong region only made an occurrence COUNT wrong,
 * and nothing acted on the count. Once the same region gated a DELETE, the defect
 * removed a live import. These pin the two shapes that produced real corruption plus the
 * escapes around them.
 *
 * They are green at base BY CONSTRUCTION and say so: the class did not exist there, so
 * there is no arm of this file that can be red at base. They are a
 * characterization pin on behaviour the extraction had to carry over unchanged — what
 * actually proves the move is the full suite and the corpus sweep, both byte-identical
 * across it.
 */
class LexicalRegionsTest extends Test {

	/**
	 * A `${ … }` hole is CODE and may hold a literal of the SAME quote. Reading `$` as
	 * ordinary text ended the outer literal at the nested quote, so the `//` inside was
	 * lexed as a comment opener over live source.
	 */
	public function testInterpolationHoleWithNestedSameQuote(): Void {
		final source: String = "var s = '${c ? '// note' : x}';\nvar t = 1;";
		final regions: Array<LexRegion> = HaxeLexicalRegions.scan(source);
		Assert.equals(1, regions.length, 'the whole literal is ONE region: ${dump(source, regions)}');
		Assert.equals("'${c ? '// note' : x}'", source.substring(regions[0].from, regions[0].to));
		Assert.equals(LexRegionKind.StringLit, regions[0].kind);
	}

	/** Arbitrary nesting depth, the same balancing Haxe's own lexer does. */
	public function testNestedInterpolationDepthThree(): Void {
		final source: String = "var s = '${'inner=${'x'}'}';";
		final regions: Array<LexRegion> = HaxeLexicalRegions.scan(source);
		Assert.equals(1, regions.length, 'nesting stays inside one region: ${dump(source, regions)}');
		Assert.equals("'${'inner=${'x'}'}'", source.substring(regions[0].from, regions[0].to));
	}

	/**
	 * An unterminated literal INSIDE a hole means the walk has lost the thread, and the
	 * recovery has to fail CLOSED — hand the `{` back so the outer literal falls to plain
	 * quote pairing. Reading it the other way widens one region to EOF, and every consumer
	 * of `RefactorSupport.collectCommentTokens` then sees live code as comment trivia.
	 */
	public function testUnterminatedNestedLiteralFailsClosed(): Void {
		final source: String = "var s = '${'unterminated};\nvar t = 1;";
		final regions: Array<LexRegion> = HaxeLexicalRegions.scan(source);
		Assert.equals(1, regions.length, 'the recovery emits one short region: ${dump(source, regions)}');
		Assert.equals("'${'", source.substring(regions[0].from, regions[0].to), 'it stops at the nested quote, not at EOF');
	}

	/**
	 * `$$` is the ESCAPED dollar, not a hole opener. The `{` after it has to stay literal
	 * text: read as a hole opener it starts a brace walk that skips the closing quote, eats
	 * the next literal whole and returns ONE region over both. The first version of this
	 * test used `'$$'` with nothing after the dollars, and deleting the `$$` arm left its
	 * result byte-identical — the fixture has to put a `{` in the escape's way to
	 * discriminate.
	 */
	public function testEscapedDollarIsNotAHole(): Void {
		final source: String = "var s = '$${';\nvar t = '}';";
		final regions: Array<LexRegion> = HaxeLexicalRegions.scan(source);
		Assert.equals(2, regions.length, 'the escaped dollar leaves TWO literals: ${dump(source, regions)}');
		Assert.equals("'$${'", source.substring(regions[0].from, regions[0].to), 'the first ends at its own quote');
		Assert.equals("'}'", source.substring(regions[1].from, regions[1].to), 'the second is a literal of its own');
	}

	/**
	 * A regex body may legally carry a comment OPENER. Without the regex arm it started a
	 * phantom block comment that ran to EOF and made every later byte comment trivia.
	 */
	public function testRegexBodyHoldingACommentOpener(): Void {
		final source: String = 'var r = ~/[\\/*]/;\nvar t = 1;';
		final regions: Array<LexRegion> = HaxeLexicalRegions.scan(source);
		Assert.equals(1, regions.length, 'the regex is one region and opens no comment: ${dump(source, regions)}');
		Assert.equals(LexRegionKind.RegexLit, regions[0].kind);
		Assert.equals('~/[\\/*]/', source.substring(regions[0].from, regions[0].to));
	}

	/** A `\`-escaped quote does not close the literal. */
	public function testEscapedQuoteInsideLiteral(): Void {
		final source: String = 'var s = "a\\"b";\nvar t = 1;';
		final regions: Array<LexRegion> = HaxeLexicalRegions.scan(source);
		Assert.equals(1, regions.length, 'one region: ${dump(source, regions)}');
		Assert.equals('"a\\"b"', source.substring(regions[0].from, regions[0].to));
	}

	/** A string is not a comment — the distinction every rename and delete rests on. */
	public function testOffsetWithinCommentSeparatesStringFromComment(): Void {
		final source: String = "// c\nvar s = 'x';";
		final regions: Array<LexRegion> = HaxeLexicalRegions.scan(source);
		Assert.isTrue(LexicalRegions.offsetWithinComment(source.indexOf('c'), regions), 'the comment body is a comment');
		Assert.isFalse(LexicalRegions.offsetWithinComment(source.indexOf("'x'") + 1, regions), 'a string literal is not');
		Assert.isFalse(LexicalRegions.offsetWithinComment(source.indexOf('var'), regions), 'code is not');
	}

	/** The code spans are the runs between the regions, the head and the tail included, an empty run left out. */
	@:pin('control')
	@:killer('M-LEXREG-CODESPANS-TAIL')
	public function testCodeSpansAreWhatLiesBetweenTheRegions(): Void {
		final source: String = "a /* b */ c '}' d // e\nf";
		final spans: Array<String> = LexicalRegions.codeSpans(source.length, HaxeLexicalRegions.scan(source))
			.map(span -> source.substring(span.from, span.to));
		Assert.same(['a ', ' c ', ' d ', '\nf'], spans);
		Assert.equals(1, LexicalRegions.codeSpans(1, []).length, 'no region: the whole source is code');
		Assert.same([], LexicalRegions.codeSpans(3, [{ from: 0, to: 3, kind: LexRegionKind.BlockComment }]), 'all comment: no code');
	}

	/**
	 * A comment opens in a range only when the lexer says so: a `//` or `/*` inside a string literal is text, a real
	 * comment inside the range counts, and one that opens outside it does not.
	 */
	@:pin('control') @:killer('M-REGIONS-COMMENT-OPENS-STRING-BLIND')
	public function testCommentOpensInIgnoresMarkersInsideStrings(): Void {
		final source: String = "var s = 'a // b'; var t = 1; /* c */";
		final regions: Array<LexRegion> = HaxeLexicalRegions.scan(source);
		Assert.isFalse(LexicalRegions.commentOpensIn(0, source.indexOf('var t'), regions), 'a `//` inside a string is no comment');
		Assert.isTrue(LexicalRegions.commentOpensIn(0, source.length, regions), 'the block comment opens inside the whole source');
		Assert.isFalse(LexicalRegions.commentOpensIn(0, source.indexOf('/* c'), regions), 'it opens past the range end');
		Assert.isFalse(
			LexicalRegions.commentOpensIn(source.indexOf('/* c') + 1, source.length, regions), 'it opened before the range start'
		);
	}

	/** Both region ends and their text, for a failure message that says what was actually scanned. */
	private function dump(source: String, regions: Array<LexRegion>): String {
		return regions.map(region -> '[${region.from},${region.to}) ${source.substring(region.from, region.to)}').join(' | ');
	}

}
