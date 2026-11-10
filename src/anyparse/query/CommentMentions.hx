package anyparse.query;

import anyparse.query.LexicalRegions.LexRegion;
import anyparse.runtime.LineIndex;
import anyparse.runtime.Span;

using Lambda;

/** One written occurrence of a name inside a comment: the name's own span and whether the comment is a doc block. */
typedef CommentMention = { final span: Span; final doc: Bool; };

/**
 * The one answer to "where is a name written inside a comment, doc or plain": every whole-identifier
 * occurrence in a comment body, labelled doc or plain, read from the lexer's comment regions — never from a
 * text scan of the file, so a string literal that holds the same word is not a hit.
 *
 * Comments are prose, so the structural readers (refs, uses, lit) never see them; a removed or renamed member
 * leaves its name here. A hit is its own class, never mixed into a structural one.
 */
@:nullSafety(Strict)
final class CommentMentions {

	/** Longest source line printed beside a hit. */
	private static inline final EXCERPT_CHARS: Int = 100;

	/** Every whole-identifier occurrence of `name` inside a comment of `source`, in source order. */
	public static function find(source: String, regions: Array<LexRegion>, name: String): Array<CommentMention> {
		final out: Array<CommentMention> = [];
		if (name.length == 0) return out;
		for (tok in SourceComments.collectCommentTokens(regions)) {
			final doc: Bool = SourceComments.isDocBlock(source, tok);
			final body: Span = SourceComments.commentBody(source, tok);
			var from: Int = body.from;
			while (true) {
				final at: Int = SourceText.identTokenOffset(source, new Span(from, body.to), name);
				if (at < 0) break;
				out.push({ span: new Span(at, at + name.length), doc: doc });
				from = at + name.length;
			}
		}
		return out;
	}

	/**
	 * The hits of one file as `mentions` prints them: `line:col: doc|plain: <the source line>`, grouped under the
	 * file name unless `flat` asks for the `file:line:col:` shape.
	 */
	public static function render(file: String, source: String, hits: Array<CommentMention>, flat: Bool): String {
		final buf: StringBuf = new StringBuf();
		final lineIndex: LineIndex = new LineIndex(source);
		if (!flat) buf.add('$file:\n');
		for (hit in hits) {
			final pos: Position = lineIndex.lineColAt(hit.span.from);
			final label: String = hit.doc ? 'doc' : 'plain';
			final excerpt: String = SourceComments.excerptLine(
				source, SourceText.lineStartOf(source, hit.span.from), source.length, EXCERPT_CHARS
			);
			buf.add('${flat ? '$file:' : '  '}${pos.line}:${pos.col}: $label: $excerpt\n');
		}
		return buf.toString();
	}

	/**
	 * What a write op says about the comments it did not touch: how many whole-identifier mentions of `name` the
	 * written `source` still holds in comments, split doc and plain, and the command that lists them; null when none.
	 */
	public static function leftBehind(file: String, source: String, regions: Array<LexRegion>, name: String): Null<String> {
		final hits: Array<CommentMention> = find(source, regions, name);
		if (hits.length == 0) return null;
		final docs: Int = hits.count(hit -> hit.doc);
		return '${hits.length} comment mention(s) of `$name` remain ($docs doc, ${hits.length - docs} plain): apq mentions $name $file';
	}

}
