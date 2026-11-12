package unit.cli;

import sys.FileSystem;
import unit.cli.CliFixture.CliRun;
#if nodejs
import sys.io.File;
#end

/**
 * `apq lint --changed-since <rev>` end to end over a scratch git repository: each file's findings narrow to the lines the
 * working tree added or changed against the revision, in the report and under `--fix`, so a fix run behind a slice's edits
 * leaves the findings that were already standing on lines it never touched.
 */
@:nullSafety(Strict)
class LintChangedSinceCliTest extends Test {

	private static final FOLDABLE_A: String = "'aaa' + 'bbb'";
	private static final FOLDABLE_B: String = "'ccc' + 'ddd'";
	private static final FOLDABLE_B_EDITED: String = "'ccc' + 'dde'";

	/** A standing finding on a line the edit never touched is no fix's business, in a touched file or an untouched one. */
	@:pin('control')
	@:killer('M-CHANGED-SINCE-INERT')
	public function testAStandingFindingOnAnUntouchedLineIsLeftAlone(): Void {
		#if nodejs
		final root: String = repo();
		final run: CliRun = fixRun(root, ['A.hx', 'C.hx']);
		final touched: String = File.getContent('$root/A.hx');
		final untouched: String = File.getContent('$root/C.hx');
		CliFixture.removeDir(root);
		Assert.equals(0, run.code);
		Assert.isTrue(touched.indexOf(FOLDABLE_A) >= 0, 'the standing finding above the edit is untouched');
		Assert.equals(source(FOLDABLE_A, FOLDABLE_B), untouched, 'a file the revision holds unchanged is not written');
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

	/** The control of the one above: a run that fixed nothing at all would pass it too. */
	@:pin('control')
	@:killer('M-CHANGED-SINCE-CHANGED-LINES-DROPPED')
	public function testAFindingOnAChangedLineIsFixed(): Void {
		#if nodejs
		final root: String = repo();
		final run: CliRun = fixRun(root, ['A.hx', 'C.hx']);
		final touched: String = File.getContent('$root/A.hx');
		CliFixture.removeDir(root);
		Assert.equals(0, run.code);
		Assert.isTrue(touched.indexOf(FOLDABLE_B_EDITED) < 0, 'the edited concatenation was folded');
		Assert.isTrue(touched.indexOf("'cccdde'") >= 0, touched);
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

	/** Every line of a file the revision does not hold is new. */
	@:pin('control')
	@:killer('M-CHANGED-SINCE-NEW-FILE-NARROWED')
	public function testAFileNewAgainstTheRevisionIsFixedWhole(): Void {
		#if nodejs
		final root: String = repo();
		File.saveContent('$root/B.hx', source(FOLDABLE_A, FOLDABLE_B));
		final run: CliRun = fixRun(root, ['B.hx']);
		final created: String = File.getContent('$root/B.hx');
		CliFixture.removeDir(root);
		Assert.equals(0, run.code);
		Assert.isTrue(created.indexOf(FOLDABLE_A) < 0 && created.indexOf(FOLDABLE_B) < 0, created);
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

	/** A renamed file is compared with the file it was, so only the lines it changed since are in its window. */
	public function testARenamedFileIsComparedWithItsEarlierPath(): Void {
		#if nodejs
		final root: String = repo();
		CliFixture.git(root, ['mv', 'A.hx', 'D.hx']);
		final run: CliRun = fixRun(root, ['D.hx']);
		final moved: String = File.getContent('$root/D.hx');
		CliFixture.removeDir(root);
		Assert.equals(0, run.code);
		Assert.isTrue(moved.indexOf(FOLDABLE_A) >= 0, 'the standing finding survives the rename');
		Assert.isTrue(moved.indexOf("'cccdde'") >= 0, moved);
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

	/** The narrowing holds in the report too: the exit code gates on the changed lines only. */
	@:pin('control')
	@:killer('M-CHANGED-SINCE-INERT')
	public function testTheReportNarrowsToTheChangedLines(): Void {
		#if nodejs
		final root: String = repo();
		final withEdit: CliRun = reportRun(root, 'A.hx');
		File.saveContent('$root/A.hx', source(FOLDABLE_A, FOLDABLE_B).split('trace(b);').join('trace(b);\n\t\ttrace(a);'));
		final withoutFinding: CliRun = reportRun(root, 'A.hx');
		CliFixture.removeDir(root);
		Assert.equals(1, withEdit.code, 'the edited line holds a finding');
		Assert.equals(0, withoutFinding.code, 'the edit left the findings it did not touch out of the report');
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

	@:pin('control')
	@:killer('M-CHANGED-SINCE-RANGE-ACCEPTED')
	public function testTwoNarrowingsAndAnUnknownRevisionAreUsageErrors(): Void {
		#if nodejs
		final root: String = repo();
		final both: CliRun = CliFixture.runIn(root, ['lint', 'A.hx', '--no-oracle', '--range', '1:9', '--changed-since', 'HEAD']);
		final unknown: CliRun = CliFixture.runIn(root, ['lint', 'A.hx', '--no-oracle', '--changed-since', 'no-such-revision']);
		final range: CliRun = CliFixture.runIn(root, ['lint', 'A.hx', '--no-oracle', '--fix', '--changed-since', 'HEAD..HEAD']);
		final option: CliRun = CliFixture.runIn(root, ['lint', 'A.hx', '--no-oracle', '--changed-since', '--fix']);
		CliFixture.removeDir(root);
		Assert.equals(2, both.code);
		Assert.equals(2, unknown.code);
		Assert.equals(2, option.code);
		Assert.equals(2, range.code, 'a range names no single base: every file would read as new');
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

	/** The same file under a `./` spelling is still the renamed one, not a new file. */
	public function testARenamedFileUnderADotSlashSpellingIsComparedWithItsEarlierPath(): Void {
		#if nodejs
		final root: String = repo();
		CliFixture.git(root, ['mv', 'A.hx', 'D.hx']);
		final run: CliRun = fixRun(root, ['./D.hx']);
		final moved: String = File.getContent('$root/D.hx');
		CliFixture.removeDir(root);
		Assert.equals(0, run.code);
		Assert.isTrue(moved.indexOf(FOLDABLE_A) >= 0, 'the standing finding survives the rename');
		Assert.isTrue(moved.indexOf("'cccdde'") >= 0, moved);
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

	/** A path above the working directory is compared in the repository's key space, renames included. */
	public function testARenamedFileAboveTheWorkingDirectoryIsComparedWithItsEarlierPath(): Void {
		#if nodejs
		final root: String = repo();
		CliFixture.git(root, ['mv', 'A.hx', 'D.hx']);
		FileSystem.createDirectory('$root/sub');
		final run: CliRun = CliFixture.runIn('$root/sub', [
			'lint',
			'../D.hx',
			'--no-oracle',
			'--fix',
			'--rule',
			'fold-adjacent-string-literals',
			'--changed-since',
			'HEAD'
		]);
		final moved: String = File.getContent('$root/D.hx');
		CliFixture.removeDir(root);
		Assert.equals(0, run.code);
		Assert.isTrue(moved.indexOf(FOLDABLE_A) >= 0, 'the standing finding survives the rename');
		Assert.isTrue(moved.indexOf("'cccdde'") >= 0, moved);
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

	/** A file outside the repository has no earlier text to compare with: it is left untouched, never read as new. */
	public function testAFileOutsideTheRepositoryIsLeftUntouched(): Void {
		#if nodejs
		final root: String = repo();
		final outside: String = CliFixture.writeTree(
			'lint_changed_since_outside',
			[{ name: 'O.hx', source: source(FOLDABLE_A, FOLDABLE_B) }]
		);
		var run: CliRun = { code: -1, out: '' };
		final said: String = CliFixture.captureStderr(() -> run = fixRun(root, ['$outside/O.hx']));
		final after: String = File.getContent('$outside/O.hx');
		CliFixture.removeDir(root);
		CliFixture.removeDir(outside);
		Assert.equals(0, run.code);
		Assert.equals(source(FOLDABLE_A, FOLDABLE_B), after);
		Assert.isTrue(said.indexOf('is outside the git repository') >= 0, said);
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

	/** A diff past the line differ's budget gives the file no window at all: its standing finding stays and the run says why. */
	@:pin('control')
	@:killer('M-CHANGED-SINCE-OVERFLOW-WHOLE')
	public function testAFileWhoseDiffOutgrowsTheLineDifferIsLeftUntouched(): Void {
		#if nodejs
		final root: String = repo();
		File.saveContent('$root/E.hx', bigSource('trace(0)'));
		CliFixture.git(root, ['add', 'E.hx']);
		CliFixture.git(root, ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'big', 'E.hx']);
		File.saveContent('$root/E.hx', bigSource('trace(1)'));
		var run: CliRun = { code: -1, out: '' };
		final said: String = CliFixture.captureStderr(() -> run = fixRun(root, ['E.hx']));
		final after: String = File.getContent('$root/E.hx');
		CliFixture.removeDir(root);
		Assert.equals(0, run.code);
		Assert.equals(bigSource('trace(1)'), after, 'no fix reached the standing finding');
		Assert.isTrue(said.indexOf('than the line diff follows') >= 0, said);
		#else
		Assert.pass('a git child process needs the nodejs target');
		#end
	}

	/** The standing foldable on line 6, then more statements than the line differ follows, each spelled `line`. */
	private static function bigSource(line: String): String {
		return 'package pkg;\n\nclass A {\n\n\tpublic static function main():Void {\n\t\tfinal a:String = $FOLDABLE_A;\n\t\ttrace(a);\n'
			+ [for (_ in 0...2100) '\t\t$line;\n'].join('')
			+ '\t}\n\n}\n';
	}

	#if nodejs
	/** Canonical module (in the default layout of a directory with no `hxformat.json`) with the two concatenations on lines 6 and 8. */
	private static function source(first: String, second: String): String {
		return 'package pkg;\n\nclass A {\n\n\tpublic static function main():Void {\n\t\tfinal a:String = $first;\n\t\ttrace(a);\n'
			+ '\t\tfinal b:String = $second;\n\t\ttrace(b);\n\t}\n\n}\n';
	}

	/** A repository holding A.hx and C.hx at their standing text, with A.hx's second concatenation then edited in the working tree. */
	private static function repo(): String {
		final root: String = CliFixture.writeTree('lint_changed_since', [
			{ name: 'A.hx', source: source(FOLDABLE_A, FOLDABLE_B) },
			{ name: 'C.hx', source: source(FOLDABLE_A, FOLDABLE_B) }
		]);
		CliFixture.git(root, ['init', '-q']);
		CliFixture.git(root, ['add', '-A']);
		CliFixture.git(root, ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'base']);
		File.saveContent('$root/A.hx', source(FOLDABLE_A, FOLDABLE_B_EDITED));
		return root;
	}

	private static function fixRun(root: String, files: Array<String>): CliRun {
		return CliFixture.runIn(
			root,
			['lint'].concat(files).concat([
				'--no-oracle',
				'--fix',
				'--rule',
				'fold-adjacent-string-literals',
				'--changed-since',
				'HEAD'
			])
		);
	}

	private static function reportRun(root: String, file: String): CliRun {
		return CliFixture.runIn(root, [
			'lint',
			file,
			'--no-oracle',
			'--rule',
			'fold-adjacent-string-literals',
			'--fail-on',
			'info',
			'--changed-since',
			'HEAD'
		]);
	}
	#end

}
