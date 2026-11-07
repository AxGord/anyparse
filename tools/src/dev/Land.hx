package dev;

import anyparse.core.PoolLease;
import dev.BaselineWarm.WarmRecipe;
import dev.BaselineWarm.WarmStart;
import dev.LandFormat.FormatTools;
import dev.MergeBrief.MergePlace;
import dev.PostLand.PostLandStart;
import dev.SuiteImpact.SuiteScope;
import devkit.Args.UsageError;
import devkit.Branches;
import devkit.Cmd.cmd;
import devkit.Lease;
import devkit.Result;
import devkit.Summary;
import devkit.Tally;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * `dev land <branch>` — the parent's landing of a reviewed slice branch in the tree that holds this `dev.js`, as ONE
 * command that moves the checked-out branch only to a commit the battery judged. In a detached candidate tree of the
 * checked-out commit (`LandCandidate`) the branch's single commit is applied (`git cherry-pick --no-commit`), so the history
 * stays linear, its files merging as their `.gitattributes` say (`docs/decisions.md` by union, source and JSON through their
 * grammar by `apq merge-file`, each merged file a detail line), the three binaries built, the pick's `.hx` files rewritten
 * as canonical when that is layout only (`LandFormat`), the commit made with a `Slice: <ID>` trailer, and `dev battery` run
 * (quick, or in full when the commit brings in a path where a shard and the one-process suite can diverge, or the number of
 * the landing, counted over every landing that runs the battery, is a multiple of ten — the battery row says which). Only
 * then is the checked-out branch fast-forwarded to that commit (`advance`), the binaries the candidate built copied into
 * it, the `prose-refs` row (`LandProse`: the prose that still names a path the commit deleted or renamed, report-only)
 * read — and one verdict line.
 * A branch that does not carry exactly one commit over the checked-out one is refused; a conflict, a failed build or fmt, a
 * red battery, or a step that threw leaves the checked-out branch, index and files as they were, and the verdict names the
 * candidate commit; a place the merge driver left gets a `MergeBrief` with the `--resolve` choices that re-land it
 * (docs/testing.md § "Landing a slice"). The candidate tree is removed whatever the outcome.
 */
@:nullSafety(Strict)
final class Land {

	public static inline final USAGE: String = 'usage: dev land <branch> [-m <message>] [--no-battery] [--full] [--allow-blast] '
		+ '[--allow <row>]... [--snapshot] [--rounds <n>] [--tokens <n>] [--resolve <path>#<key>=<ours|theirs|both>]... '
		+ '[--queue <file>] [--warm-frozen <dir>]... [--warm-infra <dir>]... [--logs <dir>] [--repo <tree>]';

	/** The trailers a landing carries its review rounds and the tokens the slice cost under, which `dev slice-stats` reads. */
	public static inline final ROUNDS_TRAILER: String = 'Review-Rounds';

	public static inline final TOKENS_TRAILER: String = 'Tokens';

	/** Every this-many-th landing runs the battery in full, whatever it touched. */
	public static inline final FULL_EVERY: Int = 10;

	public static final NO_BATTERY: String = '--no-battery';

	/** The merge driver `.gitattributes` names for the files a grammar reads (`apq merge-file`). */
	private static inline final DRIVER: String = 'anyparse';

	/** The prefix `apq merge-file` reports a merged file with. */
	private static inline final MERGED_PREFIX: String = 'auto-merged: ';

	/** The queue file whose lines a merge brief quotes, under the repository, when `--queue` names none. */
	private static inline final QUEUE: String = '.claude/batch/wave-D.md';

	/** What the battery may run before it is killed. */
	private static inline final BATTERY_TIMEOUT_MS: Int = 3 * 60 * 60 * 1000;

	/** Where, under the battery's snapshot directory, the landings are counted. */
	private static inline final TALLY_DIR: String = 'landings';

