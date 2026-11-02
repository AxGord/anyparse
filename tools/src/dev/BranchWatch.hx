package dev;

/**
 * The one answer to "how long may a gate branch go without starting a row before it is cut": each row's limit is a few
 * times the slowest honest run of the row on a loaded pool, since a row's own commands print nothing until they end, and a
 * branch's limit is the longest of its rows'. The suite row is also watched shard by shard (`Shard.IDLE_MS`), and the
 * arms row rewrites the progress file as each track ends, so its limit bounds the gap between tracks, not the run.
 */
@:nullSafety(Strict)
final class BranchWatch {

	/** The environment variable whose value, in milliseconds, replaces every limit: how a test makes a stand-in branch stall quickly. */
	public static inline final IDLE_VAR: String = 'SLICE_GATE_IDLE_MS';

	private static inline final MS_PER_MINUTE: Int = 60 * 1000;

	/** The limit of a row `LIMITS` does not name, in minutes. */
	private static inline final DEFAULT_MINUTES: Int = 20;

	/** The limit of each gate row, in minutes. */
	private static final LIMITS: Map<String, Int> = [
		'suite' => 20,
		'lists' => 5,
		'corpus' => 10,
		'fmt' => 10,
		'lint' => 20,
		'jvm' => 20,
		'infra4' => 30,
		'scrub' => 10,
		'artifacts' => 5,
		'kits' => 15,
		'arms' => 45
	];

	/** How long the branch running `rows` may go without starting a row before it is cut, in milliseconds. */
	public static function idleOf(rows: Array<String>): Int {
		final declared: Int = Std.parseInt(Sys.getEnv(IDLE_VAR) ?? '') ?? 0;
		if (declared > 0) return declared;
		var minutes: Int = 0;
		for (name in rows) minutes = Std.int(Math.max(minutes, LIMITS[name] ?? DEFAULT_MINUTES));
		return minutes * MS_PER_MINUTE;
	}

}
