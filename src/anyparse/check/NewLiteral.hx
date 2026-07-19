package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeResolver;

/**
 * Shared engine for the collection-literal checks (`prefer-array-literal`,
 * `prefer-map-literal`): each flags an empty-argument `new <typeName>()` that the
 * `[]` literal replaces, and rewrites it to `[]`. `Severity.Info` (a modernization
 * cleanup).
 *
 * The element type survives through the annotation on the assignment target — the
 * convention these checks assume — so `var xs:Array<Int> = new Array()` becomes
 * `var xs:Array<Int> = []`. What `[]` cannot recover is an unannotated target whose only
 * type source is the construction itself: `var xs = new Array<Int>()` loses its element
 * type, and worse, an unannotated `var m = new Map<K, V>()` would become an Array (`[]`
 * infers `Array`, not `Map`). The check has no type information to detect either, so the
 * `--fix` on such a target is left to the human to confirm. The report is always correct
 * (the construction IS replaceable); only the unannotated-target rewrite carries this
 * caveat.
 *
 * ## Grammar-agnostic
 *
 * Driven by `RefShape.newExprKind` (unset → no-op). The constructed type (`Array` /
 * `Map`) is matched on the node `name`, not a kind — per the convention that a literal
 * type name is a node value, not a grammar kind. A node is replaceable only when its
 * source ends in `()` (an empty argument list), so a parseable-but-non-compiling
 * `new Array(x)` never silently drops `x`. The matched node is flagged and not descended
 * into.
 */
@:nullSafety(Strict)
final class NewLiteral {

