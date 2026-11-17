package anyparse.query;

import anyparse.query.LexicalRegions.LexHole;
import anyparse.query.LexicalRegions.LexRegion;

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
		return [ for (span in spans) if (spellsWord(span, source, name)) span.from ];
	}

	/**
	 * The start of every run of `spans` that spells the dotted `path` with no gap between its tokens: each segment
	 * and each `separator` a whole token of that text. A run a `separator` touches on either side is the head or the
	 * tail of a longer path and does not count; a region is one token of its whole text, so a path inside a comment or a
	 * string is never a run.
	 */
	public static function pathOffsets(spans: Array<TokenSpan>, source: String, path: String, separator: String): Array<Int> {
		final segments: Array<String> = path.split(separator);
		final width: Int = segments.length * 2 - 1;
		return [
			for (start in 0...spans.length - width + 1)
				if (
					spellsRun(spans, source, start, segments, separator)
					&& !touchesSeparator(spans, source, start - 1, spans[start].from, separator)
					&& !touchesSeparator(spans, source, start + width, spans[start + width - 1].to, separator)
				)
					spans[start].from
		];
	}

	/** Whether the tokens from `start` on spell `segments` joined by `separator`, each one starting where the last ended. */
	private static function spellsRun(
		spans: Array<TokenSpan>, source: String, start: Int, segments: Array<String>, separator: String
	): Bool {
		for (k in 0...segments.length * 2 - 1) {
			final span: TokenSpan = spans[start + k];
			if (k > 0 && span.from != spans[start + k - 1].to) return false;
			if (!spells(span, source, k % 2 == 0 ? segments[k >> 1] : separator)) return false;
		}
		return true;
	}

	/** Whether the token at `at` exists, touches the run at `edge`, and is a `separator`. */
	private static function touchesSeparator(spans: Array<TokenSpan>, source: String, at: Int, edge: Int, separator: String): Bool {
		if (at < 0 || at >= spans.length) return false;
		final span: TokenSpan = spans[at];
		return (span.to == edge || span.from == edge) && spells(span, source, separator);
	}

	/** Whether `span`'s whole text is `text`. */
	private static function spells(span: TokenSpan, source: String, text: String): Bool {
		return span.to - span.from == text.length && source.substr(span.from, text.length) == text;
	}

	/**
	 * The start of every token of `source` in `[from, to)` that spells `name` as a word of CODE — the code inside an
	 * interpolating literal's holes included, read by `plugin`'s own token reader: the one answer to "where is this name
	 * written as code". A literal's own text and a comment never count, and a token must end by `to`; `from` is read as
	 * a token boundary.
	 */
	public static function codeWordOffsets(source: String, from: Int, to: Int, name: String, plugin: GrammarPlugin): Array<Int> {
		final out: Array<Int> = [];
		// A range that never holds the text holds no token of it, so the lex is skipped.
		if (!holdsText(source, from, to, name)) return out;
		collectCodeWords(source, from, to, to, name, plugin, LexicalRegions.lazyOf(source, plugin), out);
		return out;
	}

	/** Whether `span` is a word token — a `Word`, or a `Literal` of the same text — whose whole text is `name`. */
	public static function spellsWord(span: TokenSpan, source: String, name: String): Bool {
		return (span.kind == Word || span.kind == Literal)
			&& span.to - span.from == name.length
			&& source.substr(span.from, name.length) == name;
	}

	/** Whether the text `name` occurs whole inside `[from, to)` of `source`. */
	private static function holdsText(source: String, from: Int, to: Int, name: String): Bool {
		if (name.length == 0) return false;
		final at: Int = source.indexOf(name, from);
		return at >= 0 && at + name.length <= to;
	}

	/**
	 * Push to `out` the start of every word token spelling `name` in `[from, to)` that ends by `limit`, descending into
	 * the holes of each region `regionsHere` finds at a region token, so a name in a hole's code counts and one in the
	 * literal's text does not.
	 */
	private static function collectCodeWords(
		source: String, from: Int, to: Int, limit: Int, name: String, plugin: GrammarPlugin, regionsHere: () -> Array<LexRegion>,
		out: Array<Int>
	): Void {
		for (span in plugin.tokenSpans(source, from, to)) {
			if (span.kind != Region) {
				if (span.to <= limit && spellsWord(span, source, name)) out.push(span.from);
				continue;
			}
			if (!holdsText(source, span.from, span.to, name)) continue;
			final holes: Null<Array<LexHole>> = LexicalRegions.regionAt(span.from, regionsHere())?.holes;
			if (holes == null) continue;
			for (hole in holes) collectCodeWords(source, hole.from, hole.to, limit, name, plugin, () -> hole.regions, out);
		}
	}

}
