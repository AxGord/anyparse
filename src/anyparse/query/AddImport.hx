package anyparse.query;

import anyparse.query.RefactorSupport.EditResult;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Add an `import` (or `using`) statement to a module — a structural
 * INSERT operation built on the query engine.
 *
 * Given a dotted module path, the operation collects the existing
 * top-level `import` / `using` / `package` nodes, refuses a duplicate of
 * the same kind, splices the raw new statement on its own line (after the
 * last import / using, else after `package`, else at file start), and
 * finalizes through `RefactorSupport.canonicalize` — so the result is
 * WRITER-FORMATTED and re-parse-validated, the source canonical-gated
 * unless `reformat` is set.
 *
 * The source is never mutated; the caller decides whether to write the
 * result.
 */
@:nullSafety(Strict)
final class AddImport {

	/**
	 * Add `import <path>;` (or `using <path>;` when `isUsing`) to `source`.
	 * `reformat` opts into a whole-file canonicalisation when the source is
	 * not already writer-canonical. Returns `Ok(rewritten)` or an `Err`
	 * describing why the import could not be added.
	 */
	public static function addImport(
		source: String, path: String, isUsing: Bool, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String
	): EditResult {
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err(
			'source does not parse: ${exception.toString()}'
		)
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		final trimmed: String = StringTools.trim(path);
		if (trimmed.length == 0) return Err('add-import requires a non-empty module path');

		final targetKind: String = isUsing ? 'UsingDecl' : 'ImportDecl';
		var lastImport: Null<QueryNode> = null;
		var packageDecl: Null<QueryNode> = null;
		for (c in tree.children) switch c.kind {
			case 'ImportDecl', 'UsingDecl', 'ImportWildDecl', 'ImportAliasDecl':
				lastImport = c;
				if (c.kind == targetKind && c.name == trimmed) return Err('already imported: $trimmed');
			case 'PackageDecl':
				packageDecl = c;
			case 'Conditional':
				if (guardedDuplicate(c.children, targetKind, trimmed))
					return Err('already imported inside a conditional-compilation (#if) block: $trimmed');
			case _:
		}

		final stmt: String = '${(isUsing ? 'using ' : 'import ') + trimmed};';

		// Insertion site, in priority order: after the last existing
		// import / using (extend the block), else after the package
		// declaration, else at the very start of the file. Exact
		// whitespace is the writer's concern — the canonicalize finalize
		// re-emits the whole file.
		final lastImportTo: Int = spanTo(lastImport);
		final packageTo: Int = spanTo(packageDecl);
		final edit: { span: Span, text: String } = if (lastImportTo >= 0)
			{ span: new Span(lastImportTo, lastImportTo), text: '\n$stmt' };
		else if (packageTo >= 0)
			{ span: new Span(packageTo, packageTo), text: '\n$stmt' };
		else
			{ span: new Span(0, 0), text: '$stmt\n' };

		return RefactorSupport.canonicalize(source, [edit], reformat, plugin, optsJson);
	}

	/** `node`'s span end, or -1 when the node or its span is null. */
	private static inline function spanTo(node: Null<QueryNode>): Int {
		if (node == null) return -1;
		final s: Null<Span> = node.span;
		return s == null ? -1 : s.to;
	}

	/**
	 * Whether `nodes` (a `#if … #end` `Conditional`'s children — its
	 * `body` / `elseifs` / `elseBody` decls, flattened by the query
	 * plugin) already contain an `import` / `using` of `path` matching
	 * `targetKind`. The top-level scan in `addImport` sees only the
	 * single `Conditional` wrapper, not the guarded declarations inside
	 * it, so a duplicate that exists ONLY behind an `#if` would
	 * otherwise go undetected and a second, unguarded copy would be
	 * spliced in. Recurses through nested `Conditional`s so a chained
	 * or nested `#if` is covered too.
	 */
	private static function guardedDuplicate(nodes: Array<QueryNode>, targetKind: String, path: String): Bool {
		for (n in nodes) {
			if (n.kind == targetKind && n.name == path) return true;
			if (n.kind == 'Conditional' && guardedDuplicate(n.children, targetKind, path)) return true;
		}
		return false;
	}

}
