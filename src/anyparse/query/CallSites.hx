package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.runtime.Span;
import anyparse.runtime.Span.Position;

using Lambda;

/**
 * Collected in-file call sites or a completeness diagnostic — the result
 * of `CallSites.collect`. `COk` carries the proven-complete set of `Call`
 * nodes that target the function; `CErr` carries the human-readable reason
 * the set could not be proven complete (an unresolvable bare call, a
 * receiver-qualified `obj.foo(...)`, a value-captured reference, or an
 * ambiguous local-function name). Modelled as a sum type so each consumer
 * pattern-matches without a sentinel-array convention.
 */
enum CollectResult {

	COk(sites: Array<QueryNode>);
	CErr(message: String);

}

/**
 * Shared call-site resolution + completeness proof for the function-level
 * refactoring operations that must rewrite a function's call sites in
 * lock-step with its declaration (`ChangeSig` reorders the positional
 * arguments; `RemoveParam` deletes one). Both need the IDENTICAL guarantee:
 * the set of in-file calls is PROVEN complete, because their failure mode
 * is SILENT — a missed call keeps the old argument shape against the new
 * parameters — so any call that cannot be proven to target this function
 * is a hard refusal.
 *
 * The machinery was lifted verbatim out of `ChangeSig` once `RemoveParam`
 * needed the same resolution; keeping it here means the two operations
 * cannot drift apart in what they accept and refuse.
 *
 * Two declaration kinds collect differently because the `Refs` resolver
 * indexes methods but not local functions:
 *
 *  - `FnMember` / `FinalModifiedMember` (method, plain or `final`): bare
 *    `name(...)` calls resolve through `Refs` to the decl binding — the
 *    query projection surfaces a `final` method's name off the inner
 *    `HxFinalModifierMember.fn`, so `Refs` indexes it as a decl exactly
 *    like a plain method; `this.name(...)` calls are matched structurally
 *    (a `FieldAccess` named `name` whose receiver is `this`), exactly like
 *    `Rename`'s `this.<name>` handling. Any `obj.name(...)` (non-`this`
 *    receiver) or unresolved bare call is a refusal. A method may have
 *    callers in OTHER files we cannot see — the caller decides whether to
 *    surface a cross-file advisory.
 *  - `LocalFnStmt` (local function): `Refs` does not index local
 *    functions, so a bare call's binding comes back unresolved and cannot
 *    be told apart from an unrelated unresolved call. The collector
 *    instead requires the function name to be UNIQUE among the file's
 *    declarations; with uniqueness proven, every bare `name(...)` call in
 *    the file unambiguously targets this local function. A
 *    receiver-qualified `*.name(...)` call is then impossible for the same
 *    name and is refused. A local function cannot escape its file, so the
 *    call set is complete and no advisory is needed.
 */
@:nullSafety(Strict)
final class CallSites {

	/** Parameter slot kinds — the leading children of a function decl. */
	public static final PARAM_KINDS: Array<String> = ['Required', 'Optional'];

	/**
	 * Declaration kinds that, if any node of one carries the same name as
	 * the target local function, make a bare `name(...)` call ambiguous —
	 * so a `LocalFnStmt` collection refuses unless its name is unique
	 * across all of these. Covers every binding a bare identifier could
	 * resolve to: other local functions, class members, top-level
	 * functions, and local var / final / param bindings.
	 */
	public static final NAME_CLASH_KINDS: Array<String> = [
		'LocalFnStmt',
		'FnMember',
		'FinalModifiedMember',
		'VarMember',
		'FinalMember',
		'FnField',
		'VarField',
		'FinalField',
		'FnDecl',
		'VarDecl',
		'VarStmt',
		'FinalStmt',
		'StaticVarStmt',
		'StaticFinalStmt',
		'Required',
		'Optional',
		'Rest',
	];

