package anyparse.query;

import anyparse.query.RefactorSupport.EditResult;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Add or replace the doc-comment of the declaration at a cursor — the
 * member-doc counterpart of the writer-emit ops. `replace-node --with-doc`
 * rewrites a declaration AND its doc together (the whole declaration has to be
 * retyped); this edits ONLY the doc region, leaving the declaration untouched.
 *
 * The doc region is `[docExtendedSpan.from, declGroupSpan.from)`: the leading
 * block comment if one exists (replaced), else empty (the new doc is inserted
 * before the declaration). `text` is formatted into a doc-comment block by
 * `RefactorSupport.docComment` and the whole file is re-emitted +
 * re-parse-validated via `RefactorSupport.canonicalize` (canonical-gated unless
 * `reformat`) — so the spliced comment is re-indented and attached to the
 * declaration by the writer's own trivia rules.
 *
 * The source is never mutated; the caller decides whether to write the result.
 */
@:nullSafety(Strict)
final class SetDoc {

	/**
	 * Set the doc-comment of the node at `line:col` (the `apq refs` column
	 * convention) to `docText`. Returns `Ok(rewritten)` or an `Err` describing
	 * why the doc could not be set.
	 */
	public static function setDoc(
		source: String, line: Int, col: Int, docText: String, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String
	): EditResult {
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err(
			'source does not parse: ${exception.toString()}'
		)
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		final cursor: Int = Span.offsetOf(source, line, col + 1);
		final node: Null<QueryNode> = Engine.at(tree, cursor);
		if (node == null) return Err('position $line:$col is not on a node');
		final span: Null<Span> = node.span;
		if (span == null) return Err('the resolved ${node.kind} node has no source span');

		// Fold modifiers / `@:meta` into the declaration unit, then extend back
		// over any existing leading doc — the region between is exactly the
		// declaration's documentation slot (empty when it has none → insert).
		final groupSpan: Span = RefactorSupport.declGroupSpan(node, RefactorSupport.parentOf(tree, node), span);
		final docExtended: Span = RefactorSupport.docExtendedSpan(source, groupSpan);
		final docRegion: Span = new Span(docExtended.from, groupSpan.from);
		final edit: { span: Span, text: String } = { span: docRegion, text: '${RefactorSupport.docComment(docText)}\n' };
		return RefactorSupport.canonicalize(source, [edit], reformat, plugin, optsJson);
	}

}
