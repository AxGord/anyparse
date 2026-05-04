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
 *    spaces around each op).
 *  - `OnePerLineAfterFirst` → `items[0]` flat, then per continuation
 *    line `\n+indent op_i+' '+items[i+1]` (op-before-operand). Used
 *    for haxe-formatter default break shape — assignment RHS chains
 *    (`dirty = dirty\n\t|| (X)\n\t|| (Y)`).
 *  - `OnePerLine`           → `\n+indent items[0] ' '+op_0\n+indent
 *    items[1] ' '+op_1\n+indent …\n+indent items[n-1]`
 *    (op-after-operand). Used for `defaultWrap: onePerLine` configs.
 *  - `FillLine` /
 *    `FillLineWithLeadingBreak` → soft-line packing through `Fill` —
 *    items pack inline up to line budget, the soft-line before the
 *    overflowing item breaks at the chain's continuation indent. The
 *    operator is suffixed onto the previous item (op-after-operand).
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
			final mode:WrapMode = WrapList.decide(rules, items.length, maxLen, total, true);
			return shape(mode, items, ops, cols);
		}

		final modeFlat:WrapMode = WrapList.decide(rules, items.length, maxLen, total, false);
		final modeBreak:WrapMode = WrapList.decide(rules, items.length, maxLen, total, true);
		if (modeFlat == modeBreak) return shape(modeFlat, items, ops, cols);

		final flatDoc:Doc = shape(modeFlat, items, ops, cols);
		final breakDoc:Doc = shape(modeBreak, items, ops, cols);
		return Group(IfBreak(breakDoc, flatDoc));
	}

	private static function shape(mode:WrapMode, items:Array<Doc>, ops:Array<String>, cols:Int):Doc {
		return switch mode {
			case NoWrap: shapeNoWrap(items, ops);
			case OnePerLine: shapeOnePerLine(items, ops, cols);
			case OnePerLineAfterFirst: shapeOnePerLineAfterFirst(items, ops, cols);
			case FillLine | FillLineWithLeadingBreak: shapeFillLine(items, ops, cols);
			case _: shapeOnePerLineAfterFirst(items, ops, cols);
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

	private static function shapeOnePerLineAfterFirst(items:Array<Doc>, ops:Array<String>, cols:Int):Doc {
		// First operand stays at the call-site column; remaining operands
		// each on their own indented continuation line, prefixed by the
		// operator (BeforeLast op placement). Matches haxe-formatter's
		// default break shape for opBoolChain / opAddSubChain.
		final tail:Array<Doc> = [];
		for (i in 0...ops.length) {
			tail.push(Line('\n'));
			tail.push(Text(ops[i] + ' '));
			tail.push(items[i + 1]);
		}
		return Concat([items[0], Nest(cols, Concat(tail))]);
	}

	private static function shapeOnePerLine(items:Array<Doc>, ops:Array<String>, cols:Int):Doc {
		// Every operand on its own indented line; operator suffix
		// (` op`) on each line except the last (After op placement).
		// Matches haxe-formatter's `defaultWrap: onePerLine` shape used
		// inside parens (`return !(\n\ta || b || \n\tc || \n\td\n);`).
		final inner:Array<Doc> = [Line('\n'), items[0]];
		for (i in 0...ops.length) {
			inner.push(Text(' ' + ops[i]));
			inner.push(Line('\n'));
			inner.push(items[i + 1]);
		}
		return Nest(cols, Concat(inner));
	}

	private static function shapeFillLine(items:Array<Doc>, ops:Array<String>, cols:Int):Doc {
		// Soft-line packing with op-BEFORE-next-operand (BeforeLast
		// placement) — `' '` (flat) / `'\n+indent '` (break) lives
		// AHEAD of the operator so a broken soft-line lands the
		// operator at the start of the continuation line. Mirrors
		// haxe-formatter's `opAddSubChain` rule's `location: BeforeLast`
		// — `throw "..." + ... + "...("\n\t+ rest`. items[0] renders
		// alone; each subsequent operand is preceded by ` op operand`
		// (flat) or `\n+indent op operand` (break).
		//
		// `Fill(items, sep)` fits each item against the remaining
		// budget on the current line; the per-item-fit decision packs
		// operands until the next one overflows, then the soft-line
		// between them breaks. Wrapping in `Nest(cols)` gives the
		// continuation lines the chain's standard one-tab indent.
		final enriched:Array<Doc> = [items[0]];
		for (i in 0...ops.length)
			enriched.push(Concat([Text(ops[i] + ' '), items[i + 1]]));
		return Group(Nest(cols, Fill(enriched, Line(' '))));
	}
}