	/**
	 * Where a shard and the one-process run of the suite can diverge, so a landing that brings a path in is checked against
	 * both: the test kit and runner, the shard planning and the transcript parity it is judged by, the battery script, the
	 * process-scoped runtime caches (docs/design-principles.md § 2) and the runtime itself. A path is a prefix.
	 */
	private static final DIVERGENCE_PATHS: Array<String> = [
		'test/testkit/',
		'tools/src/dev/Shard',
		'src/anyparse/query/Shard',
		'src/anyparse/query/cli/TestTranscript.hx',
		'test/RunTests.hx',
		'tools/src/dev/Battery.hx',
		'src/anyparse/query/SharedParseTier.hx',
		'src/anyparse/query/FormatConfigDiscovery.hx',
		'src/anyparse/grammar/haxe/HaxeQueryPlugin.hx',
		'src/anyparse/macro/QueryWalkerCodegen.hx',
		'src/anyparse/runtime/'
	];

	private final _summary: Summary = new Summary();
	private final _repo: String;
	private final _branch: String;
	private final _logs: String;
	private final _compile: Compile;
	private final _exec: BatteryExec;
	private final _merged: MergedPaths;
	private final _print: String -> Void;
	private final _format: LandFormat;
	private final _prose: LandProse;

	/** The detached tree the landing is made and judged in; main's checkout moves only to its verified commit. */
	private final _candidate: LandCandidate;

	/** The trailers the commit carries beside `Slice`, each `<key>: <value>`. */
	private final _trailers: Array<String>;

	/** The places settled for the merge driver, each `<path>#<key>=<choice>`. */
	private final _resolve: Array<String>;

	private final _queue: Null<String>;

	/** The scope seam, and the start of the whole suite after the land. */
	private final _impact: Null<ImpactScope>;

	private final _postLand: Null<PostLandStart>;

	/** The snapshot key of the commit the checked-out branch was at when the landing began, or null before the base step. */
	private var _base: Null<String> = null;

	/** Whether the battery's suite ran only the classes the merge reaches, so the whole suite still has to run. */
	private var _impacted: Bool = false;

	/** The binaries the candidate's build made, as paths under the tree. */
	private var _outputs: Array<String> = [];

	private function new(options: LandOptions) {
		_repo = options.repo;
		_branch = options.branch;
		_logs = options.logs;
		_compile = options.compile;
		_exec = options.exec;
		_merged = options.merged;
		_print = options.print;
		_candidate = new LandCandidate(options.repo, Path.join([options.logs, 'candidate']));
		_format = new LandFormat(_candidate.tree, options.format, _summary);
		_prose = new LandProse(options.repo, options.skills, Path.join([options.logs, 'prose-refs.txt']), _summary);
		_trailers = options.trailers ?? [];
		_resolve = options.resolve ?? [];
		_queue = options.queue;
		_impact = options.impact;
		_postLand = options.postLand;
	}

	/**
	 * Every step in turn, each only while the ones before it passed; answers the exit status. The steps up to the battery work
	 * in the candidate tree, so one that does not pass leaves main as it was; the tree is dropped whatever the outcome.
	 */
	private function run(message: Null<String>, battery: Null<BatteryRequest>, warm: Null<WarmStart>): Int {
		final cache: Null<String> = battery?.cache;
		final steps: Array<{ name: String, step: () -> Outcome }> = [
			{
				name: 'post-red',
				step: () -> PostLand.unsettled(cache, _postLand, _repo, _summary.detail)
			},
			{ name: 'clean', step: clean },
			{ name: 'branch', step: shape },
			{ name: 'base', step: ensureBase.bind(battery) },
			{ name: 'pick', step: pick },
			{ name: 'build', step: build },
			{ name: 'fmt', step: _format.run },
			{ name: 'commit', step: commit.bind(message) },
			{ name: 'battery', step: runBattery.bind(battery) },
			{ name: 'advance', step: _candidate.advance },
			{ name: 'binaries', step: install },
			{ name: 'prose-refs', step: _prose.run },
			{
				name: 'post-land',
				step: () -> PostLand.afterwards(_postLand, _impacted, _repo, git(['rev-parse', 'HEAD']).out.trim(), cache, _summary.detail)
			},
			{
				name: 'warm',
				step: () -> BaselineWarm.afterwards(warm, _repo, git(['rev-parse', 'HEAD']).out.trim(), _summary.detail)
			}
		];
		for (s in steps) if (_summary.passed()) _summary.time(s.name, s.step);
		final left: Null<String> = _candidate.drop();
		_print(_summary.table());
		if (left != null) _print('the candidate tree ${_candidate.tree} is left in place: $left');
		final passed: Bool = _summary.passed();
		_print('land $_branch: ${passed ? 'PASS' : 'FAIL'} — ${_candidate.standing()} — logs $_logs');
		return passed ? 0 : 1;
	}

