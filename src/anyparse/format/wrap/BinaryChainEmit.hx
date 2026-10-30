package anyparse.format.wrap;

import anyparse.core.BreakCommits;
import anyparse.core.D;
import anyparse.core.Doc;
import anyparse.core.DocMeasure;
import anyparse.format.IndentChar;

using StringTools;
using Lambda;

/**
 * Runtime helper that emits a `Doc` for a binary-op chain construct (`a || b || c`,
 * `a + b - c + d`) whose layout is driven by a `WrapRules` cascade.
 *
 * Format-neutral: the chain extraction happens in a grammar-specific helper that
 * knows the language's BinOp ctors, and this engine takes the pre-built
 * `items: Array<Doc>` — each already rendered through the host writer —
 * interleaved by an `ops: Array<String>` of one operator text per gap, so
 * `items.length == ops.length + 1`.
 *
 * Differs from `WrapList.emit` in three ways: a chain has NO open / close
 * delimiters, since its operands are bare; the operator text differs per position
 * (a mixed `||` / `&&` chain), so the engine takes a parallel `ops` array rather
 * than a single separator; and operator PLACEMENT is a second axis on top of the
 * `WrapMode` — `BeforeLast` starts each continuation line with the operator,
 * `AfterLast` ends the previous line with it, and the fill shapes pack through
 * `Fill` so the operator rides ahead of or behind the soft line accordingly.
 *
 * That axis is selected per rule by `WrapRule.location`, falling back to
 * `WrapRules.defaultLocation`, and resolved by
 * `WrapList.decideRuleWithLineLengthState` — the column-aware variant of
 * `decideRule` that defers a `LineLengthLargerThan` to a caller-supplied predicate
 * so the renderer's own column can gate threshold-firing at layout time. The mode
 * and location vocabularies themselves are documented in
 * `docs/haxe-format-config.md`.
 */
@:nullSafety(Strict)
final class BinaryChainEmit {

	/**
	 * OVERFLOW-ONLY wrap for a right-associative `=` chain (`a = b = c = value`),
	 * whose nested `Assign(l, Assign(l, …))` spine the caller has already flattened
	 * into `items`. An assign chain has NO `WrapRules` class of its own — it is not
	 * wrapped until the line overflows — so the decision is a single probe rather
	 * than a rule enumeration.
	 *
	 * The FLAT SHAPE is built right-nested from the tail so it stays byte- and
	 * tree-identical to the per-level `Concat` the plain lowering emits. Its
	 * `OptSpace(' ')` is load-bearing: it drops the trailing space when the RHS opens
	 * with a hardline, so it must NOT be folded into a `Text(' =')` on this side.
	 *
	 * The BREAK SHAPE reuses `shapeFillLine(…, AfterLast)`, the established
	 * binop-chain fill convention. `AfterLast` suffixes the operator to the previous
	 * operand (`a =\n\tb = value`), the only placement that reads for an assignment,
	 * since a continuation line led by `= b` would look like a fresh statement.
	 * Packing comes for free from the shared `Fill`, and the shared `Nest` puts the
	 * continuation one indent level in.
	 *
	 * The GATE is `IfNaturalFirstLineExceeds`, not `Group` / `IfLineExceeds`: the
	 * natural probe resolves inner `Group`s by their OWN `fitsFlat`, so
	 * `x = call(reallyLongArgs…)`, whose call folds its own arguments, has a SHORT
	 * natural first line and does not fire — where a flat-width pivot would measure
	 * the un-wrapped RHS and break the `=` at every such site. The probe's render arm
	 * already honours `Frame.forceFlat`, so a chain inside a force-flat region
	 * collapses to the flat shape without a `WrapBoundary` wrapper; adding one would
	 * defeat that.
	 *
	 * The threshold is `opt.lineWidth + 1` per the project's width convention: every
	 * exceeds-maxLineLength probe compares against `lineWidth + 1`, because the render
	 * arm fires on `>=` while the config predicate means "strictly past the limit".
	 * The two gates disagree only where an operand's inner `Group` wraps and no longer
	 * re-glues, and `+ 1` is right there — a prefix landing ON column `lineWidth`
	 * stays glued, where a bare `lineWidth` would break a line that legally fits.
	 *
	 * The continuation always nests one indent level — unlike `emit` this engine takes
	 * no `nestSuppress`, because an assignment never sits directly inside a cond
	 * paren-wrap whose `Nest` it would compound with.
	 */
	public static function emitAssignChain(items: Array<Doc>, opt: WriteOptions): Doc {
		// The caller only routes a genuine chain here (its own `case Assign`
		// arm guarantees head + one inner left + terminal), so a shorter list
		// is a wiring bug, not an input — surface it instead of folding a
		// degenerate `Doc`. Mirror `MethodChainEmit.shapeOnePerLineAfterFirst`.
		if (items.length < 3) throw 'BinaryChainEmit.emitAssignChain: caller-side chain guard violated (items=${items.length})';
		var flat: Doc = items[items.length - 1];
		var i: Int = items.length - 2;
		while (i >= 0) {
			flat = Concat([items[i], Text(' '), Text('='), OptSpace(' '), flat]);
			i--;
		}
		final ops: Array<String> = [for (_ in 1...items.length) '='];
		final indentUnit: Int = indentUnitOf(opt);
		return IfNaturalFirstLineExceeds(opt.lineWidth + 1, shapeFillLine(items, ops, indentUnit, indentUnit, AfterLast), flat);
	}

	/**
	 * The chain of `items`, offered once more per break nested in an operand whose committed form carries a hardline the
	 * plain operand does not (`BreakCommits.offerItemBreaks`): the next rewrite reads that break from its source, and an
	 * operand with a hardline commits the chain to its break shape (`anyHardline`), so the first rewrite lays the chain out
	 * the same way exactly when the break happens.
	 *
	 * `inlineMultilineBranch` is the caller's verdict that a ternary's hardline comes from a block inside a branch and that its
	 * config keeps such a block on the condition's line: the hardline then no longer commits the chain to its break shape, and
	 * the cascade answers for the first line alone (`hardlineChainShape`).
	 */
	public static function emit(
		items: Array<Doc>, ops: Array<String>, opt: WriteOptions, rules: WrapRules, nestSuppress: Bool = false,
		condWrapForced: Bool = false, ?sourceBreakBefore: Array<Bool>, headBreak: Bool = false, forceKeep: Bool = false,
		?afterComments: Array<Null<Doc>>, restAware: Bool = false, ?forceKeepLocation: Null<WrappingLocation>,
		inlineMultilineBranch: Bool = false, ?ownComments: Array<Null<Doc>>, ?aboveComments: Array<Null<Doc>>
	): Doc {
		function laidOut(with: Array<Doc>, _: Int): Doc {
			return layout(
				with, ops, opt, rules, nestSuppress, condWrapForced, sourceBreakBefore, headBreak, forceKeep, afterComments, restAware,
				forceKeepLocation, inlineMultilineBranch, ownComments, aboveComments
			);
		}
		return BreakCommits.offerItemBreaks(
			items, laidOut(items, -1), laidOut, (item, _, broken) -> WrapList.flatLength(item) >= 0 && WrapList.flatLength(broken) < 0
		);
	}

	/** One indent level in columns, per the configured indent character. */
	private static inline function indentUnitOf(opt: WriteOptions): Int {
		return opt.indentChar == IndentChar.Space ? opt.indentSize : opt.tabWidth;
	}

	private static inline function sameRule(
		a: { mode: WrapMode, location: WrappingLocation }, b: { mode: WrapMode, location: WrappingLocation }
	): Bool {
		return a.mode == b.mode && a.location == b.location;
	}

	/**
	 * True for modes that lay the chain across multiple lines
	 * (`OnePerLine` / `OnePerLineAfterFirst` / `FillLine` /
	 * `FillLineWithLeadingBreak`). `NoWrap` / `Keep` / `Ignore` keep the
	 * chain inline. Used by the ω-chain-keep-flat unwrap pivot.
	 */
	private static inline function isBreakMode(m: WrapMode): Bool {
		return m == OnePerLine || m == OnePerLineAfterFirst || m == FillLine || m == FillLineWithLeadingBreak;
	}

	/**
	 * The chain's LAST operand is a BARE paren-expr — it both leads with `(` and ends with its own
	 * `)` — while operand-1 does not itself open a delimiter. The shape gate the two trailing-paren
	 * glue arms share: `(a - b) / 2` leads with `(` but is a Div whose paren covers only the
	 * numerator, so `endsWithCloseDelim` refuses it and the chain breaks `beforeLast` instead.
	 */
	private static inline function hasBareParenTail(items: Array<Doc>): Bool {
		return leadingOperandOpensDelim(items[items.length - 1], true)
			&& WrapList.endsWithCloseDelim(items[items.length - 1])
			&& !leadingOperandOpensDelim(items[0]);
	}

	/**
	 * `ops` is a ternary's degenerate two-op chain (`?` then `:`) — the mixfix
	 * shape `WriterLowering.lowerTernaryBranch` dispatches into this engine.
	 * Says nothing about `items`; the two callers that also need the operand
	 * count check it themselves.
	 */
	private static inline function isTernaryOps(ops: Array<String>): Bool {
		return ops.length == 2 && ops[0] == '?' && ops[1] == ':'; // noqa: magic-number
	}

	/**
	 * Does this `mode` at this `location` reach a shaper that honours the
	 * `cuddleLast` flag? The two one-operand-per-line shapes do; `Keep` is
	 * source-faithful by contract, the fill family breaks its gaps by packing rather
	 * than at a fixed separator, and `NoWrap` is already glued. Asked so a
	 * probe-gated cuddle wraps only the shapes that CAN differ.
	 *
	 * It takes the LOCATION as well as the mode, and the second axis is not
	 * cosmetic even though it costs no layout: both shapers read the flag only in
	 * their `BeforeLast` arm, so under `defaultLocation: "afterLast"` the two slots
	 * a cuddle-gated shape wraps are the SAME layout twice and the pair of width
	 * probes bracketing them can only ever pick between identical Docs. Asking
	 * about the mode alone therefore built two dead probe nodes per admitted
	 * ternary — three on the probe-gated leg, whose outer probe is dead there too
	 * — with measured byte-identical output, which is why no write fixture can
	 * pin it and `HxTernaryCuddleProbeShapeTest` counts the emitted nodes
	 * instead. That class pins the structural leg's two; the gated leg's three is
	 * unpinned.
	 */
	private static inline function honoursCuddleLast(mode: WrapMode, location: WrappingLocation): Bool {
		return (mode == WrapMode.OnePerLine || mode == WrapMode.OnePerLineAfterFirst) && location == WrappingLocation.BeforeLast;
	}

