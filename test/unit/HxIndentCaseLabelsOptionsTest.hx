package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-indent-case-labels — runtime-switchable `indentCaseLabels` Bool
 * gating whether `case` / `default` labels of a `switch` body sit one
 * indent level inside the surrounding `{ ... }` (`true`, default,
 * matching haxe-formatter's `indentation.indentCaseLabels:
 * @:default(true)`) or flush with the `switch` keyword (`false`,
 * exercised by `issue_478_indent_case` in the corpus).
 *
 * The knob is wired via `@:fmt(indentCaseLabels)` on the `cases` field
 * of `HxSwitchStmt` and `HxSwitchStmtBare`. Per-case body indentation
 * (`@:fmt(nestBody)` on `HxCaseBranch.body` / `HxDefaultBranch.stmts`)
 * stays in effect either way — the body is always one indent level
 * deeper than its label, regardless of the label's absolute position.
 *
 * Tests run through the trivia parser/writer pair so the Star-block
 * Doc shape with the new gate is exercised end-to-end (corpus tests
 * use the same path).
 */
@:nullSafety(Strict)
class HxIndentCaseLabelsOptionsTest extends Test {

	public function new():Void {
		super();
	}

	public function testIndentCaseLabelsDefaultIsTrue():Void {
		final defaults:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		Assert.isTrue(defaults.indentCaseLabels);
	}

	public function testIndentCaseLabelsTrueKeepsLabelsIndented():Void {
		final out:String = writeWith(
			'class M { static function f() { switch (e) { case A: 1; default: 2; } } }',
			true
		);
		// Inside `{ ... }` of switch, case label sits at 3 tabs (one inside
		// the switch's outer 2 tabs).
		Assert.isTrue(out.indexOf('\n\t\t\tcase A:') != -1,
			'expected `case A:` at 3-tab indent in: <$out>');
		Assert.isTrue(out.indexOf('\n\t\t\tdefault:') != -1,
			'expected `default:` at 3-tab indent in: <$out>');
	}

	public function testIndentCaseLabelsFalseFlushesLabelsWithSwitch():Void {
		final out:String = writeWith(
			'class M { static function f() { switch (e) { case A: 1; default: 2; } } }',
			false
		);
		// switch keyword sits at 2 tabs (inside class + function body); flushed
		// labels sit at the same 2-tab indent.
		Assert.isTrue(out.indexOf('\n\t\tcase A:') != -1,
			'expected `case A:` flushed at 2-tab indent in: <$out>');
		Assert.isTrue(out.indexOf('\n\t\tdefault:') != -1,
			'expected `default:` flushed at 2-tab indent in: <$out>');
		Assert.isTrue(out.indexOf('\n\t\t\tcase A:') == -1,
			'did not expect `case A:` at 3-tab indent in: <$out>');
	}

	public function testIndentCaseLabelsFalseKeepsBodyOneLevelDeeperThanLabel():Void {
		final out:String = writeWith(
			'class M { static function f() { switch (e) { case A: 1; default: 2; } } }',
			false
		);
		// Body still receives nestBody — one indent level relative to the
		// label, so `1;` sits at 3 tabs while the label is at 2.
		Assert.isTrue(out.indexOf('\n\t\t\t1;') != -1,
			'expected case body `1;` at 3-tab indent in: <$out>');
		Assert.isTrue(out.indexOf('\n\t\t\t2;') != -1,
			'expected default body `2;` at 3-tab indent in: <$out>');
	}

	public function testIndentCaseLabelsTrueKeepsBodyTwoLevelsDeeperThanSwitch():Void {
		final out:String = writeWith(
			'class M { static function f() { switch (e) { case A: 1; default: 2; } } }',
			true
		);
		// switch at 2 tabs, label at 3, body at 4.
		Assert.isTrue(out.indexOf('\n\t\t\t\t1;') != -1,
			'expected case body `1;` at 4-tab indent in: <$out>');
	}

	public function testIndentCaseLabelsFlagAffectsBareSwitch():Void {
		// Bare-form `switch e { ... }` (no parens around subject) routes
		// through `HxSwitchStmtBare`. The flag lives on its `cases` field
		// too, so flushing applies symmetrically.
		final out:String = writeWith(
			'class M { static function f() { switch e { case A: 1; default: 2; } } }',
			false
		);
		Assert.isTrue(out.indexOf('switch e {') != -1, 'expected bare-form switch in: <$out>');
		Assert.isTrue(out.indexOf('\n\t\tcase A:') != -1,
			'expected bare-switch `case A:` flushed at 2-tab indent in: <$out>');
	}

	public function testEmptySwitchBodyEmitsTightBraces():Void {
		// Defensive — empty cases array must not emit extra hardlines under
		// either flag value.
		final outTrue:String = writeWith('class M { static function f() { switch (e) {} } }', true);
		final outFalse:String = writeWith('class M { static function f() { switch (e) {} } }', false);
		Assert.isTrue(outTrue.indexOf('switch (e) {}') != -1, 'expected empty switch braces tight in true case: <$outTrue>');
		Assert.isTrue(outFalse.indexOf('switch (e) {}') != -1, 'expected empty switch braces tight in false case: <$outFalse>');
	}

	public function testConfigLoaderFlipsIndentCaseLabelsToFalse():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(
			'{"indentation": {"indentCaseLabels": false}}'
		);
		Assert.isFalse(opts.indentCaseLabels);
	}

	public function testConfigLoaderEmptyKeepsDefaultTrue():Void {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		Assert.isTrue(opts.indentCaseLabels);
	}

	private inline function writeWith(src:String, indentCaseLabels:Bool):String {
		final opts:HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson('{}');
		opts.indentCaseLabels = indentCaseLabels;
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}
}
