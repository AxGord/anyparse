package anyparse.format;

import anyparse.core.Doc;
import anyparse.format.wrap.LineCommentPastSep;

/**
 * The one answer to "how does an expression-position construct group measure its one fit
 * verdict": flat including whatever trails it on the line, with a `//` comment closing the
 * construct beside the group. A hardline-bearing comment inside a group makes `fitsFlat` refuse
 * flat outright, so a comment that closes the construct would break every seam of a construct
 * that fits.
 */
class ConstructFit {

	public static function group(inner: Doc): Doc {
		final comments: Array<Doc> = [];
		final peeled: Doc = peelClosingLineComment(inner, comments);
		return comments.length == 0 ? GroupWithRestProbe(inner) : Concat([GroupWithRestProbe(peeled), comments[0]]);
	}

	private static function peelClosingLineComment(doc: Doc, comments: Array<Doc>): Doc {
		return switch doc {
			case Concat(_) if (LineCommentPastSep.isGuardedLineComment(doc)):
				comments.push(doc);
				Empty;
			case Concat(items):
				final last: Int = lastContentIndex(items);
				if (last < 0) {
					doc;
				} else {
					final closing: Doc = peelClosingLineComment(items[last], comments);
					if (comments.length == 0) {
						doc;
					} else {
						final copied: Array<Doc> = items.copy();
						copied[last] = closing;
						Concat(copied);
					}
				}
			case Nest(indent, inner):
				final closing: Doc = peelClosingLineComment(inner, comments);
				comments.length == 0 ? doc : Nest(indent, closing);
			case _: doc;
		}
	}


	private static function lastContentIndex(items: Array<Doc>): Int {
		var i: Int = items.length - 1;
		while (i >= 0 && items[i].match(Empty)) i--;
		return i;
	}

}
