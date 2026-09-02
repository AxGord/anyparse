package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.FunctionTypeProvider;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.Refs;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.runtime.Span;

using Lambda;

/**
 * ETA-REDUCTION: flags a lambda whose whole body is ONE call that forwards the lambda's own
 * parameters, in order, and does nothing else — `x -> f(x)`, `(a, b) -> f(a, b)`, `() -> f()` —
 * and rewrites it to the bare `f`. `Severity.Info`, with an autofix.
 *
 * The rule is a READABILITY one and says nothing about speed. Measured on `-cpp` (hxcpp,
 * interleaved arms in one process, with and without `-D analyzer-optimize`), the reduced `f` is
 * ~10 % SLOWER per call and ~23 % slower per creation than the wrapper it replaces: a static method
 * handed to a function parameter builds a closure object of its own, while the wrapper's body gets
 * the call inlined into it. Do not claim a performance benefit.
 *
 * That number is a statement about TODAY'S hxcpp, not about the code. A static method has no captured
 * state, so its function value could be a cached singleton rather than a fresh allocation, and the
 * wrapper only wins because inlining hides the same work. The project's position, recorded
 * deliberately: a codegen weakness is not a reason to write the worse expression. The wrapper form
 * asks every author to remember a trick that will stop paying the moment the backend improves, and
 * source outlives backends. So the rule stands on readability, the measurement stands as a fact about
 * the current toolchain, and the gap belongs upstream.
 *
 * `prefer-bind` is the neighbour, and the two can never claim the same lambda: it requires a
 * ZERO-parameter lambda wrapping a call with AT LEAST ONE argument (`() -> f(a, b)`, rewritten
 * to `f.bind(a, b)`), and its own doc rules this rewrite out of its scope. This rule requires
 * the argument list to BE the parameter list, so a call with arguments needs the parameters to
 * match them one for one, and the zero-parameter case it does claim (`() -> f()`) is exactly
 * the zero-ARGUMENT call `prefer-bind` refuses.
 *
 * ## The gates ARE the rule
 *
 * Structural, on the lambda:
 *
 * - the body is the call node, reached through `bodyExpression` (which looks through the one
 *   expression-body wrapper and the one `return` the `function` spelling is REQUIRED to carry, so
 *   `function(v) return f(v)` reduces exactly as `(v) -> f(v)` does); a cast, a negation, a
 *   parenthesis, a BLOCK body, an `untyped`, a conditional region all project as a different
 *   kind and are refused — the block body most deliberately, since `function(v) { return f(v); }`
 *   and `(v) -> { return f(v); }` carry a statement list whose value the grammar does not state.
 *   `function(v):Int return f(v)` is refused one gate later: its return-type hint is a child
 *   between the parameters and the body, which the parameter loop reads as a non-plain binder;
 * - every parameter is a plain binder — an optional / rest / defaulted parameter is refused
 *   (a lambda cannot declare one in Haxe, but the seam is grammar-agnostic);
 * - the call's arguments are the parameters, ALL of them, in the SAME ORDER, each a bare
 *   identifier read — a dropped, reordered, duplicated or wrapped argument is refused;
 * - no parameter name occurs anywhere in the callee expression (`x -> x.f(x)` is refused). This one
 *   is SUBSUMED today — a lambda binder is in the file's binder set, so the shadowing gate below
 *   refuses the same sources, and no fixture isolates it. It is kept as the explicit invariant the
 *   accepted callee shapes must preserve if they are ever widened.
 *
 * On the callee, which must resolve to a DECLARED FUNCTION — the rule reduces to a method
 * value, and a method value differs from the wrapper wherever the callee is not one:
 *
 * - a bare name held by a BINDER is read on POSITIVE EVIDENCE and refused without it. Resolution
 *   here is by NAME over the whole file, so the evidence has to hold for EVERY binder carrying
 *   that name, and it is three facts: each of them is a REQUIRED parameter or a local declaration (an
 *   optional or rest parameter is refused: its annotation is not the type the binder holds —
 *   `?w:()->Void` holds a `Null<()->Void>`, `...w:()->Void` a rest collection. A `for` or
 *   `catch` binder is refused: this rule carries no scope model, and a name that is RE-bound is
 *   where a flat by-name answer is least defensible. A `case` binder never reaches the binder set
 *   at all — the grammar projects a bare lowercase pattern as a plain identifier — so it is
 *   refused one gate earlier, as a name nothing declares); each carries an explicit annotation the
 *   grammar reads as a function type of this same arity with every parameter positional
 *   (`FunctionTypeProvider` — an optional or rest one answers null, because Haxe refuses
 *   `(?Int) -> Void` where `() -> Void` is expected); and the name is never WRITTEN anywhere in
 *   the file, proven with the same scope-resolved write walker `prefer-final` trusts. Miss any one
 *   and re-reading the name at call time, which is what the wrapper does, stops being the same
 *   program as binding it once. Twins that AGREE are accepted rather than refused — two same-named
 *   parameters of one arity answer the same question, and `fs.FileIO` in the tree that motivated
 *   this rule has exactly that shape;
 * - a local function is accepted, an `inline` local function refused — a method value of one
 *   is `Cannot create closure on inline closure`, a hard compile error (measured on `-cpp`);
 * - a member of the ENCLOSING type is accepted; an inherited member is not visible here and
 *   is refused for want of evidence;
 * - `Type.member` is accepted when `Type` is declared EXACTLY ONCE in the lint scope and the
 *   member is `static`. An ambiguous simple name, a lower-initial receiver (an instance whose
 *   type the rule cannot know), a longer receiver chain, and a receiver name that is also a
 *   local are all refused;
 * - the declaration must carry NO metadata annotation. `@:overload` makes the value ambiguous;
 *   blocking the whole class keeps the gate grammar-agnostic and closes the annotations nobody
 *   has thought about yet;
 * - `dynamic` and `macro` members are refused — a `dynamic` method is rebindable, so reading it
 *   once is a behaviour change;
 * - the arity must match EXACTLY, and an optional / rest / defaulted parameter on the callee is
 *   refused: `(v:Int, ?k:Int) -> Bool` is not `Int -> Bool`, and the reduced form does not
 *   compile (measured — optional, defaulted and rest all fail the same way);
 * - a member name declared twice in one type (the two arms of a conditional region) is refused,
 *   since the two arms may disagree about any of the above.
 *
 * The NAMED spellings are refused, and that is a decision rather than a gap. A named function
 * BINDS its own name: `function nm(q) return f(q);` is a DECLARATION, so eta-reducing it means
 * deleting the declaration AND rewriting every use — a two-site rewrite this rule cannot make,
 * since its fix replaces one span and it carries no scope model. The value-position form
 * `xs.map(function nm(q) return f(q))` looks like a one-site rewrite, but the name is visible
 * inside the body, so `function nm(q) return nm(q)` would reduce to a reference nothing declares.
 * Both stay out by construction — `namedFnExprKind` is not a member of `lambdaKinds`, and the
 * local-function kinds are not either — and both are pinned by name.
 *
 * Two things deliberately NOT gated, both measured on `-cpp`: a `static inline` / instance
 * `inline` member IS usable as a value (only a LOCAL inline function is not), and a callee whose
 * parameter or return type is WIDER than the lambda's (`Float` for an `Int` binder, a non-`Void`
 * return where `Void` is expected) unifies fine.
 *
 * ## Scope sensitivity — read this before believing a zero count
 *
 * The callee table is built from the files the check is HANDED, which is the report scope.
 * Linting one file therefore resolves almost nothing and reports almost nothing; the same file
 * inside a project-wide lint resolves its `Type.member` callees and reports them. That is the
 * safe direction (no evidence → no finding) but it makes a narrow run useless as a census.
 *
 * ## Grammar-agnostic
 *
 * Hosts come from `RefShape.lambdaKinds`, the body unwrap from `expressionBodyKinds` +
 * `valueReturnKinds`, the body kind from `callKind`, parameters from
 * `paramKinds` minus `optionalParamKind` / `restParamKind`, argument reads from `identKind`,
 * the static receiver from `fieldAccessKind` gated on `upperInitialNeverCaptures`, declarations
 * from `typeDeclKinds` + `visibilityContainerKinds` (the wrapped `final class` form) with
 * `memberDeclKinds` / `functionKinds` inside, modifiers from `staticModifierKind` /
 * `dynamicModifierKind` / `macroModifierKind`, annotations from `MetaShape.metaKinds`, local
 * functions from `localFunctionKinds` / `inlineFunctionKinds`, and shadowing binders from the
 * declaration seams. An unset seam degrades to a refusal, never to a wrong accept.
 */
