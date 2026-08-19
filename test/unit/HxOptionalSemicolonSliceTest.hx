package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * E11 — `whitespace.optionalSemicolon` normalizes the OPTIONAL trailing
 * `;` that Haxe lets a `}`-terminated statement omit.
 *
 * The slot is the writer's, not the linter's: a `;` that parses as its
 * own node (`EmptyStmt`) is a deletable node and belongs to a lint rule,
 * while this one lands in the ctor's `@:trailOpt(';')` slot and never
 * becomes a node at all. It is also a DIFFERENT `;` from the editor
 * litter after `for (…) { … };` — here it is the statement's own
 * terminator, which Haxe merely permits omitting when the statement's
 * last token is `}`.
 *
 * Three values:
 *  - `"preserve"` (default) — re-emit the `;` exactly where the source
 *    had one. Today's behaviour, so fork parity is untouched.
 *  - `"always"` — emit the `;` on every participating slot, so the
 *    terminator is the same token regardless of how the value ends.
 *  - `"never"` — drop the `;` wherever the value is brace-terminated
 *    (the `endsWithCloseBrace` shape gate); a non-brace value keeps it,
 *    since `return 42` before `}` is `Missing ;`.
 *
 * The participating slots are the binding / `return` terminators —
 * `HxStatement.ReturnStmt` / `VarStmt` / `FinalStmt` / `StaticVarStmt` /
 * `StaticFinalStmt` and `HxClassMember.VarMember` / `FinalMember`. The
 * catch-all `ExprStmt` deliberately stays out: its brace-terminated
 * shapes are bare blocks and `macro { … }`, where an added `;` is
 * litter rather than a terminator.
 *
 * Trivia-mode writer only; the plain writer keeps its AST-shape gate.
 */
@:nullSafety(Strict)
final class HxOptionalSemicolonSliceTest extends Test {

	private static final ALWAYS: String = '{"whitespace": {"optionalSemicolon": "always"}}';
	private static final NEVER: String = '{"whitespace": {"optionalSemicolon": "never"}}';
	private static final PRESERVE: String = '{"whitespace": {"optionalSemicolon": "preserve"}}';

	public function new(): Void {
		super();
	}

	// The census site: `return { … }` with no `;` gains one under "always".
	public function testReturnObjectLiteralGainsSemicolon(): Void {
		final input: String = 'class C {\n\tfunction f() {\n\t\treturn {a: 1, b: 2}\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f() {\n\t\treturn {a: 1, b: 2};\n\t}\n}\n';
		Assert.equals(expected, triviaWrite(input, ALWAYS));
	}

	// `return switch … }` — the other half of the census, same direction.
	public function testReturnSwitchGainsSemicolon(): Void {
		final input: String = 'class C {\n\tfunction f() {\n\t\treturn switch (v) {\n\t\t\tcase _: 1;\n\t\t}\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f() {\n\t\treturn switch (v) {\n\t\t\tcase _: 1;\n\t\t};\n\t}\n}\n';
		Assert.equals(expected, triviaWrite(input, ALWAYS));
	}

	// A `return` whose value is NOT brace-terminated already carries the
	// `;` (it has no choice) — "always" leaves it byte-identical.
	public function testReturnPlainValueUnchangedUnderAlways(): Void {
		final input: String = 'class C {\n\tfunction f() {\n\t\treturn 42;\n\t}\n}\n';
		Assert.equals(input, triviaWrite(input, ALWAYS));
	}

	// `var` / `final` locals: the same slot, the same normalization.
	public function testVarAndFinalLocalsGainSemicolon(): Void {
		final input: String = 'class C {\n\tfunction f() {\n\t\tvar a = {x: 1}\n\t\tfinal b = {y: 2}\n\t\ttrace(a);\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f() {\n\t\tvar a = {x: 1};\n\t\tfinal b = {y: 2};\n\t\ttrace(a);\n\t}\n}\n';
		Assert.equals(expected, triviaWrite(input, ALWAYS));
	}

	// Class-level `var` / `final` members share the slot.
	public function testClassMembersGainSemicolon(): Void {
		final input: String = 'class C {\n\tvar a = {x: 1}\n\tfinal b = {y: 2}\n}\n';
		final expected: String = 'class C {\n\tvar a = {x: 1};\n\tfinal b = {y: 2};\n}\n';
		Assert.equals(expected, triviaWrite(input, ALWAYS));
	}

