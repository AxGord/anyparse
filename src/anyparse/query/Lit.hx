package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;

/**
 * String-literal / leaf-name walker for `apq lit` — finds verbatim
 * occurrences of a target text inside captured leaf-node `name` slots.
 *
 * Use case: annotation-key lookups and similar "prose inside code"
 * searches that are NOT structural patterns. The conventional grep
 * route is gated on parseable `.hx` files (the hxq skill's `# HXQ_OK:prose`
 * escape hatch). `apq lit` solves it inside the structural pipeline:
 * the parser already lifts every string literal into a `Literal`
 * leaf whose `name` carries the verbatim content, so walking the tree
 * is byte-for-byte equivalent to grepping the source for that string
 * — minus all the comment / interpolation / multi-line false positives
 * a raw text search produces.
 *
 * Default kind filter is `Literal` (the leaf inside `SingleStringExpr`
 * / `DoubleStringExpr` / `RawString` in the Haxe plugin); pass a
 * comma-separated list via `--kind` to widen or override. Common
 * widenings:
 *
 *  - `Literal,IdentExpr` — string literals + bare identifier uses.
 *  - `IdentExpr` — only identifier references (similar to `refs`
 *    but text-only, no scope or binding resolution).
 *
 * The plugin is consulted indirectly: `apq lit` reuses the standard
 * `plugin.parseFile` value-AST so every captured leaf surfaces through
 * the same `QueryNode.name` slot the engine already exposes for
 * `--select` / `refs` / `meta`. No plugin-specific code lives here.
 */
@:nullSafety(Strict)
final class Lit {

	/**
	 * Truncate hit content for rendering: collapse to the first source line,
	 * suffix `… +N more` when bytes were dropped. Captured `name` keeps
	 * the full content for downstream consumers — only the printed display
	 * truncates. Killer case: a `lit '/*' src/ --any-kind` over a corpus
	 * heavy with multi-line `/** … *\/` doc-comments previously dumped
	 * thousands of body lines verbatim (~190KB for src/). Now each hit
	 * occupies one line; the user still sees locus + kind + first line.
	 */
	private static inline final DISPLAY_MAX: Int = 120;

	/**
	 * Walk `tree`, collecting every leaf-or-named node whose `name`
	 * matches `target`. `exact=true` requires `name == target`; default
	 * is substring match (`name.indexOf(target) >= 0`).
	 *
	 * `kindFilter` (non-empty) restricts hits to nodes whose `kind` is
	 * in the set. Empty / null means no filter (match every node with
	 * a non-null name). The check is by exact string equality on
	 * `kind` — no kind-equivalence consultation (that is search-only;
	 * `lit` is a leaf-name probe with no pattern semantics).
	 *
	 * `delimiters` is the grammar's `RefShape.stringLiteralDelimiters`: for a kind listed there
	 * the `name` slot is the raw source slice WITH its quotes, so the match is tried against the
	 * name AND against the content inside them. Widening, never narrowing — a query spelling the
	 * quotes still matches. Without it the two spellings of one literal answered differently:
	 * `'needle'` matched and `"needle"` did not under `--exact`, and under a substring match only
	 * because the quotes happen to sit at the ends.
	 */
	public static function find(
		target: String, tree: QueryNode, exact: Bool, ?kindFilter: Array<String>, ?delimiters: Map<String, String>
	): Array<LitHit> {
		final out: Array<LitHit> = [];
		final filter: Null<Array<String>> = kindFilter == null || kindFilter.length == 0 ? null : kindFilter;
		walk(target, tree, exact, filter, delimiters, out);
		return out;
	}

