package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import anyparse.macro.WriterLowering.AfterCtorBlankInfo;
import anyparse.macro.WriterLowering.BeforeCtorBlankInfo;
import anyparse.macro.WriterLowering.BetweenCtorBlankInfo;
import anyparse.macro.WriterLowering.BetweenCtorPattern;
import anyparse.macro.WriterLowering.BetweenSameCtorIfNotInfo;
import anyparse.macro.WriterLowering.CascadeAccum;
import anyparse.macro.WriterLowering.CascadeEmit;
import anyparse.macro.WriterLowering.HeadCtorBlankInfo;
import anyparse.macro.WriterLowering.InterMemberCasesCtx;
import anyparse.macro.WriterLowering.TransitionAcrossInfo;
import anyparse.macro.WriterLowering.TransitionAcrossSplit;
import haxe.macro.Context;
import haxe.macro.Expr;

using StringTools;
using Lambda;

/**
 * Pass 3W — the `@:fmt(blankLines*)` cascade.
 *
 * The blank-line rules a grammar declares between members of a Star
 * are not independent: `blankLinesAfterCtor`, `blankLinesBeforeCtor`,
 * `blankLinesBetweenSameCtor*`, `blankLinesAtHeadIfCtor` and
 * `blankLinesOnTransitionAcross` all answer the same question — how
 * many blank lines go in THIS gap — and the generated writer must ask
 * them in one order and take the first that fires. That ordering is
 * the cascade, and this module is the whole of it: an `emit*Compute`
 * per rule family building the per-gap decision into a shared
 * `CascadeAccum`, a `fold*Cascade` per family folding the accumulated
 * arms into one `Expr`, `buildHeadEmit` for the head gap, and
 * `buildCascadeEmit` assembling them.
 *
 * The ctor-pattern helpers travel with it (`buildBetweenCtorPatterns`,
 * `splitTransitionAcrossCtors`, `transitionPattern`,
 * `buildInterMemberClassifyCases`) because a cascade arm is a
 * constructor pattern and nothing else builds one.
 *
 * `hxq clusters` had already isolated this as its own connected
 * component inside `WriterLowering` — 14 members with no member
 * reference into the 223-member core — so the seam was measured
 * before it was cut. The one edge left is `WriterLowering.astPredCallT`,
 * which stays behind because it reads the build-scoped predicate-root
 * mirror `generate()` sets; it is named qualified here, the same way
 * the four trivia Star modules name it.
 */
@:access(anyparse.macro.WriterLowering)
final class WriterCascadeLowering {

	/**
	 * ω-bug-2c-inner-star — extract the cascade emit machinery shared by
	 * `triviaEofStarExpr` (top-level EOF-terminated Star) and
	 * `triviaTryparseStarExpr` (inner tryparse-terminated Star, e.g.
	 * `HxConditionalDecl.body`). Returns five Exprs ready to splice into
	 * the consumer's runtime block:
	 *
	 *  - `initPrev`   — single EVars statement declaring all `_prev*`
	 *                   trackers (placed once, in the outer scope, before
	 *                   the while loop).
	 *  - `initCurr`   — single EVars statement declaring all `_curr*`
	 *                   trackers (placed inside the while body, before
	 *                   `currCompute`).
	 *  - `currCompute`— single EBlock of assignments computing `_curr*`
	 *                   from `_t.node` classifier values.
	 *  - `trackPrev`  — single EBlock of `_prev* = _curr*` assignments
	 *                   (end of iteration).
	 *  - `blanksCount`— Int-typed cascade ternary, fallback
	 *                   `(_t.blankBefore ? 1 : 0)`. Empty info arrays leave
	 *                   only the fallback, so consumers without cascade
	 *                   metas behave byte-identically (the `(0|1)` count
	 *                   matches the existing `if (blankBefore) push(\\n)`
	 *                   path).
	 *
	 * The emitted Exprs reference runtime locals defined in the consumer's
	 * scope: `_t` (per-iteration `_arr[_si]` binding), `opt` (writer
	 * options parameter), and `_v0` (bound by ctor pattern inside switch
	 * cases — local to each pattern body via `BetweenCtorPattern` /
	 * `TransitionAcrossPattern`).
	 *
	 * Sister to `readCascadeInfosFromStar`, which reads the
	 * `@:fmt(blankLines*)` metas off the Star ShapeNode and produces the
	 * info arrays consumed here. The two helpers together let any Star
	 * emit kind opt in to the cascade machinery without duplicating its
	 * implementation.
	 */
	private static function buildCascadeEmit(
		afterInfos: Array<AfterCtorBlankInfo>, beforeInfos: Array<BeforeCtorBlankInfo>, betweenInfos: Array<BetweenCtorBlankInfo>,
		transitionInfos: Array<TransitionAcrossInfo>, headInfos: Array<HeadCtorBlankInfo>,
		?betweenSameIfNotInfos: Array<BetweenSameCtorIfNotInfo>
	): CascadeEmit {
		final betweenIfNotInfos: Array<BetweenSameCtorIfNotInfo> = betweenSameIfNotInfos ?? [];
		final pos: Position = Context.currentPos();

		final acc: CascadeAccum = {
			prevVars: [],
			currVars: [],
			currCompute: [],
			trackPrev: []
		};

		emitAfterCompute(acc, afterInfos, pos);
		emitBeforeCompute(acc, beforeInfos, pos);
		emitBetweenCompute(acc, betweenInfos, pos);
		emitBetweenIfNotCompute(acc, betweenIfNotInfos, pos);
		emitTransitionCompute(acc, transitionInfos, pos);

		// Build cascade ternary from innermost (source-driven) outward —
		// before in reverse, then between in reverse, then transition in
		// reverse, then after in reverse. Final priority (outermost wins
		// first): after[0..N] > between[0..N] > transition[0..N] >
		// before[0..N] > source-driven `(_t.blankBefore ? 1 : 0)`.
		var blanksCountExpr: Expr = macro (_t.blankBefore ? 1 + (_t.blankBefore2 ?? 0) : 0);
		blanksCountExpr = foldBeforeCascade(blanksCountExpr, beforeInfos, pos);
		blanksCountExpr = foldBetweenIfNotCascade(blanksCountExpr, betweenIfNotInfos, pos);
		blanksCountExpr = foldBetweenCascade(blanksCountExpr, betweenInfos, pos);
		blanksCountExpr = foldTransitionCascade(blanksCountExpr, transitionInfos, pos);
		blanksCountExpr = foldAfterCascade(blanksCountExpr, afterInfos, pos);

		final headEmit: Expr = buildHeadEmit(headInfos, pos);
		final initPrev: Expr = acc.prevVars.length > 0 ? { expr: EVars(acc.prevVars), pos: pos } : (macro {});
		final initCurr: Expr = acc.currVars.length > 0 ? { expr: EVars(acc.currVars), pos: pos } : (macro {});
		final currComputeExpr: Expr = acc.currCompute.length > 0 ? { expr: EBlock(acc.currCompute), pos: pos } : (macro {});
		final trackPrevExpr: Expr = acc.trackPrev.length > 0 ? { expr: EBlock(acc.trackPrev), pos: pos } : (macro {});
		return {
			initPrev: initPrev,
			initCurr: initCurr,
			currCompute: currComputeExpr,
			trackPrev: trackPrevExpr,
			blanksCount: blanksCountExpr,
			headEmit: headEmit
		};
	}

