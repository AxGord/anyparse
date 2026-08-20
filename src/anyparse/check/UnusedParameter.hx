package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.Violation;
import anyparse.query.CallSites;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.RemoveParam;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * Flags a function parameter whose name is never referenced in the function —
 * a dead parameter, or a hint of a stale signature. Purely structural (no type
 * information), so it holds without a type-checker.
 *
 * `Warning` (with a `--fix`) for the provably-safe subset — a named local
 * function, or a confined private method (`isPrivateMemberConfined`) — whose
 * call set can be proven complete WITHIN one file by the shared
 * `RemoveParam.paramSlotEdits` core; `fix` removes the parameter and its
 * argument at every in-file call site (one per function per pass). A public or
 * otherwise unconfined method whose call set cannot be proven complete stays
 * `Info` — removal is a cross-file signature change, performed manually through
 * the `remove-param` op and its advisory.
 *
 * An `Info` finding is REPORT-ONLY by default. A project that sets the
 * `renameSilence` option (`apqlint.json`, default false) additionally gets the
 * conservative `_<name>` silence-rename: a decl-site-only edit that is
 * cross-file-safe (a parameter name is never part of a caller's syntax — Haxe
 * has no named arguments) and skipped on a `_<name>` collision. It is opt-in
 * because it only HIDES the finding — it removes no dead weight and changes no
 * behaviour — so a blanket `--fix` must not rewrite every signature the removal
 * proof could not complete.
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
 *  - A function CAPTURED AS A VALUE in the same file (`valueCapturedNames`) —
 *    its name referenced outside callee position: passed as an argument
 *    (`addEventListener(E, onFoo)`), assigned to a var / field, returned, or
 *    `.bind`-partialled. Whatever consumes the reference fixes the signature, so
 *    an ignored parameter there is mandated, not dead, and the finding is not
 *    actionable — it is dropped entirely rather than reported as `Info`. A callee
 *    the call site COMPUTES rather than names (`(cond ? f : g)(x)`, a cast) is a
 *    capture too — the functions are selected between as values; a merely
 *    parenthesised callee (`(f)(x)`) is not. The `Warning` arm is untouched:
 *    `CallSites` already refuses a value-captured function, so such a parameter
 *    was never autofixable, and the gate is applied only to what would otherwise
 *    be `Info`.
 *
 * The residual false positive a structural, file-scoped check cannot rule out is
 * a method captured as a fixed-signature callback in ANOTHER file — the
 * in-file capture scan cannot see it, so its unread parameter is still reported
 * as `Info`. A public method only ever called directly, the case the rule is for,
 * is reported for the same reason.
 */
@:nullSafety(Strict)
final class UnusedParameter implements Check implements ConfigAware {

	/** The rule id — also the `apqlint.json` key its options are read under. */
	private static inline final RULE_ID: String = 'unused-parameter';

