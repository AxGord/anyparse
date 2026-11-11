package unit.query;

import anyparse.query.Matcher;
import anyparse.query.Pattern;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

/**
 * A statement-sequence pattern matches a run of adjacent statements, and a metavariable
 * repeated across its statements binds one name in every place.
 */
class ApqMatcherSequenceTest extends Test {

	private static final SOURCE: String = 'class X {
		function f() {
			final cb:Int = new Sprite(0.5);
			if (cb != null) cb(1);
			final g:Int = cast command;
			if (h != null) g(2);
			final k:Int = 0.5;
			trace(1);
			if (k != null) k(3);
			final m:Int = 1;
			if (m != null) n(4);
		}
	}';
	private static final SEQUENCE: String = 'final $$l:$$t = $$f; if ($$l != null) $$l($$a);';

	@:pin('control')
	@:killer('M-PATTERN-SEQ-FIRST-ONLY')
	public function testAdjacentSameNameSequenceMatchesOnly(): Void {
		final matches: Array<Match> = search(SEQUENCE);
		Assert.equals(1, matches.length);
		Assert.equals('cb', matches[0].bindings.get('l')?.name);
	}

	@:pin('control')
	@:killer('M-MATCH-SEQ-FRESH-BINDINGS')
	public function testADifferentNameAtAnyPlaceDoesNotMatch(): Void {
		final names: Array<Null<String>> = search(SEQUENCE).map(m -> m.bindings.get('l')?.name);
		Assert.same(['cb'], names, 'only the pair that spells cb in all three places');
		Assert.isFalse(names.contains('g'), 'the `if` tests h, not g');
		Assert.isFalse(names.contains('m'), 'the call is n, not m');
		Assert.isFalse(names.contains('k'), 'a statement stands between the two');
	}

	@:pin('guard')
	public function testCapturedInitializerIsAWholeExpression(): Void {
		final f: Null<QueryNode> = search(SEQUENCE)[0]?.bindings.get('f');
		final span: Null<Span> = f?.span;
		Assert.equals('new Sprite(0.5)', span == null ? null : SOURCE.substring(span.from, span.to));
	}

	@:pin('guard')
	public function testSingleStatementPatternMatchesAsToday(): Void {
		Assert.equals(4, search('final $$l:$$t = $$f;').length);
	}

	private static function search(patternSource: String): Array<Match> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final pattern: Pattern = plugin.parsePattern(patternSource);
		final tree: QueryNode = plugin.parseFile(SOURCE);
		return Matcher.search(pattern, tree);
	}

}