	private function clean(): Outcome {
		final dirty: Array<String> = git(['status', '--porcelain', '--untracked-files=no']).lines();
		return dirty.length == 0 ? Passed : Failed('the tree has uncommitted changes, first `${dirty[0]}`');
	}

	/**
	 * The branch carries exactly one commit the checked-out one lacks, and it is not a merge: a history of one commit per
	 * slice is what makes a landing a plain pick, and a branch of several is for its author to squash.
	 */
	private function shape(): Outcome {
		if (!git(['rev-parse', '-q', '--verify', '$_branch^{commit}']).ok) return Failed('no branch `$_branch` here');
		final ahead: Array<String> = git(['rev-list', '--parents', 'HEAD..$_branch']).lines();
		if (ahead.length == 0) return Failed('`$_branch` has no commit the checked-out branch lacks');
		if (ahead.length > 1)
			return Failed(
				'`$_branch` carries ${ahead.length} commits over the checked-out branch, a landing takes one — squash it first '
				+ '(`git reset --soft $$(git merge-base HEAD $_branch) && git commit`)'
			);
		if (ahead[0].split(' ').length != 2) return Failed('the commit of `$_branch` is a merge or a root — a landing takes a plain one');
		final landed: Null<String> = landedAs();
		return landed == null ? Passed : Failed('`$_branch` is landed already as $landed');
	}

	/**
	 * The commit of the checked-out branch that landed the branch's commit, or null: one carrying this slice's `Slice`
	 * trailer, or — for a landing made without the trailer — one with the same patch. A landing makes a new commit, so the
	 * branch is never an ancestor of the branch it landed on.
	 */
	private function landedAs(): Null<String> {
		final id: String = sliceId(_branch);
		for (sha in git(['log', 'HEAD', '--fixed-strings', '--grep', 'Slice: $id', '--format=%h']).lines()) {
			final slices: Array<String> = git(['log', '-1', '--format=%(trailers:key=Slice,valueonly)', sha]).lines().map(l -> l.trim());
			if (slices.contains(id)) return sha;
		}
		for (line in git(['cherry', 'HEAD', _branch]).lines()) if (line.startsWith('- ')) return 'a commit with the same patch';
		return null;
	}

	/**
	 * The candidate tree opened at main's HEAD and `git cherry-pick --no-commit` of the branch's commit in it, with the grammar
	 * merge driver named and the places `--resolve` settled handed to it; every file it merged is a detail line, and a conflict
	 * it leaves fails the step with a brief.
	 */
	private function pick(): Outcome {
		final opened: Outcome = _candidate.open();
		if (!opened.match(Passed)) return opened;
		final apq: String = Path.join([_repo, 'bin/apq.js']);
		final choices: String = _resolve.length == 0 ? '' : ' --choices ${shellQuoted(choicesFile())}';
		final run: Result = _candidate.git([
			'-c',
			'merge.$DRIVER.driver=node ${shellQuoted(apq)} merge-file %O %A %B --path %P$choices',
			'cherry-pick',
			'--no-commit',
			_branch
		]);
		final said: String = '${run.err}\n${run.out}';
		for (line in said.split('\n')) if (line.startsWith(MERGED_PREFIX)) _summary.detail(line.trim());
		if (run.ok) return Passed;
		final unmerged: Array<String> = _candidate.git(['diff', '--name-only', '--diff-filter=U']).lines();
		if (unmerged.length == 0) return Failed(run.firstError());
		final places: Array<MergePlace> = MergeBrief.placesOf(said);
		if (places.length == 0) return Failed('git could not merge ${unmerged.join(', ')}');
		final brief: String = MergeBrief.write(_repo, _branch, _logs, places, _queue ?? Path.join([_repo, QUEUE]));
		return Failed('git could not merge ${unmerged.join(', ')} — ${places.length} place(s) to choose, brief $brief');
	}

