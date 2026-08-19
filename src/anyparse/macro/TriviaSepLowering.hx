package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.MacroStringTools;

/**
 * Pass 3W helpers — the separated-list (`@:trivia` + `@:sep`) Star emit
 * family.
 *
 * Builds the generated writer body for a close-peek trivia Star that
 * carries a separator (`HxObjectLit.fields`, `HxExpr.ArrayExpr`,
 * `HxType.Anon` typedef-RHS bodies, call / parameter lists): the
 * flat-vs-multi-line dispatch driven by source-fidelity signals on the
 * `Trivial<T>` wrapper, the force-multi lead/line probes, the typedef
 * blank-line inserts, the keep-curly open/close placement, the
 * trailing-comma emit, the matrix (fill) layout probe, the no-trivia fast
 * branch, and the per-element predicate scan.
 *
 * Split out of `WriterLowering` for size — the two are NOT independent. The
 * macro-time surface is small: one inbound entry (`triviaSepStarExpr`,
 * called from `WriterLowering.emitTriviaCloseStar` and
 * `WriterLowering.triviaSepStarBuild`) and a short outbound list back into
 * the shared lowering utilities (`optFieldAccess`, `keepsTrailingCommaExpr`,
 * `blankBefore2ExtrasExpr`, `triviaBalcEmitExpr`,
 * `triviaUniformCollapseInitExpr` — the last three are shared with the
 * sibling block-Star family, which is why they stayed behind). Both
 * directions run through `@:access` and every member here stays private.
 *
 * Parameters typed by a `WriterLowering` sub-module typedef stay qualified:
 * the extraction moved the functions, not the typedefs, so the whole
 * sub-module typedef block (including the nine `SepStar*` bundles) still
 * lives in `WriterLowering`'s module and this file imports nothing from it.
 * The bundles are now read only from here.
 *
 * The GENERATED-code surface is the real contract, and no type carries it:
 * every helper splices identifiers declared elsewhere in the Star body —
 * `_arr` / `_t` / `_si` / `_inner` / `opt` from the Star scaffold, `_elem`
 * from this module's own force-multi branch, `_currHasDocComment` from
 * `triviaSepTypedefBlanksExprs`, `_uniformCollapse` from the
 * `WriterLowering.triviaUniformCollapseInitExpr` declaration
 * `triviaSepDispatchExpr` splices, and the `_dt()` / `_dc()` / `_dn()` /
 * `_de()` / `_dhl()` / `_dwb()` Doc wrappers emitted by `WriterCodegen` on
 * the generated class. The two cross-helper locals are gated on the SAME
 * `@:fmt` flags as the computes that read them
 * (`beforeDocCommentEmptyLines` for `_currHasDocComment`,
 * `uniformStmtBlanks` for `_uniformCollapse`): move a gate on one side only
 * and the generated writer either reads an undeclared local or declares a
 * dead one, with nothing in either module's types to catch it — and the
 * `_uniformCollapse` half crosses the module boundary.
 */
final class TriviaSepLowering {

