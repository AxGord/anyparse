package anyparse.query.cli.command;

import anyparse.query.cli.CliContext;
import anyparse.runtime.ParseError;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * `apq probe` — aST/writer probe with inline source (no file IO).
 *
 * It reports and never rewrites a source file. It does WRITE one: the probe
 * source is staged to a scratch slot so the next command can chain onto it —
 * see `stageProbePath` for where that lands and why it is per process.
 */
@:nullSafety(Strict)
final class ProbeCommand implements CliCommand {

	/**
	 * Basename stem of the probe scratch slot. The temp root and this
	 * process's own id complete it — see `stageProbePath`.
	 */
	private static inline final STAGE_PROBE_STEM: String = 'anyparse-last-probe';

	/** Env var naming the staging path outright, overriding the resolved one. */
	private static inline final STAGE_PROBE_ENV: String = 'APQ_PROBE_PATH';

	/** Lowest six-digit value, so the non-node process token is always six characters. */
	private static inline final PROCESS_TOKEN_LOW: Int = 100000;

	/** How many six-digit values that token draws from. */
	private static inline final PROCESS_TOKEN_SPAN: Int = 900000;

	private static final AST_BOOL_FLAGS: Array<String> = [
		'--json',
		'--doc',
		'--source',
		'--writer-output',
		'--writer-output-plain',
		'--diff',
		'--stdin',
		'--spans',
		'--type-refs'
	];

	public function new() {}

	public function name(): String {
		return 'probe';
	}

	public function summary(): String {
		return 'AST/writer probe with inline source (no file IO)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runProbe(args);
	}

	public function usage(): Void {
		printProbeUsage();
	}

	private static inline function isAstBoolFlag(flag: String): Bool {
		return AST_BOOL_FLAGS.contains(flag);
	}

