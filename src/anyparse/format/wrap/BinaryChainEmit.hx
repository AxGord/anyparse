package anyparse.format.wrap;

import anyparse.core.Doc;
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
 * `WrapList.decideRule`. Mirrors haxe-formatter's `wrapping.<class>.location`
 * field on per-rule entries in `WrapConfig.hx`.
 */
@:nullSafety(Strict)
final class BinaryChainEmit {

	private static inline final HARDLINE_LEN:Int = 1 << 20;

	public static function emit(
		items:Array<Doc>, ops:Array<String>,
		opt:WriteOptions, rules:WrapRules
	):Doc {
		if (items.length == 0) return Empty;
		if (items.length == 1) return items[0];

		var total:Int = 0;
		var maxLen:Int = 0;
		var anyHardline:Bool = false;
		for (i in 0...items.length) {
			final len:Int = WrapList.flatLength(items[i]);
			if (len < 0) {
				anyHardline = true;
				total += HARDLINE_LEN;
				maxLen = HARDLINE_LEN;
			} else {
				total += len;
				if (len > maxLen) maxLen = len;
			}
		}
		// Add ` op ` width per gap so the cascade's `totalLength` /
		// `exceedsMaxLineLength` predicates measure the realistic flat
		// span (`items joined by ' op '`).
		for (i in 0...ops.length) total += ops[i].length + 2;

		final cols:Int = opt.indentChar == IndentChar.Space ? opt.indentSize : opt.tabWidth;

		if (anyHardline) {
			final r:{mode:WrapMode, location:WrappingLocation} = WrapList.decideRule(rules, items.length, maxLen, total, true);
			return shape(r.mode, r.location, items, ops, cols);
		}

		final flat:{mode:WrapMode, location:WrappingLocation} = WrapList.decideRule(rules, items.length, maxLen, total, false);
		final brk:{mode:WrapMode, location:WrappingLocation} = WrapList.decideRule(rules, items.length, maxLen, total, true);
		if (flat.mode == brk.mode && flat.location == brk.location)
			return shape(flat.mode, flat.location, items, ops, cols);

		final flatDoc:Doc = shape(flat.mode, flat.location, items, ops, cols);
		final breakDoc:Doc = shape(brk.mode, brk.location, items, ops, cols);
		return Group(IfBreak(breakDoc, flatDoc));
	}

	private static function shape(mode:WrapMode, location:WrappingLocation, items:Array<Doc>, ops:Array<String>, cols:Int):Doc {
		return switch mode {
			case NoWrap: shapeNoWrap(items, ops);
			case OnePerLine: shapeOnePerLine(items, ops, cols, location);
			case OnePerLineAfterFirst: shapeOnePerLineAfterFirst(items, ops, cols, location);
			case FillLine | FillLineWithLeadingBreak: shapeFillLine(items, ops, cols, location);
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
		final inner:Array<Doc> = [Line('\n'), items[0]];
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
