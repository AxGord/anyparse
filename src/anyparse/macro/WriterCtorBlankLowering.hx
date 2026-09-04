package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import haxe.macro.Context;
import haxe.macro.Expr;
import anyparse.macro.WriterCascadeLowering.*;
import anyparse.macro.WriterLoweringSupport.*;

using Lambda;
using anyparse.macro.MetaInspect;

/**
 * Pass 3W helpers - the blank-line cascade INFO builders.
 *
 * The `@:fmt(blankLines*)` family is declared on a Star ctor as a pile of
 * string-argument metas - head / after / before / between / transition, each
 * with its own `If` / `IfNot` / `IfPrevNot` / `IfTailLeafNull` variants -
 * and every one of them has to be turned into a typed INFO record before
 * any Doc is emitted. That reading is what this module is: `@:fmt` argument
 * lists in, `CascadeInfos` out, plus the classifier-enum resolution and the
 * multi-line predicates the gated kinds are built from.
 *
 * It is a pure READ of the shape tree - nothing here emits a Doc, and
 * nothing here decides a layout. That is why the module's whole boundary is
 * two things: `shape` and the arity helper `branchSynthExtraArity`.
 *
 * Split out of `WriterLowering` for size. Two members there enter through
 * `readCascadeInfosFromStar` (the tryparse and EOF Star emitters); the other
 * 21 members are reached only from inside.
 *
 * Every member is static and the build state arrives as one `CtorBlankCtx`
 * bundle, built once in `WriterLowering`'s constructor. The INFO typedefs
 * stay qualified: the extraction moved the functions, not the typedefs, and
 * `CascadeInfos` is what the Star emitters that stayed behind consume.
 */
@:access(anyparse.macro.WriterBlankLowering, anyparse.macro.WriterCascadeLowering, anyparse.macro.WriterLoweringSupport)
final class WriterCtorBlankLowering {

	/**
	 * ω-bug-2c-inner-star — read every cascade `@:fmt(blankLines*)` meta
	 * off a `@:trivia` Star ShapeNode and resolve them into the four
	 * info arrays consumed by `buildCascadeEmit`. Centralises the meta-read + transparent-merge + cross-validation block shared by the EOF-Star branch of `lowerStruct` and the inner-Star branch (`triviaTryparseStarExpr` consumers).
	 *
	 * Recognised metas:
	 *  - `blankLinesAfterCtor` / `blankLinesAfterCtorIf`
	 *  - `blankLinesBeforeCtor` / `blankLinesBeforeCtorIf`
	 *  - `blankLinesBetweenSameCtorByLevel`
	 *  - `blankLinesBetweenSameCtorTailTransparent`
	 *  - `blankLinesBetweenSameCtorHeadTransparent`
	 *  - `blankLinesBetweenSameCtorIfNot`
	 *  - `blankLinesOnTransitionAcross`
	 *
	 * Tail/head transparent metas are merged per-classifier-field into a
	 * shared adapter pair, fed to BOTH the between-ctor and transition
	 * cascades (single shared head/tail walker per Star+classifier). Any
	 * transparent meta whose classifier has no matching between/transition
	 * meta is rejected at compile time as dead code.
	 */
	private static function readCascadeInfosFromStar(
		cb: CtorBlankCtx, starNode: ShapeNode, elemRefName: String, ?measuredMultilineExpr: Expr
	): WriterLowering.CascadeInfos {
		// ω-leading-trivia-multiline — `@:fmt(multilineWhenLeadingTriviaSpansLines(
		// '<metaField>', '<declField>'))` on the Star builds a per-element
		// `_t`-scoped boolean OR-ed into the `'multiline'` predicate of every
		// predicate-gated blank rule below (afterMultilineDecl /
		// beforeMultilineDecl / betweenSingleLineTypes). The element is treated
		// as multi-line when its leading-trivia slot holds a comment (covers a
		// leading doc-comment before an otherwise single-line decl) OR the named
		// meta Star is non-empty AND the source broke before the dispatch
		// keyword (`<declField>BeforeNewline` synth slot — meta-on-own-line).
		// The inter-decl blank SEPARATOR (`_t.blankBefore` / `_t.newlineBefore`)
		// is deliberately NOT consulted — a pure-blank leading gap is still
		// single-line, mirroring fork `getTypeInfo`'s `findLowestIndex` span
		// which counts only the type's own leading comment + leading meta.
		// Absent flag → null → byte-identical to pre-slice.
		final triviaMultilineExpr: Null<Expr> = buildTriviaMultilineExpr(starNode);
		// ω-measured-multiline-decl — `@:fmt(measuredMultilineDecls)` on the Star
		// opts the two `multiline`-predicated blank rules (afterMultilineDecl /
		// beforeMultilineDecl) into the RENDERED channel: a per-element boolean
		// read out of `_measMulti`, the array `TriviaEofLowering` fills once per
		// module from each element's built Doc. Deliberately NOT threaded into
		// `blankLinesBetweenSameCtorIfNot` for the same reason the trivia flag is
		// not — that rule OWNS the pair blank when `betweenSingleLineTypes > 0`,
		// and flipping an element to not-single-line there would SUPPRESS the
		// user-configured count rather than replace it with `betweenTypes`.
		// Absent flag → null → byte-identical to pre-slice.
		//
		// The accessor is the CALLER's to supply, because only the EOF-mode Star
		// declares `_measMulti`. This function has two callers — the EOF branch
		// and the inner-Star (`@:tryparse`) branch — and reading the flag here
		// would let the inner one emit a reference to an identifier its own
		// scaffold never declares, failing as `Unknown identifier _measMulti`
		// inside generated code with nothing naming the flag. The guard below
		// turns that into the diagnostic it should be.
		if (starNode.fmtHasFlag('measuredMultilineDecls') && measuredMultilineExpr == null)
			Context.fatalError(
				'WriterLowering: @:fmt(measuredMultilineDecls) is supported only on an EOF-mode @:trivia Star (the one that declares '
				+ '`_measMulti`); this Star is lowered through another path',
				Context.currentPos()
			);
		final afterCtorAllArgs: Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesAfterCtor');
		final afterCtorInfos: Array<WriterLowering.AfterCtorBlankInfo> = [
			for (args in afterCtorAllArgs) buildAfterCtorBlankInfo(cb, elemRefName, args, null)
		];
		// NB: the trivia-multiline override is intentionally NOT threaded into
		// `blankLinesAfterCtorIf` (afterMultilineDecl). Fork `betweenTypes`
		// inserts the blank in the gap BEFORE a leading-comment / meta-on-own-
		// line type (its multi-line span is its LEADING layout), so only the
		// before-side and the inverted between-single-line-types rule consume
		// it. Firing it on the AFTER side too would insert a spurious blank
		// after a doc-commented type whose successor is single-line and whose
		// source gap the writer otherwise tightens
		// (lineends/issue_216_typedef_without_semicolon_unstable_comments).
		final afterCtorIfAllArgs: Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesAfterCtorIf');
		for (args in afterCtorIfAllArgs) afterCtorInfos.push(buildAfterCtorBlankInfoIf(cb, elemRefName, args, measuredMultilineExpr));
		// ω-after-conditional-block — tail-leaf-gated after-ctor override.
		final afterCtorIfTailNullAllArgs: Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesAfterCtorIfTailLeafNull');
		for (args in afterCtorIfTailNullAllArgs) afterCtorInfos.push(buildAfterCtorBlankInfoIfTailLeafNull(cb, elemRefName, args));
		final beforeCtorAllArgs: Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesBeforeCtor');
		final beforeCtorInfos: Array<WriterLowering.BeforeCtorBlankInfo> = [
			for (args in beforeCtorAllArgs) buildBeforeCtorBlankInfo(cb, elemRefName, args, null)
		];
		final beforeCtorIfAllArgs: Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesBeforeCtorIf');
		for (args in beforeCtorIfAllArgs) beforeCtorInfos.push(buildBeforeCtorBlankInfoIf(cb, elemRefName, args));
		final beforeCtorIfPrevNotAllArgs: Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesBeforeCtorIfPrevNot');
		for (args in beforeCtorIfPrevNotAllArgs)
			beforeCtorInfos.push(buildBeforeCtorBlankInfoIfPrevNot(cb, elemRefName, args, triviaMultilineExpr, measuredMultilineExpr));
		final betweenCtorAllArgs: Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesBetweenSameCtorByLevel');
		final tailTransparentAllArgs: Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesBetweenSameCtorTailTransparent');
		final headTransparentAllArgs: Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesBetweenSameCtorHeadTransparent');
		final transparentByClassifier: Map<String, WriterLowering.TransparentEntry> = [];
		for (args in tailTransparentAllArgs)
			ingestTransparentArg(transparentByClassifier, args, true, 'blankLinesBetweenSameCtorTailTransparent');
		for (args in headTransparentAllArgs)
			ingestTransparentArg(transparentByClassifier, args, false, 'blankLinesBetweenSameCtorHeadTransparent');
		final transitionAcrossAllArgs: Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesOnTransitionAcross');
		final ctorBlankInfos: {
			between: Array<WriterLowering.BetweenCtorBlankInfo>,
			transition: Array<WriterLowering.TransitionAcrossInfo>
		} = buildCtorBlankInfos(cb, elemRefName, betweenCtorAllArgs, transitionAcrossAllArgs, transparentByClassifier);
		final headCtorAllArgs: Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesAtHeadIfCtor');
		final headCtorInfos: Array<WriterLowering.HeadCtorBlankInfo> = [
			for (args in headCtorAllArgs) buildHeadCtorBlankInfo(cb, elemRefName, args)
		];
		// NB: the trivia-multiline override is intentionally NOT threaded into
		// `blankLinesBetweenSameCtorIfNot` (betweenSingleLineTypes, inverted).
		// That rule's blank between two single-line type pairs is OWNED by it
		// when `opt > 0`; flipping a leading-comment / meta-on-own-line type to
		// NOT-single-line there would SUPPRESS the user-configured
		// `betweenSingleLineTypes` blank (the fork still emits a blank for the
		// pair, just via `betweenTypes` instead). The before-side rule, which
		// sits one priority step BELOW it in the cascade, supplies the
		// multi-line blank when `betweenSingleLineTypes` falls through (opt 0),
		// so both fork paths are covered without double-counting
		// (lineends/issue_216_…_empty_lines: betweenSingleLineTypes=1 keeps the
		// blank around the doc-commented type pair).
		final betweenSameCtorIfNotAllArgs: Array<Array<String>> = starNode.fmtReadStringArgsAll('blankLinesBetweenSameCtorIfNot');
		final betweenSameCtorIfNotInfos: Array<WriterLowering.BetweenSameCtorIfNotInfo> = [
			for (args in betweenSameCtorIfNotAllArgs) buildBetweenSameCtorBlankInfoIfNot(cb, elemRefName, args)
		];
		return {
			afterCtorInfos: afterCtorInfos,
			beforeCtorInfos: beforeCtorInfos,
			betweenCtorInfos: ctorBlankInfos.between,
			transitionAcrossInfos: ctorBlankInfos.transition,
			headCtorInfos: headCtorInfos,
			betweenSameCtorIfNotInfos: betweenSameCtorIfNotInfos
		};
	}

