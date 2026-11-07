package anyparse.format.wrap;

import anyparse.core.D;
import anyparse.core.Doc;

/**
 * The one answer to "how does a clause list after a declaration head wrap": `extends A implements B …` under a
 * `WrapRules` cascade, one clause breaking before itself and several breaking by the matched rule's mode.
 */
final class ClauseWrap {

	/** The list's Doc from its clause Docs; the macro hands them over, this rule owns everything after. */
	public static function layout(items: Array<Doc>, cols: Int, rules: WrapRules, lineWidth: Int): Doc {
		if (items.length <= 1) return Doc.Nest(cols, Doc.Concat([Doc.IfLineExceeds(lineWidth, D.hardline(), Doc.Text(' ')), items[0]]));
		var indent: Int = cols * (rules.defaultAdditionalIndent ?? 0);
		var mode: WrapMode = rules.defaultMode;
		var threshold: Int = -1;
		for (rule in rules.rules) {
			var lineLimit: Int = -1;
			var holds: Bool = true;
			for (cond in rule.conditions) switch cond.cond {
				case WrapConditionType.ItemCountLargerThan:
					if (items.length < cond.value) holds = false;
				case WrapConditionType.ItemCountLessThan:
					if (items.length > cond.value) holds = false;
				case WrapConditionType.LineLengthLargerThan:
					lineLimit = cond.value;
				case WrapConditionType.ExceedsMaxLineLength:
					lineLimit = lineWidth;
				case _:
					holds = false;
			}
			if (!holds) continue;
			mode = rule.mode;
			threshold = lineLimit;
			indent = cols * (rule.additionalIndent ?? 0);
			break;
		}
		final glued: Doc = Doc.Concat([Doc.Text(' '), Doc.Concat(D.intersperse(items, Doc.Text(' ')))]);
		if (mode == WrapMode.NoWrap) return glued;
		final broken: Doc = switch mode {
			case WrapMode.OnePerLine: Doc.Nest(indent, separated(items, 0, D.hardline()));
			case WrapMode.OnePerLineAfterFirst: Doc.Nest(indent, Doc.Concat([Doc.Text(' '), items[0], separated(items, 1, D.hardline())]));
			case WrapMode.FillLine, WrapMode.FillLineWithLeadingBreak:
				Doc.Nest(indent, Doc.Concat([Doc.Text(' '), Doc.Fill(items, D.line())]));
			case _: glued;
		};
		return threshold < 0 ? broken : Doc.IfLineExceeds(threshold, broken, glued);
	}

	private static function separated(items: Array<Doc>, from: Int, sep: Doc): Doc {
		final out: Array<Doc> = [];
		for (i in from ... items.length) {
			out.push(sep);
			out.push(items[i]);
		}
		return Doc.Concat(out);
	}

}
