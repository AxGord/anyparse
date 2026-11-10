package dev;

import devkit.Args;
import devkit.Command;
import devkit.Result;
import devkit.Table;
import devkit.TempDir;
import devkit.TreeFiles;
import haxe.Exception;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/** One tree's reading: its `.hx` files, how many the squash changed, and how the writer fared on the originals and the squashed copies. */
typedef SquashRow = {

	final dir: String;
	final files: Int;
	final squashed: Int;

	/** Files the grammar could not format as originals or squashed; they take no part in the other columns. */
	final unparsed: Int;

	/** Files the writer settles only on a second rewrite, as written and squashed. */
	final onePassOriginal: Int;
	final onePassSquashed: Int;

	/** Files the squash made need a second rewrite that did not before. */
	final onePassNew: Int;

	/** Files whose formatted squash is not their formatted original: the writer's output depends on the author's line breaks. */
	final differs: Int;

}

/** The census: a row per tree, and the files behind the last two columns. */
typedef SquashReport = { final rows: Array<SquashRow>; final newOnePass: Array<String>; final differs: Array<String>; }

/**
 * The one answer to "how much of the writer's output depends on where the author broke lines": `dev squash-census [<dir>...]
 * [--repo DIR] [--files]` squashes (`Squash`) every `.hx` of each tree on a COPY, formats the copy and the original copy under the
 * tree's own `hxformat.json`, and prints a table of how many files are not one-pass and how many format differently. The
 * repository is never written. A `<dir>` is relative to the repo and defaults to `GateTree.TREE_SCOPE`; `--files` lists the files
 * behind the last two columns.
 */
@:nullSafety(Strict)
final class SquashCensus {

	public static inline final USAGE: String = 'usage: dev squash-census [<dir>...] [--repo DIR] [--files]';

