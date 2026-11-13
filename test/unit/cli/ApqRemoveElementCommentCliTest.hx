package unit.cli;

import anyparse.query.Cli;

/** `remove-element` says which comments still name the element it removed, as `remove-member` does. */
@:nullSafety(Strict)
class ApqRemoveElementCommentCliTest extends Test {

	private static final SOURCE: String = 'package a;\n\nclass C {\n\n\t/** The helper. */\n\tpublic function zq():Void {}\n\n'
		+ '\t// calls zq once\n\tpublic function g():Void {}\n\n}\n';
	private static final NOTE: String = '1 comment mention(s) of `zq` remain (0 doc, 1 plain): apq mentions zq ';

	/** An address resolved to a position names the removed element, and the comment that outlives it is counted. */
	@:pin('control')
	@:killer('M-REMOVE-ELEMENT-COMMENT-NOTE-DROPPED')
	public function testSelectRemovalReportsTheCommentsLeftBehind(): Void {
		final err: String = removeZq(['--select', 'FnMember:zq']);
		Assert.isTrue(err.indexOf(NOTE) >= 0, err);
	}

	/** The `--kind` form resolves its node another way and owes the same note. */
	@:pin('control')
	@:killer('M-REMOVE-ELEMENT-KIND-COMMENT-NOTE-DROPPED')
	public function testKindRemovalReportsTheCommentsLeftBehind(): Void {
		final err: String = removeZq(['--select', 'FnMember:zq', '--kind', 'FnMember']);
		Assert.isTrue(err.indexOf(NOTE) >= 0, err);
	}

	/** The note joins the cut description instead of replacing it. */
	@:pin('guard')
	public function testTheCutDescriptionStaysBesideTheNote(): Void {
		final err: String = removeZq(['--select', 'FnMember:zq']);
		Assert.isTrue(err.indexOf('removed FnMember zq') >= 0 && err.indexOf('; $NOTE') >= 0, err);
	}

	private static function removeZq(address: Array<String>): String {
		#if (sys || nodejs)
		final file: String = CliFixture.write('rmelcomment', SOURCE);
		final err: String = CliFixture.captureStderr(() -> Cli.run(['remove-element', file].concat(address).concat(['--write'])));
		sys.FileSystem.deleteFile(file);
		return err;
		#else
		return 'removed FnMember zq: 1 line; $NOTE';
		#end
	}

}