	/** The `--resolve` choices written where `apq merge-file --choices` reads them: `<path>\t<key>\t<choice>` lines. */
	private function choicesFile(): String {
		final file: String = Path.join([_logs, 'merge-choices.tsv']);
		File.saveContent(file, _resolve.map(choiceLine).join(''));
		return file;
	}

	/**
	 * `apq.js`, `test.js` and `dev.js` built from the picked candidate tree, at once; what the build made is noted for
	 * `install`. Main's suite weights are then seeded into the fresh tree, so the battery's shards balance as they would in
	 * main's checkout.
	 */
	private function build(): Outcome {
		final outcome: Outcome = _compile(_candidate.tree, Path.join([_logs, 'build.log']));
		_outputs = _candidate.built();
		final weights: String = Path.join([_repo, Shard.WEIGHTS]);
		if (FileSystem.exists(weights)) File.copy(weights, Path.join([_candidate.tree, Shard.WEIGHTS]));
		return outcome;
	}

	/**
	 * The pick committed under `message`, or the message of the branch's commit, with the author and date of that commit and
	 * a `Slice: <ID>` trailer unless the message names a slice already, and the trailers of the run (`metricTrailers`).
	 */
	private function commit(message: Null<String>): Outcome {
		final file: String = Path.join([_logs, 'commit-message.txt']);
		File.saveContent(file, '${(message ?? git(['log', '-1', '--format=%B', _branch]).out).trim()}\n');
		final trailer: Result = git([
			'interpret-trailers',
			'--in-place',
			'--if-exists',
			'doNothing',
			'--trailer',
			'Slice: ${sliceId(_branch)}',
			file
		]);
		if (!trailer.ok) return Failed(trailer.firstError());
		final markers: Array<String> = [];
		final applied: Null<String> = _format.trailer();
		final named: Array<String> = applied == null ? _trailers : _trailers.concat(['${LandFormat.TRAILER}: $applied']);
		for (marker in named) {
			markers.push('--trailer');
			markers.push(marker);
		}
		final marked: Result = git(['interpret-trailers', '--in-place', '--if-exists', 'replace'].concat(markers).concat([file]));
		if (!marked.ok) return Failed(marked.firstError());
		final author: String = git(['log', '-1', '--format=%an <%ae>', _branch]).out.trim();
		final date: String = git(['log', '-1', '--format=%aI', _branch]).out.trim();
		final commit: Result = _candidate.git(['commit', '-F', file, '--author', author, '--date', date]);
		if (!commit.ok) return Failed(commit.firstError());
		_summary.detail(_candidate.made());
		return Passed;
	}

	/**
	 * `dev battery` over the candidate tree, or a skip when there is no `request` (`--no-battery`). Quick or full is
	 * decided here, from what the commit brought in and the count of landings, and the row names why.
	 */
	private function runBattery(request: Null<BatteryRequest>): Outcome {
		if (request == null) return Skipped(NO_BATTERY);
		final landing: Int = Tally.next(Path.join([request.cache, TALLY_DIR]));
		final why: Null<String> = fullReason(_merged(_candidate.tree), landing, request.full, request.every);
		final record: Null<String> = GateReuse.locate(_repo, _branch);
		final mode: String = why == null ? 'battery quick' : 'battery full: $why';
		_summary.detail(record == null ? mode : '$mode, offered the gate record of the branch\'s worktree');
		final flags: Array<String> = batteryFlags(
			request.allowBlast, request.snapshot, why != null, request.leased, request.allow, _base, record,
			why == null ? impactFile() : null
		);
		return switch _exec(flags, _candidate.tree, Path.join([_logs, 'battery.log'])) {
			case Failed(failure): Failed('$mode — $failure');
			case other: other;
		};
	}

