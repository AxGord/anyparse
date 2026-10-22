package dev;

import devkit.Args;
import devkit.FixtureCache;

/**
 * `dev fixture-cache shim | prune | tally` — `devkit.FixtureCache` from the command line: write the probe-compile shim,
 * drop the entries no run has hit for `FC_MAX_AGE_DAYS` days, or count what one run's compiles did.
 */
@:nullSafety(Strict)
final class FixtureCacheCli {

	public static inline final USAGE: String =
		'usage: dev fixture-cache shim <repo> <entries> <bindir> [<tally>] | prune <entries> | tally <tally-file>';

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final given: Array<String> = args.positionals(['shim|prune|tally', '<path>'], ['<entries>', '<bindir>', '<tally>']);
		switch given {
			case ['shim', repo, entries, bindir], ['shim', repo, entries, bindir, _]:
				final why: Null<String> = FixtureCache.shim(repo, entries, bindir, given[4]);
				if (why == null) return 0;
				Sys.stderr().writeString('$why\n');
				return 1;
			case ['prune', entries]:
				FixtureCache.prune(entries, FixtureCache.maxAgeDays());
				return 0;
			case ['tally', file]:
				final counts: Null<String> = FixtureCache.tally(file);
				if (counts != null && counts != '') Sys.println(counts);
				return 0;
			case _:
				throw new UsageError('unexpected ${given.join(' ')}');
		}
	}

}
