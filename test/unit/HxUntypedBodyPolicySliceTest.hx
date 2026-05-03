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
 * Stmt-level form `HxStatement.UntypedBlockStmt` (incl. `try untyped
 * { … }` and block-stmt `{ untyped { … } }`) does NOT consume this
 * knob in this slice — duplicating the wrap would stack with parent
 * separators producing double spaces / spurious blank lines. Stmt-
 * context handling is a follow-up slice.
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

	public function testStmtFormUnaffectedByUntypedBodyKnob():Void {
		// Slice scope: stmt-context untypedBody handling is deferred.
		// `try untyped { … }` and `{ untyped { … } }` keep their default
		// inline layout regardless of the knob, so the wrap doesn't stack
		// with parent separators.
		final outNext:String = writeWith(
			'class M { function f():Void { try untyped { foo(); } catch (e:Dynamic) {} } }',
			BodyPolicy.Next
		);
		Assert.isTrue(outNext.indexOf('try untyped {') != -1, 'expected `try untyped {` inline regardless of knob in: <$outNext>');
		Assert.isTrue(outNext.indexOf('try\n') == -1, 'try-context untypedBody must not push `untyped` to next line in: <$outNext>');
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
