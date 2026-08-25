package anyparse.format.wrap;

import anyparse.core.Doc;
import anyparse.core.DocMeasure;
import anyparse.format.IndentChar;
import anyparse.format.WriteOptions;

using Lambda;

/**
 * Runtime helper that emits a `Doc` for a binary-op chain construct
 * (`a || b || c` / `a + b - c + d` — left-assoc nested `BinOp(left,
 * right)` AST collapsed by the caller into a flat `items + ops` pair)
 * whose layout is driven by a `WrapRules` cascade.
 *
 * Format-neutral — the chain extraction happens in a grammar-specific
 * helper that knows the language's BinOp ctors (e.g. `Or` / `And` for
 * the opBoolChain class, `Add` / `Sub` for the opAddSubChain class in
 * Haxe). This engine accepts the pre-built `items:Array<Doc>` (each
 * already rendered through the host writer) interleaved by an
 * `ops:Array<String>` (operator text per gap) and runs the cascade
 * decision + chain shape selection.
 *
 * `items.length == ops.length + 1` (n operands separated by n-1
 * operators).
 *
 * Differs from `WrapList.emit` in three ways:
 *  - chain has NO open/close delimiters (operands are bare);
 *  - the separator between two operands carries an operator text that
 *    differs per position (mixed `||` / `&&` chain in haxe-formatter's
 *    `opBoolChain` class), so the engine accepts a parallel `ops`
 *    array rather than a single `sep`;
 *  - operator placement is implicit in the selected `WrapMode` —
 *    `OnePerLineAfterFirst` puts the operator at the START of each
 *    continuation line (BeforeLast placement, mirroring haxe-formatter
 *    `wrappingLocation: BeforeLast`); `OnePerLine` and `FillLine` put
 *    it at the END of each line that breaks (After placement,
 *    matching haxe-formatter's default for those modes).
 *
 * Mirrors haxe-formatter's `WrappingProcessor.markSingleOpBoolChain` /
 * `markSingleOpAddChain` — both consume a chain of mixed-but-related
 * operators and emit one cascade decision per top-level chain.
 *
 * Modes:
 *  - `NoWrap`               → `items[0] op0 items[1] op1 …` (all inline,
 *    spaces around each op). Location field is irrelevant.
 *  - `OnePerLineAfterFirst` → first operand stays on the call-site
 *    line, remaining operands each on their own indented continuation
 *    line. With `BeforeLast` the op prefixes each continuation
 *    (`dirty = dirty\n\t|| (X)\n\t|| (Y)`); with `AfterLast` the op
 *    suffixes the previous line (`dirty = dirty ||\n\t(X) ||\n\t(Y)`).
 *  - `OnePerLine`           → every operand (including the first) on
 *    its own indented line. With `BeforeLast` every continuation line
 *    starts with `op operand` except the first; with `AfterLast` every
 *    line except the last ends with ` op`.
 *  - `FillLine` /
 *    `FillLineWithLeadingBreak` → soft-line packing through `Fill` —
 *    items pack inline up to line budget; the soft-line between two
 *    operands breaks at the chain's continuation indent when the next
 *    one would overflow. With `BeforeLast` the op rides AHEAD of the
 *    next operand (so a broken soft-line lands the op at the start of
 *    the continuation line); with `AfterLast` the op suffixes the
 *    previous operand (so the broken soft-line lands the next operand
 *    at the start of the continuation line).
 *
 * The `location` axis (`BeforeLast` vs `AfterLast`) is selected per
 * rule via `WrapRule.location` (or the parent
 * `WrapRules.defaultLocation` fallback) and resolved by
 * `WrapList.decideRuleWithLineLengthState` — column-aware variant of
 * `decideRule` that defers `LineLengthLargerThan` evaluation to a
 * caller-supplied predicate so the renderer's column position can
 * gate threshold-firing at layout time. Mirrors haxe-formatter's
 * `wrapping.<class>.location` field on per-rule entries in
 * `WrapConfig.hx`.
 */
