package unit;

import utest.Assert;
import utest.Test;
import haxe.Exception;
import unit.HxFormatterCorpusHelpers.HxTestCase;
#if (sys || nodejs)
import sys.FileSystem;
#end
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.runtime.ParseError;

/**
 * υ₁ — corpus harness validating the macro-generated Haxe writer plus
 * the σ + τ₁ … τ₄ WriteOptions stack against the AxGord/haxe-formatter
 * fork's golden test files. Each `.hxtest` case carries its own
 * `hxformat.json` config alongside paired input/expected Haxe source;
 * this harness runs `parse → write` with that config and compares
 * byte-exactly against `expected`.
 *
 * ω₈ — pivoted to the Trivia pipeline
 * (`HaxeModuleTriviaParser`/`HaxeModuleTriviaWriter`) so comments and
 * blank lines survive round-trip. Plain-mode pipeline is still available
 * on `HaxeModuleParser`/`HxModuleWriter` for layout-only tests that do
 * not need comment preservation.
 *
 * All 10 fork corpus categories are wired:
 * `whitespace/` (153), `sameline/` (132), `indentation/` (130),
 * `wrapping/` (200), `emptylines/` (96), `lineends/` (94),
 * `other/` (62), `formatrange/` (15), `expressionlevel/` (1),
 * `missing/` (1). Each category is one method reusing
 * `HxFormatterCorpusHelpers` — extending coverage to a new fork
 * directory takes ~4 lines (1 const + 1 method + doc bump).
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

	private static final _forceBuildParser:Class<HaxeModuleTriviaParser> = HaxeModuleTriviaParser;
	private static final _forceBuildWriter:Class<HaxeModuleTriviaWriter> = HaxeModuleTriviaWriter;

	private static inline final SAMELINE_SUBDIR:String = 'test/testcases/sameline';
	private static inline final WHITESPACE_SUBDIR:String = 'test/testcases/whitespace';
	private static inline final INDENTATION_SUBDIR:String = 'test/testcases/indentation';
	private static inline final WRAPPING_SUBDIR:String = 'test/testcases/wrapping';
	private static inline final EMPTYLINES_SUBDIR:String = 'test/testcases/emptylines';
	private static inline final LINEENDS_SUBDIR:String = 'test/testcases/lineends';
	private static inline final OTHER_SUBDIR:String = 'test/testcases/other';
	private static inline final FORMATRANGE_SUBDIR:String = 'test/testcases/formatrange';
	private static inline final EXPRESSIONLEVEL_SUBDIR:String = 'test/testcases/expressionlevel';
	private static inline final MISSING_SUBDIR:String = 'test/testcases/missing';
	private static inline final HXTEST_EXT:String = '.hxtest';
	private static inline final MAX_DIFF_CONTEXT:Int = 40;
	private static inline final MAX_REASON_LEN:Int = 120;
	private static inline final SNIPPET_LEN:Int = 24;
	private static inline final SWEEP_JSON_PATH:String = 'bin/.last-sweep.json';

	// ω-sweep-delta — process-wide accumulator across every per-category
	// `runCategory` invocation. The per-category prints stay (legacy
	// behavior), and a single end-of-process aggregate prints the totals
	// + delta vs the previously-recorded sweep (`bin/.last-sweep.json`,
	// .gitignored). The accumulator collapses the manual "compare against
	// the number I remember from `docs/roadmap.md`" loop at the tail of
	// every slice — Δpass / Δfail / Δskip-parse appears automatically
	// after `node bin/test.js` ends. The JSON file is rewritten only
	// when total > 0 (`ANYPARSE_HXFORMAT_FORK` actually pointed at a
	// fork checkout); a no-fork run leaves the baseline untouched.
	private static var sweepRegistered:Bool = false;
	private static var sweepPass:Int = 0;
	private static var sweepFail:Int = 0;
	private static var sweepSkipParse:Int = 0;
	private static var sweepSkipWrite:Int = 0;
	private static var sweepSkipConfig:Int = 0;
	private static var sweepSkipMalformed:Int = 0;
	// ω-sweep-fixture-status: per-fixture status map for `apq recon
	// --regression-probe`. Each runCategory iteration appends one entry
	// per `.hxtest` it inspects. Path format is `<subdir>/<name>` (e.g.
	// `whitespace/issue_195_macro_do_while.hxtest`), matching what
	// `Cli.collectReconSkipRecords` reports — so the diff machinery can
	// look up "what was this fixture's status last sweep?" by path alone.
	// Status enum is restricted to the six categories runCategory emits:
	// PASS / FAIL / SKIP_PARSE / SKIP_WRITE / SKIP_CONFIG / MALFORMED.
	private static final sweepFixtures:Array<{path:String, status:String}> = [];

	public function new():Void {
		super();
	}

	public function testSameLine():Void {
		runCategory(SAMELINE_SUBDIR, 'sameline');
	}

	public function testWhitespace():Void {
		runCategory(WHITESPACE_SUBDIR, 'whitespace');
	}

	public function testIndentation():Void {
		runCategory(INDENTATION_SUBDIR, 'indentation');
	}

	public function testWrapping():Void {
		runCategory(WRAPPING_SUBDIR, 'wrapping');
	}

	public function testEmptyLines():Void {
		runCategory(EMPTYLINES_SUBDIR, 'emptylines');
	}

	public function testLineEnds():Void {
		runCategory(LINEENDS_SUBDIR, 'lineends');
	}

	public function testOther():Void {
		runCategory(OTHER_SUBDIR, 'other');
	}

	public function testFormatRange():Void {
		runCategory(FORMATRANGE_SUBDIR, 'formatrange');
	}

	public function testExpressionLevel():Void {
		runCategory(EXPRESSIONLEVEL_SUBDIR, 'expressionlevel');
	}

	public function testMissing():Void {
		runCategory(MISSING_SUBDIR, 'missing');
	}

	private function runCategory(subdir:String, label:String):Void {
		final root:Null<String> = HxFormatterCorpusHelpers.forkRoot();
		if (root == null) {
			Assert.pass('$label: ANYPARSE_HXFORMAT_FORK unset, missing, or sys unavailable — corpus skipped');
			return;
		}
		#if (sys || nodejs)
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
		var skipConfig:Int = 0;
		final failLines:Array<String> = [];
		final parseReasons:Map<String, Int> = [];

		final names:Array<String> = FileSystem.readDirectory(dir);
		names.sort((a:String, b:String) -> a < b ? -1 : (a > b ? 1 : 0));

		for (name in names) if (StringTools.endsWith(name, HXTEST_EXT)) {
			final path:String = dir + '/' + name;
			// Subdir-relative path for the sweep snapshot; matches what
			// `apq recon` reports per-fixture, so `--regression-probe`
			// can look up the previous status by this exact key.
			final relPath:String = '$subdir/$name';
			final tc:Null<HxTestCase> = HxFormatterCorpusHelpers.readHxTest(path);
			if (tc == null) {
				skipMalformed++;
				sweepFixtures.push({path: relPath, status: 'MALFORMED'});
				continue;
			}
			final opts:HxModuleWriteOptions = try HaxeFormatConfigLoader.loadHxFormatJson(tc.config) catch (exception:Exception) {
				skipConfig++;
				sweepFixtures.push({path: relPath, status: 'SKIP_CONFIG'});
				continue;
			};
			// .hxtest fixtures strip exactly one trailing `\n` from each
			// section (HxFormatterCorpusHelpers.stripPadNewlines).
			// Enable the writer's finalNewline knob and strip a matching
			// trailing `\n` from `actual` below so the comparison stays
			// symmetric for all `lineEnd` values: under `lineEnd = '\n'`
			// the strip drops the appended LF; under `lineEnd = '\r\n'`
			// it drops the trailing LF leaving the `\r` that the fixture's
			// stripPadNewlines also leaves in `expected`.
			opts.finalNewline = true;
			final module:anyparse.grammar.haxe.trivia.Pairs.HxModuleT = try HaxeModuleTriviaParser.parse(tc.input) catch (exception:Exception) {
				skipParse++;
				final reason:String = classifyParseFailure(exception, tc.input);
				final prev:Null<Int> = parseReasons[reason];
				parseReasons[reason] = (prev == null ? 0 : prev) + 1;
				sweepFixtures.push({path: relPath, status: 'SKIP_PARSE'});
				continue;
			};
			final actualRaw:String = try HaxeModuleTriviaWriter.write(module, opts) catch (exception:Exception) {
				skipWrite++;
				sweepFixtures.push({path: relPath, status: 'SKIP_WRITE'});
				continue;
			};
			final actual:String = actualRaw.length > 0 && StringTools.fastCodeAt(actualRaw, actualRaw.length - 1) == '\n'.code
				? actualRaw.substr(0, actualRaw.length - 1)
				: actualRaw;
			if (actual == tc.expected) {
				pass++;
				sweepFixtures.push({path: relPath, status: 'PASS'});
			} else {
				fail++;
				failLines.push('  [$name] ' + describeDiff(tc.expected, actual));
				sweepFixtures.push({path: relPath, status: 'FAIL'});
			}
		}

		final total:Int = pass + fail + skipMalformed + skipParse + skipWrite + skipConfig;
		Sys.println('$label corpus: $pass pass / $fail fail / $skipParse skip-parse / $skipWrite skip-write / $skipConfig skip-config / $skipMalformed malformed (total $total)');
		if (fail > 0) Sys.println('$label fails:');
		for (line in failLines) Sys.println(line);
		if (skipParse > 0) printParseReasons(label, parseReasons);

		sweepPass += pass;
		sweepFail += fail;
		sweepSkipParse += skipParse;
		sweepSkipWrite += skipWrite;
		sweepSkipConfig += skipConfig;
		sweepSkipMalformed += skipMalformed;
		ensureSweepFinalizer();

		Assert.isTrue(total > 0, '$label: no cases processed at $dir');
		#end
	}

	/**
	 * Lazy one-shot registration of the end-of-process sweep-delta
	 * printer. Called from every `runCategory` invocation but the body
	 * runs exactly once — uses Node.js's `process.on('exit')` because
	 * Haxe `Sys` does not expose an at-exit hook and utest's
	 * `teardownClass` is not present in the 1.13.x line we run on.
	 */
	private function ensureSweepFinalizer():Void {
		if (sweepRegistered) return;
		sweepRegistered = true;
		#if nodejs
		js.Node.process.on('exit', _ -> printSweepDelta());
		#end
	}

	/**
	 * Aggregate-totals + delta-vs-baseline report. Reads the previous
	 * sweep's JSON (if any), formats the Δ triple, then overwrites the
	 * file with the current run's totals. Guards against the no-fork run
	 * (every counter still zero) so the baseline is never silently
	 * zero-clobbered.
	 */
	private static function printSweepDelta():Void {
		#if (sys || nodejs)
		final total:Int = sweepPass + sweepFail + sweepSkipParse + sweepSkipWrite + sweepSkipConfig + sweepSkipMalformed;
		if (total == 0) return;
		var prevPass:Null<Int> = null;
		var prevFail:Null<Int> = null;
		var prevSkipParse:Null<Int> = null;
		if (FileSystem.exists(SWEEP_JSON_PATH)) try {
			final raw:String = sys.io.File.getContent(SWEEP_JSON_PATH);
			final obj:Dynamic = haxe.Json.parse(raw);
			if (Reflect.hasField(obj, 'pass') && Std.isOfType(Reflect.field(obj, 'pass'), Int))
				prevPass = Reflect.field(obj, 'pass');
			if (Reflect.hasField(obj, 'fail') && Std.isOfType(Reflect.field(obj, 'fail'), Int))
				prevFail = Reflect.field(obj, 'fail');
			if (Reflect.hasField(obj, 'skipParse') && Std.isOfType(Reflect.field(obj, 'skipParse'), Int))
				prevSkipParse = Reflect.field(obj, 'skipParse');
		} catch (_:Exception) {}
		final deltaStr:String = if (prevPass != null && prevFail != null && prevSkipParse != null) {
			final dPass:Int = sweepPass - (prevPass : Int);
			final dFail:Int = sweepFail - (prevFail : Int);
			final dSkipParse:Int = sweepSkipParse - (prevSkipParse : Int);
			'  Δpass ${signed(dPass)} / Δfail ${signed(dFail)} / Δskip-parse ${signed(dSkipParse)}  vs last sweep ($prevPass / $prevFail / $prevSkipParse)';
		} else '  (no previous sweep recorded)';
		Sys.println('');
		Sys.println('===== sweep totals: $sweepPass pass / $sweepFail fail / $sweepSkipParse skip-parse / $sweepSkipWrite skip-write / $sweepSkipConfig skip-config / $sweepSkipMalformed malformed (total $total) =====');
		Sys.println(deltaStr);
		try {
			// `fixtures` array carries the per-fixture status map that
			// `apq recon --regression-probe` reads to diff status FLIPS
			// between sweeps. Backwards-compatible — older sweep readers
			// (the in-process Δ-printer above) ignore the field.
			final json:String = haxe.Json.stringify({
				pass: sweepPass,
				fail: sweepFail,
				skipParse: sweepSkipParse,
				skipWrite: sweepSkipWrite,
				skipConfig: sweepSkipConfig,
				skipMalformed: sweepSkipMalformed,
				fixtures: sweepFixtures,
			});
			sys.io.File.saveContent(SWEEP_JSON_PATH, json);
		} catch (_:Exception) {}
		#end
	}

	private static inline function signed(n:Int):String return n > 0 ? '+$n' : '$n';

	/**
	 * Classifies a parse failure into a stable category key suitable
	 * for aggregation. The raw message alone is too generic (the top-
	 * level Pratt fan always reports `expected HxDecl`), so we pair it
	 * with a short snippet of the input at the failure offset. Cases
	 * that choke on the same feature cluster under the same key.
	 */
	private static function classifyParseFailure(exception:Exception, input:String):String {
		final message:String = truncate(exception.message);
		if (!(exception is ParseError)) return message;
		final parseErr:ParseError = cast exception;
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
		#if (sys || nodejs)
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
