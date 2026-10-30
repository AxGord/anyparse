package unit.dev;

import dev.SliceMeasure;
import dev.SliceStats;
import devkit.Cmd.cmd;
import devkit.TempDir;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

/**
 * `dev slice-stats`: which commits of a history land a slice and what each record says, the queue fields beside the trailers,
 * the line and module counts, the week a landing falls in and the weekly sums, the member call edges of a tree and the share
 * of a slice's new edges landing in modules its base held, and the reading of a scratch repository end to end.
 */
@:nullSafety(Strict)
final class SliceStatsTest extends Test {

	/** 2026-10-29 12:00 UTC, a Thursday. */
	private static inline final THURSDAY: Float = 1793275200;

	private static inline final HOUR: Float = 3600;
	private static inline final DAY: Float = 86400;

	/** A member that calls another module's member from a lambda, and itself. */
	private static inline final A_SOURCE: String = 'package p;\nclass A {\n\tpublic static function f() {\n'
		+ '\t\t[1].map(x -> B.g(x));\n\t\tf();\n\t}\n}\n';

	/** A member that calls a member of its own type. */
	private static inline final B_SOURCE: String = 'package p;\nclass B {\n\tpublic static function g(x: Int): Int {\n'
		+ '\t\treturn h();\n\t}\n\tstatic function h(): Int return 1;\n}\n';

	public function testAMergeOfASliceBranchLandsItsSlice(): Void {
		final landing: Null<Landing> = SliceStats.landingOf(['m', 'p1 p2', '100', 'Merge batch/hxqb-TOOLS-5: tools', '', '', '']);
		Assert.equals('TOOLS-5', landing?.id);
		Assert.equals('p1', landing?.base);
		Assert.equals('p1..p2', landing?.branch);
		Assert.equals(100.0, landing?.landed);
	}

	public function testEveryMergeSpellingOfASliceBranchIsRead(): Void {
		Assert.equals('S212', SliceStats.landingOf(['m', 'a b', '1', 'Merge branch \'batch/hxqb-S212\'', '', '', ''])?.id);
		Assert.equals('S213', SliceStats.landingOf(['m', 'a b', '1', 'merge batch/hxqb-S213: check', '', '', ''])?.id);
		Assert.equals('B1', SliceStats.landingOf(['m', 'a b', '1', 'Merge batch/hxqb-B1 (config + gate): x', '', '', ''])?.id);
	}

	public function testALinearCommitLandsTheSliceItsTrailerNames(): Void {
		final landing: Null<Landing> = SliceStats.landingOf(['c', 'p', '5', 'a change', 'LAND-2', '3', '120000']);
		Assert.equals('LAND-2', landing?.id);
		Assert.equals('p..c', landing?.branch);
		Assert.equals(3, landing?.rounds);
		Assert.equals(120000, landing?.tokens);
	}

	public function testACommitThatLandsNoSliceIsNone(): Void {
		Assert.isNull(SliceStats.landingOf(['c', 'p', '5', 'a change', '', '', '']));
		Assert.isNull(SliceStats.landingOf(['m', 'a b', '5', 'Merge feat/infra-N55: x', '', '', '']));
		Assert.isNull(SliceStats.landingOf(['m', 'a b', '5', 'a merge', 'S1', '', '']));
	}

	public function testTheLogIsReadOldestFirst(): Void {
		final out: String = 'c2\x1fc1\x1f20\x1fsecond\x1fS2\x1f\x1f\x1e\nc1\x1fc0\x1f10\x1ffirst\x1fS1\x1f\x1f\x1e\n';
		Assert.same(['S1', 'S2'], [for (l in SliceStats.parseLog(out)) l.id]);
	}

	public function testTheQueueFillsWhatTheTrailersLack(): Void {
		final queue: String =
			'- [x] S9 | other | review-rounds: 7 | tokens: 9\n- [x] S1 | touches: x | review-rounds: 2 | tokens: 150_000 | text\n';
		final bare: Landing = SliceStats.withQueue(landing('S1', null, null), queue);
		Assert.equals(2, bare.rounds);
		Assert.equals(150000, bare.tokens);
		final marked: Landing = SliceStats.withQueue(landing('S1', 4, null), queue);
		Assert.equals(4, marked.rounds);
		Assert.equals(150000, marked.tokens);
		Assert.isNull(SliceStats.withQueue(landing('S3', null, null), queue).rounds);
	}

