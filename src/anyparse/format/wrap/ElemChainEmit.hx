package anyparse.format.wrap;

import anyparse.core.Doc;

using Lambda;

/**
 * The one answer to "how does a separated list lay out when its elements are chains of an operator that reads as a
 * second separator" (`case a | b, c:`). Both separators are gaps of one chain, so a fill packs across them and the
 * cascade counts every operand rather than every element.
 *
 * The operands are read back off the element Docs the host writer built, so the descent needs no flag telling a chain
 * which position it sits in. What follows the last element's chain (a guard) stays outside the chain: it never charges
 * the chain for a line it can wrap on its own.
 */
final class ElemChainEmit {

	/**
	 * Lays out `items` as one chain over `sep` and `op`, or returns null when the plain list layout stands: no element is a
	 * chain and no rule leads a line with `sep`, the cascade answers `keep` or `ignore` or names an additional indent, an
	 * operand opens on a line of its own, or a line comment would swallow the separator behind it.
	 */
	public static function emit(close: String, sep: String, op: String, items: Array<Doc>, opt: WriteOptions, rules: WrapRules): Null<Doc> {
		final parts: Array<Doc> = [];
		final ops: Array<String> = [];
		var tail: Array<Doc> = [];
		for (i => item in items) {
			if (i > 0) ops.push(sep);
			final elem: ElemParts = elemParts(item, op);
			for (k => part in elem.operands) {
				if (k > 0) ops.push(op);
				parts.push(part);
			}
			if (i == items.length - 1)
				tail = elem.tail;
			else if (elem.tail.length > 0)
				parts[parts.length - 1] = Concat([parts[parts.length - 1]].concat(elem.tail));
		}
		if (parts.length < 2 || (!ops.contains(op) && !leadsWithSep(rules))) return null;
		if (cascadeLeavesTheList(parts.length, rules) || namesAdditionalIndent(rules) || operandOpensItsOwnLine(parts)) return null;
		if (parts.slice(0, parts.length - 1).concat(tail).exists(WrapList.endsWithLineComment)) return null;
		return BinaryChainEmit.emit(
			parts, ops, opt, rules, false, false, null, false, false, null, false, null, false, null, null,
			{ sep: sep, tail: tail, close: close }
		);
	}

	/** An element's absent slot: no comment to carry, no guard. */
	private static inline function isBlank(d: Doc): Bool {
		return switch d {
			case Empty, Concat([]): true;
			case _: false;
		};
	}

	/** A fill gap stays flat in front of an operand that opens with a hardline, which strands the gap's space at the line end. */
	private static inline function operandOpensItsOwnLine(parts: Array<Doc>): Bool {
		return parts.exists(WrapList.startsWithHardline);
	}

	/** Whether any answer of the cascade may start a continuation line with the list separator. */
	private static function leadsWithSep(rules: WrapRules): Bool {
		return rules.defaultLocation == WrappingLocation.BeforeLast || rules.rules.exists(r -> r.location == WrappingLocation.BeforeLast);
	}

	/** A cascade defaulting to `keep` or `ignore` names no layout the chain could take. */
	private static function cascadeLeavesTheList(operands: Int, rules: WrapRules): Bool {
		return rules.defaultMode == WrapMode.Keep || rules.defaultMode == WrapMode.Ignore || WrapList.cascadeIsKeep(rules, operands);
	}

	/** The chain's cascade answer carries mode and location only, so the extra continuation indent stays with the list layout. */
	private static function namesAdditionalIndent(rules: WrapRules): Bool {
		return (rules.defaultAdditionalIndent ?? 0) != 0 || rules.rules.exists(r -> (r.additionalIndent ?? 0) != 0);
	}

	/**
	 * An element split into its operands and what follows the chain inside it (a guard, a trailing comment).
	 * A leading comment leaves the element atomic.
	 */
	private static function elemParts(d: Doc, op: String): ElemParts {
		final chain: Array<Doc> = chainOperands(d, op);
		if (chain.length > 1) return { operands: chain, tail: [] };
		final parts: Array<Doc> = switch d {
			case Concat(xs): xs.filter(x -> !isBlank(x));
			case _: [];
		};
		if (parts.length == 0) return { operands: [d], tail: [] };
		final head: ElemParts = elemParts(parts[0], op);
		return head.operands.length == 1
			? { operands: [d], tail: [] }
			: { operands: head.operands, tail: head.tail.concat(parts.slice(1)) };
	}

	/**
	 * The operands of the infix shape `WriterPrattLowering.lowerInfixBranch` writes for a plain binary operator, soft-broken
	 * or glued. Left-associative, so only the left side recurses.
	 */
	private static function chainOperands(d: Doc, op: String): Array<Doc> {
		return switch d {
			case Group(Concat([left, Nest(_, Concat([Line(_), Text(t), right]))])) if (t == '$op '):
				leftOperands(left, op).concat([right]);
			case Concat([left, Text(t), right]) if (t == ' $op '):
				leftOperands(left, op).concat([right]);
			case _:
				[d];
		};
	}

	/** A chain's left side: the comment captured after its right operand stays on that operand. */
	private static function leftOperands(d: Doc, op: String): Array<Doc> {
		switch d {
			case Concat([chain, comment]):
				final operands: Array<Doc> = chainOperands(chain, op);
				if (operands.length == 1) return [d];
				operands[operands.length - 1] = Concat([operands[operands.length - 1], comment]);
				return operands;
			case _:
				return chainOperands(d, op);
		}
	}

}

private typedef ElemParts = {
	final operands: Array<Doc>;
	final tail: Array<Doc>;
};