	/**
	 * ω-trivia-sep: build the Doc expression for a close-peek `@:trivia`
	 * Star field with `@:sep` (e.g. `HxObjectLit.fields` and
	 * `HxExpr.ArrayExpr`). Mirrors `triviaBlockStarExpr` but adds the
	 * separator between elements AND drives multi-line vs flat layout
	 * from source-fidelity signals on the `Trivial<T>` wrapper.
	 *
	 * Layout decision is computed at runtime over the captured array:
	 * if ANY element carries a `newlineBefore`, blank line, leading
	 * comment, or trailing comment, OR the orphan trail slots are
	 * non-empty, the whole literal renders multi-line. Otherwise it
	 * collapses to flat `{a, b, c}` (or `[a, b, c]`) on a single line.
	 *
	 * The runtime check preserves source intent without reaching for
	 * a width-driven Group: the existing 8 corpus fixtures all break
	 * because the user wrote them multi-line, not because they
	 * exceeded line width. Width-driven wrap stays a future slice.
	 */
	private static function triviaSepStarExpr(
		fieldAccess: Expr, trailBBAccess: Null<Expr>, trailLCAccess: Null<Expr>, trailCloseAccess: Null<Expr>, trailOpenAccess: Null<Expr>,
		elemFn: String, openText: String, closeText: String, sepText: String, ?wrapRulesField: String, ?leftCurlyKnob: String,
		?rightCurlyKnob: String, ?trailPresentAccess: Expr, ?trailingCommaField: String, ?openInsideExpr: Expr, ?closeInsideExpr: Expr,
		beforeDocCommentEmptyLines: Bool = false, forceMultiInTypedef: Bool = false, bodyAwareCompactIndent: Bool = false,
		groupRestProbe: Bool = false, ignoreSourceNewlinesForWrap: Bool = false, reflowSourceMultiline: Bool = false,
		matrixWrap: Bool = false,
		// ω-keep-fnsig-newline: accessor for the close-newline slot
		// (`value.<field>TrailingNewlineBefore`). Threaded only by callers that
		// pass it; null for every other call site → the keep close placement
		// degrades to the legacy own-line close (byte-inert).
		?trailNLAccess: Expr,
		// ω-typedef-between-fields: opt-in for typedef-RHS anon-body blank
		// inserts (currently `HxType.Anon` via `@:fmt(typedefBodyBlanks)`).
		// When true, the force-multi branch reads `opt.typedefBeginType` /
		// `opt.typedefBetweenFields` gated on `opt._inTypedefBody` to push
		// blank `_dhl()` after `{` and between adjacent fields. Default
		// false → every other sep-Star caller is byte-identical.
		typedefBodyBlanks: Bool = false,
		// ω-value-yielded-if-tail-barrier (array-element expr-position): when
		// the sep-Star ctor carries `@:fmt(propagateExprPosition)` (HxExpr.
		// ArrayExpr), wrap each element's opt arg in `_setExprPosition` so an
		// array element that is a value-if (`[if (c) a else b, …]`) reads the
		// expression-position `expressionIfBody` policy and stays glued.
		// Default false → every other sep-Star caller is byte-identical.
		propagateExprPosition: Bool = false,
		// ω-expressionif-collapse (mechanism B): when the sep-Star ctor
		// carries `@:fmt(reflowInExprPosition)` (HxObjectLit.fields), the
		// Ignore-mode runtime check (`ignoreCheckExpr`) additionally fires
		// when `opt._inValueIfBranch` is set, so a source-multiline object
		// literal that is the direct value of a value-if branch drops its
		// element `newlineBefore` signals and the wrap cascade collapses it
		// to single-line. Default false → every other sep-Star caller is
		// byte-identical.
		reflowInExprPosition: Bool = false,
		// ω-multiline-trailing-comma-remove: when the sep-Star ctor carries
		// `@:fmt(trailingCommaRemovable)` (array literal / object literal /
		// `new` argument list), the runtime `opt.trailingComma == Remove`
		// policy drops the BREAK-mode trailing separator — source-present or
		// knob-added. Default false → the policy cannot reach a construct
		// whose trailing separator is mandatory (`{ > Base, }`), and every
		// other sep-Star caller stays byte-identical.
		trailingCommaRemovable: Bool = false,
		// ω-uniform-element-blanks: when the sep-Star ctor carries
		// `@:fmt(uniformStmtBlanks)` (`HxExpr.ArrayExpr`), the
		// `emptyLines.uniformStatementBlanks` policy also governs the gaps
		// between adjacent list ELEMENTS — a fully blank interior gap set
		// collapses, a selective mix or a leading comment keeps the literal
		// byte-exact. Default false → every other sep-Star caller is
		// byte-identical.
		uniformStmtBlanks: Bool = false,
		// ω-complex-item-count: when the sep-Star ctor carries
		// `@:fmt(complexItems)` (`HxExpr.ArrayExpr`), classify every element at
		// the AST layer — call / `new`, call-bearing container literal, or
		// neither — and thread the per-element codes into `WrapList.emit` as
		// `complexItemKinds`. Feeds the `complexItemCount >= n` cascade
		// condition and the fill-mode chunk policy. Default false → no
		// classification runs and every other sep-Star caller is
		// byte-identical.
		complexItems: Bool = false
	): Expr {
		// noqa: complexity
		// ω-trivia-sep-anontype-braces (Phase B1): when the call site
		// reads `@:fmt(anonTypeBracesOpen)` / `objectLiteralBracesOpen`
		// via `delimInsidePolicySpace` and threads the resulting Doc
		// expression here, the wrap-rules branch wires it into
		// `WrapList.emit` (parity with the non-trivia path's
		// `delimInsidePolicySpace` plumbing). Null fall-through keeps
		// `_de()` — backward-compatible for callers that don't have the
		// knobs. The ω-bracket-config `@:fmt(bracketKindPad)` runtime
		// dispatch (`HxExpr.ArrayExpr`) arrives pre-built through the
		// same two parameters — see `triviaSepStarBuild`.
		final openInsideDoc: Expr = openInsideExpr ?? macro _de();
		final closeInsideDoc: Expr = closeInsideExpr ?? macro _de();
		// ω-bropen-keep-sep / ω-typedef-between-fields / ω-trivia-sep-doc-comment-cascade:
		// the typedef-blank + doc-comment-cascade Expr builders that the force-multi loop
		// and `sepCtx` consume. Extracted to `triviaSepTypedefBlanksExprs` so the
		// orchestrator stays under the complexity gate; behaviour byte-identical.
		final blanks: WriterLowering.SepStarBlanks = triviaSepTypedefBlanksExprs(
			beforeDocCommentEmptyLines, typedefBodyBlanks, uniformStmtBlanks
		);
		final keepCurlyBeginExpr: Expr = blanks.keepCurlyBeginExpr;
		final keepCurlyEndExpr: Expr = blanks.keepCurlyEndExpr;
		final typedefBeginExpr: Expr = blanks.typedefBeginExpr;
		final typedefEndExpr: Expr = blanks.typedefEndExpr;
		final typedefBetweenExpr: Expr = blanks.typedefBetweenExpr;
		final blankBeforeExpr: Expr = blanks.blankBeforeExpr;
		final initCurrDocCommentExpr: Expr = blanks.initCurrDocCommentExpr;
		// ω-typedef-anon-force-multi: when the Star carries
		// `@:fmt(forceMultiInTypedef)`, the outermost typedef-RHS anon
		// has flipped `opt._inTypedefBody=true` via the parent Ref's
		// `propagateTypedefContext`. Per-element writer calls must
		// CLEAR the flag before recursing so a nested anon
		// (`typedef T = {a:{b:Int}}` — inner `{b:Int}`) reverts to
		// default fit-driven wrap. Sister to `_clearAnonFnBody` on the
		// block-Star path.
		final elemOptBase: Expr = if (forceMultiInTypedef)
			macro _clearTypedefBody(opt);
		else if (propagateExprPosition)
			macro _setExprPosition(opt);
		else
			macro opt;
		// omega-call-grouprestprobe-subposition (nested call argument, struct-Star
		// path): a `callParameterWrap` sep-Star is `HxNewExpr.args` (`HxExpr.Call`
		// goes through `lowerPostfixStar`), so write each element with
		// `_suppressCallRestProbe` set -- a nested `Call` argument does NOT rest-probe
		// the outer `new` call's sibling args + trailing `;`; the outer call opens its
		// paren first and the inner call stays flat. Mirror of the postfix-Star gate.
		// An object-literal / array sep-Star instead CLEARS the flag: its field-values
		// / elements each get their own wrapped line, so a nested `Call` there
		// rest-probes only its own element tail and must stay free to wrap -- otherwise
		// suppress inherited from an enclosing call-arg (`f({date: g(...)})`) would
		// leave an over-long field value glued past `maxLineLength`.
		final elemOptArg: Expr = switch wrapRulesField {
			case 'callParameterWrap': macro _setSuppressCallRestProbe($elemOptBase, true, opt);
			case 'objectLiteralWrap', 'arrayLiteralWrap': macro _setSuppressCallRestProbe($elemOptBase, false, opt);
			case null, _: elemOptBase;
		}
		final triviaElemCall: Expr = {
			expr: ECall(macro $i{elemFn}, [macro _t.node, elemOptArg]),
			pos: Context.currentPos()
		};
		final emptyText: String = openText + closeText;
		final trailBB: Expr = trailBBAccess ?? macro false;
		// ω-keep-fnsig-newline: close-newline splice (`value.<field>Trailing
		// NewlineBefore`), null for non-bearing callers → defaults to `false`.
		final trailNL: Expr = trailNLAccess ?? macro false;
		final trailLC: Expr = trailLCAccess ?? macro ([]: Array<String>);
		final trailClose: Expr = trailCloseAccess ?? macro (null: Null<String>);
		final trailOpen: Expr = trailOpenAccess ?? macro (null: Null<String>);
		// Head -> body seam: an EMPTY sep-Star renders as `()` with the
		// close-trailing comment cuddled to it, and the struct's remaining
		// fields (`HxFnDecl.returnType` / `body`) still follow on the same
		// Doc line. A line comment there swallows the body's `{`, so route
		// through the guarded emitter.
		final emptyTrailExpr: Expr = macro _dc([_dt($v{emptyText}), trailingCommentDocGuarded(_trailClose, opt)]);
		// ω-keep-objectlit / ω-cascade-emits-comments / ω-nowrap-flat /
		// ω-objectlit-leftCurly-cascade / ω-anontype-right-curly: the keep/ignore/
		// noWrap runtime checks + leftCurly/rightCurly placement Docs the sep-Star
		// tail consumes. Extracted to `triviaSepCheckExprs` so the orchestrator
		// stays under the complexity gate; behaviour byte-identical.
		final checks: WriterLowering.SepStarChecks = triviaSepCheckExprs(
			wrapRulesField, ignoreSourceNewlinesForWrap, reflowInExprPosition, leftCurlyKnob, rightCurlyKnob, forceMultiInTypedef
		);
		final keepCheckExpr: Expr = checks.keepCheckExpr;
		final ignoreCheckExpr: Expr = checks.ignoreCheckExpr;
		final noWrapFlatCheckExpr: Expr = checks.noWrapFlatCheckExpr;
		final triviaLeadDoc: Expr = checks.triviaLeadDoc;
		final wrapLeadFlatDoc: Expr = checks.wrapLeadFlatDoc;
		final wrapLeadBreakDoc: Expr = checks.wrapLeadBreakDoc;
		final wrapTrailBreakDoc: Expr = checks.wrapTrailBreakDoc;
		final triviaTrailDocKeepAware: Expr = checks.triviaTrailDocKeepAware;
		// ω-wraprules-objlit: when the Star carries
		// `@:fmt(wrapRules('<field>'))`, defer the no-trivia branch's
		// layout decision to the runtime `WrapList.emit` engine. The
		// engine reads `opt.<field>:WrapRules`, measures item count +
		// flat widths, and emits one of `NoWrap` / `OnePerLine` /
		// `OnePerLineAfterFirst` / `FillLine` shapes — wrapping the
		// result in `Group(IfBreak(brkDoc, flatDoc))` when the cascade's
		// `exceeds=false` and `exceeds=true` runs disagree, so the
		// renderer's flat/break decision picks the right mode at layout
		// time. When `wrapRulesField` is null, the no-trivia branch
		// keeps its pre-slice flat-only emission.
		//
		// ω-objectlit-source-trail-comma: when both `trailPresentAccess`
		// and `trailingCommaField` are wired, the engine receives a
		// `forceExceeds` flag = `<value>.<field>TrailPresent &&
		// opt.<trailingCommaField>`. When true, the cascade collapses to
		// its `exceeds=true` branch — typically `OnePerLine` — so the
		// source's "I want this multi-line" intent (a trailing separator)
		// round-trips instead of being silently flattened. The same
		// `opt.<trailingCommaField>` value is forwarded as
		// `appendTrailingComma` so the multi-line shape's last element
		// gets its `,`. When the knob is off the conjunction stays false
		// and `appendTrailingComma` is false — behaviour is byte-
		// identical to the pre-slice path.
		final trail: WriterLowering.SepStarTrailExprs = triviaSepTrailExprs(
			trailingCommaField, trailPresentAccess, matrixWrap, forceMultiInTypedef, openText, closeText, sepText, triviaElemCall,
			trailingCommaRemovable
		);
		final forceExceedsExpr: Expr = trail.forceExceedsExpr;
		final appendTrailingCommaExpr: Expr = trail.appendTrailingCommaExpr;
		final flatTrailingCommaExpr: Expr = trail.flatTrailingCommaExpr;
		final keepMatrixComputeExpr: Expr = trail.keepMatrixComputeExpr;
		final forceModeExpr: Expr = trail.forceModeExpr;
		final noTriviaBranch: Expr = triviaSepNoTriviaBranch({
			openText: openText,
			closeText: closeText,
			sepText: sepText,
			wrapRulesField: wrapRulesField,
			bodyAwareCompactIndent: bodyAwareCompactIndent,
			matrixWrap: matrixWrap,
			groupRestProbe: groupRestProbe,
			triviaElemCall: triviaElemCall,
			openInsideDoc: openInsideDoc,
			closeInsideDoc: closeInsideDoc,
			appendTrailingCommaExpr: appendTrailingCommaExpr,
			wrapLeadFlatDoc: wrapLeadFlatDoc,
			wrapLeadBreakDoc: wrapLeadBreakDoc,
			forceExceedsExpr: forceExceedsExpr,
			wrapTrailBreakDoc: wrapTrailBreakDoc,
			forceModeExpr: forceModeExpr,
			flatTrailingCommaExpr: flatTrailingCommaExpr,
			reflowSourceMultiline: reflowSourceMultiline,
			complexItems: complexItems
		});
		final sepCtx: WriterLowering.SepStarCtx = {
			openText: openText,
			closeText: closeText,
			sepText: sepText,
			triviaElemCall: triviaElemCall,
			initCurrDocCommentExpr: initCurrDocCommentExpr,
			keepCurlyBeginExpr: keepCurlyBeginExpr,
			keepCurlyEndExpr: keepCurlyEndExpr,
			typedefBeginExpr: typedefBeginExpr,
			typedefEndExpr: typedefEndExpr,
			typedefBetweenExpr: typedefBetweenExpr,
			blankBeforeExpr: blankBeforeExpr,
			appendTrailingCommaExpr: appendTrailingCommaExpr,
			triviaLeadDoc: triviaLeadDoc,
			triviaTrailDocKeepAware: triviaTrailDocKeepAware,
			keepMatrixComputeExpr: keepMatrixComputeExpr,
			noTriviaBranch: noTriviaBranch,
			reflowSourceMultiline: reflowSourceMultiline,
			matrixWrap: matrixWrap,
			uniformStmtBlanks: uniformStmtBlanks
		}
		final predicateScan: Expr = triviaSepPredicateScanExpr(reflowSourceMultiline, uniformStmtBlanks, triviaElemCall);
		final matrixSucc: Expr = triviaSepMatrixSucceedsExpr(
			matrixWrap, openText, closeText, sepText, appendTrailingCommaExpr, triviaElemCall
		);
		final dispatchCtx: WriterLowering.SepStarDispatchCtx = {
			reflowSourceMultiline: reflowSourceMultiline,
			matrixWrap: matrixWrap,
			uniformStmtBlanks: uniformStmtBlanks,
			keepCheckExpr: keepCheckExpr,
			ignoreCheckExpr: ignoreCheckExpr,
			noWrapFlatCheckExpr: noWrapFlatCheckExpr,
			predicateScanExpr: predicateScan,
			matrixSucceedsExpr: matrixSucc,
			keepMatrixComputeExpr: keepMatrixComputeExpr,
			forceMultiExpr: triviaSepForceMultiExpr(sepCtx),
			noTriviaBranch: noTriviaBranch
		}
		return macro {
			final _arr = $fieldAccess;
			final _trailLC: Array<String> = $trailLC;
			final _trailBB: Bool = $trailBB;
			// ω-keep-fnsig-newline: source newline-before-close signal,
			// consumed by `triviaTrailDocKeepAware` under `_keepEmit`.
			final _trailNL: Bool = $trailNL;
			final _trailClose: Null<String> = $trailClose;
			final _trailOpen: Null<String> = $trailOpen;
			// ω-open-trailing-alt: empty Star with only a same-line block-
			// style trail comment after the open lit (`[ /* foo */ ]`,
			// `{ /* nop */ }`) emits flat tight `[<comment>]`. Line-style
			// `_trailOpen` ALWAYS arrives with a source newline before the
			// close (`// …` would otherwise consume `]` as comment body),
			// so it falls through to the multi-line path. The block-style
			// gate also rules out the `[ /* foo */\n]` case — the source
			// newline lands in the loop's terminal `_lead`, but that path
			// has no element to attach to and currently degrades; if/when
			// we synth a "newlineBeforeClose" slot, this gate tightens.
			if (_arr.length == 0 && _trailLC.length == 0 && _trailOpen != null && StringTools.startsWith(_trailOpen, '/*')) {
				${triviaSepEmptyOpenTrailExpr(openText, closeText)};
			} else if (_arr.length == 0 && _trailLC.length == 0 && _trailOpen == null) {
				if (_trailClose != null)
					$emptyTrailExpr
				else
					_dt($v{emptyText});
			} else {
				${triviaSepDispatchExpr(dispatchCtx)};
			}
		};
	}

	/**
	 * Sep-Star no-wrap-rules flat fallback (the `wrapRulesField == null` arm
	 * of the no-trivia branch): space-joined single-line layout. References
	 * the runtime `_arr` local declared in the emitted scope.
	 */
	private static function triviaSepFlatBranch(openText: String, closeText: String, sepText: String, triviaElemCall: Expr): Expr {
		return macro {
			final _flat: Array<anyparse.core.Doc> = [_dt($v{openText})];
			var _si2: Int = 0;
			while (_si2 < _arr.length) {
				if (_si2 > 0) {
					_flat.push(_dt($v{sepText}));
					_flat.push(_dt(' '));
				}
				final _t = _arr[_si2];
				_flat.push($triviaElemCall);
				_si2++;
			}
			_flat.push(_dt($v{closeText}));
			_dc(_flat);
		};
	}

	/**
	 * Sep-Star empty-list-with-open-trail emit: an empty Star whose only
	 * content is a same-line block-style trailing comment after the open lit
	 * (e.g. `[ /+ foo +/ ]` with block delimiters). References the runtime
	 * `_trailOpen`/`_trailClose` locals declared in the emitted scope.
	 *
	 */
	private static function triviaSepEmptyOpenTrailExpr(openText: String, closeText: String): Expr {
		return macro {
			final _openDoc: anyparse.core.Doc = _dt(_trailOpen);
			if (_trailClose != null)
				_dc([
					_dt($v{openText}),
					_openDoc,
					_dt($v{closeText}),
					trailingCommentDocVerbatim(_trailClose, opt)
				]);
			else
				_dc([_dt($v{openText}), _openDoc, _dt($v{closeText})]);
		};
	}

