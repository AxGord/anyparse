package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-objectlit-source-trail-comma — when a `@:trivia` sep-Star with a
 * close literal is parsed in trivia mode, the parser captures whether
 * the source had a trailing separator after the last element into a
 * synth `<field>TrailPresent:Bool` slot. The writer's no-trivia branch
 * forwards that flag to `WrapList.emit` as `forceExceeds` when the
 * Star also carries `@:fmt(trailingComma('<knob>'))` AND the named
 * runtime knob is `true`. Effect: short, no-comment object literals
 * whose source committed to a trailing comma round-trip as multi-line
 * (`OnePerLine`) instead of being collapsed flat by the cascade's
 * `count <= 3` rule.
 *
 * Capability foundation for issue_607 (`@patch { status: InProgress(v), }`)
 * — surrounding-context `MetaExpr` Allman placement plus indent +1 are
 * separate sub-slices. Default `trailingCommaObjectLits = false`
 * preserves byte-identical layout for every fork fixture; only opt-in
 * configs see the new behaviour.
 *
 * Plain mode (`HaxeModuleParser` / `HxModuleWriter`) is unaffected — the
 * synth slot exists only on the trivia pair, and the plain writer's
 * sep-Star path doesn't route through `triviaSepStarExpr`.
 */
@:nullSafety(Strict)
final class HxObjectLitSourceTrailCommaSliceTest extends Test {

	public function new():Void {
		super();
	}

	public function testSourceTrailingCommaForcesBreakWhenKnobOn():Void {
		// `{i: 0,}` — single-field object literal whose source has a
		// trailing `,`. With `trailingCommaObjectLits = true`, the wrap
		// engine's `forceExceeds` flag fires and the cascade's
		// `count <= 3` NoWrap rule is bypassed → OnePerLine layout.
		final src:String = 'class M {\n\tfunction f():Void {\n\t\tvar x:Dynamic = {i: 0,}\n\t}\n}';
		final out:String = formatWithKnob(src, true);
		// OnePerLine for `{i: 0,}` produces `{\n\t\t\ti: 0,\n\t\t}` —
		// at minimum verify the close brace lands on its own line.
		Assert.isTrue(out.indexOf('0,\n') != -1,
			'expected source `,` retained in OnePerLine layout, got: <$out>');
		Assert.isTrue(out.indexOf('{i: 0') == -1,
			'expected break-mode layout (no flat `{i: 0`), got: <$out>');
	}

	public function testSourceNoTrailingCommaStaysFlatWhenKnobOn():Void {
		// `{i: 0}` — same shape but no source trailing `,`. The cascade
		// stays in `NoWrap` mode regardless of the knob — `forceExceeds`
		// is gated on source presence, not the knob alone.
		final src:String = 'class M {\n\tfunction f():Void {\n\t\tvar x:Dynamic = {i: 0}\n\t}\n}';
		final out:String = formatWithKnob(src, true);
		Assert.isTrue(out.indexOf('{i: 0}') != -1,
			'expected flat `{i: 0}` when source had no trailing `,`, got: <$out>');
	}

	public function testSourceTrailingCommaIgnoredWhenKnobOff():Void {
		// Default knob (`false`) — `forceExceeds` conjunction stays
		// false even with source trailing `,`. Cascade picks NoWrap and
		// the trailing `,` is dropped (writer doesn't append in flat
		// mode regardless of the knob).
		final src:String = 'class M {\n\tfunction f():Void {\n\t\tvar x:Dynamic = {i: 0,}\n\t}\n}';
		final out:String = formatWithKnob(src, false);
		Assert.isTrue(out.indexOf('{i: 0}') != -1,
			'expected flat `{i: 0}` when knob is off, got: <$out>');
	}

	public function testSourceTrailingCommaMultiFieldKnobOn():Void {
		// Three-field literal — short enough to flatten by default
		// (count <= 3, total < 60, no item >= 30). Source trailing `,`
		// + knob on → forceExceeds → OnePerLine, with appendTrailingComma
		// emitting the closing `,` after the last field.
		final src:String = 'class M {\n\tfunction f():Void {\n\t\tvar x:Dynamic = {a: 1, b: 2, c: 3,}\n\t}\n}';
		final out:String = formatWithKnob(src, true);
		// `,\n` (sep + hardline) anchors on break-mode layout — flat
		// output emits `, ` (sep + space) between siblings, never `,\n`,
		// so the assertion catches a cascade-collapse regression that
		// looser per-field substring matches would miss.
		Assert.isTrue(out.indexOf('a: 1,\n') != -1 && out.indexOf('b: 2,\n') != -1 && out.indexOf('c: 3,\n') != -1,
			'expected each field followed by `,\\n` in OnePerLine layout, got: <$out>');
	}

	public function testEmptyObjectLitSafeWhenKnobOn():Void {
		// Empty `{}` — no elements, no source `,`. Engine returns the
		// keepInnerWhenEmpty short-circuit; forceExceeds is not consulted.
		final src:String = 'class M {\n\tfunction f():Void {\n\t\tvar x:Dynamic = {}\n\t}\n}';
		final out:String = formatWithKnob(src, true);
		Assert.isTrue(out.indexOf('{}') != -1,
			'expected empty `{}` to round-trip, got: <$out>');
	}

	private inline function formatWithKnob(src:String, trailingCommaObjectLits:Bool):String {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.finalNewline = false;
		opts.trailingCommaObjectLits = trailingCommaObjectLits;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}
}