	/**
	 * After-ctor cascade compute — single-axis kind tracker per info (plus a
	 * tail-null tracker for tail-adapter infos). Appends to `acc`.
	 */
	private static function emitAfterCompute(acc: CascadeAccum, afterInfos: Array<AfterCtorBlankInfo>, pos: Position): Void {
		for (i => info in afterInfos) {
			acc.prevVars.push({ name: '_prevKindAfter$i', type: macro :Int, expr: macro 0 });
			acc.currVars.push({ name: '_currKindAfter$i', type: macro :Int, expr: macro 0 });
			final classifierAccess: Expr = { expr: EField(macro _t.node, info.classifierFieldName), pos: pos };
			final kindIdent: Expr = { expr: EConst(CIdent('_currKindAfter$i')), pos: pos };
			if (info.tailAdapterOptField == null) {
				final switchExpr: Expr = { expr: ESwitch(classifierAccess, info.classifyCases, null), pos: pos };
				acc.currCompute.push(macro $kindIdent = $switchExpr);
			} else {
				// ω-after-conditional-block — additionally track whether the
				// matched element's tail-leaf classify returns null (tail is NOT
				// import / using). The matched classify case binds `_v0` (the
				// wrapper payload); run the adapter on it inside that case body so
				// both trackers are set from one switch. `info.classifyCases` has
				// `expr: 1` on the matched (`_v0`-binding) case and `expr: 0`
				// elsewhere — rewrite each into a `{kind = …; tailNull = …}` block.
				acc.currVars.push({ name: '_currTailNullAfter$i', type: macro :Int, expr: macro 0 });
				acc.prevVars.push({ name: '_prevTailNullAfter$i', type: macro :Int, expr: macro 0 });
				final tailNullIdent: Expr = { expr: EConst(CIdent('_currTailNullAfter$i')), pos: pos };
				final adapterCall: Expr = WriterLowering.astPredCallT(info.tailAdapterOptField, [macro _v0]);
				final dualCases: Array<Case> = [
					for (c in info.classifyCases) {
						// The builder marks the single matched (`_v0`-binding) case
						// with `expr: macro 1`; every non-matched case is `macro 0`.
						final isMatchCase: Bool = switch (c.expr != null ? c.expr.expr : null) {
							case EConst(CInt('1', _)): true;
							case _: false;
						};
						{
							values: c.values,
							guard: c.guard,
							expr: isMatchCase
								? macro {
									$kindIdent = 1;
									$tailNullIdent = $adapterCall == null ? 1 : 0;
								}
								: macro {
									$kindIdent = 0;
									$tailNullIdent = 0;
								}
						}
					}
				];
				acc.currCompute.push({ expr: ESwitch(classifierAccess, dualCases, null), pos: pos });
				final tnLhs: Expr = { expr: EConst(CIdent('_prevTailNullAfter$i')), pos: pos };
				final tnRhs: Expr = { expr: EConst(CIdent('_currTailNullAfter$i')), pos: pos };
				acc.trackPrev.push(macro $tnLhs = $tnRhs);
			}
			final tlhs: Expr = { expr: EConst(CIdent('_prevKindAfter$i')), pos: pos };
			final trhs: Expr = { expr: EConst(CIdent('_currKindAfter$i')), pos: pos };
			acc.trackPrev.push(macro $tlhs = $trhs);
		}
	}

