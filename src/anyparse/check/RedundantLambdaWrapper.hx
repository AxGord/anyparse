package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;

/**
 * ETA-REDUCTION: flags a lambda whose whole body is ONE call that forwards the lambda's own
 * parameters, in order, and does nothing else — `x -> f(x)`, `(a, b) -> f(a, b)`, `() -> f()` —
 * and rewrites it to the bare `f`. `Severity.Info`, with an autofix.
 *
 * The rule is a READABILITY one and says nothing about speed. Measured on `-cpp` (hxcpp,
 * `-D analyzer-optimize` and without, arms interleaved in one process, per-arm median of 21):
 * the reduced `f` is ~10 % SLOWER per call and ~23 % slower per creation than the wrapper it
 * replaces — a static method handed to a function parameter builds a closure object of its own,
 * while the wrapper's body gets the call inlined into it. Do not claim a performance benefit.
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
 * - the body is EXACTLY the call node — a cast, a negation, a parenthesis, a block, an
 *   `untyped`, a conditional region all project as a different kind and are refused;
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
 * - a bare name bound by a local / parameter / loop or catch binder anywhere in the file is
 *   refused. It may hold a function, but re-reading it at call time is what the wrapper does
 *   and binding it once is not the same program;
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
 * Hosts come from `RefShape.lambdaKinds`, the body kind from `callKind`, parameters from
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
		final violations: Array<Violation> = [];
		for (entry in parsed) {
			final ctx: Ctx = { seams: seams, types: types, scope: fileScope(entry.tree, seams) };
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
		if (!seams.lambdaKinds.contains(node.kind) || node.children.length == 0) return null;
		final call: QueryNode = node.children[node.children.length - 1];
		if (call.kind != seams.callKind || call.children.length == 0) return null;
		final params: Array<String> = [];
		for (i in 0...node.children.length - 1) {
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

	/** Whether a lambda parameter node is a plain binder — the bare arrow form, or a non-optional, non-rest, undefaulted declared one. */
	private static function plainBinder(param: QueryNode, seams: Seams): Bool {
		if (param.kind == seams.identKind) return true;
		return seams.paramKinds.contains(param.kind) && param.kind != seams.optionalParamKind && param.kind != seams.restParamKind
			&& param.children.length == 0;
	}

	/** Whether `name` occurs anywhere in `node`'s subtree, in ANY slot — the deliberately blunt reading of "used nowhere else". */
	private static function mentions(node: QueryNode, name: String): Bool {
		if (node.name == name) return true;
		for (c in node.children) if (mentions(c, name)) return true;
		return false;
	}

	/** Whether the forwarded callee resolves to a declaration this rule may reduce to a method value. */
	private static function reducible(forward: Forward, enclosing: Null<Map<String, Signature>>, ctx: Ctx): Bool {
		final seams: Seams = ctx.seams;
		final callee: QueryNode = forward.callee;
		final name: Null<String> = callee.name;
		if (name == null) return false;
		if (callee.kind == seams.identKind) {
			if (ctx.scope.valueNames.exists(name)) return false;
			final local: Null<Signature> = ctx.scope.localFns.get(name);
			if (local != null) return local.safe && local.arity == forward.arity;
			if (enclosing == null) return false;
			final member: Null<Signature> = enclosing.get(name);
			return member != null && member.safe && member.arity == forward.arity;
		}
		if (callee.kind != seams.fieldAccessKind || !seams.upperInitialTypes || callee.children.length != 1) return false;
		final receiver: QueryNode = callee.children[0];
		final typeName: Null<String> = receiver.name;
		if (receiver.kind != seams.identKind || typeName == null || typeName == '') return false;
		if (typeName.charAt(0).toUpperCase() != typeName.charAt(0)) return false;
		if (ctx.scope.valueNames.exists(typeName)) return false;
		final members: Null<Map<String, Signature>> = ctx.types.get(typeName);
		if (members == null) return false;
		final member: Null<Signature> = members.get(name);
		return member != null && member.safe && member.isStatic && member.arity == forward.arity;
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
		if (seams.typeHostKinds.contains(node.kind) && name != null) out.set(name, out.exists(name) ? null : membersOf(node, seams));
		for (c in node.children) collectTypeDecls(c, out, seams);
	}

	/** One type's function members by name. A name declared twice (two arms of a conditional region) is kept but marked unsafe. */
	private static function membersOf(host: QueryNode, seams: Seams): Map<String, Signature> {
		final out: Map<String, Signature> = [];
		collectMembers(host, out, seams);
		return out;
	}

	private static function collectMembers(host: QueryNode, out: Map<String, Signature>, seams: Seams): Void {
		var isStatic: Bool = false;
		var blocked: Bool = false;
		for (child in host.children) {
			if (seams.metaKinds.contains(child.kind)) {
				blocked = true;
				continue;
			}
			if (seams.modifierKinds.contains(child.kind)) {
				if (child.kind == seams.staticModifierKind) isStatic = true;
				if (child.kind == seams.dynamicModifierKind || child.kind == seams.macroModifierKind) blocked = true;
				continue;
			}
			if (child.kind == seams.conditionalMemberKind) {
				collectMembers(child, out, seams);
				isStatic = false;
				blocked = false;
				continue;
			}
			final name: Null<String> = child.name;
			if (seams.memberDeclKinds.contains(child.kind) && name != null) {
				final signature: Signature = {
					arity: countParams(child, seams),
					isStatic: isStatic,
					safe: !blocked && !out.exists(name) && seams.functionKinds.contains(child.kind) && name != seams.constructorName
						&& plainParams(child, seams)
				};
				out.set(name, signature);
			}
			isStatic = false;
			blocked = false;
		}
	}

	/** The file's shadowing value binders and its local function declarations. */
	private static function fileScope(tree: QueryNode, seams: Seams): FileScope {
		final scope: FileScope = { valueNames: new Map(), localFns: new Map() };
		collectBindings(tree, scope, seams);
		return scope;
	}

	private static function collectBindings(node: QueryNode, scope: FileScope, seams: Seams): Void {
		final name: Null<String> = node.name;
		if (name != null && seams.binderKinds.contains(node.kind)) scope.valueNames.set(name, true);
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
				if (param.kind == seams.identKind && paramName != null) scope.valueNames.set(paramName, true);
			}
		}
		for (c in node.children) collectBindings(c, scope, seams);
	}

	private static function countParams(decl: QueryNode, seams: Seams): Int {
		var count: Int = 0;
		for (c in decl.children) if (seams.paramKinds.contains(c.kind)) count++;
		return count;
	}

	/** Whether every declared parameter is required, undefaulted and non-rest — the shape a method value keeps. */
	private static function plainParams(decl: QueryNode, seams: Seams): Bool {
		for (c in decl.children) if (seams.paramKinds.contains(c.kind) && !plainBinder(c, seams)) return false;
		return true;
	}

	/** Resolve every seam the check reads, or null when one it cannot work without is unset. */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final lambdaKinds: Array<String> = shape.lambdaKinds ?? [];
		final callKind: Null<String> = shape.callKind;
		if (lambdaKinds.length == 0 || callKind == null) return null;
		final modifiers: Array<String> = (shape.modifierOrderKinds ?? []).concat(shape.visibilityModifierKinds ?? []);
		for (kind in [
			 shape.staticModifierKind, shape.inlineModifierKind,    shape.macroModifierKind,
			shape.dynamicModifierKind, shape.externModifierKind, shape.overrideModifierKind
		]) {
			if (kind != null && !modifiers.contains(kind)) modifiers.push(kind);
		}
		return {
			lambdaKinds: lambdaKinds,
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
			binderKinds: (shape.localDeclKinds ?? []).concat(shape.paramKinds ?? [])
				.concat(shape.localDeclExprKinds ?? [])
				.concat(shape.staticLocalDeclKinds ?? [])
				.concat(shape.localDeclContinuationKinds ?? [])
				.concat(shape.selfScopeDeclKinds ?? [])
				.concat(shape.casePatternBinderKinds ?? [])
				.concat(shape.iterationValueBinderKinds ?? []),
			modifierKinds: modifiers,
			metaKinds: plugin.metaShape().metaKinds,
			staticModifierKind: shape.staticModifierKind,
			dynamicModifierKind: shape.dynamicModifierKind,
			macroModifierKind: shape.macroModifierKind,
			conditionalMemberKind: shape.conditionalMemberKind,
			constructorName: shape.constructorName,
			upperInitialTypes: shape.upperInitialNeverCaptures == true
		};
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
	final localFns: Map<String, Signature>;
};

/** The resolved seams plus the per-run tables `walk` reads. */
private typedef Ctx = {
	final seams: Seams;
	final types: Map<String, Null<Map<String, Signature>>>;
	final scope: FileScope;
};

/** Every seam `RedundantLambdaWrapper` reads, resolved once per run. */
private typedef Seams = {
	final lambdaKinds: Array<String>;
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
	final modifierKinds: Array<String>;
	final metaKinds: Array<String>;
	final staticModifierKind: Null<String>;
	final dynamicModifierKind: Null<String>;
	final macroModifierKind: Null<String>;
	final conditionalMemberKind: Null<String>;
	final constructorName: Null<String>;
	final upperInitialTypes: Bool;
};
