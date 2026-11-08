package dev;

import anyparse.proc.PendingRuns;
import anyparse.proc.Sleep;
import devkit.Args;
import devkit.Cmd.cmd;
import devkit.Command;
import devkit.Lease;
import devkit.Result;
import devkit.Summary.Outcome;
import haxe.io.Path;

using StringTools;

/**
 * The one answer to "how does the baseline a first slice gate needs get measured before that gate asks for it": once a land
 * has passed, `dev land` starts `dev baseline-warm run <sha>` for the landed commit, a process that outlives the land and
 * its lock, takes a lease of its own from the pool, checks the commit out into a worktree of its own and records, with
 * `dev slice-gate --baseline`, the very entries a worker's first gate would build (one with the infra trees, one without),
 * into the `BaselineCache`, and, for a recipe with infra trees, the base engine's lint of the commit `BaseLint` keeps for the
 * `infra4` row of a rule-code gate. It never decides the land's verdict, and it is dropped — its gate killed, its worktree removed —
 * the moment the checked-out branch of the repository is no longer `sha`, since no new slice is based on that commit any more.
 * A run that failed or was dropped leaves no cache entry: the cache stores only a baseline whose every row passed.
 */
@:nullSafety(Strict)
final class BaselineWarm {

	public static inline final USAGE: String =
		'usage: dev baseline-warm run <sha> [--repo <dir>] [--frozen <dir>]... [--infra-tree <dir>]...';

