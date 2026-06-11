package anyparse.query;

import anyparse.query.RefactorSupport.EditResult;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Remove the sibling element a cursor points at — the GENERALIZED
 * list-delete op and the structural inverse of `AddElement`. It is the
 * missing DELETE verb of the mutation-op family, which had Create (the
 * `add-*` ops) and Update (`replace-node`) but no Delete. It removes a
 * statement from a block, a `case` from a switch, an element from a comma
 * list (array / object / call-arg / `new`-arg), or a class member —
 * whatever node the cursor's first token names.
 *
 * Targeting and finalize mirror `AddElement`: `line:col` points at the
 * FIRST TOKEN of the element to remove (the `apq refs` print-column
 * convention), and the whole file is re-emitted through the writer (which
 * fixes residual whitespace and re-parse-validates). The element node is
 * resolved with `RefactorSupport.nodeAtFrom` + `parentOf`; the deletion
 * span (modifier / meta group folded, one comma swallowed for comma lists)
 * and the writer finalize live in `RefactorSupport.deleteNode`, shared with
 * the by-name remove wrappers (`RemoveImport` / `RemoveMember`).
 */
@:nullSafety(Strict)
final class RemoveElement {

	/**
	 * Remove the element whose first token is at `line:col` in `source`.
	 * `reformat` opts into a whole-file canonicalisation when the source is
	 * not already writer-canonical. Returns `Ok(rewritten)` or an `Err`; the
	 * source is never mutated.
	 */
	public static function removeElement(
		source: String, line: Int, col: Int, reformat: Bool, plugin: GrammarPlugin, withDoc: Bool = false, ?optsJson: String
	): EditResult {
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err(
			'source does not parse: ${exception.toString()}'
		)
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		// `apq refs` prints `Span.lineCol().col - 1`; invert that here.
		final cursor: Int = Span.offsetOf(source, line, col + 1);

		final node: Null<QueryNode> = RefactorSupport.nodeAtFrom(tree, cursor);
		if (node == null)
			return
				Err(
					'position $line:$col is not on the first token of an element — point at the first token of a statement / case / list element / member'
				);

		final parent: Null<QueryNode> = RefactorSupport.parentOf(tree, node);
		return RefactorSupport.deleteNode(source, node, parent, reformat, plugin, withDoc, optsJson);
	}

}
