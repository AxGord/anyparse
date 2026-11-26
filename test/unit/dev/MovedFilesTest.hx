package unit.dev;

import dev.MovedFiles;
import dev.SliceGate;
import devkit.Command;
import devkit.Summary;
import sys.io.File;

using StringTools;
using Lambda;

/** `dev.MovedFiles`: the files a writer or config change moves, and the declaration the gate demands for each. */
@:nullSafety(Strict)
final class MovedFilesTest extends Test {

	@:pin('control')
	@:killer('M-MOVED-FILES-ONE-SIDED')
	public function testAFileEitherEngineListsAlone(): Void {
		Assert.same(['b.hx', 'c.hx'], MovedFiles.between(['a.hx', 'b.hx'], ['a.hx', 'c.hx']));
		Assert.same([], MovedFiles.between(['a.hx'], ['a.hx']));
		Assert.same(['a.hx', 'b.hx'], MovedFiles.listed('b.hx\n\na.hx\n'));
	}

	@:pin('control')
	@:killer('M-MOVED-FILES-HUNK-ALL-REGIONS')
	public function testTheHunkShowsTheFirstDifferingRegionWithOneLineOfContext(): Void {
		Assert.same(['  b', '- c', '+ x', '+ y', '  d'], MovedFiles.hunk('a\nb\nc\nd\ne\n', 'a\nb\nx\ny\nd\ne\n'));
		Assert.same([], MovedFiles.hunk('a\nb\n', 'a\nb\n'));
		Assert.same(['  a', '- b', '  c'], MovedFiles.hunk('a\nb\nc\nd\ne\nf\ng\n', 'a\nc\nd\ne\nf\n'));
		final long: Array<String> = MovedFiles.hunk('a\n', [ for (i in 0...20) 'n$i' ].join('\n'));
		Assert.isTrue(long.length <= 9 && long[long.length - 1].startsWith('… '), long.join('|'));
	}

	@:pin('control')
	@:killer('M-MOVED-FILES-NO-REASON')
	public function testALineNamesFilesOnlyWithAReason(): Void {
		final text: String = [
			'- `src/a/**` — the new wrap rule',
			'src/b.hx -- one file',
			'src/c.hx - ok',
			'src/bare.hx',
			'src/empty.hx — ',
			'prose without a path'
		].join('\n');
		Assert.same(['src/a/**', 'src/b.hx', 'src/c.hx'], MovedFiles.named(text));
	}

	@:pin('control')
	@:killer('M-MOVED-FILES-COVERS-LITERAL')
	public function testANameCoversAFileAGlobOrADirectoryAbove(): Void {
		Assert.isTrue(MovedFiles.covers('src/a/B.hx', 'src/a/B.hx'));
		Assert.isTrue(MovedFiles.covers('src/a/**', 'src/a/b/C.hx'));
		Assert.isTrue(MovedFiles.covers('src/a', 'src/a/b/C.hx'));
		Assert.isFalse(MovedFiles.covers('src/a/B.hx', 'src/a/C.hx'));
		Assert.isFalse(MovedFiles.covers('src/b', 'src/a/B.hx'));
	}

	@:pin('control')
	@:killer('M-MOVED-FILES-VERDICT-BLIND')
	public function testTheVerdictIsRedUntilEveryMovedFileIsNamed(): Void {
		Assert.isTrue(MovedFiles.verdict([], []).match(Passed));
		Assert.isTrue(MovedFiles.verdict(['src/a.hx', 'src/b.hx'], ['src/a.hx']).match(Failed(_)));
		Assert.isTrue(MovedFiles.verdict(['src/a.hx', 'src/b.hx'], ['src/a.hx', 'src/*.hx']).match(Passed));
	}

