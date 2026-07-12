package anyparse.format.wrap;

import anyparse.core.Doc;
import anyparse.core.DocMeasure;
import anyparse.format.IndentChar;
import anyparse.format.WriteOptions;

using Lambda;

/**
 * Runtime helper that emits a `Doc` for a delimited list whose layout
 * is driven by a `WrapRules` cascade.
 *
 * Used by macro-generated writers via a single call inserted at sites
 * tagged with `@:fmt(wrapRules('<optionFieldName>'))` on their `Star`
 * field. The macro feeds in the open / close / separator literals,
 * the per-item `Doc` array, the resolved `WriteOptions`, the inside-
 * delimiter padding `Doc`s and the rule set looked up by name on
 * `opt`. Everything else — flat-length measurement, cascade
 * evaluation, shape selection — happens at runtime in this class.
 *
 * The `ExceedsMaxLineLength` predicate is resolved without a
 * column-aware probe: the cascade runs twice (`exceeds=false` and
 * `exceeds=true`) and, when the two runs disagree, the result is
 * wrapped in `Group(IfBreak(brkDoc, flatDoc))` so the renderer's
 * standard fit/break decision picks the right mode at layout time.
 * When both runs agree the chosen mode is unconditional and no Group
 * wrap is needed.
 *
 * Items containing hardlines (e.g. block bodies, multi-line strings)
 * are intrinsically un-flattenable — the cascade is forced to the
 * `exceeds=true` branch in that case.
 */
class WrapList {

	/**
	 * `leadFlat` / `leadBreak`: optional Docs prepended INSIDE the
	 * engine's `Group(IfBreak(brk, flat))` so a per-construct decoration
	 * (typically a leftCurly placement: hardline for Allman / Empty for
	 * cuddled) tracks the wrap engine's flat/break decision. When the
	 * cascade collapses to a single mode (no Group wrap), the
	 * appropriate lead is selected via `isFlatMode`. Defaults to
	 * `Empty`/`Empty` — default-passing callers see no behavioural change. ω-objectlit-leftCurly-cascade — first consumer is
	 * `triviaSepStarExpr` for `HxObjectLit.fields` knob-form leftCurly.
	 *
	 * `forceExceeds`: when `true`, both cascade evaluations
	 * (`exceeds=false` and `exceeds=true`) are replaced with a single
	 * `exceeds=true` decide call so the engine commits unconditionally
	 * to the break-mode shape (typically `OnePerLine` for default
	 * cascades). Used by sep-Stars whose source carried a trailing
	 * separator AND whose `@:fmt(trailingComma(...))` knob is on — the
	 * trailing-sep is treated as an explicit "stay multi-line" hint
	 * even when item widths would otherwise collapse the list flat.
	 * ω-objectlit-source-trail-comma — first consumer is
	 * `HxObjectLit.fields`.
	 *
	 * `trailBreak`: the Doc emitted immediately before `Text(close)` in
	 * the `OnePerLine` shape. Null defaults to `Line('\n')` — the
	 * legacy hardcoded close-on-own-line layout — so null-passing callers stay byte-identical. Per-construct `RightCurlyPlacement` knobs
	 * pass `Empty` for `Inline` (close glued to last body token) or
	 * `Line('\n')` for `Same`. Mirrors the trivia branch's
	 * `triviaTrailDoc` in `WriterLowering.triviaSepStarExpr` so wrap-
	 * engine and trivia paths honour the same
	 * `RightCurlyPlacement.{Inline,Same}` semantic. Honoured by
	 * `shapeOnePerLine` only — `OnePerLineAfterFirst` / `FillLine` glue
	 * close by mode design and have no Inline-vs-Same axis to express.
	 * ω-wraplist-trailbreakdoc — first consumers are
	 * `HxObjectLit.fields` and `HxType.Anon` via `triviaSepStarExpr`.
	 *
	 * `forceMode`: optional `WrapMode` override that bypasses the
	 * cascade and forces a single mode regardless of `evalAt(...)`.
	 * `null` (default) — the cascade runs normally. Non-null short-circuits both `exceeds=false` and
	 * `exceeds=true` evaluations to the supplied mode AND skips
	 * extra-threshold enumeration, so the renderer commits
	 * unconditionally to one shape (no `IfBreak` wrapping needed).
	 * Used by `@:fmt(forceMultiInTypedef)` on typedef-RHS anon types
	 * to thread `WrapMode.OnePerLine` when `opt._inTypedefBody=true`,
	 * matching fork's `MarkLineEnds.markTypedef` parent-walk forcing
	 * `=\n{\n\t...\n}` shape regardless of field count or fit. ω-typedef-anon-force-multi.
	 *
	 * `sepBeforeFlags`: optional per-element `Bool` array, length-aligned
	 * with `items`. When `flags[i] == true`, the engine SKIPS the
	 * separator that would otherwise land between `items[i-1]` and
	 * `items[i]` — used by sep-Stars whose source omits a comma at a
	 * specific inter-element slot (canonical case: a `Conditional`
	 * (`#if`/`#end`) ctor inside `HxFnDecl.params` where the source
	 * elides the outer comma in favour of the cond-comp block's own
	 * leading sep). `flags[0]` is unused (no element precedes item 0)
	 * and any out-of-bounds / null treats every slot as sep-emitting,
	 * keeping flag-less consumers byte-identical. The trailing-comma
	 * decision stays on the existing `appendTrailingComma` axis.
	 * Honoured by `shapeNoWrap`, `shapeOnePerLine`,
	 * `shapeOnePerLineAfterFirst`, and `shapeFillLine` at chunk
	 * boundaries; `shapeFillLineWithLeadingBreak`'s `Fill(items,
	 * softSep)` packing keeps the legacy uniform softSep. First consumer is `HxFnDecl.params` via the wrap-rules
	 * (`ignoreSourceNewlinesForWrap`) no-trivia branch in
	 * `triviaSepStarExpr`.
	 */
	public static function emit(
		open: String, close: String, sep: String, items: Array<Doc>, opt: WriteOptions, openInside: Doc, closeInside: Doc,
		keepInnerWhenEmpty: Bool, rules: WrapRules, appendTrailingComma: Bool = false, leadFlat: Doc = Empty, leadBreak: Doc = Empty,
		forceExceeds: Bool = false, ?trailBreak: Doc, ?forceMode: Null<WrapMode>, compactContinuation: Bool = false,
		groupRestProbe: Bool = false, ?sepBeforeFlags: Array<Bool>, sourceMultilineKeep: Bool = false, ?sourceBreakBefore: Array<Bool>,
		// ω-keep-callclose-newline: when the SOLE call-arg is a Keep-mode method
		// chain whose source had NO newline before the outer close `)` (the chain
		// glued the close — `})));`), keep the close glued instead of routing
		// through `shapeFillLine`'s `isChainOPLBreak` close-on-own-line break. Set
		// only by `WriterLowering.lowerPostfixStar` when the Call ctor's
		// `methodChain` rules are `Keep` and the parser's `argsCloseNewline` slot
		// is false. Default `false` → every non-keep / source-broke caller keeps
		// the legacy chain-OPL close placement, so the change is byte-inert.
		keepCloseGlued: Bool = false,
		// ω-nowrap-source-trail-comma: source-only trailing-comma signal forwarded
		// to the flat (`NoWrap`) shape. The writer passes `<field>TrailPresent`
		// here (NOT the `trailPresent || knob` value of `appendTrailingComma`), so
		// a single-line list preserves its source `,` while the knob still only
		// drives break-mode. Default `false` → every other caller stays byte-
		// identical.
		flatTrailingComma: Bool = false
	): Doc {
		// `Line('\n')` is not a Haxe-constant default — unwrap a null
		// sentinel into the legacy hardcoded hardline here.
		final trailBreakDoc: Doc = trailBreak ?? Line('\n');
		if (items.length == 0) return WrapBoundary(Text(open + (keepInnerWhenEmpty ? ' ' : '') + close));

		// ω-arrowif-open: a call/array arg whose body is a PLAIN `if` (no else,
		// not a `{}`-block) hides its inline then-branch behind a `BodyGroup`
		// that every static width measure DEFERS to width 0 — under-measuring
		// the arg so the `callParameter` cascade, the outer-Group fit, and the
		// fill-pack all keep it hugged even when the body overflows. Re-tag its
		// hardline-free `BodyGroup`s as `Group` (render-identical; only the
		// measure differs) so the true width is visible and the call opens on
		// the overflowing line, matching the fork's full-arrow-line measure.
		// Copy-on-write: untouched when no such arg is present.
		var groupified: Null<Array<Doc>> = null;
		for (i in 0...items.length) if (isArrowPlainIfBody(items[i])) {
			if (groupified == null) groupified = items.copy();
			groupified[i] = groupifyInlineBodies(items[i]);
		}
		if (groupified != null) items = groupified;

		final sepWidth: Int = sep.length + 1;
		final measure: { total: Int, maxLen: Int, anyHardline: Bool } = measureItems(items, sepWidth);
		final total: Int = measure.total;
		final maxLen: Int = measure.maxLen;
		final anyHardline: Bool = measure.anyHardline;
		final cols: Int = continuationCols(rules, opt, items, maxLen, total, anyHardline, sourceMultilineKeep, compactContinuation);

		// Column-aware `LineLengthLargerThan` thresholds (slice
		// ω-ifwidthexceeds-infra). Cascade rules with `lineLength >= n`
		// where `n != opt.lineWidth` cannot be answered at emit time
		// because the rendered column position is unknown until layout.
		// Threshold == lineWidth collapses cleanly to `exceeds` (the
		// existing `IfBreak` pivot) and stays on the legacy 2-state
		// path. Non-lineWidth thresholds enumerate extra states and
		// emit one `IfWidthExceeds(t, …)` wrapper per distinct
		// threshold so the renderer probes `column + flatWidth(flat)`
		// against `t` at layout time.
		final extraThresholds: Array<Int> = collectExtraLineLengthThresholds(rules, opt.lineWidth);

		// Cascade-eval helper: caller specifies the (exceeds, firingThresholds)
		// state and gets the cascade's resolved mode. `LineLengthLargerThan`
		// is mapped to:
		//   - `t == lineWidth` → use `exceeds` (collapse semantic)
		//   - `t != lineWidth` → membership in `firingThresholds`
		// All other cond kinds preserve their original evaluators.
		// Non-`inline` so it can be passed as `evalAt` arg into
		// `buildForceBreakTree` (Haxe forbids closure-on-inline-closure).
		// ω-typedef-anon-force-multi: when caller passes a non-null
		// `forceMode`, the cascade is bypassed and the supplied mode is
		// returned unconditionally. Used by `@:fmt(forceMultiInTypedef)`
		// on typedef-RHS anon types via the runtime gate
		// `opt._inTypedefBody ? WrapMode.OnePerLine : null`.
		function evalAt(exceeds: Bool, firing: Array<Int>): WrapMode {
			return forceMode
				?? floorSourceMultiline(
					decideWithLineLengthState(
						rules, items.length, maxLen, total, exceeds, anyHardline, t -> t == opt.lineWidth ? exceeds : firing.contains(t)
					),
					sourceMultilineKeep
				);
		}

		// Per-state shape builder: picks the right lead based on the
		// resolved mode (flat vs break-style layout).
		function shapeAt(mode: WrapMode, lead: Doc): Doc {
			final body: Doc = shape(
				mode, open, close, sep, items, openInside, closeInside, cols, appendTrailingComma, trailBreakDoc, groupRestProbe,
				sepBeforeFlags, opt.lineWidth, sourceBreakBefore, keepCloseGlued, flatTrailingComma
			);
			return prependLead(body, lead);
		}

		function leadFor(mode: WrapMode): Doc {
			return isFlatMode(mode) ? leadFlat : leadBreak;
		}

		// Force-break path: cascade evaluated only against
		// `exceeds=true`. Thresholds still column-aware — even when
		// the parent commits to break-mode, a `LineLengthLargerThan`
		// rule answer can flip with column position. The unified
		// `buildThresholdTree` helper handles 0/1/N thresholds via
		// recursion (1-threshold optimization with impossibility
		// filtering inlined for the common case below).
		return anyHardline || forceExceeds
			? WrapBoundary(buildThresholdTree(extraThresholds, [], true, leadFlat, leadBreak, evalAt, shapeAt, leadFor))
			: extraThresholds.length == 0
				? emitZeroThreshold(
					rules, items, opt, cols, open, close, openInside, closeInside, forceMode, groupRestProbe, leadFlat, leadBreak, evalAt,
					shapeAt, leadFor
				)
				: extraThresholds.length == 1
					? emitOneThreshold(extraThresholds[0], opt, evalAt, shapeAt, leadFor)
					: WrapBoundary(buildThresholdTree(extraThresholds, [], null, leadFlat, leadBreak, evalAt, shapeAt, leadFor));
	}

	/**
	 * Single-Ref wrap variant of `emit` for statement-condition paren
	 * groups (`if (cond)`, `while (cond)`). The cascade sees the cond
	 * as a 1-item list and picks between flat shape `(cond)` and
	 * wrapped shape `(\n\tcond\n)`. Renderer's column-aware fit
	 * decision selects the right shape via `Group(IfBreak(brk, flat))`.
	 *
	 * Cond payloads carrying hardlines (cond already broken by inner
	 * opBoolChain / call-arg wrap / lambda body) commit to the wrapped
	 * shape unconditionally — `flatLength(condDoc) < 0`.
	 *
	 * `LineLengthLargerThan` thresholds beyond the cascade's basic
	 * `ExceedsMaxLineLength` rule are NOT supported here yet — first
	 * consumer (`HxIfStmt.cond` / `HxWhileStmt.cond`) ships only the
	 * fork's default `fillLineWithLeadingBreak` + `exceedsMaxLineLength:
	 * 0 → noWrap` cascade. ω-condition-wrap-wiring.
	 */
	public static function emitCondition(
		open: String, close: String, condDoc: Doc, opt: WriteOptions, rules: WrapRules,
		// ω-condition-parens (Stage C): inner padding Docs for the FLAT
		// shape (`if( cond )`). `openInside` follows `Text(open)`,
		// `closeInside` precedes `Text(close)`. Both default `Empty` →
		// byte-identical tight `(cond)`. Break shape leaves the cond on its
		// own line so inner pads do not apply there.
		openInside: Doc = Empty,
		closeInside: Doc = Empty,
		// ω-condition-wrap-keep — the source placed a newline right after the
		// open paren (`if (\n\tcond`). Captured at parse time onto the cond
		// field's `<field>CondOpenNewline:Bool` synth slot (mandatory-Ref
		// `@:fmt(condWrap)` + `@:fmt(captureCondOpenNewline)`) and threaded by
		// the single-Ref condWrap emit in `WriterLowering`. Consumed ONLY under
		// `WrapMode.Keep` (`rules.defaultMode == Keep`) → forces `brkShape`
		// (`(\n\tcond\n)`) so a kept condition round-trips the author's
		// post-`(` break verbatim while the inner chain self-breaks per the
		// already-landed chain source-newline mechanism. Default false →
		// every non-keep / non-bearing caller (span mode, plain mode) is
		// byte-inert.
		sourceOpenNewline: Bool = false
	): Doc {
		final cols: Int = opt.indentChar == IndentChar.Space ? opt.indentSize : opt.tabWidth;
		final condW: Int = DocMeasure.flatTokenWidth(condDoc);
		final hasHardline: Bool = flatLength(condDoc) < 0;

		final flatShape: Doc = Concat([Text(open), openInside, condDoc, closeInside, Text(close)]);
		// `Nest(cols, [Line('\n'), condDoc])` puts BOTH the post-open
		// hardline AND `condDoc` itself at the bumped indent base
		// (outer+cols). Inner break engines that emit their own
		// `Nest(cols, …)` therefore inherit the bumped base — call-arg
		// continuation lands at outer+2cols (matching fork's `WrapPClose`
		// `+1` paren indent + call-arg's own `+1`). Chains
		// (opBoolChain / opAddSubChain) participate via the
		// `_chainModeOverride` channel: the chain dispatch suppresses its
		// own `Nest(cols, …)` when an override is active so its breaks
		// land at outer+cols (operator-led illusion), not at
		// outer+2cols. See `BinaryChainEmit.emit`'s `nestSuppress`
		// argument and the macro-emitted call site in `WriterLowering`.
		final brkShape: Doc = Concat([
			Text(open),
			Nest(cols, Concat([Line('\n'), condDoc])),
			Line('\n'),
			Text(close),
		]);

		// ω-condition-wrap-keep: a `WrapMode.Keep` condition whose source
		// placed a newline right after the open paren (`if (\n\tcond`) breaks
		// the cond onto its own line verbatim — `brkShape` reproduces BOTH the
		// post-`(` break AND the `)` on its own line. Without this, the
		// width-driven decision below glues `if (cond` whenever the cond fits
		// flat (or returns the chain's own hardline-bearing flat shape via the
		// `hasHardline` branch), dropping the author's structural break. Gated
		// on `rules.defaultMode == Keep` so every other wrap mode (and the
		// non-bearing default `sourceOpenNewline == false`) is byte-inert. The
		// inner chain self-breaks via the already-landed chain source-newline
		// mechanism (`BinaryChainEmit.shapeKeep`), so `condDoc` already carries
		// the `&& operand` continuation breaks — `brkShape`'s `Nest(cols)` just
		// indents them under the bumped base. Pre-empts the `hasHardline` and
		// `isTopLevelChain` branches below, both of which would otherwise glue.
		if (sourceOpenNewline && rules.defaultMode == WrapMode.Keep) return WrapBoundary(brkShape);

		inline function decideAt(exceeds: Bool): WrapMode {
			return decideWithLineLengthState(rules, 1, condW, condW, exceeds, hasHardline, t -> t == opt.lineWidth && exceeds);
		}

		// Only `FillLineWithLeadingBreak` materialises the leading +
		// trailing hardlines around the cond — other wrap modes
		// (`OnePerLine`, `OnePerLineAfterFirst`, `FillLine`) keep the
		// open/close glued to the cond and rely on the cond's own
		// internal break engines (opBoolChain, call-arg wrap, …) for
		// per-operand layout. `NoWrap` and unmodelled modes fall back
		// to flat. This narrow ⟂-modes match keeps the slice net-
		// positive — every other mode acts as a no-op until a future
		// slice models its specific shape.
		inline function shapeFor(mode: WrapMode): Doc {
			return mode == FillLineWithLeadingBreak ? brkShape : flatShape;
		}

		// A hardline cond whose break comes from a TRAILING container (array /
		// object / call that leading-breaks after its open delimiter) keeps the
		// paren GLUED (`for (x in [\n...\n])`, `if ([\n...\n].has(x))`, fork
		// parity) instead of opening `(\n\tcond\n)`. A top-level `&&`/`||`/`+`/`-`
		// chain still OPENS even when its last operand ends in a container (fork
		// wraps the chain, not the paren) -- so only a NON-chain cond takes the
		// glue probe, mirroring the non-hardline path's `isTopLevelChain &&
		// !chainKeepFlatCandidate` split. Non-FLWLB modes stay flat-glued.
		if (hasHardline) {
			final hlMode: WrapMode = decideAt(true);
			final chainOpens: Bool = isTopLevelChain(condDoc) && !chainKeepFlatCandidate(condDoc);
			return WrapBoundary(
				hlMode == FillLineWithLeadingBreak && !chainOpens
					? IfNaturalFirstLineFitsOpenDelim(opt.lineWidth, brkShape, flatShape)
					: shapeFor(hlMode)
			);
		}

		final modeFlat: WrapMode = decideAt(false);
		final modeBreak: WrapMode = decideAt(true);
		final flatBrk: Bool = modeFlat == FillLineWithLeadingBreak;
		final breakBrk: Bool = modeBreak == FillLineWithLeadingBreak;
		// ω-cond-plaincall-open: a no-keep-flat top-level chain (plain-call /
		// nested-paren absorber; an arrow-lambda absorber stays a keep-flat
		// candidate and takes the natural-first-line probe below) opens the cond
		// paren on a genuine full-line overflow. `IfLineExceeds` measures
		// `col + (cond)` plus the rest-of-stack lookahead, whose `restNodeWidth`
		// BodyGroup arm counts a cuddled block body's ` {` prefix and aborts at
		// the body's own hardline — so a `if (cond) {` header exactly one column
		// past the limit opens (its `{` was the missing column), while the
		// else-if tail past the body hardline stays invisible to the probe.
		// `lineWidth + 1`: the probe fires on `>= n` while the fork opens on
		// a strict `> maxLineLength` — a line landing exactly ON the limit
		// stays glued.
		return flatBrk == breakBrk
			? WrapBoundary(shapeFor(modeFlat))
			: isTopLevelChain(condDoc) && !chainKeepFlatCandidate(condDoc)
				? WrapBoundary(IfLineExceeds(opt.lineWidth + 1, shapeFor(modeBreak), shapeFor(modeFlat)))
				: WrapBoundary(IfNaturalFirstLineFitsOpenDelim(opt.lineWidth + 1, shapeFor(modeBreak), shapeFor(modeFlat)));
	}

