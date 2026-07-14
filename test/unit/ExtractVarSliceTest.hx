package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.ExtractVar;
import anyparse.query.ExtractVar.ExtractResult;
import haxe.Exception;

/**
 * `ExtractVar.extractVar` — scope-correct, format-preserving
 * extract-variable, the inverse of `Inline`.
 *
 * Each test points a cursor at the START of an expression in a fixture
 * and asserts the EXACT rewritten text: the outermost expression
 * starting at the cursor is hoisted into a fresh `final <name> = <expr>;`
 * line inserted before the enclosing block-level statement (at that
 * statement's indentation), and the occurrence is replaced with the
 * name. Refusal cases assert `Err` and that no source is emitted. Every
 * `Ok` result is additionally re-parsed, so an accepted rewrite is
 * guaranteed valid Haxe.
 *
 * Coordinates are the positions `apq refs` prints (the extract
 * interprets the column in the same 1-based convention
 * as `rename` / `inline`).
 */
class ExtractVarSliceTest extends Test {

	/**
	 * Extract a binary RHS: pointing at `a` in `var y = a + b * 2;` grabs
	 * the whole `a + b * 2` (the outermost expression at the cursor, not
	 * the bare `a`), hoists `final t = a + b * 2;` above, and rewrites the
	 * decl to `var y = t;`.
	 */
	public function testExtractBinaryRhsGrabsOutermost(): Void {
		final source: String = 'class C {\n' + '\tfunction f(a:Int, b:Int):Int {\n' + '\t\tvar y = a + b * 2;\n' + '\t\treturn y;\n'
			+ '\t}\n' + '}';
		final expected: String = 'class C {\n' + '\tfunction f(a:Int, b:Int):Int {\n' + '\t\tfinal t = a + b * 2;\n' + '\t\tvar y = t;\n'
			+ '\t\treturn y;\n' + '\t}\n' + '}';
		// Line 3 col 11 — the `a` in `a + b * 2`.
		assertExtract(source, 3, 11, 't', expected);
	}

	/**
	 * Pointing at a call argument's first token extracts only that
	 * argument expression, not the enclosing call.
	 */
	public function testExtractCallArgument(): Void {
		final source: String = 'class C {\n' + '\tfunction f(a:Int, b:Int):Void {\n' + '\t\tg(a + b);\n' + '\t}\n' + '}';
		final expected: String = 'class C {\n' + '\tfunction f(a:Int, b:Int):Void {\n' + '\t\tfinal t = a + b;\n' + '\t\tg(t);\n' + '\t}\n'
			+ '}';
		// Line 3 col 5 — the `a` inside `g(a + b)`.
		assertExtract(source, 3, 5, 't', expected);
	}

	/**
	 * Pointing at the call's callee (the first token of the whole call
	 * expression) extracts the entire `g(a + b)` call instead of an
	 * argument.
	 */
	public function testExtractWholeCall(): Void {
		final source: String = 'class C {\n' + '\tfunction f(a:Int, b:Int):Void {\n' + '\t\tvar r = g(a + b);\n' + '\t\ttrace(r);\n'
			+ '\t}\n' + '}';
		final expected: String = 'class C {\n' + '\tfunction f(a:Int, b:Int):Void {\n' + '\t\tfinal t = g(a + b);\n' + '\t\tvar r = t;\n'
			+ '\t\ttrace(r);\n' + '\t}\n' + '}';
		// Line 3 col 11 — the `g` callee of `g(a + b)`.
		assertExtract(source, 3, 11, 't', expected);
	}

	/**
	 * Extract an `if` CONDITION: the `IfStmt` owning the condition IS a
	 * block child, so the hoist is allowed — `final c = a > 0;` is
	 * inserted above the `if`, whose condition becomes `if (c)`.
	 */
	public function testExtractIfCondition(): Void {
		final source: String = 'class C {\n' + '\tfunction f(a:Int):Int {\n' + '\t\tif (a > 0) {\n' + '\t\t\treturn 1;\n' + '\t\t}\n'
			+ '\t\treturn 0;\n' + '\t}\n' + '}';
		final expected: String = 'class C {\n' + '\tfunction f(a:Int):Int {\n' + '\t\tfinal c = a > 0;\n' + '\t\tif (c) {\n'
			+ '\t\t\treturn 1;\n' + '\t\t}\n' + '\t\treturn 0;\n' + '\t}\n' + '}';
		// Line 3 col 7 — the `a` in `if (a > 0)`.
		assertExtract(source, 3, 7, 'c', expected);
	}

	/**
	 * Indentation is preserved: a target nested two blocks deep carries
	 * the enclosing statement's deeper indent on the hoisted line.
	 */
	public function testIndentationPreservedInNestedBlock(): Void {
		final source: String = 'class C {\n' + '\tfunction f(a:Int, b:Int):Void {\n' + '\t\twhile (a > 0) {\n' + '\t\t\tg(a + b);\n'
			+ '\t\t}\n' + '\t}\n' + '}';
		final expected: String = 'class C {\n' + '\tfunction f(a:Int, b:Int):Void {\n' + '\t\twhile (a > 0) {\n'
			+ '\t\t\tfinal t = a + b;\n' + '\t\t\tg(t);\n' + '\t\t}\n' + '\t}\n' + '}';
		// Line 4 col 6 — the `a` inside the braced while body's `g(a + b)`.
		assertExtract(source, 4, 6, 't', expected);
	}