	/**
	 * Before-ctor cascade compute — same single-axis shape as after-ctor with
	 * separate idents, plus an optional `prevExcludeCases` binary tracker.
	 * Appends to `acc`.
	 */
	private static function emitBeforeCompute(acc: CascadeAccum, beforeInfos: Array<BeforeCtorBlankInfo>, pos: Position): Void {
		for (i => info in beforeInfos) {
			acc.prevVars.push({ name: '_prevKindBefore$i', type: macro :Int, expr: macro 0 });
			acc.currVars.push({ name: '_currKindBefore$i', type: macro :Int, expr: macro 0 });
			final classifierAccess: Expr = { expr: EField(macro _t.node, info.classifierFieldName), pos: pos };
			final switchExpr: Expr = { expr: ESwitch(classifierAccess, info.classifyCases, null), pos: pos };
			final lhs: Expr = { expr: EConst(CIdent('_currKindBefore$i')), pos: pos };
			acc.currCompute.push(macro $lhs = $switchExpr);
			final tlhs: Expr = { expr: EConst(CIdent('_prevKindBefore$i')), pos: pos };
			final trhs: Expr = { expr: EConst(CIdent('_currKindBefore$i')), pos: pos };
			acc.trackPrev.push(macro $tlhs = $trhs);
			// ω-before-multiline-prev-not — second binary classify-switch on
			// the same classifier field, tracking whether the element matched
			// an excluded-prev ctor (e.g. `Conditional`). Only built when the
			// info carries `prevExcludeCases`; the ternary below adds a
			// `_prevKindPrevExcl != 1` guard so the override is suppressed when
			// the previous sibling was excluded (falls through to source).
			final prevExcludeCases: Null<Array<Case>> = info.prevExcludeCases;
			if (prevExcludeCases == null) continue;
			acc.prevVars.push({ name: '_prevKindPrevExcl$i', type: macro :Int, expr: macro 0 });
			acc.currVars.push({ name: '_currKindPrevExcl$i', type: macro :Int, expr: macro 0 });
			final exclSwitch: Expr = { expr: ESwitch(classifierAccess, prevExcludeCases, null), pos: pos };
			final exclLhs: Expr = { expr: EConst(CIdent('_currKindPrevExcl$i')), pos: pos };
			acc.currCompute.push(macro $exclLhs = $exclSwitch);
			final exclTlhs: Expr = { expr: EConst(CIdent('_prevKindPrevExcl$i')), pos: pos };
			final exclTrhs: Expr = { expr: EConst(CIdent('_currKindPrevExcl$i')), pos: pos };
			acc.trackPrev.push(macro $exclTlhs = $exclTrhs);
		}
	}

	/**
	 * Between-ctor cascade compute — kind+path trackers on head AND tail axes,
	 * transparent-wrapper support via the shared head/tail adapter pair.
	 * Appends to `acc`.
	 */
	private static function emitBetweenCompute(acc: CascadeAccum, betweenInfos: Array<BetweenCtorBlankInfo>, pos: Position): Void {
		for (i => info in betweenInfos) {
			acc.prevVars.push({ name: '_prevTailKindBetween$i', type: macro :Int, expr: macro 0 });
			acc.prevVars.push({ name: '_prevTailPathBetween$i', type: macro :String, expr: macro '' });
			acc.currVars.push({ name: '_currTailKindBetween$i', type: macro :Int, expr: macro 0 });
			acc.currVars.push({ name: '_currTailPathBetween$i', type: macro :String, expr: macro '' });
			acc.currVars.push({ name: '_currHeadKindBetween$i', type: macro :Int, expr: macro 0 });
			acc.currVars.push({ name: '_currHeadPathBetween$i', type: macro :String, expr: macro '' });

			final classifierAccess: Expr = { expr: EField(macro _t.node, info.classifierFieldName), pos: pos };
			final tailKindIdent: Expr = { expr: EConst(CIdent('_currTailKindBetween$i')), pos: pos };
			final tailPathIdent: Expr = { expr: EConst(CIdent('_currTailPathBetween$i')), pos: pos };
			final headKindIdent: Expr = { expr: EConst(CIdent('_currHeadKindBetween$i')), pos: pos };
			final headPathIdent: Expr = { expr: EConst(CIdent('_currHeadPathBetween$i')), pos: pos };

			final ctorNameMatch: Expr = {
				var acc2: Expr = macro false;
				for (cn in info.matchedCtorNames) {
					final lit: Expr = { expr: EConst(CString(cn)), pos: pos };
					acc2 = macro $acc2 || _r.ctorName == $lit;
				}
				acc2;
			};
			final tailBody: Expr = if (info.tailAdapterOptField == null)
				macro {
					$tailKindIdent = 0;
					$tailPathIdent = '';
				}
			else {
				final adapterCall: Expr = WriterLowering.astPredCallT(info.tailAdapterOptField, [macro _v0]);
				macro {
					final _r = $adapterCall;
					if (_r != null && $ctorNameMatch) {
						$tailKindIdent = 1;
						$tailPathIdent = _r.path;
					} else {
						$tailKindIdent = 0;
						$tailPathIdent = '';
					}
				};
			}
			final headBody: Expr = if (info.headAdapterOptField == null)
				macro {
					$headKindIdent = 0;
					$headPathIdent = '';
				}
			else {
				final adapterCall: Expr = WriterLowering.astPredCallT(info.headAdapterOptField, [macro _v0]);
				macro {
					final _r = $adapterCall;
					if (_r != null && $ctorNameMatch) {
						$headKindIdent = 1;
						$headPathIdent = _r.path;
					} else {
						$headKindIdent = 0;
						$headPathIdent = '';
					}
				};
			}
			final transparentBody: Expr = macro {
				$tailBody;
				$headBody;
			};
			// ω-orphan-prefix-decl: the null arm — same zero body an unmatched
			// ctor gets. See `resolveCtorBlankArgs` for why it is mandatory once
			// the classifier field can be absent.
			final noMatchBody: Expr = macro {
				$tailKindIdent = 0;
				$tailPathIdent = '';
				$headKindIdent = 0;
				$headPathIdent = '';
			};
			final cases: Array<Case> = [
				for (cp in info.ctorPatterns)
					{
						values: [cp.pattern],
						guard: null,
						expr: cp.isMatch
							? macro {
								// `_v0` is the matched ctor's first positional
								// arg. For ctors whose first arg is a leaf path
								// terminal (`HxTypeName` / `HxWildPath` abstracts
								// over `String`), `_v0` IS the path string and
								// `Reflect.hasField` returns false. For ctors
								// whose first arg is a struct sub-rule carrying
								// a `.path` field (`HxImportAlias`), the lookup
								// extracts the dotted-ident path. Multi-arg
								// enum branches are unsupported by the PEG
								// lowering so this is the only struct-payload
								// shape the cascade has to recognise.
								final _v0Path: String = Reflect.hasField(_v0, 'path') ? Std.string(Reflect.field(_v0, 'path')) : '$_v0';
								$tailKindIdent = 1;
								$tailPathIdent = _v0Path;
								$headKindIdent = 1;
								$headPathIdent = _v0Path;
							}
							: cp.isTransparent ? transparentBody : noMatchBody
					}
			];
			cases.push({ values: [macro null], guard: null, expr: noMatchBody });
			acc.currCompute.push({ expr: ESwitch(classifierAccess, cases, null), pos: pos });

			final pkLhs: Expr = { expr: EConst(CIdent('_prevTailKindBetween$i')), pos: pos };
			final pkRhs: Expr = { expr: EConst(CIdent('_currTailKindBetween$i')), pos: pos };
			final ppLhs: Expr = { expr: EConst(CIdent('_prevTailPathBetween$i')), pos: pos };
			final ppRhs: Expr = { expr: EConst(CIdent('_currTailPathBetween$i')), pos: pos };
			acc.trackPrev.push(macro $pkLhs = $pkRhs);
			acc.trackPrev.push(macro $ppLhs = $ppRhs);
		}
	}