	private function git(words: Array<String>): Result {
		return cmd('git -C $_repo $words').run();
	}

	/** The detached tree at `tree`, if one is there; a tree git will not remove is left and said so. */
	private function dropTree(tree: String): Void {
		if (!FileSystem.exists(tree)) return;
		final removed: Result = git(['worktree', 'remove', '--force', tree]);
		if (!removed.ok) _summary.detail('the tree $tree is left in place: ${removed.firstError()}');
	}

	/**
	 * The snapshot of the commit the landing merges onto, in the cache, before anything is picked: a landing is judged against
	 * that commit and no other, and a snapshot that cannot be had leaves the tree untouched. A missing one is made by a battery
	 * over a detached tree of that commit that compares nothing; the snapshot is a reading, so a red battery of the base
	 * still serves — only a base whose battery left no snapshot fails.
	 */
	private function ensureBase(request: Null<BatteryRequest>): Outcome {
		if (request == null) return Skipped(NO_BATTERY);
		final head: String = git(['rev-parse', 'HEAD']).out.trim();
		_base = Battery.keyOf(_repo, head);
		final base: Null<String> = _base;
		return base == null ? Passed : baseSnapshot(request, base, head);
	}

	private function baseSnapshot(request: BatteryRequest, base: String, head: String): Outcome {
		final file: String = Path.join([request.cache, '$base-suite.txt']);
		if (FileSystem.exists(file)) return Passed;
		final tree: String = Path.join([_logs, 'base-$base']);
		dropTree(tree);
		final added: Result = git(['worktree', 'add', '--detach', tree, head]);
		if (!added.ok) return Failed('no tree of the base $base to snapshot: ${added.firstError()}');
		_summary.detail('base $base had no snapshot — made');
		final flags: Array<String> = batteryFlags(false, true, false, request.leased, []).concat(['--no-base', '--repo', tree]);
		final outcome: Outcome = _exec(flags, _repo, Path.join([_logs, 'battery-base.log']));
		dropTree(tree);
		if (!FileSystem.exists(file)) return Failed('the snapshot of the base $base could not be made — ${why(outcome)}');
		if (!outcome.match(Passed)) _summary.detail('the battery of the base $base was red — its snapshot is the base all the same');
		return Passed;
	}

	/**
	 * The file listing the test classes the merge reaches against the commit before it, or null when the suite runs whole: no
	 * scope seam, or a change no text dependency bounds. The whole suite of the landed commit then runs after the land.
	 */
	private function impactFile(): Null<String> {
		final impact: Null<ImpactScope> = _impact;
		if (impact == null) return null;
		return switch impact(_candidate.tree, _candidate.before) {
			case WholeSuite(why):
				_summary.detail('whole suite under the lock — $why');
				null;
			case Selected(classes):
				final file: String = Path.join([_logs, 'suite-impact.txt']);
				File.saveContent(file, classes.map(name -> '$name\n').join(''));
				_summary.detail('impact suite under the lock — ${classes.length} class(es), listed in $file');
				_impacted = true;
				file;
		}
	}