@:nullSafety(Strict)
final class BinaryChainEmit {

	public static function emit(
		items: Array<Doc>, ops: Array<String>, opt: WriteOptions, rules: WrapRules, nestSuppress: Bool = false,
		condWrapForced: Bool = false, ?sourceBreakBefore: Array<Bool>, headBreak: Bool = false, forceKeep: Bool = false,
		?afterComments: Array<Null<Doc>>, ternaryRestAware: Bool = false,
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
		?forceKeepLocation: Null<WrappingLocation>
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
		final measure: { total: Int, maxLen: Int, anyHardline: Bool } = measureChain(items, ops);
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
		// `buildBinaryThresholdTree` (Haxe forbids closure-on-inline-closure).
		function evalAt(exceeds: Bool, firing: Array<Int>): { mode: WrapMode, location: WrappingLocation } {
			return WrapList.decideRuleWithLineLengthState(
				rules, items.length, maxLen, total, exceeds, anyHardline, t -> t == opt.lineWidth ? exceeds : firing.contains(t)
			);
		}

		function shapeAt(r: { mode: WrapMode, location: WrappingLocation }): Doc {
			return shape(r.mode, r.location, items, ops, cols, indentUnit, sourceBreakBefore, headBreak, afterComments);
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
		// `buildBinaryThresholdTree` handles 0/1/N thresholds via
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
			WrapBoundary(hardlineChainShape(items, ops, opt, extraThresholds, evalAt, shapeAt, shapeNoWrapAt))
		else if (pivotHugIdx >= 0)
			WrapBoundary(IfLineExceeds(
				opt.lineWidth + 1, ternaryHugShape(pivotHugIdx, items, ops, opt, evalAt, shapeAt),
				emitNoThreshold(items, ops, opt, nestSuppress, condWrapForced, ternaryRestAware, evalAt, shapeAt, shapeNoWrapAt)
			))
		else if (extraThresholds.length == 0)
			emitNoThreshold(items, ops, opt, nestSuppress, condWrapForced, ternaryRestAware, evalAt, shapeAt, shapeNoWrapAt)
		else if (extraThresholds.length == 1)
			emitSingleThreshold(extraThresholds[0], opt, evalAt, shapeAt)
		else
			WrapBoundary(buildBinaryThresholdTree(extraThresholds, [], null, evalAt, shapeAt));
	}

	/**
	 * ω-assign-chain-fill: OVERFLOW-ONLY wrap for a right-associative `=`
	 * chain (`a = b = c = value`), whose nested `Assign(l, Assign(l, …))`
	 * spine the caller has already flattened into `items` (n operands, n-1
	 * implicit `=` gaps). Unlike the cascade-driven `emit`, an assign chain
	 * has NO `WrapRules` class of its own — the fork never wraps one until
	 * the line overflows — so the decision is a single probe rather than a
	 * rule enumeration.
	 *
	 * FLAT SHAPE is built right-nested from the tail so it is byte- AND
	 * tree-identical to the per-level `Concat([left, ' ', '=', OptSpace(' '),
	 * right])` the plain lowering emits. The `OptSpace(' ')` is load-bearing:
	 * it drops the trailing space when the RHS opens with a hardline (a
	 * break-mode chain / collection on the right of the last `=`), so it must
	 * NOT be folded into a `Text(' =')` on this side.
	 *
	 * BREAK SHAPE reuses `shapeFillLine(…, AfterLast)` — the established
	 * binop-chain fill convention. `AfterLast` suffixes the operator to the
	 * previous operand (`a =\n\tb = value`), which is the only placement that
	 * reads for an assignment: a continuation line led by `= b` would look
	 * like a fresh statement. Packing (rather than one-operand-per-line) comes
	 * for free from the shared `Fill(enriched, Line(' '), 1)` with its
	 * fork-`>=` tail reserve, and the shared `Nest` puts the continuation at
	 * one indent level.
	 *
	 * GATE is `IfNaturalFirstLineExceeds`, NOT `Group` / `IfLineExceeds`:
	 * the natural probe resolves inner `Group`s by their OWN `fitsFlat`, so
	 * `x = call(reallyLongArgs…)` — whose call folds its own arguments —
	 * has a SHORT natural first line (it ends at the call's open paren), the
	 * probe does not fire, and the output stays byte-identical to today's.
	 * A flat-width pivot would measure the un-wrapped RHS and break the `=`
	 * on every such site. The probe's render arm already honours
	 * `Frame.forceFlat`, so a chain inside a force-flat region (string
	 * interpolation) collapses to the flat shape without a `WrapBoundary`
	 * wrapper — adding one would defeat that.
	 *
	 * Threshold is `opt.lineWidth + 1` per the project's width convention:
	 * every exceeds-maxLineLength probe (including the natural / fits-probe
	 * family) compares against `lineWidth + 1`, because the render arm fires
	 * on `>=` while the config predicate means "strictly past the limit".
	 * On a chain of PLAIN operands the constant is byte-inert (measured): the
	 * break shape's own `Group` re-runs `fitsFlat`, which is Wadler-inclusive,
	 * at the same column — so a chain that merely REACHES the limit renders
	 * flat whichever threshold the probe carries. Where the two gates DISAGREE
	 * — an operand whose inner `Group` wraps, so the `Group` no longer re-glues
	 * — the constant is observable at exactly one column, and `+ 1` is the
	 * correct answer there (measured): a prefix landing ON column `lineWidth`
	 * stays glued, a bare `lineWidth` would break a line that legally fits.
	 *
	 * The continuation always nests one indent level: unlike `emit` this
	 * engine takes no `nestSuppress`, because an assignment is a statement-
	 * level (or call-argument) construct that never sits directly inside a
	 * cond paren-wrap whose `Nest` it would compound with.
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
		return leadingOperandOpensDelim(items[items.length - 1], true) && WrapList.endsWithCloseDelim(items[items.length - 1])
			&& !leadingOperandOpensDelim(items[0]);
	}

	/**
	 * Recursive helper that builds the `IfWidthExceeds + IfBreak` tree
	 * for chain-emit's cascade-with-thresholds layout. Sister of
	 * `WrapList.buildThresholdTree` but emits chain shapes
	 * (`shape(mode, location, …)`) at each leaf instead of routing
	 * through a delimited-list `shapeAt(mode, lead)` closure.
	 *
	 *  - `forcedExceeds == true` → emit a single shape at each leaf
	 *    (no IfBreak — parent committed to break-mode regardless of
	 *    column). Used by the `anyHardline` path.
	 *  - `forcedExceeds == null` → enumerate `exceeds=false` /
	 *    `exceeds=true` at each leaf and split via `Group(IfBreak(…))`
	 *    when the resolved {mode, location} pairs differ.
	 *
	 * `firing` accumulates thresholds chosen as "fired" along the
	 * brk-side recursion. No impossibility filtering — renderer's
	 * column probe at each `IfWidthExceeds` layer is monotone, so the
	 * impossible-state leaves are unreachable at runtime regardless.
	 */
	private static function buildBinaryThresholdTree(
		thresholds: Array<Int>, firing: Array<Int>, forcedExceeds: Null<Bool>,
		evalAt: (Bool, Array<Int>) -> { mode: WrapMode, location: WrappingLocation },
		shapeAt: { mode: WrapMode, location: WrappingLocation } -> Doc
	): Doc {
		if (thresholds.length == 0) {
			if (forcedExceeds != null) return shapeAt(evalAt(forcedExceeds, firing));
			final rFlat: { mode: WrapMode, location: WrappingLocation } = evalAt(false, firing);
			final rBrk: { mode: WrapMode, location: WrappingLocation } = evalAt(true, firing);
			return sameRule(rFlat, rBrk) ? shapeAt(rFlat) : Group(IfBreak(shapeAt(rBrk), shapeAt(rFlat)));
		}
		final t: Int = thresholds[0];
		final rest: Array<Int> = thresholds.slice(1);
		final firingPlus: Array<Int> = firing.copy();
		firingPlus.push(t);
		final brk: Doc = buildBinaryThresholdTree(rest, firingPlus, forcedExceeds, evalAt, shapeAt);
		final flat: Doc = buildBinaryThresholdTree(rest, firing, forcedExceeds, evalAt, shapeAt);
		return IfWidthExceeds(t, brk, flat);
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
	 * True iff any operand `Doc` is a top-level function call
	 * (`DocMeasure.operandIsCall`). The ω-opbool-reeval gate mirrors fork
	 * `hasSimpleCallParamBreaksBetween` (an inner `POpen` that wrapped); a chain
	 * with NO call operand can never have a callParameter wrap to re-evaluate
	 * after, so the marker is skipped (byte-inert).
	 */
	private static function containsCallOperand(items: Array<Doc>): Bool {
		return items.exists(it -> DocMeasure.operandIsCall(it));
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
				s.length > 0
					&& (StringTools.fastCodeAt(s, 0) == '('.code || !parenOnly
						&& (StringTools.fastCodeAt(s, 0) == '['.code || StringTools.fastCodeAt(s, 0) == '{'.code));
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
			case Group(i), BodyGroup(i), GroupWithRestProbe(i), Nest(_, i), Flatten(i), HardFlatten(i), CollapseProbe(i),
				CollapseAddProbe(i), CollapseBoolProbe(i), CollapseChainProbe(i), WrapBoundary(i), ConditionalMarkerZero(i),
				ConditionalMarkerDecrease(i):
				leadingOperandOpensDelim(i, parenOnly);
			case IfBreak(_, flat), IfWidthExceeds(_, _, flat), IfFirstLineExceeds(_, _, flat), IfLineExceeds(_, _, flat),
				IfResidualLineExceeds(_, _, flat), IfFullLineExceeds(_, _, flat), IfNaturalFirstLineExceeds(_, _, flat),
				IfNaturalFirstLineExceedsWithRest(_, _, flat), IfNaturalFirstLineFitsOpenDelim(_, _, flat),
				IfArrowContinuationFits(_, _, _, _, flat), IfIndentWidthExceeds(_, _, _, flat), IfGluedFirstLineExceeds(_, _, _, flat):
				// PROBE FAMILY (Doc.hx header table), flat side for all three:
				//  - `IfArrowContinuationFits` is a two-SHAPE probe like the natural
				//    siblings above, and its two shapes always share a leading token —
				//    the list's own `Text(open)` at the three call-argument consumers,
				//    `items[0]` at the chain consumer this file emits itself (`emit`'s
				//    arrow-continuation glue, which pairs two layouts of the same
				//    operand array and no delimiter at all). Side-independent either
				//    way; flat keeps this walker on one side for the whole two-shape
				//    population.
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
	 *   chain WITHOUT a hardline reaches `emitNoThreshold`'s ω-opadd-trailing-paren-glue and
	 *   keeps its head glued, so a paren carrying a forced break (a value-`if` chain in
	 *   `expressionIf` policy layout, a `switch`, a block) was the one shape that did not.
	 *
	 * The pivot is the same `IfNaturalFirstLineFitsOpenDelim` that arm uses, so the two agree by
	 * construction: glue when the glued shape's natural first line FITS, else only when it ends
	 * at an open delimiter. Note this does NOT require the paren to open — a content-glued paren
	 * whose head line fits glues too, which is the intended reading of "the break buys nothing".
	 *
	 * Measured inert on the fork corpus (946 fixtures, identical pass/fail set): at the fork
	 * defaults an expression-position `if` branch carries no forced break, so the shape does not
	 * arise there.
	 *
	 * `extraThresholds` non-empty keeps the column-aware tree — a `LineLengthLargerThan` rule at
	 * a non-`lineWidth` threshold cannot be answered here.
	 */
	private static function hardlineChainShape(
		items: Array<Doc>, ops: Array<String>, opt: WriteOptions, extraThresholds: Array<Int>,
		evalAt: (Bool, Array<Int>) -> { mode: WrapMode, location: WrappingLocation },
		shapeAt: ({ mode: WrapMode, location: WrappingLocation }) -> Doc, shapeNoWrapAt: (WrappingLocation) -> Doc
	): Doc {
		if (extraThresholds.length == 0) {
			final hugIdx: Int = ternaryHugCollectionBranchIndex(items, ops);
			if (hugIdx >= 0) return ternaryHugShape(hugIdx, items, ops, opt, evalAt, shapeAt);
			if (isAddSubOps(ops) && hasBareParenTail(items))
				return IfNaturalFirstLineFitsOpenDelim(opt.lineWidth, shapeAt(evalAt(true, [])), shapeNoWrapAt(evalAt(false, []).location));
		}
		return buildBinaryThresholdTree(extraThresholds, [], true, evalAt, shapeAt);
	}

	private static function shape(
		mode: WrapMode, location: WrappingLocation, items: Array<Doc>, ops: Array<String>, cols: Int, indentUnit: Int,
		?sourceBreakBefore: Array<Bool>, headBreak: Bool = false, ?afterComments: Array<Null<Doc>>
	): Doc {
		return switch mode {
			case NoWrap: shapeNoWrap(items, ops);
			case OnePerLine: shapeOnePerLine(items, ops, cols, location);
			case OnePerLineAfterFirst: shapeOnePerLineAfterFirst(items, ops, cols, location);
			case FillLine, FillLineWithLeadingBreak:
				shapeFillLine(items, ops, cols, indentUnit, location);
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
				shapeKeep(items, ops, cols, location, sourceBreakBefore, headBreak, afterComments);
			// ω-cascade-emits-comments: Ignore sister to Keep — the writer
			// pre-empts at the trivia branch. Defensive fallback to
			// shapeNoWrap on engine leakage.
			case Ignore: shapeNoWrap(items, ops);
			case _: shapeOnePerLineAfterFirst(items, ops, cols, location);
		};
	}

	private static function shapeNoWrap(items: Array<Doc>, ops: Array<String>): Doc {
		final inner: Array<Doc> = [items[0]];
		for (i in 0...ops.length) {
			inner.push(Text(' ${ops[i]} '));
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
		headBreak: Bool = false, ?afterComments: Array<Null<Doc>>
	): Doc {
		final breaks: Array<Bool> = sourceBreakBefore ?? [];
		// ω-keep-infix-postop-comment: a per-op comment trailing the operator
		// (`a || // c\n b`) — emit `OP // c` on the current line and force a
		// break before the next operand, regardless of the chain's location.
		inline function afterOf(i: Int): Null<Doc> return afterComments != null && i < afterComments.length ? afterComments[i] : null;
		// First operand stays at the call-site column (unless `headBreak`);
		// only the continuation tail is nested at the chain's one-tab indent,
		// so a broken gap lands its line at `base + cols` while a glued gap
		// keeps the operands inline (mirror `shapeOnePerLineAfterFirst`).
		final tail: Array<Doc> = [];
		switch location {
			case BeforeLast:
				for (i in 0...ops.length) {
					final ac: Null<Doc> = afterOf(i);
					if (ac != null) {
						tail.push(Text(' ${ops[i]}'));
						tail.push(ac);
						tail.push(Line('\n'));
					} else if (i < breaks.length && breaks[i]) {
						tail.push(Line('\n'));
						tail.push(Text('${ops[i]} '));
					} else {
						tail.push(Text(' ${ops[i]} '));
					}
					tail.push(items[i + 1]);
				}
			case AfterLast:
				for (i in 0...ops.length) {
					final ac: Null<Doc> = afterOf(i);
					if (ac != null) {
						tail.push(Text(' ${ops[i]}'));
						tail.push(ac);
						tail.push(Line('\n'));
					} else if (i < breaks.length && breaks[i]) {
						tail.push(Text(' ${ops[i]}'));
						tail.push(Line('\n'));
					} else {
						tail.push(Text(' ${ops[i]} '));
					}
					tail.push(items[i + 1]);
				}
		}
		// `headBreak` puts the head operand on its own continuation line:
		// the whole chain (head + tail) is nested and led by a `Line('\n')`.
		return headBreak ? Nest(cols, Concat([Line('\n'), items[0]].concat(tail))) : Concat([items[0], Nest(cols, Concat(tail))]);
	}

	private static function shapeOnePerLineAfterFirst(items: Array<Doc>, ops: Array<String>, cols: Int, location: WrappingLocation): Doc {
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
				for (i in 0...ops.length) {
					tail.push(Line('\n'));
					tail.push(Text('${ops[i]} '));
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

	private static function shapeOnePerLine(items: Array<Doc>, ops: Array<String>, cols: Int, location: WrappingLocation): Doc {
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
				for (i in 0...ops.length) {
					inner.push(Text(' ${ops[i]}'));
					inner.push(Line('\n'));
					inner.push(items[i + 1]);
				}
			case BeforeLast:
				for (i in 0...ops.length) {
					inner.push(Line('\n'));
					inner.push(Text('${ops[i]} '));
					inner.push(items[i + 1]);
				}
		}
		return Nest(cols, Concat(inner));
	}

	private static function shapeFillLine(
		items: Array<Doc>, ops: Array<String>, cols: Int, indentUnit: Int, location: WrappingLocation
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
				for (i in 0...ops.length) acc.push(Concat([Text('${ops[i]} '), items[i + 1]]));
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
		return Group(Nest(nestCols, Fill(enriched, Line(' '), 1)));
	}

	/**
	 * Build the chain Doc for the single-extra-threshold case (`extraThresholds
	 * == [t]`). The renderer's column-aware `IfWidthExceeds(t, …)` probe selects
	 * between the impossibility-filtered 3-state leaves. Split out of `emit` for
	 * the complexity threshold; `evalAt` / `shapeAt` are passed as the same
	 * closures `emit` uses.
	 */
	private static function emitSingleThreshold(
		t: Int, opt: WriteOptions, evalAt: (Bool, Array<Int>) -> { mode: WrapMode, location: WrappingLocation },
		shapeAt: ({ mode: WrapMode, location: WrappingLocation }) -> Doc
	): Doc {
		if (t < opt.lineWidth) {
			// 3 valid states (col+w<t implies col+w<lineWidth implies !exceeds):
			//   (firing=∅,    exceeds=no)  → rNN
			//   (firing={t},  exceeds=no)  → rYN
			//   (firing={t},  exceeds=yes) → rYY
			final rNN: { mode: WrapMode, location: WrappingLocation } = evalAt(false, []);
			final rYN: { mode: WrapMode, location: WrappingLocation } = evalAt(false, [t]);
			final rYY: { mode: WrapMode, location: WrappingLocation } = evalAt(true, [t]);
			if (sameRule(rNN, rYN) && sameRule(rYN, rYY)) return WrapBoundary(shapeAt(rNN));
			// Inner IfBreak picks between exceeds-yes and exceeds-no
			// when the column has already crossed `t`. Outer
			// IfWidthExceeds picks the column-vs-t answer first; the
			// flat side bypasses the IfBreak entirely (only one
			// valid state below `t`).
			final brk: Doc = sameRule(rYY, rYN) ? shapeAt(rYY) : Group(IfBreak(shapeAt(rYY), shapeAt(rYN)));
			return WrapBoundary(Group(IfWidthExceeds(t, brk, shapeAt(rNN))));
		}
		// t > lineWidth: 3 valid states (col+w>=t implies col+w>=lineWidth):
		//   (firing=∅,    exceeds=no)  → rNN
		//   (firing=∅,    exceeds=yes) → rNY
		//   (firing={t},  exceeds=yes) → rYY
		final rNN: { mode: WrapMode, location: WrappingLocation } = evalAt(false, []);
		final rNY: { mode: WrapMode, location: WrappingLocation } = evalAt(true, []);
		final rYY: { mode: WrapMode, location: WrappingLocation } = evalAt(true, [t]);
		if (sameRule(rNN, rNY) && sameRule(rNY, rYY)) return WrapBoundary(shapeAt(rNN));
		// Outer IfBreak picks exceeds=no/yes; inner IfWidthExceeds
		// further partitions the exceeds=yes side around `t`.
		final brk: Doc = sameRule(rNY, rYY) ? shapeAt(rYY) : Group(IfWidthExceeds(t, shapeAt(rYY), shapeAt(rNY)));
		return WrapBoundary(Group(IfBreak(brk, shapeAt(rNN))));
	}

	/**
	 * Build the chain Doc for the no-extra-threshold case (the legacy 2-state
	 * `Group(IfBreak(…))` path plus the CollapsePass-probe / cond-wrap-unwrap
	 * tags). Split out of `emit` for the complexity threshold; the closures are
	 * the same ones `emit` builds — `shapeNoWrapAt` renders the forced-NoWrap
	 * unwrap shape that bypasses the cascade-decided mode.
	 */
	private static function emitNoThreshold(
		items: Array<Doc>, ops: Array<String>, opt: WriteOptions, nestSuppress: Bool, condWrapForced: Bool, ternaryRestAware: Bool,
		evalAt: (Bool, Array<Int>) -> { mode: WrapMode, location: WrappingLocation },
		shapeAt: ({ mode: WrapMode, location: WrappingLocation }) -> Doc, shapeNoWrapAt: (WrappingLocation) -> Doc
	): Doc {
		// noqa: complexity
		final flat: { mode: WrapMode, location: WrappingLocation } = evalAt(false, []);
		final brk: { mode: WrapMode, location: WrappingLocation } = evalAt(true, []);
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
		final unwrapCandidate: Bool = condWrapForced && isChainOps(ops) && !leadingOperandOpensDelim(items[0])
			&& laterOperandContainsArrow(items);
		// `condWrapForced` forces the chain rules to {rules:[], defaultMode:FLWLB}
		// (WriterCodegen._setChainModeOverride), so flat == brk == that one break
		// mode here — pivot the NoWrap UNWRAP shape against the forced break shape.
		if (unwrapCandidate && isBreakMode(flat.mode))
			return WrapBoundary(IfNaturalFirstLineFitsOpenDelim(opt.lineWidth, shapeAt(flat), shapeNoWrapAt(flat.location)));
		if (sameRule(flat, brk)) return WrapBoundary(shapeAt(flat));
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
			final brkDoc: Doc = Group(IfBreak(CollapseAddProbe(shapeAt(brk)), shapeAt(flat)));
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
			// OPERAND CLASS IS NOT A GATE (T37). The arm shipped restricted to a
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
			// glue probe unchanged (no bac488c regression, and
			// `HxOpAddTrailingParenGlueSliceTest`'s 3-operand glue stays pinned).
			// Widening MEASURED AND REFUSED by T38: it costs two PASSING fork
			// goldens + two pinned anyparse shapes for one TM site — full record in
			// `CollapsePass.commitChainGlue`'s doc (which fixed the 3+-operand
			// cascade at its real seam, the width-blind forward glue commit).
			//
			// UNREACHABLE-ARM PRUNE `contWidth > opt.lineWidth`: the continuation is
			// `indent + cols + contWidth` columns wide and `indent + cols >= 0`, so a
			// tail wider than the limit can NEVER win the fits probe. Emitting the
			// probe anyway would be render-inert but NOT walker-inert: the fits arm
			// is SLOT-INVERTED (see below), so every walker that resolves
			// `IfArrowContinuationFits` on its flat side would see the forced-break
			// shape and answer questions about it — measured, that flipped an
			// enclosing sole-arg call from hugged to opened for a paren whose ternary
			// branches carry their own chain breaks (`HxTernaryBranchChainIndentTest`).
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
			//    pinned (`HxOpAddParenInnerBreakTest` at the statement, T20's
			//    continuation pins at the call argument).
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
		// `nestSuppress` here means call-arg / keep-in-paren.
		final boolReevalTag: Bool = isOpBoolOps(ops) && brk.location == AfterLast
			&& (brk.mode == FillLine || brk.mode == FillLineWithLeadingBreak) && !nestSuppress && containsCallOperand(items);
		final brkShape: Doc = boolReevalTag ? CollapseBoolProbe(shapeAt(brk)) : shapeAt(brk);
		// ternary-rest-aware: a ternary the caller flagged `ternaryRestAware`
		// (every host context except an interpolation body or an explicit
		// expression paren, see `lowerTernaryBranch`) reaches this pivot. A plain
		// `Group(IfBreak)`'s fitsFlat measures `col + flatWidth` and IGNORES the
		// rest-of-stack (the statement `;`, an enclosing argument `,`), so a ternary
		// whose flat body ends exactly at lineWidth stays glued while its physical
		// line overflows; the fork wraps it. Swap to `GroupWithRestProbe`, which
		// keeps the same fitsFlat decision (a break-mode `flat` cascade with inner
		// hardlines makes fitsFlat refuse to flatten and commit to break, where a
		// flatTokenWidth probe would collapse those hardlines to 0-width and stay
		// under threshold) but subtracts `flatTokenWidthOfRestStack(stack)` from the
		// budget, so the trailing content is counted. opBool `&&`/`||` chains
		// (non-ternary ops) keep the plain `Group(IfBreak)` pivot.
		final isTernaryOps: Bool = ops.length == 2 && ops[0] == '?' && ops[1] == ':';
		final ifBreak: Doc = IfBreak(brkShape, shapeAt(flat));
		return WrapBoundary(isTernaryOps && ternaryRestAware ? GroupWithRestProbe(ifBreak) : Group(ifBreak));
	}

	/**
	 * Flat-measure the chain operands: `total` is the joined flat span (operand
	 * widths plus a ` op ` gap per operator), `maxLen` the widest rendered
	 * operand (operands beyond the first include their leading `op ` per
	 * upstream's per-item width semantic), and `anyHardline` whether any operand
	 * has a hardline anywhere (drives the break-commit shortcut). Split out of
	 * `emit` for the complexity threshold.
	 */
	private static function measureChain(items: Array<Doc>, ops: Array<String>): { total: Int, maxLen: Int, anyHardline: Bool } {
		var total: Int = 0;
		var maxLen: Int = 0;
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
		}
		// Add ` op ` width per gap so the cascade's `totalLength` /
		// `exceedsMaxLineLength` predicates measure the realistic flat
		// span (`items joined by ' op '`).
		for (i in 0...ops.length) total += ops[i].length + 2;
		return { total: total, maxLen: maxLen, anyHardline: anyHardline };
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
		if (items.length != 3 || ops.length != 2 || ops[0] != '?' || ops[1] != ':') return -1;
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
		// every ternary (measured: it cost `a ? { … } : f(x)` its hug).
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
