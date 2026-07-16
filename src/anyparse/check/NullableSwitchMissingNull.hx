package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.NullFlow.NullFacts;
import anyparse.check.NullableSource.NullableSourceCfg;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

/**
 * Flags a `switch` over a **provably-nullable subject** whose branches include a
 * catch-all wildcard (`case _:` / `default:`) but NO `case null` — a latent NPE.
 * Haxe's `case _:` and `default:` do NOT match `null` (the compiler skips the null
 * check for them), so switching a null subject falls through every arm: on hxcpp a
 * null enum subject SEGFAULTS, on the other targets the null silently matches no
 * branch. The author believes the wildcard covers everything; null is the one value
 * it does not. `Severity.Warning`, REPORT-ONLY — the fix is `case null, _:` or an
 * explicit `case null:` arm, but the right BODY for the null case is the author's
 * call (the wildcard body might be right for null, might not), so v1 does not
 * auto-insert.
 *
 * ## Trigger — all three
 *
 * A switch is flagged when (1) its subject is provably nullable, (2) some branch is
 * an UNGUARDED wildcard — a `default:` (`defaultBranchKind`) or a `case _:` whose
 * pattern is `wildcardPatternName` and which carries no guard — and (3) no branch
 * mentions `null` (`case null:` / `case null, _:` / any pattern that is the null
 * literal, guarded or not, all count as handling null). Without a wildcard the
 * compiler's own exhaustiveness forces the null case on enums and a non-exhaustive
 * non-enum switch simply no-matches, so ONLY wildcard switches are flagged.
 *
 * ## Provably-nullable subject
 *
 * Routed through the `NullFlow` engine (the mechanism-A machinery
 * `unguarded-nullable-deref` uses), so a subject narrowed non-null on the path
 * (`if (x == null) return; switch x`) is a safe miss and a local bound from a
 * nullable source is caught. A bare-identifier subject is nullable when, at the
 * switch, flow does not prove it non-null AND either: flow proves it `MaybeNull`
 * (bound from a `Map` index / `Null<T>` call — source 2) or `Null`; its declared
 * type's outer nominal is a `Null<…>` wrapper (`nullableReturnMarkerTypes`, so
 * `Dynamic` / `Any` are excluded) for a LOCAL or PARAMETER binding only — a bare field never narrows, so it stays out of scope (source 1a); or it binds to an optional parameter
 * (`?x:T`, `optionalParamKind` — source 1b). A non-identifier subject is nullable
 * when it is itself a nullable-source expression — a `Map` index, an `Array` /
 * `List` nullable call, a `Null<T>`-returning call (`NullableSource.describe`,
 * source 3). A `?`-coalesced subject (`switch (x ?? d)`, `nullCoalesceKind`) is
 * never nullable (the `??` removes null). A bare field / `this.f` subject is out of
 * v1 scope, and only switches inside a function body are analyzed (the flow
 * engine's scope) — a field-initializer switch is a documented miss.
 *
 * ## Grammar-agnostic
 *
 * Required: `switchKinds`, `caseBranchKind`, `plainCasePatternKind`, `identKind`,
 * `nullLiteralKind`, `wildcardPatternName` (any unset → no-op). Optional:
 * `defaultBranchKind` (the `default:` wildcard), `parenKind` (guard detection),
 * `nullCoalesceKind`, `optionalParamKind`, `nullableReturnMarkerTypes`, and the
 * `NullableSource` config for sources 2 / 3. Needs `plugin is TypeInfoProvider` for
 * declared-type / return resolution.
 */
@:nullSafety(Strict)
final class NullableSwitchMissingNull implements Check {

	public function new() {}

	public function id(): String {
		return 'nullable-switch-missing-null';
	}