	private static final LIST_SUMMARY: String = 'apq fmt --list:';
	private static final HEADER: Array<String> = [
		'tree',
		'files',
		'squashed',
		'unparsed',
		'1pass',
		'1pass-sq',
		'1pass-new',
		'differs'
	];
	private static final NOT_ONE_PASS: String = ': the writer needed ';

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final listed: Bool = args.flag('--files');
		final repo: String = Repo.resolve(args.option('--repo'));
		final given: Array<String> = args.rest([]);
		final dirs: Array<String> = given.length == 0 ? GateTree.TREE_SCOPE : given;
		final report: SquashReport = TempDir.with(scratch -> census(words -> GateTree.shim(repo, repo, words), repo, dirs, scratch.path));
		Sys.println(render(report));
		if (listed) {
			for (name in report.newOnePass) Sys.println('1pass-new $name');
			for (name in report.differs) Sys.println('differs $name');
		}
		return 0;
	}

	/**
	 * The census of `dirs` of `repo`, worked in `scratch`: the originals under `scratch/original`, the squashed copies under
	 * `scratch/squashed`, each with the formatter configs that govern them. `hxq` is the command that runs the engine.
	 */
	public static function census(hxq: Array<String> -> Command, repo: String, dirs: Array<String>, scratch: String): SquashReport {
		final original: String = Path.join([scratch, 'original']);
		final squashed: String = Path.join([scratch, 'squashed']);
		final names: Map<String, Array<String>> = [];
		final changed: Array<String> = [];
		for (dir in dirs) {
			final found: Found = hxFiles(repo, dir);
			copyConfigs(repo, dir, found.configs, [original, squashed]);
			final inDir: Array<String> = found.sources;
			names[dir] = inDir;
			for (name in inDir) {
				final text: String = File.getContent(Path.join([repo, name]));
				final squash: String = Squash.haxe(text);
				put(Path.join([original, name]), text);
				put(Path.join([squashed, name]), squash);
				if (squash != text) changed.push(name);
			}
		}
		final before: FmtRun = format(hxq, original, dirs);
		final after: FmtRun = format(hxq, squashed, dirs);
		final rows: Array<SquashRow> = [];
		final newOnePass: Array<String> = [];
		final differs: Array<String> = [];
		for (dir in dirs) {
			final inDir: Array<String> = names[dir] ?? [];
			final usable: Array<String> = inDir.filter(name -> !before.unparsed.contains(name) && !after.unparsed.contains(name));
			final fresh: Array<String> = usable.filter(name -> after.onePass.contains(name) && !before.onePass.contains(name));
			final apart: Array<String> = usable.filter(name ->
				File.getContent(Path.join([original, name])) != File.getContent(Path.join([squashed, name]))
			);
			for (name in fresh) newOnePass.push(name);
			for (name in apart) differs.push(name);
			rows.push({
				dir: dir,
				files: inDir.length,
				squashed: inDir.count(name -> changed.contains(name)),
				unparsed: inDir.length - usable.length,
				onePassOriginal: usable.count(name -> before.onePass.contains(name)),
				onePassSquashed: usable.count(name -> after.onePass.contains(name)),
				onePassNew: fresh.length,
				differs: apart.length
			});
		}
		return { rows: rows, newOnePass: newOnePass, differs: differs };
	}

	/** The report as the table the command prints, a total row last. */
	public static function render(report: SquashReport): String {
		final total: SquashRow = {
			dir: 'total',
			files: report.rows.fold((row, n) -> n + row.files, 0),
			squashed: report.rows.fold((row, n) -> n + row.squashed, 0),
			unparsed: report.rows.fold((row, n) -> n + row.unparsed, 0),
			onePassOriginal: report.rows.fold((row, n) -> n + row.onePassOriginal, 0),
			onePassSquashed: report.rows.fold((row, n) -> n + row.onePassSquashed, 0),
			onePassNew: report.rows.fold((row, n) -> n + row.onePassNew, 0),
			differs: report.rows.fold((row, n) -> n + row.differs, 0)
		};
		return Table.render(HEADER, report.rows.concat([total]).map(cellsOf));
	}

	/** Whether `run` ended the way `fmt` ends when it ran: 0, or 1 when some file failed to format. */
	private static inline function ran(run: Result): Bool {
		return run.status == 0 || run.status == 1;
	}

	private static function cellsOf(row: SquashRow): Array<String> {
		return [
			row.dir,
			'${row.files}',
			'${row.squashed}',
			'${row.unparsed}',
			'${row.onePassOriginal}',
			'${row.onePassSquashed}',
			'${row.onePassNew}',
			'${row.differs}'
		];
	}

	/** What `fmt --list --one-pass` said of the tree under `root`, then the tree formatted in place. */
	private static function format(hxq: Array<String> -> Command, root: String, dirs: Array<String>): FmtRun {
		final targets: Array<String> = dirs.map(dir -> Path.join([root, dir]));
		final run: Result = hxq(['fmt', '--list', '--one-pass'].concat(targets)).env('APQ_NO_CONFIG_WARN', '1').run();
		if (!ran(run) || run.err.indexOf(LIST_SUMMARY) < 0)
			throw new Exception('fmt --list --one-pass did not run to its summary: ${run.firstError()}');
		final prefix: String = 'apq fmt: $root/';
		final unparsed: Array<String> = [];
		for (line in run.err.split('\n')) if (line.startsWith(prefix) && line.indexOf(NOT_ONE_PASS) < 0) {
			final rest: String = line.substring(prefix.length);
			unparsed.push(rest.substring(0, rest.indexOf(': ')));
		}
		final write: Result = hxq(['fmt', '--write'].concat(targets)).env('APQ_NO_CONFIG_WARN', '1').run();
		if (!ran(write)) throw new Exception('fmt --write did not run: ${write.firstError()}');
		return { onePass: XconfigFmt.onePassSet(run.err, root), unparsed: unparsed };
	}

	/** The `.hx` files under `dir` of `repo`, relative to `repo`, sorted. */
	private static function hxFiles(repo: String, dir: String): Found {
		if (!FileSystem.exists(Path.join([repo, dir]))) throw new Exception('no such directory: $dir');
		final files: Array<String> = TreeFiles.below(repo, dir, TreeFiles.visible);
		return {
			sources: files.filter(file -> TreeFiles.visible(Path.withoutDirectory(file)) && file.endsWith('.hx')),
			configs: files.filter(file -> GateTree.FORMATTER_CONFIGS.contains(Path.withoutDirectory(file)))
		};
	}

	/** Every formatter config the writer discovers for a file under `dir`: those in `dir` and in each folder above it up to `repo`. */
	private static function copyConfigs(repo: String, dir: String, below: Array<String>, roots: Array<String>): Void {
		final configs: Array<String> = below.copy();
		var at: String = '';
		for (part in [''].concat(dir.split('/'))) {
			at = Path.join([at, part]);
			for (config in GateTree.FORMATTER_CONFIGS) {
				final path: String = Path.join([at, config]);
				if (FileSystem.exists(Path.join([repo, path])) && !configs.contains(path)) configs.push(path);
			}
		}
		for (path in configs) for (root in roots) put(Path.join([root, path]), File.getContent(Path.join([repo, path])));
	}

	private static function put(path: String, text: String): Void {
		final parent: String = Path.directory(path);
		if (!FileSystem.exists(parent)) FileSystem.createDirectory(parent);
		File.saveContent(path, text);
	}

}

/** What one formatter run over a tree reported: the files it settles only on a second rewrite, and the ones it could not format. */
private typedef FmtRun = { final onePass: Array<String>; final unparsed: Array<String>; }

/** What `hxFiles` found under a tree: its `.hx` files and the formatter configs inside it, relative to the repo. */
private typedef Found = { final sources: Array<String>; final configs: Array<String>; }