	public function testLinesAreCountedUnderSrcAndTest(): Void {
		final counts: LineCounts = SliceStats.lineCounts([
			'3\t1\tsrc/a/A.hx',
			'2\t0\tsrc/b.json',
			'5\t4\ttest/unit/ATest.hx',
			'9\t9\tdocs/x.md',
			'-\t-\tsrc/bin.png'
		]);
		Assert.same({ added: 5, deleted: 1 }, counts.src);
		Assert.same({ added: 5, deleted: 4 }, counts.test);
	}

	public function testAModuleIsNewOrEditedAndARenameIsAnEdit(): Void {
		final counts: ModuleCounts = SliceStats.moduleCounts([
			'A\tsrc/New.hx',
			'M\tsrc/Old.hx',
			'R087\tsrc/From.hx\tsrc/To.hx',
			'D\tsrc/Gone.hx',
			'A\tdocs/x.md'
		]);
		Assert.same({ fresh: 1, edited: 2 }, counts);
	}

	public function testAWeekStartsOnItsMonday(): Void {
		Assert.equals('2026-10-26', SliceStats.weekOf(THURSDAY));
		Assert.equals('2026-10-26', SliceStats.weekOf(THURSDAY - 3 * DAY));
		Assert.equals('2026-10-19', SliceStats.weekOf(THURSDAY - 4 * DAY));
		Assert.equals('2026-10-26', SliceStats.weekOf(THURSDAY + 3 * DAY + 11 * HOUR));
	}

	public function testAWeekSumsItsSlices(): Void {
		final weeks: Array<WeekRow> = SliceStats.trend([
			row(THURSDAY - 4 * DAY, 9, 1, 100, { added: 1, existing: 1, fresh: 0 }, 2),
			row(THURSDAY, 1, 1, 200, { added: 4, existing: 2, fresh: 1 }, -1),
			row(THURSDAY + DAY, 2, 3, null, { added: 1, existing: 0, fresh: 1 }, 0),
			row(THURSDAY + 2 * DAY, 6, null, 50, null, null)
		]);
		Assert.same(['2026-10-19', '2026-10-26'], [for (w in weeks) w.week]);
		Assert.equals(3, weeks[1].slices);
		Assert.equals(2.0, weeks[1].hours);
		Assert.equals(2.0, weeks[1].rounds);
		Assert.equals(250, weeks[1].tokens);
		Assert.same({ added: 5, existing: 2, fresh: 2 }, weeks[1].edges);
		Assert.equals(-1, weeks[1].clones);
		Assert.equals(30, weeks[1].src);
		final table: String = SliceStats.trendTable(weeks, true, true);
		Assert.equals('2026-10-26       3       2.0     2.0      0k     30       3         3/6        5 50%   -1', table.split('\n')[2]);
	}

	public function testANewEdgeIsCountedByWhereItLands(): Void {
		final before: EdgeReading = { files: ['src/A.hx', 'src/B.hx'], edges: ['a.A.f -> a.B.g' => 'src/B.hx'] };
		final after: EdgeReading = {
			files: ['src/A.hx', 'src/B.hx', 'src/C.hx'],
			edges: [
				'a.A.f -> a.B.g' => 'src/B.hx',
				'a.A.f -> a.B.h' => 'src/B.hx',
				'a.A.f -> a.C.k' => 'src/C.hx',
				'a.C.k -> Std.string' => ''
			]
		};
		Assert.same({ added: 3, existing: 1, fresh: 1 }, SliceMeasure.share(before, after));
	}