	/**
	 * True iff any operand `Doc` is a top-level function call
	 * (`DocMeasure.operandIsCall`). The ω-opbool-reeval gate mirrors fork
	 * `hasSimpleCallParamBreaksBetween` (an inner `POpen` that wrapped); a chain
	 * with NO call operand can never have a callParameter wrap to re-evaluate
	 * after, so the marker is skipped (byte-inert).
	 */
	private static inline function containsCallOperand(items: Array<Doc>): Bool {
		return items.exists(DocMeasure.operandIsCall);
	}

	private static function layout(
		items: Array<Doc>, ops: Array<String>, opt: WriteOptions, rules: WrapRules, nestSuppress: Bool = false,
		condWrapForced: Bool = false, ?sourceBreakBefore: Array<Bool>, headBreak: Bool = false, forceKeep: Bool = false,
		?afterComments: Array<Null<Doc>>, restAware: Bool = false,
		// ω-keep-ternary-operand-comment: the wrapping location the `forceKeep`
		// shape must use, overriding the cascade's own answer. A caller that
		// forces `Keep` because an operand carries a LINE comment has exactly one
		// legal location: `BeforeLast` puts the break BEFORE the operator
		// (`a // c` then `? b`), while `AfterLast` emits ` op` first and the
		// comment swallows it. The cascade's fallback is `AfterLast`, so a config
		// whose rules do not fire at `exceeds = true` would otherwise produce
		// `a // c ?` — output the comment-loss guard then refuses, leaving `fmt`
		// a no-op on exactly the file the capture existed to fix. Null (every
		// other caller, including the infix chain whose forced comments may be
		// inline blocks) keeps the cascade's location — byte-inert.
		?forceKeepLocation: Null<WrappingLocation>,
		inlineMultilineBranch: Bool = false,
		// The Keep shape's other two per-gap comment channels (`shapeKeep`); null for every caller but the infix chain.
		?ownComments: Array<Null<Doc>>,
		?aboveComments: Array<Null<Doc>>
	): Doc {
		if (items.length == 0) return WrapBoundary(Empty);
		if (items.length == 1) return WrapBoundary(items[0]);

		// Decoupled measurement (mirror ω-flatlength-decouple-tokenwidth
		// in `WrapList.emit`):
		//   - `flatLength(item) < 0` retains its legacy semantic and
		//     drives `anyHardline` — preserves the (b) break-commit
		//     shortcut on items with hardlines anywhere (including
		//     inside `BodyGroup`).
		//   - `DocMeasure.flatTokenWidth(item)` feeds clean widths to cascade rule
		//     conditions — mirrors `Renderer.fitsFlat`'s BG-defer so
		//     `LineLengthLargerThan` / `TotalItemLengthLargerThan` /
		//     `AnyItemLengthLargerThan` see the same widths the renderer
		//     would lay out flat. Replaces the old `HARDLINE_LEN` (~1M)
		//     inflation that conflated "has hardline anywhere" with
		//     "rule-bound widths".
		final measure: WrapItemMeasure = measureChain(items, ops);
		final total: Int = measure.total;
		final maxLen: Int = measure.maxLen;
		final anyHardline: Bool = measure.anyHardline;

		// `nestSuppress` collapses the chain shapes' own `Nest(cols, …)`
		// to a no-op (cols=0) so chain breaks land at the inherited
		// indent base rather than `base+cols`. Used when the chain is
		// emitted inside a `WrapList.emitCondition` paren-wrap whose
		// outer `Nest(cols, condDoc)` already supplies the +1 paren
		// indent — chain operator-led continuation should stay at
		// outer+cols (matching fork's `\n\t…&& X` shape) rather than
		// compounding to outer+2cols. Call-arg / lambda-body engines
		// inside the same cond keep their own Nest because their
		// continuation legitimately wants the +2cols (paren+1 +
		// callArg+1) layout.
		final indentUnit: Int = indentUnitOf(opt);
		final cols: Int = nestSuppress ? 0 : indentUnit;

		// Column-aware `LineLengthLargerThan` thresholds — mirror
		// `WrapList.emit`'s threshold-aware enumeration pattern (slice
		// ω-ifwidthexceeds-infra). Cascade rules with `lineLength >= n`
		// where `n != opt.lineWidth` cannot be answered at emit time
		// because the rendered column position is unknown until layout.
		// Threshold == lineWidth collapses cleanly to `exceeds` (the
		// existing `IfBreak` pivot) and stays on the legacy 2-state
		// path. Non-lineWidth thresholds enumerate extra states and
		// emit one `IfWidthExceeds(t, …)` wrapper per distinct
		// threshold so the renderer probes `column + flatWidth(flat)`
		// against `t` at layout time.
		final extraThresholds: Array<Int> = WrapList.collectExtraLineLengthThresholds(rules, opt.lineWidth);

		// Cascade-eval helper: caller specifies the (exceeds,
		// firingThresholds) state and gets the cascade's resolved
		// {mode, location}. `LineLengthLargerThan` is mapped to:
		//   - `t == lineWidth` → use `exceeds` (collapse semantic)
		//   - `t != lineWidth` → membership in `firing`
		// All other cond kinds preserve their original evaluators.
		// Non-`inline` so it can be passed as a closure into
		// `thresholdTree` (Haxe forbids closure-on-inline-closure).
		function evalAt(exceeds: Bool, firing: Array<Int>): { mode: WrapMode, location: WrappingLocation } {
			return WrapList.decideRuleWithLineLengthState(
				rules, items.length, maxLen, total, exceeds, anyHardline, t -> t == opt.lineWidth ? exceeds : firing.contains(t), 0,
				measure.minLen, measure.equalLens
			);
		}

		// ω-ternary-cuddled-braces: the gate reads only the operand Docs and the
		// knob, never a column, so it is decided once and handed to every shape the
		// cascade may pick. `probeGated` shapes pay one extra probe layer (below);
		// `null` — the knob off, or the operands declining — takes the pre-knob
		// construction with the flag never set.
		final cuddle: Null<{ probeGated: Bool, closerWidth: Int }> = ternaryBracesCuddle(items, ops, opt);
		// Split into plain flags before the closures read them, so nothing
		// downstream has to re-narrow a nullable across a closure boundary.
		final cuddleAdmitted: Bool = cuddle != null;
		final cuddleProbed: Bool = cuddle != null && cuddle.probeGated;
		// The rendered width of the then branch's closing-line closer run, which the
		// gate measured on the rendering it admitted. What the `:` rides is the whole
		// run, not its last token: a branch closing `}))` opens its line three columns
		// wide.
		final cuddleCloserWidth: Int = cuddle == null ? 0 : cuddle.closerWidth;
		// The then branch's own continuation line, flat: the `? ` prefix plus the
		// branch's flat token width, measured at the continuation indent `cols`
		// adds. Only a `probeGated` cuddle reads it, and only that leg pays the walk.
		final cuddleProbeWidth: Int = cuddleProbed ? ops[0].length + 1 + DocMeasure.flatTokenWidth(items[1]) : 0;

		function shapeWith(r: { mode: WrapMode, location: WrappingLocation }, cuddleLast: Bool): Doc {
			return shape(
				r.mode, r.location, items, ops, cols, indentUnit, sourceBreakBefore, headBreak, afterComments, cuddleLast, restAware,
				{ own: ownComments, above: aboveComments, lineWidth: opt.lineWidth }
			);
		}

		function shapeAt(r: { mode: WrapMode, location: WrappingLocation }): Doc {
			final plain: Doc = shapeWith(r, false);
			return cuddleAdmitted && honoursCuddleLast(r.mode, r.location)
				? cuddleShape(cuddleProbed, cuddleCloserWidth, items, ops, opt, cols, cuddleProbeWidth, shapeWith(r, true), plain)
				: plain;
		}

		function shapeNoWrapAt(location: WrappingLocation): Doc {
			return shape(NoWrap, location, items, ops, cols, indentUnit, sourceBreakBefore, headBreak);
		}

		// ω-keep-infix-operand-comment: when an operand carries a captured
		// trailing comment, force the source-faithful `Keep` shape so a line
		// comment's mandatory newline lands the operator on its own
		// continuation line (`a // c` then `+ b`) while a block comment stays
		// inline (`a /* c */ + b`, no source break). Location follows the
		// rules' flat decision; `sourceBreakBefore` drives the per-gap break.
		// Force-break path: cascade evaluated only against
		// `exceeds=true` (anyHardline already commits to break-mode
		// per the prior decoupling slice). Thresholds still
		// column-aware — even when the parent commits to break-mode,
		// a `LineLengthLargerThan` rule answer can flip with column.
		// `thresholdTree` handles 0/1/N thresholds via
		// recursion (no IfBreak split — single shape per leaf).
		// ω-ternary-collection-hug: a breaking ternary whose sole multi-line
		// branch is a bare collection literal (`cond ? flat : {…}`) HUGS —
		// keep `cond ? A : {` on the head line and let the collection self-
		// break — WHEN that head fits (`IfFirstLineExceeds` picks the flat
		// `shapeNoWrap` hug), else fall through to the leading-break-all shape.
		// ω-render-pivot-collection-arg, ternary leg: a collection branch whose
		// break is decided at RENDER time leaves `anyHardline` false, so the chain
		// takes the cascade route and breaks `?` / `:` — then writes a newline the
		// next pass force-commits, `anyHardline` turns true, and the hug above
		// fires instead. Route to the same hug one pass earlier, behind the ONE
		// condition that makes resolving the branch's pivot legal: the ternary
		// does not fit the line it is on, so that pivot is certain to fire. The
		// `IfLineExceeds` flat arm is the untouched cascade route, so a ternary
		// that still fits is byte-identical.
		final pivotHugIdx: Int = !anyHardline && !forceKeep && extraThresholds.length == 0
			? ternaryHugCollectionBranchIndex(items, ops)
			: -1;
		return if (forceKeep)
			WrapBoundary(shapeAt({ mode: WrapMode.Keep, location: forceKeepLocation ?? evalAt(true, []).location }))
		else if (anyHardline)
			WrapBoundary(hardlineChainShape(items, ops, opt, extraThresholds, evalAt, shapeAt, shapeNoWrapAt, inlineMultilineBranch))
		else if (pivotHugIdx >= 0)
			WrapBoundary(IfLineExceeds(
				opt.lineWidth + 1, ternaryHugShape(pivotHugIdx, items, ops, opt, evalAt, shapeAt),
				emitCascadePivot(items, ops, opt, nestSuppress, condWrapForced, restAware, evalAt, shapeAt, shapeNoWrapAt, [])
			))
		else
			emitCascadePivot(items, ops, opt, nestSuppress, condWrapForced, restAware, evalAt, shapeAt, shapeNoWrapAt, extraThresholds);
	}

