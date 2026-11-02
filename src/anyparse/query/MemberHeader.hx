package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.runtime.Span;

/**
 * The one answer to "what is a member's declaration header, without its body?": the source
 * text from a caller-chosen start up to where the body begins, with the trailing `{` or `;`
 * trimmed.
 *
 * The cut is STRUCTURAL: the first child whose kind the grammar lists as a function body
 * (`RefShape.functionBodyKinds`), else a caller-supplied bound (a type's first member), else the
 * end of the node. No text scan for a brace, so a `{` or `;` inside a type, a string or a default
 * value cannot end the header early.
 */
@:nullSafety(Strict)
final class MemberHeader {

	/**
	 * The header of `node` read from `source` between `from` and the body, or null when that
	 * range is blank. `from` is the caller's: `node.span.from` for a signature that starts at the
	 * member itself, earlier to keep same-line modifiers the grammar stores as siblings. `until`
	 * bounds the header from the right when the node's own children carry no body marker (the
	 * offset of a type's first member).
	 */
	public static function of(node: QueryNode, source: String, shape: RefShape, from: Int, ?until: Int): Null<String> {
		final span: Null<Span> = node.span;
		if (span == null) return null;
		final bodyKinds: Array<String> = shape.functionBodyKinds ?? [];
		var cut: Int = span.to;
		for (child in node.children) {
			final childSpan: Null<Span> = child.span;
			if (childSpan != null && bodyKinds.contains(child.kind) && childSpan.from < cut) cut = childSpan.from;
		}
		if (until != null && until < cut) cut = until;
		if (cut <= from) return null;
		var header: String = source.substring(from, cut).trim();
		if (header.endsWith(';') || header.endsWith('{')) header = header.substr(0, header.length - 1).trim();
		return header == '' ? null : header;
	}

}
