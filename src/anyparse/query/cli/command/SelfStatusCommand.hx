package anyparse.query.cli.command;

import anyparse.query.cli.CliArgs;
import anyparse.query.cli.CliContext;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * Corpus-walk tallies for `apq self-status`: how many project files `parseable`, how many `skipParse`, and the `skipLines` describing each skipped file. Rolled up into the self-status report.
 */
typedef SelfStatusWalk = {
	var parseable: Int;
	var skipParse: Int;
	var skipLines: Array<String>;
};

/**
 * Parsed options for `apq self-status` — `lang`, the `roots` (file / dir / glob specs) to walk, and `strict` / `showSource` flags. `errExit` non-null means arg parsing hit a terminal case the caller returns immediately.
 */
typedef SelfStatusOpts = {
	var lang: String;
	var roots: Array<String>;
	var strict: Bool;
	var showSource: Bool;
	var errExit: Null<Int>;
};

/**
 * `apq self-status` — list .hx files the grammar plugin cannot parse (dogfood gap).
 *
 * A READ-ONLY command: it reports and never writes.
 */
@:nullSafety(Strict)
final class SelfStatusCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'self-status';
	}

	public function summary(): String {
		return 'List .hx files the grammar plugin cannot parse (dogfood gap)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		#if (sys || nodejs)
		return runSelfStatus(args);
		#else
		CliIo.stderr('apq self-status: requires a sys target (filesystem walk)\n');
		return EXIT_USAGE;
		#end
	}

	public function usage(): Void {
		#if (sys || nodejs)
		printSelfStatusUsage();
		#end
	}

	/**
	 * Parse `self-status` argv. `errExit` carries the exit code when a help
	 * flag or a usage error short-circuits the command (EXIT_OK for -h,
	 * EXIT_USAGE for a bad option); null = proceed.
	 */
	private static function parseSelfStatusArgs(args: Array<String>): SelfStatusOpts {
		final opts: SelfStatusOpts = {
			lang: 'haxe',
			roots: [],
			strict: false,
			showSource: false,
			errExit: null
		};
		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '-h', '--help':
					printSelfStatusUsage();
					opts.errExit = EXIT_OK;
					return opts;
				case '--lang':
					opts.lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--strict':
					opts.strict = true;
				case '--source':
					opts.showSource = true;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq self-status: unknown option "$a"\n');
						opts.errExit = EXIT_USAGE;
						return opts;
					}
					opts.roots.push(a);
			}
			i++;
		}
		return opts;
	}

	/**
	 * Parse every `.hx` file in `paths` under the plugin, tallying
	 * parseable vs skip-parse and collecting a SKIP line (with locus, and an
	 * optional source snippet) per failure.
	 */
	private static function walkSelfStatus(plugin: GrammarPlugin, paths: Array<String>, showSource: Bool): SelfStatusWalk {
		var parseable: Int = 0;
		var skipParse: Int = 0;
		final skipLines: Array<String> = [];
		for (path in paths) {
			final source: String = try CliIo.readSourceForParse(path) catch (_: Exception) continue;
			try {
				plugin.parseFile(source);
				parseable++;
			} catch (exception: ParseError) {
				skipParse++;
				final pos: Position = exception.span.lineCol(source);
				final exp: String = ReconCommand.reconNormalize(exception.expected);
				final src: String = showSource
					? ' :: src="${ReconCommand.reconNormalize(ReconCommand.reconSnippet(source, exception.span.from))}"'
					: '';
				skipLines.push('SKIP $path :: ${pos.line}:${pos.col} expected="$exp"$src');
			} catch (exception: Exception) {
				skipParse++;
				skipLines.push('SKIP $path :: <non-ParseError> ${ReconCommand.reconNormalize(exception.message)}');
			}
		}
		return { parseable: parseable, skipParse: skipParse, skipLines: skipLines };
	}

	#if (sys || nodejs)
	/**
	 * `apq self-status [<dir>]` — walk `<dir>` recursively (default `src/`),
	 * try every `.hx` file via the grammar plugin's trivia parser, print
	 * one `SKIP <path> :: LINE:COL <message>` line per failure plus a
	 * footer `--- self-status: M parseable, N skip-parse (total T) ---`.
	 *
	 * Solves the dogfooding gap where `hxq` walkers silently skip
	 * unparseable files: the user finds out a file is unparseable only by
	 * grepping warnings emitted by `lit` / `refs` / `uses` etc., one at a
	 * time. `self-status` surfaces the full skip-parse set in one call.
	 *
	 * Exit code is 0 even when files skip-parse — this is a status report,
	 * not a check. `--strict` flips to non-zero on any skip-parse so CI
	 * wiring can guard against regressions.
	 */
	private static function runSelfStatus(args: Array<String>): Int {
		final opts: SelfStatusOpts = parseSelfStatusArgs(args);
		if (opts.errExit != null) return opts.errExit;
		final specs: Array<String> = opts.roots.length > 0 ? opts.roots : ['src'];
		final io: ResolvedInputs = CliArgs.resolveInputPaths(opts.lang, specs);
		if (io.paths.length == 0) {
			CliIo.stderr('apq self-status: ${CliArgs.quotedSpecs(specs)} matched no .hx files\n');
			return EXIT_RUNTIME;
		}
		final walk: SelfStatusWalk = walkSelfStatus(io.plugin, io.paths, opts.showSource);
		walk.skipLines.sort((a, b) -> if (a < b)
			-1
		else if (a > b)
			1
		else
			0);
		for (line in walk.skipLines) CliIo.sysPrint('$line\n');
		final total: Int = walk.parseable + walk.skipParse;
		CliIo.sysPrint('--- self-status: ${walk.parseable} parseable, ${walk.skipParse} skip-parse (total $total) ---\n');
		return opts.strict && walk.skipParse > 0 ? EXIT_RUNTIME : EXIT_OK;
	}

	private static function printSelfStatusUsage(): Void {
		CliIo.sysPrint('apq self-status [<file/dir/glob>...] [--strict] [--source]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Walks each input recursively (default `src/`) and prints which `.hx` files\n');
		CliIo.sysPrint('the grammar plugin cannot parse. Each failure shows as:\n');
		CliIo.sysPrint('  SKIP <path> :: LINE:COL expected="<X>"\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('With --source the SKIP line gains a `:: src="<window>"` tail showing\n');
		CliIo.sysPrint('the bytes around the fail-locus (same format as `recon --probe`).\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Closes the dogfood gap: hxq walkers silently skip unparseable files;\n');
		CliIo.sysPrint('self-status surfaces the full set in one call.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --strict       Exit non-zero when any file skip-parses (CI guard).\n');
		CliIo.sysPrint('  --source       Append windowed source around each fail-locus.\n');
		CliIo.sysPrint('  --lang <name>  Grammar plugin (default `haxe`).\n');
		CliIo.sysPrint('  -h, --help     Show this help.\n');
	}
	#end

}
