package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport.EditResult;
import anyparse.query.SetComment;

using StringTools;

/**
 * Probe for `apq set-comment` — replace the comment at a cursor, the comment
 * counterpart of `set-doc` (line comments are trivia no other op reaches).
 * Drives `SetComment.setComment` directly on in-memory sources (pure,
 * JS-native) with `reformat = true` so fixtures need not be writer-canonical.
 * Covers a `//` run merged into one unit, a block comment, a doc comment, a
 * trailing comment, and the refusal cases (off a comment / non-comment
 * replacement / empty).
 */
class SetCommentSliceTest extends Test {

	/** A full-line `//` run is replaced as ONE unit (all lines swapped). */
	public function testReplacesLineRun(): Void {
		final src: String = 'class C {\n\t// old one\n\t// old two\n\tvar x: Int = 1;\n}';
		final text: String = okText(SetComment.setComment(src, 2, 1, '// new A\n// new B', true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('new A'));
		Assert.isTrue(text.contains('new B'));
		Assert.isFalse(text.contains('old one'));
		Assert.isFalse(text.contains('old two'));
	}

	/** A block comment is replaced whole. */
	public function testReplacesBlock(): Void {
		final src: String = 'class C {\n\t/* old block */\n\tvar x: Int = 1;\n}';
		final text: String = okText(SetComment.setComment(src, 2, 1, '/* new block */', true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('new block'));
		Assert.isFalse(text.contains('old block'));
	}

	/** A doc comment is replaced (it is a block comment to the scanner). */
	public function testReplacesDoc(): Void {
		final src: String = 'class C {\n\t/**\n\t * old doc\n\t */\n\tpublic function f(): Void {}\n}';
		final text: String = okText(SetComment.setComment(src, 2, 1, '/**\n * new doc\n */', true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('new doc'));
		Assert.isFalse(text.contains('old doc'));
	}

	/** A trailing `//` after code is replaced alone, not merged. */
	public function testReplacesTrailing(): Void {
		final src: String = 'class C {\n\tvar x: Int = 1; // tail old\n}';
		final text: String = okText(SetComment.setComment(src, 2, 17, '// tail new', true, new HaxeQueryPlugin()));
		Assert.isTrue(text.contains('tail new'));
		Assert.isFalse(text.contains('tail old'));
	}

	/** A cursor not on a comment is an error. */
	public function testBadPositionIsError(): Void {
		final src: String = 'class C {\n\t// c\n\tvar x: Int = 1;\n}';
		Assert.isTrue(isErr(SetComment.setComment(src, 99, 1, '// x', true, new HaxeQueryPlugin())));
	}

	/** A replacement that is not a comment is refused. */
	public function testNonCommentReplacementIsError(): Void {
		final src: String = 'class C {\n\t// c\n\tvar x: Int = 1;\n}';
		Assert.isTrue(isErr(SetComment.setComment(src, 2, 1, 'var z = 1;', true, new HaxeQueryPlugin())));
	}

	/** An empty replacement is refused. */
	public function testEmptyReplacementIsError(): Void {
		final src: String = 'class C {\n\t// c\n\tvar x: Int = 1;\n}';
		Assert.isTrue(isErr(SetComment.setComment(src, 2, 1, '   ', true, new HaxeQueryPlugin())));
	}

	private function okText(res: EditResult): String {
		return switch res {
			case Ok(text): text;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				'';
		};
	}

	private function isErr(res: EditResult): Bool {
		return switch res {
			case Ok(_): false;
			case Err(_): true;
		};
	}

}