	/**
	 * The chain's shape on ONE side of the `exceeds` pivot: `shapeAt` of the cascade's answer, partitioned by an
	 * `IfWidthExceeds` for each column-aware `lineLength` threshold whose two sides answer differently. `firing` holds the
	 * thresholds already taken as reached on the way down. The renderer's column probe is monotone, so a leaf whose state
	 * cannot occur is never rendered.
	 */
	private static function thresholdTree(
		thresholds: Array<Int>, firing: Array<Int>, exceeds: Bool,
		evalAt: (Bool, Array<Int>) -> { mode: WrapMode, location: WrappingLocation },
		shapeAt: { mode: WrapMode, location: WrappingLocation } -> Doc
	): Doc {
		final uniform: Null<{ mode: WrapMode, location: WrappingLocation }> = uniformAnswer(thresholds, firing, exceeds, evalAt);
		if (uniform != null) return shapeAt(uniform);
		final t: Int = thresholds[0];
		final rest: Array<Int> = thresholds.slice(1);
		return IfWidthExceeds(
			t, thresholdTree(rest, firing.concat([t]), exceeds, evalAt, shapeAt), thresholdTree(rest, firing, exceeds, evalAt, shapeAt)
		);
	}

	/**
	 * The cascade's one answer over every combination of the remaining `thresholds` on the given side of the `exceeds`
	 * pivot, or null when two combinations answer differently.
	 */
	private static function uniformAnswer(
		thresholds: Array<Int>, firing: Array<Int>, exceeds: Bool,
		evalAt: (Bool, Array<Int>) -> { mode: WrapMode, location: WrappingLocation }
	): Null<{ mode: WrapMode, location: WrappingLocation }> {
		if (thresholds.length == 0) return evalAt(exceeds, firing);
		final rest: Array<Int> = thresholds.slice(1);
		final reached: Null<{ mode: WrapMode, location: WrappingLocation }> = uniformAnswer(
			rest, firing.concat([thresholds[0]]), exceeds, evalAt
		);
		final below: Null<{ mode: WrapMode, location: WrappingLocation }> = uniformAnswer(rest, firing, exceeds, evalAt);
		return reached != null && below != null && sameRule(reached, below) ? below : null;
	}

	/**
	 * True iff every operator is a binary chain operator (`&&` / `||` /
	 * `+` / `-`) — i.e. NOT a ternary (`?` / `:`). The ternary dispatch
	 * reuses this engine with a degenerate 3-item chain; the keep-flat
	 * unwrap must not fire there.
	 */
	private static function isChainOps(ops: Array<String>): Bool {
		for (o in ops) switch o {
			case '&&', '||', '+', '-':
			case _:
				return false;
		}
		return ops.length > 0;
	}

	/**
	 * True iff every operator is an opBool chain operator (`&&` / `||`) —
	 * i.e. NOT an opAddSub (`+`/`-`) or a ternary (`?`/`:`). Drives the
	 * ω-opbool-reeval-after-callparam `CollapseBoolProbe` marker: only a pure
	 * opBool chain's trailing FillLine shape is tagged for the break-direction
	 * flip (mirror fork `reEvaluateOpBoolAfterCallParam`, which fires only on
	 * `OpBoolChainWrapping` places).
	 */
	private static function isOpBoolOps(ops: Array<String>): Bool {
		for (o in ops) switch o {
			case '&&', '||':
			case _:
				return false;
		}
		return ops.length > 0;
	}

	/**
	 * True iff a NON-FIRST operand's flat text contains a thin-arrow `->`
	 * (an arrow lambda absorbing the overflow). The keep-flat unwrap probe
	 * (`IfNaturalFirstLineFitsOpenDelim`) faithfully mirrors the fork ONLY
	 * when the overflow-absorbing operand is an arrow lambda whose body owns
	 * the wrap: for a plain-call absorber the fork opens the condition paren
	 * (breaks the chain) once the flat condition clearly exceeds, so it must
	 * NOT take the keep-flat glue route.
	 */
	private static function laterOperandContainsArrow(items: Array<Doc>): Bool {
		for (i in 1...items.length) if (DocMeasure.flatText(items[i]).indexOf('->') >= 0) return true;
		return false;
	}

	/**
	 * True iff every operator is an opAddSub chain operator (`+` / `-`) —
	 * i.e. NOT an opBool (`&&`/`||`) or a ternary (`?`/`:`). Drives the
	 * ω-unwrap-add-ops `CollapseAddProbe` marker: only a pure opAddSub
	 * chain's broken shape is wrapped, so `CollapsePass` collapses ONLY
	 * inner `+`/`-` chains (mirror fork `unwrapAddOps`, which strips ONLY
	 * `Binop(OpAdd)` / `Binop(OpSub)` line-ends, never `&&`/`||`).
	 */
	private static function isAddSubOps(ops: Array<String>): Bool {
		for (o in ops) switch o {
			case '+', '-':
			case _:
				return false;
		}
		return ops.length > 0;
	}

	/**
	 * True iff the FIRST operand's rendered first token is an open
	 * delimiter (`(` / `[` / `{`) — i.e. operand-1 is itself a
	 * paren-expression / array / object literal that leads with an open
	 * delim. The keep-flat unwrap must NOT fire then: the chain's natural
	 * first line would end at operand-1's own `(` (a degenerate prefix),
	 * gluing the cond paren to `((` when the fork breaks the chain at its
	 * own operator instead (`condition_first_operand_paren_no_merge`).
	 * Only a LATER operand-call absorbing the overflow is a valid unwrap.
	 */
	private static function leadingOperandOpensDelim(item0: Doc, parenOnly: Bool = false): Bool {
		return switch item0 {
			case Text(s):
				s.length > 0 && (s.fastCodeAt(0) == '('.code || !parenOnly && (s.fastCodeAt(0) == '['.code || s.fastCodeAt(0) == '{'.code));
			case Concat(arr):
				var hit: Bool = false;
				var done: Bool = false;
				for (it in arr) if (!done) switch it {
					case Empty, Line(_), OptSpace(_), OptSpaceSkipAfterHardline, OptHardline, OptHardlineSkipAtOpenDelim,
						OptHardlineSkipBeforeHardline:
					case _:
						done = true;
						hit = leadingOperandOpensDelim(it, parenOnly);
				}
				hit;
			case Group(i), BodyGroup(i), GroupWithRestProbe(i), Nest(_, i), BreakCommit(_, i), LeadingBreak(_, i), Flatten(i),
				HardFlatten(i), CollapseProbe(i), CollapseAddProbe(i), CollapseBoolProbe(i), CollapseChainProbe(i), WrapBoundary(i),
				ConditionalMarkerZero(i), ConditionalMarkerDecrease(i), BreakMark(i, _):
				leadingOperandOpensDelim(i, parenOnly);
			case IfBreak(_, flat), IfWidthExceeds(_, _, flat), IfFirstLineExceeds(_, _, flat), IfLineExceeds(_, _, flat),
				IfResidualLineExceeds(_, _, flat), IfFullLineExceeds(_, _, flat), IfNaturalFirstLineExceeds(_, _, flat),
				IfNaturalFirstLineExceedsWithRest(_, _, flat), IfNaturalFirstLineFitsOpenDelim(_, _, flat),
				IfArrowContinuationFits(_, _, _, _, flat), IfArrowContinuationFitsWithRest(_, _, _, _, flat),
				IfIndentWidthExceeds(_, _, _, flat), IfGluedFirstLineExceeds(_, _, _, flat), IfTrailingCommentOverflows(_, _, _, _, flat):
				// PROBE FAMILY (`docs/architecture.md` table), flat side for all four:
				//  - `IfArrowContinuationFits` and its rest-aware sibling are two-SHAPE
				//    probes like the natural siblings above, and their two shapes always
				//    share a leading token — the list's own `Text(open)` at the three
				//    call-argument consumers, `items[0]` at the chain consumer this file
				//    emits itself (`emit`'s arrow-continuation glue, which pairs two
				//    layouts of the same operand array and no delimiter at all), and
				//    `cuddleShape`'s two else probes, whose two layouts come from ONE
				//    `shape(…)` call with `cuddleLast` flipped and therefore share every
				//    operand, differing only at the final separator. Side-independent
				//    either way; flat keeps this walker on one side for the whole
				//    two-shape population.
				//  - the two body-placement probes wrap the SAME body object and
				//    differ only in the separator before it (`Line('\n')` vs
				//    `OptSpace(' ')` / `Line(' ')`), both of which this walker's
				//    Concat scan skips as leading layout atoms — so either side
				//    reaches the same first token, and flat is the family's
				//    content-walker convention (`CollapsePass.walk`,
				//    `MatrixWrap.isMultiline`, `Renderer.findCollapseProbe`).
				leadingOperandOpensDelim(flat, parenOnly);
			case Empty, Line(_), OptSpace(_), OptSpaceSkipAfterHardline, OptHardline, OptHardlineSkipAtOpenDelim,
				OptHardlineSkipBeforeHardline, Fill(_, _, _), FillWithRestProbe(_, _, _), FillBreakAfterWrap(_, _, _):
				// Layout atoms carry no token; a `Fill` is the wrap engine's own
				// packing of a LIST, never a single operand's head shape. Enumerated
				// rather than left to `case _` so a new `Doc` ctor fails to compile
				// here instead of silently inheriting `false`.
				false;
		};
	}

