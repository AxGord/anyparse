package dev;

using Lambda;
using StringTools;

/** One row of a stage's model table: the difficulties `from`..`upto` run on `model` at `effort`. */
typedef TableRow = {
	var stage: String;
	var from: Int;
	var upto: Int;
	var model: String;
	var effort: String;
}

/**
 * The one answer to "which model and effort does a workflow's `model_table` give each stage and difficulty band": reads the
 * `model_table:` → `stages:` block of a workflow YAML, each stage a list of flow mappings `{ upto: N, model: M, effort: E }` in
 * rising `upto`, into `TableRow`s; a band starts one past the row before it. YAML has no grammar here, so only that block's
 * shape is read: a key line opens a level, a deeper `- { … }` line is a row, a line no deeper than `model_table:` ends it.
 */
@:nullSafety(Strict)
final class ModelTable {

	private static final TABLE_KEY: String = 'model_table';
	private static final STAGES_KEY: String = 'stages';
	private static final KEY: EReg = ~/^ *([a-z_]+): *(#.*)?$/;
	private static final ROW: EReg = ~/^ *- *\{(.*)\} *(#.*)?$/;
	private static final PAIR: EReg = ~/^ *([a-z_]+) *: *([^ ]+) *$/;

	/** The rows of every stage of the `model_table` in `yaml`, in document order; empty when it declares none. */
	public static function read(yaml: String): Array<TableRow> {
		final rows: Array<TableRow> = [];
		var tableIndent: Int = -1;
		var stagesIndent: Int = -1;
		var stage: Null<String> = null;
		var from: Int = 1;
		for (line in yaml.split('\n')) {
			final body: String = line.trim();
			if (body == '' || body.startsWith('#')) continue;
			final indent: Int = line.length - line.ltrim().length;
			if (tableIndent < 0) {
				if (KEY.match(line) && KEY.matched(1) == TABLE_KEY) tableIndent = indent;
				continue;
			}
			if (indent <= tableIndent) break;
			if (KEY.match(line)) {
				final key: String = KEY.matched(1);
				if (stagesIndent >= 0 && indent <= stagesIndent) break;
				if (stagesIndent < 0) {
					if (key == STAGES_KEY) stagesIndent = indent;
					continue;
				}
				stage = key;
				from = 1;
				continue;
			}
			final row: Null<TableRow> = stage == null || !ROW.match(line) ? null : rowOf(stage, from, ROW.matched(1));
			if (row == null) continue;
			rows.push(row);
			from = row.upto + 1;
		}
		return rows;
	}

	/** The row of `stage` whose band holds `difficulty`, or null. */
	public static function cellOf(table: Array<TableRow>, stage: String, difficulty: Int): Null<TableRow> {
		return table.find(row -> row.stage == stage && row.from <= difficulty && difficulty <= row.upto);
	}

	/** The stages of `table` in their first-row order. */
	public static function stages(table: Array<TableRow>): Array<String> {
		final out: Array<String> = [];
		for (row in table) if (!out.contains(row.stage)) out.push(row.stage);
		return out;
	}

	private static function rowOf(stage: String, from: Int, mapping: String): Null<TableRow> {
		final values: Map<String, String> = [ for (pair in mapping.split(',')) if (PAIR.match(pair)) PAIR.matched(1) => PAIR.matched(2) ];
		final upto: Null<Int> = Std.parseInt(values['upto'] ?? '');
		final model: Null<String> = values['model'];
		final effort: Null<String> = values['effort'];
		return upto == null || model == null || effort == null ? null : {
			stage: stage,
			from: from,
			upto: upto,
			model: model,
			effort: effort
		};
	}

}
