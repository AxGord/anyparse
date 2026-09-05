package anyparse.macro;

#if macro
import anyparse.core.LoweringCtx;
import anyparse.core.ShapeTree;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.MacroStringTools;

using Lambda;
using anyparse.macro.MetaInspect;

/**
 * Pass 3W — whether a branch must mirror its sibling's braces, and what the
 * mirror emits.
 *
 * `SingleStmtBraces` gate 7 says a de-braced branch keeps its braces when
 * its sibling kept them. Answering that at emit time needs two things the
 * grammar knows and the runtime does not: WHICH sibling is the counterpart
 * (`findThenSiblingAccess` finds the mandatory `dropSingleStmtBraces` field
 * of the same struct) and WHAT the symmetry test is for a VALUE-position
 * branch (`valueBraceSymmetryProbe` builds the
 * `SingleStmtBraces.symmetryNeedsValueWrap` call from the
 * `@:fmt(valueBraceSymmetry)` args). `fitGroupExpr` is the grouping the
 * mirrored branch renders under, and `foldSsbTrailingComment` folds the
 * de-braced statement's own trailing comment back into that group so it
 * enters the fit measurement rather than trailing the closing brace.
 *
 * Those four are pure functions of their arguments, and they were the whole of
 * this module until S91. What arrived then is the STATE-CARRYING half of the same
 * question — the twelve members that decide whether a body de-braces at all, and
 * what the mirror wraps it back into:
 *
 *  - `deBraceBodyAccess`, the entry: it substitutes a `@:fmt(dropSingleStmtBraces)`
 *    body field's runtime value with the unwrapped statement and hands back the two
 *    side channels its gates feed;
 *  - `valueBraceSymmetry{Wrap,StmtPath,TrailDrop}`, the VALUE-position mirror;
 *  - `try{Brace,CatchesBrace}SymmetryWrap`, the `try` / `catch` mirror;
 *  - `build{ThenSiblingKeeps,ElseChainSuppress}Expr` and `wrapElseChainSuppress`,
 *    the if/else CHAIN symmetry;
 *  - `starElementTypePath`, `seqFieldRefTarget` and `blockElemLift`, the rule
 *    lookups that answer "what type does this block hold one of", reached from
 *    nowhere else.
 *
 * Those twelve read build state, so unlike the first four they are not free to
 * move: each takes a `BraceSymmetryCtx` bundle (below), built once in
 * `WriterLowering`'s constructor and passed as the first argument. The price was
 * seven call sites there; the census that picked this family over its neighbours is
 * in `WriterLowering`'s own doc.
 *
 * `VALUE_BRACE_SYMMETRY_MIN_ARGS` came with them — both its readers are here now,
 * which is what let the class-level `@:access(anyparse.macro.WriterLowering)` go.
 */
final class WriterBraceSymmetryLowering {

	/** `@:fmt(valueBraceSymmetry)` required args (siblingField, blockCtor, stmtCtor); any further ones are skip-ctors. */
	private static inline final VALUE_BRACE_SYMMETRY_MIN_ARGS: Int = 3;

	/**
	 * The body-field flag that opts a construct into de-bracing, read at the four gates that
	 * must agree on ONE answer — the sibling probe, both chain-suppress halves, and the
	 * substitution itself. A site spelling it differently would de-brace a body whose sibling
	 * the chain never consulted.
	 */
	private static inline final DROP_SINGLE_STMT_BRACES: String = 'dropSingleStmtBraces';

	/**
	 * Locate the mandatory bodyPolicy sibling carrying `dropSingleStmtBraces`
	 * (the then-body) and build its `value.<then>` field-access expr. Shared by
	 * both if/else-body brace-symmetry probes; `null` when there is no such
	 * sibling (a for / while / do body has none).
	 */
	private static function findThenSiblingAccess(node: ShapeNode): Null<{ sibling: ShapeNode, name: String, access: Expr }> {
		final thenSibling: Null<ShapeNode> = node.children.find(
			c -> c.annotations.get(AnnotationKeys.BASE_OPTIONAL) != true && c.fmtHasFlag(DROP_SINGLE_STMT_BRACES)
		);
		final thenName: Null<String> = thenSibling?.annotations.get(AnnotationKeys.BASE_FIELD_NAME);
		return thenSibling == null || thenName == null ? null : {
			sibling: thenSibling,
			name: thenName,
			access: { expr: EField(macro value, thenName), pos: Context.currentPos() }
		};
	}

