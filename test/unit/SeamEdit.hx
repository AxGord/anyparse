package unit;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Hand-built edits over a fixture, through `RefactorSupport.canonicalize` — the
 * seam every writer-emit op and every `lint --fix` wave passes through, and the
 * only entry that can splice a region no addressed op can name (a whole `else`
 * branch) or a replacement no op will generate on its own (a comment).
 *
 * Shared, because BOTH structural guards are asked from that one function:
 * `BodySlotGuard` on the shape a deletion leaves behind and `docSplittingEdit`
 * on whose doc comment an insertion steals. A copy of the splice per guard test
 * would let the two drift on HOW the seam is called while both claim to be
 * testing the same seam.
 *
 * `reformat` is true throughout so a fixture does not also have to be
 * writer-canonical.
 */
final class SeamEdit {

	/** Insert `text` before the first occurrence of `find` — an edit whose span deletes nothing. */
	public static function insert(source: String, find: String, text: String): EditResult {
		return apply(source, [{ find: find, covered: 0, text: text }]);
	}

	/** Replace the first occurrence of `find` with `text`. */
	public static function replace(source: String, find: String, text: String): EditResult {
		return apply(source, [{ find: find, covered: find.length, text: text }]);
	}

	/**
	 * SEVERAL edits at once — the shape a `patch` multi-pair payload and one
	 * `lint --fix` check's edit set both produce, and the only one where a
	 * construct's end can land in an edit OTHER than the one that touched its body.
	 * `covered` is how many bytes of `find` the edit replaces: 0 inserts before it.
	 */
	public static function apply(source: String, pairs: Array<{ find: String, covered: Int, text: String }>): EditResult {
		final edits: Array<{ span: Span, text: String }> = [];
		for (pair in pairs) {
			final at: Int = source.indexOf(pair.find);
			if (at < 0) throw new Exception('the fixture does not contain "${pair.find}"');
			edits.push({ span: new Span(at, at + pair.covered), text: pair.text });
		}
		return CanonicalEdit.canonicalize(source, edits, true, new HaxeQueryPlugin());
	}

}
