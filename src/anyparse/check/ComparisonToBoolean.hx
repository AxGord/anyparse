package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import anyparse.query.TypeResolver;
import anyparse.query.TypeInfoProvider;

/**
 * Flags a comparison against a boolean literal — `x == true`, `x != false` and the like —
 * where the literal adds nothing (SonarLint S1125). Structural shape plus a type gate;
 * `Severity.Info`. `fix` rewrites the comparison to its operand — `x == true` /
 * `x != false` → `x`, `x == false` / `x != true` → `!x` — but ONLY when the operand is
 * provably non-null Bool. All four rewrites ride the SAME proof, because on a nullable
 * operand they are not symmetric (see the null-safety caveat below).
 *
 * ## Constant fold
 *
 * A comparison where BOTH operands are boolean literals (`true == true`) is a separate
 * case: it is always reported (no type gate needed — both sides are literals, provably
 * non-null), and `fix` folds the whole comparison to its constant value —
 * `true == true` → `true`, `true != true` → `false`. Like the rest of `fix`, the fold
 * needs `eqKind` to tell `==` from `!=`; without it the case stays report-only.
 *
 * ## Null-safety caveat
 *
 * Under strict null-safety `expr == true` on a `Null<Bool>` is REQUIRED — `if (x)` on a
 * nullable Bool does not compile — so that `== true` is load-bearing, not redundant. And
 * even where it does compile the four rewrites diverge: measured on hxcpp with a `null`
 * `Null<Bool>`, `x == true` is `false` and `x != true` is `true`, matching `x` / `!x`,
 * while `x == false` is `false` where `!x` is `true` — so the `false`-literal pair would
 * CHANGE the value. Rather than license two of four on a nullable operand, the check
 * demands a non-nullable Bool for all four and stays silent otherwise.
 *
 * Two proofs grant it, and an operand with neither is skipped. STRUCTURALLY: a
 * boolean-operator result (`RefShape.comparisonKinds` ∪ `RefShape.notKind`, parentheses
 * unwrapped — non-null `Bool` by construction), or a bare identifier whose declared type
 * proves non-null Bool (`TypeResolver.isProvablyNonNull` over
 * `TypeInfoProvider.declaredTypes`) — a `Null<Bool>` local, an optional parameter, or an
 * unannotated / unresolvable identifier stays silent. This arm sits behind a blanket veto
 * on any operand subtree reaching `RefShape.nullableOperandKinds` (Haxe `Call` /
 * `FieldAccess` / `SafeFieldAccess`: a method or `Map.get` result, a possibly-`@:optional`
 * field, a `?.` access). BY RESOLVED TYPE: a FIELD ACCESS whose receiver type resolves and
 * whose member's declared type is one of `RefShape.nonNullableTypeNames` — `object.visible`
 * on an `openfl` `DisplayObject`, and (through `TypeInfoProvider.castTargetSources`, since
 * the projection drops the written target) `cast(object, DisplayObjectContainer).mouseEnabled`
 * on the cast target's own or INHERITED member. This is the one arm that may pass the veto,
 * because a member declared plain `Bool` is not of unknown nullability. An ANONYMOUS-STRUCTURE
 * receiver is refused wholesale: an `@:optional` field is nullable while carrying a bare
 * `Bool` annotation, and the member table records both identically.
 *
 * Grammars with no `TypeInfoProvider` fall back to reporting bare identifiers for a human to
 * judge; `fix` leaves those untouched (no proof, so the `== true` may be load-bearing). The
 * check does not descend into macro-reification subtrees (`RefShape.opaqueKinds`), whose
 * comparisons are generated code rather than authored style.
 *
 * ## Grammar-agnostic
 *
 * Equality kinds come from `RefShape.equalityKinds`, the literal from `RefShape.boolLitKind`,
 * the nullable-operand skip from `RefShape.nullableOperandKinds` (falling back to the single
 * `RefShape.nullSafeAccessKind` when unset), the macro skip from `RefShape.opaqueKinds`, the
 * identifier gate from `TypeInfoProvider.declaredTypes` + the nullability seams
 * (`nonNullableTypeNames` / `nullableWrapperTypeNames`), the boolean-operator half of the
 * provably-Bool gate from `RefShape.comparisonKinds` + `RefShape.notKind`, and the
 * resolved-type arm from `RefShape.fieldAccessKind` / `typedCastKinds` +
 * `TypeInfoProvider.castTargetSources` + the `SymbolIndex`. Unset equality kinds or literal
 * kind makes the check a no-op; an unset `fieldAccessKind` drops just the resolved-type arm.
 */
