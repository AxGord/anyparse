package anyparse.query;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.ImportSpelling.ImportSpelled;

/**
 * Remove an `import` / `using` statement by its module path — the by-name
 * convenience over the cursor-based `RemoveElement`, sister to `add-import`,
 * and the backend of `lint --fix` for the `unused-import` check. The path
 * matches the verbatim payload the grammar exposes for the statement:
 * `import pkg.Mod;` → `pkg.Mod`, `import pkg.Mod.Sub;` → `pkg.Mod.Sub`,
 * `using pkg.Mod;` → `pkg.Mod`, `import pkg.*;` → `pkg.*`, and for an
 * aliased import — either spelling, `import pkg.Mod as Alias;` or the
 * legacy `import pkg.Mod in Alias;` — it is the alias `Alias` (the
 * original path is not exposed — the documented grammar limitation). The
 * path must name EXACTLY ONE import — zero or many is an `Err` — and the
 * statement is removed through `RefactorSupport.deleteNode`, which takes a leading
 * `/**` doc block with it: a doc directly above one import is about THAT import, and
 * left behind it re-attaches to the next statement — the same silent orphan the member
 * remove used to leave. A PLAIN block comment is not taken, because the one that sits
 * above a module first import is normally its licence header. `withDoc = false`
 * (`--keep-doc`) suppresses the doc removal too.
 */
@:nullSafety(Strict)
final class RemoveImport {

	private static inline final USING_KIND: String = 'UsingDecl';

	/**
	 * Remove the import / using whose exposed path equals `modulePath`, with its leading `/**` doc
	 * block. `modulePath` may also be the whole statement (`import x.Y;` / `using x.Y;`, read by
	 * `ImportSpelling`), and then its keyword narrows the match to that kind: `using a.B;` names the
	 * `using` alone where a bare `a.B` beside an `import a.B;` is ambiguous. `reformat` opts into a
	 * whole-file canonicalisation when the source is not already writer-canonical; `withDoc = false`
	 * keeps the comment. Returns `Ok(rewritten)` or an `Err`.
	 */
	public static function removeImport(
		source: String, modulePath: String, reformat: Bool, plugin: GrammarPlugin, withDoc: Bool = true, ?optsJson: String
	): EditResult {
		final tree: QueryNode = switch ParseGate.parse(plugin, source, 'source') {
			case Unparsed(message): return Err(message);
			case Parsed(parsed): parsed;
		};

		final spelled: Null<ImportSpelled> = ImportSpelling.split(modulePath);
		if (spelled == null) return Err(ImportSpelling.notAPath(modulePath));
		final path: String = spelled.path;
		final kinds: Array<String> = kindsFor(spelled.keyword);
		final matches: Array<QueryNode> = tree.children.filter(n -> kinds.contains(n.kind) && n.name == path);
		return if (matches.length == 0)
			Err(absentMessage(tree, path, kinds, spelled.keyword))
		else if (matches.length > 1)
			Err('ambiguous — "$path" matches ${matches.length} import statements')
		else
			ElementSpan.deleteNode(source, matches[0], tree, reformat, plugin, withDoc, optsJson);
	}

	/**
	 * The statement kinds a request spelled with `keyword` may name: a `using` statement names a
	 * `using` only, an `import` statement every import spelling but a `using`, and a bare path any of
	 * them — the by-path lookup this op has always made.
	 */
	private static function kindsFor(keyword: Null<String>): Array<String> {
		return switch (keyword) {
			case null: ModuleScan.IMPORT_DECL_KINDS;
			case ImportSpelling.USING_WORD: [USING_KIND];
			case _: ModuleScan.IMPORT_DECL_KINDS.filter(kind -> kind != USING_KIND);
		};
	}

	/**
	 * The refusal for a path this op found no TOP-LEVEL statement for — split by whether the
	 * file holds one further down.
	 *
	 * A `#if`-guarded import is a child of the `Conditional` node, not of the module, so the
	 * top-level filter above cannot see it and the plain "no import found" was a true sentence
	 * that described the wrong world: the import is right there, one line below an `#if`. It
	 * sent the reader looking for a typo in the path.
	 *
	 * The op still declines to remove it, and that is a decision rather than a gap: deleting the
	 * only statement in a region leaves `#if sys` / `#end` standing around nothing, and whether
	 * the empty region should go with it depends on what else the condition is for. `remove-element`
	 * has no such opinion because the caller addressed one node deliberately, so the message hands
	 * the work to it by name — spelled with the keyword the caller asked for, when it asked for one.
	 */
	private static function absentMessage(tree: QueryNode, modulePath: String, kinds: Array<String>, keyword: Null<String>): String {
		final guarded: Int = guardedCount(tree, modulePath, kinds);
		final what: String = keyword ?? 'import';
		final hint: String = keyword == null
			? '`apq remove-element <file> --match \'import $modulePath;\' --write` (or `--match \'using $modulePath;\'`)'
			: '`apq remove-element <file> --match \'$keyword $modulePath;\' --write`';
		return guarded == 0
			? 'no $what of "$modulePath" found'
			: 'no TOP-LEVEL $what of "$modulePath" found, but $guarded inside a conditional-compilation region — this op removes an '
				+ 'unguarded statement only, because deleting the last one out of an `#if` leaves the region empty with its condition '
				+ 'standing and only the caller can say whether that region should go too. Remove it with $hint, then read the region back';
	}

	/** Statements of `kinds` naming `modulePath` anywhere BELOW the module's own children — that is, inside a conditional region. */
	private static function guardedCount(node: QueryNode, modulePath: String, kinds: Array<String>): Int {
		var found: Int = 0;
		for (child in node.children) {
			if (kinds.contains(child.kind) && child.name == modulePath) found++;
			found += guardedCount(child, modulePath, kinds);
		}
		return found;
	}

}
