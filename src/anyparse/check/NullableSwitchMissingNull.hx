package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.NullFlow.NullFacts;
import anyparse.check.NullableSource.NullableSourceCfg;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

using StringTools;

/**
 * Flags a `switch` over a **provably-nullable ENUM subject** that has NO arm matching null
 * and NO wildcard — the one shape whose null subject is dereferenced. Reading a value's
 * constructor tag is what a wildcard-less enum switch compiles to, and it happens BEFORE any
 * pattern is tried, so a null subject faults: hxcpp SIGSEGVs, js throws
 * `Cannot read properties of null (reading '_hx_index')`, eval throws `Null Access`.
 * `Severity.Warning`, REPORT-ONLY — there is no catch-all body to route null into, so what
 * `case null` should DO is the author's decision, not a mechanical edit.
 *
 * ## Why a wildcard makes the shape safe
 *
 * `case _:` / `default:` is the exact opposite of a hazard here: its presence makes the
 * compiler emit a null check ahead of the tag read, and null then lands in the wildcard body.
 * Measured on hxcpp (with and without `-D analyzer-optimize -dce full`), js and eval, for
 * `String`, `Null<Int>` and `enum` subjects, in statement and expression position — every
 * wildcard shape routes null to the wildcard and none faults. A wildcard-less switch over a
 * NON-enum subject is equally safe: it compiles to plain comparisons, which null simply fails
 * to match, and control falls past the switch.
 *
 * So the trigger is the CONJUNCTION of three things, each necessary: nullable subject,
 * runtime-tagged (enum) subject type, and no arm — wildcard or `case null` — that catches
 * null. Drop any one and the shape does not fault.
 *
 * ## Trigger — all four
 *
 * (1) No branch is a wildcard: a `default:` (`defaultBranchKind`) or a `case _:` whose
 * pattern is `wildcardPatternName`. A GUARD does not weaken it —
 * `case _ if (false)` over a null enum was measured surviving on hxcpp, so the mere
 * presence of the arm is what makes the compiler emit the null check. (2) No branch
 * mentions `null`
 * (`case null:` / `case null, _:` / any null-literal pattern, guarded or not). (3) The subject
 * is provably nullable. (4) The subject's declared type is a `runtimeTaggedTypeKinds`
 * declaration the `SymbolIndex` can resolve — a real `enum`, `Null<T>` unwrapped first. An
 * `enum abstract` is deliberately excluded: its values ARE the underlying primitives, so its
 * switch is plain comparisons.
 *
 * ## Provably-nullable subject
 *
 * Routed through the `NullFlow` engine (the mechanism-A machinery `unguarded-nullable-deref`
 * uses), so a subject narrowed non-null on the path (`if (x == null) return; switch x`) is a
 * safe miss and a local bound from a nullable source is caught. A bare-identifier subject is
 * nullable when, at the switch, flow does not prove it non-null AND either: flow proves it
 * `MaybeNull` (bound from a `Map` index / `Null<T>` call — source 2) or `Null`; its declared
 * type's outer nominal is a `Null<…>` wrapper (`nullableReturnMarkerTypes`, so `Dynamic` /
 * `Any` are excluded) for a LOCAL or PARAMETER binding only — a bare field never narrows, so
 * it stays out of scope (source 1a); or it binds to an optional parameter (`?x:T`,
 * `optionalParamKind` — source 1b). Gate (4) then re-reads the same binding, so a
 * non-identifier subject — a `Map` index, a nullable call — never reaches the finding even
 * when flow calls it nullable: there is no declared type to prove the enum with, and the
 * check fails closed. A `?`-coalesced subject (`switch (x ?? d)`, `nullCoalesceKind`) is never
 * nullable. Only switches inside a function body are analyzed (the flow engine's scope) — a
 * field-initializer switch is a documented miss.
 *
 * ## Grammar-agnostic
 *
 * Required: `switchKinds`, `caseBranchKind`, `plainCasePatternKind`, `identKind`,
 * `nullLiteralKind`, `wildcardPatternName`, `runtimeTaggedTypeKinds` (any unset → no-op).
 * Optional: `defaultBranchKind`, `parenKind` (guard detection), `nullCoalesceKind`,
 * `optionalParamKind`, `nullableReturnMarkerTypes`, and the `NullableSource` config for
 * sources 2 / 3. Needs `plugin is TypeInfoProvider` for declared-type / return resolution.
 */
