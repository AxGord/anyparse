package anyparse.format.wrap;

import anyparse.core.Doc;
import anyparse.core.DocMeasure;
import anyparse.format.IndentChar;
import anyparse.format.WriteOptions;

using StringTools;

/**
 * Runtime helper that emits a `Doc` for a method-chain construct
 * (`a.b().c().d()` — left-assoc nested `Call(FieldAccess(Call(...)))` /
 * `FieldAccess(Call(FieldAccess(...)))` AST) whose layout is driven by a
 * `WrapRules` cascade.
 *
 * Format-neutral — the AST walking happens in the macro-generated
 * writer (it knows the grammar's Call/FieldAccess constructors); this
 * engine accepts the pre-built `receiver:Doc` and `segments:Array<Doc>`
 * (each a `.field` or `.field(args)` shaped Doc) and runs the cascade
 * decision + chain shape selection.
 *
 * Differs from `WrapList.emit` in three ways:
 *  - chain has NO open/close/separator delimiters (segments include
 *    their own `.field` lead);
 *  - the receiver renders OUTSIDE the cascade-controlled break (it
 *    appears once, before the first segment);
 *  - chain shapes prepend `Line('\n')` between segments instead of a
 *    delimiter sequence.
 *
 * Mirrors fork `WrappingProcessor`'s chain shaping. Modes:
 *  - `NoWrap`           → `receiver seg0 seg1 …` (all inline)
 *  - `OnePerLineAfterFirst` → `receiver seg0 \n+indent seg1 \n+indent …`
 *  - `OnePerLine`       → `receiver \n+indent seg0 \n+indent seg1 …`
 *  - `FillLine`         → falls back to `OnePerLineAfterFirst` (chain
 *    contexts haven't surfaced a fill semantics yet; deferred to a
 *    later slice if a fixture demands it).
 *
 * ω-methodchain-all-or-nothing — the layout POLICY on top of those
 * shapes. Every shaper here returns the chain MINUS its receiver, and
 * `emit` re-attaches it as `Concat([receiver, <decision>])`, so the
 * renderer reaches the width probe with the pen at the column where the
 * head actually ENDED rather than at the chain's start measured flat. The
 * Haxe default cascade then breaks to `OnePerLine`, never to
 * `OnePerLineAfterFirst`. Together those two make the chain one unit: the
 * whole tail fits after the head → one line, even when the head rendered
 * multi-line; it does not → every link on its own continuation line and a
 * head line that carries no glued link (so a glued link can no longer push
 * the head past `maxLineLength`). `OnePerLineAfterFirst` survives as an
 * explicitly configurable mode (`methodChain.defaultWrap`); it is just no
 * longer a default.
 *
 * "Every link" is fork's `MarkWrapping.isDotAfterPClose` reading: a `.` is a
 * chain ITEM only when it follows a `)`. A head that is not a call therefore
 * keeps its first segment — `Actuate.tween(…)` stays whole rather than
 * stranding the two-token `Actuate` on a line of its own, which reads heavier
 * than the glued head the policy set out to fix. `headEndsWithCall` carries
 * that structural fact from the macro walk (the innermost segment's operand IS
 * a Call ctor), never from the receiver's rendered text; and the downgrade to
 * `OnePerLineAfterFirst` applies ONLY to a cascade that opted in via
 * `WrapRules.chainItemsAfterCloseParenOnly` — the Haxe policy cascade, or a
 * `wrapping.methodChain` section that names `itemsAfterCloseParenOnly` — so an
 * explicitly configured `onePerLine` that stays silent about the key keeps the
 * fork's literal every-segment semantic (five fork corpus fixtures depend on
 * that).
 */
class MethodChainEmit {

