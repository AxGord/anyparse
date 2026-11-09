package unit.dev;

import dev.SquashCensus;
import devkit.Command;
import devkit.TempDir;
import haxe.Exception;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * `dev.SquashCensus`: the table of a report, and a census run over a small tree whose engine is faked by a command printing
 * what `fmt --list --one-pass` prints for the original copy and for the squashed one.
 */
@:nullSafety(Strict)
final class SquashCensusTest extends Test {

	@:pin('control')
	@:killer('M-SQUASH-CENSUS-TOTAL-BLIND')
	public function testTheTableAddsUpATotalRow(): Void {
		final report: SquashReport = {
			rows: [
				{
					dir: 'src',
					files: 3,
					squashed: 2,
					unparsed: 0,
					onePassOriginal: 0,
					onePassSquashed: 1,
					onePassNew: 1,
					differs: 2
				},
				{
					dir: 'test',
					files: 5,
					squashed: 4,
					unparsed: 1,
					onePassOriginal: 1,
					onePassSquashed: 1,
					onePassNew: 0,
					differs: 3
				}
			],
			newOnePass: [],
			differs: []
		};
		final lines: Array<String> = SquashCensus.render(report).split('\n');
		Assert.same([
			'tree',
			'files',
			'squashed',
			'unparsed',
			'1pass',
			'1pass-sq',
			'1pass-new',
			'differs'
		], cells(lines[0]));
		Assert.same(['src', '3', '2', '0', '0', '1', '1', '2'], cells(lines[1]));
		Assert.same(['test', '5', '4', '1', '1', '1', '0', '3'], cells(lines[2]));
		Assert.same(['total', '8', '6', '1', '1', '2', '1', '5'], cells(lines[3]));
	}

	@:pin('control')
	@:killer('M-SQUASH-CENSUS-NEW-COUNTS-ALL')
	public function testAFileAlreadyNeedingASecondRewriteIsNotCountedAsBroken(): Void {
		final report: SquashReport = censusOfThree();
		Assert.equals(1, report.rows[0].onePassOriginal);
		Assert.equals(2, report.rows[0].onePassSquashed);
		Assert.equals(1, report.rows[0].onePassNew);
		Assert.same(['src/A.hx'], report.newOnePass);
	}

	@:pin('control')
	@:killer('M-SQUASH-CENSUS-UNPARSED-COUNTED')
	public function testAFileTheGrammarCannotFormatTakesNoPartInTheColumns(): Void {
		final report: SquashReport = censusOfThree();
		Assert.equals(3, report.rows[0].files);
		Assert.equals(3, report.rows[0].squashed);
		Assert.equals(1, report.rows[0].unparsed);
		Assert.same(['src/A.hx', 'src/B.hx'], report.differs);
	}

	@:pin('control')
	@:killer('M-SQUASH-CENSUS-DIFFERS-BLIND')
	public function testTheFormattedSquashIsComparedWithTheFormattedOriginal(): Void {
		Assert.equals(2, censusOfThree().rows[0].differs);
	}

	@:pin('control')
	@:killer('M-SQUASH-CENSUS-CONFIG-LOST')
	public function testTheCopiesCarryTheTreesFormatterConfig(): Void {
		TempDir.with(repo -> TempDir.with(scratch -> {
			put(repo.file('hxformat.json'), '{}');
			put(repo.file('src/A.hx'), 'class A {\n}\n');
			Assert.equals(1, SquashCensus.census(fakeEngine, repo.path, ['src'], scratch.path).rows.length);
			Assert.isTrue(FileSystem.exists(scratch.file('original/hxformat.json')));
			Assert.isTrue(FileSystem.exists(scratch.file('squashed/hxformat.json')));
		}));
	}

	@:pin('control')
	@:killer('M-SQUASH-CENSUS-LIST-STATUS-UNCHECKED')
	public function testAListThatNeverStartedRefusesTheCensus(): Void {
		Assert.isTrue(refuses(engine(127, true, 0)));
		Assert.isFalse(refuses(engine(1, true, 0)));
	}

	@:pin('control')
	@:killer('M-SQUASH-CENSUS-LIST-SUMMARY-UNCHECKED')
	public function testAListThatCrashedBeforeItsSummaryRefusesTheCensus(): Void {
		Assert.isTrue(refuses(engine(1, false, 0)));
	}

