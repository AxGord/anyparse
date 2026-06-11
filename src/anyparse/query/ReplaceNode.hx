package anyparse.query;

import anyparse.query.RefactorSupport.EditResult;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * How the node to replace is addressed. Modelled as a sum type so the
 * CLI passes one value and the operation resolves uniformly:
 *
 *  - `BySelector` reuses the `apq ast --select` resolver (kind /
 *    `Kind:name` / `A > B`); the selector MUST match exactly one node.
 *  - `ByPosition` reuses the `apq ast --at` resolver (innermost spanned
 *    node at the cursor), but interprets the column in the SAME
 *    convention `apq refs` prints — identical to `rename` / `add-param`,
 *    NOT the raw 1-indexed `ast --at` convention.
 */
enum ReplaceTarget {

	BySelector(selector: String);
	ByPosition(line: Int, col: Int);

}

/**
 * Replace the source span of a single AST node with new source text —
 * a structural REPLACE operation built on the query engine.
 *
 * Given a target (a `--select` selector OR a cursor position) and the
 * full source of a replacement, the operation resolves the target to
 * exactly one node, swaps its `[span.from, span.to)` range for the raw
 * replacement text, and finalizes through `RefactorSupport.canonicalize`
 * — so the replacement is WRITER-FORMATTED together with the whole file
 * (not spliced as-is) and re-parse-validated. The source is canonical-
 * gated unless `reformat` is set.
 *
 * The source is never mutated; the caller decides whether to write the
 * result.
 */
@:nullSafety(Strict)
final class ReplaceNode {

	/**
	 * Replace the node addressed by `target` in `source` with `newSource`.
	 * `reformat` opts into a whole-file canonicalisation when the source is
	 * not already writer-canonical. `plugin` is the caller-owned grammar
	 * plugin. Returns `Ok(rewritten)` or an `Err` describing why the node
	 * could not be replaced.
	 */
	public static function replaceNode(
		source: String, target: ReplaceTarget, newSource: String, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String
	): EditResult {
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err(
			'source does not parse: ${exception.toString()}'
		)
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		final node: QueryNode = switch target {
			case BySelector(selectorExpr):
				final selector: Selector = try Selector.parse(selectorExpr) catch (exception: Exception) return Err(
					'malformed selector "$selectorExpr": ${exception.message}'
				);
				final matches: Array<QueryNode> = Engine.select(tree, selector, plugin.selectKindEquivalence());
				if (matches.length == 0) return Err('--select "$selectorExpr" matched no nodes');
				if (matches.length > 1)
					return Err('--select "$selectorExpr" matched ${matches.length} nodes — ambiguous; narrow with Kind:name or A > B');
				matches[0];

			case ByPosition(line, col):
				// `apq refs` prints `Span.lineCol().col - 1`; invert that here
				// so a position copied from `refs` / `ast --select` output maps
				// back to the real offset (same convention as `Rename` /
				// `AddParam`, NOT the raw 1-indexed `ast --at`).
				final cursor: Int = Span.offsetOf(source, line, col + 1);
				final hit: Null<QueryNode> = Engine.at(tree, cursor);
				if (hit == null) return Err('position $line:$col is not on a node');
				hit;
		};

		final span: Null<Span> = node.span;
		if (span == null) return Err('the resolved ${node.kind} node has no source span to replace');

		// Fold a modifier-decorated declaration into one unit: `private static
		// function f` projects to `(Private)(Static)(FnMember)`, and a
		// `--select FnMember` / `--at` cursor resolves only the `function …`
		// node. Expand the replaced range to the whole `[@:meta modifiers…
		// decl]` group so the replacement is the full declaration as written
		// (modifiers included), not a fragment that would duplicate the
		// surviving modifier siblings. A non-decl node (expression, statement,
		// package) has no modifier run, so `declGroupSpan` returns it intact.
		final groupSpan: Span = RefactorSupport.declGroupSpan(node, RefactorSupport.parentOf(tree, node), span);
		final edit: { span: Span, text: String } = { span: groupSpan, text: newSource };
		return RefactorSupport.canonicalize(source, [edit], reformat, plugin, optsJson);
	}

}
