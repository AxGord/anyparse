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
	ByKindPosition(line: Int, col: Int, kind: String);

	/**
	 * A pre-resolved node — the CLI's shared address layer (`Address.resolve`)
	 * already picked it. The node MUST come from `plugin.parseFile(source)` of
	 * the SAME (caching) plugin instance the op receives, so the internal
	 * re-parse returns the identical tree and `RefactorSupport.parentOf`
	 * recognises the node by reference.
	 */
	ByNode(node: QueryNode);

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
		source: String, target: ReplaceTarget, newSource: String, reformat: Bool, plugin: GrammarPlugin, withDoc: Bool = false,
		?optsJson: String
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

			case ByNode(n):
				// Pre-resolved by the CLI's shared address layer (`Address`); the
				// caching plugin guarantees `n` belongs to the tree parsed above.
				n;

			case ByPosition(line, col):
				// line:col is 1-based, as apq refs / ast --at / source print.
				final cursor: Int = Span.offsetOf(source, line, col);
				final hit: Null<QueryNode> = Engine.at(tree, cursor);
				if (hit == null) return Err('position $line:$col is not on a node');
				hit;

			case ByKindPosition(line, col, kind):
				// `--at <l>:<c> --kind <Kind>`: the innermost node of `kind`
				// containing the cursor — reaches a co-starting wrapper / operator
				// node that plain `--at` (innermost overall) skips past to a child.
				final cursor: Int = Span.offsetOf(source, line, col);
				final hit: Null<QueryNode> = Engine.atKind(tree, cursor, kind, plugin.selectKindEquivalence());
				if (hit == null) return Err('position $line:$col is not on a "$kind" node');
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
		// `--with-doc` extends the replaced range back over the leading doc / block
		// comment run (trivia the grammar keeps outside the node span) so the new
		// source carries the declaration documentation. The same extension applies
		// when `newSource` itself opens with a block comment — replacing only the
		// declaration would otherwise stack the new doc above the surviving old one,
		// so the existing leading doc is absorbed rather than duplicated.
		final carriesDoc: Bool = withDoc || startsWithBlockComment(newSource);
		final finalSpan: Span = carriesDoc ? RefactorSupport.docExtendedSpan(source, groupSpan) : groupSpan;
		final edit: { span: Span, text: String } = { span: finalSpan, text: newSource };
		return RefactorSupport.canonicalize(source, [edit], reformat, plugin, optsJson);
	}

	/** Whether `source`, ignoring leading whitespace, opens with a block comment (`/*`, including the `/**` doc form). */
	private static function startsWithBlockComment(source: String): Bool {
		return StringTools.startsWith(StringTools.ltrim(source), '/*');
	}

}