	/**
	 * Fold one `@:fmt(blankLinesBetweenSameCtor{Tail,Head}Transparent)`
	 * arg-triple (classifierField, ctorName, adapterOptField) into the
	 * per-classifier `transparentByClassifier` accumulator, validating
	 * arity and one-shared-adapter-per-side.
	 */
	private static function ingestTransparentArg(
		transparentByClassifier: Map<String, WriterLowering.TransparentEntry>, args: Array<String>, isTail: Bool, metaName: String
	): Void {
		if (args.length != 3)
			Context.fatalError(
				'WriterLowering: @:fmt($metaName) expects exactly 3 string args (classifierField, ctorName, adapterOptField), got '
				+ args.length,
				Context.currentPos()
			);
		final cf: String = args[0];
		final ctor: String = args[1];
		final adapter: String = args[2];
		var entry: Null<WriterLowering.TransparentEntry> = transparentByClassifier[cf];
		if (entry == null) {
			entry = { ctors: [], tailAdapter: null, headAdapter: null };
			transparentByClassifier[cf] = entry;
		}
		if (entry.ctors.indexOf(ctor) < 0) entry.ctors.push(ctor);
		if (isTail) {
			if (entry.tailAdapter != null && entry.tailAdapter != adapter)
				Context.fatalError(
					'WriterLowering: @:fmt($metaName) adapter mismatch for classifier "$cf" — got "${entry.tailAdapter}" and "$adapter'
					+ '"; one shared tail adapter per Star+classifier',
					Context.currentPos()
				);
			entry.tailAdapter = adapter;
		} else {
			if (entry.headAdapter != null && entry.headAdapter != adapter)
				Context.fatalError(
					'WriterLowering: @:fmt($metaName) adapter mismatch for classifier "$cf" — got "${entry.headAdapter}" and "$adapter'
					+ '"; one shared head adapter per Star+classifier',
					Context.currentPos()
				);
			entry.headAdapter = adapter;
		}
	}

	/**
	 * Build the `betweenCtorInfos` + `transitionAcrossInfos` lists from
	 * their arg-lists, threading each classifier's transparent-ctor entry,
	 * then verify every accumulated transparent classifier has a matching
	 * between/transition rule on the same Star.
	 */
	private static function buildCtorBlankInfos(
		cb: CtorBlankCtx, elemRefName: String, betweenCtorAllArgs: Array<Array<String>>, transitionAcrossAllArgs: Array<Array<String>>,
		transparentByClassifier: Map<String, WriterLowering.TransparentEntry>
	): { between: Array<WriterLowering.BetweenCtorBlankInfo>, transition: Array<WriterLowering.TransitionAcrossInfo> } {
		final betweenCtorInfos: Array<WriterLowering.BetweenCtorBlankInfo> = [
			for (args in betweenCtorAllArgs) {
				final classifier: String = args[0];
				final tt: Null<WriterLowering.TransparentEntry> = transparentByClassifier[classifier];
				buildBetweenCtorBlankInfo(cb, elemRefName, args, tt != null ? tt.ctors : [], tt?.tailAdapter, tt?.headAdapter);
			}
		];
		final transitionAcrossInfos: Array<WriterLowering.TransitionAcrossInfo> = [
			for (args in transitionAcrossAllArgs) {
				final classifier: String = args[0];
				final tt: Null<WriterLowering.TransparentEntry> = transparentByClassifier[classifier];
				buildTransitionAcrossInfo(cb, elemRefName, args, tt != null ? tt.ctors : [], tt?.tailAdapter, tt?.headAdapter);
			}
		];
		for (cf in transparentByClassifier.keys()) {
			final hasBetween: Bool = betweenCtorInfos.exists(info -> info.classifierFieldName == cf);
			final hasTransition: Bool = transitionAcrossInfos.exists(info -> info.classifierFieldName == cf);
			if (!hasBetween && !hasTransition)
				Context.fatalError(
					'WriterLowering: @:fmt(blankLinesBetweenSameCtor{Tail,Head}Transparent) classifier "$cf'
					+ '" has no matching @:fmt(blankLinesBetweenSameCtorByLevel) or @:fmt(blankLinesOnTransitionAcross) on the same Star',
					Context.currentPos()
				);
		}
		return { between: betweenCtorInfos, transition: transitionAcrossInfos };
	}

	/**
	 * ω-before-package — resolve
	 * `@:fmt(blankLinesAtHeadIfCtor(classifierField, CtorName1,
	 * [CtorName2, …], optField))` into a `HeadCtorBlankInfo`. Same
	 * single-axis classify-switch shape as `buildAfterCtorBlankInfo`
	 * (1 if matched, 0 otherwise) — semantic divergence is at the cascade
	 * splice point: head-of-Star override fires once on `_arr[0].node`,
	 * not per-iteration. Reuses `resolveCtorBlankArgs` for arity
	 * validation, classifier-enum resolution, and synth-arity-aware case
	 * pattern emission.
	 */
	private static function buildHeadCtorBlankInfo(
		cb: CtorBlankCtx, elemRefName: String, args: Array<String>
	): WriterLowering.HeadCtorBlankInfo {
		final r: WriterLowering.CtorBlankResolution = resolveCtorBlankArgs(cb, elemRefName, args, 'blankLinesAtHeadIfCtor', null);
		return {
			classifierFieldName: r.fieldName,
			classifyCases: r.cases,
			optField: r.optField
		};
	}

	/**
	 * ω-after-package — resolve `@:fmt(blankLinesAfterCtor(classifierField,
	 * CtorName1, [CtorName2, …], optField))` into a binary classify-switch
	 * (`1` for any matching ctor, `0` otherwise) plus the option-field
	 * name read at runtime to pick the forced-minimum blank-line count.
	 *
	 * Mirrors `buildInterMemberClassifyInfo` but with arity ≥ 3
	 * (classifierField, ≥ 1 ctor name, optField) and a single-axis
	 * yes/no classification instead of var/fn/other. Reusable for any
	 * "blank line after ctor X" slice — the args list defines which
	 * ctors trigger and which `HxModuleWriteOptions` Int field is
	 * consulted.
	 */
	private static function buildAfterCtorBlankInfo(
		cb: CtorBlankCtx, elemRefName: String, args: Array<String>, predicateAdapter: Null<String>
	): WriterLowering.AfterCtorBlankInfo {
		final r: WriterLowering.CtorBlankResolution = resolveCtorBlankArgs(cb, elemRefName, args, 'blankLinesAfterCtor', predicateAdapter);
		return {
			classifierFieldName: r.fieldName,
			classifyCases: r.cases,
			optField: r.optField
		};
	}

