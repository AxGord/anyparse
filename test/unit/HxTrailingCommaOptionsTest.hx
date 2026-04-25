package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.grammar.haxe.HxModuleWriter;

/**
 * τ₂ — runtime-switchable trailing-comma policies for array literals,
 * call argument lists, and parameter lists.
 *
 * Three independent `Bool` knobs on `HxModuleWriteOptions` — all
 * defaulting to `false` on `HaxeFormat.defaultWriteOptions`. Each knob
 * is wired through the declarative `@:fmt(trailingComma("flagName"))` knob
 * on the relevant grammar field / enum branch and plumbed to the new
 * `trailingComma:Bool` argument of the generated `sepList` helper.
 *
 * A trailing `,` appears only when the enclosing `sepList` lays out in
 * break mode (via the new `IfBreak` Doc primitive). Tests force break
 * with a narrow `lineWidth` so the trailing-comma branch fires on
 * intentionally short sources, independent of content length.
 *
 * Each test exercises one sepList consumer (array literal, call, func
 * params) and verifies both the positive (flag `true` → trailing `,`)
 * and negative (flag `false` → no trailing `,`) runtime outcomes.
 */
@:nullSafety(Strict)
class HxTrailingCommaOptionsTest extends Test {

	public function new():Void {
		super();
	}