	public function testTheEdgesOfATreeAreBetweenMembersAndNameTheirTargetsFile(): Void {
		TempDir.with(dir -> {
			FileSystem.createDirectory(dir.file('src/p'));
			File.saveContent(dir.file('src/p/A.hx'), A_SOURCE);
			File.saveContent(dir.file('src/p/B.hx'), B_SOURCE);
			final reading: EdgeReading = SliceMeasure.edgesOf(dir.path, ['src']);
			final files: Array<String> = reading.files.copy();
			files.sort(Reflect.compare);
			Assert.same(['src/p/A.hx', 'src/p/B.hx'], files);
			Assert.equals('src/p/B.hx', reading.edges['p.A.f -> p.B.g']);
			Assert.equals('src/p/B.hx', reading.edges['p.B.g -> p.B.h']);
			Assert.isFalse(reading.edges.exists('p.A.f -> p.A.f'), [for (k in reading.edges.keys()) k].join(', '));
		});
	}

	public function testAScratchHistoryIsReadEndToEnd(): Void {
		TempDir.with(dir -> {
			final repo: String = dir.file('repo');
			FileSystem.createDirectory(repo);
			git(repo, ['init', '-q', '-b', 'main'], THURSDAY);
			FileSystem.createDirectory('$repo/src');
			File.saveContent('$repo/src/A.hx', 'class A {}\n');
			git(repo, ['add', '.'], THURSDAY);
			git(repo, ['commit', '-q', '-m', 'base'], THURSDAY);
			git(repo, ['checkout', '-q', '-b', 'batch/hxqb-S1'], THURSDAY);
			File.saveContent('$repo/src/B.hx', 'class B {}\n');
			git(repo, ['add', '.'], THURSDAY);
			git(repo, ['commit', '-q', '-m', 'one'], THURSDAY + HOUR);
			File.saveContent('$repo/src/A.hx', 'class A {\n}\n');
			git(repo, ['commit', '-q', '-am', 'two'], THURSDAY + 2 * HOUR);
			git(repo, ['checkout', '-q', 'main'], THURSDAY);
			git(repo, [
				'merge',
				'-q',
				'--no-ff',
				'-m',
				'Merge batch/hxqb-S1: one and two',
				'batch/hxqb-S1'
			], THURSDAY + 4 * HOUR);
			File.saveContent('$repo/src/A.hx', 'class A {\n\tvar x: Int;\n}\n');
			git(
				repo, ['commit', '-q', '-am', 'three\n\nSlice: S2\nReview-Rounds: 2\nTokens: 5000'],
				THURSDAY + 5 * HOUR, THURSDAY + 6 * HOUR
			);
			final found: Array<Landing> = SliceStats.landings(repo, 'HEAD', null);
			Assert.same(['S1', 'S2'], [for (l in found) l.id]);
			Assert.equals(3.0, (found[0].landed - found[0].started) / HOUR);
			Assert.equals(1.0, (found[1].landed - found[1].started) / HOUR);
			Assert.equals(2, found[1].rounds);
			Assert.equals(5000, found[1].tokens);
			Assert.isNull(found[0].rounds);
		});
	}

	private static function landing(id: String, rounds: Null<Int>, tokens: Null<Int>): Landing {
		return {
			id: id,
			commit: 'c',
			base: 'b',
			branch: 'b..c',
			landed: THURSDAY,
			started: THURSDAY,
			rounds: rounds,
			tokens: tokens
		};
	}

	private static function row(
		landed: Float, hours: Float, rounds: Null<Int>, tokens: Null<Int>, edges: Null<EdgeShare>, clones: Null<Int>
	): SliceRow {
		final l: Landing = landing('S', rounds, tokens);
		l.landed = landed;
		return {
			landing: l,
			hours: hours,
			src: { added: 10, deleted: 0 },
			test: { added: 1, deleted: 0 },
			fresh: 1,
			edited: 2,
			edges: edges,
			clones: clones
		};
	}

	/** `git <words>` in `repo`, authored at `authored` and committed at `committed` (the author time when absent). */
	private static function git(repo: String, words: Array<String>, authored: Float, ?committed: Float): Void {
		cmd('git -c user.name=stats -c user.email=stats@example.com -c commit.gpgsign=false -C $repo $words')
			.env('GIT_AUTHOR_DATE', '@${Std.int(authored)} +0000')
			.env('GIT_COMMITTER_DATE', '@${Std.int(committed ?? authored)} +0000')
			.run()
			.check();
	}

}
