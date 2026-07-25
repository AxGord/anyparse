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

	public function testEmptyMemberFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Void {}\n\t;\n\tfunction g():Void {}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('empty-statement', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('empty statement', vs[0].message);
	}

	public function testFixDeletesOwnLineMemberSemicolon(): Void {
		final src: String = 'class C {\n\tfunction f():Void {}\n\t;\n\tfunction g():Void {}\n}';
		Assert.equals('class C {\n\tfunction f():Void {}\n\tfunction g():Void {}\n}', applyFix(src));
	}

	public function testFixDeletesGluedMemberSemicolon(): Void {
		final src: String = 'class C {\n\tfunction f():Void {};\n}';
		Assert.equals('class C {\n\tfunction f():Void {}\n}', applyFix(src));
	}

	public function testFixDeletesMixedStatementAndMemberSemicolons(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tg();;\n\t}\n\t;\n}';
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


	/**
	 * A `;` after a BLOCK-bodied statement (`for (…) { … };`) is stray too, but the
	 * parser folds it into trivia instead of an empty-statement node - it has to be
	 * found by position, in the gap between two statements.
	 */
	public function testSemicolonAfterForBlockFlagged(): Void {
		final src: String =
			'class C {\n\tfunction f(m:Map<Int, Int>):Void {\n\t\tfor (k => v in m) {\n\t\t\tg(k, v);\n\t\t};\n\t\th();\n\t}\n}';
		Assert.equals(1, violations(src).length);
	}


	/** The same stray `;` after an empty `catch` body, at the end of a block. */
	public function testSemicolonAfterCatchBlockFlagged(): Void {
		final src: String =
			'class C {\n\tfunction f():Void {\n\t\ttry\n\t\t\trisky()\n\t\tcatch (_:haxe.Exception)\n\t\t\t{};\n\t\th();\n\t}\n}';
		Assert.equals(1, violations(src).length);
	}


	/**
	 * The `;` that TERMINATES a value-position block must stay: an `if`-expression
	 * initialiser (`final x = if (c) {…} else {…};`) needs it, and it sits INSIDE the
	 * declaration statement rather than in the gap after it.
	 */
	public function testSemicolonClosingIfExpressionNotFlagged(): Void {
		final src: String =
			'class C {\n\tfunction f(c:Bool):Void {\n\t\tfinal x:Int = if (c) {\n\t\t\tg();\n\t\t\t1;\n\t\t} else {\n\t\t\t2;\n\t\t};\n\t\th(x);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}


	/** `fix` drops the absorbed `;` and leaves the closing brace and its line intact. */
	public function testFixDeletesSemicolonAfterForBlock(): Void {
		final src: String =
			'class C {\n\tfunction f(m:Map<Int, Int>):Void {\n\t\tfor (k => v in m) {\n\t\t\tg(k, v);\n\t\t};\n\t\th();\n\t}\n}';
		final expected: String =
			'class C {\n\tfunction f(m:Map<Int, Int>):Void {\n\t\tfor (k => v in m) {\n\t\t\tg(k, v);\n\t\t}\n\t\th();\n\t}\n}';
		Assert.equals(expected, applyFix(src));
	}


	/**
	 * Every OTHER `;` that follows a `}` is mandatory and must survive: a
	 * block/lambda/object-literal/switch-expression initialiser, and the `while`
	 * terminator of a `do` loop. `if (c) g();` ends in its inner statement, not a block.
	 */
	public function testMandatorySemicolonsAfterBraceNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f(c:Bool):Void {\n\t\tfinal a:Int = {\n\t\t\tg();\n\t\t\t1;\n\t\t};\n'
			+ '\t\tfinal fn:()->Void = function() {\n\t\t\tg();\n\t\t};\n' + '\t\tfinal o:Dynamic = { k: 1 };\n'
			+ '\t\tfinal s:Int = switch a {\n\t\t\tcase _: 0;\n\t\t};\n' + '\t\tdo {\n\t\t\tg();\n\t\t} while (c);\n' + '\t\tif (c) g();\n'
			+ '\t\th(s);\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}


	/**
	 * A `catch` whose body is a SINGLE STATEMENT ends before the `;` just like a
	 * block-bodied one, but there the terminator is mandatory - real code broke on
	 * this, so it is locked in: what must precede the stray `;` is a `}`.
	 */
	public function testSemicolonAfterSingleStatementCatchNotFlagged(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\ttry\n\t\t\trisky()\n\t\tcatch (exception:Exception)\n'
			+ '\t\t\tlog(exception);\n' + '\t\th();\n\t}\n}';
		Assert.equals(0, violations(src).length);
	}

}
