package anyparse.query;

/**
 * What a token span IS — the kinds a generated token reader tells apart.
 *
 * `Word` and `Number` are the kinds a grammar may DECLARE on a `@:re` terminal with `@:token(<Kind>)`; the
 * other three the reader assigns itself: a declared literal text, a whole lexical region, and a character no
 * declaration covers.
 */
enum abstract TokenKind(Int) {
	final Word = 0;
	final Number = 1;
	final Literal = 2;
	final Region = 3;
	final Unknown = 4;
}

/** One token of a source: `[from, to)` byte offsets and the kind that matched there. */
typedef TokenSpan = { final from: Int; final to: Int; final kind: TokenKind; }

/**
 * The one answer to "which tokens does a source hold, by its grammar's own declarations" — the TYPES of the
 * answer and the pure helpers over it; the reader itself is GENERATED per grammar by `Build.buildLexicalScan`
 * and reached through `GrammarPlugin.tokenSpans`.
 *
 * The reader is maximal munch over three declared sets: every literal text the grammar spells (`@:lit`,
 * `@:lead`, `@:trail`, `@:kw`, `@:sep`, the operator tags, directive keywords), every
 * terminal tagged `@:token(<Kind>)`, and every lexical region as ONE token. A literal wins a tie with a
 * terminal, so a keyword the word pattern also matches reads as the keyword. Whitespace the format declares
 * separates tokens and is never one.
 */
@:nullSafety(Strict)
final class TokenSpans {

	/** The source text of every span of `spans`, in order. */
	public static function texts(source: String, spans: Array<TokenSpan>): Array<String> {
		return spans.map(span -> source.substring(span.from, span.to));
	}

	/**
	 * The start of every token of `spans` that spells `name` as a word: a `Word`, or a `Literal` of the same text, since a
	 * declared keyword wins its tie with the word pattern and a contextual keyword used as a name (`from`) reads as one.
	 * A region never counts, so a name inside a string or a comment is not a token of it.
	 */
	public static function wordOffsets(spans: Array<TokenSpan>, source: String, name: String): Array<Int> {
		return [
			for (span in spans)
				if (
					(span.kind == Word || span.kind == Literal)
					&& span.to - span.from == name.length
					&& source.substr(span.from, name.length) == name
				)
					span.from
		];
	}

}
