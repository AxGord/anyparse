package dev;

using Lambda;
using StringTools;

import devkit.Cmd.cmd;
import devkit.Result;
import sys.FileSystem;
import sys.io.File;

/**
 * The one answer to "is a land whose battery is red only on the `fmt` row the branch's own doing, or the writer's drift on files
 * main changed after the branch's last sync?". Reads the battery's log (its table and the files its `fmt` section lists) and the two
 * file lists of the landing: what the branch changed and what main changed since their merge base. A drifted file the branch did not
 * touch and main did is a race the author settles by syncing and rewriting it; every other red battery stays a plain failure.
 */
@:nullSafety(Strict)
final class LandFmtRace {

	/** The reason the battery's `fmt` row gives when the one-pass list is not empty. */
	public static final LISTED: String = 'fmt --list --one-pass is not empty';

	/** The capture group of a table line that holds its reason. */
	private static inline final WHY_GROUP: Int = 3;

	/** The name of the battery row this verdict is about; its siblings `fmt xconfig` and `fmt squash` are other rows. */
	private static final ROW: String = 'fmt';

	/** The log line that opens the section the `fmt` row printed its listed files in. */
	private static final HEADER: String = '=== fmt ===';

	/** The verdict text, or null when the red battery is not a race: see the class doc. `own` and `moved` are repo-relative paths. */
	public static function verdict(log: String, own: Array<String>, moved: Array<String>): Null<String> {
		final rows: Array<RedRow> = red(log);
		if (rows.length != 1 || rows[0].name != ROW) return null;
		final why: String = rows[0].why;
		// a second reason, joined by `; `, is the fork verify failing too: not a drift main alone brought
		if (!why.startsWith(LISTED) || why.indexOf('; ') >= 0) return null;
		final files: Array<String> = listed(log);
		if (files.length == 0 || files.exists(file -> own.contains(file) || !moved.contains(file))) return null;
		final names: String = files.join(' ');
		return 'fmt-race $names\n'
			+ 'main changed these after the branch\'s last sync and the writer rewrites them; the branch did not touch them. '
			+ 'fix: sync; `hxq fmt --write $names` with your engine; `hxq changed <base>..HEAD` must class every file `layout`; amend';
	}

	/**
	 * `verdict` of the battery log at `log` against the checked-out commit of `repo` and `branch`: the branch's own files are
	 * what it changed since their merge base, the moved ones what the checked-out commit changed since it. Null when the log
	 * is unread or git cannot say.
	 */
	public static function read(repo: String, branch: String, log: String): Null<String> {
		if (!FileSystem.exists(log)) return null;
		final base: Result = cmd('git -C $repo merge-base HEAD $branch').run();
		if (!base.ok) return null;
		final from: String = base.out.trim();
		final own: Result = cmd('git -C $repo diff --name-only --no-renames $from $branch').run();
		final moved: Result = cmd('git -C $repo diff --name-only --no-renames $from HEAD').run();
		return own.ok && moved.ok ? verdict(File.getContent(log), own.lines(), moved.lines()) : null;
	}

	/** The rows of the battery's table that failed or could not run, in table order. */
	public static function red(log: String): Array<RedRow> {
		final rows: Array<RedRow> = [];
		final row: EReg = ~/^(.+?) {2,}(passed|FAILED|not run|skipped) +[0-9]+\.[0-9]s(.*)$/;
		for (line in log.split('\n')) if (row.match(line)) {
			final label: String = row.matched(2);
			if (label == 'FAILED' || label == 'not run') rows.push({ name: row.matched(1), why: row.matched(WHY_GROUP).trim() });
		}
		return rows;
	}

	/** The files of `GateTree.TREE_SCOPE` the `fmt` section of the log lists, each once. */
	public static function listed(log: String): Array<String> {
		final files: Array<String> = [];
		var inside: Bool = false;
		for (line in log.split('\n')) {
			if (line.startsWith('=== ')) {
				inside = line.trim() == HEADER;
				continue;
			}
			if (inside && isTreeFile(line) && !files.contains(line)) files.push(line);
		}
		return files;
	}

	private static function isTreeFile(line: String): Bool {
		return line.endsWith('.hx') && line.indexOf(' ') < 0 && GateTree.TREE_SCOPE.exists(root -> line.startsWith('$root/'));
	}

}

/** A battery row that did not pass: its name and the reason its table line gives. */
typedef RedRow = { var name: String; var why: String; }
