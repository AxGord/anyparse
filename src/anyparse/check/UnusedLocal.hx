package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags local `var` / `final` declarations whose bound name is never
 * referenced within its lexical scope — dead bindings the formatter cannot
 * remove. Statement-position locals only (`VarStmt` / `FinalStmt`); function
 * parameters, `for` iterators, `catch` variables, class fields and top-level
 * declarations are deliberately out of scope (an unused parameter is usually
 * a signature constraint, not dead code).
 *
 * ## Why a raw scope-bounded text scan
 *
 * A local is visible only from its declaration to the end of the enclosing
 * scope, so its entire visibility region lies inside that scope node's source
 * span. The "is it referenced" test is therefore a raw word-boundary scan of
 * the enclosing scope's source, OUTSIDE the declaration itself
 * (`RefactorSupport.referencedInRange`) — the same conservative approach
 * `unused-import` uses, for the same reason: an AST projection misses
 * reference forms the grammar surfaces under non-obvious ctors (the
 * simple-interpolation `'$name'` is an `Ident`, not the `IdentExpr` the
 * reference walker matches). A textual scan catches every reference the
 * compiler can see, at the cost of also counting the name inside comments /
 * strings / a sibling nested scope that re-declares it — which only ever
 * yields a missed finding (a kept binding), never a wrong deletion. Bounding
 * the scan to the enclosing scope (not the whole file) is what stops a
 * same-named local in a different function from masking this one.
 *
 * ## Reification is opaque
 *
 * Inside a metaprogramming-reification subtree (the plugin's `opaqueKinds` —
 * Haxe `macro { … }`), a binding's uses can be injected by splicing rather
 * than written literally, so a source scan cannot see them. Declarations
 * inside such a subtree are skipped entirely: flagging one would be a false
 * positive, and the autofix would then delete a live binding. This is the one
 * structural concession the text scan makes, and it is plugin-declared so the
 * check stays grammar-agnostic.
 *
 * ## Autofix
 *
 * A flagged local is by construction wholly unreferenced, so the only
 * deletion hazard is a side-effecting initializer (`final x = compute();`).
 * `fix` deletes the declaration line only when it has no initializer or a
 * side-effect-free one (`RefactorSupport.isSideEffectFree`); a side-effecting
 * initializer is reported but left for the author to resolve.
 */
@:nullSafety(Strict)
final class UnusedLocal implements Check {

	/**
	 * Statement-position local declaration kinds — a plain local `var` /
	 * `final`. Excludes params, `for` iterators, `catch` vars, class fields,
	 * and the expression-position `VarExpr` / `FinalExpr` twins (not a
	 * standalone deletable statement).
	 */
	private static final LOCAL_DECL_KINDS: Array<String> = ['VarStmt', 'FinalStmt'];

	public function new() {}

	public function id(): String {
		return 'unused-local';
	}

	public function description(): String {
		return 'local var/final declared but never referenced in its scope';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final scopeKinds: Array<String> = shape.scopeKinds;
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(violations, entry.file, entry.source, tree, null, scopeKinds, opaqueKinds);
		}
		return violations;
	}

	/**
	 * Delete each fixable unused-local declaration. A flagged local is wholly
	 * unreferenced, so the deletion is safe whenever the initializer carries
	 * no side effect (or is absent). The declaration's whole physical line is
	 * removed (`lineExtendedSpan`) so the batched `canonicalize` leaves no
	 * blank residue; a side-effecting initializer is skipped (no edit).
	 */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
		if (tree == null) return edits;

		final opaqueKinds: Array<String> = plugin.refShape().opaqueKinds ?? [];
		final declByFrom: Map<Int, QueryNode> = [];
		collectLocalDecls(tree, declByFrom, opaqueKinds);

		for (v in violations) {
			if (v.severity != Severity.Warning) continue;
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final decl: Null<QueryNode> = declByFrom[span.from];
			if (decl == null) continue;
			final init: Null<QueryNode> = decl.children.length > 0 ? decl.children[0] : null;
			if (init != null && !RefactorSupport.isSideEffectFree(init)) continue;
			edits.push({ span: RefactorSupport.lineExtendedSpan(source, span), text: '' });
		}
		return edits;
	}

	/**
	 * Walk `node`, tracking the innermost enclosing scope, and append a
	 * `Warning` for every unreferenced local declaration. A subtree whose root
	 * kind is in `opaqueKinds` (macro reification) is skipped wholesale — its
	 * bindings' uses may be splice-injected and invisible to a source scan. A
	 * scope-introducing node (`scopeKinds`) becomes the enclosing scope of its
	 * descendants; a local declaration is tested against the scope it was
	 * passed (its parent scope), never one it might open itself.
	 */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, enclosingScope: Null<QueryNode>, scopeKinds: Array<String>,
		opaqueKinds: Array<String>
	): Void {
		if (opaqueKinds.contains(node.kind)) return;
		if (LOCAL_DECL_KINDS.contains(node.kind)) checkDecl(out, file, source, node, enclosingScope);
		final childScope: Null<QueryNode> = scopeKinds.contains(node.kind) ? node : enclosingScope;
		for (c in node.children) walk(out, file, source, c, childScope, scopeKinds, opaqueKinds);
	}

	/**
	 * Append a `Warning` if the local `decl` is unreferenced in `enclosingScope`.
	 * Bails (no finding) when any coordinate the test needs is missing — a null
	 * name, declaration span, or scope span — so an unspanned node is never
	 * flagged.
	 */
	private static function checkDecl(
		out: Array<Violation>, file: String, source: String, decl: QueryNode, enclosingScope: Null<QueryNode>
	): Void {
		final name: Null<String> = decl.name;
		final declSpan: Null<Span> = decl.span;
		if (name == null || declSpan == null || enclosingScope == null) return;
		final scopeSpan: Null<Span> = enclosingScope.span;
		if (scopeSpan == null) return;
		if (RefactorSupport.referencedInRange(source, name, scopeSpan.from, scopeSpan.to, [declSpan])) return;
		out.push({
			file: file,
			span: declSpan,
			rule: 'unused-local',
			severity: Severity.Warning,
			message: 'unused local \'$name\''
		});
	}

	/**
	 * Index every statement-position local declaration by its span's `from`
	 * offset, skipping reification (`opaqueKinds`) subtrees so the autofix
	 * never resolves to a binding inside one.
	 */
	private static function collectLocalDecls(node: QueryNode, out: Map<Int, QueryNode>, opaqueKinds: Array<String>): Void {
		if (opaqueKinds.contains(node.kind)) return;
		if (LOCAL_DECL_KINDS.contains(node.kind)) {
			final span: Null<Span> = node.span;
			if (span != null) out[span.from] = node;
		}
		for (c in node.children) collectLocalDecls(c, out, opaqueKinds);
	}

}
