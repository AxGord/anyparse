package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import anyparse.macro.WriterLowering.PadFlags;
import anyparse.macro.WriterLowering.PlainStarCtx;
import haxe.macro.Context;
import haxe.macro.Expr;

using anyparse.macro.MetaInspect;

/**
 * Pass 3W — what one repetition-loop iteration body emits for a PLAIN
 * (non-`@:trivia`) Star, once its pad / separator / gate flags are known.
 *
 * Every member here is a leaf of the struct-side Star emit: it receives the
 * already-decided flags and returns, or pushes, the `while` loop that walks
 * the captured array. `emitEofPlainStar` is the last-field, no-`@:trail`
 * mode (double hardline between elements); `emitTryparsePadEmit` picks
 * between the line-length-aware pad and the plain one, and
 * `emitTryparsePadSepEmit` builds the plain arm's leading / inter-element /
 * trailing separators including the `Fill` form. `orStarNonEmpty` and
 * `gateMultiVarMoreParts` are the two gates a Star's emitted `parts` can be
 * wrapped in.
 *
 * ⚠️ Star emission FORKS across FOUR sites —
 * `StarFieldLowering.emitStarFieldSteps` and the `lowerStar*Branch` leaves
 * beside it on the parse side, `emitWriterStarField` and `lowerEnumStar`
 * on the writer side. All four
 * stayed where they were; nothing here is reachable from `lowerEnumStar`,
 * measured on the module's own call graph, so no fork half was separated
 * from its twin by this module's existence. A change to Star+sep emission
 * still has to visit all four sites, and they still name each other.
 */
@:access(anyparse.macro.WriterLoweringSupport)
final class WriterStarPadLowering {

	/**
	 * Plain-mode EOF Star dispatch (the final `else` branch of
	 * `emitWriterStarField`). Emits the lead then the double-hardline-separated
	 * element list. Extracted to keep the orchestrator under the complexity gate.
	 */
	private static function emitEofPlainStar(c: PlainStarCtx, parts: Array<Expr>): Void {
		final fieldAccess: Expr = c.fieldAccess;
		final elemCall: Expr = c.elemCall;
		final openText: Null<String> = c.openText;
		// EOF mode. Emit lead if present.
		if (openText != null) parts.push(macro _dt($v{openText}));
		parts.push(macro {
			final _arr = $fieldAccess;
			if (_arr.length == 0) {
				_de();
			} else {
				final _docs: Array<anyparse.core.Doc> = [];
				var _si: Int = 0;
				while (_si < _arr.length) {
					if (_si > 0) {
						_docs.push(_dhl());
						_docs.push(_dhl());
					}
					_docs.push($elemCall);
					_si++;
				}
				_dc(_docs);
			}
		});
	}

	private static function emitTryparsePadEmit(c: PlainStarCtx, f: PadFlags, parts: Array<Expr>): Void {
		final fieldAccess: Expr = c.fieldAccess;
		final elemCall: Expr = c.elemCall;
		final padLeading: Bool = f.padLeading;
		final padTrailing: Bool = f.padTrailing;
		final lineLengthAwareSeps: Bool = f.lineLengthAwareSeps;
		if (padLeading || padTrailing) {
			if (lineLengthAwareSeps) {
				final leadingPush: Expr = padLeading ? macro _docs.push(_dile(opt.lineWidth, _dhl(), _dt(' '))) : macro {};
				final trailingPush: Expr = padTrailing ? macro _docs.push(_dile(opt.lineWidth, _dhl(), _dt(' '))) : macro {};
				parts.push(macro {
					final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
					final _arr = $fieldAccess;
					if (_arr.length == 0) {
						_de();
					} else {
						final _docs: Array<anyparse.core.Doc> = [];
						$leadingPush;
						var _si: Int = 0;
						while (_si < _arr.length) {
							_docs.push($elemCall);
							if (_si < _arr.length - 1) _docs.push(_dile(opt.lineWidth, _dhl(), _dt(' ')));
							_si++;
						}
						$trailingPush;
						_dn(_cols, _dc(_docs));
					}
				});
			} else {
				emitTryparsePadSepEmit(c, f, parts);
			}
		} else {
			emitTryparseRunEmit(c, f, parts);
		}
	}

