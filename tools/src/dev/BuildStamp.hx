package dev;

import anyparse.core.ContentHash;
import devkit.Cmd.cmd;
import devkit.Result;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * The one answer to "are the binaries in a tree's `bin` already the build of its content as it stands": a build line that
 * compiled green leaves a marker named by the content it read and the binaries it left, and a later compile of that line in
 * the same tree takes the binaries only while both are unchanged.
 *
 * The content is the tree id of every file git does not ignore, uncommitted and untracked ones included (staged in an index
 * of the stamp's own, never the tree's), joined with the compile fingerprint of the build file the caller hands in
 * (`Binaries` hands `OracleCache.fingerprint`: the compiler, its defines, the library and std sources it names). An ignored
 * file is never an input. The binaries are every ignored
 * `bin/*.js` by content, so a hand build, a mutant's build or a copy over one makes every marker stale.
 */
@:nullSafety(Strict)
final class BuildStamp {

	/** The directory of markers, under the tree's own git directory: a worktree's dies with it and none is ever tracked. */
	public static final DIR: String = 'anyparse-build-stamps';

	/** The index the content is staged in, beside the markers. */
	private static final INDEX: String = 'anyparse-build-index';

	private final _keys: Map<String, Null<String>> = [];
	private final _tree: String;
	private final _dir: Null<String>;
	private final _content: Null<String>;
	private final _binaries: String;
	private final _fingerprint: String -> Null<String>;

	private function new(
		tree: String, dir: Null<String>, content: Null<String>, binaries: String, fingerprint: String -> Null<String>
	) {
		_tree = tree;
		_dir = dir;
		_content = content;
		_binaries = binaries;
		_fingerprint = fingerprint;
	}

	/** Whether the build line `words` already made this content into the binaries the tree holds. */
	public function holds(words: Array<String>): Bool {
		final dir: Null<String> = _dir;
		final key: Null<String> = keyOf(words);
		return dir != null && key != null && FileSystem.exists(Path.join([dir, marker(key, _binaries)]));
	}

	/**
	 * Leave a marker for each line of `made` (green on this content) over the binaries the tree holds now, every older marker
	 * gone; nothing when the content moved since `of`, as the binaries may then be the build of either.
	 */
	public function record(made: Array<Array<String>>): Void {
		final dir: Null<String> = _dir;
		final content: Null<String> = _content;
		if (dir == null || content == null || contentOf(_tree) != content) return;
		if (FileSystem.exists(dir))
			for (name in FileSystem.readDirectory(dir)) FileSystem.deleteFile(Path.join([dir, name]));
		else
			FileSystem.createDirectory(dir);
		final binaries: String = binariesOf(_tree);
		for (words in made) {
			final key: Null<String> = keyOf(words);
			if (key != null) File.saveContent(Path.join([dir, marker(key, binaries)]), words.join(' '));
		}
	}

	/** The key of the build line `words` on this content, or null when the tree has no git or the compiler no fingerprint. */
	private function keyOf(words: Array<String>): Null<String> {
		final line: String = words.join(' ');
		if (_keys.exists(line)) return _keys[line];
		final content: Null<String> = _content;
		final fingerprint: Null<String> = content == null || words.length == 0 ? null : _fingerprint(words[0]);
		final key: Null<String> = content == null || fingerprint == null
			? null
			: ContentHash.md5([content, fingerprint].concat(words).join('\n'));
		_keys[line] = key;
		return key;
	}

	/**
	 * The stamp of `tree` as it stands now; `fingerprint` answers the compile fingerprint of a build file of `tree`, or null when
	 * it cannot, and then no line of that file is ever held.
	 */
	public static function of(tree: String, fingerprint: String -> Null<String>): BuildStamp {
		final dir: Null<String> = gitPath(tree, DIR);
		return new BuildStamp(tree, dir, dir == null ? null : contentOf(tree), binariesOf(tree), fingerprint);
	}

	private static function marker(key: String, binaries: String): String {
		return ContentHash.md5('$key\n$binaries');
	}

	/** The tree id of every file of `tree` git does not ignore, as the files stand, or null when git cannot say. */
	private static function contentOf(tree: String): Null<String> {
		final index: Null<String> = gitPath(tree, INDEX);
		if (index == null) return null;
		final seed: Null<String> = gitPath(tree, 'index');
		// the tree's own index seeds the first staging with its file stats, so only a changed file is read again
		if (!FileSystem.exists(index) && seed != null && FileSystem.exists(seed)) File.copy(seed, index);
		final staged: Result = cmd('git -C $tree add -A').env('GIT_INDEX_FILE', index).run();
		if (!staged.ok) return null;
		final written: Result = cmd('git -C $tree write-tree').env('GIT_INDEX_FILE', index).run();
		return written.ok ? written.out.trim() : null;
	}

	/** The digest of every ignored `bin/*.js` of `tree` by path and content. */
	private static function binariesOf(tree: String): String {
		final listed: Result = cmd('git -C $tree ls-files --others --ignored --exclude-standard -- bin').run();
		final files: Array<String> = listed.ok ? listed.lines() : [];
		return ContentHash.md5([
			for (path in files) if (Path.extension(path) == 'js') '$path ${ContentHash.md5Bytes(File.getBytes(Path.join([tree, path])))}'
		].join('\n'));
	}

	/** The absolute path of `name` in the git directory of `tree`, or null when `tree` is in no git tree. */
	private static function gitPath(tree: String, name: String): Null<String> {
		final asked: Result = cmd('git -C $tree rev-parse --git-path $name').run();
		final path: String = asked.out.trim();
		return if (!asked.ok || path == '')
			null
		else if (Path.isAbsolute(path))
			path
		else
			Path.join([FileSystem.fullPath(tree), path]);
	}

}
