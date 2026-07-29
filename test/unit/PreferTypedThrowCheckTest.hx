package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.PreferTypedThrow;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CachingGrammarPlugin.LibrarySources;
import anyparse.query.StdResolver;
import anyparse.runtime.Span;

/**
 * The `prefer-typed-throw` check: `throw '<string>'` is flagged `Info` and — when the
 * catch-clause gate passes — boxed into `throw new Exception('<string>')` with the exception
 * reference spelled by `TypeRefPrinter`. Covers fix mode, the degraded report-only mode a
 * `String` / `Dynamic` / `Any` catch anywhere in scope forces, the short-name collision
 * fallback to the qualified path, the import insertion position, and the std-exclusion of
 * the catch-clause gate (a std-only catch does not degrade, a project one still does).
 */
class PreferTypedThrowCheckTest extends Test {

	// --- what is flagged ---

	public function testStringThrowFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\n\tpublic function f():Void {\n\t\tthrow \'boom\';\n\t}\n\n}\n');
		Assert.equals(1, vs.length);
		Assert.equals('prefer-typed-throw', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testSpanIsTheLiteral(): Void {
		final src: String = 'class C {\n\n\tpublic function f():Void {\n\t\tthrow \'boom\';\n\t}\n\n}\n';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.equals('\'boom\'', src.substring(vs[0].span.from, vs[0].span.to));
	}

	public function testInterpolatedStringThrowFlagged(): Void {
		// Double-quoted fixture source: the `$id` inside it is fixture text, not interpolation.
		Assert.equals(1, violations("class C {\n\n\tpublic function f():Void {\n\t\tthrow 'bad $id';\n\t}\n\n}\n").length);
	}

	public function testDoubleQuotedStringThrowFlagged(): Void {
		Assert.equals(1, violations('class C {\n\n\tpublic function f():Void {\n\t\tthrow "boom";\n\t}\n\n}\n').length);
	}

	public function testParenthesisedLiteralFlagged(): Void {
		Assert.equals(1, violations('class C {\n\n\tpublic function f():Void {\n\t\tthrow (\'boom\');\n\t}\n\n}\n').length);
	}

	public function testConstructedThrowNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\n\tpublic function f():Void {\n\t\tthrow new E(\'boom\');\n\t}\n\n}\n').length);
	}

