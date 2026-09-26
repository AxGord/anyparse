package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.Refs;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

using Lambda;

/**
 * Flags a zero-parameter arrow lambda whose whole body is a single call —
 * `() -> f(a, b)` — and rewrites it to a partial application, `f.bind(a, b)`.
 * The wrapper lambda is noise when every argument is already known at the point
 * the callback is created. `Severity.Info` (a modernization matching the Haxe
 * idiom), with an autofix.
 *
 * Only a `() -> callee(args)` form with at least one argument is touched: a lambda
 * carrying parameters (`x -> f(x)`, `(x, y) -> f(x)`) keeps them as separate
 * `Required` / `Optional` children and is left alone (binding would leave them
 * unbound), and a block body (`() -> { … }`) is not a single call. A zero-argument
 * `() -> f()` is out of scope — `f.bind()` adds nothing, and the lambda may instead
 * collapse to a bare `f`, a different rewrite.
 *
 * ## Evaluation time
 *
 * `.bind` evaluates the callee's receiver and every argument when the callback is
 * CREATED, the lambda when it is CALLED. The rewrite is therefore made only when each
 * of them is certain to hold the same value at both moments and to cost nothing to
 * evaluate — a positive criterion, not a list of refused shapes:
 *
 * - an argument is a literal (an interpolation-free string, a negated number
 *   included), or a bare identifier bound to a local or parameter that nothing
 *   WRITES anywhere in the file and whose declared type is written, nominal and not a
 *   nullable wrapper — not optional, not initialised with `null`. A field (bare or
 *   `this.x`), a static, a call or any computed value is refused: a field may change
 *   between the two moments, and a call would move its side effect. The nullability
 *   half is the null-safety one: a `Null<String>` capture the compiler accepts inside
 *   the lambda is rejected as a `bind` argument (`Cannot assign nullable value here`);
 * - the callee is a bare name (a method, a static import, a local function, or a local
 *   passing the argument test), `local.m` over such a local, `this.m` or `pkg.Type.m` —
 *   a field receiver or a longer chain is refused, since `bind` reads it (and throws on
 *   a null one) at creation time.
 *
 * A bare callee name that resolves to nothing may still be a function-typed FIELD reassigned later, and one that resolves
 * to a `dynamic` method may be rebound; telling either from a plain method needs more than this per-file scan reads.
 *
 * ## Grammar-agnostic
 *
 * The lambda kind comes from `RefShape.parenLambdaKind` and the call kind from
 * `callKind` (either unset → no-op). The outermost matching lambda is flagged and
 * not descended into, so a nested `() -> f(() -> g(1))` yields one non-overlapping
 * fix per `--fix` iteration.
 */
@:nullSafety(Strict)
final class PreferBind implements Check {