	/**
	 * Between-same-ctor-if-not cascade compute — single-axis kind tracker per
	 * info (ω-between-single-line-types). Appends to `acc`.
	 */
	private static function emitBetweenIfNotCompute(
		acc: CascadeAccum, betweenIfNotInfos: Array<BetweenSameCtorIfNotInfo>, pos: Position
	): Void {
		for (i => info in betweenIfNotInfos) {
			acc.prevVars.push({ name: '_prevKindBetweenIfNot$i', type: macro :Int, expr: macro 0 });
			acc.currVars.push({ name: '_currKindBetweenIfNot$i', type: macro :Int, expr: macro 0 });
			final classifierAccess: Expr = { expr: EField(macro _t.node, info.classifierFieldName), pos: pos };
			final switchExpr: Expr = { expr: ESwitch(classifierAccess, info.classifyCases, null), pos: pos };
			final lhs: Expr = { expr: EConst(CIdent('_currKindBetweenIfNot$i')), pos: pos };
			acc.currCompute.push(macro $lhs = $switchExpr);
			final tlhs: Expr = { expr: EConst(CIdent('_prevKindBetweenIfNot$i')), pos: pos };
			final trhs: Expr = { expr: EConst(CIdent('_currKindBetweenIfNot$i')), pos: pos };
			acc.trackPrev.push(macro $tlhs = $trhs);
		}
	}

	/**
	 * Cross-subset transition cascade compute — A/B subset trackers on head
	 * AND tail axes, transparent-wrapper support via the head/tail adapter
	 * pair. Appends to `acc`.
	 */
	private static function emitTransitionCompute(acc: CascadeAccum, transitionInfos: Array<TransitionAcrossInfo>, pos: Position): Void {
		for (i => info in transitionInfos) {
			acc.prevVars.push({ name: '_prevTailKindAcrossA$i', type: macro :Int, expr: macro 0 });
			acc.prevVars.push({ name: '_prevTailKindAcrossB$i', type: macro :Int, expr: macro 0 });
			acc.currVars.push({ name: '_currTailKindAcrossA$i', type: macro :Int, expr: macro 0 });
			acc.currVars.push({ name: '_currTailKindAcrossB$i', type: macro :Int, expr: macro 0 });
			acc.currVars.push({ name: '_currHeadKindAcrossA$i', type: macro :Int, expr: macro 0 });
			acc.currVars.push({ name: '_currHeadKindAcrossB$i', type: macro :Int, expr: macro 0 });

			final classifierAccess: Expr = { expr: EField(macro _t.node, info.classifierFieldName), pos: pos };
			final tkaIdent: Expr = { expr: EConst(CIdent('_currTailKindAcrossA$i')), pos: pos };
			final tkbIdent: Expr = { expr: EConst(CIdent('_currTailKindAcrossB$i')), pos: pos };
			final hkaIdent: Expr = { expr: EConst(CIdent('_currHeadKindAcrossA$i')), pos: pos };
			final hkbIdent: Expr = { expr: EConst(CIdent('_currHeadKindAcrossB$i')), pos: pos };
			final tailAdapterCall: Null<Expr> = info.tailAdapterOptField == null
				? null
				: WriterLowering.astPredCallT(info.tailAdapterOptField, [macro _v0]);
			final headAdapterCall: Null<Expr> = info.headAdapterOptField == null
				? null
				: WriterLowering.astPredCallT(info.headAdapterOptField, [macro _v0]);
			final tailMatchA: Expr = transitionAdapterMatchExpr(info.tailAdapterOptField, info.matchedCtorNamesA, pos);
			final tailMatchB: Expr = transitionAdapterMatchExpr(info.tailAdapterOptField, info.matchedCtorNamesB, pos);
			final headMatchA: Expr = transitionAdapterMatchExpr(info.headAdapterOptField, info.matchedCtorNamesA, pos);
			final headMatchB: Expr = transitionAdapterMatchExpr(info.headAdapterOptField, info.matchedCtorNamesB, pos);
			final transparentBody: Expr = if (tailAdapterCall == null && headAdapterCall == null)
				macro {
					$tkaIdent = 0;
					$tkbIdent = 0;
					$hkaIdent = 0;
					$hkbIdent = 0;
				}
			else if (headAdapterCall == null)
				macro {
					final _r = $tailAdapterCall;
					$tkaIdent = $tailMatchA;
					$tkbIdent = $tailMatchB;
					$hkaIdent = 0;
					$hkbIdent = 0;
				}
			else if (tailAdapterCall == null)
				macro {
					final _r = $headAdapterCall;
					$hkaIdent = $headMatchA;
					$hkbIdent = $headMatchB;
					$tkaIdent = 0;
					$tkbIdent = 0;
				}
			else
				macro {
					final _r = $tailAdapterCall;
					$tkaIdent = $tailMatchA;
					$tkbIdent = $tailMatchB;
					{
						final _r = $headAdapterCall;
						$hkaIdent = $headMatchA;
						$hkbIdent = $headMatchB;
					}
				};
			// ω-orphan-prefix-decl: the null arm — same zero body an unmatched
			// ctor gets. See `resolveCtorBlankArgs` for why it is mandatory once
			// the classifier field can be absent.
			final noMatchBody: Expr = macro {
				$tkaIdent = 0;
				$tkbIdent = 0;
				$hkaIdent = 0;
				$hkbIdent = 0;
			};
			final cases: Array<Case> = [
				for (cp in info.ctorPatterns)
					{
						values: [cp.pattern],
						guard: null,
						expr: switch cp.subset {
							case 1: macro {
								$tkaIdent = 1;
								$tkbIdent = 0;
								$hkaIdent = 1;
								$hkbIdent = 0;
							};
							case 2: macro {
								$tkaIdent = 0;
								$tkbIdent = 1;
								$hkaIdent = 0;
								$hkbIdent = 1;
							};
							case 3: transparentBody; // noqa: magic-number
							case _: noMatchBody;
						}
					}
			];
			cases.push({ values: [macro null], guard: null, expr: noMatchBody });
			acc.currCompute.push({ expr: ESwitch(classifierAccess, cases, null), pos: pos });

			final pkaLhs: Expr = { expr: EConst(CIdent('_prevTailKindAcrossA$i')), pos: pos };
			final pkaRhs: Expr = { expr: EConst(CIdent('_currTailKindAcrossA$i')), pos: pos };
			final pkbLhs: Expr = { expr: EConst(CIdent('_prevTailKindAcrossB$i')), pos: pos };
			final pkbRhs: Expr = { expr: EConst(CIdent('_currTailKindAcrossB$i')), pos: pos };
			acc.trackPrev.push(macro $pkaLhs = $pkaRhs);
			acc.trackPrev.push(macro $pkbLhs = $pkbRhs);
		}
	}

