package anyparse.format.wrap;

import anyparse.core.Doc;
import anyparse.core.DocMeasure;
import anyparse.format.IndentChar;
import anyparse.format.WriteOptions;

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
		items:Array<Doc>, ops:Array<String>,
		opt:WriteOptions, rules:WrapRules,
		nestSuppress:Bool = false, condWrapForced:Bool = false,
		?sourceBreakBefore:Array<Bool>, headBreak:Bool = false
	):Doc {
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
		var total:Int = 0;
		var maxLen:Int = 0;
		var anyHardline:Bool = false;
		for (i in 0...items.length) {
			final item:Doc = items[i];
			if (WrapList.flatLength(item) < 0) anyHardline = true;
			final w:Int = DocMeasure.flatTokenWidth(item);
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
			final renderedW:Int = (i == 0) ? w : (ops[i - 1].length + 1 + w);
			if (renderedW > maxLen) maxLen = renderedW;
		}
		// Add ` op ` width per gap so the cascade's `totalLength` /
		// `exceedsMaxLineLength` predicates measure the realistic flat
		// span (`items joined by ' op '`).
		for (i in 0...ops.length) total += ops[i].length + 2;

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
		final cols:Int = nestSuppress ? 0 : (opt.indentChar == IndentChar.Space ? opt.indentSize : opt.tabWidth);

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
		final extraThresholds:Array<Int> = WrapList.collectExtraLineLengthThresholds(rules, opt.lineWidth);

		// Cascade-eval helper: caller specifies the (exceeds,
		// firingThresholds) state and gets the cascade's resolved
		// {mode, location}. `LineLengthLargerThan` is mapped to:
		//   - `t == lineWidth` → use `exceeds` (collapse semantic)
		//   - `t != lineWidth` → membership in `firing`
		// All other cond kinds preserve their original evaluators.
		// Non-`inline` so it can be passed as a closure into
		// `buildBinaryThresholdTree` (Haxe forbids closure-on-inline-closure).
		function evalAt(exceeds:Bool, firing:Array<Int>):{mode:WrapMode, location:WrappingLocation} {
			return WrapList.decideRuleWithLineLengthState(rules, items.length, maxLen, total,
				exceeds, anyHardline,
				t -> t == opt.lineWidth ? exceeds : firing.contains(t));
		}

		function shapeAt(r:{mode:WrapMode, location:WrappingLocation}):Doc {
			return shape(r.mode, r.location, items, ops, cols, sourceBreakBefore, headBreak);
		}

		// Force-break path: cascade evaluated only against
		// `exceeds=true` (anyHardline already commits to break-mode
		// per the prior decoupling slice). Thresholds still
		// column-aware — even when the parent commits to break-mode,
		// a `LineLengthLargerThan` rule answer can flip with column.
		// `buildBinaryThresholdTree` handles 0/1/N thresholds via
		// recursion (no IfBreak split — single shape per leaf).
		if (anyHardline)
			return WrapBoundary(buildBinaryThresholdTree(extraThresholds, [], true, evalAt, shapeAt));

		// Normal path: cascade evaluated against (exceeds=false /
		// exceeds=true) AND each non-lineWidth threshold's firing
		// state. Tree construction:
		//   - 0 extra thresholds: existing 2-state Group(IfBreak)
		//   - 1 extra threshold T (impossibility-filtered, 3 shapes):
		//       * T < lineWidth: `IfWidthExceeds(T, IfBreak(YY, YN), NN)`
		//         (col<T → col<lineWidth → !exceeds; one impossible state pruned)
		//       * T > lineWidth: `IfBreak(IfWidthExceeds(T, YY, NY), NN)`
		//         (col>=T>lineWidth → exceeds; one impossible state pruned)
		//   - 2+ extra thresholds: full enumeration via
		//     `buildBinaryThresholdTree` (each `IfWidthExceeds(t, …)`
		//     nests the next threshold). Impossibility filtering not
		//     applied at N≥2; renderer never reaches the impossible-
		//     state leaves at runtime, so the extra Doc shapes are
		//     inert. None of the current default cascades use N≥2 —
		//     this branch is correctness insurance for future cascades.
		if (extraThresholds.length == 0) {
			final flat:{mode:WrapMode, location:WrappingLocation} = evalAt(false, []);
			final brk:{mode:WrapMode, location:WrappingLocation} = evalAt(true, []);
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
			final unwrapCandidate:Bool = condWrapForced && isChainOps(ops)
				&& !leadingOperandOpensDelim(items[0]);
			// `condWrapForced` forces the chain rules to {rules:[], defaultMode:FLWLB}
			// (WriterCodegen._setChainModeOverride), so flat == brk == that one break
			// mode here — pivot the NoWrap UNWRAP shape against the forced break shape.
			if (unwrapCandidate && isBreakMode(flat.mode))
				return WrapBoundary(IfNaturalFirstLineFitsOpenDelim(opt.lineWidth, shapeAt(flat),
					shape(NoWrap, flat.location, items, ops, cols, sourceBreakBefore, headBreak)));
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
			if (isAddSubOps(ops))
				return WrapBoundary(Group(IfBreak(CollapseAddProbe(shapeAt(brk)), shapeAt(flat))));
			return WrapBoundary(Group(IfBreak(shapeAt(brk), shapeAt(flat))));
		}

		if (extraThresholds.length == 1) {
			final t:Int = extraThresholds[0];
			if (t < opt.lineWidth) {
				// 3 valid states (col+w<t implies col+w<lineWidth implies !exceeds):
				//   (firing=∅,    exceeds=no)  → rNN
				//   (firing={t},  exceeds=no)  → rYN
				//   (firing={t},  exceeds=yes) → rYY
				final rNN:{mode:WrapMode, location:WrappingLocation} = evalAt(false, []);
				final rYN:{mode:WrapMode, location:WrappingLocation} = evalAt(false, [t]);
				final rYY:{mode:WrapMode, location:WrappingLocation} = evalAt(true, [t]);
				if (sameRule(rNN, rYN) && sameRule(rYN, rYY)) return WrapBoundary(shapeAt(rNN));
				// Inner IfBreak picks between exceeds-yes and exceeds-no
				// when the column has already crossed `t`. Outer
				// IfWidthExceeds picks the column-vs-t answer first; the
				// flat side bypasses the IfBreak entirely (only one
				// valid state below `t`).
				final brk:Doc = sameRule(rYY, rYN) ? shapeAt(rYY) : Group(IfBreak(shapeAt(rYY), shapeAt(rYN)));
				return WrapBoundary(Group(IfWidthExceeds(t, brk, shapeAt(rNN))));
			}
			// t > lineWidth: 3 valid states (col+w>=t implies col+w>=lineWidth):
			//   (firing=∅,    exceeds=no)  → rNN
			//   (firing=∅,    exceeds=yes) → rNY
			//   (firing={t},  exceeds=yes) → rYY
			final rNN:{mode:WrapMode, location:WrappingLocation} = evalAt(false, []);
			final rNY:{mode:WrapMode, location:WrappingLocation} = evalAt(true, []);
			final rYY:{mode:WrapMode, location:WrappingLocation} = evalAt(true, [t]);
			if (sameRule(rNN, rNY) && sameRule(rNY, rYY)) return WrapBoundary(shapeAt(rNN));
			// Outer IfBreak picks exceeds=no/yes; inner IfWidthExceeds
			// further partitions the exceeds=yes side around `t`.
			final brk:Doc = sameRule(rNY, rYY) ? shapeAt(rYY) : Group(IfWidthExceeds(t, shapeAt(rYY), shapeAt(rNY)));
			return WrapBoundary(Group(IfBreak(brk, shapeAt(rNN))));
		}

		// 2+ extra thresholds — full enumeration without impossibility
		// filtering. Renderer's column-aware probe at each
		// IfWidthExceeds layer picks the correct leaf at runtime.
		return WrapBoundary(buildBinaryThresholdTree(extraThresholds, [], null, evalAt, shapeAt));
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
		thresholds:Array<Int>, firing:Array<Int>,
		forcedExceeds:Null<Bool>,
		evalAt:(Bool, Array<Int>) -> {mode:WrapMode, location:WrappingLocation},
		shapeAt:{mode:WrapMode, location:WrappingLocation} -> Doc
	):Doc {
		if (thresholds.length == 0) {
			if (forcedExceeds != null) return shapeAt(evalAt(forcedExceeds, firing));
			final rFlat:{mode:WrapMode, location:WrappingLocation} = evalAt(false, firing);
			final rBrk:{mode:WrapMode, location:WrappingLocation} = evalAt(true, firing);
			if (sameRule(rFlat, rBrk)) return shapeAt(rFlat);
			return Group(IfBreak(shapeAt(rBrk), shapeAt(rFlat)));
		}
		final t:Int = thresholds[0];
		final rest:Array<Int> = thresholds.slice(1);
		final firingPlus:Array<Int> = firing.copy();
		firingPlus.push(t);
		final brk:Doc = buildBinaryThresholdTree(rest, firingPlus, forcedExceeds, evalAt, shapeAt);
		final flat:Doc = buildBinaryThresholdTree(rest, firing, forcedExceeds, evalAt, shapeAt);
		return IfWidthExceeds(t, brk, flat);
	}

	private static inline function sameRule(a:{mode:WrapMode, location:WrappingLocation}, b:{mode:WrapMode, location:WrappingLocation}):Bool {
		return a.mode == b.mode && a.location == b.location;
	}

	/**
	 * True for modes that lay the chain across multiple lines
	 * (`OnePerLine` / `OnePerLineAfterFirst` / `FillLine` /
	 * `FillLineWithLeadingBreak`). `NoWrap` / `Keep` / `Ignore` keep the
	 * chain inline. Used by the ω-chain-keep-flat unwrap pivot.
	 */
	private static inline function isBreakMode(m:WrapMode):Bool {
		return m == OnePerLine || m == OnePerLineAfterFirst
			|| m == FillLine || m == FillLineWithLeadingBreak;
	}

	/**
	 * True iff every operator is a binary chain operator (`&&` / `||` /
	 * `+` / `-`) — i.e. NOT a ternary (`?` / `:`). The ternary dispatch
	 * reuses this engine with a degenerate 3-item chain; the keep-flat
	 * unwrap must not fire there.
	 */
	private static function isChainOps(ops:Array<String>):Bool {
		for (o in ops) switch o {
			case '&&' | '||' | '+' | '-':
			case _: return false;
		}
		return ops.length > 0;
	}

	/**
	 * True iff every operator is an opAddSub chain operator (`+` / `-`) —
	 * i.e. NOT an opBool (`&&`/`||`) or a ternary (`?`/`:`). Drives the
	 * ω-unwrap-add-ops `CollapseAddProbe` marker: only a pure opAddSub
	 * chain's broken shape is wrapped, so `CollapsePass` collapses ONLY
	 * inner `+`/`-` chains (mirror fork `unwrapAddOps`, which strips ONLY
	 * `Binop(OpAdd)` / `Binop(OpSub)` line-ends, never `&&`/`||`).
	 */
	private static function isAddSubOps(ops:Array<String>):Bool {
		for (o in ops) switch o {
			case '+' | '-':
			case _: return false;
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
	private static function leadingOperandOpensDelim(item0:Doc):Bool {
		return switch item0 {
			case Text(s): s.length > 0 && (StringTools.fastCodeAt(s, 0) == '('.code
				|| StringTools.fastCodeAt(s, 0) == '['.code
				|| StringTools.fastCodeAt(s, 0) == '{'.code);
			case Concat(arr):
				var hit:Bool = false;
				var done:Bool = false;
				for (it in arr) if (!done) switch it {
					case Empty | Line(_) | OptSpace(_) | OptSpaceSkipAfterHardline
							| OptHardline | OptHardlineSkipAtOpenDelim | OptHardlineSkipBeforeHardline:
					case _:
						done = true;
						hit = leadingOperandOpensDelim(it);
				}
				hit;
			case Group(i) | BodyGroup(i) | GroupWithRestProbe(i) | Nest(_, i)
					| Flatten(i) | HardFlatten(i) | CollapseProbe(i) | CollapseAddProbe(i) | WrapBoundary(i)
					| ConditionalMarkerZero(i) | ConditionalMarkerDecrease(i):
				leadingOperandOpensDelim(i);
			case IfBreak(_, flat) | IfWidthExceeds(_, _, flat) | IfFirstLineExceeds(_, _, flat)
					| IfLineExceeds(_, _, flat) | IfFullLineExceeds(_, _, flat)
					| IfNaturalFirstLineExceeds(_, _, flat) | IfNaturalFirstLineFitsOpenDelim(_, _, flat):
				leadingOperandOpensDelim(flat);
			case _: false;
		};
	}

	private static function shape(mode:WrapMode, location:WrappingLocation, items:Array<Doc>, ops:Array<String>, cols:Int, ?sourceBreakBefore:Array<Bool>, headBreak:Bool = false):Doc {
		return switch mode {
			case NoWrap: shapeNoWrap(items, ops);
			case OnePerLine: shapeOnePerLine(items, ops, cols, location);
			case OnePerLineAfterFirst: shapeOnePerLineAfterFirst(items, ops, cols, location);
			case FillLine | FillLineWithLeadingBreak: shapeFillLine(items, ops, cols, location);
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
			case Keep: shapeKeep(items, ops, cols, location, sourceBreakBefore, headBreak);
			// ω-cascade-emits-comments: Ignore sister to Keep — the writer
			// pre-empts at the trivia branch. Defensive fallback to
			// shapeNoWrap on engine leakage.
			case Ignore: shapeNoWrap(items, ops);
			case _: shapeOnePerLineAfterFirst(items, ops, cols, location);
		};
	}

	private static function shapeNoWrap(items:Array<Doc>, ops:Array<String>):Doc {
		final inner:Array<Doc> = [items[0]];
		for (i in 0...ops.length) {
			inner.push(Text(' ' + ops[i] + ' '));
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
	private static function shapeKeep(items:Array<Doc>, ops:Array<String>, cols:Int, location:WrappingLocation, ?sourceBreakBefore:Array<Bool>, headBreak:Bool = false):Doc {
		final breaks:Array<Bool> = sourceBreakBefore ?? [];
		// First operand stays at the call-site column (unless `headBreak`);
		// only the continuation tail is nested at the chain's one-tab indent,
		// so a broken gap lands its line at `base + cols` while a glued gap
		// keeps the operands inline (mirror `shapeOnePerLineAfterFirst`).
		final tail:Array<Doc> = [];
		switch location {
			case BeforeLast:
				for (i in 0...ops.length) {
					if (i < breaks.length && breaks[i]) {
						tail.push(Line('\n'));
						tail.push(Text(ops[i] + ' '));
					} else {
						tail.push(Text(' ' + ops[i] + ' '));
					}
					tail.push(items[i + 1]);
				}
			case AfterLast:
				for (i in 0...ops.length) {
					if (i < breaks.length && breaks[i]) {
						tail.push(Text(' ' + ops[i]));
						tail.push(Line('\n'));
					} else {
						tail.push(Text(' ' + ops[i] + ' '));
					}
					tail.push(items[i + 1]);
				}
		}
		// `headBreak` puts the head operand on its own continuation line:
		// the whole chain (head + tail) is nested and led by a `Line('\n')`.
		if (headBreak)
			return Nest(cols, Concat([Line('\n'), items[0]].concat(tail)));
		return Concat([items[0], Nest(cols, Concat(tail))]);
	}

	private static function shapeOnePerLineAfterFirst(items:Array<Doc>, ops:Array<String>, cols:Int, location:WrappingLocation):Doc {
		// First operand stays at the call-site column; remaining operands
		// each on their own indented continuation line.
		//
		//  - `BeforeLast`: the op prefixes each continuation operand
		//    (`items[0]\n+indent op_i items[i+1]`). Matches haxe-formatter's
		//    default break shape for opBoolChain / opAddSubChain.
		//  - `AfterLast`: the op suffixes the previous line, the next
		//    operand starts the continuation line
		//    (`items[0] op_0\n+indent items[1] op_1\n+indent items[2]…`).
		final tail:Array<Doc> = [];
		switch location {
			case BeforeLast:
				for (i in 0...ops.length) {
					tail.push(Line('\n'));
					tail.push(Text(ops[i] + ' '));
					tail.push(items[i + 1]);
				}
				return Concat([items[0], Nest(cols, Concat(tail))]);
			case AfterLast:
				// op_0 suffixes items[0] (still on the first line); each
				// continuation line carries items[i] and, when there is
				// a next op, a trailing ` op_i`.
				final head:Array<Doc> = [items[0]];
				if (ops.length > 0) head.push(Text(' ' + ops[0]));
				for (i in 1...items.length) {
					tail.push(Line('\n'));
					tail.push(items[i]);
					if (i < ops.length) tail.push(Text(' ' + ops[i]));
				}
				return Concat([Concat(head), Nest(cols, Concat(tail))]);
		}
	}

	private static function shapeOnePerLine(items:Array<Doc>, ops:Array<String>, cols:Int, location:WrappingLocation):Doc {
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
		final inner:Array<Doc> = [OptHardlineSkipAtOpenDelim, items[0]];
		switch location {
			case AfterLast:
				for (i in 0...ops.length) {
					inner.push(Text(' ' + ops[i]));
					inner.push(Line('\n'));
					inner.push(items[i + 1]);
				}
			case BeforeLast:
				for (i in 0...ops.length) {
					inner.push(Line('\n'));
					inner.push(Text(ops[i] + ' '));
					inner.push(items[i + 1]);
				}
		}
		return Nest(cols, Concat(inner));
	}

	private static function shapeFillLine(items:Array<Doc>, ops:Array<String>, cols:Int, location:WrappingLocation):Doc {
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
		// `Fill(items, sep)` fits each item against the remaining
		// budget; wrapping in `Nest(cols)` gives the continuation lines
		// the chain's one-tab indent.
		final enriched:Array<Doc> = switch location {
			case BeforeLast:
				final acc:Array<Doc> = [items[0]];
				for (i in 0...ops.length) acc.push(Concat([Text(ops[i] + ' '), items[i + 1]]));
				acc;
			case AfterLast:
				final acc:Array<Doc> = [];
				for (i in 0...ops.length) acc.push(Concat([items[i], Text(' ' + ops[i])]));
				acc.push(items[items.length - 1]);
				acc;
		}
		return Group(Nest(cols, Fill(enriched, Line(' '))));
	}
}
