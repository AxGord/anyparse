package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.Refs;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
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
 * - the callee is PROVEN to be a plain method through the `SymbolIndex`: a bare name or
 *   `this.m` declared by the enclosing type, `local.m` over a local passing the argument
 *   test, or `Type.m` on a type name — each naming exactly one declaration, a method
 *   rather than a function-typed `var` / `final`, and not `dynamic` (rebindable), not a
 *   macro (`Macro functions must be called immediately`), not generic, not `inline`
 *   together with `extern`, and not one of several overloads (`Cannot create closure`).
 *   Its type must be a non-extern one from the project's own roots: a library or
 *   standard-library declaration may be `extern inline` on some target (`std/js/_std`).
 *   An abstract's INSTANCE method reached through an implicit `this` is refused, since an
 *   abstract may reassign `this` after the callback is created; a class `this` cannot be.
 *   A local function is accepted as it stands. Anything the index cannot answer — an
 *   inherited member, a static import, a type outside the index, an ambiguous name, a
 *   field receiver, a longer chain — is refused.
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
		final index: String -> Null<SymbolIndex> = coveringIndex(files, plugin);
		return RunScan.collectWith(files, plugin, resolveSeams(plugin), (entry, tree, seams, violations) -> {
			for (m in matches(tree, entry.file, entry.source, seams, plugin, index)) violations.push({
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
		if (seams == null) return [];
		final file: String = violations.length == 0 ? '' : violations[0].file;
		final scope: String -> Null<SymbolIndex> = coveringIndex([{ file: file, source: source }], plugin, index);
		return CheckScan.applyTextMatches(plugin, source, violations, (tree, text) -> matches(tree, file, text, seams, plugin, scope));
	}

	/** Every bindable lambda under `tree` with its rewrite — the outermost one of a nest only. */
	private static function matches(
		tree: QueryNode, file: String, source: String, seams: Seams, plugin: GrammarPlugin, index: String -> Null<SymbolIndex>
	): Array<{ span: Span, text: String }> {
		final provider: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		final ctx: Ctx = {
			seams: seams,
			root: tree,
			file: file,
			source: source,
			provider: provider,
			index: index.bind(file),
			declaredTypes: provider?.declaredTypes(source) ?? [],
			binder: null
		};
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
		if (call.kind != seams.callKind || call.children.length < 2) return null;
		for (i in 1...call.children.length) if (!stableArg(call.children[i], ctx)) return null;
		// The callee last: its proof may build the index, which a lambda with a computed argument never needs.
		return stableCallee(call.children[0], ctx) ? call : null;
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
	 * Whether the callee is a function that cannot change between creation and call and can be closed
	 * over: a bare name or `this.m` the enclosing type declares, `local.m` over an unchanging local, or
	 * `Type.m` on a type name — each proven by `plainMethod`; or a bare name bound to a local function.
	 */
	private static function stableCallee(callee: QueryNode, ctx: Ctx): Bool {
		final shape: RefShape = ctx.seams.shape;
		if (callee.kind == shape.identKind) return bareCalleeIsMethod(callee, ctx);
		final method: Null<String> = callee.name;
		if (callee.kind != shape.fieldAccessKind || callee.children.length != 1 || method == null) return false;
		final receiver: QueryNode = callee.children[0];
		final receiverName: Null<String> = receiver.name;
		if (receiver.kind != shape.identKind || receiverName == null) return false;
		if (receiverName == shape.selfReferenceText) return enclosingDeclares(callee, method, ctx);
		final local: Bool = TypeResolver.identBindingFrom(receiver, ctx.root, shape) != null;
		// A bound receiver must be a local `bind` reads unchanged; an unbound one must name a type.
		if (local ? !unchangingBinding(receiver, ctx) : !CasePatternScan.startsUpper(receiverName)) return false;
		final owners: Null<Array<ResolvedType>> = binderOf(ctx)?.receiverDecls(receiver);
		return owners != null && owners.length == 1 && plainMethod(owners[0], method, !local, ctx);
	}

	/**
	 * A bare callee name: bound to a local function, or — bound to nothing local — a method the enclosing
	 * type itself declares. A local holding a function value is refused (its type is not a nominal one the
	 * argument test can prove), and so is a name the enclosing type does not declare: an inherited member,
	 * a static import, a module-level function.
	 */
	private static function bareCalleeIsMethod(callee: QueryNode, ctx: Ctx): Bool {
		final shape: RefShape = ctx.seams.shape;
		final name: Null<String> = callee.name;
		final span: Null<Span> = callee.span;
		if (name == null || span == null) return false;
		final binding: Null<QueryNode> = TypeResolver.bindingNodeFrom(name, span, ctx.root, shape);
		if (binding != null && (shape.localFunctionKinds ?? []).contains(binding.kind)) return true;
		return (binding == null || !isLocalOrParam(binding.kind, shape)) && enclosingDeclares(callee, name, ctx);
	}

	/** Whether the type enclosing `node` declares `name` as a `plainMethod`, static or not. */
	private static function enclosingDeclares(node: QueryNode, name: String, ctx: Ctx): Bool {
		final span: Null<Span> = node.span;
		final index: Null<SymbolIndex> = ctx.index();
		final fi: Null<FileInfo> = index?.fileInfo(ctx.file);
		if (span == null || fi == null) return false;
		final file: FileInfo = fi;
		final found: Null<TypeDeclInfo> = fi.types.find(t -> t.span.from <= span.from && span.to <= t.span.to);
		if (found == null) return false;
		final owner: TypeDeclInfo = found;
		// Called through an implicit `this`, an ABSTRACT's instance method is bound to the value `this`
		// holds NOW, and an abstract may reassign `this` before the call; a class `this` never changes.
		final abstractSelf: Bool = (ctx.seams.shape.underlyingThisTypeKinds ?? []).contains(owner.kind);
		return plainMethod({ type: owner, file: file }, name, abstractSelf ? true : null, ctx);
	}

	/**
	 * Whether `owner` declares `name` exactly once, as a method `bind` can close over and nothing can rebind:
	 * a function member (not a function-typed `var` / `final` field), outside any `#if`, and not `dynamic`,
	 * a macro, generic, one of several overloads (by modifier or `@:overload`), or `extern inline`. The
	 * owner must be a non-extern type from the project's own roots: a library or standard-library
	 * declaration is one view among the target's overrides (`std/js/_std` makes `String.charCodeAt`
	 * `extern inline`, which has no closure). `isStatic`, when given, is what the access demands.
	 */
	private static function plainMethod(owner: ResolvedType, name: String, isStatic: Null<Bool>, ctx: Ctx): Bool {
		final shape: RefShape = ctx.seams.shape;
		final members: Array<MemberInfo> = owner.type.members.filter(m -> m.name == name);
		if (members.length != 1) return false;
		final m: MemberInfo = members[0];
		final generic: Null<String> = shape.genericFunctionMetaName;
		final index: Null<SymbolIndex> = ctx.index();
		return index != null && !index.isThirdParty(owner.file.file) && !owner.type.isExtern
			&& (shape.functionKinds ?? []).contains(m.kind) && !m.guarded && !m.isDynamic && !m.isMacro && !m.isOverload
			&& !m.hasOverloadMeta && !(m.isInline && m.isExtern) && (generic == null || !m.metaNames.contains(generic))
			&& (isStatic == null || isStatic == m.isStatic);
	}

	/** The file's `OperandBinder`, built on first use; null when the grammar supplies no type information or the index is missing. */
	private static function binderOf(ctx: Ctx): Null<OperandBinder> {
		final built: Null<OperandBinder> = ctx.binder;
		if (built != null) return built;
		final index: Null<SymbolIndex> = ctx.index();
		final provider: Null<TypeInfoProvider> = ctx.provider;
		if (index == null || provider == null) return null;
		final shape: RefShape = ctx.seams.shape;
		final binder: OperandBinder = new OperandBinder(
			ctx.file, ctx.source, ctx.root, shape, index, provider, OperandBinder.builtinNamesOf(shape)
		);
		ctx.binder = binder;
		return binder;
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

	/**
	 * A memoised index lookup that COVERS the file asked about: the plugin's resolution scope when it
	 * holds that file — the one `run` proves against, and wider than the per-pass index `--fix` hands in
	 * — else the caller's `given` index, else one built over `files`. A file outside the resolution
	 * roots would otherwise find no declarations at all and every callee would be refused.
	 */
	private static function coveringIndex(
		files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, ?given: SymbolIndex
	): String -> Null<SymbolIndex> {
		var wide: Null<SymbolIndex> = null;
		var widened: Bool = false;
		var own: Null<SymbolIndex> = given;
		function covering(file: String): Null<SymbolIndex> {
			if (!widened) {
				wide = RefactorSupport.resolutionIndexOf(plugin);
				widened = true;
			}
			final scope: Null<SymbolIndex> = wide;
			if (scope != null && scope.fileInfo(file) != null) return scope;
			final built: SymbolIndex = own ?? SymbolIndex.build(files, plugin);
			own = built;
			return built;
		}
		return covering;
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
 * One file's scan: the seams, the parsed root the scope resolver binds identifiers against, the file's
 * name and source, the declared-type map keyed by binding offset, and the index a callee is proven
 * against with the `OperandBinder` over it, both built on first use.
 */
private typedef Ctx = {
	final seams: Seams;
	final root: QueryNode;
	final file: String;
	final source: String;
	final provider: Null<TypeInfoProvider>;
	final index: () -> Null<SymbolIndex>;
	final declaredTypes: Map<Int, String>;
	var binder: Null<OperandBinder>;
};
