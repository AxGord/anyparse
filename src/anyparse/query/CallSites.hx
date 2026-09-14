package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

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

/** The function a cursor resolves to, with the tree it lives in and the name it was resolved by. */
typedef CursorFn = {
	final tree: QueryNode;
	final decl: QueryNode;
	final name: String;
};

/**
 * Outcome of `CallSites.resolveFnAtCursor`: the resolved function, or the diagnostic the calling op reports
 * verbatim (an unparseable source, a cursor on nothing named, a name that binds to no declaration).
 */
enum CursorFnResult {

	FnAt(fn: CursorFn);
	FnAtErr(message: String);

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
 * indexes methods but not local functions, and the split is read off the
 * grammar's `localFunctionKinds` rather than named here:
 *
 *  - a METHOD (plain or in whatever spelling the grammar gives a `final`
 *    one): bare `name(...)` calls resolve through `Refs` to the decl
 *    binding — the query projection surfaces a `final` method's name off
 *    its inner function node, so `Refs` indexes it as a decl exactly like
 *    a plain method; `this.name(...)` calls are matched structurally (a
 *    field access named `name` whose receiver is the grammar's
 *    `selfReferenceText`), exactly like `Rename`'s handling. Any
 *    `obj.name(...)` (other receiver) or unresolved bare call is a
 *    refusal. A method may have callers in OTHER files we cannot see —
 *    the caller decides whether to surface a cross-file advisory.
 *  - a LOCAL FUNCTION: `Refs` does not index them, so a bare call's
 *    binding comes back unresolved and cannot be told apart from an
 *    unrelated unresolved call. The collector instead requires the
 *    function name to be UNIQUE among the file's declarations
 *    (`nameClashKinds`); with uniqueness proven, every bare `name(...)`
 *    call in the file unambiguously targets this local function. A
 *    receiver-qualified `*.name(...)` call is then impossible for the same
 *    name and is refused. A local function cannot escape its file, so the
 *    call set is complete and no advisory is needed.
 *
 * Every node kind and identifier text this module decides by is read off
 * the handed `RefShape`; none is spelled here. The vocabulary a completeness
 * PROOF rests on is exactly the vocabulary that must not be allowed to go
 * quietly stale, and a name in a private array is checked by nothing —
 * `nameClashKinds` used to be a seventeen-name one, missing eleven binder
 * spellings the language has.
 */
@:nullSafety(Strict)
final class CallSites {

	/**
	 * Parse `source` and resolve the function whose declaration or bare call is at `line:col` (1-based, as
	 * `apq refs` prints them) — the prologue `ChangeSig` and `RemoveParam` share, so the two cannot drift in
	 * what they accept. The kind check on the resolved declaration stays with the caller: its message names
	 * the op.
	 */
	public static function resolveFnAtCursor(source: String, line: Int, col: Int, plugin: GrammarPlugin, shape: RefShape): CursorFnResult {
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: ParseError) return FnAtErr(
			'source does not parse: $exception'
		)
		catch (exception: Exception) return FnAtErr('source does not parse: ${exception.message}');
		final cursor: Int = Span.offsetOf(source, line, col);
		final node: Null<QueryNode> = RefactorSupport.resolveCursorNode(tree, cursor, source);
		if (node == null) return FnAtErr('position $line:$col is not on a function or a call');
		final targetName: Null<String> = node.name;
		if (targetName == null) return FnAtErr('position $line:$col is not on a function or a call');
		final name: String = targetName;
		final declNode: Null<QueryNode> = resolveFnDecl(node, tree, name, shape);
		if (declNode == null) return FnAtErr('could not resolve a function binding for "$name" at $line:$col');
		// Re-bound to non-null locals: the narrowing does not reach into the struct literal.
		final decl: QueryNode = declNode;
		return FnAt({ tree: tree, decl: decl, name: name });
	}

