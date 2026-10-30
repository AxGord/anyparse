package dev;

import devkit.Cmd.cmd;
import devkit.Result;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/** One place `apq merge-file` could not merge: the file, the key of the place, and what each side did there. */
typedef MergePlace = {
	final path: String;
	final key: String;
	final sides: String;
}

/**
 * The brief a landing writes when the merge driver leaves a place both sides changed differently: per place, what each
 * side did and what it meant (`apq changed` of the file on each side since the pick's base), the slices behind each side
 * and their queue lines, and the choices a machine can apply — each a `dev land … --resolve` line that re-lands the branch
 * with the place settled by `apq merge-file` — or, when none fits, the rebase the branch's worker owes.
 */
@:nullSafety(Strict)
final class MergeBrief {

	/** The prefix `apq merge-file` reports a conflicting place with. */
	public static inline final CONFLICT_PREFIX: String = 'merge-conflict: ';

	/** The choices a place can be settled with, as `apq merge-file --choices` reads them. */
	public static final CHOICES: Array<String> = ['ours', 'theirs', 'both'];

	/** The places the driver's `output` reports, in order. */
	public static function placesOf(output: String): Array<MergePlace> {
		final out: Array<MergePlace> = [];
		for (raw in output.split('\n')) {
			final line: String = raw.trim();
			if (!line.startsWith(CONFLICT_PREFIX)) continue;
			final rest: String = line.substr(CONFLICT_PREFIX.length);
			final space: Int = rest.indexOf(' ');
			final open: Int = rest.lastIndexOf(' (');
			if (space < 0 || open <= space) continue;
			out.push(
				{ path: rest.substr(0, space), key: rest.substring(space + 1, open), sides: rest.substring(open + 2, rest.length - 1) }
			);
		}
		return out;
	}

	/**
	 * The brief for landing `branch` in `repo` with `places` left, written under `logs`; answers its path. `queue` is the
	 * queue file whose lines name the slices, or null.
	 */
	public static function write(repo: String, branch: String, logs: String, places: Array<MergePlace>, queue: Null<String>): String {
		final base: String = git(repo, ['rev-parse', '--short', '$branch^']).out.trim();
		final queueText: String = queue != null && FileSystem.exists(queue) ? File.getContent(queue) : '';
		final theirsId: String = Land.sliceId(branch);
		final out: StringBuf = new StringBuf();
		out.add('# Merge brief: `$branch` onto `${git(repo, ['rev-parse', '--short', 'HEAD']).out.trim()}` (base `$base`)\n\n');
		out.add('Each place below was changed by both sides differently; `apq merge-file` merged everything else.\n');
		final paths: Array<String> = [];
		for (place in places) if (!paths.contains(place.path)) paths.push(place.path);
		for (path in paths) {
			final oursIds: Array<String> = sliceIds(repo, '$base..HEAD', path);
			out.add('\n## `$path`\n\n');
			out.add('Ours (HEAD) since the base — slices ${oursIds.length == 0 ? 'none named' : oursIds.join(', ')}:\n\n');
			out.add(fenced(changed(repo, '$base..HEAD', path)));
			for (id in oursIds) out.add(queueLine(queueText, id));
			out.add('\nTheirs (`$branch`, slice $theirsId):\n\n');
			out.add(fenced(changed(repo, '$base..$branch', path)));
			out.add(queueLine(queueText, theirsId));
			for (place in places) if (place.path == path) {
				out.add('\n### `${place.key}` — ${place.sides}\n\n');
				for (choice in CHOICES)
					out.add('- $choice: `node bin/dev.js land $branch --resolve \'${place.path}#${place.key}=$choice\'`\n');
				out.add('- none fits: back to the worker of $theirsId — rebase `$branch` onto HEAD with this brief\n');
			}
		}
		final file: String = Path.join([logs, 'merge-brief.md']);
		File.saveContent(file, out.toString());
		return file;
	}

	/** The `Slice` trailers of the commits in `range` that touch `path`, oldest first, each once. */
	private static function sliceIds(repo: String, range: String, path: String): Array<String> {
		final out: Array<String> = [];
		for (line in git(repo, [
			'log',
			'--reverse',
			'--format=%(trailers:key=Slice,valueonly)',
			range,
			'--',
			path
		]).lines()) {
			final id: String = line.trim();
			if (id != '' && !out.contains(id)) out.push(id);
		}
		return out;
	}

	/** What `apq changed` reads off `path` over `range`, or why it could not. */
	private static function changed(repo: String, range: String, path: String): String {
		final run: Result = cmd('node bin/apq.js changed $range $path').at(repo).run();
		return run.ok ? run.out : 'apq changed failed: ${run.firstError()}\n';
	}

	/** The queue line of slice `id` in `queue`, as a quote, or nothing when the queue has none. */
	private static function queueLine(queue: String, id: String): String {
		for (line in queue.split('\n')) if (~/^- \[.\] /.match(line) && line.substr(6).startsWith('$id ')) return '\n> $line\n';
		return '';
	}

	private static function fenced(text: String): String {
		return '```\n${text.endsWith('\n') ? text : '$text\n'}```\n';
	}

	private static function git(repo: String, words: Array<String>): Result {
		return cmd('git -C $repo $words').run();
	}

}
