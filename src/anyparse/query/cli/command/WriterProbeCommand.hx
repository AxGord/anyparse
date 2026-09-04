package anyparse.query.cli.command;

import anyparse.query.cli.CliContext;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * `apq writer-probe` — emit trivia + plain writer outputs side-by-side.
 *
 * A READ-ONLY command: it reports and never writes.
 */
@:nullSafety(Strict)
final class WriterProbeCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'writer-probe';
	}

	public function summary(): String {
		return 'Emit trivia + plain writer outputs side-by-side';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runWriterProbe(args);
	}

	public function usage(): Void {
		printWriterProbeUsage();
	}

	/**
	 * `apq writer-probe <input> [--lang haxe]` — emit BOTH trivia and
	 * plain writer outputs in one call, separated by labelled fences.
	 * Replaces the `hxq ast … --writer-output` + `hxq ast …
	 * --writer-output-plain` two-command dance when constructing a
	 * unit-test `writerEquals` expected literal: side-by-side output
	 * makes the pipeline divergence (anon structs flatten, terminators
	 * change, comments drop in plain) immediately visible.
	 *
	 * Each pipeline runs independently; one failing does not abort the
	 * other. Exit 0 only when both succeed. Output format:
	 *   === trivia ===
	 *   <bytes>
	 *   === plain ===
	 *   <bytes>
	 *
	 * The `=== trivia ===` / `=== plain ===` fences are deliberately
	 * verbatim (no shell metacharacters) so a downstream `awk` /
	 * `split` can pull either section without ambiguity.
	 */
	private static function runWriterProbe(args: Array<String>): Int {
		var lang: String = 'haxe';
		var file: Null<String> = null;
		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '-h', '--help':
					printWriterProbeUsage();
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq writer-probe: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file != null) {
						CliIo.stderr('apq writer-probe: only one file argument supported (got "$file" and "$a")\n');
						return EXIT_USAGE;
					}
					file = a;
			}
			i++;
		}
		if (file == null) {
			CliIo.stderr('apq writer-probe: missing <file> argument\n');
			printWriterProbeUsage();
			return EXIT_USAGE;
		}
		final fileFinal: String = file;
		final plugin: GrammarPlugin = CliArgs.pickPlugin(lang);
		final source: String = CliIo.readSourceForParse(fileFinal);
		// `.hxtest` section-1 config drives BOTH labelled probes so the
		// trivia ↔ plain comparison reflects the corpus harness's actual
		// writer surface for this fixture.
		final optsJson: Null<String> = CliArgs.readWriteOptionsJsonOrNull(fileFinal);
		final triviaOk: Bool = ProbeCommand.emitOneWriterProbe(plugin, source, fileFinal, lang, false, optsJson);
		final plainOk: Bool = ProbeCommand.emitOneWriterProbe(plugin, source, fileFinal, lang, true, optsJson);
		return triviaOk && plainOk ? EXIT_OK : EXIT_RUNTIME;
	}

	private static function printWriterProbeUsage(): Void {
		CliIo.sysPrint('Usage: apq writer-probe [options] <file>\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --lang <name>       Grammar plugin (default: haxe)\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Parse <file>, run BOTH the trivia and plain writer pipelines, and\n');
		CliIo.sysPrint('emit each output between labelled fences:\n');
		CliIo.sysPrint('  === trivia ===\n');
		CliIo.sysPrint('  <bytes>\n');
		CliIo.sysPrint('  === plain ===\n');
		CliIo.sysPrint('  <bytes>\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Replaces the two-command dance (`hxq ast … --writer-output` then\n');
		CliIo.sysPrint('`hxq ast … --writer-output-plain`) when constructing a unit-test\n');
		CliIo.sysPrint('`writerEquals` expected literal: side-by-side output makes the\n');
		CliIo.sysPrint('pipeline divergence (anon flatten, terminators, comments) visible.\n');
		CliIo.sysPrint('Exit 0 only when both pipelines succeed.\n');
	}

}
