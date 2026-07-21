package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;
import anyparse.query.TypeInfoProvider;

/**
 * Flags a `catch` clause whose declared exception type is `Dynamic` (or `Any`) — a raw
 * catch-all. The user's rule: use `catch (exception:Exception)`, NOT `catch (e:Dynamic)`.
 * An `Exception` handler binds a wrapper object with a richer, uniform API; a `Dynamic`
 * handler binds the raw thrown value with none. `Severity.Warning`.
 *
 * ## Autofix — only when the caught value is unused
 *
 * `fix` swaps `Dynamic` / `Any` to `Exception` ONLY when the caught variable is never
 * mentioned in the catch body — an unused catch-all swaps with zero behaviour change (Haxe 4.1
 * unified exceptions), adding `import haxe.Exception;` when the name is free (fully-qualified
 * `haxe.Exception` on a name collision). A body that READS the raw value (a different API from
 * the `Exception` wrapper's) stays a finding — that needs a manual `.unwrap` migration.
 *
 * ## What is flagged
 *
 * A `catchClauseKind` whose declared type (read from the clause header source, between the
 * first `:` and the closing `)`) resolves to a `catchAllTypeNames` name (`Dynamic` / `Any`).
 * A typed catch of any other name (`Exception`, a custom class, `String`, …) and an untyped
 * `catch (e)` — which the grammar records with no type text — are left alone.
 */
@:nullSafety(Strict)
final class CatchDynamic implements Check {

	public function new() {}

	public function id(): String {
		return 'catch-dynamic';
	}

	public function description(): String {
		return 'a catch clause whose declared type is Dynamic or Any — prefer catch (exception:Exception)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams = readKinds(plugin);
		if (seams == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(violations, entry.file, entry.source, tree, seams.kind, seams.catchAll);
		}
		return violations;
	}

