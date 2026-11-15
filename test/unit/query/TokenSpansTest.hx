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

	/** The offsets of `name` in `source`, read by the Haxe grammar's token reader. */
	private static function offsets(source: String, name: String): Array<Int> {
		return TokenSpans.wordOffsets(new HaxeQueryPlugin().tokenSpans(source, 0, source.length), source, name);
	}

	/** The offsets of the dotted `path` in `source`, read by the Haxe grammar's token reader. */
	private static function paths(source: String, path: String): Array<Int> {
		return TokenSpans.pathOffsets(new HaxeQueryPlugin().tokenSpans(source, 0, source.length), source, path, '.');
	}

}