	/**
	 * The function declaration node the cursor identifies. When the cursor
	 * already sits on a `FnMember` / `FinalModifiedMember` / `LocalFnStmt`
	 * decl, that node is returned directly. Otherwise the cursor is on a
	 * call / reference and the binding is resolved back to its decl through
	 * the shared resolver: `resolveBindingFrom` yields the decl's
	 * `span.from`, and `nodeAtFrom` looks the decl node up by that offset.
	 * Returns null when nothing resolves.
	 */
	public static function resolveFnDecl(cursorNode: QueryNode, tree: QueryNode, name: String, shape: RefShape): Null<QueryNode> {
		if (RefactorSupport.FN_DECL_KINDS.contains(cursorNode.kind)) return cursorNode;

		final hits: Array<RefHit> = Refs.find(name, tree, shape);
		final bindingFrom: Null<Int> = RefactorSupport.resolveBindingFrom(cursorNode, hits);
		return bindingFrom == null ? null : RefactorSupport.nodeAtFrom(tree, bindingFrom);
	}

	/**
	 * The leading `Required` / `Optional` children of `decl`, in source
	 * order. The scan stops at the first child that is neither — the
	 * `Named` return-type child or the function body — so the return type
	 * is never mistaken for a parameter.
	 */
	public static function leadingParams(decl: QueryNode): Array<QueryNode> {
		final out: Array<QueryNode> = [];
		for (child in decl.children) {
			if (!PARAM_KINDS.contains(child.kind)) break;
			out.push(child);
		}
		return out;
	}

	/**
	 * Collect every in-file call site of the function declared at `decl`
	 * and PROVE the set is complete. Routes by declaration kind: a class
	 * method (`FnMember` or the `final` form `FinalModifiedMember`) uses
	 * the `Refs`-bound collector; a `LocalFnStmt` takes the
	 * uniqueness-based local-function path. `binding` is the decl's
	 * `span.from`. Returns `COk(sites)` with the proven-complete set or
	 * `CErr(message)` describing why the set could not be proven complete.
	 */
	public static function collect(
		decl: QueryNode, tree: QueryNode, source: String, name: String, binding: Int, shape: RefShape
	): CollectResult {
		final isMethod: Bool = decl.kind != 'LocalFnStmt';
		return isMethod ? collectMethodCalls(tree, source, name, binding, shape) : collectLocalFnCalls(tree, source, name);
	}

	/**
	 * Collect a method's in-file call sites and prove the set complete.
	 *
	 *  - Bare `name(...)` calls: every `Read` hit bound to `binding` whose
	 *    enclosing `Call` has an `IdentExpr name` callee at the hit's span.
	 *  - `this.name(...)` calls: matched structurally — a `Call` whose
	 *    callee is a `FieldAccess name` with an `IdentExpr this` receiver.
	 *
	 * Completeness scan: every `Call` callee named `name` must be in one
	 * of those two sets. A bare callee binding to a DIFFERENT decl is a
	 * different function (ignored); a bare callee with no resolvable
	 * binding, or an `obj.name(...)` call with a non-`this` receiver, is a
	 * refusal — those could be this very function but cannot be proven, so
	 * silently leaving their argument shape stale is not allowed.
	 */
	private static function collectMethodCalls(tree: QueryNode, source: String, name: String, binding: Int, shape: RefShape): CollectResult {
		final hits: Array<RefHit> = Refs.find(name, tree, shape);
		final boundReads: Array<RefHit> = [
			for (h in hits)
				if (h.kind == RefKind.Read && h.bindingSpan != null && bindingFrom(h) == binding) h
		];
		final boundReadFroms: Array<Int> = [for (h in boundReads) h.span.from];

		final sites: Array<QueryNode> = [];
		final consumedFroms: Array<Int> = [];
		var thisSiteCount: Int = 0;
		var error: Null<String> = null;
		function walk(node: QueryNode): Void {
			if (error != null) return;
			if (node.kind == 'Call' && node.children.length > 0) {
				final callee: QueryNode = node.children[0];
				switch calleeShape(callee, name) {
					case CalleeBare(identSpan):
						// A bare `name(...)` call. It is OUR call iff its
						// callee identifier read binds to `binding`.
						if (boundReadFroms.contains(identSpan.from)) {
							sites.push(node);
							consumedFroms.push(identSpan.from);
						} else if (!bareBindsElsewhere(identSpan, hits))
							error = 'cannot prove all call sites target "$name": unresolved call at ${posOf(source, node.span)} — every call site must be resolvable';
					case CalleeThis:
						sites.push(node);
						thisSiteCount++;
					case CalleeOtherReceiver(recv):
						error = 'cannot resolve receiver-qualified call `$recv.$name(...)` at ${posOf(source, node.span)} — every call site must be resolvable (supported for local functions and methods called only via bare `$name(...)` / `this.$name(...)`)';
					case CalleeNone:
				}
			}
			for (c in node.children) {
				if (error != null) return;
				walk(c);
			}
		}
		walk(tree);
		// Refuse the method captured as a first-class value, whose indirect
		// calls cannot be tracked — rewriting its decl would silently break
		// them. Three capture forms: a bare `var fn = foo;` (a binding read
		// not consumed as a call callee), a `var f = this.foo;` (a
		// `this.foo` field access beyond the `this.foo(...)` call count),
		// and a `var f = obj.foo;` (any non-`this` receiver field access —
		// its call form already errored above).
		if (error == null) {
			final dangling: Null<RefHit> = boundReads.find(h -> !consumedFroms.contains(h.span.from));
			if (dangling != null)
				error = '"$name" is referenced as a value (not called) at ${posOf(source, dangling.span)} — indirect calls through a captured reference cannot be tracked';
		}
		if (error == null) error = fieldAccessValueCapture(tree, source, name, thisSiteCount);
		return error != null ? CErr(error) : COk(sites);
	}