	/**
	 * ω-after-multiline — predicate-gated variant of
	 * `buildAfterCtorBlankInfo`. Args shape: `(classifierField,
	 * predicateAdapter, CtorName1, …, optField)`. The runtime kind-=1
	 * path runs `opt.<predicateAdapter>(_t.node)` after the ctor match
	 * succeeds; kind stays `0` when the adapter returns false (or when
	 * the adapter field on `opt` is null). Lets a single ctor set fire
	 * a blank-line override only on shape-relevant elements (e.g.
	 * "blank line around any multi-line type decl") instead of bare
	 * ctor name (which would force the blank around empty-body decls
	 * too, e.g. `class C<T> {}`).
	 */
	private static function buildAfterCtorBlankInfoIf(
		cb: CtorBlankCtx, elemRefName: String, args: Array<String>, ?measuredMultilineExpr: Expr
	): WriterLowering.AfterCtorBlankInfo {
		if (args.length < 4)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesAfterCtorIf) expects ≥ 4 string args (classifierField, predicateAdapter, CtorName1, ['
				+ 'CtorName2, …], optField), got ${args.length}',
				Context.currentPos()
			);
		final reduced: Array<String> = [args[0]].concat(args.slice(2));
		final r: WriterLowering.CtorBlankResolution = resolveCtorBlankArgs(
			cb, elemRefName, reduced, 'blankLinesAfterCtorIf', args[1], false, null, measuredMultilineExpr
		);
		return {
			classifierFieldName: r.fieldName,
			classifyCases: r.cases,
			optField: r.optField
		};
	}

