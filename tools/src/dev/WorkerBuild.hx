package dev;

import devkit.Args;
import devkit.Cmd.cmd;
import devkit.Pool;
import devkit.Result;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * `dev worker-build <workdir> [both|apq|test]` — a PRIVATE `apq.js` / `test.js` for one worker, built from the tree that
 * holds this `dev.js` (or `--repo`) into `<workdir>`, never into the shared `bin/` two workers would truncate under each
 * other. Both builds run at once; each writes `<workdir>/build-<job>.log`. `APQ_HAXE_SERVER=<port>` compiles through a
 * running `haxe --wait <port>` (docs/testing.md § "Mutation runs: slots, servers and the fixture cache").
 */
@:nullSafety(Strict)
final class WorkerBuild {

	public static inline final USAGE: String = 'usage: dev worker-build <workdir> [both|apq|test] [--repo <tree>]';

	/** The lines of a failed build's log shown under its refusal. */
	private static inline final LOG_TAIL: Int = 30;

	/** Each job: its name, the hxml it builds with, the artifact it writes. */
	private static final JOBS: Array<{ name: String, hxml: String, artifact: String }> = [
		{ name: 'apq', hxml: 'bin/apq-js-common.hxml', artifact: 'apq.js' },
		{ name: 'test', hxml: 'test-js-common.hxml', artifact: 'test.js' }
	];

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final repo: String = Repo.resolve(args.option('--repo'));
		final given: Array<String> = args.positionals(['<workdir>'], ['<target>']);
		final workdir: String = given[0];
		final target: String = given[1] ?? 'both';
		if (workdir == '') throw new UsageError('empty <workdir>');
		if (!['both', 'apq', 'test'].contains(target)) throw new UsageError('unknown target \'$target\' (expected both|apq|test)');
		FileSystem.createDirectory(workdir);
		final out: String = FileSystem.fullPath(workdir);
		if (out == Path.join([repo, 'bin']) && !isLinkedWorktree(repo))
			throw new UsageError(
				'<workdir> is the repo\'s own bin/ — that is the shared build this tool exists to avoid; pick a private directory'
			);
		final server: Null<String> = Sys.getEnv('APQ_HAXE_SERVER');
		final connect: Array<String> = server == null || server == '' ? [] : ['--connect', server];
		final jobs: Array<{ name: String, hxml: String, artifact: String }> = JOBS.filter(j -> target == 'both' || target == j.name);
		final results: Array<Result> = Pool.of(jobs.length)
			.map(jobs, j -> cmd('haxe $connect ${j.hxml} -js $out/${j.artifact} ${launcherBuild(j.name, out)}').at(repo));
		var failed: Bool = false;
		for (i => job in jobs) {
			final result: Result = results[i];
			final log: String = '$out/build-${job.name}.log';
			File.saveContent(log, result.out + result.err + (result.failure == '' ? '' : '${result.failure}\n'));
			if (result.ok) continue;
			failed = true;
			final lines: Array<String> = File.getContent(log).split('\n');
			if (lines[lines.length - 1] == '') lines.pop();
			Sys.stderr().writeString('dev worker-build: ${job.name} build FAILED — $log\n${lines.slice(-LOG_TAIL).join('\n')}\n');
		}
		if (failed) return 1;
		if (target != 'test') {
			final warm: Result = cmd('sh $repo/bin/apq --warm-code-cache').env('HXQ_BIN', '$out/apq.js').at(repo).run();
			File.saveContent('$out/build-apq.log', File.getContent('$out/build-apq.log') + warm.out + warm.err);
		}
		for (job in jobs) Sys.println('${job.name}: $out/${job.artifact}');
		return 0;
	}

	/**
	 * Whether `repo` is a LINKED worktree (`git worktree add`), whose `bin/` is a private, gitignored artifact nothing
	 * else can clobber: there `--git-dir` names `.git/worktrees/<name>` while `--git-common-dir` names the shared `.git`;
	 * in the main tree the two agree. A tree git cannot read counts as the main one — refusing is the safe default.
	 */
	private static function isLinkedWorktree(repo: String): Bool {
		final dir: Result = cmd('git rev-parse --git-dir').at(repo).run();
		final common: Result = cmd('git rev-parse --git-common-dir').at(repo).run();
		return dir.ok && common.ok && dir.out.trim() != common.out.trim();
	}

	/**
	 * The `--next` half of the `apq` job: the code-cache launcher beside the private engine, whose cache `main` then warms
	 * through the shim as `bin/apq-js.hxml` does (`anyparse.query.cli.CodeCacheLauncher`).
	 */
	private static function launcherBuild(job: String, out: String): Array<String> {
		return job == 'apq' ? ['--next', 'bin/apq-launch-common.hxml', '-js', '$out/apq-launch.js'] : [];
	}

}