	/**
	 * ω-opadd-hardline-paren-glue — the chain Doc for the `anyHardline` commit, where a forced
	 * hardline inside some operand has already decided that the chain breaks.
	 *
	 * Two shapes escape the plain break tree, both because the break it emits buys nothing:
	 *
	 * - the ternary collection hug (`cond ? flat : {…}`) — keep the head glued and let the sole
	 *   multi-line branch self-break, WHEN that head fits.
	 * - a bare paren TAIL on an add/sub chain (`a + (…)`): the leading break before the last
	 *   operand costs a line and an indent level and saves nothing, because that operand is
	 *   multi-line either way. This is the arm the hardline commit had cut off — the identical
	 *   chain WITHOUT a hardline reaches `emitCascadePivot`'s ω-opadd-trailing-paren-glue and
	 *   keeps its head glued, so a paren carrying a forced break (a value-`if` chain in
	 *   `expressionIf` policy layout, a `switch`, a block) was the one shape that did not.
	 *
	 * The pivot is the same `IfNaturalFirstLineFitsOpenDelim` that arm uses, so the two agree by
	 * construction: glue when the glued shape's natural first line FITS, else only when it ends
	 * at an open delimiter. Note this does NOT require the paren to open — a content-glued paren
	 * whose head line fits glues too, which is the intended reading of "the break buys nothing".
	 *
	 * Inert at the fork defaults, where an expression-position `if` branch carries no forced
	 * break, so the shape does not arise there at all.
	 *
	 * `extraThresholds` non-empty keeps the column-aware tree — a `LineLengthLargerThan` rule at
	 * a non-`lineWidth` threshold cannot be answered here.
	 *
	 * A third shape, `inlineMultilineBranch`: a ternary whose branch holds a multi-line block keeps
	 * `cond ? macro {` glued while its first line fits, the hug's pivot applied to a branch the hug
	 * does not recognise, and breaks into the cascade's shape when it does not.
	 */
	private static function hardlineChainShape(
		items: Array<Doc>, ops: Array<String>, opt: WriteOptions, extraThresholds: Array<Int>,
		evalAt: (Bool, Array<Int>) -> { mode: WrapMode, location: WrappingLocation },
		shapeAt: ({ mode: WrapMode, location: WrappingLocation }) -> Doc, shapeNoWrapAt: (WrappingLocation) -> Doc,
		inlineMultilineBranch: Bool
	): Doc {
		if (extraThresholds.length == 0) {
			final hugIdx: Int = ternaryHugCollectionBranchIndex(items, ops);
			if (hugIdx >= 0) return ternaryHugShape(hugIdx, items, ops, opt, evalAt, shapeAt);
			if (isAddSubOps(ops) && hasBareParenTail(items))
				return IfNaturalFirstLineFitsOpenDelim(opt.lineWidth, shapeAt(evalAt(true, [])), shapeNoWrapAt(evalAt(false, []).location));
		}
		final broken: Doc = thresholdTree(extraThresholds, [], true, evalAt, shapeAt);
		if (inlineMultilineBranch) return IfFirstLineExceeds(opt.lineWidth, broken, shapeNoWrap(items, ops));
		// Only the LAST operand breaks and the cascade keeps a fitting chain on one line: the chain hugs that operand
		// (`a && xs.exists(x -> {`, `|| [`) when the glued line up to its break fits and ends at a delimiter the operand
		// opened, rather than counting the operand's own break as the chain's overflow. A break of another kind (a line
		// comment, a `#if` line) keeps the broken chain, whose nest indents the operand's continuation.
		final hugsLast: Bool = isChainOps(ops)
			&& !items.slice(0, items.length - 1).exists(item -> WrapList.flatLength(item) < 0)
			&& evalAt(false, []).mode == NoWrap;
		if (!hugsLast) return broken;
		final glued: Doc = shapeNoWrap(items, ops);
		return IfFirstLineExceeds(opt.lineWidth, broken, IfNaturalFirstLineFitsOpenDelim(opt.lineWidth, broken, glued));
	}

	private static function shape(
		mode: WrapMode, location: WrappingLocation, items: Array<Doc>, ops: Array<String>, cols: Int, indentUnit: Int,
		?sourceBreakBefore: Array<Bool>, headBreak: Bool = false, ?afterComments: Array<Null<Doc>>, cuddleLast: Bool = false,
		restAware: Bool = false, ?keepComments: KeepGapComments
	): Doc {
		return switch mode {
			case NoWrap: shapeNoWrap(items, ops);
			case OnePerLine: shapeOnePerLine(items, ops, cols, location, cuddleLast);
			case OnePerLineAfterFirst: shapeOnePerLineAfterFirst(items, ops, cols, location, cuddleLast);
			case FillLine, FillLineWithLeadingBreak:
				shapeFillLine(items, ops, cols, indentUnit, location, restAware);
			// ω-keep-chain (increment 2): JSON `"defaultWrap": "keep"` on chain
			// configs (opAddSubChain, opBoolChain) preserves the source's
			// per-operator line breaks verbatim — break before operand `i`
			// iff the parser captured a source newline in that operator's
			// gap (`sourceBreakBefore[i-1]`), else glue with ` op `. The
			// signal is the per-infix-ctor `chainNewline` synth slot
			// captured at parse time in `lowerPrattLoop`; mirror of fork's
			// `keepLineEnds`/`markKeepLineEnds` per-token `isOriginalNewlineBefore`.
			// When the signal is absent (null — plain mode / non-capturing
			// ctor) shapeKeep degrades to shapeNoWrap → byte-inert.
			case Keep:
				shapeKeep(items, ops, cols, location, sourceBreakBefore, headBreak, afterComments, keepComments);
			// ω-cascade-emits-comments: Ignore sister to Keep — the writer
			// pre-empts at the trivia branch. Defensive fallback to
			// shapeNoWrap on engine leakage.
			case Ignore: shapeNoWrap(items, ops);
			case _: shapeOnePerLineAfterFirst(items, ops, cols, location);
		};
	}

	private static function shapeNoWrap(items: Array<Doc>, ops: Array<String>): Doc {
		final inner: Array<Doc> = [items[0]];
		for (i => op in ops) {
			inner.push(Text(' ${op} '));
			inner.push(items[i + 1]);
		}
		return Concat(inner);
	}

	/**
	 * `WrapMode.Keep` shaper — reproduces the source's per-operator line
	 * breaks. `sourceBreakBefore` is parallel to `ops`: entry `i` is true
	 * when the parser captured a source newline in the gap of operator `i`
	 * (between operand `i` and operand `i+1`). When true the continuation
	 * breaks at the chain's one-tab `Nest(cols)` indent; when false the
	 * operands stay glued with ` op `.
	 *
	 *  - `BeforeLast`: a broken gap lands the operator at the START of the
	 *    continuation line (`a\n\t&& b`). Matches haxe-formatter's default
	 *    chain break shape. A glued gap emits ` op operand` inline.
	 *  - `AfterLast`: a broken gap suffixes the operator to the previous
	 *    line and lands the next operand at the start of the continuation
	 *    line (`a +\n\tb`). A glued gap emits ` op operand` inline.
	 *
	 * `headBreak` (the source had a newline between the call-site keyword —
	 * e.g. `return` — and the chain head) prepends a `Line('\n')` INSIDE the
	 * `Nest` so the head operand lands on its own continuation line
	 * (`return\n\t\t\thead\n\t\t\t&& …`). Default false keeps the head glued.
	 *
	 * When `sourceBreakBefore` is null (plain mode / non-capturing ctor)
	 * or every entry is false AND `headBreak` is false, the output is
	 * byte-identical to `shapeNoWrap` — inert for the non-keep hot path.
	 */
	private static function shapeKeep(
		items: Array<Doc>, ops: Array<String>, cols: Int, location: WrappingLocation, ?sourceBreakBefore: Array<Bool>,
		headBreak: Bool = false, ?afterComments: Array<Null<Doc>>, ?keepComments: KeepGapComments
	): Doc {
		final breaks: Array<Bool> = sourceBreakBefore ?? [];
		final owns: Null<Array<Null<Doc>>> = keepComments?.own;
		final aboves: Null<Array<Null<Doc>>> = keepComments?.above;
		final lineWidth: Int = keepComments?.lineWidth ?? 0;
		function gap(i: Int, withAfter: Bool): Array<Doc> {
			final broken: Bool = i < breaks.length && breaks[i];
			final leftLineComment: Bool = WrapList.endsWithLineComment(items[i]);
			return keepGap(
				ops[i], location, broken || leftLineComment, withAfter ? gapComment(afterComments, i) : null, gapComment(owns, i),
				leftLineComment
			);
		}
		// First operand stays at the call-site column (unless `headBreak`);
		// only the continuation tail is nested at the chain's one-tab indent,
		// so a broken gap lands its line at `base + cols` while a glued gap
		// keeps the operands inline (mirror `shapeOnePerLineAfterFirst`).
		final tail: Array<Doc> = [];
		var prevCandidate: Bool = false;
		for (i in 0...ops.length) {
			final above: Null<Doc> = gapComment(aboves, i);
			final candidate: Bool = keepStartsOwnLine(i, location, breaks, afterComments, owns)
				&& !(prevCandidate && location == BeforeLast);
			prevCandidate = candidate && above != null;
			if (above != null && candidate) {
				// `comments.trailingCommentOverflow: "above"`: the operator's `//` comment moves onto its own line above
				// operand `i` when it alone carries that line past the limit. Under `BeforeLast` the gap then breaks
				// before its operator, so the next operand no longer opens a line after one and stays out.
				tail.pop();
				final code: Doc = Concat([items[i], Text(' ${ops[i]}')]);
				final flat: Doc = Concat([items[i]].concat(gap(i, true)));
				final moved: Doc = Concat(([above, Line('\n'), items[i]]: Array<Doc>).concat(gap(i, false)));
				tail.push(IfTrailingCommentOverflows(lineWidth, 1 + DocMeasure.flatTokenWidth(above), code, moved, flat));
			} else {
				for (part in gap(i, true)) tail.push(part);
			}
			tail.push(items[i + 1]);
		}
		// `headBreak` puts the head operand on its own continuation line:
		// the whole chain (head + tail) is nested and led by a `Line('\n')`.
		return headBreak ? Nest(cols, Concat([Line('\n'), items[0]].concat(tail))) : Concat([items[0], Nest(cols, Concat(tail))]);
	}