	/**
	 * The runtime `symmetryNeedsValueWrap(…)` test for `valueExpr`, built from ONE
	 * reading of the meta's args — the skip-ctor tail included. Both consumers (the
	 * wrap and the `@:trailOpt` drop) go through here, so the skip list cannot be
	 * taught to one of them alone.
	 */
	private static function valueBraceSymmetryProbe(args: Array<String>, valueExpr: Expr): Expr {
		final siblingAccess: Expr = { expr: EField(macro value, args[0]), pos: Context.currentPos() };
		// `$a{…}` in a call-argument position SPLICES its elements as separate arguments — build the
		// array literal itself, so the callee receives ONE `Array<String>`.
		final skipArray: Expr = {
			expr: EArrayDecl([for (c in args.slice(VALUE_BRACE_SYMMETRY_MIN_ARGS)) macro $v{c}]),
			pos: Context.currentPos()
		};
		final blockCtor: String = args[1];
		return macro anyparse.format.SingleStmtBraces.symmetryNeedsValueWrap(
			$valueExpr, $siblingAccess, opt.dropSingleStmtBraces || opt.singleStmtBraceSymmetry, $v{blockCtor}, $skipArray
		);
	}

	/**
	 * ω-single-stmt-braces trailing-comment hoist: fold a de-braced single
	 * statement's same-line trailing comment (`ssbTrailCommentExpr`, a runtime
	 * `Null<String>`) after the body's `;` via `foldTrailingIntoBodyGroup`, so it
	 * enters the body's fit/break measurement. Null off the dropSingleStmtBraces
	 * path -> the base writeCall is returned unchanged (byte-inert).
	 */
	private static function foldSsbTrailingComment(base: Expr, ssbTrailCommentExpr: Null<Expr>): Expr {
		return ssbTrailCommentExpr == null
			? base
			: macro {
				final _ssbBodyDoc: anyparse.core.Doc = $base;
				final _ssbTc: Null<String> = $ssbTrailCommentExpr;
				_ssbTc != null ? foldTrailingIntoBodyGroup(_ssbBodyDoc, trailingCommentDocVerbatim(_ssbTc, opt)) : _ssbBodyDoc;
			};
	}

	/**
	 * The construct-level cond-fit group for a body field carrying an optional `else` sibling --
	 * `BodyGroup` with no else, `Group` with one. On a node carrying `@:fmt(arrowValueIfReflow)` the
	 * `Group` arm is additionally suppressed while the value-if re-flow is active (see the call site);
	 * `_vifFit` exists only on such a node, and is false unless its knob is on, so every other struct
	 * is byte-identical.
	 */
	private static function fitGroupExpr(node: ShapeNode, elseAcc: Expr, grpInner: Expr): Expr {
		final grouped: Expr = node.fmtReadStringArgs('arrowValueIfReflow') == null
			? macro _dg($grpInner)
			: macro (_vifFit ? $grpInner : _dg($grpInner));
		return macro $elseAcc == null ? _dbg($grpInner) : $grouped;
	}

