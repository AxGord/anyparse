package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import anyparse.macro.WriterLoweringSupport.*;
import haxe.macro.Context;
import haxe.macro.Expr;

using anyparse.macro.MetaInspect;

/**
 * Pass 3W — where a `@:fmt(condWrap)` span begins and ends, and what the
 * closed span emits.
 *
 * One question, asked at three moments of `lowerStruct`'s walk over a
 * struct's fields. `detectCondWrapSpan` asks it BEFORE the walk — is there
 * a start field carrying `@:fmt(condWrap('<knob>'))` and a later sibling
 * carrying the `@:fmt(condWrapEnd)` sentinel, and which literals do their
 * `@:lead` / `@:trail` contribute. `validateCondWrap` asks it at the start
 * field — is this shape one the emitter can honour at all (a bare mandatory
 * `Ref`, one knob arg, a lead, and a trail unless a sentinel supplies one).
 * `spliceCondWrapEnd` asks it at the end field — the `parts` accumulated
 * since the start index ARE the span, so they come back out and go in again
 * as one `WrapList.emitCondition` call under the knob's cascade.
 *
 * All three are pure functions of their arguments: they read the shape node
 * and the accumulated `parts`, never the build state. That is why they are
 * statics here and why the call sites in `WriterLowering` did not move —
 * a wildcard import plus the class-level `@:access` reaches them unqualified.
 */
@:access(anyparse.macro.WriterLoweringSupport)
final class WriterCondWrapLowering {

	/**
	 * ω-condwrap-forstmt: scan a struct's children for a span-mode condWrap
	 * pair — `@:fmt(condWrap('<knob>'))` on a starting field plus a later
	 * sibling carrying the `@:fmt(condWrapEnd)` sentinel flag. Returns the
	 * matched span (start/end indices, the `(` / `)` literals from the start
	 * field's `@:lead` and the end field's `@:trail`, and the knob) or `null`
	 * when no end-field sentinel pairs with a start condWrap (single-Ref
	 * consumers run the existing path). Extracted verbatim from `lowerStruct`.
	 */
	private static function detectCondWrapSpan(node: ShapeNode): Null<{
		startIdx: Int,
		endIdx: Int,
		leadText: String,
		trailText: String,
		knob: String
	}> {
		var startIdx: Int = -1;
		var startKnob: Null<String> = null;
		var startLead: Null<String> = null;
		for (i in 0...node.children.length) {
			final c: ShapeNode = node.children[i];
			final cw: Null<Array<String>> = c.fmtReadStringArgs('condWrap');
			if (cw != null && startIdx == -1) {
				startIdx = i;
				startKnob = cw[0];
				startLead = c.readMetaString(':lead');
			} else if (c.fmtHasFlag('condWrapEnd') && startIdx != -1) {
				final endTrail: Null<String> = c.readMetaString(':trail');
				if (startLead == null || endTrail == null)
					Context.fatalError(
						'WriterLowering: @:fmt(condWrap)/@:fmt(condWrapEnd) '
						+ 'span requires @:lead on the start field and @:trail on the end field',
						Context.currentPos()
					);
				if (startKnob == null) Context.fatalError('WriterLowering: @:fmt(condWrap) requires a knob arg', Context.currentPos());
				if (c.kind != Ref || c.annotations[AnnotationKeys.BASE_OPTIONAL] == true)
					Context.fatalError(
						'WriterLowering: @:fmt(condWrapEnd) is supported only on bare mandatory Ref fields', Context.currentPos()
					);
				return {
					startIdx: startIdx,
					endIdx: i,
					leadText: startLead,
					trailText: endTrail,
					knob: startKnob
				};
			}
		}
		return null;
	}

	/**
	 * ω-condition-wrap-wiring: validate a field carrying `@:fmt(condWrap('<knob>'))`.
	 * Enforces a single string arg, a mandatory `@:lead`, a `@:trail` in single-Ref
	 * mode (or a sibling `@:fmt(condWrapEnd)` for span mode, signalled by `hasSpan`),
	 * a bare mandatory Ref kind, and no same-field `@:kw` in single-Ref mode. Throws
	 * via `Context.fatalError` on any violation.
	 */
	private static function validateCondWrap(
		condWrapArgs: Array<String>, leadText: Null<String>, trailText: Null<String>, kwLead: Null<String>, hasSpan: Bool,
		isOptional: Bool, isStar: Bool, childKind: ShapeKind
	): Void {
		if (condWrapArgs.length != 1)
			Context.fatalError(
				'WriterLowering: @:fmt(condWrap(\'<knob>\')) requires 1 string arg, got ${condWrapArgs.length}', Context.currentPos()
			);
		if (leadText == null) Context.fatalError('WriterLowering: @:fmt(condWrap) requires @:lead on the field', Context.currentPos());
		// Span mode: trail literal lives on the matched `@:fmt(condWrapEnd)`
		// sibling; single-Ref mode: trail required on the same field.
		if (!hasSpan && trailText == null)
			Context.fatalError(
				'WriterLowering: @:fmt(condWrap) requires @:trail on the field (or a sibling @:fmt(condWrapEnd) for span mode)',
				Context.currentPos()
			);
		if (isOptional || isStar || childKind != Ref)
			Context.fatalError('WriterLowering: @:fmt(condWrap) is supported only on bare mandatory Ref fields', Context.currentPos());
		if (!hasSpan && kwLead != null)
			Context.fatalError(
				'WriterLowering: @:fmt(condWrap) (single-Ref mode) does not support @:kw on the same field', Context.currentPos()
			);
	}

	/**
	 * ω-condwrap-forstmt: at the end of a span-mode condWrap iteration, splice
	 * the accumulated cond-span Doc parts (from `spanStartPartsIdx` to the end of
	 * `parts`) out and replace them with a single `WrapList.emitCondition` call —
	 * the `(` / `)` literals and knob come from `spanInfo`, the inner condDoc is a
	 * runtime `_dc([...])` composite. Rewrites `parts` in place.
	 */
	private static function spliceCondWrapEnd(
		parts: Array<Expr>, spanStartPartsIdx: Int, knob: String, leadStr: String, trailStr: String
	): Void {
		final spanLen: Int = parts.length - spanStartPartsIdx;
		final spanBuf: Array<Expr> = parts.slice(spanStartPartsIdx, parts.length);
		parts.splice(spanStartPartsIdx, spanLen);
		final innerDoc: Expr = spanBuf.length == 1 ? spanBuf[0] : dcCall(spanBuf);
		final condKnobAccess: Expr = optFieldAccess(knob);
		parts.push(macro {
			final _condRules: anyparse.format.wrap.WrapRules = $condKnobAccess;
			final _condMode: anyparse.format.wrap.WrapMode = _condRules.defaultMode;
			final _chainOvr: Null<anyparse.format.wrap.WrapMode> = _condMode == anyparse.format.wrap.WrapMode.NoWrap ? null : _condMode;
			final opt = _setChainModeOverride(opt, _chainOvr);
			anyparse.format.wrap.WrapList.emitCondition($v{leadStr}, $v{trailStr}, $innerDoc, opt, $condKnobAccess);
		});
	}

}
#end