	@:pin('control')
	@:killer('M-SQUASH-CENSUS-WRITE-STATUS-UNCHECKED')
	public function testAWriteThatNeverRanRefusesTheCensus(): Void {
		Assert.isTrue(refuses(engine(0, true, 127)));
		Assert.isFalse(refuses(engine(0, true, 1)));
	}

	@:pin('control')
	@:killer('M-SQUASH-CENSUS-MISSING-DIR-UNCHECKED')
	public function testATreeThatDoesNotExistIsNamedInTheRefusal(): Void {
		TempDir.with(repo -> TempDir.with(scratch -> {
			try {
				final report: SquashReport = SquashCensus.census(engine(0, true, 0), repo.path, ['nowhere'], scratch.path);
				Assert.fail('a census over a missing tree must throw, read ${report.rows.length} row(s)');
			} catch (exception: Exception) {
				Assert.stringContains('no such directory: nowhere', exception.message);
			}
		}));
	}

	@:pin('control')
	@:killer('M-SQUASH-CENSUS-NESTED-CONFIG-LOST')
	public function testAConfigInsideTheTreeReachesBothCopies(): Void {
		TempDir.with(repo -> TempDir.with(scratch -> {
			put(repo.file('src/sub/hxformat.json'), '{}');
			put(repo.file('src/sub/S.hx'), 'class S {\n}\n');
			Assert.equals(1, SquashCensus.census(fakeEngine, repo.path, ['src'], scratch.path).rows.length);
			Assert.isTrue(FileSystem.exists(scratch.file('original/src/sub/hxformat.json')));
			Assert.isTrue(FileSystem.exists(scratch.file('squashed/src/sub/hxformat.json')));
		}));
	}

	/**
	 * The engine of a census over `A`, `B`, `C`: the originals settle only on a second rewrite for `B` and cannot be formatted for
	 * `C`; the squashed copies need a second rewrite for `A` and `B`; `--write` changes nothing.
	 */
	private static function fakeEngine(args: Array<String>): Command {
		if (args.indexOf('--one-pass') < 0) return Command.of(['true']);
		final target: String = args[args.length - 1];
		final root: String = Path.directory(target);
		final twice: String = ': the writer needed 2 rewrites to reach its fixed point';
		final said: Array<String> = [
			'apq fmt: $root/src/C.hx: unexpected input',
			'apq fmt: $root/src/B.hx$twice',
			'apq fmt --list: 3 file(s)'
		];
		if (target.indexOf('/squashed/') >= 0) said.push('apq fmt: $root/src/A.hx$twice');
		return Command.of(['sh', '-c', 'printf "%s\\n" "$$1" >&2', 'sh', said.join('\n')]);
	}

	private static function put(path: String, text: String): Void {
		if (!FileSystem.exists(Path.directory(path))) FileSystem.createDirectory(Path.directory(path));
		File.saveContent(path, text);
	}

	private static function cells(line: String): Array<String> {
		return ~/\s+/g.split(line.trim());
	}

	private static function censusOfThree(): SquashReport {
		return TempDir.with(repo -> TempDir.with(scratch -> {
			for (name in ['A', 'B', 'C']) put(repo.file('src/$name.hx'), 'class $name {\n\tvar x: Int;\n\tvar y: Int;\n}\n');
			return SquashCensus.census(fakeEngine, repo.path, ['src'], scratch.path);
		}));
	}

	/**
	 * An engine whose `--list` exits `listStatus` (printing its summary
	 * line when `summarised`) and whose `--write` exits `writeStatus`.
	 */
	private static function engine(listStatus: Int, summarised: Bool, writeStatus: Int): Array<String> -> Command {
		return args -> {
			if (args.indexOf('--one-pass') < 0) return Command.of(['sh', '-c', 'exit $$1', 'sh', '$writeStatus']);
			final summary: String = summarised ? 'apq fmt --list: 0 file(s)' : '';
			return Command.of(['sh', '-c', 'printf "%s\\n" "$$1" >&2; exit $$2', 'sh', summary, '$listStatus']);
		};
	}

	/** Whether a census over one file with `run` throws. */
	private static function refuses(run: Array<String> -> Command): Bool {
		return TempDir.with(repo -> TempDir.with(scratch -> {
			put(repo.file('src/A.hx'), 'class A {\n}\n');
			try {
				final report: SquashReport = SquashCensus.census(run, repo.path, ['src'], scratch.path);
				return report.rows.length == 0;
			} catch (exception: Exception) {
				return true;
			}
		}));
	}

}
