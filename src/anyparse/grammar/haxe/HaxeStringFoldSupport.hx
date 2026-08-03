package anyparse.grammar.haxe;

import anyparse.query.QueryNode;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.StringLiteral;
import anyparse.runtime.Span;

using Lambda;

import anyparse.query.StringFold.ConcatSegment;

/**
 * Haxe `StringFoldSupport`. Concatenation is `+` (`Add`).
 *
 * A double-quoted literal is always plain (Haxe never interpolates `"..."`).
 * `literalOf` answers the narrow "is this a PLAIN literal, and what is its raw
 * content" question its callers ask: a `SingleStringExpr` qualifies only when every
 * fragment is a `Literal` or an ESCAPED `Dollar` (`$$`). A LONE `$` (`LoneDollar`)
 * is deliberately excluded even though it is literal text — a caller appending to
 * such a literal would turn the trailing `$` into live interpolation.
 *
 * `segmentsOf` / `expressionSegment` are the general decomposition the width-aware
 * `fold-adjacent-string-literals` grouping runs on, and `renderGroup` / `renderBare`
 * are their inverse. Three Haxe facts live here and nowhere else: `PRIMARY_KINDS`,
 * the expression kinds that bind at least as tightly as `+` (so a bare operand needs
 * no parentheses); the single-quoted escaping rules — a lone `$` normalises to `$$`,
 * a double-quoted literal re-escapes `\"` to `"`, `$` to `$$` and `'` to `\'`, and a
 * raw carrying a `\x..` / `\u....` escape may not be re-emitted into a single-quoted
 * literal at all, because the compiler DECODES those escapes before it scans for
 * `$`; and `interpolationBlockSafe`, what a `${ … }` block may contain.
 */
@:nullSafety(Strict)
final class HaxeStringFoldSupport implements StringFoldSupport {

	/** The escaped form of one literal dollar inside a single-quoted literal (a two-character string). */
	private static inline final ESCAPED_DOLLAR: String = "$$";

	/**
	 * Expression kinds that bind at least as tightly as `+`, so a lone segment of
	 * one needs no parentheses when it is emitted as a bare concatenation operand.
	 * A POSITIVE list on purpose: a negative one ("everything but ternary and
	 * assignment") leaks by category as soon as the grammar grows an operator.
	 */
	private static final PRIMARY_KINDS: Array<String> = [
		'IdentExpr',
		'IntLit',
		'FloatLit',
		'BoolLit',
		'NullLit',
		'SingleStringExpr',
		'DoubleStringExpr',
		'FieldAccess',
		'SafeFieldAccess',
		'Call',
		'IndexAccess',
		'NewExpr',
		'ParenExpr',
		'ArrayExpr',
		'ObjectLit',
		'ECheckTypeExpr',
		'Mul',
		'Div',
		'Mod',
		'Neg',
		'Not',
		'PreIncr',
		'PreDecr',
		'PostIncr',
		'PostDecr'
	];

	public function new() {}

	public function concatKind(): String {
		return 'Add';
	}

	public function literalOf(node: QueryNode, source: String): Null<StringLiteral> {
		final span: Null<Span> = node.span;
		if (span == null || span.to - span.from < 2) return null;
		return switch node.kind {
			case 'DoubleStringExpr': { quote: '"', content: inner(source, span) };
			case 'SingleStringExpr': node.children.foreach(c -> c.kind == 'Literal' || c.kind == 'Dollar') ? {
				quote: "'",
				content: inner(source, span)
			} : null;
			case _: null;
		}
	}

