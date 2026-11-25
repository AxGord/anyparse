package unit.query;

import anyparse.query.OccurrenceScan;
import anyparse.query.SourceWordIndex;
import anyparse.runtime.Span;

/**
 * `SourceWordIndex` answers "does this name stand as a word outside these spans" from one pass over
 * the sources, and must agree with the per-name text walk `OccurrenceScan.referencedInRange` it
 * replaces: the word boundary, a `$` escape ahead of a name, a name at the end of the text, the
 * excluded spans of a file and the inert mask.
 */
@:nullSafety(Strict)
class SourceWordIndexTest extends Test {

	private static final NONE: Map<String, Array<Span>> = [];

	@:pin('control')
	@:killer('M-WORDINDEX-RUN-UNSPLIT')
	public function testOnlyAWholeRunOfIdentifierCharactersIsAWord(): Void {
		final index: SourceWordIndex = new SourceWordIndex(['a' => 'foobar xfoo foo9 _foo']);
		Assert.isFalse(asks(index, 'foo'), 'a prefix, a suffix and a longer run are no word');
		Assert.isTrue(asks(index, 'foobar'));
		Assert.isTrue(asks(index, 'xfoo'));
		Assert.isTrue(asks(index, 'foo9'));
		Assert.isFalse(asks(index, 'absent'));
		Assert.isTrue(asks(new SourceWordIndex(['a' => 'x = foo']), 'foo'), 'a word that ends the text');
		Assert.isTrue(asks(new SourceWordIndex(['a' => 'foo']), 'foo'), 'a word that is the whole text');
	}

	@:pin('control')
	@:killer('M-WORDINDEX-ESCAPE-TAIL-UNRECORDED')
	public function testANameAfterADollarEscapeIsAWord(): Void {
		Assert.isTrue(asks(new SourceWordIndex(['a' => "'\\x24foo'"]), 'foo'), 'hex escape');
		Assert.isTrue(asks(new SourceWordIndex(['a' => "'\\u0024foo'"]), 'foo'), 'unicode escape');
		Assert.isFalse(asks(new SourceWordIndex(['a' => "'x24foo'"]), 'foo'), 'no backslash, one longer word');
		Assert.isFalse(asks(new SourceWordIndex(['a' => "'\\x25foo'"]), 'foo'), 'another escape');
		Assert.isTrue(asks(new SourceWordIndex(['a' => "'$foo'"]), 'foo'), 'the plain trigger');
	}

	@:pin('control')
	@:killer('M-WORDINDEX-EXCLUDED-IGNORED')
	public function testAnExcludedSpanOfTheOwnFileDoesNotCount(): Void {
		final index: SourceWordIndex = new SourceWordIndex(['a' => 'foo foo', 'b' => 'bar']);
		Assert.isTrue(index.occursOutside('foo', ['a' => [new Span(0, 3)]], noMask), 'the second occurrence stands');
		Assert.isFalse(index.occursOutside('foo', ['a' => [new Span(0, 3), new Span(4, 7)]], noMask), 'both excluded');
		Assert.isTrue(index.occursOutside('foo', ['b' => [new Span(0, 7)]], noMask), 'a span of another file excludes nothing here');
	}

	@:pin('control')
	@:killer('M-WORDINDEX-MASK-IGNORED')
	public function testAnOccurrenceInsideTheMaskDoesNotCount(): Void {
		final index: SourceWordIndex = new SourceWordIndex(['a' => 'foo foo']);
		Assert.isFalse(index.occursOutside('foo', NONE, _ -> [new Span(0, 3), new Span(4, 7)]));
		Assert.isTrue(index.occursOutside('foo', NONE, _ -> [new Span(0, 3)]));
	}

	@:pin('control')
	@:killer('M-WORDINDEX-INDEXABLE-ANY')
	public function testOnlyARunOfIdentifierCharactersIsIndexable(): Void {
		Assert.isTrue(SourceWordIndex.indexable('foo_9'));
		Assert.isFalse(SourceWordIndex.indexable(''));
		Assert.isFalse(SourceWordIndex.indexable('a.b'));
		Assert.isFalse(SourceWordIndex.indexable('$$a'));
	}

	@:pin('control')
	@:killer('M-WORDINDEX-RUN-UNSPLIT')
	public function testItAgreesWithTheTextWalkOnEveryWordOfASource(): Void {
		final source: String = "class A { var foo; function bar() { foo = foobar + xfoo; '\\x24foo $bar \\u0024xfoo'; baz(foo9); } } foo";
		final excluded: Array<Span> = [new Span(10, 20)];
		final mask: Array<Span> = [new Span(60, 70)];
		final index: SourceWordIndex = new SourceWordIndex(['a' => source]);
		for (name in [
			'A',
			'foo',
			'bar',
			'foobar',
			'xfoo',
			'foo9',
			'baz',
			'class',
			'var',
			'x24foo',
			'u0024xfoo',
			'missing'
		])
			Assert.equals(
				OccurrenceScan.referencedInRange(source, name, 0, source.length, excluded, mask),
				index.occursOutside(name, ['a' => excluded], _ -> mask), name
			);
	}

	private static function noMask(file: String): Array<Span> {
		return [];
	}

	private static function asks(index: SourceWordIndex, name: String): Bool {
		return index.occursOutside(name, NONE, noMask);
	}

}
