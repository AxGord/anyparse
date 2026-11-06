package devkit;

using StringTools;

/**
 * The one answer to "which lines of a failed step's output decide it, and how many may a table show": a step names the
 * lines that explain its failure, and the table prints them under itself, so no reader opens the log to find them.
 * The cap is the reader's budget, not the log's size — a longer excerpt ends in a line saying how many it left out.
 */
@:nullSafety(Strict)
final class Excerpt {

	/** The most lines one step's excerpt prints, the line that counts the rest included. */
	public static inline final MAX_LINES: Int = 10;

	/** The longest line an excerpt prints; a longer one ends in an ellipsis. */
	public static inline final MAX_WIDTH: Int = 240;

	/** A line that reads like an error. */
	private static final ERROR_LINE: EReg = ~/error|Error|ERROR|FAIL|fail|not found|refused|CONFLICT|threw/;

	/** The non-blank lines of `text`, trailing whitespace removed. */
	public static function linesOf(text: String): Array<String> {
		return [for (line in text.split('\n')) if (line.trim() != '') line.rtrim()];
	}

	/** The last `count` non-blank lines of `text`. */
	public static function tail(text: String, count: Int = MAX_LINES): Array<String> {
		final all: Array<String> = linesOf(text);
		return all.slice(Std.int(Math.max(0, all.length - count)));
	}

	/** The lines of `text` that read like an error and are no compiler warning; the last lines of it when none does. */
	public static function errors(text: String): Array<String> {
		final found: Array<String> = linesOf(text).filter(l -> ERROR_LINE.match(l) && l.indexOf('Warning') < 0);
		return found.length == 0 ? tail(text) : found;
	}

	/** `lines` as a table prints them: each clipped to `MAX_WIDTH`, at most `MAX_LINES`, the last saying how many were left out. */
	public static function cut(lines: Array<String>): Array<String> {
		final shown: Array<String> = lines.length <= MAX_LINES ? lines : lines.slice(0, MAX_LINES - 1);
		final cutLines: Array<String> = shown.map(line -> line.length <= MAX_WIDTH ? line : '${line.substr(0, MAX_WIDTH - 1)}…');
		if (lines.length > MAX_LINES) cutLines.push('… ${lines.length - shown.length} more');
		return cutLines;
	}

}
