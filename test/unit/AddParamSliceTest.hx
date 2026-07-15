package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.AddParam;
import anyparse.query.AddParam.AddParamResult;
import haxe.Exception;

/**
 * `AddParam.addParam` — add a backward-compatible parameter to a
 * function declaration, a deliberately DECL-ONLY refactoring operation.
 *
 * Each test points a cursor at a function declaration and asserts the
 * EXACT rewritten text: the new parameter is appended at the
 * parameter-list tail, preserving the existing parameter formatting.
 * Refusal cases assert `Err` and that no source is emitted (a required
 * parameter, a name collision, a cursor off any function). Every `Ok`
 * result is additionally re-parsed, so an accepted rewrite is guaranteed
 * valid Haxe.
 *
 * No call site is updated — that is the whole point: because the added
 * parameter is always optional or defaulted, existing call sites stay
 * compilable, so the operation is safe for methods and local functions
 * alike.
 *
 * Coordinates are the positions `apq refs` prints (the add interprets
 * the column in the same 1-based convention as
 * `rename` / `inline` / `extract-var`).
 */
class AddParamSliceTest extends Test {

	/**
	 * Add a defaulted trailing parameter to a 2-parameter method:
	 * `function f(a:Int, b:Int)` gains `c:Int = 0` at the list tail,
	 * preserving the existing two parameters verbatim.
	 */
	public function testAddDefaultedToTwoParamMethod(): Void {
		final source: String = 'class C {\n\tfunction f(a:Int, b:Int):Void {}\n}';
		final expected: String = 'class C {\n\tfunction f(a:Int, b:Int, c:Int = 0):Void {}\n}';
		// Line 2 col 11 — the `f` method name token.
		assertAdd(source, 2, 11, 'c:Int = 0', expected);
	}

	/**
	 * Add an optional `?`-parameter to a ZERO-parameter function:
	 * `function g()` becomes `function g(?flag:Bool)` — the parameter is
	 * inserted just inside the `(`.
	 */
	public function testAddOptionalToZeroParamFunction(): Void {
		final source: String = 'class C {\n\tfunction g():Void {}\n}';
		final expected: String = 'class C {\n\tfunction g(?flag:Bool):Void {}\n}';
		// Line 2 col 11 — the `g` method name token.
		assertAdd(source, 2, 11, '?flag:Bool', expected);
	}

	/**
	 * Add an optional `?`-parameter to a function that already has one
	 * parameter — it lands after the existing parameter.
	 */
	public function testAddOptionalToOneParamMethod(): Void {
		final source: String = 'class C {\n\tfunction h(a:Int):Void {}\n}';
		final expected: String = 'class C {\n\tfunction h(a:Int, ?b:String):Void {}\n}';
		// Line 2 col 11 — the `h` method name token.
		assertAdd(source, 2, 11, '?b:String', expected);
	}

	/**
	 * Add a defaulted parameter to a LOCAL function (`LocalFnStmt`),
	 * confirming the operation resolves the inner declaration, not the
	 * enclosing method.
	 */
	public function testAddToLocalFunction(): Void {
		final source: String = 'class C {\n\tfunction m():Void {\n\t\tfunction loc(x:Int):Int return x;\n\t}\n}';
		final expected: String = 'class C {\n\tfunction m():Void {\n\t\tfunction loc(x:Int, y:Int = 1):Int return x;\n\t}\n}';
		// Line 3 col 12 — the `loc` local-function name token.
		assertAdd(source, 3, 12, 'y:Int = 1', expected);
	}

	/**
	 * Add an optional parameter to a `final` METHOD
	 * (`FinalModifiedMember`). The query projection surfaces the method
	 * name off the inner `HxFinalModifierMember.fn`, so the operation
	 * resolves a final method exactly like a plain `FnMember`.
	 */
	public function testAddToFinalMethod(): Void {
		final source: String = 'class C {\n\tfinal function d(a:Int):Void {}\n}';
		final expected: String = 'class C {\n\tfinal function d(a:Int, ?b:String):Void {}\n}';
		// Line 2 col 17 — the `d` final-method name token.
		assertAdd(source, 2, 17, '?b:String', expected);
	}

	/**
	 * Add a function-typed optional parameter — the `->` in the type does
	 * not confuse the parameter-name parse or the insertion.
	 */
	public function testAddFunctionTypedOptionalParam(): Void {
		final source: String = 'class C {\n\tfunction k(a:Int):Void {}\n}';
		final expected: String = 'class C {\n\tfunction k(a:Int, ?cb:Void->Void):Void {}\n}';
		// Line 2 col 11 — the `k` method name token.
		assertAdd(source, 2, 11, '?cb:Void->Void', expected);
	}

	/**
	 * Existing parameter formatting is preserved: a multi-line parameter
	 * list keeps its layout, and the new parameter is appended after the
	 * last parameter's content (not glued onto the closing-paren line).
	 */
	public function testMultilineParamListFormattingPreserved(): Void {
		final source: String = 'class C {\n\tfunction f(\n\t\ta:Int,\n\t\tb:Int\n\t):Void {}\n}';
		final expected: String = 'class C {\n\tfunction f(\n\t\ta:Int,\n\t\tb:Int, c:Int = 0\n\t):Void {}\n}';
		// Line 2 col 11 — the `f` method name token.
		assertAdd(source, 2, 11, 'c:Int = 0', expected);
	}

	/**
	 * Refuse a REQUIRED parameter (no `?`, no `=`): a required parameter
	 * would break existing call sites, so it is rejected.
	 */
	public function testRefuseRequiredParam(): Void {
		final source: String = 'class C {\n\tfunction f(a:Int):Void {}\n}';
		// Line 2 col 11 — the `f`; `b:Int` is required (no default, not optional).
		assertRefused(source, 2, 11, 'b:Int');
	}

	/**
	 * Refuse a name that collides with an existing parameter — adding a
	 * second `a` would redeclare the parameter.
	 */
	public function testRefuseNameCollidesWithExistingParam(): Void {
		final source: String = 'class C {\n\tfunction f(a:Int, b:Int):Void {}\n}';
		// Line 2 col 11 — the `f`; `a` already names a parameter.
		assertRefused(source, 2, 11, 'a:Int = 0');
	}

	/**
	 * Refuse when the cursor is not on any function declaration (here, on
	 * the class name): there is nothing to add a parameter to.
	 */
	public function testRefuseCursorOffFunction(): Void {
		final source: String = 'class C {\n\tvar x:Int = 0;\n}';
		// Line 2 col 6 — the `x` field, not a function.
		assertRefused(source, 2, 6, '?flag:Bool');
	}

	private function assertAdd(source: String, line: Int, col: Int, paramText: String, expected: String): Void {
		final result: AddParamResult = addOf(source, line, col, paramText);
		switch result {
			case Ok(text):
				Assert.equals(expected, text);
				// Every accepted rewrite must itself re-parse.
				assertReparses(text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	private function assertRefused(source: String, line: Int, col: Int, paramText: String): Void {
		final result: AddParamResult = addOf(source, line, col, paramText);
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
			Assert.fail('add-param output failed to re-parse: ${exception.message}\n$text');
		}
	}

	private static function addOf(source: String, line: Int, col: Int, paramText: String): AddParamResult {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return AddParam.addParam(source, line, col, paramText, plugin);
	}

}
