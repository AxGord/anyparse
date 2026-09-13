package anyparse.check;

import anyparse.query.QueryNode;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * Renders a source span as ONE LINE of display text for a finding's message: a whitespace run
 * BETWEEN tokens collapses to a single space, whitespace INSIDE a token — a string or regex
 * literal's own content — is copied byte for byte, and the ends are trimmed.
 *
 * ## Why this is not `CheckScan.normalizeSpan`
 *
 * That sibling collapses whitespace EVERYWHERE, literal interiors included. As an equality KEY
 * that is right wherever something EXACT stands beside it: `tail-merge` and
 * `redundant-case-body` pair it with `MemberKinds.structurallyEqual`, `prefer-case-guard` refuses
 * content carrying a backslash or either quote, and `extract-repeated-expression` uses it as a
 * cheap prefilter and re-splits every surviving bucket by this renderer. Standing alone it
 * manufactures matches instead: `duplicate-code` bucketed three-gram norms outright and read two
 * `--help` blocks padded to different column widths as a clone, so it keys on this renderer too.
 *
 * A MESSAGE is the opposite job. Its text is quoted back to a reader who is expected to find it
 * in the file, and where the check also offers a fix, that text is the code the fix would write.
 * A message rendering `'  '` as `' '` cannot be verified by reading, and it misdescribes the
 * rewrite — `prefer-static-extension` splices the receiver's bytes verbatim, so the two were
 * free to disagree. `extract-repeated-expression` is the second display consumer and needed only
 * the first half: it is report-only, so nothing there writes the quoted text, but the finding is
 * spanned at an occurrence a reader is expected to go and read. Normalising for comparison and
 * rendering for display are two operations;
 * they were one function, and only the comparison half was ever correct.
 *
 * ## Token interiors come from the TREE
 *
 * There is no lexer here and no literal-kind list. A LEAF of the node handed in has no structure
 * inside it, so whitespace within its span is content by construction — which is true of every
 * grammar, not just of Haxe strings. An interpolated string still collapses inside its `${…}`
 * holes: those project leaves of their own, and the whitespace between them lies in none of them.
 * A node with no children at all protects its whole span, which is the conservative direction.
 */
@:nullSafety(Strict)
final class SpanRender {

	/**
	 * `[from, to)` of `source` on one line, with token interiors intact. `root` must be a node
	 * whose subtree covers `[from, to)`; bytes of the range that lie in no leaf of it are treated
	 * as structure and their whitespace collapses.
	 */
	public static function renderSpan(source: String, from: Int, to: Int, root: QueryNode, ?overrides: Array<SpanOverride>): String {
		final parts: Array<RenderPart> = renderParts(root, overrides ?? []);
		final buf: StringBuf = new StringBuf();
		var emitted: Bool = false;
		var pendingSpace: Bool = false;
		inline function separate(): Void {
			if (pendingSpace && emitted) buf.addChar(' '.code);
			pendingSpace = false;
		}
		var next: Int = 0;
		var i: Int = from;
		while (i < to) {
			while (next < parts.length && parts[next].to <= i) next++;
			final part: Null<RenderPart> = next < parts.length ? parts[next] : null;
			if (part != null && part.from <= i) {
				final end: Int = part.to < to ? part.to : to;
				separate();
				buf.add(part.text ?? source.substring(i, end));
				emitted = true;
				i = end;
			} else {
				final c: Int = source.fastCodeAt(i);
				if (c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code) {
					pendingSpace = true;
				} else {
					separate();
					buf.addChar(c);
					emitted = true;
				}
				i++;
			}
		}
		return buf.toString();
	}

	/** Append the span of every LEAF in `node`'s subtree to `out` — the token interiors `renderSpan` copies verbatim. */
	private static function collectLeafSpans(node: QueryNode, out: Array<Span>): Void {
		if (node.children.length > 0) {
			for (child in node.children) collectLeafSpans(child, out);
			return;
		}
		final span: Null<Span> = node.span;
		if (span != null) out.push(span);
	}

	/**
	 * The spans `renderSpan` walks, in document order: every LEAF of `root` except one an override
	 * replaces whole, plus every override in place. A part with a null `text` is copied from the
	 * source; one carrying text is emitted instead of the bytes it covers.
	 */
	private static function renderParts(root: QueryNode, overrides: Array<SpanOverride>): Array<RenderPart> {
		final tokens: Array<Span> = [];
		collectLeafSpans(root, tokens);
		final parts: Array<RenderPart> = [
			for (token in tokens) if (!replaced(overrides, token)) { from: token.from, to: token.to, text: null }
		];
		for (hole in overrides) parts.push({ from: hole.span.from, to: hole.span.to, text: hole.text });
		parts.sort((a, b) -> a.from - b.from);
		return parts;
	}

	/** Whether an override covers `token` whole, in which case the token's own bytes are not emitted. */
	private static function replaced(overrides: Array<SpanOverride>, token: Span): Bool {
		return overrides.exists(hole -> hole.span.from <= token.from && token.to <= hole.span.to);
	}

}

/**
 * One stretch of a rendered span: the bytes `[from, to)` and, when non-null, the text emitted in
 * their place. A null `text` is a token whose interior is copied verbatim.
 */
typedef RenderPart = {
	var from: Int;
	var to: Int;
	var text: Null<String>;
}

/**
 * A stretch of source and the text `renderSpan` emits in its place — the caller's way of blanking
 * a name out of a comparison key without touching the bytes around it. Spans must not overlap.
 */
typedef SpanOverride = {
	var span: Span;
	var text: String;
}