	/** Swaps an unused `Dynamic`/`Any` catch-all to `Exception` (adding the import); a body that references the caught value stays a finding. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams = readKinds(plugin);
		if (seams == null) return [];
		final kind: String = seams.kind;
		final catchAll: Array<String> = seams.catchAll;
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final root: QueryNode = tree;
		final flagged: Map<String, Bool> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) flagged['${span.from}:${span.to}'] = true;
		}
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		final importMap: Map<String, String> = provider != null ? provider.importMap(source) : [];
		final ex = resolveExceptionType(root, importMap);
		final edits: Array<{ span: Span, text: String }> = [];
		var rewrote: Bool = false;
		function walk(node: QueryNode): Void {
			if (node.kind == kind) {
				final edit: Null<{ span: Span, text: String }> = swapEdit(node, source, catchAll, ex.text, flagged);
				if (edit != null) {
					edits.push(edit);
					rewrote = true;
				}
			}
			for (c in node.children) walk(c);
		}
		walk(root);
		if (rewrote && ex.needImport) edits.push(importInsertEdit(root));
		return edits;
	}

	/** Walk `node`, flagging every catch clause whose declared type is a catch-all name. */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, catchKind: String, catchAll: Array<String>
	): Void {
		if (node.kind == catchKind) flagCatch(out, file, source, node, catchAll);
		for (c in node.children) walk(out, file, source, c, catchKind, catchAll);
	}

	/**
	 * Append a `Warning` when `catchNode`'s declared exception type is a catch-all name.
	 * The `(var:Type)` parameter region is decoded by `catchParamRegion`, so an untyped
	 * `catch (e)` (no `:`) and a non-nominal type (a function type / generics) are skipped.
	 * The violation span covers only the parameter region, not the handler body.
	 */
	private static function flagCatch(
		out: Array<Violation>, file: String, source: String, catchNode: QueryNode, catchAll: Array<String>
	): Void {
		final p = catchParamRegion(catchNode, source);
		if (p == null || !catchAll.contains(p.typeName)) return;
		out.push({
			file: file,
			span: new Span(p.from, p.to),
			rule: 'catch-dynamic',
			severity: Severity.Warning,
			message: 'catch type \'${p.typeName}\' is a raw catch-all — prefer catch (exception:Exception)'
		});
	}


	/**
	 * The `(var:Type)` parameter region of a catch clause, decoded from the header
	 * source `[span.from, body.from)`: its `from:to` span, the bound variable name, the
	 * simple nominal type name, and the body node. Null when the clause is untyped (no
	 * `:`) or its type is non-nominal (a function type / generics reduce the name to null).
	 * Shared by `run`'s `flagCatch` and `fix`'s `swapEdit` so both decode identically.
	 */
	private static function catchParamRegion(catchNode: QueryNode, source: String): Null<{
		from: Int,
		to: Int,
		varName: String,
		typeName: String,
		body: QueryNode
	}> {
		final cs: Null<Span> = catchNode.span;
		final kids: Array<QueryNode> = catchNode.children;
		if (cs == null || kids.length == 0) return null;
		final bodyNode: QueryNode = kids[kids.length - 1];
		final body: Null<Span> = bodyNode.span;
		if (body == null) return null;
		final start: Int = cs.from;
		final header: String = source.substring(start, body.from);
		final open: Int = header.indexOf('(');
		final colon: Int = header.indexOf(':');
		final close: Int = header.lastIndexOf(')');
		if (open == -1 || colon == -1 || close == -1 || close <= colon) return null;
		final typeName: Null<String> = TypeResolver.simpleNominalName(header.substring(colon + 1, close));
		return typeName == null ? null : {
			from: start + open,
			to: start + close + 1,
			varName: StringTools.trim(header.substring(open + 1, colon)),
			typeName: typeName,
			body: bodyNode
		};
	}

	/**
	 * The `(var:Exception)` rewrite for a flagged catch clause, or null when it must stay
	 * a finding. Fires only when the clause was flagged (its region span is in `flagged`),
	 * its type is a catch-all name, and the bound variable is never mentioned in the body —
	 * an unused catch-all swaps to `Exception` with zero behaviour change (Haxe 4.1 unified
	 * exceptions), while a body that reads the raw value needs a manual `.unwrap` migration.
	 */
	private static function swapEdit(
		catchNode: QueryNode, source: String, catchAll: Array<String>, exText: String, flagged: Map<String, Bool>
	): Null<{ span: Span, text: String }> {
		final p = catchParamRegion(catchNode, source);
		if (p == null || !catchAll.contains(p.typeName)) return null;
		final unfixable: Bool = !flagged.exists('${p.from}:${p.to}') || p.varName.length == 0 || mentionsName(p.body, p.varName);
		return unfixable ? null : { span: new Span(p.from, p.to), text: '(${p.varName}:$exText)' };
	}

	/** Whether any node in `node`'s subtree carries `name` — catches plain identifiers, field-access names, and string-interpolation idents alike (a conservative reference test). */
	private static function mentionsName(node: QueryNode, name: String): Bool {
		if (node.name == name) return true;
		for (c in node.children) if (mentionsName(c, name)) return true;
		return false;
	}

	/**
	 * How to spell `Exception` in the rewrite, and whether an import must be added. Uses
	 * the short `Exception` + `import haxe.Exception;` when the name is free; falls back to
	 * fully-qualified `haxe.Exception` (no import) when the simple name is already bound to a
	 * different import or a local type — so the swap never silently retargets a wrong type.
	 */
	private static function resolveExceptionType(root: QueryNode, importMap: Map<String, String>): { text: String, needImport: Bool } {
		final resolved: Null<String> = importMap['Exception'];
		return resolved == 'haxe.Exception'
			? {
				text: 'Exception',
				needImport: false
			}
			: resolved != null || hasLocalType(root, 'Exception') ? { text: 'haxe.Exception', needImport: false } : {
				text: 'Exception',
				needImport: true
			};
	}

	/**
	 * Whether a top-level declaration binds the simple name `name` — a same-file type, or an
	 * `import`/`using`/alias whose bound simple name (last dotted segment) is `name`. Such a
	 * binding would shadow a bare `Exception`, so the swap must qualify instead of importing.
	 */
	private static function hasLocalType(root: QueryNode, name: String): Bool {
		for (c in root.children) {
			final n: Null<String> = c.name;
			if (n != null && StringTools.endsWith(c.kind, 'Decl') && lastSegment(n) == name) return true;
		}
		return false;
	}

	/** The last dotted segment of `dotted` (`baz.Exception` -> `Exception`), or the whole string when unqualified. */
	private static inline function lastSegment(dotted: String): String {
		final dot: Int = dotted.lastIndexOf('.');
		return dot == -1 ? dotted : dotted.substring(dot + 1);
	}

	/** The edit inserting `import haxe.Exception;` — after the last import / using, else after `package`, else at file start (mirrors `AddImport`). */
	private static function importInsertEdit(root: QueryNode): { span: Span, text: String } {
		var lastImport: Null<QueryNode> = null;
		var packageDecl: Null<QueryNode> = null;
		for (c in root.children) switch c.kind {
			case 'ImportDecl', 'UsingDecl', 'ImportWildDecl', 'ImportAliasDecl', 'ImportAliasInDecl':
				lastImport = c;
			case 'PackageDecl':
				packageDecl = c;
			case _:
		}
		final stmt: String = 'import haxe.Exception;';
		final anchor: Null<QueryNode> = lastImport ?? packageDecl;
		final aspan: Null<Span> = anchor?.span;
		return aspan == null ? { span: new Span(0, 0), text: '$stmt\n' } : { span: new Span(aspan.to, aspan.to), text: '\n$stmt' };
	}


	/** The catch-clause kind and catch-all type names, or null when the grammar sets neither (the check is then a no-op). */
	private static function readKinds(plugin: GrammarPlugin): Null<{ kind: String, catchAll: Array<String> }> {
		final shape: RefShape = plugin.refShape();
		final catchKind: Null<String> = shape.catchClauseKind;
		if (catchKind == null) return null;
		final catchAll: Array<String> = shape.catchAllTypeNames ?? [];
		return catchAll.length == 0 ? null : { kind: catchKind, catchAll: catchAll };
	}

}
