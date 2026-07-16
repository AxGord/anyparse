package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

/**
 * Flags a `catch` clause that can never run because an EARLIER clause in the same `try`
 * already catches everything it would — a duplicate type, a supertype/interface it
 * extends, or a catch-all (`Dynamic` / `Any`). `Severity.Warning`; report-only.
 *
 * ## Three covered-by relations (per `try`, earlier clause `j` covers later clause `i`)
 *
 * - **Catch-all earlier**: `j`'s type is a `RefShape.catchAllTypeNames` value — it
 *   catches every thrown value, so every later clause is dead.
 * - **Duplicate**: `i` and `j` have the same written type SOURCE, compared import-aware
 *   via `TypeResolver.sameTypeSource` (so `e:Eof` and `e:haxe.io.Eof` reconcile). Sound
 *   within one file.
 * - **Subtype-after-supertype**: `i`'s type transitively extends/implements `j`'s type —
 *   `SymbolIndex.isSubtype` (the cross-file hierarchy the index already builds). A value
 *   `i` would catch is already a `j`, so `j` caught it first.
 *
 * Conservative: the exception type is recovered from the clause header source between the
 * first `:` and the closing `)` (bounded by the handler block's span); a non-nominal type
 * (generic / function / anon) yields no simple name and is a safe miss. The subtype check
 * is simple-name based — an unindexed supertype link ends the chain (safe miss), and a
 * same-named unrelated type is the residual soundness boundary (as in `impossible-is-check`).
 * Macro-reification subtrees (`RefShape.opaqueKinds`) are not descended into.
 *
 * Report-only: removing a dead clause vs. fixing its type / ordering is context-dependent.
 */
@:nullSafety(Strict)
final class UnreachableCatch implements Check {

	public function new() {}

	public function id(): String {
		return 'unreachable-catch';
	}

	public function description(): String {
		return 'a catch clause already covered by an earlier clause in the same try';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final catchClauseKind: Null<String> = shape.catchClauseKind;
		if (catchClauseKind == null) return [];
		final kind: String = catchClauseKind;
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		final catchAll: Array<String> = shape.catchAllTypeNames ?? [];
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		if (provider == null) return [];
		final typed: TypeInfoProvider = provider;
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final importMap: Map<String, String> = typed.importMap(entry.source);
			function walk(node: QueryNode): Void {
				if (opaqueKinds.contains(node.kind)) return;
				final clauses: Array<QueryNode> = [for (c in node.children) if (c.kind == kind) c];
				if (clauses.length >= 2) checkClauses(clauses, entry, catchAll, importMap, index, violations);
				for (c in node.children) walk(c);
			}
			walk(tree);
		}
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/**
	 * Flag every clause in `clauses` (the in-order catch clauses of one `try`) that an
	 * EARLIER clause already covers: an earlier catch-all (`Dynamic` / `Any`, or an untyped
	 * `catch (e)`) covers any later clause; otherwise an earlier clause covers a later one of
	 * the same type (`sameTypeSource`, import-aware) or of a subtype (`SymbolIndex.isSubtype`).
	 */
	private static function checkClauses(
		clauses: Array<QueryNode>, entry: { file: String, source: String }, catchAll: Array<String>, importMap: Map<String, String>,
		index: SymbolIndex, violations: Array<Violation>
	): Void {
		final raws: Array<Null<String>> = [for (c in clauses) catchTypeSource(c, entry.source)];
		final simples: Array<Null<String>> = raws.map(TypeResolver.simpleNominalName);
		final catchAllFlags: Array<Bool> = [
			for (k in 0...clauses.length) isUntypedCatch(clauses[k], entry.source) || coversAllType(simples[k], catchAll)
		];
		for (i in 1...clauses.length) {
			final laterRaw: Null<String> = raws[i];
			if (laterRaw == null && !catchAllFlags[i]) continue;
			final laterSimple: Null<String> = simples[i];
			var covered: Null<String> = null;
			for (j in 0...i) {
				if (catchAllFlags[j]) {
					covered = raws[j] ?? 'catch-all';
					break;
				}
				final earlierRaw: Null<String> = raws[j];
				if (earlierRaw == null || laterRaw == null) continue;
				final earlierSimple: Null<String> = simples[j];
				final duplicate: Bool = TypeResolver.sameTypeSource(laterRaw, earlierRaw, importMap);
				final subtype: Bool = laterSimple != null && earlierSimple != null && index.isSubtype(laterSimple, earlierSimple);
				if (duplicate || subtype) {
					covered = earlierRaw;
					break;
				}
			}
			final coveredBy: Null<String> = covered;
			final span: Null<Span> = clauses[i].span;
			if (coveredBy != null && span != null) violations.push({
				file: entry.file,
				span: span,
				rule: 'unreachable-catch',
				severity: Severity.Warning,
				message: 'catch clause is unreachable — already caught by an earlier $coveredBy clause'
			});
		}
	}

	/**
	 * The exception type SOURCE of a catch clause — the text between the first `:` and the
	 * closing `)` of the header, bounded by the handler block (the clause's last child).
	 * Null when the clause is untyped or malformed.
	 */
	private static function catchTypeSource(clause: QueryNode, source: String): Null<String> {
		final cs: Null<Span> = clause.span;
		if (cs == null || clause.children.length < 1) return null;
		final body: Null<Span> = clause.children[clause.children.length - 1].span;
		if (body == null) return null;
		final header: String = source.substring(cs.from, body.from);
		final colon: Int = header.indexOf(':');
		final close: Int = header.lastIndexOf(')');
		if (colon == -1 || close == -1 || close <= colon) return null;
		final t: String = StringTools.trim(header.substring(colon + 1, close));
		return t == '' ? null : t;
	}

	/**
	 * Whether `clause` is an untyped `catch (e)` — a Haxe catch-all (it binds the exception
	 * root, catching every thrown value). Well-formed (a var name + handler body) with a
	 * header carrying no `:`. A malformed / unparseable clause is not treated as one.
	 */
	private static function isUntypedCatch(clause: QueryNode, source: String): Bool {
		final cs: Null<Span> = clause.span;
		if (cs == null || clause.children.length < 1) return false;
		final body: Null<Span> = clause.children[clause.children.length - 1].span;
		if (body == null) return false;
		final header: String = source.substring(cs.from, body.from);
		return header.indexOf(':') == -1 && header.lastIndexOf(')') != -1;
	}

	/** Whether a clause of simple type `simple` catches every value (a `catchAllTypeNames` type). */
	private static function coversAllType(simple: Null<String>, catchAll: Array<String>): Bool {
		return simple != null && catchAll.contains(simple);
	}

}
