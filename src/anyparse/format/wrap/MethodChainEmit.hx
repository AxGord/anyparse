package anyparse.format.wrap;

import anyparse.core.Doc;
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
		if (segments.length == 0) return receiver;

		// Token-text width metric: chain segment length is the segment's
		// rendered width with internal `Line('\n')` / `OptHardline`
		// counted as zero contribution. Mirrors fork's chain measurement
		// (token-position-based span ignoring inside-lambda layout
		// breaks). Without this, a multi-line lambda body inside `.then(
		// λ)` makes `WrapList.flatLength` return -1 and forces break-mode
		// unconditionally — wrong: a 2-segment chain whose only "size"
		// is internal lambda content should stay flat per fork's
		// `itemCount<=3 + !exceeds → NoWrap` default rule.
		var total:Int = 0;
		var maxLen:Int = 0;
		for (seg in segments) {
			final len:Int = chainItemLength(seg);
			total += len;
			if (len > maxLen) maxLen = len;
		}

		final cols:Int = opt.indentChar == IndentChar.Space ? opt.indentSize : opt.tabWidth;

		final modeFlat:WrapMode = WrapList.decide(rules, segments.length, maxLen, total, false);
		final modeBreak:WrapMode = WrapList.decide(rules, segments.length, maxLen, total, true);
		if (modeFlat == modeBreak)
			return shape(modeFlat, receiver, segments, cols);

		final flatDoc:Doc = shape(modeFlat, receiver, segments, cols);
		final breakDoc:Doc = shape(modeBreak, receiver, segments, cols);
		return Group(IfBreak(breakDoc, flatDoc));
	}

	private static function chainItemLength(d:Doc):Int {
		final stack:Array<Doc> = [d];
		var total:Int = 0;
		while (stack.length > 0) {
			final node:Doc = stack.pop();
			switch (node) {
				case Empty:
				case Text(s):
					total += s.length;
				case Line(flat):
					if (flat.length > 0 && StringTools.fastCodeAt(flat, 0) == '\n'.code) {
						// hardline — count 0 (token-width measurement
						// skips the layout break).
					} else {
						total += flat.length;
					}
				case Nest(_, inner):
					stack.push(inner);
				case Concat(items):
					var i:Int = items.length;
					while (--i >= 0) stack.push(items[i]);
				case Group(inner) | BodyGroup(inner):
					stack.push(inner);
				case IfBreak(_, flatDoc):
					stack.push(flatDoc);
				case Fill(items, sep):
					var k:Int = items.length;
					while (k > 0) {
						k--;
						stack.push(items[k]);
						if (k > 0) stack.push(sep);
					}
				case OptSpace(s):
					total += s.length;
				case OptHardline:
					// Same zero-width treatment as `Line('\n')`.
			}
		}
		return total;
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
