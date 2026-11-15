package unit.query;

import anyparse.query.TokenSpans;

/** `TokenSpans.wordOffsets`: the tokens of a source that spell a name as a word, by the grammar's own token reader. */
@:nullSafety(Strict)
final class TokenSpansTest extends Test {

	/** A contextual keyword the grammar declares (`to`) still spells a name: the Literal it reads as counts. */
	@:pin('control')
	@:killer('M-WORD-OFFSETS-LITERAL-DROPPED')
	public function testAContextualKeywordSpelledAsANameCounts(): Void {
		Assert.same([2, 7], offsets('a.to + to(from)', 'to'));
	}

	/** Only a token whose whole text is the name counts: not a longer word, not a string, not a comment. */
	@:pin('control')
	@:killer('M-WORD-OFFSETS-ANY-WORD')
	public function testOnlyAWholeWordTokenOfTheNameCounts(): Void {
		Assert.same([0, 27], offsets("walk(walker, 'walk', talk, walk) // walk", 'walk'));
	}

	/** A dotted path counts only as a whole run: not the tail or the head of a longer path, not inside a comment. */
	@:pin('control')
	@:killer('M-PATH-OFFSETS-ANY-NEIGHBOUR')
	public function testAPathCountsOnlyAsAWholeRun(): Void {
		final source: String = 'new a.pkg.T(); new pkg.T.Sub(); /* pkg.T */ new pkg.T()';
		Assert.same([source.lastIndexOf('pkg.T')], paths(source, 'pkg.T'));
	}

	/** A path spelled with a gap between its tokens is not the path: the run's tokens touch. */
	@:pin('control')
	@:killer('M-PATH-OFFSETS-GAPS')
	public function testAPathSpelledWithAGapDoesNotCount(): Void {
		final source: String = 'new pkg . T(); new pkg.T()';
		Assert.same([source.lastIndexOf('pkg.T')], paths(source, 'pkg.T'));
	}

	/** A name in the code of an interpolation hole counts; the same name in the literal's own text does not. */
	@:pin('control')
	@:killer('M-CODE-WORDS-HOLES-SKIPPED')
	public function testANameInAnInterpolationHoleIsCode(): Void {
		Assert.same([5, 23], codeOffsets("'a ${count} b count' + count", 0, 'count'));
	}

	/** A name in a plain string or a comment is no code word; the one in code is. */
	@:pin('control')
	@:killer('M-CODE-WORDS-REGION-TEXT-COUNTS')
	public function testANameInAStringOrACommentIsNoCodeWord(): Void {
		Assert.same([0], codeOffsets('count + "count" /* count */ // count', 0, 'count'));
	}

	/** A token that starts inside the range but ends past it is not reported. */
	@:pin('control')
	@:killer('M-CODE-WORDS-PAST-LIMIT')
	public function testAWordMustEndByTheRangeEnd(): Void {
		Assert.same([0], codeOffsets('count count', 3, 'count'));
	}

	/** The code-word offsets of `name` in `source` up to `cut` characters before its end, by the Haxe token reader. */
	private static function codeOffsets(source: String, cut: Int, name: String): Array<Int> {
		return TokenSpans.codeWordOffsets(source, 0, source.length - cut, name, new HaxeQueryPlugin());
	}

	/** The offsets of `name` in `source`, read by the Haxe grammar's token reader. */
	private static function offsets(source: String, name: String): Array<Int> {
		return TokenSpans.wordOffsets(new HaxeQueryPlugin().tokenSpans(source, 0, source.length), source, name);
	}

	/** The offsets of the dotted `path` in `source`, read by the Haxe grammar's token reader. */
	private static function paths(source: String, path: String): Array<Int> {
		return TokenSpans.pathOffsets(new HaxeQueryPlugin().tokenSpans(source, 0, source.length), source, path, '.');
	}

}