	/**
	 * The kinds of `shape` whose `name` slot CARRIES string-literal content: the interpolating
	 * literal's plain-text fragment (`stringInterpTextKind`) first, then every `stringLiteralKinds`
	 * entry that is not itself an `interpolatingStringKinds` one. Deduped, and in that order so a
	 * hit listing reads fragment-before-whole the way a nested literal nests.
	 *
	 * This is the default kind set of `apq lit`, and naming ONE of its members was the command's
	 * oldest defect: over a directory holding `'needle'` and `"needle"` it printed the
	 * single-quoted hit and said nothing about the other, because the 0-hit auto-widen never
	 * fired. `CondQuery.carriesLiteralText` asks the same question with the opposite polarity —
	 * that consumer DROPS these kinds from a symbol listing — so the two now read one vocabulary.
	 *
	 * The subtraction is what keeps the set honest rather than merely wide: a segmented literal's
	 * OWN name slot is empty — its content lives in the fragments already named — so listing it
	 * would add a kind that can never match and then report it to the user as content they are
	 * missing.
	 *
	 * A grammar declaring none of the three leaves the set EMPTY, which `find` reads as no kind
	 * filter at all — the same answer `--any-kind` gives. That is the fail-open direction on
	 * purpose: an unaudited grammar gets a noisy answer rather than a silently empty one.
	 */
	public static function contentKinds(shape: RefShape): Array<String> {
		final text: Null<String> = shape.stringInterpTextKind;
		final segmented: Array<String> = shape.interpolatingStringKinds ?? [];
		final out: Array<String> = text == null ? [] : [text];
		for (kind in shape.stringLiteralKinds ?? []) if (!segmented.contains(kind) && !out.contains(kind)) out.push(kind);
		return out;
	}

	public static function render(file: String, source: String, hits: Array<LitHit>, flat: Bool = false): String {
		final buf: StringBuf = new StringBuf();
		if (!flat && hits.length > 0) buf.add('$file:\n');
		for (h in hits) {
			final pos: Position = h.span.lineCol(source);
			final shown: String = displayText(h.name);
			buf.add(flat ? '$file:${pos.line}:${pos.col}: ${h.kind} \'$shown\'\n' : '  ${pos.line}:${pos.col}: ${h.kind} \'$shown\'\n');
		}
		return buf.toString();
	}

	/** Whether `name` answers `target`: full equality under `exact`, else a substring test. */
	private static inline function matches(name: String, target: String, exact: Bool): Bool {
		return exact ? name == target : name.indexOf(target) >= 0;
	}

	/**
	 * `name` with one `delimiter` stripped off each end, or null when it does not carry the pair.
	 *
	 * A pair rather than a prefix: a one-character slice like `"` is the quote itself and stripping
	 * it twice off the same byte would answer about an empty content. Escapes are NOT decoded —
	 * this is about the QUOTES, and the grammar's other string spelling leaves its escapes raw
	 * too, so decoding here would make the two answer differently for the opposite reason.
	 */
	private static function unquoted(name: String, delimiter: String): Null<String> {
		final width: Int = delimiter.length;
		return name.length < width * 2 || name.substr(0, width) != delimiter || name.substr(name.length - width) != delimiter
			? null
			: name.substring(width, name.length - width);
	}

	private static function walk(
		target: String, node: QueryNode, exact: Bool, filter: Null<Array<String>>, delimiters: Null<Map<String, String>>,
		out: Array<LitHit>
	): Void {
		final n: Null<String> = node.name;
		if (n != null) {
			final kindOk: Bool = filter == null || filter.contains(node.kind);
			if (kindOk) {
				final delimiter: Null<String> = delimiters == null ? null : delimiters[node.kind];
				final content: Null<String> = delimiter == null ? null : unquoted(n, delimiter);
				final hit: Bool = matches(n, target, exact) || content != null && matches(content, target, exact);
				if (hit && node.span != null) out.push(new LitHit(node.kind, n, (node.span: Span)));
			}
		}
		for (c in node.children) walk(target, c, exact, filter, delimiters, out);
	}

	private static function displayText(name: String): String {
		final nl: Int = name.indexOf('\n');
		final firstLine: String = nl < 0 ? name : name.substring(0, nl);
		// Count trailing lines so the user sees how much was hidden.
		var trailingLines: Int = 0;
		var i: Int = nl;
		while (i >= 0 && i < name.length) {
			trailingLines++;
			i = name.indexOf('\n', i + 1);
		}
		final tail: String = trailingLines > 0 ? ' … +$trailingLines lines' : '';
		if (firstLine.length <= DISPLAY_MAX) return firstLine + tail;
		final dropChars: Int = firstLine.length - DISPLAY_MAX;
		return '${firstLine.substring(0, DISPLAY_MAX)} … +$dropChars chars$tail';
	}

}

/**
 * One `apq lit` result: a string / numeric literal matched by content, carrying
 * its node `kind`, the literal `name` (its source text), and its source `span`.
 */
@:nullSafety(Strict)
final class LitHit {

	public final kind: String;
	public final name: String;
	public final span: Span;

	public function new(kind: String, name: String, span: Span) {
		this.kind = kind;
		this.name = name;
		this.span = span;
	}

}