	public function description(): String {
		return
			'a switch over a nullable subject with a wildcard (case _ / default) but no case null — a latent NPE (case _ does not match null)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final seams: Null<Seams> = readSeams(shape);
		if (seams == null) return [];
		final s: Seams = seams;
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		if (provider == null) return [];
		final typed: TypeInfoProvider = provider;
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final root: QueryNode = tree;
			final declaredTypes: Map<Int, String> = typed.declaredTypes(entry.source);
			final returnTypes: Map<Int, String> = typed.returnTypes(entry.source);
			final ctx: FileCtx = {
				file: entry.file,
				root: root,
				declaredTypes: declaredTypes,
				returnTypes: returnTypes,
				s: s,
				index: index
			};
			final seed: Null<(QueryNode) -> Bool> = makeSeed(s.cfg, root, declaredTypes, returnTypes, index);
			NullFlow.analyze(tree, shape, entry.source, (node, facts) -> checkSwitch(violations, node, facts, ctx), seed);
		}
		return violations;
	}

	/** No safe single edit — report-only (the null arm's body is the author's call). */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/** Bundle the required + optional `RefShape` kinds, or null when a required one is unset (the check is then a no-op). */
	private static function readSeams(shape: RefShape): Null<Seams> {
		final switchKinds: Null<Array<String>> = shape.switchKinds;
		if (switchKinds == null || switchKinds.length == 0) return null;
		final caseBranchKind: Null<String> = shape.caseBranchKind;
		if (caseBranchKind == null) return null;
		final plainKind: Null<String> = shape.plainCasePatternKind;
		if (plainKind == null) return null;
		final nullLitKind: Null<String> = shape.nullLiteralKind;
		if (nullLitKind == null) return null;
		final wildcardName: Null<String> = shape.wildcardPatternName;
		return wildcardName == null ? null : {
			shape: shape,
			switchKinds: switchKinds,
			caseBranchKind: caseBranchKind,
			plainKind: plainKind,
			identKind: shape.identKind,
			nullLitKind: nullLitKind,
			wildcardName: wildcardName,
			defaultBranchKind: shape.defaultBranchKind,
			parenKind: shape.parenKind,
			nullCoalesceKind: shape.nullCoalesceKind,
			optionalParamKind: shape.optionalParamKind,
			localDeclKinds: shape.localDeclKinds ?? [],
			paramKinds: shape.paramKinds ?? [],
			nullMarkers: shape.nullableReturnMarkerTypes ?? [],
			callKind: shape.callKind,
			fieldAccessKind: shape.fieldAccessKind,
			nullAssertionCalls: shape.nullAssertionCalls ?? [],
			cfg: NullableSource.build(shape, shape.nullableFlowExcludedCalls ?? [])
		};
	}

	/** The `MaybeNull` seed for `NullFlow` — a local assigned a nullable-source RHS — or null when no nullable source is configured. */
	private static function makeSeed(
		cfg: Null<NullableSourceCfg>, root: QueryNode, declaredTypes: Map<Int, String>, returnTypes: Map<Int, String>, index: SymbolIndex
	): Null<(QueryNode) -> Bool> {
		if (cfg == null) return null;
		final c: NullableSourceCfg = cfg;
		return rhs -> NullableSource.describe(rhs, root, declaredTypes, returnTypes, c, index) != null;
	}

	/**
	 * When `node` is a switch with an unguarded wildcard, no null arm, and a
	 * provably-nullable subject, push a finding spanned at the subject. Invoked by
	 * `NullFlow` at every node with the facts holding at the switch's entry.
	 */
	private static function checkSwitch(out: Array<Violation>, node: QueryNode, facts: NullFacts, ctx: FileCtx): Void {
		final s: Seams = ctx.s;
		if (!s.switchKinds.contains(node.kind) || node.children.length < 1) return;
		var hasNullArm: Bool = false;
		var hasWildcard: Bool = false;
		for (i in 1...node.children.length) {
			final branch: QueryNode = node.children[i];
			if (s.defaultBranchKind != null && branch.kind == s.defaultBranchKind) {
				hasWildcard = true;
				continue;
			}
			if (branch.kind != s.caseBranchKind) continue;
			final guarded: Bool = branchGuarded(branch, s);
			for (p in branch.children) if (p.kind == s.plainKind && p.children.length >= 1) {
				final pat: QueryNode = p.children[0];
				if (pat.kind == s.nullLitKind)
					hasNullArm = true;
				else if (!guarded && pat.kind == s.identKind && pat.name == s.wildcardName)
					hasWildcard = true;
			}
		}
		if (!hasWildcard || hasNullArm) return;
		final subject: QueryNode = node.children[0];
		if (!subjectNullable(subject, facts, ctx)) return;
		final span: Null<Span> = subject.span;
		if (span != null) out.push({
			file: ctx.file,
			span: span,
			rule: 'nullable-switch-missing-null',
			severity: Severity.Warning,
			message: 'switch subject is nullable but case _ / default does not match null — add case null (case null, _:) or narrow the subject'
		});
	}

	/** Whether `branch` carries a case guard — a direct `parenKind` child sits between its patterns and its body. */
	private static function branchGuarded(branch: QueryNode, s: Seams): Bool {
		final parenKind: Null<String> = s.parenKind;
		if (parenKind == null) return false;
		for (c in branch.children) if (c.kind == parenKind) return true;
		return false;
	}

	/**
	 * Whether `subject` is provably nullable at the switch — a flow-narrowed non-null
	 * bare identifier is safe; otherwise a `MaybeNull` / `Null`-by-flow, `Null<…>`-declared,
	 * or optional-parameter identifier, or a nullable-source expression, is nullable. A
	 * `?`-coalesced subject is never nullable.
	 */
	private static function subjectNullable(subject: QueryNode, facts: NullFacts, ctx: FileCtx): Bool {
		final s: Seams = ctx.s;
		final coalKind: Null<String> = s.nullCoalesceKind;
		if (coalKind != null && subject.kind == coalKind) return false;
		if (subject.kind == s.identKind) {
			final name: Null<String> = subject.name;
			if (name == null) return false;
			final n: String = name;
			if (facts.nonNull(n)) return false;
			if (facts.isMaybeNull(n) || facts.isNull(n)) return true;
			final bindingFrom: Null<Int> = TypeResolver.identBindingFrom(subject, ctx.root, s.shape);
			if (bindingFrom == null) return false;
			final from: Int = bindingFrom;
			if (assertedNonNullBefore(subject, from, ctx)) return false;
			final declared: Null<String> = ctx.declaredTypes[from];
			if (
				declared != null && s.nullMarkers.contains(declared)
				&& TypeResolver.bindingIsLocalOrParam(ctx.root, from, s.localDeclKinds, s.paramKinds)
			)
				return true;
			final optKind: Null<String> = s.optionalParamKind;
			return optKind != null && TypeResolver.bindingIsOptionalParam(ctx.root, from, optKind);
		}
		final cfg: Null<NullableSourceCfg> = s.cfg;
		return cfg != null && NullableSource.describe(subject, ctx.root, ctx.declaredTypes, ctx.returnTypes, cfg, ctx.index) != null;
	}


	/**
	 * Whether a `nullAssertionCalls` assertion (`Assert.notNull(x)`) proving the
	 * subject non-null runs before the switch — `NullFlow` clears only the `MaybeNull`
	 * fact for such a call (never set for a parameter or a field-derived local), so the
	 * flow-insensitive declared-type / optional-param sources honour it here. The
	 * assertion's argument must resolve to the SAME binding as the subject (so a
	 * same-named assertion in another scope does not falsely clear it) and lie before
	 * the switch.
	 */
	private static function assertedNonNullBefore(subject: QueryNode, bindingFrom: Int, ctx: FileCtx): Bool {
		final s: Seams = ctx.s;
		if (s.nullAssertionCalls.length == 0) return false;
		final subjSpan: Null<Span> = subject.span;
		if (subjSpan == null) return false;
		final subjFrom: Int = subjSpan.from;
		var found: Bool = false;
		function walk(node: QueryNode): Void {
			if (found) return;
			final arg: Null<QueryNode> = assertionArg(node, s);
			if (arg != null) {
				final argSpan: Null<Span> = arg.span;
				if (argSpan != null && argSpan.to <= subjFrom && TypeResolver.identBindingFrom(arg, ctx.root, s.shape) == bindingFrom) {
					found = true;
					return;
				}
			}
			for (c in node.children) walk(c);
		}
		walk(ctx.root);
		return found;
	}

	/** The plain-identifier argument of a `nullAssertionCalls` call (`Assert.notNull(x)`), or null when `node` is not one. */
	private static function assertionArg(node: QueryNode, s: Seams): Null<QueryNode> {
		final callKind: Null<String> = s.callKind;
		final fieldAccessKind: Null<String> = s.fieldAccessKind;
		if (callKind == null || fieldAccessKind == null || node.kind != callKind || node.children.length != 2) return null;
		final callee: QueryNode = node.children[0];
		final method: Null<String> = callee.name;
		if (callee.kind != fieldAccessKind || method == null || callee.children.length != 1) return null;
		final recv: QueryNode = callee.children[0];
		final recvName: Null<String> = recv.name;
		if (recv.kind != s.identKind || recvName == null || !s.nullAssertionCalls.contains('${recvName}.${method}')) return null;
		final arg: QueryNode = node.children[1];
		return arg.kind == s.identKind ? arg : null;
	}

}

/** The `RefShape` kinds `NullableSwitchMissingNull` reads, bundled once so the walkers take one argument. */
private typedef Seams = {
	var shape: RefShape;
	var switchKinds: Array<String>;
	var caseBranchKind: String;
	var plainKind: String;
	var identKind: String;
	var nullLitKind: String;
	var wildcardName: String;
	var defaultBranchKind: Null<String>;
	var parenKind: Null<String>;
	var nullCoalesceKind: Null<String>;
	var optionalParamKind: Null<String>;
	var localDeclKinds: Array<String>;
	var paramKinds: Array<String>;
	var nullMarkers: Array<String>;
	var callKind: Null<String>;
	var fieldAccessKind: Null<String>;
	var nullAssertionCalls: Array<String>;
	var cfg: Null<NullableSourceCfg>;
}

/** Per-file context threaded to the `NullFlow` visit callback. */
private typedef FileCtx = {
	var file: String;
	var root: QueryNode;
	var declaredTypes: Map<Int, String>;
	var returnTypes: Map<Int, String>;
	var s: Seams;
	var index: SymbolIndex;
}