@:nullSafety(Strict)
final class ComparisonToBoolean implements Check {

	private static inline final RULE_ID: String = 'comparison-to-boolean';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a comparison against a boolean literal (x == true / x != false / true == true)';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		// Lazy: the resolution scope reads the configured libraries, and only the field-access
		// proof ever demands it — after every cheaper arm on every candidate has failed.
		final index: () -> Null<SymbolIndex> = RefactorSupport.lazySymbolIndex(files, plugin);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			walk(violations, tree, seams, proofOf(entry.file, entry.source, tree, provider, index));
		}
		return violations;
	}

	/**
	 * Rewrite each flagged comparison to its operand. `x == true` / `x != false` collapse
	 * to the operand verbatim; `x == false` / `x != true` collapse to its negation
	 * (`!operand`, parenthesized unless the operand is atomic — a bare identifier, an
	 * already-parenthesized expression, or a field access — so the unary `!` binds correctly).
	 * Emitted for any operand `operandProven` accepts, with the no-proof fallback OFF: an
	 * unresolved bare identifier is left to the report, since its `== true` may be
	 * load-bearing under strict null-safety. `eqKind` tells `==` from `!=` — it is required
	 * HERE only (unset → report-only), not in `run`'s gate.
	 *
	 * The resolved-type arm needs a `SymbolIndex`; `fixIndex` supplies the run's
	 * resolution-scoped one when the plugin hosts it, the caller's otherwise, and as a last
	 * resort one built over `source` alone (enough for a same-file receiver type). The file the
	 * member lookup resolves imports against comes from the violations themselves.
	 *
	 * When both operands are boolean literals (`true == true`), the whole comparison is
	 * folded to its constant value instead — `true == true` → `true`, `true != true` →
	 * `false` — via `comparisonEdit`'s dedicated branch; no type gate applies, since two
	 * literal operands are provably non-null. Like the single-literal path, the fold needs
	 * `eqKind`, so it stays report-only when `eqKind` is unset.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final maybeEqKind: Null<String> = seams.eqKind;
		final maybeRoot: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (maybeEqKind == null || maybeRoot == null) return [];
		final eqKind: String = maybeEqKind;
		final root: QueryNode = maybeRoot;
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		final file: String = violations.length > 0 ? violations[0].file : '';
		final proof: TypeProof = proofOf(file, source, root, provider, fixIndex(file, source, plugin, index));
		return CheckScan.applyBySpan(
			plugin, source, violations, seams.equalityKinds, (node, span) -> comparisonEdit(node, span, source, seams, proof, eqKind)
		);
	}

	/**
	 * The lazy `SymbolIndex` the fix resolves member types through: the run's resolution-scoped
	 * index when the plugin hosts one, else the caller's report-scoped index, else — a direct
	 * `check.fix` against a bare plugin — one built over `source` ALONE, which still resolves a
	 * same-file receiver type. Lazy, so a fix set with no field-access operand builds nothing.
	 */
	private static function fixIndex(
		file: String, source: String, plugin: GrammarPlugin, supplied: Null<SymbolIndex>
	): () -> Null<SymbolIndex> {
		var built: Null<SymbolIndex> = null;
		return () -> {
			final ready: Null<SymbolIndex> = RefactorSupport.resolutionIndexOf(plugin) ?? supplied ?? built;
			if (ready != null) return ready;
			final fresh: SymbolIndex = SymbolIndex.build([{ file: file, source: source }], plugin);
			built = fresh;
			return fresh;
		};
	}

	/**
	 * The per-file resolution context the resolved-type proof reads. `castTargets` is memoized
	 * because recovering it costs a SECOND full parse of the file, and `index` is the run's lazy
	 * `SymbolIndex` — neither is touched until a field-access operand actually reaches the proof.
	 */
	private static function proofOf(
		file: String, source: String, root: QueryNode, provider: Null<TypeInfoProvider>, index: () -> Null<SymbolIndex>
	): TypeProof {
		var casts: Null<Map<Int, String>> = null;
		return {
			file: file,
			root: root,
			declaredTypes: provider != null ? provider.declaredTypes(source) : null,
			castTargets: () -> {
				final ready: Null<Map<Int, String>> = casts;
				if (ready != null) return ready;
				final p: Null<TypeInfoProvider> = provider;
				final computed: Map<Int, String> = p != null ? p.castTargetSources(source) : [];
				casts = computed;
				return computed;
			},
			index: index
		};
	}

	/**
	 * Walk `node`, flagging an equality whose exactly one operand is a boolean literal and
	 * whose other operand `operandProven` accepts with the report's no-proof fallback ON —
	 * a boolean-operator result, a bare identifier whose declared type proves non-null Bool, or
	 * a field access whose resolved member type does. A `Null<Bool>` local's `== true` is
	 * load-bearing under strict null-safety, and an unresolvable / unannotated identifier cannot
	 * be verified, so both stay silent; without a `TypeInfoProvider` the identifier falls back to
	 * being reported for a human to judge. Macro reification subtrees (`opaqueKinds`) are not
	 * descended into.
	 *
	 * A comparison where BOTH operands are boolean literals (`true == true`) is flagged
	 * unconditionally in a separate branch — no provably-Bool gate applies, since two literal
	 * operands are provably non-null.
	 */
	private static function walk(out: Array<Violation>, node: QueryNode, seams: Seams, proof: TypeProof): Void {
		if (seams.opaqueKinds.contains(node.kind)) return;
		final span: Null<Span> = node.span;
		if (span != null && node.children.length == 2 && seams.equalityKinds.contains(node.kind)) {
			final leftIsBool: Bool = node.children[0].kind == seams.boolLitKind;
			final rightIsBool: Bool = node.children[1].kind == seams.boolLitKind;
			if (leftIsBool && rightIsBool) {
				out.push({
					file: proof.file,
					span: span,
					rule: RULE_ID,
					severity: Severity.Info,
					message: 'constant boolean comparison'
				});
			} else if (leftIsBool != rightIsBool) {
				final other: QueryNode = leftIsBool ? node.children[1] : node.children[0];
				if (operandProven(other, seams, proof, true)) out.push({
					file: proof.file,
					span: span,
					rule: RULE_ID,
					severity: Severity.Info,
					message: 'comparison against a boolean literal'
				});
			}
		}
		for (c in node.children) walk(out, c, seams, proof);
	}

	/**
	 * Whether `other` is a PROVABLY non-null Bool operand — the shared gate for BOTH the report
	 * (`walk`) and the autofix (`comparisonEdit`). Two independent proofs, cheapest first:
	 *
	 *  - the STRUCTURAL one (`operandProvablyBool`), behind the blanket `nullableKinds` subtree
	 *    veto that has always guarded it: a boolean-operator result, or a bare identifier whose
	 *    declared type proves non-null Bool.
	 *  - the RESOLVED-TYPE one (`resolvedNonNullBool`), which reads a FIELD ACCESS's member type
	 *    out of the `SymbolIndex`. It is the ONE arm allowed past that veto, and only because the
	 *    veto exists to refuse an operand of UNKNOWN nullability — a member declared plain `Bool`
	 *    is not of unknown nullability, it is resolved.
	 *
	 * `fallbackReport` settles the no-type-info case for the structural arm: with no
	 * `TypeInfoProvider` a bare identifier cannot be proven either way. The report passes `true`
	 * (surface it for a human to judge); the autofix passes `false` (never strip without proof —
	 * an unproven `== true` may be load-bearing).
	 */
	private static function operandProven(other: QueryNode, seams: Seams, proof: TypeProof, fallbackReport: Bool): Bool {
		final structural: Bool = !operandIsNullable(other, seams.nullableKinds)
			&& operandProvablyBool(other, proof.root, seams.shape, proof.declaredTypes, seams.boolOpKinds, fallbackReport);
		return structural || resolvedNonNullBool(other, seams.shape, proof);
	}

	/**
	 * Whether `other`'s resolved DECLARED type is a non-nullable Bool. `fieldAccessTypeNominal`
	 * reads the member's written type off the `SymbolIndex`; the answer counts only when the
	 * resulting nominal is one of `RefShape.nonNullableTypeNames`. A `Null<Bool>` member reduces
	 * to the wrapper nominal `Null` and fails, as does every nominal the shape does not vouch for
	 * — `Dynamic` / `Any`, and a user abstract over `Bool` whose own null behaviour is its own.
	 *
	 * Bool-ness needs no separate seam: `other` is compared against a BOOLEAN literal, so the one
	 * value type that can survive the comparison's own typing is the boolean one.
	 */
	private static function resolvedNonNullBool(other: QueryNode, shape: RefShape, proof: TypeProof): Bool {
		final nominal: Null<String> = fieldAccessTypeNominal(other, shape, proof);
		return nominal != null && (shape.nonNullableTypeNames ?? []).contains(nominal);
	}

	/**
	 * The simple nominal of the type a FIELD-ACCESS operand carries: its receiver's type resolved
	 * to a nominal, then that type's member `other.name` looked up through the index — import- and
	 * inheritance-aware first, falling back to the package-blind simple-name walk for the aliased
	 * supertypes the import-aware walk cannot follow. Null for any other operand kind, for an
	 * unresolved receiver, and for an unresolved member.
	 *
	 * An ANONYMOUS-STRUCTURE receiver is refused wholesale: an `@:optional` structural field is
	 * nullable despite carrying a bare `Bool` annotation, and the member table records the two
	 * forms identically — so no anon field can be proven non-null here.
	 */
	private static function fieldAccessTypeNominal(other: QueryNode, shape: RefShape, proof: TypeProof): Null<String> {
		final faKind: Null<String> = shape.fieldAccessKind;
		final field: Null<String> = other.name;
		if (faKind == null || other.kind != faKind || other.children.length != 1 || field == null) return null;
		final index: Null<SymbolIndex> = proof.index();
		if (index == null) return null;
		final resolved: SymbolIndex = index;
		final recvType: Null<String> = receiverTypeNominal(other.children[0], shape, proof, resolved);
		if (recvType == null || resolved.isAnonStructType(recvType)) return null;
		final memberSource: Null<String> =
			resolved.resolvePathFinalMemberTypeSource(proof.file, recvType, [field]) ?? resolved.memberTypeSourceOf(recvType, field);
		return memberSource == null ? null : RefactorSupport.outerNominalOf(memberSource);
	}

	/**
	 * The simple nominal of a field-access RECEIVER's type. A TYPED CAST (`cast(e, T)` / `(e : T)`)
	 * answers its TARGET type, recovered from `TypeInfoProvider.castTargetSources` — the
	 * `QueryNode` projection drops the written type, and without this the whole
	 * `cast(e, T).member` shape is unresolvable. Every other receiver goes through
	 * `RefactorSupport.valueTypeNominal`, which covers a bare identifier, the self reference, and
	 * a longer `a.b` receiver path.
	 */
	private static function receiverTypeNominal(recv: QueryNode, shape: RefShape, proof: TypeProof, index: SymbolIndex): Null<String> {
		final recvSpan: Null<Span> = recv.span;
		if ((shape.typedCastKinds ?? []).contains(recv.kind))
			return recvSpan == null ? null : TypeResolver.simpleNominalName(TypeResolver.castTargetWithin(recvSpan, proof.castTargets()));
		final declaredTypes: Null<Map<Int, String>> = proof.declaredTypes;
		return declaredTypes == null
			? null
			: TypeResolver.simpleNominalName(RefactorSupport.valueTypeNominal(recv, proof.root, shape, declaredTypes, index, proof.file));
	}

	/**
	 * The STRUCTURAL half of `operandProven`: whether `other` is provably non-null Bool by shape
	 * alone. Two proofs: a boolean-operator result (comparison / `&&` / `||` / `!`, parentheses
	 * unwrapped — `RefactorSupport.provablyBoolOperand`, non-null Bool by construction), or a bare
	 * identifier whose declared type proves non-null Bool (`TypeResolver.isProvablyNonNull` over
	 * `declaredTypes`). Any other operand — an array element, a `Map.get` / method result, a
	 * possibly-`@:optional` field, a `?.` access, a `Null<Bool>` / unannotated identifier — is not
	 * proven here; a field access may still be proven by `resolvedNonNullBool`, which asks the
	 * `SymbolIndex` for the member's declared type instead of reading the operand's shape.
	 *
	 * `fallbackReport` settles the no-type-info case: when the grammar exposes no
	 * `TypeInfoProvider` (`declaredTypes == null`) a bare identifier cannot be proven either way.
	 * The report passes `true` (surface it for a human to judge); the autofix passes `false` (never
	 * strip without proof — an unproven `== true` may be load-bearing).
	 */
	private static function operandProvablyBool(
		other: QueryNode, root: QueryNode, shape: RefShape, declaredTypes: Null<Map<Int, String>>, boolOpKinds: Array<String>,
		fallbackReport: Bool
	): Bool {
		if (RefactorSupport.provablyBoolOperand(other, boolOpKinds, shape.parenKind)) return true;
		if (other.kind != shape.identKind) return false;
		return declaredTypes == null ? fallbackReport : TypeResolver.isProvablyNonNull(other, root, shape, declaredTypes);
	}

	/** Whether `operand`'s subtree reaches any kind whose nullness the check cannot rule out. */
	private static function operandIsNullable(operand: QueryNode, nullableKinds: Array<String>): Bool {
		for (k in nullableKinds) if (RefactorSupport.subtreeContainsKind(operand, k)) return true;
		return false;
	}

	/**
	 * `!operand`, parenthesizing a non-atomic operand so the unary `!` binds correctly. A bare
	 * identifier, an already-parenthesized operand and a FIELD ACCESS are atomic — member access
	 * binds tighter than the unary `!`, so `!o.flag` and `!cast(o, T).flag` need no parentheses
	 * (and adding them would only give `redundant-parens` something to strip).
	 */
	private static function negate(operand: QueryNode, src: String, shape: RefShape): String {
		final atomic: Bool = operand.kind == shape.identKind || operand.kind == shape.parenKind || operand.kind == shape.fieldAccessKind;
		return atomic ? '!$src' : '!($src)';
	}

	/**
	 * The replacement edit for one flagged comparison, or null when it cannot be rewritten:
	 * not a two-operand comparison, no boolean-literal operand at all, or — for a single
	 * literal operand — the other operand not provably non-null Bool (`operandProvablyBool`
	 * with the no-proof fallback OFF — an unprovable bare identifier is left alone).
	 *
	 * When BOTH operands are boolean literals, the whole comparison folds to its constant
	 * value — `true == true` → `true`, `true != true` → `false` — no type gate needed, since
	 * both operands are literals and therefore provably non-null. Otherwise, when rewritable,
	 * an `x == true` / `x != false` collapses to `x`, and an `x == false` / `x != true` to its
	 * negation (`negate` parenthesises unless the operand is an ident / paren).
	 */
	private static function comparisonEdit(
		node: QueryNode, span: Span, source: String, seams: Seams, proof: TypeProof, eqKind: String
	): Null<{ span: Span, text: String }> {
		if (node.children.length != 2) return null;
		final boolLitKind: String = seams.boolLitKind;
		final leftIsBool: Bool = node.children[0].kind == boolLitKind;
		final rightIsBool: Bool = node.children[1].kind == boolLitKind;
		if (!leftIsBool && !rightIsBool) return null;
		if (leftIsBool && rightIsBool) {
			final leftSpan: Null<Span> = node.children[0].span;
			final rightSpan: Null<Span> = node.children[1].span;
			if (leftSpan == null || rightSpan == null) return null;
			final leftText: String = spanText(leftSpan, source);
			final rightText: String = spanText(rightSpan, source);
			final equal: Bool = leftText == rightText;
			final isEq: Bool = node.kind == eqKind;
			return { span: span, text: isEq == equal ? 'true' : 'false' };
		}
		final lit: QueryNode = leftIsBool ? node.children[0] : node.children[1];
		final other: QueryNode = leftIsBool ? node.children[1] : node.children[0];
		if (!operandProven(other, seams, proof, false)) return null;
		final litSpan: Null<Span> = lit.span;
		final otherSpan: Null<Span> = other.span;
		if (litSpan == null || otherSpan == null) return null;
		final litIsTrue: Bool = spanText(litSpan, source) == 'true';
		final isEq: Bool = node.kind == eqKind;
		final otherSrc: String = spanText(otherSpan, source);
		return { span: span, text: isEq == litIsTrue ? otherSrc : negate(other, otherSrc, seams.shape) };
	}

	/** Resolve the equality / bool-literal / paren seam kinds, or null when any required kind is unset. */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final equalityKinds: Array<String> = shape.equalityKinds ?? [];
		if (equalityKinds.length == 0) return null;
		final boolLitKind: Null<String> = shape.boolLitKind;
		if (boolLitKind == null) return null;
		final nullSafeKind: Null<String> = shape.nullSafeAccessKind;
		final nullableKinds: Array<String> = shape.nullableOperandKinds ?? (nullSafeKind != null ? [nullSafeKind] : []);
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		final notKind: Null<String> = shape.notKind;
		final boolOpKinds: Array<String> = (shape.comparisonKinds ?? []).concat(notKind != null ? [notKind] : []);
		return {
			shape: shape,
			equalityKinds: equalityKinds,
			boolLitKind: boolLitKind,
			eqKind: shape.eqKind,
			nullableKinds: nullableKinds,
			opaqueKinds: opaqueKinds,
			identKind: shape.identKind,
			parenKind: shape.parenKind,
			boolOpKinds: boolOpKinds
		};
	}

	/** The trimmed source text under `span`. */
	private static inline function spanText(span: Span, source: String): String {
		return StringTools.trim(source.substring(span.from, span.to));
	}

}

/** The resolved seams `ComparisonToBoolean` reads in both `run` and `fix`. */
private typedef Seams = {
	final shape: RefShape;
	final equalityKinds: Array<String>;
	final boolLitKind: String;
	final eqKind: Null<String>;
	final nullableKinds: Array<String>;
	final opaqueKinds: Array<String>;
	final identKind: String;
	final parenKind: Null<String>;
	final boolOpKinds: Array<String>;
};

/**
 * One file's resolution context for the resolved-type Bool proof: the parsed `root` the scope
 * resolver walks, the file's `declaredTypes`, and two LAZY seams — `castTargets` (a second full
 * parse) and `index` (the run's `SymbolIndex`, which reads the configured libraries). Both stay
 * unforced until a field-access operand reaches `fieldAccessTypeNominal`.
 */
private typedef TypeProof = {
	final file: String;
	final root: QueryNode;
	final declaredTypes: Null<Map<Int, String>>;
	final castTargets: () -> Map<Int, String>;
	final index: () -> Null<SymbolIndex>;
};