	/**
	 * True iff `d`'s OWN outermost wrap level carries a binary-operator
	 * separator (`+` / `-` / `||` / `&&`) — i.e. `d` is a top-level binary
	 * chain whose own operators break, rather than a delimiter-bounded
	 * construct (call / array / prefix-call) whose inner args break one
	 * level deeper. The `BinaryChainEmit` output wraps the whole chain in a
	 * single `WrapBoundary`, so the chain's top-level operators sit at
	 * `WrapBoundary` depth 1; a `WrapList.emit` call/array wraps its args
	 * in their own `WrapBoundary`, putting any operand operators at depth ≥ 2.
	 * Mirror of `isPureOpAddSubChain`'s depth-tracking walk but answers the
	 * coarser "any top-level operator at depth 1" question used by the
	 * cond-paren-glued discriminator in `emitCondition`.
	 */
	// ω-ternary-paren-glue (composite, ternary_collapse_after_opadd): true iff
	// the inner's TOP-LEVEL (WrapBoundary depth 1) operator separators are
	// ternary `?`/`:` and NO `+`/`-`/`||`/`&&` appears at that level. Mirrors
	// isTopLevelChain's depth-1 walk; routes a ternary-inner expr-paren to the
	// keep-`(`-glued shape instead of the IfFullLineExceeds open when expressionWrapping is at its universal default; a fillLine-family mode opens the paren (fork parity).
	public static function isTopLevelTernary(d: Doc): Bool {
		var ternary: Bool = false;
		var other: Bool = false;
		function w(n: Doc, depth: Int): Void {
			if (depth > 1) return;
			switch n {
				case Group(i) | BodyGroup(i) | GroupWithRestProbe(i) | Nest(_, i) | Flatten(i) | HardFlatten(i) | CollapseProbe(i) | CollapseAddProbe(
					i
				) | ConditionalMarkerZero(i) | ConditionalMarkerDecrease(i):
					w(i, depth);
				case WrapBoundary(i):
					w(i, depth + 1);
				case IfBreak(b, _) | IfWidthExceeds(_, b, _) | IfFirstLineExceeds(_, b, _) | IfLineExceeds(_, b, _) | IfResidualLineExceeds(
					_, b, _
				) | IfFullLineExceeds(_, b, _) | IfNaturalFirstLineExceeds(_, b, _) | IfNaturalFirstLineFitsOpenDelim(_, b, _) | IfArrowContinuationFits(
					_, _, _, b, _
				):
					w(b, depth);
				case Concat(items):
					for (it in items) w(it, depth);
				case Fill(items, sep, _) | FillWithRestProbe(items, sep, _) | FillBreakAfterWrap(items, sep, _):
					w(sep, depth);
					for (it in items) w(it, depth);
				case Text(t):
					if (depth == 1) switch StringTools.trim(t) {
						case '?' | ':':
							ternary = true;
						case '+' | '-' | '||' | '&&':
							other = true;
						case _:
					}
				case _:
			}
		}
		w(d, 0);
		return ternary && !other;
	}

	/**
	 * Returns the de-duplicated set of `LineLengthLargerThan` thresholds
	 * appearing in `rules.rules` whose value differs from `lineWidth`.
	 * Thresholds equal to `lineWidth` collapse to the `exceeds` semantic
	 * (handled by the standard `IfBreak` pivot) and are filtered out.
	 *
	 * Public so chain-emit consumers (`BinaryChainEmit`) can build the
	 * same threshold-aware Doc tree on top of the cascade evaluator
	 * variants `decideWithLineLengthState` / `decideRuleWithLineLengthState`.
	 */
	public static function collectExtraLineLengthThresholds(rules: WrapRules, lineWidth: Int): Array<Int> {
		final out: Array<Int> = [];
		for (rule in rules.rules) {
			for (cond in rule.conditions) {
				if (cond.cond == LineLengthLargerThan && cond.value != lineWidth && out.indexOf(cond.value) < 0) out.push(cond.value);
			}
		}
		return out;
	}

	/**
	 * Walks the rules cascade and returns the first matching mode.
	 * `LineLengthLargerThan` evaluation is deferred to the caller-
	 * supplied `lineLengthFires` predicate so consumers can enumerate
	 * cascade outcomes across (exceeds, lineLength-firing) state
	 * combinations and route the threshold answer through the renderer's
	 * column-aware `IfWidthExceeds` probe at layout time. Falls back to
	 * `rules.defaultMode` when no rule matches.
	 *
	 * Used by `emit`, `BinaryChainEmit.emit`, and `MethodChainEmit.emit`
	 * — the three callers that build threshold-aware Doc trees on top
	 * of this evaluator (slice ω-ifwidthexceeds-infra +
	 * ω-methodchain-threshold-aware).
	 */
	public static function decideWithLineLengthState(
		rules: WrapRules, itemCount: Int, maxItemLen: Int, totalItemLen: Int, exceedsMaxLineLength: Bool, hasMultilineItems: Bool,
		lineLengthFires: Int -> Bool
	): WrapMode {
		for (rule in rules.rules) {
			if (matchesWithLineLengthState(
				rule, itemCount, maxItemLen, totalItemLen, exceedsMaxLineLength, hasMultilineItems, lineLengthFires
			))
				return rule.mode;
		}
		return rules.defaultMode;
	}

	/**
	 * ω-keep-fnsig-newline: width-independent Keep predicate for the trivia
	 * source-newline-preservation path (`WriterLowering.triviaSepStarExpr`'s
	 * `_keepEmit` gate). The trivia branch decides whether to reproduce each
	 * element's source `newlineBefore` BEFORE per-element Docs (and thus
	 * rendered widths) exist, so it cannot consult the column-aware cascade
	 * the no-trivia `emit` path uses. This resolves the cascade for the known
	 * `itemCount` (= element count) across BOTH the fits and exceeds states
	 * (and both `lineLengthFires` outcomes, paired with the exceeds probe);
	 * returns `true` only when EVERY probed state yields `Keep`. That is
	 * exactly the set of configs whose Keep decision is width-independent:
	 *  - `defaultWrap: keep` with `rules: []` (e.g.
	 *    `issue_238_keep_wrapping_function_signature`) — `decide*` falls
	 *    through to `defaultMode == Keep` in every state.
	 *  - a structural rule such as `itemCount >= 0 -> keep` (e.g.
	 *    `wrapping_of_function_signature_keep`) — matches in every state.
	 * A genuinely width-conditional rule (`lineLength >= 140 -> keep`)
	 * disagrees across the probes and correctly returns `false`, so the
	 * trivia path does NOT force keep when the source-layout intent is
	 * actually gated on rendered width — that case stays on the legacy
	 * cascade. Item-length / total-length conditions cannot be evaluated
	 * pre-render either, so they are probed as "not firing"; no current
	 * function-signature keep fixture uses them.
	 */
	public static function cascadeIsKeep(rules: WrapRules, itemCount: Int): Bool {
		inline function at(exceeds: Bool): WrapMode {
			return decideWithLineLengthState(rules, itemCount, 0, 0, exceeds, false, _ -> exceeds);
		}
		return at(false) == WrapMode.Keep && at(true) == WrapMode.Keep;
	}

	/**
	 * Walks the cascade and returns the matched rule's `mode` paired with
	 * its effective `location` (`BeforeLast` / `AfterLast`), so chain-emit
	 * consumers can render per-rule operator placement. `LineLengthLargerThan`
	 * evaluation is deferred to the caller-supplied `lineLengthFires`
	 * predicate so the threshold answer can route through the renderer's
	 * column-aware `IfWidthExceeds` probe at layout time.
	 *
	 * Location resolution: `rule.location ?? rules.defaultLocation ??
	 * WrappingLocation.AfterLast` — mirrors haxe-formatter's `WrapRules.defaultLocation`
	 * typedef default.
	 *
	 * Used by `BinaryChainEmit.emit` to enumerate cascade outcomes
	 * across (exceeds, lineLength-firing) state combinations.
	 */
	public static function decideRuleWithLineLengthState(
		rules: WrapRules, itemCount: Int, maxItemLen: Int, totalItemLen: Int, exceedsMaxLineLength: Bool, hasMultilineItems: Bool,
		lineLengthFires: Int -> Bool
	): { mode: WrapMode, location: WrappingLocation } {
		final fallback: WrappingLocation = rules.defaultLocation ?? WrappingLocation.AfterLast;
		for (rule in rules.rules) {
			if (matchesWithLineLengthState(
				rule, itemCount, maxItemLen, totalItemLen, exceedsMaxLineLength, hasMultilineItems, lineLengthFires
			))
				return { mode: rule.mode, location: rule.location ?? fallback };
		}
		return { mode: rules.defaultMode, location: fallback };
	}

	/**
	 * Walks a `Doc` tree and returns its flat-mode width in columns.
	 * Returns `-1` when the tree contains a forced hardline
	 * (`Line` whose flat replacement starts with `\n`) — those trees
	 * cannot be laid out in flat mode at all and the caller should
	 * pick a break-mode shape unconditionally.
	 */
	public static function flatLength(d: Doc): Int {
		final stack: Array<Doc> = [d];
		var total: Int = 0;
		while (stack.length > 0) {
			final node: Doc = stack.pop();
			if (flatPushChildren(node, stack)) continue;
			final contribution: Int = flatLeafLen(node);
			if (contribution < 0) return -1;
			total += contribution;
		}
		return total;
	}

	/**
	 * Returns `true` if `d`, when laid out in break mode, would emit a
	 * forced hardline (`Line('\n')` or `OptHardline`) before any
	 * non-newline content. Walks the leftmost spine: descends through
	 * `Nest`/`Group`/`BodyGroup`, picks the break branch of `IfBreak`,
	 * and skips leading transparent nodes (`Empty` / `Concat([])`).
	 *
	 * Mirrors `flatLength`'s "forced hardline" convention — soft
	 * `Line(' ')` / `Line('')` and `OptSpace(_)` answer `false` (a soft
	 * line in break mode emits `\n` but is flat-flattenable, so it
	 * doesn't qualify as a "starts with hardline" signal). Distinct
	 * from `hasLeadingHardline` (private) which is FillLine-mode-only
	 * and returns `false` for `IfBreak` unconditionally; this variant
	 * descends into the break branch because its caller renders in
	 * break mode.
	 *
	 * Used by macro-generated paren-wrap (`@:wrap(open, close)` on an
	 * enum ctor) to gate "trailing hardline before close": when the
	 * inner Doc opens with a forced hardline (e.g. `BinaryChainEmit`'s
	 * `OnePerLine` shape — every operand on its own line including
	 * the first), the wrap renders the close delimiter on its own line
	 * at the outer indent, matching haxe-formatter's `return !(\n…\n)`
	 * shape on issue_187_oneline. When the inner does NOT start with a
	 * hardline (e.g. `OnePerLineAfterFirst` keeps the first operand
	 * inline with the open delim), the wrap stays glued — matches the
	 * default-cascade `((items[0]\n\t…\n\titems[n-1]))` shape on
	 * issue_187_multi_line_wrapped_assignment.
	 */
	public static function startsWithHardline(d: Doc): Bool {
		var node: Doc = d;
		while (true) switch node {
			case Empty | Text(_) | OptSpace(_) | OptSpaceSkipAfterHardline:
				return false;
			case Line(flat):
				return flat.length > 0 && StringTools.fastCodeAt(flat, 0) == '\n'.code;
			case OptHardline | OptHardlineSkipAtOpenDelim | OptHardlineSkipBeforeHardline:
				// All three opt-hardline variants count as a leading
				// hardline for the wrap-engine `(...)` shape decision.
				// Their render-time drops are emit-time decisions; the
				// structural answer here stays "yes, inner has a leading
				// break point" so the wrap still places close on its own
				// line.
				return true;
			case Nest(_, inner) | Group(inner) | BodyGroup(inner) | GroupWithRestProbe(inner):
				node = inner;
			case IfBreak(brk, _):
				node = brk;
			case IfWidthExceeds(_, brk, _):
				node = brk;
			case IfFirstLineExceeds(_, brk, _):
				node = brk;
			case IfLineExceeds(_, brk, _) | IfResidualLineExceeds(_, brk, _):
				node = brk;
			case IfFullLineExceeds(_, brk, _):
				node = brk;
			case IfNaturalFirstLineExceeds(_, brk, _) | IfNaturalFirstLineFitsOpenDelim(_, brk, _) | IfArrowContinuationFits(
				_, _, _, brk, _
			):
				// Break-side leading-edge walk: descend the break branch
				// (mirrors the If*Exceeds siblings).
				node = brk;
			case Concat(items):
				final first: Null<Doc> = items.find(it -> !isLeadingTransparent(it));
				if (first == null) return false;
				node = first;
			case Fill(items, _, _) | FillWithRestProbe(items, _, _) | FillBreakAfterWrap(items, _, _):
				final first: Null<Doc> = items.find(it -> !isLeadingTransparent(it));
				if (first == null) return false;
				node = first;
			case Flatten(inner) | WrapBoundary(inner) | HardFlatten(inner) | CollapseProbe(inner) | CollapseAddProbe(inner) | CollapseBoolProbe(
				inner
			) | CollapseChainProbe(inner):
				// ω-force-flat-engine slice A: pass-through. Render-time
				// state — leading-hardline detection sees the marker's
				// `inner` as if no wrapper were present.
				node = inner;
			case ConditionalMarkerZero(inner):
				// ω-cond-indent-policy FixedZero: render-time marker,
				// transparent — descend `inner` for leading-hardline detection.
				node = inner;
			case ConditionalMarkerDecrease(inner):
				// ω-cond-indent-policy AlignedDecrease: render-time marker,
				// transparent — descend `inner` for leading-hardline detection.
				node = inner;
		}
	}

	/**
	 * ω-expr-paren-in-condition (cond F2): returns the fillLine-family
	 * `WrapMode` an `expressionWrapping` cascade WOULD produce when its
	 * content overflows, or `null` when the cascade never fillLine-wraps.
	 *
	 * The fork applies `expressionWrapping` (fillLineWithLeadingBreak) to
	 * an expression paren whose content exceeds the line; anyparse routes
	 * an in-condition expr paren through the `expressionParenHardFlatten`
	 * branch (HardFlatten → inner chain collapsed flat). When the
	 * configured `expressionWrappingWrap` cascade has a fillLine-family
	 * rule (or default), this surfaces that mode so the cond-emit site can
	 * thread it as a `_chainModeOverride` into the in-condition paren's
	 * inner chain — making the inner chain wrap fillLine instead of
	 * collapsing flat. Returns `null` for the universal default
	 * (`{rules: [], defaultMode: NoWrap}`) so every default-config
	 * consumer is byte-inert.
	 */
	public static function effectiveExpressionWrapMode(rules: WrapRules): Null<WrapMode> {
		inline function isFill(m: WrapMode): Bool return m == FillLine || m == FillLineWithLeadingBreak;
		if (isFill(rules.defaultMode)) return rules.defaultMode;
		final fillRule: Null<WrapRule> = rules.rules.find(r -> isFill(r.mode));
		return fillRule != null ? fillRule.mode : null;
	}

	/**
	 * True iff `d`'s first rendered visible token is an open delimiter
	 * (`(` / `[` / `{`) — i.e. the construct is a paren-expression / call /
	 * array / object literal whose open bracket leads. Left-spine walk that
	 * descends through transparent render wrappers and the flat side of every
	 * render-decision (`Group` / `If*`), skipping leading whitespace
	 * fragments. O(left-spine), no re-measure.
	 *
	 * Used by the generic non-chain infix emit (ω-binop-open-delim-glue) to
	 * keep the operator GLUED (`a * (chain)`) when its right operand opens a
	 * delimiter that will absorb the line break inside its own brackets —
	 * mirrors the fork, where `*` / `/` / `%` / compare / shift / bitwise /
	 * `is` / `??` are NEVER wrap-marked (`MarkWrapping` wrap-marks only
	 * `OpAdd` / `OpLt` type-param / `OpArrow`), so the operator never breaks;
	 * only its bracketed operand does. Structural sister of
	 * `startsWithHardline` (this checks the FLAT leading edge for an open
	 * delim; that checks the BREAK leading edge for a hardline).
	 */
	public static function startsWithOpenDelim(d: Doc): Bool {
		var node: Doc = d;
		while (true) switch node {
			case Empty | Line(_) | OptSpace(_) | OptSpaceSkipAfterHardline | OptHardline | OptHardlineSkipAtOpenDelim
				| OptHardlineSkipBeforeHardline:
				return false;
			case Text(s):
				return s.length > 0
					&& (StringTools.fastCodeAt(s, 0) == '('.code || StringTools.fastCodeAt(s, 0) == '['.code
						|| StringTools.fastCodeAt(s, 0) == '{'.code);
			case Nest(_, inner) | Group(inner) | BodyGroup(inner) | GroupWithRestProbe(inner) | Flatten(inner) | WrapBoundary(inner) | HardFlatten(
				inner
			) | CollapseProbe(inner) | CollapseAddProbe(inner) | CollapseBoolProbe(inner) | CollapseChainProbe(inner) | ConditionalMarkerZero(
				inner
			) | ConditionalMarkerDecrease(inner):
				node = inner;
			case IfBreak(_, flat) | IfWidthExceeds(_, _, flat) | IfFirstLineExceeds(_, _, flat) | IfLineExceeds(_, _, flat) | IfResidualLineExceeds(
				_, _, flat
			) | IfFullLineExceeds(_, _, flat) | IfNaturalFirstLineExceeds(_, _, flat) | IfNaturalFirstLineFitsOpenDelim(_, _, flat) | IfArrowContinuationFits(
				_, _, _, _, flat
			):
				node = flat;
			case Concat(items):
				final first: Null<Doc> = items.find(it -> !isLeadingTransparent(it));
				if (first == null) return false;
				node = first;
			case Fill(items, _, _) | FillWithRestProbe(items, _, _) | FillBreakAfterWrap(items, _, _):
				final first: Null<Doc> = items.find(it -> !isLeadingTransparent(it));
				if (first == null) return false;
				node = first;
		}
	}

	/**
	 * True iff `d`'s last rendered visible token is a close delimiter
	 * (`)` / `]` / `}`) — i.e. the construct is a paren-expression / call /
	 * array / object literal / index access whose close bracket trails. The
	 * right-spine mirror of `startsWithOpenDelim`: descends through transparent
	 * render wrappers and the flat side of every render-decision (`Group` /
	 * `If*`), skipping trailing whitespace fragments, taking the LAST visible
	 * element of every `Concat` / `Fill`. O(right-spine), no re-measure.
	 *
	 * Used by the generic non-chain infix emit (ω-binop-close-delim-glue) to
	 * keep a never-wrap-marked operator (`*` / `/` / `%` / compare / shift /
	 * bitwise / `is` / `??`) GLUED to its LEFT operand's close-paren line
	 * (`[…].indexOf(x) < 0`) when that operand opens a delimiter that absorbs
	 * the line break inside its own brackets. Without it, the legacy
	 * `Group(Line)` over-breaks the operator (`].indexOf(x)\n\t< 0`) once the
	 * left operand's bracket wraps and injects a committed hardline. Mirrors the
	 * fork: compare ops are never wrap-marked, so they ride the close-delim line.
	 */
	public static function endsWithCloseDelim(d: Doc): Bool {
		var node: Doc = d;
		while (true) switch node {
			case Empty | Line(_) | OptSpace(_) | OptSpaceSkipAfterHardline | OptHardline | OptHardlineSkipAtOpenDelim
				| OptHardlineSkipBeforeHardline:
				return false;
			case Text(s):
				if (s.length == 0) return false;
				final c: Int = StringTools.fastCodeAt(s, s.length - 1);
				return c == ')'.code || c == ']'.code || c == '}'.code;
			case Nest(_, inner) | Group(inner) | BodyGroup(inner) | GroupWithRestProbe(inner) | Flatten(inner) | WrapBoundary(inner) | HardFlatten(
				inner
			) | CollapseProbe(inner) | CollapseAddProbe(inner) | CollapseBoolProbe(inner) | CollapseChainProbe(inner) | ConditionalMarkerZero(
				inner
			) | ConditionalMarkerDecrease(inner):
				node = inner;
			case IfBreak(_, flat) | IfWidthExceeds(_, _, flat) | IfFirstLineExceeds(_, _, flat) | IfLineExceeds(_, _, flat) | IfResidualLineExceeds(
				_, _, flat
			) | IfFullLineExceeds(_, _, flat) | IfNaturalFirstLineExceeds(_, _, flat) | IfNaturalFirstLineFitsOpenDelim(_, _, flat) | IfArrowContinuationFits(
				_, _, _, _, flat
			):
				node = flat;
			case Concat(items):
				final last: Null<Doc> = findLastNonTrailingTransparent(items);
				if (last == null) return false;
				node = last;
			case Fill(items, _, _) | FillWithRestProbe(items, _, _) | FillBreakAfterWrap(items, _, _):
				final last: Null<Doc> = findLastNonTrailingTransparent(items);
				if (last == null) return false;
				node = last;
		}
	}

