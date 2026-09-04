package anyparse.query.cli.command;

import anyparse.query.cli.CliContext;
import anyparse.runtime.ParseError;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * `apq probe` — aST/writer probe with inline source (no file IO).
 *
 * A READ-ONLY command: it reports and never writes.
 */
@:nullSafety(Strict)
final class ProbeCommand implements CliCommand {

	private static inline final STAGE_PROBE_PATH: String = '/tmp/anyparse-last-probe.hx';

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
		// ω-probe-staging: persist the probe source to a fixed scratch
		// path so a follow-up `strip` / `recon --probe` / `writer-equals`
		// can target the same bytes without re-heredoc-ing them. The
		// stdin path is also captured (we read once, write to /tmp, then
		// hand the bytes to runAst via --code instead of --stdin so the
		// downstream loader sees the same source we staged).
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
	 * Resolve the probe source bytes (from arg or stdin), persist them to
	 * `/tmp/anyparse-last-probe.hx`, and emit a stderr nudge naming the
	 * path. Returns the resolved bytes UNCONDITIONALLY on `sys` (whether
	 * or not the write succeeded) so the caller can re-use them via
	 * `--code` instead of attempting a second stdin read on an already-
	 * drained stream. Returns `null` only on `#if !sys` (no FileSystem
	 * access — the caller falls through to the original argv-passthrough
	 * path).
	 *
	 * Inline-arg and stdin-source both stage on `sys`: the user can
	 * re-run `strip /tmp/anyparse-last-probe.hx …` straight after any
	 * `probe` invocation. A write failure (read-only /tmp, disk full,
	 * permission) skips the nudge but still returns the resolved bytes —
	 * losing the stdin read AND failing the probe would be the worse
	 * outcome.
	 *
	 * `STAGE_PROBE_PATH` is a constant (not a flag) — the scratch path
	 * is single-slot by design (a chained `recon --probe` should target
	 * the LAST probe, not pick from a history).
	 */
	private static function stageProbeSource(codeArg: String): Null<String> {
		#if (sys || nodejs)
		final source: String = codeArg == '-' ? CliIo.readStdin() : codeArg;
		try {
			sys.io.File.saveContent(STAGE_PROBE_PATH, source);
			CliIo.stderr(
				'apq probe: staged source -> $STAGE_PROBE_PATH (use it with `apq strip $STAGE_PROBE_PATH …` or `apq recon --probe '
				+ '$STAGE_PROBE_PATH`).\n'
			);
		} catch (_: Exception) {
			// Write failed (read-only /tmp, disk full, permission). Skip
			// the nudge but STILL return the read bytes so the caller can
			// use `--code` instead of `--stdin` — a second stdin read on
			// an already-drained stream would silently parse empty input.
		}
		return source;
		#else
		return null;
		#end
	}

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
		CliIo.sysPrint('Example:\n');
		CliIo.sysPrint("  apq probe 'class C { function f() { @:m return switch x { case _: 0; } } }' --depth 6\n");
		CliIo.sysPrint("  apq probe 'class C {}' --writer-probe\n");
	}

}
