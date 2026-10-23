package anyparse.grammar.mermaid;

import anyparse.query.QueryNode;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;

/**
 * The `mermaid` grammar's QUERY projection: a flowchart parsed by the span parser and walked onto
 * the engine's `QueryNode` tree by the generated walker (`MermaidQueryWalker`), under a synthetic
 * `Document` root holding the statements in source order.
 *
 * The vocabulary is the grammar's own ctor names (`Header`, `Subgraph`, `Chain`, `Rect`, `Arrow`,
 * `Id`, …) and it is the `--select` vocabulary. A node is named by its id (`Id:A`), a shape by its
 * decoded label (`Rect:Start`).
 */
@:nullSafety(Strict)
final class MermaidProjection {

	/** The synthetic root kind. */
	public static inline final DOCUMENT: String = 'Document';

	/** A `%%` comment statement. */
	public static inline final COMMENT: String = 'Comment';

	/** Parse `source` and project it. Throws the parser's `ParseError` on a document that does not parse. */
	public static function parse(source: String): QueryNode {
		final statements: Array<QueryNode> = MermaidQueryWalker.walk(source, false);
		if (statements.length > 0) statements[0] = tight(statements[0], source);
		return new QueryNode(DOCUMENT, null, statements);
	}

	/** `node`'s span; every projected node but the synthetic root carries one. */
	public static function spanOf(node: QueryNode): Span {
		final span: Null<Span> = node.span;
		if (span == null) throw new Exception('mermaid: a ${node.kind} node carries no span');
		return span;
	}

	/** The first statement with its span past the document's leading whitespace. */
	private static function tight(statement: QueryNode, source: String): QueryNode {
		final span: Span = spanOf(statement);
		var from: Int = span.from;
		while (from < span.to && source.isSpace(from)) from++;
		return from == span.from ? statement : new QueryNode(statement.kind, statement.name, statement.children, new Span(from, span.to));
	}

}