	/**
	 * The function declaration node the cursor identifies. When the cursor
	 * already sits on a function declaration (`MemberKinds.FN_DECL_KINDS` — the
	 * methods and the named local function), that node is returned directly.
	 * Otherwise the cursor is on a call / reference and the binding is resolved
	 * back to its decl through the shared resolver: `resolveBindingFrom` yields
	 * the decl's `span.from`, and `nodeAtFrom` looks the decl node up by that
	 * offset. Returns null when nothing resolves.
	 */
	public static function resolveFnDecl(cursorNode: QueryNode, tree: QueryNode, name: String, shape: RefShape): Null<QueryNode> {
		if (MemberKinds.FN_DECL_KINDS.contains(cursorNode.kind)) return cursorNode;

		final hits: Array<RefHit> = Refs.find(name, tree, shape);
		final bindingFrom: Null<Int> = RefactorSupport.resolveBindingFrom(cursorNode, hits);
		return bindingFrom == null ? null : RefactorSupport.nodeAtFrom(tree, bindingFrom);
	}

	/**
	 * The leading POSITIONAL parameter children of `decl`, in source order
	 * (`positionalParamKinds`). The scan stops at the first child that is not
	 * one — the return-type child, the function body, or a variadic tail — so
	 * neither the return type nor a rest parameter is ever handed to an
	 * operation that rewrites parameters by index.
	 */
	public static function leadingParams(decl: QueryNode, shape: RefShape): Array<QueryNode> {
		final positional: Array<String> = positionalParamKinds(shape);
		final out: Array<QueryNode> = [];
		for (child in decl.children) {
			if (!positional.contains(child.kind)) break;
			out.push(child);
		}
		return out;
	}

	/**
	 * Collect every in-file call site of the function declared at `decl` and
	 * PROVE the set is complete. Routes by declaration kind: a local function
	 * (the grammar's `localFunctionKinds`) takes the uniqueness-based path,
	 * anything else is a method and uses the `Refs`-bound collector. `binding`
	 * is the decl's `span.from`. Returns `COk(sites)` with the proven-complete
	 * set or `CErr(message)` describing why the set could not be proven
	 * complete.
	 */
	public static function collect(
		decl: QueryNode, tree: QueryNode, source: String, name: String, binding: Int, shape: RefShape
	): CollectResult {
		// The completeness proof is what every consumer buys here, and an unparsed
		// conditional-compilation region defeats it by construction: a call written inside one
		// projects no node, so both collectors report a set that is complete only for the builds
		// that strip the region. Refused before either runs - the shape neither can see.
		final opaque: Null<String> = CondRegionScan.opaqueCondRegionDiagnostic(source, tree, name, shape, 'rewriting calls of "$name"');
		if (opaque != null) return CErr(opaque);
		final unspellable: Null<String> = missingCallVocabulary(name, shape);
		if (unspellable != null) return CErr(unspellable);
		final isMethod: Bool = !(shape.localFunctionKinds ?? []).contains(decl.kind);
		return isMethod ? collectMethodCalls(tree, source, name, binding, shape) : collectLocalFnCalls(tree, source, name, shape);
	}

	/** Human-facing `line:col` for a span, in the `apq refs` print convention. */
	public static function posOf(source: String, span: Null<Span>): String {
		if (span == null) return '?:?';
		final pos: Position = span.lineCol(source);
		return '${pos.line}:${pos.col}';
	}

	/** `from` offset of a Read / Write hit's binding span (caller null-checks). */
	private static inline function bindingFrom(hit: RefHit): Int {
		final b: Null<Span> = hit.bindingSpan;
		return b == null ? -1 : b.from;
	}

	/**
	 * The POSITIONAL parameter slots — the grammar's `paramKinds` minus its rest spelling.
	 *
	 * The exclusion is the contract, not an omission. `leadingParams` feeds the operations
	 * that PERMUTE (`change-sig`) or DELETE (`remove-param`) a parameter by index, and a
	 * variadic tail is neither reorderable (the language requires it last) nor deletable by
	 * argument position (it consumes zero or more arguments at each call site). The
	 * two-name hand list this replaces said the same thing by spelling `Required` and
	 * `Optional` and stopping at everything else; this says it by naming what it drops.
	 *
	 * A grammar declaring no `paramKinds` answers the empty set, and the scan then stops at
	 * the first child — the ops refuse on the index they cannot place, `unused-parameter`
	 * reports nothing. Both are the quiet direction rather than the wrong-rewrite one.
	 */
	private static function positionalParamKinds(shape: RefShape): Array<String> {
		final rest: Null<String> = shape.restParamKind;
		return [for (kind in shape.paramKinds ?? []) if (kind != rest) kind];
	}