	/**
	 * The element type path of the `Star` branch of `typePath`'s `Alt` rule whose ctor is
	 * `ctor` — the type a `{ … }` block holds one of. `null` when the rule is not an `Alt`,
	 * carries no such branch, or the branch is not a single `Star`.
	 */
	private static function starElementTypePath(bs: BraceSymmetryCtx, typePath: String, ctor: String): Null<String> {
		final rule: Null<ShapeNode> = bs.shape.rules[typePath];
		if (rule == null || rule.kind != Alt) return null;
		for (branch in rule.children) if (branch.annotations.get(AnnotationKeys.BASE_CTOR) == ctor) {
			final star: Null<ShapeNode> = branch.children.length == 1 && branch.children[0].kind == Star ? branch.children[0] : null;
			return star == null || star.children.length == 0 ? null : star.children[0].annotations.get(AnnotationKeys.BASE_REF);
		}
		return null;
	}

	/**
	 * The ref target of the `Seq` rule `typePath`'s field named `fieldName` — how a
	 * catches-Star element reaches its sibling body field's own type.
	 */
	private static function seqFieldRefTarget(bs: BraceSymmetryCtx, typePath: String, fieldName: String): Null<String> {
		final rule: Null<ShapeNode> = bs.shape.rules[typePath];
		if (rule == null || rule.kind != Seq) return null;
		for (child in rule.children) if (child.kind == Ref && child.annotations.get(AnnotationKeys.BASE_FIELD_NAME) == fieldName)
			return child.annotations.get(AnnotationKeys.BASE_REF);
		return null;
	}

	/**
	 * The `inner -> <StmtCtor>(inner, true)` lift the runtime symmetry helpers call to
	 * re-wrap a de-braced body. `null` when the grammar named no stmt ctor or the block
	 * element type cannot be resolved.
	 */
	private static function blockElemLift(bs: BraceSymmetryCtx, valuePath: Null<String>, blockCtor: String, stmtCtor: Null<String>): Expr {
		if (valuePath == null || stmtCtor == null) return macro null;
		final stmtPath: Null<String> = starElementTypePath(bs, valuePath, blockCtor);
		if (stmtPath == null) return macro null;
		final stmtRef: Expr = MacroStringTools.toFieldExpr(bs.ruleCtorPath(stmtPath, stmtCtor));
		return macro (_tbsInner -> $stmtRef(cast _tbsInner, true));
	}

	/**
	 * The block-statement type path `@:fmt(valueBraceSymmetry)` wraps into on `child`,
	 * or `null` when the meta is absent, the build is plain, or the field carries no ref.
	 */
	private static function valueBraceSymmetryStmtPath(bs: BraceSymmetryCtx, child: ShapeNode, args: Null<Array<String>>): Null<String> {
		if (args == null || !bs.ctx.trivia) return null;
		if (args.length < VALUE_BRACE_SYMMETRY_MIN_ARGS)
			Context.fatalError(
				'WriterBraceSymmetryLowering: @:fmt(valueBraceSymmetry) expects at least 3 string args (siblingField, blockCtor'
				+ ', stmtCtor, [skipCtor…]), got ${args.length}',
				Context.currentPos()
			);
		final valuePath: Null<String> = child.annotations[AnnotationKeys.BASE_REF];
		return valuePath == null ? null : starElementTypePath(bs, valuePath, args[1]);
	}

	/**
	 * ω-value-brace-symmetry: wrap a VALUE-position branch back into a block when its
	 * sibling kept braces. Byte-inert for every field without `@:fmt(valueBraceSymmetry)`.
	 */
	private static function valueBraceSymmetryWrap(bs: BraceSymmetryCtx, child: ShapeNode, fieldAccess: Expr): Expr {
		final args: Null<Array<String>> = child.fmtReadStringArgs('valueBraceSymmetry');
		final stmtPath: Null<String> = valueBraceSymmetryStmtPath(bs, child, args);
		if (args == null || stmtPath == null) return fieldAccess;
		final stmtRef: Expr = MacroStringTools.toFieldExpr(bs.ruleCtorPath(stmtPath, args[2]));
		final blockCtor: String = args[1];
		final needsWrap: Expr = valueBraceSymmetryProbe(args, macro _vbsVal);
		return macro {
			final _vbsVal = $fieldAccess;
			$needsWrap
				? cast anyparse.format.SingleStmtBraces.wrapInBlock(
					cast _vbsVal, $v{blockCtor}, _vbsInner -> $stmtRef(cast _vbsInner, true)
				)
				: _vbsVal;
		};
	}

