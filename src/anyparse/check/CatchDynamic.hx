package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeResolver;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags a `catch` clause whose declared exception type is `Dynamic` (or `Any`) — a raw
 * catch-all. The user's rule: use `catch (exception:Exception)`, NOT `catch (e:Dynamic)`.
 * An `Exception` handler binds a wrapper object with a richer, uniform API; a `Dynamic`
 * handler binds the raw thrown value with none. `Severity.Warning`.
 *
 * ## Report-only — no autofix
 *
 * `fix` yields no edits. `catch (e:Dynamic)` binds the RAW thrown value, whereas
 * `catch (e:Exception)` binds an `Exception` WRAPPER with a different API — swapping the
 * type automatically would silently change what the handler body operates on (a body that
 * inspects the raw value, rethrows it, or pattern-matches on it would break). Rewriting a
 * catch-all is a human decision, so the check only reports.
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
		final shape: RefShape = plugin.refShape();
		final catchKind: Null<String> = shape.catchClauseKind;
		if (catchKind == null) return [];
		final kind: String = catchKind;
		final catchAll: Array<String> = shape.catchAllTypeNames ?? [];
		if (catchAll.length == 0) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(violations, entry.file, entry.source, tree, kind, catchAll);
		}
		return violations;
	}

	/** Report-only — swapping `Dynamic` for `Exception` changes the bound value's type and API. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
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
	 * The type is read from the clause header source `[span.from, body.from)` — the text
	 * between the first `:` and the closing `)` — so an untyped `catch (e)` (no `:`) is
	 * skipped and a non-nominal type (a function type, generics) reduces to `null` via
	 * `simpleNominalName` and is skipped. The violation span covers only the `(var:Type)`
	 * parameter region, not the handler body.
	 */
	private static function flagCatch(
		out: Array<Violation>, file: String, source: String, catchNode: QueryNode, catchAll: Array<String>
	): Void {
		final cs: Null<Span> = catchNode.span;
		final kids: Array<QueryNode> = catchNode.children;
		if (cs == null || kids.length == 0) return;
		final body: Null<Span> = kids[kids.length - 1].span;
		if (body == null) return;
		final start: Int = cs.from;
		final header: String = source.substring(start, body.from);
		final open: Int = header.indexOf('(');
		final colon: Int = header.indexOf(':');
		final close: Int = header.lastIndexOf(')');
		if (open == -1 || colon == -1 || close == -1 || close <= colon) return;
		final typeName: Null<String> = TypeResolver.simpleNominalName(header.substring(colon + 1, close));
		if (typeName == null || !catchAll.contains(typeName)) return;
		out.push({
			file: file,
			span: new Span(start + open, start + close + 1),
			rule: 'catch-dynamic',
			severity: Severity.Warning,
			message: 'catch type \'$typeName\' is a raw catch-all — prefer catch (exception:Exception)'
		});
	}

}
