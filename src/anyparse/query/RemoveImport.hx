package anyparse.query;

import anyparse.query.RefactorSupport.EditResult;
import anyparse.runtime.ParseError;
import haxe.Exception;

using Lambda;

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
 * statement is removed through `RefactorSupport.deleteNode`.
 */
@:nullSafety(Strict)
final class RemoveImport {

	private static final IMPORT_KINDS: Array<String> = [
		'ImportDecl',
		'ImportAliasDecl',
		'ImportAliasInDecl',
		'ImportWildDecl',
		'UsingDecl'
	];

	/**
	 * Remove the import / using whose exposed path equals `modulePath`.
	 * `reformat` opts into a whole-file canonicalisation when the source is
	 * not already writer-canonical. Returns `Ok(rewritten)` or an `Err`.
	 */
	public static function removeImport(
		source: String, modulePath: String, reformat: Bool, plugin: GrammarPlugin, ?optsJson: String
	): EditResult {
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return Err(
			'source does not parse: ${exception.toString()}'
		)
		catch (exception: Exception) return Err('source does not parse: ${exception.message}');

		final matches: Array<QueryNode> = tree.children.filter(n -> IMPORT_KINDS.contains(n.kind) && n.name == modulePath);
		return matches.length == 0
			? Err('no import of "$modulePath" found')
			: matches.length > 1
				? Err('ambiguous — "$modulePath" matches ${matches.length} import statements')
				: RefactorSupport.deleteNode(source, matches[0], tree, reformat, plugin, optsJson);
	}

}
