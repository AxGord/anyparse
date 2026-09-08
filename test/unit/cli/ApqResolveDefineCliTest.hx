package unit.cli;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end
import anyparse.query.Cli;
import utest.Assert;
import utest.Test;

/**
 * `apq resolve-define <DEFINE> <scope>` — the write-twin of `apq cond`, end to end.
 *
 * What is pinned here is the SURFACE: which stream each answer goes to, the wording of the
 * summary, and the report line for a region the op refuses to fold. The decision underneath —
 * which branch survives, what the fold produces byte for byte, and every refusal — is pinned at
 * the API in `unit.query.CondResolveTest`.
 *
 * The stream split is the part worth a fixture: the rewritten source is the PAYLOAD and goes to
 * stdout, while the `NOT written` note, the per-region report and the summary are DIAGNOSTICS and
 * go to stderr — so a preview can be redirected into a file and diffed without a single line of
 * commentary in it.
 */
@:nullSafety(Strict)
class ApqResolveDefineCliTest extends Test {

	/** A statement region with an `#else`: the polarity picks `a();` or `b();`. */
	private static final BRANCHED: String = fn('#if X\n\t\ta();\n\t\t#else\n\t\tb();\n\t\t#end');

	/** A region a second flag also decides, so the op leaves it and reports it. */
	private static final COMPOUND: String = fn('#if (X && other)\n\t\ta();\n\t\t#end');

	/** A file with no region at all — what the walk must skip without reporting anything. */
	private static final PLAIN: String = fn('a();');

	/** One file, no `--write`: the rewritten source on stdout and nothing but diagnostics on stderr. */
	public function testASingleFilePreviewsOnStdoutAndSaysSoOnStderr(): Void {
		#if nodejs
		final f: String = CliFixture.write('resolve_preview', BRANCHED);
		var exit: Int = -1;
		var printed: String = '';
		final noted: String = CliFixture.captureStderr(() ->
			printed = CliFixture.captureStdout(() -> exit = Cli.run(['resolve-define', 'X', f]))
		);
		Assert.equals(0, exit);
		Assert.equals(fn('a();'), printed, 'stdout is the rewritten source and nothing else');
		Assert.isTrue(noted.indexOf('NOT written') >= 0, 'the preview says it wrote nothing: $noted');
		Assert.isTrue(noted.indexOf('would rewrite 1 file(s), 1 region(s)') >= 0, 'the summary is future tense: $noted');
		Assert.equals(BRANCHED, File.getContent(f), 'a preview leaves the file byte-identical');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A DIRECTORY prints the paths that would change, one per line, and nothing else — the walk
	 * default `comment-rewrite` and `fmt` share. A file the define never reaches contributes no
	 * line and no diagnostic.
	 */
	public function testADirectoryListsThePathsThatWouldChange(): Void {
		#if nodejs
		final dir: String = CliFixture.writeDir('resolve_dir', [
			{ name: 'A.hx', source: BRANCHED },
			{ name: 'B.hx', source: PLAIN }
		]);
		var printed: String = '';
		final noted: String = CliFixture.captureStderr(
			() -> printed = CliFixture.captureStdout(() -> Assert.equals(0, Cli.run(['resolve-define', 'X', dir])))
		);
		Assert.equals('$dir/A.hx\n', printed);
		Assert.isTrue(noted.indexOf('would rewrite 1 file(s), 1 region(s)') >= 0, noted);
		CliFixture.removeDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `--write` rewrites in place and reports it in the past tense. */
	public function testWriteRewritesInPlaceAndSaysSo(): Void {
		#if nodejs
		final f: String = CliFixture.write('resolve_write', BRANCHED);
		final noted: String = CliFixture.captureStderr(() -> Assert.equals(0, Cli.run(['resolve-define', 'X', f, '--write'])));
		Assert.equals(fn('a();'), File.getContent(f));
		Assert.isTrue(noted.indexOf('rewrote 1 file(s), 1 region(s)') >= 0, noted);
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * `--undefined` states the opposite hypothesis, and the same file folds to the other branch.
	 *
	 * The pair with the test above is what makes either one discriminate: an implementation that
	 * ignored the flag and always kept the first live branch would pass one of them.
	 */
	public function testUndefinedFoldsTheSameFileToTheOtherBranch(): Void {
		#if nodejs
		final f: String = CliFixture.write('resolve_undefined', BRANCHED);
		CliFixture.captureStderr(() -> Assert.equals(0, Cli.run(['resolve-define', 'X', f, '--write', '--undefined'])));
		Assert.equals(fn('b();'), File.getContent(f));
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A region the query cannot decide is reported on stderr by POSITION with its own directive
	 * text, and counted in the summary — the residue the op deliberately does not touch, which is
	 * exactly the list a caller has to go and read by hand.
	 */
	public function testAnUndecidedRegionIsReportedByPosition(): Void {
		#if nodejs
		final f: String = CliFixture.write('resolve_maybe', COMPOUND);
		var printed: String = '';
		final noted: String = CliFixture.captureStderr(
			() -> printed = CliFixture.captureStdout(() -> Assert.equals(0, Cli.run(['resolve-define', 'X', f, '--list'])))
		);
		Assert.equals('', printed, 'nothing would change, so nothing is listed');
		Assert.isTrue(
			noted.indexOf('$f:4:3: #if (X && other) - left as is: a flag outside the query decides') >= 0,
			'the region is named where the reader has to open it: $noted'
		);
		Assert.isTrue(noted.indexOf('1 region(s) left undecided') >= 0, noted);
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A run that matched NOTHING says so, rather than reporting `0 region(s)` — which reads as
	 * "they were already folded", the one thing it never means.
	 */
	public function testAWalkThatMatchedNothingSaysSo(): Void {
		#if nodejs
		final f: String = CliFixture.write('resolve_nothing', PLAIN);
		final noted: String = CliFixture.captureStderr(
			() -> CliFixture.captureStdout(() -> Assert.equals(0, Cli.run(['resolve-define', 'X', f, '--list'])))
		);
		Assert.isTrue(noted.indexOf('no #if region in 1 file(s) mentions "X"') >= 0, noted);
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `-h` prints the usage page and exits 0; a missing argument is a usage error. */
	public function testHelpExitsZeroAndAMissingArgumentIsAUsageError(): Void {
		#if nodejs
		CliFixture.captureStderr(() -> CliFixture.captureStdout(() -> {
			Assert.equals(0, Cli.run(['resolve-define', '-h']));
			Assert.equals(2, Cli.run(['resolve-define']));
			Assert.equals(2, Cli.run(['resolve-define', 'X']));
			Assert.equals(2, Cli.run(['resolve-define', 'X', '--nope']));
		}));
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** `body` as the one statement run of a canonical single-method class. */
	private static inline function fn(body: String): String {
		return 'class C {\n\n\tfunction f():Void {\n\t\t$body\n\t}\n\n}\n';
	}

}
