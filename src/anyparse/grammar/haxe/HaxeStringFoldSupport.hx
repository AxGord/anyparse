package anyparse.grammar.haxe;

import anyparse.query.QueryNode;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.StringLiteral;
import anyparse.runtime.Span;

using StringTools;
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
 * `requoteVerbatim` answers the neighbouring "may this literal simply change quotes"
 * question (`prefer-single-quotes`' whole decision) on the same lexer terms.
 *
 * `segmentsOf` / `expressionSegment` are the general decomposition the width-aware
 * `fold-adjacent-string-literals` grouping runs on, and `renderGroup` / `renderBare`
 * are their inverse. A text fragment is cut once more, at each `\n` ESCAPE it carries
 * (`splitAtNewlines`), which is the only seam a literal with no interpolation has.
 * Three Haxe facts live here and nowhere else: `PRIMARY_KINDS`,
 * the expression kinds that bind at least as tightly as `+` (so a bare operand needs
 * no parentheses); the single-quoted escaping rules — a lone `$` normalises to `$$`,
 * a double-quoted literal re-escapes `\"` to `"`, `$` to `$$` and `'` to `\'`, and a
 * double-quoted raw whose escapes DECODE to a `$` (`"\x24a"`) may not be re-emitted
 * into a single-quoted literal at all, because the compiler decodes before it scans
 * for `$`, so the text `$a` would become the VALUE of `a` (`HxStringEscape`); and
 * `interpolationBlockSafe`, what a `${ … }` block may contain.
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
		return span == null || span.to - span.from < 2
			? null
			: switch node.kind {
				case 'DoubleStringExpr': { quote: '"', content: inner(source, span) };
				case 'SingleStringExpr': node.children.foreach(c -> c.kind == 'Literal' || c.kind == 'Dollar') ? {
					quote: "'",
					content: inner(source, span)
				} : null;
				case _: null;
			};
	}

	/**
	 * Only the double→single direction is modelled, the one `prefer-single-quotes`
	 * asks about. Two conditions, both about what the CONTENT can spell rather than
	 * about which escapes it happens to use:
	 *
	 *  - a raw `'` would close the single-quoted form early. An ESCAPED one (`\'`)
	 *    may not — it means `'` under both quotings — and so may a `\x27`, which
	 *    decodes to `'` only AFTER the literal's extent is already fixed;
	 *  - the content must decode to no `$`, spelled raw or through an escape. Haxe
	 *    decodes before it scans for interpolation, so `"\x24a"` (the text `$a`)
	 *    would become the VALUE of `a` the moment it moved into single quotes —
	 *    compile-and-run verified, and the reason this lives behind the seam.
	 *
	 * A `"` needs nothing: it is an ordinary character inside `'…'`, and the `\"`
	 * escape stays valid there too.
	 */
	public function requoteVerbatim(literal: StringLiteral, quote: String): Null<String> {
		return if (quote != "'" || literal.quote != '"')
			null
		else if (unescapedQuote(literal.content) || HxStringEscape.carriesDollar(literal.content))
			null
		else
			'\'${literal.content}\'';
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
		if (node.kind == 'DoubleStringExpr') return splitAtNewlines([SegText('"', inner(source, span))]);
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
		return splitAtNewlines(coalesceText(out));
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
		return node.kind == 'IdentExpr' && name != null && name != 'this'
			? SegIdent(name)
			: SegExpr(source.substring(span.from, span.to), PRIMARY_KINDS.contains(node.kind));
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
	 * quoting to `'ab'`.
	 *
	 * Neither quoting needs a guard here. Same-quote texts concatenate by definition,
	 * and the one hazard — an escape that DECODES to `$` and starts interpolating once
	 * it lands in a single-quoted literal — cannot reach a single-quoted `SegText`:
	 * `HxInterpProjection` has already split every escape-spelled trigger out of the
	 * fragment it came from, so a group holding one is no longer all-text and never
	 * arrives here. A DOUBLE-quoted group interpolates nothing whatever its escapes say.
	 */
	private static function renderPlain(quote: String, segments: Array<ConcatSegment>): String {
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
				buf.add(nc != -1 && HxStringEscape.isIdentContinue(nc) ? '$${$name}' : '$$$name');
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
	 * this rule promises never to make. Fusing FIRST is also what lets
	 * `splitAtNewlines` see a `\n` escape that a `$` happens to sit next to: the two
	 * run in that order, so the only text seams that survive are the ones it cuts.
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
	 * Cut every text segment after each `\n` ESCAPE it carries, the escape staying with
	 * the LEFT piece. This is the seam that makes a lone over-long string TOKEN
	 * layout-fixable at all: the writer can wrap a `+` chain but nothing can wrap one
	 * literal, so a message whose own text names its line breaks has to become a chain
	 * before layout can reach it.
	 *
	 * Idempotent with `renderPlain`, which is the whole reason the cut may be made here
	 * rather than in the grouping: two same-quote pieces render back to the single
	 * literal they came from, and re-decomposing that literal cuts it in the same two
	 * places. A group that keeps them together is therefore indistinguishable from never
	 * having split.
	 *
	 * The scan is the lexer's, not a search: a backslash consumes the character after it,
	 * so the `n` of `\\n` is an ordinary letter and never a seam. A RAW line break in the
	 * source is not one either — it already ends the line it sits on, so cutting there
	 * buys no width and would leave the break dangling inside the left literal. Nor is a
	 * line break spelled `\x0a` / `\u000a`: it decodes to one, but only the `\n` spelling
	 * is worth the decoder, and refusing the others costs a seam rather than correctness.
	 */
	private static function splitAtNewlines(segments: Array<ConcatSegment>): Array<ConcatSegment> {
		final out: Array<ConcatSegment> = [];
		for (s in segments) switch s {
			case SegText(quote, raw):
				for (piece in newlinePieces(raw)) out.push(SegText(quote, piece));
			case _:
				out.push(s);
		}
		return out;
	}

	/** `raw` cut after each `\n` escape; a raw ending in one yields no empty tail, and a raw with no seam yields itself. */
	private static function newlinePieces(raw: String): Array<String> {
		final pieces: Array<String> = [];
		var from: Int = 0;
		var i: Int = 0;
		while (i < raw.length) {
			if (raw.fastCodeAt(i) != '\\'.code) {
				i++;
			} else if (i + 1 < raw.length && raw.fastCodeAt(i + 1) == 'n'.code) {
				pieces.push(raw.substring(from, i + 2));
				i += 2;
				from = i;
			} else {
				i += 2;
			}
		}
		if (from < raw.length) pieces.push(raw.substring(from));
		if (pieces.length == 0) pieces.push(raw);
		return pieces;
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
	 * Whether `src` can sit inside a single-quoted `'${ … }'` block. The `$` and brace
	 * refusals follow the REAL Haxe compiler's interpolation scanner, which is cruder
	 * than anyparse's own lexer; the LINE-BREAK refusal is this model's own, and is
	 * STRICTER than the compiler:
	 *
	 *  - a `$` would re-interpolate, and a BACKSLASH is refused because the scanner does
	 *    not process escapes inside a nested same-quote string (`'\\'` reports
	 *    "Unterminated string"). A line break is refused because FOLDING one into a block
	 *    would reflow the caller's literal, NOT because the compiler rejects it: a Haxe
	 *    string literal spans lines freely and `${if (a)\n\tb\nelse c}` compiles. Callers
	 *    reasoning about what the scanner ACCEPTS must not read this as its rule;
	 *  - the block's closing `}` is found by counting `{` / `}` NAIVELY, without
	 *    lexing nested strings, so a brace inside one still counts. A source whose
	 *    running depth ever goes negative closes the block early (`q("}")` reports
	 *    "Unterminated string") and one that ends above zero never closes it
	 *    (`q("{")` reports "Unclosed brace"). A balanced `{x: 1}.x` is fine.
	 */
	private static function interpolationBlockSafe(src: String): Bool {
		var depth: Int = 0;
		for (i in 0...src.length) {
			final c: Int = src.fastCodeAt(i);
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
	 * The single-quoted-context escaping of a DOUBLE-quoted text segment's raw content,
	 * or the single-quoted one's own content with its lone dollars normalised.
	 *
	 * The double-quoted side is null when an ESCAPE of its raw decodes to a `$`: Haxe
	 * decodes `\x24` / `$` / `\u{24}` before it scans a `'…'` for interpolation,
	 * so such a raw reaching the output is a live `$` — `"\x24a"` is the text `$a`, but
	 * `'\x24a'` is the VALUE of the local `a`. A RAW `$` is no obstacle;
	 * `escapeDoubleToSingle` doubles it. And the test is precise, not "any `\x` /
	 * `\u` escape": `"\x41b"` denotes `Ab` under either quoting and folds fine.
	 *
	 * The single-quoted side asks nothing, and must not: its `$`s are the deliberate
	 * `$$` that `segmentsOf` emits for a `Dollar` fragment, and an escape-SPELLED
	 * trigger can no longer reach it — `HxInterpProjection` splits every one of those
	 * out of the `Literal` fragment before this seam ever sees the tree.
	 */
	private static function escapeLiteral(quote: String, raw: String): Null<String> {
		return if (quote == "'")
			normalizeSingleDollars(raw)
		else if (HxStringEscape.carriesEscapedDollar(raw))
			null
		else
			escapeDoubleToSingle(raw);
	}

	/** Whether `content` holds a `'` that is not part of an escape — the one character that ends a single-quoted literal. */
	private static function unescapedQuote(content: String): Bool {
		var i: Int = 0;
		while (i < content.length) {
			final c: Int = content.fastCodeAt(i);
			if (c == "'".code) return true;
			i += c == '\\'.code ? 2 : 1;
		}
		return false;
	}

	/**
	 * Normalize a single-quoted literal's already-escaped raw content for reuse
	 * inside a single-quoted interpolation: a lone `$` becomes `$$`, an existing
	 * `$$` pair is preserved. Every other character (`\'`, `\n`, `\\`, `\x..`,
	 * `\u....`) is copied verbatim, which is sound because it stays in the SAME
	 * quoting: an escape means there what it meant here. The one escape that would
	 * not — a `\x24` decoding to a live `$` — cannot be in this raw at all, since
	 * `HxInterpProjection` split it into its own segment before the seam saw the tree.
	 */
	private static function normalizeSingleDollars(s: String): String {
		final buf: StringBuf = new StringBuf();
		var i: Int = 0;
		while (i < s.length) {
			final c: Int = s.fastCodeAt(i);
			if (c == "$".code) {
				buf.add(ESCAPED_DOLLAR);
				i += i + 1 < s.length && s.fastCodeAt(i + 1) == "$".code ? 2 : 1;
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
	 * escapes (`\n`, `\t`, `\\`) and plain characters are copied verbatim. A `\x..` /
	 * `\u....` is copied verbatim TOO and that is deliberate — it denotes the same
	 * character under either quoting. Only one that DECODES to a `$` would not, and
	 * `escapeLiteral` has already refused the whole raw for that (`carriesEscapedDollar`).
	 */
	private static function escapeDoubleToSingle(raw: String): String {
		final buf: StringBuf = new StringBuf();
		var i: Int = 0;
		while (i < raw.length) {
			final c: Int = raw.fastCodeAt(i);
			if (c == '\\'.code && i + 1 < raw.length) {
				final n: Int = raw.fastCodeAt(i + 1);
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
	 * The first character code that `segments[j...]` emits AS THE COMPILER READS IT, or
	 * -1 when none remain. `escaped` is `escapedTexts`' parallel array — the text slots
	 * are read from it rather than re-escaped.
	 *
	 * DECODED, not raw: the caller is deciding whether the character would extend a
	 * `$name` it is about to emit, and the compiler decodes the literal before it scans
	 * for that name's end. A text starting `\x41b` begins with an `A`, so `'$x\x41b'`
	 * reads a local `xAb` — reading the raw backslash instead saw a boundary that is not
	 * there and shipped that VALUE change (compile-and-run verified).
	 */
	private static function nextOutputChar(segments: Array<ConcatSegment>, escaped: Array<String>, j: Int): Int {
		for (k in j ... segments.length) switch segments[k] {
			case SegText(_, _):
				if (escaped[k].length > 0) return HxStringEscape.firstCode(escaped[k]);
			case SegExpr(_, _), SegIdent(_):
				return "$".code;
		}
		return -1;
	}

}
