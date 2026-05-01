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
 * ω-functionBody-policy — `opt.functionBody:BodyPolicy` driving the
 * separator between the `()` of a function declaration's parameter
 * list and its body when the body is a single expression
 * (`function foo() expr;`).
 *
 * The knob lives on `HxFnBody.ExprBody` via ctor-level
 * `@:fmt(bodyPolicy('functionBody'))`; the parent `HxFnDecl.body`
 * Case 5 (Ref + `@:fmt(leftCurly)`) suppresses its fixed `_dt(' ')`
 * separator for ctors carrying ctor-level `@:fmt(bodyPolicy(...))` so
 * the wrap inside the sub-rule writer fully owns the kw-to-body
 * separator. `BlockBody` (`function f() { … }`) is unaffected — its
 * layout is owned by `leftCurly`. `NoBody` (`function f();`) is
 * unaffected — `;`-led siblings keep `_de()` (no inserted space).
 *
 * Default `Next` matches upstream haxe-formatter's
 * `sameLine.functionBody: @:default(Next)` — the body is pushed onto
 * a fresh line at one indent level deeper. Opt into the inline form
 * via `"sameLine": { "functionBody": "same" }`.
 */
@:nullSafety(Strict)
class HxFunctionBodyPolicySliceTest extends Test {

	public function new():Void {
		super();
	}

	public function testDefaultIsNext():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(BodyPolicy.Next, defaults.functionBody);
	}

	public function testSameKeepsBodyFlat():Void {
		final out:String = writeWith('class M { function f() trace("hi"); }', BodyPolicy.Same);
		Assert.isTrue(out.indexOf('f() trace("hi");') != -1, 'expected `f() trace("hi");` flat in: <$out>');
	}

	public function testNextBreaksBody():Void {
		final out:String = writeWith('class M { function f() trace("hi"); }', BodyPolicy.Next);
		Assert.isTrue(out.indexOf('f() trace') == -1, 'did not expect inline `f() trace` in: <$out>');
		Assert.isTrue(out.indexOf('f()\n') != -1, 'expected hardline after `f()` in: <$out>');
	}

	public function testBlockBodyUnaffectedBySame():Void {
		final out:String = writeWith('class M { function f() { trace("hi"); } }', BodyPolicy.Same);
		Assert.isTrue(out.indexOf('f() {') != -1, 'block body must stay `f() { … }` in: <$out>');
	}

	public function testBlockBodyUnaffectedByNext():Void {
		final out:String = writeWith('class M { function f() { trace("hi"); } }', BodyPolicy.Next);
		Assert.isTrue(out.indexOf('f() {') != -1, 'block body must stay `f() { … }` regardless of functionBody in: <$out>');
		Assert.isTrue(out.indexOf('f()\n{') == -1, 'block body must not be pushed to next line by functionBody in: <$out>');
	}

	public function testNoBodyUnaffected():Void {
		final out:String = writeWith('interface I { function f():Void; }', BodyPolicy.Next);
		Assert.isTrue(out.indexOf('function f():Void;') != -1, 'NoBody `function f():Void;` must stay flat regardless of policy in: <$out>');
	}

	public function testConfigLoaderMapsFunctionBodySame():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"sameLine": {"functionBody": "same"}}'
		);
		Assert.equals(BodyPolicy.Same, opts.functionBody);
	}

	public function testConfigLoaderMapsFunctionBodyNext():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"sameLine": {"functionBody": "next"}}'
		);
		Assert.equals(BodyPolicy.Next, opts.functionBody);
	}

	public function testConfigLoaderMissingKeyKeepsDefault():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(BodyPolicy.Next, opts.functionBody);
	}

	private inline function writeWith(src:String, policy:BodyPolicy):String {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.functionBody = policy;
		return HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
	}
}
