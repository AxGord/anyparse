package anyparse.grammar.json;

import anyparse.query.QueryNode;
import anyparse.query.StringFold.ConcatSegment;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.StringLiteral;
import anyparse.runtime.Span;

/**
 * The `json` grammar's string-literal seam — what `add-element --sorted` reads to order the
 * entries of a JSON array of strings (`AddElement.insertSorted` asks `literalOf` for each
 * element's quote and raw content).
 *
 * JSON has ONE string spelling, the double-quoted literal, and no concatenation, interpolation
 * or conversion operand, so every question beyond `literalOf` answers "none": the fold check is
 * never pointed at a JSON document, and an op that asks gets the conservative answer.
 */
@:nullSafety(Strict)
final class JsonStringFold implements StringFoldSupport {

	/** The one quote a JSON string is written in. */
	private static inline final QUOTE: String = '"';

	public function new() {}

	/** JSON has no concatenation operator; no projected kind is this one. */
	public function concatKind(): String {
		return '';
	}

	/** A `String` node's quote and raw content — escapes as written, the quotes off. */
	public function literalOf(node: QueryNode, source: String): Null<StringLiteral> {
		final span: Null<Span> = node.span;
		return node.kind != JsonProjection.STRING || span == null
			? null
			: { quote: QUOTE, content: source.substring(span.from + 1, span.to - 1) };
	}

	public function requoteVerbatim(literal: StringLiteral, quote: String): Null<String> {
		return quote == QUOTE ? QUOTE + literal.content + QUOTE : null;
	}

	public function segmentsOf(node: QueryNode, source: String): Null<Array<ConcatSegment>> {
		return null;
	}

	public function expressionSegment(node: QueryNode, source: String): Null<ConcatSegment> {
		return null;
	}

	public function constantText(node: QueryNode, source: String): Null<String> {
		return null;
	}

	public function renderGroup(segments: Array<ConcatSegment>): Null<String> {
		return null;
	}

	public function renderBare(segment: ConcatSegment): Null<String> {
		return null;
	}

	public function readsArgumentsAsSyntax(name: String): Bool {
		return false;
	}

}
