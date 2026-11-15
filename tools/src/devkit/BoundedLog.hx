package devkit;

import haxe.io.Path;
import js.Node;
import sys.FileSystem;
import sys.io.File;

/**
 * The one answer to "keep a bounded append-only line file": a file of single lines (under the blast cache, where a worktree's own
 * logs would die with its slice) that `append` adds one line to and, past a bound, rewrites to the lines the caller's `keep` picks.
 * It is advisory: a compaction racing an append may lose that line.
 */
@:nullSafety(Strict)
final class BoundedLog {

	private final _file: String;

	public function new(file: String) {
		_file = file;
	}

	/** Add `line`; when the file then holds more than `max` lines it is rewritten to the lines `keep` answers for all of them. */
	public function append(line: String, max: Int, keep: Array<String> -> Array<String>): Void {
		final directory: String = Path.directory(_file);
		if (directory != '' && !FileSystem.exists(directory)) FileSystem.createDirectory(directory);
		js.node.Fs.appendFileSync(_file, '$line\n');
		final held: Array<String> = lines();
		if (held.length <= max) return;
		final temp: String = '$_file.${Node.process.pid}.tmp';
		File.saveContent(temp, keep(held).map(kept -> '$kept\n').join(''));
		FileSystem.rename(temp, _file);
	}

	/** The non-empty lines of the file, oldest first; none when there is no file. */
	public function lines(): Array<String> {
		return FileSystem.exists(_file) ? File.getContent(_file).split('\n').filter(line -> line != '') : [];
	}

}