	/**
	 * The binaries the candidate's build made, copied into main's checkout once it holds the commit they were built from: the
	 * bytes the battery ran, without a second build; and the suite weights, when the battery measured new ones. Each lands by a
	 * rename, so a call starting meanwhile reads a whole file.
	 */
	private function install(): Outcome {
		final measured: String = Path.join([_candidate.tree, Shard.WEIGHTS]);
		final held: String = Path.join([_repo, Shard.WEIGHTS]);
		final renewed: Bool = FileSystem.exists(measured)
			&& (!FileSystem.exists(held) || File.getContent(measured) != File.getContent(held));
		final carried: Array<String> = renewed ? _outputs.concat([Shard.WEIGHTS]) : _outputs;
		for (path in carried) {
			final target: String = Path.join([_repo, path]);
			final part: String = '$target.land-tmp';
			FileSystem.createDirectory(Path.directory(target));
			File.copy(Path.join([_candidate.tree, path]), part);
			FileSystem.rename(part, target);
		}
		_summary.detail(
			'${_outputs.length} file(s) of the candidate\'s build${renewed ? ', and the suite weights its battery measured' : ''}'
		);
		return Passed;
	}

	public static function main(argv: Array<String>): Int {
		final args: LandArgs = new LandArgs(argv);
		final request: BatteryRequest = {
			allowBlast: args.allowBlast,
			snapshot: args.snapshot,
			allow: args.allow,
			full: args.full,
			leased: PoolLease.threads(),
			cache: cacheDir(Sys.getEnv),
			every: FULL_EVERY
		};
		final repo: String = Repo.resolve(args.repo);
		final home: Null<String> = Sys.getEnv('HOME');
		final branch: String = args.branch;
		final noBattery: Bool = args.noBattery;
		if (!noBattery && (Sys.getEnv('ANYPARSE_HXFORMAT_FORK') ?? '') == '')
			throw new UsageError('the battery needs ANYPARSE_HXFORMAT_FORK — set it, or pass --no-battery');
		for (entry in args.resolve) choiceLine(entry);
		final logs: String = args.logs ?? Path.join([Sys.getEnv('TMPDIR') ?? '/tmp', 'anyparse-land', branch.replace('/', '-')]);
		FileSystem.createDirectory(logs);
		final recipe: WarmRecipe = args.recipe;
		final warming: Bool = !noBattery && (recipe.frozen.length > 0 || recipe.infra.length > 0);
		return land({
			repo: repo,
			branch: branch,
			logs: logs,
			message: args.message,
			trailers: args.trailers,
			resolve: args.resolve,
			queue: args.queue,
			skills: home == null ? null : Path.join([home, '.claude/skills']),
			battery: noBattery ? null : request,
			compile: (tree, log) -> Binaries.compileWith(tree, log, [], Lease.ofEnvironment()),
			format: LandFormat.engine(),
			impact: SuiteImpact.ofTree,
			postLand: PostLand.start,
			warm: warming ? (tree, sha) -> BaselineWarm.start(tree, sha, request.cache, recipe) : null,
			exec: execBattery,
			merged: mergedPaths,
			print: Sys.println
		});
	}

	/** The pick, the build and the battery of `options`; answers the exit status. */
	public static function land(options: LandOptions): Int {
		return new Land(options).run(options.message, options.battery, options.warm);
	}

	/**
	 * The choices-file line of a `--resolve` entry `<path>#<key>=<choice>` (the key may hold `#` and `=` itself: the path
	 * ends at the first `#`, the choice starts past the last `=`); an entry of another shape is refused.
	 */
	public static function choiceLine(entry: String): String {
		final hash: Int = entry.indexOf('#');
		final equals: Int = entry.lastIndexOf('=');
		final choice: String = equals > hash ? entry.substr(equals + 1) : '';
		if (hash <= 0 || equals <= hash + 1 || !MergeBrief.CHOICES.contains(choice))
			throw new UsageError('--resolve takes <path>#<key>=<${MergeBrief.CHOICES.join('|')}>, not `$entry`');
		return '${entry.substr(0, hash)}\t${entry.substring(hash + 1, equals)}\t$choice\n';
	}