	/**
	 * The unpadded try-parse Star: elements joined by a space, or by the separators and the break after the last
	 * a metadata site's line-end knob (`f.metaPolicy`) asks for.
	 */
	private static function emitTryparseRunEmit(c: PlainStarCtx, f: PadFlags, parts: Array<Expr>): Void {
		final fieldAccess: Expr = c.fieldAccess;
		final elemCall: Expr = c.elemCall;
		// `@:fmt(glueToPrevious)`: no space before a glued element (the case body's `{ … };`).
		final glueTest: Null<Expr> = WriterLoweringSupport.glueElemTestExpr(
			MetaInspect.fmtReadStringArgs(c.starNode, 'glueToPrevious'), macro _arr[_si + 1]
		);
		final nextGlued: Expr = glueTest ?? macro false;
		final metaPolicy: Null<Expr> = f.metaPolicy;
		final policyDecl: Expr = metaPolicy == null
			? macro {}
			: WriterMetaLineEndLowering.fitDecls(
				WriterMetaLineEndLowering.simplePred(f.metaNode, f.rootTypePath, f.trivia), metaPolicy, macro _arr, e -> e, macro false
			);
		final fitSep: Expr = WriterMetaLineEndLowering.fitSepExpr();
		final elemSep: Expr = metaPolicy == null
			? macro _dt(' ')
			: macro (_metaPolicy == anyparse.format.MetadataLineEndPolicy.After ? _dhl() : $fitSep);
		final rowWrap: Expr = metaPolicy == null ? macro {} : WriterMetaLineEndLowering.fitRowWrapExpr(macro 0);
		final fitAfterLast: Expr = WriterMetaLineEndLowering.fitAfterLastExpr();
		final afterLast: Expr = metaPolicy == null ? macro {} : macro if (
			_metaPolicy != anyparse.format.MetadataLineEndPolicy.None && _arr.length > 0
		)
			_docs.push($fitAfterLast);
		parts.push(macro {
			final _arr = $fieldAccess;
			final _docs: Array<anyparse.core.Doc> = [];
			$policyDecl;
			var _si: Int = 0;
			while (_si < _arr.length) {
				_docs.push($elemCall);
				if (_si < _arr.length - 1 && !$nextGlued) _docs.push($elemSep);
				_si++;
			}
			$rowWrap;
			$afterLast;
			_dc(_docs);
		});
	}

