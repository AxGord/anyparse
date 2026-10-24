package anyparse.query;

import anyparse.check.scan.UsingScan;
import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.ImportOrder.ImportAnchor;
import anyparse.query.ImportSpelling.ImportSpelled;
import anyparse.runtime.Span;

/**
 * Add an `import` (or `using`) statement to a module — a structural
 * INSERT operation built on the query engine.
 *
 * Given a dotted module path — or the whole `import x.Y;` / `using x.Y;`
 * statement, read by `ImportSpelling` — the operation collects the existing
 * top-level `import` / `using` / `package` nodes, refuses a duplicate of
 * the same kind (one behind an `#if` included), splices the raw new statement
 * on its own line, and finalizes through `RefactorSupport.canonicalize` — so the result is
 * WRITER-FORMATTED and re-parse-validated, the source canonical-gated
 * unless `reformat` is set.
 *
 * An import lands inside the plain-import RUN it belongs to, in that run's own
 * order (see `ImportOrder`), else on the header's fallback ladder. A `using`
 * lands ABOVE the header's first `using` (`UsingScan.usingInsertEdit`, the seat
 * every `using`-inserting rule takes), else after the last package / import:
 * Haxe ranks static extensions in REVERSE declaration order, so the fresh one
 * takes the lowest priority and no extension call already in the file moves.
 *
 * The source is never mutated; the caller decides whether to write the
 * result.
 */
@:nullSafety(Strict)
final class AddImport {

	/**
	 * Add `import <path>;` (or `using <path>;` when `isUsing`) to `source`. `path` may also be the
	 * whole statement — `import x.Y;` / `using x.Y;`, read by `ImportSpelling` — whose keyword then
	 * decides the kind; an `import` statement under `isUsing` contradicts itself and is refused.
	 * `reformat` opts into a whole-file canonicalisation when the source is not already
	 * writer-canonical. Returns `Ok(rewritten)` or an `Err` describing why the import could not be
	 * added.
	 */
	public static function addImport(
		source: String, path: String, isUsing: Bool, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String
	): EditResult {
		final tree: QueryNode = switch ParseGate.parse(plugin, source, 'source') {
			case Unparsed(message): return Err(message);
			case Parsed(parsed): parsed;
		};

		final spelled: Null<ImportSpelled> = ImportSpelling.split(path, isUsing);
		if (spelled == null) return Err(ImportSpelling.flagConflict(path));
		final trimmed: String = spelled.path;
		if (trimmed.length == 0) return Err('add-import requires a non-empty module path');
		if (!ImportSpelling.isModulePath(trimmed)) return Err(ImportSpelling.notAPath(path));
		final asUsing: Bool = spelled.keyword == ImportSpelling.USING_WORD;

		final targetKind: String = asUsing ? 'UsingDecl' : 'ImportDecl';
		for (c in tree.children) switch c.kind {
			case 'ImportDecl', 'UsingDecl', 'ImportWildDecl', 'ImportAliasDecl', 'ImportAliasInDecl':
				if (c.kind == targetKind && c.name == trimmed) return Err('already imported: $trimmed');
			case 'Conditional':
				if (guardedDuplicate(c.children, targetKind, trimmed))
					return Err('already imported inside a conditional-compilation (#if) block: $trimmed');
			case _:
		}

		// A `using` takes the seat every `using`-inserting rule takes: ABOVE the header's first `using`,
		// the lowest static-extension priority, since Haxe ranks them in REVERSE declaration order and an
		// insert below the group would re-target every same-named extension call the file already makes.
		final edit: { span: Span, text: String } = asUsing
			? UsingScan.usingInsertEdit(UsingScan.headerOf(tree, source, plugin), trimmed)
			: importEdit(source, tree, plugin, trimmed);
		return CanonicalEdit.canonicalize(source, [edit], reformat, plugin, optsJson);
	}

	/**
	 * Whether the import being added may take the ordered slot inside a plain-import RUN. Only a plain
	 * module path may: a wildcard (`pkg.*`) or an aliased payload (`pkg.T as U`) binds names the
	 * plain-import ordering cannot see, so both keep the append that has always placed them.
	 */
	private static inline function orderable(path: String): Bool {
		return path.indexOf('*') < 0 && path.indexOf(' ') < 0;
	}

	/**
	 * The zero-width insert of `import <path>;`. Placement is `ImportOrder`'s single answer for every
	 * inserting caller: the run slot the path sorts into, else the header's own fallback ladder — read
	 * from the `#if` region when one guards the module's whole body. A wildcard or an aliased payload
	 * passes no path, so it takes the ladder rather than a slot the plain-import ordering cannot see.
	 * Exact whitespace is the writer's concern — the canonicalize finalize re-emits the whole file.
	 */
	private static function importEdit(source: String, tree: QueryNode, plugin: GrammarPlugin, path: String): { span: Span, text: String } {
		final anchor: ImportAnchor = ImportOrder.insertionFor(source, tree, plugin, orderable(path) ? path : null);
		return {
			span: new Span(anchor.offset, anchor.offset),
			text: '${anchor.lead}${ImportSpelling.IMPORT_WORD} $path;\n${anchor.trail}'
		};
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