	@:pin('control')
	@:killer('M-MOVED-FILES-REACHED-ANY')
	public function testOnlyWriterCodeAndTheRootFormatterConfigReachTheRow(): Void {
		Assert.isTrue(MovedFiles.reached(['src/anyparse/format/haxe/HxFormat.hx']));
		Assert.isTrue(MovedFiles.reached(['docs/a.md', 'hxformat.json']));
		Assert.isTrue(MovedFiles.reached(['src/anyparse/core/Renderer.hx']));
		Assert.isTrue(MovedFiles.reached(['src/anyparse/query/cli/command/FmtCommand.hx']));
		Assert.isFalse(MovedFiles.reached(['src/anyparse/query/cli/command/LintCommand.hx']));
		Assert.isFalse(MovedFiles.reached([
			'src/anyparse/check/Foo.hx',
			'test/fixtures/hxformat.json',
			'tools/src/dev/SliceGate.hx'
		]));
	}

	@:pin('control')
	@:killer('M-MOVED-FILES-READ-TIP-ONLY')
	public function testAReadingTakesBothEnginesListsAndTheHunkOfTheMovedFile(): Void {
		final reading: MovedReading = MovedFiles.read(fake, {
			label: 'sibling',
			baseDir: '.',
			tipDir: '.',
			targets: ['src']
		});
		Assert.same(['sibling/src/A.hx', 'sibling/src/Gone.hx'], reading.moved);
		Assert.same(['sibling/src/A.hx', '  x', '- y', '+ z', '  '], reading.hunks[0]);
	}

	@:pin('control')
	@:killer('M-MOVED-FILES-SETTLE-UNDECLARED')
	public function testTheRowListsTheMovedFilesAndPassesOnlyOnceTheDeclarationNamesThem(): Void {
		TempDir.with(dir -> {
			final readings: Array<MovedReading> = [{ moved: ['src/A.hx', 'sibling/src/B.hx'], hunks: [['src/A.hx', '@@ line 1']] }];
			final declared: String = dir.file(MovedFiles.DECLARATION);
			final list: String = dir.file(MovedFiles.LIST);
			final summary: Summary = new Summary();
			Assert.isTrue(MovedFiles.settle(readings, true, declared, list, summary).match(Failed(_)));
			Assert.equals('src/A.hx\nsibling/src/B.hx\n', File.getContent(list));
			Assert.equals('src/A.hx\n@@ line 1\n', File.getContent(dir.file(MovedFiles.HUNKS)));
			File.saveContent(declared, '- src/A.hx — a wrap change\n');
			Assert.isTrue(MovedFiles.settle(readings, true, declared, list, summary).match(Failed(_)), 'one file still unnamed');
			File.saveContent(declared, '- src/A.hx — a wrap change\n- sibling/** — the same change on the sibling\n');
			Assert.isTrue(MovedFiles.settle(readings, true, declared, list, summary).match(Passed));
		});
	}

	@:pin('control')
	@:killer('M-MOVED-FILES-DECLARATION-IN-LOGS')
	public function testTheDeclarationLiesBesideTheGateLogsDirectory(): Void {
		Assert.equals('/w-logs/${MovedFiles.DECLARATION}', MovedFiles.declaration('/w-logs/slice-gate/'));
	}

	@:pin('control')
	@:killer('M-MOVED-FILES-SKIP-GONE')
	public function testASliceThatTouchedNoWriterCodeIsNotRead(): Void {
		Assert.isTrue(MovedFiles.outcome('/nowhere', 'none', ['docs/a.md'], '/nowhere-logs', new Summary()).match(Skipped(_)));
	}

	@:pin('guard')
	public function testTheFmtRowIsInTheGate(): Void {
		Assert.isTrue(SliceGate.GATE_BRANCHES.exists(rows -> rows.contains('fmt')));
	}

	/** An engine that lists a file only the base knows and one only the tip knows, and formats the second differently per side. */
	private static function fake(side: MovedSide, dir: String, args: Array<String>): Command {
		final text: String = if (args.contains('--list'))
			(side == Base ? 'src/Gone.hx\nsrc/Same.hx\n' : 'src/A.hx\nsrc/Same.hx\n')
		else if (side == Base)
			'w\nx\ny\n'
		else
			'w\nx\nz\n';
		return Command.of(['printf', '%s', text]);
	}

}
