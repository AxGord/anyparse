package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import anyparse.query.CallSites;
import anyparse.query.RemoveParam;

/**
 * Flags a function parameter whose name is never referenced in the function —
 * a dead parameter, or a hint of a stale signature. Purely structural (no type
 * information), so it holds without a type-checker.
 *
 * `Warning` (with a `--fix`) for the provably-safe subset — a named local
 * function, or a confined private method (`isPrivateMemberConfined`) — whose
 * call set can be proven complete WITHIN one file by the shared
 * `RemoveParam.paramSlotEdits` core; `fix` removes the parameter and its
 * argument at every in-file call site (one per function per pass). A public /
 * unconfined method stays `Info` — its callers may be cross-file, where the
 * `remove-param` op applies the change with a completeness proof and advisory.
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
 *  - A function carrying the `dynamic` modifier (`RefShape.dynamicModifierKind`)
 *    — a reassignable callback slot whose signature external assigners rely on.
 *    An unreferenced parameter there is by design (the default body may
 *    legitimately ignore it while a reassigned closure elsewhere uses it), so
 *    the whole function is skipped — not merely downgraded to `Info`.
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
		final visibilityKinds: Array<String> = shape.visibilityModifierKinds ?? [];
		final modifierKinds: Array<String> = shape.modifierOrderKinds ?? [];
		final noBodyKind: Null<String> = shape.noBodyKind;
		final dynamicKind: Null<String> = shape.dynamicModifierKind;
		// The autofixable subset (a confined private method) is proven against the
		// cross-file SymbolIndex, exactly as `unused-private`; both are registered in
		// the `--fix` loop's `fullScopeIds` so this index sees every file each pass.
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) {
				final candidates: Array<{ fn: QueryNode, parent: QueryNode }> = [];
				walk(candidates, tree, null, functionKinds, opaqueKinds, supertypeClauseKinds, noBodyKind);
				for (c in candidates)
					checkFunction(
						violations, entry.file, entry.source, c.fn, c.parent, tree, visibilityKinds, modifierKinds, dynamicKind, shape,
						index
					);
			}
		}
		return violations;
	}

	/**
	 * Remove every `Warning` (autofixable) unused parameter and its positional
	 * argument at all in-file call sites, reusing the
	 * `RemoveParam.paramSlotEdits` core. Only ONE parameter per function is
	 * edited per call — removing one shifts the remaining parameters' indices
	 * and arity, so the lint fixed-point loop re-runs the proof on the
	 * rewritten file and removes the next. `Info` findings (public / unconfined
	 * methods) are left untouched.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final flagged: Array<String> = [];
		for (v in violations) if (v.severity == Severity.Warning) {
			final span: Null<Span> = v.span;
			if (span != null) flagged.push('${span.from}:${span.to}');
		}
		if (flagged.length == 0) return [];
		final edits: Array<{ span: Span, text: String }> = [];
		final handled: Array<Int> = [];
		collectFixEdits(tree, tree, source, shape, flagged, handled, edits);
		return RefactorSupport.dropContainedEdits(edits);
	}

	/**
	 * Collect every in-scope function as a `{ fn, parent }` candidate — its
	 * parent node resolves the enclosing type's name and visibility for the
	 * autofixability decision. A reification subtree (`opaqueKinds`) is
	 * skipped wholesale; a function is collected unless it is a contract
	 * candidate (its parent type carries a supertype clause) or has no body.
	 */
	private static function walk(
		out: Array<{ fn: QueryNode, parent: QueryNode }>, node: QueryNode, parent: Null<QueryNode>, functionKinds: Array<String>,
		opaqueKinds: Array<String>, supertypeClauseKinds: Array<String>, noBodyKind: Null<String>
	): Void {
		if (opaqueKinds.contains(node.kind)) return;
		if (
			functionKinds.contains(node.kind) && parent != null && !isContractCandidate(parent, supertypeClauseKinds)
			&& !hasNoBody(node, noBodyKind)
		)
			out.push({ fn: node, parent: parent });
		for (c in node.children) walk(out, c, node, functionKinds, opaqueKinds, supertypeClauseKinds, noBodyKind);
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
	 * Append a violation for every parameter of `fn` unreferenced in the
	 * function span (skipping a null name / span and an `_`-prefixed name).
	 * Severity is `Warning` — the autofixable subset — when the parameter can
	 * be removed safely WITHIN this file: `fn` is a named local function (its
	 * call sites are all in its body), or a confined private method (its
	 * callers are confined to its class / file), AND the shared
	 * `RemoveParam.paramSlotEdits` proof succeeds (complete, arity-matched call
	 * sites). Everything else — a public method, an unconfined or otherwise
	 * unprovable signature — stays `Info`, resolved via the `remove-param` op
	 * with its cross-file advisory.
	 */
	private static function checkFunction(
		out: Array<Violation>, file: String, source: String, fn: QueryNode, parent: QueryNode, tree: QueryNode,
		visibilityKinds: Array<String>, modifierKinds: Array<String>, dynamicKind: Null<String>, shape: RefShape, index: SymbolIndex
	): Void {
		final fnSpan: Null<Span> = fn.span;
		if (fnSpan == null) return;
		if (isDynamicFn(fn, parent, visibilityKinds, modifierKinds, dynamicKind)) return;
		final fnName: Null<String> = fn.name;
		final isLocal: Bool = fn.kind == 'LocalFnStmt';
		final ownerName: Null<String> = parent.name;
		final eligible: Bool = isLocal
			|| (ownerName != null && !isPublicDecl(fn, parent, source, visibilityKinds, modifierKinds)
				&& RefactorSupport.isPrivateMemberConfined(ownerName, source, index));
		final params: Array<QueryNode> = CallSites.leadingParams(fn);
		for (pi in 0...params.length) {
			final p: QueryNode = params[pi];
			final name: Null<String> = p.name;
			final pspan: Null<Span> = p.span;
			if (name == null || pspan == null) continue;
			if (StringTools.startsWith(name, '_')) continue;
			if (RefactorSupport.referencedInRange(source, name, fnSpan.from, fnSpan.to, [pspan])) continue;
			final autofixable: Bool = eligible && fnName != null
				&& RemoveParam.paramSlotEdits(source, tree, fn, pi, fnName, fnSpan.from, shape).error == null;
			out.push({
				file: file,
				span: pspan,
				rule: 'unused-parameter',
				severity: autofixable ? Severity.Warning : Severity.Info,
				message: 'unused parameter \'$name\''
			});
		}
	}

	/**
	 * Whether the method `fn` carries an explicit `public` visibility modifier
	 * — a preceding sibling in `parent`'s child list whose source is `public`.
	 * Default (no modifier) is `private` in Haxe, so its absence means private.
	 * The backward scan stops at the first non-modifier sibling (the previous
	 * member), so it never crosses into an earlier declaration's modifiers.
	 */
	private static function isPublicDecl(
		fn: QueryNode, parent: QueryNode, source: String, visibilityKinds: Array<String>, modifierKinds: Array<String>
	): Bool {
		final sibs: Array<QueryNode> = parent.children;
		final fnIdx: Int = sibs.indexOf(fn);
		if (fnIdx < 0) return false;
		var i: Int = fnIdx - 1;
		while (i >= 0) {
			final sib: QueryNode = sibs[i];
			if (!visibilityKinds.contains(sib.kind) && !modifierKinds.contains(sib.kind)) break;
			final sspan: Null<Span> = sib.span;
			if (visibilityKinds.contains(sib.kind) && sspan != null && StringTools.trim(source.substring(sspan.from, sspan.to)) == 'public')
				return true;
			i--;
		}
		return false;
	}

	/**
	 * Whether `fn` carries the `dynamic` modifier among its preceding sibling
	 * modifiers — a reassignable callback slot whose signature external
	 * assigners rely on (see the class docstring). Mirrors `isPublicDecl`'s
	 * backward sibling scan, additionally treating the dynamic modifier itself
	 * as part of the modifier run so the scan does not stop short of it.
	 */
	private static function isDynamicFn(
		fn: QueryNode, parent: QueryNode, visibilityKinds: Array<String>, modifierKinds: Array<String>, dynamicKind: Null<String>
	): Bool {
		if (dynamicKind == null) return false;
		final sibs: Array<QueryNode> = parent.children;
		final fnIdx: Int = sibs.indexOf(fn);
		if (fnIdx < 0) return false;
		var i: Int = fnIdx - 1;
		while (i >= 0) {
			final sib: QueryNode = sibs[i];
			final isModifier: Bool = visibilityKinds.contains(sib.kind) || modifierKinds.contains(sib.kind) || sib.kind == dynamicKind;
			if (!isModifier) break;
			if (sib.kind == dynamicKind) return true;
			i--;
		}
		return false;
	}

	/**
	 * Walk `node`, and for each function-declaration node whose binding offset
	 * is not yet `handled`, find the FIRST leading parameter whose span is in
	 * `flagged` and, if `RemoveParam.paramSlotEdits` proves it removable, append
	 * the slot-removal edits and mark the function handled (one parameter per
	 * function per pass — see `fix`). `root` is the whole-file tree the proof
	 * scans for call sites.
	 */
	private static function collectFixEdits(
		node: QueryNode, root: QueryNode, source: String, shape: RefShape, flagged: Array<String>, handled: Array<Int>,
		edits: Array<{ span: Span, text: String }>
	): Void {
		if (RefactorSupport.FN_DECL_KINDS.contains(node.kind)) {
			final fnSpan: Null<Span> = node.span;
			final fnName: Null<String> = node.name;
			if (fnSpan != null && fnName != null && !handled.contains(fnSpan.from)) {
				final params: Array<QueryNode> = CallSites.leadingParams(node);
				for (pi in 0...params.length) {
					final pspan: Null<Span> = params[pi].span;
					if (pspan != null && flagged.contains('${pspan.from}:${pspan.to}')) {
						final result: {
							edits: Array<{ span: Span, text: String }>,
							error: Null<String>,
							callSites: Int
						} = RemoveParam.paramSlotEdits(source, root, node, pi, fnName, fnSpan.from, shape);
						if (result.error == null) {
							for (e in result.edits) edits.push(e);
							handled.push(fnSpan.from);
						}
						break;
					}
				}
			}
		}
		for (c in node.children) collectFixEdits(c, root, source, shape, flagged, handled, edits);
	}

}