	private static inline final DIRECTORY: String = 'baseline-warm';
	private static inline final POLL_MS: Int = 5000;

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final repo: Null<String> = args.option('--repo');
		final cache: String = args.option('--cache') ?? Land.cacheDir(Sys.getEnv);
		final recipe: WarmRecipe = { frozen: args.options('--frozen'), infra: args.options('--infra-tree') };
		final words: Array<String> = args.rest(['run', '<sha>']);
		if (words[0] != 'run') throw new UsageError('unknown verb ${words[0]}');
		if (words.length != 2) throw new UsageError('run takes one <sha>');
		return run(Repo.resolve(repo), words[1], cache, recipe);
	}

	/**
	 * The gate runs of one recipe, in the order they are worth waiting for: the one that also lints the infra trees (the
	 * longest, taken by a slice that touches rule code), then the plain one. The infra trees are named only when the recipe
	 * has any.
	 */
	public static function variants(recipe: WarmRecipe): Array<Array<String>> {
		final frozen: Array<String> = [for (dir in recipe.frozen) for (word in ['--frozen', dir]) word];
		final infra: Array<String> = [for (dir in recipe.infra) for (word in ['--infra-tree', dir]) word];
		return recipe.infra.length == 0 ? [frozen] : [frozen.concat(infra), frozen];
	}

	/** The command line of the detached run: this tool's own copy `script`, behind the pool lease `mode` grants. */
	public static function argvOf(
		mode: LeaseMode, script: String, repo: String, sha: String, cache: String, recipe: WarmRecipe
	): Array<String> {
		final words: Array<String> = ['node', script, DIRECTORY, 'run', sha, '--repo', repo, '--cache', cache];
		for (dir in recipe.frozen) words.push('--frozen=$dir');
		for (dir in recipe.infra) words.push('--infra-tree=$dir');
		return PostLand.leased(mode, words, 'baseline-warm $sha');
	}

	/** Start the warm run of `sha` and answer at once; the process outlives the caller. */
	public static function start(repo: String, sha: String, cache: String, recipe: WarmRecipe): Outcome {
		PostLand.launch(directory(cache), sha, repo, script -> argvOf(Lease.pooled(), script, repo, sha, cache, recipe));
		return Passed;
	}

	/**
	 * The step of a land that follows its last check: starts the warm run of the landed `head` and never fails the land —
	 * a warm that cannot start is a note, not a verdict.
	 */
	public static function afterwards(start: Null<WarmStart>, repo: String, head: String, note: String -> Void): Outcome {
		if (start == null) return Skipped('no baseline warm requested');
		return try {
			final started: Outcome = start(repo, head);
			if (started.match(Passed)) note('baseline of $head is measured in the background, no lock held');
			started;
		} catch (exception: haxe.Exception) {
			Skipped('baseline warm not started: ${exception.message}');
		}
	}

	/**
	 * Run each of `variants` in turn through `begin`, for as long as `tip()` is still `sha`: a run in flight is cancelled and
	 * the rest not started the moment it is not. Answers Skipped when dropped, else the first failure, else Passed.
	 */
	public static function warm(
		sha: String, variants: Array<Array<String>>, tip: () -> String, begin: Array<String> -> Warming, pause: () -> Void
	): Outcome {
		var failure: Null<String> = null;
		for (variant in variants) {
			if (tip() != sha) return moved(sha);
			final warming: Warming = begin(variant);
			while (warming.running()) {
				if (tip() != sha) {
					warming.cancel();
					return moved(sha);
				}
				pause();
			}
			switch warming.ended() {
				case Failed(why):
					if (failure == null) failure = why;
				case _:
			}
		}
		return failure == null ? Passed : Failed(failure);
	}

	/** The end of a run for `sha`, whatever the verdict: its script copy is removed, and its log unless the run failed. */
	public static function settle(cache: String, sha: String, verdict: Outcome): Void {
		PostLand.release(directory(cache), sha, verdict.match(Failed(_)));
	}

	public static function directory(cache: String): String {
		return Path.join([cache, DIRECTORY]);
	}

	/**
	 * The lint of the landed `tree` by the engine its `--baseline` built (the base engine of every slice based on it), kept in the
	 * cache `BaseLint` reads.
	 */
	public static function baseLint(tree: String, work: String): Warming {
		final report: String = Path.join([work, BaseLint.FILE]);
		final stamp: String = BaseLint.stampOf(cmd('git rev-parse HEAD').at(tree).check().out, BaseEngine.toolchain());
		final command: Command = BaseLint.command(tree, Path.join([tree, 'bin/apq.js']), Path.withExtension(report, 'err'));
		final batch: PendingRuns = command.background();
		return {
			running: batch.running,
			cancel: batch.cancel,
			ended: () -> {
				final why: Null<String> = BaseLint.keep(command.answer(batch), stamp, report, BaseLint.defaultCache());
				why == null ? Passed : Failed(why);
			}
		};
	}

	private static function moved(sha: String): Outcome {
		return Skipped('dropped: the repository is no longer on $sha');
	}

	private static function run(repo: String, sha: String, cache: String, recipe: WarmRecipe): Int {
		function tip(): String return cmd('git -C $repo rev-parse HEAD').run().out.trim();
		final verdict: Outcome = tip() != sha
			? moved(sha)
			: PostLand.inWorktree(repo, sha, DIRECTORY, (work, tree) -> judge(sha, recipe, work, tree, tip));
		Sys.println('baseline-warm: $sha ${why(verdict)}');
		settle(cache, sha, verdict);
		return verdict.match(Failed(_)) ? 1 : 0;
	}

	private static function judge(sha: String, recipe: WarmRecipe, work: String, tree: String, tip: () -> String): Outcome {
		final built: Result = cmd('haxe tools/dev.hxml').at(tree).run();
		if (!built.ok) return Failed('bin/dev.js of $sha did not build: ${built.firstError()}');
		var round: Int = 0;
		function pause(): Void {
			Sleep.pause(POLL_MS);
		}
		final gates: Outcome = warm(sha, variants(recipe), tip, variant -> {
			final logs: String = Path.join([work, 'logs-${round++}']);
			final words: Array<String> = ['node', 'bin/dev.js', 'slice-gate', tree, '--baseline'].concat(variant).concat(['--logs', logs]);
			return warming(Command.of(words).at(tree));
		}, pause);
		if (recipe.infra.length == 0 || gates.match(Skipped(_))) return gates;
		final linted: Outcome = warm(sha, [[BaseLint.ROW]], tip, _ -> baseLint(tree, work), pause);
		return gates.match(Failed(_)) ? gates : linted;
	}

	private static function warming(command: Command): Warming {
		final batch: PendingRuns = command.background();
		return {
			running: batch.running,
			cancel: batch.cancel,
			ended: () -> {
				final result: Result = command.answer(batch);
				Sys.println(result.out + result.err);
				result.ok ? Passed : Failed(result.firstError());
			}
		};
	}

	private static function why(outcome: Outcome): String {
		return switch outcome {
			case Passed: 'recorded';
			case Failed(reason), Skipped(reason), NotRun(reason): reason;
		}
	}

}

/** Which commands a warm run measures: the trees a baseline records as frozen, and the infra trees a rule-code slice lints. */
typedef WarmRecipe = {
	var frozen: Array<String>;
	var infra: Array<String>;
}

/** A gate run in flight: whether it still runs, how to end it, and what it answered once it ended. */
typedef Warming = {
	var running: () -> Bool;
	var cancel: () -> Void;
	var ended: () -> Outcome;
}

/** Starts the warm run of a landed commit in `repo`. */
typedef WarmStart = (repo:String, sha:String) -> Outcome;