	/** Entry `i` of a per-gap comment channel, null when the channel or the entry is absent. */
	private static function gapComment(channel: Null<Array<Null<Doc>>>, i: Int): Null<Doc> {
		return channel == null || i >= channel.length ? null : channel[i];
	}

	/**
	 * The Keep separator of one gap. A comment after the operator (`a || // c`) or an own-line run before the operand
	 * (`a ||`, then `// c`, then `b`) ends the line at the operator whatever the location; otherwise a
	 * source break lands where the location puts it, and a glued gap stays ` op `. An operand ending
	 * in a line comment breaks before the operator whatever the location: the comment would swallow it.
	 */
	private static function keepGap(
		op: String, location: WrappingLocation, broken: Bool, after: Null<Doc>, own: Null<Doc>, leftLineComment: Bool = false
	): Array<Doc> {
		if (after != null || own != null) {
			final parts: Array<Doc> = [Text(' $op')];
			if (after != null) parts.push(after);
			parts.push(Line('\n'));
			if (own != null) {
				parts.push(own);
				parts.push(Line('\n'));
			}
			return parts;
		}
		if (!broken) return [Text(' $op ')];
		return location == BeforeLast || leftLineComment ? [Line('\n'), Text('$op ')] : [Text(' $op'), Line('\n')];
	}

	/**
	 * Operand `i` of a Keep chain opens its own line right after an operator that ended the previous one, with no
	 * comment above it yet: a comment moved above it there reads back as the previous gap's own-line run, so the move
	 * is a fixed point. The head operand never qualifies — above it is the enclosing statement, not the chain.
	 */
	private static function keepStartsOwnLine(
		i: Int, location: WrappingLocation, breaks: Array<Bool>, afterComments: Null<Array<Null<Doc>>>, owns: Null<Array<Null<Doc>>>
	): Bool {
		return i != 0
			&& gapComment(owns, i - 1) == null
			&& (gapComment(afterComments, i - 1) != null || location == AfterLast && i - 1 < breaks.length && breaks[i - 1]);
	}

	private static function shapeOnePerLineAfterFirst(
		items: Array<Doc>, ops: Array<String>, cols: Int, location: WrappingLocation, cuddleLast: Bool = false
	): Doc {
		// First operand stays at the call-site column; remaining operands
		// each on their own indented continuation line.
		//
		//  - `BeforeLast`: the op prefixes each continuation operand
		//    (`items[0]\n+indent op_i items[i+1]`). Matches haxe-formatter's
		//    default break shape for opBoolChain / opAddSubChain.
		//  - `AfterLast`: the op suffixes the previous line, the next
		//    operand starts the continuation line
		//    (`items[0] op_0\n+indent items[1] op_1\n+indent items[2]…`).
		final tail: Array<Doc> = [];
		switch location {
			case BeforeLast:
				for (i => op in ops) {
					// ω-ternary-cuddled-braces: `cuddleLast` glues the FINAL gap —
					// the operator rides the previous operand's own closing line
					// (` : {`) instead of opening a continuation line of its own.
					// `ternaryBracesCuddle` is what decides it; here it is one
					// dropped `Line`, so the knob-off path is the pre-knob Concat.
					final cuddled: Bool = cuddleLast && i == ops.length - 1;
					if (!cuddled) tail.push(Line('\n'));
					tail.push(Text(cuddled ? ' ${op} ' : '${op} '));
					tail.push(items[i + 1]);
				}
				return Concat([items[0], Nest(cols, Concat(tail))]);
			case AfterLast:
				// op_0 suffixes items[0] (still on the first line); each
				// continuation line carries items[i] and, when there is
				// a next op, a trailing ` op_i`.
				final head: Array<Doc> = [items[0]];
				if (ops.length > 0) head.push(Text(' ${ops[0]}'));
				for (i in 1...items.length) {
					tail.push(Line('\n'));
					tail.push(items[i]);
					if (i < ops.length) tail.push(Text(' ${ops[i]}'));
				}
				return Concat([Concat(head), Nest(cols, Concat(tail))]);
		}
	}

	private static function shapeOnePerLine(
		items: Array<Doc>, ops: Array<String>, cols: Int, location: WrappingLocation, cuddleLast: Bool = false
	): Doc {
		// Every operand on its own indented line.
		//
		//  - `AfterLast` (haxe-formatter's `defaultWrap: onePerLine`
		//    shape): each line except the last ends with ` op`
		//    (`return !(\n\ta || b || \n\tc || \n\td\n);`).
		//  - `BeforeLast`: every continuation line starts with `op `
		//    (`\n\titems[0]\n\top_0 items[1]\n\top_1 items[2]…`).
		//
		// Leading break is `OptHardlineSkipAtOpenDelim` rather than
		// plain `Line('\n')`: when the chain is wrapped directly inside
		// `(`/`[`/`{` (e.g. `((a || b || c))` paren-wrapped sub-chain),
		// the renderer drops the leading `\n+indent` so items[0] glues
		// to the open delim, matching haxe-formatter's
		// `((items[0] ||\n\titems[1]...\n))` shape on
		// issue_187_oneline. Outer-context cases (`dirty = chain`,
		// `return chain`) keep the leading `\n+indent` because their
		// previous emitted byte is `=` / `n` / etc., not an open delim.
		final inner: Array<Doc> = [OptHardlineSkipAtOpenDelim, items[0]];
		switch location {
			case AfterLast:
				for (i => op in ops) {
					inner.push(Text(' ${op}'));
					inner.push(Line('\n'));
					inner.push(items[i + 1]);
				}
			case BeforeLast:
				for (i => op in ops) {
					// ω-ternary-cuddled-braces, sister of the `OnePerLineAfterFirst`
					// arm: the final gap glues when `cuddleLast`. Same one dropped
					// `Line` — this shaper differs only in breaking before the FIRST
					// operand as well, which the cuddle never touches.
					final cuddled: Bool = cuddleLast && i == ops.length - 1;
					if (!cuddled) inner.push(Line('\n'));
					inner.push(Text(cuddled ? ' ${op} ' : '${op} '));
					inner.push(items[i + 1]);
				}
		}
		return Nest(cols, Concat(inner));
	}

	private static function shapeFillLine(
		items: Array<Doc>, ops: Array<String>, cols: Int, indentUnit: Int, location: WrappingLocation, restAware: Bool = false
	): Doc {
		// Soft-line packing through `Fill`. Per-item-fit decision packs
		// operands inline until the next one would overflow, then the
		// soft-line between two operands breaks at the chain's standard
		// one-tab continuation indent.
		//
		//  - `BeforeLast` (haxe-formatter's `opAddSubChain` default):
		//    op rides AHEAD of the next operand so a broken soft-line
		//    lands the op at the start of the continuation line —
		//    `throw "..." + ... + "...("\n\t+ rest`.
		//  - `AfterLast` (haxe-formatter's typedef-level default for
		//    rules-empty fallback, e.g. `opBoolChain.defaultWrap: fillLine`
		//    with `rules: []`): op suffixes the previous operand so the
		//    broken soft-line lands the NEXT operand at the start of
		//    the continuation line —
		//    `dirty || (X) || (Y) ||\n\t(Z) || (W)`.
		//
		// `Fill(items, sep)` fits each item against the remaining budget.
		// `BeforeLast` nests at `cols` (the chain's normal one-tab
		// continuation indent, collapsed to 0 by `nestSuppress` when an
		// outer call-arg / cond paren already supplied the +1) — the
		// leading `op ` on each continuation line is the visual chain
		// marker, so under suppression the continuation co-indents with
		// the chain base. `AfterLast` instead nests at `indentUnit` (one
		// indent level, NEVER suppressed): the trailing operator leaves
		// no marker at the start of the continuation line, so the +1
		// indent disambiguates the wrapped operand from a sibling
		// statement — mirror fork `wrapFillLine2AfterLast`'s
		// `indent + 1 + addIndent`. For a non-suppressed chain
		// (`cols == indentUnit`) both branches are byte-identical.
		final enriched: Array<Doc> = switch location {
			case BeforeLast:
				final acc: Array<Doc> = [items[0]];
				for (i => op in ops) acc.push(Concat([Text('${op} '), items[i + 1]]));
				acc;
			case AfterLast:
				final acc: Array<Doc> = [for (i in 0...ops.length) Concat([items[i], Text(' ${ops[i]}')])];
				acc.push(items[items.length - 1]);
				acc;
		}
		// AfterLast continuation indent is +1 ONLY for an opAddSub (`+`/`-`)
		// chain: the trailing operator leaves the wrapped operand bare at the
		// start of its line, so a one-level indent disambiguates it from a
		// sibling statement (fork `wrapFillLine2AfterLast`'s `indent + 1`). An
		// opBool (`&&`/`||`) AfterLast chain keeps the legacy `cols` indent —
		// under nest-suppression (call-arg / `if (` condition) it co-indents
		// with the chain base (+0), matching the fork-preserved trailing layout
		// of `opbool_in_call_leading_break_preserved` /
		// `condition_wrapping_priority_over_opbool`. For a non-suppressed chain
		// (`cols == indentUnit`) both arms are byte-identical.
		final nestCols: Int = location == AfterLast && isAddSubOps(ops) ? indentUnit : cols;
		// tailReserve = 1: match the fork's fill boundary, which breaks a chain
		// operand that reaches EXACTLY `maxLineLength` (`>=`), unlike the Wadler-
		// inclusive raw `Fill` whose `fitsFlat` accepts a zero-budget exact fit.
		// Without it a middle operand ending flush at the limit stays on the packed
		// line and an inner group (e.g. a call operand) then splits its own args
		// instead of the chain breaking at the operator.
		// omega-chain-rest-width: a `restAware` chain's own fill Group counts the
		// whole physical line as the pivot that picked this shape did; left plain,
		// it re-decided flat on `col + flatWidth` alone and undid that pivot's break.
		final packed: Doc = Nest(nestCols, Fill(enriched, Line(' '), 1));
		return D.groupOrRestProbe(packed, restAware);
	}