	/**
	 * Detect a method captured as a value via a field access — a
	 * `this.name` / `obj.name` `FieldAccess` that is not a call callee. A
	 * non-`this` receiver field access is always a refusal (its call form
	 * has already errored, so any remaining one is a value capture); a
	 * `this.name` field access is a refusal only for the surplus beyond
	 * the `this.name(...)` call sites (each call contributes exactly one
	 * `this.name` access). Returns the diagnostic or null when no value
	 * capture is present.
	 */
	private static function fieldAccessValueCapture(tree: QueryNode, source: String, name: String, thisSiteCount: Int): Null<String> {
		var thisAccess: Int = 0;
		var error: Null<String> = null;
		function scan(node: QueryNode): Void {
			if (error != null) return;
			if (node.kind == 'FieldAccess' && node.name == name && node.children.length > 0) {
				final recv: QueryNode = node.children[0];
				if (recv.kind == 'IdentExpr' && recv.name == 'this')
					thisAccess++;
				else
					error = '"$name" is referenced as a value (not called) at ${posOf(source, node.span)} — indirect calls through a captured reference cannot be tracked';
			}
			for (c in node.children) scan(c);
		}
		scan(tree);
		return error ?? (thisAccess > thisSiteCount
			? '"$name" is referenced as a value (not called) via `this.$name` — indirect calls through a captured reference cannot be tracked'
			: null);
	}

	/**
	 * Collect a local function's in-file call sites. `Refs` does not index
	 * local functions, so the name's UNIQUENESS across the file's
	 * declarations is required first (any clashing declaration makes a bare
	 * `name(...)` ambiguous). With uniqueness proven, every bare
	 * `name(...)` call in the file targets this function, and a
	 * receiver-qualified `*.name(...)` call is impossible for that name and
	 * is refused.
	 */
	private static function collectLocalFnCalls(tree: QueryNode, source: String, name: String): CollectResult {
		final clashes: Int = countNameDecls(tree, name);
		if (clashes > 1)
			return
				CErr(
					'cannot prove all call sites target the local function "$name": another declaration named "$name" exists — refused when a local-function name is ambiguous'
				);

		final sites: Array<QueryNode> = [];
		var error: Null<String> = null;
		function walk(node: QueryNode): Void {
			if (error != null) return;
			if (node.kind == 'Call' && node.children.length > 0) {
				final callee: QueryNode = node.children[0];
				switch calleeShape(callee, name) {
					case CalleeBare(_):
						sites.push(node);
					case CalleeThis:
						error = 'cannot resolve `this.$name(...)` at ${posOf(source, node.span)} — `$name` is a local function, not a method';
					case CalleeOtherReceiver(recv):
						error = 'cannot resolve receiver-qualified call `$recv.$name(...)` at ${posOf(source, node.span)} — `$name` is a local function and cannot be called through a receiver';
					case CalleeNone:
				}
			}
			for (c in node.children) {
				if (error != null) return;
				walk(c);
			}
		}
		walk(tree);
		// With the name proven unique, every `IdentExpr` named `name` is a
		// reference to this local function. Each bare CALL contributes
		// exactly one such ident (its callee); a surplus is a non-call
		// value reference whose indirect calls cannot be tracked.
		if (error == null && countIdentExprNamed(tree, name) > sites.length)
			error = 'the local function "$name" is referenced as a value (not called) — indirect calls through a captured reference cannot be tracked';
		return error != null ? CErr(error) : COk(sites);
	}