	public static function emit(
		receiver: Doc, segments: Array<Doc>, opt: WriteOptions, rules: WrapRules, ?sourceBreakBefore: Array<Bool>,
		nestSuppress: Bool = false, segCallLeadingBreak: Bool = false, headEndsWithCall: Bool = true
	): Doc {
		if (segments.length == 0) return WrapBoundary(receiver);

		// ω-chain-comment-forced-break: a method-chain segment (or the
		// receiver) whose rendered Doc ENDS with a line comment cannot be
		// followed by the next `.field` on the same physical line — the
		// comment would swallow it. `commentForcedBreak` is parallel to
		// `segments`: entry `i` is true when the thing rendered immediately
		// before segment `i` (receiver for i=0, else segment i-1) ends with
		// a line comment. The signal is read structurally from the already-
		// built Docs (`WrapList.endsWithLineComment` — the ONE veto every
		// glue-seam shaper asks; this module carried a second walker for the
		// same question until it was found to disagree), so every receiver
		// shape (bare ident with a glued `// …`, `new T()` with its own
		// trailing slot, a call receiver) is covered uniformly. When any
		// entry fires we
		// route every cascade-decided shape through `shapeKeepTail` with a mask
		// = `commentForcedBreak[i] OR (the cascade mode breaks at i)`, so
		// the chain breaks at comment boundaries while preserving the
		// cascade's width-driven breaks (the wide chains still break
		// everywhere via `IfFullLineExceeds`). When nothing fires (the
		// non-comment hot path) `shapeAt` uses the original `shape(mode, …)`
		// exactly as before → byte-inert.
		final commentForcedBreak: Array<Bool> = [
			for (i in 0...segments.length)
				WrapList.endsWithLineComment(i == 0 ? receiver : segments[i - 1])
		];
		final hasCommentBreak: Bool = commentForcedBreak.indexOf(true) != -1;

		// Token-text width metric: chain segment length is the segment's
		// rendered width with `BodyGroup` content deferred (mirrors
		// `Renderer.fitsFlat`'s BG-defer in Departure 2 — block / lambda /
		// struct-lit bodies decide their own break/flat at render time and
		// must NOT contribute to the parent chain's static `total`/`maxLen`
		// measurement). Internal `Line('\n')` / `OptHardline` outside
		// `BodyGroup` count as zero contribution (token-width semantics
		// keep a 2-segment chain whose only "size" is internal break-mode
		// layout flat per fork's `itemCount<=3 + !exceeds → NoWrap`
		// default rule). Cascade rules `TotalItemLengthLargerThan` /
		// `AnyItemLengthLargerThan` then see chain widths consistent
		// with the renderer's flat-fit decision (ω-chain-itemlen-bg-defer).
		final measure: WrapItemMeasure = measureSegments(segments);
		final total: Int = measure.total;
		final maxLen: Int = measure.maxLen;

		final cols: Int = opt.indentChar == IndentChar.Space ? opt.indentSize : opt.tabWidth;

		// Column-aware `LineLengthLargerThan` thresholds — mirror
		// `WrapList.emit` / `BinaryChainEmit.emit` threshold-aware
		// enumeration pattern (slice ω-ifwidthexceeds-infra +
		// ω-methodchain-threshold-aware). Cascade rules with
		// `lineLength >= n` where `n != opt.lineWidth` cannot be answered
		// at emit time because the rendered column position is unknown
		// until layout. Threshold == lineWidth collapses cleanly to
		// `exceeds` (the existing `IfBreak` pivot) and stays on the
		// 2-state path. Non-lineWidth thresholds enumerate extra states
		// and emit one `IfWidthExceeds(t, …)` wrapper per distinct
		// threshold so the renderer probes `column + flatWidth(flat)`
		// against `t` at layout time.
		final extraThresholds: Array<Int> = WrapList.collectExtraLineLengthThresholds(rules, opt.lineWidth);

		// Cascade-eval helper: caller specifies the (exceeds, firing) state
		// and gets the cascade's resolved mode. `LineLengthLargerThan` is
		// mapped to:
		//   - `t == lineWidth` → use `exceeds` (collapse semantic)
		//   - `t != lineWidth` → membership in `firing`
		// `hasMultilineItems` is `false` — chain segments don't track
		// internal hardlines for cascade purposes (BG-deferred bodies
		// decide their own layout; bare `Line('\n')` inside a segment is
		// not expected outside BG). `MethodChainEmit` does NOT have an
		// `anyHardline` force-break path mirroring `BinaryChainEmit`'s —
		// adding one is a separate slice if a fixture demands it.
		// Non-`inline` so it can be passed as a closure into
		// `buildChainThresholdTree` (Haxe forbids closure-on-inline-closure).
		function evalAt(exceeds: Bool, firing: Array<Int>): WrapMode {
			return WrapList.decideWithLineLengthState(
				rules, segments.length, maxLen, total, exceeds, false, t -> t == opt.lineWidth ? exceeds : firing.contains(t), 0,
				measure.minLen, measure.equalLens
			);
		}

		function shapeAt(mode: WrapMode): Doc {
			// `Keep` mode already reproduces the source per-segment layout
			// (incl. the comment-bearing dot breaks) via `sourceBreakBefore`,
			// so leave it untouched — the comment-forced mask is only needed
			// for the NON-keep cascade modes that would otherwise glue a
			// `.field` onto a line comment.
			// ω-methodchain-all-or-nothing / isDotAfterPClose: the policy breaks
			// EVERY chain item onto its own line, and a `.` is a chain item only
			// when it follows a `)` (fork `MarkWrapping.isDotAfterPClose`). For a
			// head that is not a call — a bare ident (`Actuate`), a field path, an
			// array access — the dot before segment 0 is not a chain boundary at
			// all, so that segment belongs to the HEAD and stays glued to it. The
			// break shape for such a chain is exactly `OnePerLineAfterFirst`.
			// Without this the policy strands a two-token receiver alone on a line
			// (`Actuate` above `.tween(…)`), which is heavier reading than the
			// glued head the policy set out to fix.
			final policyItems: Bool = rules.chainItemsAfterCloseParenOnly == true;
			final effective: WrapMode = mode == OnePerLine && policyItems && !headEndsWithCall && segments.length >= 2
				? OnePerLineAfterFirst
				: mode;
			return hasCommentBreak && effective != Keep
				? shapeKeepTail(segments, cols, commentBreakMask(effective, segments.length, commentForcedBreak))
				: shapeTail(effective, receiver, segments, cols, opt.lineWidth, opt.methodChainCuddledLinks, sourceBreakBefore);
		}

		// Normal path: cascade evaluated against (exceeds=false /
		// exceeds=true) AND each non-lineWidth threshold's firing state.
		// Tree construction mirrors `WrapList.emit`'s 0/1/N branches —
		// the impossibility-pruning at N=1 keeps the renderer's tree
		// minimal (one impossible state filtered out per `t < lineWidth`
		// or `t > lineWidth` case).
		final tail: Doc = switch extraThresholds.length {
			case 0:
				emitNoThreshold(opt, segments, nestSuppress, segCallLeadingBreak, evalAt, shapeAt);
			case 1:
				emitSingleThreshold(extraThresholds[0], opt, segments, nestSuppress, segCallLeadingBreak, evalAt, shapeAt);
			case _:
				buildChainThresholdTree(extraThresholds, [], evalAt, shapeAt, opt.lineWidth);
		}
		// ω-methodchain-all-or-nothing: the receiver is emitted OUTSIDE the
		// width decision, so the renderer reaches the probe with the pen at the
		// column where the head actually ENDED — its last physical line, not
		// its flat width. The probe then measures exactly the segment tail plus
		// whatever trails it on that line, which is the question the policy
		// asks ("does the whole tail fit after the head?"). Pre-slice the probe
		// wrapped the receiver too and measured it FLAT, so a chain riding a
		// multi-line call's `)` read as 180+ columns and dot-broke although its
		// tail had a whole line free.
		return WrapBoundary(Concat([receiver, tail]));
	}