	/**
	 * True iff the LAST rendered `Text` atom of `d` ends with a decimal digit
	 * (`0`-`9`). Mirrors `endsWithCloseDelim`'s Doc-tail walk, changing only
	 * the terminal predicate. Used by the interval writer to reproduce
	 * haxe-formatter's LEXICAL fused `IntInterval` rule: a decimal digit that
	 * directly abuts `...` in source (`0...n`, `i + 1...len`) lexes as one
	 * tight token, so the operator stays tight regardless of `intervalPolicy`;
	 * any other left-operand tail is a binary `OpInterval` honouring the
	 * policy.
	 */
	public static function endsWithDecimalDigit(d: Doc): Bool {
		var node: Doc = d;
		while (true) switch node {
			case Empty | Line(_) | OptSpace(_) | OptSpaceSkipAfterHardline | OptHardline | OptHardlineSkipAtOpenDelim
				| OptHardlineSkipBeforeHardline:
				return false;
			case Text(s):
				if (s.length == 0) return false;
				final c: Int = StringTools.fastCodeAt(s, s.length - 1);
				return c >= '0'.code && c <= '9'.code;
			case Nest(_, inner) | Group(inner) | BodyGroup(inner) | GroupWithRestProbe(inner) | Flatten(inner) | WrapBoundary(inner) | HardFlatten(
				inner
			) | CollapseProbe(inner) | CollapseAddProbe(inner) | CollapseBoolProbe(inner) | CollapseChainProbe(inner) | ConditionalMarkerZero(
				inner
			) | ConditionalMarkerDecrease(inner):
				node = inner;
			case IfBreak(_, flat) | IfWidthExceeds(_, _, flat) | IfFirstLineExceeds(_, _, flat) | IfLineExceeds(_, _, flat) | IfResidualLineExceeds(
				_, _, flat
			) | IfFullLineExceeds(_, _, flat) | IfNaturalFirstLineExceeds(_, _, flat) | IfNaturalFirstLineFitsOpenDelim(_, _, flat) | IfArrowContinuationFits(
				_, _, _, _, flat
			):
				node = flat;
			case Concat(items):
				final last: Null<Doc> = findLastNonTrailingTransparent(items);
				if (last == null) return false;
				node = last;
			case Fill(items, _, _) | FillWithRestProbe(items, _, _) | FillBreakAfterWrap(items, _, _):
				final last: Null<Doc> = findLastNonTrailingTransparent(items);
				if (last == null) return false;
				node = last;
		}
	}

	/**
	 * True iff `d` is a binary-op chain whose TOP-LEVEL separators are all
	 * `+` / `-` (opAddSub), with no top-level `||` / `&&` / `?` / `:`. The
	 * walk descends through transparent render wrappers and the chain's own
	 * `Group`/`IfBreak`/`Fill` cascade, collecting operator-text separators,
	 * but does NOT recurse into operand sub-chains (`WrapBoundary` marks a
	 * sub-chain/operand boundary in the `BinaryChainEmit` output). A chain
	 * with no operator separators at all (single operand) is NOT a pure
	 * opAddSub chain.
	 */
	public static function isPureOpAddSubChain(d: Doc, multIsOther: Bool = false): Bool {
		// Operator separators recorded per WrapBoundary depth. The chain's
		// own top-level separators sit at the SHALLOWEST depth that has any
		// operator (the chain emit wraps its whole output in a WrapBoundary,
		// so the chain level is depth >= 1; operand sub-chains nest deeper).
		// The TOP-LEVEL operator class is the operator set at that minimum
		// depth — nested operand ops at deeper levels are irrelevant.
		var addSubDepth: Int = -1;
		var otherDepth: Int = -1;
		function record(isAdd: Bool, depth: Int): Void {
			if (isAdd) {
				if (addSubDepth < 0 || depth < addSubDepth) addSubDepth = depth;
			} else {
				if (otherDepth < 0 || depth < otherDepth) otherDepth = depth;
			}
		}
		function w(n: Doc, depth: Int): Void {
			switch n {
				case Group(i) | BodyGroup(i) | GroupWithRestProbe(i) | Nest(_, i) | Flatten(i) | HardFlatten(i) | CollapseProbe(i) | CollapseAddProbe(
					i
				) | ConditionalMarkerZero(i) | ConditionalMarkerDecrease(i):
					w(i, depth);
				case WrapBoundary(i):
					w(i, depth + 1);
				case IfBreak(b, f) | IfWidthExceeds(_, b, f) | IfFirstLineExceeds(_, b, f) | IfLineExceeds(_, b, f) | IfResidualLineExceeds(
					_, b, f
				) | IfFullLineExceeds(_, b, f) | IfNaturalFirstLineExceeds(_, b, f) | IfNaturalFirstLineFitsOpenDelim(_, b, f) | IfArrowContinuationFits(
					_, _, _, b, f
				):
					// Both branches of a chain cascade carry the same
					// separators; walk only the break branch to avoid
					// double-counting.
					w(b, depth);
				case Concat(items):
					for (it in items) w(it, depth);
				case Fill(items, sep, _) | FillWithRestProbe(items, sep, _) | FillBreakAfterWrap(items, sep, _):
					w(sep, depth);
					for (it in items) w(it, depth);
				case Text(t):
					switch StringTools.trim(t) {
						case '+' | '-': record(true, depth);
						case '||' | '&&' | '?' | ':':
							record(false, depth);
						// ω-opadd-trailing-paren-break: opt-in — a `*`/`/`/`%` at a
						// shallower depth marks the top level as opMult, so a paren
						// wrapping `(b - c) * s` is NOT a pure opAddSub sub-chain (the
						// nested `-` would otherwise falsely qualify it).
						case '*' | '/' | '%' if (multIsOther): record(false, depth);
						case _:
					}
				case _:
			}
		}
		w(d, 0);
		// Pure opAddSub iff an add/sub separator exists and no other-class
		// separator appears at the SAME-OR-SHALLOWER depth (the chain's top
		// level is opAddSub; any `||`/`&&`/`?`/`:` at that level disqualifies).
		return addSubDepth >= 0 && (otherDepth < 0 || otherDepth > addSubDepth);
	}

	/**
	 * Normal-path 0-extra-threshold tree: the cascade collapses to the
	 * legacy 2-state shape. When flat (`exceeds=false`) and break
	 * (`exceeds=true`) resolve to the SAME mode, `emitZeroThresholdAgree`
	 * picks the unconditional shape (with the sole-arrow paren-break
	 * probe); when they disagree, the outer `Group(IfBreak(...))` lets
	 * the renderer's own `fitsFlat` choose (routed through
	 * `groupOrRestProbe` for `@:fmt(groupRestProbe)` consumers).
	 */
	private static function emitZeroThreshold(
		rules: WrapRules, items: Array<Doc>, opt: WriteOptions, cols: Int, open: String, close: String, openInside: Doc, closeInside: Doc,
		forceMode: Null<WrapMode>, groupRestProbe: Bool, leadFlat: Doc, leadBreak: Doc, evalAt: (Bool, Array<Int>) -> WrapMode,
		shapeAt: (WrapMode, Doc) -> Doc, leadFor: WrapMode -> Doc
	): Doc {
		final modeFlat: WrapMode = evalAt(false, []);
		final modeBreak: WrapMode = evalAt(true, []);
		if (modeFlat == modeBreak)
			return emitZeroThresholdAgree(
				modeFlat, rules, items, opt, cols, open, close, openInside, closeInside, forceMode, leadFlat, leadBreak, shapeAt, leadFor
			);
		final flatWithLead: Doc = shapeAt(modeFlat, leadFlat);
		final breakWithLead: Doc = shapeAt(modeBreak, leadBreak);
		// ω-group-rest-probe cascade-disagree: when the cascade resolves
		// to different modes at flat (`exceeds=false`) vs break
		// (`exceeds=true`), the outer Group's own `fitsFlat` decides
		// which branch the renderer commits to. A plain `Group` measures
		// only the wrap construct's flat width from its column — blind to
		// same-line content trailing AFTER the close delim. When the
		// Star opted into `@:fmt(groupRestProbe)`, route through
		// `GroupWithRestProbe` so the fit decision subtracts
		// `flatTokenWidthOfRestStack` (the trailing `):Void {}` after a
		// wrapped anon param type, etc.) — matching fork's `lengthAfter`
		// bias at the cascade-Group layer. Sister to the agree-path
		// `groupOrRestProbe` in `shapeFillLine`. Every current
		// `groupRestProbe` consumer (functionSignatureWrap empty-rules /
		// typeParameterWrap exceeds-independent rules) resolves both
		// states identically and never reaches this branch, so the only
		// behavioural change is for cascades whose NoWrap rule is gated
		// on `ExceedsMaxLineLength` (anonTypeWrap) — byte-inert elsewhere.
		return WrapBoundary(groupOrRestProbe(IfBreak(breakWithLead, flatWithLead), groupRestProbe));
	}

	/**
	 * 0-threshold AGREE case (`modeFlat == modeBreak`): the cascade
	 * commits to one mode. The legacy collapse returns it
	 * unconditionally — except when both states resolve to `NoWrap`
	 * while the cascade `defaultMode` is a break mode, in which case the
	 * flat collapse is blind to the call-prefix column: a short arg that
	 * fits the `noWrap` rule may still overflow `maxLineLength` at its
	 * actual column. There the first rendered line is probed instead —
	 * break the call paren (default-mode shape) iff the glued flat line
	 * exceeds `lineWidth`, else keep it glued (fork
	 * `MarkWrappingBase.determineWrapType2`). Paren-param arrows
	 * (`isArrowBodyMarker`) and `forceMode` callers are excluded; a sole
	 * bare-ident infix arrow whose body chain breaks glues its head and
	 * breaks after `->` (ω-thinarrow-break leg-3).
	 */
	private static function emitZeroThresholdAgree(
		modeFlat: WrapMode, rules: WrapRules, items: Array<Doc>, opt: WriteOptions, cols: Int, open: String, close: String,
		openInside: Doc, closeInside: Doc, forceMode: Null<WrapMode>, leadFlat: Doc, leadBreak: Doc, shapeAt: (WrapMode, Doc) -> Doc,
		leadFor: WrapMode -> Doc
	): Doc {
		// ω-iffirstline-callarg: both states resolve to `NoWrap`
		// (the cascade's NoWrap rules shadow a break `defaultMode`),
		// so the legacy collapse commits flat — blind to the call-
		// prefix column. A short single arg whose flat width fits
		// the cascade's `noWrap` rule still overflows `maxLineLength`
		// at its actual column, leaving the call paren glued
		// (under-wrap). When the shadowed default is a break mode,
		// probe the first rendered line instead: break the paren
		// (default-mode shape) iff the glued flat line exceeds
		// `lineWidth`, else keep it glued. Mirrors fork's
		// `MarkWrappingBase.determineWrapType2` — break the call
		// paren iff the collapsed flat line at its column exceeds
		// `maxLineLength`, keeping the inner arg flat. Arrow lambdas
		// own a dedicated wrap path (`isArrowBodyMarker`), so the
		// sole-arrow case is excluded — the generic paren-break
		// shape conflicts with `applyArrowWrapping`'s break-after-
		// `->` layout. `forceMode != null` already bypasses the
		// cascade, so it is excluded too.
		final dm: WrapMode = rules.defaultMode;
		final dmBreak: Bool = dm == OnePerLine || dm == OnePerLineAfterFirst || dm == FillLine || dm == FillLineWithLeadingBreak;
		final soleArrow: Bool = items.length == 1 && isArrowBodyMarker(items[0]);
		if (modeFlat == NoWrap && dmBreak && forceMode == null && !soleArrow) {
			// ω-thinarrow-break leg-3: a sole bare-ident infix arrow
			// (`call(item -> body)`) whose body chain BREAKS (leg-2
			// `bareArrowBodyBreaks` — e.g. an `||` opBoolChain configured to
			// fillLine on overflow) glues the arrow HEAD to the open paren
			// and breaks AFTER `->`, instead of the generic open-paren shape
			// (`call(\n\titem -> body\n)`). The INVERSE of `isArrowBodyMarker`
			// (paren-param) handling above — paren-param arrows are excluded
			// (`isArrowBodyMarker(items[0])` ⇒ `soleArrow`), so only the
			// bare-ident infix path reaches here. Mirrors fork
			// `applyArrowWrapping` (MarkWrapping.hx:2336-2378) + the single-
			// arg call `hasInnerBreak` gate.
			//
			// Block-body bare arrows are excluded (body's first visible Text is
			// `{`): the block owns its own multi-line layout, matching fork's
			// BrOpen skip in `applyArrowWrapping`'s collapse loop.
			//
			// Two nested render-time first-line probes (both O(1)
			// `flatTokenWidthFirstLine`, no recursive spine probe across the
			// chain — PERF safe):
			//  - OUTER `IfFirstLineExceeds(lineWidth, brk, flat)`: break iff
			//    the whole-flat `call(item -> body)` first line overflows.
			//  - INNER `IfFirstLineExceeds(lineWidth, openShape, glueShape)`:
			//    within the break branch, fall back to the generic open-paren
			//    shape iff the GLUED head line `call(item ->` itself overflows
			//    (fork `firstLineLen > maxLen → continue`); else GLUE.
			if (items.length == 1) {
				final split: Null<{ head: Doc, body: Doc }> = bareArrowSplit(items[0]);
				if (split != null && !firstVisibleTextStartsWith(split.body, '{'.code) && bareArrowBodyBreaks(split.body)) {
					final openShape: Doc = shapeAt(dm, leadBreak);
					final flatShape: Doc = shapeAt(NoWrap, leadFlat);
					final glueShape: Doc = bareArrowGlueShape(open, close, openInside, closeInside, split.head, split.body, cols);
					final brk: Doc = IfFirstLineExceeds(opt.lineWidth, openShape, glueShape);
					return WrapBoundary(IfFirstLineExceeds(opt.lineWidth, brk, flatShape));
				}
			}
			return WrapBoundary(IfFirstLineExceeds(opt.lineWidth, shapeAt(dm, leadBreak), shapeAt(NoWrap, leadFlat)));
		}
		return WrapBoundary(shapeAt(modeFlat, leadFor(modeFlat)));
	}

	/**
	 * Normal-path 1-extra-threshold tree (impossibility-filtered, 3
	 * shapes). `t < lineWidth`: `col+w<t` implies `!exceeds`, so the
	 * only valid states are (∅,no) / ({t},no) / ({t},yes) → outer
	 * `IfWidthExceeds` then an `IfBreak` on the crossed side. `t >
	 * lineWidth`: `col+w>=t` implies `exceeds`, so the valid states are
	 * (∅,no) / (∅,yes) / ({t},yes) → outer `IfBreak` then an inner
	 * `IfWidthExceeds` on the exceeds side.
	 */
	private static function emitOneThreshold(
		t: Int, opt: WriteOptions, evalAt: (Bool, Array<Int>) -> WrapMode, shapeAt: (WrapMode, Doc) -> Doc, leadFor: WrapMode -> Doc
	): Doc {
		if (t < opt.lineWidth) {
			// 3 valid states (col+w<t implies col+w<lineWidth implies !exceeds):
			//   (firing=∅,    exceeds=no)  → modeNN
			//   (firing={t},  exceeds=no)  → modeYN
			//   (firing={t},  exceeds=yes) → modeYY
			final modeNN: WrapMode = evalAt(false, []);
			final modeYN: WrapMode = evalAt(false, [t]);
			final modeYY: WrapMode = evalAt(true, [t]);
			final shapeNN: Doc = shapeAt(modeNN, leadFor(modeNN));
			final shapeYN: Doc = shapeAt(modeYN, leadFor(modeYN));
			final shapeYY: Doc = shapeAt(modeYY, leadFor(modeYY));
			if (modeNN == modeYN && modeYN == modeYY) return WrapBoundary(shapeNN);
			// Inner IfBreak picks between exceeds-yes and exceeds-no
			// when the column has already crossed `t`. Outer
			// IfWidthExceeds picks the column-vs-t answer first; the
			// flat side bypasses the IfBreak entirely (only one
			// valid state below `t`).
			final brk: Doc = (modeYY == modeYN) ? shapeYY : Group(IfBreak(shapeYY, shapeYN));
			return WrapBoundary(Group(IfWidthExceeds(t, brk, shapeNN)));
		}
		// t > lineWidth: 3 valid states (col+w>=t implies col+w>=lineWidth):
		//   (firing=∅,    exceeds=no)  → modeNN
		//   (firing=∅,    exceeds=yes) → modeNY
		//   (firing={t},  exceeds=yes) → modeYY
		final modeNN: WrapMode = evalAt(false, []);
		final modeNY: WrapMode = evalAt(true, []);
		final modeYY: WrapMode = evalAt(true, [t]);
		final shapeNN: Doc = shapeAt(modeNN, leadFor(modeNN));
		final shapeNY: Doc = shapeAt(modeNY, leadFor(modeNY));
		final shapeYY: Doc = shapeAt(modeYY, leadFor(modeYY));
		if (modeNN == modeNY && modeNY == modeYY) return WrapBoundary(shapeNN);
		// Outer IfBreak picks exceeds=no/yes; inner IfWidthExceeds
		// further partitions the exceeds=yes side around `t`.
		final brk: Doc = (modeNY == modeYY) ? shapeYY : Group(IfWidthExceeds(t, shapeYY, shapeNY));
		return WrapBoundary(Group(IfBreak(brk, shapeNN)));
	}

	/**
	 * Decoupled flat-width measurement of the item list
	 * (ω-flatlength-decouple-tokenwidth). `flatLength(item) < 0` retains
	 * its legacy semantic and drives `anyHardline` — preserving the
	 * break-commit shortcut on items with a hardline anywhere (including
	 * inside `BodyGroup`). `DocMeasure.flatTokenWidth(item)` feeds clean
	 * widths to the cascade rule conditions, mirroring `Renderer.fitsFlat`'s
	 * BG-defer so `LineLengthLargerThan` / `TotalItemLengthLargerThan` /
	 * `AnyItemLengthLargerThan` see the same widths the renderer lays out
	 * flat. Each non-last item adds `sepWidth` (`sep.length + 1`): fork
	 * extends each non-last `endToken` to include the trailing comma and
	 * its `spacesAfter`, and the renderer always pairs the bare `sep` with
	 * a flat-mode space — so the effective per-gap width is `sep.length + 1`
	 * (closes `wrapping/issue_494_type_parameter`).
	 */
	private static function measureItems(items: Array<Doc>, sepWidth: Int): { total: Int, maxLen: Int, anyHardline: Bool } {
		var total: Int = 0;
		var maxLen: Int = 0;
		var anyHardline: Bool = false;
		final lastIdx: Int = items.length - 1;
		for (i in 0...items.length) {
			final item: Doc = items[i];
			if (flatLength(item) < 0) anyHardline = true;
			final rawW: Int = DocMeasure.flatTokenWidth(item);
			final w: Int = i < lastIdx ? rawW + sepWidth : rawW;
			total += w;
			if (w > maxLen) maxLen = w;
		}
		return { total: total, maxLen: maxLen, anyHardline: anyHardline };
	}

	/**
	 * Continuation-indent depth (in columns) for break-mode shapes
	 * (`Nest(cols, …)`). Two indent regimes coexist:
	 *   - **Cascade-forced break** (`OnePerLine` / `OnePerLineAfterFirst`
	 *     / `FillLineWithLeadingBreak`): the cascade injects its own
	 *     hardlines; fork's `calcIndent + additionalIndent` lands at
	 *     `outer-block-indent + additional` tabs, so `Nest` adds
	 *     `additional` units only (the outer `Nest` stack contributes the
	 *     `calcIndent` portion).
	 *   - **Fit-driven / trivia-driven** (`NoWrap` / `FillLine`): hardlines
	 *     come from trivia-preserved source breaks or `Fill`'s break-on-
	 *     overflow; fork positions those at `calcIndent + 1 + additional`
	 *     (the paren-bump `+1`), matched by `baseCols * (1 + additional)`.
	 * The probe mode is evaluated at `exceeds=true / firing=∅` before
	 * threshold enumeration — a heuristic that does not cover cascades
	 * combining `defaultAdditionalIndent > 0` with `LineLengthLargerThan`
	 * thresholds (no current consumer does). ω-functionsignature-body-aware-
	 * indent: `compactContinuation` (from `opt._fnSigBodyEmpty`) extends the
	 * `additional`-only regime to FillLine / NoWrap when the wrapped
	 * signature is followed by an empty / absent body.
	 */
	private static function continuationCols(
		rules: WrapRules, opt: WriteOptions, items: Array<Doc>, maxLen: Int, total: Int, anyHardline: Bool, sourceMultilineKeep: Bool,
		compactContinuation: Bool
	): Int {
		final baseCols: Int = opt.indentChar == IndentChar.Space ? opt.indentSize : opt.tabWidth;
		final additional: Int = rules.defaultAdditionalIndent ?? 0;
		final probeMode: WrapMode = floorSourceMultiline(
			decideWithLineLengthState(rules, items.length, maxLen, total, true, anyHardline, _ -> false), sourceMultilineKeep
		);
		final cascadeForcesBreak: Bool = probeMode == OnePerLine || probeMode == OnePerLineAfterFirst
			|| probeMode == FillLineWithLeadingBreak;
		final compactCont: Bool = cascadeForcesBreak || compactContinuation;
		return baseCols * (compactCont && additional > 0 ? additional : 1 + additional);
	}

	private static function isTopLevelChain(d: Doc): Bool {
		var found: Bool = false;
		function w(n: Doc, depth: Int): Void {
			if (found || depth > 1) return;
			switch n {
				case Group(i) | BodyGroup(i) | GroupWithRestProbe(i) | Nest(_, i) | Flatten(i) | HardFlatten(i) | CollapseProbe(i) | CollapseAddProbe(
					i
				) | ConditionalMarkerZero(i) | ConditionalMarkerDecrease(i):
					w(i, depth);
				case WrapBoundary(i):
					w(i, depth + 1);
				case IfBreak(b, _) | IfWidthExceeds(_, b, _) | IfFirstLineExceeds(_, b, _) | IfLineExceeds(_, b, _) | IfResidualLineExceeds(
					_, b, _
				) | IfFullLineExceeds(_, b, _) | IfNaturalFirstLineExceeds(_, b, _) | IfNaturalFirstLineFitsOpenDelim(_, b, _):
					w(b, depth);
				case Concat(items):
					for (it in items) w(it, depth);
				case Fill(items, sep, _) | FillWithRestProbe(items, sep, _) | FillBreakAfterWrap(items, sep, _):
					w(sep, depth);
					for (it in items) w(it, depth);
				case Text(t):
					if (depth == 1) switch StringTools.trim(t) {
						case '+' | '-' | '||' | '&&':
							found = true;
						case _:
					}
				case _:
			}
		}
		w(d, 0);
		return found;
	}