	/**
	 * Build the `(_r != null && (_r.ctorName == "A" || …)) ? 1 : 0` adapter
	 * match Expr for the transition cascade — `macro 0` when no adapter is
	 * wired.
	 */
	private static function transitionAdapterMatchExpr(adapterField: Null<String>, names: Array<String>, pos: Position): Expr {
		if (adapterField == null) return macro 0;
		var acc: Expr = macro false;
		for (cn in names) {
			final lit: Expr = { expr: EConst(CString(cn)), pos: pos };
			acc = macro $acc || _r.ctorName == $lit;
		}
		return macro _r != null && $acc ? 1 : 0;
	}

	/**
	 * Fold the after-ctor cascade ternaries onto `blanksCountExpr` — fires
	 * `opt.<f>` blanks when the previous element matched the ctor (tail-adapter
	 * infos additionally require the tail leaf was NOT import/using).
	 */
	private static function foldAfterCascade(blanksCountExpr: Expr, afterInfos: Array<AfterCtorBlankInfo>, pos: Position): Expr {
		var result: Expr = blanksCountExpr;
		for (i in 0...afterInfos.length) {
			final idx: Int = afterInfos.length - 1 - i;
			final info: AfterCtorBlankInfo = afterInfos[idx];
			final afterAccess: Expr = { expr: EField(macro opt, info.optField), pos: pos };
			final prevIdent: Expr = { expr: EConst(CIdent('_prevKindAfter$idx')), pos: pos };
			final fallback: Expr = result;
			// ω-after-conditional-block — tail-adapter infos gain a
			// `_prevTailNullAfter != 0` guard so the override fires only when
			// the previous element matched the ctor AND its tail leaf was NOT
			// an import / using (adapter returned null). Plain after-ctor infos
			// keep the bare `_prevKind == 1` gate, byte-identical.
			final gate: Expr = if (info.tailAdapterOptField == null)
				macro $prevIdent == 1;
			else {
				final prevTailNullIdent: Expr = { expr: EConst(CIdent('_prevTailNullAfter$idx')), pos: pos };
				macro $prevIdent == 1 && $prevTailNullIdent == 1;
			}
			result = macro ($gate ? $afterAccess : $fallback);
		}
		return result;
	}

	/**
	 * Fold the before-ctor cascade ternaries onto `blanksCountExpr` (reverse
	 * order so info[0] is outermost). Optional `prevExcludeCases` adds a
	 * `_prevKindPrevExcl != 1` guard.
	 */
	private static function foldBeforeCascade(blanksCountExpr: Expr, beforeInfos: Array<BeforeCtorBlankInfo>, pos: Position): Expr {
		var result: Expr = blanksCountExpr;
		for (i in 0...beforeInfos.length) {
			final idx: Int = beforeInfos.length - 1 - i;
			final info: BeforeCtorBlankInfo = beforeInfos[idx];
			final beforeAccess: Expr = { expr: EField(macro opt, info.optField), pos: pos };
			final currIdent: Expr = { expr: EConst(CIdent('_currKindBefore$idx')), pos: pos };
			final prevIdent: Expr = { expr: EConst(CIdent('_prevKindBefore$idx')), pos: pos };
			final fallback: Expr = result;
			// ω-before-multiline-prev-not — gate construction: when the info
			// carries `prevExcludeCases`, the fire condition gains a
			// `_prevKindPrevExcl != 1` guard so the override falls through to
			// the source-driven fallback when the previous sibling matched an
			// excluded ctor (e.g. a cond-comp `#if … #end`). Without
			// `prevExcludeCases` the gate is the original two-term form —
			// byte-identical for every existing `blankLinesBeforeCtor{,If}`.
			final gate: Expr = if (info.prevExcludeCases == null)
				macro $currIdent == 1 && $prevIdent != 1;
			else {
				final prevExclIdent: Expr = { expr: EConst(CIdent('_prevKindPrevExcl$idx')), pos: pos };
				macro $currIdent == 1 && $prevIdent != 1 && $prevExclIdent != 1;
			}
			result = macro ($gate ? $beforeAccess : $fallback);
		}
		return result;
	}

