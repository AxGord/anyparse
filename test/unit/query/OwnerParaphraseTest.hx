package unit.query;

import anyparse.query.IndexScope;
import anyparse.query.OwnerIndex;
import anyparse.query.cli.CliArgs;
import haxe.Json;
import unit.cli.CliFixture;

using Lambda;

/** One held-out question of a benchmark file and the types whose answer it is. */
typedef ParaphrasedQuestion = {
	final question: String;
	final owners: Array<String>;
};

/** A benchmark file under `test/probes`: its questions, how far down an owner may rank, and how many must find one. */
typedef ParaphraseBenchmark = {
	final top: Int;
	final atLeast: Int;
	final questions: Array<ParaphrasedQuestion>;
};

/**
 * `hxq owner` on paraphrased questions, worded from review records and by a
 * reviewer rather than copied from the owners' docs: each benchmark file under
 * `test/probes` keeps at least its stated number of questions with an owner, the type or one of its members, ranked in its
 * top over the project's own `src`.
 */
class OwnerParaphraseTest extends Test {

	/**
	 * The benchmark files, relative to the repository root: the set the ranking was tuned on, a second written after tuning
	 * by the same author, and the held-out one a reviewer wrote without the owners' wording.
	 */
	private static final BENCHMARKS: Array<String> = [
		'test/probes/owner-paraphrases.json',
		'test/probes/owner-paraphrases-validation.json',
		'test/probes/owner-paraphrases-reviewer.json'
	];

	@:pin('control') @:killer('M-OWNER-STANDING-FLAT')
	public function testEachBenchmarkFindsItsOwnersAmongTheFirstFew(): Void {
		#if (sys || nodejs)
		final root: String = CliFixture.repoRoot();
		final io: ResolvedInputs = CliArgs.resolveInputPaths('haxe', ['$root/src']);
		final files: Array<{ file: String, source: String }> = [
			for (path in io.paths)
				{
					file: path,
					source: sys.io.File.getContent(path)
				}
		];
		final owners: OwnerIndex = OwnerIndex.build(IndexScope.over(files, io.plugin), io.plugin);
		for (name in BENCHMARKS) {
			final benchmark: ParaphraseBenchmark = Json.parse(sys.io.File.getContent('$root/$name'));
			final missed: Array<String> = [];
			for (asked in benchmark.questions) {
				final top: Array<String> = [for (hit in owners.rank(asked.question, benchmark.top)) hit.entry.type];
				if (!top.exists(type -> asked.owners.contains(type))) missed.push('"${asked.question}" ranks ${top.join(', ')}');
			}
			final found: Int = benchmark.questions.length - missed.length;
			Assert.isTrue(
				found >= benchmark.atLeast, '$name: $found found, at least ${benchmark.atLeast} expected; missed:\n${missed.join('\n')}'
			);
		}
		#else
		Assert.pass('non-sys target');
		#end
	}

}