	/**
	 * A `DoubleStringExpr` is one `SegText` (Haxe never interpolates `"…"`); a
	 * `SingleStringExpr` maps child-per-child — `Literal` to `SegText`, the `$name`
	 * shorthand (`Ident`) to `SegIdent`, a `${ … }` `Block` to its INNER
	 * expression's segment. An empty literal still yields one empty `SegText`, so
	 * every literal contributes at least one segment.
	 *
	 * Both `Dollar` (`$$`) and `LoneDollar` (`$`) normalise to the ESCAPED form:
	 * appending a text that starts with a letter to a raw lone `$` would silently
	 * create an interpolation, and the escaped form is what re-parsing this check's
	 * own output produces — which is what makes the decomposition a fixed point.
	 */
	public function segmentsOf(node: QueryNode, source: String): Null<Array<ConcatSegment>> {
		final span: Null<Span> = node.span;
		if (span == null || span.to - span.from < 2) return null;
		if (node.kind == 'DoubleStringExpr') return [SegText('"', inner(source, span))];
		if (node.kind != 'SingleStringExpr') return null;
		final out: Array<ConcatSegment> = [];
		for (c in node.children) {
			final childSpan: Null<Span> = c.span;
			if (childSpan == null) return null;
			switch c.kind {
				case 'Literal':
					out.push(SegText("'", source.substring(childSpan.from, childSpan.to)));
				case 'Dollar', 'LoneDollar':
					out.push(SegText("'", ESCAPED_DOLLAR));
				case 'Ident':
					final name: Null<String> = c.name;
					if (name == null) return null;
					out.push(SegIdent(name));
				case 'Block':
					if (c.children.length != 1) return null;
					final seg: Null<ConcatSegment> = expressionSegment(c.children[0], source);
					if (seg == null) return null;
					out.push(seg);
				case _:
					return null;
			}
		}
		if (out.length == 0) out.push(SegText("'", ''));
		return coalesceText(out);
	}

	/**
	 * A bare identifier becomes `SegIdent` (rendered `$name`); everything else
	 * becomes `SegExpr` carrying its verbatim source plus whether its kind is in
	 * `PRIMARY_KINDS`. `this` is deliberately NOT a `SegIdent` — `$this` is not the
	 * interpolation shorthand.
	 */
	public function expressionSegment(node: QueryNode, source: String): Null<ConcatSegment> {
		final span: Null<Span> = node.span;
		if (span == null) return null;
		final name: Null<String> = node.name;
		if (node.kind == 'IdentExpr' && name != null && name != 'this') return SegIdent(name);
		return SegExpr(source.substring(span.from, span.to), PRIMARY_KINDS.contains(node.kind));
	}

	public function renderGroup(segments: Array<ConcatSegment>): Null<String> {
		if (segments.length == 0) return null;
		final plainQuote: Null<String> = sharedTextQuote(segments);
		return plainQuote != null ? renderPlain(plainQuote, segments) : renderInterpolated(segments);
	}

	public function renderBare(segment: ConcatSegment): Null<String> {
		return switch segment {
			case SegText(_, _): null;
			case SegIdent(name): name;
			case SegExpr(src, primary): primary ? src : '($src)';
		}
	}

	/**
	 * An all-text group as ONE plain literal in the quote its texts share, joined by
	 * RAW concatenation — the original `fold-adjacent-string-literals` semantics,
	 * kept so `"a" + "b"` still folds to `"ab"` rather than switching the file's
	 * quoting to `'ab'`. A SINGLE-quoted result still has to clear `escapedTexts`:
	 * Haxe decodes `\x..` / `\u....` before it scans a `'…'` for interpolation, so a
	 * `\x24` carried into the merged literal would become a live `$`.
	 */
	private static function renderPlain(quote: String, segments: Array<ConcatSegment>): Null<String> {
		if (quote == "'" && escapedTexts(segments) == null) return null;
		final buf: StringBuf = new StringBuf();
		buf.add(quote);
		for (s in segments) switch s {
			case SegText(_, raw):
				buf.add(raw);
			case _:
		}
		buf.add(quote);
		return buf.toString();
	}

	/**
	 * A mixed group as ONE single-quoted interpolated literal: each text segment
	 * re-escaped for that context, each expression segment inside a `${ … }` block,
	 * each identifier as `$name` — braced when the next emitted character would
	 * extend the name. Null when a text refuses re-escaping (`escapedTexts`) or an
	 * expression cannot enter a block (`interpolationBlockSafe`).
	 */
	private static function renderInterpolated(segments: Array<ConcatSegment>): Null<String> {
		final texts: Null<Array<String>> = escapedTexts(segments);
		if (texts == null) return null;
		final escaped: Array<String> = texts;
		final buf: StringBuf = new StringBuf();
		buf.add("'");
		for (i in 0...segments.length) switch segments[i] {
			case SegText(_, _):
				buf.add(escaped[i]);
			case SegExpr(src, _):
				if (!interpolationBlockSafe(src)) return null;
				buf.add('$${$src}');
			case SegIdent(name):
				final nc: Int = nextOutputChar(segments, escaped, i + 1);
				buf.add(nc != -1 && isIdentContinue(nc) ? '$${$name}' : '$$$name');
		}
		buf.add("'");
		return buf.toString();
	}

