package anyparse.query.cli.command;

import anyparse.query.ExitCode.EXIT_OK;
import anyparse.query.ExitCode.EXIT_RUNTIME;
import anyparse.query.ExitCode.EXIT_USAGE;
import anyparse.query.OwnerIndex.OwnerEntry;
import anyparse.query.OwnerIndex.OwnerHit;
import anyparse.query.cli.CliArgs.ResolvedInputs;

/**
 * `apq owner` — which component answers a question: the declarations of a scope ranked by how well their name and doc
 * comment cover the question's words (`OwnerIndex`), or with `--list` every question a doc says its declaration owns.
 *
 * A READ-ONLY command: it reports and never writes.
 */
@:nullSafety(Strict)
final class OwnerCommand implements CliCommand {

	/** How many ranked declarations print without `--limit`. */
	private static inline final DEFAULT_LIMIT: Int = 10;

	public function new() {}

	public function name(): String {
		return 'owner';
	}

	public function summary(): String {
		return 'Which component answers a question, ranked by its doc comment and name';
	}

	public function flags(): CliFlags {
		return new CliFlags(['--list'], ['--limit']);
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runOwner(args);
	}

	public function usage(): Void {
		printOwnerUsage();
	}

	/**
	 * `apq owner <question> <scope...>` prints the best declarations as `Type[.member]<TAB>file:line<TAB>first sentence`;
	 * `apq owner --list <scope...>` prints every owned question as `question<TAB>Type[.member]<TAB>file:line`.
	 */
	private static function runOwner(args: Array<String>): Int {
		var lang: String = 'haxe';
		var list: Bool = false;
		var limit: Int = DEFAULT_LIMIT;
		final positionals: Array<String> = [];
		for (arg in new OwnerCommand().flags().walk(args)) {
			switch arg.flag {
				case '--lang':
					lang = arg.value();
				case '--list':
					list = true;
				case '--limit':
					limit = CliArgs.parseLimit(arg.value());
				case '-h', '--help':
					printOwnerUsage();
					return EXIT_OK;
				case null:
					positionals.push(arg.token);
			}
		}
		final question: Null<String> = list ? null : positionals.shift();
		if ((!list && question == null) || positionals.length == 0) {
			CliIo.stderr('apq owner: expected <question> <scope...>, or --list <scope...>\n');
			printOwnerUsage();
			return EXIT_USAGE;
		}

		final io: ResolvedInputs = CliArgs.resolveInputPaths(lang, positionals);
		if (io.paths.length == 0) {
			CliIo.stderr('apq owner: ${CliArgs.quotedSpecs(positionals)} matched no files\n');
			return EXIT_RUNTIME;
		}
		final files: Array<{ file: String, source: String }> = [
			for (path in io.paths)
				{
					file: path,
					source: (try {
						CliIo.readSourceForParse(path);
					} catch (exception: Exception) {
						CliIo.stderr('apq owner: $path: ${exception.message}\n');
						return EXIT_RUNTIME;
					}: String)
				}
		];
		final owners: OwnerIndex = OwnerIndex.build(IndexScope.over(files, io.plugin), io.plugin);

		if (question == null) {
			for (entry in owners.owned()) CliIo.sysPrint('${entry.question}\t${OwnerIndex.nameOf(entry)}\t${entry.file}:${entry.line}\n');
			return EXIT_OK;
		}
		final hits: Array<OwnerHit> = owners.rank(question, limit);
		if (hits.length == 0) CliIo.stderr('apq owner: no declaration in the scope carries a word of "$question"\n');
		for (hit in hits) {
			final entry: OwnerEntry = hit.entry;
			CliIo.sysPrint('${OwnerIndex.nameOf(entry)}\t${entry.file}:${entry.line}\t${entry.summary}\n');
		}
		return EXIT_OK;
	}

	private static function printOwnerUsage(): Void {
		CliIo.sysPrint('Usage: apq owner <question> <scope...> [options]\n');
		CliIo.sysPrint('       apq owner --list <scope...> [options]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Rank the types and members of the scope by how well their name and doc comment\n');
		CliIo.sysPrint('cover the words of <question> (a rare word counts more), best first, as\n');
		CliIo.sysPrint('Type[.member]<TAB>file:line<TAB>the doc\'s first sentence. A doc names the\n');
		CliIo.sysPrint('question its declaration owns as: the one answer to "<question>".\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --list          Print every owned question instead, as\n');
		CliIo.sysPrint('                  question<TAB>Type[.member]<TAB>file:line\n');
		CliIo.sysPrint('  --limit N       How many declarations to print (default 10)\n');
		CliIo.sysPrint('  --lang <name>   Grammar plugin (default: haxe)\n');
		CliIo.sysPrint('  -h, --help      Show this help\n');
	}

}