	/**
	 * Whether an `Info` finding carries the conservative `_<name>` silence-rename fix,
	 * unless an `apqlint.json` sets `renameSilence`. Default FALSE: the rename only
	 * HIDES the finding — it removes no dead weight and changes no behaviour — so a
	 * blanket `--fix` must not rewrite every signature the removal proof cannot
	 * complete; a project opts into that edit deliberately.
	 */
	private static inline final DEFAULT_RENAME_SILENCE: Bool = false;

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function id(): String {
		return RULE_ID;
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
			final captured: Array<String> = valueCapturedNames(tree);
			for (c in candidates)
				checkFunction(
					violations, entry.file, entry.source, c.fn, c.parent, tree, visibilityKinds, modifierKinds, dynamicKind, shape, index,
					captured
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
	 * proof and removes the next. An `Info` unused parameter (a signature the removal
	 * proof cannot complete) is instead RENAMED to `_<name>` — a decl-site-only,
	 * cross-file-safe silencing, skipped on a `_<name>` name collision — but ONLY when
	 * the file's `apqlint.json` opts in via `renameSilence`; the default is no edit at
	 * all for the `Info` bucket. The two edit sets are disjoint (a function's flagged
	 * parameters share its removability).
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final shape: RefShape = plugin.refShape();
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		// A finding's severity IS the fix dispatch: `Warning` = a provably-removable
		// parameter (an eligible local / confined-private method with a complete in-file
		// call set), removed by `collectFixEdits`; `Info` = a public / unconfined method,
		// silenced by the conservative `_`-prefix rename in `collectRenameEdits` when
		// `renameSilence` is opted in. The two sets never overlap within one function —
		// a function's flagged parameters share its removability — so their edits are
		// disjoint.
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
		if (renameFlagged.length > 0 && renameSilenceEnabled(violations)) {
			final functionKinds: Array<String> = shape.functionKinds ?? [];
			final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
			if (functionKinds.length > 0) collectRenameEdits(tree, null, source, functionKinds, opaqueKinds, renameFlagged, index, edits);
		}
		return RefactorSupport.dropContainedEdits(edits);
	}

	/**
	 * Whether the `_<name>` silence-rename is enabled for the file these `violations`
	 * belong to — the rule's `apqlint.json` `renameSilence` option, defaulting to
	 * `DEFAULT_RENAME_SILENCE`. `fix` is called with ONE file's findings, so the first
	 * one names the file whose config governs the batch; an empty batch cannot produce
	 * a rename edit anyway and takes the default.
	 */
	private function renameSilenceEnabled(violations: Array<Violation>): Bool {
		return violations.length == 0
			? DEFAULT_RENAME_SILENCE
			: renameSilenceLive(LintConfig.resolveWith(_resolveConfig, violations[0].file));
	}

	/**
	 * Whether `config` opts the `_<name>` silence-rename in — the ONE seat for the option
	 * key and its default, so a cross-rule guard cannot drift from the rule it guards
	 * (`NoUnderscorePrefix` reads it to decide whether the rename it must not fight is live).
	 */
	private static function renameSilenceLive(config: LintConfig): Bool {
		return config.boolOption(RULE_ID, 'renameSilence') ?? DEFAULT_RENAME_SILENCE;
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
		return parent.children.exists(c -> supertypeClauseKinds.contains(c.kind));
	}

	/** Whether `fn` is a body-less declaration (an interface / abstract method). */
	private static function hasNoBody(fn: QueryNode, noBodyKind: Null<String>): Bool {
		return noBodyKind != null && fn.children.exists(c -> c.kind == noBodyKind);
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
	 * with its cross-file advisory, EXCEPT a function whose name is in `captured`
	 * (referenced as a value somewhere in the file): its signature is fixed from
	 * outside, so the `Info` finding would not be actionable and is dropped. The
	 * `Warning` arm ignores `captured` — a value-captured function never passes the
	 * removal proof anyway.
	 */
	private static function checkFunction(
		out: Array<Violation>, file: String, source: String, fn: QueryNode, parent: QueryNode, tree: QueryNode,
		visibilityKinds: Array<String>, modifierKinds: Array<String>, dynamicKind: Null<String>, shape: RefShape, index: SymbolIndex,
		captured: Array<String>
	): Void {
		final fnSpan: Null<Span> = fn.span;
		if (fnSpan == null) return;
		if (isDynamicFn(fn, parent, visibilityKinds, modifierKinds, dynamicKind)) return;
		final fnName: Null<String> = fn.name;
		final isLocal: Bool = fn.kind == 'LocalFnStmt';
		final ownerName: Null<String> = parent.name;
		final eligible: Bool = isLocal
			|| (ownerName != null && !isPublicDecl(fn, parent, source, visibilityKinds, modifierKinds)
				&& RefactorSupport.isPrivateMemberConfined(ownerName, fnName ?? '', source, index));
		final capturedAsValue: Bool = fnName != null && captured.contains(fnName);
		final params: Array<QueryNode> = CallSites.leadingParams(fn);
		for (pi => p in params) {
			final name: Null<String> = p.name;
			final pspan: Null<Span> = p.span;
			if (name == null || pspan == null) continue;
			if (StringTools.startsWith(name, '_')) continue;
			if (RefactorSupport.referencedInRange(source, name, fnSpan.from, fnSpan.to, [pspan])) continue;
			final autofixable: Bool = eligible && fnName != null
				&& RemoveParam.paramSlotEdits(source, tree, fn, pi, fnName, fnSpan.from, shape).error == null;
			if (!autofixable && capturedAsValue) continue;
			out.push({
				file: file,
				span: pspan,
				rule: RULE_ID,
				severity: autofixable ? Severity.Warning : Severity.Info,
				message: 'unused parameter \'$name\''
			});
		}
	}

	/**
	 * Every name the module references in VALUE position — a bare `IdentExpr`, or a
	 * `this.<name>` field access, that is NOT the callee of a call. A function whose
	 * name is in this set is captured as a value somewhere in the file (passed as an
	 * argument to `addEventListener` and friends, assigned to a var / field, returned,
	 * `.bind`-partialled), which fixes its signature from OUTSIDE: the parameter its
	 * body ignores is mandated by whatever consumes the reference, so the finding is
	 * not actionable and is dropped rather than reported.
	 *
	 * The scan is by NAME only — no binding resolution — so an unrelated identifier
	 * that merely shares a function's name silences it too. That is the conservative
	 * direction: it only ever drops a finding, never invents one. It is also
	 * FILE-scoped, so a capture living in another file is invisible; a public method
	 * only ever CALLED in its own file keeps its `Info` finding, as intended.
	 *
	 * A `<other>.<name>` field access is deliberately NOT counted — a member of an
	 * unrelated receiver shares nothing with the function but its spelling.
	 *
	 * Callee position propagates through a `ParenExpr` — `(foo)(x)` is a direct call,
	 * not a capture. It deliberately does NOT propagate through any construct that
	 * COMPUTES the callee (a ternary, a cast, an index access): `(cond ? f : g)(x)`
	 * hands both functions to an expression that selects between them as values, which
	 * is a capture in every sense that matters here.
	 */
	private static function valueCapturedNames(tree: QueryNode): Array<String> {
		final out: Array<String> = [];
		function scan(node: QueryNode, calleePosition: Bool): Void {
			final name: Null<String> = node.name;
			if (!calleePosition && name != null && !out.contains(name) && isValueReference(node)) out.push(name);
			final isCall: Bool = node.kind == 'Call';
			final parenthesizedCallee: Bool = calleePosition && node.kind == 'ParenExpr';
			for (i in 0...node.children.length) scan(node.children[i], parenthesizedCallee || (isCall && i == 0));
		}
		scan(tree, false);
		return out;
	}

	/** Whether `node` is one of the two reference forms a value capture takes: a bare identifier, or a `this.<name>` field access. */
	private static function isValueReference(node: QueryNode): Bool {
		if (node.kind == 'IdentExpr') return true;
		if (node.kind != 'FieldAccess' || node.children.length == 0) return false;
		final receiver: QueryNode = node.children[0];
		return receiver.kind == 'IdentExpr' && receiver.name == 'this';
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
			if (visibilityKinds.contains(sib.kind) && sspan != null && source.substring(sspan.from, sspan.to).trim() == 'public')
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
					if (pspan == null || !flagged.contains('${pspan.from}:${pspan.to}')) continue;
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
		for (c in node.children) collectFixEdits(c, root, source, shape, flagged, handled, edits);
	}


	/**
	 * Rename every `Info` (non-removable) unused parameter to `_<name>` — the
	 * conservative silencing fix, reached only when the file opts into
	 * `renameSilence`, for a parameter that cannot be safely removed (a public /
	 * unconfined method whose call set is not provably complete). Only the
	 * DECLARATION site is edited: an unused
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
		return if (pspan == null)
			-1
		else if (StringTools.startsWith(name, '_'))
			-1
		else if (RefactorSupport.referencedInRange(source, '_$name', fnSpan.from, fnSpan.to, []))
			-1
		else if (RefactorSupport.referencedInRange(source, name, fnSpan.from, fnSpan.to, [pspan]))
			-1
		else
			firstIdentOccurrence(source, name, pspan.from, pspan.to);
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
			final beforeOk: Bool = at == 0 || !RefactorSupport.isIdentChar(source.fastCodeAt(at - 1));
			final afterIdx: Int = at + len;
			final afterOk: Bool = afterIdx >= source.length || !RefactorSupport.isIdentChar(source.fastCodeAt(afterIdx));
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
