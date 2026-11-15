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

	/** The offsets of `name` in `source`, read by the Haxe grammar's token reader. */
	private static function offsets(source: String, name: String): Array<Int> {
		return TokenSpans.wordOffsets(new HaxeQueryPlugin().tokenSpans(source, 0, source.length), source, name);
	}

}