	/**
	 * The padded try-parse Star off the line-length-aware path: the leading and trailing pads (`sepBeforeOpt` aware)
	 * and the elements joined by the separator plus a space, or packed by a `softFill` Fill. A `#if` region body
	 * carrying `@:fmt(elementPerLine)` puts each element on a line of its own and, once it holds two or more, opens and
	 * closes on lines of its own through `regionPadSlotExpr`, the pad the trivia writer takes too; under a block-ended
	 * separator an element that ends its own statement takes no separator after it.
	 */
	private static function emitTryparsePadSepEmit(c: PlainStarCtx, f: PadFlags, parts: Array<Expr>): Void {
		final starNode: ShapeNode = c.starNode;
		final fieldAccess: Expr = c.fieldAccess;
		final elemCall: Expr = c.elemCall;
		final elementPerLine: Bool = starNode.fmtHasFlag('elementPerLine');
		final siblingPad: Null<Array<String>> = starNode.fmtReadStringArgs('siblingPad');
		final padGlued: Expr = macro _dt(' ');
		final padDoc: Expr = WriterLoweringSupport.regionPadSlotExpr(siblingPad, macro _padHardline, macro _dhl(), padGlued);
		final leadingPush: Expr = if (f.sepBeforeOptActive) {
			final fieldName: String = starNode.annotations[AnnotationKeys.BASE_FIELD_NAME];
			final sepBeforeAccess: Expr = {
				expr: EField(macro value, fieldName + TriviaTypeSynth.SEP_BEFORE_SUFFIX),
				pos: Context.currentPos()
			};
			final sepText: Null<String> = starNode.annotations[AnnotationKeys.LIT_SEP_TEXT];
			final sepLeadText: String = '${sepText ?? ','} ';
			macro _docs.push($sepBeforeAccess ? _dt($v{sepLeadText}) : _dt(' '));
		} else if (f.padLeading)
			macro _docs.push($padDoc);
		else
			macro {};
		final trailingDoc: Expr = f.padTrailing ? padDoc : macro _de();
		// A sep-bearing Star (`HxConditionalParam.body` with `@:sep(',')`) writes its separator between elements; a
		// sep-less one (a modifier run) packs them with one space.
		final sepTextForInter: Null<String> = starNode.annotations[AnnotationKeys.LIT_SEP_TEXT];
		if (f.softFill) {
			parts.push(softFillEmit(c, leadingPush, trailingDoc, sepTextForInter ?? ''));
			return;
		}
		final blockEndedPrior: Null<Expr> = f.blockEndedPrior;
		final sepDoc: Expr = macro _docs.push(_dt($v{sepTextForInter}));
		final guardedSep: Expr = blockEndedPrior == null
			? sepDoc
			: macro {
				if (!anyparse.core.DocMeasure.endsWithSemi(_elemDoc) && !$blockEndedPrior) $sepDoc;
			};
		final sepPush: Expr = sepTextForInter == null ? macro {} : guardedSep;
		final joiner: Expr = elementPerLine ? macro _dhl() : macro _dt(' ');
		// Only a body laid out one element per line nests; a glued body (call arguments, object fields) stays as written.
		final condIncrease: Expr = elementPerLine
			? WriterLoweringSupport.condIncreaseGateExpr(starNode.fmtHasFlag('conditionalBodyIndent'))
			: macro false;
		parts.push(macro {
			final _arr = $fieldAccess;
			if (_arr.length == 0) {
				_de();
			} else {
				final _padHardline: Bool = $v{elementPerLine} && _arr.length > 1;
				final _docs: Array<anyparse.core.Doc> = [];
				$leadingPush;
				var _si: Int = 0;
				while (_si < _arr.length) {
					final _elemDoc: anyparse.core.Doc = $elemCall;
					_docs.push(_elemDoc);
					if (_si < _arr.length - 1) {
						$sepPush;
						_docs.push($joiner);
					}
					_si++;
				}
				if ($condIncrease) {
					// The body nests past its markers; the pad before the closing marker stays at their indent.
					final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
					_dc([_dn(_cols, _dc(_docs)), $trailingDoc]);
				} else {
					_docs.push($trailingDoc);
					_dc(_docs);
				}
			}
		});
	}

	/**
	 * A `softFill` Star: `Fill(items, Concat([Text(sep), Line(' ')]))`, which reads as the plain join flat and, broken,
	 * puts the separator and a newline before each item that overflows the budget.
	 */
	private static function softFillEmit(c: PlainStarCtx, leadingPush: Expr, trailingDoc: Expr, interSepLit: String): Expr {
		final fieldAccess: Expr = c.fieldAccess;
		final elemCall: Expr = c.elemCall;
		return macro {
			final _arr = $fieldAccess;
			if (_arr.length == 0) {
				_de();
			} else {
				final _padHardline: Bool = false;
				final _docs: Array<anyparse.core.Doc> = [];
				$leadingPush;
				final _items: Array<anyparse.core.Doc> = [];
				var _si: Int = 0;
				while (_si < _arr.length) {
					_items.push($elemCall);
					_si++;
				}
				_docs.push(_dfill(_items, _dc([_dt($v{interSepLit}), _dl()])));
				_docs.push($trailingDoc);
				_dc(_docs);
			}
		};
	}

	/**
	 * ω-member-meta: OR this bare-tryparse Star's `_arr.length > 0` runtime
	 * check into the cumulative `prevAnyStarNonEmpty` signal (or seed it when
	 * no prior Star contributed).
	 */
	private static function orStarNonEmpty(prev: Null<Expr>, fieldAccess: Expr): Expr {
		final thisNonEmpty: Expr = macro $fieldAccess.length > 0;
		if (prev == null) return thisNonEmpty;
		final prevExpr: Expr = prev;
		return macro $prevExpr || $thisNonEmpty;
	}

	/**
	 * ω-multivar-wrap: gate every `parts` entry pushed for the `<moreField>`
	 * Star (indices `[start, parts.length)`) on the runtime `_suppressMore`
	 * entry flag, so a head-only recursive self-call drops the Star to
	 * `_de()`. Rewrites the slice in place.
	 */
	private static function gateMultiVarMoreParts(parts: Array<Expr>, start: Int): Void {
		for (i in start ... parts.length) {
			final entry: Expr = parts[i];
			parts[i] = macro _suppressMoreEntry ? _de() : $entry;
		}
	}

}
#end