	/**
	 * Sep-Star force-multi per-element leading break dispatch: Keep-mode
	 * source-aware break, noWrap-flat cuddle, or the legacy unconditional
	 * hardline. References the runtime `_keepEmit`/`_noWrapFlatten`/`_si`/
	 * `_t`/`_arr`/`_inner` locals declared in the force-multi loop.
	 */
	private static function triviaSepForceMultiLeadExpr(): Expr {
		return macro {
			// ω-keep-objectlit: per-element source-aware leading break.
			// Keep mode: first element gets hardline only if source
			// had `\n` before it (`newlineBefore=true`) — otherwise
			// glue to open lit. Subsequent elements: hardline on
			// source-newline, space otherwise. Legacy non-Keep path
			// always pushes hardline (force-multi byte-identical).
			if (_keepEmit) {
				if (_si > 0) {
					if (_t.newlineBefore)
						_inner.push(_dhl());
					else
						_inner.push(_dt(' '));
				} else if (_t.newlineBefore) {
					_inner.push(_dhl());
				}
			} else if (_noWrapFlatten) {
				// ω-nowrap-flat: cuddle every element flat (space sep),
				// mirroring the fork's `noWrap()` line-end suppression.
				// The ONLY break is the unsuppressible newline a `//`
				// line-comment forces — emit it on the element that
				// FOLLOWS a line-comment-bearing element (the comment
				// ends its own source line). First element glues to the
				// open delimiter (no leading break). A list with a
				// multi-line item falls through to the legacy `_dhl()`
				// one-per-line shape (its items cannot be cuddled).
				if (_si > 0) {
					final _prevTc: Null<String> = _arr[_si - 1].trailingComment;
					if (_prevTc != null && !StringTools.startsWith(_prevTc, '/*'))
						_inner.push(_dhl());
					else
						_inner.push(_dt(' '));
				}
			} else {
				_inner.push(_dhl());
			}
		};
	}

	/**
	 * Sep-Star force-multi per-element separator + trailing-comment assembly:
	 * builds `_line` from `_elem` with the inter/trailing comma honouring
	 * source `sepAfter` / `appendTrailingComma`, and the trailing comment
	 * before-or-after the sep. References the runtime `_elem`/`_line`/`_si`/
	 * `_t`/`_arr`/`_inner` locals declared in the force-multi loop.
	 */
	private static function triviaSepForceMultiLineExpr(appendTrailingCommaExpr: Expr, sepText: String): Expr {
		return macro {
			var _line: anyparse.core.Doc = _elem;
			// ω-objectlit-source-inter-sep: inter-element comma
			// honours source presence via `_t.sepAfter` (default
			// `true` for non-tracking sites — see Trivial.hx).
			// Trailing-position comma keeps the existing
			// `appendTrailingComma` decision (source-present OR
			// knob, computed by `appendTrailingCommaExpr`).
			// Handles source with two
			// `field:` slots and no separator between
			// them.
			final _isLast: Bool = _si == _arr.length - 1;
			final _emitSep: Bool = _isLast ? $appendTrailingCommaExpr : _t.sepAfter;
			final _tc: Null<String> = _t.trailingComment;
			// ω-trivia-trailing-before-sep: emit `elem /*c*/, next`
			// instead of `elem, /*c*/ next` when the source captured
			// the trailing comment between the element and the sep.
			// Falls through to the legacy after-sep position for
			// every existing capture site (`trailingBeforeSep:false`
			// default in producer pushes, see Lowering.hx).
			if (_tc != null && _t.trailingBeforeSep) _line = _dc([_line, trailingCommentDocVerbatim(_tc, opt)]);
			if (_emitSep) _line = _dc([_line, _dt($v{sepText})]);
			if (_tc != null && !_t.trailingBeforeSep) _line = _dc([_line, trailingCommentDocVerbatim(_tc, opt)]);
			_inner.push(_line);
		};
	}

	/**
	 * Sep-Star force-multi emit (the `_forceMulti` dispatch arm): per-element
	 * leading break + blank + leading comments + element + separator/trailing
	 * assembly, the orphan-trail-comment tail, and the open/inner/close parts
	 * wrap. Splices the per-element leaf builders + the ctx Expr fragments.
	 * References the runtime locals declared in `triviaSepStarExpr`'s emitted
	 * scope. Extracted so the orchestrator stays under the complexity gate.
	 */
	@:access(anyparse.macro.WriterLowering)
	private static function triviaSepForceMultiExpr(c: WriterLowering.SepStarCtx): Expr {
		final initCurrDocCommentExpr: Expr = c.initCurrDocCommentExpr;
		final keepCurlyBeginExpr: Expr = c.keepCurlyBeginExpr;
		final typedefBeginExpr: Expr = c.typedefBeginExpr;
		final blankBeforeExpr: Expr = c.blankBeforeExpr;
		final typedefBetweenExpr: Expr = c.typedefBetweenExpr;
		final keepCurlyEndExpr: Expr = c.keepCurlyEndExpr;
		final typedefEndExpr: Expr = c.typedefEndExpr;
		final triviaLeadDoc: Expr = c.triviaLeadDoc;
		final triviaTrailDocKeepAware: Expr = c.triviaTrailDocKeepAware;
		final triviaElemCall: Expr = c.triviaElemCall;
		final leadBreakExpr: Expr = triviaSepForceMultiLeadExpr();
		final lineExpr: Expr = triviaSepForceMultiLineExpr(c.appendTrailingCommaExpr, c.sepText);
		final balcEmitExpr: Expr = WriterLowering.triviaBalcEmitExpr(c.uniformStmtBlanks);
		return macro {
			final _inner: Array<anyparse.core.Doc> = [];
			$initCurrDocCommentExpr;
			$keepCurlyBeginExpr;
			$typedefBeginExpr;
			var _si: Int = 0;
			while (_si < _arr.length) {
				final _t = _arr[_si];
				$leadBreakExpr;
				$blankBeforeExpr;
				$typedefBetweenExpr;
				var _ci: Int = 0;
				while (_ci < _t.leadingComments.length) {
					_inner.push(leadingCommentDocRun(_t.leadingComments, _ci, opt));
					// ω-643-leading-block-glue: the LAST leading comment
					// keeps the element on its line (single space, no
					// break) when the source glued a block-style comment
					// to it (`/* c */ field` — `leadingCommentsGlued`).
					// Line-style `//` always ends its line → never glued.
					// Intermediate comments and the non-glued case keep
					// the legacy hardline. Default-false (every non-trivia
					// -sep-Star producer) preserves the pre-slice break.
					final _isLastLead: Bool = _ci == _t.leadingComments.length - 1;
					final _glueLead: Bool = _isLastLead && _t.leadingCommentsGlued == true
						&& StringTools.startsWith(_t.leadingComments[_ci], '/*');
					_inner.push(_glueLead ? _dt(' ') : _dhl());
					_ci++;
				}
				$balcEmitExpr;
				final _elem: anyparse.core.Doc = $triviaElemCall;
				$lineExpr;
				_si++;
			}
			$keepCurlyEndExpr;
			$typedefEndExpr;
			if (_trailLC.length > 0) {
				_inner.push(_dhl());
				if (_trailBB && _arr.length > 0) _inner.push(_dhl());
				var _tii: Int = 0;
				while (_tii < _trailLC.length) {
					_inner.push(leadingCommentDocRun(_trailLC, _tii, opt));
					if (_tii < _trailLC.length - 1) _inner.push(_dhl());
					_tii++;
				}
			}
			final _cols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			final _innerWrap: anyparse.core.Doc = _dn(_cols, _dc(_inner));
			final _parts: Array<anyparse.core.Doc> = [];
			_parts.push($triviaLeadDoc);
			_parts.push(_dt($v{c.openText}));
			if (_trailOpen != null) _parts.push(trailingCommentDocVerbatim(_trailOpen, opt));
			_parts.push(_innerWrap);
			// ω-nowrap-flat: glue the close delimiter to the last
			// element (`0]`) — the fork's `noWrap()` calls
			// `noLineEndBefore(close)`. Only when the list actually
			// cuddled flat (`_noWrapFlatten`); otherwise keep the legacy
			// own-line close (`triviaTrailDocKeepAware`).
			_parts.push(_noWrapFlatten ? _de() : $triviaTrailDocKeepAware);
			_parts.push(_dt($v{c.closeText}));
			// ω-sep-star-close-trail: guarded, not verbatim — a `//` close-trailing
			// ends its source line, and the enclosing list glues its separator
			// after this Doc (`} // c` + `,` became the comment text `} // c,`).
			// The guard is forward-looking and drops when the next emit is
			// already a hardline, so a close-trailing with nothing after it on
			// the line stays byte-identical.
			if (_trailClose != null) _parts.push(trailingCommentDocGuarded(_trailClose, opt));
			// ω-force-flat-engine slice D follow-up: trivia branch builds
			// hardlined Doc by hand instead of going through one of the 4
			// cascade-emit functions Slice C wraps. Without `_dwb` here a
			// trivia-bearing inner construct nested inside a NoWrap-cascade
			// `Flatten` region loses its source-preserved indent (the
			// hardlines fire but `Nest`'s columns are dropped by force-flat).
			// WrapBoundary is no-op when the parent frame is not in force-flat
			// mode, so this wrap is safe on the non-nested common path.
			_dwb(_dbg(_dc(_parts)));
		};
	}

	/**
	 * Sep-Star typedef-blank + doc-comment-cascade Expr builders. Bundles the
	 * seven spliced Expr fragments that the force-multi loop and `_sepCtx`
	 * consume (`keepCurlyBegin/End`, `typedefBegin/End/Between`, `blankBefore`,
	 * `initCurrDocComment`), with the four intermediate predicates
	 * (`stripByCurrDoc`/`addByCurrDoc`/`currHasDocCompute`/`typedefStripBetween`)
	 * kept local.
	 */
	private static function triviaSepTypedefBlanksExprs(
		beforeDocCommentEmptyLines: Bool, typedefBodyBlanks: Bool, uniformStmtBlanks: Bool
	): WriterLowering.SepStarBlanks {
		final curly: WriterLowering.SepStarKeepCurly = triviaSepKeepCurlyExprs(typedefBodyBlanks);
		final blankBeforeExpr: Expr = triviaSepBlankBeforeExpr(beforeDocCommentEmptyLines, typedefBodyBlanks, uniformStmtBlanks);
		final initCurrDocCommentExpr: Expr = beforeDocCommentEmptyLines ? macro var _currHasDocComment: Bool = false : macro {};
		return {
			keepCurlyBeginExpr: curly.keepCurlyBeginExpr,
			keepCurlyEndExpr: curly.keepCurlyEndExpr,
			typedefBeginExpr: curly.typedefBeginExpr,
			typedefEndExpr: curly.typedefEndExpr,
			typedefBetweenExpr: curly.typedefBetweenExpr,
			blankBeforeExpr: blankBeforeExpr,
			initCurrDocCommentExpr: initCurrDocCommentExpr
		};
	}

