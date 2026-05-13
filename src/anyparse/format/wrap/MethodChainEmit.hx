package anyparse.format.wrap;

import anyparse.core.Doc;
import anyparse.core.DocMeasure;
import anyparse.format.IndentChar;
import anyparse.format.WriteOptions;

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
 */
class MethodChainEmit {

	public static function emit(
		receiver:Doc, segments:Array<Doc>, opt:WriteOptions, rules:WrapRules
	):Doc {
		if (segments.length == 0) return WrapBoundary(receiver);

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
		var total:Int = 0;
		var maxLen:Int = 0;
		for (seg in segments) {
			final len:Int = DocMeasure.flatTokenWidth(seg);
			total += len;
			if (len > maxLen) maxLen = len;
		}

		final cols:Int = opt.indentChar == IndentChar.Space ? opt.indentSize : opt.tabWidth;

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
		final extraThresholds:Array<Int> = WrapList.collectExtraLineLengthThresholds(rules, opt.lineWidth);

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
		function evalAt(exceeds:Bool, firing:Array<Int>):WrapMode {
			return WrapList.decideWithLineLengthState(rules, segments.length, maxLen, total,
				exceeds, false,
				t -> t == opt.lineWidth ? exceeds : firing.contains(t));
		}

		function shapeAt(mode:WrapMode):Doc {
			return shape(mode, receiver, segments, cols);
		}

		// Normal path: cascade evaluated against (exceeds=false /
		// exceeds=true) AND each non-lineWidth threshold's firing state.
		// Tree construction mirrors `WrapList.emit`'s 0/1/N branches —
		// the impossibility-pruning at N=1 keeps the renderer's tree
		// minimal (one impossible state filtered out per `t < lineWidth`
		// or `t > lineWidth` case).
		if (extraThresholds.length == 0) {
			final modeFlat:WrapMode = evalAt(false, []);
			final modeBreak:WrapMode = evalAt(true, []);
			if (modeFlat == modeBreak) return WrapBoundary(shapeAt(modeFlat));
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
			return WrapBoundary(IfFullLineExceeds(opt.lineWidth, shapeAt(modeBreak), shapeAt(modeFlat)));
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
				if (modeNN == modeYN && modeYN == modeYY) return WrapBoundary(shapeAt(modeNN));
				final brk:Doc = (modeYY == modeYN) ? shapeAt(modeYY) : IfFullLineExceeds(opt.lineWidth, shapeAt(modeYY), shapeAt(modeYN));
				return WrapBoundary(Group(IfWidthExceeds(t, brk, shapeAt(modeNN))));
			}
			// t > lineWidth: 3 valid states (col+w>=t implies col+w>=lineWidth):
			//   (firing=∅,    exceeds=no)  → modeNN
			//   (firing=∅,    exceeds=yes) → modeNY
			//   (firing={t},  exceeds=yes) → modeYY
			final modeNN:WrapMode = evalAt(false, []);
			final modeNY:WrapMode = evalAt(true, []);
			final modeYY:WrapMode = evalAt(true, [t]);
			if (modeNN == modeNY && modeNY == modeYY) return WrapBoundary(shapeAt(modeNN));
			final brk:Doc = (modeNY == modeYY) ? shapeAt(modeYY) : Group(IfWidthExceeds(t, shapeAt(modeYY), shapeAt(modeNY)));
			return WrapBoundary(IfFullLineExceeds(opt.lineWidth, brk, shapeAt(modeNN)));
		}

		// 2+ extra thresholds — full enumeration without impossibility
		// filtering. Renderer's column-aware probe at each
		// `IfWidthExceeds` layer picks the correct leaf at runtime; the
		// impossible-state shapes are inert. None of the current default
		// cascades use N≥2 — this branch is correctness insurance.
		return WrapBoundary(buildChainThresholdTree(extraThresholds, [], evalAt, shapeAt, opt.lineWidth));
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
		thresholds:Array<Int>, firing:Array<Int>,
		evalAt:(Bool, Array<Int>) -> WrapMode,
		shapeAt:WrapMode -> Doc,
		lineWidth:Int
	):Doc {
		if (thresholds.length == 0) {
			final modeFlat:WrapMode = evalAt(false, firing);
			final modeBreak:WrapMode = evalAt(true, firing);
			if (modeFlat == modeBreak) return shapeAt(modeFlat);
			return IfFullLineExceeds(lineWidth, shapeAt(modeBreak), shapeAt(modeFlat));
		}
		final t:Int = thresholds[0];
		final rest:Array<Int> = thresholds.slice(1);
		final firingPlus:Array<Int> = firing.copy();
		firingPlus.push(t);
		final brk:Doc = buildChainThresholdTree(rest, firingPlus, evalAt, shapeAt, lineWidth);
		final flat:Doc = buildChainThresholdTree(rest, firing, evalAt, shapeAt, lineWidth);
		return IfWidthExceeds(t, brk, flat);
	}

	private static function shape(
		mode:WrapMode, receiver:Doc, segments:Array<Doc>, cols:Int
	):Doc {
		return switch mode {
			case NoWrap: shapeNoWrap(receiver, segments);
			case OnePerLine: shapeOnePerLine(receiver, segments, cols);
			case OnePerLineAfterFirst: shapeOnePerLineAfterFirst(receiver, segments, cols);
			// FillLine and FillLineWithLeadingBreak don't have a chain-
			// specific semantics in fork's `WrappingProcessor` either.
			// Fall back to OnePerLineAfterFirst (the most common chain
			// break shape) — a future slice can split if a fixture
			// demands it.
			case _: shapeOnePerLineAfterFirst(receiver, segments, cols);
		};
	}

	private static function shapeNoWrap(receiver:Doc, segments:Array<Doc>):Doc {
		final inner:Array<Doc> = [receiver];
		for (s in segments) inner.push(s);
		return Concat(inner);
	}

	private static function shapeOnePerLineAfterFirst(receiver:Doc, segments:Array<Doc>, cols:Int):Doc {
		// `receiver seg0` inline; remaining segments each on their own
		// indented line. The macro-side dispatch guards with
		// `segments.length >= 2`, so a one-segment input here is a
		// regression — surface it loudly per "guard clauses throw"
		// rather than producing a degraded but plausible single-call
		// shape.
		if (segments.length < 2)
			throw 'MethodChainEmit.shapeOnePerLineAfterFirst: macro-side ≥2 guard violated (segments=${segments.length})';
		final tail:Array<Doc> = [];
		for (i in 1...segments.length) {
			tail.push(Line('\n'));
			tail.push(segments[i]);
		}
		return Concat([receiver, segments[0], Nest(cols, Concat(tail))]);
	}

	private static function shapeOnePerLine(receiver:Doc, segments:Array<Doc>, cols:Int):Doc {
		// Receiver inline, then ALL segments on their own indented
		// lines (including the first). Mirrors fork's
		// `WrappingType.onePerLine` shape for chain origin —
		// the receiver stays at the call-site column and the chain
		// breaks below it at one indent level deeper.
		final tail:Array<Doc> = [];
		for (s in segments) {
			tail.push(Line('\n'));
			tail.push(s);
		}
		return Concat([receiver, Nest(cols, Concat(tail))]);
	}
}
