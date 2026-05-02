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

	public static function emit(
		open:String, close:String, sep:String,
		items:Array<Doc>, opt:WriteOptions,
		openInside:Doc, closeInside:Doc,
		keepInnerWhenEmpty:Bool, rules:WrapRules,
		appendTrailingComma:Bool = false
	):Doc {
		if (items.length == 0)
			return Text(open + (keepInnerWhenEmpty ? ' ' : '') + close);

		var total:Int = 0;
		var maxLen:Int = 0;
		var anyHardline:Bool = false;
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
		}

		final cols:Int = opt.indentChar == IndentChar.Space ? opt.indentSize : opt.tabWidth;

		if (anyHardline) {
			final mode:WrapMode = decide(rules, items.length, maxLen, total, true);
			return shape(mode, open, close, sep, items, openInside, closeInside, cols, appendTrailingComma);
		}

		final modeFlat:WrapMode = decide(rules, items.length, maxLen, total, false);
		final modeBreak:WrapMode = decide(rules, items.length, maxLen, total, true);
		if (modeFlat == modeBreak)
			return shape(modeFlat, open, close, sep, items, openInside, closeInside, cols, appendTrailingComma);

		final flatDoc:Doc = shape(modeFlat, open, close, sep, items, openInside, closeInside, cols, appendTrailingComma);
		final breakDoc:Doc = shape(modeBreak, open, close, sep, items, openInside, closeInside, cols, appendTrailingComma);
		return Group(IfBreak(breakDoc, flatDoc));
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

	private static function shape(
		mode:WrapMode, open:String, close:String, sep:String,
		items:Array<Doc>, openInside:Doc, closeInside:Doc, cols:Int,
		appendTrailingComma:Bool
	):Doc {
		return switch mode {
			case NoWrap: shapeNoWrap(open, close, sep, items, openInside, closeInside);
			case OnePerLine: shapeOnePerLine(open, close, sep, items, cols, appendTrailingComma);
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
		appendTrailingComma:Bool
	):Doc {
		final sepDoc:Doc = Concat([Text(sep), Line(' ')]);
		final body:Doc = items.length == 1 ? items[0] : Fill(items, sepDoc);
		final tail:Doc = appendTrailingComma ? Text(sep) : Empty;
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
		// object literals).
		return Group(Concat([
			Text(open), openInside,
			Nest(cols, Concat([body, tail])),
			closeInside, Text(close),
		]));
	}
}
