package unit.format;

import anyparse.format.comment.CommentDirective;

/**
 * `CommentDirective`: the one answer the writer's trailing-comment move (FU12) and the comment reflow share on
 * which comments another tool reads off their own line.
 */
@:nullSafety(Strict)
final class CommentDirectiveTest extends Test {

	public function new(): Void {
		super();
	}

	/** Suppressions and both region-marker families are directives, whatever their case and padding. */
	@:pin('control')
	@:killer('M-COMMENT-DIRECTIVE-NONE')
	public function testDirectivesAreRecognised(): Void {
		for (text in [
			' noqa',
			'noqa: naming',
			'NOQA',
			' CHECKSTYLE:OFF',
			'checkstyle:on',
			' @formatter:off',
			'@formatter:on'
		]) Assert.isTrue(CommentDirective.isDirective(text), text);
		for (text in [' a plain note', ' see noqa below', ' formatter: off']) Assert.isFalse(CommentDirective.isDirective(text), text);
	}

	/** Only a non-directive `//` comment may move; a block comment never does. */
	@:pin('control')
	@:killer('M-TCO-DIRECTIVE-MOVED')
	public function testOnlyAPlainLineCommentIsRelocatable(): Void {
		Assert.isTrue(CommentDirective.relocatableTrailing('// listed by handleAddUsers'));
		Assert.isFalse(CommentDirective.relocatableTrailing('// noqa: naming'));
		Assert.isFalse(CommentDirective.relocatableTrailing('/* a block comment */'));
	}

}
