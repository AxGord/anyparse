package dev;

import anyparse.query.Glob;
import anyparse.query.cli.DeclarationDelta;
import anyparse.util.Compare;
import devkit.Cmd.cmd;
import devkit.Command;
import devkit.Result;
import devkit.Summary;
import devkit.TempDir;
import haxe.Exception;
import haxe.io.Path;
import js.node.Fs.Fs;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/** The engine a reading is taken with: the one of the slice's base commit, or the one the slice built. */
enum MovedSide {
	Base;
	Tip;
}

/**
 * One tree both engines format: where each reads it (the config each
 * engine finds differs only for the slice's own tree) and what of it.
 */
typedef MovedUnit = {
	var label: String;
	var baseDir: String;
	var tipDir: String;
	var targets: Array<String>;
}

/** What one unit showed: the files that moved (labelled paths) and, for the first few, a hunk led by its path. */
typedef MovedReading = { var moved: Array<String>; var hunks: Array<Array<String>>; }

/**
 * The one answer to "which files does this slice's writer or formatter-config change move": the files the base engine and the
 * engine the slice built list differently under `fmt --list`, over the base tree of this repository (the tip's own config on it)
 * and over a sibling library. The row is red until the worker's `moved-files.md`, in the `<worktree>-logs` directory, names every
 * one of them with the reason; the file is filed into the report, where the reviewer reads it.
 */
@:nullSafety(Strict)
final class MovedFiles {

	/** The worker's declaration, in the slice's logs directory: one `<path or glob> — <why>` line per moved file or group. */
	public static final DECLARATION: String = 'moved-files.md';

	/** What the gate leaves in its own logs: every moved file, one path per line. */
	public static final LIST: String = 'moved-files.txt';

	/** The environment variable naming the sibling library's directory (its `hxformat.json` and `src`), read-only. */
	public static final SIBLING_VAR: String = 'ANYPARSE_SIBLING_LIB';

	/** The label that prefixes a moved path of the sibling library. */
	public static final SIBLING: String = 'sibling';

	/** What the gate leaves beside the list: the hunk of every moved file it read. */
	public static final HUNKS: String = 'moved-hunks.txt';

	/** The moved files of one unit whose hunk the row prints. */
	private static inline final HUNK_FILES: Int = 5;

	/** The most lines of one hunk the row prints. */
	private static inline final HUNK_LINES: Int = 8;

	/** The moved paths the row's excerpt lists before it counts the rest. */
	private static inline final LISTED_PATHS: Int = 3;

	/** The lines of the first hunk the row's excerpt prints. */
	private static inline final EXCERPT_HUNK_LINES: Int = 5;

	/** The lines of unchanged context a hunk keeps on each side of a change. */
	private static inline final HUNK_CONTEXT: Int = 1;

	/** The sibling library's formatter config names, copied beside its sources. */
	private static final CONFIGS: Array<String> = ['hxformat.json', '.hxformat.json'];

	/** The files of the tree root both engines read the project's options from. */
	private static final ROOT_FILES: Array<String> = ['hxformat.json', 'apq.json'];

	/** Where the writer and what drives it live: a change here can move how a file formats. */
	private static final WRITER_CODE: EReg = ~/^src\/anyparse\/((core|format|grammar|macro|runtime)\/|query\/cli\/command\/FmtCommand\.hx$)/;

	/** Whether the slice changed code that decides how a file formats, or the root formatter config. */
	public static function reached(touched: Array<String>): Bool {
		return touched.exists(file -> WRITER_CODE.match(file) || GateTree.FORMATTER_CONFIGS.contains(file));
	}

	/** The paths `fmt --list` printed on its standard output `out`, sorted. */
	public static function listed(out: String): Array<String> {
		final files: Array<String> = [ for (line in out.split('\n')) if (line.trim() != '') line.trim() ];
		files.sort(Compare.compareString);
		return files;
	}

	/** The files one engine lists and the other does not, sorted: a file the change now rewrites, or now leaves alone. */
	public static function between(base: Array<String>, tip: Array<String>): Array<String> {
		final files: Array<String> = [ for (file in tip) if (!base.contains(file)) file ];
		for (file in base) if (!tip.contains(file)) files.push(file);
		files.sort(Compare.compareString);
		return files;
	}

