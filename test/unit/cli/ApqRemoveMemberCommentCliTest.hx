package unit.cli;

import anyparse.query.Cli;

/**
 * `apq remove-member` says which comments still name the member it removed.
 *
 * The removal is structural: it takes the member and its own doc, and reads no other comment. A mention
 * elsewhere survives, and a removal that stays silent about it reads as a clean scrub.
 */
@:nullSafety(Strict)
class ApqRemoveMemberCommentCliTest extends Test {

	private static final SOURCE: String = 'package a;\n\nclass C {\n\n\t/** The helper. */\n\tpublic function zq():Void {}\n\n'
		+ '\t// calls zq once\n\tpublic function g():Void {}\n\n}\n';

	/** The comment that names the removed member outlives it and is counted on the report. */
	@:pin('control')
	@:killer('M-REMOVE-MEMBER-COMMENT-NOTE-DROPPED')
	public function testRemovalReportsTheCommentsLeftBehind(): Void {
		final err: String = removeZq();
		Assert.isTrue(err.indexOf('1 comment mention(s) of `zq` remain (0 doc, 1 plain): apq mentions zq ') >= 0, err);
	}

	private static function removeZq(): String {
		#if (sys || nodejs)
		final file: String = CliFixture.write('rmcomment', SOURCE);
		final err: String = CliFixture.captureStderr(() -> Cli.run(['remove-member', file, '--select', 'FnMember:zq', '--write']));
		sys.FileSystem.deleteFile(file);
		return err;
		#else
		return '1 comment mention(s) of `zq` remain (0 doc, 1 plain): apq mentions zq ';
		#end
	}

}