	/**
	 * True iff `d`'s outermost wrap level is a chain that emitted the
	 * keep-flat probe `IfNaturalFirstLineFitsOpenDelim` (its flat mode
	 * was `NoWrap` — see `BinaryChainEmit.emit` ω-chain-keep-flat). Such
	 * a chain no longer hides behind a `Group(IfBreak)` break-branch, so
	 * the natural-first-line measurer sees its full flat NoWrap shape and
	 * the cond-paren decision can glue when the chain's 2nd operand
	 * absorbs the overflow into its own inner call/paren. Used by
	 * `emitCondition` to skip the legacy `IfLineExceeds` route for such
	 * chains (which would otherwise always open the cond paren on the
	 * full flat width). Pure stack walk to the first `WrapBoundary` child.
	 */
	private static function chainKeepFlatCandidate(d: Doc): Bool {
		var found: Bool = false;
		function w(n: Doc, depth: Int): Void {
			if (found || depth > 1) return;
			switch n {
				case Group(i) | BodyGroup(i) | GroupWithRestProbe(i) | Nest(_, i) | Flatten(i) | HardFlatten(i) | CollapseProbe(i) | CollapseAddProbe(
					i
				) | ConditionalMarkerZero(i) | ConditionalMarkerDecrease(i):
					w(i, depth);
				case WrapBoundary(i):
					w(i, depth + 1);
				case IfNaturalFirstLineFitsOpenDelim(_, _, _):
					if (depth == 1) found = true;
				case Concat(items):
					for (it in items) w(it, depth);
				case _:
			}
		}
		w(d, 0);
		return found;
	}

	/**
	 * Recursive helper that builds the IfWidthExceeds + IfBreak tree
	 * for the cascade-with-thresholds layout. `forcedExceeds`:
	 *   - `true` → emit a single shape at each leaf (no IfBreak —
	 *     parent commits to break-mode regardless of column).
	 *     Used by the `anyHardline || forceExceeds` path.
	 *   - `null` → enumerate `exceeds=false` / `exceeds=true` at each
	 *     leaf and split via `Group(IfBreak(…))` when the resolved
	 *     modes differ (existing 2-state pivot).
	 * `firing` accumulates thresholds chosen as "fired" along the
	 * brk-side recursion. No impossibility filtering — renderer's
	 * column probe at each `IfWidthExceeds` layer is monotone, so the
	 * impossible-state leaves are unreachable at runtime regardless.
	 */
	private static function buildThresholdTree(
		thresholds: Array<Int>, firing: Array<Int>, forcedExceeds: Null<Bool>, leadFlat: Doc, leadBreak: Doc,
		evalAt: (Bool, Array<Int>) -> WrapMode, shapeAt: (WrapMode, Doc) -> Doc, leadFor: WrapMode -> Doc
	): Doc {
		if (thresholds.length == 0) {
			if (forcedExceeds != null) {
				final mode: WrapMode = evalAt(forcedExceeds, firing);
				return shapeAt(mode, leadFor(mode));
			}
			final modeFlat: WrapMode = evalAt(false, firing);
			final modeBreak: WrapMode = evalAt(true, firing);
			if (modeFlat == modeBreak) return shapeAt(modeFlat, leadFor(modeFlat));
			final flatWithLead: Doc = shapeAt(modeFlat, leadFlat);
			final breakWithLead: Doc = shapeAt(modeBreak, leadBreak);
			return Group(IfBreak(breakWithLead, flatWithLead));
		}
		final t: Int = thresholds[0];
		final rest: Array<Int> = thresholds.slice(1);
		final firingPlus: Array<Int> = firing.copy();
		firingPlus.push(t);
		final brk: Doc = buildThresholdTree(rest, firingPlus, forcedExceeds, leadFlat, leadBreak, evalAt, shapeAt, leadFor);
		final flat: Doc = buildThresholdTree(rest, firing, forcedExceeds, leadFlat, leadBreak, evalAt, shapeAt, leadFor);
		return IfWidthExceeds(t, brk, flat);
	}

	private static function matchesWithLineLengthState(
		rule: WrapRule, itemCount: Int, maxItemLen: Int, totalItemLen: Int, exceedsMaxLineLength: Bool, hasMultilineItems: Bool,
		lineLengthFires: Int -> Bool
	): Bool {
		for (cond in rule.conditions) {
			final ok: Bool = switch cond.cond {
				case ItemCountLargerThan: itemCount >= cond.value;
				case ItemCountLessThan: itemCount <= cond.value;
				case AnyItemLengthLargerThan: maxItemLen >= cond.value;
				case AllItemLengthsLessThan: maxItemLen <= cond.value;
				case TotalItemLengthLargerThan: totalItemLen >= cond.value;
				case TotalItemLengthLessThan: totalItemLen <= cond.value;
				case ExceedsMaxLineLength: cond.value == 0 ? !exceedsMaxLineLength : exceedsMaxLineLength;
				case LineLengthLargerThan: lineLengthFires(cond.value);
				case HasMultilineItems: cond.value == 0 ? !hasMultilineItems : hasMultilineItems;
				case _: false;
			};
			if (!ok) return false;
		}
		return true;
	}

	/**
	 * Container arms of the `flatLength` walk: push each descendant
	 * Doc onto `stack` and return `true`. Returns `false` for the
	 * length-contributing leaves, which `flatLength` routes to
	 * `flatLeafLen`. The `If*Exceeds` arms forward to the FLAT side —
	 * the column-aware decision happens at render time, not in static
	 * walks (mirrors the `IfBreak` arm). The `Flatten` / collapse /
	 * conditional-marker wrappers are render-time state, transparent
	 * to static length measurement, so descend `inner`.
	 */
	private static function flatPushChildren(node: Doc, stack: Array<Doc>): Bool {
		switch (node) {
			case Nest(_, inner):
				stack.push(inner);
			case Concat(items):
				var i: Int = items.length;
				while (--i >= 0) stack.push(items[i]);
			case Group(inner) | BodyGroup(inner) | GroupWithRestProbe(inner):
				stack.push(inner);
			case IfBreak(_, flatDoc):
				stack.push(flatDoc);
			case IfWidthExceeds(_, _, flatDoc):
				stack.push(flatDoc);
			case IfFirstLineExceeds(_, _, flatDoc):
				stack.push(flatDoc);
			case IfLineExceeds(_, _, flatDoc) | IfResidualLineExceeds(_, _, flatDoc):
				stack.push(flatDoc);
			case IfFullLineExceeds(_, _, flatDoc):
				stack.push(flatDoc);
			case IfNaturalFirstLineExceeds(_, _, flatDoc) | IfNaturalFirstLineFitsOpenDelim(_, _, flatDoc) | IfArrowContinuationFits(
				_, _, _, _, flatDoc
			):
				stack.push(flatDoc);
			case Fill(items, sep, _) | FillWithRestProbe(items, sep, _) | FillBreakAfterWrap(items, sep, _):
				var k: Int = items.length;
				while (k > 0) {
					k--;
					stack.push(items[k]);
					if (k > 0) stack.push(sep);
				}
			case Flatten(inner) | WrapBoundary(inner) | HardFlatten(inner) | CollapseProbe(inner) | CollapseAddProbe(inner) | CollapseBoolProbe(
				inner
			) | CollapseChainProbe(inner):
				stack.push(inner);
			case ConditionalMarkerZero(inner):
				stack.push(inner);
			case ConditionalMarkerDecrease(inner):
				stack.push(inner);
			case _:
				return false;
		}
		return true;
	}

	/**
	 * Leaf arms of the `flatLength` walk: the flat-mode byte width a
	 * node contributes, or `-1` to signal an un-flattenable node
	 * (a hardline `Line('\n')` or any opt-hardline variant) so the
	 * caller commits the wrap engine to break mode. `OptSpace` /
	 * `OptSpaceSkipAfterHardline` count their width-1 byte because a
	 * flat layout always renders them (mirrors `Renderer.fitsFlat`);
	 * the runtime drop only fires after a hardline, which can never
	 * hold inside a flat-shape probe. `Empty` and any non-leaf node
	 * fall to the `0` default.
	 */
	private static function flatLeafLen(node: Doc): Int {
		return switch (node) {
			case Text(s): s.length;
			case Line(flat):
				flat.length > 0 && StringTools.fastCodeAt(flat, 0) == '\n'.code ? -1 : flat.length;
			case OptSpace(s): s.length;
			case OptSpaceSkipAfterHardline: 1;
			case OptHardline | OptHardlineSkipAtOpenDelim | OptHardlineSkipBeforeHardline: -1;
			case _: 0;
		};
	}

	/**
	 * True iff `d`'s first visible Text leaf starts with a COLLECTION open
	 * delimiter — `[` (array literal) or `{` (object / map literal). The
	 * narrower sibling of `startsWithOpenDelim`: that matches `(` too (paren-
	 * expr / call), this restricts to the two literal-collection brackets.
	 * Used by the multi-arg-trailing-collection glue intercept in `shape()` to
	 * recognise a trailing array / object-literal arg (whose internal break the
	 * call head can absorb at the open paren) while excluding a trailing paren-
	 * expr or call arg. Same left-spine descent through transparent render
	 * wrappers + the flat side of every render-decision. O(left-spine), no
	 * re-measure.
	 */
	public static function startsWithCollectionDelim(d: Doc): Bool {
		var node: Doc = d;
		while (true) switch node {
			case Empty | Line(_) | OptSpace(_) | OptSpaceSkipAfterHardline | OptHardline | OptHardlineSkipAtOpenDelim
				| OptHardlineSkipBeforeHardline:
				return false;
			case Text(s):
				return s.length > 0 && (StringTools.fastCodeAt(s, 0) == '['.code || StringTools.fastCodeAt(s, 0) == '{'.code);
			case Nest(_, inner) | Group(inner) | BodyGroup(inner) | GroupWithRestProbe(inner) | Flatten(inner) | WrapBoundary(inner) | HardFlatten(
				inner
			) | CollapseProbe(inner) | CollapseAddProbe(inner) | CollapseBoolProbe(inner) | CollapseChainProbe(inner) | ConditionalMarkerZero(
				inner
			) | ConditionalMarkerDecrease(inner):
				node = inner;
			case IfBreak(_, flat) | IfWidthExceeds(_, _, flat) | IfFirstLineExceeds(_, _, flat) | IfLineExceeds(_, _, flat) | IfResidualLineExceeds(
				_, _, flat
			) | IfFullLineExceeds(_, _, flat) | IfNaturalFirstLineExceeds(_, _, flat) | IfNaturalFirstLineFitsOpenDelim(_, _, flat) | IfArrowContinuationFits(
				_, _, _, _, flat
			):
				node = flat;
			case Concat(items):
				final first: Null<Doc> = items.find(it -> !isLeadingTransparent(it));
				if (first == null) return false;
				node = first;
			case Fill(items, _, _) | FillWithRestProbe(items, _, _) | FillBreakAfterWrap(items, _, _):
				final first: Null<Doc> = items.find(it -> !isLeadingTransparent(it));
				if (first == null) return false;
				node = first;
		}
	}

	/**
	 * Returns the index of the SOLE multi-line arg in `items` when that arg's
	 * multi-line-ness is owned by a breaking array literal — either the arg IS the
	 * array (`startsWithCollectionDelim`) OR the array is nested and is the arg's
	 * FIRST break (`firstBreakIsArrayDelim` — `new X([\n … \n], y)` / `f([\n …
	 * \n])`) — AND `flatLength < 0`, while EVERY other arg renders single-line
	 * (`flatLength >= 0`); else -1.
	 *
	 * The multi-arg-collection-glue intercept's structural predicate: gluing all
	 * args inline is a valid fixed point ONLY when exactly one arg breaks and it
	 * is (or is built around) the array — the other (flat) args then ride the
	 * open-paren line (before it) or the array's close line (after it). A second
	 * multi-line arg, or a multi-line arrow / method-chain / paren-expr arg, would
	 * place a break in a spot the all-inline glue can't absorb, so we bail (-1). A
	 * nested-array arg is a valid fixed point only because its head up to `[` is
	 * flat and its tail after `]` is flat too — `firstBreakIsArrayDelim` stops at
	 * the FIRST line break, so a chain-owned bracket (reached past a soft break) is
	 * refused.
	 *
	 * `flatLength(item) < 0` short-circuits on the first hardline per arg (no full
	 * re-measure); the scan is O(Σ arg spines up to first hardline).
	 */
	private static function soleMultilineCollectionArg(items: Array<Doc>): Int {
		var collIdx: Int = -1;
		for (i in 0...items.length) if (flatLength(items[i]) < 0) {
			// A second multi-line arg, or a multi-line arg that is not a plain
			// breaking collection — the all-inline glue is not a fixed point.
			if (collIdx >= 0) return -1;
			final it: Doc = items[i];
			if (isArrowBodyMarker(it) || isMethodChainItem(it) || !(startsWithCollectionDelim(it) || firstBreakIsArrayDelim(it))) return -1;
			collIdx = i;
		}
		return collIdx;
	}

	/**
	 * Last element of `items` that is not a trailing-transparent fragment
	 * (whitespace / opt-hardline), scanning from the end. Right-spine sister of
	 * the `items.find(it -> !isLeadingTransparent(it))` head scan.
	 */
	private static function findLastNonTrailingTransparent(items: Array<Doc>): Null<Doc> {
		var i: Int = items.length - 1;
		while (i >= 0) {
			final it: Doc = items[i];
			if (!isLeadingTransparent(it)) return it;
			i--;
		}
		return null;
	}

	/**
	 * Wrap `body` with `lead` unless `lead` is `Empty` — avoids a
	 * pointless single-element `Concat` for the common no-lead path.
	 */
	private static inline function prependLead(body: Doc, lead: Doc): Doc {
		return switch lead {
			case Empty: body;
			case _: Concat([lead, body]);
		};
	}

	/**
	 * Classifies a `WrapMode` as single-line (`NoWrap`) vs multi-line
	 * (`OnePerLine`, `OnePerLineAfterFirst`, `FillLine`, …). Used by
	 * `emit` to pick `leadFlat` vs `leadBreak` when the cascade
	 * collapses to a single mode and no `Group(IfBreak)` wrap is
	 * emitted. `FillLine` counts as multi-line by intent — its inner
	 * `Group` decides per-item fit but the construct as a whole opts
	 * into wrapped layout.
	 */
	private static inline function isFlatMode(mode: WrapMode): Bool {
		return switch mode {
			case NoWrap: true;
			case _: false;
		};
	}

	/**
	 * ω-array-reflow: when `on` is set (the caller threaded
	 * `@:fmt(reflowSourceMultiline)`'s runtime `_smlKeep` gate), a cascade
	 * resolution of `NoWrap` is floored to `OnePerLine`. The source list
	 * already spans multiple lines, so collapsing it fully flat would
	 * discard the author's "stay multi-line" intent; flooring keeps the
	 * list broken while still letting width-driven modes (`FillLine`,
	 * `FillLineWithLeadingBreak`) reflow it. No-op when `on` is false — gate-less consumers stay byte-identical.
	 */
	private static inline function floorSourceMultiline(mode: WrapMode, on: Bool): WrapMode {
		return on && mode == NoWrap ? OnePerLine : mode;
	}

	private static function shape(
		mode: WrapMode, open: String, close: String, sep: String, items: Array<Doc>, openInside: Doc, closeInside: Doc, cols: Int,
		appendTrailingComma: Bool, trailBreak: Doc, groupRestProbe: Bool, sepBeforeFlags: Null<Array<Bool>>, lineWidth: Int,
		sourceBreakBefore: Null<Array<Bool>> = null, keepCloseGlued: Bool = false,
		// ω-nowrap-source-trail-comma: source-only trailing-comma signal for the
		// FLAT (`NoWrap`) layout. Distinct from `appendTrailingComma` (= source
		// `<field>TrailPresent` OR per-construct knob): the knob forces break-mode
		// + a comma on the broken last element, but must NOT add a comma to a
		// single-line flat list whose source had none. So the flat shape keys on
		// source presence alone. Default `false` keeps every non-threaded caller
		// byte-identical.
		flatTrailingComma: Bool = false
	): Doc {
		// ω-thinarrow-break if-else: a sole bare-ident arrow arg of a call / new-expr
		// (`f(p -> if … else …)`) whose body is an ALREADY-multiline if/else breaks
		// AFTER `->` with the enclosing `)` on its own line — regardless of the
		// cascade-resolved wrap mode. Without this the arg's internal hardline renders
		// hugged (`f(p -> if (…) {` … `})`), aligning `else` with the enclosing call
		// statement instead of nesting it in the lambda body. Mirrors fork
		// `applyArrowWrapping` + `isArrowBodyMultilineIfElse` (MarkWrapping.hx:2346/
		// 2401). Gated to `(`-delimited constructs (call / new); a plain `if` (no
		// else) / `switch` / `for` / `while` / `{ }`-block body has no top-level
		// `else` and stays hugged, preserving the landed block/statement-body hugs.
		// Only a BARE-ident arrow (`p -> …`, a leading-edge `Concat` recognised by
		// `bareArrowSplit`) is handled; a paren-param arrow (`(p) -> …`) lowers to a
		// `WrapBoundary` marker for which `bareArrowSplit` returns null, so it is
		// excluded and keeps its current layout.
		if (open == '(' && items.length == 1) {
			final ifElseSplit: Null<{ head: Doc, body: Doc }> = bareArrowSplit(items[0]);
			if (ifElseSplit != null && arrowBodyIsBrokenIfElse(ifElseSplit.body))
				return bareArrowGlueShape(open, close, openInside, closeInside, ifElseSplit.head, ifElseSplit.body, cols);
		}
		final comprBlockHug: Null<Doc> = shapeComprehensionBlockHug(open, close, items, openInside, closeInside);
		if (comprBlockHug != null) return comprBlockHug;
		final soleArrowUniform: Null<Doc> = shapeSoleArrowUniform(mode, open, close, openInside, closeInside, items);
		if (soleArrowUniform != null) return soleArrowUniform;
		final soleArrowContGlue: Null<Doc> = shapeSoleArrowContGlue(
			mode, open, close, sep, items, openInside, closeInside, cols, appendTrailingComma, lineWidth
		);
		if (soleArrowContGlue != null) return soleArrowContGlue;
		final singleArgGlue: Null<Doc> = shapeSingleArgGlue(
			mode, open, close, sep, items, openInside, closeInside, cols, appendTrailingComma, lineWidth
		);
		if (singleArgGlue != null) return singleArgGlue;
		final multiArgBlockLambda: Null<Doc> = shapeMultiArgBlockLambda(
			mode, open, close, sep, items, openInside, closeInside, cols, appendTrailingComma, sepBeforeFlags, lineWidth
		);
		if (multiArgBlockLambda != null) return multiArgBlockLambda;
		final multiArgCollection: Null<Doc> = shapeMultiArgCollection(
			mode, open, close, sep, items, openInside, closeInside, cols, appendTrailingComma, groupRestProbe, sepBeforeFlags,
			keepCloseGlued, lineWidth
		);
		return multiArgCollection
			?? shapeByMode(
				mode, open, close, sep, items, openInside, closeInside, cols, appendTrailingComma, trailBreak, groupRestProbe,
				sepBeforeFlags, sourceBreakBefore, keepCloseGlued, flatTrailingComma
			);
	}

	/**
	 * ω-inc5 sole-arrow uniform escalation: a call whose SOLE arg is an
	 * arrow lambda whose body wraps gets the SAME close-on-own-line +
	 * params-glued-to-open shape regardless of the cascade-resolved wrap
	 * mode. Without this intercept, FillLine routes to `shapeFillLine`
	 * (close glued to body) and FillLineWithLeadingBreak to
	 * `shapeFillLineWithLeadingBreak` (paren OPENS, arrow onto its own
	 * line) — both wrong. Mirrors fork's `applyArrowWrapping` (MarkWrapping
	 * .hx:1962), a late dedicated pass that overrides the generic call-arg
	 * wrap: arrow params + `->` stay glued to the open paren, body breaks,
	 * and `lineEndBefore(pClose)` puts the close paren on its own line.
	 *
	 * NoWrap path already did this via `shapeNoWrap`; this lifts the same
	 * `Group(IfBreak)` decision to the auto-overflow break modes FillLine
	 * and FillLineWithLeadingBreak. `applyArrowWrapping` overrides the
	 * config-driven call-arg wrap uniformly — even a `callParameter:
	 * fillLineWithLeadingBreak` config keeps the sole arrow glued to the
	 * open paren (`condition_chain_in_arrow_lambda`).
	 *
	 * Gates:
	 *  - NoWrap is excluded (already handled by `shapeNoWrap`; preserves the
	 *    baseline open-vs-glue split for `condition_wrapping_nested` /
	 *    `paren_indent_call`, both NoWrap).
	 *  - FillLineWithLeadingBreak additionally requires the body to
	 *    STRUCTURALLY break (`arrowBodyBreaks`): a single-expression body
	 *    that fits one continuation line keeps the generic open-paren shape,
	 *    mirroring fork `preferLambdaSignatureInlineOverWrap` (2986-2992,
	 *    cites `condition_wrapping_nested`/`paren_indent_call` by name).
	 *  - Block-body lambdas (`() -> { … }`) are excluded (`arrowBodyIsBlock`):
	 *    the block owns its own multi-line layout, close stays glued (`})`),
	 *    matching fork `applyArrowWrapping`'s `bodyFirst.match(BrOpen)` skip
	 *    (`issue_538`).
	 */
	private static function shapeSoleArrowUniform(
		mode: WrapMode, open: String, close: String, openInside: Doc, closeInside: Doc, items: Array<Doc>
	): Null<Doc> {
		return items.length == 1 && isArrowBodyMarker(items[0]) && !arrowBodyIsBlock(items[0])
			&& (mode == FillLine || (mode == FillLineWithLeadingBreak && arrowBodyBreaks(items[0])))
			? arrowBodyCloseParenShape(open, close, openInside, closeInside, items[0])
			: null;
	}

