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
 * argument at every in-file call site (one per function per pass). Every other
 * flagged parameter — a public / unconfined method, or a function captured as a
 * value — stays `Info`, because removal cannot be proven safe (a `remove-param`
 * op with a cross-file advisory is the manual route); `fix` still silences it by
 * renaming it to `_<name>`, a decl-site-only edit that is cross-file-safe (a
 * parameter name is never part of a caller's syntax — Haxe has no named
 * arguments) and skipped on a `_<name>` collision.
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
 * only ever keeps a parameter, never wrongly reports one. The same scan gates
 * the rename: a `_<name>` occurrence anywhere in the span blocks it (a collision
 * or accidental capture), and a `#if`-guarded use of the name counts as a
 * reference (branch-blind in the SAFE direction), so a conditionally-used
 * parameter is neither flagged nor renamed.
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
 *    a supertype-less type stay in scope. Because an override / interface method
 *    is skipped here wholesale, no such parameter ever reaches the rename either.
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
 * parameter; `Info` flags it, and `fix` renames the parameter to `_<name>` —
 * the conventional "intentionally unused" marker — leaving the signature intact.
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
			if (tree == null) continue;
			final candidates: Array<{ fn: QueryNode, parent: QueryNode }> = [];
			walk(candidates, tree, null, functionKinds, opaqueKinds, supertypeClauseKinds, noBodyKind);
			for (c in candidates)
				checkFunction(
					violations, entry.file, entry.source, c.fn, c.parent, tree, visibilityKinds, modifierKinds, dynamicKind, shape, index
				);
		}
		return violations;
	}

	/**
	 * Apply the auto-fixable subset of `violations`. Dispatch is by severity, which
	 * `run` already resolved: a `Warning` unused parameter (an eligible local /
	 * confined-private method with a provably complete in-file call set) is REMOVED
	 * along with its positional argument at every call site via
	 * `RemoveParam.paramSlotEdits` — only ONE per function per call, since removing
	 * one shifts the remaining indices and arity, so the fixed-point loop re-runs the
	 * proof and removes the next. An `Info` unused parameter (a public / unconfined
	 * method, or a function captured as a value — a signature the removal proof
	 * cannot complete) is instead RENAMED to `_<name>`: a decl-site-only,
	 * cross-file-safe silencing, skipped on a `_<name>` name collision. The two edit
	 * sets are disjoint (a function's flagged parameters share its removability).
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		// A finding's severity IS the fix dispatch: `Warning` = a provably-removable
		// parameter (an eligible local / confined-private method with a complete in-file
		// call set), removed by `collectFixEdits`; `Info` = every other flagged parameter
		// (a public / unconfined method, or a function captured as a value), silenced by
		// the conservative `_`-prefix rename in `collectRenameEdits`. The two sets never
		// overlap within one function — a function's flagged parameters share its
		// removability — so their edits are disjoint.
		final removeFlagged: Array<String> = [];
		final renameFlagged: Array<String> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final key: String = '${span.from}:${span.to}';
			if (v.severity == Severity.Warning)
				removeFlagged.push(key);
			else if (v.severity == Severity.Info)
				renameFlagged.push(key);
		}
		final edits: Array<{ span: Span, text: String }> = [];
		if (removeFlagged.length > 0) {
			final handled: Array<Int> = [];
			collectFixEdits(tree, tree, source, shape, removeFlagged, handled, edits);
		}
		if (renameFlagged.length > 0) {
			final functionKinds: Array<String> = shape.functionKinds ?? [];
			final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
			if (functionKinds.length > 0) collectRenameEdits(tree, null, source, functionKinds, opaqueKinds, renameFlagged, index, edits);
		}
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


	/**
	 * Rename every `Info` (non-removable) unused parameter to `_<name>` — the
	 * conservative silencing fix for a parameter that cannot be safely removed
	 * (a public / unconfined method whose call set is not provably complete, or a
	 * function captured as a value). Only the DECLARATION site is edited: an unused
	 * parameter has no body reference by definition, and a parameter name is never
	 * part of a caller's syntax (Haxe has no named arguments), so the rename is
	 * cross-file-safe and needs no call-site edit. Walks the same function kinds `run`
	 * scans, skipping a reification subtree (`opaqueKinds`); the contract / body-less
	 * / dynamic gates were already applied when the finding was produced, so a flagged
	 * span is by construction in scope. A method a subtype OVERRIDES is skipped
	 * (`ownerMayBeOverridden`) — the override could USE the parameter, so the rename
	 * would misdescribe it. Every remaining flagged parameter of a rename function is
	 * renamed in one pass — each edit is an independent, non-overlapping name-token
	 * replacement.
	 */
	private static function collectRenameEdits(
		node: QueryNode, parent: Null<QueryNode>, source: String, functionKinds: Array<String>, opaqueKinds: Array<String>,
		renameFlagged: Array<String>, index: Null<SymbolIndex>, edits: Array<{ span: Span, text: String }>
	): Void {
		if (opaqueKinds.contains(node.kind)) return;
		if (functionKinds.contains(node.kind)) {
			final fnSpan: Null<Span> = node.span;
			if (fnSpan != null && !ownerMayBeOverridden(node, parent, index)) for (p in CallSites.leadingParams(node)) {
				final pspan: Null<Span> = p.span;
				final name: Null<String> = p.name;
				if (pspan == null || name == null) continue;
				if (!renameFlagged.contains('${pspan.from}:${pspan.to}')) continue;
				final nameStart: Int = renameNameStart(source, fnSpan, p);
				if (nameStart >= 0) edits.push({ span: new Span(nameStart, nameStart + name.length), text: '_$name' });
			}
		}
		for (c in node.children) collectRenameEdits(c, node, source, functionKinds, opaqueKinds, renameFlagged, index, edits);
	}


	/**
	 * The offset at which to insert the `_` prefix for a rename — the start of
	 * `param`'s name token within its span — or `-1` when the parameter must NOT
	 * be renamed: it already starts with `_`, its `_<name>` form already occurs
	 * anywhere in the function span `fnSpan` (a declaration, use, or accidental
	 * capture — conflict-safe skip), or the name unexpectedly reads as referenced
	 * (a defensive re-check; the textual scan is `#if`-inclusive, so a
	 * conditional use counts and keeps the parameter). The name token is the
	 * first word-boundary occurrence of the name inside the parameter span —
	 * always the leading identifier (`[?] name : type`), so a type or default
	 * that repeats the name cannot be mistaken for it.
	 */
	private static function renameNameStart(source: String, fnSpan: Span, param: QueryNode): Int {
		final name: Null<String> = param.name;
		if (name == null) return -1;
		final pspan: Null<Span> = param.span;
		if (pspan == null) return -1;
		if (StringTools.startsWith(name, '_')) return -1;
		if (RefactorSupport.referencedInRange(source, '_$name', fnSpan.from, fnSpan.to, [])) return -1;
		if (RefactorSupport.referencedInRange(source, name, fnSpan.from, fnSpan.to, [pspan])) return -1;
		return firstIdentOccurrence(source, name, pspan.from, pspan.to);
	}


	/**
	 * The offset of the first word-boundary occurrence of `name` in `[from, to)`,
	 * or `-1`. A word boundary requires a non-identifier character (or the buffer
	 * edge) on each side, so a longer identifier that merely contains `name` is
	 * not matched.
	 */
	private static function firstIdentOccurrence(source: String, name: String, from: Int, to: Int): Int {
		final len: Int = name.length;
		if (len == 0) return -1;
		final stop: Int = to <= source.length ? to : source.length;
		var i: Int = from;
		while (i + len <= stop) {
			final at: Int = source.indexOf(name, i);
			if (at < 0 || at + len > stop) return -1;
			final beforeOk: Bool = at == 0 || !RefactorSupport.isIdentChar(StringTools.fastCodeAt(source, at - 1));
			final afterIdx: Int = at + len;
			final afterOk: Bool = afterIdx >= source.length || !RefactorSupport.isIdentChar(StringTools.fastCodeAt(source, afterIdx));
			if (beforeOk && afterOk) return at;
			i = at + 1;
		}
		return -1;
	}


	/**
	 * Whether `fn` is a method that a subtype OVERRIDES — a subtype of `fn`'s owner
	 * type declares a method of the same name, which could USE the parameter that
	 * reads as unused HERE (this body ignores it, but the override may rely on it —
	 * e.g. an abstract base stub against a concrete override), making the `_`-prefix
	 * rename misleading. Precise override detection via `index.subtypeDeclaresMember`,
	 * available only with the cross-file `index` (the `--fix` pipeline). A local
	 * function is never overridden, and a null index (no hierarchy visible, e.g. a
	 * direct `fix` call) leaves the rename to the walk-level contract gate that
	 * already excludes the derived side.
	 */
	private static function ownerMayBeOverridden(fn: QueryNode, parent: Null<QueryNode>, index: Null<SymbolIndex>): Bool {
		if (index == null || parent == null || fn.kind == 'LocalFnStmt') return false;
		final owner: Null<String> = parent.name;
		final method: Null<String> = fn.name;
		return owner != null && method != null && index.subtypeDeclaresMember(owner, method);
	}

}
