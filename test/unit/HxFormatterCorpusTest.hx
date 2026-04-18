package unit;

import utest.Assert;
import utest.Test;
import haxe.Exception;
import unit.HxFormatterCorpusHelpers.HxTestCase;
#if sys
import sys.FileSystem;
#end
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.runtime.ParseError;

/**
 * υ₁ — corpus harness validating the macro-generated `HxModuleWriter`
 * plus the σ + τ₁ … τ₄ WriteOptions stack against the AxGord/haxe-
 * formatter fork's golden test files. Each `.hxtest` case carries its
 * own `hxformat.json` config alongside paired input/expected Haxe
 * source; this harness runs `parse → write` with that config and
 * compares byte-exactly against `expected`.
 *
 * Category coverage grows one method at a time. This slice lands
 * `sameline/` (132 cases). Subsequent slices add `expressionlevel`,
 * `indentation`, `wrapping`, etc. — each is one new method reusing
 * `HxFormatterCorpusHelpers`.
 *
 * The harness intentionally does NOT fail the utest pass on per-case
 * byte diffs. The first run will surface dozens of grammar gaps
 * (skip-parse) and layout regressions (fail); converting each to a
 * hard assertion right away would block harness adoption. Instead the
 * test prints a summary + the list of failing cases, and stays green
 * as long as the harness itself ran end-to-end. Ratcheting individual
 * categories to hard assertions happens as fixes land.
 */
@:nullSafety(Strict)
class HxFormatterCorpusTest extends Test {

	private static inline final SAMELINE_SUBDIR:String = 'test/testcases/sameline';
	private static inline final HXTEST_EXT:String = '.hxtest';
	private static inline final MAX_DIFF_CONTEXT:Int = 40;
	private static inline final MAX_REASON_LEN:Int = 120;
	private static inline final SNIPPET_LEN:Int = 24;

	public function new():Void {
		super();
	}

	public function testSameLine():Void {
		runCategory(SAMELINE_SUBDIR, 'sameline');
	}

	private function runCategory(subdir:String, label:String):Void {
		final root:Null<String> = HxFormatterCorpusHelpers.forkRoot();
		if (root == null) {
			Assert.pass('$label: ANYPARSE_HXFORMAT_FORK unset, missing, or sys unavailable — corpus skipped');
			return;
		}
		#if sys
		final dir:String = root + '/' + subdir;
		if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir)) {
			Assert.fail('$label: expected corpus dir missing: $dir');
			return;
		}

		var pass:Int = 0;
		var fail:Int = 0;
		var skipMalformed:Int = 0;
		var skipParse:Int = 0;
		var skipWrite:Int = 0;
		final failLines:Array<String> = [];
		final parseReasons:Map<String, Int> = [];

		final names:Array<String> = FileSystem.readDirectory(dir);
		names.sort((a:String, b:String) -> a < b ? -1 : (a > b ? 1 : 0));

		for (name in names) if (StringTools.endsWith(name, HXTEST_EXT)) {
			final path:String = dir + '/' + name;
			final tc:Null<HxTestCase> = HxFormatterCorpusHelpers.readHxTest(path);
			if (tc == null) {
				skipMalformed++;
				continue;
			}
			final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(tc.config);
			// .hxtest fixtures strip the file's trailing \n during read
			// (HxFormatterCorpusHelpers.stripPadNewlines), so the expected
			// section never carries a trailing newline. Disable the
			// writer's finalNewline knob to match — comparison would
			// otherwise show a spurious +1 \n on every byte-exact pass.
			opts.finalNewline = false;
			final module:HxModule = try HaxeModuleParser.parse(tc.input) catch (exception:Exception) {
				skipParse++;
				final reason:String = classifyParseFailure(exception, tc.input);
				final prev:Null<Int> = parseReasons[reason];
				parseReasons[reason] = (prev == null ? 0 : prev) + 1;
				continue;
			};
			final actual:String = try HxModuleWriter.write(module, opts) catch (exception:Exception) {
				skipWrite++;
				continue;
			};
			if (actual == tc.expected) {
				pass++;
			} else {
				fail++;
				failLines.push('  [$name] ' + describeDiff(tc.expected, actual));
			}
		}

		final total:Int = pass + fail + skipMalformed + skipParse + skipWrite;
		Sys.println('$label corpus: $pass pass / $fail fail / $skipParse skip-parse / $skipWrite skip-write / $skipMalformed malformed (total $total)');
		if (fail > 0) Sys.println('$label fails:');
		for (line in failLines) Sys.println(line);
		if (skipParse > 0) printParseReasons(label, parseReasons);

		Assert.isTrue(total > 0, '$label: no cases processed at $dir');
		#end
	}

	/**
	 * Classifies a parse failure into a stable category key suitable
	 * for aggregation. The raw message alone is too generic (the top-
	 * level Pratt fan always reports `expected HxDecl`), so we pair it
	 * with a short snippet of the input at the failure offset. Cases
	 * that choke on the same feature cluster under the same key.
	 */
	private static function classifyParseFailure(exception:Exception, input:String):String {
		final message:String = truncate(exception.message);
		final parseErr:Null<ParseError> = Std.downcast(exception, ParseError);
		if (parseErr == null) return message;
		final pos:Int = parseErr.span.from;
		if (pos < 0 || pos >= input.length) return '$message  @<eof>';
		return '$message  @"${escape(slice(input, pos, SNIPPET_LEN))}"';
	}

	private static function truncate(s:Null<String>):String {
		if (s == null || s == '') return '<no message>';
		return s.length > MAX_REASON_LEN ? s.substr(0, MAX_REASON_LEN) + '...' : s;
	}

	private static function slice(s:String, from:Int, maxLen:Int):String {
		final end:Int = from + maxLen < s.length ? from + maxLen : s.length;
		return s.substring(from, end);
	}

	private static function printParseReasons(label:String, reasons:Map<String, Int>):Void {
		#if sys
		final entries:Array<{reason:String, count:Int}> = [for (r => c in reasons) {reason: r, count: c}];
		entries.sort((a, b) -> b.count - a.count);
		Sys.println('$label skip-parse reasons:');
		for (entry in entries) Sys.println('  ${entry.count}× ${entry.reason}');
		#end
	}

	private static function describeDiff(expected:String, actual:String):String {
		final len:Int = expected.length < actual.length ? expected.length : actual.length;
		var offset:Int = len;
		for (i in 0...len) if (expected.charCodeAt(i) != actual.charCodeAt(i)) {
			offset = i;
			break;
		}
		final expTail:String = snippet(expected, offset);
		final actTail:String = snippet(actual, offset);
		return 'byte-diff @ $offset  exp=<$expTail> act=<$actTail>  (exp.len=${expected.length}, act.len=${actual.length})';
	}

	private static function snippet(s:String, from:Int):String {
		return escape(slice(s, from, MAX_DIFF_CONTEXT));
	}

	private static function escape(s:String):String {
		final buf:StringBuf = new StringBuf();
		for (i in 0...s.length) {
			final c:Int = StringTools.fastCodeAt(s, i);
			switch c {
				case '\n'.code: buf.add('\\n');
				case '\t'.code: buf.add('\\t');
				case '\r'.code: buf.add('\\r');
				case _: buf.addChar(c);
			}
		}
		return buf.toString();
	}

}
