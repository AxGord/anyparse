package dev;

import devkit.Command;
import devkit.Result;
import haxe.io.Path;
import js.node.Fs.Fs;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * The cross-config one-pass set: the one answer to "which files does the writer settle only on a second rewrite under the
 * vendored second config?". The battery runs it over the whole tree and the slice gate over the files a slice touched.
 */
@:nullSafety(Strict)
final class XconfigFmt {

	/** The vendored second formatter config the cross-config arm formats this tree under. */
	public static inline final XCONFIG: String = 'tools/data/xconfig-hxformat.json';

	/**
	 * The files the writer settles only on a second rewrite under the vendored config. Compared for equality:
	 * a file joining is a regression and one leaving is progress, and either is recorded here with the measurement.
	 */
	public static final XCONFIG_ONE_PASS: Array<String> = [
		'src/anyparse/check/common/control/UnnecessarySwitch.hx',
		'src/anyparse/query/cli/DeclarationDelta.hx'
	];

	/** The files under the scratch `root` that `fmt --one-pass`'s stderr `err` names, relative to `root`, sorted. */
	public static function onePassSet(err: String, root: String): Array<String> {
		final prefix: String = 'apq fmt: $root/';
		final marker: String = ': the writer needed ';
		final files: Array<String> = [
			for (line in err.split('\n')) if (line.startsWith(prefix) && line.indexOf(marker) >= 0)
				line.substring(prefix.length, line.indexOf(marker))
		];
		files.sort(Reflect.compare);
		return files;
	}

	/** How the set `now` differs from `expected`: `- <file>` for one gone, `+ <file>` for one joined; empty when equal. */
	public static function setMoves(expected: Array<String>, now: Array<String>): Array<String> {
		return
			[for (file in expected) if (!now.contains(file)) '- $file'].concat([for (file in now) if (!expected.contains(file)) '+ $file']);
	}

	/**
	 * The files `files` of `repo` (its whole `TREE_SCOPE` when null) formatted one-pass under the vendored second config, through a
	 * scratch `root` of symlinks (config discovery walks up lexically), so an interrupted run cannot leave the repo holding a foreign
	 * config. `hxq` is the command that runs the engine over the given arguments. The one answer to "which files does the writer settle
	 * only on a second rewrite under the cross-config?".
	 */
	public static function xconfigRun(hxq: Array<String> -> Command, repo: String, root: String, files: Null<Array<String>>): XconfigRun {
		FileSystem.createDirectory(root);
		File.copy(Path.join([repo, XCONFIG]), Path.join([root, 'hxformat.json']));
		final targets: Array<String> = files ?? GateTree.TREE_SCOPE;
		for (target in targets) {
			final link: String = Path.join([root, target]);
			final parent: String = Path.directory(link);
			if (!FileSystem.exists(parent)) FileSystem.createDirectory(parent);
			Fs.symlinkSync(Path.join([repo, target]), link);
		}
		final run: Result = hxq(['fmt', '--list', '--one-pass'].concat([for (target in targets) Path.join([root, target])]))
			.env('APQ_NO_CONFIG_WARN', '1')
			.run();
		final lines: Array<String> = run.err.split('\n').filter(l -> l != '');
		final summary: Array<String> = lines.filter(l -> l.startsWith('apq fmt --list:') || l.startsWith('apq fmt --one-pass:'));
		// the per-file one-pass lines are the expected bulk; anything else on stderr (a crash, a parse failure) is shown
		return {
			shown: summary.concat(lines.filter(l -> l.indexOf(': the writer needed ') < 0 && !summary.contains(l))),
			// the summary line is the completion proof: a run cut short after the baseline's packages would match the set
			finished: lines.exists(l -> l.startsWith('apq fmt --list:')),
			onePass: onePassSet(run.err, root)
		};
	}

