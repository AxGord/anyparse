package unit.cli;

import anyparse.query.Cli;

/**
 * `apq rename` says which comments still name the old name, on each of its three emit seams.
 *
 * The rename rewrites code occurrences; prose that names the old name survives, and a rename that stays silent
 * about it reads as a clean one.
 */
@:nullSafety(Strict)
class ApqRenameCommentCliTest extends Test {

	private static final NOTE: String = '1 comment mention(s) of `zq` remain (0 doc, 1 plain): apq mentions zq ';
	private static final VALUE: String = 'package a;\n\nclass C {\n\n\tpublic function f():Void {\n\t\t// zq counts the calls\n'
		+ '\t\tvar zq:Int = 1;\n\t\ttrace(zq);\n\t}\n\n}\n';
	private static final MEMBER: String =
		'package a;\n\nclass C {\n\n\tpublic function zq():Void {}\n\n\t// calls zq once\n\tpublic function g():Void {}\n\n}\n';
	private static final TYPE: String = 'package a;\n\n// Zq is the one\nclass Zq {\n\n\tpublic function new() {}\n\n}\n';

	/** A local renamed by value resolution leaves its name in a comment and says so on the write line. */
	@:pin('control')
	@:killer('M-RENAME-VALUE-COMMENT-NOTE-DROPPED')
	public function testValueRenameReportsTheCommentsLeftBehind(): Void {
		final err: String = renameIn(VALUE, ['--select', 'FnMember:f >> VarStmt:zq', 'n']);
		Assert.isTrue(err.indexOf(NOTE) >= 0, err);
	}

	/** A member renamed in its own file takes the in-file path and owes the same note. */
	@:pin('control')
	@:killer('M-RENAME-IN-FILE-COMMENT-NOTE-DROPPED')
	public function testMemberInFileRenameReportsTheCommentsLeftBehind(): Void {
		final err: String = renameIn(MEMBER, ['--select', 'FnMember:zq', 'wq']);
		Assert.isTrue(err.indexOf(NOTE) >= 0, err);
	}

	/** A type renamed in its own file reports the comment that still spells the old name. */
	@:pin('control')
	@:killer('M-RENAME-IN-FILE-COMMENT-NOTE-DROPPED')
	public function testTypeInFileRenameReportsTheCommentsLeftBehind(): Void {
		final err: String = renameIn(TYPE, ['--select', 'ClassDecl:Zq', 'Wq']);
		Assert.isTrue(err.indexOf('1 comment mention(s) of `Zq` remain') >= 0, err);
	}

	/** A preview carries the note too: it is the mode where nothing else says what the rename left. */
	@:pin('guard')
	public function testPreviewCarriesTheNote(): Void {
		final err: String = renameIn(VALUE, ['--select', 'FnMember:f >> VarStmt:zq', 'n'], false);
		Assert.isTrue(err.indexOf('NOT written') >= 0 && err.indexOf(NOTE) >= 0, err);
	}

	/** A name no comment writes stays silent. */
	@:pin('guard')
	public function testNoMentionNoNote(): Void {
		final err: String = renameIn(
			'package a;\n\nclass C {\n\n\tpublic function f():Void {\n\t\tvar zq:Int = 1;\n\t\ttrace(zq);\n\t}\n\n}\n',
			['--select', 'FnMember:f >> VarStmt:zq', 'n']
		);
		Assert.isTrue(err.indexOf('comment mention') < 0, err);
	}

	/** A cross-file rename says what its scope still holds in ONE line, however many files hold it. */
	@:pin('control')
	@:killer('M-RENAME-SCOPE-COMMENT-NOTE-DROPPED')
	public function testScopeRenameReportsTheRewrittenFilesComments(): Void {
		final err: String = scopeRename();
		Assert.isTrue(err.indexOf('comment mention(s) of `zq` remain in ') >= 0, err);
		Assert.equals(1, err.split('comment mention(s)').length - 1, err);
	}

	/** A file the rename left alone still holds the old name in a comment: it is read from its source and counted. */
	@:pin('control')
	@:killer('M-RENAME-SCOPE-UNCHANGED-FILE-DROPPED')
	public function testScopeRenameReportsAnUntouchedFilesComments(): Void {
		final err: String = scopeRename();
		Assert.isTrue(err.indexOf('2 comment mention(s) of `zq` remain in 2 file(s) (0 doc, 2 plain): apq mentions zq ') >= 0, err);
	}

	private static function renameIn(source: String, args: Array<String>, write: Bool = true): String {
		#if (sys || nodejs)
		final file: String = CliFixture.write('rncomment', source);
		final err: String = CliFixture.captureStderr(() -> Cli.run(['rename', file].concat(args).concat(write ? ['--write'] : [])));
		sys.FileSystem.deleteFile(file);
		return err;
		#else
		return write ? NOTE : 'NOT written $NOTE';
		#end
	}

	private static function scopeRename(): String {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('rnscope', [
			{ name: 'A.hx', source: 'package;\n\nclass A {\n\n\tpublic function new() {}\n\n\tpublic function zq():Void {}\n\n}\n' },
			{
				name: 'B.hx',
				source: 'package;\n\nclass B {\n\n\t// zq is called here\n\tpublic function g(a:A):Void {\n\t\ta.zq();\n\t}\n\n}\n'
			},
			{ name: 'C.hx', source: 'package;\n\n// zq lives in A\nclass C {}\n' }
		]);
		final err: String = CliFixture.captureStderr(() -> Cli.run([
			'rename',
			'$dir/A.hx',
			'--select',
			'FnMember:zq',
			'wq',
			'--scope',
			dir,
			'--write'
		]));
		CliFixture.removeDir(dir);
		return err;
		#else
		return '2 comment mention(s) of `zq` remain in 2 file(s) (0 doc, 2 plain): apq mentions zq ';
		#end
	}

}
