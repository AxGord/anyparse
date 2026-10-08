package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.AddParam;
import haxe.Exception;
import utest.Assert;
import utest.Test;

using StringTools;

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

	/** A writer config narrow enough that the fixture's signature wraps. */
	private static inline final NARROW: String = '{"wrapping": {"maxLineLength": 60}}';

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

	/**
	 * PIN. Canonical in, canonical out: a signature that fitted no longer does once the parameter is added, and the raw
	 * insertion used to leave it one over-long line the next writer-emit op refuses as drifted.
	 *
	 * The raw splice (the killing arm) answers the one-line `k(alpha:Int, beta:Int, ?gammaDeltaEpsilon:String = null):Bool {`.
	 */
	@:pin('control')
	@:killer('M-ADD-PARAM-RAW-SPLICE')
	public function testASignatureThatNoLongerFitsComesBackCanonical(): Void {
		final source: String = canonical('class K {\n\tfunction k(alpha:Int, beta:Int):Bool {\n\t\treturn true;\n\t}\n}\n');
		Assert.isTrue(source.contains('\tfunction k(alpha:Int, beta:Int):Bool {\n'), 'the fixture starts on one line:\n$source');
		final text: String = switch addOf(source, 2, 11, '?gammaDeltaEpsilon:String = null', NARROW) {
			case Ok(t): t;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				'';
		};
		Assert.isTrue(text.contains('?gammaDeltaEpsilon:String = null'), 'the parameter was added:\n$text');
		Assert.isFalse(text.contains('\tfunction k(alpha:Int, beta:Int, ?gammaDeltaEpsilon'), 'the signature wrapped:\n$text');
		Assert.equals(canonical(text), text, 'and the file is canonical');
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

	private static function addOf(source: String, line: Int, col: Int, paramText: String, ?optsJson: String): AddParamResult {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return AddParam.addParam(source, line, col, paramText, plugin, optsJson);
	}

	/** `source` as the writer lays it out under `NARROW`. */
	private static function canonical(source: String): String {
		return new HaxeQueryPlugin().writeRoundTrip(source, NARROW) ?? '';
	}

}