@:nullSafety(Strict)
final class RedundantLambdaWrapper implements Check implements DefaultOff {

	private static inline final RULE_ID: String = 'redundant-lambda-wrapper';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a lambda that only forwards its parameters to one call — x -> f(x) is f';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final resolved: Null<Seams> = resolveSeams(plugin);
		if (resolved == null) return [];
		// A narrowed local never reaches a non-nullable field of an anonymous structure literal; re-bind first.
		final seams: Seams = resolved;
		final parsed: Array<{ file: String, source: String, tree: QueryNode }> = CheckScan.parseAll(plugin, files);
		final types: Map<String, Null<Map<String, Signature>>> = collectTypes(parsed, seams);
		final typeInfo: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		final functionTypes: Null<FunctionTypeProvider> = plugin is FunctionTypeProvider ? cast plugin : null;
		final shape: RefShape = plugin.refShape();
		final violations: Array<Violation> = [];
		for (entry in parsed) {
			final ctx: Ctx = {
				seams: seams,
				shape: shape,
				types: types,
				scope: fileScope(entry.tree, seams),
				tree: entry.tree,
				typeSources: typeInfo?.declaredTypeSources(entry.source),
				functionTypes: functionTypes,
				written: []
			};
			walk(violations, entry.file, entry.tree, null, ctx);
		}
		return violations;
	}

	/** Replace each flagged lambda with the callee expression it forwards to. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = resolveSeams(plugin);
		return seams == null
			? []
			: CheckScan.applyBySpan(plugin, source, violations, seams.lambdaKinds, (node, span) -> {
				final forward: Null<Forward> = forwarding(node, seams);
				if (forward == null) return null;
				final calleeSpan: Null<Span> = forward.callee.span;
				return calleeSpan == null ? null : { span: span, text: source.substring(calleeSpan.from, calleeSpan.to) };
			});
	}

	private static function walk(
		out: Array<Violation>, file: String, node: QueryNode, enclosing: Null<Map<String, Signature>>, ctx: Ctx
	): Void {
		final host: Null<Map<String, Signature>> = ctx.seams.typeHostKinds.contains(node.kind) && node.name != null
			? membersOf(node, ctx.seams)
			: enclosing;
		final forward: Null<Forward> = forwarding(node, ctx.seams);
		if (forward != null && reducible(forward, host, ctx)) {
			final span: Null<Span> = node.span;
			if (span != null) {
				out.push({
					file: file,
					span: span,
					rule: RULE_ID,
					severity: Severity.Info,
					message: 'this lambda only forwards its parameters to one call — pass the function itself'
				});
				return;
			}
		}
		for (c in node.children) walk(out, file, c, host, ctx);
	}

	/**
	 * The forwarded call when `node` is a lambda whose body IS a call taking exactly the
	 * lambda's own parameters, in order, as bare identifier reads and nothing else; else null.
	 * Structure only — whether the callee may become a method value is `reducible`'s question.
	 */
	private static function forwarding(node: QueryNode, seams: Seams): Null<Forward> {
		final childCount: Int = node.children.length;
		if (!seams.lambdaKinds.contains(node.kind) || childCount == 0) return null;
		final body: Null<QueryNode> = bodyExpression(node.children[childCount - 1], seams);
		if (body == null || body.kind != seams.callKind || body.children.length == 0) return null;
		final call: QueryNode = body;
		final params: Array<String> = [];
		for (i in 0...childCount - 1) {
			final param: QueryNode = node.children[i];
			final name: Null<String> = param.name;
			if (name == null || !plainBinder(param, seams)) return null;
			params.push(name);
		}
		if (call.children.length - 1 != params.length) return null;
		for (i in 0...params.length) {
			final arg: QueryNode = call.children[i + 1];
			if (arg.kind != seams.identKind || arg.name != params[i]) return null;
		}
		final callee: QueryNode = call.children[0];
		for (name in params) if (mentions(callee, name)) return null;
		return { callee: callee, arity: params.length };
	}

	/**
	 * The single expression a lambda's body child evaluates to, looking through the wrappers the
	 * grammar interposes for the spellings that cannot write a bare expression there — or null
	 * when the body is anything else.
	 *
	 * Haxe needs both: `function(v) return f(v)` projects as `ExprBody(ReturnExpr(Call))`, and
	 * the `return` is not optional in that spelling, so a consumer demanding the body BE the call
	 * could never fire on ANY `function` lambda while the identical `(v) -> f(v)` did — a silence
	 * this rule's own doc contradicted. Each wrapper is looked through AT MOST ONCE and only when
	 * it holds exactly one child, so nothing nests its way past the gate.
	 *
	 * A BLOCK body stays refused, which is the point of naming `expressionBodyKinds` rather than
	 * `functionBodyKinds`: `function(v) { return f(v); }` and `(v) -> { return f(v); }` carry a
	 * statement list whose value the grammar does not state, and the rule reduces only what it can
	 * see IS one expression. `ExprBody(UntypedExpr(Call))` is refused by the same construction —
	 * `untyped` is neither wrapper, so the walk stops on it.
	 */
	private static function bodyExpression(body: QueryNode, seams: Seams): Null<QueryNode> {
		var node: QueryNode = body;
		if (seams.expressionBodyKinds.contains(node.kind)) {
			if (node.children.length != 1) return null;
			node = node.children[0];
		}
		if (seams.valueReturnKinds.contains(node.kind)) {
			if (node.children.length != 1) return null;
			node = node.children[0];
		}
		return node;
	}

	/** Whether a lambda parameter node is a plain binder — the bare arrow form, or a non-optional, non-rest, undefaulted declared one. */
	private static function plainBinder(param: QueryNode, seams: Seams): Bool {
		return param.kind == seams.identKind || seams.paramKinds.contains(param.kind) && param.kind != seams.optionalParamKind
			&& param.kind != seams.restParamKind && param.children.length == 0;
	}

	/** Whether `name` occurs anywhere in `node`'s subtree, in ANY slot — the deliberately blunt reading of "used nowhere else". */
	private static function mentions(node: QueryNode, name: String): Bool {
		return node.name == name || node.children.exists(c -> mentions(c, name));
	}

	/** Whether the forwarded callee resolves to a declaration this rule may reduce to a method value. */
	private static function reducible(forward: Forward, enclosing: Null<Map<String, Signature>>, ctx: Ctx): Bool {
		final callee: QueryNode = forward.callee;
		final name: Null<String> = callee.name;
		if (name == null) return false;
		final signature: Null<Signature> = callee.kind == ctx.seams.identKind
			? bareSignature(name, enclosing, ctx)
			: staticSignature(callee, name, ctx);
		return signature != null && signature.safe && signature.arity == forward.arity;
	}

	/**
	 * What a BARE callee name resolves to — the binder that shadows everything else first, then a
	 * local function, else a member of the enclosing type. Null when nothing declares it.
	 */
	private static function bareSignature(name: String, enclosing: Null<Map<String, Signature>>, ctx: Ctx): Null<Signature> {
		return ctx.scope.valueNames.exists(name) ? binderSignature(name, ctx) : ctx.scope.localFns.get(name) ?? enclosing?.get(name);
	}

	/**
	 * What a callee name held by a BINDER resolves to, on positive evidence only — see the type
	 * doc's binder bullet for why each of the three facts is load-bearing. Null the moment one is
	 * missing, which includes a grammar that exposes neither annotations nor function types.
	 */
	private static function binderSignature(name: String, ctx: Ctx): Null<Signature> {
		final sources: Null<Map<Int, String>> = ctx.typeSources;
		final provider: Null<FunctionTypeProvider> = ctx.functionTypes;
		final spans: Null<Array<Span>> = ctx.scope.binderSpans[name];
		if (spans == null || spans.length == 0) return null;
		// Resolution here is by NAME over the whole file, so the answer has to hold for EVERY binder
		// that carries it: one binder of a kind this rule may not read through, and the occurrence
		// could be the one it cannot see.
		if (sources == null || provider == null || ctx.scope.binderCounts[name] != spans.length) return null;
		var agreed: Null<Int> = null;
		for (span in spans) {
			final annotation: Null<String> = sources[span.from];
			if (annotation == null) return null;
			final declared: Null<Int> = provider.functionTypeArity(annotation);
			if (declared == null || (agreed != null && declared != agreed)) return null;
			agreed = declared;
		}
		if (agreed == null || written(name, ctx)) return null;
		// A narrowed local never reaches a non-nullable field of an anonymous structure literal.
		final params: Int = agreed;
		return { arity: params, isStatic: false, safe: true };
	}

	/**
	 * Whether `name` is assigned anywhere in this file. One scope-resolved write scan per name,
	 * memoized: the walker `prefer-final` trusts is COMPLETE for writes — every one of them is a
	 * structural assignment / increment node, and the single reference a source scan would miss,
	 * simple `'$x'` interpolation, can only ever be a read.
	 */
	private static function written(name: String, ctx: Ctx): Bool {
		final known: Null<Bool> = ctx.written[name];
		if (known != null) return known;
		final any: Bool = Refs.find(name, ctx.tree, ctx.shape).exists(h -> h.kind == RefKind.Write);
		ctx.written[name] = any;
		return any;
	}

	/**
	 * What a `Type.member` callee resolves to. Null unless `Type` is an upper-initial simple name
	 * declared exactly once in scope, shadowed by no local, and `member` is one of its statics.
	 */
	private static function staticSignature(callee: QueryNode, name: String, ctx: Ctx): Null<Signature> {
		final seams: Seams = ctx.seams;
		if (callee.kind != seams.fieldAccessKind || !seams.upperInitialTypes || callee.children.length != 1) return null;
		final receiver: QueryNode = callee.children[0];
		final typeName: Null<String> = receiver.name;
		if (receiver.kind != seams.identKind || typeName == null || typeName == '') return null;
		if (typeName.charAt(0).toUpperCase() != typeName.charAt(0)) return null;
		if (ctx.scope.valueNames.exists(typeName)) return null;
		final members: Null<Map<String, Signature>> = ctx.types.get(typeName);
		final member: Null<Signature> = members == null ? null : members[name];
		return member != null && member.isStatic ? member : null;
	}

	/** Every type simple name declared across `parsed`, mapped to its function members — null when the name is declared more than once. */
	private static function collectTypes(
		parsed: Array<{ file: String, source: String, tree: QueryNode }>, seams: Seams
	): Map<String, Null<Map<String, Signature>>> {
		final out: Map<String, Null<Map<String, Signature>>> = [];
		for (entry in parsed) collectTypeDecls(entry.tree, out, seams);
		return out;
	}

	private static function collectTypeDecls(node: QueryNode, out: Map<String, Null<Map<String, Signature>>>, seams: Seams): Void {
		final name: Null<String> = node.name;
		if (seams.typeHostKinds.contains(node.kind) && name != null) out[name] = out.exists(name) ? null : membersOf(node, seams);
		for (c in node.children) collectTypeDecls(c, out, seams);
	}

	/** One type's function members by name. A name declared twice (two arms of a conditional region) is kept but marked unsafe. */
	private static function membersOf(host: QueryNode, seams: Seams): Map<String, Signature> {
		final out: Map<String, Signature> = [];
		collectMembers(host, out, seams);
		return out;
	}

	private static function collectMembers(host: QueryNode, out: Map<String, Signature>, seams: Seams): Void {
		final run: Array<String> = [];
		var blocked: Bool = false;
		for (child in host.children) {
			if (seams.metaKinds.contains(child.kind)) {
				blocked = true;
				continue;
			}
			if (seams.modifierKinds.contains(child.kind)) {
				run.push(child.kind);
				if (child.kind == seams.dynamicModifierKind || child.kind == seams.macroModifierKind) blocked = true;
				continue;
			}
			if (child.kind == seams.conditionalMemberKind) {
				collectMembers(child, out, seams);
				// A region that HOLDS a declaration ends the run — what precedes it belongs to that
				// declaration. A member-free one CONTINUES it: `#if (haxe_ver >= 4.2) extern #else
				// @:extern #end public inline function f()` is an `extern inline` method in EVERY
				// build, and the run's own walk would otherwise never see either spelling.
				if (holdsMember(child, seams)) {
					run.resize(0);
					blocked = false;
				} else if (collectRegionPrefix(child, seams, run))
					blocked = true;
				continue;
			}
			final name: Null<String> = child.name;
			if (seams.memberDeclKinds.contains(child.kind) && name != null) {
				final staticKind: Null<String> = seams.staticModifierKind;
				final signature: Signature = {
					arity: countParams(child, seams),
					isStatic: staticKind != null && run.contains(staticKind),
					safe: !blocked && !closureless(run, seams) && !out.exists(name) && seams.functionKinds.contains(child.kind)
						&& name != seams.constructorName && plainParams(child, seams)
				};
				out[name] = signature;
			}
			run.resize(0);
			blocked = false;
		}
	}

	/** Whether `region` declares a member in any branch, at any nesting depth. */
	private static function holdsMember(region: QueryNode, seams: Seams): Bool {
		return region.children.exists(child -> seams.memberDeclKinds.contains(child.kind) || holdsMember(child, seams));
	}

	/**
	 * Append to `run` every modifier kind a member-free `region` contributes to the declaration that
	 * follows it, and report whether it also carries an annotation — which blocks the reduction exactly
	 * as one written outside the region does.
	 */
	private static function collectRegionPrefix(region: QueryNode, seams: Seams, run: Array<String>): Bool {
		var meta: Bool = false;
		for (child in region.children) {
			if (seams.metaKinds.contains(child.kind))
				meta = true;
			else if (seams.modifierKinds.contains(child.kind))
				run.push(child.kind);
			if (collectRegionPrefix(child, seams, run)) meta = true;
		}
		return meta;
	}

	/**
	 * Whether a member carrying this modifier run can never be referenced as a VALUE. `extern inline`
	 * has no runtime function to close over — Haxe answers `Can't create closure on an extern inline
	 * member method` — so replacing `e -> exists(e)` with `exists` turns a compiling call into a build
	 * failure. Plain `inline` is fine: only the `extern` pairing removes the callable.
	 */
	private static function closureless(run: Array<String>, seams: Seams): Bool {
		final externKind: Null<String> = seams.externModifierKind;
		final inlineKind: Null<String> = seams.inlineModifierKind;
		return externKind != null && inlineKind != null && run.contains(externKind) && run.contains(inlineKind);
	}

	/** The file's shadowing value binders and its local function declarations. */
	private static function fileScope(tree: QueryNode, seams: Seams): FileScope {
		final scope: FileScope = {
			valueNames: [],
			binderSpans: [],
			binderCounts: [],
			localFns: []
		};
		collectBindings(tree, scope, seams);
		return scope;
	}

	private static function collectBindings(node: QueryNode, scope: FileScope, seams: Seams): Void {
		final name: Null<String> = node.name;
		if (name != null && seams.binderKinds.contains(node.kind)) bind(scope, name, node, seams);
		if (name != null && (seams.localFunctionKinds.contains(node.kind) || seams.inlineFunctionKinds.contains(node.kind))) {
			scope.localFns.set(name, {
				arity: countParams(node, seams),
				isStatic: false,
				safe: !scope.localFns.exists(name) && !seams.inlineFunctionKinds.contains(node.kind) && plainParams(node, seams)
			});
		}
		// A bare-arrow lambda binds its parameter as a plain identifier node, not a declared one.
		if (seams.lambdaKinds.contains(node.kind)) {
			for (i in 0...node.children.length - 1) {
				final param: QueryNode = node.children[i];
				final paramName: Null<String> = param.name;
				if (param.kind == seams.identKind && paramName != null) bind(scope, paramName, param, seams);
			}
		}
		for (c in node.children) collectBindings(c, scope, seams);
	}

	/**
	 * Record one binding of `name`. Every binder counts toward `binderCounts` — a name bound twice
	 * is ambiguous and no reduction may read through it — while only a PARAMETER or a local
	 * declaration contributes a span to `binderSpans`, because only those two hold their value for
	 * the whole scope the lambda is created in. A loop / `case` / `catch` binder rebinds per
	 * iteration or per arm, so the wrapper's re-read and the reduction's single capture can
	 * genuinely differ.
	 */
	private static function bind(scope: FileScope, name: String, node: QueryNode, seams: Seams): Void {
		scope.valueNames.set(name, true);
		scope.binderCounts.set(name, (scope.binderCounts[name] ?? 0) + 1);
		final span: Null<Span> = node.span;
		if (span == null || !seams.reducibleBinderKinds.contains(node.kind)) return;
		final spans: Array<Span> = scope.binderSpans[name] ?? [];
		spans.push(span);
		scope.binderSpans.set(name, spans);
	}

	private static function countParams(decl: QueryNode, seams: Seams): Int {
		var count: Int = 0;
		for (c in decl.children) if (seams.paramKinds.contains(c.kind)) count++;
		return count;
	}

	/** Whether every declared parameter is required, undefaulted and non-rest — the shape a method value keeps. */
	private static function plainParams(decl: QueryNode, seams: Seams): Bool {
		return decl.children.foreach(c -> !seams.paramKinds.contains(c.kind) || plainBinder(c, seams));
	}

	/**
	 * Every declaration seam that BINDS a value name — the set whose members shadow a bare callee.
	 */
	private static function binderKindsOf(shape: RefShape): Array<String> {
		return (shape.localDeclKinds ?? []).concat(shape.paramKinds ?? [])
			.concat(shape.localDeclExprKinds ?? [])
			.concat(shape.staticLocalDeclKinds ?? [])
			.concat(shape.localDeclContinuationKinds ?? [])
			.concat(shape.selfScopeDeclKinds ?? [])
			.concat(shape.casePatternBinderKinds ?? [])
			.concat(shape.iterationValueBinderKinds ?? []);
	}

	/**
	 * Resolve every seam the check reads, or null when one it cannot work without is unset.
	 */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final lambdaKinds: Array<String> = shape.lambdaKinds ?? [];
		final callKind: Null<String> = shape.callKind;
		if (lambdaKinds.length == 0 || callKind == null) return null;
		final modifiers: Array<String> = modifierKindsOf(shape);
		return {
			lambdaKinds: lambdaKinds,
			expressionBodyKinds: shape.expressionBodyKinds ?? [],
			valueReturnKinds: shape.valueReturnKinds ?? [],
			callKind: callKind,
			identKind: shape.identKind,
			fieldAccessKind: shape.fieldAccessKind,
			paramKinds: shape.paramKinds ?? [],
			optionalParamKind: shape.optionalParamKind,
			restParamKind: shape.restParamKind,
			typeHostKinds: (shape.typeDeclKinds ?? []).concat(shape.visibilityContainerKinds ?? []),
			memberDeclKinds: shape.memberDeclKinds ?? [],
			functionKinds: shape.functionKinds ?? [],
			localFunctionKinds: shape.localFunctionKinds ?? [],
			inlineFunctionKinds: shape.inlineFunctionKinds ?? [],
			binderKinds: binderKindsOf(shape),
			reducibleBinderKinds: (
				shape.paramKinds ?? []
			).filter(k -> k != shape.optionalParamKind && k != shape.restParamKind).concat(shape.localDeclKinds ?? []),
			modifierKinds: modifiers,
			metaKinds: plugin.metaShape().metaKinds,
			staticModifierKind: shape.staticModifierKind,
			externModifierKind: shape.externModifierKind,
			inlineModifierKind: shape.inlineModifierKind,
			dynamicModifierKind: shape.dynamicModifierKind,
			macroModifierKind: shape.macroModifierKind,
			conditionalMemberKind: shape.conditionalMemberKind,
			constructorName: shape.constructorName,
			upperInitialTypes: shape.upperInitialNeverCaptures == true
		};
	}

	/**
	 * Every modifier kind a member declaration can carry — the ordered / visibility vocabularies plus
	 * each individually-named modifier seam the grammar declares outside them.
	 */
	private static function modifierKindsOf(shape: RefShape): Array<String> {
		final out: Array<String> = (shape.modifierOrderKinds ?? []).concat(shape.visibilityModifierKinds ?? []);
		for (kind in [
			 shape.staticModifierKind, shape.inlineModifierKind,    shape.macroModifierKind,
			shape.dynamicModifierKind, shape.externModifierKind, shape.overrideModifierKind
		]) {
			if (kind != null && !out.contains(kind)) out.push(kind);
		}
		return out;
	}

}