	/**
	 * ω-inc5-cont sole-arrow head-glue on continuation OVERFLOW: a FLWLB sole-
	 * arrow whose body does NOT structurally break (single expression) but
	 * would OVERFLOW its continuation line. inc5 only glued the head for
	 * structurally-multiline bodies (`arrowBodyBreaks`); a single-expression
	 * body that fits one continuation line keeps the OPEN-paren shape
	 * (`f(\n\t(p) -> body\n)` — `paren_indent_call`, `condition_wrapping_nested`),
	 * but one that overflows must glue the arrow head to the open paren and
	 * break the body (`f((p) ->\n\tbody\n)` — `lambda_wrapped_after_single_arg_collapse`).
	 * The discriminator is a CONTINUATION-INDENT width probe: the arrow's flat
	 * `(params) -> body` measured at `f.indent + cols` (NOT the open-paren
	 * column). `IfArrowContinuationFits` re-bases the measure there; flatWidth
	 * is the arrow item's column-independent flat token width (>= 0 since the
	 * body has no structural hardline here). Mirrors fork
	 * `preferLambdaSignatureInlineOverWrap`.
	 * The arrow BODY must not be a top-level binary chain (opBool / opAddSub /
	 * ternary): such a body, when it overflows, is the fork's condition-chain
	 * case (`condition_wrapping_nested_with_opbool` — the C1 family deferred
	 * from inc5) where fork OPENS the paren and puts the arrow on its own
	 * continuation line regardless of width. Head-glue is fork-correct only
	 * for a single non-chain body (call / method chain).
	 */
	private static function shapeSoleArrowContGlue(
		mode: WrapMode, open: String, close: String, sep: String, items: Array<Doc>, openInside: Doc, closeInside: Doc, cols: Int,
		appendTrailingComma: Bool, lineWidth: Int
	): Null<Doc> {
		if (
			mode == FillLineWithLeadingBreak && items.length == 1 && isArrowBodyMarker(items[0]) && !arrowBodyIsBlock(items[0])
			&& !arrowBodyBreaks(items[0])
		) {
			final body: Null<Doc> = arrowBodyDoc(items[0]);
			final arrowFlatWidth: Int = DocMeasure.flatTokenWidth(items[0]);
			if (arrowFlatWidth >= 0 && body != null && !isTopLevelChain(body)) {
				final glueShape: Doc = arrowBodyCloseParenShape(open, close, openInside, closeInside, items[0]);
				final openShape: Doc = shapeFillLineWithLeadingBreak(
					open, close, sep, items, openInside, closeInside, cols, appendTrailingComma
				);
				return IfArrowContinuationFits(cols, arrowFlatWidth, lineWidth, glueShape, openShape);
			}
		}
		return null;
	}

	/**
	 * ω-callparam-single-arg-glue PROTOTYPE: a FLWLB call whose SOLE arg is a
	 * non-arrow head ending at an open delim (`new X(` / `f(`) keeps the outer
	 * open paren GLUED to that head iff the arg's natural first line both fits
	 * and ends at an open delim; the inner construct self-breaks its own args.
	 * Method-chain args are EXCLUDED — their break is at a `.` dot (not an open
	 * delim), and the natural-first-line measurer diverges from render for a
	 * chain operand (the documented inc6/inc7 wall): glue would mis-keep the
	 * outer paren glued when the fork breaks it (`method_chain_single_arg_break_parens`).
	 */
	private static function shapeSingleArgGlue(
		mode: WrapMode, open: String, close: String, sep: String, items: Array<Doc>, openInside: Doc, closeInside: Doc, cols: Int,
		appendTrailingComma: Bool, lineWidth: Int
	): Null<Doc> {
		if (mode == FillLineWithLeadingBreak && items.length == 1 && !isArrowBodyMarker(items[0]) && !isMethodChainItem(items[0])) {
			final glued: Doc = Concat([Text(open), openInside, items[0], closeInside, Text(close)]);
			final broken: Doc = shapeFillLineWithLeadingBreak(open, close, sep, items, openInside, closeInside, cols, appendTrailingComma);
			// ω-callparam-single-objectlit: a sole OBJECT-LITERAL arg (`f({...})`)
			// leading-breaks with the object kept FLAT on its own indented line iff
			// the object fits there (fork keeps the object flat); if it exceeds its
			// own line it stays brace-hugged and its fields wrap (fork `({`-glued +
			// explode). Arrays / nested calls keep the open-delim-glue path below.
			if (firstVisibleTextStartsWith(items[0], '{'.code))
				return IfArrowContinuationFits(cols, DocMeasure.flatTokenWidth(items[0]), lineWidth, glued, broken);
			return IfNaturalFirstLineFitsOpenDelim(lineWidth, broken, glued);
		}
		return null;
	}

	/**
	 * ω-callparam-multiarg-block-lambda: a FLWLB MULTI-arg call ANY of whose args is a block-bodied paren-param lambda (`f((p) -> { … }, y)` / `f(x, () -> { … })`) keeps ALL args
	 * GLUED to the open paren iff the glued flat first line (up to the block
	 * `{`) fits `lineWidth`; the lambda's block body self-breaks at its `{` and
	 * the enclosing `)` glues to the block close (`});`). Without this, the
	 * cascade-resolved FLWLB shape OPENS the outer paren (`f(\n\tx, () -> {…`),
	 * pushing every arg + the whole body one indent deeper. Mirrors fork
	 * `applyArrowWrapping` (MarkWrapping.hx:2336-2356): the arrow head is
	 * collapsed (no break after `->`) when the head line fits, and the block
	 * body's own brace layout supplies the only break — the enclosing call paren
	 * is never opened. The `reEvaluateMultiArgCallParamAfterContextWraps` pass
	 * (713-748) then leaves the collapsed multi-arg call as-is.
	 *
	 * DISJOINT from the sole-arrow paths above (inc5 / inc5-cont / ThinArrow, all `items.length == 1`): this gates on `items.length > 1`, so sole-arrow handling is untouched. The block-body lambda may sit at ANY position (first / middle / last); trailing args ride the block-close line (`}, y)`), matching fork applyArrowWrapping, which collapses the arrow head regardless of arg position. The block-body discriminator is STRUCTURAL
	 * (`arrowBodyIsBlock` — the body's first visible Text is `{`), needing no
	 * post-layout "did it break" fact: a block with statements always carries
	 * hardlines.
	 *
	 * Render-time first-line probe (O(1) `flatTokenWidthFirstLine`, capped at
	 * the block-open hardline — NO recursive spine probe, PERF safe):
	 *  - `IfFirstLineExceeds(lineWidth, openShape, glueShape)`: glue iff the
	 *    GLUED head line `f(x, () -> {` fits; else fall back to the generic
	 *    open-paren FLWLB shape (`firstLineLen > maxLen → continue` in fork).
	 */
	private static function shapeMultiArgBlockLambda(
		mode: WrapMode, open: String, close: String, sep: String, items: Array<Doc>, openInside: Doc, closeInside: Doc, cols: Int,
		appendTrailingComma: Bool, sepBeforeFlags: Null<Array<Bool>>, lineWidth: Int
	): Null<Doc> {
		var hasBlockLambda: Bool = false;
		for (it in items) if ((isArrowBodyMarker(it) && arrowBodyIsBlock(it)) || isFunctionBlockLambdaItem(it)) {
			hasBlockLambda = true;
			break;
		}
		if (mode == FillLineWithLeadingBreak && items.length > 1 && hasBlockLambda) {
			final glueShape: Doc = multiArgBlockLambdaGlueShape(open, close, sep, items, openInside, closeInside, sepBeforeFlags);
			final openShape: Doc = shapeFillLineWithLeadingBreak(
				open, close, sep, items, openInside, closeInside, cols, appendTrailingComma
			);
			return IfFirstLineExceeds(lineWidth, openShape, glueShape);
		}
		return null;
	}

	/**
	 * ω-callparam-multiarg-collection-glue: a `FillLine` / FLWLB MULTI-arg call
	 * whose SOLE multi-line arg is a BREAKING collection literal (array `[…]` /
	 * object `{…}` whose first visible Text is `[`/`{` AND that carries an
	 * internal hardline → renders multi-line) keeps ALL args GLUED to the open
	 * paren iff the glued flat first line (up to the collection's own break)
	 * fits `lineWidth`; the collection self-breaks at its `[`/`{` and every
	 * other arg stays inline — the args before it on the open-paren line, the
	 * args after it glued onto the collection's close line (`f(a, [\n…\n], b)`).
	 *
	 * Without this, `shapeFillLine`'s outer `Group` aborts `fitsFlat` on the
	 * collection's internal hardline and commits MBreak, so the `Fill` breaks
	 * EVERY soft sep — ALL args open onto their own lines (`f(\n\ta,\n\t[\n…`).
	 * The glued fixed point (head + flat args inline, only the collection self-
	 * breaks) is only reached on a LATER write once the source already broke
	 * (the collection arg's own Doc shifts), so the writer OSCILLATES — write 1
	 * ≠ write 2. The break decision is SOURCE-DEPENDENT (incoming layout changes
	 * the collection arg's internal Doc → flips the outer Group), which is
	 * exactly the non-idempotence. This intercept replaces that source-blind
	 * Group decision with the deterministic `IfFirstLineExceeds` width probe, so
	 * the FIRST write already produces the glued fixed point.
	 *
	 * Sibling of the block-lambda intercept above: same
	 * `IfFirstLineExceeds(lineWidth, openShape, glueShape)` O(1) first-line
	 * width probe + reused `multiArgBlockLambdaGlueShape` (glue all items
	 * inline with `sep + ' '`; the lone multi-line collection self-breaks).
	 * `openShape` is the mode's own break shape (`shapeFillLine` /
	 * `shapeFillLineWithLeadingBreak`) — the unchanged fallback for a too-wide
	 * glued head. The discriminator is STRUCTURAL + spine-bounded:
	 *  - `items.length > 1` (DISJOINT from the single-arg / sole-arrow paths,
	 *    all `items.length == 1`);
	 *  - EXACTLY ONE arg renders multi-line (`flatLength(...) < 0`), and it is
	 *    a collection literal (first visible Text `[`/`{`, NOT `(` — a paren-
	 *    expr / call arg is excluded), NOT an arrow (block-lambda owns the
	 *    FLWLB gate above) and NOT a method chain (a chain breaks at a `.` dot,
	 *    not at an open delim — gluing would keep the paren glued where the
	 *    fork opens it, the documented inc6/inc7 chain-operand wall). Requiring
	 *    the collection to be the SOLE multi-line arg keeps the all-inline glue
	 *    a valid fixed point: every OTHER arg is flat, so it rides either the
	 *    open-paren line (before the collection) or the collection-close line
	 *    (after it). `flatLength` short-circuits on the first hardline per arg —
	 *    no full re-measure. The collection may sit at ANY position
	 *    (`docHelper('_dib', [\n…\n], macro …)` — the canonical churning site —
	 *    has it in the MIDDLE, not last).
	 */
	private static function shapeMultiArgCollection(
		mode: WrapMode, open: String, close: String, sep: String, items: Array<Doc>, openInside: Doc, closeInside: Doc, cols: Int,
		appendTrailingComma: Bool, groupRestProbe: Bool, sepBeforeFlags: Null<Array<Bool>>, keepCloseGlued: Bool, lineWidth: Int
	): Null<Doc> {
		if ((mode == FillLine || mode == FillLineWithLeadingBreak) && items.length > 1 && soleMultilineCollectionArg(items) >= 0) {
			final glueShape: Doc = multiArgBlockLambdaGlueShape(open, close, sep, items, openInside, closeInside, sepBeforeFlags);
			final openShape: Doc = mode == FillLineWithLeadingBreak
				? shapeFillLineWithLeadingBreak(open, close, sep, items, openInside, closeInside, cols, appendTrailingComma)
				: shapeFillLine(
					open, close, sep, items, openInside, closeInside, cols, appendTrailingComma, groupRestProbe, sepBeforeFlags,
					keepCloseGlued
				);
			return IfFirstLineExceeds(lineWidth, openShape, glueShape);
		}
		return null;
	}

	/**
	 * The cascade-resolved `WrapMode` dispatch — the tail of `shape` once
	 * every special-case glue intercept declined. Each mode routes to its
	 * dedicated `shape*` layout builder. `Keep` / `Ignore` are normally
	 * pre-empted by the writer's trivia branch (`triviaSepStarExpr`) and
	 * collapse to a sensible single-line fallback here; the `multiVar`
	 * `Keep` fold is the one path that threads `sourceBreakBefore` to
	 * reproduce each comma-link's source break via `shapeKeep`.
	 */
	private static function shapeByMode(
		mode: WrapMode, open: String, close: String, sep: String, items: Array<Doc>, openInside: Doc, closeInside: Doc, cols: Int,
		appendTrailingComma: Bool, trailBreak: Doc, groupRestProbe: Bool, sepBeforeFlags: Null<Array<Bool>>,
		sourceBreakBefore: Null<Array<Bool>>, keepCloseGlued: Bool, flatTrailingComma: Bool
	): Doc {
		return switch mode {
			case NoWrap: shapeNoWrap(open, close, sep, items, openInside, closeInside, sepBeforeFlags, flatTrailingComma);
			case OnePerLine: shapeOnePerLine(open, close, sep, items, cols, appendTrailingComma, trailBreak, sepBeforeFlags);
			case OnePerLineAfterFirst: shapeOnePerLineAfterFirst(open, close, sep, items, cols, appendTrailingComma, sepBeforeFlags);
			case FillLine: shapeFillLine(
				open, close, sep, items, openInside, closeInside, cols, appendTrailingComma, groupRestProbe, sepBeforeFlags, keepCloseGlued
			);
			case FillLineWithLeadingBreak:
				shapeFillLineWithLeadingBreak(open, close, sep, items, openInside, closeInside, cols, appendTrailingComma);
			// ω-keep-objectlit: Keep cascade hits are pre-empted by the
			// writer's trivia branch (`triviaSepStarExpr`) — at the engine
			// level, Keep collapses to NoWrap so any leakage produces a
			// sensible single-line layout instead of a crash. The Keep
			// emit shape lives at the writer, not the engine, because it
			// needs per-element `Trivial<T>.newlineBefore` access (already
			// rendered Docs lose that signal).
			//
			// ω-keep-newline-after-sep (increment 1): the multiVar fold
			// DOES carry the per-link source-break signal into the engine
			// via `sourceBreakBefore` (built from `Trivial.newlineAfterSep`).
			// When present, `shapeKeep` reproduces each comma-link's source
			// break; absent (every other Keep consumer) keeps the legacy
			// defensive `shapeNoWrap` glue so the change is byte-inert.
			case Keep:
				sourceBreakBefore != null
					? shapeKeep(open, close, sep, items, cols, appendTrailingComma, sourceBreakBefore)
					: shapeNoWrap(open, close, sep, items, openInside, closeInside, sepBeforeFlags, flatTrailingComma);
			// ω-cascade-emits-comments: Ignore is the sister policy on the
			// source-newline axis. Like Keep, the writer's trivia branch
			// pre-empts before reaching the engine — the cascade-emit
			// shape lives inside `triviaSepStarExpr` because it needs
			// per-element `Trivial<T>.leadingComments` / `trailingComment`
			// access. Defensive fallback so any leakage produces a
			// sensible single-line layout.
			case Ignore: shapeNoWrap(open, close, sep, items, openInside, closeInside, sepBeforeFlags, flatTrailingComma);
			case _: shapeNoWrap(open, close, sep, items, openInside, closeInside, sepBeforeFlags, flatTrailingComma);
		};
	}

	/**
	 * Returns `true` when `sepBeforeFlags[i]` is set, meaning
	 * the engine should skip the separator between items `[i-1]` and `i`.
	 * Null / out-of-bounds is treated as "do not skip".
	 */
	private static inline function skipSepBefore(flags: Null<Array<Bool>>, i: Int): Bool {
		return flags != null && i >= 0 && i < flags.length && flags[i];
	}

	/**
	 * ω-inc5: the sole-arrow-arg close-paren shape. `Group(IfBreak(close on
	 * its own line, close glued))` — the Group's `fitsFlat` walks the arrow's
	 * inline body (`IfLineExceeds.flat`), so MFlat fires iff the body fits at
	 * the column (close glued); else MBreak (close on its own line). The arrow
	 * params + `->` always stay glued to `open` in both branches. Mirrors fork
	 * `applyArrowWrapping`'s `lineEndBefore(pClose)`. Extracted from
	 * `shapeNoWrap`'s arrow escalation so every break mode reuses one shape.
	 */
	private static function arrowBodyCloseParenShape(open: String, close: String, openInside: Doc, closeInside: Doc, arrowItem: Doc): Doc {
		final flatShape: Doc = Concat([Text(open), openInside, arrowItem, closeInside, Text(close)]);
		final brkShape: Doc = Concat([Text(open), openInside, arrowItem, Line('\n'), closeInside, Text(close)]);
		// ω-arrow-residual-linewrap: couple the close `)` to the SAME residual
		// decision as the arrow body, driving BOTH from ONE `IfResidualLineExceeds`
		// so the arrow body AND the close `)` break together (fork's `arrow ->`
		// break + `lineEndBefore(pClose)` close-own-line), or both stay glued.
		// The decision node is placed AT THE ARROW BODY (after the `(params) ->`
		// head, via `coupledArrowItem`) so its flat/break boundary is IDENTICAL
		// to the arrow marker's own probe (same col, same `flatBody + close +
		// rest` width). At the open paren it over-measured by one column at the
		// exact-`lineWidth` boundary and broke a fitting `exists(arrow) ? a : b`
		// fork keeps inline. Block-body lambdas keep the legacy `Group(IfBreak)`
		// (whose `fitsFlat` defers the block `BodyGroup` to width 0) so the close
		// stays glued (`})`) — the block owns its own multi-line layout.
		if (arrowBodyIsBlock(arrowItem)) return Group(IfBreak(brkShape, flatShape));
		final coupled: Null<Doc> = coupledArrowItem(arrowItem, closeInside, close);
		return coupled != null ? Concat([Text(open), openInside, coupled]) : Group(IfBreak(brkShape, flatShape));
	}

	// ω-arrow-residual-linewrap: build the coupled arrow-body + close-paren shape.
	// Splits `arrowItem` into its glued head (`(params) ->`) and the trailing
	// arrow-body marker `WrapBoundary(IfResidualLineExceeds(n, brk, flat))`, then
	// re-emits ONE decision node at the body position whose flat side glues the
	// close (`flat close`) and whose break side puts the close on its own line
	// (`brk \n close`). Returns null when `arrowItem` carries no marker.
	// ω-arrow-residual-linewrap: return `item` with its trailing arrow-body marker
	// replaced by the coupled decision node (`coupledMarker`), or null when `item`
	// carries no marker. Recurses through a trailing `Concat` like the sibling
	// marker walkers (`arrowBodyDoc` / `arrowBodyIsBlock`).
	private static function coupledArrowItem(item: Doc, closeInside: Doc, close: String): Null<Doc> {
		switch item {
			case WrapBoundary(IfResidualLineExceeds(n, brk, fl)):
				return coupledMarker(n, brk, fl, closeInside, close);
			case Concat(arr) if (arr.length > 0):
				final sub: Null<Doc> = coupledArrowItem(arr[arr.length - 1], closeInside, close);
				if (sub == null) return null;
				final copy: Array<Doc> = arr.copy();
				copy[copy.length - 1] = sub;
				return Concat(copy);
			case _:
				return null;
		}
	}

	// ω-arrow-residual-linewrap: the single coupled decision node — flat glues the
	// close after the arrow's flat body, break puts the close on its own line
	// after the arrow's broken body. `WrapBoundary` preserves the marker's
	// force-flat reset.
	private static function coupledMarker(n: Int, brk: Doc, fl: Doc, closeInside: Doc, close: String): Doc {
		return WrapBoundary(IfResidualLineExceeds(
			n, Concat([brk, Line('\n'), closeInside, Text(close)]), Concat([fl, closeInside, Text(close)])
		));
	}

	// ω-inc5: does the arrow body's FLAT side carry a structural hardline
	// (multi-statement block / if-else-if chain) — i.e. the body wraps
	// regardless of width? Walks to the marker `IfResidualLineExceeds(_, _, flatBody)`
	// and reports `flatLength(flatBody) < 0`. Used to keep the generic open-paren
	// shape for a single-expression FLWLB body that fits one continuation line
	// (fork `preferLambdaSignatureInlineOverWrap` 2986-2992).
	private static function arrowBodyBreaks(item: Doc): Bool {
		return switch item {
			case WrapBoundary(IfResidualLineExceeds(_, _, flatBody)): flatLength(flatBody) < 0;
			case Concat(arr) if (arr.length > 0): arrowBodyBreaks(arr[arr.length - 1]);
			case _: false;
		};
	}

	// ω-inc5-cont: the arrow body's FLAT side (the marker's `flatBody`), or null
	// if `item` is not a recognized arrow-body marker. Used to inspect the body
	// shape (e.g. `isTopLevelChain`) when deciding head-glue.