	/**
	 * ω-methodchain-all-or-nothing — the GLUED tail: every segment on the
	 * head's own line. Kept as a named shaper (rather than an inline
	 * `Concat(segments)`) because `CollapsePass.rewriteChainProbe` destructures
	 * this exact `Concat` to re-measure a re-glued chain's first line.
	 */
	private static inline function shapeNoWrapTail(segments: Array<Doc>): Doc {
		return Concat(segments);
	}

	/**
	 * ω-methodchain-cuddled-links — may a chain link start on `doc`'s last
	 * rendered line? Yes exactly when that line is a dedented CLOSING line: a
	 * forced hardline followed only by close delimiters and whitespace, which
	 * `DocMeasure.endsWithForcedCloseLine` answers structurally (never by width,
	 * so no render-time measurement can change a chain's shape) — read its doc
	 * for what does and does not force such a hardline, including the
	 * input-layout sensitivity of an object-literal tail.
	 *
	 * The closes-only half of that predicate is load-bearing here beyond mere
	 * shape: it pins the ride-along point to a low column (base indent plus two
	 * or three characters), so a cuddled `.method(` head cannot blow the line by
	 * itself.
	 */
	private static inline function endsWithMultilineClose(doc: Doc): Bool {
		return DocMeasure.endsWithForcedCloseLine(doc);
	}

	private static inline function isTextAtom(d: Doc): Bool {
		return switch d {
			case Text(_): true;
			case _: false;
		};
	}

	/**
	 * Recursive helper that builds the `IfWidthExceeds + IfFullLineExceeds`
	 * tree for chain-emit's cascade-with-thresholds layout. Sister of
	 * `WrapList.buildThresholdTree` and `BinaryChainEmit.buildBinaryThresholdTree`
	 * but emits chain shapes (`shape(mode, …)`) at each leaf — no
	 * `location` axis (chain segments don't have op placement).
	 *
	 * `firing` accumulates thresholds chosen as "fired" along the
	 * brk-side recursion. Each leaf splits via `IfFullLineExceeds(lineWidth, …)`
	 * (asymmetric BG-descend on rest-of-stack only) when the resolved
	 * modes differ — mirrors the top-level chain-emit collapse. No
	 * impossibility filtering at N≥2 — renderer's column probe at each
	 * `IfWidthExceeds` layer is monotone, so the impossible-state leaves
	 * are unreachable at runtime regardless.
	 */
	private static function buildChainThresholdTree(
		thresholds: Array<Int>, firing: Array<Int>, evalAt: (Bool, Array<Int>) -> WrapMode, shapeAt: WrapMode -> Doc, lineWidth: Int
	): Doc {
		if (thresholds.length == 0) {
			final modeFlat: WrapMode = evalAt(false, firing);
			final modeBreak: WrapMode = evalAt(true, firing);
			return modeFlat == modeBreak ? shapeAt(modeFlat) : IfFullLineExceeds(lineWidth, shapeAt(modeBreak), shapeAt(modeFlat));
		}
		final t: Int = thresholds[0];
		final rest: Array<Int> = thresholds.slice(1);
		final firingPlus: Array<Int> = firing.copy();
		firingPlus.push(t);
		final brk: Doc = buildChainThresholdTree(rest, firingPlus, evalAt, shapeAt, lineWidth);
		final flat: Doc = buildChainThresholdTree(rest, firing, evalAt, shapeAt, lineWidth);
		return IfWidthExceeds(t, brk, flat);
	}

