package anyparse.query.cli.command;

import anyparse.check.oracle.HaxeSpawn;
import anyparse.core.TempScratch;
import anyparse.query.merge.KeyedMerge.MergeChoice;
import anyparse.query.merge.StructuralMerge;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/** What `apq merge-file` was asked. */
private typedef MergeFileOpts = {
	final base: String;
	final ours: String;
	final theirs: String;
	final path: Null<String>;
	final lang: Null<String>;
	final choices: Null<String>;
}

/**
 * `apq merge-file <base> <ours> <theirs>` — the git merge driver `merge=anyparse` names (`%O %A %B --path %P`): the three
 * versions of one file merged through its grammar (`StructuralMerge`), the result written over `<ours>`. A merge prints
 * `auto-merged: <path> (<how>)` and exits 0; a place both sides changed differently prints
 * `merge-conflict: <path> <key> (…)`, is left between conflict markers and exits 1; a file no grammar reads gets git's
 * own line merge (`git merge-file`). `--choices` settles conflicting places by key, the file's own lines of
 * `<path>\t<key>\t<ours|theirs|both>`.
 */
@:nullSafety(Strict)
final class MergeFileCommand implements CliCommand implements LanguageFree {

	/** The field separator of a choices line. */
	private static inline final TAB: String = '\t';

	/** Git's own three-way file merge, the line merge this command widens. */
	private static inline final GIT_MERGE_FILE: String = 'merge-file';

	/** The output cap of the `git merge-file` child, which writes its result in place and prints little. */
	private static inline final GIT_BUFFER: Int = 256 * 1024 * 1024;

	public function new() {}

	public function name(): String {
		return 'merge-file';
	}

	public function summary(): String {
		return 'Three-way merge of one file through its grammar — the git merge driver (merge=anyparse)';
	}

	public function flags(): CliFlags {
		return new CliFlags([], ['--choices', '--path']);
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		final opts: Null<MergeFileOpts> = parseArgs(args);
		if (opts == null) return ExitCode.EXIT_OK;
		final path: String = opts.path ?? opts.ours;
		final lang: Null<String> = opts.lang ?? CliArgs.langOfFile(path);
		if (lang == null) return lineMerge(opts, path, 'no grammar reads it');
		final plugin: GrammarPlugin = CliArgs.pickPluginFor(lang, path);
		final shape: MergeShape = CliArgs.mergeShapeOf(plugin.langName());
		final choicesFile: Null<String> = opts.choices;
		final choices: Map<String, MergeChoice> = choicesFile == null ? [] : choicesOf(CliIo.readFile(choicesFile), path);
		final result: MergeResult = StructuralMerge.merge(
			plugin, shape, CliIo.readFile(opts.base), CliIo.readFile(opts.ours), CliIo.readFile(opts.theirs),
			CliArgs.discoverFormatConfig(path), choices, linesMerged
		);
		return switch result {
			case Merged(text, how):
				CliIo.writeFile(opts.ours, text);
				CliIo.stderr('auto-merged: $path (${how.length == 0 ? 'one side changed it' : how.join('; ')})\n');
				ExitCode.EXIT_OK;
			case Conflicted(text, conflicts):
				CliIo.writeFile(opts.ours, text);
				for (conflict in conflicts)
					CliIo.stderr('merge-conflict: $path ${conflict.key} (ours ${conflict.ours}, theirs ${conflict.theirs})\n');
				ExitCode.EXIT_RUNTIME;
			case Unreadable(why):
				lineMerge(opts, path, why);
		};
	}