	private static function arrowBodyDoc(item: Doc): Null<Doc> {
		return switch item {
			case WrapBoundary(IfResidualLineExceeds(_, _, flatBody)): flatBody;
			case Concat(arr) if (arr.length > 0): arrowBodyDoc(arr[arr.length - 1]);
			case _: null;
		};
	}

	// ω-inc5: true iff the arrow body (the marker's flat side) is a `{ }` block.
	// Fork's `preferLambdaSignatureInlineOverWrap` (2980-2981) and the close-
	// paren-own-line escalation EXPLICITLY skip block-body lambdas — the block
	// owns its own multi-line layout (open brace placed by the curly policy), so
	// the outer close paren stays glued (`})`, not `}\n)`). Walks to the marker's
	// flat body; the first visible content token of a block body is `{` (skipping
	// transparent wrappers, leading hardlines and OptSpace inserted by an
	// `anonFunctionCurly` newline policy).
	private static function arrowBodyIsBlock(item: Doc): Bool {
		return switch item {
			case WrapBoundary(IfResidualLineExceeds(_, _, flatBody)): firstVisibleTextStartsWith(flatBody, '{'.code);
			case Concat(arr) if (arr.length > 0): arrowBodyIsBlock(arr[arr.length - 1]);
			case _: false;
		};
	}

	// ω-thinarrow-break (ThinArrow break-after-`->` foundation): split a
	// bare-ident infix arrow item (`item -> body`, lowered by the Pratt path as
	// `Concat([head, Text(' '), Text('->'), OptSpace(' '), body])` — NOT the
	// paren-param `(params) -> body` `arrowBodyLineWrap` marker which carries its
	// own `_dwb(_dile(...))` shape) into `{head, body}` at the top-level `->`/`=>`
	// operator Text. `head` is every element up to AND including the operator
	// Text; `body` is the operand(s) after the OptSpace. Returns `null` when
	// `item` is not a recognisable bare-ident arrow Concat — pure structural
	// recogniser, byte-inert standalone (it only inspects). The OptSpace between
	// `->` and the body is dropped: leg-3's glue shape replaces it with a forced
	// `Line('\n')` (break AFTER `->`), so the inline space must not survive.
	private static function bareArrowSplit(item: Doc): Null<{ head: Doc, body: Doc }> {
		final arr: Null<Array<Doc>> = switch item {
			case Concat(a): a;
			case _: null;
		};
		if (arr == null) return null;
		var opIdx: Int = -1;
		for (i in 0...arr.length) switch arr[i] {
			case Text(s) if (opIdx < 0 && (s == '->' || s == '=>')):
				opIdx = i;
			case _:
		}
		if (opIdx < 0) return null;
		final headParts: Array<Doc> = [for (i in 0...opIdx + 1) arr[i]];
		// Body = everything after the operator, skipping a single leading OptSpace
		// (the `_dop(' ')` post-arrow space the Pratt codegen emits).
		final bodyParts: Array<Doc> = [];
		for (i in opIdx + 1...arr.length) switch arr[i] {
			case OptSpace(_) if (bodyParts.length == 0):
			case _:
				bodyParts.push(arr[i]);
		}
		if (bodyParts.length == 0) return null;
		final body: Doc = bodyParts.length == 1 ? bodyParts[0] : Concat(bodyParts);
		return { head: Concat(headParts), body: body };
	}

	// ω-thinarrow-break leg-2 discriminator: true iff the bare-ident arrow's body
	// chain CAN break — its Doc carries a render-time break conditional. The
	// chain emitter (`BinaryChainEmit.emit`) returns `WrapBoundary(shapeAt(flat))`
	// (NO conditional) when both cascade states resolve to the same mode
	// (`sameRule(flat, brk)`), and `WrapBoundary(Group(IfBreak(brk, flat)))` (a
	// conditional) when the chain can break. So the presence of an `IfBreak` /
	// `IfLineExceeds` / `IfWidthExceeds` / … conditional inside the body's wrap
	// level IS the breakable signal.
	// For #5 the `||` opBool chain (config REPLACE rules: NoWrap when fits /
	// fillLine when exceeds) emits `WrapBoundary(Group(IfBreak(...)))` →
	// breakable. For the inverse sibling (`opbool_in_call_no_extra_indent`,
	// default opBool rules) the 2-operand chain resolves NoWrap for both states →
	// `WrapBoundary(flat)` with no conditional → NOT breakable, so the call keeps
	// the generic open-paren shape. Mirrors fork
	// `reEvaluateSingleArgCallParam`'s `hasInnerBreak` (MarkWrapping.hx:521-530):
	// the single-arg call glues the arrow head only when the inner content
	// actually broke. Stack walk down the body's transparent wrappers + Concat
	// children to the first render-time conditional (does not descend into a
	// conditional's own branches — a nested sub-construct break is the operand's
	// own layout, like fork's per-token `whitespaceAfter == Newline` scan).
	private static function bareArrowBodyBreaks(body: Doc): Bool {
		final stack: Array<Doc> = [body];
		while (stack.length > 0) {
			final node: Doc = stack.pop();
			switch node {
				case IfBreak(_, _) | IfWidthExceeds(_, _, _) | IfFirstLineExceeds(_, _, _) | IfLineExceeds(_, _, _) | IfResidualLineExceeds(
					_, _, _
				) | IfFullLineExceeds(_, _, _) | IfNaturalFirstLineExceeds(_, _, _) | IfNaturalFirstLineFitsOpenDelim(_, _, _) | IfArrowContinuationFits(
					_, _, _, _, _
				):
					return true;
				case WrapBoundary(inner) | Group(inner) | BodyGroup(inner) | GroupWithRestProbe(inner) | Nest(_, inner) | Flatten(inner) | HardFlatten(
					inner
				) | CollapseProbe(inner) | CollapseAddProbe(inner) | ConditionalMarkerZero(inner) | ConditionalMarkerDecrease(inner):
					stack.push(inner);
				case Concat(arr):
					for (it in arr) stack.push(it);
				case Fill(items, _, _) | FillWithRestProbe(items, _, _) | FillBreakAfterWrap(items, _, _):
					return items.length > 0;
				case Line(s):
					if (s.length > 0 && StringTools.fastCodeAt(s, 0) == '\n'.code) return true;
				case OptHardline | OptHardlineSkipAtOpenDelim | OptHardlineSkipBeforeHardline:
					return true;
				case _:
			}
		}
		return false;
	}

	// ω-thinarrow-break leg-3 glue shape: `call(item ->\n\tbody\n)` — arrow head
	// glued to the open paren, forced break AFTER `->`, body on the +cols
	// continuation indent, close on its own line. The INVERSE of the generic
	// open-paren FLWLB shape (`call(\n\titem -> body\n)`). Mirrors fork
	// `applyArrowWrapping` (MarkWrapping.hx:2336-2378): restore the break after
	// the arrow and put the enclosing call's `)` on its own line, leaving the
	// open paren glued to the arrow head.
	private static function bareArrowGlueShape(
		open: String, close: String, openInside: Doc, closeInside: Doc, head: Doc, body: Doc, cols: Int
	): Doc {
		return Concat([
			Text(open),
			openInside,
			head,
			Nest(cols, Concat([Line('\n'), body])),
			Line('\n'),
			closeInside,
			Text(close),
		]);
	}

	// ω-callparam-multiarg-block-lambda glue shape: `f(a, b, () -> {`-style — open
	// paren glued, all args joined inline with `sep + ' '`, close glued. The
	// `shapeNoWrap` skeleton WITHOUT its `Flatten` wrapper: the last arg (a block-
	// bodied lambda) must keep its OWN multi-line break (the block's brace layout),
	// so the inner content must NOT be force-flattened. The enclosing `)` glues to
	// the block close `}` (`})`), the surrounding statement adds `;` → `});`.
	// Mirrors fork `applyArrowWrapping`'s collapsed arrow head + the block's own
	// brace break. `sepBeforeFlags` is honoured identically to `shapeNoWrap` so a
	// source-elided separator (cond-comp ctor) stays byte-faithful.
	private static function multiArgBlockLambdaGlueShape(
		open: String, close: String, sep: String, items: Array<Doc>, openInside: Doc, closeInside: Doc, sepBeforeFlags: Null<Array<Bool>>
	): Doc {
		final inner: Array<Doc> = [];
		for (i in 0...items.length) {
			if (i > 0) inner.push(skipSepBefore(sepBeforeFlags, i) ? Text(' ') : Text(sep + ' '));
			inner.push(items[i]);
		}
		return Concat([Text(open), openInside, Concat(inner), closeInside, Text(close)]);
	}

	// ω-callparam-single-arg-glue: true iff `item`'s OWN outermost layout breaks
	// at a `.` dot rather than at the head construct's own open delimiter — i.e.
	// `item` is a method chain. `MethodChainEmit.shape*` emits
	// `Concat([receiver, seg0, Nest(cols, Concat([Line, seg1, …]))])`: a
	// `Line('\n')` whose following sibling's first visible Text starts with `.`,
	// sitting at the item's own top level (or inside the chain-tail `Nest`). The
	// single-arg glue must skip these — the natural-first-line measurer diverges
	// from render for a chain operand (it under-measures the chain ignoring the
	// outer close + rest stack), so gluing would keep the outer paren glued where
	// the fork opens it.
	//
	// Descent is deliberately NARROW: only the item's own wrap-shape wrappers and
	// the bare chain-tail `Nest` are followed. A nested `Group` / `WrapBoundary`
	// is a SUB-construct's own break (e.g. the inner args of `new X(a.b().c())`) —
	// NOT this item's top-level layout — so we do NOT recurse through it.
	private static function isMethodChainItem(item: Doc): Bool {
		return switch item {
			case WrapBoundary(inner) | Group(inner) | BodyGroup(inner) | GroupWithRestProbe(inner) | Nest(_, inner) | Flatten(inner) | HardFlatten(
				inner
			) | CollapseProbe(inner) | CollapseAddProbe(inner) | ConditionalMarkerZero(inner) | ConditionalMarkerDecrease(inner):
				isMethodChainItem(inner);
			case IfBreak(brk, _) | IfWidthExceeds(_, brk, _) | IfFirstLineExceeds(_, brk, _) | IfLineExceeds(_, brk, _) | IfResidualLineExceeds(
				_, brk, _
			) | IfFullLineExceeds(_, brk, _) | IfNaturalFirstLineExceeds(_, brk, _) | IfNaturalFirstLineFitsOpenDelim(_, brk, _):
				isMethodChainItem(brk);
			case Concat(arr):
				var hit: Bool = false;
				for (k in 0...arr.length) if (!hit) switch arr[k] {
					case Line(flat) if (flat.length > 0 && StringTools.fastCodeAt(flat, 0) == '\n'.code && k + 1 < arr.length
						&& firstVisibleTextStartsWith(arr[k + 1], '.'.code)):
						hit = true;
					// Follow ONLY a bare chain-tail `Nest` (where MethodChainEmit
					// parks segments 1..N). Sub-construct `Group`/`WrapBoundary`
					// children are NOT this item's own layout — skip them.
					case Nest(_, nested):
						hit = isMethodChainItem(nested);
					case _:
				}
				hit;
			case _: false;
		};
	}

	// First visible Text leaf's leading char-code, comparing to `c`. Skips
	// transparent wrappers (Empty / Line / OptSpace* / leading Concat slot /
	// Group family / Nest / Flatten / WrapBoundary). Returns false if no Text
	// leaf is reached before a non-skippable, non-`c` token.
	private static function firstVisibleTextStartsWith(d: Doc, c: Int): Bool {
		return switch d {
			case Text(s):
				s.length > 0 && StringTools.fastCodeAt(s, 0) == c;
			case Concat(arr):
				var found: Bool = false;
				var hit: Bool = false;
				for (it in arr) if (!found) switch it {
					case Empty | Line(_) | OptSpace(_) | OptSpaceSkipAfterHardline | OptHardline | OptHardlineSkipAtOpenDelim
						| OptHardlineSkipBeforeHardline:
					case _:
						found = true;
						hit = firstVisibleTextStartsWith(it, c);
				}
				hit;
			case Group(i) | BodyGroup(i) | GroupWithRestProbe(i) | Nest(_, i) | Flatten(i) | HardFlatten(i) | CollapseProbe(i) | CollapseAddProbe(
				i
			) | WrapBoundary(i) | ConditionalMarkerZero(i) | ConditionalMarkerDecrease(i):
				firstVisibleTextStartsWith(i, c);
			case IfBreak(_, flat) | IfWidthExceeds(_, _, flat) | IfFirstLineExceeds(_, _, flat) | IfLineExceeds(_, _, flat) | IfResidualLineExceeds(
				_, _, flat
			) | IfFullLineExceeds(_, _, flat) | IfNaturalFirstLineExceeds(_, _, flat) | IfNaturalFirstLineFitsOpenDelim(_, _, flat):
				firstVisibleTextStartsWith(flat, c);
			case _: false;
		};
	}

	private static function shapeNoWrap(
		open: String, close: String, sep: String, items: Array<Doc>, openInside: Doc, closeInside: Doc,
		sepBeforeFlags: Null<Array<Bool>> = null, flatTrailingComma: Bool = false
	): Doc {
		// ω-arrow-body-close-paren-own-line slice 2: when the sole item
		// carries a slice-1 arrow-body-line-wrap marker, escalate the shape
		// from `Flatten(items)` to `Group(IfBreak(close-on-own-line,
		// close-glued))` so the outer call's `)` lands on its own line
		// when the inner arrow body wraps. Group's `fitsFlat` walks the
		// inner `IfResidualLineExceeds.flat` (the inline lambda body), so MFlat
		// fires iff the body fits — coupling the two wrap decisions.
		// Mirrors fork's `applyArrowWrapping` parent-walk close-paren mark.
		//
		// Why escalate out of `Flatten`: under `Flatten`, the inner
		// arrow-body wrap's `_dilr` probe inside `_dwb` would still fire
		// independently (WrapBoundary resets forceFlat), but the outer
		// close paren has no mechanism to follow that decision. Group +
		// IfBreak emits both close placements and picks consistently.
		if (items.length == 1 && isArrowBodyMarker(items[0]))
			return arrowBodyCloseParenShape(open, close, openInside, closeInside, items[0]);
		final inner: Array<Doc> = [];
		for (i in 0...items.length) {
			if (i > 0)
				// `sepBeforeFlags[i] == true` ⇒ source omitted
				// the comma between items[i-1] and items[i] (canonical:
				// `Conditional` cond-comp ctor whose body leads with sep).
				// Emit a bare space so tokens don't glue; everything else
				// stays byte-identical (`Text(sep + ' ')`).
				inner.push(skipSepBefore(sepBeforeFlags, i) ? Text(' ') : Text(sep + ' '));
			inner.push(items[i]);
		}
		// ω-nowrap-source-trail-comma: preserve a source trailing comma in the
		// flat (single-line) layout. `flatTrailingComma` is the source-only
		// `<field>TrailPresent` signal — true only when the source actually had
		// a `,` after the last element (NOT the knob, which only forces break-
		// mode). The fork is source-faithful here: a single-line `{a: 1,}` /
		// `[1, 2,]` / `f(x,)` keeps its trailing comma flat. Lists without a
		// source comma pass `false` and stay byte-identical. Empty lists
		// short-circuit before reaching this shape.
		if (flatTrailingComma && items.length > 0) inner.push(Text(sep));
		// ω-force-flat-engine slice D: wrap inner content in `Flatten` so any
		// Group/IfBreak/Fill nested inside a NoWrap-cascade construct is forced
		// to its flat branch by the renderer (Frame.forceFlat propagation).
		// `open`/`close` delimiters and `openInside`/`closeInside` trivia stay
		// outside the marker — they're construct metadata, not body content.
		// Nested cascades inside `inner` reset force-flat via the
		// `WrapBoundary` wraps Slice C placed around their `emit()` returns.
		return Concat([Text(open), openInside, Flatten(Concat(inner)), closeInside, Text(close)]);
	}

	private static function shapeOnePerLine(
		open: String, close: String, sep: String, items: Array<Doc>, cols: Int, appendTrailingComma: Bool, trailBreak: Doc,
		sepBeforeFlags: Null<Array<Bool>> = null
	): Doc {
		final inner: Array<Doc> = [];
		for (i in 0...items.length) {
			inner.push(Line('\n'));
			inner.push(items[i]);
			final isLast: Bool = i == items.length - 1;
			// When `sepBeforeFlags[i+1] == true`, the source had
			// no separator between this item and the next — suppress this
			// item's trailing sep. Trailing-comma decision on the LAST item
			// stays on `appendTrailingComma` (independent axis).
			final nextSkips: Bool = !isLast && skipSepBefore(sepBeforeFlags, i + 1);
			if ((!isLast && !nextSkips) || (isLast && appendTrailingComma)) inner.push(Text(sep));
		}
		// `trailBreak` per-construct rightCurly substitution
		// (ω-wraplist-trailbreakdoc). Default `Line('\n')` preserves the
		// legacy close-on-own-line layout; `Empty` produced from
		// `RightCurlyPlacement.Inline` glues close to the last body
		// token. See `emit` docstring for the full rationale.
		return Concat([Text(open), Nest(cols, Concat(inner)), trailBreak, Text(close)]);
	}

	private static function shapeOnePerLineAfterFirst(
		open: String, close: String, sep: String, items: Array<Doc>, cols: Int, appendTrailingComma: Bool,
		sepBeforeFlags: Null<Array<Bool>> = null
	): Doc {
		if (items.length == 1) return Concat([Text(open), items[0], Text(close)]);
		final tail: Array<Doc> = [];
		for (i in 1...items.length) {
			// Drop the trailing-sep on the previous item when
			// the source elided the comma at this slot.
			if (!skipSepBefore(sepBeforeFlags, i)) tail.push(Text(sep));
			tail.push(Line('\n'));
			tail.push(items[i]);
		}
		if (appendTrailingComma) tail.push(Text(sep));
		return Concat([
			Text(open),
			items[0],
			Nest(cols, Concat(tail)),
			Text(close),
		]);
	}

	/**
	 * ω-keep-newline-after-sep (increment 1): the `WrapMode.Keep` engine
	 * shape. Reproduces each link's source layout per the
	 * `sourceBreakBefore` flags (built by the multiVar fold from
	 * `Trivial.newlineAfterSep`): each link gets its separator then either a
	 * forced hardline at the continuation indent (`sourceBreakBefore[i] ==
	 * true`) or a literal space (source kept it on the same line).
	 * ω-keep-kw-newline (increment 1b): the head (`items[0]`,
	 * `sourceBreakBefore[0]`) likewise breaks onto its own continuation line
	 * when the source put a newline after the `var` / `final` keyword
	 * (`var\n\trawRead`); otherwise it stays glued to the open delim.
	 * Structurally the `shapeOnePerLineAfterFirst` skeleton with a per-link
	 * break/space decision instead of an unconditional hardline. Only
	 * reached when the caller threads `sourceBreakBefore` (multiVar fold);
	 * every other Keep consumer stays on the legacy `shapeNoWrap` glue.
	 */
	private static function shapeKeep(
		open: String, close: String, sep: String, items: Array<Doc>, cols: Int, appendTrailingComma: Bool, sourceBreakBefore: Array<Bool>
	): Doc {
		// ω-keep-kw-newline (increment 1b): the head (`items[0]`) breaks onto
		// its own line at the continuation indent when `sourceBreakBefore[0]`
		// is set — the multiVar fold maps the source `var`→head newline
		// (`var\n\t\t\trawRead`) onto that flag. When unset (the default, and
		// every other Keep consumer) the head stays glued to the open delim.
		final headBreak: Bool = sourceBreakBefore.length > 0 && sourceBreakBefore[0];
		if (items.length == 1) {
			return !headBreak
				? Concat([Text(open), items[0], Text(close)])
				: Concat([Text(open), Nest(cols, Concat([Line('\n'), items[0]])), Text(close)]);
		}
		// `nested` holds everything inside the continuation Nest: the optional
		// leading head break, the head itself (when broken), then each link's
		// separator + per-link break/space + item. When the head is glued the
		// Nest contains only the tail and `items[0]` rides the open delim line.
		final nested: Array<Doc> = [];
		if (headBreak) {
			nested.push(Line('\n'));
			nested.push(items[0]);
		}
		for (i in 1...items.length) {
			nested.push(Text(sep));
			final brk: Bool = i < sourceBreakBefore.length && sourceBreakBefore[i];
			nested.push(brk ? Line('\n') : Text(' '));
			nested.push(items[i]);
		}
		if (appendTrailingComma) nested.push(Text(sep));
		return headBreak
			? Concat([Text(open), Nest(cols, Concat(nested)), Text(close)])
			: Concat([Text(open), items[0], Nest(cols, Concat(nested)), Text(close)]);
	}