/** The lambda's forwarded callee plus the parameter count it forwards — `forwarding`'s structural verdict. */
private typedef Forward = {
	final callee: QueryNode;
	final arity: Int;
};

/** What one declaration offers a caller that wants its VALUE rather than its result. */
private typedef Signature = {
	final arity: Int;
	final isStatic: Bool;

	/** False when the declaration's own shape forbids the reduction — see the type doc's gate list. */
	final safe: Bool;
};

/** One file's shadowing value binders and its local function declarations. */
private typedef FileScope = {
	final valueNames: Map<String, Bool>;

	/** How many times each name is bound, by ANY binder — a name bound twice is ambiguous. */
	final binderCounts: Map<String, Int>;

	/** The binding spans of the binder kinds a reduction may read through — see `bind`. */
	final binderSpans: Map<String, Array<Span>>;

	final localFns: Map<String, Signature>;
};

/** The resolved seams plus the per-run tables `walk` reads. */
private typedef Ctx = {
	final seams: Seams;
	final shape: RefShape;
	final types: Map<String, Null<Map<String, Signature>>>;
	final scope: FileScope;
	final tree: QueryNode;

	/** Verbatim `:Type` annotations by binding-span start, or null when the grammar exposes none. */
	final typeSources: Null<Map<Int, String>>;

	/** The grammar's function-type reader, or null when it implements none. */
	final functionTypes: Null<FunctionTypeProvider>;

	/** Memo of "is this name ever written in this file", filled on demand by `written`. */
	final written: Map<String, Bool>;
};

/** Every seam `RedundantLambdaWrapper` reads, resolved once per run. */
private typedef Seams = {
	final lambdaKinds: Array<String>;
	final expressionBodyKinds: Array<String>;
	final valueReturnKinds: Array<String>;
	final callKind: String;
	final identKind: String;
	final fieldAccessKind: Null<String>;
	final paramKinds: Array<String>;
	final optionalParamKind: Null<String>;
	final restParamKind: Null<String>;
	final typeHostKinds: Array<String>;
	final memberDeclKinds: Array<String>;
	final functionKinds: Array<String>;
	final localFunctionKinds: Array<String>;
	final inlineFunctionKinds: Array<String>;
	final binderKinds: Array<String>;
	final reducibleBinderKinds: Array<String>;
	final modifierKinds: Array<String>;
	final metaKinds: Array<String>;
	final staticModifierKind: Null<String>;
	final externModifierKind: Null<String>;
	final inlineModifierKind: Null<String>;
	final dynamicModifierKind: Null<String>;
	final macroModifierKind: Null<String>;
	final conditionalMemberKind: Null<String>;
	final constructorName: Null<String>;
	final upperInitialTypes: Bool;
};
