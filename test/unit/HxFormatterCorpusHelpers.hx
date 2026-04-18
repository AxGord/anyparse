package unit;

#if sys
import sys.FileSystem;
import sys.io.File;
#end

/**
 * One parsed `.hxtest` golden file — three sections separated by
 * `\n---\n` in the on-disk format used by the AxGord/haxe-formatter
 * fork's test corpus. `config` is the per-case `hxformat.json` string,
 * `input` is the pre-format Haxe source, `expected` is the reference
 * formatter's byte-exact output.
 */
typedef HxTestCase = {
	final config:String;
	final input:String;
	final expected:String;
}

/**
 * Shared helpers for the haxe-formatter corpus harness. Resolves the
 * fork root from the `ANYPARSE_HXFORMAT_FORK` environment variable and
 * parses individual `.hxtest` golden files into `HxTestCase` triples.
 * The fork lives outside the project tree, so the path is
 * configuration, not a hard-coded constant — a missing fork yields
 * `null` and the consuming test skips cleanly.
 */
@:nullSafety(Strict)
final class HxFormatterCorpusHelpers {

	private static inline final ENV_KEY:String = 'ANYPARSE_HXFORMAT_FORK';
	private static inline final SECTION_SEP:String = '\n---\n';
	private static inline final EXPECTED_SECTIONS:Int = 3;

	/**
	 * Returns the absolute path to the haxe-formatter fork root, or
	 * `null` if the environment variable is unset, empty, points at a
	 * missing directory, or the target has no `sys` package (e.g.
	 * browser-style js builds).
	 */
	public static function forkRoot():Null<String> {
		#if sys
		final root:Null<String> = Sys.getEnv(ENV_KEY);
		if (root == null || root == '') return null;
		if (!FileSystem.exists(root) || !FileSystem.isDirectory(root)) return null;
		return root;
		#else
		return null;
		#end
	}

	/**
	 * Parses a `.hxtest` file at the given absolute path into its
	 * three sections. Returns `null` on malformed files (section
	 * count other than 3) so the harness can count them as skips
	 * without aborting the whole run. Returns `null` on non-`sys`
	 * targets — in practice this path is never reached because
	 * `forkRoot()` already returns `null` there and the consuming
	 * harness skips before calling this helper.
	 */
	public static function readHxTest(path:String):Null<HxTestCase> {
		#if sys
		final content:String = File.getContent(path);
		final parts:Array<String> = content.split(SECTION_SEP);
		if (parts.length != EXPECTED_SECTIONS) return null;
		return {
			config: StringTools.trim(parts[0]),
			input: stripPadNewlines(parts[1]),
			expected: stripPadNewlines(parts[2]),
		};
		#else
		return null;
		#end
	}

	/**
	 * Drops exactly one leading and one trailing `\n` — the padding
	 * convention around each section in the `.hxtest` format.
	 * Preserves any further newlines that are meaningful content.
	 */
	private static function stripPadNewlines(s:String):String {
		var r:String = s;
		if (r.length > 0 && r.charAt(0) == '\n') r = r.substr(1);
		if (r.length > 0 && r.charAt(r.length - 1) == '\n') r = r.substr(0, r.length - 1);
		return r;
	}

	private function new():Void {}

}
