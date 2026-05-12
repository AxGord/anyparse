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
	 * `Empty`/`Empty` — pre-slice callers see no behavioural change.
	 * Slice ω-objectlit-leftCurly-cascade — first consumer is
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
	 * Slice ω-objectlit-source-trail-comma — first consumer is
	 * `HxObjectLit.fields`.
	 *
	 * `trailBreak`: the Doc emitted immediately before `Text(close)` in
	 * the `OnePerLine` shape. Null defaults to `Line('\n')` — the
	 * legacy hardcoded close-on-own-line layout — so pre-slice callers
	 * stay byte-identical. Per-construct `RightCurlyPlacement` knobs
	 * pass `Empty` for `Inline` (close glued to last body token) or
	 * `Line('\n')` for `Same`. Mirrors the trivia branch's
	 * `triviaTrailDoc` in `WriterLowering.triviaSepStarExpr` so wrap-
	 * engine and trivia paths honour the same
	 * `RightCurlyPlacement.{Inline,Same}` semantic. Honoured by
	 * `shapeOnePerLine` only — `OnePerLineAfterFirst` / `FillLine` glue
	 * close by mode design and have no Inline-vs-Same axis to express.
	 * Slice ω-wraplist-trailbreakdoc — first consumers are
	 * `HxObjectLit.fields` and `HxType.Anon` via `triviaSepStarExpr`.
	 *
	 * `forceMode`: optional `WrapMode` override that bypasses the
	 * cascade and forces a single mode regardless of `evalAt(...)`.
	 * `null` (default) is the pre-slice behaviour — the cascade runs
	 * normally. Non-null short-circuits both `exceeds=false` and
	 * `exceeds=true` evaluations to the supplied mode AND skips
	 * extra-threshold enumeration, so the renderer commits
	 * unconditionally to one shape (no `IfBreak` wrapping needed).
	 * Used by `@:fmt(forceMultiInTypedef)` on typedef-RHS anon types
	 * to thread `WrapMode.OnePerLine` when `opt._inTypedefBody=true`,
	 * matching fork's `MarkLineEnds.markTypedef` parent-walk forcing
	 * `=\n{\n\t...\n}` shape regardless of field count or fit.
	 * Slice ω-typedef-anon-force-multi.
	 */
	public static function emit(
		open:String, close:String, sep:String,
		items:Array<Doc>, opt:WriteOptions,
		openInside:Doc, closeInside:Doc,
		keepInnerWhenEmpty:Bool, rules:WrapRules,
		appendTrailingComma:Bool = false,
		leadFlat:Doc = Empty, leadBreak:Doc = Empty,
		forceExceeds:Bool = false,
		?trailBreak:Doc,
		?forceMode:Null<WrapMode>
	):Doc {
		// `Line('\n')` is not a Haxe-constant default — unwrap a null
		// sentinel into the legacy hardcoded hardline here.
		final trailBreakDoc:Doc = trailBreak ?? Line('\n');
		if (items.length == 0)
			return Text(open + (keepInnerWhenEmpty ? ' ' : '') + close);

		// Decoupled measurement (ω-flatlength-decouple-tokenwidth):
		//   - `flatLength(item) < 0` retains its legacy semantic and
		//     drives `anyHardline` — preserves the (b) break-commit
		//     shortcut on items with hardlines anywhere (including
		//     inside `BodyGroup`).
		//   - `DocMeasure.flatTokenWidth(item)` feeds clean widths to
		//     cascade rule conditions — mirrors `Renderer.fitsFlat`'s
		//     BG-defer so `LineLengthLargerThan` /
		//     `TotalItemLengthLargerThan` / `AnyItemLengthLargerThan` see
		//     the same widths the renderer would lay out flat. Replaces
		//     the old `HARDLINE_LEN` (~1M) inflation that conflated "has
		//     hardline anywhere" with "rule-bound widths".
		var total:Int = 0;
		var maxLen:Int = 0;
		var anyHardline:Bool = false;
		for (item in items) {
			if (flatLength(item) < 0) anyHardline = true;
			final w:Int = DocMeasure.flatTokenWidth(item);
			total += w;
			if (w > maxLen) maxLen = w;
		}

		final cols:Int = opt.indentChar == IndentChar.Space ? opt.indentSize : opt.tabWidth;

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
		final extraThresholds:Array<Int> = collectExtraLineLengthThresholds(rules, opt.lineWidth);

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
		function evalAt(exceeds:Bool, firing:Array<Int>):WrapMode {
			if (forceMode != null) return forceMode;
			return decideWithLineLengthState(rules, items.length, maxLen, total,
				exceeds, anyHardline,
				t -> t == opt.lineWidth ? exceeds : firing.contains(t));
		}

		// Per-state shape builder: picks the right lead based on the
		// resolved mode (flat vs break-style layout).
		function shapeAt(mode:WrapMode, lead:Doc):Doc {
			final body:Doc = shape(mode, open, close, sep, items, openInside, closeInside, cols, appendTrailingComma, trailBreakDoc);
			return prependLead(body, lead);
		}

		function leadFor(mode:WrapMode):Doc {
			return isFlatMode(mode) ? leadFlat : leadBreak;
		}

		// Force-break path: cascade evaluated only against
		// `exceeds=true`. Thresholds still column-aware — even when
		// the parent commits to break-mode, a `LineLengthLargerThan`
		// rule answer can flip with column position. The unified
		// `buildThresholdTree` helper handles 0/1/N thresholds via
		// recursion (1-threshold optimization with impossibility
		// filtering inlined for the common case below).
		if (anyHardline || forceExceeds)
			return buildThresholdTree(extraThresholds, [], true, leadFlat, leadBreak, evalAt, shapeAt, leadFor);

		// Normal path: cascade evaluated against (exceeds=false /
		// exceeds=true) AND each non-lineWidth threshold's firing
		// state. Tree construction:
		//   - 0 extra thresholds: existing 2-state Group(IfBreak)
		//   - 1 extra threshold T (impossibility-filtered, 3 shapes):
		//       * T < lineWidth: `IfWidthExceeds(T, IfBreak(YY, YN), NN)`
		//         (no T-no/exceeds-yes — impossible since col<T → col<lineWidth)
		//       * T > lineWidth: `IfBreak(IfWidthExceeds(T, YY, NY), NN)`
		//         (no T-yes/exceeds-no — impossible since col>=T>lineWidth → exceeds)
		//   - 2+ extra thresholds: full enumeration via
		//     `buildThresholdTree` (each `IfWidthExceeds(t, …)` nests
		//     the next threshold). Impossibility filtering not applied
		//     at N≥2; renderer never reaches the impossible-state
		//     leaves at runtime, so the extra Doc shapes are inert.
		//     None of the current default cascades use N≥2 — this
		//     branch is correctness insurance for future cascades.
		if (extraThresholds.length == 0) {
			final modeFlat:WrapMode = evalAt(false, []);
			final modeBreak:WrapMode = evalAt(true, []);
			if (modeFlat == modeBreak)
				return shapeAt(modeFlat, leadFor(modeFlat));
			final flatWithLead:Doc = shapeAt(modeFlat, leadFlat);
			final breakWithLead:Doc = shapeAt(modeBreak, leadBreak);
			return Group(IfBreak(breakWithLead, flatWithLead));
		}

		if (extraThresholds.length == 1) {
			final t:Int = extraThresholds[0];
			if (t < opt.lineWidth) {
				// 3 valid states (col+w<t implies col+w<lineWidth implies !exceeds):
				//   (firing=∅,    exceeds=no)  → modeNN
				//   (firing={t},  exceeds=no)  → modeYN
				//   (firing={t},  exceeds=yes) → modeYY
				final modeNN:WrapMode = evalAt(false, []);
				final modeYN:WrapMode = evalAt(false, [t]);
				final modeYY:WrapMode = evalAt(true, [t]);
				final shapeNN:Doc = shapeAt(modeNN, leadFor(modeNN));
				final shapeYN:Doc = shapeAt(modeYN, leadFor(modeYN));
				final shapeYY:Doc = shapeAt(modeYY, leadFor(modeYY));
				if (modeNN == modeYN && modeYN == modeYY) return shapeNN;
				// Inner IfBreak picks between exceeds-yes and exceeds-no
				// when the column has already crossed `t`. Outer
				// IfWidthExceeds picks the column-vs-t answer first; the
				// flat side bypasses the IfBreak entirely (only one
				// valid state below `t`).
				final brk:Doc = (modeYY == modeYN) ? shapeYY : Group(IfBreak(shapeYY, shapeYN));
				return Group(IfWidthExceeds(t, brk, shapeNN));
			}
			// t > lineWidth: 3 valid states (col+w>=t implies col+w>=lineWidth):
			//   (firing=∅,    exceeds=no)  → modeNN
			//   (firing=∅,    exceeds=yes) → modeNY
			//   (firing={t},  exceeds=yes) → modeYY
			final modeNN:WrapMode = evalAt(false, []);
			final modeNY:WrapMode = evalAt(true, []);
			final modeYY:WrapMode = evalAt(true, [t]);
			final shapeNN:Doc = shapeAt(modeNN, leadFor(modeNN));
			final shapeNY:Doc = shapeAt(modeNY, leadFor(modeNY));
			final shapeYY:Doc = shapeAt(modeYY, leadFor(modeYY));
			if (modeNN == modeNY && modeNY == modeYY) return shapeNN;
			// Outer IfBreak picks exceeds=no/yes; inner IfWidthExceeds
			// further partitions the exceeds=yes side around `t`.
			final brk:Doc = (modeNY == modeYY) ? shapeYY : Group(IfWidthExceeds(t, shapeYY, shapeNY));
			return Group(IfBreak(brk, shapeNN));
		}

		// 2+ extra thresholds — full enumeration without impossibility
		// filtering. Renderer's column-aware probe at each
		// IfWidthExceeds layer picks the correct leaf at runtime.
		return buildThresholdTree(extraThresholds, [], null, leadFlat, leadBreak, evalAt, shapeAt, leadFor);
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
	 * 0 → noWrap` cascade. Slice ω-condition-wrap-wiring.
	 */
	public static function emitCondition(
		open:String, close:String,
		condDoc:Doc, opt:WriteOptions, rules:WrapRules
	):Doc {
		final cols:Int = opt.indentChar == IndentChar.Space ? opt.indentSize : opt.tabWidth;
		final condW:Int = DocMeasure.flatTokenWidth(condDoc);
		final hasHardline:Bool = flatLength(condDoc) < 0;

		final flatShape:Doc = Concat([Text(open), condDoc, Text(close)]);
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
		final brkShape:Doc = Concat([
			Text(open),
			Nest(cols, Concat([Line('\n'), condDoc])),
			Line('\n'),
			Text(close),
		]);

		inline function decideAt(exceeds:Bool):WrapMode {
			return decideWithLineLengthState(
				rules, 1, condW, condW, exceeds, hasHardline,
				t -> t == opt.lineWidth ? exceeds : false
			);
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
		inline function shapeFor(mode:WrapMode):Doc {
			return mode == FillLineWithLeadingBreak ? brkShape : flatShape;
		}

		if (hasHardline) return shapeFor(decideAt(true));

		final modeFlat:WrapMode = decideAt(false);
		final modeBreak:WrapMode = decideAt(true);
		final flatBrk:Bool = modeFlat == FillLineWithLeadingBreak;
		final breakBrk:Bool = modeBreak == FillLineWithLeadingBreak;
		if (flatBrk == breakBrk) return shapeFor(modeFlat);
		// `IfLineExceeds` over `Group(IfBreak(…))`: `Group` only measures
		// the cond's own flat width; trailing tokens on the same rendered
		// line (e.g. ` {` after the close paren on `if`-stmt sites)
		// vanish from the fit decision — a 129-col `(cond)` fits exactly
		// at the 11-col `\t\tif ` start but the trailing ` {` pushes the
		// rendered line to 142 > 140 lineWidth. `IfLineExceeds` adds the
		// `flatTokenWidthOfRestStack` lookahead so the probe accounts for
		// what lands on the same line if the flat branch fires. Closes
		// the Wadler-style local-Group blindspot for cond-wrap sites.
		return IfLineExceeds(opt.lineWidth, shapeFor(modeBreak), shapeFor(modeFlat));
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
		thresholds:Array<Int>, firing:Array<Int>,
		forcedExceeds:Null<Bool>, leadFlat:Doc, leadBreak:Doc,
		evalAt:(Bool, Array<Int>) -> WrapMode,
		shapeAt:(WrapMode, Doc) -> Doc,
		leadFor:WrapMode -> Doc
	):Doc {
		if (thresholds.length == 0) {
			if (forcedExceeds != null) {
				final mode:WrapMode = evalAt(forcedExceeds, firing);
				return shapeAt(mode, leadFor(mode));
			}
			final modeFlat:WrapMode = evalAt(false, firing);
			final modeBreak:WrapMode = evalAt(true, firing);
			if (modeFlat == modeBreak)
				return shapeAt(modeFlat, leadFor(modeFlat));
			final flatWithLead:Doc = shapeAt(modeFlat, leadFlat);
			final breakWithLead:Doc = shapeAt(modeBreak, leadBreak);
			return Group(IfBreak(breakWithLead, flatWithLead));
		}
		final t:Int = thresholds[0];
		final rest:Array<Int> = thresholds.slice(1);
		final firingPlus:Array<Int> = firing.copy();
		firingPlus.push(t);
		final brk:Doc = buildThresholdTree(rest, firingPlus, forcedExceeds, leadFlat, leadBreak, evalAt, shapeAt, leadFor);
		final flat:Doc = buildThresholdTree(rest, firing, forcedExceeds, leadFlat, leadBreak, evalAt, shapeAt, leadFor);
		return IfWidthExceeds(t, brk, flat);
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
	public static function collectExtraLineLengthThresholds(rules:WrapRules, lineWidth:Int):Array<Int> {
		final out:Array<Int> = [];
		for (rule in rules.rules) {
			for (cond in rule.conditions) {
				if (cond.cond == LineLengthLargerThan && cond.value != lineWidth && out.indexOf(cond.value) < 0)
					out.push(cond.value);
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
		rules:WrapRules, itemCount:Int, maxItemLen:Int,
		totalItemLen:Int, exceedsMaxLineLength:Bool,
		hasMultilineItems:Bool, lineLengthFires:Int -> Bool
	):WrapMode {
		for (rule in rules.rules) {
			if (matchesWithLineLengthState(rule, itemCount, maxItemLen, totalItemLen,
					exceedsMaxLineLength, hasMultilineItems, lineLengthFires))
				return rule.mode;
		}
		return rules.defaultMode;
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
		rules:WrapRules, itemCount:Int, maxItemLen:Int,
		totalItemLen:Int, exceedsMaxLineLength:Bool,
		hasMultilineItems:Bool, lineLengthFires:Int -> Bool
	):{mode:WrapMode, location:WrappingLocation} {
		final fallback:WrappingLocation = rules.defaultLocation ?? WrappingLocation.AfterLast;
		for (rule in rules.rules) {
			if (matchesWithLineLengthState(rule, itemCount, maxItemLen, totalItemLen,
					exceedsMaxLineLength, hasMultilineItems, lineLengthFires))
				return {mode: rule.mode, location: rule.location ?? fallback};
		}
		return {mode: rules.defaultMode, location: fallback};
	}

	private static function matchesWithLineLengthState(
		rule:WrapRule, itemCount:Int, maxItemLen:Int,
		totalItemLen:Int, exceedsMaxLineLength:Bool,
		hasMultilineItems:Bool, lineLengthFires:Int -> Bool
	):Bool {
		for (cond in rule.conditions) {
			final ok:Bool = switch cond.cond {
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
	 * Walks a `Doc` tree and returns its flat-mode width in columns.
	 * Returns `-1` when the tree contains a forced hardline
	 * (`Line` whose flat replacement starts with `\n`) — those trees
	 * cannot be laid out in flat mode at all and the caller should
	 * pick a break-mode shape unconditionally.
	 */
	public static function flatLength(d:Doc):Int {
		final stack:Array<Doc> = [d];
		var total:Int = 0;
		while (stack.length > 0) {
			final node:Doc = stack.pop();
			switch (node) {
				case Empty:
				case Text(s):
					total += s.length;
				case Line(flat):
					if (flat.length > 0 && StringTools.fastCodeAt(flat, 0) == '\n'.code)
						return -1;
					total += flat.length;
				case Nest(_, inner):
					stack.push(inner);
				case Concat(items):
					var i:Int = items.length;
					while (--i >= 0) stack.push(items[i]);
				case Group(inner) | BodyGroup(inner):
					stack.push(inner);
				case IfBreak(_, flatDoc):
					stack.push(flatDoc);
				case IfWidthExceeds(_, _, flatDoc):
					// Forward to flat side: width measurement reflects
					// what the flat shape would consume. Mirrors `IfBreak`
					// arm — the column-aware decision happens at render
					// time, not in static walks.
					stack.push(flatDoc);
				case IfFirstLineExceeds(_, _, flatDoc):
					// Mirror `IfWidthExceeds` arm: forward to flat side.
					// First-line cap is renderer-side; static walks see
					// the full flat shape.
					stack.push(flatDoc);
				case IfLineExceeds(_, _, flatDoc):
					// Mirror `IfWidthExceeds` arm: forward to flat side.
					// Rest-of-stack lookahead is renderer-side (slice
					// ω-iflineexceeds-infra).
					stack.push(flatDoc);
				case IfFullLineExceeds(_, _, flatDoc):
					// Mirror `IfLineExceeds` arm: forward to flat side.
					// Asymmetric BG semantic only applies to renderer-
					// side rest-of-stack probe.
					stack.push(flatDoc);
				case Fill(items, sep):
					var k:Int = items.length;
					while (k > 0) {
						k--;
						stack.push(items[k]);
						if (k > 0) stack.push(sep);
					}
				case OptSpace(s):
					// OptSpace contributes its length to flat measurement
					// (mirrors `Renderer.fitsFlat`): in a flat layout the
					// optional trailing space always renders, only break
					// mode discards it. Wrap-rules-cascade measurements
					// must therefore include it.
					total += s.length;
				case OptSpaceSkipAfterHardline:
					// Mirror `OptSpace`: width-1 byte for flat measurement.
					// Runtime-time drop only fires when `lastEmit==Hardline`
					// which can never hold inside a flat-shape probe.
					total += 1;
				case OptHardline | OptHardlineSkipAtOpenDelim:
					// Both opt-hardline variants can never flatten —
					// mirrors `Line('\n')` returning -1 (and
					// `Renderer.fitsFlat`'s OptHardline arm). Any item
					// containing either forces the wrap engine into
					// break mode unconditionally.
					return -1;
			}
		}
		return total;
	}

	/**
	 * Walks `d` right-to-left tracking `Nest` depth, returns the depth
	 * at which the rightmost forced hardline (`Line('\n')` or
	 * `OptHardline`) lives. Returns `-1` when `d` contains no forced
	 * hardline at all.
	 *
	 * Used by `shapeFillLine`'s single-item branch as a trigger for
	 * splitting close-paren placement into a flat vs break `IfBreak`
	 * shape: when the item's tail in MBreak would land at an inner-
	 * `Nest` column (chain segments via `MethodChainEmit`'s break shape,
	 * `IfBreak.brk` content with its own continuation Nest), inserting
	 * a `Line('\n')` before the close paren returns the close to the
	 * outer column. The flat branch is needed because the same item
	 * may render as MFlat (chain that fits inline, `BodyGroup`-deferred
	 * lambda body) and the close should glue to the last token.
	 *
	 * `IfBreak` walks the break branch (the question we're answering is
	 * about MBreak layout). `Fill` items are NOT walked — they're
	 * typically `BodyGroup`-wrapped and their hardlines defer from
	 * outer-Group fit measurement; only the sep contributes (a hard
	 * `Line('\n')` sep signals a chunk-boundary inter-item layout per
	 * the post-`ω-fillline-pergap-sep` shapeFillLine structure).
	 */
	public static function lastHardlineDepth(d:Doc, depth:Int):Int {
		return switch d {
			case Empty | Text(_) | OptSpace(_) | OptSpaceSkipAfterHardline: -1;
			case Line(flat):
				flat.length > 0 && StringTools.fastCodeAt(flat, 0) == '\n'.code ? depth : -1;
			case OptHardline | OptHardlineSkipAtOpenDelim: depth;
			case Nest(cols, inner): lastHardlineDepth(inner, depth + cols);
			case Group(inner) | BodyGroup(inner): lastHardlineDepth(inner, depth);
			case IfBreak(brk, _): lastHardlineDepth(brk, depth);
			case IfWidthExceeds(_, brk, _): lastHardlineDepth(brk, depth);
			case IfFirstLineExceeds(_, brk, _): lastHardlineDepth(brk, depth);
			case IfLineExceeds(_, brk, _): lastHardlineDepth(brk, depth);
			case IfFullLineExceeds(_, brk, _): lastHardlineDepth(brk, depth);
			case Concat(items):
				var i:Int = items.length;
				while (--i >= 0) {
					final r:Int = lastHardlineDepth(items[i], depth);
					if (r >= 0) return r;
				}
				-1;
			case Fill(items, sep):
				items.length > 1 ? lastHardlineDepth(sep, depth) : -1;
		};
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
	public static function startsWithHardline(d:Doc):Bool {
		var node:Doc = d;
		while (true) switch node {
			case Empty | Text(_) | OptSpace(_) | OptSpaceSkipAfterHardline:
				return false;
			case Line(flat):
				return flat.length > 0 && StringTools.fastCodeAt(flat, 0) == '\n'.code;
			case OptHardline | OptHardlineSkipAtOpenDelim:
				// Both opt-hardline variants count as a leading hardline
				// for the wrap-engine `(...)` shape decision. The new
				// ctor's render-time drop (when inside an open delim)
				// keeps items[0] glued, but the structural answer here
				// stays "yes, inner has a leading break point" so the
				// wrap still places close on its own line.
				return true;
			case Nest(_, inner) | Group(inner) | BodyGroup(inner):
				node = inner;
			case IfBreak(brk, _):
				node = brk;
			case IfWidthExceeds(_, brk, _):
				node = brk;
			case IfFirstLineExceeds(_, brk, _):
				node = brk;
			case IfLineExceeds(_, brk, _):
				node = brk;
			case IfFullLineExceeds(_, brk, _):
				node = brk;
			case Concat(items):
				final first:Null<Doc> = items.find(it -> !isLeadingTransparent(it));
				if (first == null) return false;
				node = first;
			case Fill(items, _):
				final first:Null<Doc> = items.find(it -> !isLeadingTransparent(it));
				if (first == null) return false;
				node = first;
		}
	}

	/**
	 * Wrap `body` with `lead` unless `lead` is `Empty` — avoids a
	 * pointless single-element `Concat` for the common no-lead path.
	 */
	private static inline function prependLead(body:Doc, lead:Doc):Doc {
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
	private static inline function isFlatMode(mode:WrapMode):Bool {
		return switch mode {
			case NoWrap: true;
			case _: false;
		};
	}

	private static function shape(
		mode:WrapMode, open:String, close:String, sep:String,
		items:Array<Doc>, openInside:Doc, closeInside:Doc, cols:Int,
		appendTrailingComma:Bool, trailBreak:Doc
	):Doc {
		return switch mode {
			case NoWrap: shapeNoWrap(open, close, sep, items, openInside, closeInside);
			case OnePerLine: shapeOnePerLine(open, close, sep, items, cols, appendTrailingComma, trailBreak);
			case OnePerLineAfterFirst: shapeOnePerLineAfterFirst(open, close, sep, items, cols, appendTrailingComma);
			case FillLine | FillLineWithLeadingBreak: shapeFillLine(open, close, sep, items, openInside, closeInside, cols, appendTrailingComma);
			case _: shapeNoWrap(open, close, sep, items, openInside, closeInside);
		};
	}

	private static function shapeNoWrap(
		open:String, close:String, sep:String, items:Array<Doc>,
		openInside:Doc, closeInside:Doc
	):Doc {
		final inner:Array<Doc> = [];
		for (i in 0...items.length) {
			if (i > 0) inner.push(Text(sep + ' '));
			inner.push(items[i]);
		}
		return Concat([Text(open), openInside, Concat(inner), closeInside, Text(close)]);
	}

	private static function shapeOnePerLine(
		open:String, close:String, sep:String, items:Array<Doc>, cols:Int,
		appendTrailingComma:Bool, trailBreak:Doc
	):Doc {
		final inner:Array<Doc> = [];
		for (i in 0...items.length) {
			inner.push(Line('\n'));
			inner.push(items[i]);
			if (i < items.length - 1 || appendTrailingComma) inner.push(Text(sep));
		}
		// `trailBreak` per-construct rightCurly substitution
		// (ω-wraplist-trailbreakdoc). Default `Line('\n')` preserves the
		// legacy close-on-own-line layout; `Empty` produced from
		// `RightCurlyPlacement.Inline` glues close to the last body
		// token. See `emit` docstring for the full rationale.
		return Concat([Text(open), Nest(cols, Concat(inner)), trailBreak, Text(close)]);
	}

	private static function shapeOnePerLineAfterFirst(
		open:String, close:String, sep:String, items:Array<Doc>, cols:Int,
		appendTrailingComma:Bool
	):Doc {
		if (items.length == 1)
			return Concat([Text(open), items[0], Text(close)]);
		final tail:Array<Doc> = [];
		for (i in 1...items.length) {
			tail.push(Text(sep));
			tail.push(Line('\n'));
			tail.push(items[i]);
		}
		if (appendTrailingComma) tail.push(Text(sep));
		return Concat([
			Text(open), items[0],
			Nest(cols, Concat(tail)),
			Text(close),
		]);
	}

	private static function shapeFillLine(
		open:String, close:String, sep:String, items:Array<Doc>,
		openInside:Doc, closeInside:Doc, cols:Int,
		appendTrailingComma:Bool
	):Doc {
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
			final tail0:Doc = appendTrailingComma ? Text(sep) : Empty;
			// Close-paren placement: when `items[0]` contains an
			// inner-anchored hardline (something inside one or more
			// `Nest(cols, …)` layers — e.g. method-chain segments via
			// `MethodChainEmit`'s break-shape, or `IfBreak`'s break
			// branch when the inner content commits to break), the
			// close paren should land at the outer column instead of
			// gluing to the last inner-anchored token. But the inner
			// might also stay flat (chain that fits inline, lambda
			// whose body is `BodyGroup`-deferred and outer Group goes
			// MFlat). We don't know which way the renderer's outer
			// Group will go, so emit BOTH shapes through `IfBreak` and
			// let the outer Group's `fitsFlat` pick the right one:
			//  - flat → `(<item>)` (close glued, lambda-style)
			//  - brk  → `(<item>\n<close>)` (close on own line, chain-style)
			// `lastHardlineDepth` is the trigger for the IfBreak split;
			// when no inner-anchored hardline exists at all
			// (depth ≤ 0), there's no scenario where break-before-close
			// is needed, so emit the simpler `(<item>)` shape directly.
			final lastDepth:Int = lastHardlineDepth(items[0], 0);
			if (lastDepth > 0) {
				return Group(IfBreak(
					Concat([
						Text(open), openInside, items[0], tail0,
						Line('\n'), closeInside, Text(close),
					]),
					Concat([
						Text(open), openInside, items[0], tail0,
						closeInside, Text(close),
					])
				));
			}
			return Group(Concat([
				Text(open), openInside, items[0], tail0,
				closeInside, Text(close),
			]));
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
		final softSep:Doc = Concat([Text(sep), Line(' ')]);
		final bodyParts:Array<Doc> = [];
		var chunkStart:Int = 0;
		for (i in 1...items.length + 1) {
			final atEnd:Bool = i == items.length;
			final hardLed:Bool = !atEnd && hasLeadingHardline(items[i]);
			if (atEnd || hardLed) {
				if (chunkStart > 0) {
					bodyParts.push(Text(sep));
					bodyParts.push(Line('\n'));
				}
				if (i - chunkStart == 1) {
					bodyParts.push(items[chunkStart]);
				} else {
					final chunk:Array<Doc> = items.slice(chunkStart, i);
					bodyParts.push(Fill(chunk, softSep));
				}
				chunkStart = i;
			}
		}
		final tail:Doc = appendTrailingComma ? Text(sep) : Empty;
		final inner:Doc = Concat([Concat(bodyParts), tail]);
		return Group(Concat([
			Text(open), openInside,
			Nest(cols, inner),
			closeInside, Text(close),
		]));
	}

	/**
	 * Walks the leading edge of `d` and returns `true` if the first
	 * Doc that emits visible content is a hardline (`Line('\n')` or
	 * `OptHardline`). Skips through transparent wrappers (`Empty`,
	 * single-leading-edge Concat slot, `Group` / `BodyGroup` / `Nest`
	 * inner). Used by `emit` to decide whether the FillLine shape
	 * must commit to break mode unconditionally.
	 */
	private static function hasLeadingHardline(d:Doc):Bool {
		return switch d {
			case Empty: false;
			case OptHardline | OptHardlineSkipAtOpenDelim: true;
			case Line(flat): flat.length > 0 && StringTools.fastCodeAt(flat, 0) == '\n'.code;
			case Text(_): false;
			case OptSpace(_): false;
			case OptSpaceSkipAfterHardline: false;
			case Nest(_, inner): hasLeadingHardline(inner);
			case Group(inner) | BodyGroup(inner): hasLeadingHardline(inner);
			case IfBreak(_, _): false;
			case IfWidthExceeds(_, _, _): false;
			case IfFirstLineExceeds(_, _, _): false;
			case IfLineExceeds(_, _, _): false;
			case IfFullLineExceeds(_, _, _): false;
			case Concat(items):
				for (it in items) {
					if (hasLeadingHardline(it)) return true;
					if (!isLeadingTransparent(it)) return false;
				}
				false;
			case Fill(items, _):
				items.length > 0 && hasLeadingHardline(items[0]);
		};
	}

	private static inline function isLeadingTransparent(d:Doc):Bool {
		return switch d {
			case Empty: true;
			case Concat([]): true;
			case _: false;
		};
	}
}