	public function usage(): Void {
		CliIo.sysPrint('Usage: apq merge-file <base> <ours> <theirs> [--path <path>] [--choices <file>] [--lang <name>]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('The git merge driver: in .gitattributes `*.hx merge=anyparse`, and\n');
		CliIo.sysPrint('  git -c merge.anyparse.driver=\'node bin/apq.js merge-file %O %A %B --path %P\' merge ...\n');
		CliIo.sysPrint('The three versions are read as the writer emits them and merged by key: declarations (members,\n');
		CliIo.sysPrint('imports) in source code, members and records in a data document. A side that changed only layout\n');
		CliIo.sysPrint('changed nothing; additions of both sides are kept, ours first; an import only theirs added takes\n');
		CliIo.sysPrint('the grammar\'s own seat. A declaration both sides changed differently is a conflict.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Writes the result over <ours>. Exit 0 merged (stderr `auto-merged: <path> (<how>)`), 1 conflict\n');
		CliIo.sysPrint('(stderr `merge-conflict: <path> <key> (ours <did>, theirs <did>)` per place, markers in <ours>).\n');
		CliIo.sysPrint('A file no grammar reads, or a version that does not parse, gets `git merge-file`.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --path <path>     The file\'s path in the repository (%P): picks the grammar and hxformat.json\n');
		CliIo.sysPrint('  --choices <file>  Settles conflicting places: lines `<path>\\t<key>\\t<ours|theirs|both>`\n');
		CliIo.sysPrint('  --lang <name>     Grammar plugin when the path names none\n');
	}

	/** The options of one run, or null when it asked for the usage text and got it. */
	private function parseArgs(args: Array<String>): Null<MergeFileOpts> {
		var path: Null<String> = null;
		var lang: Null<String> = null;
		var choices: Null<String> = null;
		final files: Array<String> = [];
		for (arg in new MergeFileCommand().flags().walk(args)) {
			final a: String = arg.token;
			switch arg.flag {
				case '--path':
					path = arg.value();
				case '--lang':
					lang = arg.value();
				case '--choices':
					choices = arg.value();
				case '-h', '--help':
					usage();
					return null;
				case null:
					files.push(a);
			}
		}
		if (files.length != 3) throw new UsageFailure('merge-file takes <base> <ours> <theirs>, got ${files.length} file(s)');
		return {
			base: files[0],
			ours: files[1],
			theirs: files[2],
			path: path,
			lang: lang,
			choices: choices
		};
	}

	/** The choices `text` makes for `path`, by key; a line naming no choice is refused. */
	public static function choicesOf(text: String, path: String): Map<String, MergeChoice> {
		final out: Map<String, MergeChoice> = [];
		for (line in text.split('\n')) if (line.trim() != '') {
			final fields: Array<String> = line.split(TAB);
			final choice: Null<MergeChoice> = fields.length == 3 ? MergeChoice.ofWord(fields[2].trim()) : null;
			if (choice == null) throw new UsageFailure('a choices line is not `<path>\\t<key>\\t<ours|theirs|both>`: $line');
			if (fields[0] == path) out[fields[1]] = choice;
		}
		return out;
	}

	/**
	 * Git's line merge of three texts (`git merge-file -p`), the merged text when it is clean, else null — the merge a
	 * structural one widens, run on the whole file first and on each colliding place.
	 */
	public static function linesMerged(base: String, ours: String, theirs: String): Null<String> {
		final dir: String = TempScratch.slot('apq-merge-lines');
		if (!FileSystem.exists(dir)) FileSystem.createDirectory(dir);
		final files: Array<String> = [for (name in ['base', 'ours', 'theirs']) Path.join([dir, name])];
		File.saveContent(files[0], base);
		File.saveContent(files[1], ours);
		File.saveContent(files[2], theirs);
		final run: HaxeRun = HaxeSpawn.exec(
			{ cmd: 'git', args: [GIT_MERGE_FILE, '-p', '-q', files[1], files[0], files[2]], cwd: null }, GIT_BUFFER
		);
		for (file in files) FileSystem.deleteFile(file);
		FileSystem.deleteDirectory(dir);
		return run.failure == '' && run.status == 0 ? run.out : null;
	}

	/** Git's own line merge of the three files, `why` the structural one did not serve; 0 when it left no conflict. */
	private static function lineMerge(opts: MergeFileOpts, path: String, why: String): Int {
		CliIo.stderr('merge-file: $path: $why — git\'s line merge instead\n');
		final run: HaxeRun = HaxeSpawn.exec({
			cmd: 'git',
			args: [
				GIT_MERGE_FILE,
				'-L',
				'ours',
				'-L',
				'base',
				'-L',
				'theirs',
				opts.ours,
				opts.base,
				opts.theirs
			],
			cwd: null
		}, GIT_BUFFER);
		return run.failure == '' && run.status == 0 ? ExitCode.EXIT_OK : ExitCode.EXIT_RUNTIME;
	}

}