	/**
	 * The first region where `after` differs from `before` as `DeclarationDelta.hunk` rows it, one line of context on each side: `-` the
	 * lines of `before`, `+` those of `after`, cut at `HUNK_LINES`; empty when the texts are equal.
	 */
	public static function hunk(before: String, after: String): Array<String> {
		final rows: Array<String> = DeclarationDelta.hunk(before.split('\n'), after.split('\n'), HUNK_CONTEXT);
		final first: Array<String> = [];
		for (row in rows) {
			if (row == DeclarationDelta.ELIDED && first.length > 0) break;
			if (row != DeclarationDelta.ELIDED) first.push(row);
		}
		return first.length <= HUNK_LINES ? first : first.slice(0, HUNK_LINES).concat(['… ${first.length - HUNK_LINES} more']);
	}

	/**
	 * The paths and globs the worker's declaration `text` names, each with a reason: a line `<path or glob> — <why>` (an em dash,
	 * ` -- ` or ` - `; a list marker and backticks around the path are ignored). A line with no reason names nothing.
	 */
	public static function named(text: String): Array<String> {
		final names: Array<String> = [];
		for (raw in text.split('\n')) {
			var line: String = raw.trim();
			if (line.startsWith('- ') || line.startsWith('* ')) line = line.substr(2);
			for (separator in [' — ', ' -- ', ' - ']) {
				final at: Int = line.indexOf(separator);
				if (at < 0) continue;
				final path: String = line.substr(0, at).replace('`', '').trim();
				if (path != '') names.push(path);
				break;
			}
		}
		return names;
	}

	/** Whether the declared path or glob `name` names `file`: the file itself, a directory above it, or a glob that matches it. */
	public static function covers(name: String, file: String): Bool {
		return Glob.expandListed(name, '', [file]).length > 0;
	}

	/** The verdict on the `moved` files against the `names` the worker declared. */
	public static function verdict(moved: Array<String>, names: Array<String>): Outcome {
		final open: Array<String> = moved.filter(file -> !names.exists(name -> covers(name, file)));
		return open.length == 0
			? Passed
			: Failed('${open.length} of ${moved.length} moved files not named in $DECLARATION — write `<path or glob> — <why>` lines');
	}

	/**
	 * What `unit` shows: the files `fmt --list` of the base engine and of the tip engine tell apart, and the first differing region of
	 * the first few. `format` is the command of a side's engine run in a directory over arguments. A file both engines would rewrite, each
	 * its own way, is not seen: the base tree is a fixed point of its own engine, so a sibling library is the only place that happens.
	 */
	public static function read(format: (MovedSide, String, Array<String>) -> Command, unit: MovedUnit): MovedReading {
		final base: Array<String> = listed(run(format(Base, unit.baseDir, ['fmt', '--list'].concat(unit.targets))).out);
		final tip: Array<String> = listed(run(format(Tip, unit.tipDir, ['fmt', '--list'].concat(unit.targets))).out);
		final files: Array<String> = between(base, tip);
		final prefix: String = unit.label == '' ? '' : '${unit.label}/';
		return {
			moved: files.map(file -> prefix + file),
			hunks: files.slice(0, HUNK_FILES).map(file ->
				['$prefix$file'].concat(
					hunk(run(format(Base, unit.baseDir, ['fmt', file])).out, run(format(Tip, unit.tipDir, ['fmt', file])).out)
				)
			)
		};
	}

	/** The row over `tree` for a slice whose changes against `base` are `touched`; its worker's declaration lies beside `logs`. */
	public static function outcome(tree: String, base: String, touched: Array<String>, logs: String, summary: Summary): Outcome {
		if (!reached(touched)) return Skipped('no writer or formatter config change');
		final sibling: String = Sys.getEnv(SIBLING_VAR) ?? '';
		if (sibling != '' && !FileSystem.exists(Path.join([sibling, 'src'])))
			return Failed(GateTree.clip('$SIBLING_VAR=$sibling holds no src directory'));
		return try {
			final engine: String = BaseEngine.forCommit(tree, base, BaseEngine.defaultCache());
			final readings: Array<MovedReading> = TempDir.with(scratch -> {
				final units: Array<MovedUnit> = [repoUnit(tree, base, scratch.path)];
				if (sibling != '') units.push(siblingUnit(sibling, scratch.path));
				units.map(unit -> read((side, dir, args) -> engineAt(tree, engine, side, dir, args), unit));
			});
			settle(readings, sibling != '', declaration(logs), Path.join([logs, LIST]), summary);
		} catch (exception: Exception) {
			Failed(GateTree.clip('moved files: ${exception.message}'));
		};
	}