	/**
	 * Refuse a sub-node of a braceless `if (cond) return a + b;`
	 * then-branch: the `ReturnStmt` parent is the `IfStmt`, not a block,
	 * so the enclosing statement is not inside a `{ }` block.
	 */
	public function testRefuseBracelessBranchSubExpr(): Void {
		final source: String = 'class C {\n' + '\tfunction f(a:Int, b:Int):Int {\n' + '\t\tif (a > 0) return a + b;\n' + '\t\treturn 0;\n'
			+ '\t}\n' + '}';
		// Line 3 col 21 — the `a` in the braceless then-branch `a + b`.
		assertRefused(source, 3, 21, 't');
	}

	/**
	 * Refuse when the cursor is not on an expression start (whitespace
	 * between tokens): no expression node begins there.
	 */
	public function testRefuseCursorNotOnExpressionStart(): Void {
		final source: String = 'class C {\n' + '\tfunction f(a:Int, b:Int):Int {\n' + '\t\tvar y = a + b;\n' + '\t\treturn y;\n' + '\t}\n'
			+ '}';
		// Line 3 col 12 — the space between `a` and `+`.
		assertRefused(source, 3, 12, 't');
	}

	/**
	 * Refuse an invalid extraction name: a non-identifier target name is
	 * rejected before any source inspection.
	 */
	public function testRefuseInvalidName(): Void {
		final source: String = 'class C {\n' + '\tfunction f(a:Int, b:Int):Int {\n' + '\t\tvar y = a + b;\n' + '\t\treturn y;\n' + '\t}\n'
			+ '}';
		// Line 3 col 11 — the `a`; name `1bad` is not a valid identifier.
		assertRefused(source, 3, 11, '1bad');
	}

	/**
	 * Refuse extracting into a name that already binds a parameter in the
	 * enclosing function — the hoisted `final x` would shadow / redeclare
	 * the param `x`.
	 */
	public function testRefuseNameCollidesWithParam(): Void {
		final source: String = 'class C {\n' + '\tfunction f(a:Int, b:Int, x:Int):Int {\n' + '\t\treturn a + b;\n' + '\t}\n' + '}';
		// Line 3 col 10 — the `a`; name `x` already names a parameter.
		assertRefused(source, 3, 10, 'x');
	}

	/**
	 * Extract an expression inside a `final` METHOD body. The enclosing
	 * function is a `FinalModifiedMember`; the projection surfaces its name
	 * off the inner `HxFinalModifierMember.fn`, so the hoist resolves the
	 * scope exactly like a plain `FnMember` body.
	 */
	public function testExtractInsideFinalMethod(): Void {
		final source: String = 'class C {\n' + '\tfinal function d(a:Int, b:Int):Int {\n' + '\t\tvar y = a + b * 2;\n' + '\t\treturn y;\n'
			+ '\t}\n' + '}';
		final expected: String = 'class C {\n' + '\tfinal function d(a:Int, b:Int):Int {\n' + '\t\tfinal t = a + b * 2;\n'
			+ '\t\tvar y = t;\n' + '\t\treturn y;\n' + '\t}\n' + '}';
		// Line 3 col 11 — the `a` in `a + b * 2`.
		assertExtract(source, 3, 11, 't', expected);
	}

	/**
	 * Refuse a name that collides with a parameter of the enclosing `final`
	 * METHOD. This exercises the enclosing-function resolution
	 * (`nameDeclaredInEnclosingFunction`): the `FinalModifiedMember` must be
	 * recognised as the enclosing function so its param `x` is found —
	 * before the fix the nameless final-method node failed `innermostWhere`
	 * and the collision was silently missed.
	 */
	public function testRefuseCollidesFinalMethodParam(): Void {
		final source: String = 'class C {\n' + '\tfinal function d(a:Int, b:Int, x:Int):Int {\n' + '\t\treturn a + b;\n' + '\t}\n' + '}';
		// Line 3 col 10 — the `a`; name `x` already names a param of the final method.
		assertRefused(source, 3, 10, 'x');
	}

	private function assertExtract(source: String, line: Int, col: Int, name: String, expected: String): Void {
		final result: ExtractResult = extractOf(source, line, col, name);
		switch result {
			case Ok(text):
				Assert.equals(expected, text);
				// Every accepted rewrite must itself re-parse.
				assertReparses(text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	private function assertRefused(source: String, line: Int, col: Int, name: String): Void {
		final result: ExtractResult = extractOf(source, line, col, name);
		switch result {
			case Ok(text):
				Assert.fail('expected Err (refusal), got Ok:\n$text');
			case Err(_):
				Assert.pass();
		}
	}

	private function assertReparses(text: String): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		try {
			plugin.parseFile(text);
			Assert.pass();
		} catch (exception: Exception) {
			Assert.fail('extracted output failed to re-parse: ${exception.message}\n$text');
		}
	}

	private static function extractOf(source: String, line: Int, col: Int, name: String): ExtractResult {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return ExtractVar.extractVar(source, line, col, name, plugin);
	}

}