	public function testExpressionThrowNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\n\tpublic function f():Void {\n\t\tthrow err;\n\t}\n\n}\n').length);
	}

	// --- fix mode ---

	public function testFixBoxesAndAddsImport(): Void {
		final out: String = applyFix('class C {\n\n\tpublic function f():Void {\n\t\tthrow \'boom\';\n\t}\n\n}\n');
		Assert.isTrue(out.indexOf('throw new Exception(\'boom\');') != -1, 'literal boxed, got: $out');
		Assert.isTrue(out.indexOf('import haxe.Exception;') != -1, 'import added, got: $out');
	}

	public function testFixKeepsInterpolatedLiteralVerbatim(): Void {
		final out: String = applyFix("class C {\n\n\tpublic function f():Void {\n\t\tthrow 'bad $id';\n\t}\n\n}\n");
		Assert.isTrue(out.indexOf("throw new Exception('bad $id');") != -1, 'interpolation carried through, got: $out');
	}

	public function testFixUsesExistingImportWithoutAddingASecond(): Void {
		final src: String = 'import haxe.Exception;\n\nclass C {\n\n\tpublic function f():Void {\n\t\tthrow \'boom\';\n\t}\n\n}\n';
		final out: String = applyFix(src);
		Assert.isTrue(out.indexOf('throw new Exception(\'boom\');') != -1, 'literal boxed, got: $out');
		Assert.equals(1, occurrences(out, 'import haxe.Exception;'));
	}

	// --- degraded report-only mode ---

	public function testStringCatchInScopeDegradesToReportOnly(): Void {
		final thrower: String = 'class C {\n\n\tpublic function f():Void {\n\t\tthrow \'boom\';\n\t}\n\n}\n';
		final handler: String = 'class D {\n\n\tpublic function g():Void {\n\t\ttry h() catch (e:String) {}\n\t}\n\n}\n';
		final check: PreferTypedThrow = new PreferTypedThrow();
		final vs: Array<Violation> = check.run(
			[{ file: 'C.hx', source: thrower }, { file: 'D.hx', source: handler }], new HaxeQueryPlugin()
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('report-only') != -1, 'degraded message, got: ${vs[0].message}');
		Assert.equals(0, check.fix(thrower, vs, new HaxeQueryPlugin()).length, 'a degraded finding yields no edit');
	}

	public function testDynamicCatchInScopeDegradesToReportOnly(): Void {
		final thrower: String = 'class C {\n\n\tpublic function f():Void {\n\t\tthrow \'boom\';\n\t}\n\n}\n';
		final handler: String = 'class D {\n\n\tpublic function g():Void {\n\t\ttry h() catch (e : Dynamic) {}\n\t}\n\n}\n';
		final check: PreferTypedThrow = new PreferTypedThrow();
		final vs: Array<Violation> = check.run(
			[{ file: 'C.hx', source: thrower }, { file: 'D.hx', source: handler }], new HaxeQueryPlugin()
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('report-only') != -1, 'degraded message, got: ${vs[0].message}');
	}

	public function testValueExceptionCatchInScopeDegradesToReportOnly(): Void {
		// `haxe.ValueException` is the wrapper the RUNTIME builds for a raw throw — it matches
		// `throw 'boom'` and does NOT match `throw new Exception('boom')`, exactly like a String
		// catch. Verified against the compiler before the name joined the gate.
		final thrower: String = 'class C {\n\n\tpublic function f():Void {\n\t\tthrow \'boom\';\n\t}\n\n}\n';
		final handler: String = 'class D {\n\n\tpublic function g():Void {\n\t\ttry h() catch (e:haxe.ValueException) {}\n\t}\n\n}\n';
		final check: PreferTypedThrow = new PreferTypedThrow();
		final vs: Array<Violation> = check.run(
			[{ file: 'C.hx', source: thrower }, { file: 'D.hx', source: handler }], new HaxeQueryPlugin()
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('report-only') != -1, 'degraded message, got: ${vs[0].message}');
		Assert.equals(0, check.fix(thrower, vs, new HaxeQueryPlugin()).length);
	}

	public function testLineBrokenCatchParameterDegrades(): Void {
		final thrower: String = 'class C {\n\n\tpublic function f():Void {\n\t\tthrow \'boom\';\n\t}\n\n}\n';
		final handler: String = 'class D {\n\n\tpublic function g():Void {\n\t\ttry h() catch (\n\t\t\te:String\n\t\t) {}\n\t}\n\n}\n';
		final check: PreferTypedThrow = new PreferTypedThrow();
		final vs: Array<Violation> = check.run(
			[{ file: 'C.hx', source: thrower }, { file: 'D.hx', source: handler }], new HaxeQueryPlugin()
		);
		Assert.isTrue(vs[0].message.indexOf('report-only') != -1, 'degraded message, got: ${vs[0].message}');
	}

	public function testThrowInExpressionPositionFlaggedAndFixed(): Void {
		// `ThrowExpr` is a distinct grammar kind from `ThrowStmt` — both must be reached.
		final src: String = 'class C {\n\n\tpublic function f(c:Bool):Int {\n\t\treturn c ? 1 : throw \'nope\';\n\t}\n\n}\n';
		Assert.equals(1, violations(src).length);
		Assert.isTrue(applyFix(src).indexOf('throw new Exception(\'nope\')') != -1);
	}

	public function testTwoThrowsShareOneImport(): Void {
		final src: String =
			'class C {\n\n\tpublic function f():Void {\n\t\tthrow \'a\';\n\t}\n\n\tpublic function g():Void {\n\t\tthrow \'b\';\n\t}\n\n}\n';
		final out: String = applyFix(src);
		Assert.isTrue(out.indexOf('throw new Exception(\'a\');') != -1, 'first boxed, got: $out');
		Assert.isTrue(out.indexOf('throw new Exception(\'b\');') != -1, 'second boxed, got: $out');
		Assert.equals(1, occurrences(out, 'import haxe.Exception;'));
	}

	public function testSameFileCatchAllDegrades(): Void {
		final src: String = 'class C {\n\n\tpublic function f():Void {\n\t\ttry g() catch (e:Any) {}\n\t\tthrow \'boom\';\n\t}\n\n}\n';
		final check: PreferTypedThrow = new PreferTypedThrow();
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals(0, check.fix(src, vs, new HaxeQueryPlugin()).length);
	}

	public function testTypedCatchDoesNotDegrade(): Void {
		final thrower: String = 'class C {\n\n\tpublic function f():Void {\n\t\tthrow \'boom\';\n\t}\n\n}\n';
		final handler: String = 'class D {\n\n\tpublic function g():Void {\n\t\ttry h() catch (e:Exception) {}\n\t}\n\n}\n';
		final check: PreferTypedThrow = new PreferTypedThrow();
		final vs: Array<Violation> = check.run(
			[{ file: 'C.hx', source: thrower }, { file: 'D.hx', source: handler }], new HaxeQueryPlugin()
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('report-only') == -1, 'not degraded, got: ${vs[0].message}');
		Assert.isTrue(check.fix(thrower, vs, new HaxeQueryPlugin()).length > 0, 'a non-degraded finding yields edits');
	}

	public function testUntypedCatchDoesNotDegrade(): Void {
		final thrower: String = 'class C {\n\n\tpublic function f():Void {\n\t\tthrow \'boom\';\n\t}\n\n}\n';
		final handler: String = 'class D {\n\n\tpublic function g():Void {\n\t\ttry h() catch (e) {}\n\t}\n\n}\n';
		final check: PreferTypedThrow = new PreferTypedThrow();
		final vs: Array<Violation> = check.run(
			[{ file: 'C.hx', source: thrower }, { file: 'D.hx', source: handler }], new HaxeQueryPlugin()
		);
		Assert.isTrue(vs[0].message.indexOf('report-only') == -1, 'not degraded, got: ${vs[0].message}');
	}

	// --- std exclusion ---

	/**
	 * A `String` catch that lives ONLY in the auto-discovered std does NOT degrade the rule.
	 * The clause guards std-internal throws, which boxing a project throw cannot reach — and
	 * before the exclusion the std's own ~31 such clauses made the fix arm unreachable on every
	 * Haxe-equipped machine.
	 */
	public function testStdOnlyCatchDoesNotDegrade(): Void {
		final std: Null<String> = StdResolver.stdDir();
		if (std == null) {
			Assert.pass('no installed Haxe std on this machine');
			return;
		}
		final report: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: THROWER }];
		final scoped: CachingGrammarPlugin = scopedPlugin(report, [
			{ file: haxe.io.Path.join([std, 'haxe', 'ds', 'BalancedTree.hx']), source: STRING_CATCH }
		]);
		final check: PreferTypedThrow = new PreferTypedThrow();
		final vs: Array<Violation> = check.run(report, scoped);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('report-only') == -1, 'a std-only catch does not degrade, got: ${vs[0].message}');
		Assert.isTrue(check.fix(THROWER, vs, scoped).length > 0, 'the fix arm is open');
	}

	/** A `String` catch in a PROJECT library root — not std — still degrades the whole rule. */
	public function testProjectLibraryCatchDegrades(): Void {
		final report: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: THROWER }];
		final scoped: CachingGrammarPlugin = scopedPlugin(report, [{ file: 'vendor/crashdumper/CrashDumper.hx', source: STRING_CATCH }]);
		final check: PreferTypedThrow = new PreferTypedThrow();
		final vs: Array<Violation> = check.run(report, scoped);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('report-only') != -1, 'a project catch degrades, got: ${vs[0].message}');
		Assert.equals(0, check.fix(THROWER, vs, scoped).length, 'a degraded finding yields no edit');
	}

	/** Excluding std must not MASK a project clause sitting in the same scope alongside it. */
	public function testStdExclusionDoesNotMaskAProjectCatch(): Void {
		final std: Null<String> = StdResolver.stdDir();
		if (std == null) {
			Assert.pass('no installed Haxe std on this machine');
			return;
		}
		final report: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: THROWER }];
		final scoped: CachingGrammarPlugin = scopedPlugin(report, [
			{ file: haxe.io.Path.join([std, 'haxe', 'ds', 'BalancedTree.hx']), source: STRING_CATCH },
			{ file: 'vendor/crashdumper/CrashDumper.hx', source: STRING_CATCH }
		]);
		final vs: Array<Violation> = new PreferTypedThrow().run(report, scoped);
		Assert.isTrue(vs[0].message.indexOf('report-only') != -1, 'the project clause still degrades, got: ${vs[0].message}');
	}

	/**
	 * With the std channel DECLINED (`APQ_NO_STD`) there is no root to attribute a file to, so
	 * the exclusion excludes NOTHING and a std-path source degrades exactly as any other would.
	 * Uses the `resetCache` seam on BOTH sides, since `stdDir` memoises per process.
	 */
	public function testDeclinedStdExcludesNothing(): Void {
		#if (sys || nodejs)
		final live: Null<String> = StdResolver.stdDir();
		if (live == null) {
			Assert.pass('no installed Haxe std on this machine');
			return;
		}
		final report: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: THROWER }];
		final scoped: CachingGrammarPlugin = scopedPlugin(report, [
			{ file: haxe.io.Path.join([live, 'haxe', 'ds', 'BalancedTree.hx']), source: STRING_CATCH }
		]);
		StdResolver.resetCache();
		Sys.putEnv('APQ_NO_STD', '1');
		final vs: Array<Violation> = new PreferTypedThrow().run(report, scoped);
		Sys.putEnv('APQ_NO_STD', '');
		StdResolver.resetCache();
		Assert.equals(live, StdResolver.stdDir(), 'the memo is re-primed for the rest of the suite');
		Assert.isTrue(vs[0].message.indexOf('report-only') != -1, 'a declined std excludes nothing, got: ${vs[0].message}');
		#else
		Assert.pass('non-sys target');
		#end
	}

	// --- collision mode ---

	public function testCollidingExceptionNameUsesQualifiedPath(): Void {
		final src: String =
			'package pkg;\n\nimport pkg.err.Exception;\n\nclass C {\n\n\tpublic function f():Void {\n\t\tthrow \'boom\';\n\t}\n\n}\n';
		final out: String = applyFix(src);
		Assert.isTrue(out.indexOf('throw new haxe.Exception(\'boom\');') != -1, 'qualified on collision, got: $out');
		Assert.equals(0, occurrences(out, 'import haxe.Exception;'));
	}

	public function testLocalExceptionTypeUsesQualifiedPath(): Void {
		final src: String =
			'package pkg;\n\nclass Exception {}\n\nclass C {\n\n\tpublic function f():Void {\n\t\tthrow \'boom\';\n\t}\n\n}\n';
		final out: String = applyFix(src);
		Assert.isTrue(out.indexOf('throw new haxe.Exception(\'boom\');') != -1, 'qualified on a module-local type, got: $out');
	}

	public function testConditionalRegionQualifiedWithNoImport(): Void {
		final src: String = 'class C {\n\n\tpublic function f():Void {\n\t\t#if debug\n\t\tthrow \'boom\';\n\t\t#end\n\t}\n\n}\n';
		final out: String = applyFix(src);
		Assert.isTrue(out.indexOf('throw new haxe.Exception(\'boom\');') != -1, 'qualified inside #if, got: $out');
		Assert.equals(0, occurrences(out, 'import haxe.Exception;'));
	}

	// --- import insertion position ---

	public function testImportKeepsASortedImportBlockSorted(): Void {
		final src: String =
			'package pkg;\n\nimport a.Alpha;\nimport z.Zeta;\n\nclass C {\n\n\tpublic function f():Void {\n\t\tthrow \'boom\';\n\t}\n\n}\n';
		final out: String = applyFix(src);
		Assert.isTrue(
			out.indexOf('import a.Alpha;\nimport haxe.Exception;\nimport z.Zeta;') != -1, 'import lands in sorted position, got: $out'
		);
	}

	public function testImportAppendsAfterAnUnsortedBlock(): Void {
		final src: String =
			'package pkg;\n\nimport z.Zeta;\nimport a.Alpha;\n\nclass C {\n\n\tpublic function f():Void {\n\t\tthrow \'boom\';\n\t}\n\n}\n';
		final out: String = applyFix(src);
		Assert.isTrue(out.indexOf('import a.Alpha;\nimport haxe.Exception;') != -1, 'import appended after the block, got: $out');
	}

	// --- registration ---

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-typed-throw'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-typed-throw'));
	}

	public function testIsDefaultOff(): Void {
		Assert.isTrue(new PreferTypedThrow() is DefaultOff);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { throw').length);
	}

	// --- helpers -------------------------------------------------------------------

	/** The thrower every scoped test reports on. */
	private static inline final THROWER: String = 'class C {\n\n\tpublic function f():Void {\n\t\tthrow \'boom\';\n\t}\n\n}\n';

	/** A source carrying one blocking `catch (e:String)` clause — the gate's trigger shape. */
	private static inline final STRING_CATCH: String =
		'class H {\n\n\tpublic function g():Void {\n\t\ttry h() catch (e:String) {}\n\t}\n\n}\n';

	private function scopedPlugin(
		report: Array<{ file: String, source: String }>, library: Array<{ file: String, source: String }>
	): CachingGrammarPlugin {
		final scoped: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		scoped.setResolutionScope({ declared: true, sources: () -> {report: report, library: new LibrarySources(library) } });
		return scoped;
	}

	private function violations(src: String): Array<Violation> {
		return new PreferTypedThrow().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function applyFix(src: String): String {
		final check: PreferTypedThrow = new PreferTypedThrow();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

	private function occurrences(haystack: String, needle: String): Int {
		var count: Int = 0;
		var i: Int = haystack.indexOf(needle);
		while (i >= 0) {
			count++;
			i = haystack.indexOf(needle, i + needle.length);
		}
		return count;
	}

}
