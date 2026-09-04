package anyparse.query;

import anyparse.query.CanonicalEdit.EditResult;
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
 * resolved with `RefactorSupport.elementAtFrom` + `parentOf`; the deletion
 * span (modifier / meta group and leading `/**` doc folded, one comma swallowed
 * for comma lists) and the writer finalize live in
 * `RefactorSupport.deleteNode`, shared with the by-name remove wrappers
 * (`RemoveImport` / `RemoveMember`).
 */
@:nullSafety(Strict)
final class RemoveElement {

	/**
	 * Remove the sibling element whose first token the cursor at `line:col` falls
	 * within — a statement, `case`, comma-list element, or member (folded with its
	 * leading modifier / `@:meta` group AND its leading `/**` doc block — a plain
	 * block comment above it is left alone). `reformat` opts into a whole-file
	 * canonicalisation when the source is not writer-canonical; `withDoc = false`
	 * keeps the doc. Returns `Ok(rewritten)` or an `Err`; the
	 * source is never mutated.
	 */
	public static function removeElement(
		source: String, line: Int, col: Int, reformat: Bool, plugin: GrammarPlugin, withDoc: Bool = true, ?optsJson: String
	): EditResult {
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err('source does not parse: $exception')
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		// line:col is 1-based, as apq refs / ast --at / source print.
		final cursor: Int = Span.offsetOf(source, line, col);

		final hit: Null<{ node: QueryNode, parent: Null<QueryNode> }> = RefactorSupport.elementAtFrom(tree, source, cursor);
		return hit == null
			? Err(
				'position $line:$col'
				+ ' is not on the first token of an element — point at the first token of a statement / case / list element / member'
			)
			: ElementSpan.deleteNode(source, hit.node, hit.parent, reformat, plugin, withDoc, optsJson);
	}

}