	/**
	 * `apq probe '<code>' [ast-options]` — micro-AST probe with inline
	 * source. Replaces the Write→hxq scratch-file dance for 3-5 line
	 * code snippets: `hxq probe 'class C{function f(){…}}' --depth 5`
	 * is byte-equivalent to `hxq ast --code 'class C{…}' --depth 5`
	 * but reads as the call site of a probe, not as an ast inspection
	 * of a file that doesn't exist.
	 *
	 * Accepts every `apq ast` flag (`--depth`, `--select`, `--at`,
	 * `--json`, `--writer-output`, `--writer-output-plain`,
	 * `--writer-output --diff`, `--min-children`, `--max-children`).
	 * Pass `-` as the code argument to read source from stdin instead
	 * — useful when the snippet has shell-quoting trouble or comes
	 * from a heredoc / process substitution.
	 */
	private static function runProbe(args: Array<String>): Int {
		// Bare `apq probe` → usage. Doing the check up front (before the
		// argv walker) keeps the empty-args branch return 0, matching
		// the convention of `apq <cmd>` (no args) elsewhere.
		if (args.length == 0) {
			printProbeUsage();
			return EXIT_OK;
		}
		// The `hxq` shim auto-injects `--lang haxe` after the subcommand,
		// so the code arg is NOT always at args[0]. Walk the array and
		// pick the FIRST non-flag positional (skipping every `--flag`
		// AND its value-bearing successor). All flags are forwarded to
		// `runAst` verbatim; the positional becomes `--code <s>` (or
		// switches to `--stdin` when literal `-`).
		var codeArg: Null<String> = null;
		final forwarded: Array<String> = [];
		// `--writer-probe` is a probe-only flag that diverts the source to
		// `runWriterProbe`'s trivia+plain side-by-side emitter instead of
		// the default `runAst` path. Lives here (not in `runAst`'s flag
		// set) because writer-probe is a multi-pipeline aggregator with
		// no `--depth` / `--select` knobs to compose with. `--lang` IS
		// forwarded because `pickPlugin` needs it.
		var writerProbeMode: Bool = false;
		var lang: String = 'haxe';
		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			if (a == '-h' || a == '--help') {
				printProbeUsage();
				return EXIT_OK;
			}
			if (a == '--writer-probe') {
				writerProbeMode = true;
				i++;
				continue;
			}
			if (a == '--lang') {
				lang = CliArgs.expectValue(args, ++i, '--lang');
				forwarded.push('--lang');
				forwarded.push(lang);
				i++;
				continue;
			}
			if (a.startsWith('--')) {
				forwarded.push(a);
				// Forward the option's value too. Boolean flags like
				// `--json` / `--stdin` / `--writer-output` consume no
				// value — track them by name so we don't eat the code
				// positional. Anything else is value-bearing per `runAst`.
				if (!isAstBoolFlag(a) && i + 1 < args.length) {
					forwarded.push(args[i + 1]);
					i++;
				}
				i++;
				continue;
			}
			if (codeArg != null) {
				CliIo.stderr('apq probe: only one code argument supported (got "$codeArg" and "$a")\n');
				return EXIT_USAGE;
			}
			codeArg = a;
			i++;
		}
		if (codeArg == null) {
			CliIo.stderr('apq probe: missing <code> argument\n');
			printProbeUsage();
			return EXIT_USAGE;
		}
		final codeFinal: String = codeArg;
		// ω-probe-staging: persist the probe source to a per-process scratch
		// path so a follow-up `strip` / `recon --probe` / `writer-equals` can
		// target the same bytes without re-heredoc-ing them. The stdin path is
		// also captured (we read once, write the file, then hand the bytes to
		// runAst via --code instead of --stdin so the downstream loader sees the
		// same source we staged).
		final stagedSource: Null<String> = stageProbeSource(codeFinal);
		if (writerProbeMode) {
			final source: String = stagedSource ?? (codeFinal == '-' ? CliIo.readStdin() : codeFinal);
			final plugin: GrammarPlugin = CliArgs.pickPlugin(lang);
			// `<probe>` is the synthetic file label — matches the byte
			// shape `apq writer-probe` uses on real files and keeps any
			// downstream error message format consistent.
			final triviaOk: Bool = emitOneWriterProbe(plugin, source, '<probe>', lang, false, null);
			final plainOk: Bool = emitOneWriterProbe(plugin, source, '<probe>', lang, true, null);
			return triviaOk && plainOk ? EXIT_OK : EXIT_RUNTIME;
		}
		// When stdin was staged, prefer --code over --stdin so runAst
		// loads the bytes we just persisted (avoids a double stdin read
		// on a now-empty stream). Falls through to the original --stdin
		// path when staging was skipped (#if !sys or codeFinal != '-').
		final injected: Array<String> = if (stagedSource != null)
			['--code', stagedSource];
		else if (codeFinal == '-')
			['--stdin'];
		else
			['--code', codeFinal];
		return AstCommand.runAst(injected.concat(forwarded));
	}

	/**
	 * Resolve the probe source bytes (from arg or stdin), persist them to the
	 * path `stageProbePath` resolves, and emit a stderr nudge naming THAT path
	 * rather than a constant — the nudge is the only thing a caller can chain
	 * from, so it has to carry the name the next command needs.
	 *
	 * Returns the resolved bytes UNCONDITIONALLY on `sys` (whether or not the
	 * write happened) so the caller can re-use them via `--code` instead of
	 * attempting a second stdin read on an already-drained stream. Returns
	 * `null` only on `#if !sys` (no FileSystem access — the caller falls
	 * through to the original argv-passthrough path).
	 *
	 * Inline-arg and stdin-source both stage on `sys`: the user can re-run
	 * `strip <the announced path> …` straight after any `probe` invocation. A
	 * write failure (read-only temp root, disk full, permission) skips the
	 * nudge but still returns the resolved bytes — losing the stdin read AND
	 * failing the probe would be the worse outcome. So does a refusal: staging
	 * is a convenience, never the probe's job.
	 */
	private static function stageProbeSource(codeArg: String): Null<String> {
		#if (sys || nodejs)
		final source: String = codeArg == '-' ? CliIo.readStdin() : codeArg;
		try {
			// Inside the `try` on purpose: resolving the path reads the
			// environment and the OS temp root, and a throw there would
			// otherwise fail a probe that staging is only decorating.
			final path: String = stageProbePath();
			if (isStageTargetSafe(path)) {
				sys.io.File.saveContent(path, source);
				CliIo.stderr('apq probe: staged source -> $path (use it with `apq strip $path …` or `apq recon --probe $path`).\n');
			} else {
				CliIo.stderr(
					'apq probe: not staged — "$path" exists and is not a regular file (symlink, directory or device); '
					+ 'set $STAGE_PROBE_ENV to stage somewhere else.\n'
				);
			}
		} catch (_: Exception) {
			// Write failed (read-only temp root, disk full, permission). Skip
			// the nudge but STILL return the read bytes so the caller can
			// use `--code` instead of `--stdin` — a second stdin read on
			// an already-drained stream would silently parse empty input.
		}
		return source;
		#else
		return null;
		#end
	}

	#if (sys || nodejs)
	/**
	 * The scratch path THIS process stages to: `$STAGE_PROBE_ENV` when set,
	 * else `<temp root>/anyparse-last-probe.<pid>.hx`.
	 *
	 * Both halves are load-bearing and neither alone is enough, measured.
	 * The temp root answers the caller's own isolation — the suite's
	 * `CliFixture.isolateTempDir` (S150) puts every fixture under a private
	 * root, and staging now lands there and is reaped with it. But two
	 * WORKERS on one machine share `$TMPDIR`: on macOS every process of one
	 * user inherits the same `/var/folders/…/T`, and nothing in the campaign
	 * sets its own. So the pid is what actually separates two `apq probe`
	 * processes, and without it the old fixed `/tmp` slot let worker B's
	 * source answer worker A's `strip` — exit 0, no exception, a plausible
	 * WRONG answer. Overlapping writes were worse than that: two truncating
	 * opens interleaved produced a HYBRID file (A's 23 bytes carrying a
	 * residual `}` of B's 24) that neither process ever wrote.
	 *
	 * The single-slot intent survives whole. It was never "one slot per
	 * machine" — it is "a chained `recon --probe` targets the LAST probe,
	 * not a history", and one slot per PROCESS says exactly that for the
	 * only caller that can chain. The nudge prints this resolved path, so
	 * the next command is handed the right name rather than a constant it
	 * has to remember.
	 */
	private static function stageProbePath(): String {
		final explicit: Null<String> = Sys.getEnv(STAGE_PROBE_ENV);
		return explicit != null && explicit.length > 0
			? explicit
			: haxe.io.Path.join([probeTempRoot(), '$STAGE_PROBE_STEM.${processToken()}.hx']);
	}

	/** The OS temp root, mirroring `OracleCache.tempDir` — `$TMPDIR` when the caller set one. */
	private static function probeTempRoot(): String {
		#if nodejs
		return js.node.Os.tmpdir();
		#elseif sys
		final tmp: Null<String> = Sys.getEnv('TMPDIR');
		return tmp != null && tmp.length > 0 ? tmp : '/tmp';
		#end
	}

	/** What separates two concurrent stagings: this process's own id. */
	private static function processToken(): String {
		// No portable pid outside node, and no CLI runner outside it either — a
		// draw keeps two processes apart on a target that never reaches here.
		#if nodejs
		return '${js.Node.process.pid}';
		#elseif sys
		return '${PROCESS_TOKEN_LOW + Std.random(PROCESS_TOKEN_SPAN)}';
		#end
	}

	/**
	 * Whether staging may write `path`. `sys.io.File.saveContent` FOLLOWS a
	 * symlink, so a slot under a shared temp root is otherwise a
	 * write-anywhere primitive with this process's rights: plant a link and
	 * the next `apq probe` overwrites whatever it points at. An absent target
	 * is fine — that is the ordinary first probe.
	 *
	 * A HARD link is not covered and cannot be: it lstats as the regular file
	 * it is. Reachable only by pointing `APQ_PROBE_PATH` into a directory
	 * someone else can write.
	 *
	 * Check-then-write, so not atomic: a link planted in the window between
	 * the two still wins. What closes the window for good is the pid in the
	 * name — an attacker has to guess the slot before the process that owns
	 * it exists — and this check is what stops the case that needs no timing
	 * at all, a link left lying at a predictable path.
	 */
	private static function isStageTargetSafe(path: String): Bool {
		#if nodejs
		// `lstatSync`, not `statSync`: the latter resolves the link and would
		// report the VICTIM's kind, which is exactly the file being protected.
		final stat: Null<js.node.fs.Stats> = try js.node.Fs.lstatSync(path) catch (_: Exception) null;
		return stat == null || stat.isFile();
		#else
		// `sys.FileSystem` has no `lstat` and `exists` FOLLOWS the link, so
		// this branch catches a directory and nothing else — a symlink to a
		// regular file, and a dangling one, both read as writable here. It is
		// weaker than the contract on purpose rather than by oversight, and
		// `docs/cli-query-tool.md` scopes the refusal to the node runner
		// because of it. Nothing in this repo compiles this branch: the
		// `--jvm` portability probe reaches `anyparse.query` and
		// `anyparse.query.format.json` only (measured — 0 of 3346 jar entries
		// under `anyparse/query/cli`), and every hxml that DOES reach this
		// file passes `-lib hxnodejs`. It exists for the hxcpp target the
		// project has not built yet.
		return !sys.FileSystem.exists(path) || !sys.FileSystem.isDirectory(path);
		#end
	}
	#end

	public static function emitOneWriterProbe(
		plugin: GrammarPlugin, source: String, file: String, lang: String, plain: Bool, optsJson: Null<String>
	): Bool {
		final label: String = plain ? 'plain' : 'trivia';
		CliIo.sysPrint('=== $label ===\n');
		final emitted: Null<String> = try (
			plain ? plugin.writeRoundTripPlain(source, optsJson) : plugin.writeRoundTrip(source, optsJson)
		) catch (e: ParseError) {
			CliIo.stderr('apq writer-probe: $label: $file: $e\n');
			return false;
		} catch (e: Exception) {
			CliIo.stderr('apq writer-probe: $label: $file: ${e.message}\n');
			return false;
		}
		if (emitted == null) {
			final flag: String = plain ? '--writer-output-plain' : '--writer-output';
			CliIo.stderr('apq writer-probe: $label: no writer wired up for lang "$lang" ($flag equivalent)\n');
			return false;
		}
		CliIo.sysPrint(emitted);
		if (!StringTools.endsWith(emitted, '\n')) CliIo.sysPrint('\n');
		// DX v10: source-preservation note. The trivia pipeline is meant
		// to round-trip source bytes verbatim (subject to the writer's
		// fidelity); a byte-diff signals an actual writer-fidelity gap
		// (e.g. `HxVarMore` `,` collapsing the space, or `static var`
		// emitted as `staticvar`). Plain pipeline is allowed
		// to canonicalise, so the check is trivia-only. The note is
		// stderr — stdout stays the labelled output, exit code unchanged.
		if (!plain) writerProbeSourcePreservationNote(source, emitted);
		return true;
	}

	private static function writerProbeSourcePreservationNote(source: String, emitted: String): Void {
		if (source == emitted) return;
		final minLen: Int = source.length < emitted.length ? source.length : emitted.length;
		var diffAt: Int = minLen;
		for (i in 0...minLen) if (source.fastCodeAt(i) != emitted.fastCodeAt(i)) {
			diffAt = i;
			break;
		}
		// Show a small window around the divergence on each side so the
		// reader can immediately see the missing/extra bytes without
		// re-running a diff tool.
		final wnd: Int = 8;
		final sFrom: Int = diffAt - wnd >= 0 ? diffAt - wnd : 0;
		final sExp: String = escapeProbeWindow(source.substring(sFrom, diffAt + wnd < source.length ? diffAt + wnd : source.length));
		final sAct: String = escapeProbeWindow(emitted.substring(sFrom, diffAt + wnd < emitted.length ? diffAt + wnd : emitted.length));
		CliIo.stderr('apq writer-probe: NOTE trivia output differs from source at offset $diffAt (writer-fidelity gap)\n');
		CliIo.stderr('  source : "$sExp"\n');
		CliIo.stderr('  emitted: "$sAct"\n');
	}

	private static function escapeProbeWindow(s: String): String {
		final buf: StringBuf = new StringBuf();
		for (i in 0...s.length) {
			final c: Int = s.fastCodeAt(i);
			switch c {
				case '\n'.code:
					buf.add('\\n');
				case '\t'.code:
					buf.add('\\t');
				case '\r'.code:
					buf.add('\\r');
				case '"'.code:
					buf.add('\\"');
				case _:
					buf.addChar(c);
			}
		}
		return buf.toString();
	}

	private static function printProbeUsage(): Void {
		CliIo.sysPrint('Usage: apq probe <code> [ast-options]\n');
		CliIo.sysPrint('       apq probe - [ast-options]   (read code from stdin)\n');
		CliIo.sysPrint('       apq probe <code> --writer-probe   (trivia + plain side-by-side)\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Inline-source variant of `apq ast`. Accepts every ast option\n');
		CliIo.sysPrint('(--depth/--select/--at/--json/--writer-output/--writer-output-plain/\n');
		CliIo.sysPrint('--writer-output --diff/--min-children/--max-children/--lang).\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('--writer-probe diverts to the `writer-probe` aggregator: emits BOTH\n');
		CliIo.sysPrint('the trivia and plain writer outputs separated by `=== trivia ===` /\n');
		CliIo.sysPrint('`=== plain ===` fences. Mirrors `apq writer-probe <file>` for inline\n');
		CliIo.sysPrint('source — no scratch file needed.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('The source is staged to a scratch slot and the path is printed on\n');
		CliIo.sysPrint('stderr — read it from there, it is per-process. $STAGE_PROBE_ENV\n');
		CliIo.sysPrint('names the slot outright.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Example:\n');
		CliIo.sysPrint("  apq probe 'class C { function f() { @:m return switch x { case _: 0; } } }' --depth 6\n");
		CliIo.sysPrint("  apq probe 'class C {}' --writer-probe\n");
	}

}
