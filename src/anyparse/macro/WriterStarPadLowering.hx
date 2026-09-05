package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import anyparse.macro.WriterLowering.PadFlags;
import anyparse.macro.WriterLowering.PlainStarCtx;
import haxe.macro.Context;
import haxe.macro.Expr;

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
 * ⚠️ Star emission FORKS across FOUR sites — `Lowering.emitStarFieldSteps`
 * and its `lowerEnumBranch` Case 4 branch on the parse side,
 * `emitWriterStarField` and `lowerEnumStar` on the writer side. All four
 * stayed where they were; nothing here is reachable from `lowerEnumStar`,
 * measured on the module's own call graph, so no fork half was separated
 * from its twin by this module's existence. A change to Star+sep emission
 * still has to visit all four sites, and they still name each other.
 */
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
			if (_arr.length == 0)
				_de()
			else {
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
		final sepBeforeOptActive: Bool = f.sepBeforeOptActive;
		final softFill: Bool = f.softFill;
		if (padLeading || padTrailing) {
			if (lineLengthAwareSeps) {
				final leadingPush: Expr = padLeading ? macro _docs.push(_dile(opt.lineWidth, _dhl(), _dt(' '))) : macro {};
				final trailingPush: Expr = padTrailing ? macro _docs.push(_dile(opt.lineWidth, _dhl(), _dt(' '))) : macro {};
				parts.push(macro {
					final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
					final _arr = $fieldAccess;
					if (_arr.length == 0)
						_de()
					else {
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
				emitTryparsePadSepEmit(c, padLeading, padTrailing, sepBeforeOptActive, softFill, parts);
			}
		} else {
			parts.push(macro {
				final _arr = $fieldAccess;
				final _docs: Array<anyparse.core.Doc> = [];
				var _si: Int = 0;
				while (_si < _arr.length) {
					_docs.push($elemCall);
					if (_si < _arr.length - 1) _docs.push(_dt(' '));
					_si++;
				}
				_dc(_docs);
			});
		}
	}

	/**
	 * Plain-mode try-parse pad path (the `else` branch of
	 * `emitTryparseOrPadStar`). Handles `@:fmt(padLeading)` / `padTrailing` /
	 * `softFill` / `lineLengthAwareSeps` / `sepBeforeOpt` inter-element + edge
	 * spacing. Extracted to keep the helper under the complexity gate.
	 * Plain-mode try-parse pad emission (the `if (padLeading || padTrailing)`
	 * block of `emitTryparsePadStar`). Emits the lineLengthAware / sepBeforeOpt /
	 * softFill / plain inter-element + edge layouts per the resolved `PadFlags`.
	 * Extracted to keep the helper under the complexity gate.
	 * Plain-mode try-parse pad emission, non-lineLengthAware path (the inner
	 * `else` of `emitTryparsePadEmit`). Resolves the leading / trailing pad pushes
	 * (`sepBeforeOpt` aware) and emits the `softFill` or plain inter-element
	 * layout. Extracted to keep the helper under the complexity gate.
	 */
	private static function emitTryparsePadSepEmit(
		c: PlainStarCtx, padLeading: Bool, padTrailing: Bool, sepBeforeOptActive: Bool, softFill: Bool, parts: Array<Expr>
	): Void {
		final starNode: ShapeNode = c.starNode;
		final fieldAccess: Expr = c.fieldAccess;
		final elemCall: Expr = c.elemCall;
		final leadingPush: Expr = if (sepBeforeOptActive) {
			final fieldName: String = starNode.annotations[AnnotationKeys.BASE_FIELD_NAME];
			final sepBeforeAccess: Expr = {
				expr: EField(macro value, fieldName + TriviaTypeSynth.SEP_BEFORE_SUFFIX),
				pos: Context.currentPos()
			};
			final sepText: Null<String> = starNode.annotations[AnnotationKeys.LIT_SEP_TEXT];
			final sepLeadText: String = '${sepText ?? ','} ';
			macro _docs.push($sepBeforeAccess ? _dt($v{sepLeadText}) : _dt(' '));
		} else if (padLeading)
			macro _docs.push(_dt(' '));
		else
			macro {};
		final trailingPush: Expr = padTrailing ? macro _docs.push(_dt(' ')) : macro {};
		// ω-condcomp-body-inter-sep: the default inter-element
		// separator for this branch is `_dt(' ')` — designed for
		// sep-less Stars where elements pack with one space (e.g.
		// modifier runs). Sep-bearing Stars (e.g.
		// `HxConditionalParam.body` / `HxConditionalObjectField.body`
		// with `@:sep(',')`) emit their actual sep + space so multi-
		// element bodies round-trip the source comma. Falls back to
		// `' '` when sepText is absent.
		final sepTextForInter: Null<String> = starNode.annotations[AnnotationKeys.LIT_SEP_TEXT];
		final interSepText: String = sepTextForInter != null ? '$sepTextForInter ' : ' ';
		if (softFill) {
			// ω-condcomp-body-softfill: route inter-element sep
			// through `Fill(items, Concat([Text(sep), Line(' ')]))`.
			// Flat mode renders the sep identically to the
			// pre-softFill `Text(interSepText)` path (`, ` for
			// sep-bearing Stars, ` ` for sep-less). Break mode
			// emits `sep` + newline+indent before each overflow
			// item — Fill picks per-item flat/break against the
			// current Renderer budget.
			final interSepLit: String = sepTextForInter ?? '';
			parts.push(macro {
				final _arr = $fieldAccess;
				if (_arr.length == 0)
					_de()
				else {
					final _docs: Array<anyparse.core.Doc> = [];
					$leadingPush;
					final _items: Array<anyparse.core.Doc> = [];
					var _si: Int = 0;
					while (_si < _arr.length) {
						_items.push($elemCall);
						_si++;
					}
					_docs.push(_dfill(_items, _dc([_dt($v{interSepLit}), _dl()])));
					$trailingPush;
					_dc(_docs);
				}
			});
		} else
			parts.push(macro {
				final _arr = $fieldAccess;
				if (_arr.length == 0)
					_de()
				else {
					final _docs: Array<anyparse.core.Doc> = [];
					$leadingPush;
					var _si: Int = 0;
					while (_si < _arr.length) {
						_docs.push($elemCall);
						if (_si < _arr.length - 1) _docs.push(_dt($v{interSepText}));
						_si++;
					}
					$trailingPush;
					_dc(_docs);
				}
			});
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
