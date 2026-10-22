package dev;

import devkit.Args;
import devkit.Cmd.cmd;
import devkit.TmpLifecycle;

using StringTools;

/**
 * `dev tmp-lifecycle [--list | --sweep]` — the hand tool over the scratch directories this project's tools claim
 * (`devkit.TmpLifecycle`): `--list` (the default) prints each with its owner pid, its state, its idle seconds and its
 * size; `--sweep` removes every orphan now, as each tool's startup sweep does.
 */
@:nullSafety(Strict)
final class Tmp {

	public static inline final USAGE: String = 'usage: dev tmp-lifecycle [--list | --sweep]';

	/** The listing's column widths, as `tools/tmp-lifecycle.sh --list` prints them. */
	private static inline final OWNER_WIDTH: Int = 10;

	private static inline final STATE_WIDTH: Int = 9;
	private static inline final IDLE_WIDTH: Int = 8;
	private static inline final SIZE_WIDTH: Int = 6;

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final sweep: Bool = args.flag('--sweep');
		final list: Bool = args.flag('--list');
		args.done();
		if (sweep && list) throw new UsageError('--list and --sweep are two runs');
		final dirs: TmpLifecycle = TmpLifecycle.fromEnv();
		if (sweep) {
			if ((Sys.getEnv('APQ_TMP_NO_SWEEP') ?? '') == '') {
				final swept: Int = dirs.sweep(TmpLifecycle.now(), Repo.ofScript());
				final noun: String = swept == 1 ? 'directory' : 'directories';
				if (swept > 0) Sys.stderr().writeString('tmp-lifecycle: swept $swept orphaned scratch $noun under ${dirs.root}\n');
			}
			Sys.println('tmp-lifecycle: sweep done');
			return 0;
		}
		Sys.println(row('OWNER', 'STATE', 'IDLE'.rpad(' ', IDLE_WIDTH), 'SIZE', 'DIRECTORY'));
		for (dir in dirs.claimed()) {
			final now: Int = TmpLifecycle.now();
			final state: String = if (dirs.isKept(dir))
				'KEEP'
			else if (dirs.isOrphan(dir, now))
				'ORPHAN'
			else
				'live/young';
			final idle: Int = now - (dirs.newestMtime(dir) ?? 0);
			final size: String = cmd('du -sh $dir').run().out.split('\t')[0].trim();
			Sys.println(row(dirs.ownerPid(dir) ?? '-', state, '${idle}s'.lpad(' ', IDLE_WIDTH), size, dir));
		}
		return 0;
	}

	/** One line of the listing. */
	private static function row(owner: String, state: String, idle: String, size: String, dir: String): String {
		return '${owner.rpad(' ', OWNER_WIDTH)} ${state.rpad(' ', STATE_WIDTH)} $idle ${size.lpad(' ', SIZE_WIDTH)}  $dir';
	}

}