	private static inline final RULE_ID: String = 'prefer-bind';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a () -> f(a, b) wrapper lambda replaceable with f.bind(a, b)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return RunScan.collectWith(files, plugin, resolveSeams(plugin), (entry, tree, seams, violations) -> {
			for (m in matches(tree, entry.source, seams, plugin)) violations.push({
				file: entry.file,
				span: m.span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: 'this () -> f(...) wrapper lambda can be f.bind(...)'
			});
		});
	}

	/** Rewrite each flagged `() -> callee(args)` to `callee.bind(args)`. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = resolveSeams(plugin);
		return seams == null
			? []
			: CheckScan.applyTextMatches(plugin, source, violations, (tree, text) -> matches(tree, text, seams, plugin));
	}

	/** Every bindable lambda under `tree` with its rewrite — the outermost one of a nest only. */
	private static function matches(
		tree: QueryNode, source: String, seams: Seams, plugin: GrammarPlugin
	): Array<{ span: Span, text: String }> {
		final ctx: Ctx = { seams: seams, root: tree, declaredTypes: RunScan.typeInfoOf(plugin)?.declaredTypes(source) ?? [] };
		final out: Array<{ span: Span, text: String }> = [];
		walk(tree, source, ctx, out);
		return out;
	}

	private static function walk(node: QueryNode, source: String, ctx: Ctx, out: Array<{ span: Span, text: String }>): Void {
		final span: Null<Span> = node.span;
		final text: Null<String> = rewrite(node, source, ctx);
		if (span != null && text != null) {
			out.push({ span: span, text: text });
			return;
		}
		for (c in node.children) walk(c, source, ctx, out);
	}

	/** The wrapped call when `node` is a bindable `() -> callee(arg, …)` lambda; else null. */
	private static function bindableCall(node: QueryNode, ctx: Ctx): Null<QueryNode> {
		final seams: Seams = ctx.seams;
		if (node.kind != seams.lambdaKind || node.children.length != 1) return null;
		final call: QueryNode = node.children[0];
		// callee + at least one argument; a parameter-bearing lambda has Required/Optional
		// children, so children.length != 1 excludes it.
		if (call.kind != seams.callKind || call.children.length < 2 || !stableCallee(call.children[0], ctx)) return null;
		for (i in 1...call.children.length) if (!stableArg(call.children[i], ctx)) return null;
		return call;
	}

	/**
	 * Whether `arg` holds the same value when the callback is created and when it is called,
	 * and costs nothing to evaluate: a literal, or an identifier `unchangingBinding` accepts.
	 */
	private static function stableArg(arg: QueryNode, ctx: Ctx): Bool {
		final shape: RefShape = ctx.seams.shape;
		final numeric: Array<String> = shape.numericLiteralKinds ?? [];
		if (numeric.contains(arg.kind) || arg.kind == shape.boolLitKind || arg.kind == shape.nullLiteralKind) return true;
		final strings: Array<String> = shape.stringLiteralKinds ?? [];
		return if (strings.contains(arg.kind))
			stringWithoutInterpolation(arg, shape)
		else if (arg.kind == shape.identKind)
			unchangingBinding(arg, ctx)
		else
			arg.kind == shape.negationKind && arg.children.length == 1 && numeric.contains(arg.children[0].kind);
	}

	/**
	 * Whether the callee reads the same function at both moments: a bare name bound to nothing
	 * in the file (an inherited method or a static import), to a method or local function, or to
	 * a local passing `unchangingBinding`; `local.m` over such a local; the self reference's
	 * `this.m`; or a static `pkg.Type.m`, whose receiver chain is package segments ending in one
	 * type-cased segment and binds to no value.
	 */
	private static function stableCallee(callee: QueryNode, ctx: Ctx): Bool {
		final shape: RefShape = ctx.seams.shape;
		if (callee.kind == shape.identKind) return stableBareCallee(callee, ctx);
		if (callee.kind != shape.fieldAccessKind || callee.children.length != 1) return false;
		final segments: Array<QueryNode> = [];
		var cur: QueryNode = callee.children[0];
		while (cur.kind == shape.fieldAccessKind && cur.children.length == 1) {
			segments.unshift(cur);
			cur = cur.children[0];
		}
		if (cur.kind != shape.identKind) return false;
		if (!TypeResolver.receiverRootIsUnboundType(cur, ctx.root, shape)) return segments.length == 0 && unchangingBinding(cur, ctx);
		segments.unshift(cur);
		return staticReceiver([for (s in segments) s.name], shape.selfReferenceText);
	}

	/** A bare callee name: bound to nothing in the file, to a method or local function, or to a local `unchangingBinding` accepts. */
	private static function stableBareCallee(callee: QueryNode, ctx: Ctx): Bool {
		final shape: RefShape = ctx.seams.shape;
		final name: Null<String> = callee.name;
		final span: Null<Span> = callee.span;
		if (name == null || span == null) return false;
		final binding: Null<QueryNode> = TypeResolver.bindingNodeFrom(name, span, ctx.root, shape);
		return binding == null || (shape.functionKinds ?? []).contains(binding.kind) || unchangingBinding(callee, ctx);
	}

	/**
	 * Whether an unbound receiver chain, spelled `names`, is the self reference alone or a static type path —
	 * package segments ending in one type-cased segment.
	 */
	private static function staticReceiver(names: Array<Null<String>>, self: Null<String>): Bool {
		if (names.length == 1 && names[0] == self) return true;
		final last: Null<String> = names[names.length - 1];
		if (last == null || !CasePatternScan.startsUpper(last)) return false;
		for (i in 0...names.length - 1) {
			final segment: Null<String> = names[i];
			if (segment == null || CasePatternScan.startsUpper(segment) || segment == self) return false;
		}
		return true;
	}

	/**
	 * Whether the identifier `ident` is bound to a local or parameter that is never written anywhere
	 * in the file and whose declared type is written, nominal and non-nullable — so the value `bind`
	 * captures at creation is the one the lambda would read at the call. A field (resolved or not)
	 * or a static is refused: it may change in between. A nullable binding is refused too, since null
	 * safety narrows a capture the compiler sees inside the lambda but rejects it as an argument.
	 */
	private static function unchangingBinding(ident: QueryNode, ctx: Ctx): Bool {
		final shape: RefShape = ctx.seams.shape;
		final name: Null<String> = ident.name;
		final span: Null<Span> = ident.span;
		if (name == null || span == null) return false;
		final binding: Null<QueryNode> = TypeResolver.bindingNodeFrom(name, span, ctx.root, shape);
		final from: Null<Int> = binding?.span?.from;
		if (binding == null || from == null || !isLocalOrParam(binding.kind, shape)) return false;
		final declared: Null<String> = ctx.declaredTypes[from];
		if (declared == null || (shape.nullableWrapperTypeNames ?? []).contains(declared)) return false;
		final optionalKind: Null<String> = shape.optionalParamKind;
		if (optionalKind != null && TypeResolver.bindingIsOptionalParam(ctx.root, from, optionalKind)) return false;
		final nullKind: Null<String> = shape.nullLiteralKind;
		if (nullKind != null && TypeResolver.bindingIsNullInitialised(ctx.root, from, TypeResolver.valueBinderDeclKinds(shape), nullKind))
			return false;
		return !Refs.find(name, ctx.root, shape).exists(hit -> hit.kind == RefKind.Write && hit.bindingSpan?.from == from);
	}

	/** Whether a declaration of `kind` binds a local or a parameter — not a field, whose value any code may change. */
	private static function isLocalOrParam(kind: String, shape: RefShape): Bool {
		return (shape.localDeclKinds ?? []).contains(kind) || (shape.localDeclContinuationKinds ?? []).contains(kind)
			|| (shape.paramKinds ?? []).contains(kind);
	}

	/** Whether a string-literal node carries no interpolation (every child, if any, is plain literal text). */
	private static function stringWithoutInterpolation(arg: QueryNode, shape: RefShape): Bool {
		final interp: Array<String> = shape.interpolationKinds ?? [];
		return !arg.children.exists(c -> c.kind == shape.stringInterpIdentKind || interp.contains(c.kind));
	}

	/** `callee.bind(arg, …)` built from the lambda's wrapped call, or null if it is not bindable. */
	private static function rewrite(node: QueryNode, source: String, ctx: Ctx): Null<String> {
		final call: Null<QueryNode> = bindableCall(node, ctx);
		if (call == null) return null;
		final calleeSpan: Null<Span> = call.children[0].span;
		if (calleeSpan == null) return null;
		final callee: String = source.substring(calleeSpan.from, calleeSpan.to);
		final args: Array<String> = [];
		for (i in 1...call.children.length) {
			final argSpan: Null<Span> = call.children[i].span;
			if (argSpan == null) return null;
			args.push(source.substring(argSpan.from, argSpan.to));
		}
		return '$callee.bind(${args.join(', ')})';
	}

	/** Resolve the lambda / call seam kinds, or null when either is unset. */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final lambdaKind: Null<String> = shape.parenLambdaKind;
		if (lambdaKind == null) return null;
		final callKind: Null<String> = shape.callKind;
		return callKind == null ? null : { lambdaKind: lambdaKind, callKind: callKind, shape: shape };
	}

}

/** The resolved seams `PreferBind` reads in both `run` and `fix`. */
private typedef Seams = {
	final lambdaKind: String;
	final callKind: String;
	final shape: RefShape;
};

/**
 * One file's scan: the seams, the parsed root the scope resolver binds identifiers against, and
 * the declared-type map keyed by binding offset.
 */
private typedef Ctx = {
	final seams: Seams;
	final root: QueryNode;
	final declaredTypes: Map<Int, String>;
};
