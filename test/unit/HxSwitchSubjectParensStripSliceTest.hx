package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HxModuleWriteOptions;

/**
 * ω-switch-subject-parens: `whitespace.parenConfig.switchSubjectParens:
 * "remove"` drops the redundant parens around a switch subject
 * (`switch (v) { … }` → `switch v { … }`), rendering the idiomatic bare
 * form. Statement- and expression-position switch share the `HxSwitchStmt`
 * grammar, so both are covered by one writer change. The parens are kept
 * for a leading-brace subject (object literal / block), where they keep the
 * subject brace from abutting the cases brace.
 *
 * Trivia-mode writer only (fed `opt.dropSwitchSubjectParens`); the plain
 * writer ignores the knob. Default `"keep"` preserves the authored parens
 * (byte-inert, fork parity). The `switch` keyword already emits its trailing
 * space, so the stripped form needs no substitute separator.
 */
@:nullSafety(Strict)
final class HxSwitchSubjectParensStripSliceTest extends Test {

	private static final REMOVE: String = '{"whitespace": {"parenConfig": {"switchSubjectParens": "remove"}}}';

	public function new(): Void {
		super();
	}

	// Statement-position: `switch (v) {` → `switch v {`.
	public function testStmtIdentStripsParens(): Void {
		final input: String = 'class C { function f() { switch (v) { case _: a; } } }';
		final expected: String = 'class C {\n\tfunction f() {\n\t\tswitch v {\n\t\t\tcase _:\n\t\t\t\ta;\n\t\t}\n\t}\n}\n';
		Assert.equals(expected, triviaWriteRemove(input));
	}

	// Expression-position (var init): `var y = switch (v) {` → `var y = switch v {`.
	public function testExprVarInitStripsParens(): Void {
		final input: String = 'class C { function f() { var y = switch (v) { case _: a; }; } }';
		final expected: String = 'class C {\n\tfunction f() {\n\t\tvar y = switch v {\n\t\t\tcase _: a;\n\t\t};\n\t}\n}\n';
		Assert.equals(expected, triviaWriteRemove(input));
	}

	// Expression-position (return): `return switch (v) {` → `return switch v {`.
	public function testReturnPositionStripsParens(): Void {
		final input: String = 'class C { function f() { return switch (v) { case 1: a; case _: b; }; } }';
		final expected: String = 'class C {\n\tfunction f() {\n\t\treturn switch v {\n\t\t\tcase 1: a;\n\t\t\tcase _: b;\n\t\t};\n\t}\n}\n';
		Assert.equals(expected, triviaWriteRemove(input));
	}

	// A non-trivial subject (call) strips too.
	public function testCallSubjectStripsParens(): Void {
		final input: String = 'class C { function f() { switch (foo()) { case _: a; } } }';
		final expected: String = 'class C {\n\tfunction f() {\n\t\tswitch foo() {\n\t\t\tcase _:\n\t\t\t\ta;\n\t\t}\n\t}\n}\n';
		Assert.equals(expected, triviaWriteRemove(input));
	}

	// Carve-out: an object-literal subject keeps its parens (`switch ({…}) {`),
	// so the subject brace never abuts the cases brace.
	public function testObjectLiteralSubjectKeepsParens(): Void {
		final input: String = 'class C { function f() { switch ({a: 1}) { case _: a; } } }';
		final expected: String = 'class C {\n\tfunction f() {\n\t\tswitch ({a: 1}) {\n\t\t\tcase _:\n\t\t\t\ta;\n\t\t}\n\t}\n}\n';
		Assert.equals(expected, triviaWriteRemove(input));
	}

	// Carve-out: a block subject keeps its parens.
	public function testBlockSubjectKeepsParens(): Void {
		final input: String = 'class C { function f() { switch ({ g(); v; }) { case _: a; } } }';
		final expected: String = 'class C {\n\tfunction f() {\n\t\tswitch ({\n\t\t\tg();\n\t\t\tv;\n\t\t}) {\n\t\t\tcase _:\n\t\t\t\ta;\n\t\t}\n\t}\n}\n';
		Assert.equals(expected, triviaWriteRemove(input));
	}

	// An already-bare subject is stable under "remove" (idempotency).
	public function testBareSubjectStableUnderRemove(): Void {
		final input: String = 'class C { function f() { switch v { case _: a; } } }';
		final expected: String = 'class C {\n\tfunction f() {\n\t\tswitch v {\n\t\t\tcase _:\n\t\t\t\ta;\n\t\t}\n\t}\n}\n';
		Assert.equals(expected, triviaWriteRemove(input));
	}

	// Default (knob off): parens are preserved in both positions — byte-inert.
	public function testDefaultKeepsParens(): Void {
		final stmtIn: String = 'class C { function f() { switch (v) { case _: a; } } }';
		final stmtExp: String = 'class C {\n\tfunction f() {\n\t\tswitch (v) {\n\t\t\tcase _: a;\n\t\t}\n\t}\n}\n';
		Assert.equals(stmtExp, triviaWriteDefault(stmtIn));
		final exprIn: String = 'class C { function f() { var y = switch (v) { case _: a; }; } }';
		final exprExp: String = 'class C {\n\tfunction f() {\n\t\tvar y = switch (v) {\n\t\t\tcase _: a;\n\t\t};\n\t}\n}\n';
		Assert.equals(exprExp, triviaWriteDefault(exprIn));
	}

	private inline function triviaWriteRemove(src: String): String {
		final opts: HxModuleWriteOptions = HaxeFormatConfigLoader.loadHxFormatJson(REMOVE);
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), opts);
	}

	private inline function triviaWriteDefault(src: String): String {
		return HaxeModuleTriviaWriter.write(HaxeModuleTriviaParser.parse(src), HaxeFormat.instance.defaultWriteOptions);
	}

}