	/**
	 * ω-after-conditional-block — resolve
	 * `@:fmt(blankLinesAfterCtorIfTailLeafNull(classifierField, CtorName,
	 * tailAdapterField, optField))` (arity exactly 4). Like
	 * `blankLinesAfterCtor` it forces `opt.<optField>` blank lines after a
	 * previous element matching `CtorName`, but the override is gated at
	 * runtime on the previous element's tail-leaf classify (run via the
	 * named `WriteOptions` adapter on the matched ctor's first positional
	 * arg, bound as `_v0`) returning null — i.e. the wrapper's tail leaf is
	 * NOT one of the adapter's recognised ctors. The single matched case
	 * binds `_v0`; every other ctor stays kind `0` with the plain wildcard
	 * pattern. Used to mirror fork's module-level `#if … #end → type`
	 * boundary: a conditional whose tail is an import / using keeps the
	 * source blank (adapter returns non-null → override suppressed → source-
	 * driven count), every other tail (error, metadata, expression)
	 * collapses to `opt.afterConditionalBlock` (=0). Only one ctor name is
	 * accepted — the tail-leaf gate is meaningful only for a transparent
	 * wrapper ctor (`Conditional`).
	 */
	private static function buildAfterCtorBlankInfoIfTailLeafNull(
		cb: CtorBlankCtx, elemRefName: String, args: Array<String>
	): WriterLowering.AfterCtorBlankInfo {
		if (args.length != 4)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesAfterCtorIfTailLeafNull) expects exactly 4 string args ('
				+ 'classifierField, CtorName, tailAdapterField, optField), got ${args.length}',
				Context.currentPos()
			);
		final fieldName: String = args[0];
		final ctorName: String = args[1];
		final tailAdapterField: String = args[2];
		final optField: String = args[3];
		final r: { enumRule: ShapeNode, enumRuleName: String } = resolveClassifierEnum(
			cb, elemRefName, fieldName, 'blankLinesAfterCtorIfTailLeafNull'
		);
		final enumRule: ShapeNode = r.enumRule;
		final enumRuleName: String = r.enumRuleName;
		final pos: Position = Context.currentPos();
		final cases: Array<Case> = [];
		var matched: Bool = false;
		for (branch in enumRule.children) {
			final branchCtor: Null<String> = branch.annotations.get(AnnotationKeys.BASE_CTOR);
			if (branchCtor == null) continue;
			final arity: Int = branch.children.length + cb.branchSynthExtraArity(enumRuleName, branch);
			final ctorIdent: Expr = { expr: EConst(CIdent(branchCtor)), pos: pos };
			final isMatch: Bool = branchCtor == ctorName;
			if (isMatch) {
				matched = true;
				if (arity < 1)
					Context.fatalError(
						'WriterLowering: @:fmt(blankLinesAfterCtorIfTailLeafNull) ctor "$ctorName" must have arity ≥ 1 ('
						+ 'first arg is the wrapper payload bound to _v0 and passed to the tail-leaf classifier adapter); got arity $arity',
						Context.currentPos()
					);
				final binders: Array<Expr> = [for (i in 0...arity) i == 0 ? macro _v0 : macro _];
				final pattern: Expr = { expr: ECall(ctorIdent, binders), pos: pos };
				cases.push({ values: [pattern], guard: null, expr: macro 1 });
			} else {
				final pattern: Expr = arity == 0 ? ctorIdent : {
					expr: ECall(ctorIdent, [for (_ in 0...arity) macro _]),
					pos: pos
				};
				cases.push({ values: [pattern], guard: null, expr: macro 0 });
			}
		}
		// ω-orphan-prefix-decl: the null arm, kind `0` — see
		// `resolveCtorBlankArgs`. `emitAfterCompute` rewrites every non-`1` case
		// into the zero body, so this arm needs no shape of its own.
		cases.push({ values: [macro null], guard: null, expr: macro 0 });
		if (!matched)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesAfterCtorIfTailLeafNull) ctor "$ctorName" not found in enum $enumRuleName',
				Context.currentPos()
			);
		return {
			classifierFieldName: fieldName,
			classifyCases: cases,
			optField: optField,
			tailAdapterOptField: tailAdapterField
		};
	}

	/**
	 * ω-imports-using-blank — resolve `@:fmt(blankLinesBeforeCtor(classifierField,
	 * CtorName1, [CtorName2, …], optField))` — symmetric mirror of
	 * `buildAfterCtorBlankInfo`. Same arity (≥ 3 string args), same
	 * single-axis yes/no classification on the named ctors. The runtime
	 * gate (in `triviaEofStarExpr`) fires when the CURRENT element matches
	 * AND the previous element did NOT match the same set, driving
	 * "blank line before first X group" semantics (e.g. `import → using`
	 * transition) independently of the after-ctor knob.
	 */
	private static function buildBeforeCtorBlankInfo(
		cb: CtorBlankCtx, elemRefName: String, args: Array<String>, predicateAdapter: Null<String>
	): WriterLowering.BeforeCtorBlankInfo {
		final r: WriterLowering.CtorBlankResolution = resolveCtorBlankArgs(cb, elemRefName, args, 'blankLinesBeforeCtor', predicateAdapter);
		return {
			classifierFieldName: r.fieldName,
			classifyCases: r.cases,
			optField: r.optField,
			prevExcludeCases: null
		};
	}

	/**
	 * Predicate-gated variant of `buildBeforeCtorBlankInfo`. Same arg
	 * shape and adapter semantics as `buildAfterCtorBlankInfoIf` — the
	 * runtime gate at consumption keeps the existing "curr matches AND
	 * prev did NOT match" semantics, so the predicate-gated kind feeds
	 * both sides of the comparison. A single decl pair is governed by
	 * at most one override, and the cascade still picks after-ctor
	 * entries before before-ctor entries.
	 */
	private static function buildBeforeCtorBlankInfoIf(
		cb: CtorBlankCtx, elemRefName: String, args: Array<String>
	): WriterLowering.BeforeCtorBlankInfo {
		if (args.length < 4)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesBeforeCtorIf) expects ≥ 4 string args (classifierField, predicateAdapter, CtorName1, ['
				+ 'CtorName2, …], optField), got ${args.length}',
				Context.currentPos()
			);
		final reduced: Array<String> = [args[0]].concat(args.slice(2));
		final r: WriterLowering.CtorBlankResolution = resolveCtorBlankArgs(cb, elemRefName, reduced, 'blankLinesBeforeCtorIf', args[1]);
		return {
			classifierFieldName: r.fieldName,
			classifyCases: r.cases,
			optField: r.optField,
			prevExcludeCases: null
		};
	}

	/**
	 * ω-before-multiline-prev-not — predicate-gated `blankLinesBeforeCtor`
	 * variant that ALSO suppresses the override when the previous sibling
	 * matched an excluded ctor. Args shape:
	 * `(classifierField, predicateName, TargetCtor1, …, '|', ExcludeCtor1,
	 * …, optField)`. The `'|'` separator splits the target set (left) from
	 * the excluded-prev set (right). The target side resolves exactly like
	 * `buildBeforeCtorBlankInfoIf` (predicate-gated kind tracker); the
	 * excluded side builds a second binary classify-switch on the SAME
	 * classifier field (kind=1 for any excluded ctor) stored in
	 * `prevExcludeCases`. The cascade consumer (`buildCascadeEmit`) adds a
	 * `&& _prevKindPrevExcl != 1` guard so the override falls through to the
	 * source-driven blank count when the prev sibling was excluded.
	 *
	 * Drives the "do not force a blank before a multiline type decl when
	 * the preceding sibling is a cond-comp `#if … #end` with no source
	 * blank" rule (issue_298): `Conditional`-prev → respect source.
	 */
	private static function buildBeforeCtorBlankInfoIfPrevNot(
		cb: CtorBlankCtx, elemRefName: String, args: Array<String>, ?triviaMultilineExpr: Expr, ?measuredMultilineExpr: Expr
	): WriterLowering.BeforeCtorBlankInfo {
		final sepIdx: Int = args.indexOf('|');
		if (args.length < 5 || sepIdx < 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesBeforeCtorIfPrevNot) expects ≥ 5 string args (classifierField, predicateName, '
				+ 'TargetCtor1, …, "|", ExcludeCtor1, …, optField) with a "|" separator, got ${args.length}',
				Context.currentPos()
			);
		final classifier: String = args[0];
		final predicateName: String = args[1];
		final optField: String = args[args.length - 1];
		final targetCtors: Array<String> = args.slice(2, sepIdx);
		final excludeCtors: Array<String> = args.slice(sepIdx + 1, args.length - 1);
		if (targetCtors.length == 0 || excludeCtors.length == 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesBeforeCtorIfPrevNot) requires ≥ 1 target ctor before "|" and ≥ 1 excluded ctor after it',
				Context.currentPos()
			);
		// Target side: predicate-gated kind tracker, same resolution as
		// `buildBeforeCtorBlankInfoIf` (classifier + ctors + optField, with
		// the predicate name threaded in).
		final targetArgs: Array<String> = [classifier].concat(targetCtors).concat([optField]);
		final target: WriterLowering.CtorBlankResolution = resolveCtorBlankArgs(
			cb, elemRefName, targetArgs, 'blankLinesBeforeCtorIfPrevNot', predicateName, false, triviaMultilineExpr, measuredMultilineExpr
		);
		// Excluded side: bare binary classify-switch on the same classifier
		// field — no predicate, kind=1 for any excluded ctor. `optField` is
		// reused only to satisfy the resolver arity; its result is discarded.
		final excludeArgs: Array<String> = [classifier].concat(excludeCtors).concat([optField]);
		final exclude: WriterLowering.CtorBlankResolution = resolveCtorBlankArgs(
			cb, elemRefName, excludeArgs, 'blankLinesBeforeCtorIfPrevNot', null
		);
		return {
			classifierFieldName: target.fieldName,
			classifyCases: target.cases,
			optField: target.optField,
			prevExcludeCases: exclude.cases
		};
	}

	/**
	 * ω-between-single-line-types — resolve
	 * `@:fmt(blankLinesBetweenSameCtorIfNot(classifierField,
	 * predicateName, CtorName1, [CtorName2, …], optField))` into a
	 * `BetweenSameCtorIfNotInfo`. Same arg shape as
	 * `blankLinesAfterCtorIf` (≥ 4 string args, predicate name at args[1])
	 * but the resolver runs with `predicateInvert=true`, so the kind
	 * tracker fires `1` when the ctor matches AND the predicate is FALSE
	 * (i.e. the ctor's payload is single-line per the grammar-derived
	 * `multiline` predicate). The cascade-emit phase consults BOTH prev
	 * and curr trackers — fires `opt.<optField>` blank lines only when
	 * both sides of the consecutive pair land in kind=1.
	 *
	 * Currently only `'multiline'` is registered as a predicate name (via
	 * `buildPredicateGatedKind`). Untagged / empty-body / no-payload
	 * ctors bucket into kind=1 (single-line by default), so adding new
	 * ctors to the named set without tagging their payload type with
	 * `@:fmt(multilineWhen…)` is safe — they fire the rule whenever they
	 * appear next to another matched ctor.
	 */
	private static function buildBetweenSameCtorBlankInfoIfNot(
		cb: CtorBlankCtx, elemRefName: String, args: Array<String>
	): WriterLowering.BetweenSameCtorIfNotInfo {
		if (args.length < 4)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesBetweenSameCtorIfNot) expects ≥ 4 string args ('
				+ 'classifierField, predicateName, CtorName1, [CtorName2, …], optField), got ${args.length}',
				Context.currentPos()
			);
		final reduced: Array<String> = [args[0]].concat(args.slice(2));
		final r: WriterLowering.CtorBlankResolution = resolveCtorBlankArgs(
			cb, elemRefName, reduced, 'blankLinesBetweenSameCtorIfNot', args[1], true
		);
		return {
			classifierFieldName: r.fieldName,
			classifyCases: r.cases,
			optField: r.optField
		};
	}

	/**
	 * ω-imports-using-between — resolve
	 * `@:fmt(blankLinesBetweenSameCtorByLevel(classifierField,
	 * CtorName1, [CtorName2, …], levelOptField, countOptField,
	 * pathDifferFQN))` into a `BetweenCtorBlankInfo`. Validates the
	 * classifier resolves to an enum and that every named ctor exists
	 * with arity ≥ 1 (the first positional arg is the path payload
	 * read at runtime). Patterns for matched ctors bind `_v0` to the
	 * first arg; unmatched ctors use bare wildcards.
	 *
	 * Reuses the classifier resolution path from `resolveCtorBlankArgs`
	 * (probe Seq element rule → find Ref field → walk to enum target →
	 * enumerate Alt branches) but builds its own case-pattern set
	 * because (a) the runtime case body assigns BOTH a kind flag AND a
	 * path String at index-dependent ident names, generated at cascade-
	 * emit time, and (b) the matched arity-≥1 requirement is stricter
	 * than the existing builder's optional `_v0` binding.
	 */
	private static function buildBetweenCtorBlankInfo(
		cb: CtorBlankCtx, elemRefName: String, args: Array<String>, transparentCtorNames: Array<String>, tailAdapterOptField: Null<String>,
		headAdapterOptField: Null<String>
	): WriterLowering.BetweenCtorBlankInfo {
		if (args.length < 5)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesBetweenSameCtorByLevel) expects ≥ 5 string args (classifierField, CtorName1, ['
				+ 'CtorName2, …], levelOptField, countOptField, adapterOptField), got ${args.length}',
				Context.currentPos()
			);
		final fieldName: String = args[0];
		final adapterOptField: String = args[args.length - 1];
		final countOptField: String = args[args.length - 2];
		final levelOptField: String = args[args.length - 3];
		final ctorNames: Array<String> = args.slice(1, args.length - 3);
		if (ctorNames.length == 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesBetweenSameCtorByLevel) '
				+ 'requires at least one ctor name between the classifier field and the level/count/adapter tail',
				Context.currentPos()
			);
		// ω-cond-comp-tail-transparency — sanity-check no overlap between
		// matched and transparent sets. A ctor in both lists would be
		// ambiguous (kind=1/path=_v0 wins or transparent adapter call?).
		// Reject at compile time so the grammar author resolves it.
		for (name in ctorNames) if (transparentCtorNames.indexOf(name) >= 0)
			Context.fatalError(
				'WriterLowering: ctor "$name" appears both in @:fmt(blankLinesBetweenSameCtorByLevel) matched set and in '
				+ '@:fmt(blankLinesBetweenSameCtorTailTransparent) transparent set on the same Star — must be one or the other',
				Context.currentPos()
			);
		final r: { enumRule: ShapeNode, enumRuleName: String } = resolveClassifierEnum(
			cb, elemRefName, fieldName, 'blankLinesBetweenSameCtorByLevel'
		);
		final enumRule: ShapeNode = r.enumRule;
		final enumRuleName: String = r.enumRuleName;
		final pos: Position = Context.currentPos();
		final built: {
			patterns: Array<WriterLowering.BetweenCtorPattern>,
			matched: Array<String>,
			transparentMatched: Array<String>
		} = buildBetweenCtorPatterns(enumRule, ctorNames, transparentCtorNames, pos);
		for (name in ctorNames) if (built.matched.indexOf(name) < 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesBetweenSameCtorByLevel) ctor "$name" not found in enum $enumRuleName',
				Context.currentPos()
			);
		for (name in transparentCtorNames) if (built.transparentMatched.indexOf(name) < 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesBetweenSameCtorTailTransparent) ctor "$name" not found in enum $enumRuleName',
				Context.currentPos()
			);
		return {
			classifierFieldName: fieldName,
			ctorPatterns: built.patterns,
			matchedCtorNames: ctorNames.copy(),
			levelOptField: levelOptField,
			countOptField: countOptField,
			adapterOptField: adapterOptField,
			tailAdapterOptField: tailAdapterOptField,
			headAdapterOptField: headAdapterOptField,
			transparentCtorNames: transparentCtorNames.copy()
		};
	}

	/**
	 * ω-imports-using-transition — lower one
	 * `@:fmt(blankLinesOnTransitionAcross(classifierField, CtorA1,
	 * [CtorA2, …], '|', CtorB1, [CtorB2, …], countOptField))` into a
	 * `TransitionAcrossInfo`. The `'|'` literal in the args list separates
	 * subset A (left) from subset B (right). Each subset must be non-
	 * empty; ctors must exist in the classifier's target enum.
	 *
	 * Transparent-ctor support is inherited from sibling
	 * `blankLinesBetweenSameCtor{Tail,Head}Transparent` metas via the
	 * pre-merged `transparentByClassifier` map (caller).
	 */
	private static function buildTransitionAcrossInfo(
		cb: CtorBlankCtx, elemRefName: String, args: Array<String>, transparentCtorNames: Array<String>, tailAdapterOptField: Null<String>,
		headAdapterOptField: Null<String>
	): WriterLowering.TransitionAcrossInfo {
		if (args.length < 5)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesOnTransitionAcross) expects ≥ 5 string args (classifierField, CtorA1, ['
				+ 'CtorA2, …], "|", CtorB1, [CtorB2, …], countOptField), got ${args.length}',
				Context.currentPos()
			);
		final fieldName: String = args[0];
		final countOptField: String = args[args.length - 1];
		final split: WriterLowering.TransitionAcrossSplit = splitTransitionAcrossCtors(args, transparentCtorNames);
		final ctorNamesA: Array<String> = split.ctorNamesA;
		final ctorNamesB: Array<String> = split.ctorNamesB;
		final r: { enumRule: ShapeNode, enumRuleName: String } = resolveClassifierEnum(
			cb, elemRefName, fieldName, 'blankLinesOnTransitionAcross'
		);
		final enumRule: ShapeNode = r.enumRule;
		final enumRuleName: String = r.enumRuleName;
		final built: WriterLowering.TransitionAcrossPatterns = buildTransitionAcrossPatterns(cb, {
			enumRule: enumRule,
			enumRuleName: enumRuleName,
			ctorNamesA: ctorNamesA,
			ctorNamesB: ctorNamesB,
			transparentCtorNames: transparentCtorNames
		});
		for (name in ctorNamesA) if (built.matchedA.indexOf(name) < 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesOnTransitionAcross) subset A ctor "$name" not found in enum $enumRuleName',
				Context.currentPos()
			);
		for (name in ctorNamesB) if (built.matchedB.indexOf(name) < 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesOnTransitionAcross) subset B ctor "$name" not found in enum $enumRuleName',
				Context.currentPos()
			);
		for (name in transparentCtorNames) if (built.transparentMatched.indexOf(name) < 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesBetweenSameCtor{Tail,Head}Transparent) ctor "$name" not found in enum $enumRuleName',
				Context.currentPos()
			);
		return {
			classifierFieldName: fieldName,
			ctorPatterns: built.patterns,
			matchedCtorNamesA: ctorNamesA.copy(),
			matchedCtorNamesB: ctorNamesB.copy(),
			countOptField: countOptField,
			tailAdapterOptField: tailAdapterOptField,
			headAdapterOptField: headAdapterOptField,
			transparentCtorNames: transparentCtorNames.copy()
		};
	}

	/**
	 * Build the per-ctor switch patterns for a transition-across classifier.
	 * The per-branch loop that
	 * assigns each enum ctor to subset 1 (A) / 2 (B) / 3 (transparent) / 0
	 * (other), binding the first synth arg to `_v0` for matched/transparent
	 * ctors. Instance because `branchSynthExtraArity` reads `isTriviaBearing`.
	 */
	private static function buildTransitionAcrossPatterns(
		cb: CtorBlankCtx, c: WriterLowering.TransitionAcrossPatternsCtx
	): WriterLowering.TransitionAcrossPatterns {
		final pos: Position = Context.currentPos();
		final patterns: Array<WriterLowering.TransitionAcrossPattern> = [];
		final matchedA: Array<String> = [];
		final matchedB: Array<String> = [];
		final transparentMatched: Array<String> = [];
		for (branch in c.enumRule.children) {
			final ctorName: Null<String> = branch.annotations.get(AnnotationKeys.BASE_CTOR);
			if (ctorName == null) continue;
			final shapeArity: Int = branch.children.length;
			// In trivia mode, ctors with `@:trailOpt` / `@:lead` close-trailing /
			// `@:fmt(captureSource)` carry a synthesized positional arg appended
			// to the synth ctor (`HxDeclT.TypedefDecl(decl, trailPresent)`). The
			// pattern arity must match the synth ctor's full arity, otherwise
			// the generated switch fails with "Not enough arguments". Helper
			// returns 0 outside trivia mode or for non-bearing enums.
			final arity: Int = shapeArity + cb.branchSynthExtraArity(c.enumRuleName, branch);
			final ctorIdent: Expr = { expr: EConst(CIdent(ctorName)), pos: pos };
			final inA: Bool = c.ctorNamesA.indexOf(ctorName) >= 0;
			final inB: Bool = !inA && c.ctorNamesB.indexOf(ctorName) >= 0;
			final isTransparent: Bool = !inA && !inB && c.transparentCtorNames.indexOf(ctorName) >= 0;
			if (inA) {
				matchedA.push(ctorName);
				patterns.push({ pattern: transitionPattern(ctorIdent, arity, true, pos), subset: 1 });
			} else if (inB) {
				matchedB.push(ctorName);
				patterns.push({ pattern: transitionPattern(ctorIdent, arity, true, pos), subset: 2 });
			} else if (isTransparent) {
				if (shapeArity < 1)
					Context.fatalError(
						'WriterLowering: @:fmt(blankLinesOnTransitionAcross) transparent ctor "$ctorName'
						+ '" must have arity ≥ 1 (first arg is the wrapper payload bound to _v0 and passed to the head/tail-leaf '
						+ 'classifier adapters); got arity $shapeArity',
						Context.currentPos()
					);
				transparentMatched.push(ctorName);
				patterns.push({
					pattern: { expr: ECall(ctorIdent, [for (i in 0...arity) i == 0 ? macro _v0 : macro _]), pos: pos },
					subset: 3
				});
			} else {
				patterns.push({ pattern: transitionPattern(ctorIdent, arity, false, pos), subset: 0 });
			}
		}
		return {
			patterns: patterns,
			matchedA: matchedA,
			matchedB: matchedB,
			transparentMatched: transparentMatched
		};
	}

	/**
	 * Shared classifier-lookup path for the `blankLines{After,Before,
	 * BetweenSameCtorByLevel}Ctor[*]` meta family. Validates that the
	 * Seq element rule has a Ref field matching `fieldName`, that the
	 * Ref points at an Alt rule, and returns `(enumRule, enumRuleName)`
	 * for downstream branch enumeration. Centralising this stops the
	 * five fatalError messages from drifting out of sync across builders.
	 */
	private static function resolveClassifierEnum(
		cb: CtorBlankCtx, elemRefName: String, fieldName: String, metaName: String
	): { enumRule: ShapeNode, enumRuleName: String } {
		final elemRule: Null<ShapeNode> = cb.shape.rules[elemRefName];
		if (elemRule == null || elemRule.kind != Seq)
			Context.fatalError(
				'WriterLowering: @:fmt($metaName) requires element rule $elemRefName to be a Seq struct', Context.currentPos()
			);
		final classifierNode: Null<ShapeNode> = elemRule.children.find(c -> c.annotations.get(AnnotationKeys.BASE_FIELD_NAME) == fieldName);
		if (classifierNode == null)
			Context.fatalError(
				'WriterLowering: @:fmt($metaName) classifier field "$fieldName" not found on element rule $elemRefName',
				Context.currentPos()
			);
		if (classifierNode.kind != Ref)
			Context.fatalError(
				'WriterLowering: @:fmt($metaName) classifier field "$fieldName" must be a plain Ref to an enum rule', Context.currentPos()
			);
		final enumRuleName: Null<String> = classifierNode.annotations.get(AnnotationKeys.BASE_REF);
		if (enumRuleName == null)
			Context.fatalError(
				'WriterLowering: @:fmt($metaName) classifier field "$fieldName" has no base.ref annotation', Context.currentPos()
			);
		final enumRule: Null<ShapeNode> = cb.shape.rules[enumRuleName];
		if (enumRule == null || enumRule.kind != Alt)
			Context.fatalError(
				'WriterLowering: @:fmt($metaName) classifier target $enumRuleName must be an Alt (enum)', Context.currentPos()
			);
		return { enumRule: enumRule, enumRuleName: enumRuleName };
	}

	/**
	 * Shared resolver for `@:fmt(blankLinesAfterCtor(...))` and
	 * `@:fmt(blankLinesBeforeCtor(...))` — both metas accept the same
	 * `(classifierField, CtorName1, …, optField)` arg shape and produce
	 * the same single-axis classify-switch (`1` for any matching ctor,
	 * `0` otherwise) plus an opt-field name. The two metas diverge only
	 * at runtime: after-ctor consults the previous element's kind,
	 * before-ctor consults the current element's kind paired with a
	 * `prev != curr` gate. Centralising the parse/validation here keeps
	 * both knobs in sync on shape-validation messages and the classifier
	 * lookup path.
	 */
	private static function resolveCtorBlankArgs(
		cb: CtorBlankCtx, elemRefName: String, args: Array<String>, metaName: String, predicateName: Null<String>,
		predicateInvert: Bool = false, ?triviaMultilineExpr: Expr, ?measuredMultilineExpr: Expr
	): WriterLowering.CtorBlankResolution {
		if (args.length < 3)
			Context.fatalError(
				'WriterLowering: @:fmt($metaName) expects ≥ 3 string args (classifierField, CtorName1, [CtorName2, …], optField), got '
				+ args.length,
				Context.currentPos()
			);
		final fieldName: String = args[0];
		final optField: String = args[args.length - 1];
		final ctorNames: Array<String> = args.slice(1, args.length - 1);
		if (ctorNames.length == 0)
			Context.fatalError(
				'WriterLowering: @:fmt($metaName) requires at least one ctor name between the classifier field and the opt field',
				Context.currentPos()
			);
		final r: { enumRule: ShapeNode, enumRuleName: String } = resolveClassifierEnum(cb, elemRefName, fieldName, metaName);
		final enumRule: ShapeNode = r.enumRule;
		final enumRuleName: String = r.enumRuleName;
		final pos: Position = Context.currentPos();
		final cases: Array<Case> = [];
		final matched: Array<String> = [];
		for (branch in enumRule.children) {
			final ctorName: Null<String> = branch.annotations.get(AnnotationKeys.BASE_CTOR);
			if (ctorName == null) continue;
			// Synth-aware arity: in trivia mode, ctors carrying `@:trailOpt` /
			// `@:lead` close-trailing / `@:fmt(captureSource)` etc. grow
			// positional args on the paired synth ctor. The wildcard / `_v0`
			// pattern must size to the full synth arity or Haxe rejects with
			// "Not enough arguments" at the generated switch.
			final arity: Int = branch.children.length + cb.branchSynthExtraArity(enumRuleName, branch);
			final ctorIdent: Expr = { expr: EConst(CIdent(ctorName)), pos: pos };
			final pattern: Expr = arity == 0 ? ctorIdent : {
				expr: ECall(ctorIdent, [for (_ in 0...arity) macro _]),
				pos: pos
			};
			final isMatch: Bool = ctorNames.indexOf(ctorName) >= 0;
			if (isMatch) matched.push(ctorName);
			final kindExpr: Expr = if (!isMatch)
				macro 0;
			else if (predicateName == null)
				macro 1;
			else
				buildPredicateGatedKind(cb, branch, predicateName, metaName, predicateInvert, triviaMultilineExpr, measuredMultilineExpr);
			// When a predicate gate is active, the case pattern must bind the
			// first arg as `_v0` so the predicate can reference it. Plain
			// (non-predicated) and zero-arg ctors keep the original wildcard
			// pattern.
			final patternFinal: Expr = if (isMatch && predicateName != null && arity >= 1) {
				final binders: Array<Expr> = [for (i in 0...arity) i == 0 ? macro _v0 : macro _];
				{ expr: ECall(ctorIdent, binders), pos: pos };
			} else
				pattern;
			cases.push({ values: [patternFinal], guard: null, expr: kindExpr });
		}
		// ω-orphan-prefix-decl: a classifier field declared `@:optional` —
		// `HxTopLevelDecl.decl`, absent for a module-scope declaration that is
		// nothing but its own `#if X #end` prefix — reaches this switch as null.
		// The case list above is exhaustive over the enum's CTORS only, so
		// without an explicit arm strict null-safety rejects the subject. Kind
		// `0` is the same answer every unmatched ctor gets, so a declaration
		// that is only a prefix takes part in no blank-line cascade. Mirrors
		// `buildInterMemberClassifyCases`'s member-scope arm.
		cases.push({ values: [macro null], guard: null, expr: macro 0 });
		for (name in ctorNames) if (matched.indexOf(name) < 0)
			Context.fatalError('WriterLowering: @:fmt($metaName) ctor "$name" not found in enum $enumRuleName', Context.currentPos());
		return {
			fieldName: fieldName,
			cases: cases,
			optField: optField
		};
	}

	/**
	 * ω-after-multiline — build the kind-=1 case body for a
	 * predicate-gated `blankLines{After,Before}CtorIf` ctor match.
	 * `predicateName` is currently only `'multiline'`; resolves to a
	 * grammar-derived structural check via `buildMultilinePredicate`
	 * applied to the ctor's first arg (bound as `_v0` in the case
	 * pattern). Returns `macro 0` when the ctor's payload type carries
	 * no relevant `@:fmt(multilineWhen...)` meta, so adding new ctors to
	 * the gated set without tagging their target type silently keeps
	 * them at kind=0 (same as the bare ctor not being in the set).
	 *
	 * Recursive design: `multilineWhenFieldNonEmpty(<arrayField>)` on a
	 * struct typedef → `_v0.<field>.length > 0`.
	 * `multilineWhenFieldShape(<refField>)` → recurse into the field's
	 * target type's predicate. On enum types, switch over each ctor
	 * and apply `multilineCtor`-tagged ctor's arg-type predicate;
	 * untagged ctors emit `false`.
	 */
	private static function buildPredicateGatedKind(
		cb: CtorBlankCtx, branch: ShapeNode, predicateName: String, metaName: String, invert: Bool = false, ?triviaMultilineExpr: Expr,
		?measuredMultilineExpr: Expr
	): Expr {
		if (predicateName != 'multiline')
			Context.fatalError(
				'WriterLowering: @:fmt($metaName) predicate "$predicateName" is not registered (currently only "multiline" is supported)',
				Context.currentPos()
			);
		// ω-between-single-line-types — `invert=true` flips the kind polarity:
		// kind=1 when predicate is FALSE (i.e. the ctor matches AND is NOT
		// multi-line). Used by `blankLinesBetweenSameCtorIfNot` to track
		// "single-line side of the pair". Untagged ctors (no relevant
		// `multilineWhen…` meta on payload type) return `null` predicate
		// → kind=1 unconditionally under invert (single-line by default).
		//
		// ω-leading-trivia-multiline — when the Star carries
		// `@:fmt(multilineWhenLeadingTriviaSpansLines(...))`, `triviaMultilineExpr`
		// is a per-element `_t`-scoped boolean (leading comment present OR
		// meta-on-own-line). It OR-folds into the structural predicate so a
		// payload that renders single-line by its own shape is still treated
		// as multi-line when its leading layout crosses source lines (fork
		// `getTypeInfo` includes leading comment + leading meta in the
		// `oneLine` span). Null → byte-identical to the pre-slice paths.
		final structPred: Null<Expr> = if (branch.children.length == 0)
			null
		else {
			final argNode: ShapeNode = branch.children[0];
			final argTypeName: Null<String> = argNode.annotations[AnnotationKeys.BASE_REF];
			if (argTypeName == null)
				null
			else
				buildMultilinePredicate(cb, argTypeName, macro _v0);
		}
		// ω-measured-multiline-decl — the RENDERED channel. `structPred` answers
		// from the payload's SHAPE (a class is multi-line iff it declares
		// members), which is blind to a header that renders across lines on its
		// own: an empty-bodied `class C extends B implements … {}` whose heritage
		// clauses wrap is structurally single-line and physically three. Fork
		// `MarkEmptyLines.getTypeInfo` asks `isSameLine`, which reads the
		// whitespace `MarkWrapping` already committed — a rendering property, not
		// a source one — so the honest analogue is to measure the built Doc. The
		// caller supplies a per-element boolean (`_measMulti[_si]`, computed once
		// per module in `TriviaEofLowering`); null keeps every pre-slice path
		// byte-identical.
		final rendered: Null<Expr> = if (triviaMultilineExpr != null && measuredMultilineExpr != null)
			macro ($triviaMultilineExpr || $measuredMultilineExpr);
		else if (triviaMultilineExpr != null)
			triviaMultilineExpr;
		else
			measuredMultilineExpr;
		final cond: Null<Expr> = if (structPred != null && rendered != null)
			macro ($structPred || $rendered);
		else if (structPred != null)
			structPred;
		else if (rendered != null)
			rendered;
		else
			null;
		return if (cond == null)
			invert ? macro 1 : macro 0
		else if (invert)
			macro ($cond ? 0 : 1)
		else
			macro ($cond ? 1 : 0);
	}

	/**
	 * ω-after-multiline — recursively build the multi-line predicate
	 * for `typeName` applied to `accessExpr`. Returns `null` when the
	 * type carries no multi-line meta — caller substitutes `macro 0`
	 * (or `macro false`).
	 *
	 * Reads three `@:fmt(...)` flag forms from the grammar shape:
	 *  - typedef-level `multilineWhenFieldNonEmpty('field')` →
	 *    `accessExpr.field.length > 0`. Used when the type's multi-line
	 *    nature is determined by a Star field's emptiness (Class /
	 *    Iface / Abstract members, EnumDecl ctors, FnBlock stmts).
	 *  - typedef-level `multilineWhenFieldShape('field')` → recurse
	 *    into the named field's target type, applied to
	 *    `accessExpr.field`. Used when the type defers its multi-line
	 *    decision to a sub-rule (HxFnDecl → body).
	 *  - ctor-level `multilineCtor` (on enum branches) → switch over
	 *    every ctor of the enum; the tagged ctor binds its first arg
	 *    and recurses into the arg's type predicate; untagged ctors
	 *    emit `false`. Used for enum types whose multi-line nature
	 *    depends on which variant is present (HxFnBody → BlockBody
	 *    multi-line iff its block is, NoBody / ExprBody never).
	 *  - typedef-level `multilineWhenFieldCtorAndOpt('<field>', '<ctorName>',
	 *    '<optField>', '<optEnumExpr>')` (4-arg form) →
	 *    `Type.enumConstructor(accessExpr.<field>) == ctorName
	 *    && opt.<optField> == <optEnumExpr>`. The 4th arg is parsed as
	 *    a Haxe expression (via `Context.parse`) so the compared value
	 *    can be a fully-qualified `enum abstract` constructor like
	 *    `anyparse.format.BracePlacement.Next` — `Type.enumConstructor`
	 *    on the opt side would not compile for `enum abstract` knobs.
	 *    Use when the structural ctor match alone isn't enough — the
	 *    bound type may render flat or multi-line depending on a runtime
	 *    layout knob. Currently used by `HxTypedefDecl` to mark itself
	 *    multi-line only when `type` is `Anon` AND `anonTypeLeftCurly`
	 *    is `Next` (Allman): under `Same` the same source emits single-
	 *    line so the predicate stays false. The full path on the 4th
	 *    arg keeps the macro free of grammar-specific imports.
	 *  - typedef-level `multilineWhenStarFieldWrapsCascade('<starField>',
	 *    '<cascadeKnob>', '<itemNameField>')` (3-arg form) — predicate
	 *    fires when the named Star field's wrap cascade would resolve
	 *    to a non-`NoWrap` mode. The macro emits a runtime mirror of
	 *    `WrapList.emit`'s width arithmetic (sum/max with `(n-1)*2`
	 *    inter-item sep correction for `, `), reads `opt.<cascadeKnob>`
	 *    as a `WrapRules`, and calls `WrapList.decideWithLineLengthState`
	 *    with layout-blind inputs (`exceeds=false`, no `LineLengthLargerThan`
	 *    firing). Per-item width approximated as `item.<itemNameField>.length`
	 *    — sufficient when items are dominated by a single bare-name field
	 *    (e.g. `HxTypeParamDecl.name`, no constraint). Used by
	 *    `HxTypedefDecl` to detect typedefs whose declare-site typeParams
	 *    overflow `totalItemLength`/`anyItemLength` thresholds.
	 *
	 * Multiple struct-level meta entries OR-fold into one predicate:
	 * each matching meta contributes a clause, and the predicate fires
	 * when any clause fires. Enables composing structural conditions
	 * (Anon-Allman binding) with rendering-aware conditions (wrap-cascade
	 * fires on a Star field) on the same typedef. Previously first-match-
	 * wins-returns precluded this composition.
	 */
	private static function buildMultilinePredicate(cb: CtorBlankCtx, typeName: String, accessExpr: Expr): Null<Expr> {
		final node: Null<ShapeNode> = cb.shape.rules[typeName];
		if (node == null) return null;
		final meta: Null<Metadata> = node.annotations.get(AnnotationKeys.BASE_META);
		if (meta != null) {
			final folded: Null<Expr> = buildMultilineMetaPredicate(cb, node, typeName, accessExpr, meta);
			if (folded != null) return folded;
		}
		// Enum dispatch: switch over each ctor's `multilineCtor` flag.
		return node.kind == Alt ? buildMultilineEnumPredicate(cb, node, accessExpr) : null;
	}

	/**
	 * Struct-level `@:fmt(multiline*)` flag path of `buildMultilinePredicate`:
	 * collect every matching multiline flag on `meta` and OR-fold them into
	 * one predicate (null when none match). Extracted to keep
	 * `buildMultilinePredicate` below the complexity gate.
	 */
	private static function buildMultilineMetaPredicate(
		cb: CtorBlankCtx, node: ShapeNode, typeName: String, accessExpr: Expr, meta: Metadata
	): Null<Expr> {
		final pos: Position = Context.currentPos();
		// Collect every matching struct-level multiline flag and OR-fold
		// them into one predicate. Single first-match-wins precluded
		// composing structural conditions (Anon-Allman binding) with
		// rendering-aware conditions (wrap-cascade fires on a Star field),
		// so a typedef whose body type stays simple but whose declare-site
		// typeParams overflow into a wrap could not be detected as
		// multi-line. Closes the `wrapping/issue_494_type_parameter`
		// boundary between a flat typedef and a typeParam-wrapping typedef.
		final preds: Array<Expr> = [];
		for (entry in meta) if (entry.name == ':fmt') {
			for (param in entry.params) switch param.expr {
				case ECall({ expr: EConst(CIdent('multilineWhenFieldNonEmpty')) }, [{ expr: EConst(CString(field, _)) }]):
					final fieldExpr: Expr = { expr: EField(accessExpr, field), pos: pos };
					preds.push(macro $fieldExpr.length > 0);
				case ECall({ expr: EConst(CIdent('multilineWhenFieldShape')) }, [{ expr: EConst(CString(field, _)) }]):
					final fieldNode: Null<ShapeNode> = findFieldByName(node, field);
					if (fieldNode == null)
						Context.fatalError(
							'WriterLowering: @:fmt(multilineWhenFieldShape) field "$field" not found on $typeName', Context.currentPos()
						);
					final targetType: Null<String> = fieldNode.annotations.get(AnnotationKeys.BASE_REF);
					if (targetType == null) continue;
					final fieldExpr: Expr = { expr: EField(accessExpr, field), pos: pos };
					final inner: Null<Expr> = buildMultilinePredicate(cb, targetType, fieldExpr);
					if (inner != null) preds.push(inner);
				// ω-typedef-between-blank: 4-arg runtime ctor match on a
				// named field PLUS an opt-side runtime equality with a
				// fully-qualified enum literal. Emits
				// `Type.enumConstructor(<accessExpr>.<field>) == <ctorName>
				// && opt.<optField> == <optEnumExpr>`.
				// The opt-gate distinguishes layout modes that drive
				// whether a structurally-bound type renders multi-line
				// — e.g. `HxTypedefDecl` is "multi-line in output" only
				// when the bound type is `Anon` AND `anonTypeLeftCurly`
				// is `BracePlacement.Next` (issue_301 boundary). Avoids
				// spurious blanks under Same / other placements where the
				// same source emits single-line. The 4th arg is parsed
				// as a Haxe expression so `enum abstract` knobs (which
				// fail `Type.enumConstructor`) can be compared directly
				// against their declared constructor.
				case ECall({ expr: EConst(CIdent('multilineWhenFieldCtorAndOpt')) }, [
					{ expr: EConst(CString(field, _)) },
					{ expr: EConst(CString(ctorName, _)) },
					{ expr: EConst(CString(optField, _)) },
					{ expr: EConst(CString(optEnumExprStr, _)) }
				]):
					final fieldExpr: Expr = { expr: EField(accessExpr, field), pos: pos };
					final optAccess: Expr = optFieldAccess(optField);
					final optEnumExpr: Expr = Context.parse(optEnumExprStr, pos);
					preds.push(macro Type.enumConstructor($fieldExpr) == $v{ctorName} && $optAccess == $optEnumExpr);
				// ω-typedef-typeparam-multiline: 3-arg cascade probe on a
				// Star field. Mirror of `WrapList.decideWithLineLengthState`
				// at predicate-eval time, approximating per-item width via
				// `<itemNameField>.length` and the same `(n-1)*(sep+space)`
				// inter-item correction `WrapList.emit` applies. Predicate
				// fires when the cascade would resolve to any non-NoWrap
				// mode, i.e. the typedef's declare-site type parameters
				// would render multi-line. Hardcodes sep width to fork-
				// standard `, ` (2 chars) — every Haxe wrap cascade uses
				// comma separators, so this matches the runtime that
				// `shapeNoWrap` / `shapeFillLine` produce.
				case ECall({ expr: EConst(CIdent('multilineWhenStarFieldWrapsCascade')) }, [
					{ expr: EConst(CString(field, _)) },
					{ expr: EConst(CString(cascadeKnob, _)) },
					{ expr: EConst(CString(itemNameField, _)) }
				]):
					final fieldExpr: Expr = { expr: EField(accessExpr, field), pos: pos };
					final cascadeAccess: Expr = optFieldAccess(cascadeKnob);
					final itemFieldExpr: Expr = { expr: EField(macro _p, itemNameField), pos: pos };
					preds.push(buildStarWrapsCascadePred(fieldExpr, cascadeAccess, itemFieldExpr));
				case _:
			}
		}
		if (preds.length == 0) return null;
		var folded: Expr = preds[0];
		for (i in 1...preds.length) {
			final next: Expr = preds[i];
			folded = macro $folded || $next;
		}
		return folded;
	}

	/**
	 * Enum-dispatch path of `buildMultilinePredicate` (Alt nodes): a switch
	 * over each ctor's `multilineCtor` flag, recursing into the first arg's
	 * type for the multi-line probe. Returns null when no branch is tagged.
	 * Extracted to keep `buildMultilinePredicate` below the complexity gate.
	 */
	private static function buildMultilineEnumPredicate(cb: CtorBlankCtx, node: ShapeNode, accessExpr: Expr): Null<Expr> {
		final pos: Position = Context.currentPos();
		final cases: Array<Case> = [];
		var anyTagged: Bool = false;
		for (branch in node.children) {
			final ctorName: Null<String> = branch.annotations.get(AnnotationKeys.BASE_CTOR);
			if (ctorName == null) continue;
			final arity: Int = branch.children.length;
			final ctorIdent: Expr = { expr: EConst(CIdent(ctorName)), pos: pos };
			final tagged: Bool = ctorBranchHasFlag(branch, 'multilineCtor');
			final pattern: Expr = if (tagged && arity >= 1) {
				final binders: Array<Expr> = [for (i in 0...arity) i == 0 ? macro _v : macro _];
				{ expr: ECall(ctorIdent, binders), pos: pos };
			} else if (arity == 0) {
				ctorIdent;
			} else {
				{ expr: ECall(ctorIdent, [for (_ in 0...arity) macro _]), pos: pos };
			};
			final body: Expr = if (!tagged)
				macro false;
			else {
				anyTagged = true;
				final argNode: ShapeNode = branch.children[0];
				final argTypeName: Null<String> = argNode.annotations[AnnotationKeys.BASE_REF];
				final inner: Null<Expr> = argTypeName == null ? null : buildMultilinePredicate(cb, argTypeName, macro _v);
				inner ?? macro false;
			};
			cases.push({ values: [pattern], guard: null, expr: body });
		}
		return !anyTagged ? null : { expr: ESwitch(accessExpr, cases, null), pos: pos };
	}

	/**
	 * ω-typedef-typeparam-multiline: build the runtime cascade-probe Expr
	 * for `@:fmt(multilineWhenStarFieldWrapsCascade)` — mirrors
	 * `WrapList.emit`'s width arithmetic (`, ` sep = +2 per non-last item)
	 * over the Star field, firing when `WrapList.decideWithLineLengthState`
	 * resolves to any non-NoWrap mode.
	 */
	private static function buildStarWrapsCascadePred(fieldExpr: Expr, cascadeAccess: Expr, itemFieldExpr: Expr): Expr {
		// Width arithmetic mirrors `WrapList.measureItems`: each non-last item
		// contributes `name + sep + space` (= +2 for fork-standard `, `), the last
		// item contributes just `name`. Applied to EVERY measurement the cascade
		// reads — `_sum` (`totalItemLength`), `_maxLen` (`anyItemLength >= n` /
		// `allItemLengths <= n`), `_minLen` (`anyItemLength <= n` /
		// `allItemLengths >= n`) and `_equalLens` (`equalItemLengths`, with the
		// same last-item allowance `measureItems` spells, since that item carries
		// no separator) — so the predicate's answers match `WrapList.emit`'s at
		// runtime. Without sep in maxLen the predicate could undershoot on
		// item-length boundary cases (e.g. item of exactly 49 chars vs threshold
		// 50: predicate false, emit true).
		//
		// The `+ 2` is literal because this predicate's only consumer is a
		// comma-separated Star; a Star with a wider separator would need it
		// threaded, and would silently measure short until then.
		return macro {
			final _arr = $fieldExpr;
			if (_arr == null || _arr.length == 0)
				false;
			else {
				var _sum: Int = 0;
				var _maxLen: Int = 0;
				var _minLen: Int = anyparse.format.wrap.WrapList.MAX_ITEM_LEN;
				var _firstLen: Int = -1;
				var _equalLens: Bool = true;
				final _lastIdx: Int = _arr.length - 1;
				for (_i in 0..._arr.length) {
					final _p = _arr[_i];
					final _raw: Int = ($itemFieldExpr: String).length;
					final _w: Int = _i < _lastIdx ? _raw + 2 : _raw;
					_sum += _w;
					if (_w > _maxLen) _maxLen = _w;
					if (_w < _minLen) _minLen = _w;
					if (_firstLen < 0)
						_firstLen = _w;
					else if (_w != _firstLen && !(_i == _lastIdx && _w + 2 == _firstLen))
						_equalLens = false;
				}
				anyparse.format.wrap.WrapList.decideWithLineLengthState(
					$cascadeAccess, _arr.length, _maxLen, _sum, false, false, _ -> false, 0, _minLen, _equalLens
				) != anyparse.format.wrap.WrapMode.NoWrap;
			}
		};
	}

	/**
	 * ω-leading-trivia-multiline — build the per-element `_t`-scoped
	 * boolean for `@:fmt(multilineWhenLeadingTriviaSpansLines('<metaField>',
	 * '<declField>'))`, OR-ed into the `'multiline'` predicate of every
	 * predicate-gated blank rule. Returns null when the flag is absent.
	 */
	private static function buildTriviaMultilineExpr(starNode: ShapeNode): Null<Expr> {
		final triviaMultilineArgs: Null<Array<String>> = starNode.fmtReadStringArgs('multilineWhenLeadingTriviaSpansLines');
		if (triviaMultilineArgs == null) return null;
		if (triviaMultilineArgs.length != 2)
			Context.fatalError(
				'WriterLowering: @:fmt(multilineWhenLeadingTriviaSpansLines) expects exactly 2 string args (metaField, declField), got '
				+ triviaMultilineArgs.length,
				Context.currentPos()
			);
		final pos: Position = Context.currentPos();
		final metaField: String = triviaMultilineArgs[0];
		final declField: String = triviaMultilineArgs[1];
		final metaAccess: Expr = { expr: EField(macro _t.node, metaField), pos: pos };
		final beforeNlAccess: Expr = { expr: EField(macro _t.node, declField + TriviaTypeSynth.BEFORE_NEWLINE_SUFFIX), pos: pos };
		return macro (_t.leadingComments.length > 0 || ($metaAccess.length > 0 && $beforeNlAccess));
	}

}

/**
 * The build state the cascade INFO builders read, bundled once per
 * `WriterLowering` instance.
 *
 * Two fields is the whole dependency surface, which is what a pure read of
 * the shape tree should cost.
 */
typedef CtorBlankCtx = {
	final shape: ShapeBuilder.ShapeResult;
	final branchSynthExtraArity: (bodyTypePath:String, branch:ShapeNode) -> Int;
}
#end