	/**
	 * Build the chain Doc around its one `exceeds` pivot (the 2-state `Group(IfBreak(…))` plus the CollapsePass-probe /
	 * cond-wrap-unwrap tags). Column-aware `thresholds` partition each side of that pivot from inside, never wrap it: a
	 * cascade that merely CONTAINS a `lineLength` rule must keep the pivot's rest-aware Group and markers, or its last
	 * `exceeds` rule loses the line's trailing columns and the inner add-chain collapse. The closures are the ones `emit`
	 * builds — `shapeNoWrapAt` renders the forced-NoWrap unwrap shape that bypasses the cascade-decided mode.
	 */
	private static function emitCascadePivot(
		items: Array<Doc>, ops: Array<String>, opt: WriteOptions, nestSuppress: Bool, condWrapForced: Bool, restAware: Bool,
		evalAt: (Bool, Array<Int>) -> { mode: WrapMode, location: WrappingLocation },
		shapeAt: ({ mode: WrapMode, location: WrappingLocation }) -> Doc, shapeNoWrapAt: (WrappingLocation) -> Doc, thresholds: Array<Int>
	): Doc {
		// noqa: complexity
		// The flat answer at no fired threshold stands for the decisions that read one mode or location (the cond-wrap
		// unwrap, whose forced cascade has no threshold, and the NoWrap glue's location); with no threshold it is the cascade.
		final flat: { mode: WrapMode, location: WrappingLocation } = evalAt(false, []);
		// ω-opbool-reeval-after-callparam (CollapsePass increment 2): an opBool
		// chain (`&&`/`||`) whose BROKEN shape is FillLine operator-TRAILING
		// (`AfterLast`) and that contains a function-call operand. TAG the broken
		// branch with `CollapseBoolProbe`. The marker is render-transparent
		// (byte-inert on its own); `CollapsePass` flips it to operator-LEADING
		// ONLY when a contained call operand overflows at its flat column (fork
		// `reEvaluateOpBoolAfterCallParam` — strip the call breaks, re-apply
		// opBool with `useTrailing: false`). Gated to opBool + FillLine +
		// AfterLast + has-call so every other chain stays byte-identical.
		// `!nestSuppress` excludes a chain that is itself a CALL ARGUMENT
		// (`_callArgChainNest`) or wrapped by a return-context paren
		// (`_keepChainInParen`) — fork `reEvaluateOpBoolAfterCallParam` flips
		// only condition / bare-value opBool chains, never a chain that is a
		// call argument (`opbool_in_call_leading_break_preserved`, which keeps
		// its trailing layout). At this final-IfBreak path `condWrapForced` is
		// already false (the cond-wrap collapse takes the inc6 path above), so
		// `nestSuppress` here means call-arg / keep-in-paren. The tag is decided
		// per cascade answer, so a threshold that changes the broken mode or
		// location tags only the leaves it applies to.
		final boolReevalChain: Bool = isOpBoolOps(ops) && !nestSuppress && containsCallOperand(items);
		function brkShapeAt(r: { mode: WrapMode, location: WrappingLocation }): Doc {
			return boolReevalChain && r.location == AfterLast && (r.mode == FillLine || r.mode == FillLineWithLeadingBreak)
				? CollapseBoolProbe(shapeAt(r))
				: shapeAt(r);
		}
		// Each side of the `exceeds` pivot below partitions by the column-aware thresholds INSIDE it, so every probe this
		// pivot takes (the rest-aware Group, the add-chain collapse marker, the paren-tail glue) is the one a cascade with
		// no `lineLength` rule takes.
		final flatSide: Doc = thresholdTree(thresholds, [], false, evalAt, shapeAt);
		final brkSide: Doc = thresholdTree(thresholds, [], true, evalAt, brkShapeAt);
		final flatAll: Null<{ mode: WrapMode, location: WrappingLocation }> = uniformAnswer(thresholds, [], false, evalAt);
		final brkAll: Null<{ mode: WrapMode, location: WrappingLocation }> = uniformAnswer(thresholds, [], true, evalAt);
		// ω-chain-keep-flat (increment-6 — CONSTRAINED probe): UNWRAP the
		// chain to a single flat NoWrap line ONLY in the cond-wrap context
		// (`condWrapForced` — the chain was collapsed to a forced mode
		// inside an active `@:fmt(condWrap)` paren, NOT a leading-break
		// call-arg) AND only when a NON-FIRST operand is a call/arrow
		// whose open delim absorbs the overflow.
		// Mirrors fork `unwrapBoolOps`/`unwrapAddOps` which fire ONLY inside
		// `applyArrowWrapping` (an operand-call owns the wrap), never for a
		// bare break-mode chain. Gates (each excludes a measured regression):
		//  - `condWrapForced` — scope to cond-wrap (excludes string_concat /
		//    issue_299 plain assignment AND call-arg chains —
		//    opbool_in_call_leading_break_preserved / opsub_chain_in_single_param_call).
		//  - `isChainOps(ops)` — `&&`/`||`/`+`/`-` only (excludes ternary
		//    `?`/`:` — the ternary dispatch shares this engine).
		//  - `!leadingOperandOpensDelim(items[0])` — operand-1 must not be a
		//    paren-expr/array that itself leads with an open delim (excludes
		//    condition_first_operand_paren_no_merge, where the fork breaks
		//    the chain instead of gluing to operand-1's `(`).
		final unwrapCandidate: Bool = condWrapForced
			&& isChainOps(ops)
			&& !leadingOperandOpensDelim(items[0])
			&& laterOperandContainsArrow(items);
		// A cascade whose flat answer is itself a break mode lays the chain out
		// broken even where it fits — pivot the NoWrap UNWRAP shape against it.
		if (unwrapCandidate && isBreakMode(flat.mode))
			return WrapBoundary(IfNaturalFirstLineFitsOpenDelim(opt.lineWidth, flatSide, shapeNoWrapAt(flat.location)));
		if (flatAll != null && brkAll != null && sameRule(flatAll, brkAll)) return WrapBoundary(flatSide);
		// ω-unwrap-add-ops (inverse CollapsePass): for a pure opAddSub
		// chain (`+`/`-` only) whose broken shape differs from its flat
		// (NoWrap-glued) shape, TAG the broken branch with
		// `CollapseAddProbe`. The marker is render-transparent (byte-inert
		// on its own); it lets `CollapsePass` recognise this `Group(IfBreak)`
		// as an inner add-chain and, ONLY when an enclosing op-chain
		// committed to its broken form, collapse this IfBreak to its `flat`
		// (NoWrap) branch — gluing the `+`/`-` separators while leaving each
		// operand's OWN wrapping intact (a ternary / call operand still
		// breaks via its own Group). Mirrors fork `unwrapAddOps`, which
		// strips `+`/`-` line-ends inside a wrapped region without touching
		// inner ternary/call breaks. opBool / ternary chains are NOT tagged
		// (fork never `unwrapAddOps` them).
		if (isAddSubOps(ops)) {
			final brkDoc: Doc = D.groupOrRestProbe(IfBreak(CollapseAddProbe(brkSide), flatSide), restAware);
			// ω-opadd-trailing-paren-glue: when the chain's LAST operand leads
			// with a bare `(` (a paren-expr operand) and operand-1 does not, pivot
			// the committed break shape against the NoWrap glue via the natural-
			// first-line probe: the glue renders ONLY when the flat chain's first
			// physical line ENDS at an open delimiter and fits — i.e. the paren
			// operand leading-broke under a fillLine-family expressionWrapping
			// (`a - b - (` head glued, inner nested, `)` on its own line; fork
			// `unwrapAddOps`). At the universal default the paren-expr stays
			// content-glued (`- (inner`), the probe never ends on an open delim,
			// and the committed break shape renders unchanged (fork-corpus inert).
			// The last operand must ALSO END with its close delim (a BARE paren
			// operand) via `endsWithCloseDelim`, so `(a - b) / 2` -- which leads with
			// `(` but is a Div whose paren is only the numerator -- does NOT glue: the
			// chain breaks `beforeLast` and the operand stays flat on its own line.
			final isBareParenTail: Bool = hasBareParenTail(items);
			if (!isBareParenTail) return WrapBoundary(brkDoc);
			final glueProbe: Doc = IfNaturalFirstLineFitsOpenDelim(opt.lineWidth, brkDoc, shapeNoWrapAt(flat.location));
			// ω-opadd-trailing-paren-break: a 2-operand `a OP (bare paren)` whose
			// rendered line OVERFLOWS breaks the chain at its own operator
			// (`a\n+ (paren)`) whenever the paren operand FITS the continuation line
			// it would land on — the outer-first priority (ω-outer-first-wrap's rung
			// at the chain level): the seam BETWEEN the two operands is an outer
			// boundary, the paren's own `(` an inner one, so the delimited group
			// stays intact and the break lands one level up. Only when the paren
			// cannot fit that continuation does the decision fall through to
			// `glueProbe`, which keeps the head glued and lets the paren open
			// (`a + (` … `)` — fork `unwrapAddOps`).
			//
			// OPERAND CLASS IS NOT A GATE. The arm shipped restricted to a
			// paren wrapping a same-class opAddSub subexpression (`(b - c)`), with a
			// ternary / other-class paren (`(cond ? a : b)`) kept on the glue probe
			// as fork parity. That restriction is retired: the user-facing rule is
			// "a break inside an inner `()` is less preferable than a break at an
			// outer boundary", and the operator class of the paren's CONTENTS says
			// nothing about which boundary is outer. A DELIBERATE fork divergence,
			// re-pinned in `HxOpAddParenInnerBreakTest` and
			// `HxCallParamOuterFirstWrapSliceTest`.
			//
			// SCOPE `items.length == 2`: the forced `OnePerLineAfterFirst` equals the
			// fillLine-beforeLast shape only for one gap; 3+-operand chains keep the
			// glue probe unchanged, and `HxOpAddTrailingParenGlueSliceTest`'s
			// 3-operand glue stays pinned. Widening it is REFUSED — it costs passing
			// fork goldens and pinned anyparse shapes for one site; the record is in
			// `CollapsePass.commitChainGlue`'s doc, which fixed the 3+-operand
			// cascade at its real seam, the width-blind forward glue commit.
			//
			// UNREACHABLE-ARM PRUNE `contWidth > opt.lineWidth`: the continuation is
			// `indent + cols + contWidth` columns wide and `indent + cols >= 0`, so a
			// tail wider than the limit can NEVER win the fits probe. Emitting the
			// probe anyway would be render-inert but NOT walker-inert: the fits arm
			// is SLOT-INVERTED (see below), so every walker that resolves
			// `IfArrowContinuationFits` on its flat side would see the forced-break
			// shape and answer questions about it — that flipped an enclosing
			// sole-arg call from hugged to opened for a paren whose ternary branches
			// carry their own chain breaks (`HxTernaryBranchChainIndentTest`).
			// Pruning the dead arm keeps those shapes on the glue probe by
			// CONSTRUCTION rather than by a render-time answer no walker sees.
			//
			// SLOT INVERSION: `IfArrowContinuationFits` renders its FLAT slot when
			// the continuation fits, and here "fits" is the reason to BREAK — so
			// `forcedBreak` sits in the flat slot and `glueProbe` in the break slot,
			// the reverse of the arrow consumer's pairing (Doc.hx records the same
			// inversion at `WrapList.shapeSingleArgGlue`'s two consumers).
			//
			// WIDTH CONVENTIONS, both `lineWidth + 1`, and neither is decorative:
			//  - the outer gate is `IfFullLineExceeds`, NOT `IfLineExceeds`. The
			//    question is "does the rendered PHYSICAL line exceed the limit", and
			//    only the `n > width` form of that probe charges `pendingSpace` — the
			//    un-flushed `OptSpace` after an `=` that lands on the same line but is
			//    not yet in `col`. `IfLineExceeds(lineWidth)` reads a column one short
			//    of the truth, which the statement context cancels (its trailing `;`
			//    IS counted by the rest-of-stack walk — the extra rest column offsets
			//    the short `col`; under this ctor the charged pending space and the
			//    `+ 1` on `n` cancel the same way, so statement output is unchanged
			//    at every probed width) and the CALL-ARGUMENT continuation does not —
			//    there `col` is exact and the rest is 0, so it fired on a line
			//    landing EXACTLY on the limit and broke an argument that fits. At
			//    this ctor's `lineWidth + 1` calibration the renderer picks the
			//    BG-deferring rest-of-stack walker (`flatTokenWidthOfRestStack`,
			//    same as `IfLineExceeds`; the BG-descending `Full` form serves the
			//    `n == lineWidth` chain probes) — probed nil on this arm's shapes
			//    at the time of the ctor swap. Both edges are
			//    pinned (`HxOpAddParenInnerBreakTest` at the statement, the
			//    outer-first-wrap continuation pins at the call argument).
			//  - `IfArrowContinuationFits`'s own `n` is `lineWidth + 1` for the family
			//    reason: it fits on strict `<`, so the budget must exclude the column
			//    `n` itself for a continuation landing ON the limit to count as
			//    fitting.
			if (items.length != 2) return WrapBoundary(glueProbe);
			final cols: Int = nestSuppress ? 0 : indentUnitOf(opt);
			final contWidth: Int = ops[ops.length - 1].length + 1 + DocMeasure.flatTokenWidth(items[items.length - 1]);
			if (contWidth > opt.lineWidth) return WrapBoundary(glueProbe);
			final forcedBreak: Doc = shapeOnePerLineAfterFirst(items, ops, cols, BeforeLast);
			return WrapBoundary(IfFullLineExceeds(
				opt.lineWidth + 1, IfArrowContinuationFits(cols, contWidth, opt.lineWidth + 1, glueProbe, forcedBreak),
				shapeNoWrapAt(flat.location)
			));
		}
		// rest-aware pivot: a chain the caller flagged `restAware` (a ternary, or an
		// `&&` / `||` chain, in every host context except an interpolation body or an
		// explicit expression paren, see `lowerTernaryBranch` / `lowerInfixChain`)
		// reaches this pivot. A plain `Group(IfBreak)`'s fitsFlat measures
		// `col + flatWidth` and IGNORES the rest-of-stack (the statement `;`, an
		// enclosing argument `,`) and the un-flushed space after an `=`, so a chain
		// whose flat body ends at lineWidth stays glued while its physical line
		// overflows by one or two columns; the fork wraps it at the chain operator,
		// where the glued chain broke at the first INNER group that did count the
		// rest (before a nested `==`, after `return`). Swap to `GroupWithRestProbe`,
		// which keeps the same fitsFlat decision (a break-mode `flat` cascade with
		// inner hardlines makes fitsFlat refuse to flatten and commit to break, where
		// a flatTokenWidth probe would collapse those hardlines to 0-width and stay
		// under threshold) but subtracts the pending space and
		// `flatTokenWidthOfRestStack(stack)` from the budget, so the whole physical
		// line is counted.
		final ifBreak: Doc = IfBreak(brkSide, flatSide);
		return WrapBoundary(D.groupOrRestProbe(ifBreak, restAware));
	}