	/**
	 * Every segment's text re-escaped for a SINGLE-quoted literal, parallel to
	 * `segments` (empty in the slots that hold no text), or null when ONE of them
	 * refuses. Computed once per group, so a `$name` lookahead reads the escaping
	 * rather than redoing it.
	 */
	private static function escapedTexts(segments: Array<ConcatSegment>): Null<Array<String>> {
		final out: Array<String> = [];
		for (s in segments) switch s {
			case SegText(quote, raw):
				final text: Null<String> = escapeLiteral(quote, raw);
				if (text == null) return null;
				out.push(text);
			case _:
				out.push('');
		}
		return out;
	}

	/** The raw source between the literal's two quote characters. */
	private static inline function inner(source: String, span: Span): String {
		return source.substring(span.from + 1, span.to - 1);
	}

	/**
	 * Fuse adjacent same-quote text segments into one. A `Dollar` fragment sits
	 * BETWEEN two `Literal` fragments of the same literal, and leaving the three
	 * apart would let the grouping cut a plain run of TEXT at the `$` — a split
	 * this rule promises never to make (it cuts at interpolation seams only).
	 */
	private static function coalesceText(segments: Array<ConcatSegment>): Array<ConcatSegment> {
		final out: Array<ConcatSegment> = [];
		for (s in segments) switch [out.length > 0 ? out[out.length - 1] : null, s] {
			case [SegText(prevQuote, prevRaw), SegText(quote, raw)] if (prevQuote == quote):
				out[out.length - 1] = SegText(quote, prevRaw + raw);
			case _:
				out.push(s);
		}
		return out;
	}

	/**
	 * The one quote every segment shares when they are ALL text, else null. Such a
	 * group renders as a plain literal by raw concatenation — the old
	 * `fold-adjacent-string-literals` semantics, kept so `"a" + "b"` still folds to
	 * `"ab"` rather than switching the file's quoting to `'ab'`.
	 */
	private static function sharedTextQuote(segments: Array<ConcatSegment>): Null<String> {
		var shared: Null<String> = null;
		for (s in segments) switch s {
			case SegText(quote, _):
				if (shared == null)
					shared = quote;
				else if (shared != quote)
					return null;
			case _:
				return null;
		}
		return shared;
	}

	/**
	 * Whether `src` can sit inside a single-quoted `'${ … }'` block. Both refusals
	 * follow the REAL Haxe compiler's interpolation scanner, which is cruder than
	 * anyparse's own lexer:
	 *
	 *  - a `$` would re-interpolate and a line break would break the literal, and a
	 *    BACKSLASH is refused because the scanner does not process escapes inside a
	 *    nested same-quote string (`'\\'` reports "Unterminated string");
	 *  - the block's closing `}` is found by counting `{` / `}` NAIVELY, without
	 *    lexing nested strings, so a brace inside one still counts. A source whose
	 *    running depth ever goes negative closes the block early (`q("}")` reports
	 *    "Unterminated string") and one that ends above zero never closes it
	 *    (`q("{")` reports "Unclosed brace"). A balanced `{x: 1}.x` is fine.
	 */
	private static function interpolationBlockSafe(src: String): Bool {
		var depth: Int = 0;
		for (i in 0...src.length) {
			final c: Int = StringTools.fastCodeAt(src, i);
			if (c == "$".code || c == '\n'.code || c == '\r'.code || c == '\\'.code) return false;
			if (c == '{'.code) {
				depth++;
			} else if (c == '}'.code) {
				depth--;
				if (depth < 0) return false;
			}
		}
		return depth == 0;
	}