	public static function run(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, typeName: String, rule: String, message: String
	): Array<Violation> {
		final newExprKind: Null<String> = plugin.refShape().newExprKind;
		if (newExprKind == null) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(violations, entry.file, entry.source, tree, newExprKind, typeName, rule, message);
		}
		return violations;
	}

	/** Rewrite each flagged `new <typeName>()` to the `[]` literal — but only where the target type is pinned by an annotation. */
	public static function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, typeName: String, ?symbolIndex: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		final newExprKind: Null<String> = shape.newExprKind;
		if (newExprKind == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];

		final nodeByKey: Map<String, QueryNode> = [];
		final parentByKey: Map<String, QueryNode> = [];
		index(tree, null, newExprKind, nodeByKey, parentByKey);

		// A plain-assignment target's declared type comes from the binding's WRITTEN annotation
		// via `TypeInfoProvider.declaredTypeSources` — resolved lazily, so a file whose findings
		// are all annotated declarations never pays for the parse.
		final declaredTypeSources: () -> Map<Int, String> = TypeResolver.memoizedDeclaredTypeSources(plugin, source);

		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final key: String = '${span.from}:${span.to}';
			final node: Null<QueryNode> = nodeByKey[key];
			if (node == null || !matches(node, source, newExprKind, typeName)) continue;
			final parent: Null<QueryNode> = parentByKey[key];
			if (parent == null) continue;
			final parentSpan: Null<Span> = parent.span;
			if (parentSpan == null) continue;
			// Rewrite when the `new` is the direct initializer of an annotated declaration
			// (`var xs:Array<Int> = new …`), OR the RHS of a plain assignment whose lvalue's
			// declaration pins the collection type.
			if (
				pinnedByTypeHint(source, parentSpan.from, span.from)
				|| assignmentTargetPinsType(parent, node, shape, tree, symbolIndex, declaredTypeSources, typeName)
			)
				edits.push({ span: span, text: '[]' });
		}
		return edits;
	}

	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, newExprKind: String, typeName: String, rule: String,
		message: String
	): Void {
		if (matches(node, source, newExprKind, typeName)) {
			final span: Null<Span> = node.span;
			if (span != null) {
				out.push({
					file: file,
					span: span,
					rule: rule,
					severity: Severity.Info,
					message: message
				});
				return;
			}
		}
		for (c in node.children) walk(out, file, source, c, newExprKind, typeName, rule, message);
	}

	/** Whether `node` is a `new <typeName>()` with an empty argument list (source ends in `()`). */
	private static function matches(node: QueryNode, source: String, newExprKind: String, typeName: String): Bool {
		if (node.kind != newExprKind || node.name != typeName) return false;
		final span: Null<Span> = node.span;
		return span != null && StringTools.endsWith(StringTools.rtrim(source.substring(span.from, span.to)), '()');
	}

	/** Index every `new` node by its `from:to` span key and record its parent (for `fix` to re-find a flagged node and gate on its enclosing declaration). */
	private static function index(
		node: QueryNode, parent: Null<QueryNode>, newExprKind: String, nodeByKey: Map<String, QueryNode>,
		parentByKey: Map<String, QueryNode>
	): Void {
		if (node.kind == newExprKind) {
			final span: Null<Span> = node.span;
			if (span != null) {
				final key: String = '${span.from}:${span.to}';
				nodeByKey[key] = node;
				if (parent != null) parentByKey[key] = parent;
			}
		}
		for (c in node.children) index(c, node, newExprKind, nodeByKey, parentByKey);
	}


	/**
	 * Whether the `new` node starting at `newStart` is the direct initializer of a
	 * declaration whose target type is PINNED by an explicit annotation — the only context
	 * where `[]` safely preserves the intended type. `[]` infers `Array`, so an unannotated
	 * `var m = new Map()` rewritten to `var m = []` silently becomes an `Array` (and no
	 * longer compiles once used as a map), and an unannotated `var xs = new Array<Int>()`
	 * loses its `<Int>`. `declStart` is the enclosing declaration node's span start.
	 *
	 * The head — `source[declStart...newStart]` — is the declaration up to and including the
	 * `=`. It qualifies when it ends in a lone `=` (a plain initializer) and its left side
	 * carries a top-level type-hint `:` with no top-level `,`. A metadata colon (`@:meta`) is
	 * excluded (the `:` follows `@`); a colon or comma inside `<>` / `()` / `[]` / `{}` is a
	 * type parameter or access clause, not the hint, so bracket depth is tracked. An
	 * unannotated declaration, an argument / return / element position, an assignment to an
	 * lvalue typed elsewhere, and a later declarator in a multi-variable declaration all fail
	 * and stay a finding — conservative by construction: a context the annotation cannot prove
	 * safe is never rewritten.
	 *
	 */
	private static function pinnedByTypeHint(source: String, declStart: Int, newStart: Int): Bool {
		final head: String = StringTools.rtrim(source.substring(declStart, newStart));
		final len: Int = head.length;
		if (len == 0 || StringTools.fastCodeAt(head, len - 1) != '='.code) return false;
		var depth: Int = 0;
		var sawColon: Bool = false;
		for (i in 0...len - 1) {
			final c: Int = StringTools.fastCodeAt(head, i);
			switch c {
				case '<'.code | '('.code | '['.code | '{'.code:
					depth++;
				case '>'.code | ')'.code | ']'.code | '}'.code:
					if (depth > 0) depth--;
				case ':'.code:
					if (depth == 0 && (i == 0 || StringTools.fastCodeAt(head, i - 1) != '@'.code)) sawColon = true;
				case ','.code:
					if (depth == 0) return false;
				case _:
			}
		}
		return sawColon;
	}


	/**
	 * Whether the flagged `new` node is the RHS of a plain assignment (`assignKind`) whose
	 * lvalue's DECLARATION pins the collection type — the only assignment context where `[]`
	 * safely preserves the intended type: in a plain assignment the lvalue is already typed,
	 * so `[]` unifies with that type (an `Array` / `Map` distinction the annotation carries).
	 * The lvalue must be a bare identifier — resolved to its own-class field / parameter /
	 * typed local via `TypeResolver.identDeclaredTypeSource` — or `this.<field>`, resolved to
	 * the enclosing type's member via the cross-file `SymbolIndex` (`memberTypeSourceOf`). Any
	 * other lvalue (a field access on another value, a static `Type.field`), an unresolved /
	 * unannotated binding, or a binding whose declared type's outer nominal is not `typeName`
	 * yields false — conservative by construction, never guessing across a type the resolvers
	 * cannot prove.
	 */
	private static function assignmentTargetPinsType(
		parent: QueryNode, newNode: QueryNode, shape: RefShape, tree: QueryNode, symbolIndex: Null<SymbolIndex>,
		declaredTypeSources: () -> Map<Int, String>, typeName: String
	): Bool {
		final assignKind: Null<String> = shape.assignKind;
		if (assignKind == null || parent.kind != assignKind || parent.children.length != 2) return false;
		// The `new` must be the assignment's RHS (`children[1]`), not a nested position.
		final rhs: QueryNode = parent.children[1];
		final rhsSpan: Null<Span> = rhs.span;
		final newSpan: Null<Span> = newNode.span;
		if (rhsSpan == null || newSpan == null) return false;
		if (rhsSpan.from != newSpan.from || rhsSpan.to != newSpan.to) return false;
		final typeSrc: Null<String> = lvalueTypeSource(parent.children[0], shape, tree, symbolIndex, declaredTypeSources, newSpan);
		return typeSrc != null && outerNominal(typeSrc) == typeName;
	}

	/**
	 * The declared type SOURCE of an assignment lvalue, or null when it cannot be soundly
	 * resolved. A bare identifier resolves through `TypeResolver.identDeclaredTypeSource`
	 * (own-field / parameter / typed-local, shadow-guarded); a `this.<field>` access resolves
	 * to the enclosing type's member via the `SymbolIndex` (`memberTypeSourceOf`). Every other
	 * lvalue shape — including a field access on another receiver or a static `Type.field` —
	 * yields null.
	 */
	private static function lvalueTypeSource(
		lval: QueryNode, shape: RefShape, tree: QueryNode, symbolIndex: Null<SymbolIndex>, declaredTypeSources: () -> Map<Int, String>,
		newSpan: Span
	): Null<String> {
		final identKind: Null<String> = shape.identKind;
		final faKind: Null<String> = shape.fieldAccessKind;
		if (identKind != null && lval.kind == identKind)
			return TypeResolver.identDeclaredTypeSource(lval, shape, tree, declaredTypeSources, false);
		if (faKind == null || identKind == null || lval.kind != faKind || lval.children.length != 1) return null;
		final recv: QueryNode = lval.children[0];
		final member: Null<String> = lval.name;
		if (symbolIndex == null || member == null || recv.kind != identKind || recv.name != 'this') return null;
		final enclosing: Null<String> = TypeResolver.enclosingTypeName(tree, newSpan);
		return enclosing == null ? null : symbolIndex.memberTypeSourceOf(enclosing, member);
	}

	/**
	 * The simple OUTER nominal of a declared type source — `Array<Int>` / `haxe.ds.Map<K, V>`
	 * → `Array` / `Map`. The generic tail is cut at the first `<`, then the last `.`-segment
	 * is taken (`TypeResolver.simpleNominalName`). Null when the base is not a plain nominal (a
	 * function type, an anonymous struct), so such a target stays a finding.
	 */
	private static function outerNominal(typeSrc: String): Null<String> {
		final lt: Int = typeSrc.indexOf('<');
		return TypeResolver.simpleNominalName(lt == -1 ? typeSrc : typeSrc.substring(0, lt));
	}

}
