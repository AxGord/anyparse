package devkit;

using StringTools;

/**
 * The one answer to "how does a tool print rows under a header": each column as wide as its widest cell, the first
 * left-aligned and the rest right-aligned.
 */
@:nullSafety(Strict)
final class Table {

	/** `cells` under `header` as aligned text lines, trailing blanks trimmed. */
	public static function render(header: Array<String>, cells: Array<Array<String>>): String {
		final all: Array<Array<String>> = [header].concat(cells);
		final widths: Array<Int> = [for (_ in header) 0];
		for (row in all) for (i => cell in row) if (cell.length > widths[i]) widths[i] = cell.length;
		return [
			for (row in all)
				[
					for (i => cell in row) i == 0 ? cell.rpad(' ', widths[i]) : cell.lpad(' ', widths[i])
				].join('  ').rtrim()
		].join('\n');
	}

}
