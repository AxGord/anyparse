package anyparse.query.cli.command;

import anyparse.query.cli.CliContext;
import anyparse.runtime.ParseError;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * `apq writer-equals` — byte-equality check on writer output (trivia + --plain).
 *
 * A READ-ONLY command: it reports and never writes.
 */
@:nullSafety(Strict)
final class WriterEqualsCommand implements CliCommand {

	private static inline final BYTE_DIFF_WINDOW: Int = 40;

	private static inline final BYTE_DIFF_LEAD: Int = 4;

	public function new() {}

	public function name(): String {
		return 'writer-equals';
	}

	public function summary(): String {
		return 'Byte-equality check on writer output (trivia + --plain)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runWriterEquals(args);
	}

	public function usage(): Void {
		printWriterEqualsUsage();
	}

	/**
	 * Read a file as **expected output bytes** for byte-comparison
	 * (`writer-equals <input> <expected>`). Symmetric to
	 * `readSourceForParse`: when the path ends with `.hxtest` and has the
	 * canonical 3-section layout, returns section 3 (the fork's reference
	 * formatted output); otherwise returns the raw bytes. Lets a fork
	 * fixture serve as its own expected-bytes file in one command instead
	 * of pre-extracting via `awk` / scratch file.
	 */
	public static inline function readExpectedForCompare(path: String): String {
		return CliIo.readHxtestSectionOrRaw(path, 2);
	}

	/**
	 * `apq writer-equals <input> <expected> [--plain] [--lang haxe]` —
	 * byte-equality check on writer output. Parses `<input>`, writes via
	 * the plugin's trivia pipeline (default) or plain pipeline (`--plain`),
	 * compares the emitted bytes against the contents of `<expected>`.
	 *
	 * Exit 0 on match, 1 on byte-diff (or parse/write failure). On diff
	 * prints a single `apq writer-equals: byte-diff @ <offset>  exp=<…>
	 * act=<…>  (exp.len=…, act.len=…)` line — same shape as the corpus
	 * harness's `describeDiff`. Constructed for the writer-bug iteration
	 * loop where running a full Haxe probe + hxml + compile + node would
	 * be 4× slower.
	 *
	 * Default writer is TRIVIA (matches corpus + `--writer-output`).
	 * `--plain` selects the PLAIN writer that matches unit tests of the
	 * form `HxModuleWriter.write(HaxeModuleParser.parse(src))`. Always
	 * probe the pipeline that matches the test entry being constructed.
	 */
	private static function runWriterEquals(args: Array<String>): Int {
		var lang: String = 'haxe';
		var plain: Bool = false;
		var inputPath: Null<String> = null;
		var expectedPath: Null<String> = null;
		var configPath: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--plain':
					plain = true;
				case '--config':
					configPath = CliArgs.expectValue(args, ++i, '--config');
				case '-h', '--help':
					printWriterEqualsUsage();
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq writer-equals: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (inputPath == null)
						inputPath = a;
					else if (expectedPath == null)
						expectedPath = a;
					else {
						CliIo.stderr('apq writer-equals: expects exactly two paths (input, expected); got extra "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (inputPath == null || expectedPath == null) {
			CliIo.stderr('apq writer-equals: missing <input> and/or <expected> argument\n');
			printWriterEqualsUsage();
			return EXIT_USAGE;
		}
		final inputPathFinal: String = inputPath;
		final expectedPathFinal: String = expectedPath;
		final plugin: GrammarPlugin = CliArgs.pickPlugin(lang);
		final source: String = CliIo.readSourceForParse(inputPathFinal);
		final expected: String = readExpectedForCompare(expectedPathFinal);
		// Config precedence: section-1 from a `.hxtest` input wins (per-
		// fixture intent), fall back to `--config <path>` (project-wide
		// opt-in for plain `.hx` files — dogfood `.hxformat.json` etc.),
		// then plugin defaults.
		final sectionOpts: Null<String> = CliArgs.readWriteOptionsJsonOrNull(inputPathFinal);
		final optsJson: Null<String> = sectionOpts ?? (configPath != null ? CliIo.readFile(configPath) : null);

		final emitted: Null<String> = try (
			plain ? plugin.writeRoundTripPlain(source, optsJson) : plugin.writeRoundTrip(source, optsJson)
		) catch (e: ParseError) {
			CliIo.stderr('apq writer-equals: $inputPathFinal: $e\n');
			return EXIT_RUNTIME;
		} catch (e: Exception) {
			CliIo.stderr('apq writer-equals: $inputPathFinal: ${e.message}\n');
			return EXIT_RUNTIME;
		}
		if (emitted == null) {
			final flagName: String = plain ? '--plain' : '(trivia)';
			CliIo.stderr('apq writer-equals: no writer wired up for lang "$lang" $flagName\n');
			return EXIT_USAGE;
		}
		if (emitted == expected) return EXIT_OK;
		CliIo.sysPrint('${describeByteDiff(emitted, expected)}\n');
		return EXIT_RUNTIME;
	}

	public static function describeByteDiff(actual: String, expected: String): String {
		final maxLen: Int = expected.length < actual.length ? expected.length : actual.length;
		var diffAt: Int = -1;
		for (idx in 0...maxLen) if (expected.fastCodeAt(idx) != actual.fastCodeAt(idx)) {
			diffAt = idx;
			break;
		}
		if (diffAt == -1) diffAt = maxLen;
		final start: Int = diffAt - BYTE_DIFF_LEAD < 0 ? 0 : diffAt - BYTE_DIFF_LEAD;
		final expWin: String = escapeWindow(expected.substr(start, BYTE_DIFF_WINDOW));
		final actWin: String = escapeWindow(actual.substr(start, BYTE_DIFF_WINDOW));
		return
			'apq writer-equals: byte-diff @ $diffAt  exp=<$expWin>  act=<$actWin>  (exp.len=${expected.length}, act.len=${actual.length})';
	}

	private static function escapeWindow(s: String): String {
		final buf: StringBuf = new StringBuf();
		for (idx in 0...s.length) {
			final c: Int = s.fastCodeAt(idx);
			switch c {
				case '\n'.code:
					buf.add('\\n');
				case '\t'.code:
					buf.add('\\t');
				case '\r'.code:
					buf.add('\\r');
				case _:
					buf.addChar(c);
			}
		}
		return buf.toString();
	}

	private static function printWriterEqualsUsage(): Void {
		CliIo.sysPrint('Usage: apq writer-equals [options] <input> <expected>\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --plain             Use the plain (non-trivia) writer (mirrors unit tests)\n');
		CliIo.sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		CliIo.sysPrint('  --config <path>     Load writer options from JSON file (hxformat.json-shaped).\n');
		CliIo.sysPrint('                      Used for plain .hx inputs (dogfood opt-in); a .hxtest section-1\n');
		CliIo.sysPrint('                      always wins over this flag.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Parse <input>, write through the grammar plugin (trivia pipeline by\n');
		CliIo.sysPrint('default, plain pipeline with --plain), compare against bytes of <expected>.\n');
		CliIo.sysPrint('Exit 0 on match, 1 on byte-diff or parse/write failure.\n');
	}

}
