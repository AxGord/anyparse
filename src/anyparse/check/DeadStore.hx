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

using Lambda;

/**
 * Per-function context for one `DeadStore` walk: the grammar-derived node-kind
 * sets, the unit's own narrowable names, the names excluded because a nested
 * closure uses them, and the reporting sink. Built once per analyzed function
 * body.
 */
private typedef LiveCtx = {
	var identKind: String;
	var interpIdentKind: Null<String>;
	var assignKind: Null<String>;
	var callKind: Null<String>;
	var safeNavKind: Null<String>;
	var writeKinds: Array<String>;
	var localDeclKinds: Array<String>;
	var mutableLocalDeclKinds: Array<String>;
	var declTypeChildKinds: Array<String>;
	var exitClearKinds: Array<String>;
	var exitTopKinds: Array<String>;
	var opaqueKinds: Array<String>;
	var scopeKinds: Array<String>;
	var loopJumpNames: Array<String>;
	var ownNames: Array<String>;
	var excluded: Array<String>;
	var file: String;
	var source: String;
	var out: Array<Violation>;
}

/**
 * Flags a **dead store**: an assignment to a local variable / parameter whose
 * value is provably never read — every path from the store reaches another
 * write to the name or the function exit without reading it. Two forms are
 * reported: a plain assignment (`x = e;` then never read) and a `var`
 * initializer reassigned before any read (`var x = e; x = f;`). Both waste the
 * computed value and usually indicate a logic slip (the wrong variable written,
 * a result computed and forgotten).
 *
 * ## Backward liveness, over-approximated
 *
 * The engine is an intra-procedural **backward liveness** walk — the dual of
 * `NullFlow`'s forward null lattice, so it lives inside this check rather than
 * extending that engine (the unit discovery, kind lists and decl helpers ARE
 * shared via `NullFlow` statics). The soundness direction is inverted
 * accordingly: every uncertainty makes MORE names live, so a report means
 * dead-on-all-paths and an uncertain store is a safe miss. Concretely:
 *
 * - **Branches** union their arms' liveness (a read in either arm keeps the
 *   store alive); an arm pair that both overwrite kills precisely.
 * - **Loops** have no fixpoint: every name read anywhere in the loop subtree
 *   stays live at the loop's boundaries and at every branch seam inside it
 *   (back-edge safety), and the pre-loop state also survives (a loop may run
 *   zero times). A reassign-then-reassign within one straight-line run is
 *   still caught. **`switch` / `try`** are seeded the same way.
 * - **`return`** clears the state (nothing after a function exit reads a
 *   local); **`throw`** instead makes every own name live — its continuation
 *   is an unmodeled `catch` that may read anything.
 * - **`break` / `continue`** (which project as plain identifier expressions
 *   named so — `RefShape.loopJumpNames`, not dedicated kinds) jump to a point
 *   this walk does not model, so they make every own name live.
 * - **Short-circuit operators** (`&&` / `||` / `??`) evaluate their right
 *   operand conditionally, so its kills never leak into the left path; the
 *   same guard covers the arguments of a call whose callee chain contains a
 *   null-safe access (`x?.m(a = 1)`, `x?.a.g(a = 1)`).
 * - **Closures**: a name a nested function value reads OR writes is excluded
 *   entirely — the closure may run at any later time.
 * - **Shadowing**: a name bound more than once in the unit (redeclaration, or
 *   a parameter shadowed by a local) is excluded entirely — name-keyed
 *   liveness cannot tell the bindings apart, and a kill on one binding could
 *   silence a read of the other.
 * - **Multi-binding declarations** (`var a = 1, b = 2;` — projected as ONE
 *   node named after the first binding) report nothing; their initializers
 *   are still folded so every read inside them counts.
 * - **Macro reification** (`RefShape.opaqueKinds`) can splice a read of
 *   anything, so it makes every own name live.
 * - **String interpolation**: a simple `'$name'` projects as a distinct
 *   identifier kind (`RefShape.stringInterpIdentKind`), counted as a read.
 *
 * Only a unit's own names (parameters plus locally-declared `var` / `final`s,
 * excluding closure-internal declarations) are ever reported — a field or
 * captured outer local has unknowable readers. Lambda-expression bodies are
 * not separate units (mirrors `NullFlow`); local named functions are.
 *
 * ## Partition with `unused-local`
 *
 * `unused-local` owns the binding **never referenced at all** (its text scan
 * counts a write as a reference, so a written-then-never-read local is NOT its
 * finding — it is this check's). A dead `var` initializer is reported only when
 * the name IS referenced elsewhere in its enclosing scope
 * (`RefactorSupport.referencedInRange`, the same test `unused-local` uses
 * inverted) — a zero-reference binding stays `unused-local`'s finding, so no
 * store is ever double-reported. A `final` initializer is never flagged: with
 * no reassignment possible, a dead final init means zero reads, which is
 * `unused-local`'s case by construction.
 *
 * `Severity.Info`, report-only: deleting a store is behavior-preserving only
 * when its right-hand side is side-effect-free — an autofix promotion can
 * follow once the engine has earned trust (the null-flow consumers' path).
 */
