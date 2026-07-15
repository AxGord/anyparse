package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-switch-after-paren: a `switch` expression directly after an open `(` —
 * a call argument (`f(switch x { … })`) or a parenthesised expression
 * (`(switch x { … })`) — gets a SPACE after the `(` (`f( switch x {` /
 * `( switch x {`), while the close `)` stays tight to the switch's `}`
 * (`});`). Mirrors the haxe-formatter fork.
 *
 * The space is the switch keyword's LEADING gap, so it is config-gated on
 * `whitespace.switchPolicy` being `before` / `around` (→
 * `opt.switchKwLeadingSpace`); with the default / `after` / `none` the `(`
 * stays tight. The gate is kept separate from `opt.switchPolicy`, which the
 * `conditionParens` catch-all overwrites.
 *
 * Two seams:
 *  - Call-arg: `WriterLowering.lowerPostfixCallInside` sets the call `(`
 *    inner-open pad to a space when the first argument's ctor is
 *    `SwitchExpr` / `SwitchExprBare`.
 *  - Paren-expr: `HxExpr.ParenExpr` carries `@:fmt(switchWrapSpace)`, and
 *    `WriterLowering.lowerKwRefBranch` appends the conditional space to the
 *    `@:wrap` lead Doc when the inner ctor is a switch.
 */
@:nullSafety(Strict)
final class HxSwitchAfterParenSpaceSliceTest extends Test {

	private static final AROUND: String = '{"whitespace": {"switchPolicy": "around"}}';

	public function new(): Void {
		super();
	}

	// `switchPolicy: around` → a `switch` as the sole call argument spaces `(`.
	public function testCallArgSwitchSpacesOpenParen(): Void {
		final input: String = 'class C {\n\tfunction f() {\n\t\tfinal a = pick(switch mode { case One: alpha; case _: beta; });\n\t}\n}';
		final expected: String = 'class C {\n\tfunction f() {\n\t\tfinal a = pick( switch mode {\n\t\t\tcase One: alpha;\n\t\t\tcase _: beta;\n\t\t});\n\t}\n}\n';
		Assert.equals(expected, triviaWriteAround(input));
	}

	// `switchPolicy: around` → a parenthesised `switch` expression spaces `(`.
	public function testParenSwitchSpacesOpenParen(): Void {
		final input: String = 'class C {\n\tfunction f() {\n\t\tfinal b = (switch mode { case One: alpha; case _: beta; });\n\t}\n}';
		final expected: String = 'class C {\n\tfunction f() {\n\t\tfinal b = ( switch mode {\n\t\t\tcase One: alpha;\n\t\t\tcase _: beta;\n\t\t});\n\t}\n}\n';
		Assert.equals(expected, triviaWriteAround(input));
	}

	// Guard: with `switchPolicy: around`, a non-switch paren and a non-switch
	// call argument stay tight — the space is switch-only.
	public function testNonSwitchStaysTight(): Void {
		final input: String = 'class C {\n\tfunction f() {\n\t\tfinal d = (alpha + beta);\n\t\tfinal c = pick(alpha);\n\t}\n}';
		final expected: String = 'class C {\n\tfunction f() {\n\t\tfinal d = (alpha + beta);\n\t\tfinal c = pick(alpha);\n\t}\n}\n';
		Assert.equals(expected, triviaWriteAround(input));
	}

	// Guard: the DEFAULT policy (no leading space) keeps `(` tight for both the
	// call-arg and paren switch — the space is policy-gated, not on by default.
	public function testDefaultPolicyStaysTight(): Void {
		final input: String = 'class C {\n\tfunction f() {\n\t\tfinal a = pick(switch mode { case One: alpha; case _: beta; });\n\t\tfinal b = (switch mode { case One: alpha; case _: beta; });\n\t}\n}';
		final expected: String = 'class C {\n\tfunction f() {\n\t\tfinal a = pick(switch mode {\n\t\t\tcase One: alpha;\n\t\t\tcase _: beta;\n\t\t});\n\t\tfinal b = (switch mode {\n\t\t\tcase One: alpha;\n\t\t\tcase _: beta;\n\t\t});\n\t}\n}\n';
		Assert.equals(expected, triviaWriteDefault(input));
	}

	// Regression (ω-switch-after-paren trailing-space): a switch-FIRST call arg
	// that WRAPS with a leading break (a second arg forces one-per-line) must
	// NOT leave the switch-after-paren space as trailing whitespace before the
	// break — the open `(` sits alone on its line (`caller(` + newline), not
	// `caller( ` + newline. The openInside space is an `OptSpace`, which the
	// renderer drops before a break-mode `Line`.
	public function testCallArgSwitchWrapDropsTrailingSpace(): Void {
		final cfg: String = '{"whitespace": {"switchPolicy": "around"}, "wrapping": {"callParameter": {"defaultWrap": "fillLineWithLeadingBreak", "rules": [{"conditions": [{"cond": "exceedsMaxLineLength", "value": 0}], "type": "noWrap"}]}}}';
		final input: String = 'class C {\n\tfunction m() {\n\t\tcaller(switch mode { case One: alpha; case Two: beta; }, other);\n\t}\n}';
		final expected: String = 'class C {\n\tfunction m() {\n\t\tcaller(\n\t\t\tswitch mode {\n\t\t\t\tcase One: alpha;\n\t\t\t\tcase Two: beta;\n\t\t\t},\n\t\t\tother\n\t\t);\n\t}\n}\n';
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(cfg);
		Assert.equals(expected, HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(input), opts));
	}

	private inline function triviaWriteAround(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(AROUND);
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}


	private inline function triviaWriteDefault(src: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HaxeFormat.instance.defaultWriteOptions);
	}

}