	/** The slice id a branch carries: its name past the last `/`, without the `hxqb-` prefix (`batch/hxqb-LAND-2` is `LAND-2`). */
	public static function sliceId(branch: String): String {
		final name: String = branch.substr(branch.lastIndexOf('/') + 1);
		return name.startsWith('hxqb-') ? name.substr('hxqb-'.length) : name;
	}

	/** `dev battery` with `flags` over `tree`, its output kept at `log`. */
	public static function execBattery(flags: Array<String>, tree: String, log: String): Outcome {
		final run: Result = cmd('node bin/dev.js battery $flags').at(tree).timeout(BATTERY_TIMEOUT_MS).run();
		File.saveContent(log, run.out + run.err);
		return run.ok ? Passed : Failed('${run.firstError()} — $log');
	}

	/**
	 * The battery's snapshot directory, which also keeps the count of landings: `$ANYPARSE_BLAST_CACHE`,
	 * else `anyparse-blast-cache` under the home directory, given the environment `env` reads.
	 */
	public static function cacheDir(env: String -> Null<String>): String {
		return env('ANYPARSE_BLAST_CACHE') ?? Path.join([env('HOME') ?? '', 'anyparse-blast-cache']);
	}

	/**
	 * The paths the commit at the head of `tree` changes against its parent — both sides of a rename — or null when git
	 * cannot say.
	 */
	public static function mergedPaths(tree: String): Null<Array<String>> {
		final diff: Result = cmd('git -C $tree diff --name-only --no-renames HEAD~1 HEAD').run();
		return diff.ok ? diff.lines() : null;
	}

	/**
	 * Why a landing runs the battery in full, or null when quick will do: it was asked for, the commit brought in a path
	 * where a shard and the one-process suite can diverge, its paths are unknown, or it is the `every`-th landing.
	 */
	public static function fullReason(changed: Null<Array<String>>, landing: Int, asked: Bool, every: Int): Null<String> {
		if (asked) return '--full';
		if (changed == null) return 'the merged paths are unknown';
		for (path in changed) if (!isInertData(path)) for (prefix in DIVERGENCE_PATHS) if (path.startsWith(prefix)) return 'touches $path';
		return every > 0 && landing % every == 0 ? 'landing $landing' : null;
	}

	/**
	 * What `dev battery` is given. The monolith cross-check of the suite is not run at every landing, so `--quick`
	 * is the default (`fullReason` says when it is not); under a pool lease (`leased` threads) a quick battery's suite takes the
	 * shards the lease leaves beside the battery's light branches, and a full one runs on one shard, which is the monolith run
	 * itself — more shards would add a second, monolith run to the cross-check; otherwise the battery
	 * sizes it, from its own count or from the lease its suite's branch takes. `reuse` is the gate record
	 * of the branch's worktree; the battery itself judges which rows it may take over (`GateReuse`).
	 */
	public static function batteryFlags(
		allowBlast: Bool, snapshot: Bool, full: Bool, leased: Null<Int>, allow: Array<String>, ?base: String, ?reuse: String, ?only: String
	): Array<String> {
		final flags: Array<String> = [];
		if (allowBlast) flags.push('--allow-blast');
		if (snapshot) flags.push('--snapshot');
		for (row in allow) {
			flags.push('--allow');
			flags.push(row);
		}
		if (!full) flags.push('--quick');
		if (base != null) {
			flags.push('--base');
			flags.push(base);
		}
		if (reuse != null) {
			flags.push('--reuse');
			flags.push(reuse);
		}
		if (only != null) {
			flags.push('--only');
			flags.push(only);
		}
		final shards: Null<Int> = full && leased != null ? 1 : Branches.share(leased, Battery.lightThreads());
		if (shards != null) {
			flags.push('-n');
			flags.push('$shards');
		}
		return flags;
	}