	/**
	 * ω-methodchain-all-or-nothing — the chain layout MINUS the receiver. The
	 * receiver is emitted by `emit` before the width decision, so every shaper
	 * here returns only what follows it; `emit` re-attaches it once via
	 * `Concat([receiver, tail])`. The receiver is still a PARAMETER because two
	 * shapers read it structurally (the `OnePerLine` cuddle asks whether the
	 * receiver's last line is a dedented closer, the `OnePerLineAfterFirst` one
	 * asks the same of `receiver + seg0`), never to place it.
	 */
	private static function shapeTail(
		mode: WrapMode, receiver: Doc, segments: Array<Doc>, cols: Int, lineWidth: Int, cuddledLinks: Bool, ?sourceBreakBefore: Array<Bool>
	): Doc {
		return switch mode {
			case NoWrap: shapeNoWrapTail(segments);
			case OnePerLine: shapeOnePerLine(receiver, segments, cols, lineWidth, cuddledLinks);
			case OnePerLineAfterFirst:
				shapeOnePerLineAfterFirst(receiver, segments, cols, lineWidth, cuddledLinks);
			// ω-keep-chain (increment 9): JSON `"defaultWrap": "keep"` on
			// method-chain configs (`methodChain.defaultWrap = "keep"`)
			// reproduces the source's per-segment dot-boundary line breaks
			// verbatim — break before segment `i` iff the parser captured a
			// source newline in that `.field`'s leading gap
			// (`sourceBreakBefore[i]`), else glue the segment inline. The
			// signal is the per-FieldAccess-ctor `chainNewline` synth slot
			// captured at parse time in `lowerPostfixLoop` (mirror of the
			// Pratt-operand `captureChainNewline` channel and fork's
			// `markMethodChaining` + per-Dot `isOriginalNewlineBefore`). When
			// the signal is absent (null — plain mode / non-capturing ctor)
			// `shapeKeepTail` degrades to `shapeNoWrapTail` → byte-inert.
			case Keep:
				shapeKeepTail(segments, cols, sourceBreakBefore);
			// ω-cascade-emits-comments: Ignore sister to Keep — defensive
			// fallback on engine leakage.
			case Ignore:
				shapeNoWrapTail(segments);
			// FillLine and FillLineWithLeadingBreak don't have a chain-
			// specific semantics in fork's `WrappingProcessor` either.
			// Fall back to OnePerLineAfterFirst (the most common chain
			// break shape) — a future slice can split if a fixture
			// demands it.
			case _: shapeOnePerLineAfterFirst(receiver, segments, cols, lineWidth, cuddledLinks);
		};
	}

	/**
	 * The chain's per-segment measurements, in the shape the cascade tests
	 * against. Segment width is the segment's rendered width with `BodyGroup`
	 * content deferred (mirrors `Renderer.fitsFlat`'s BG-defer) and carries no
	 * separator adjustment — a method chain has no separator, only the `.` that
	 * each segment already begins with, so unlike a delimited list every segment
	 * measures the same way and `equalLens` needs no last-item allowance.
	 *
	 * `anyHardline` is reported as `false`: this emitter has no force-break path
	 * mirroring `BinaryChainEmit`'s, and its callers pass `hasMultilineItems =
	 * false` to the cascade deliberately (see `emit`'s own note). The field is
	 * present because `WrapItemMeasure` is one shape for all three emitters, not
	 * because it is measured here.
	 */
	private static function measureSegments(segments: Array<Doc>): WrapItemMeasure {
		var total: Int = 0;
		var maxLen: Int = 0;
		var minLen: Int = WrapList.MAX_ITEM_LEN;
		var equalLens: Bool = true;
		var firstLen: Int = -1;
		for (seg in segments) {
			final len: Int = DocMeasure.flatTokenWidth(seg);
			total += len;
			if (len > maxLen) maxLen = len;
			if (len < minLen) minLen = len;
			if (firstLen < 0)
				firstLen = len;
			else if (len != firstLen)
				equalLens = false;
		}
		return {
			total: total,
			maxLen: maxLen,
			minLen: minLen,
			equalLens: equalLens,
			anyHardline: false
		};
	}

	/**
	 * ω-chain-comment-forced-break — build the `shapeKeepTail` break mask for a
	 * comment-bearing chain under a cascade-decided `mode`. Each entry is
	 * `commentForced[i] OR modeBreaksAt(i)` so the chain breaks at every
	 * line-comment boundary AND wherever the width-driven cascade mode
	 * would have broken:
	 *  - `NoWrap`               → breaks nowhere (mask = comment only);
	 *  - `OnePerLine`           → breaks before every segment incl. seg0;
	 *  - everything else        → breaks before segments 1…n (the
	 *    `OnePerLineAfterFirst` / Fill family — seg0 glued to receiver
	 *    unless a comment forces it).
	 */
	private static function commentBreakMask(mode: WrapMode, count: Int, commentForced: Array<Bool>): Array<Bool> {
		return [
			for (i in 0...count) {
				final forced: Bool = i < commentForced.length && commentForced[i];
				final modeBreaks: Bool = switch mode {
					case NoWrap: false;
					case OnePerLine: true;
					case _: i >= 1;
				};
				forced || modeBreaks;
			}
		];
	}