	/**
	 * The `@:trailOpt` half of `valueBraceSymmetry`: a branch that the wrap above will
	 * re-block must not also emit its own trail, or the trail lands inside the new braces.
	 */
	private static function valueBraceSymmetryTrailDrop(bs: BraceSymmetryCtx, child: ShapeNode, fieldAccess: Expr, emit: Expr): Expr {
		final args: Null<Array<String>> = child.fmtReadStringArgs('valueBraceSymmetry');
		if (args == null || valueBraceSymmetryStmtPath(bs, child, args) == null) return emit;
		final needsWrap: Expr = valueBraceSymmetryProbe(args, fieldAccess);
		return macro $needsWrap ? _de() : $emit;
	}

	/**
	 * ω-try-brace-symmetry: a `try` body mirrors its `catch` clauses' braces. Composed onto
	 * the value wrap above — a field carries at most ONE of the two symmetry metas.
	 */
	private static function tryBraceSymmetryWrap(bs: BraceSymmetryCtx, child: ShapeNode, fieldAccess: Expr): Expr {
		final args: Null<Array<String>> = child.fmtReadStringArgs('tryBraceSymmetry');
		if (args == null || !bs.ctx.trivia) return fieldAccess;
		if (args.length < 2)
			Context.fatalError(
				'WriterBraceSymmetryLowering: @:fmt(tryBraceSymmetry) expects at least 2 string args (catchesField, blockCtor'
				+ ', [stmtCtor]), got ${args.length}',
				Context.currentPos()
			);
		final catchesAccess: Expr = { expr: EField(macro value, args[0]), pos: Context.currentPos() };
		final blockCtor: String = args[1];
		final liftExpr: Expr = blockElemLift(bs, child.annotations[AnnotationKeys.BASE_REF], blockCtor, args[2]);
		final deBrace: Bool = child.fmtHasFlag('tryDeBrace');
		return macro {
			var _tbs = $fieldAccess;
			_tbs = cast anyparse.format.SingleStmtBraces.trySymmetryBody(
				_tbs, $catchesAccess, opt.dropSingleStmtBraces, opt.singleStmtBraceSymmetry, opt._ssbSuppress, $v{blockCtor}, $v{deBrace},
				$liftExpr
			);
			_tbs;
		};
	}

	/**
	 * The catches side of the same mirror — entered from the catches Star rather than from
	 * the body field, so the element type has to be resolved through the Star's own ref.
	 */
	private static function tryCatchesSymmetryWrap(
		bs: BraceSymmetryCtx, starNode: ShapeNode, fieldAccess: Expr, elemRefName: String
	): Expr {
		final args: Null<Array<String>> = starNode.fmtReadStringArgs('tryCatchBraceSymmetry');
		if (args == null || !bs.ctx.trivia) return fieldAccess;
		if (args.length < 2)
			Context.fatalError(
				'WriterBraceSymmetryLowering: @:fmt(tryCatchBraceSymmetry) expects at least 2 string args (bodyField, blockCtor'
				+ ', [stmtCtor]), got ${args.length}',
				Context.currentPos()
			);
		final bodyAccess: Expr = { expr: EField(macro value, args[0]), pos: Context.currentPos() };
		final blockCtor: String = args[1];
		final liftExpr: Expr = blockElemLift(bs, seqFieldRefTarget(bs, elemRefName, args[0]), blockCtor, args[2]);
		final deBrace: Bool = starNode.fmtHasFlag('tryDeBrace');
		return macro {
			var _tcs = $fieldAccess;
			_tcs = cast anyparse.format.SingleStmtBraces.trySymmetryCatches(
				_tcs, $bodyAccess, opt.dropSingleStmtBraces, opt.singleStmtBraceSymmetry, opt._ssbSuppress, $v{blockCtor}, $v{deBrace},
				$liftExpr
			);
			_tcs;
		};
	}