	/**
	 * Why a cross-config `run` fails against the `expected` set: a file that joined the set is a writer defect (or a filed
	 * non-convergence), one that left is progress to record; the filed files
	 * `gone` from the tree count with those that left; null when the run holds.
	 */
	public static function xconfigVerdict(run: XconfigRun, expected: Array<String>, gone: Array<String>): Null<XconfigFailure> {
		if (!run.finished) return {
			line: 'the cross-config fmt run printed no summary line — it did not finish, so its one-pass set means nothing',
			detail: run.shown
		};
		final moved: Array<String> = setMoves(expected, run.onePass);
		return failureOf(
			[for (move in moved) if (move.startsWith('+ ')) move.substr(2)],
			[for (move in moved) if (move.startsWith('- ')) move.substr(2)],
			gone
		);
	}

	/** The `.hx` files among `touched` that lie under the tree's formatted scope. */
	public static function hxFilesOf(touched: Array<String>): Array<String> {
		return touched.filter(file -> file.endsWith('.hx') && GateTree.TREE_SCOPE.exists(dir -> file.startsWith('$dir/')));
	}

	/**
	 * The filed files that no longer exist under `repo`: a slice that deletes one leaves the filed set holding a name the writer can
	 * never report, which the battery then reads as a file that settled.
	 */
	public static function missingFiled(repo: String): Array<String> {
		return XCONFIG_ONE_PASS.filter(file -> !FileSystem.exists(Path.join([repo, file])));
	}

	/**
	 * The cross-config check of a slice that touched `touched`: the touched `.hx` files run in the scratch `root` against the filed
	 * files among them (an untouched filed file is not compared: the battery sees it at the landing), and every filed file gone from
	 * `repo`, touched or not. Nothing to run and nothing gone is `Skipped`.
	 */
	public static function touchedStand(hxq: Array<String> -> Command, repo: String, touched: Array<String>, root: String): XconfigStand {
		final gone: Array<String> = missingFiled(repo);
		final files: Array<String> = hxFilesOf(touched);
		final failure: Null<XconfigFailure> = files.length == 0
			? failureOf([], [], gone)
			: xconfigVerdict(xconfigRun(hxq, repo, root, files), XCONFIG_ONE_PASS.filter(file -> files.contains(file)), gone);
		return if (failure != null)
			Breaks(failure)
		else if (files.length == 0)
			Skipped
		else
			Holds;
	}

	/**
	 * The failure of the files `joined` (needing a second rewrite and not filed) and `left` (filed and settling) plus the filed
	 * files `gone`, or null when there are none. The line names each half with its remedy, short enough to survive a row's clip at
	 * any file count; the detail names the files and spells the remedies out.
	 */
	private static function failureOf(joined: Array<String>, left: Array<String>, gone: Array<String>): Null<XconfigFailure> {
		final settled: Array<String> = left.concat(gone.filter(file -> !left.contains(file)));
		if (joined.length == 0 && settled.length == 0) return null;
		final parts: Array<String> = [];
		final detail: Array<String> = [];
		if (joined.length > 0) {
			parts.push('+${joined.length}: fix the writer, or file in XCONFIG_ONE_PASS (non-convergence only, decisions line)');
			for (file in joined) detail.push('+ $file');
			detail.push(
				'+ needs a second rewrite only under the cross-config: fix the writer, or, for a filed non-convergence only, '
				+ 'add the file to XconfigFmt.XCONFIG_ONE_PASS with a decisions line'
			);
		}
		if (settled.length > 0) {
			parts.push('-${settled.length}: now settle, remove from XCONFIG_ONE_PASS');
			for (file in settled) detail.push(gone.contains(file) ? '- $file (gone from the tree)' : '- $file');
			detail.push('- settles in one pass (or is gone): remove the file from XconfigFmt.XCONFIG_ONE_PASS');
		}
		return { line: 'xconfig ${parts.join('; ')}', detail: detail };
	}

}

/** One cross-config run: the lines worth showing, whether it ran to its summary line, and the one-pass set it found. */
typedef XconfigRun = {
	var shown: Array<String>;
	var finished: Bool;
	var onePass: Array<String>;
}

/** A failed cross-config check: the one line a gate row quotes (half and remedy, whatever the file count) and the lines beneath it. */
typedef XconfigFailure = {
	var line: String;
	var detail: Array<String>;
}

/** Where the cross-config check of a slice's touched files stands: nothing to check, held, or broken. */
enum XconfigStand {
	Skipped;
	Holds;
	Breaks(failure: XconfigFailure);
}