	/**
	 * Flat-measure the chain operands: `total` is the joined flat span (operand
	 * widths plus a ` op ` gap per operator), `maxLen` the widest rendered
	 * operand (operands beyond the first include their leading `op ` per
	 * upstream's per-item width semantic), and `anyHardline` whether any operand
	 * has a hardline anywhere (drives the break-commit shortcut). Split out of
	 * `emit` for the complexity threshold.
	 */
	private static function measureChain(items: Array<Doc>, ops: Array<String>): WrapItemMeasure {
		var total: Int = 0;
		var maxLen: Int = 0;
		var minLen: Int = WrapList.MAX_ITEM_LEN;
		var equalLens: Bool = true;
		var firstLen: Int = -1;
		var anyHardline: Bool = false;
		for (i => item in items) {
			if (WrapList.flatLength(item) < 0) anyHardline = true;
			final w: Int = DocMeasure.flatTokenWidth(item);
			total += w;
			// `anyItemLength` mirrors upstream haxe-formatter's
			// per-item width semantic: each operand beyond the first
			// is preceded by `op ` on its continuation line, so the
			// rendered token width for those items includes the
			// leading `op ` (operator + single space). The first
			// operand has no leading operator (it sits at the call
			// site after the assignment / open paren). Without this
			// adjustment a chain of ~39-char operands joined by `||`
			// would measure `maxLen=39` and miss rule 1's
			// `anyItemLength >= 40` predicate, while upstream
			// measures `maxLen=42` (`|| ` + 39) and the rule fires.
			final renderedW: Int = i == 0 ? w : (ops[i - 1].length + 1 + w);
			if (renderedW > maxLen) maxLen = renderedW;
			if (renderedW < minLen) minLen = renderedW;
			// `equalItemLengths` reads the BARE operand width, not the rendered
			// one. `renderedW` charges every operand but the FIRST for an operator,
			// so a chain of identical operands answers "not equal" no matter how
			// uniform it is: the predicate could never match, and its `value: 0`
			// twin could never fail.
			//
			// This is a deliberate DIVERGENCE from upstream, not parity with it.
			// Upstream charges every operand but the LAST (its operator is
			// trailing) and forgives the short one with a hard-coded `(length + 2)
			// == itemLength` — a literal 2, which only ever equalises a ONE-
			// character operator. Every operator these two cascades handle is two
			// (`||`, `&&`, and `+` / `-` arrive here via `opAddSubChain` with the
			// same ` op ` padding), so upstream's allowance never fires and it
			// answers "not equal" for uniform chains too. Measuring the operands
			// themselves is the semantic the predicate NAMES; matching upstream's
			// arithmetic would only reproduce a number that never fires.
			//
			// `minLen` / `maxLen` deliberately keep the rendered width — those feed
			// width-vs-`maxLineLength` questions, where the operator is real ink —
			// so a cascade CAN be told "every item is equal" beside a min and max
			// that differ. Nothing reads them together today, and no shipped fork
			// config names `equalItemLengths` on a chain cascade at all (its two
			// uses are both `arrayWrap` / `mapWrap`).
			if (firstLen < 0)
				firstLen = w;
			else if (w != firstLen)
				equalLens = false;
		}
		// Add ` op ` width per gap so the cascade's `totalLength` /
		// `exceedsMaxLineLength` predicates measure the realistic flat
		// span (`items joined by ' op '`).
		for (op in ops) total += op.length + 2;
		return {
			total: total,
			maxLen: maxLen,
			minLen: minLen,
			equalLens: equalLens,
			anyHardline: anyHardline
		};
	}

