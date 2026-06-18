package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags a function parameter whose name is never referenced in the function —
 * a dead parameter, or a hint of a stale signature. Purely structural (no type
 * information), so it holds without a type-checker. Report-only: removing a
 * parameter changes the signature and every call site, which the `remove-param`
 * op performs with a completeness proof — a blind lint deletion would break
 * callers, so this check only reports.
 *
 * ## Why a scope-bounded text scan
 *
 * A parameter is visible throughout its function, so its entire visibility
 * region lies inside the function node's source span. "Is it referenced" is a
 * raw word-boundary scan of that span OUTSIDE the parameter's own declaration
 * (`RefactorSupport.referencedInRange`) — the conservative approach the rest of
 * the unused-* family uses, for the same reason: an AST projection misses
 * reference forms the grammar surfaces under non-obvious ctors (the
 * simple-interpolation `'$name'` is an `Ident`, not the `IdentExpr` the
 * reference walker matches). Scanning the whole function span (not just the
 * body) also counts a use inside a sibling parameter's default value. A textual
 * scan over-counts (a name in a comment / string / nested re-declaration), which
 * only ever keeps a parameter, never wrongly reports one.
 *
 * ## What is skipped (false-positive gates)
 *
 *  - A name starting with `_` — the conventional "intentionally unused" marker.
 *  - A body-less function (`RefShape.noBodyKind`: an interface / abstract method
 *    declaration) — it has no body to reference its parameters in, so every
 *    parameter would read as unused.
 *  - A method whose enclosing type carries a supertype clause
 *    (`RefShape.supertypeClauseKinds`: `extends` / `implements`) — its signature
 *    may be fixed by an overridden / implemented contract, where an unused
 *    parameter is mandated, not dead. The gate is the PARENT test: a function
 *    whose direct parent (the type body) holds a supertype clause is a contract
 *    candidate and skipped; a local function (parent is a block) and a method of
 *    a supertype-less type stay in scope.
 *  - A subtree inside metaprogramming reification (`RefShape.opaqueKinds`,
 *    Haxe `macro { … }`) — a parameter's uses there may be splice-injected and
 *    invisible to a source scan.
 *
 * The residual false positive a structural check cannot rule out is a function
 * passed as a fixed-signature callback (an event handler) that ignores a
 * parameter; `Info` flags it advisorily, the author resolving it via
 * `remove-param` or an `_`-rename.
 */
@:nullSafety(Strict)
final class UnusedParameter implements Check {

	public function new() {}

	public function id(): String {
		return 'unused-parameter';
	}

	public function description(): String {
		return 'function parameter declared but never referenced in its body';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final functionKinds: Array<String> = shape.functionKinds ?? [];
		final paramKinds: Array<String> = shape.paramKinds ?? [];
		if (functionKinds.length == 0 || paramKinds.length == 0) return [];
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		final supertypeClauseKinds: Array<String> = shape.supertypeClauseKinds ?? [];
		final noBodyKind: Null<String> = shape.noBodyKind;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null)
				walk(
					violations, entry.file, entry.source, tree, null, functionKinds, paramKinds, opaqueKinds, supertypeClauseKinds,
					noBodyKind
				);
		}
		return violations;
	}

	/** Report-only — removing a parameter is a cross-file signature change (use the `remove-param` op). */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/**
	 * Walk `node` (tracking its `parent`), checking every in-scope function's
	 * parameters. A reification subtree (`opaqueKinds`) is skipped wholesale. A
	 * function is checked unless it is a contract candidate (its parent type
	 * carries a supertype clause) or has no body.
	 */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, parent: Null<QueryNode>, functionKinds: Array<String>,
		paramKinds: Array<String>, opaqueKinds: Array<String>, supertypeClauseKinds: Array<String>, noBodyKind: Null<String>
	): Void {
		if (opaqueKinds.contains(node.kind)) return;
		if (functionKinds.contains(node.kind) && parent != null && !isContractCandidate(parent, supertypeClauseKinds) && !hasNoBody(
			node, noBodyKind
		)) checkFunction(out, file, source, node, paramKinds);
		for (c in node.children) walk(out, file, source, c, node, functionKinds, paramKinds, opaqueKinds, supertypeClauseKinds, noBodyKind);
	}

	/** Whether `parent` (a function's enclosing node) carries a supertype clause — making the function a contract candidate. */
	private static function isContractCandidate(parent: QueryNode, supertypeClauseKinds: Array<String>): Bool {
		for (c in parent.children) if (supertypeClauseKinds.contains(c.kind)) return true;
		return false;
	}

	/** Whether `fn` is a body-less declaration (an interface / abstract method). */
	private static function hasNoBody(fn: QueryNode, noBodyKind: Null<String>): Bool {
		if (noBodyKind == null) return false;
		for (c in fn.children) if (c.kind == noBodyKind) return true;
		return false;
	}

	/**
	 * Append an `Info` for every parameter of `fn` unreferenced in the function
	 * span. Skips a null name / span and an `_`-prefixed name (the intentional-
	 * discard convention); the parameter's own declaration span is excluded from
	 * the reference scan.
	 */
	private static function checkFunction(
		out: Array<Violation>, file: String, source: String, fn: QueryNode, paramKinds: Array<String>
	): Void {
		final fnSpan: Null<Span> = fn.span;
		if (fnSpan == null) return;
		for (p in fn.children) if (paramKinds.contains(p.kind)) {
			final name: Null<String> = p.name;
			final pspan: Null<Span> = p.span;
			if (name == null || pspan == null) continue;
			if (StringTools.startsWith(name, '_')) continue;
			if (RefactorSupport.referencedInRange(source, name, fnSpan.from, fnSpan.to, [pspan])) continue;
			out.push({
				file: file,
				span: pspan,
				rule: 'unused-parameter',
				severity: Severity.Info,
				message: 'unused parameter \'$name\''
			});
		}
	}

}