@:nullSafety(Strict)
final class NullableSwitchMissingNull implements Check {

	public function new() {}

	public function id(): String {
		return 'nullable-switch-missing-null';
	}

	public function description(): String {
		return 'a wildcard-less switch over a nullable enum subject with no case null — the constructor-tag read dereferences null';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final seams: Null<Seams> = readSeams(shape);
		if (seams == null) return [];
		final s: Seams = seams;
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
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
				declaredTypeSources: typed.declaredTypeSources(entry.source),
				returnTypes: returnTypes,
				s: s,
				index: index
			};
			final seed: Null<(QueryNode) -> Bool> = makeSeed(s.cfg, root, declaredTypes, returnTypes, index);
			NullFlow.analyze(tree, shape, entry.source, (node, facts) -> checkSwitch(violations, node, facts, ctx), seed);
		}
		return violations;
	}

	/** Route null through the switch's lone wildcard/default arm — rewrite its head to `case null, _:`. */
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
		if (wildcardName == null) return null;
		final taggedKinds: Null<Array<String>> = shape.runtimeTaggedTypeKinds;
		return taggedKinds == null || taggedKinds.length == 0 ? null : {
			taggedKinds: taggedKinds,
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
			assertTrueCalls: shape.assertTrueCalls ?? [],
			assertFalseCalls: shape.assertFalseCalls ?? [],
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
			for (p in branch.children) if (p.kind == s.plainKind && p.children.length >= 1) {
				final pat: QueryNode = p.children[0];
				if (pat.kind == s.nullLitKind)
					hasNullArm = true;
				else if (pat.kind == s.identKind && pat.name == s.wildcardName)
					hasWildcard = true;
			}
		}
		if (hasWildcard || hasNullArm) return;
		final subject: QueryNode = node.children[0];
		if (!subjectNullable(subject, facts, ctx) || !subjectRuntimeTagged(subject, ctx)) return;
		final span: Null<Span> = subject.span;
		if (span != null) out.push({
			file: ctx.file,
			span: span,
			rule: 'nullable-switch-missing-null',
			severity: Severity.Warning,
			message: 'switch subject is a nullable enum and no arm matches null — reading the constructor tag off null'
			+ ' dereferences it; add case null or narrow the subject'
		});
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
				&& TypeResolver.mayBeLocalOrParam(ctx.root, from, s.localDeclKinds, s.paramKinds)
			)
				return true;
			final optKind: Null<String> = s.optionalParamKind;
			return optKind != null && TypeResolver.bindingIsOptionalParam(ctx.root, from, optKind);
		}
		final cfg: Null<NullableSourceCfg> = s.cfg;
		return cfg != null && NullableSource.describe(subject, ctx.root, ctx.declaredTypes, ctx.returnTypes, cfg, ctx.index) != null;
	}

	/**
	 * Whether `subject` is a bare identifier whose DECLARED type is a runtime-tagged type
	 * (`Seams.taggedKinds` — a real `enum`), the one subject shape whose wildcard-less switch
	 * dereferences a null value: the generated code reads the constructor tag off the subject
	 * before any pattern is tried. A `Null<T>` wrapper is unwrapped first, so both
	 * `x:Null<Colour>` and a flow-nullable `x:Colour` answer true. Every other shape answers
	 * FALSE and the site is not flagged: a non-identifier subject (no declared type to resolve),
	 * a type the `SymbolIndex` cannot see (an out-of-scope or stdlib enum), an `enum abstract`
	 * (its values ARE the underlying primitives, so the switch is plain comparisons a null
	 * subject merely fails to match), and every ordinary class / string / numeric subject.
	 */
	private static function subjectRuntimeTagged(subject: QueryNode, ctx: FileCtx): Bool {
		final s: Seams = ctx.s;
		if (subject.kind != s.identKind) return false;
		final bindingFrom: Null<Int> = TypeResolver.identBindingFrom(subject, ctx.root, s.shape);
		if (bindingFrom == null) return false;
		final declared: Null<String> = ctx.declaredTypeSources[bindingFrom];
		if (declared == null) return false;
		final inner: String = unwrapNullable(declared, s);
		for (hit in ctx.index.resolveTypeRefsFrom(inner, ctx.file)) if (s.taggedKinds.contains(hit.type.kind)) return true;
		return false;
	}

	/**
	 * The type argument of a `Null<T>`-style wrapper in the declared-type SOURCE `declared`, or
	 * `declared` trimmed when it carries no wrapper. Only a wrapper named in `Seams.nullMarkers`
	 * is unwrapped, and only one level -- `Null<Null<T>>` is not a shape Haxe produces.
	 */
	private static function unwrapNullable(declared: String, s: Seams): String {
		final trimmed: String = declared.trim();
		final open: Int = trimmed.indexOf('<');
		if (open <= 0 || !trimmed.endsWith('>')) return trimmed;
		return s.nullMarkers.contains(trimmed.substring(0, open)) ? trimmed.substring(open + 1, trimmed.length - 1).trim() : trimmed;
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

	/**
	 * The identifier a precondition call proves non-null before `node` runs — the plain-ident argument of a `nullAssertionCalls` call (`Assert.notNull(x)`), or the operand a `assertTrueCalls`/`assertFalseCalls` relational assert narrows non-null (`Assert.isTrue(x != null)` / `Assert.isFalse(x == null)`); null when `node` is neither.
	 */
	private static function assertionArg(node: QueryNode, s: Seams): Null<QueryNode> {
		final callKind: Null<String> = s.callKind;
		final fieldAccessKind: Null<String> = s.fieldAccessKind;
		if (callKind == null || fieldAccessKind == null || node.kind != callKind || node.children.length != 2) return null;
		final callee: QueryNode = node.children[0];
		final method: Null<String> = callee.name;
		if (callee.kind != fieldAccessKind || method == null || callee.children.length != 1) return null;
		final recv: QueryNode = callee.children[0];
		final recvName: Null<String> = recv.name;
		if (recv.kind != s.identKind || recvName == null) return null;
		final dotted: String = '${recvName}.${method}';
		final arg: QueryNode = node.children[1];
		// A direct non-null precondition (`Assert.notNull(x)`) — the plain-ident argument.
		if (s.nullAssertionCalls.contains(dotted)) return arg.kind == s.identKind ? arg : null;
		// A relational precondition (`Assert.isTrue(x != null)` / `Assert.isFalse(x == null)`) — the
		// operand a bare or parenthesized null comparison proves non-null on the asserted outcome.
		final asTrue: Bool = s.assertTrueCalls.contains(dotted);
		final asFalse: Bool = s.assertFalseCalls.contains(dotted);
		return asTrue == asFalse ? null : relationalAssertOperand(arg, s, asTrue);
	}


	/**
	 * The plain own-name operand a bare (or parenthesized) null comparison proves non-null on
	 * the asserted outcome: for a truth assert (`asTrue`) an `x != null`, for a falsity assert an
	 * `x == null` (whose false outcome is `x != null`). Any other shape — a compound `&&`/`||`, a
	 * wrong-polarity comparison, a non-comparison — returns null (the switch stays flagged; a
	 * refusal only ever KEEPS a finding). Compound and De-Morgan `!` forms are intentionally the
	 * flow-based `NullFlow` path's job, not this positional scanner's.
	 */
	private static function relationalAssertOperand(arg: QueryNode, s: Seams, asTrue: Bool): Null<QueryNode> {
		final e: QueryNode = RefactorSupport.unwrapParens(arg, s.parenKind);
		final wantKind: Null<String> = asTrue ? s.shape.notEqKind : s.shape.eqKind;
		return wantKind == null || e.kind != wantKind ? null : NullFlow.nullComparisonOperand(e, s.identKind, s.nullLitKind);
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
	var taggedKinds: Array<String>;
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
	var assertTrueCalls: Array<String>;
	var assertFalseCalls: Array<String>;
	var cfg: Null<NullableSourceCfg>;
}

/** Per-file context threaded to the `NullFlow` visit callback. */
private typedef FileCtx = {
	var file: String;
	var root: QueryNode;
	var declaredTypes: Map<Int, String>;
	var declaredTypeSources: Map<Int, String>;
	var returnTypes: Map<Int, String>;
	var s: Seams;
	var index: SymbolIndex;
}