	// "never" is the mirror: a brace-terminated value loses the `;` while
	// the plain value in the SAME block keeps it — one assertion spanning
	// both halves, so neither can be satisfied on its own.
	public function testNeverDropsOnlyBraceTerminated(): Void {
		final input: String = 'class C {\n\tfunction f() {\n\t\tvar a = {x: 1};\n\t\tvar b = 2;\n\t\treturn {c: 3};\n\t}\n}\n';
		final expected: String = 'class C {\n\tfunction f() {\n\t\tvar a = {x: 1}\n\t\tvar b = 2;\n\t\treturn {c: 3}\n\t}\n}\n';
		Assert.equals(expected, triviaWrite(input, NEVER));
	}

	// A multi-variable declaration's `;` belongs to its LAST binding, not
	// its head. `var a = {x: 1}, b = 2` before a `}` is `Missing ;`, so
	// "never" must read the tail: the brace-headed list KEEPS its `;`
	// while the brace-TAILED one loses it — one assertion over both, so
	// neither half can pass alone.
	public function testNeverReadsTheLastBindingOfAMultiVarDecl(): Void {
		final input: String =
			'class C {\n\tfunction f() {\n\t\tvar a = {x: 1}, b = 2;\n\t\tvar c = 3, d = {y: 4};\n\t\ttrace(a);\n\t}\n}\n';
		final expected: String =
			'class C {\n\tfunction f() {\n\t\tvar a = {x: 1}, b = 2;\n\t\tvar c = 3, d = {y: 4}\n\t\ttrace(a);\n\t}\n}\n';
		Assert.equals(expected, triviaWrite(input, NEVER));
	}

	// "always" over the same pair is unconditional — both keep their `;`.
	public function testAlwaysKeepsMultiVarSemicolons(): Void {
		final input: String = 'class C {\n\tfunction f() {\n\t\tvar a = {x: 1}, b = 2;\n\t\tvar c = 3, d = {y: 4}\n\t\ttrace(a);\n\t}\n}\n';
		final expected: String =
			'class C {\n\tfunction f() {\n\t\tvar a = {x: 1}, b = 2;\n\t\tvar c = 3, d = {y: 4};\n\t\ttrace(a);\n\t}\n}\n';
		Assert.equals(expected, triviaWrite(input, ALWAYS));
	}

	// The catch-all `ExprStmt` is out of the whitelist: a bare block
	// statement keeps its authored form under both non-default values.
	public function testBareBlockStatementUntouched(): Void {
		final input: String = 'class C {\n\tfunction f() {\n\t\t{\n\t\t\ttrace(1);\n\t\t}\n\t\ttrace(2);\n\t}\n}\n';
		Assert.equals(input, triviaWrite(input, ALWAYS));
		Assert.equals(input, triviaWrite(input, NEVER));
	}

	// Default and explicit "preserve" both keep the source's own choice —
	// the two forms survive side by side, which is what fork parity means.
	public function testPreserveIsTheDefaultAndKeepsBothForms(): Void {
		final input: String = 'class C {\n\tfunction f() {\n\t\tvar a = {x: 1}\n\t\tvar b = {y: 2};\n\t\treturn a;\n\t}\n}\n';
		Assert.equals(input, triviaWriteDefault(input));
		Assert.equals(input, triviaWrite(input, PRESERVE));
	}

	// Idempotency: a second pass over "always" / "never" output is a no-op.
	public function testIdempotentUnderBothSettings(): Void {
		final input: String = 'class C {\n\tfunction f() {\n\t\tvar a = {x: 1}\n\t\treturn switch (a) {\n\t\t\tcase _: 1;\n\t\t}\n\t}\n}\n';
		final always: String = triviaWrite(input, ALWAYS);
		Assert.equals(always, triviaWrite(always, ALWAYS));
		final never: String = triviaWrite(input, NEVER);
		Assert.equals(never, triviaWrite(never, NEVER));
	}

	private inline function triviaWrite(src: String, json: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(json);
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

	private inline function triviaWriteDefault(src: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HaxeFormat.instance.defaultWriteOptions);
	}

}
