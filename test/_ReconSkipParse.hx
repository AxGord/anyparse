import haxe.Exception;
import sys.FileSystem;
import unit.HxFormatterCorpusHelpers;
import unit.HxFormatterCorpusHelpers.HxTestCase;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span.Position;

/**
 * Throwaway recon for the Phase 3 skip-parse drill campaign (plan
 * rosy-coalescing-clarke, step B1).
 *
 * Now that the parser carries a farthest-failure tracker
 * (`Parser.maxFailPos`/`maxFailExpected`, re-surfaced by the public
 * entry), `ParseError.span.from` points at the innermost blocker
 * instead of the module head. This recon keys its histogram on the
 * deepest `expected` terminal and prints `bucket/name :: L:C
 * expected=… :: <source window at the locus>` so misses cluster by
 * the actual stuck construct, not "expected HxDecl @file-head".
 * Member-bisect a cluster with `hxq`. NOT part of RunTests; delete
 * after recon.
 *
 * Build/run:
 *   haxe -cp src -cp test -lib hxnodejs -main _ReconSkipParse -js /tmp/recon.js
 *   ANYPARSE_HXFORMAT_FORK=/Users/axg/dev/libs/haxe-formatter node /tmp/recon.js
 */
final class _ReconSkipParse {

	private static final _forceBuildParser:Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;

	private static final SUBDIRS:Array<String> = [
		'sameline', 'whitespace', 'indentation', 'wrapping', 'emptylines',
		'lineends', 'other', 'formatrange', 'expressionlevel', 'missing',
	];
	private static inline final HXTEST_EXT:String = '.hxtest';
	private static inline final HEAD_LEN:Int = 70;

	public static function main():Void {
		final args:Array<String> = Sys.args();
		if (args.length > 0) {
			probeFile(args[0]);
			return;
		}
		final root:Null<String> = HxFormatterCorpusHelpers.forkRoot();
		if (root == null) {
			Sys.println('RECON: ANYPARSE_HXFORMAT_FORK env var unset or points at a missing dir — abort.');
			Sys.println('  set it to the haxe-formatter fork checkout containing test/testcases/, e.g.:');
			Sys.println('    ANYPARSE_HXFORMAT_FORK=/path/to/haxe-formatter node /tmp/recon.js');
			Sys.println('  rebuild after a grammar edit with:');
			Sys.println('    haxe recon.hxml');
			return;
		}
		final msgCounts:Map<String, Int> = [];
		var total:Int = 0;
		for (bucket in SUBDIRS) {
			final dir:String = '$root/test/testcases/$bucket';
			if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir)) continue;
			final names:Array<String> = FileSystem.readDirectory(dir);
			names.sort((a:String, b:String) -> a < b ? -1 : (a > b ? 1 : 0));
			for (name in names) if (StringTools.endsWith(name, HXTEST_EXT)) {
				final tc:Null<HxTestCase> = HxFormatterCorpusHelpers.readHxTest('$dir/$name');
				if (tc == null) continue;
				try {
					HaxeModuleTriviaParser.parse(tc.input);
				} catch (exception:ParseError) {
					total++;
					final pos:Position = exception.span.lineCol(tc.input);
					final exp:String = normalize(exception.expected);
					final src:String = normalize(snippet(tc.input, exception.span.from));
					final key:String = '$exp @ $src';
					final prev:Null<Int> = msgCounts[key];
					msgCounts[key] = (prev == null ? 0 : prev) + 1;
					Sys.println('SKIP $bucket/$name :: ${pos.line}:${pos.col} expected="$exp" :: src="$src"');
				} catch (exception:Exception) {
					total++;
					final key:String = '<non-ParseError> ' + normalize(exception.message);
					final prev:Null<Int> = msgCounts[key];
					msgCounts[key] = (prev == null ? 0 : prev) + 1;
					Sys.println('SKIP $bucket/$name :: $key :: head="${head(tc.input)}"');
				}
			}
		}
		Sys.println('--- skip-parse innermost-blocker histogram (total $total) ---');
		final entries:Array<{msg:String, count:Int}> = [for (m => c in msgCounts) {msg: m, count: c}];
		entries.sort((a:{msg:String, count:Int}, b:{msg:String, count:Int}) -> b.count - a.count);
		for (entry in entries) Sys.println('  ${entry.count}× ${entry.msg}');
	}

	private static function probeFile(path:String):Void {
		final src:String = StringTools.endsWith(path, HXTEST_EXT)
			? {
				final tc:Null<HxTestCase> = HxFormatterCorpusHelpers.readHxTest(path);
				tc == null ? '' : tc.input;
			}
			: sys.io.File.getContent(path);
		try {
			HaxeModuleTriviaParser.parse(src);
			Sys.println('PARSE OK');
		} catch (exception:ParseError) {
			final pos:Position = exception.span.lineCol(src);
			Sys.println('PARSE FAIL :: ${pos.line}:${pos.col} expected="${normalize(exception.expected)}" :: src="${normalize(snippet(src, exception.span.from))}"');
		} catch (exception:Exception) {
			Sys.println('PARSE FAIL :: <non-ParseError> ${normalize(exception.message)}');
		}
	}

	/**
	 * Source window of `HEAD_LEN` characters centred on `offset` — the
	 * text around the farthest-failure locus, for construct clustering.
	 */
	private static function snippet(input:String, offset:Int):String {
		final half:Int = Std.int(HEAD_LEN / 2);
		final centre:Int = offset > input.length ? input.length : offset;
		final start:Int = centre - half < 0 ? 0 : centre - half;
		final end:Int = centre + half > input.length ? input.length : centre + half;
		return input.substring(start, end);
	}

	private static function normalize(message:Null<String>):String {
		if (message == null || message == '') return '<no message>';
		return StringTools.replace(StringTools.replace(message, '\n', '\\n'), '\t', '\\t');
	}

	private static function head(input:String):String {
		final cut:String = input.length > HEAD_LEN ? input.substr(0, HEAD_LEN) : input;
		return StringTools.replace(StringTools.replace(cut, '\n', '\\n'), '\t', '\\t');
	}

}