@:nullSafety(Strict)
final class DeadStore implements Check {

	/** Short-circuit binary kinds — the right operand evaluates conditionally, so its kills must not leak left. */
	private static final SHORT_CIRCUIT_KINDS: Array<String> = ['And', 'Or', 'NullCoal'];

	public function new() {}

	public function id(): String {
		return 'dead-store';
	}

	public function description(): String {
		return 'an assignment to a local whose value is never read on any path (dead store)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final identKind: Null<String> = shape.identKind;
		if (identKind == null) return [];
		final id: String = identKind;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree == null) continue;
			NullFlow.forEachFunctionUnit(
				tree, shape, (body, paramNames) -> analyzeBody(violations, entry.file, entry.source, body, shape, id, paramNames)
			);
		}
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/**
	 * Analyze one function body backward from an empty (nothing-live) exit state.
	 * A name bound more than once in the unit (shadowing, redeclaration, or a
	 * parameter shadowed by a local) is excluded entirely: name-keyed liveness
	 * cannot tell the bindings apart, and a kill on one could silence a read of
	 * the other — the unsound direction here (the mirror of `NullFlow`, where
	 * over-killing is safe).
	 */
	private static function analyzeBody(
		out: Array<Violation>, file: String, source: String, body: QueryNode, shape: RefShape, identKind: String,
		paramNames: Array<String>
	): Void {
		final localDeclKinds: Array<String> = shape.localDeclKinds ?? [];
		final controlExitKinds: Array<String> = shape.controlExitKinds ?? [];
		final returnKinds: Array<String> = [];
		{
			final rk: Null<String> = shape.returnStatementKind;
			if (rk != null) returnKinds.push(rk);
		}
		{
			final vk: Null<String> = shape.voidReturnKind;
			if (vk != null) returnKinds.push(vk);
		}
		final ownNames: Array<String> = paramNames.concat(NullFlow.collectDeclared(body, localDeclKinds));
		final excluded: Array<String> = collectExcluded(body, identKind, shape.stringInterpIdentKind);
		for (i in 0...ownNames.length) {
			final n: String = ownNames[i];
			if (ownNames.indexOf(n) != i && !excluded.contains(n)) excluded.push(n);
		}
		final ctx: LiveCtx = {
			identKind: identKind,
			interpIdentKind: shape.stringInterpIdentKind,
			assignKind: shape.assignKind,
			callKind: shape.callKind,
			safeNavKind: shape.nullSafeAccessKind,
			writeKinds: shape.writeParentKinds ?? [],
			localDeclKinds: localDeclKinds,
			mutableLocalDeclKinds: shape.mutableLocalDeclKinds ?? [],
			declTypeChildKinds: shape.declTypeChildKinds ?? [],
			exitClearKinds: returnKinds,
			exitTopKinds: [for (k in controlExitKinds) if (!returnKinds.contains(k)) k],
			opaqueKinds: shape.opaqueKinds ?? [],
			scopeKinds: shape.scopeKinds,
			loopJumpNames: shape.loopJumpNames ?? [],
			ownNames: ownNames,
			excluded: excluded,
			file: file,
			source: source,
			out: out
		};
		walkBack(body, [], body, ctx);
	}

	/**
	 * Walk `node` backward: `live` holds the names live at `node`'s EXIT and is
	 * mutated in place to the names live at its ENTRY. Reports fire at write
	 * sites whose target is not live. `scope` is the nearest enclosing scope
	 * node (for the decl-initializer partition test). Leaf-ish transfers live
	 * here; compound constructs dispatch through `walkConstruct`. A `return`
	 * clears the state (nothing after a function exit reads a local); a `throw`
	 * conservatively makes everything live — its continuation is an unmodeled
	 * `catch` that may read anything.
	 */
	private static function walkBack(node: QueryNode, live: Array<String>, scope: QueryNode, ctx: LiveCtx): Void {
		final kind: String = node.kind;
		if (NullFlow.META_KINDS.contains(kind)) return;
		if (ctx.opaqueKinds.contains(kind)) {
			setTop(live, ctx);
			return;
		}
		if (NullFlow.NESTED_FN_KINDS.contains(kind)) return;
		final childScope: QueryNode = ctx.scopeKinds.contains(kind) ? node : scope;
		if (kind == ctx.identKind) {
			final name: Null<String> = node.name;
			if (name != null && ctx.loopJumpNames.contains(name))
				setTop(live, ctx);
			else if (name != null)
				addLive(live, name);
			return;
		}
		if (ctx.interpIdentKind != null && kind == ctx.interpIdentKind) {
			final name: Null<String> = node.name;
			if (name != null) addLive(live, name);
			foldChildren(node, live, childScope, ctx);
			return;
		}
		if (ctx.exitClearKinds.contains(kind)) {
			live.resize(0);
			foldChildren(node, live, childScope, ctx);
			return;
		}
		if (ctx.exitTopKinds.contains(kind)) {
			setTop(live, ctx);
			foldChildren(node, live, childScope, ctx);
			return;
		}
		if (ctx.writeKinds.contains(kind) && node.children.length >= 1) {
			handleWrite(node, live, childScope, ctx);
			return;
		}
		if (ctx.localDeclKinds.contains(kind)) {
			handleDecl(node, live, childScope, ctx);
			return;
		}
		walkConstruct(node, kind, live, childScope, ctx);
	}

	/** The compound-construct half of the backward dispatch: branches, loops, branchy constructs, short-circuit operators, null-safe calls — anything else folds its children generically. */
	private static function walkConstruct(node: QueryNode, kind: String, live: Array<String>, scope: QueryNode, ctx: LiveCtx): Void {
		if (NullFlow.IF_KINDS.contains(kind) && node.children.length >= 2)
			handleIf(node, live, scope, ctx);
		else if (NullFlow.LOOP_KINDS.contains(kind))
			handleLoop(node, live, scope, ctx);
		else if (NullFlow.BRANCHY_KINDS.contains(kind))
			handleBranchy(node, live, scope, ctx);
		else if (SHORT_CIRCUIT_KINDS.contains(kind) && node.children.length == 2)
			handleShortCircuit(node, live, scope, ctx);
		else if (isSafeNavCall(node, ctx))
			handleSafeNavCall(node, live, scope, ctx);
		else
			foldChildren(node, live, scope, ctx);
	}

	/** Fold `node`'s children right-to-left (backward flow order) into the shared `live` state. */
	private static function foldChildren(node: QueryNode, live: Array<String>, scope: QueryNode, ctx: LiveCtx): Void {
		final n: Int = node.children.length;
		for (i in 0...n) walkBack(node.children[n - 1 - i], live, scope, ctx);
	}

	/**
	 * A write whose first child is the target. A plain assignment of a non-live
	 * own name is a dead store; a compound assignment / increment reads the old
	 * value, so it both keeps the name live and is never itself reported.
	 */
	private static function handleWrite(node: QueryNode, live: Array<String>, scope: QueryNode, ctx: LiveCtx): Void {
		final target: QueryNode = node.children[0];
		final name: Null<String> = target.name;
		if (target.kind != ctx.identKind || name == null) {
			foldChildren(node, live, scope, ctx);
			return;
		}
		final targetName: String = name;
		if (!ctx.ownNames.contains(targetName) || ctx.excluded.contains(targetName)) {
			foldChildren(node, live, scope, ctx);
			return;
		}
		final rhs: Null<QueryNode> = node.children.length >= 2 ? node.children[1] : null;
		if (node.kind == ctx.assignKind) {
			final span: Null<Span> = node.span;
			if (span != null && !live.contains(targetName)) ctx.out.push({
				file: ctx.file,
				span: span,
				rule: 'dead-store',
				severity: Severity.Info,
				message: 'dead store — value assigned to \'$targetName\' is never read on any path'
			});
			live.remove(targetName);
		} else {
			addLive(live, targetName);
		}
		if (rhs != null) walkBack(rhs, live, scope, ctx);
	}

	/**
	 * A local declaration: the binding is born here, so the name's liveness ends
	 * (backward). A mutable declaration whose initializer is not live is a dead
	 * store — but only when the name IS referenced elsewhere in its enclosing
	 * scope (a zero-reference binding is `unused-local`'s finding) and the
	 * declaration binds a single name (`NullFlow.isMultiBinding` — a multi-binding
	 * decl's initializers cannot be attributed to its one projected name). Every
	 * child is folded regardless, so reads inside every initializer count.
	 */
	private static function handleDecl(node: QueryNode, live: Array<String>, scope: QueryNode, ctx: LiveCtx): Void {
		final name: Null<String> = node.name;
		if (name != null && ctx.ownNames.contains(name) && !ctx.excluded.contains(name)) {
			final span: Null<Span> = node.span;
			final init: Null<QueryNode> = NullFlow.declInit(node, ctx.declTypeChildKinds);
			if (
				init != null && span != null && ctx.mutableLocalDeclKinds.contains(node.kind) && !live.contains(name)
				&& !NullFlow.isMultiBinding(node, ctx.source, ctx.declTypeChildKinds) && referencedOutsideDecl(ctx, name, scope, span)
			) ctx.out.push({
				file: ctx.file,
				span: span,
				rule: 'dead-store',
				severity: Severity.Info,
				message: 'dead store — initializer of \'$name\' is reassigned before any read'
			});
			live.remove(name);
		}
		foldChildren(node, live, scope, ctx);
	}

	/** Branch: liveness after the construct flows into each arm independently; the entry liveness is the union of the arms (plus the fall-through path when there is no else). */
	private static function handleIf(node: QueryNode, live: Array<String>, scope: QueryNode, ctx: LiveCtx): Void {
		final cond: QueryNode = node.children[0];
		final thenArm: QueryNode = node.children[1];
		final elseArm: Null<QueryNode> = node.children.length > 2 ? node.children[2] : null;
		final thenLive: Array<String> = live.copy();
		walkBack(thenArm, thenLive, scope, ctx);
		if (elseArm != null) {
			final elseLive: Array<String> = live.copy();
			walkBack(elseArm, elseLive, scope, ctx);
			live.resize(0);
			for (n in elseLive) addLive(live, n);
		}
		for (n in thenLive) addLive(live, n);
		walkBack(cond, live, scope, ctx);
	}

	/** Loop: no fixpoint — every name read anywhere in the subtree is live throughout the body (back-edge), and the exit state survives (zero iterations). */
	private static function handleLoop(node: QueryNode, live: Array<String>, scope: QueryNode, ctx: LiveCtx): Void {
		final reads: Array<String> = collectReads(node, ctx);
		final bodyLive: Array<String> = live.copy();
		for (n in reads) addLive(bodyLive, n);
		foldChildren(node, bodyLive, scope, ctx);
		for (n in bodyLive) addLive(live, n);
	}

	/** `switch` / `try`: each branch folds from the exit state plus every name read anywhere in the construct (a read in any branch keeps stores in the others alive). */
	private static function handleBranchy(node: QueryNode, live: Array<String>, scope: QueryNode, ctx: LiveCtx): Void {
		final reads: Array<String> = collectReads(node, ctx);
		final n: Int = node.children.length;
		for (i in 0...n) {
			final branchLive: Array<String> = live.copy();
			for (r in reads) addLive(branchLive, r);
			walkBack(node.children[n - 1 - i], branchLive, scope, ctx);
		}
		for (r in reads) addLive(live, r);
	}

	/** Short-circuit operator: the right operand evaluates conditionally, so its liveness result is unioned with the skip path instead of replacing it. */
	private static function handleShortCircuit(node: QueryNode, live: Array<String>, scope: QueryNode, ctx: LiveCtx): Void {
		final rhsLive: Array<String> = live.copy();
		walkBack(node.children[1], rhsLive, scope, ctx);
		for (n in rhsLive) addLive(live, n);
		walkBack(node.children[0], live, scope, ctx);
	}

	/**
	 * Whether `node` is a call whose callee chain goes through a null-safe access
	 * (`x?.m(...)`, `x?.a.g(...)`) — the whole chain short-circuits, so the
	 * arguments evaluate conditionally. The callee SUBTREE is scanned: a `?.`
	 * at any depth makes the call conditional (over-approximate, safe).
	 */
	private static function isSafeNavCall(node: QueryNode, ctx: LiveCtx): Bool {
		final navKind: Null<String> = ctx.safeNavKind;
		return ctx.callKind != null && node.kind == ctx.callKind && node.children.length >= 2 && navKind != null
			&& containsKind(node.children[0], navKind);
	}

	/** Whether `node`'s subtree contains a node of `kind`. */
	private static function containsKind(node: QueryNode, kind: String): Bool {
		if (node.kind == kind) return true;
		for (c in node.children) if (containsKind(c, kind)) return true;
		return false;
	}

	/** A null-safe call: fold the conditionally-evaluated arguments in isolation and union, then the callee (whose receiver read is unconditional). */
	private static function handleSafeNavCall(node: QueryNode, live: Array<String>, scope: QueryNode, ctx: LiveCtx): Void {
		final argsLive: Array<String> = live.copy();
		final n: Int = node.children.length;
		for (i in 0...n - 1) walkBack(node.children[n - 1 - i], argsLive, scope, ctx);
		for (r in argsLive) addLive(live, r);
		walkBack(node.children[0], live, scope, ctx);
	}

	/** The decl-initializer partition test: is `name` referenced in the enclosing scope outside the declaration itself (`unused-local`'s own test, inverted)? */
	private static function referencedOutsideDecl(ctx: LiveCtx, name: String, scope: QueryNode, declSpan: Span): Bool {
		final scopeSpan: Null<Span> = scope.span;
		if (scopeSpan == null) return false;
		return RefactorSupport.referencedInRange(ctx.source, name, scopeSpan.from, scopeSpan.to, [declSpan]);
	}

	/** Make every own name live — the conservative TOP used at loop jumps and opaque subtrees. */
	private static function setTop(live: Array<String>, ctx: LiveCtx): Void {
		for (n in ctx.ownNames) addLive(live, n);
	}

	/** Add `name` to the live set, deduplicated. */
	private static inline function addLive(live: Array<String>, name: String): Void {
		if (!live.contains(name)) live.push(name);
	}

	/** Every identifier name occurring anywhere in `node`'s subtree (including nested functions and write targets — over-counting reads only ever loses precision, never soundness). */
	private static function collectReads(node: QueryNode, ctx: LiveCtx): Array<String> {
		final out: Array<String> = [];
		function walkR(n: QueryNode): Void {
			final name: Null<String> = n.name;
			if (
				name != null && (n.kind == ctx.identKind || (ctx.interpIdentKind != null && n.kind == ctx.interpIdentKind))
				&& !out.contains(name)
			)
				out.push(name);
			for (c in n.children) walkR(c);
		}
		walkR(node);
		return out;
	}

	/** The names a nested function value reads or writes — excluded from the whole unit's analysis (the closure may run at any later time). */
	private static function collectExcluded(body: QueryNode, identKind: String, interpIdentKind: Null<String>): Array<String> {
		final out: Array<String> = [];
		function collectNames(n: QueryNode): Void {
			final name: Null<String> = n.name;
			if (name != null && (n.kind == identKind || (interpIdentKind != null && n.kind == interpIdentKind)) && !out.contains(name))
				out.push(name);
			for (c in n.children) collectNames(c);
		}
		function walkB(n: QueryNode): Void {
			if (NullFlow.NESTED_FN_KINDS.contains(n.kind))
				collectNames(n);
			else
				for (c in n.children) walkB(c);
		}
		walkB(body);
		return out;
	}

}