	/**
	 * Fold the between-ctor cascade ternaries onto `blanksCountExpr` —
	 * head/tail kind+path match with a null-guarded `differ` adapter call and
	 * the keep-source-blank-across-conditional widening.
	 */
	private static function foldBetweenCascade(blanksCountExpr: Expr, betweenInfos: Array<BetweenCtorBlankInfo>, pos: Position): Expr {
		var result: Expr = blanksCountExpr;
		for (i in 0...betweenInfos.length) {
			final idx: Int = betweenInfos.length - 1 - i;
			final info: BetweenCtorBlankInfo = betweenInfos[idx];
			final countAccess: Expr = { expr: EField(macro opt, info.countOptField), pos: pos };
			final levelAccess: Expr = { expr: EField(macro opt, info.levelOptField), pos: pos };
			final adapterAccess: Expr = { expr: EField(macro opt, info.adapterOptField), pos: pos };
			final currKindIdent: Expr = { expr: EConst(CIdent('_currHeadKindBetween$idx')), pos: pos };
			final prevKindIdent: Expr = { expr: EConst(CIdent('_prevTailKindBetween$idx')), pos: pos };
			final currPathIdent: Expr = { expr: EConst(CIdent('_currHeadPathBetween$idx')), pos: pos };
			final prevPathIdent: Expr = { expr: EConst(CIdent('_prevTailPathBetween$idx')), pos: pos };
			final differCall: Expr = { expr: ECall(adapterAccess, [prevPathIdent, currPathIdent, levelAccess]), pos: pos };
			final fallback: Expr = result;
			// Null-guard the adapter call — `WriteOptions.<adapterOptField>` is
			// declared `Null<(String,String,Int)->Bool>`, and the consuming
			// writer files (HxModuleWriter / HaxeModuleTriviaWriter, both
			// `@:nullSafety(Strict)`) reject a bare `opt.f(...)` call. The `&&`
			// short-circuit on `$adapterAccess != null` keeps the path inert
			// when no adapter is wired (cascade falls through to the fallback /
			// source-driven blank count).
			//
			// ω-D12-keep-source-blank-across-conditional — when
			// `opt.keepSourceBlankAcrossConditional` is opt-in `true` AND the
			// current item has a captured source blank (`_t.blankBefore`), the
			// emitted count is widened to `max(countAccess, 1)` so a real
			// source blank around `(prevImport, #if … importB; #end)` survives
			// the head/tail-transparency override path with `betweenImports=0`.
			// Default `false` preserves fork byte-identical behaviour — the
			// override emits `$countAccess` unchanged.
			final betweenChosen: Expr = macro (
				opt.keepSourceBlankAcrossConditional && _t.blankBefore && $countAccess < 1 ? 1 : $countAccess
			);
			result = macro (
				$currKindIdent == 1 && $prevKindIdent == 1 && $adapterAccess != null && $differCall ? $betweenChosen : $fallback
			);
		}
		return result;
	}

	/**
	 * Fold the between-same-ctor-if-not cascade ternaries onto
	 * `blanksCountExpr` — fires `opt.<f>` blanks when both prev and curr
	 * trackers report 1 AND `opt > 0` (ω-between-single-line-types,
	 * insertion-only).
	 */
	private static function foldBetweenIfNotCascade(
		blanksCountExpr: Expr, betweenIfNotInfos: Array<BetweenSameCtorIfNotInfo>, pos: Position
	): Expr {
		var result: Expr = blanksCountExpr;
		for (i in 0...betweenIfNotInfos.length) {
			final idx: Int = betweenIfNotInfos.length - 1 - i;
			final info: BetweenSameCtorIfNotInfo = betweenIfNotInfos[idx];
			final optAccess: Expr = { expr: EField(macro opt, info.optField), pos: pos };
			final currIdent: Expr = { expr: EConst(CIdent('_currKindBetweenIfNot$idx')), pos: pos };
			final prevIdent: Expr = { expr: EConst(CIdent('_prevKindBetweenIfNot$idx')), pos: pos };
			final fallback: Expr = result;
			result = macro ($currIdent == 1 && $prevIdent == 1 && $optAccess > 0 ? $optAccess : $fallback);
		}
		return result;
	}

	/**
	 * Fold the cross-subset transition cascade ternaries onto
	 * `blanksCountExpr` — fires `opt.<count>` blanks on an A→B or B→A
	 * head/tail transition.
	 */
	private static function foldTransitionCascade(
		blanksCountExpr: Expr, transitionInfos: Array<TransitionAcrossInfo>, pos: Position
	): Expr {
		var result: Expr = blanksCountExpr;
		for (i in 0...transitionInfos.length) {
			final idx: Int = transitionInfos.length - 1 - i;
			final info: TransitionAcrossInfo = transitionInfos[idx];
			final countAccess: Expr = { expr: EField(macro opt, info.countOptField), pos: pos };
			final currHKAIdent: Expr = { expr: EConst(CIdent('_currHeadKindAcrossA$idx')), pos: pos };
			final currHKBIdent: Expr = { expr: EConst(CIdent('_currHeadKindAcrossB$idx')), pos: pos };
			final prevTKAIdent: Expr = { expr: EConst(CIdent('_prevTailKindAcrossA$idx')), pos: pos };
			final prevTKBIdent: Expr = { expr: EConst(CIdent('_prevTailKindAcrossB$idx')), pos: pos };
			final fallback: Expr = result;
			result = macro (
				($currHKAIdent == 1 && $prevTKBIdent == 1) || ($currHKBIdent == 1 && $prevTKAIdent == 1) ? $countAccess : $fallback
			);
		}
		return result;
	}

