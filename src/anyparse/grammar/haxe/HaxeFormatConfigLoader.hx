package anyparse.grammar.haxe;

import anyparse.format.IndentChar;
import anyparse.grammar.json.JEntry;
import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;

using Lambda;

/**
 * Loads a haxe-formatter `hxformat.json` config and maps the subset of
 * fields the `HxModule` writer understands into `HxModuleWriteOptions`.
 *
 * The mapping is strictly additive: anything the loader does not
 * recognise is silently ignored (forward-compatible), and every field
 * it does not find falls back to `HaxeFormat.instance.defaultWriteOptions`.
 * This makes round-tripping `HaxeFormatConfigLoader.loadHxFormatJson('{}')`
 * byte-identical to using the defaults directly.
 *
 * Recognised key paths (all optional):
 *
 * - `indentation.character`: string — `"tab"` → `indentChar = Tab, indentSize = 1`;
 *   any string composed entirely of spaces → `indentChar = Space, indentSize = length`.
 *   Every other value is ignored.
 * - `indentation.tabWidth`: int → `tabWidth`.
 * - `wrapping.maxLineLength`: int → `lineWidth`.
 * - `sameLine.ifElse` / `sameLine.tryCatch` / `sameLine.doWhile`: enum
 *   string — `"same"` maps to `true`, every other value (`"next"`,
 *   `"keep"`, `"fitLine"`) maps to `false`. `keep` / `fitLine` would
 *   need per-site source-shape tracking the Haxe writer does not yet
 *   carry; treating them as `next` (false) matches the nearest layout
 *   we can currently render.
 * - `trailingCommas.arrayLiteralDefault` / `trailingCommas.callArgumentDefault`
 *   / `trailingCommas.functionParameterDefault`: enum string — `"yes"`
 *   maps to `true`, every other value (`"no"`, `"keep"`, `"ignore"`) to
 *   `false`. `keep` requires an AST that remembers whether the source
 *   had a trailing comma — a debt to address once the parser records
 *   that detail; for now the writer only knows "always" or "never".
 *
 * Deliberately NOT supported in this slice (no corresponding
 * `HxModuleWriteOptions` field yet): `wrapping.*`, `lineEnds.*`,
 * `emptyLines.*`, `whitespace.*`, `indentation.conditionalPolicy`,
 * `indentation.trailingWhitespace`, `baseTypeHints`, `disableFormatting`,
 * `excludes`. They will land with the slices that introduce the
 * matching knobs.
 *
 * All-static utility: the loader holds no state.
 */
@:nullSafety(Strict)
final class HaxeFormatConfigLoader {

	/**
	 * Parses a `hxformat.json` document and returns the equivalent
	 * `HxModuleWriteOptions`, starting from the Haxe format defaults
	 * and overwriting only the fields the config explicitly sets.
	 */
	public static function loadHxFormatJson(json:String):HxModuleWriteOptions {
		final ast:JValue = JValueParser.parse(json);
		final base:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		final result:HxModuleWriteOptions = {
			indentChar: base.indentChar,
			indentSize: base.indentSize,
			tabWidth: base.tabWidth,
			lineWidth: base.lineWidth,
			lineEnd: base.lineEnd,
			finalNewline: base.finalNewline,
			sameLineElse: base.sameLineElse,
			sameLineCatch: base.sameLineCatch,
			sameLineDoWhile: base.sameLineDoWhile,
			trailingCommaArrays: base.trailingCommaArrays,
			trailingCommaArgs: base.trailingCommaArgs,
			trailingCommaParams: base.trailingCommaParams,
		};
		final root:Array<JEntry> = entriesOf(ast);
		applyIndentation(findObject(root, 'indentation'), result);
		applyWrapping(findObject(root, 'wrapping'), result);
		applySameLine(findObject(root, 'sameLine'), result);
		applyTrailingCommas(findObject(root, 'trailingCommas'), result);
		return result;
	}

	private function new() {}

	private static function applyIndentation(entries:Array<JEntry>, opt:HxModuleWriteOptions):Void {
		final character:Null<String> = findString(entries, 'character');
		if (character != null) {
			if (character == 'tab') {
				opt.indentChar = Tab;
				opt.indentSize = 1;
			} else if (isAllSpaces(character) && character.length > 0) {
				opt.indentChar = Space;
				opt.indentSize = character.length;
			}
		}
		final tabWidth:Null<Int> = findInt(entries, 'tabWidth');
		if (tabWidth != null) opt.tabWidth = tabWidth;
	}

	private static function applyWrapping(entries:Array<JEntry>, opt:HxModuleWriteOptions):Void {
		final maxLineLength:Null<Int> = findInt(entries, 'maxLineLength');
		if (maxLineLength != null) opt.lineWidth = maxLineLength;
	}

	private static function applySameLine(entries:Array<JEntry>, opt:HxModuleWriteOptions):Void {
		final ifElse:Null<String> = findString(entries, 'ifElse');
		if (ifElse != null) opt.sameLineElse = (ifElse == 'same');
		final tryCatch:Null<String> = findString(entries, 'tryCatch');
		if (tryCatch != null) opt.sameLineCatch = (tryCatch == 'same');
		final doWhile:Null<String> = findString(entries, 'doWhile');
		if (doWhile != null) opt.sameLineDoWhile = (doWhile == 'same');
	}

	private static function applyTrailingCommas(entries:Array<JEntry>, opt:HxModuleWriteOptions):Void {
		final arrays:Null<String> = findString(entries, 'arrayLiteralDefault');
		if (arrays != null) opt.trailingCommaArrays = (arrays == 'yes');
		final args:Null<String> = findString(entries, 'callArgumentDefault');
		if (args != null) opt.trailingCommaArgs = (args == 'yes');
		final params:Null<String> = findString(entries, 'functionParameterDefault');
		if (params != null) opt.trailingCommaParams = (params == 'yes');
	}

	private static inline function entriesOf(value:JValue):Array<JEntry> {
		return switch value {
			case JObject(es): es;
			case _: [];
		};
	}

	private static function findEntry(entries:Array<JEntry>, key:String):Null<JEntry> {
		return entries.find(e -> e.key == key);
	}

	private static function findObject(entries:Array<JEntry>, key:String):Array<JEntry> {
		final entry:Null<JEntry> = findEntry(entries, key);
		return entry == null ? [] : entriesOf(entry.value);
	}

	private static function findString(entries:Array<JEntry>, key:String):Null<String> {
		final entry:Null<JEntry> = findEntry(entries, key);
		if (entry == null) return null;
		return switch entry.value {
			case JString(s): s;
			case _: null;
		};
	}

	private static function findInt(entries:Array<JEntry>, key:String):Null<Int> {
		final entry:Null<JEntry> = findEntry(entries, key);
		if (entry == null) return null;
		return switch entry.value {
			case JNumber(n): Std.int(n);
			case _: null;
		};
	}

	private static function isAllSpaces(s:String):Bool {
		for (i in 0...s.length) if (s.charCodeAt(i) != ' '.code) return false;
		return true;
	}
}
