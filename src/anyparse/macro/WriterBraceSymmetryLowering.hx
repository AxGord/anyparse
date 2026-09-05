package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import haxe.macro.Context;
import haxe.macro.Expr;

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
 * All four are pure functions of their arguments. The
 * `@:access(anyparse.macro.WriterLowering)` is for one constant —
 * `VALUE_BRACE_SYMMETRY_MIN_ARGS`, the arity that splits the
 * `valueBraceSymmetry` required args from the skip-ctor tail — which stayed
 * there because a second reader of it did.
 */
@:access(anyparse.macro.WriterLowering)
final class WriterBraceSymmetryLowering {

	/**
	 * Locate the mandatory bodyPolicy sibling carrying `dropSingleStmtBraces`
	 * (the then-body) and build its `value.<then>` field-access expr. Shared by
	 * both if/else-body brace-symmetry probes; `null` when there is no such
	 * sibling (a for / while / do body has none).
	 */
	private static function findThenSiblingAccess(node: ShapeNode): Null<{ sibling: ShapeNode, name: String, access: Expr }> {
		final thenSibling: Null<ShapeNode> = node.children.find(c ->
			c.annotations.get(AnnotationKeys.BASE_OPTIONAL) != true && c.fmtHasFlag('dropSingleStmtBraces')
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
			expr: EArrayDecl([for (c in args.slice(WriterLowering.VALUE_BRACE_SYMMETRY_MIN_ARGS)) macro $v{c}]),
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

}
#end