	/**
	 * ω-methodchain-reeval-after-callparam (CollapsePass increment 3, subroot-E):
	 * wrap a chain's `IfFullLineExceeds(width, breakShape, glueShape)` in a
	 * `CollapseChainProbe` so `CollapsePass.rewriteChainProbe` can STRIP the
	 * chain dot-break (re-glue) when the chain dot-broke ONLY because a segment's
	 * call args wrapped — fork `reEvaluateMethodChainAfterCallParam` (strip
	 * method-chain breaks, keep callParameter breaks). Gate: the width-driven
	 * BREAK mode is a dot-break (`OnePerLine*`) over a glued `NoWrap` flat mode,
	 * the chain is NOT itself a call argument (`!nestSuppress` — fork never
	 * strips chain breaks for a chain inside a breaking outer call, e.g.
	 * `method_chain_single_arg_break_parens`), and the glued last segment is a
	 * breakable call (`reGluableChain`). Every non-matching chain stays the bare
	 * `IfFullLineExceeds` (byte-inert).
	 *
	 * `segCallLeadingBreak` is the load-bearing discriminator vs fork's
	 * `isNewLineAfter(POpen)`: the segment call's args must wrap with a LEADING
	 * BREAK (first arg on its own line — `callParameterWrap.defaultMode == FLWLB`),
	 * NOT a glued first arg (`FillLine` default) or a glued arrow/lambda whose
	 * BODY breaks (`.map(x -> {…})`). Without this gate the re-glue over-fires on
	 * chains fork keeps dot-broken (`arrow_wrapping_method_chain`,
	 * `issue_311_line_break_before_popen`, `issue_180_middle_of_function_call`,
	 * `issue_231_anon_function_parameter`) whose segment call glues its first
	 * arg / arrow param to the open paren.
	 */
	private static function maybeTagReglue(
		ifFLE: Doc, breakMode: WrapMode, flatMode: WrapMode, segments: Array<Doc>, nestSuppress: Bool, segCallLeadingBreak: Bool
	): Doc {
		final reGluable: Bool = !nestSuppress && segCallLeadingBreak && isDotBreak(breakMode) && flatMode == NoWrap
			&& reGluableChain(segments);
		return reGluable ? CollapseChainProbe(ifFLE) : ifFLE;
	}

	/**
	 * ω-methodchain-reeval-after-callparam — is `mode` a dot-break chain shape
	 * (`OnePerLine` / `OnePerLineAfterFirst`)? The re-glue flip only tags a
	 * chain whose width-driven BREAK shape actually splits at a Dot; a chain
	 * whose break shape is itself `NoWrap` / `Keep` has no dot-break to strip.
	 */
	private static function isDotBreak(mode: WrapMode): Bool {
		return switch mode {
			case OnePerLine, OnePerLineAfterFirst: true;
			case _: false;
		};
	}

	/**
	 * ω-methodchain-reeval-after-callparam — is this chain a re-glue candidate?
	 * The glued (`NoWrap`) layout's overflow must come from a SEGMENT'S call
	 * args (which can break independently), not from the receiver / a non-call
	 * segment. Mirror fork `reEvaluateMethodChainAfterCallParam`'s precondition
	 * `hasCallParamBreaksInChain` (a `POpen` with `isNewLineAfter`): the last
	 * segment must be a call (`.field(args)`) whose args can wrap. The
	 * `CollapsePass` re-measure then confirms the glued first line (up to that
	 * call's open delim) fits at the captured column before stripping the break.
	 * Conservative: requires the LAST segment to be the breakable call (the #3
	 * `manager.getInstance().add(<args>)` shape); a chain whose breakable call
	 * is mid-chain keeps its dot-break (out of scope, byte-inert).
	 */
	private static function reGluableChain(segments: Array<Doc>): Bool {
		return segments.length != 0 && segmentOpensCall(segments[segments.length - 1]);
	}

	/**
	 * True iff the chain segment `seg` is a call `.field(args)` whose flat text
	 * contains an open delimiter (`(`/`[`/`{`) after the leading `.field` — i.e.
	 * a breakable call whose args can wrap onto their own lines. A bare
	 * `.field` access (no call) has no breakable args.
	 */
	private static function segmentOpensCall(seg: Doc): Bool {
		final flat: String = DocMeasure.flatText(seg);
		for (i in 0...flat.length) {
			final c: Int = flat.fastCodeAt(i);
			if (c == '('.code || c == '['.code || c == '{'.code) return true;
		}
		return false;
	}

	private static function shapeOnePerLineAfterFirst(
		receiver: Doc, segments: Array<Doc>, cols: Int, lineWidth: Int, cuddledLinks: Bool
	): Doc {
		// `seg0` glued to the already-emitted receiver; remaining segments each
		// on their own indented line. An empty `segments` cannot reach here —
		// `emit` returns at its own `segments.length == 0` guard before any
		// shaper runs, and that guard dominates every call path into this one.
		//
		// ω-methodchain-all-or-nothing widened the macro gate to one-segment
		// chains, which this mode has no break for: its only gap is the one
		// glued by construction. Degrade to the glued tail rather than emit an
		// empty `Nest` run. Consequence worth stating: under an EXPLICIT
		// `methodChain.defaultWrap: onePerLineAfterFirst` a one-link chain's
		// two `IfFullLineExceeds` branches become byte-identical, so it can
		// never break — the widened gate buys the over-wide-head fix only in
		// combination with the `OnePerLine` default cascade, never on its own.
		if (segments.length == 1) return shapeNoWrapTail(segments);
		final segs: Array<Doc> = restAwareCallParamSegments(segments, lineWidth);
		// ω-methodchain-cuddled-links: gap `i` (the boundary before
		// `segs[i]`) cuddles when the doc rendered immediately before it
		// ends in a forced hardline whose whole tail is close delimiters —
		// `Concat([receiver, segs[0]])` for the first gap, `segs[i-1]`
		// after. `false` everywhere (knob off, or nothing structurally
		// multi-line) takes the pre-knob construction below verbatim.
		final cuddle: Array<Bool> = cuddledLinks ? [
			for (i in 1...segs.length)
				endsWithMultilineClose(i == 1 ? Concat([receiver, segs[0]]) : segs[i - 1])
		] : [];
		if (cuddle.indexOf(true) != -1) return Concat(cuddledRuns([segs[0]], segs, 1, cuddle, cols));
		final tail: Array<Doc> = [];
		for (i in 1...segs.length) {
			tail.push(Line('\n'));
			tail.push(segs[i]);
		}
		return Concat([segs[0], Nest(cols, Concat(tail))]);
	}

