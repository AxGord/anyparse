package dev;

import anyparse.query.BuildFailure;
import devkit.Excerpt;

using StringTools;

/**
 * The one answer to "which lines of a gate row's log decide its failure": the suite's red shards, the findings a lint
 * added, the arms that were not killed — the lines the slice gate prints under its table, so a worker never opens a
 * gate log. Each reader takes the text a row already wrote to its log and answers the lines; `devkit.Excerpt` bounds them.
 */
@:nullSafety(Strict)
final class GateExcerpt {

	/** The verdict words of a track whose cut built and ran and whose own pin did not go red. */
	public static final UNKILLED: Array<String> = ['SURVIVED', 'MISMATCH'];

	/** The verdict word of a track row of `dev mutation-arm`, and the arm it names after it. */
	private static final TRACK_ROW: EReg = ~/^([A-Z][A-Z-]*) +(\S+)/;

	/** The verdict words of a track that held. */
	private static final HELD: Array<String> = ['KILLED', 'APPLIES'];

	/**
	 * The error lines of a haxe build `log` (`BuildFailure.errorLines`, continuations included, no warning); the
	 * error-looking lines of it when the compiler printed none in its own shape.
	 */
	public static function compile(log: String): Array<String> {
		final found: Array<String> = BuildFailure.errorLines(log);
		return found.length == 0 ? Excerpt.errors(log) : found;
	}

	/**
	 * The lines of a `dev shard` transcript that name what went red: each red shard's first failure and failing tests
	 * (`TestTranscript`'s extraction, which `dev shard` prints), a shard that did not finish, the verdict and the
	 * tool's own warnings; the last lines when the transcript names none.
	 */
	public static function suite(lines: Array<String>): Array<String> {
		final red: Array<String> = lines.filter(
			line ->
				line.startsWith('  shard ')
				|| line.startsWith('suite-shard: FAILED')
				|| line.startsWith('dev shard:')
				|| line.indexOf('exit-status disagreement') >= 0
				|| line.indexOf('did NOT finish') >= 0
		);
		return red.length == 0 ? Excerpt.tail(lines.join('\n')) : red;
	}

	/**
	 * The rows `hxq lint-diff` printed for findings that appeared (`  + `) and, with `removed`, for those that went (`  - `),
	 * each without its indentation.
	 */
	public static function lintRows(report: String, removed: Bool): Array<String> {
		return [
			for (line in report.split('\n')) if (line.startsWith('  + ') || (removed && line.startsWith('  - '))) line.trim()
		];
	}

	/**
	 * The track rows of a `dev mutation-arm` log whose verdict is not that the arm held (`SURVIVED`, `MISMATCH`, a
	 * build that failed); the error-looking lines when no row says so.
	 */
	public static function arms(log: String): Array<String> {
		final rows: Array<ArmRow> = armRows(log);
		return rows.length == 0 ? Excerpt.errors(log) : rows.map(row -> row.line);
	}

	/** The track rows of a `dev mutation-arm` log whose verdict is not that the arm held, each read into its verdict and arm. */
	public static function armRows(log: String): Array<ArmRow> {
		return [
			for (line in Excerpt.linesOf(log))
				if (TRACK_ROW.match(line) && !HELD.contains(TRACK_ROW.matched(1)))
					{ verdict: TRACK_ROW.matched(1), name: TRACK_ROW.matched(2), line: line }
		];
	}

	/** The arms `log` shows killed: only a printed `KILLED` row says so, a track that printed no row is not one. */
	public static function killedNames(log: String): Array<String> {
		return [
			for (line in Excerpt.linesOf(log)) if (TRACK_ROW.match(line) && TRACK_ROW.matched(1) == 'KILLED') TRACK_ROW.matched(2)
		];
	}

}

/** A track row of `dev mutation-arm`, read. */
typedef ArmRow = {
	var verdict: String;
	var name: String;
	var line: String;
}
