package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.BodyPolicy;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-return-body — `opt.returnBody:BodyPolicy` driving the separator
 * between `return` and its value expression at `HxStatement.ReturnStmt`.
 * Mirrors `ifBody` / `forBody` / `whileBody` / `doBody` shape: same
 * `bodyPolicyWrap` macro path, same 4-value `BodyPolicy` enum
 * (`Same` / `Next` / `FitLine` / `Keep`).
 *
 * Default is `FitLine` — the only `*Body` knob that does NOT default
 * to `Next`, because haxe-formatter's effective `sameLine.returnBody:
 * @:default(Same)` semantics wrap long values via a separate
 * `wrapping.maxLineLength` pass. Strict `Same` (no wrap) requires an
 * explicit `hxformat.json` override.
 *
 * The sibling JSON knob `sameLine.returnBodySingleLine` (ω-return-body-
 * single-line) refines the policy for returns whose value renders as a
 * single line — literals, idents, ternaries, array / object /
 * comprehension literals, calls. Control-flow / block values
 * (`if` / `switch` / `for` / `while` / `try` / `{ … }`) keep using
 * `returnBody`. The runtime split lives in `bodyPolicyWrap` via the
 * `bodyPolicySingleLine('returnBodySingleLine', '<ctor>'...)` knob on
 * `HxStatement.ReturnStmt`, mirroring the fork's `shouldReturnBeSameLine`
 * AST classification. Default `FitLine` keeps single-line behaviour
 * byte-identical to pre-slice (single-line values went through the
 * `FitLine` `returnBody`; they now go through the `FitLine`
 * `returnBodySingleLine`).
 */
@:nullSafety(Strict)
class HxReturnBodySliceTest extends Test {

	public function new():Void {
		super();
	}

	public function testDefaultIsFitLine():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(BodyPolicy.FitLine, defaults.returnBody);
	}

	public function testSameKeepsValueFlat():Void {
		final out:String = writeWith('class M { function f():Int { return 1; } }', BodyPolicy.Same);
		Assert.isTrue(out.indexOf('return 1;') != -1, 'expected `return 1;` flat in: <$out>');
	}

	public function testNextBreaksShortValue():Void {
		final out:String = writeWith('class M { function f():Int { return 1; } }', BodyPolicy.Next);
		Assert.isTrue(out.indexOf('return\n') != -1, 'expected hardline after `return` in: <$out>');
		Assert.isTrue(out.indexOf('return 1;') == -1, 'did not expect `return 1;` flat in: <$out>');
	}

	public function testFitLineFitsShortValueFlat():Void {
		final out:String = writeWith('class M { function f():Int { return 1; } }', BodyPolicy.FitLine);
		Assert.isTrue(out.indexOf('return 1;') != -1, 'expected `return 1;` flat (fits lineWidth) in: <$out>');
	}

	public function testFitLineBreaksLongValue():Void {
		final buf:StringBuf = new StringBuf();
		for (i in 0...200) buf.add('-');
		final longLit:String = '"' + buf.toString() + '"';
		final src:String = 'class M { function f():String { return $longLit; } }';
		final out:String = writeWith(src, BodyPolicy.FitLine);
		Assert.isTrue(out.indexOf('return\n') != -1, 'expected break before long value (>lineWidth) in: <$out>');
	}

	public function testKeepDoesNotForceLayout():Void {
		final out:String = writeWith('class M { function f():Int { return 1; } }', BodyPolicy.Keep);
		Assert.isTrue(out.indexOf('return') != -1, 'sanity: `return` present in: <$out>');
	}

	public function testVoidReturnUnaffected():Void {
		final out:String = writeWith('class M { function f():Void { return; } }', BodyPolicy.Next);
		Assert.isTrue(out.indexOf('return;') != -1, 'void `return;` must stay flat regardless of policy in: <$out>');
		Assert.isTrue(out.indexOf('return\n') == -1, 'void `return;` must not break in: <$out>');
	}

	/**
	 * F. Single-expr body anti-wrap — when `returnBody = FitLine` (default)
	 * and the value expression has its own internal hardlines (e.g. a call
	 * with a function-block argument), `return` must stay inline-with-space
	 * before the value's first line. The width-driven break exists only to
	 * handle long FLAT values; multiline values already render across lines
	 * and adding a kw-side break+nest just over-indents the body.
	 *
	 * Real-world fixture: `issue_546_wrapping_and_arrow_function.hxtest`.
	 */
	public function testFitLineMultilineValueStaysInline():Void {
		final src:String = 'class M { static function f():Int { return foo(function() { var x = 1; return x; }); } }';
		final out:String = writeWith(src, BodyPolicy.FitLine);
		Assert.isTrue(out.indexOf('return foo(') != -1, 'expected `return foo(` inline (multiline body) in: <$out>');
		Assert.isTrue(out.indexOf('return\n') == -1, 'multiline value must NOT trigger kw-side break in: <$out>');
	}

	public function testConfigLoaderMapsReturnBodySame():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"sameLine": {"returnBody": "same"}}'
		);
		Assert.equals(BodyPolicy.Same, opts.returnBody);
	}

	public function testConfigLoaderMapsReturnBodyNext():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"sameLine": {"returnBody": "next"}}'
		);
		Assert.equals(BodyPolicy.Next, opts.returnBody);
	}

	public function testConfigLoaderMapsReturnBodyKeep():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"sameLine": {"returnBody": "keep"}}'
		);
		Assert.equals(BodyPolicy.Keep, opts.returnBody);
	}

	public function testConfigLoaderMapsReturnBodyFitLine():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"sameLine": {"returnBody": "fitLine"}}'
		);
		Assert.equals(BodyPolicy.FitLine, opts.returnBody);
	}

	public function testConfigLoaderMissingKeyKeepsDefault():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(BodyPolicy.FitLine, opts.returnBody);
	}

	public function testConfigLoaderMapsReturnBodySingleLine():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"sameLine": {"returnBody": "next", "returnBodySingleLine": "same"}}'
		);
		Assert.equals(BodyPolicy.Next, opts.returnBody);
		Assert.equals(BodyPolicy.Same, opts.returnBodySingleLine);
	}

	public function testConfigLoaderReturnBodySingleLineDefault():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(BodyPolicy.FitLine, opts.returnBodySingleLine);
	}

	private inline function writeWith(src:String, policy:BodyPolicy):String {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		// ω-return-body-single-line: set both axes so these mechanism tests
		// observe `policy` regardless of whether the return value renders as a
		// single line (driven by `returnBodySingleLine`) or multi-line / control-
		// flow (driven by `returnBody`). The single-value fixtures here are
		// single-line, so without the single-line field they'd silently fall to
		// its default and ignore `policy`.
		opts.returnBody = policy;
		opts.returnBodySingleLine = policy;
		return HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
	}
}