	/**
	 * Sep-Star keep/ignore/noWrap runtime checks + leftCurly/rightCurly
	 * placement Doc builders. Bundles the eight spliced Expr fragments the
	 * sep-Star tail consumes, keeping the knob/pattern intermediates
	 * (`ignoreBase`/`knobExpr`/`nextPat`/`knobNextOrEmpty`/`rightCurlyKnobExpr`/
	 * `inlinePat`/`triviaTrailDoc`) local.
	 */
	@:access(anyparse.macro.WriterLowering)
	private static function triviaSepCheckExprs(
		wrapRulesField: Null<String>, ignoreSourceNewlinesForWrap: Bool, reflowInExprPosition: Bool, leftCurlyKnob: Null<String>,
		rightCurlyKnob: Null<String>, forceMultiInTypedef: Bool
	): WriterLowering.SepStarChecks {
		final keepCheckExpr: Expr = wrapRulesField != null ? {
			final rulesAccess: Expr = WriterLowering.optFieldAccess(wrapRulesField);
			macro anyparse.format.wrap.WrapList.cascadeIsKeep($rulesAccess, _arr.length);
		} : macro false;
		// ω-cascade-emits-comments: Ignore-mode runtime check, sister to
		// `keepCheckExpr`. Fires when the wrap-rules JSON config sets
		// `"defaultWrap": "ignore"` (case-2, user-driven) OR the grammar
		// annotation `@:fmt(ignoreSourceNewlinesForWrap)` is set (case-1,
		// intrinsic per-construct semantic — currently `HxFnDecl.params`).
		// Architecture per [[feedback-grammar-annotation-keep-too-aggressive]]:
		// intrinsic flags + JSON checks are disjoined here, no separate
		// override channel.
		//
		// ω-expressionif-collapse (mechanism B): `@:fmt(reflowInExprPosition)`
		// adds a THIRD, runtime-gated disjunct — Ignore fires when
		// `opt._inValueIfBranch` is set, i.e. the object literal is the direct
		// value of a value-if branch. Combined with mechanism A's `{ x }`
		// padding this collapses `{\n width: …\n}` to `{ width: … }` only in
		// that one context (var-init / call-arg object literals keep their
		// source-multiline shape because the flag is cleared on every
		// expression-position descent).
		final ignoreBase: Expr = if (ignoreSourceNewlinesForWrap)
			macro true
		else if (wrapRulesField != null) {
			final rulesAccess: Expr = WriterLowering.optFieldAccess(wrapRulesField);
			macro $rulesAccess.defaultMode == anyparse.format.wrap.WrapMode.Ignore;
		} else
			macro false;
		// ω-arrow-body-objlit-reflow: a FOURTH disjunct on the same
		// `@:fmt(reflowInExprPosition)` Star (HxObjectLit.fields) — Ignore
		// also fires when the literal is an arrow-lambda body (runtime
		// `opt._inArrowLambdaBody`, the same signal the open-pad suppress
		// consumes) AND the config opted in via `objectLiteralBraces.
		// arrowBodyReflow: true`. A source-multiline arrow-body literal then
		// drops its newlineBefore signals and the wrap cascade re-flows it
		// by width — collapsing `u -> {\n a: 1\n}` to the canonical
		// `u -> { a: 1 }` when it fits (a deliberate config-gated divergence:
		// the fork keeps such literals source-multiline). Without the knob
		// the legacy force-multi shape is kept; it also sidesteps the
		// enclosing-chain BodyGroup under-measure that exploded the arrow
		// (`u ->` newline `{…}`) non-idempotently.
		final ignoreResolved: Expr = reflowInExprPosition
			? macro ($ignoreBase) || opt._inValueIfBranch || (opt._inArrowLambdaBody && opt.objectLiteralArrowBodyReflow)
			: ignoreBase;
		// ω-anontype-reflow-typedef-guard: a typedef RHS anon is NOT governed by
		// `wrapping.anonType` in the fork at all — its brace classifies as
		// `BrOpenType.TypedefDecl` and routes to `MarkWrapping.typedefWrapping`,
		// which keeps the source line structure verbatim (collapse only when the
		// body was already same-line). anyparse models both positions with the
		// single `HxType.Anon` Star, so an `anonType.defaultWrap: "ignore"` config
		// — meant to re-flow INLINE anon type hints by width — would also drop the
		// source newlines of every multi-line typedef body and collapse it. Gate
		// the Ignore drop off inside the typedef RHS on the Star that opted into
		// `@:fmt(forceMultiInTypedef)` (only `HxType.Anon`); `opt._inTypedefBody`
		// is set by `HxTypedefDecl.type`'s `propagateTypedefContext` and cleared
		// per-element, so a NESTED anon inside a typedef body still re-flows.
		final ignoreCheckExpr: Expr = forceMultiInTypedef ? macro ($ignoreResolved) && !opt._inTypedefBody : ignoreResolved;
		// ω-nowrap-flat: pure-`noWrap` runtime check, sister to
		// `keepCheckExpr` / `ignoreCheckExpr`. Fires only when the
		// wrap-rules JSON config selects `"defaultWrap": "noWrap"` with an
		// EMPTY rule cascade (`{rules: [], defaultMode: NoWrap}` — the shape
		// the loader builds for a user `arrayWrap.defaultWrap: noWrap` block,
		// see `Loader.wrapRulesFromConfig`). This is the fork's `noWrap()`
		// policy (`MarkWrappingBase.noWrap` → `noWrappingBetween`): every
		// element cuddles flat, and the ONLY break is the unsuppressible
		// `lineEndAfter` a `//` line-comment forces. Distinct from the
		// built-in `defaultArrayLiteralWrap` cascade (non-empty `rules`), so
		// the gate stays false for the default config → byte-inert there.
		// Used to (a) defeat the `reflowSourceMultiline` floor so a
		// source-multiline list collapses fully flat under explicit noWrap,
		// and (b) swap the force-multi per-element hardline for a space
		// (break only after a line-comment) when a mid-list `//` forced the
		// list into the trivia branch.
		final noWrapFlatCheckExpr: Expr = wrapRulesField != null ? {
			final rulesAccess: Expr = WriterLowering.optFieldAccess(wrapRulesField);
			macro $rulesAccess.defaultMode == anyparse.format.wrap.WrapMode.NoWrap && $rulesAccess.rules.length == 0;
		} : macro false;
		// ω-objectlit-leftCurly-cascade: when the call site delegates
		// leftCurly emission to this helper (knob-form leftCurly + wrap-
		// rules), build runtime accessors for the knob value that:
		//  - in the trivia branch: pick `_dhl()` (Next) or `_de()` (Same)
		//    as a single Doc prepended to the BodyGroup's parts.
		//  - in the no-trivia branch: feed `(leadFlat, leadBreak)` into
		//    `WrapList.emit` so the engine's Group(IfBreak) picks the
		//    right shape per the wrap-cascade's flat/break decision.
		final knobExpr: Null<Expr> = leftCurlyKnob == null ? null : WriterLowering.optFieldAccess(leftCurlyKnob);
		final nextPat: Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'BracePlacement', 'Next']);
		// Doc that selects `_doh()` for `BracePlacement.Next`, `_de()`
		// otherwise. `_doh()` is `OptHardline` — drops when the previous
		// emit was already a hardline (e.g. wrap-engine sep `\n`
		// between call args). Avoids the `,\n\n{` newline-collision
		// bug when an outer wrap-engine sep and an inner leftCurly Next
		// independently push a leading newline at the same insertion
		// point (ω-opthardline).
		//
		// `wrapLeadFlatDoc` is always `_de()` — flat layout never wants
		// a hardline before the open brace, regardless of knob value.
		final knobNextOrEmpty: Expr = knobExpr == null ? macro _de() : {
			expr: ESwitch(knobExpr, [{ values: [nextPat], expr: macro _doh(), guard: null }], macro _de()),
			pos: Context.currentPos()
		};
		final triviaLeadDoc: Expr = knobNextOrEmpty;
		final wrapLeadFlatDoc: Expr = macro _de();
		final wrapLeadBreakDoc: Expr = knobNextOrEmpty;
		// ω-anontype-right-curly: when the call site reads
		// `@:fmt(rightCurly('<knob>'))`, build a Doc that picks `_de()`
		// for `RightCurlyPlacement.Inline` (close glued to last body
		// token) and `_dhl()` otherwise. Null knob → unconditional
		// `_dhl()` (legacy). Substituted for the unconditional `_dhl()`
		// emitted immediately before `_dt(closeText)` in the trivia
		// branch. The wrap-engine branch reads the same expression
		// through `WrapList.emit`'s `trailBreak` param (slice
		// ω-wraplist-trailbreakdoc) — both branches honour the same
		// `RightCurlyPlacement.{Inline,Same}` semantic.
		final rightCurlyKnobExpr: Null<Expr> = rightCurlyKnob == null ? null : WriterLowering.optFieldAccess(rightCurlyKnob);
		final inlinePat: Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'RightCurlyPlacement', 'Inline']);
		final triviaTrailDoc: Expr = rightCurlyKnobExpr == null ? macro _dhl() : {
			expr: ESwitch(rightCurlyKnobExpr, [{ values: [inlinePat], expr: macro _de(), guard: null }], macro _dhl()),
			pos: Context.currentPos()
		};
		// ω-wraplist-trailbreakdoc: wrap-engine close placement reads
		// the same knob as the trivia branch's `triviaTrailDoc`.
		// `WrapList.shapeOnePerLine` substitutes the result for the
		// hardcoded `Line('\n')` before `Text(close)` — `_de()` glues
		// the close to the last body token (Inline), `_dhl()` keeps
		// it on its own line (Same).
		final wrapTrailBreakDoc: Expr = triviaTrailDoc;
		// ω-keep-fnsig-newline: close-delimiter placement for the trivia
		// force-multi KEEP path. Function signatures (the only Star carrying
		// `@:fmt(ignoreSourceNewlinesForWrap)`) preserve the SOURCE close
		// placement under keep: the close `)` stays glued to the last
		// parameter (`param7:Int)` — `wrapping_of_function_signature_keep`) when
		// the source had no newline before it, but drops to its own indented
		// line (`\n\t):FastMatrix3` — `issue_238_keep_wrapping_function_signature`)
		// when the author put one there. `_trailNL` carries that source signal
		// (captured at the Star's close-peek into the `TrailingNewlineBefore`
		// slot). When `_keepEmit` is live: `_dhl()` if the source broke before
		// close, `_de()` (glued) otherwise. Object-literals / arrays (no
		// intrinsic flag) keep their own-line close unchanged, and non-keep
		// params (`_keepEmit == false`) stay on the legacy break — both byte-
		// inert. Only consumed at the trivia branch's `_parts` assembly; the
		// no-trivia cascade reads `wrapTrailBreakDoc`.
		final triviaTrailDocKeepAware: Expr = ignoreSourceNewlinesForWrap
			? macro (_keepEmit ? (_trailNL ? _dhl() : _de()) : $triviaTrailDoc)
			: triviaTrailDoc;
		return {
			keepCheckExpr: keepCheckExpr,
			ignoreCheckExpr: ignoreCheckExpr,
			noWrapFlatCheckExpr: noWrapFlatCheckExpr,
			triviaLeadDoc: triviaLeadDoc,
			wrapLeadFlatDoc: wrapLeadFlatDoc,
			wrapLeadBreakDoc: wrapLeadBreakDoc,
			wrapTrailBreakDoc: wrapTrailBreakDoc,
			triviaTrailDocKeepAware: triviaTrailDocKeepAware
		};
	}

	/**
	 * Sep-Star source-trailing-comma / force-exceeds / force-mode / keep-matrix
	 * Expr builders. Bundles the five spliced Expr fragments the sep-Star tail
	 * consumes, keeping the `knobAccessOrFalse` intermediate local.
	 */
	@:access(anyparse.macro.WriterLowering)
	private static function triviaSepTrailExprs(
		trailingCommaField: Null<String>, trailPresentAccess: Null<Expr>, matrixWrap: Bool, forceMultiInTypedef: Bool, openText: String,
		closeText: String, sepText: String, triviaElemCall: Expr, trailingCommaRemovable: Bool
	): WriterLowering.SepStarTrailExprs {
		final knobAccessOrFalse: Expr = trailingCommaField == null ? macro false : WriterLowering.optFieldAccess(trailingCommaField);
		final forceExceedsExpr: Expr = trailPresentAccess != null && trailingCommaField != null
			? WriterLowering.keepsTrailingCommaExpr(macro $trailPresentAccess && $knobAccessOrFalse, trailingCommaRemovable)
			: macro false;
		// ω-meta-allman-objectlit: when source had a trailing `,`, preserve
		// it in any multi-line shape regardless of the ADD knob (but not
		// regardless of `wrapping.trailingComma`, whose `Remove` value vetoes
		// the whole expression below). The change
		// matters when the layout is forced multi-line by some other signal
		// — surrounding hardlines (e.g. the meta-Allman wrap from
		// `HxMetaExpr.expr`'s `@:fmt(allmanIndentForCtor)`), natural
		// cascade fit, or `forceExceeds` — at which point the source's
		// `,` round-trips like the rest of the multi-line shape.
		// Mirrors haxe-formatter's "Keep" trailing-comma policy for the
		// meta-prefixed object-literal pattern (`return @patch { ..., }`
		// → multi-line with closing `,`).
		final appendTrailingCommaExpr: Expr = WriterLowering.keepsTrailingCommaExpr(
			trailPresentAccess != null && trailingCommaField != null ? macro $trailPresentAccess || $knobAccessOrFalse : knobAccessOrFalse,
			trailingCommaRemovable
		);
		// ω-nowrap-source-trail-comma: the FLAT (`NoWrap`) trailing-comma signal
		// is source-presence ONLY (`<field>TrailPresent`), NOT the knob-inclusive
		// `appendTrailingComma`. The fork is source-faithful for single-line
		// lists: `{a: 1,}` / `[1, 2,]` / `f(x,)` keep their trailing `,` flat,
		// while a list whose source had none stays comma-free even with the knob
		// on (the knob only forces the break-mode layout via `forceExceeds`).
		// Null `trailPresentAccess` (Stars without a source-trail slot) → `false`,
		// byte-identical to the pre-slice flat shape.
		final flatTrailingCommaExpr: Expr = trailPresentAccess ?? macro false;
		// ω-arraymatrix-keep: matrix-align takes precedence over the Keep
		// cascade. The non-Keep matrix attempt (`matrixComputeExpr`, in the
		// no-trivia/cascade branch) is gated `!_keepEmit` and so never fires
		// under a `"defaultWrap": "keep"` array — a kept matrix lands in the
		// force-multi path, which preserves the source rows but emits no
		// column padding. The fork runs `tryMatrixWrap` BEFORE
		// `applyWrappingPlace` inside `arrayLiteralWrapping`, so matrix grid
		// layout wins over the array's keep/noWrap rules; this expr mirrors
		// that for the Keep case. Computed at the outer Star scope (the
		// no-trivia branch's `_matrixDoc` is unreachable under Keep) and
		// gated on `_keepEmit` + the same source-multiline-without-hardline
		// condition the non-Keep path uses (`!_requiresHardline`,
		// `_hasSourceNewlines`). The matrix detector reads per-element
		// `newlineBefore` (row boundaries) and the bare rendered cell Docs;
		// on a uniform grid it returns the aligned/unaligned Doc, else null
		// → fall through to force-multi. Cells under `!_requiresHardline`
		// carry no comments (any leading/trailing comment forces a hardline
		// under Keep, see the predicate split below), so the bare
		// `$triviaElemCall` render matches the no-trivia branch's `_docs`
		// exactly. Only meaningful when the Star opted into
		// `@:fmt(arrayMatrixWrap)` (`matrixWrap` compile-time flag); every
		// other sep-Star consumer leaves it `macro null` and stays byte-
		// identical.
		final keepMatrixComputeExpr: Expr = matrixWrap
			? macro {
				if (
					_keepEmit && !_requiresHardline && _hasSourceNewlines
					&& opt.arrayMatrixWrap != anyparse.format.ArrayMatrixWrap.NoMatrixWrap
				) {
					final _kdocs: Array<anyparse.core.Doc> = [];
					final _krow: Array<Bool> = [];
					var _kmi: Int = 0;
					while (_kmi < _arr.length) {
						final _t = _arr[_kmi];
						_kdocs.push($triviaElemCall);
						_krow.push(_kmi == 0 || _t.newlineBefore);
						_kmi++;
					}
					final _kmcols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
					anyparse.format.wrap.MatrixWrap.tryLayout(
						_kdocs, _krow, opt.arrayMatrixWrap, $v{openText}, $v{closeText}, $v{sepText}, $appendTrailingCommaExpr, _kmcols
					);
				} else {
					(null: Null<anyparse.core.Doc>);
				}
			}
			: macro (null: Null<anyparse.core.Doc>);
		// ω-typedef-anon-force-multi: the `forceMode` option of
		// `WrapList.emit` — a runtime `Null<WrapMode>` predicate. When
		// the Star opted into `@:fmt(forceMultiInTypedef)` AND the
		// parent typedef-RHS Ref flipped `opt._inTypedefBody=true` via
		// `propagateTypedefContext` AND `opt.anonTypeLeftCurly == Next`,
		// the engine bypasses the cascade and lays out the body
		// `OnePerLine` unconditionally — closes the issue_301 typedef-
		// anon source-flat → fork-multi-line shape gap deferred in
		// ω-anontype-left-curly. The leftCurly==Next gate mirrors fork's
		// `MarkLineEnds.detectCurlyPolicy(TypedefDecl)` rule: the
		// curly-break-driven multi-line layout fires only when the
		// global `lineEnds.leftCurly` ↔ our `anonTypeLeftCurly` cascade
		// hits `before`/`both` (= Next). For the default `after` (= Same)
		// flat typedef-RHS anons stay cuddled, matching issue_586 /
		// issue_206 / issue_588 (which leave `typedef T = {a:Int}` /
		// `typedef T = {…}->Void` / `typedef T = Array<{k:Int}>` flat).
		// Null fall-through preserves pre-slice cascade-driven layout
		// for non-typedef anon consumers (var-type-hint, fn-return-type).
		final forceModeExpr: Expr = forceMultiInTypedef
			? macro (
				opt._inTypedefBody && opt.anonTypeLeftCurly == anyparse.format.BracePlacement.Next
					? anyparse.format.wrap.WrapMode.OnePerLine
					: (null: Null<anyparse.format.wrap.WrapMode>)
			)
			: macro (null: Null<anyparse.format.wrap.WrapMode>);
		return {
			forceExceedsExpr: forceExceedsExpr,
			appendTrailingCommaExpr: appendTrailingCommaExpr,
			flatTrailingCommaExpr: flatTrailingCommaExpr,
			keepMatrixComputeExpr: keepMatrixComputeExpr,
			forceModeExpr: forceModeExpr
		};
	}

	/**
	 * Sep-Star no-trivia (wrap-cascade) branch builder: the `wrapRulesField !=
	 * null` arm wraps each per-element Doc with its leading/trailing comments,
	 * attempts a matrix grid, and defers layout to `WrapList.emit`; the null
	 * arm falls back to the space-joined flat layout.
	 */
	@:access(anyparse.macro.WriterLowering)
	private static function triviaSepNoTriviaBranch(c: WriterLowering.SepStarNoTriviaCtx): Expr {
		// noqa: complexity
		final triviaElemCall: Expr = c.triviaElemCall;
		final openInsideDoc: Expr = c.openInsideDoc;
		final closeInsideDoc: Expr = c.closeInsideDoc;
		final appendTrailingCommaExpr: Expr = c.appendTrailingCommaExpr;
		final wrapLeadFlatDoc: Expr = c.wrapLeadFlatDoc;
		final wrapLeadBreakDoc: Expr = c.wrapLeadBreakDoc;
		final forceExceedsExpr: Expr = c.forceExceedsExpr;
		final wrapTrailBreakDoc: Expr = c.wrapTrailBreakDoc;
		final forceModeExpr: Expr = c.forceModeExpr;
		final flatTrailingCommaExpr: Expr = c.flatTrailingCommaExpr;
		final openText: String = c.openText;
		final closeText: String = c.closeText;
		final sepText: String = c.sepText;
		// ω-complex-item-count: the per-element AST classification, computed
		// once over the captured element array. `null` when the Star does not
		// carry `@:fmt(complexItems)` — the engine then counts 0 and the chunk
		// policy stays off, so the emit call is byte-identical.
		final complexKindsDecl: Expr = c.complexItems
			? macro final _complexKinds: Null<Array<Int>> = opt._suppressComplexItems
				? null
				: anyparse.grammar.haxe.HxComplexItems.kinds(cast _arr)
			: macro final _complexKinds: Null<Array<Int>> = null;
		return if (c.wrapRulesField != null) {
			final rulesExpr: Expr = WriterLowering.optFieldAccess(c.wrapRulesField);
			// ω-functionsignature-body-aware-indent: thread the field-level
			// `@:fmt(bodyAwareCompactIndent)` opt-in into `WrapList.emit`'s
			// `compactContinuation` param as `true` for EVERY function-signature
			// wrap (mirror of the plain-path site). Those signatures carry
			// `ignoreSourceNewlinesForWrap`, so every break is the cascade
			// leading-break at `calcIndent + additionalIndent` (additional-only);
			// gating on `opt._fnSigBodyEmpty` left a NON-empty single-param
			// signature one indent level too deep. Other sep-Star consumers
			// (HxType.Anon.fields, HxObjectLit.fields, etc.) leave the flag
			// clear and pass `macro false`.
			final compactContExpr: Expr = macro $v{c.bodyAwareCompactIndent};
			// ω-arraymatrix-wrap: when the Star opted into
			// `@:fmt(arrayMatrixWrap)` (currently `HxExpr.ArrayExpr`) and the
			// runtime policy preserves the source grid, attempt a one-pass
			// grid layout BEFORE the wrap cascade. The matrix detector reads
			// per-element `newlineBefore` (row boundaries) and the rendered
			// cell widths; on a uniform matrix (>=2 columns, equal rows, no
			// multi-line cell) it returns the aligned/unaligned grid Doc,
			// which is wrapped in BodyGroup (sister to the `_smlKeep` path)
			// so an enclosing Group's `fitsFlat` defers the grid's hardlines
			// and the call/assign context stays inline. `tryLayout` returns
			// null for non-matrix shapes → fall through to the cascade.
			// Gated on the same source-multiline-without-blocking-trivia
			// condition as `_smlKeep`; only fires when `matrixWrap` is set,
			// so every other sep-Star consumer is byte-identical (`macro {}`).
			final matrixComputeExpr: Expr = c.matrixWrap
				? macro {
					// ω-matrix-survives-ignore: the probe reads `newlineBefore` off the
					// elements itself, so `_hasSourceNewlines` was only ever a fast path —
					// and under `Ignore` that signal is deliberately DROPPED, which took
					// the grid with it. A 16-per-row lookup table then reflowed to one
					// element per line, because a matrix has no representation other than
					// the source rows: `Ignore` means "re-flow by width", and a grid is
					// exactly the thing width cannot reconstruct. So the grid wins over
					// Ignore, the same precedence the noWrap-flatten path already gives it.
					//
					// Nothing else needs a guard: `MatrixWrap.tryLayout` returns null
					// unless the rows form a uniform grid of at least TWO columns, so a
					// flat array (no `newlineBefore` anywhere) and a one-per-line array
					// both fall straight through to the cascade.
					if (opt.arrayMatrixWrap != anyparse.format.ArrayMatrixWrap.NoMatrixWrap && !_requiresHardline && !_keepEmit) {
						final _rowStart: Array<Bool> = [for (_mi in 0..._arr.length) _mi == 0 || _arr[_mi].newlineBefore];
						final _mcols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
						_matrixDoc = anyparse.format.wrap.MatrixWrap.tryLayout(
							_docs, _rowStart, opt.arrayMatrixWrap, $v{openText}, $v{closeText}, $v{sepText}, $appendTrailingCommaExpr,
							_mcols
						);
					}
				}
				: macro {};
			// ω-cascade-emits-comments: wrap each per-element Doc with its
			// leading comments (each followed by a hardline) and an inline
			// block-style trailing comment (line-style trailings are not
			// cascade-emittable — the engine inserts the separator AFTER
			// the item, which would land INSIDE a `// ...` line comment;
			// those route to the force-multi branch via `_requiresHardline`
			// in the predicate split below). When the element has no
			// trivia, `_parts.length==1`
			// collapses to the bare
			// `_elemBase` Doc.
			macro {
				final _docs: Array<anyparse.core.Doc> = [];
				// ω-sep-faithful: per-pair `sepBefore` flags so `WrapList.emit`
				// can suppress the engine's inter-element comma when the
				// source elided it (canonical: `HxParam.Conditional` body
				// leading-sep elides the outer `,` ahead of the `#if`).
				// `_sepBeforeFlags[i] = !_arr[i-1].sepAfter` for i >= 1;
				// slot 0 is unused. Trailing-comma stays on the existing
				// `appendTrailingComma` axis.
				final _sepBeforeFlags: Array<Bool> = [];
				// A block trailing comment captured AFTER the separator
				// (trailingBeforeSep == false) is deferred here and emitted as
				// an inline leading prefix of the NEXT item, so WrapList.emit
				// places it after the comma, matching the force-multi path's
				// after-sep emission (see triviaSepForceMultiLineExpr).
				var _pendingAfterSep: Null<String> = null;
				var _si2: Int = 0;
				while (_si2 < _arr.length) {
					final _t = _arr[_si2];
					_sepBeforeFlags.push(_si2 != 0 && !_arr[_si2 - 1].sepAfter);
					final _elemBase: anyparse.core.Doc = $triviaElemCall;
					final _parts: Array<anyparse.core.Doc> = [];
					if (_pendingAfterSep != null) {
						_parts.push(leadingCommentDoc(_pendingAfterSep, opt));
						_parts.push(_dt(' '));
						_pendingAfterSep = null;
					}
					var _ci2: Int = 0;
					while (_ci2 < _t.leadingComments.length) {
						_parts.push(leadingCommentDocRun(_t.leadingComments, _ci2, opt));
						_parts.push(_dhl());
						_ci2++;
					}
					_parts.push(_elemBase);
					final _tc2: Null<String> = _t.trailingComment;
					if (_tc2 != null && StringTools.startsWith(_tc2, '/*')) {
						if (_t.trailingBeforeSep || _si2 == _arr.length - 1)
							_parts.push(trailingCommentDocVerbatim(_tc2, opt));
						else
							_pendingAfterSep = _tc2;
					}
					_docs.push(_parts.length == 1 ? _parts[0] : _dc(_parts));
					_si2++;
				}
				// ω-arraymatrix-wrap: grid layout attempt before the cascade.
				// `_matrixDoc` stays null for non-matrix shapes (or when the
				// flag is off — `matrixComputeExpr` is then `macro {}`), so the
				// trailing expression falls through to the wrap cascade.
				var _matrixDoc: Null<anyparse.core.Doc> = null;
				$matrixComputeExpr;
				// ω-comprehension-fitline: a for/while comprehension under
				// comprehensionFor:fitLine (padded brackets) is fit-driven. Use the fit
				// cascade instead of the generic arrayWrap fixed thresholds (which break the
				// sole for-expr item past ~80 chars regardless of maxLineLength), AND drop
				// source-multiline-keep so an already-wrapped but fitting comprehension
				// reflows flat (fork parity) rather than staying pinned open.
				// ω-comprehension-fit-measure: the same flag also rides into
				// `WrapList.emit` as `comprehensionFitMeasure`, which re-tags the sole
				// item's hardline-free `BodyGroup`s as `Group` so the fit cascade's
				// width question sees the generator body it would otherwise defer to 0.
				final _isComprehension: Bool = $v{c.reflowSourceMultiline} && _arr.length > 0
					&& anyparse.grammar.haxe.HaxeFormat.isComprehensionGenerator(_arr[0]);
				final _comprehensionFit: Bool = _isComprehension && opt.comprehensionBracketsOpen == anyparse.format.WhitespacePolicy.After;
				final _effRules: anyparse.format.wrap.WrapRules = _comprehensionFit
					? anyparse.grammar.haxe.HaxeFormat.defaultComprehensionWrap()
					: $rulesExpr;
				final _effSmlKeep: Bool = _comprehensionFit ? false : _smlKeep;
				$complexKindsDecl;
				final _wlResult: anyparse.core.Doc = anyparse.format.wrap.WrapList.emit(
					$v{openText}, $v{closeText}, $v{sepText}, _docs, opt, $openInsideDoc, $closeInsideDoc, false, _effRules, {
						appendTrailingComma: $appendTrailingCommaExpr,
						leadFlat: $wrapLeadFlatDoc,
						leadBreak: $wrapLeadBreakDoc,
						forceExceeds: $forceExceedsExpr,
						trailBreak: $wrapTrailBreakDoc,
						forceMode: $forceModeExpr,
						compactContinuation: $compactContExpr,
						groupRestProbe: $v{c.groupRestProbe},
						sepBeforeFlags: _sepBeforeFlags,
						sourceMultilineKeep: _effSmlKeep,
						flatTrailingComma: $flatTrailingCommaExpr,
						comprehensionFitMeasure: _comprehensionFit,
						complexItemKinds: _complexKinds
					}
				);
				// ω-comprehension-count idempotence: a `for`/`while` array comprehension
				// self-lays-out (the writer re-emits a wide one as `[` then a newline then `for…`). The non-
				// idempotency: a COMPACT source comprehension lowers to a bare counted `Group`
				// (full flat width in a parent's `flatTokenWidth`), while a pre-EXPLODED one
				// takes the `_smlKeep` path → `BodyGroup`, which `flatTokenWidth` defers to
				// width 0. So the SAME comprehension AST measures wide on one pass and ~0 on
				// the next → a wrap decision in an enclosing method-chain / `+` operator flips
				// between passes. Force a comprehension to ALWAYS count (bare `Group`, real
				// width) so the parent measure is trivia-independent and its wrap decision is
				// stable. (Deferring to width 0 instead — the sister pre-exploded path — was
				// tried and REGRESSED: an enclosing call then under-measures, commits to flat,
				// and overflows into a mangled break — see
				// `testChainOwnedArrayPastSoftBreakLeadingBreaks`.) Detect by AST structure
				// (first element a `ForExpr`/`WhileExpr`), gated on the compile-time
				// `reflowSourceMultiline` array-Star flag so the `Type.enumConstructor` probe
				// never runs on a non-array Star (whose element node is a non-enum struct →
				// the cast would throw). Non-comprehension arrays keep their `_smlKeep` reflow
				// behaviour untouched.
				_matrixDoc != null ? _dbg(_matrixDoc) : (_smlKeep && !_isComprehension ? _dbg(_wlResult) : _wlResult);
			};
		} else {
			triviaSepFlatBranch(openText, closeText, sepText, triviaElemCall);
		};
	}

	/**
	 * Sep-Star predicate-scan loop: one pass over `_arr` populating the
	 * `_requiresHardline` / `_hasSourceNewlines` / `_hasInlineableTrivia` /
	 * `_anyMultilineItem` accumulators (declared in the emitted scope) from each
	 * element's blank/comment/source-newline signals. References the runtime
	 * `_keepEmit`/`_ignoreEmit`/`_noWrapFlat`/`_matrixOff` locals.
	 */
	private static function triviaSepPredicateScanExpr(reflowSourceMultiline: Bool, uniformStmtBlanks: Bool, triviaElemCall: Expr): Expr {
		final blankHardlineExpr: Expr = triviaSepBlankHardlineExpr(uniformStmtBlanks);
		return macro {
			var _ti: Int = 0;
			while (_ti < _arr.length) {
				final _t = _arr[_ti];
				if ($blankHardlineExpr) _requiresHardline = true;
				if (_t.leadingComments.length > 0) {
					if (_ignoreEmit)
						_hasInlineableTrivia = true;
					else
						_requiresHardline = true;
				}
				final _tcSig: Null<String> = _t.trailingComment;
				if (_tcSig != null) {
					if (_ignoreEmit && StringTools.startsWith(_tcSig, '/*'))
						_hasInlineableTrivia = true;
					else
						_requiresHardline = true;
				}
				// ω-array-reflow idempotence: the FIRST element's `newlineBefore` also fires for
				// a newline BEFORE the open `[` (the array on a fresh line of an enclosing broken
				// construct — e.g. a wrapped ternary branch), not only an internal one. Counting
				// it marks a single-line `['a', 'b']` as source-multiline → forces it OnePerLine,
				// which the writer's own broken-branch output then re-triggers every pass (non-
				// idempotent). So for a `reflowSourceMultiline` array Star ignore the first
				// element's flag — EXCEPT in Keep mode (preserves source breaks verbatim) and for
				// a comprehension (`for`/`while` sole element), whose element genuinely starts on
				// its own line after `[`. Other elements (index > 0) carry only genuine INTERNAL
				// newlines, so they are always counted.
				if (
					_t.newlineBefore && !_ignoreEmit && !_matrixOff && !(
						$v{reflowSourceMultiline} && _ti == 0 && !_keepEmit
						&& !anyparse.grammar.haxe.HaxeFormat.isComprehensionGenerator(_t)
					)
				)
					_hasSourceNewlines = true;
				// A non-enum payload (e.g. an object-literal field struct) answers
				// `false` inside the shared classifier, so the non-array Star case
				// needs no guard of its own.
				if (
					_noWrapFlat && (
						anyparse.grammar.haxe.HaxeFormat.isComprehensionGenerator(_t)
						|| anyparse.format.wrap.WrapList.flatLength($triviaElemCall) < 0
					)
				)
					_anyMultilineItem = true;
				_ti++;
			}
		};
	}

	/**
	 * Sep-Star noWrap matrix-grid probe: the RHS of the `_matrixSucceeds` flag —
	 * true when a matrix-eligible Star under noWrap with no comment/blank
	 * hardline forms a uniform source grid (`MatrixWrap.tryLayout != null`), else
	 * false. References the runtime `_noWrapFlat`/`_anyMultilineItem`/
	 * `_requiresHardline`/`_arr` locals.
	 */
	private static function triviaSepMatrixSucceedsExpr(
		matrixWrap: Bool, openText: String, closeText: String, sepText: String, appendTrailingCommaExpr: Expr, triviaElemCall: Expr
	): Expr {
		return macro if (
			$v{matrixWrap} && _noWrapFlat && !_anyMultilineItem && !_requiresHardline
			&& opt.arrayMatrixWrap != anyparse.format.ArrayMatrixWrap.NoMatrixWrap
		) {
			final _pdocs: Array<anyparse.core.Doc> = [];
			final _prow: Array<Bool> = [];
			var _pi: Int = 0;
			while (_pi < _arr.length) {
				final _t = _arr[_pi];
				_pdocs.push($triviaElemCall);
				_prow.push(_pi == 0 || _t.newlineBefore);
				_pi++;
			}
			final _pcols: Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			anyparse.format.wrap.MatrixWrap.tryLayout(
				_pdocs, _prow, opt.arrayMatrixWrap, $v{openText}, $v{closeText}, $v{sepText}, $appendTrailingCommaExpr, _pcols
			) != null;
		} else
			false;
	}

	/**
	 * Sep-Star non-empty-list dispatch block: derives the keep/ignore/noWrap/
	 * forceMulti predicates (via the predicate-split machinery) and routes the
	 * list to the keep-matrix grid, the force-multi loop, or the no-trivia
	 * cascade. References the runtime `_arr`/`_trailLC`/`_trailOpen` locals.
	 *
	 */
	@:access(anyparse.macro.WriterLowering)
	private static function triviaSepDispatchExpr(c: WriterLowering.SepStarDispatchCtx): Expr {
		final keepCheckExpr: Expr = c.keepCheckExpr;
		final ignoreCheckExpr: Expr = c.ignoreCheckExpr;
		final noWrapFlatCheckExpr: Expr = c.noWrapFlatCheckExpr;
		final predicateScanExpr: Expr = c.predicateScanExpr;
		final matrixSucceedsExpr: Expr = c.matrixSucceedsExpr;
		final keepMatrixComputeExpr: Expr = c.keepMatrixComputeExpr;
		final forceMultiExpr: Expr = c.forceMultiExpr;
		final noTriviaBranch: Expr = c.noTriviaBranch;
		// ω-uniform-element-blanks: the `_uniformCollapse` pre-pass, shared with
		// the block-Star statement policy. Declared BEFORE the predicate scan
		// (which reads it) and before the force-multi loop's blank guard.
		// `macro {}` for every non-opted sep-Star.
		final uniformCollapseInitExpr: Expr = WriterLowering.triviaUniformCollapseInitExpr(c.uniformStmtBlanks);
		return macro {
			// ω-keep-predicate-split + ω-cascade-emits-comments: decompose
			// `_hasTrivia` into three orthogonal predicates so the
			// Ignore-mode cascade can ingest per-element block comments
			// and the Keep emit path can stay gated on physical hardline
			// requirements alone.
			//
			//  - `_requiresHardline` — physical hardline requirement:
			//    `_trailLC`/`_trailOpen` on the open/close boundary, any
			//    blank line before an element, leading comments (when
			//    NOT in ignore mode), and trailing LINE comments (any
			//    mode — engine inserts the sep AFTER the item, which
			//    would land inside `// ...`). Anything in this bucket
			//    MUST route through the force-multi branch.
			//  - `_hasSourceNewlines` — bare `newlineBefore=true` on at
			//    least one element. Independent axis. Under
			//    `_ignoreEmit` this signal is DROPPED (fork's `Ignore`
			//    policy ignores source newlines and lets width drive
			//    layout); legacy default still flips `_hasTrivia=true`.
			//  - `_hasInlineableTrivia` — at least one element carries a
			//    leading comment OR a block-style trailing comment, AND
			//    `_ignoreEmit` is live. These are cascade-emittable: the
			//    no-trivia branch wraps each item Doc with its leading
			//    comments + inline block trailing before passing to
			//    `WrapList.emit`. Routes the item to cascade (not
			//    force-multi) when no `_requiresHardline` blocker fires.
			//
			// Byte-identity for `_ignoreEmit=false`: comments still set
			// `_requiresHardline=true` (legacy bucket); cascade rewrite
			// at the no-trivia branch collapses to `_docs.push(_elem)`
			// because `_parts.length==1` on no-comment elements.
			// ω-keep-fnsig-newline: `_keepEmit` is read FIRST so the
			// `_ignoreEmit` gate below can yield to it. The only Star
			// carrying the intrinsic `@:fmt(ignoreSourceNewlinesForWrap)`
			// flag (so `ignoreCheckExpr == macro true`) is `HxFnDecl.params`;
			// it ALSO reads `wrapRules('functionSignatureWrap')`. When the
			// JSON config sets that rule to `keep`, the author opted into
			// source-newline preservation explicitly, so Keep must win over
			// the per-construct Ignore default. For every JSON-config consumer
			// `defaultMode` is a single value — Keep and Ignore are mutually
			// exclusive — so `!_keepEmit` only ever flips the params-in-Keep
			// case; all other Stars (Ignore-mode object-literals / arrays,
			// default-mode params) keep the prior `_ignoreEmit` value byte-
			// for-byte. The force-multi per-element swap further below reads
			// this same `_keepEmit` for the source-`newlineBefore` dispatch.
			final _keepEmit: Bool = $keepCheckExpr;
			final _ignoreEmit: Bool = $ignoreCheckExpr && !_keepEmit;
			// ω-nowrap-flat: pure-`noWrap` config (empty cascade) — yields
			// to Keep/Ignore (mutually exclusive `defaultMode`s, so this
			// only ever flips for an actual NoWrap config). Scoped to the
			// ARRAY-LITERAL Star via the `reflowSourceMultiline` compile
			// flag (the only Star carrying it). The fork flattens noWrap
			// arrays (`arrayLiteralWrapping` → `applyWrappingPlace`) but
			// does NOT flatten a source-multiline OBJECT literal under
			// noWrap — `objectLiteralWrapping` force-one-per-lines any
			// `!isOriginalSameLine` body BEFORE consulting the rule. Object
			// literals (no `reflowSourceMultiline`) therefore keep their
			// legacy source-multiline force-multi shape. Drives the fork's
			// `noWrap()` flat-with-comment-break layout below.
			final _noWrapFlat: Bool = $v{c.reflowSourceMultiline} && $noWrapFlatCheckExpr && !_keepEmit && !_ignoreEmit;
			// ω-arraymatrix-wrap: `NoMatrixWrap` ignores the source grid
			// entirely — like the `Ignore` policy it DROPS source newlines
			// so the cascade (not the force-multi path) drives layout: a
			// short matrix-shaped array collapses flat, a wide one width-
			// packs. Only meaningful on a matrix-eligible Star (`matrixWrap`
			// compile-time flag); every other consumer leaves it false.
			final _matrixOff: Bool = $v{c.matrixWrap} && opt.arrayMatrixWrap == anyparse.format.ArrayMatrixWrap.NoMatrixWrap;
			$uniformCollapseInitExpr;
			var _requiresHardline: Bool = _trailLC.length > 0 || _trailOpen != null;
			var _hasSourceNewlines: Bool = false;
			var _hasInlineableTrivia: Bool = false;
			// ω-nowrap-flat: the noWrap-flatten path applies only to a plain
			// element list. Two kinds of item make a list NON-flattenable,
			// mirroring the fork (`MarkWrapping.arrayLiteralWrapping`):
			//  - a `for`/`while` ARRAY-COMPREHENSION item: the fork returns
			//    early from `arrayLiteralWrapping` when the first item is
			//    `Kwd(KwdFor)`/`Kwd(KwdWhile)` under `comprehensionFor: keep`,
			//    leaving the comprehension's layout to the sameLine/forBody
			//    policy — so the noWrap arrayWrap rule never touches it.
			//  - an item that renders with its own forced hardline (block
			//    body, etc.): cannot be cuddled flat (the inner construct
			//    keeps its mandatory breaks). Probed via
			//    `WrapList.flatLength(item) < 0`, the same "has forced
			//    hardline" signal the cascade's `HasMultilineItems` uses.
			// Both flow into `_anyMultilineItem`, which gates the flatten
			// off → such lists keep the legacy `_smlKeep`/force-multi shape.
			// Only computed under `_noWrapFlat` (every other path leaves it
			// false → no extra per-element render / reflection).
			var _anyMultilineItem: Bool = false;
			$predicateScanExpr;
			final _hasTrivia: Bool = _requiresHardline || _hasSourceNewlines;
			// ω-nowrap-flat: matrix grid wins over noWrap-flatten, mirroring
			// the fork (`arrayLiteralWrapping` calls `tryMatrixWrap` BEFORE
			// `applyWrappingPlace`). Probe whether the source rows form a
			// uniform grid; if so, leave `_noWrapFlatten` off so the array
			// flows to the existing `_smlKeep` / no-trivia matrix path
			// (column-aligned grid). Only computed for a matrix-eligible
			// Star (`matrixWrap`) under noWrap with no comment/blank
			// hardline; every other path leaves it false.
			final _matrixSucceeds: Bool = $matrixSucceedsExpr;
			// ω-keep-relax-gate: Keep emit gate. Fires whenever the
			// wrap-rules runtime mode is Keep — comments and blanks no
			// longer block Keep semantics. The force-multi loop below
			// emits leadingComments/trailingComment + blanks per
			// element, and the per-element swap honours source
			// `newlineBefore` for inter-element breaks. Syntactic
			// invariant: a line-trailing `// ...` comment ends the
			// source line, so the next element always carries
			// `newlineBefore=true` and gets `_dhl()` from the swap —
			// no risk of `_dt(' ')` cuddling content after a `//`.
			// The cascade-emits-comments path remains reserved for
			// Ignore mode (`_hasInlineableTrivia` bucket).
			// `_keepEmit` itself is declared above (hoisted so the
			// `_ignoreEmit` gate can yield to it — ω-keep-fnsig-newline).
			// ω-array-reflow: when the Star opted into
			// `@:fmt(reflowSourceMultiline)` AND its only "multi-line"
			// signal is bare source newlines (no hardline-requiring
			// trivia, no Keep / Ignore policy), divert away from the
			// force-multi (one-`_dhl()`-per-element) path and let the
			// wrap cascade re-flow the list. `_smlKeep` gates that
			// diversion; `WrapList.emit`'s `sourceMultilineKeep` floor
			// then guarantees the cascade never collapses such a list
			// fully flat (NoWrap → OnePerLine), so the source's
			// "stay multi-line" intent is honoured while width-driven
			// packing (FillLine / FillLineWithLeadingBreak) applies.
			// Under `NoMatrixWrap` (`_matrixOff`) `_hasSourceNewlines` was
			// already forced false above, so `_smlKeep` collapses here and
			// the cascade drives layout — no extra gate needed.
			// ω-nowrap-flat: under an explicit pure-`noWrap` array config a
			// source-multiline list whose items carry NO intrinsic hardline
			// (`_anyMultilineItem`: a `for`/`while` comprehension or a
			// hardline-bearing item) AND that is not a uniform matrix grid
			// (`_matrixSucceeds`) must collapse to the fork's `noWrap()` flat
			// shape — every element cuddled, the close glued, and the only
			// break the one a `//` line-comment forces. Both the comment
			// case (`_requiresHardline` via a line-comment) and the plain
			// case route through the FORCE-MULTI per-element loop below: its
			// `_noWrapFlatten` branch
			// lays the list out flat AND preserves the source trailing comma
			// (`appendTrailingCommaExpr`) — which the no-trivia cascade's
			// `shapeNoWrap` would have dropped. A comprehension / multi-line
			// item or a matrix-grid array keeps the legacy `_smlKeep` reflow
			// (its layout is owned by another path).
			final _noWrapFlatten: Bool = _noWrapFlat && !_anyMultilineItem && !_matrixSucceeds;
			// ω-nowrap-flat: `_smlKeep` reflow stays ON for a comprehension /
			// multi-line-item / matrix noWrap array — those keep their HEAD
			// source-multiline shape. It is disabled ONLY when the array
			// actually flattens (`_noWrapFlatten`), so the flatten routes
			// through the force-multi flat loop below instead of reflow.
			final _smlKeep: Bool = $v{c.reflowSourceMultiline} && _hasSourceNewlines && !_requiresHardline && !_keepEmit && !_ignoreEmit
				&& !_noWrapFlatten;
			final _forceMulti: Bool = (_hasTrivia && !_smlKeep) || _noWrapFlatten;
			// ω-arraymatrix-keep: attempt the matrix grid BEFORE the keep
			// force-multi emit. `_keepMatrixDoc` is non-null only for a
			// matrix-eligible Star (`matrixWrap`) under Keep with a
			// uniform source grid; otherwise null → fall through to the
			// existing force-multi / cascade dispatch byte-identically.
			// Wrapped in `_dwb(_dbg(...))` like the force-multi path so a
			// matrix nested inside a force-flat region keeps its indent
			// and an enclosing Group defers the grid's hardlines.
			final _keepMatrixDoc: Null<anyparse.core.Doc> = $keepMatrixComputeExpr;
			if (_keepMatrixDoc != null) {
				${triviaSepCloseTrailAppendExpr(macro _dwb(_dbg(_keepMatrixDoc)))};
			} else if (_forceMulti) {
				$forceMultiExpr;
			} else {
				${triviaSepCloseTrailAppendExpr(noTriviaBranch)};
			}
		};
	}

	/**
	 * ω-sep-star-close-trail: append the Star's close-trailing comment
	 * (`_trailClose`) to a branch Doc that does not emit the slot itself.
	 *
	 * `_trailClose` holds a same-line comment captured AFTER the Star's close
	 * literal — `{a: 1} /* c *\/` parks the comment on the OBJECT literal's
	 * `fieldsTrailingClose`, never on the enclosing array element's
	 * `Trivial.trailingComment`, so the enclosing list cannot rescue it. Before
	 * this wrapper only three emit paths read the slot back out: the two
	 * empty-list arms (`_arr.length == 0`) and the force-multi loop's `_parts`
	 * tail. Every literal the fit-driven wrap cascade renders — which is every
	 * SHORT one, the common case — dropped the comment on the floor. `apq fmt`
	 * caught the loss and refused the file, so no bytes were corrupted, but the
	 * file could not be formatted at all.
	 *
	 * Emission goes through `trailingCommentDocGuarded`, matching the
	 * empty-list arm: a `//` close-trailing ends its source line, so the
	 * enclosing list's `,` (or its close delimiter) would otherwise be
	 * swallowed into the comment text. The guard is forward-looking and drops
	 * when the next emit is already a hardline, so every shape whose seam was
	 * already sound stays byte-identical.
	 *
	 * The Doc is bound to a local first: the branch Exprs are statement blocks
	 * whose value is the Doc, and splicing one twice would emit it twice.
	 */
	private static function triviaSepCloseTrailAppendExpr(branch: Expr): Expr {
		return macro {
			final _ctBranchDoc: anyparse.core.Doc = $branch;
			_trailClose != null ? _dc([_ctBranchDoc, trailingCommentDocGuarded(_trailClose, opt)]) : _ctBranchDoc;
		};
	}

	/**
	 * Sep-Star keepCurly / typedef-RHS blank-insert Expr builders — the five
	 * `typedefBodyBlanks`-gated fragments (`keepCurlyBegin/End`, `typedefBegin/
	 * End/Between`). Sub-split out of `triviaSepTypedefBlanksExprs` so each
	 * builder stays under the complexity gate; byte-identical.
	 */
	private static function triviaSepKeepCurlyExprs(typedefBodyBlanks: Bool): WriterLowering.SepStarKeepCurly {
		final oc: WriterLowering.SepStarKeepCurlyOC = triviaSepKeepCurlyOpenClose(typedefBodyBlanks);
		final ins: WriterLowering.SepStarTypedefInserts = triviaSepTypedefBlankInserts(typedefBodyBlanks);
		return {
			keepCurlyBeginExpr: oc.keepCurlyBeginExpr,
			keepCurlyEndExpr: oc.keepCurlyEndExpr,
			typedefBeginExpr: ins.typedefBeginExpr,
			typedefEndExpr: ins.typedefEndExpr,
			typedefBetweenExpr: ins.typedefBetweenExpr
		};
	}

	/**
	 * Sep-Star per-element between-fields blank Expr — the `blankBeforeExpr`
	 * fragment, with the doc-comment-cascade intermediates (`stripByCurrDoc`/
	 * `addByCurrDoc`/`currHasDocCompute`/`typedefStripBetween`) kept local.
	 * Sub-split out of `triviaSepTypedefBlanksExprs` so each builder stays under
	 * the complexity gate; byte-identical.
	 */
	@:access(anyparse.macro.WriterLowering)
	private static function triviaSepBlankBeforeExpr(
		beforeDocCommentEmptyLines: Bool, typedefBodyBlanks: Bool, uniformStmtBlanks: Bool
	): Expr {
		// noqa: complexity
		// ω-trivia-sep-doc-comment-cascade (Phase B2): mirror the
		// `_currHasDocComment` / `addByCurrDocExpr` machinery from
		// `triviaBlockStarExpr` so sep-Stars (e.g. `HxType.Anon.fields`
		// in trivia mode) honour the `beforeDocCommentEmptyLines` policy
		// at inter-element slots. Compile-time gate keeps callers without
		// the flag (`HxExpr.ArrayExpr.elems`, `HxObjectLit.fields`)
		// byte-identical to pre-slice behaviour.
		final stripByCurrDocExpr: Expr = beforeDocCommentEmptyLines
			? macro (_currHasDocComment && opt.beforeDocCommentEmptyLines == anyparse.format.CommentEmptyLinesPolicy.None)
			: macro false;
		final addByCurrDocExpr: Expr = beforeDocCommentEmptyLines
			? macro (_currHasDocComment && opt.beforeDocCommentEmptyLines == anyparse.format.CommentEmptyLinesPolicy.One)
			: macro false;
		final currHasDocComputeExpr: Expr = beforeDocCommentEmptyLines
			? macro {
				_currHasDocComment = false;
				var _cdci: Int = 0;
				while (_cdci < _t.leadingComments.length) {
					if (StringTools.startsWith(_t.leadingComments[_cdci], '/**')) {
						_currHasDocComment = true;
						break;
					}
					_cdci++;
				}
			}
			: macro {};
		// ω-typedef-between-fields: runtime predicate that strips the
		// source-captured inter-field blank for a typedef RHS body. Fires
		// when this Star opted into `@:fmt(typedefBodyBlanks)` AND the anon
		// is in typedef context AND EITHER a forced `typedefBetweenFields`
		// count owns the slot (the `$typedefBetweenExpr` pushes the exact
		// count, so the source blank must not stack on top) OR
		// `typedefExistingBetweenFields == Remove` collapses source blanks.
		// `false` for every non-typedef caller (compile-time gate) → the
		// existing source-blank pass-through is byte-identical.
		final typedefStripBetweenExpr: Expr = typedefBodyBlanks
			? macro (opt._inTypedefBody
				&& (opt.typedefBetweenFields > 0 || opt.typedefExistingBetweenFields == anyparse.format.KeepEmptyLinesPolicy.Remove))
			: macro false;
		// ω-uniform-element-blanks: suppress the source blank at every interior
		// gap once the pre-pass found the gap set uniform. Sister to the
		// block-Star guard in `TriviaBlockLowering.triviaBlockBlankBeforeExpr`;
		// `macro false` for every non-opted sep-Star keeps the emit
		// byte-identical.
		final uniformStripExpr: Expr = uniformStmtBlanks ? macro _uniformCollapse : macro false;
		final blankExtras: Expr = WriterLowering.blankBefore2ExtrasExpr(macro _inner.push(_dhl()));
		return beforeDocCommentEmptyLines
			? macro {
				$currHasDocComputeExpr;
				final _stripBlank: Bool = $stripByCurrDocExpr || $typedefStripBetweenExpr || $uniformStripExpr;
				final _addBlank: Bool = $addByCurrDocExpr;
				final _sourceBlank: Bool = _t.blankBefore && !_stripBlank;
				if (_si > 0 && (_sourceBlank || _addBlank)) {
					_inner.push(_dhl());
					if (_sourceBlank) $blankExtras;
				}
			}
			: macro {
				if (_t.blankBefore && _si > 0 && !($typedefStripBetweenExpr) && !($uniformStripExpr)) {
					_inner.push(_dhl());
					$blankExtras;
				}
			};
	}

	/**
	 * Sep-Star open/close-side Keep-mode curly-blank Expr builders. Sub-split
	 * out of `triviaSepKeepCurlyExprs` so each builder stays under the
	 * complexity gate; byte-identical.
	 */
	private static function triviaSepKeepCurlyOpenClose(typedefBodyBlanks: Bool): WriterLowering.SepStarKeepCurlyOC {
		// ω-bropen-keep-sep: opt-in via `@:fmt(keepCurlyBlanks)` on a
		// sep-Star (currently `HxType.Anon.fields`). Push one extra `_dhl()`
		// at the head of `_inner` when source had a blank between `{` and
		// the first element AND the runtime opted into Keep; symmetric
		// end-side push before `_trailLC` handling. Other sep-Star consumers
		// default `keepCurlyBlanks=false` → both pushes are `macro {}`.
		final keepCurlyBeginExpr: Expr = typedefBodyBlanks
			? macro {
				if (opt.afterLeftCurly == anyparse.format.KeepEmptyLinesPolicy.Keep && _arr.length > 0 && _arr[0].blankBefore)
					_inner.push(_dhl());
			}
			: macro {};
		final keepCurlyEndExpr: Expr = typedefBodyBlanks
			? macro {
				if (opt.beforeRightCurly == anyparse.format.KeepEmptyLinesPolicy.Keep && _trailBB && _arr.length > 0) _inner.push(_dhl());
			}
			: macro {};
		return {
			keepCurlyBeginExpr: keepCurlyBeginExpr,
			keepCurlyEndExpr: keepCurlyEndExpr
		};
	}

	/**
	 * Sep-Star typedef-RHS forced blank-insert Expr builders (begin/end/between).
	 * Active only when this Star opted into `@:fmt(typedefBodyBlanks)`
	 * (`HxType.Anon`) AND the parent typedef RHS flipped `opt._inTypedefBody`;
	 * a positive count pushes exactly that many blanks. Sub-split out of
	 * `triviaSepKeepCurlyExprs` so each builder stays under the complexity gate.
	 */
	private static function triviaSepTypedefBlankInserts(typedefBodyBlanks: Bool): WriterLowering.SepStarTypedefInserts {
		final typedefBeginExpr: Expr = typedefBodyBlanks
			? macro {
				if (opt._inTypedefBody && opt.typedefBeginType > 0 && _arr.length > 0) {
					var _tbi: Int = 0;
					while (_tbi < opt.typedefBeginType) {
						_inner.push(_dhl());
						_tbi++;
					}
				}
			}
			: macro {};
		final typedefEndExpr: Expr = typedefBodyBlanks
			? macro {
				if (opt._inTypedefBody && opt.typedefEndType > 0 && _arr.length > 0) {
					var _tei: Int = 0;
					while (_tei < opt.typedefEndType) {
						_inner.push(_dhl());
						_tei++;
					}
				}
			}
			: macro {};
		// Per-element between-fields blank: pushed before the element for
		// `_si > 0`; a positive `typedefBetweenFields` forces the exact count.
		final typedefBetweenExpr: Expr = typedefBodyBlanks
			? macro {
				if (_si > 0 && opt._inTypedefBody && opt.typedefBetweenFields > 0) {
					var _tfi: Int = 0;
					while (_tfi < opt.typedefBetweenFields) {
						_inner.push(_dhl());
						_tfi++;
					}
				}
			}
			: macro {};
		return {
			typedefBeginExpr: typedefBeginExpr,
			typedefEndExpr: typedefEndExpr,
			typedefBetweenExpr: typedefBetweenExpr
		};
	}

	/**
	 * ω-uniform-element-blanks: the sep-Star predicate scan's `blankBefore`
	 * hardline signal. A collapsed gap must not leave a hardline requirement
	 * behind — the list has to take exactly the route a blank-free source would
	 * have taken, or the next `fmt` pass (which sees no blanks) picks a
	 * different branch and the emit is not idempotent. `macro _t.blankBefore`
	 * (the pre-slice expression) for every non-opted Star.
	 *
	 * The gate is deliberately NOT restricted to interior gaps. The blank right
	 * after the open delimiter is already dropped upstream — it is owned by the
	 * `afterLeftCurly` family, never reaches the emit (`_si > 0`), and an
	 * element-0-only carve-out here was measured to change no output — so the
	 * extra clause would be an untestable special case.
	 *
	 * Consequence worth stating: dropping the requirement also unblocks every
	 * route the hardline was gating — `_smlKeep` reflow, the Keep matrix grid,
	 * the `noWrap` flatten. Under an `arrayWrap: noWrap` config a
	 * uniformly-blank list therefore collapses onto ONE line rather than merely
	 * losing its blanks. That is the shape the blank-free source produces,
	 * which is exactly the invariant this gate buys.
	 */
	private static function triviaSepBlankHardlineExpr(uniformStmtBlanks: Bool): Expr {
		return uniformStmtBlanks ? macro (_t.blankBefore && !_uniformCollapse) : macro _t.blankBefore;
	}

}
#end
