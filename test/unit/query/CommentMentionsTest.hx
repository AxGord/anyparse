package unit.query;

import anyparse.query.CommentMentions;

/**
 * `CommentMentions`: the whole-identifier occurrences of a name inside comment regions, and the note a
 * write op prints about the ones it left behind.
 */
@:nullSafety(Strict)
class CommentMentionsTest extends Test {

	private static final SOURCE: String = 'class C {\n\t/** zq in docs */\n\tvar a: Int;\n\t// zq twice: zq\n\tvar zq: Int;\n}';

	/** Each occurrence is its own hit, in source order, labelled by the kind of comment holding it. */
	public function testFindLabelsEachOccurrence(): Void {
		final hits: Array<CommentMention> = CommentMentions.find(SOURCE, new HaxeQueryPlugin().lexicalRegions(SOURCE), 'zq');
		Assert.equals(3, hits.length);
		Assert.isTrue(hits[0].doc);
		Assert.isFalse(hits[1].doc);
		Assert.isFalse(hits[2].doc);
		Assert.isTrue(hits[1].span.from < hits[2].span.from);
	}

	/** The note counts doc and plain mentions apart and names the command that lists them. */
	@:pin('control')
	@:killer('M-COMMENT-LEFTBEHIND-DOC-SPLIT')
	public function testLeftBehindSplitsDocAndPlain(): Void {
		final note: Null<String> = CommentMentions.leftBehind('C.hx', SOURCE, new HaxeQueryPlugin().lexicalRegions(SOURCE), 'zq');
		Assert.equals('3 comment mention(s) of `zq` remain (1 doc, 2 plain): apq mentions zq C.hx', note);
	}

	/** A name no comment writes leaves nothing to say. */
	public function testLeftBehindIsNullWithoutMentions(): Void {
		Assert.isNull(CommentMentions.leftBehind('C.hx', SOURCE, new HaxeQueryPlugin().lexicalRegions(SOURCE), 'absent'));
	}

}