	/**
	 * Classify a `Call`'s callee node relative to the target `name`:
	 * a bare `IdentExpr name` (with its span), a `this.name` field access,
	 * an `obj.name` field access on a non-`this` receiver (with the
	 * receiver's display name), or none of these (a call to something
	 * else).
	 */
	private static function calleeShape(callee: QueryNode, name: String): CalleeShape {
		if (callee.kind == 'IdentExpr' && callee.name == name) {
			final span: Null<Span> = callee.span;
			return span == null ? CalleeNone : CalleeBare(span);
		}
		if (callee.kind == 'FieldAccess' && callee.name == name && callee.children.length > 0) {
			final recv: QueryNode = callee.children[0];
			if (recv.kind == 'IdentExpr' && recv.name == 'this') return CalleeThis;
			final recvName: String = recv.name ?? recv.kind;
			return CalleeOtherReceiver(recvName);
		}
		return CalleeNone;
	}

	/**
	 * Does the bare callee identifier at `identSpan` resolve to a binding
	 * (a different same-named function)? True ⇒ the call belongs to that
	 * other function and is safely ignored. False ⇒ the callee has no
	 * resolvable binding at all, so it cannot be proven NOT to be ours.
	 * `hits` is the already-computed `Refs.find(name, …)` result for the
	 * target name — reused so the resolver is not re-run per call site.
	 */
	private static function bareBindsElsewhere(identSpan: Span, hits: Array<RefHit>): Bool {
		final hit: Null<RefHit> = hits.find(h -> h.span.from == identSpan.from);
		return hit != null && hit.bindingSpan != null;
	}

	/** Count declarations named `name` anywhere in the tree. */
	private static function countNameDecls(tree: QueryNode, name: String): Int {
		var count: Int = 0;
		function walk(node: QueryNode): Void {
			if (node.name == name && NAME_CLASH_KINDS.contains(node.kind)) count++;
			for (c in node.children) walk(c);
		}
		walk(tree);
		return count;
	}

	/** Count `IdentExpr` nodes named `name` anywhere in the tree. */
	private static function countIdentExprNamed(tree: QueryNode, name: String): Int {
		var count: Int = 0;
		function walk(node: QueryNode): Void {
			if (node.kind == 'IdentExpr' && node.name == name) count++;
			for (c in node.children) walk(c);
		}
		walk(tree);
		return count;
	}

	/** `from` offset of a Read / Write hit's binding span (caller null-checks). */
	private static inline function bindingFrom(hit: RefHit): Int {
		final b: Null<Span> = hit.bindingSpan;
		return b == null ? -1 : b.from;
	}

	/** Human-facing `line:col` for a span, in the `apq refs` print convention. */
	public static function posOf(source: String, span: Null<Span>): String {
		if (span == null) return '?:?';
		final pos: Position = span.lineCol(source);
		return '${pos.line}:${pos.col}';
	}

}

/** Classification of a `Call`'s callee relative to the target name — internal. */
private enum CalleeShape {

	CalleeBare(identSpan: Span);
	CalleeThis;
	CalleeOtherReceiver(recv: String);
	CalleeNone;

}