	public function testDefaultsAreAllFalse():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.isFalse(defaults.trailingCommaArrays);
		Assert.isFalse(defaults.trailingCommaArgs);
		Assert.isFalse(defaults.trailingCommaParams);
	}

	public function testArrayTrailingCommaOnBreak():Void {
		final src:String = 'class F { function f():Void { var xs:Dynamic = [1, 2, 3]; } }';
		final out:String = writeWithBreak(src, true, false, false);
		assertTrailingComma(out, '3', ']');
	}

	public function testArrayNoTrailingCommaWhenFlagOff():Void {
		final src:String = 'class F { function f():Void { var xs:Dynamic = [1, 2, 3]; } }';
		final out:String = writeWithBreak(src, false, false, false);
		assertNoTrailingComma(out, '3', ']');
	}

	public function testArrayFlatNeverHasTrailingComma():Void {
		// Default lineWidth=120 — short array stays flat, so the IfBreak
		// trailer collapses to Empty even with the flag set.
		final src:String = 'class F { function f():Void { var xs:Dynamic = [1, 2, 3]; } }';
		final out:String = writeWith(src, 120, true, false, false);
		Assert.isTrue(out.indexOf('[1, 2, 3]') != -1, 'expected flat `[1, 2, 3]` in: <$out>');
		assertNoTrailingComma(out, '3', ']');
	}

	public function testCallArgsTrailingCommaOnBreak():Void {
		final src:String = 'class F { function f():Void { foo(a, b, c); } }';
		final out:String = writeWithBreak(src, false, true, false);
		assertTrailingComma(out, 'c', ')');
	}

	public function testCallArgsNoTrailingCommaWhenFlagOff():Void {
		final src:String = 'class F { function f():Void { foo(a, b, c); } }';
		final out:String = writeWithBreak(src, false, false, false);
		assertNoTrailingComma(out, 'c', ')');
	}

	public function testNewArgsShareCallArgsFlag():Void {
		// `new T(args)` uses the same trailingCommaArgs knob via HxNewExpr.
		final src:String = 'class F { function f():Void { var x:Dynamic = new Foo(a, b, c); } }';
		final out:String = writeWithBreak(src, false, true, false);
		assertTrailingComma(out, 'c', ')');
	}

	public function testFnParamsTrailingCommaOnBreak():Void {
		final src:String = 'class F { function f(a:Int, b:Int, c:Int):Void {} }';
		final out:String = writeWithBreak(src, false, false, true);
		assertTrailingComma(out, 'c:Int', ')');
	}

	public function testFnParamsNoTrailingCommaWhenFlagOff():Void {
		final src:String = 'class F { function f(a:Int, b:Int, c:Int):Void {} }';
		final out:String = writeWithBreak(src, false, false, false);
		assertNoTrailingComma(out, 'c:Int', ')');
	}

	public function testFlagsAreIndependent():Void {
		// Flip only trailingCommaArgs → arrays and params must not emit `,`.
		final src:String = 'class F { function f(a:Int, b:Int):Void { var xs:Dynamic = [1, 2]; foo(x, y); } }';
		final out:String = writeWithBreak(src, false, true, false);
		assertTrailingComma(out, 'y', ')');
		assertNoTrailingComma(out, '2', ']');
		assertNoTrailingComma(out, 'b:Int', ')');
	}

	private function assertTrailingComma(out:String, lastItem:String, close:String):Void {
		Assert.equals(',', firstNonWsAfter(out, lastItem),
			'expected `$lastItem,` before `$close` (break mode + flag on) in: <$out>');
	}

	private function assertNoTrailingComma(out:String, lastItem:String, close:String):Void {
		Assert.equals(close, firstNonWsAfter(out, lastItem),
			'expected `$close` right after `$lastItem` (no trailing comma) in: <$out>');
	}

	/**
	 * First non-whitespace character following the *last* occurrence of
	 * `needle` in `s`. `lastIndexOf` anchors on the final instance so
	 * the probe targets the intended list element even when `needle`
	 * appears earlier in surrounding source (e.g. `c` inside `class`).
	 */
	private function firstNonWsAfter(s:String, needle:String):String {
		final at:Int = s.lastIndexOf(needle);
		if (at < 0) return '';
		var i:Int = at + needle.length;
		while (i < s.length) {
			final c:String = s.charAt(i);
			if (c != ' ' && c != '\t' && c != '\n' && c != '\r') return c;
			i++;
		}
		return '';
	}

	private function writeWithBreak(src:String, arrays:Bool, args:Bool, params:Bool):String {
		return writeWith(src, 10, arrays, args, params);
	}

	private function writeWith(src:String, lineWidth:Int, arrays:Bool, args:Bool, params:Bool):String {
		return HxModuleWriter.write(HaxeModuleParser.parse(src), makeOpts(lineWidth, arrays, args, params));
	}

	private function makeOpts(lineWidth:Int, arrays:Bool, args:Bool, params:Bool):HxModuleWriteOptions {
		final base:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		return {
			indentChar: base.indentChar,
			indentSize: base.indentSize,
			tabWidth: base.tabWidth,
			lineWidth: lineWidth,
			lineEnd: base.lineEnd,
			finalNewline: base.finalNewline,
			trailingWhitespace: base.trailingWhitespace,
			commentStyle: base.commentStyle,
			sameLineElse: base.sameLineElse,
			sameLineCatch: base.sameLineCatch,
			sameLineDoWhile: base.sameLineDoWhile,
			trailingCommaArrays: arrays,
			trailingCommaArgs: args,
			trailingCommaParams: params,
			ifBody: base.ifBody,
			elseBody: base.elseBody,
			forBody: base.forBody,
			whileBody: base.whileBody,
			doBody: base.doBody,
			leftCurly: base.leftCurly,
			objectFieldColon: base.objectFieldColon,
			typeHintColon: base.typeHintColon,
			funcParamParens: base.funcParamParens,
			callParens: base.callParens,
			elseIf: base.elseIf,
			fitLineIfWithElse: base.fitLineIfWithElse,
			afterFieldsWithDocComments: base.afterFieldsWithDocComments,
			existingBetweenFields: base.existingBetweenFields,
			beforeDocCommentEmptyLines: base.beforeDocCommentEmptyLines,
			betweenVars: base.betweenVars,
			betweenFunctions: base.betweenFunctions,
			afterVars: base.afterVars,
			interfaceBetweenVars: base.interfaceBetweenVars,
			interfaceBetweenFunctions: base.interfaceBetweenFunctions,
			interfaceAfterVars: base.interfaceAfterVars,
			typedefAssign: base.typedefAssign,
		};
	}
}