	/**
	 * ω-single-stmt-braces gate 7, then-side: does the mandatory then-body sibling keep its
	 * braces? `false` for a struct with no such sibling (a for / while body).
	 */
	private static function buildThenSiblingKeepsProbe(bs: BraceSymmetryCtx, node: ShapeNode, typePath: String): Expr {
		final found: Null<{ sibling: ShapeNode, name: String, access: Expr }> = findThenSiblingAccess(node);
		if (found == null) return macro false;
		final thenAccess: Expr = found.access;
		final trailSlot: String = found.name + TriviaTypeSynth.TRAIL_PRESENT_SUFFIX;
		final thenTrailAccess: Expr = { expr: EField(macro value, trailSlot), pos: Context.currentPos() };
		final thenTrail: Expr = found.sibling.annotations.get(AnnotationKeys.LIT_TRAIL_OPTIONAL) == true && bs.isTriviaBearing(typePath)
			? macro ($thenTrailAccess == true)
			: macro false;
		// The probed sibling IS an if-then-body, so the omega-ssb-wrap arm applies
		// (a bare `if` there renders braced) - pass `isIfThenBody=true`.
		return macro anyparse.format.SingleStmtBraces.keepsBraces(
			$thenAccess, opt.dropSingleStmtBraces, opt.singleStmtBraceSymmetry, opt._ssbSuppress, true, $thenTrail, true
		);
	}

	/**
	 * ω-single-stmt-braces CHAIN symmetry, else-side: the runtime expression that decides
	 * whether an `else` branch is mid-chain and must therefore keep its braces.
	 */
	private static function buildElseChainSuppressExpr(bs: BraceSymmetryCtx, node: ShapeNode, child: ShapeNode, fieldAccess: Expr): Expr {
		if (!bs.ctx.trivia || !child.fmtHasFlag(DROP_SINGLE_STMT_BRACES)) return macro false;
		final found: Null<{ sibling: ShapeNode, name: String, access: Expr }> = findThenSiblingAccess(node);
		if (found == null) return macro opt._ssbChainSuppress;
		final thenAccess: Expr = found.access;
		return macro (opt._ssbChainSuppress
			|| anyparse.format.SingleStmtBraces.chainForcesBraces(
				$thenAccess, $fieldAccess, opt.dropSingleStmtBraces, opt.singleStmtBraceSymmetry, opt._ssbSuppress
			));
	}

	/**
	 * Thread the chain-suppress verdict into the opt handed to a nested `if` — and CLEAR it
	 * for every other ctor, so an `else` holding anything but an `if` starts a fresh chain.
	 */
	private static function wrapElseChainSuppress(
		bs: BraceSymmetryCtx, e: Expr, child: ShapeNode, refName: String, chainSuppressExpr: Expr
	): Expr {
		if (!bs.ctx.trivia || !child.fmtHasFlag(DROP_SINGLE_STMT_BRACES)) return e;
		final ifPat: Null<Expr> = bs.findCtorPattern(refName, 'IfStmt');
		if (ifPat == null) return e;
		final setExpr: Expr = macro _setSsbChainSuppress($e, $chainSuppressExpr, opt);
		final clearExpr: Expr = macro _setSsbChainSuppress($e, false, opt);
		return {
			expr: ESwitch(macro _optVal, [{ values: [ifPat], expr: setExpr, guard: null }], clearExpr),
			pos: Context.currentPos()
		};
	}

