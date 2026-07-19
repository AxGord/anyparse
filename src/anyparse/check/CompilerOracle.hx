package anyparse.check;

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
 * Process spawn is target-conditional: `js.node.ChildProcess.spawnSync` under
 * nodejs (the target `apq` ships on), `sys.io.Process` on a native sys target,
 * and a compile-time `Unavailable` on a pure target with no process API — so
 * the class type-checks under `#if (sys || nodejs)` everywhere while only the
 * nodejs path is exercised in practice. `cwd` is honoured on nodejs; a native
 * sys spawn resolves relative `.hxml` paths against the process CWD.
 */
@:nullSafety(Strict)
final class CompilerOracle {

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
		#if nodejs
		final options: Dynamic = { encoding: 'utf8' };
		if (cwd != null) Reflect.setField(options, 'cwd', cwd);
		final res = js.node.ChildProcess.spawnSync('haxe', [hxml, '--no-output'], options);
		final launchError: Null<Dynamic> = (res.error: Dynamic);
		if (launchError != null) {
			// ENOBUFS = the compiler out-wrote the default output buffer; a build that
			// verbose is failing, so treat overflow as a rejection (with the partial
			// errors) rather than unavailability. Any other spawn error means haxe never
			// ran (missing binary, permission) -> Unavailable.
			final code: Null<Dynamic> = Reflect.field(launchError, 'code');
			if (code != null && Std.string(code) == 'ENOBUFS')
				return Rejected(StringTools.trim(oracleText(res.stderr) + oracleText(res.stdout)));
			return Unavailable('could not launch haxe (${Reflect.field(launchError, 'message')})');
		}
		final status: Null<Int> = (res.status: Null<Int>);
		if (status == null) return Unavailable('haxe exited without a status code');
		if (status == 0) return Confirmed;
		return Rejected(StringTools.trim(oracleText(res.stderr) + oracleText(res.stdout)));
		#elseif sys
		try {
			final process: sys.io.Process = new sys.io.Process('haxe', [hxml, '--no-output']);
			final code: Int = process.exitCode();
			final errText: String = StringTools.trim(process.stderr.readAll().toString() + process.stdout.readAll().toString());
			process.close();
			return code == 0 ? Confirmed : Rejected(errText);
		} catch (exception: haxe.Exception) {
			return Unavailable('could not launch haxe (${exception.message})');
		}
		#else
		return Unavailable('compiler oracle requires a sys or nodejs target');
		#end
	}

	#if nodejs
	/** Coerce a possibly-null spawn stream field (Buffer|String under utf8) to a String. */
	static function oracleText(value: Dynamic): String {
		return value == null ? '' : Std.string(value);
	}
	#end

}
