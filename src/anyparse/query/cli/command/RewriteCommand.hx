package anyparse.query.cli.command;

import anyparse.query.cli.CliContext;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;

/**
 * `apq rewrite` — structural search-and-replace (search-pattern metavars).
 *
 * An ADDRESSED EDIT: one addressed node in one file, out through `CliEdit`'s address
 * resolution and its `--write` / preview tail.
 */
@:nullSafety(Strict)
final class RewriteCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'rewrite';
	}

	public function summary(): String {
		return 'Structural search-and-replace (search-pattern metavars)';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runRewrite(args);
	}

	public function usage(): Void {
		printRewriteUsage();
	}

	/**
	 * `apq rewrite <file> <pattern> <replacement> [--reformat] [--write]` —
	 * structural search-and-replace (see `Rewrite`). Every node matching the
	 * `apq search`-syntax `<pattern>` is rewritten from `<replacement>`, where
	 * `$x` / `${x}` expand to the captured metavar's source and `${x+N}` /
	 * `${x-N}` shift an integer-literal metavar. All matches in one pass,
	 * writer-formatted + re-parse-validated (canonical-gated unless `--reformat`).
	 */
	private static function runRewrite(args: Array<String>): Int {
		var lang: String = 'haxe';
		var write: Bool = false;
		var reformat: Bool = false;
		var file: Null<String> = null;
		var pattern: Null<String> = null;
		var replacement: Null<String> = null;

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--reformat':
					reformat = true;
				case '--write':
					write = true;
				case '-h', '--help':
					printRewriteUsage();
					return EXIT_OK;
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq rewrite: unknown option "$a"\n');
						return EXIT_USAGE;
					}
					if (file == null)
						file = a;
					else if (pattern == null)
						pattern = a;
					else if (replacement == null)
						replacement = a;
					else {
						CliIo.stderr('apq rewrite: unexpected extra argument "$a"\n');
						return EXIT_USAGE;
					}
			}
			i++;
		}
		if (file == null || pattern == null || replacement == null) {
			CliIo.stderr('apq rewrite: expected <file> <pattern> <replacement>\n');
			printRewriteUsage();
			return EXIT_USAGE;
		}

		final filePath: String = file;
		final pat: String = pattern;
		final repl: String = replacement;
		final source: String = try CliIo.readFile(filePath) catch (exception: Exception) {
			CliIo.stderr('apq rewrite: $filePath: ${exception.message}\n');
			return EXIT_RUNTIME;
		};
		final plugin: GrammarPlugin = CliArgs.pickPlugin(lang);
		final optsJson: Null<String> = CliArgs.discoverFormatConfig(filePath);
		final op: String = 'rewrite';
		switch Rewrite.rewrite(source, pat, repl, reformat, plugin, optsJson) {
			case Ok(text, rewrites):
				CliEdit.warnRewrites(op, filePath, rewrites);
				if (write) {
					CliIo.writeFile(filePath, text);
					CliIo.stderr('apq rewrite: wrote $filePath\n');
				} else
					CliEdit.previewEdit(op, filePath, text);
				return EXIT_OK;
			case Err(message):
				CliIo.stderr('apq rewrite: $message\n');
				return EXIT_RUNTIME;
		}
	}

	private static function printRewriteUsage(): Void {
		CliIo.sysPrint('Usage: apq rewrite <file> <pattern> <replacement> [--reformat] [--write]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint("Structural search-and-replace. <pattern> uses apq search syntax with $x\n");
		CliIo.sysPrint("metavariables; <replacement> is a template where $x / ${x} expand to the\n");
		CliIo.sysPrint("captured source and ${x+N} / ${x-N} shift an integer-literal metavar by N.\n");
		CliIo.sysPrint('\n');
		CliIo.sysPrint('A template reads as a TREE, so it is spliced as one: a capture whose new\n');
		CliIo.sysPrint('surroundings would re-read it, and a replacement the matched context would,\n');
		CliIo.sysPrint('get the parentheses that keep the parse — and only where dropping them\n');
		CliIo.sysPrint("would change it, so `$x * 2` over `v` stays `v * 2`.\n");
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --reformat  Canonicalise the whole file (allow a non-canonical input)\n');
		CliIo.sysPrint('  --write     Overwrite <file> in place (default: emit to stdout)\n');
	}

}
