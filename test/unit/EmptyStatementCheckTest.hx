package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.EmptyStatement;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `empty-statement` check: a stray empty statement (a lone `;`) is flagged
 * `Warning`. `fix` deletes it — the whole physical line when the `;` is alone on
 * it (no blank residue), only the `;` itself when it trails code (`g();;`).
 */
class EmptyStatementCheckTest extends Test {

	public function testEmptyStatementFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Void {\n\t\tg();\n\t\t;\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('empty-statement', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('empty statement', vs[0].message);
	}

	public function testTwoEmptyStatements(): Void {
		Assert.equals(2, violations('class C {\n\tfunction f():Void {\n\t\tg();;\n\t\t;\n\t}\n}').length);
	}

	public function testNoEmptyStatement(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tg();\n\t}\n}').length);
	}

	public function testFixDeletesOwnLineSemicolon(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tg();\n\t\t;\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tg();\n\t}\n}', applyFix(src));
	}

	public function testFixDeletesInlineSemicolon(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tg();;\n\t}\n}';
		Assert.equals('class C {\n\tfunction f():Void {\n\t\tg();\n\t}\n}', applyFix(src));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('empty-statement'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('empty-statement'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	private function violations(src: String): Array<Violation> {
		return new EmptyStatement().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function applyFix(src: String): String {
		final check: EmptyStatement = new EmptyStatement();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

}