	/**
	 * ω-methodchain-cuddled-links — assemble a dot-broken chain's segment tail
	 * as RUNS of segments that share one nest depth.
	 *
	 * `lead` is the already-placed prefix that stays at the statement's base
	 * indent (`[segs[0]]` for `OnePerLineAfterFirst`, EMPTY for `OnePerLine` —
	 * ω-methodchain-all-or-nothing moved the receiver out of every shaper, so
	 * the lead now holds only what the shape glues to it); `first` is the index
	 * of the first segment the tail places; `cuddle[k]` answers the gap before
	 * `segs[first + k]`.
	 *
	 * A cuddled segment is appended BARE to the run it rides on, so it renders
	 * on the previous segment's closing-delimiter line and — crucially — at
	 * the SAME nest depth, since `Nest` is cumulative against the frame indent
	 * (`Renderer.pushStructural`: `nextIndent = f.mode == MBreak ? f.indent + n
	 * : f.indent`). Appending it to a fresh `Nest` instead would push its
	 * lambda/object body one level deeper per link, which is exactly the
	 * layout this slice removes. A BREAK gap opens a new
	 * `Nest(cols, Concat([Line('\n'), …]))` run at one indent below base, and
	 * every segment cuddled onto a broken segment lands inside that same
	 * `Nest`.
	 */
	private static function cuddledRuns(lead: Array<Doc>, segs: Array<Doc>, first: Int, cuddle: Array<Bool>, cols: Int): Array<Doc> {
		final out: Array<Doc> = lead.copy();
		var run: Null<Array<Doc>> = null;
		for (i in first ... segs.length) {
			if (cuddle[i - first]) {
				if (run == null)
					out.push(segs[i]);
				else
					run.push(segs[i]);
				continue;
			}
			if (run != null) out.push(Nest(cols, Concat(run)));
			run = [Line('\n'), segs[i]];
		}
		if (run != null) out.push(Nest(cols, Concat(run)));
		return out;
	}

	/**
	 * `WrapMode.Keep` shaper — reproduces the source's per-segment dot-
	 * boundary line breaks. `sourceBreakBefore` is parallel to `segments`:
	 * entry `i` is true when the parser captured a source newline in the
	 * gap before segment `i`'s `.field` lead. When true the segment breaks
	 * onto its own line at the chain's one-tab `Nest(cols)` indent; when
	 * false the segment glues inline onto the running line (mirror fork's
	 * `markMethodChaining` keep semantics — break at a Dot iff that Dot was
	 * `isOriginalNewlineBefore`).
	 *
	 * The receiver and the leading run of glued segments stay at the call-
	 * site column; only broken segments (and any further segments after
	 * them) land at `base + cols`. The whole segment tail is nested so a
	 * broken gap's continuation line indents one tab deeper, while glued
	 * gaps keep the segments on the same rendered line (mirror
	 * `shapeOnePerLineAfterFirst`'s `Nest` placement).
	 *
	 * When `sourceBreakBefore` is null (plain mode / non-capturing ctor) or
	 * every entry is false, the output is byte-identical to `shapeNoWrapTail` —
	 * inert for the non-keep method-chain hot path.
	 */
	private static function shapeKeepTail(segments: Array<Doc>, cols: Int, ?sourceBreakBefore: Array<Bool>): Doc {
		final breaks: Array<Bool> = sourceBreakBefore ?? [];
		final tail: Array<Doc> = [];
		for (i in 0...segments.length) {
			if (i < breaks.length && breaks[i]) tail.push(Line('\n'));
			tail.push(segments[i]);
		}
		return Concat([Nest(cols, Concat(tail))]);
	}

	private static function shapeOnePerLine(receiver: Doc, segments: Array<Doc>, cols: Int, lineWidth: Int, cuddledLinks: Bool): Doc {
		// ALL segments on their own indented lines (including the first).
		// Mirrors fork's `WrappingType.onePerLine` shape for chain origin —
		// the already-emitted receiver stays at the call-site column and the
		// chain breaks below it at one indent level deeper. This is the
		// ω-methodchain-all-or-nothing break shape: the head line carries no
		// glued link.
		final segs: Array<Doc> = restAwareCallParamSegments(segments, lineWidth);
		// ω-methodchain-cuddled-links: gap `i` is the boundary before
		// `segs[i]`, so its predecessor is the receiver at `i == 0` and
		// `segs[i-1]` after. No cuddling gap keeps the pre-knob shape below.
		final cuddle: Array<Bool> = cuddledLinks ? [
			for (i in 0...segs.length)
				endsWithMultilineClose(i == 0 ? receiver : segs[i - 1])
		] : [];
		if (cuddle.indexOf(true) != -1) return Concat(cuddledRuns([], segs, 0, cuddle, cols));
		final tail: Array<Doc> = [];
		for (s in segs) {
			tail.push(Line('\n'));
			tail.push(s);
		}
		// Single-element `Concat` (rather than a bare `Nest`) so
		// `CollapsePass.topLevelNestCols` and `WrapList.isOPLShape` keep
		// reading this shape through their `Concat`-child scans.
		return Concat([Nest(cols, Concat(tail))]);
	}