	private static function shapeFillLine(
		open: String, close: String, sep: String, items: Array<Doc>, openInside: Doc, closeInside: Doc, cols: Int,
		appendTrailingComma: Bool, groupRestProbe: Bool, sepBeforeFlags: Null<Array<Bool>> = null, keepCloseGlued: Bool = false
	): Doc {
		// Per-gap sep awareness (slice ω-fillline-pergap-sep): items split
		// into chunks at every leading-hardline boundary. Within each
		// chunk items pack via `Fill(chunk, softSep)` (Wadler fillSep —
		// per-item fit, soft `Line(' ')` between operands); between two
		// chunks a forced `Text(sep) + Line('\n')` enforces the break in
		// front of the next chunk's leading-hardline-bearing first item.
		//
		// Replaces the previous `forceBreak`-when-anyLeadingHardline
		// mechanism (slice ω-fillline-force-break) which over-fired:
		// with one hardline-led item in a list of N, ALL N-1 seps were
		// turned into forced hardlines, breaking even between items that
		// would otherwise pack inline (e.g. `Event.wysiwygCreateLink(id,
		// false, {…})` had `id` and `false` driven onto their own lines
		// by the `{…}` arg's leading hardline). The chunked structure
		// keeps the BG-deferred-flat fix's intent — the outer Group's
		// `fitsFlat` still aborts on the chunk-boundary `Line('\n')` and
		// commits to MBreak, so `Nest` continues to provide the
		// continuation indent for the broken-before items — without
		// smearing the forced-break onto soft gaps.
		// ω-fillline-single-noncascade: a single hardline-bearing item
		// (e.g. a chain segment whose lone arg is a multi-line lambda)
		// has no list shape to make — there's nothing to fill, no
		// per-item positioning. The cascade still picks `FillLine` for
		// such items because the hardline counts the item as overflow,
		// but the FillLine continuation `Nest(cols, …)` then drifts
		// every break-mode `\n` inside the item one indent too deep
		// relative to the surrounding column. Mirror fork's wrapping
		// engine, which emits `(<item>)` inline in this situation:
		// drop the continuation Nest (and the leading hardline that
		// only exists to force MBreak) when there is exactly one item.
		// Multi-item lists keep the existing `Fill(items, sep)` shape
		// where the Nest legitimately positions each broken-before
		// item at the list's continuation indent.
		if (items.length == 1) {
			final tail0: Doc = appendTrailingComma ? Text(sep) : Empty;
			// Close-paren placement at items.length=1: default close-glued.
			// When `items[0]` carries an internal hardline (binop chain
			// break inside a 1-arg call, multi-line lambda body, ternary
			// branch inside parens, …), the break is internal continuation
			// — not list pluralization. Fork's wrap engine routes such
			// inner breaks via the arg's own wrap and keeps the call's
			// paren attached to the last rendered token. Mirrors fork's
			// `wrapping/issue_314_splitting_field_access` and related
			// 1-arg-multiline-arg fixtures.
			//
			// EXCEPTION — chain-OPL receiver-led break: when `items[0]`
			// is a method chain in `OnePerLine` mode (receiver on the
			// first line, EVERY segment on its own indented line including
			// the first), fork puts the outer call's close paren back on
			// its own line at the outer column instead of gluing it to the
			// last segment's tail. Distinguishable structurally — OPL
			// shape is `Concat([receiver, Nest(cols, [Line, seg0, ...])])`
			// (length=2, second child Nest), vs OPLAF's `Concat([r, seg0,
			// Nest])` (length=3) where the close stays glued. See
			// `isChainOPLBreak` for the marker probe and ω-1arg-close-
			// chain-opl-gate for the slice that introduced it.
			final gluedShape: Doc = Concat([
				Text(open),
				openInside,
				items[0],
				tail0,
				closeInside,
				Text(close),
			]);
			// ω-keep-callclose-newline: under a Keep-mode method-chain sole arg
			// whose source glued the outer close `)` (`argsCloseNewline == false`,
			// surfaced as `keepCloseGlued`), the chain renders via
			// `MethodChainEmit.shapeKeep` — a `Concat([receiver, Nest(...)])` whose
			// length-2-Nest signature is INDISTINGUISHABLE from a genuine
			// OnePerLine chain at `isChainOPLBreak`. The OPL gate would force the
			// outer close onto its own line (`}))\n\t\t);`), but the fork keeps it
			// where the source put it (`})));`). The keep signal carries the source
			// intent directly (no width re-probe), so we short-circuit to the glued
			// shape — the source-faithful close for the `})));` case. A keep chain
			// whose source DID break before the close has `keepCloseGlued == false`
			// (the parser captured a newline) and falls through to the OPL break,
			// reproducing the author's own-line close.
			if (!keepCloseGlued && isChainOPLBreak(items[0])) {
				final brkShape: Doc = Concat([
					Text(open),
					openInside,
					items[0],
					tail0,
					closeInside,
					Line('\n'),
					Text(close),
				]);
				return groupOrRestProbe(IfBreak(brkShape, gluedShape), groupRestProbe);
			}
			return groupOrRestProbe(gluedShape, groupRestProbe);
		}
		// Chunk loop. Walk items[1..N]; at every leading-hardline-bearing
		// item OR the end of the list, emit (a) the comma + forced
		// `Line('\n')` between this chunk and the previous one (skipped
		// for the first chunk) and (b) the chunk body — `Fill(chunk,
		// softSep)` for multi-item chunks, the bare item for singletons
		// (no Wadler fillSep needed at length 1). The `Group` wrap below
		// preserves the renderer's flat/break decision: when no item has
		// any hardline the Group selects MFlat and items inline cleanly;
		// the moment any chunk boundary or any item carries a hardline
		// `fitsFlat` aborts on it and the Group commits to MBreak with
		// `Nest` providing the continuation indent.
		final softSep: Doc = Concat([Text(sep), Line(' ')]);
		// Cols of post-Fill same-line content. Three components:
		//   1. The eventual trailing-separator that lands on EACH wrapped
		//      line (`,` from softSep going break-mode between this line's
		//      last packed item and the next line's first item). Universal
		//      — every non-final wrapped line ends with this `,`.
		//   2. A `+1` semantic alignment for fork's `lineLength +
		//      tokenLength >= maxLineLength` (strict-break-at-threshold)
		//      vs our `fitsFlat`'s `flatWidth <= remaining` (lenient-pack-
		//      at-threshold) semantic mismatch. Without it the per-item-
		//      fit probe packs one item too many on lines that fork would
		//      break at exactly `col == lineWidth` (target fixture:
		//      `wrapping_of_function_signature.hxtest` byte-diff @ 616).
		//   3. Last-line tail: optional explicit trailing comma + the
		//      `closeInside` Doc's flat width + close delim. These share
		//      the line with the LAST packed item of the LAST chunk.
		// Subtracted from the Fill's per-item-fit budget so the last
		// packed item on EACH wrapped line leaves room for that tail —
		// mirrors fork's `wrapFillLine2AfterLast` accounting where each
		// item carries its trailing comma in `firstLineLength`
		// (slice ω-fill-tail-reserve).
		final lastChunkTailReserve: Int = sep.length + 1 + (appendTrailingComma ? sep.length : 0) + DocMeasure.flatTokenWidth(closeInside)
			+ close.length;
		final bodyParts: Array<Doc> = [];
		var chunkStart: Int = 0;
		for (i in 1...items.length + 1) {
			final atEnd: Bool = i == items.length;
			// `sepBeforeFlags[i] == true` also forces a chunk
			// split before `items[i]` so the inter-element slot routes
			// through the chunk-boundary path (where the `Text(sep)`
			// gate below honours the same flag). Without this, both
			// elements would land in one chunk and be packed via
			// `Fill(chunk, softSep)` with a uniform sep — no
			// per-pair elision possible. Closes whitespace/issue_582
			// where the outer `,` was elided in favour of the cond-comp
			// body's own leading sep but neither element starts with a
			// hardline at the Doc level.
			final hardLed: Bool = !atEnd && (hasLeadingHardline(items[i]) || skipSepBefore(sepBeforeFlags, i));
			if (atEnd || hardLed) {
				if (chunkStart > 0) {
					// The inter-chunk sep belongs immediately
					// BEFORE `items[chunkStart]` (the first element of the
					// current chunk we are about to push) — its flag is
					// `sepBeforeFlags[chunkStart]`. When `true`, suppress
					// the `Text(sep)` and keep only the forced `Line('\n')`.
					// Closes whitespace/issue_582 where a `#if … #end`
					// conditional-param body leads with its own sep and
					// the outer comma was therefore elided.
					if (!skipSepBefore(sepBeforeFlags, chunkStart)) bodyParts.push(Text(sep));
					bodyParts.push(Line('\n'));
				}
				if (i - chunkStart == 1) {
					bodyParts.push(items[chunkStart]);
				} else {
					final chunk: Array<Doc> = items.slice(chunkStart, i);
					// Only the LAST chunk reserves cols for the tail —
					// earlier chunks are followed by a forced `,\n` chunk
					// boundary so their last-item-fit decision can't push
					// the tail off the line. Reserving on them would
					// tighten the in-chunk wrap budget without benefit.
					final tailReserve: Int = atEnd ? lastChunkTailReserve : 0;
					// ω-fill-rest-probe: opt-in to `FillWithRestProbe` on the
					// LAST chunk when the caller's Star opted in via
					// `@:fmt(groupRestProbe)`. Mirrors `GroupWithRestProbe`
					// at outer Group layer — together they close fixtures
					// like `wrapping/issue_494_type_parameter` where the LHS
					// typeParams must wrap because significant content
					// (`= RequestMethod<...>;`) trails on the same source
					// line. Earlier chunks are followed by a forced `,\n`
					// boundary so rest-probe is irrelevant there — bare Fill
					// preserves byte-equivalent legacy behavior.
					bodyParts.push(
						groupRestProbe && atEnd ? FillWithRestProbe(chunk, softSep, tailReserve) : Fill(chunk, softSep, tailReserve)
					);
				}
				chunkStart = i;
			}
		}
		final tail: Doc = appendTrailingComma ? Text(sep) : Empty;
		final inner: Doc = Concat([Concat(bodyParts), tail]);
		final outerInner: Doc = Concat([
			Text(open),
			openInside,
			Nest(cols, inner),
			closeInside,
			Text(close),
		]);
		return groupOrRestProbe(outerInner, groupRestProbe);
	}

	/**
	 * ω-group-rest-probe slice 2: pick `GroupWithRestProbe` over `Group`
	 * when the caller's Star opted into rest-of-stack lookahead via
	 * `@:fmt(groupRestProbe)`. Used at sites where significant same-line
	 * content trails the wrap construct (e.g. typedef LHS `<T,U,V>`
	 * followed by ` = Rhs<...>;` on the same source line). Fork's wrap
	 * engine considers `lengthAfter` when deciding whether to wrap the
	 * LHS — our plain `Group.fitsFlat` is blind to rest-of-stack.
	 * `GroupWithRestProbe(inner)` subtracts
	 * `flatTokenWidthOfRestStack(stack)` from the budget at render time,
	 * matching fork's bias. Default `false` keeps every other consumer
	 * (call args, object literals, anon types, HxTypeRef.params) on the
	 * legacy `Group` decision.
	 */
	private static inline function groupOrRestProbe(inner: Doc, groupRestProbe: Bool): Doc {
		return groupRestProbe ? GroupWithRestProbe(inner) : Group(inner);
	}

	/**
	 * ω-1arg-close-chain-opl-gate: structural marker probe for chain-OPL
	 * shape inside a 1-arg list. Returns `true` when `item` likely
	 * originated from `MethodChainEmit` in `OnePerLine` mode — receiver
	 * is followed IMMEDIATELY by a `Nest` (no inline first segment).
	 *
	 * Two emitter paths covered, both wrapped in `WrapBoundary`:
	 *  - Collapsed cascade (modes equal at flat/break): `<shape>` direct.
	 *  - Split cascade no-threshold: `IfFullLineExceeds(_, <break-shape>, _)`.
	 *
	 * Shape signature: `Concat([_, Nest(_, _)])` (length=2, second child
	 * is `Nest`). Distinguishes OPL (`MethodChainEmit.shapeOnePerLine`)
	 * from OPLAF (`shapeOnePerLineAfterFirst`, length=3) at the chain
	 * layer.
	 *
	 * False-positive footprint: `BinaryChainEmit`'s `sameRule`-collapse
	 * path can also emit `WrapBoundary(Concat([_, Nest(_)]))` directly
	 * when its cascade resolves to OnePerLineAfterFirst at both
	 * exceeds=false/true. No current corpus fixture triggers this — binop
	 * default cascade always splits via `LineLengthLargerThan`, so the
	 * top-level wrapper at issue_314 et al. is `Group(IfBreak(...))`,
	 * not the bare `WrapBoundary(<shape>)` matched here. Thresholded
	 * chain OPL (`MethodChainEmit:137/148`) returns `false` here —
	 * future slice if a fixture demands.
	 */
	private static function isChainOPLBreak(item: Doc): Bool {
		return switch item {
			case WrapBoundary(inner): isOPLShape(inner);
			case _: false;
		};
	}

	private static function isOPLShape(d: Doc): Bool {
		return switch d {
			case Concat(arr) if (arr.length == 2):
				switch arr[1] {
					case Nest(_, _):
						true;
					case _:
						false;
				}
			case IfFullLineExceeds(_, brk, _): isOPLShape(brk);
			case _: false;
		};
	}

	/**
	 * ω-arrow-body-close-paren-own-line slice 2: structural marker probe
	 * for the arrow-body-line-wrap shape emitted by slice 1 at
	 * `WriterLowering.hx:2703-2740`. Returns `true` when `item`'s tail
	 * contains a `WrapBoundary(IfResidualLineExceeds(_, Nest(_, Concat([Line('\n'), _])), _))`
	 * marker — the slice-1 emit signature for `HxThinParenLambda.body` /
	 * `HxParenLambda.body` under `@:fmt(arrowBodyLineWrap)`.
	 *
	 * Used by `shapeNoWrap` to route the outer Call's `(arg)` shape to
	 * `Group(IfBreak(brk_close_on_own_line, flat_close_glued))` when the
	 * sole arg is an arrow lambda whose body might wrap. The Group's
	 * `fitsFlat` walks `IfResidualLineExceeds.flat` (the inline body) so
	 * MFlat fires iff the body fits — aligned with the inner `_dilr`
	 * probe's decision. Mirrors fork's `applyArrowWrapping` parent-walk
	 * that marks the enclosing call's close paren on a separate line when
	 * the arrow body wraps.
	 *
	 * Tail-walk: items[0] is the entire lambda Doc `Concat([Text('('),
	 * params, Text(')'), Text('->'), OptSpace(' '), wrapped_body])`; the
	 * marker is in the last element. Recurse on Concat tail until a
	 * `WrapBoundary` is reached.
	 *
	 * False-positive footprint: none by ctor alone since the residual
	 * retag — `IfResidualLineExceeds` is emitted only by the arrow-body
	 * wrap (`emitCondition`'s cond-wrap uses `IfWidthExceeds`;
	 * `HxAbstractDecl.clauses` stays on `IfLineExceeds`). The brk-shape
	 * check is belt-and-braces against future emitters.
	 */
	private static function isArrowBodyMarker(item: Doc): Bool {
		return switch item {
			case WrapBoundary(IfResidualLineExceeds(_, brk, _)): isArrowBrkShape(brk);
			case Concat(arr) if (arr.length > 0): isArrowBodyMarker(arr[arr.length - 1]);
			case _: false;
		};
	}

	private static function isArrowBrkShape(d: Doc): Bool {
		return switch d {
			case Nest(_, Concat(arr)) if (arr.length >= 1):
				switch arr[0] {
					case Line(s) if (s == '\n'):
						true;
					case _:
						false;
				}
			case _: false;
		};
	}

	/**
	 * `FillLineWithLeadingBreak` shape on the multi-item path: always
	 * emit `Line('\n')` immediately after `open` (inside the
	 * continuation `Nest`) and immediately before `close` (at the
	 * outer column). Items pack inline via `Fill(items, softSep)` —
	 * Wadler fillSep, same soft per-item wrap-on-overflow used by
	 * `shapeFillLine`'s multi-item chunk body. Mirrors the single-Ref
	 * `emitCondition.brkShape` semantics for cascade-fired FLWLB on
	 * Star fields (first consumer: `HxFnDecl.params` with the fork's
	 * `wrapPClose` paren-break pattern). The caller's
	 * `Group(IfBreak(this-shape, NoWrap-shape))` flow keeps this
	 * branch off the flat path — the renderer only commits here when
	 * the flat form doesn't fit. `cols` is supplied by `emit`'s
	 * mode-gated formula and lands the cascade-forced break at
	 * `outer + additional` tabs (the wrap-engine indent regime),
	 * matching fork's `calcIndent + additionalIndent`.
	 */
	private static function shapeFillLineWithLeadingBreak(
		open: String, close: String, sep: String, items: Array<Doc>, openInside: Doc, closeInside: Doc, cols: Int,
		appendTrailingComma: Bool
	): Doc {
		final softSep: Doc = Concat([Text(sep), Line(' ')]);
		// Tail reserve identical in structure to `shapeFillLine` but
		// without the `closeInside + close` component — FLWLB places
		// close on its own line via the forced `Line('\n')` between
		// the Nest exit and `closeInside`. The `sep.length + 1` base
		// covers (a) trailing softSep `,` landing on every wrapped
		// line and (b) the fork-`>=` vs ours-`<=` semantic alignment.
		// ω-fill-tail-reserve.
		final tailReserve: Int = sep.length + 1 + (appendTrailingComma ? sep.length : 0);
		// ω-fill-break-after-wrap: `FillBreakAfterWrap` forces the separator
		// before an item to break when the preceding arg self-wrapped (e.g. a
		// long opAddSub chain arg that fills across continuation lines). Plain
		// `Fill` would glue the trailing scalar args onto the wrapped arg's
		// short last line (`+ "…", 10212`); the break-after-wrap variant puts
		// them on a fresh continuation line where they fill-pack among
		// themselves — matching fork's `wrapFillLineWithLeading2AfterLast`
		// flat-width accounting. Fixes `opadd_multiparam_before_last` and
		// `callparam_fill_pack_after_opadd_first_arg`; corrects the outer-arg
		// layout of `opadd_multiparam_{after_last,continuation_indent}` too
		// (those stay FAIL only on a separate opAddSub-internal indent defect).
		final inner: Doc = items.length == 1 ? items[0] : FillBreakAfterWrap(items, softSep, tailReserve);
		final tail: Doc = appendTrailingComma ? Text(sep) : Empty;
		return Concat([
			Text(open),
			openInside,
			Nest(cols, Concat([Line('\n'), inner, tail])),
			Line('\n'),
			closeInside,
			Text(close),
		]);
	}

	/**
	 * Walks the leading edge of `d` and returns `true` if the first
	 * Doc that emits visible content is a hardline (`Line('\n')` or
	 * `OptHardline`). Skips through transparent wrappers (`Empty`,
	 * single-leading-edge Concat slot, `Group` / `BodyGroup` / `Nest`
	 * inner). Used by `emit` to decide whether the FillLine shape
	 * must commit to break mode unconditionally.
	 */
	private static function hasLeadingHardline(d: Doc): Bool {
		final leaf: Null<Bool> = leadingHardlineLeaf(d);
		return leaf ?? switch d {
			case Nest(_, inner): hasLeadingHardline(inner);
			case Group(inner) | BodyGroup(inner) | GroupWithRestProbe(inner): hasLeadingHardline(inner);
			case Concat(items):
				for (it in items) {
					if (hasLeadingHardline(it)) return true;
					if (!isLeadingTransparent(it)) return false;
				}
				false;
			case Fill(items, _, _) | FillWithRestProbe(items, _, _) | FillBreakAfterWrap(items, _, _):
				items.length > 0 && hasLeadingHardline(items[0]);
			// ω-force-flat-engine slice A: pass-through. All four markers
			// are render-time state — their `inner` carries the same leading
			// hardline answer it would without the wrap.
			case Flatten(inner) | WrapBoundary(inner) | HardFlatten(inner) | CollapseProbe(inner) | CollapseAddProbe(inner) | CollapseBoolProbe(
				inner
			) | CollapseChainProbe(inner):
				hasLeadingHardline(inner);
			// ω-cond-indent-policy FixedZero / AlignedDecrease: render-time
			// markers, transparent — leading-hardline answer matches `inner`.
			case ConditionalMarkerZero(inner): hasLeadingHardline(inner);
			case ConditionalMarkerDecrease(inner):
				hasLeadingHardline(inner);
			// Every leaf kind is already resolved by `leadingHardlineLeaf`.
			case _: false;
		};
	}

	/**
	 * Leaf arms of the `hasLeadingHardline` walk: a definitive answer
	 * for nodes that do not recurse, or `null` for the container kinds
	 * (`Nest` / `Group` / `Concat` / `Fill` / the render-time wrappers)
	 * that `hasLeadingHardline` descends. Only an opt-hardline or a
	 * `Line('\n')` leads with a hardline; the `If*` conditional nodes
	 * report `false` (their leading hardline is renderer-side).
	 */
	private static function leadingHardlineLeaf(d: Doc): Null<Bool> {
		return switch d {
			case Empty: false;
			case OptHardline | OptHardlineSkipAtOpenDelim | OptHardlineSkipBeforeHardline: true;
			case Line(flat):
				flat.length > 0 && StringTools.fastCodeAt(flat, 0) == '\n'.code;
			case Text(_): false;
			case OptSpace(_): false;
			case OptSpaceSkipAfterHardline: false;
			case IfBreak(_, _): false;
			case IfWidthExceeds(_, _, _): false;
			case IfFirstLineExceeds(_, _, _): false;
			case IfLineExceeds(_, _, _) | IfResidualLineExceeds(_, _, _): false;
			case IfFullLineExceeds(_, _, _): false;
			case IfNaturalFirstLineExceeds(_, _, _): false;
			case IfNaturalFirstLineFitsOpenDelim(_, _, _): false;
			case IfArrowContinuationFits(_, _, _, _, _): false;
			case _: null;
		};
	}

	private static inline function isLeadingTransparent(d: Doc): Bool {
		return switch d {
			case Empty: true;
			case Concat([]): true;
			case _: false;
		};
	}

