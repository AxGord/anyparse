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
 * ω-untyped-body-policy — `opt.untypedBody:BodyPolicy` driving the
 * separator between a function-decl header and the `untyped` keyword
 * of an `untyped { … }` body modifier (`function f():T untyped { … }`).
 *
 * Consumed via branch-level `@:fmt(bodyPolicy('untypedBody'))` on
 * `HxFnBody.UntypedBlockBody`. The parent `HxFnDecl.body` Ref-field's
 * leftCurly Case 5 routes the ctor through `spacePrefixCtors` +
 * `ctorHasBodyPolicy` so the parent emits `_de()` and the wrap is
 * the sole source of the kw-leading transition. Default `Same` matches
 * haxe-formatter's `sameLine.untypedBody: @:default(Same)`.
 *
 * ω-untyped-body-stmt-override — stmt-level form
 * `HxStatement.UntypedBlockStmt` is reached as the body of `try`
 * (`HxTryCatchStmt.body`) via the parent-side
 * `@:fmt(bodyPolicyOverride('UntypedBlockStmt', 'untypedBody'))`
 * companion meta. The wrap reads `opt.untypedBody` instead of
 * `opt.tryBody` at runtime when the body's runtime ctor matches —
 * the inner-shape knob wins over the parent-shape knob. Block-stmt
 * Star context (`{ untyped { … } }`) has no override and keeps the
 * Star's `\n<indent>` separator, so `untypedBody` stays inert there
 * — matching haxe-formatter's BrOpen-parent exception.
 */
@:nullSafety(Strict)
class HxUntypedBodyPolicySliceTest extends Test {

	public function new():Void {
		super();
	}

	public function testDefaultIsSame():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.equals(BodyPolicy.Same, defaults.untypedBody);
	}

	public function testSameKeepsUntypedInline():Void {
		final out:String = writeWith(
			'class M { function f():Int untyped { return 1; } }',
			BodyPolicy.Same
		);
		Assert.isTrue(out.indexOf(':Int untyped {') != -1, 'expected `:Int untyped {` cuddled in: <$out>');
	}

	public function testNextPushesUntypedToOwnLine():Void {
		final out:String = writeWith(
			'class M { function f():Int untyped { return 1; } }',
			BodyPolicy.Next
		);
		Assert.isTrue(out.indexOf(':Int untyped') == -1, 'did not expect inline `:Int untyped` in: <$out>');
		Assert.isTrue(out.indexOf(':Int\n') != -1, 'expected hardline after `:Int` in: <$out>');
		Assert.isTrue(out.indexOf('untyped {') != -1, 'expected `untyped {` after the break in: <$out>');
	}

	public function testTryBodyDefaultSameKeepsUntypedInline():Void {
		// `try untyped { … }` with default `untypedBody=Same` cuddles
		// the kw to `try` (`try untyped {…}`). The override fires
		// (body is `UntypedBlockStmt`) but the chosen knob's `Same`
		// layout still emits the inline space.
		final out:String = writeWith(
			'class M { function f():Void { try untyped { foo(); } catch (e:Dynamic) {} } }',
			BodyPolicy.Same
		);
		Assert.isTrue(out.indexOf('try untyped {') != -1, 'expected `try untyped {` inline with default Same in: <$out>');
	}

	public function testTryBodyNextPushesUntypedToOwnLine():Void {
		// `try untyped { … }` with `untypedBody=Next` overrides the
		// parent's `tryBody` knob (default Same) and pushes `untyped`
		// onto its own line at one indent step deeper.
		final out:String = writeWith(
			'class M { function f():Void { try untyped { foo(); } catch (e:Dynamic) {} } }',
			BodyPolicy.Next
		);
		Assert.isTrue(out.indexOf('try untyped') == -1, 'did not expect inline `try untyped` in: <$out>');
		Assert.isTrue(out.indexOf('try\n') != -1, 'expected hardline after `try` in: <$out>');
		Assert.isTrue(out.indexOf('untyped {') != -1, 'expected `untyped {` after the break in: <$out>');
	}

	public function testBlockStmtContextUnaffectedByUntypedBodyKnob():Void {
		// `{ untyped { … } }` (UntypedBlockStmt under BlockStmt's Star)
		// has no parent-side override — the Star's `\n<indent>`
		// separator drives layout regardless of `untypedBody`. Both
		// Same and Next produce the same output (cuddled to its own
		// indented line).
		final src:String = 'class M { function f():Void { untyped { foo(); } } }';
		final outSame:String = writeWith(src, BodyPolicy.Same);
		final outNext:String = writeWith(src, BodyPolicy.Next);
		Assert.equals(outSame, outNext);
		Assert.isTrue(outSame.indexOf('\n\t\tuntyped {') != -1, 'expected block-stmt `untyped {` at +2 indent in: <$outSame>');
	}

	public function testConfigLoaderMapsUntypedBodySame():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"sameLine": {"untypedBody": "same"}}'
		);
		Assert.equals(BodyPolicy.Same, opts.untypedBody);
	}

	public function testConfigLoaderMapsUntypedBodyNext():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"sameLine": {"untypedBody": "next"}}'
		);
		Assert.equals(BodyPolicy.Next, opts.untypedBody);
	}

	public function testConfigLoaderMissingKeyKeepsDefault():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.equals(BodyPolicy.Same, opts.untypedBody);
	}

	private inline function writeWith(src:String, policy:BodyPolicy):String {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.untypedBody = policy;
		return HxModuleWriter.write(HaxeModuleParser.parse(src), opts);
	}
}