	/**
	 * Build the chain Doc for the single-extra-threshold case (`extraThresholds
	 * == [t]`). The renderer's column-aware `IfWidthExceeds(t, …)` probe selects
	 * between the impossibility-filtered 3-state leaves. Split out of `emit` for
	 * the complexity threshold; `evalAt` / `shapeAt` are the same closures `emit`
	 * builds, `segments` / `nestSuppress` / `segCallLeadingBreak` feed the
	 * re-glue tag.
	 */
	private static function emitSingleThreshold(
		t: Int, opt: WriteOptions, segments: Array<Doc>, nestSuppress: Bool, segCallLeadingBreak: Bool,
		evalAt: (Bool, Array<Int>) -> WrapMode, shapeAt: (WrapMode) -> Doc
	): Doc {
		if (t < opt.lineWidth) {
			// 3 valid states (col+w<t implies col+w<lineWidth implies !exceeds):
			//   (firing=∅,    exceeds=no)  → modeNN
			//   (firing={t},  exceeds=no)  → modeYN
			//   (firing={t},  exceeds=yes) → modeYY
			final modeNN: WrapMode = evalAt(false, []);
			final modeYN: WrapMode = evalAt(false, [t]);
			final modeYY: WrapMode = evalAt(true, [t]);
			if (modeNN == modeYN && modeYN == modeYY) return shapeAt(modeNN);
			final brk: Doc = modeYY == modeYN ? shapeAt(modeYY) : IfFullLineExceeds(opt.lineWidth, shapeAt(modeYY), shapeAt(modeYN));
			return Group(IfWidthExceeds(t, brk, shapeAt(modeNN)));
		}
		// t > lineWidth: 3 valid states (col+w>=t implies col+w>=lineWidth):
		//   (firing=∅,    exceeds=no)  → modeNN
		//   (firing=∅,    exceeds=yes) → modeNY
		//   (firing={t},  exceeds=yes) → modeYY
		final modeNN: WrapMode = evalAt(false, []);
		final modeNY: WrapMode = evalAt(true, []);
		final modeYY: WrapMode = evalAt(true, [t]);
		if (modeNN == modeNY && modeNY == modeYY) return shapeAt(modeNN);
		final brk: Doc = modeNY == modeYY ? shapeAt(modeYY) : Group(IfWidthExceeds(t, shapeAt(modeYY), shapeAt(modeNY)));
		final ifFLE: Doc = IfFullLineExceeds(opt.lineWidth, brk, shapeAt(modeNN));
		// ω-methodchain-reeval-after-callparam: re-glue tag also for the
		// `t > lineWidth` extra-threshold case (the default cascade's
		// `LineLengthLargerThan 160` against a maxLineLength < 160 — the #3
		// `manager.getInstance().add(<wrapping-args>)` shape). The break side
		// is a single dot-break only when `modeNY == modeYY` (no inner
		// `IfWidthExceeds` split); tag using that break mode.
		return modeNY == modeYY ? maybeTagReglue(ifFLE, modeNY, modeNN, segments, nestSuppress, segCallLeadingBreak) : ifFLE;
	}

	/**
	 * The zero-extra-threshold leaf of chain-emit's cascade: only the
	 * lineWidth axis is live, so the layout is decided by evaluating the
	 * cascade at (exceeds=false) and (exceeds=true). Sister of
	 * `emitSingleThreshold` (one extra threshold) and
	 * `buildChainThresholdTree` (two or more).
	 */
	private static function emitNoThreshold(
		opt: WriteOptions, segments: Array<Doc>, nestSuppress: Bool, segCallLeadingBreak: Bool, evalAt: (Bool, Array<Int>) -> WrapMode,
		shapeAt: (WrapMode) -> Doc
	): Doc {
		final modeFlat: WrapMode = evalAt(false, []);
		final modeBreak: WrapMode = evalAt(true, []);
		if (modeFlat == modeBreak) return shapeAt(modeFlat);
		// `IfFullLineExceeds` over `Group(IfBreak(…))`: chain's own
		// `Group` measures only its own subtree; trailing tokens on
		// the same rendered line (e.g. ` BODY` after the for-cond
		// close-paren on `condition_wrapping_method_chain`, where
		// `BODY` lives inside a sibling `BodyGroup` from
		// `forBody=fitLine`) vanish from the fit decision. The
		// asymmetric BG semantic: own-subtree DEFERS BG (chain-of-
		// lambdas like `xs.map(λ).filter(λ)` don't inflate the
		// probe), rest-of-stack DESCENDS BG (sibling body after
		// chain IS visible). Slice ω-iffulllineexceeds-primitive.
		final ifFLE: Doc = IfFullLineExceeds(opt.lineWidth, shapeAt(modeBreak), shapeAt(modeFlat));
		return maybeTagReglue(ifFLE, modeBreak, modeFlat, segments, nestSuppress, segCallLeadingBreak);
	}