	/**
	 * ω-cond-end-call-glue: true when `d`'s trailing visible text ends with
	 * the conditional-compilation close marker `#end` — a call whose CALLEE
	 * is a conditional group (`#if a X #elseif b Y #end (args)`) must keep a
	 * space before its open paren instead of the tight `callee(` glue, both
	 * for readability and byte-parity with sources that write `#end (`.
	 * Same trailing-edge walk as `endsWithCloseDelim` (flat side of the
	 * `If*` conditionals, transparent wrappers descended).
	 */
	public static function endsWithCondEnd(d: Doc): Bool {
		var node: Doc = d;
		while (true) switch node {
			case Empty | Line(_) | OptSpace(_) | OptSpaceSkipAfterHardline | OptHardline | OptHardlineSkipAtOpenDelim
				| OptHardlineSkipBeforeHardline:
				return false;
			case Text(s):
				return StringTools.endsWith(s, '#end');
			case Nest(_, inner) | Group(inner) | BodyGroup(inner) | GroupWithRestProbe(inner) | Flatten(inner) | WrapBoundary(inner) | HardFlatten(
				inner
			) | CollapseProbe(inner) | CollapseAddProbe(inner) | CollapseBoolProbe(inner) | CollapseChainProbe(inner) | ConditionalMarkerZero(
				inner
			) | ConditionalMarkerDecrease(inner):
				node = inner;
			case IfBreak(_, flat) | IfWidthExceeds(_, _, flat) | IfFirstLineExceeds(_, _, flat) | IfLineExceeds(_, _, flat) | IfResidualLineExceeds(
				_, _, flat
			) | IfFullLineExceeds(_, _, flat) | IfNaturalFirstLineExceeds(_, _, flat) | IfNaturalFirstLineFitsOpenDelim(_, _, flat) | IfArrowContinuationFits(
				_, _, _, _, flat
			):
				node = flat;
			case Concat(items):
				final last: Null<Doc> = findLastNonTrailingTransparent(items);
				if (last == null) return false;
				node = last;
			case Fill(items, _, _) | FillWithRestProbe(items, _, _) | FillBreakAfterWrap(items, _, _):
				final last: Null<Doc> = findLastNonTrailingTransparent(items);
				if (last == null) return false;
				node = last;
		}
	}

	/**
	 * ω-callparam-function-block-lambda: true iff `item` is a `function`-
	 * keyword anonymous-function expression argument with a BLOCK body — the
	 * `function(){}` sibling of the arrow-body block lambda (`arrowBodyIsBlock`).
	 * `function` is a reserved keyword so a first-visible-Text of exactly
	 * `function` is unambiguously a function expr (never an identifier); the
	 * forced-hardline test (`flatLength < 0`) restricts to block bodies (a
	 * single-expression body `function() return e` renders inline, carries no
	 * hardline, and must NOT lambda-hug). Fed into the same multi-arg glue gate
	 * as the arrow markers so an OpenFL-style callback (`addEventListener(evt,
	 * function(e) { … })`) keeps its head glued instead of opening the paren.
	 */
	private static function isFunctionBlockLambdaItem(item: Doc): Bool {
		return firstVisibleTextIsFunctionKw(item) && flatLength(item) < 0;
	}

	/**
	 * Left-spine walk mirroring `firstVisibleTextStartsWith` but matching the
	 * whole trimmed first-visible-Text against the `function` keyword.
	 */
	private static function firstVisibleTextIsFunctionKw(d: Doc): Bool {
		return switch d {
			case Text(s):
				StringTools.trim(s) == 'function';
			case Concat(arr):
				var found: Bool = false;
				var hit: Bool = false;
				for (it in arr) if (!found) switch it {
					case Empty | Line(_) | OptSpace(_) | OptSpaceSkipAfterHardline | OptHardline | OptHardlineSkipAtOpenDelim
						| OptHardlineSkipBeforeHardline:
					case _:
						found = true;
						hit = firstVisibleTextIsFunctionKw(it);
				}
				hit;
			case Group(i) | BodyGroup(i) | GroupWithRestProbe(i) | Nest(_, i) | Flatten(i) | HardFlatten(i) | CollapseProbe(i) | CollapseAddProbe(
				i
			) | WrapBoundary(i) | ConditionalMarkerZero(i) | ConditionalMarkerDecrease(i):
				firstVisibleTextIsFunctionKw(i);
			case IfBreak(_, flat) | IfWidthExceeds(_, _, flat) | IfFirstLineExceeds(_, _, flat) | IfLineExceeds(_, _, flat) | IfResidualLineExceeds(
				_, _, flat
			) | IfFullLineExceeds(_, _, flat) | IfNaturalFirstLineExceeds(_, _, flat) | IfNaturalFirstLineFitsOpenDelim(_, _, flat):
				firstVisibleTextIsFunctionKw(flat);
			case _:
				false;
		};
	}

	/**
	 * ω-comprehension-block-hug: true iff `item` is a `for` / `while`
	 * comprehension element with a BLOCK body — the array-comprehension analog
	 * of the block lambda. `for` / `while` are reserved keywords so an exact
	 * first-visible-Text match is unambiguous; the forced-hardline test
	 * (`flatLength < 0`) restricts to block bodies (a single-expression
	 * comprehension body renders inline, carries no hardline, and must NOT
	 * head-hug).
	 */
	private static function isBlockBodyComprehensionItem(item: Doc): Bool {
		final t: Null<String> = firstVisibleText(item);
		// Require a `{ … }` BLOCK body (last token `}`), not merely any hardline:
		// an expression-body comprehension that WRAPS also carries a hardline but
		// its close is placed differently by the fork (`]` on its own line).
		return (t == 'for' || t == 'while') && lastVisibleText(item) == '}' && flatLength(item) < 0;
	}

	/**
	 * The whole trimmed first-visible-Text of `d`, or `null`. Left-spine walk
	 * mirroring `firstVisibleTextStartsWith` but returning the token text.
	 */
	private static function firstVisibleText(d: Doc): Null<String> {
		return switch d {
			case Text(s):
				StringTools.trim(s);
			case Concat(arr):
				var found: Bool = false;
				var r: Null<String> = null;
				for (it in arr) if (!found) switch it {
					case Empty | Line(_) | OptSpace(_) | OptSpaceSkipAfterHardline | OptHardline | OptHardlineSkipAtOpenDelim
						| OptHardlineSkipBeforeHardline:
					case _:
						found = true;
						r = firstVisibleText(it);
				}
				r;
			case Group(i) | BodyGroup(i) | GroupWithRestProbe(i) | Nest(_, i) | Flatten(i) | HardFlatten(i) | CollapseProbe(i) | CollapseAddProbe(
				i
			) | WrapBoundary(i) | ConditionalMarkerZero(i) | ConditionalMarkerDecrease(i):
				firstVisibleText(i);
			case IfBreak(_, flat) | IfWidthExceeds(_, _, flat) | IfFirstLineExceeds(_, _, flat) | IfLineExceeds(_, _, flat) | IfResidualLineExceeds(
				_, _, flat
			) | IfFullLineExceeds(_, _, flat) | IfNaturalFirstLineExceeds(_, _, flat) | IfNaturalFirstLineFitsOpenDelim(_, _, flat):
				firstVisibleText(flat);
			case _:
				null;
		};
	}

	/**
	 * ω-thinarrow-break if-else: `true` iff `body` is an ALREADY-multiline
	 * `if … else` (or `else if` chain) — the one arrow-body shape the fork breaks
	 * after `->` even when the glued head fits (`applyArrowWrapping` +
	 * `isArrowBodyMultilineIfElse`, MarkWrapping.hx:2346/2401). Three structural
	 * conditions, all cheap:
	 *  - the body's first visible token is the `if` keyword;
	 *  - the body carries a structural hardline (`flatLength < 0`) — i.e. it is
	 *    ALREADY wrapped across lines (fork's `hasInnerBreakInRange`), so a
	 *    single-line `if a else b` that merely fits its continuation line stays
	 *    huggable;
	 *  - the body has a TOP-LEVEL `else` (`hasTopLevelElse`) — an `else` that
	 *    belongs to the OUTER if, not one nested inside the then-block. Mirrors the
	 *    fork's `firstOf(Kwd(KwdElse))`, which inspects only the outer if's DIRECT
	 *    children, so an outer if whose then-block merely CONTAINS a nested if/else
	 *    (with no else of its own) stays huggable.
	 * A plain `if` (no else) / `switch` / `for` / `while` body returns `false`,
	 * keeping the landed block/statement-body hug intact.
	 */
	private static function arrowBodyIsBrokenIfElse(body: Doc): Bool {
		return firstVisibleText(body) == 'if' && flatLength(body) < 0 && hasTopLevelElse(body, 0);
	}

	/**
	 * Walks `body` for an `else` keyword Text at the if construct's own structural
	 * level (`Nest` depth 0), skipping transparent wrappers and following
	 * conditionals' FLAT branch (as `firstVisibleText` does). An `else` reached only
	 * by descending into a `Nest` (a nested block body's indent) is ignored — it
	 * belongs to an inner if, not the outer one.
	 */
	private static function hasTopLevelElse(d: Doc, depth: Int): Bool {
		return switch d {
			case Text(s):
				depth == 0 && isElseKeyword(s);
			case Concat(arr):
				for (it in arr) if (hasTopLevelElse(it, depth)) return true;
				false;
			case Nest(_, inner):
				hasTopLevelElse(inner, depth + 1);
			case Group(i) | BodyGroup(i) | GroupWithRestProbe(i) | Flatten(i) | HardFlatten(i) | CollapseProbe(i) | CollapseAddProbe(i) | WrapBoundary(
				i
			) | ConditionalMarkerZero(i) | ConditionalMarkerDecrease(i):
				hasTopLevelElse(i, depth);
			case IfBreak(_, flat) | IfWidthExceeds(_, _, flat) | IfFirstLineExceeds(_, _, flat) | IfLineExceeds(_, _, flat) | IfResidualLineExceeds(
				_, _, flat
			) | IfFullLineExceeds(_, _, flat) | IfNaturalFirstLineExceeds(_, _, flat) | IfNaturalFirstLineFitsOpenDelim(_, _, flat):
				hasTopLevelElse(flat, depth);
			case _:
				false;
		};
	}

	/**
	 * `true` iff the trimmed keyword Text `s` is (or begins with) the `else`
	 * keyword — covers a standalone `else` token and a glued `else if` head.
	 */
	private static function isElseKeyword(s: String): Bool {
		final t: String = StringTools.trim(s);
		return t == 'else' || StringTools.startsWith(t, 'else ') || StringTools.startsWith(t, 'else\t');
	}

	/**
	 * ω-comprehension-block-hug: a single-element array whose element is a
	 * block-body `for` / `while` comprehension keeps `[ for (...) {` glued on
	 * the head line (block body indents underneath, `} ]` closes) instead of
	 * leading-breaking the `[`. Fires ONLY when the comprehension brackets are
	 * PADDED (`openInside`/`closeInside` non-empty) — the runtime signal that
	 * `sameLine.comprehensionFor == fitLine` (fork's coupling); under `same`
	 * the brackets are tight and this returns null (no hug), preserving the
	 * unpadded house-style layout.
	 */
	private static function shapeComprehensionBlockHug(
		open: String, close: String, items: Array<Doc>, openInside: Doc, closeInside: Doc
	): Null<Doc> {
		final padded: Bool = switch openInside {
			case Empty:
				false;
			case _:
				true;
		};
		if (padded && items.length == 1 && isBlockBodyComprehensionItem(items[0]))
			return Concat([Text(open), openInside, items[0], closeInside, Text(close)]);
		return null;
	}

	/**
	 * The trimmed last-visible-Text of `d`, or `null`. Right-spine mirror of
	 * `firstVisibleText` — used to confirm a comprehension body is a `{ … }`
	 * BLOCK (last token `}`), distinguishing it from an expression body that
	 * merely wrapped (whose last token is the expression's own close).
	 */
	public static function lastVisibleText(d: Doc): Null<String> {
		return switch d {
			case Text(s):
				final t: String = StringTools.trim(s);
				t == '' ? null : t;
			case Concat(arr):
				var r: Null<String> = null;
				var i: Int = arr.length;
				while (--i >= 0 && r == null) r = lastVisibleText(arr[i]);
				r;
			case Group(i) | BodyGroup(i) | GroupWithRestProbe(i) | Nest(_, i) | Flatten(i) | HardFlatten(i) | CollapseProbe(i) | CollapseAddProbe(
				i
			) | WrapBoundary(i) | ConditionalMarkerZero(i) | ConditionalMarkerDecrease(i):
				lastVisibleText(i);
			case IfBreak(brk, _) | IfWidthExceeds(_, brk, _) | IfFirstLineExceeds(_, brk, _) | IfLineExceeds(_, brk, _) | IfResidualLineExceeds(
				_, brk, _
			) | IfFullLineExceeds(_, brk, _) | IfNaturalFirstLineExceeds(_, brk, _) | IfNaturalFirstLineFitsOpenDelim(_, brk, _):
				lastVisibleText(brk);
			case _:
				null;
		};
	}

	/**
	 * True iff `d`'s FIRST structural break (soft or hard line) is immediately
	 * preceded by an ARRAY open delimiter `[` — i.e. `d`'s multi-line-ness is
	 * owned by a (possibly nested) array literal whose open bracket sits at the
	 * end of the head line (`new X([\n … \n], y)`, `f([\n … \n])`). The
	 * generalisation of `startsWithCollectionDelim` from "STARTS with `[`" to
	 * "first BREAKS at `[`", so a call / `new` whose sole multi-line-ness is an
	 * array arg is recognised as huggable: the head up to the bracket rides the
	 * open-paren line, the bracket self-breaks one-per-line, and the arg tail
	 * (`], y)`) plus any inline sibling args ride the array-close line
	 * (`f(new X([\n … \n], y), z)`).
	 *
	 * ARRAY-ONLY (`[`, not `{`): an object / anon-type `{` at the first break is
	 * excluded — a function-signature param `x: Null<{…}>` breaks at that `{` too,
	 * and the fork opens the signature paren there rather than hugging it. Object-
	 * literal call args that START with `{` keep the existing `startsWithCollection
	 * Delim` path.
	 *
	 * A SOFT line reached before the bracket disqualifies `d`: the bracket then
	 * sits inside a chain (opAdd / opBool / ternary continuation) whose own wrap
	 * semantics the fork honours (it explodes the call rather than hugging).
	 *
	 * In-order left-spine DFS reusing `flatPushChildren`'s child order (so it
	 * descends the SAME flat side that `flatLength` walked to prove `d` breaks —
	 * the caller gates on `flatLength(d) < 0` first, so a raw hardline is
	 * guaranteed reachable here). Tracks the last Text leaf's final char and, at
	 * the first line break, answers whether that char is `[`. O(spine up to the
	 * first break), no re-measure.
	 */
	private static function firstBreakIsArrayDelim(d: Doc): Bool {
		final stack: Array<Doc> = [d];
		var lastCh: Int = -1;
		while (stack.length > 0) {
			final node: Doc = stack.pop();
			switch (node) {
				case Text(s):
					if (s.length > 0) lastCh = StringTools.fastCodeAt(s, s.length - 1);
				case Line(_):
					// A SOFT line (opAdd / opBool / ternary continuation) reaching before
					// the bracket means the array is NOT the arg's first break — its owning
					// chain has its own wrap semantics (fork explodes the call, does not
					// hug). Stop here: only a `[` at the VERY first break qualifies.
					return lastCh == '['.code;
				case OptHardline | OptHardlineSkipAtOpenDelim | OptHardlineSkipBeforeHardline:
					return lastCh == '['.code;
				case _:
					flatPushChildren(node, stack);
			}
		}
		return false;
	}


	/**
	 * True iff `item` is a paren/bare arrow-lambda arg whose body is a PLAIN
	 * `if` (no top-level `else`) that is NOT a `{}`-block. Such an arrow hides
	 * its `if`-then-branch behind a `BodyGroup`, which `DocMeasure.flatTokenWidth`
	 * defers to width 0 — under-measuring the arg so the `callParameter` cascade
	 * mis-picks NoWrap / fill-hug even when the body overflows. `emit` gates `groupifyInlineBodies` on this predicate so exactly this arg shape has its hardline-free `BodyGroup`s re-tagged as render-identical `Group`s, making the true width visible so an overflowing plain-`if` arrow opens the call (fork parity). Block-body arrows (`arrowBodyIsBlock`) and if-ELSE arrows
	 * (`hasTopLevelElse`) are excluded: the former hugs (block owns its layout),
	 * the latter is the landed thin-arrow if-else path.
	 */
	private static function isArrowPlainIfBody(item: Doc): Bool {
		if (!isArrowBodyMarker(item) || arrowBodyIsBlock(item)) return false;
		final body: Null<Doc> = arrowBodyDoc(item);
		if (body == null) return false;
		return firstVisibleText(body) == 'if' && !hasTopLevelElse(body, 0);
	}


	/**
	 * Deep-map that re-tags every hardline-FREE `BodyGroup` inside `d` as a
	 * plain `Group` (block bodies — `flatLength(inner) < 0` — stay deferred
	 * `BodyGroup`s). At render time `Group` and `BodyGroup` are identical
	 * (same `fitsFlat` decision), so the produced layout is byte-unchanged;
	 * the ONLY difference is static width measurement — `DocMeasure
	 * .flatTokenWidth` / `fitsFlat` DEFER a `BodyGroup` (width 0) but DESCEND a
	 * `Group`. Applied by `emit` to an arrow-lambda arg whose body is a plain
	 * `if` (`isArrowPlainIfBody`): the if-then-branch lives behind a
	 * `BodyGroup`, so the whole arg under-measures and the `callParameter`
	 * cascade / fill-pack / outer-Group fit all mis-hug even when the body
	 * overflows. Exposing the true width lets the call open on the overflowing
	 * line — matching the fork, which measures the full arrow line.
	 */
	private static function groupifyInlineBodies(d: Doc): Doc {
		return switch d {
			case Empty | Text(_) | Line(_) | OptSpace(_) | OptHardline | OptHardlineSkipAtOpenDelim | OptHardlineSkipBeforeHardline
				| OptSpaceSkipAfterHardline:
				d;
			case BodyGroup(inner):
				flatLength(inner) >= 0 ? Group(groupifyInlineBodies(inner)) : BodyGroup(groupifyInlineBodies(inner));
			case Group(inner):
				Group(groupifyInlineBodies(inner));
			case GroupWithRestProbe(inner):
				GroupWithRestProbe(groupifyInlineBodies(inner));
			case Nest(n, inner):
				Nest(n, groupifyInlineBodies(inner));
			case Flatten(inner):
				Flatten(groupifyInlineBodies(inner));
			case WrapBoundary(inner):
				WrapBoundary(groupifyInlineBodies(inner));
			case HardFlatten(inner):
				HardFlatten(groupifyInlineBodies(inner));
			case CollapseProbe(inner):
				CollapseProbe(groupifyInlineBodies(inner));
			case CollapseAddProbe(inner):
				CollapseAddProbe(groupifyInlineBodies(inner));
			case CollapseBoolProbe(inner):
				CollapseBoolProbe(groupifyInlineBodies(inner));
			case CollapseChainProbe(inner):
				CollapseChainProbe(groupifyInlineBodies(inner));
			case ConditionalMarkerZero(inner):
				ConditionalMarkerZero(groupifyInlineBodies(inner));
			case ConditionalMarkerDecrease(inner):
				ConditionalMarkerDecrease(groupifyInlineBodies(inner));
			case Concat(items):
				Concat([for (it in items) groupifyInlineBodies(it)]);
			case IfBreak(b, f):
				IfBreak(groupifyInlineBodies(b), groupifyInlineBodies(f));
			case IfWidthExceeds(n, b, f):
				IfWidthExceeds(n, groupifyInlineBodies(b), groupifyInlineBodies(f));
			case IfFirstLineExceeds(n, b, f):
				IfFirstLineExceeds(n, groupifyInlineBodies(b), groupifyInlineBodies(f));
			case IfLineExceeds(n, b, f):
				IfLineExceeds(n, groupifyInlineBodies(b), groupifyInlineBodies(f));
			case IfResidualLineExceeds(n, b, f):
				IfResidualLineExceeds(n, groupifyInlineBodies(b), groupifyInlineBodies(f));
			case IfFullLineExceeds(n, b, f):
				IfFullLineExceeds(n, groupifyInlineBodies(b), groupifyInlineBodies(f));
			case IfNaturalFirstLineExceeds(n, b, f):
				IfNaturalFirstLineExceeds(n, groupifyInlineBodies(b), groupifyInlineBodies(f));
			case IfNaturalFirstLineFitsOpenDelim(n, b, f):
				IfNaturalFirstLineFitsOpenDelim(n, groupifyInlineBodies(b), groupifyInlineBodies(f));
			case IfArrowContinuationFits(ei, fw, n, b, f):
				IfArrowContinuationFits(ei, fw, n, groupifyInlineBodies(b), groupifyInlineBodies(f));
			case Fill(items, sep, tr):
				Fill([for (it in items) groupifyInlineBodies(it)], groupifyInlineBodies(sep), tr);
			case FillWithRestProbe(items, sep, tr):
				FillWithRestProbe([for (it in items) groupifyInlineBodies(it)], groupifyInlineBodies(sep), tr);
			case FillBreakAfterWrap(items, sep, tr):
				FillBreakAfterWrap([for (it in items) groupifyInlineBodies(it)], groupifyInlineBodies(sep), tr);
		};
	}

}
