package anyparse.format.wrap;

import anyparse.core.D;
import anyparse.core.Doc;

/**
 * The one answer to "how does a chain of operands joined by an operator that is never a wrap point lay out"
 * (`A & B & {…} & C`): every operand follows its operator on the same line; where the site grants it, the one after a
 * multi-line operand that closes with a delimiter starts a line of its own one indent deeper (`} &` then the operand).
 * The chain's first operand never counts as such a predecessor: what follows a head that is a multi-line body stays
 * on its closing line.
 */
final class OperandChainEmit {

	/**
	 * `items` joined by `op`. `spaced` is the operator with its own trailing spacing; `afters[i]` what was written
	 * between the operator after `items[i]` and the next operand (comments, with their own break), `leadLine[i]`
	 * whether `items[i]` ends in a line comment, so its operator must open the next line. `breakAfterBody` is the
	 * site granting the break after a multi-line body; without it every operand stays on its operator line.
	 */
	public static function emit(
		items: Array<Doc>, op: String, spaced: Doc, afters: Array<Null<Doc>>, leadLine: Array<Bool>, indent: Int, breakAfterBody: Bool
	): Doc {
		final parts: Array<Doc> = [items[0]];
		for (i in 1...items.length) {
			final prior: Doc = items[i - 1];
			parts.push(leadLine[i - 1] ? Nest(indent, D.hardline()) : Text(' '));
			if (breakAfterBody && i > 1 && WrapList.flatLength(prior) < 0 && WrapList.endsWithCloseDelim(prior)) {
				parts.push(Text(op));
				parts.push(Nest(indent, D.hardline()));
			} else {
				parts.push(spaced);
			}
			final after: Null<Doc> = afters[i - 1];
			if (after != null) parts.push(after);
			parts.push(items[i]);
		}
		return Concat(parts);
	}

}