	/**
	 * ω-ternary-cuddled-braces — may the `:` and the ELSE branch's opening
	 * delimiter ride on the THEN branch's own closing line, rather than opening
	 * a continuation line that would hold nothing but `: {`?
	 *
	 * Yes exactly when `WriteOptions.ternaryCuddledBraces` is on and both
	 * operands answer for their own half:
	 *
	 *  - the THEN branch's rendered tail is a forced closing line whose leftmost
	 *    closer is a BRACE landing at Nest depth ZERO — the indent of the line
	 *    the branch itself started on. `DocMeasure.breakTailCloseNest` answers
	 *    all three in one walk, which is why it is asked instead of a
	 *    forced-break test plus a separate brace test: the depth and the brace
	 *    have to be measured on the same rendering. The zero is what makes the
	 *    cuddle safe rather than merely shorter — the else branch's `{` opens at
	 *    the `?` line's indent, so its own `}` closes there too and no delimiter
	 *    lands below its opener. A then branch that renders FLAT has no closing
	 *    line to ride and answers `-1`, so a ternary whose branches both fit is
	 *    never rebuilt onto one line.
	 *  - the ELSE branch OPENS with a collection delimiter. `} : {` is legible
	 *    because what follows the separator is itself a delimited body that owns
	 *    its own multi-line layout; a call / chain / bare identifier there keeps
	 *    the continuation line the cascade gave it.
	 *
	 * The FIRST leg is structural and column-free, so no render-time measurement
	 * can flip a ternary's shape — the discipline the sibling
	 * `methodChainCuddledLinks` gate keeps throughout. The second leg gives that
	 * up deliberately, because a config that defers every object-literal break to
	 * the renderer (`objectLiteral.defaultWrap: "ignore"` plus a single
	 * `exceedsMaxLineLength` rule — Pony's own in-flight config) leaves the
	 * structural read nothing to see; it pays for the render-time reading with a
	 * probe the caller must emit, and its pre-knob shape sits in the slot every
	 * Doc walker resolves to.
	 */
	private static function ternaryBracesCuddle(
		items: Array<Doc>, ops: Array<String>, opt: WriteOptions
	): Null<{ probeGated: Bool, closerWidth: Int }> {
		if (!opt.ternaryCuddledBraces || !isTernaryOps(ops) || items.length != 3) return null;
		if (!WrapList.startsWithCollectionDelim(items[2])) return null; // noqa: magic-number
		// `closerWidth` is measured on whichever rendering the leg admitted, never
		// on `items[1]` as written: the pivot leg's branch has no committed closing
		// line at all, so only its resolved arm knows how wide the run is.
		if (DocMeasure.breakTailCloseNest(items[1]) == 0) return { probeGated: false, closerWidth: DocMeasure.breakTailCloseRun(items[1]) };
		// ω-render-pivot-collection-arg, cuddle leg — the SAME second scan the hug
		// below runs, and for the same reason: a branch whose break the renderer
		// decides leaves no forced hardline for the structural read, so resolving
		// its pivot is the only way to see the closing line at all. What differs is
		// the certainty available. The hug knows its branch breaks because the whole
		// ternary did not fit and the hug's own head does; a cuddle sits on the
		// branch's CONTINUATION line, which can fit while the ternary does not — so
		// the resolved arm only makes the cuddle POSSIBLE, and the caller owes it a
		// continuation-fits probe. Without that probe this leg would rebuild a
		// ternary whose branches both fit onto one line, which is the shape the
		// structural leg refuses by construction. Both pivot shapes are asked for,
		// in the order `WrapList.shapeMultiArgCollection` asks them: the
		// `IfFirstLineExceeds` threshold a shadowed breaking default emits, then the
		// `Group(IfBreak(…))` a two-run `exceedsMaxLineLength` cascade emits
		// (`fitPivot`). The second carries the stricter contract — a committed host
		// does NOT make it certain to fire — and the probe owed is the same one
		// either way, so they share it.
		final threshold: Null<Doc> = WrapList.renderPivotBreakArm(items[1]);
		final arm: Null<Doc> = threshold ?? WrapList.renderPivotBreakArm(items[1], true);
		return arm == null || DocMeasure.breakTailCloseNest(arm) != 0
			? null
			: { probeGated: true, closerWidth: DocMeasure.breakTailCloseRun(arm) };
	}

	/**
	 * The shape an ADMITTED ternary cuddle takes, `cuddled` and `plain` being the two
	 * already-built candidates. `items` / `ops` are the three-operand ternary
	 * `ternaryBracesCuddle` admitted, and `closerWidth` is the rendered width of the
	 * then branch's closing-line closer run.
	 *
	 * The else branch is measured TWICE, because gluing does not move it — it SHIFTS
	 * it: the separator line the cuddle removes was `: <else>` at `cols`, the line it
	 * rides instead is `} : <else>`, wider by that whole closer run plus a space. Which
	 * is why `closerWidth` is a number and not a constant — a branch closing `}))`
	 * opens its line three columns wide, so charging one closer admits a glued line
	 * past the limit and the renderer then breaks a branch that had been one line.
	 *
	 * The two widths BRACKET the decision rather than decide it: both failing means the
	 * else lays out across lines either way, both fitting means it stays on one line
	 * either way, and only the gap between them — fits alone, overflows glued — keeps
	 * its separator line. `flatTokenWidth` is right even for an else whose break the
	 * renderer decides: it reports the whole flat width and fails both probes together.
	 *
	 * Both else probes are `IfArrowContinuationFitsWithRest` at `opt.lineWidth + 1`,
	 * because the tail is CHARGED rather than reserved: the line they measure ends
	 * where the HOST does, not where the branch does, and the plain ctor's
	 * column-independent width cannot see that tail. A constant reserve cannot replace
	 * the reading — one column is exact only for a STATEMENT-position ternary, and the
	 * two probes want OPPOSITE conservatism, so a loose glue probe cuddles a line that
	 * overflows while a strict else probe reads a fitting else as "breaks anyway" and
	 * cuddles it too.
	 *
	 * SLOT INVERSION on the `probeGated` layer, the pairing four other consumers of
	 * this ctor already use: the arm renders `flatDoc` when the continuation FITS, and
	 * a then branch that fits stays FLAT, so the PRE-KNOB shape is the flat slot and
	 * the cuddle the break slot — which is what keeps every Doc walker reading the
	 * pre-knob layout. The else-fits probe pairs the same way; the inner GLUE probe
	 * does NOT, since fitting is its reason to glue, so its flat slot holds the cuddle
	 * and a walker resolving that node reads the CUDDLED layout; `Doc.hx`'s header
	 * records the disagreement. `probeGated` itself stays on the PLAIN ctor by design:
	 * it asks about the THEN branch's continuation line, which under the pre-knob
	 * shape ends at the branch, so its tail is empty and charging the render stack
	 * would bill a terminator several lines further down.
	 */
	private static function cuddleShape(
		probeGated: Bool, closerWidth: Int, items: Array<Doc>, ops: Array<String>, opt: WriteOptions, cols: Int, probeWidth: Int,
		cuddled: Doc, plain: Doc
	): Doc {
		final elseWidth: Int = ops[1].length + 1 + DocMeasure.flatTokenWidth(items[2]);
		final gluedWidth: Int = elseWidth + closerWidth + 1;
		final guarded: Doc = IfArrowContinuationFitsWithRest(
			cols, elseWidth, opt.lineWidth + 1, cuddled,
			IfArrowContinuationFitsWithRest(cols, gluedWidth, opt.lineWidth + 1, plain, cuddled)
		);
		return probeGated ? IfArrowContinuationFits(cols, probeWidth, opt.lineWidth + 1, guarded, plain) : guarded;
	}

	/**
	 * ω-ternary-collection-hug: returns the index (1 = THEN, 2 = ELSE) of a
	 * TERNARY chain's SOLE multi-line branch when that branch is a bare
	 * collection literal — it STARTS with `{`/`[` and ENDS with the matching
	 * `}`/`]`, so its multi-line-ness is owned entirely by the collection's own
	 * internal breaks — while the condition and the OTHER branch both render
	 * flat (`flatLength >= 0`). Returns -1 otherwise.
	 *
	 * The clean sub-pattern this predicate unlocks: `cond ? flat : {\n…\n}` (or
	 * the mirror with a multi-line THEN). Such a ternary HUGS — `cond ? A : {`
	 * rides the head/assignment line and the collection self-breaks — rather
	 * than leading-break the whole ternary (`\n? A\n: B`). The hug is applied
	 * only when the head up to the collection's open delim FITS the line
	 * (`IfFirstLineExceeds` probe at the call site); an overflowing head keeps
	 * the leading-break-all shape.
	 *
	 * Deliberately NARROW so the entangled overlapping sub-patterns keep the
	 * leading-break-all shape: a SECOND multi-line branch (both-branch explode),
	 * a multi-line CONDITION, a nested ternary branch (STARTS with an
	 * identifier, not `{`/`[`), and a branch that is an opAdd / opBool CHAIN
	 * built around a collection (`{…} + x` — ENDS with `x`, not `}`) all fail
	 * the predicate.
	 */
	private static function ternaryHugCollectionBranchIndex(items: Array<Doc>, ops: Array<String>): Int {
		if (items.length != 3 || !isTernaryOps(ops)) return -1;
		if (WrapList.flatLength(items[0]) < 0) return -1;
		var idx: Int = -1; // noqa: magic-number
		for (i in 1...3) if (WrapList.flatLength(items[i]) < 0) { // noqa: magic-number
			if (idx != -1) return -1;
			idx = i;
		}
		// ω-render-pivot-collection-arg: no branch has committed to a break yet, so
		// look for one whose break the RENDERER decides — it reads flat to
		// `flatLength` on the pass that writes the newline and multi-line on the
		// pass that reads it back, and the hug would fire on the second pass only.
		// A SECOND scan, not a widening of the first: a pivot may only NOMINATE a
		// branch, never disqualify one, since nearly every nested CALL carries a
		// pivot and the first scan's second-branch bail would then reject almost
		// every ternary — it cost `a ? { … } : f(x)` its hug.
		if (idx == -1) for (i in 1...3) if (WrapList.renderPivotBreakArm(items[i]) != null) { // noqa: magic-number
			if (idx != -1) return -1;
			idx = i;
		}
		if (idx == -1) return -1;
		final branch: Doc = items[idx];
		if (!WrapList.startsWithCollectionDelim(branch)) return -1;
		final last: Null<String> = WrapList.lastVisibleText(branch);
		return last == '}' || last == ']' ? idx : -1;
	}

	/**
	 * ω-render-pivot-collection-arg, ternary leg: the hug probe, with the
	 * branch's own render-time break pivot resolved to its break arm.
	 *
	 * `IfFirstLineExceeds` measures the FLAT arm's first line, and that arm is
	 * the hug — so the branch inside it must carry the break the hug exists to
	 * accommodate. Left unresolved, the probe measures the whole ternary flat,
	 * picks the leading-break shape, and the newline it writes is what the next
	 * pass force-commits — after which this same hug fires and the two passes
	 * disagree. A branch that already carries a hardline resolves to itself.
	 */
	private static function ternaryHugShape(
		idx: Int, items: Array<Doc>, ops: Array<String>, opt: WriteOptions,
		evalAt: (Bool, Array<Int>) -> { mode: WrapMode, location: WrappingLocation },
		shapeAt: ({ mode: WrapMode, location: WrappingLocation }) -> Doc
	): Doc {
		final arm: Null<Doc> = WrapList.renderPivotBreakArm(items[idx]);
		final hugItems: Array<Doc> = arm == null ? items : [for (i in 0...items.length) i == idx ? arm : items[i]];
		return IfFirstLineExceeds(opt.lineWidth, shapeAt(evalAt(true, [])), shapeNoWrap(hugItems, ops));
	}

}

/**
 * The Keep shape's per-gap comment channels besides the after-operator one, parallel to `ops`: `own` the run of
 * own-line comments between an operator and its right operand, `above` an after-operator `//` comment as the line
 * `comments.trailingCommentOverflow: "above"` may move it to (null where it may not), `lineWidth` the overflow limit.
 */
private typedef KeepGapComments = {
	final own: Null<Array<Null<Doc>>>;
	final above: Null<Array<Null<Doc>>>;
	final lineWidth: Int;
}
