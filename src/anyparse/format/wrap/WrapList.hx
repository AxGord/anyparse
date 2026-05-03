package anyparse.format.wrap;

import anyparse.core.Doc;
import anyparse.format.IndentChar;
import anyparse.format.WriteOptions;

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

	private static inline final HARDLINE_LEN:Int = 1 << 20;

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
	 */
	public static function emit(
		open:String, close:String, sep:String,
		items:Array<Doc>, opt:WriteOptions,
		openInside:Doc, closeInside:Doc,
		keepInnerWhenEmpty:Bool, rules:WrapRules,
		appendTrailingComma:Bool = false,
		leadFlat:Doc = Empty, leadBreak:Doc = Empty
	):Doc {
		if (items.length == 0)
			return Text(open + (keepInnerWhenEmpty ? ' ' : '') + close);

		var total:Int = 0;
		var maxLen:Int = 0;
		var anyHardline:Bool = false;
		var anyLeadingHardline:Bool = false;
		for (item in items) {
			final len:Int = flatLength(item);
			if (len < 0) {
				anyHardline = true;
				total += HARDLINE_LEN;
				maxLen = HARDLINE_LEN;
			} else {
				total += len;
				if (len > maxLen) maxLen = len;
			}
			if (hasLeadingHardline(item)) anyLeadingHardline = true;
		}

		final cols:Int = opt.indentChar == IndentChar.Space ? opt.indentSize : opt.tabWidth;

		if (anyHardline) {
			final mode:WrapMode = decide(rules, items.length, maxLen, total, true);
			final body:Doc = shape(mode, open, close, sep, items, openInside, closeInside, cols, appendTrailingComma, anyLeadingHardline);
			return prependLead(body, isFlatMode(mode) ? leadFlat : leadBreak);
		}

		final modeFlat:WrapMode = decide(rules, items.length, maxLen, total, false);
		final modeBreak:WrapMode = decide(rules, items.length, maxLen, total, true);
		if (modeFlat == modeBreak) {
			final body:Doc = shape(modeFlat, open, close, sep, items, openInside, closeInside, cols, appendTrailingComma, false);
			return prependLead(body, isFlatMode(modeFlat) ? leadFlat : leadBreak);
		}

		final flatDoc:Doc = shape(modeFlat, open, close, sep, items, openInside, closeInside, cols, appendTrailingComma, false);
		final breakDoc:Doc = shape(modeBreak, open, close, sep, items, openInside, closeInside, cols, appendTrailingComma, false);
		final flatWithLead:Doc = prependLead(flatDoc, leadFlat);
		final breakWithLead:Doc = prependLead(breakDoc, leadBreak);
		return Group(IfBreak(breakWithLead, flatWithLead));
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
				case OptHardline:
					// OptHardline can never flatten — mirrors `Line('\n')`
					// returning -1 (and `Renderer.fitsFlat`'s OptHardline
					// arm). Any item containing an OptHardline forces the
					// wrap engine into break mode unconditionally.
					return -1;
			}
		}
		return total;
	}

	/**
	 * Walks the rules cascade and returns the first matching mode.
	 * Falls back to `rules.defaultMode` when no rule matches.
	 */
	public static function decide(
		rules:WrapRules, itemCount:Int, maxItemLen:Int,
		totalItemLen:Int, exceedsMaxLineLength:Bool
	):WrapMode {
		for (rule in rules.rules) {
			if (matches(rule, itemCount, maxItemLen, totalItemLen, exceedsMaxLineLength))
				return rule.mode;
		}
		return rules.defaultMode;
	}

	private static function matches(
		rule:WrapRule, itemCount:Int, maxItemLen:Int,
		totalItemLen:Int, exceedsMaxLineLength:Bool
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
				case _: false;
			};
			if (!ok) return false;
		}
		return true;
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
		appendTrailingComma:Bool, forceBreak:Bool
	):Doc {
		return switch mode {
			case NoWrap: shapeNoWrap(open, close, sep, items, openInside, closeInside);
			case OnePerLine: shapeOnePerLine(open, close, sep, items, cols, appendTrailingComma);
			case OnePerLineAfterFirst: shapeOnePerLineAfterFirst(open, close, sep, items, cols, appendTrailingComma);
			case FillLine | FillLineWithLeadingBreak: shapeFillLine(open, close, sep, items, openInside, closeInside, cols, appendTrailingComma, forceBreak);
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
		appendTrailingComma:Bool
	):Doc {
		final inner:Array<Doc> = [];
		for (i in 0...items.length) {
			inner.push(Line('\n'));
			inner.push(items[i]);
			if (i < items.length - 1 || appendTrailingComma) inner.push(Text(sep));
		}
		return Concat([Text(open), Nest(cols, Concat(inner)), Line('\n'), Text(close)]);
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
		appendTrailingComma:Bool, forceBreak:Bool
	):Doc {
		// `forceBreak`: at least one item starts with a hardline
		// (typically an objectLit / anonFn arg with `leftCurly=Next`).
		// In this case the cascade-picked FillLine layout MUST commit
		// to break mode regardless of total flat width — otherwise
		// the outer Group's `fitsFlat` walks past `BodyGroup`-deferred
		// items (Departure 2 in `Renderer`) and concludes that the
		// whole list fits inline, so `Nest` is bypassed and each
		// item's leading hardline lands at the surrounding indent
		// instead of the list's continuation indent.
		// (`feedback_fillline_bodygroup_deferred_flat.md`.)
		//
		// Two changes follow:
		//  - sep's soft-line replacement becomes a real hardline
		//    (`Line('\n')`) so `Fill`'s per-item-fit decision always
		//    routes the sep frame through MBreak — no `, \n` trailing
		//    space when the next item brings its own leading hardline;
		//  - a `Line('\n')` is prepended inside the `Nest`, so the
		//    Group sees an unflattenable hardline and commits to
		//    MBreak (Departure 3); `items[0]`'s own leading
		//    `OptHardline` then collides with this one and drops the
		//    duplicate `\n` (per `Renderer.OptHardline`'s
		//    `lastEmittedWasHardline` check).
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
			return Group(Concat([
				Text(open), openInside, items[0], tail0,
				closeInside, Text(close),
			]));
		}
		final sepLine:Doc = forceBreak ? Line('\n') : Line(' ');
		final sepDoc:Doc = Concat([Text(sep), sepLine]);
		final body:Doc = Fill(items, sepDoc);
		final tail:Doc = appendTrailingComma ? Text(sep) : Empty;
		final inner:Doc = forceBreak
			? Concat([Line('\n'), body, tail])
			: Concat([body, tail]);
		// Group wrap: matches the old `fillList` shape (parity with
		// pre-cascade `@:fmt(fill)` Wadler-fillSep emission). The Group
		// gives the renderer a coherent flat/break unit for measuring
		// Fill's natural fit — when the Fill subtree fits flat on the
		// remaining line, the Group selects MFlat and Nest is bypassed
		// (no extra indent on inline args); when it doesn't, the Group
		// breaks and Nest applies, giving each broken-before item the
		// list's continuation indent. Without this Group wrap, the
		// renderer stays in MBreak by default and Nest unconditionally
		// adds cols to every Line replacement, over-indenting hardline-
		// bearing args (e.g. anon-function block bodies, multi-line
		// object literals). When `forceBreak=true` the prepended
		// hardline guarantees the Group lands in MBreak.
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
			case OptHardline: true;
			case Line(flat): flat.length > 0 && StringTools.fastCodeAt(flat, 0) == '\n'.code;
			case Text(_): false;
			case OptSpace(_): false;
			case Nest(_, inner): hasLeadingHardline(inner);
			case Group(inner) | BodyGroup(inner): hasLeadingHardline(inner);
			case IfBreak(_, _): false;
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