	/**
	 * Build the head-of-Star blank-line emit block (ω-before-package). Each
	 * info contributes a `_arr[0].node.<classifier>` switch; the cascade picks
	 * the first matching `opt.<optField>` (source order = priority). Empty
	 * `headInfos` → `macro {}`.
	 */
	private static function buildHeadEmit(headInfos: Array<HeadCtorBlankInfo>, pos: Position): Expr {
		var headBlanksExpr: Expr = macro 0;
		for (i in 0...headInfos.length) {
			final idx: Int = headInfos.length - 1 - i;
			final info: HeadCtorBlankInfo = headInfos[idx];
			final classifierAccess: Expr = { expr: EField(macro _arr[0].node, info.classifierFieldName), pos: pos };
			final switchExpr: Expr = { expr: ESwitch(classifierAccess, info.classifyCases, null), pos: pos };
			final optAccess: Expr = { expr: EField(macro opt, info.optField), pos: pos };
			final fallback: Expr = headBlanksExpr;
			headBlanksExpr = macro ($switchExpr == 1 ? $optAccess : $fallback);
		}
		return headInfos.length == 0
			? (macro {})
			: (macro if (_arr.length > 0) {
				final _hb: Int = $headBlanksExpr;
				var _hbi: Int = 0;
				while (_hbi < _hb) {
					_docs.push(_dhl());
					_hbi++;
				}
			});
	}

	/**
	 * Build the per-branch `BetweenCtorPattern` list for
	 * `@:fmt(blankLinesBetweenSameCtorByLevel)`, classifying each enum
	 * branch as matched / tail-transparent / inert and binding `_v0` on
	 * the payload arg. Returns the patterns plus the matched and
	 * transparent-matched ctor-name sets the caller verifies against.
	 *
	 */
	private static function buildBetweenCtorPatterns(
		enumRule: ShapeNode, ctorNames: Array<String>, transparentCtorNames: Array<String>, pos: Position
	): { patterns: Array<BetweenCtorPattern>, matched: Array<String>, transparentMatched: Array<String> } {
		final patterns: Array<BetweenCtorPattern> = [];
		final matched: Array<String> = [];
		final transparentMatched: Array<String> = [];
		for (branch in enumRule.children) {
			final ctorName: Null<String> = branch.annotations.get(AnnotationKeys.BASE_CTOR);
			if (ctorName == null) continue;
			final arity: Int = branch.children.length;
			final ctorIdent: Expr = { expr: EConst(CIdent(ctorName)), pos: pos };
			final isMatch: Bool = ctorNames.indexOf(ctorName) >= 0;
			final isTransparent: Bool = !isMatch && transparentCtorNames.indexOf(ctorName) >= 0;
			if (isMatch) {
				if (arity < 1)
					Context.fatalError(
						'WriterLowering: @:fmt(blankLinesBetweenSameCtorByLevel) ctor "$ctorName'
						+ '" must have arity ≥ 1 (first arg is the path payload bound to _v0); got arity $arity',
						Context.currentPos()
					);
				matched.push(ctorName);
				final binders: Array<Expr> = [for (i in 0...arity) i == 0 ? macro _v0 : macro _];
				patterns.push({
					pattern: { expr: ECall(ctorIdent, binders), pos: pos },
					isMatch: true,
					isTransparent: false
				});
			} else if (isTransparent) {
				if (arity < 1)
					Context.fatalError(
						'WriterLowering: @:fmt(blankLinesBetweenSameCtorTailTransparent) ctor "$ctorName" must have arity ≥ 1 ('
						+ 'first arg is the wrapper payload bound to _v0 and passed to the tail-leaf classifier adapter); got arity $arity',
						Context.currentPos()
					);
				transparentMatched.push(ctorName);
				final binders: Array<Expr> = [for (i in 0...arity) i == 0 ? macro _v0 : macro _];
				patterns.push({
					pattern: { expr: ECall(ctorIdent, binders), pos: pos },
					isMatch: false,
					isTransparent: true
				});
			} else {
				final pattern: Expr = arity == 0 ? ctorIdent : {
					expr: ECall(ctorIdent, [for (_ in 0...arity) macro _]),
					pos: pos
				};
				patterns.push({ pattern: pattern, isMatch: false, isTransparent: false });
			}
		}
		return { patterns: patterns, matched: matched, transparentMatched: transparentMatched };
	}