	/** The row from the `readings` of its units: the list left in `listFile`, the lines shown and the verdict against the declaration. */
	public static function settle(
		readings: Array<MovedReading>, withSibling: Bool, declared: String, listFile: String, summary: Summary
	): Outcome {
		final moved: Array<String> = [ for (reading in readings) for (file in reading.moved) file ];
		File.saveContent(listFile, moved.map(file -> '$file\n').join(''));
		final hunksFile: String = Path.join([Path.directory(listFile), HUNKS]);
		File.saveContent(hunksFile, [ for (reading in readings) for (hunk in reading.hunks) hunk.join('\n') + '\n' ].join('\n'));
		final names: Array<String> = FileSystem.exists(declared) ? named(File.getContent(declared)) : [];
		final result: Outcome = verdict(moved, names);
		summary.detail('${moved.length} moved${withSibling ? '' : ' (no $SIBLING_VAR: the sibling library unread)'}');
		final first: Array<String> = readings.find(reading -> reading.hunks.length > 0)?.hunks[0] ?? [];
		final lines: Array<String> = [
			'${moved.length} moved${result.match(Passed) ? '' : ', name each in $declared as `<path or glob> — <why>` lines'}',
			'all of them in $listFile, a hunk each in $hunksFile'
		];
		for (file in moved.slice(0, LISTED_PATHS)) lines.push('+ $file');
		summary.excerpt(lines.concat(first.slice(0, EXCERPT_HUNK_LINES)));
		return result;
	}

	/** The declaration the worker writes, in the directory above the gate's logs (`<worktree>-logs`). */
	public static function declaration(logs: String): String {
		return Path.join([Path.directory(Path.removeTrailingSlashes(logs)), DECLARATION]);
	}

	/** The command of `side`'s engine (`base` for the base side, the tree's own for the tip) in `dir` over `args`. */
	private static function engineAt(tree: String, base: String, side: MovedSide, dir: String, args: Array<String>): Command {
		return GateTree.shim(tree, dir, args)
			.env(GateTree.ENGINE_VAR, side == Base ? base : Path.join([tree, 'bin/apq.js']))
			.env('APQ_NO_CONFIG_WARN', '1');
	}

	/** `command` run, a failure thrown. */
	private static function run(command: Command): Result {
		final result: Result = command.run();
		if (!result.ok) throw new Exception(result.firstError());
		return result;
	}

	/**
	 * This repository as the base had it, read by the base engine under the base config and by the tip engine under the tip's:
	 * the tip side is a root of symlinks to the base sources beside the config files the tree holds now.
	 */
	private static function repoUnit(tree: String, base: String, root: String): MovedUnit {
		final baseDir: String = Path.join([root, 'repo-base']);
		final tipDir: String = Path.join([root, 'repo-tip']);
		final archive: String = Path.join([root, 'repo.tar']);
		FileSystem.createDirectory(baseDir);
		FileSystem.createDirectory(tipDir);
		cmd('git -C $tree archive --format=tar -o $archive $base ${GateTree.TREE_SCOPE.concat(ROOT_FILES)}').check();
		cmd('tar -xf $archive -C $baseDir').check();
		for (file in ROOT_FILES) File.copy(Path.join([tree, file]), Path.join([tipDir, file]));
		for (target in GateTree.TREE_SCOPE) Fs.symlinkSync(Path.join([baseDir, target]), Path.join([tipDir, target]));
		return {
			label: '',
			baseDir: baseDir,
			tipDir: tipDir,
			targets: GateTree.TREE_SCOPE
		};
	}

	/** The sibling library copied into the scratch `root`, its sources and formatter config only: the library itself is never written. */
	private static function siblingUnit(sibling: String, root: String): MovedUnit {
		final dir: String = Path.join([root, SIBLING]);
		FileSystem.createDirectory(dir);
		cmd('cp -R ${Path.join([sibling, 'src'])} ${Path.join([dir, 'src'])}').check();
		for (config in CONFIGS) if (FileSystem.exists(Path.join([sibling, config])))
			File.copy(Path.join([sibling, config]), Path.join([dir, config]));
		return {
			label: SIBLING,
			baseDir: dir,
			tipDir: dir,
			targets: ['src']
		};
	}

}
