package anyparse.query;

import anyparse.query.Pattern.KindEquivalence;

/**
 * Parsed `--select` path expression.
 *
 * V2 grammar (see `docs/cli-query-tool.md`):
 *
 *  - `kind`             — match any node with this kind
 *  - `kind:name`        — match a node of this kind whose name equals
 *  - `kind name`        — space is an accepted alias for the `:`
 *  - `A > B`            — `B` is a direct child of `A`
 *  - `A >> B`           — `B` is any-depth descendant of `A`
 *
 * The selector is a non-empty sequence of segments separated by `>`
 * (direct child) or `>>` (descendant). The first segment matches at any
 * depth from the root; each later segment matches relative to the
 * previous match per its separator.
 *
 * Whitespace around separators is permitted and discarded by the parser.
 */
@:nullSafety(Strict)
final class Selector {

	public final segments: Array<SelectorSegment>;

	public function new(segments: Array<SelectorSegment>) {
		this.segments = segments;
	}

	/**
	 * Parse a selector string. Throws on malformed input — the CLI
	 * catches the exception and prints a user-facing error.
	 */
	public static function parse(source: String): Selector {
		final segments: Array<SelectorSegment> = [];
		var start: Int = 0;
		var descendant: Bool = false;
		var i: Int = 0;
		inline function pushSegment(end: Int): Void {
			final trimmed: String = trim(source.substring(start, end));
			if (trimmed == '') throw 'selector: empty segment in "$source"';
			segments.push(parseSegment(trimmed, descendant));
		}
		while (i < source.length) {
			if (StringTools.fastCodeAt(source, i) == '>'.code) {
				pushSegment(i);
				final double: Bool = i + 1 < source.length && StringTools.fastCodeAt(source, i + 1) == '>'.code;
				descendant = double;
				i += double ? 2 : 1;
				start = i;
			} else {
				i++;
			}
		}
		pushSegment(source.length);
		if (segments.length == 0) throw 'selector: empty selector';
		return new Selector(segments);
	}

	private static function parseSegment(s: String, descendant: Bool): SelectorSegment {
		final colon: Int = s.indexOf(':');
		if (colon >= 0) {
			final kind: String = trim(s.substr(0, colon));
			final name: String = trim(s.substr(colon + 1));
			if (kind == '') throw 'selector: missing kind in "$s"';
			if (name == '') throw 'selector: missing name after colon in "$s"';
			return new SelectorSegment(kind, name, descendant);
		}
		// No colon: accept `Kind name` as equivalent to `Kind:name`.
		// Kind and name are single identifiers, so the first interior
		// whitespace run is an unambiguous kind/name separator — this
		// makes the natural `--select 'FnMember paramBody'` work.
		final ws: Int = firstWs(s);
		if (ws < 0) return new SelectorSegment(s, null, descendant);
		final name: String = trim(s.substr(ws + 1));
		return new SelectorSegment(s.substr(0, ws), name == '' ? null : name, descendant);
	}

	private static function firstWs(s: String): Int {
		for (i in 0...s.length) if (isWs(StringTools.fastCodeAt(s, i))) return i;
		return -1;
	}

	private static function trim(s: String): String {
		var start: Int = 0;
		var end: Int = s.length;
		while (start < end && isWs(StringTools.fastCodeAt(s, start))) start++;
		while (end > start && isWs(StringTools.fastCodeAt(s, end - 1))) end--;
		return s.substring(start, end);
	}

	private static inline function isWs(c: Int): Bool {
		return c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code;
	}

}

@:nullSafety(Strict)
final class SelectorSegment {

	public final kind: String;
	public final name: Null<String>;

	/**
	 * Relation of this segment to the PREVIOUS match: `false` — a direct
	 * child (`A > B`), `true` — any-depth descendant (`A >> B`). Meaningless
	 * on the first segment (which matches at any depth from the root).
	 */
	public final descendant: Bool;

	public function new(kind: String, name: Null<String>, descendant: Bool = false) {
		this.kind = kind;
		this.name = name;
		this.descendant = descendant;
	}

	/**
	 * Does `node` match this segment? `equiv` (when non-null) widens the
	 * kind test through the grammar's kind-equivalence relation, so a
	 * `--select ClassDecl` matches the `final class` inner `ClassForm` and
	 * `--select FnMember` matches a `final function`'s `FinalModifiedMember`
	 * (see `GrammarPlugin.selectKindEquivalence`). A null `equiv` keeps the
	 * exact-kind behaviour, so the matcher stays usable without a plugin
	 * (synthetic-tree callers / tests).
	 */
	public function matches(node: QueryNode, ?equiv: KindEquivalence): Bool {
		final kindMatch: Bool = equiv == null ? node.kind == kind : equiv.equivalent(node.kind, kind);
		return kindMatch && (name == null || node.name == name);
	}

}