	/**
	 * The trailers that mark a landing with its review rounds and the tokens it cost, from `--rounds` and `--tokens`; a value
	 * that is not a count is refused.
	 */
	public static function metricTrailers(rounds: Null<String>, tokens: Null<String>): Array<String> {
		final out: Array<String> = [];
		for (marker in [{ key: ROUNDS_TRAILER, value: rounds }, { key: TOKENS_TRAILER, value: tokens }]) {
			final value: Null<String> = marker.value;
			if (value == null) continue;
			if (!~/^[0-9]+$/.match(value)) throw new UsageError('${marker.key} takes a count, not `$value`');
			out.push('${marker.key}: $value');
		}
		return out;
	}

	/** `word` as one shell word: git runs a merge driver through the shell, and quotes only its own `%` placeholders. */
	public static function shellQuoted(word: String): String {
		return "'" + word.replace("'", "'\\''") + "'";
	}

	/**
	 * Whether `path` is a data record under the test kit: a `.json` there is read as data, by a test or at build time,
	 * the same way by a shard and by the one-process suite, so they cannot diverge on it; a `.hx` there is the kit itself.
	 */
	private static function isInertData(path: String): Bool {
		return path.startsWith('test/testkit/') && path.endsWith('.json');
	}

	/** Why the battery of a base left no snapshot. */
	private static function why(outcome: Outcome): String {
		return switch outcome {
			case Failed(failure): failure;
			case _: 'it left none';
		};
	}

}

/**
 * The build of the three binaries `Land` runs in the candidate tree after the pick: the tree and the log the transcripts go
 * to.
 */
typedef Compile = (tree:String, log:String) -> Outcome;

/** The battery of a `Land` run: its flags, the snapshot directory that keeps the count of landings, and how often it runs in full. */
typedef BatteryRequest = {

	var allowBlast: Bool;
	var snapshot: Bool;

	/** The battery rows whose failure the verdict waives, each reported as allowed (`dev battery --allow`). */
	var allow: Array<String>;

	/** Whether the full battery was asked for. */
	var full: Bool;
	var leased: Null<Int>;
	var cache: String;
	var every: Int;

}

/** The paths a merge brought into the tree, or null when they cannot be read. */
typedef MergedPaths = (tree:String) -> Null<Array<String>>;
/** The run of `dev battery`: its flags, the tree it runs over and the log it leaves. */
typedef BatteryExec = (flags:Array<String>, tree:String, log:String) -> Outcome;

/** The scope of the suite a merge needs: the tree and the commit it is compared with. */
typedef ImpactScope = (tree:String, base:String) -> SuiteScope;

/** What a run of `Land` is given: what to merge into where, and the two seams a test replaces (the build and the output). */
typedef LandOptions = {

	/** The main checkout: the tree whose checked-out branch a passed landing fast-forwards. */
	var repo: String;
	var branch: String;
	var logs: String;
	var message: Null<String>;

	/** The trailers the commit carries beside `Slice` (`metricTrailers`); none when absent. */
	@:optional var trailers: Array<String>;

	/** The places settled for the merge driver, each `<path>#<key>=<choice>` (`Land.choiceLine`); none when absent. */
	@:optional var resolve: Array<String>;

	/** The queue file a merge brief quotes; the repository's `.claude/batch/wave-D.md` when absent. */
	@:optional var queue: String;

	/** The directory of skill documents the `prose-refs` row also reads; none when absent. */
	@:optional var skills: Null<String>;

	/** The battery to run; null runs none. */
	var battery: Null<BatteryRequest>;
	var compile: Compile;

	/** The writer runs of the `fmt` step (`LandFormat.engine` for a real landing). */
	var format: FormatTools;

	/** Which test classes the merge needs against the commit before it (`SuiteImpact.ofTree`); absent runs the whole suite. */
	@:optional var impact: Null<ImpactScope>;

	/** Starts the whole suite of the landed commit beside the next land (`PostLand.start`); absent starts none. */
	@:optional var postLand: Null<PostLandStart>;

	/** Starts the baseline of the landed commit beside the next land (`BaselineWarm.start`); absent starts none. */
	@:optional var warm: Null<WarmStart>;
	var exec: BatteryExec;
	var merged: MergedPaths;
	var print: String -> Void;

}