	/**
	 * Build the top-level classify switch cases for an inter-member-blank-
	 * lines classifier. The `kindFor`/`patternFor` local builders plus the look-through `innerCases`
	 * and the per-ctor `cases` loop.
	 */
	private static function buildInterMemberClassifyCases(c: InterMemberCasesCtx): Array<Case> {
		final enumRule: ShapeNode = c.enumRule;
		final varCtors: Array<String> = c.varCtors;
		final fnCtors: Array<String> = c.fnCtors;
		final condCtor: Null<String> = c.condCtor;
		final bodyField: Null<String> = c.bodyField;
		final fieldName: String = c.fieldName;
		final pos: Position = Context.currentPos();
		// Base var/fn/other kind mapping for the TOP-level classify switch:
		// var family → `1`, fn → `2`, everything else → `0`.
		inline function kindFor(ctorName: String): Expr {
			return if (varCtors.contains(ctorName))
				macro 1;
			else if (fnCtors.contains(ctorName))
				macro 2;
			else
				macro 0;
		}
		// `case <Ctor>(_, …):` pattern for one enum variant, binding the
		// single ctor arg to `_inner` when `bindInner` (the look-through
		// ctor needs the wrapper to reach its body Star).
		inline function patternFor(branch: ShapeNode, ctorName: String, bindInner: Bool): Expr {
			final arity: Int = branch.children.length;
			final ctorIdent: Expr = { expr: EConst(CIdent(ctorName)), pos: pos };
			return arity == 0 ? ctorIdent : {
				expr: ECall(ctorIdent, [for (i in 0...arity) bindInner && i == 0 ? macro _inner : macro _]),
				pos: pos
			};
		}
		// Nested classify cases for the look-through switch. The look-through
		// is deliberately FUNCTION-ONLY: an inner `fnCtor` member yields kind
		// `2`, EVERYTHING else (including var-family ctors and a nested
		// `condCtor`) yields `0`. The fork's `markClassFieldEmptyLines` pairs
		// the REAL inner fields across the `#if … #end` boundary, factoring in
		// each field's static-ness and visibility (afterStaticVars /
		// afterPrivateVars), and lets the doc-comment policy override the
		// field-type blank for doc-comment-led members. anyparse classifies a
		// whole conditional MEMBER as one outer-loop unit, so promoting a
		// var-bearing conditional to kind `1`/`3` cannot reproduce that
		// field-vs-field static/visibility/doc-comment arbitration and instead
		// over-fires the static-var subdivision cascade (afterStaticVars) and
		// the `none`-doc-comment strip. The function family carries no such
		// subdivision at member scope (afterStaticFunctions etc. are not
		// modelled here) and no doc-comment-strip conflict surfaced in the
		// corpus, so fn-only is the byte-safe subset: two consecutive
		// function-bearing conditional members get a `betweenFunctions` blank,
		// nothing else changes.
		final innerCases: Array<Case> = condCtor == null ? [] : [
			for (branch in enumRule.children) if (branch.annotations.get(AnnotationKeys.BASE_CTOR) != null) {
				final ctorName: String = branch.annotations.get(AnnotationKeys.BASE_CTOR);
				{ values: [patternFor(branch, ctorName, false)], guard: null, expr: fnCtors.contains(ctorName) ? macro 2 : macro 0 };
			}
		];
		// A classifier field declared `@:optional` (Haxe `HxMemberDecl.member`,
		// absent for a prefix-only member such as a member-position `#if X #end`
		// region with nothing after it) reaches the switch as null. Without an
		// explicit arm the emitted switch is exhaustive over the ctors only and
		// strict null-safety rejects the subject. Kind `0` is the same answer
		// every non-var / non-fn ctor gets, so a member with no declaration
		// takes part in no blank-line cascade.
		if (condCtor != null) innerCases.push({ values: [macro null], guard: null, expr: macro 0 });
		final cases: Array<Case> = [];
		for (branch in enumRule.children) {
			final ctorName: Null<String> = branch.annotations.get(AnnotationKeys.BASE_CTOR);
			if (ctorName == null) continue;
			final isLookThrough: Bool = condCtor != null && ctorName == condCtor;
			final pattern: Expr = patternFor(branch, ctorName, isLookThrough);
			final kindExpr: Expr = if (isLookThrough) {
				// `_inner.<bodyField>[0].node.<classifierField>` — the body
				// Star is trivia-collected so `[0]` is a trivia wrapper with
				// a `.node` raw accessor; `.node.<classifierField>` is the
				// inner member's classifier enum.
				final innerBodyAccess: Expr = { expr: EField(macro _inner, bodyField), pos: pos };
				final innerClassifier: Expr = {
					expr: EField({ expr: EField(macro $innerBodyAccess[0], 'node'), pos: pos }, fieldName),
					pos: pos
				};
				final innerSwitch: Expr = { expr: ESwitch(innerClassifier, innerCases, null), pos: pos };
				macro ($innerBodyAccess.length > 0 ? $innerSwitch : 0);
			} else {
				kindFor(ctorName);
			}
			cases.push({ values: [pattern], guard: null, expr: kindExpr });
		}
		cases.push({ values: [macro null], guard: null, expr: macro 0 });
		return cases;
	}

	/**
	 * Split the `@:fmt(blankLinesOnTransitionAcross)` arg list into subset A
	 * and subset B around the `"|"` separator and run the pre-loop validation
	 * gates (separator position, non-empty sides, A/B disjointness, and
	 * matched-vs-transparent disjointness).
	 */
	private static function splitTransitionAcrossCtors(args: Array<String>, transparentCtorNames: Array<String>): TransitionAcrossSplit {
		final pipeIdx: Int = args.indexOf('|');
		if (pipeIdx < 2 || pipeIdx > args.length - 3)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesOnTransitionAcross) requires a "|" separator between subset A and subset B ('
				+ 'with at least one ctor on each side); got args $args',
				Context.currentPos()
			);
		final ctorNamesA: Array<String> = args.slice(1, pipeIdx);
		final ctorNamesB: Array<String> = args.slice(pipeIdx + 1, args.length - 1);
		if (ctorNamesA.length == 0 || ctorNamesB.length == 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesOnTransitionAcross) requires at least one ctor on each side of "|"', Context.currentPos()
			);
		for (name in ctorNamesA) if (ctorNamesB.indexOf(name) >= 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesOnTransitionAcross) ctor "$name'
				+ '" appears in both subset A and subset B — must be in exactly one',
				Context.currentPos()
			);
		for (name in ctorNamesA) if (transparentCtorNames.indexOf(name) >= 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesOnTransitionAcross) ctor "$name'
				+ '" appears both as a matched (subset A) and transparent ctor on the same Star — must be one or the other',
				Context.currentPos()
			);
		for (name in ctorNamesB) if (transparentCtorNames.indexOf(name) >= 0)
			Context.fatalError(
				'WriterLowering: @:fmt(blankLinesOnTransitionAcross) ctor "$name'
				+ '" appears both as a matched (subset B) and transparent ctor on the same Star — must be one or the other',
				Context.currentPos()
			);
		return { ctorNamesA: ctorNamesA, ctorNamesB: ctorNamesB };
	}

	/**
	 * Build one transition-across switch pattern: a bare ctor ident for arity
	 * 0, else `Ctor(<arg0>, _, …)` where `arg0` is `_v0` when `bindFirst`
	 * (matched subsets A/B bind the first payload) and `_` otherwise (subset
	 * 0 ignores it).
	 */
	private static function transitionPattern(ctorIdent: Expr, arity: Int, bindFirst: Bool, pos: Position): Expr {
		if (arity == 0) return ctorIdent;
		final binders: Array<Expr> = [for (i in 0...arity) bindFirst && i == 0 ? macro _v0 : macro _];
		return { expr: ECall(ctorIdent, binders), pos: pos };
	}

}
#end