	/**
	 * The single-quoted-context escaping of a text segment's raw content (its `quote`
	 * selects the rule), or null when the raw carries a `\x..` / `\u....` escape.
	 * Those are REFUSED rather than copied: Haxe DECODES them before it scans a
	 * `'…'` for interpolation, so a `\x24` reaching the output is a live `$` —
	 * `'\x24a'` is the value of the local `a`, not the text `$a`.
	 */
	private static function escapeLiteral(quote: String, raw: String): Null<String> {
		if (hasNumericEscape(raw)) return null;
		return quote == "'" ? normalizeSingleDollars(raw) : escapeDoubleToSingle(raw);
	}

	/**
	 * Whether `raw` carries a `\x..` or `\u....` escape. A `\\` is consumed as one
	 * unit, so the literal backslash in `'\\x24'` does not count.
	 */
	private static function hasNumericEscape(raw: String): Bool {
		var i: Int = 0;
		while (i < raw.length) {
			if (StringTools.fastCodeAt(raw, i) != '\\'.code) {
				i++;
				continue;
			}
			if (i + 1 >= raw.length) return false;
			final next: Int = StringTools.fastCodeAt(raw, i + 1);
			if (next == 'x'.code || next == 'u'.code) return true;
			i += 2;
		}
		return false;
	}

	/**
	 * Normalize a single-quoted literal's already-escaped raw content for reuse
	 * inside a single-quoted interpolation: a lone `$` becomes `$$`, an existing
	 * `$$` pair is preserved. Every other character (`\'`, `\n`, `\\`) is copied
	 * verbatim; a `\x..` / `\u....` never arrives, `escapeLiteral` having refused it.
	 */
	private static function normalizeSingleDollars(s: String): String {
		final buf: StringBuf = new StringBuf();
		var i: Int = 0;
		while (i < s.length) {
			final c: Int = StringTools.fastCodeAt(s, i);
			if (c == "$".code) {
				buf.add(ESCAPED_DOLLAR);
				i += i + 1 < s.length && StringTools.fastCodeAt(s, i + 1) == "$".code ? 2 : 1;
			} else {
				buf.addChar(c);
				i++;
			}
		}
		return buf.toString();
	}

	/**
	 * Re-escape a double-quoted literal's raw content for a single-quoted
	 * interpolation: `\"` becomes `"`, `$` becomes `$$`, `'` becomes `\'`; other
	 * escapes (`\n`, `\t`, `\\`) and plain characters are copied verbatim. A
	 * `\x..` / `\u....` never arrives, `escapeLiteral` having refused it.
	 */
	private static function escapeDoubleToSingle(raw: String): String {
		final buf: StringBuf = new StringBuf();
		var i: Int = 0;
		while (i < raw.length) {
			final c: Int = StringTools.fastCodeAt(raw, i);
			if (c == '\\'.code && i + 1 < raw.length) {
				final n: Int = StringTools.fastCodeAt(raw, i + 1);
				if (n == '"'.code) {
					buf.addChar('"'.code);
				} else {
					buf.addChar('\\'.code);
					buf.addChar(n);
				}
				i += 2;
			} else if (c == "$".code) {
				buf.add(ESCAPED_DOLLAR);
				i++;
			} else if (c == "'".code) {
				buf.add("\\'");
				i++;
			} else {
				buf.addChar(c);
				i++;
			}
		}
		return buf.toString();
	}

	/**
	 * The first output character code that `segments[j...]` emits, or -1 when none
	 * remain. `escaped` is `escapedTexts`' parallel array — the text slots are read
	 * from it rather than re-escaped.
	 */
	private static function nextOutputChar(segments: Array<ConcatSegment>, escaped: Array<String>, j: Int): Int {
		for (k in j ... segments.length) switch segments[k] {
			case SegText(_, _):
				if (escaped[k].length > 0) return StringTools.fastCodeAt(escaped[k], 0);
			case SegExpr(_, _), SegIdent(_):
				return "$".code;
		}
		return -1;
	}

	/** Whether `code` continues an identifier (a letter, a digit, or an underscore). */
	private static function isIdentContinue(code: Int): Bool {
		return code >= 'a'.code && code <= 'z'.code || code >= 'A'.code && code <= 'Z'.code || code >= '0'.code && code <= '9'.code
			|| code == '_'.code;
	}

}
