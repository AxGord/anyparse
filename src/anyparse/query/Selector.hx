package anyparse.query;

import anyparse.query.Pattern.KindEquivalence;

/**
 * Parsed `--select` path expression.
 *
 * V1 grammar (frozen, see `docs/cli-query-tool.md`):
 *
 *  - `kind`             — match any node with this kind
 *  - `kind:name`        — match a node of this kind whose name equals
 *  - `kind name`        — space is an accepted alias for the `:`
 *  - `A > B`            — `B` is a direct child of `A`
 *
 * The selector is a non-empty sequence of segments separated by `>`.
 * The first segment matches at any depth from the root; subsequent
 * segments must match direct children of the previous match.
 *
 * Whitespace around `>` is permitted and discarded by the parser.
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
		final raw: Array<String> = source.split('>');
		final segments: Array<SelectorSegment> = [];
		for (part in raw) {
			final trimmed: String = trim(part);
			if (trimmed == '') throw 'selector: empty segment in "$source"';
			segments.push(parseSegment(trimmed));
		}
		if (segments.length == 0) throw 'selector: empty selector';
		return new Selector(segments);
	}

	private static function parseSegment(s: String): SelectorSegment {
		final colon: Int = s.indexOf(':');
		if (colon >= 0) {
			final kind: String = trim(s.substr(0, colon));
			final name: String = trim(s.substr(colon + 1));
			if (kind == '') throw 'selector: missing kind in "$s"';
			if (name == '') throw 'selector: missing name after colon in "$s"';
			return new SelectorSegment(kind, name);
		}
		// No colon: accept `Kind name` as equivalent to `Kind:name`.
		// Kind and name are single identifiers, so the first interior
		// whitespace run is an unambiguous kind/name separator — this
		// makes the natural `--select 'FnMember paramBody'` work.
		final ws: Int = firstWs(s);
		if (ws < 0) return new SelectorSegment(s, null);
		final name: String = trim(s.substr(ws + 1));
		return new SelectorSegment(s.substr(0, ws), name == '' ? null : name);
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

	public function new(kind: String, name: Null<String>) {
		this.kind = kind;
		this.name = name;
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
		if (!kindMatch) return false;
		if (name == null) return true;
		return node.name == name;
	}

}