	/**
	 * The de-braced substitute for a body field carrying `@:fmt(dropSingleStmtBraces)`, plus
	 * the two side channels its gates feed (the nested-unwrap suppress frame and the hoisted
	 * trailing comment). Off-path the access is byte-identical to the raw field access.
	 */
	private static function deBraceBodyAccess(
		bs: BraceSymmetryCtx, child: ShapeNode, fieldAccess: Expr, elseFieldName: Null<String>
	): { effAccess: Expr, ssbSuppressCond: Null<Expr>, ssbTrailCommentExpr: Null<Expr> } {
		// ω-single-stmt-braces: a body field carrying `@:fmt(dropSingleStmtBraces)`
		// (trivia mode only) substitutes its runtime value with
		// `SingleStmtBraces.unwrapStmt(value.<field>, …)` BEFORE any writeCall /
		// layout / shape dispatch, so a `{ single; }` block body is seen (and laid
		// out) as the bare inner statement everywhere downstream — incl. the next
		// sibling's shape-aware `else` separator and the `semicolonNextLineElse`
		// re-render (both consume the substituted access via `prevBareRefBody`).
		// `elseFollows` (an `else` sibling is present at runtime) arms the
		// dangling-else gate inside the helper; the same condition (narrowed to a
		// then-body that renders WITHOUT braces) wraps the writeCall's opt in
		// `_setSsbSuppress` so unwraps nested deeper in the then-body
		// (e.g. `if (a) while (c) { if (b) x; } else y`) are gated too.
		// `elseFieldName` is non-null only for `HxIfStmt.thenBody` (via
		// `fitLineIfWithElse`'s optionalBodyFieldName channel); for / while bodies
		// pass `false`. Off-path (`dropSingleStmtBraces` absent or plain mode) the
		// access is byte-identical to pre-slice.
		final dropBraces: Bool = bs.ctx.trivia && child.fmtHasFlag(DROP_SINGLE_STMT_BRACES);
		final elseAccess: Null<Expr> = dropBraces && elseFieldName != null ? {
			expr: EField(macro value, elseFieldName),
			pos: Context.currentPos()
		} : null;
		final elseFollowsExpr: Expr = elseAccess == null ? macro false : macro $elseAccess != null;
		// The body's own `@:trailOpt(';')` slot (`value.<field>TrailPresent`): a redundant
		// trailing `;` (`for (…) { x; };`) would become `for (…) x;;` once de-braced — invalid
		// to the Haxe compiler — so it fails the unwrap closed (braces kept).
		// omega-ssb-trailopt-drop: always `false` — the trail slot of a brace-droppable
		// field is no longer emitted (see `emitMandatoryRefTrail`), so the `for (…) x;;`
		// shape the keep-braces gate defended against cannot occur. The gate itself stays
		// as a fail-closed guard for any FUTURE field that both drops braces and emits a trail.
		final trailSemiExpr: Expr = macro false;
		// ω-single-stmt-braces symmetry (gate 7): probe whether the `else` sibling would
		// KEEP its braces. If it does, this then-body keeps its own too - an if/else must
		// de-brace both branches or neither. The else-body's own splice unwraps with
		// `elseFollows=false, hasTrailingSemi=false`, so the probe mirrors those exactly.
		final elseSiblingKeepsExpr: Expr = elseAccess == null
			? macro false
			: macro ($elseAccess != null
				&& anyparse.format.SingleStmtBraces.keepsBraces(
					$elseAccess, opt.dropSingleStmtBraces, opt.singleStmtBraceSymmetry, opt._ssbSuppress, false, false, false
				));
		// ω-single-stmt-braces CHAIN symmetry: force this then-body to keep its
		// braces when we are mid-chain (`opt._ssbChainSuppress`, propagated from
		// the root) OR when THIS `if` is the chain root and the spine scan finds a
		// keeper. Folded into `siblingKeepsBraces` alongside the immediate-pair
		// probe. For / while / do bodies (no `else` sibling) never force.
		final thenChainSuppressExpr: Expr = elseAccess == null
			? macro false
			: macro (opt._ssbChainSuppress
				|| anyparse.format.SingleStmtBraces.chainForcesBraces(
					$fieldAccess, $elseAccess, opt.dropSingleStmtBraces, opt.singleStmtBraceSymmetry, opt._ssbSuppress
				));
		// omega-ssb-wrap: `isIfThenBody` is a MACRO-time discriminator - `elseFieldName`
		// is non-null only for `HxIfStmt.thenBody` (the fitLineIfWithElse
		// optionalBodyFieldName channel), so for / while / do bodies pass `false` and
		// stay exempt from gate 8 and the wrap direction.
		final isThenBodyExpr: Expr = elseFieldName != null ? macro true : macro false;
		final effAccess: Expr = dropBraces
			? macro {
				var _sv = $fieldAccess;
				_sv = cast anyparse.format.SingleStmtBraces.unwrapStmt(
					_sv, opt.dropSingleStmtBraces, opt.singleStmtBraceSymmetry, opt._ssbSuppress, $elseFollowsExpr, $trailSemiExpr,
					$elseSiblingKeepsExpr || $thenChainSuppressExpr, $isThenBodyExpr
				);
				_sv;
			}
			: tryBraceSymmetryWrap(
				// omega-try-brace-symmetry composes here rather than in a branch of its own: a field
				// carries at most ONE of the two symmetry metas, so each wrap is inert for the other's
				// fields and the pair is byte-identical to the pre-slice access without either.
				bs,
				child,
				valueBraceSymmetryWrap(bs, child, fieldAccess)
			);
		// The runtime gate includes `opt.dropSingleStmtBraces` so the default-off
		// path never allocates a suppress-frame opt copy (byte-inert AND
		// allocation-inert).
		// omega-ssb-span-precision: the frame is armed ONLY when the then-body renders
		// WITHOUT braces. A brace-bearing then-body ends on its own `}`, which seals the
		// whole subtree from the trailing `else` - nothing inside it can be on the
		// then-body's trailing spine, so suppressing there is pure over-keeping.
		// `keepsBraces` mirrors the then splice's own arguments; it answers `false` for a
		// branch that gate 7 would WRAP, which arms the frame needlessly but never
		// disarms it wrongly (fail closed).
		final ssbSuppressCond: Null<Expr> = elseAccess == null
			? null
			: macro ($elseAccess != null && opt.dropSingleStmtBraces
				&& !anyparse.format.SingleStmtBraces.keepsBraces(
					$fieldAccess, opt.dropSingleStmtBraces, opt.singleStmtBraceSymmetry, opt._ssbSuppress, true, $trailSemiExpr, true
				));
		// ω-single-stmt-braces trailing-comment hoist: when the de-brace fires AND the
		// single statement carries a same-line trailing comment, `hoistTrailingComment`
		// returns it (else null) so `buildBodyWriteCall` folds it after the bare
		// statement's own `;`. Same gate args as the `unwrapStmt` splice above.
		final ssbTrailCommentExpr: Null<Expr> = dropBraces
			? macro anyparse.format.SingleStmtBraces.hoistTrailingComment(
				$fieldAccess, opt.dropSingleStmtBraces, opt._ssbSuppress, $elseFollowsExpr, $trailSemiExpr,
				$elseSiblingKeepsExpr || $thenChainSuppressExpr, $isThenBodyExpr
			)
			: null;
		return { effAccess: effAccess, ssbSuppressCond: ssbSuppressCond, ssbTrailCommentExpr: ssbTrailCommentExpr };
	}

}

/**
 * The build state the brace-symmetry family reads, bundled once per
 * `WriterLowering` instance.
 *
 * Two data fields — `shape` for the rule lookups that resolve a block's element
 * type, `ctx` for the trivia gate every member opens with — and three shape-name
 * helpers that stayed in `WriterLowering` because most of their callers did.
 * The bundle IS the dependency surface: a member here that needs something else
 * has to widen this literal, which is one visible edit in that constructor.
 */
typedef BraceSymmetryCtx = {
	final shape: ShapeBuilder.ShapeResult;
	final ctx: LoweringCtx;
	final findCtorPattern: (bodyTypePath:String, ctorName:String) -> Null<Expr>;
	final isTriviaBearing: (refName:String) -> Bool;
	final ruleCtorPath: (typePath:String, ctor:String) -> Array<String>;
}
#end
