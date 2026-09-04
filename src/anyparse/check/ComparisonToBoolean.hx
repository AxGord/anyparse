package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.BoolExprShape;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberKinds;
import anyparse.query.NominalTypes;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;
import haxe.Exception;

using Lambda;
using StringTools;

/**
 * Flags a comparison against a boolean literal — `x == true`, `x != false` and the like —
 * where the literal adds nothing (SonarLint S1125). Structural shape plus a type gate.
 * `fix` rewrites the comparison to its operand — `x == true` / `x != false` → `x`,
 * `x == false` / `x != true` → `!x` — but ONLY when the operand is provably non-null Bool.
 * All four rewrites ride the SAME proof, because on a nullable operand they are not
 * symmetric (see the null-safety caveat below).
 *
 * ## Severity tracks fixability
 *
 * A finding this check can MECHANICALLY rewrite is `Severity.Warning`; one it can only
 * surface for a human is `Severity.Info`. The two coincide with the proof: a proven
 * non-null Bool operand (or two boolean literals) is autofixable, so it is a `Warning`,
 * while the no-`TypeInfoProvider` fallback — a bare identifier reported for a human
 * because nothing can prove or refute it — stays report-only `Info`. `eqKind` is part of
 * the same question: without it `fix` cannot tell `==` from `!=` and every arm degrades
 * to report-only, so the severity degrades with it.
 *
 * ## Constant fold
 *
 * A comparison where BOTH operands are boolean literals (`true == true`) is a separate
 * case: it is always reported (no type gate needed — both sides are literals, provably
 * non-null), and `fix` folds the whole comparison to its constant value —
 * `true == true` → `true`, `true != true` → `false`. Like the rest of `fix`, the fold
 * needs `eqKind` to tell `==` from `!=`; without it the case stays report-only `Info`.
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
 * Three proofs grant it, and an operand with none is skipped. STRUCTURALLY: a
 * boolean-operator result (`RefShape.comparisonKinds` ∪ `RefShape.notKind`, parentheses
 * unwrapped — non-null `Bool` by construction), or a bare identifier whose declared type
 * proves non-null Bool (`TypeResolver.isProvablyNonNull` over
 * `TypeInfoProvider.declaredTypes`) — a `Null<Bool>` local, an optional parameter, or an
 * unannotated / unresolvable identifier stays silent. This arm sits behind a blanket veto
 * on any operand subtree reaching `RefShape.nullableOperandKinds` (Haxe `Call` /
 * `FieldAccess` / `SafeFieldAccess`: a method or `Map.get` result, a possibly-`@:optional`
 * field, a `?.` access). BY RESOLVED MEMBER TYPE: a FIELD ACCESS whose receiver type resolves
 * and whose member's declared type is one of `RefShape.nonNullableTypeNames` — `object.visible`
 * on an `openfl` `DisplayObject`, and (through `TypeInfoProvider.castTargetSources`, since
 * the projection drops the written target) `cast(object, DisplayObjectContainer).mouseEnabled`
 * on the cast target's own or INHERITED member. BY RESOLVED RETURN TYPE: a METHOD CALL
 * `recv.method(…)` whose receiver type resolves the same way and whose method's written return
 * type is one of those same nominals — `o.isReady()` on a project class, an inherited method, a
 * `cast(o, T).has(k)`. A `Null<Bool>`-returning method reduces to the wrapper nominal `Null` and
 * fails, as does an unannotated one — with ONE curated exception: `RefShape.instanceMethodReturns`
 * answers behind the index for the stdlib methods whose own source writes no return type, which is
 * what makes `moveHashMap.exists(hash) != false` provable at all (`haxe.ds.Map.exists` is written
 * `public inline function exists(key:K) return this.exists(key);`, so no resolution scope can read
 * an annotation that was never written).
 *
 * The two RESOLVED arms are the ones that may pass the veto: the veto refuses an operand of
 * UNKNOWN nullability, and a member or return type the index resolved is not unknown. Both share
 * `memberLookupIsPinned`, which refuses the lookups the index cannot answer soundly — an
 * anon-struct receiver, a simple-name homonym, a `#if`-guarded declaration. Neither reaches a
 * `?.` anywhere in the receiver chain: `x?.m()` is `Null<Bool>` even when `m` returns a plain
 * `Bool`, and the receiver walk answers null for every safe-access node, so the veto stands
 * exactly where it is load-bearing.
 *
 * The resolved arms inherit the `nonNullableTypeNames` PREMISE — that a declared `Bool`
 * holds no null — from the identifier arm beside them (`TypeResolver.isProvablyNonNull` returns
 * true for a `Bool` annotation with no null-safety involved at all). That premise is exact on a
 * static target and NOT exact on a dynamic one, where an uninitialized or `@:optional`
 * `public var flag:Bool` class field reads `null`: there `o.flag == false` is `false` while
 * `!o.flag` is `true`. ALL arms share the hole — the identifier arm has carried it since the
 * declared-type gate landed — so closing it belongs to the shared premise (or to a per-target
 * seam), not to one arm. A `Bool`-returning METHOD is the least exposed of the three where the body
 * is Haxe: the annotation is written by hand at the one place the value is produced, with no
 * default-initialisation seam behind it. An EXTERN method is the exception — there its `:Bool` is a
 * promise about foreign code, which a JS `undefined` can break, exactly as a field's can.
 *
 * Grammars with no `TypeInfoProvider` fall back to reporting bare identifiers for a human to
 * judge; `fix` leaves those untouched (no proof, so the `== true` may be load-bearing). The check
 * does not descend into macro-reification subtrees (`RefShape.opaqueKinds`), whose comparisons
 * are generated code rather than authored style.
 *
 * ## Grammar-agnostic
 *
 * Equality kinds come from `RefShape.equalityKinds`, the literal from `RefShape.boolLitKind`,
 * the nullable-operand skip from `RefShape.nullableOperandKinds` (falling back to the single
 * `RefShape.nullSafeAccessKind` when unset), the macro skip from `RefShape.opaqueKinds`, the
 * identifier gate from `TypeInfoProvider.declaredTypes` + the nullability seams
 * (`nonNullableTypeNames` / `nullableWrapperTypeNames`), the boolean-operator half of the
 * provably-Bool gate from `RefShape.comparisonKinds` + `RefShape.notKind`, and the two resolved
 * arms from `RefShape.fieldAccessKind` / `callKind` / `typedCastKinds` +
 * `TypeInfoProvider.castTargetSources` + the `SymbolIndex` + `RefShape.instanceMethodReturns`.
 * Unset equality kinds or literal kind makes the check a no-op; an unset `fieldAccessKind` drops
 * BOTH resolved arms (a call's callee is a field access too), an unset `callKind` drops just the
 * return-type one, and an unset `instanceMethodReturns` drops only its stdlib fallback.
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
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		// Lazy: the resolution scope reads the configured libraries, and only the two RESOLVED
		// proofs demand it — after every cheaper arm on every candidate has failed.
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
	 * already-parenthesized expression, a field access, or a call — so the unary `!` binds
	 * correctly). Emitted for any operand `operandProven` accepts, with the no-proof fallback OFF:
	 * an unresolved bare identifier is left to the report, since its `== true` may be
	 * load-bearing under strict null-safety. `eqKind` tells `==` from `!=` — it is required
	 * HERE only (unset → report-only, which `run` mirrors by dropping every finding to `Info`).
	 *
	 * The resolved-type arms need a `SymbolIndex`; `fixIndex` supplies the run's
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
		if (seams == null || violations.length == 0) return [];
		final maybeEqKind: Null<String> = seams.eqKind;
		final maybeRoot: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (maybeEqKind == null || maybeRoot == null) return [];
		final eqKind: String = maybeEqKind;
		final root: QueryNode = maybeRoot;
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		final file: String = violations[0].file;
		for (violation in violations) if (violation.file != file)
			throw new Exception('$RULE_ID: fix() takes ONE file\'s violations, got $file and ${violation.file}');
		// `lazySymbolIndex` prefers the run's resolution scope, then the caller's report index, and
		// only then builds over `source` alone — enough for a same-file receiver type.
		final resolver: () -> Null<SymbolIndex> = RefactorSupport.lazySymbolIndex([{ file: file, source: source }], plugin, index);
		final proof: TypeProof = proofOf(file, source, root, provider, resolver);
		return CheckScan.applyBySpan(
			plugin, source, violations, seams.equalityKinds, (node, span) -> comparisonEdit(node, span, source, seams, proof, eqKind)
		);
	}

	/** The trimmed source text under `span`. */
	private static inline function spanText(span: Span, source: String): String {
		return source.substring(span.from, span.to).trim();
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
			declaredTypes: provider?.declaredTypes(source),
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
	 * whose other operand `operandProven` accepts — a boolean-operator result, a bare identifier
	 * whose declared type proves non-null Bool, a field access whose resolved member type does,
	 * or a method call whose resolved return type does. A `Null<Bool>` local's `== true` is
	 * load-bearing under strict null-safety, and an unresolvable / unannotated identifier cannot
	 * be verified, so both stay silent; without a `TypeInfoProvider` the identifier falls back to
	 * being reported for a human to judge. Macro reification subtrees (`opaqueKinds`) are not
	 * descended into.
	 *
	 * The gate runs with the no-proof fallback OFF first, and consults the fallback ONLY when
	 * `declaredTypes` is absent — the one condition under which it can change the answer. That is
	 * what separates the two severities: a proven operand is autofixable (`Warning`), a
	 * fallback-only one is not (`Info`), and re-asking with the fallback ON would otherwise repeat
	 * the index lookups the strict pass already paid for.
	 *
	 * A comparison where BOTH operands are boolean literals (`true == true`) is flagged
	 * unconditionally in a separate branch — no provably-Bool gate applies, since two literal
	 * operands are provably non-null, so it is autofixable whenever `eqKind` is set.
	 */
	private static function walk(out: Array<Violation>, node: QueryNode, seams: Seams, proof: TypeProof): Void {
		if (seams.opaqueKinds.contains(node.kind)) return;
		final span: Null<Span> = node.span;
		if (span != null && node.children.length == 2 && seams.equalityKinds.contains(node.kind)) {
			final leftIsBool: Bool = node.children[0].kind == seams.boolLitKind;
			final rightIsBool: Bool = node.children[1].kind == seams.boolLitKind;
			final fixable: Bool = seams.eqKind != null;
			if (leftIsBool && rightIsBool) {
				out.push({
					file: proof.file,
					span: span,
					rule: RULE_ID,
					severity: fixable ? Severity.Warning : Severity.Info,
					message: 'constant boolean comparison'
				});
			} else if (leftIsBool != rightIsBool) {
				final other: QueryNode = leftIsBool ? node.children[1] : node.children[0];
				final proven: Bool = operandProven(other, seams, proof, false);
				if (proven || (proof.declaredTypes == null && operandProven(other, seams, proof, true))) out.push({
					file: proof.file,
					span: span,
					rule: RULE_ID,
					severity: proven && fixable ? Severity.Warning : Severity.Info,
					message: 'comparison against a boolean literal'
				});
			}
		}
		for (c in node.children) walk(out, c, seams, proof);
	}

	/**
	 * Whether `other` is a PROVABLY non-null Bool operand — the shared gate for BOTH the report
	 * (`walk`) and the autofix (`comparisonEdit`). Three independent proofs, cheapest first:
	 *
	 *  - the STRUCTURAL one (`operandProvablyBool`), behind the blanket `nullableKinds` subtree
	 *    veto that has always guarded it: a boolean-operator result, or a bare identifier whose
	 *    declared type proves non-null Bool.
	 *  - the RESOLVED-MEMBER one (`resolvedNonNullBool`), which reads a FIELD ACCESS's member type
	 *    out of the `SymbolIndex`.
	 *  - the RESOLVED-RETURN one (`resolvedCallReturnBool`), which reads a METHOD CALL's written
	 *    return type out of the same index.
	 *
	 * The two resolved arms are the ones allowed past that veto, and only because the veto exists
	 * to refuse an operand of UNKNOWN nullability — a member declared plain `Bool`, or a method
	 * annotated to return one, is not of unknown nullability, it is resolved.
	 *
	 * `fallbackReport` settles the no-type-info case for the structural arm: with no
	 * `TypeInfoProvider` a bare identifier cannot be proven either way. The report passes `true`
	 * (surface it for a human to judge); the autofix passes `false` (never strip without proof —
	 * an unproven `== true` may be load-bearing).
	 */
	private static function operandProven(other: QueryNode, seams: Seams, proof: TypeProof, fallbackReport: Bool): Bool {
		final structural: Bool = !operandIsNullable(other, seams.nullableKinds)
			&& operandProvablyBool(other, proof.root, seams.shape, proof.declaredTypes, seams.boolOpKinds, fallbackReport);
		return structural || resolvedNonNullBool(other, seams.shape, proof) || resolvedCallReturnBool(other, seams, proof);
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
	 * to a nominal, then that type's member `other.name` looked up through the import- and
	 * inheritance-aware `SymbolIndex` walk. Null for any other operand kind, for an unresolved
	 * receiver, for a receiver `memberLookupIsPinned` refuses, and for an unresolved member.
	 *
	 * `SymbolIndex`'s package-blind simple-name fallback is deliberately NOT used here. Its stated
	 * purpose is the aliased conditional supertype the import-aware walk cannot follow — but it has
	 * no supertype walk of its own, so for THIS arm it can only ever answer from a same-simple-named
	 * type in another package: a wrong answer rather than a wider one.
	 */
	private static function fieldAccessTypeNominal(other: QueryNode, shape: RefShape, proof: TypeProof): Null<String> {
		final faKind: Null<String> = shape.fieldAccessKind;
		final field: Null<String> = other.name;
		if (faKind == null || other.kind != faKind || other.children.length != 1 || field == null) return null;
		final lookup: Null<PinnedLookup> = pinnedLookup(other.children[0], field, shape, proof);
		if (lookup == null) return null;
		final memberSource: Null<String> = lookup.index.resolvePathFinalMemberTypeSource(proof.file, lookup.recvType, [field]);
		return memberSource == null ? null : NominalTypes.outerNominalOf(memberSource);
	}

	/**
	 * The `SymbolIndex` plus the receiver type nominal BOTH resolved arms key their member lookup on,
	 * or null when there is no index, `recv` resolves to no nominal, or `memberLookupIsPinned` refuses
	 * the `nominal.member` lookup. The two arms differ only in what they then ASK of the pair — a
	 * member's written type, or a method's written return — so everything up to the question is here.
	 */
	private static function pinnedLookup(recv: QueryNode, member: String, shape: RefShape, proof: TypeProof): Null<PinnedLookup> {
		final index: Null<SymbolIndex> = proof.index();
		if (index == null) return null;
		final resolved: SymbolIndex = index;
		final recvType: Null<String> = receiverTypeNominal(recv, shape, proof, resolved);
		return recvType == null || !memberLookupIsPinned(recvType, member, resolved) ? null : { index: resolved, recvType: recvType };
	}

	/**
	 * Whether `other`'s resolved RETURN type is a non-nullable Bool — the `map.exists(k)` /
	 * `o.isReady()` arm. `callReturnTypeNominal` reads the method's written return nominal off the
	 * `SymbolIndex`; the answer counts only when it is one of `RefShape.nonNullableTypeNames`. A
	 * `Null<Bool>`-returning method reduces to the wrapper nominal `Null` and fails, as does an
	 * unannotated one (no nominal at all) and every nominal the shape does not vouch for.
	 *
	 * The Bool-ness argument is the field arm's verbatim: `other` is compared against a BOOLEAN
	 * literal, so the one value type that can survive the comparison's own typing is the boolean one.
	 */
	private static function resolvedCallReturnBool(other: QueryNode, seams: Seams, proof: TypeProof): Bool {
		final nominal: Null<String> = callReturnTypeNominal(other, seams, proof);
		return nominal != null && (seams.shape.nonNullableTypeNames ?? []).contains(nominal);
	}

	/**
	 * The simple nominal of the type a METHOD-CALL operand carries: its callee's receiver resolved
	 * to a nominal (the same `receiverTypeNominal` walk the field arm uses, so `cast(o, T).m()`
	 * resolves too), then that type's method looked up through the inheritance-aware
	 * `SymbolIndex.returnNominalOf`. Null for any other operand kind, for an unresolved receiver,
	 * for a receiver `memberLookupIsPinned` refuses, and for a method with no written return type.
	 *
	 * Requiring the callee to be a plain `fieldAccessKind` is what keeps `?.` out: `x?.m()` is
	 * `Null<Bool>` even when `m` returns a plain `Bool`, and its callee is the safe-access kind, not
	 * this one. A safe access DEEPER in the receiver chain (`a?.b.m()`) is refused by the receiver
	 * walk, which resolves no path through a safe-access node. A bare `m()` has no receiver at all
	 * and is refused by the same requirement; a WRITTEN `this.m()` is not — its receiver is an
	 * ordinary identifier that the walk maps to the enclosing type through `RefShape.selfReferenceText`,
	 * so it resolves like any other.
	 *
	 * `RefShape.instanceMethodReturns` answers BEHIND the index, for the stdlib methods whose own
	 * source writes no return type — `haxe.ds.Map.exists` forwards to `IMap.exists(k:K):Bool` with
	 * the annotation left inferred, so no resolution scope can read one. A written annotation always
	 * wins over it, and `NominalTypes.shadowedByNonStdType` — the same guard the sibling
	 * `staticMethodReturns` table rides — refuses it the moment ANY non-std file declares the
	 * receiver's simple name. That guard is the load-bearing one, NOT `memberLookupIsPinned`: a
	 * single project type named `Map` passes the pin, and its own `exists` may be unannotated (a
	 * `@:forward` abstract, an alias, an inherited member) so that `returnNominalOf` answers null and
	 * the table would otherwise stand in for a possibly-`Null<Bool>` project method.
	 */
	private static function callReturnTypeNominal(other: QueryNode, seams: Seams, proof: TypeProof): Null<String> {
		final callKind: Null<String> = seams.callKind;
		final faKind: Null<String> = seams.shape.fieldAccessKind;
		if (callKind == null || faKind == null || other.kind != callKind || other.children.length == 0) return null;
		final callee: QueryNode = other.children[0];
		final method: Null<String> = callee.name;
		if (callee.kind != faKind || method == null || callee.children.length != 1) return null;
		final lookup: Null<PinnedLookup> = pinnedLookup(callee.children[0], method, seams.shape, proof);
		if (lookup == null) return null;
		final recvType: String = lookup.recvType;
		final written: Null<String> = lookup.index.returnNominalOf(recvType, method);
		if (written != null) return written;
		if (NominalTypes.shadowedByNonStdType(lookup.index, recvType)) return null;
		final tabled: Null<String> = seams.instanceMethodReturns['$recvType.$method'];
		return tabled == null ? null : NominalTypes.outerNominalOf(tabled);
	}

	/**
	 * Whether the `recvType.field` member lookup can be TRUSTED — three refusals, each a known
	 * blind spot of the simple-name `SymbolIndex` that BOTH resolved arms (the member-type one and
	 * the return-type one) would otherwise turn into a value-changing rewrite:
	 *
	 *  - an ANONYMOUS-STRUCTURE receiver. An `@:optional` structural field is nullable while
	 *    carrying a bare `Bool` annotation, and the member table records both forms identically;
	 *    an `@:optional` METHOD field is nullable in the same way.
	 *  - a receiver type whose SIMPLE NAME has more than one INDEPENDENT declaration
	 *    (`typeNameIsPinned`). The index keys types by simple name, so a homonym in another package
	 *    can answer for the type actually in scope — a root `T` declaring `flag:Bool` standing in
	 *    for a `p.T extends Base` that INHERITS `flag:Null<Bool>` (p.T declares nothing directly, so
	 *    nothing else notices the swap). Conservative: the in-scope type often resolves correctly
	 *    anyway, but proving which of the index's arms answered costs more than the refusal.
	 *  - a `#if`-GUARDED declaration of `field` on `recvType`. The index is branch-blind and its
	 *    inheritance walk is first-wins, so which branch is written first would decide the proof;
	 *    `MemberInfo.guarded` exists precisely so a rewriting consumer bails. A member declared on a
	 *    SUPERTYPE has no direct declaration to inspect here, so its guardedness stays invisible — a
	 *    residual hole, narrower than the one it replaces.
	 *
	 * Nothing checks the member's WRITTEN TYPE for agreement or presence: past the first two refusals
	 * exactly one type is named `recvType`, so Haxe permits at most one non-`#if` declaration of
	 * `field` on it, and a member carrying no annotation of the kind the calling arm reads — a
	 * method for the member-type walk, a value field or an unannotated method for the return-type
	 * one — makes that walk itself answer null.
	 */
	private static function memberLookupIsPinned(recvType: String, field: String, index: SymbolIndex): Bool {
		return !index.isAnonStructType(recvType) && typeNameIsPinned(recvType, index)
			&& index.memberDeclarationsOf(recvType, field).foreach(declaration -> !(declaration.member.guarded));
	}

	/**
	 * Whether AT MOST ONE independent declaration carries the simple name `recvType` — the homonym
	 * refusal, with two shapes excused because neither is a second answer:
	 *
	 *  - a plain alias re-pointing at its OWN simple name (`typedef Map<K, V> = haxe.ds.Map<K, V>`
	 *    beside `abstract Map` in `haxe/ds/Map.hx`). It denotes a type the index already keys under
	 *    `recvType`, so it cannot disagree with it — where a homonym in another package genuinely can.
	 *    Without this excusal the alias-plus-implementation pair Haxe's std uses for its core generic
	 *    types is permanently ambiguous, and `map.exists(k) != false` — the shape that motivated the
	 *    return-type arm — refuses its own receiver.
	 *  - a count of ZERO: an out-of-scope type nothing indexed declares. Every index-backed lookup then
	 *    answers null of its own accord, so the excusal cannot license a proof — it only lets the
	 *    stdlib table be REACHED, and that table has its own, stricter shadowing guard
	 *    (`NominalTypes.shadowedByNonStdType`) which this predicate must not be mistaken for.
	 *
	 * `aliasTargetNominal` is null for every non-alias declaration AND for an alias whose target the
	 * builder could not read as a nominal path, so an unreadable alias counts as independent and keeps
	 * the refusal — the fail-closed direction.
	 */
	private static function typeNameIsPinned(recvType: String, index: SymbolIndex): Bool {
		var independent: Int = 0;
		for (fi in index.declaringFiles(recvType))
			for (t in fi.types)
				if (t.name == recvType && t.aliasTargetNominal != recvType) independent++;
		return independent <= 1;
	}

	private static function receiverTypeNominal(recv: QueryNode, shape: RefShape, proof: TypeProof, index: SymbolIndex): Null<String> {
		final recvSpan: Null<Span> = recv.span;
		if ((shape.typedCastKinds ?? []).contains(recv.kind))
			return recvSpan == null ? null : TypeResolver.simpleNominalName(TypeResolver.castTargetWithin(recvSpan, proof.castTargets()));
		final declaredTypes: Null<Map<Int, String>> = proof.declaredTypes;
		return declaredTypes == null
			? null
			: TypeResolver.simpleNominalName(NominalTypes.valueTypeNominal(recv, proof.root, shape, declaredTypes, index, proof.file));
	}

	/**
	 * The STRUCTURAL half of `operandProven`: whether `other` is provably non-null Bool by shape
	 * alone. Two proofs: a boolean-operator result (comparison / `&&` / `||` / `!`, parentheses
	 * unwrapped — `RefactorSupport.provablyBoolOperand`, non-null Bool by construction), or a bare
	 * identifier whose declared type proves non-null Bool (`TypeResolver.isProvablyNonNull` over
	 * `declaredTypes`). Any other operand — an array element, a `Map.get` / method result, a
	 * possibly-`@:optional` field, a `?.` access, a `Null<Bool>` / unannotated identifier — is not
	 * proven here; a field access may still be proven by `resolvedNonNullBool` and a method call by
	 * `resolvedCallReturnBool`, both of which ask the `SymbolIndex` for a written annotation instead
	 * of reading the operand's shape.
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
		return BoolExprShape.provablyBoolOperand(other, boolOpKinds, shape.parenKind) || other.kind == shape.identKind
			&& (declaredTypes == null ? fallbackReport : TypeResolver.isProvablyNonNull(other, root, shape, declaredTypes));
	}

	/** Whether `operand`'s subtree reaches any kind whose nullness the check cannot rule out. */
	private static function operandIsNullable(operand: QueryNode, nullableKinds: Array<String>): Bool {
		return nullableKinds.exists(k -> MemberKinds.subtreeContainsKind(operand, k));
	}

	/**
	 * `!operand`, parenthesizing a non-atomic operand so the unary `!` binds correctly. A bare
	 * identifier, an already-parenthesized operand, a FIELD ACCESS and a CALL are atomic — member
	 * access and the call's own argument list bind tighter than the unary `!`, so `!o.flag`,
	 * `!cast(o, T).flag` and `!map.exists(k)` need no parentheses (and adding them would only give
	 * `redundant-parens` something to strip).
	 */
	private static function negate(operand: QueryNode, src: String, seams: Seams): String {
		final shape: RefShape = seams.shape;
		final atomic: Bool = operand.kind == shape.identKind || operand.kind == shape.parenKind || operand.kind == shape.fieldAccessKind
			|| operand.kind == seams.callKind;
		return atomic ? '!$src' : '!($src)';
	}

	/**
	 * The replacement edit for one flagged comparison, or null when it cannot be rewritten:
	 * not a two-operand comparison, no boolean-literal operand at all, or — for a single
	 * literal operand — the other operand not provably non-null Bool (`operandProven`
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
		return { span: span, text: isEq == litIsTrue ? otherSrc : negate(other, otherSrc, seams) };
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
			callKind: shape.callKind,
			instanceMethodReturns: shape.instanceMethodReturns ?? [],
			boolOpKinds: boolOpKinds
		};
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
	final callKind: Null<String>;
	final instanceMethodReturns: Map<String, String>;
	final boolOpKinds: Array<String>;
};

/** A member lookup both resolved arms have already PINNED: the run's index and the receiver's type nominal. */
private typedef PinnedLookup = {
	final index: SymbolIndex;
	final recvType: String;
};

/**
 * One file's resolution context for the resolved-type Bool proof: the parsed `root` the scope
 * resolver walks, the file's `declaredTypes`, and two deferred seams — `castTargets` and `index`
 * (the run's `SymbolIndex`, which reads the configured libraries). `index` is genuinely lazy and
 * shared across the run. `castTargets` is memoized per file: on a `CachingGrammarPlugin` it is a
 * read off the same memoized span-info bundle `declaredTypes` already forced, so the memo saves a
 * map rebuild rather than a parse; against a bare plugin it saves the second full parse.
 */
private typedef TypeProof = {
	final file: String;
	final root: QueryNode;
	final declaredTypes: Null<Map<Int, String>>;
	final castTargets: () -> Map<Int, String>;
	final index: () -> Null<SymbolIndex>;
};