	/**
	 * Declaration kinds that, if any node of one carries the same name as the target local
	 * function, make a bare `name(...)` call ambiguous — so a local-function collection
	 * refuses unless its name is unique across all of them. Every binding a bare identifier
	 * could resolve to: the class members (`MemberKinds.FIELD_MEMBER_KINDS`, which carries
	 * the anonymous-structure field spellings too), the module-level VALUE declarations, and
	 * every named binder the grammar projects (`BinderScan.binderKinds`).
	 *
	 * The seventeen-name hand list this replaces was missing eleven of those twenty-eight,
	 * and the gap was not decorative. `LocalInlineFnStmt` was one of them, so a file
	 * declaring `function helper()` in one method and `inline function helper()` in another
	 * read as UNIQUE: uniqueness "proven", every bare `helper(...)` in the file collected as
	 * a site of the FIRST one, and `remove-param` / `change-sig` rewriting the calls of the
	 * second against a signature that is not theirs — at rc 0, with a file that still parses.
	 * The other ten (`VarForm`, `VarMore`, `VarExpr`, `FinalExpr`, `NamedFnExpr`,
	 * `CatchClause`, `ForStmt`, `ForExpr`, `KeyValueBinder`, `Capture`) are the same class of
	 * hole reached through a more exotic shadow. Nothing was dropped: over-answering a clash
	 * costs a refusal, which is the direction this proof is allowed to fail in.
	 */
	private static function nameClashKinds(shape: RefShape): Array<String> {
		final out: Array<String> = MemberKinds.FIELD_MEMBER_KINDS.copy();
		for (kind in shape.moduleValueDeclKinds.concat(BinderScan.binderKinds(shape))) if (!out.contains(kind)) out.push(kind);
		return out;
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
	private static function collectMethodCalls(
		tree: QueryNode, source: String, name: String, binding: Int, shape: RefShape
	): CollectResult {
		final hits: Array<RefHit> = Refs.find(name, tree, shape);
		// A braceless `$name` interpolation read is excluded: it can only STRINGIFY the
		// function, never call through it, so it is not a first-class-value capture and no
		// signature change can break it. Left in, it refuses every method whose name merely
		// appears in an interpolated string.
		final boundReads: Array<RefHit> = [
			for (h in hits)
				if (h.kind == RefKind.Read && !h.interpolated && h.bindingSpan != null && bindingFrom(h) == binding) h
		];
		final boundReadFroms: Array<Int> = [for (h in boundReads) h.span.from];

		final classified: MethodCallScan = classifyMethodCalls(tree, source, name, boundReadFroms, hits, shape);
		var error: Null<String> = classified.error;
		final sites: Array<QueryNode> = classified.sites;
		// Refuse the method captured as a first-class value, whose indirect
		// calls cannot be tracked — rewriting its decl would silently break
		// them. Three capture forms: a bare `var fn = foo;` (a binding read
		// not consumed as a call callee), a `var f = this.foo;` (a
		// `this.foo` field access beyond the `this.foo(...)` call count),
		// and a `var f = obj.foo;` (any non-`this` receiver field access —
		// its call form already errored above).
		if (error == null) {
			final dangling: Null<RefHit> = boundReads.find(h -> !classified.consumedFroms.contains(h.span.from));
			if (dangling != null)
				error = '"$name" is referenced as a value (not called) at ${posOf(source, dangling.span)}'
					+ ' — indirect calls through a captured reference cannot be tracked';
		}
		if (error == null) error = fieldAccessValueCapture(tree, source, name, classified.thisSiteCount, shape);
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
	private static function fieldAccessValueCapture(
		tree: QueryNode, source: String, name: String, thisSiteCount: Int, shape: RefShape
	): Null<String> {
		var thisAccess: Int = 0;
		var error: Null<String> = null;
		function scan(node: QueryNode): Void {
			if (error != null) return;
			if (node.kind == shape.fieldAccessKind && node.name == name && node.children.length > 0) {
				final recv: QueryNode = node.children[0];
				if (recv.kind == shape.identKind && recv.name == shape.selfReferenceText)
					thisAccess++;
				else
					error = '"$name" is referenced as a value (not called) at ${posOf(source, node.span)}'
						+ ' — indirect calls through a captured reference cannot be tracked';
			}
			for (c in node.children) scan(c);
		}
		scan(tree);
		return error ?? (
			thisAccess > thisSiteCount
				? '"$name" is referenced as a value (not called) via `this.$name'
					+ '` — indirect calls through a captured reference cannot be tracked'
				: null
		);
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
	private static function collectLocalFnCalls(tree: QueryNode, source: String, name: String, shape: RefShape): CollectResult {
		final clashes: Int = countNameDecls(tree, name, shape);
		if (clashes > 1)
			return CErr(
				'cannot prove all call sites target the local function "$name": another declaration named "$name'
				+ '" exists — refused when a local-function name is ambiguous'
			);

		final sites: Array<QueryNode> = [];
		var error: Null<String> = null;
		final callKind: Null<String> = shape.callKind;
		function walk(node: QueryNode): Void {
			if (error != null) return;
			if (node.kind == callKind && node.children.length > 0) {
				final callee: QueryNode = node.children[0];
				switch calleeShape(callee, name, shape) {
					case CalleeBare(_):
						sites.push(node);
					case CalleeThis:
						error = 'cannot resolve `this.$name(...)` at ${posOf(source, node.span)} — `$name'
							+ '` is a local function, not a method';
					case CalleeOtherReceiver(recv):
						error = 'cannot resolve receiver-qualified call `$recv.$name(...)` at ${posOf(source, node.span)} — `$name'
							+ '` is a local function and cannot be called through a receiver';
					case CalleeNone:
				}
			}
			for (c in node.children) {
				if (error != null) return;
				walk(c);
			}
		}
		walk(tree);
		// With the name proven unique, every bare identifier named `name` is
		// a reference to this local function. Each bare CALL contributes
		// exactly one such ident (its callee); a surplus is a non-call
		// value reference whose indirect calls cannot be tracked.
		if (error == null && countIdentExprNamed(tree, name, shape) > sites.length)
			error = 'the local function "$name'
				+ '" is referenced as a value (not called) — indirect calls through a captured reference cannot be tracked';
		return error != null ? CErr(error) : COk(sites);
	}

	/**
	 * Classify a `Call`'s callee node relative to the target `name`:
	 * a bare `IdentExpr name` (with its span), a `this.name` field access,
	 * an `obj.name` field access on a non-`this` receiver (with the
	 * receiver's display name), or none of these (a call to something
	 * else).
	 */
	private static function calleeShape(callee: QueryNode, name: String, shape: RefShape): CalleeShape {
		if (callee.kind == shape.identKind && callee.name == name) {
			final span: Null<Span> = callee.span;
			return span == null ? CalleeNone : CalleeBare(span);
		}
		if (callee.kind != shape.fieldAccessKind || callee.name != name || callee.children.length <= 0) return CalleeNone;
		final recv: QueryNode = callee.children[0];
		if (recv.kind == shape.identKind && recv.name == shape.selfReferenceText) return CalleeThis;
		final recvName: String = recv.name ?? recv.kind;
		return CalleeOtherReceiver(recvName);
	}

	/**
	 * The call-site vocabulary this grammar does not declare, or null when it declares all of it.
	 *
	 * The completeness proof is a claim about EVERY call in the file, and each of these three
	 * absences turns a refusal into a FALSE proof rather than into a missing feature: with no
	 * call kind no site is recognised at all and the scan reports a complete empty set; with no
	 * field-access kind or no self-reference text a receiver-qualified `obj.name(...)` reads as
	 * "a call to something else" and is silently ignored instead of refused. Required up front,
	 * because a default nobody can state correctly belongs at the producer.
	 */
	private static function missingCallVocabulary(name: String, shape: RefShape): Null<String> {
		final missing: Array<String> = [];
		if (shape.callKind == null) missing.push('call kind');
		if (shape.fieldAccessKind == null) missing.push('field-access kind');
		if (shape.selfReferenceText == null) missing.push('self-reference text');
		return missing.length == 0
			? null
			: 'cannot prove all call sites target "$name": this grammar declares no ${missing.join(', no ')}'
				+ ' — the shapes a call site is recognised by';
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
		return hit?.bindingSpan != null;
	}

	/** Count declarations named `name` anywhere in the tree. */
	private static function countNameDecls(tree: QueryNode, name: String, shape: RefShape): Int {
		// Derived ONCE and closed over: the vocabulary is a function of the handed shape, so a
		// per-node derivation would rebuild all twenty-eight names for every node of the file.
		final clashKinds: Array<String> = nameClashKinds(shape);
		var count: Int = 0;
		function walk(node: QueryNode): Void {
			if (node.name == name && clashKinds.contains(node.kind)) count++;
			for (c in node.children) walk(c);
		}
		walk(tree);
		return count;
	}

	/** Count bare-identifier nodes named `name` anywhere in the tree. */
	private static function countIdentExprNamed(tree: QueryNode, name: String, shape: RefShape): Int {
		var count: Int = 0;
		function walk(node: QueryNode): Void {
			if (node.kind == shape.identKind && node.name == name) count++;
			for (c in node.children) walk(c);
		}
		walk(tree);
		return count;
	}

	/**
	 * Walk the tree once, classifying every `Call` callee named `name`
	 * against the target binding. A bare `name(...)` whose callee ident is in
	 * `boundReadFroms` is OUR call (its span recorded in `consumedFroms`); a
	 * bare callee that resolves to a different binding is ignored; an
	 * unresolvable bare callee or a non-`this` receiver-qualified call is a
	 * refusal. `this.name(...)` calls are collected and counted separately so
	 * the caller can reconcile them against `this.name` field-access captures.
	 * Returns the partial collection plus the first completeness diagnostic,
	 * or a null error when every call site was resolvable.
	 */
	private static function classifyMethodCalls(
		tree: QueryNode, source: String, name: String, boundReadFroms: Array<Int>, hits: Array<RefHit>, shape: RefShape
	): MethodCallScan {
		final sites: Array<QueryNode> = [];
		final consumedFroms: Array<Int> = [];
		var thisSiteCount: Int = 0;
		var error: Null<String> = null;
		final callKind: Null<String> = shape.callKind;
		function walk(node: QueryNode): Void {
			if (error != null) return;
			if (node.kind == callKind && node.children.length > 0) {
				final callee: QueryNode = node.children[0];
				switch calleeShape(callee, name, shape) {
					case CalleeBare(identSpan):
						// A bare `name(...)` call. It is OUR call iff its
						// callee identifier read binds to `binding`.
						if (boundReadFroms.contains(identSpan.from)) {
							sites.push(node);
							consumedFroms.push(identSpan.from);
						} else if (!bareBindsElsewhere(identSpan, hits))
							error = 'cannot prove all call sites target "$name": unresolved call at ${posOf(source, node.span)}'
								+ ' — every call site must be resolvable';
					case CalleeThis:
						sites.push(node);
						thisSiteCount++;
					case CalleeOtherReceiver(recv):
						error = 'cannot resolve receiver-qualified call `$recv.$name(...)` at ${posOf(source, node.span)}'
							+ ' — every call site must be resolvable (supported for local functions and methods called only via bare `$name'
							+ '(...)` / `this.$name(...)`)';
					case CalleeNone:
				}
			}
			for (c in node.children) {
				if (error != null) return;
				walk(c);
			}
		}
		walk(tree);
		return {
			sites: sites,
			consumedFroms: consumedFroms,
			thisSiteCount: thisSiteCount,
			error: error
		};
	}

}

/** Classification of a `Call`'s callee relative to the target name — internal. */
private enum CalleeShape {

	CalleeBare(identSpan: Span);
	CalleeThis;
	CalleeOtherReceiver(recv: String);
	CalleeNone;

}

/**
 * The partial result of `classifyMethodCalls`: the collected call-site
 * `Call` nodes, the spans already consumed as bare-call callees, the count
 * of `this.name(...)` sites, and the first completeness diagnostic (null
 * when every call site was resolvable).
 */
private typedef MethodCallScan = {
	final sites: Array<QueryNode>;
	final consumedFroms: Array<Int>;
	final thisSiteCount: Int;
	final error: Null<String>;
};
