package anyparse.query;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.ImportOrder.ImportAnchor;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

using StringTools;

/**
 * Add an `import` (or `using`) statement to a module — a structural
 * INSERT operation built on the query engine.
 *
 * Given a dotted module path, the operation collects the existing
 * top-level `import` / `using` / `package` nodes, refuses a duplicate of
 * the same kind, splices the raw new statement on its own line (inside the
 * plain-import RUN it belongs to, in that run's own order — see
 * `ImportOrder`; else after the last import / using, else after `package`,
 * else at file start), and finalizes through `RefactorSupport.canonicalize` — so the result is
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
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err('source does not parse: $exception')
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		final trimmed: String = path.trim();
		if (trimmed.length == 0) return Err('add-import requires a non-empty module path');

		final targetKind: String = isUsing ? 'UsingDecl' : 'ImportDecl';
		for (c in tree.children) switch c.kind {
			case 'ImportDecl', 'UsingDecl', 'ImportWildDecl', 'ImportAliasDecl', 'ImportAliasInDecl':
				if (c.kind == targetKind && c.name == trimmed) return Err('already imported: $trimmed');
			case 'Conditional':
				if (guardedDuplicate(c.children, targetKind, trimmed))
					return Err('already imported inside a conditional-compilation (#if) block: $trimmed');
			case _:
		}

		final stmt: String = '${(isUsing ? 'using ' : 'import ') + trimmed};';

		// Placement is `ImportOrder`'s single answer for every inserting caller: the run slot the path
		// sorts into, else the header's own fallback ladder — read from the `#if` region when one
		// guards the module's whole body. A `using`, a wildcard or an aliased payload passes no path,
		// so it takes the ladder rather than a slot the plain-import ordering cannot see.
		final anchor: ImportAnchor = ImportOrder.insertionFor(source, tree, plugin, orderable(trimmed, isUsing) ? trimmed : null);
		// Exact whitespace is the writer's concern — the canonicalize finalize re-emits the whole file.
		final edit: { span: Span, text: String } = {
			span: new Span(anchor.offset, anchor.offset),
			text: '${anchor.lead}$stmt\n${anchor.trail}'
		};

		return CanonicalEdit.canonicalize(source, [edit], reformat, plugin, optsJson);
	}

	/**
	 * Whether the statement being added may take the ordered slot inside a plain-import RUN.
	 * Only a plain module path may: a `using`'s position ranks static-extension resolution, and a
	 * wildcard (`pkg.*`) or an aliased payload (`pkg.T as U`) binds names the plain-import
	 * ordering cannot see, so both keep the append that has always placed them.
	 */
	private static inline function orderable(path: String, isUsing: Bool): Bool {
		return !isUsing && path.indexOf('*') < 0 && path.indexOf(' ') < 0;
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