	/**
	 * ω-methodchain-callparam-restaware: within a DOT-BROKEN chain shape, a
	 * segment's callParameter wrap (a cascade-disagree `Group(IfBreak(brk, flat))`
	 * whose break branch LEADING-BREAKS the argument onto its own line) picks
	 * flat-vs-break via the renderer's LOCAL `fitsFlat` — blind to the trailing
	 * tokens (`;` / `: null` / `,`) that share the segment's physical line. The
	 * fork's `exceedsMaxLineLength` measures the WHOLE physical line, so it
	 * leading-breaks a segment that fits on its own but overflows once the
	 * trailing content is counted (probe: `.concat(arg)` at 5 tabs = 137 stays
	 * glued, at 6 tabs = 141 leading-breaks — the only delta is the trailing
	 * `;`). Swap the segment's `Group(IfBreak(brk, flat))` for a rest-of-stack-
	 * aware `IfLineExceeds(lineWidth, brk, flat)` (the rest walker aborts at the
	 * next chain-internal hardline, so a mid-chain segment sees only its own
	 * line while the last segment additionally sees the trailing terminator).
	 * Only leading-break callParameter groups are rewritten — arrow-body close-
	 * paren couplings (break keeps the argument glued) and non-`Group` wraps
	 * (`IfFirstLineExceeds`) keep their existing local decision.
	 */
	private static function restAwareCallParamSegments(segments: Array<Doc>, lineWidth: Int): Array<Doc> {
		return [for (seg in segments) restAwareCallParamSegment(seg, lineWidth)];
	}

	/**
	 * Rewrite a single chain segment: find its outermost callParameter args
	 * wrap and, when it is a leading-break `Group(IfBreak(brk, flat))`, swap it
	 * for a rest-aware `IfLineExceeds`. A segment carries at most one such wrap,
	 * so the first match wins; a non-call / non-matching segment is returned
	 * unchanged.
	 */
	private static function restAwareCallParamSegment(seg: Doc, lineWidth: Int): Doc {
		return switch seg {
			case Concat(items):
				final copy: Array<Doc> = items.copy();
				var changed: Bool = false;
				for (i in 0...copy.length) if (!changed) {
					final swapped: Null<Doc> = restAwareArgsWrap(copy[i], lineWidth);
					if (swapped != null) {
						copy[i] = swapped;
						changed = true;
					}
				}
				changed ? Concat(copy) : seg;
			case _: seg;
		};
	}

	/**
	 * Return the rest-aware replacement for a callParameter args wrap, or `null`
	 * when `argsDoc` is not a leading-break `Group(IfBreak(...))` (possibly under
	 * a render-transparent `WrapBoundary`). The `brk` / `flat` branches are NOT
	 * descended — the argument's own inner wrapping (nested chains, lambdas)
	 * stays intact.
	 */
	private static function restAwareArgsWrap(argsDoc: Doc, lineWidth: Int): Null<Doc> {
		return switch argsDoc {
			case WrapBoundary(inner):
				final swapped: Null<Doc> = restAwareArgsWrap(inner, lineWidth);
				swapped == null ? null : WrapBoundary(swapped);
			case Group(IfBreak(brk, flat)) if (brkLeadingBreaks(brk)):
				IfLineExceeds(lineWidth, brk, flat);
			case _: null;
		};
	}

	/**
	 * True iff `brk` is a callParameter LEADING-BREAK shape — after the open
	 * delimiter `Text`, the first non-`Empty` element pushes the argument onto
	 * its own new line (a hard `Line('\n')`, possibly wrapped in the argument
	 * `Nest`). Distinguishes the callParameter FLWLB / one-per-line break from
	 * an arrow-body close-paren coupling, whose break keeps the argument glued
	 * and only breaks the close delimiter.
	 */
	private static function brkLeadingBreaks(brk: Doc): Bool {
		return switch brk {
			case Concat(items):
				var i: Int = 0;
				if (i < items.length && isTextAtom(items[i])) i++;
				while (i < items.length && items[i] == Empty) i++;
				i < items.length && startsWithHardline(items[i]);
			case _: false;
		};
	}

	/**
	 * True iff `d`'s first visible content is a hard `Line('\n')` — descends the
	 * argument `Nest` and leading `Concat` padding.
	 *
	 * DELIBERATELY NARROW, and deliberately NOT the `WrapList` function of the same
	 * name. It recognises ONE emit signature — a callParameter break branch whose
	 * argument starts on its own line — so "anything else" is its answer, not a
	 * hole. It is therefore outside the exhaustive-spine-walker net the `Doc` enum
	 * header describes, and its `case _` must stay: descending wrappers or probes
	 * here would report a break BELOW the argument's own top level as a leading
	 * one, which is exactly the distinction `brkLeadingBreaks` is asking about.
	 */
	private static function startsWithHardline(d: Doc): Bool {
		return switch d {
			case Line(s):
				s.length > 0 && StringTools.fastCodeAt(s, 0) == '\n'.code;
			case Nest(_, inner): startsWithHardline(inner);
			case Concat(items):
				var i: Int = 0;
				while (i < items.length && items[i] == Empty) i++;
				i < items.length && startsWithHardline(items[i]);
			case _: false;
		};
	}

}
