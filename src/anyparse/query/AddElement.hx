package anyparse.query;

import anyparse.query.RefactorSupport.EditResult;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Which side of the cursor's element the new element is inserted on.
 * Modelled as a sum type so the CLI passes one value and the operation
 * branches uniformly.
 */
enum InsertSide {

	After;
	Before;

}

/**
 * Insert a sibling element next to an existing one — the GENERALIZED
 * list-insert mutation op, and the writer-emit primitive the per-kind
 * insert ops (`AddMember`, `AddImport`, the future `add-param` engine)
 * are special cases of. It fills the gap those ops left: there was no way
 * to insert a STATEMENT into a `{ }` block, a `case` into a `switch`, or
 * an element into a comma list — only whole-node `replace-node` (a full
 * rewrite, not an insert) covered them.
 *
 * The model is the same writer-emit substrate as the insert layer
 * (`RefactorSupport.canonicalize`): there is NO fragment-parse. The
 * operation only computes WHERE to splice the raw element text and WHICH
 * separator the slot needs; the whole-file re-emit BOTH formats the
 * inserted element and re-parse-validates it (a malformed element makes
 * the re-parse fail → `Err`). The source is canonical-gated unless
 * `reformat` is set, exactly like `AddMember`.
 *
 * ## Targeting
 *
 * `line:col` points at the FIRST TOKEN of an EXISTING sibling element —
 * the node whose `span.from` equals the cursor (the outermost such node,
 * i.e. the first in pre-order: the list element itself, not a sub-node of
 * it). `--after` / `--before` then inserts the new element on that side.
 * To append, point at the last sibling with `--after`; to prepend, point
 * at the first with `--before`. (`apq refs` print-column convention,
 * identical to `extract-var` / `extract-method`'s START.)
 *
 * ## Separator — the only per-slot knowledge
 *
 * Statement / `case` lists are SELF-TERMINATED (each statement ends with
 * `;` / `}`; each `case` is delimited by the next `case`), so the element
 * is spliced with a leading / trailing newline and no separator token.
 * COMMA lists (array / object / call-args / `new`-args) need an explicit
 * `,`. The slot is a comma list when the cursor element's parent is a
 * known comma container OR the element is already adjacent to a `,` in the
 * source (the latter catches comma containers not in the enumerated set,
 * for any multi-element list). A single-element list of an unenumerated
 * comma kind can't be told from a block and falls back to the newline
 * form — the re-parse gate then refuses it rather than corrupt the file.
 *
 * The op is deliberately CONTAINER-AGNOSTIC beyond the separator: it does
 * not validate that the supplied text is a valid element for the slot —
 * the whole-file re-parse is that gate — so it works for any list-shaped
 * slot, including ones not foreseen here.
 */
@:nullSafety(Strict)
final class AddElement {

	/**
	 * Expression-list container kinds whose direct children are
	 * comma-separated. When the cursor element's parent is one of these,
	 * the new element is joined with a `,` even for a single-element list
	 * (where the source-adjacency check alone could not tell a one-element
	 * list from a block). `Call` / `NewExpr` carry a leading non-element
	 * child (the callee / the constructed type) — harmless here because the
	 * cursor element is an actual argument, never the callee.
	 */
	private static final COMMA_CONTAINER_KINDS: Array<String> = ['ArrayExpr', 'ObjectLit', 'Call', 'NewExpr'];

	/**
	 * Insert `code` as a new sibling element on `side` of the element whose
	 * first token is at `line:col` in `source`. `reformat` opts into a
	 * whole-file canonicalisation when the source is not already
	 * writer-canonical. `plugin` is the caller-owned grammar plugin;
	 * `optsJson` the project writer config. Returns `Ok(rewritten)` or an
	 * `Err`. The source is never mutated.
	 */
	public static function addElement(
		source: String, line: Int, col: Int, side: InsertSide, code: String, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String
	): EditResult {
		final trimmed: String = StringTools.trim(code);
		if (trimmed.length == 0) return Err('add-element requires a non-empty element text');

		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err(
			'source does not parse: ${exception.toString()}'
		)
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		// `apq refs` prints `Span.lineCol().col - 1`; invert that here.
		final cursor: Int = Span.offsetOf(source, line, col + 1);

		final hit: Null<{ node: QueryNode, parent: Null<QueryNode> }> = findElementAt(tree, cursor);
		if (hit == null)
			return
				Err(
					'position $line:$col is not on the first token of an element — point at the first token of an existing statement / case / list element'
				);
		final element: QueryNode = hit.node;
		final elemSpan: Null<Span> = element.span;
		if (elemSpan == null) return Err('the element at $line:$col has no source span');
		final span: Span = elemSpan;

		final parent: Null<QueryNode> = hit.parent;
		var isComma: Bool = adjacentToComma(source, span);
		if (!isComma && parent != null) isComma = COMMA_CONTAINER_KINDS.contains(parent.kind);

		final edit: { span: Span, text: String } = switch side {
			case After:
				{ span: new Span(span.to, span.to), text: isComma ? ', ' + trimmed : '\n' + trimmed };
			case Before:
				{ span: new Span(span.from, span.from), text: isComma ? trimmed + ', ' : trimmed + '\n' };
		};

		return RefactorSupport.canonicalize(source, [edit], reformat, plugin, optsJson);
	}

	/**
	 * The outermost node whose `span.from == cursor` (the FIRST in
	 * pre-order, since a container always starts before its element — a
	 * block at `{`, a call at its callee, a switch at `switch`), together
	 * with its parent node. This is the list element the cursor's first
	 * token identifies. Null when no node starts exactly at `cursor`.
	 */
	private static function findElementAt(tree: QueryNode, cursor: Int): Null<{ node: QueryNode, parent: Null<QueryNode> }> {
		var result: Null<{ node: QueryNode, parent: Null<QueryNode> }> = null;
		function walk(node: QueryNode, parent: Null<QueryNode>): Void {
			if (result != null) return;
			final sp: Null<Span> = node.span;
			if (sp != null && sp.from == cursor) {
				result = { node: node, parent: parent };
				return;
			}
			for (c in node.children) {
				if (result != null) return;
				walk(c, node);
			}
		}
		walk(tree, null);
		return result;
	}

	/**
	 * Is the element at `span` immediately adjacent to a `,` — the next
	 * non-whitespace byte after `span.to`, or the previous non-whitespace
	 * byte before `span.from`, is a comma? True ⇒ the element sits in a
	 * comma-separated list (covers a comma container not in
	 * `COMMA_CONTAINER_KINDS`, for any list with at least two elements).
	 */
	private static function adjacentToComma(source: String, span: Span): Bool {
		var i: Int = span.to;
		while (i < source.length && isSpace(StringTools.fastCodeAt(source, i))) i++;
		if (i < source.length && StringTools.fastCodeAt(source, i) == ','.code) return true;

		var j: Int = span.from - 1;
		while (j >= 0 && isSpace(StringTools.fastCodeAt(source, j))) j--;
		if (j >= 0 && StringTools.fastCodeAt(source, j) == ','.code) return true;

		return false;
	}

	private static inline function isSpace(c: Int): Bool {
		return c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code;
	}

}
