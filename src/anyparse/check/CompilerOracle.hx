package anyparse.check;

import anyparse.check.HaxeSpawn.HaxeRun;

/**
 * The verdict of one compiler-oracle typecheck run — `apq lint`'s bridge to
 * treating the Haxe compiler as ground truth. A project opts in through the
 * `apqlint.json` `compilerOracle` key (a path to an `.hxml`); the linter then
 * runs `haxe <hxml> --no-output` and folds the result back into the run:
 *
 *  - `Confirmed`   — the project typechecks; report mode annotates its
 *    `@:nullSafety` trust as compiler-confirmed, fix mode keeps a risky fix.
 *  - `Rejected`    — the project does NOT typecheck; carries the compiler's
 *    error text. Report mode fails the lint; fix mode reverts the risky edit.
 *  - `Unavailable` — the oracle could not run (no `haxe` on PATH, a non-sys/
 *    nodejs target, or a spawn that produced no exit status). Treated
 *    conservatively: a report run degrades to a note (never a failure), a
 *    risky fix is left unapplied (report-only) since safety cannot be shown.
 */
enum OracleOutcome {
	Confirmed;
	Rejected(errors: String);
	Unavailable(reason: String);
}

/**
 * Runs the Haxe compiler as a lint oracle: `haxe <hxml> --no-output` in a child
 * process, mapping its exit status to an `OracleOutcome`. Stateless bar
 * `invocations` — a spawn counter tests read to prove the gate-invariant that
 * WITHOUT a configured `compilerOracle` the compiler is never launched (see
 * `FixVerifier` / `Cli.runLint`).
 *
 * The spawn itself is `HaxeSpawn`, shared with the two `-v` probes — the target
 * conditional, the output buffer and the four ways a run can produce no verdict all
 * live there. `cwd` is honoured on nodejs; the native sys branch IGNORES it and runs
 * in the process CWD, so an hxml's own relative `-cp` entries resolve against the
 * wrong root there (`HaxeSpawn.honoursCwd`).
 */
@:nullSafety(Strict)
final class CompilerOracle {

	/**
	 * Output buffer for the typecheck spawn, in bytes.
	 *
	 * Node's default is 1 MiB, and an overflow there is not a lost log line: it arrives as
	 * a spawn ERROR with a null status and a truncated stream, so a build whose errors run
	 * long was reported as a rejection quoting a cut-off transcript. `OracleCoverage`
	 * already pays 256 MiB for a `-v` probe on the same projects; a typecheck's error text
	 * is far smaller than that, so the cap only ever costs address space that is never
	 * touched.
	 */
	private static inline final ORACLE_BUFFER: Int = 256 * 1024 * 1024;

	/** Total typecheck spawns this process — tests assert 0 when no oracle is configured. */
	public static var invocations(default, null): Int = 0;

	/**
	 * Typecheck the project described by `hxml` (a path resolved by the caller,
	 * relative to `cwd` when given) and return the compiler's verdict. `--no-output`
	 * forces a type-only pass, so a code-emitting `.hxml` is reused unchanged. A
	 * missing `haxe`, a non-process target, or a status-less spawn all map to
	 * `Unavailable` rather than throwing — the oracle degrades, never crashes the lint.
	 */
	public static function typecheck(hxml: String, ?cwd: String): OracleOutcome {
		invocations++;
		final run: HaxeRun = HaxeSpawn.run([hxml, '--no-output'], cwd, ORACLE_BUFFER);
		// An overflow is the compiler having RUN and out-written the buffer; a build that
		// verbose is failing, so it is a rejection carrying the partial errors rather than
		// unavailability. Every other launch failure means haxe never ran.
		if (run.overflowed) return Rejected(StringTools.trim(run.err + run.out));
		if (run.failure != '') return Unavailable(run.failure);
		return switch (run.status) {
			case null: Unavailable('haxe exited without a status code');
			case 0: Confirmed;
			case _: Rejected(StringTools.trim(run.err + run.out));
		};
	}

}
