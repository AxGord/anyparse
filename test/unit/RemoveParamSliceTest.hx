package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.RemoveParam;
import anyparse.query.RemoveParam.RemoveParamResult;
import haxe.Exception;

/**
 * `RemoveParam.removeParam` — scope-correct, format-preserving
 * remove-parameter, the fifth refactoring operation built on the query
 * engine, the inverse of `AddParam`.
 *
 * Each test points a cursor at a function declaration in a fixture, asks
 * for a 0-based parameter index, and asserts the EXACT rewritten text:
 * the parameter and the corresponding positional argument at every
 * resolvable call site are deleted (with the separating comma), the
 * surrounding layout left in place. Refusal cases assert `Err` and that
 * no source is emitted. Every `Ok` result is additionally re-parsed, so
 * an accepted rewrite is guaranteed valid Haxe.
 *
 * Unlike `add-param`, removing a parameter breaks calls, so the operation
 * proves the call set complete with the SAME strict completeness proof
 * `ChangeSig` uses — an unresolvable / receiver-qualified call or an
 * arity mismatch is refused. The removed parameter must also be unused in
 * the body.
 *
 * Coordinates are the positions `apq refs` prints (remove-param
 * interprets the column in the same `Span.lineCol().col - 1` convention
 * as `rename` / `inline` / `extract-var` / `change-sig`).
 */
class RemoveParamSliceTest extends Test {

	/**
	 * Remove the MIDDLE parameter (index 1) of a method with three
	 * parameters. The fixture has a bare `f(...)` call and a `this.f(...)`
	 * call; both lose argument 1, comma intact. A method removal carries a
	 * non-null cross-file advisory.
	 */
	public function testRemoveMiddleMethodWithBareAndThisCalls():Void {
		final source:String =
			'class C {\n'
			+ '\tpublic function f(a:Int, b:String, c:Int):Void {\n'
			+ '\t\ttrace(a);\n'
			+ '\t}\n'
			+ '\tpublic function caller():Void {\n'
			+ '\t\tf(1, "x", 3);\n'
			+ '\t\tthis.f(7, "y", 9);\n'
			+ '\t}\n'
			+ '}';
		final expected:String =
			'class C {\n'
			+ '\tpublic function f(a:Int, c:Int):Void {\n'
			+ '\t\ttrace(a);\n'
			+ '\t}\n'
			+ '\tpublic function caller():Void {\n'
			+ '\t\tf(1, 3);\n'
			+ '\t\tthis.f(7, 9);\n'
			+ '\t}\n'
			+ '}';
		// Line 2 col 8 — the method `f` decl, as `apq refs --decls` prints.
		assertRemove(source, 2, 8, 1, expected, true);
	}

	/**
	 * Remove the FIRST parameter (index 0): the slot plus the FOLLOWING
	 * comma + whitespace goes, leaving the remaining parameters / arguments
	 * flush against the open paren.
	 */
	public function testRemoveFirstParam():Void {
		final source:String =
			'class C {\n'
			+ '\tpublic function f(a:Int, b:String, c:Int):Void {}\n'
			+ '\tpublic function caller():Void {\n'
			+ '\t\tf(1, "x", 3);\n'
			+ '\t}\n'
			+ '}';
		final expected:String =
			'class C {\n'
			+ '\tpublic function f(b:String, c:Int):Void {}\n'
			+ '\tpublic function caller():Void {\n'
			+ '\t\tf("x", 3);\n'
			+ '\t}\n'
			+ '}';
		assertRemove(source, 2, 8, 0, expected, true);
	}

	/**
	 * Remove the LAST parameter (index n-1): the PRECEDING comma +
	 * whitespace plus the slot goes, leaving the earlier parameters /
	 * arguments untouched.
	 */
	public function testRemoveLastParam():Void {
		final source:String =
			'class C {\n'
			+ '\tpublic function f(a:Int, b:String, c:Int):Void {}\n'
			+ '\tpublic function caller():Void {\n'
			+ '\t\tf(1, "x", 3);\n'
			+ '\t}\n'
			+ '}';
		final expected:String =
			'class C {\n'
			+ '\tpublic function f(a:Int, b:String):Void {}\n'
			+ '\tpublic function caller():Void {\n'
			+ '\t\tf(1, "x");\n'
			+ '\t}\n'
			+ '}';
		assertRemove(source, 2, 8, 2, expected, true);
	}

	/**
	 * Remove a parameter from a named LOCAL function (`LocalFnStmt`). A
	 * local function cannot escape its file, so the advisory is null.
	 */
	public function testRemoveLocalFunctionParam():Void {
		final source:String =
			'class C {\n'
			+ '\tpublic function run():Void {\n'
			+ '\t\tfunction add(x:Int, y:Int):Int {\n'
			+ '\t\t\treturn x;\n'
			+ '\t\t}\n'
			+ '\t\tvar r = add(1, 2);\n'
			+ '\t}\n'
			+ '}';
		final expected:String =
			'class C {\n'
			+ '\tpublic function run():Void {\n'
			+ '\t\tfunction add(x:Int):Int {\n'
			+ '\t\t\treturn x;\n'
			+ '\t\t}\n'
			+ '\t\tvar r = add(1);\n'
			+ '\t}\n'
			+ '}';
		// Line 3 col 11 — the local function `add` name token; remove `y`.
		assertRemove(source, 3, 11, 1, expected, false);
	}

	/**
	 * Remove a parameter from a `final` METHOD (`FinalModifiedMember`). The
	 * query projection surfaces the method name off the inner
	 * `HxFinalModifierMember.fn`, so `Refs` indexes it like a plain method:
	 * the bare `d(...)` call binds to it and the `this.d(...)` call matches
	 * structurally. A method removal carries a non-null cross-file advisory.
	 */
	public function testRemoveFinalMethodParam():Void {
		final source:String =
			'class C {\n'
			+ '\tfinal function d(a:Int, b:String, c:Int):Void {\n'
			+ '\t\ttrace(a);\n'
			+ '\t}\n'
			+ '\tpublic function caller():Void {\n'
			+ '\t\td(1, "x", 3);\n'
			+ '\t\tthis.d(7, "y", 9);\n'
			+ '\t}\n'
			+ '}';
		final expected:String =
			'class C {\n'
			+ '\tfinal function d(a:Int, c:Int):Void {\n'
			+ '\t\ttrace(a);\n'
			+ '\t}\n'
			+ '\tpublic function caller():Void {\n'
			+ '\t\td(1, 3);\n'
			+ '\t\tthis.d(7, 9);\n'
			+ '\t}\n'
			+ '}';
		// Line 2 col 1 — the `final` method decl, as `apq refs --decls` prints.
		assertRemove(source, 2, 1, 1, expected, true);
	}

	/**
	 * Remove the sole parameter of a 1-parameter function: the lone slot
	 * goes, leaving an empty `()` parameter / argument list.
	 */
	public function testRemoveLoneParamLeavesEmptyParens():Void {
		final source:String =
			'class C {\n'
			+ '\tpublic function f(a:Int):Void {}\n'
			+ '\tpublic function caller():Void {\n'
			+ '\t\tf(1);\n'
			+ '\t}\n'
			+ '}';
		final expected:String =
			'class C {\n'
			+ '\tpublic function f():Void {}\n'
			+ '\tpublic function caller():Void {\n'
			+ '\t\tf();\n'
			+ '\t}\n'
			+ '}';
		assertRemove(source, 2, 8, 0, expected, true);
	}

	/**
	 * Multi-line parameter list: removing a middle parameter deletes the
	 * preceding comma + slot, and the remaining parameters keep their
	 * per-line layout byte-for-byte.
	 */
	public function testRemoveMiddleParamMultilinePreservesLayout():Void {
		final source:String =
			'class C {\n'
			+ '\tfunction f(\n'
			+ '\t\ta:Int,\n'
			+ '\t\tb:Int,\n'
			+ '\t\tc:Int\n'
			+ '\t):Void {}\n'
			+ '}';
		final expected:String =
			'class C {\n'
			+ '\tfunction f(\n'
			+ '\t\ta:Int,\n'
			+ '\t\tc:Int\n'
			+ '\t):Void {}\n'
			+ '}';
		// Line 2 col 10 — the `f` method name token; remove `b` (index 1).
		assertRemove(source, 2, 10, 1, expected, true);
	}

	/** Refuse an index past the last parameter (out of range). */
	public function testRefuseIndexOutOfRange():Void {
		final source:String =
			'class C {\n'
			+ '\tpublic function f(a:Int, b:Int):Void {}\n'
			+ '}';
		assertRefused(source, 2, 8, 5);
	}

	/** Refuse a negative index (out of range). */
	public function testRefuseNegativeIndex():Void {
		final source:String =
			'class C {\n'
			+ '\tpublic function f(a:Int, b:Int):Void {}\n'
			+ '}';
		assertRefused(source, 2, 8, -1);
	}

	/**
	 * Refuse when the removed parameter is still used in the body — the
	 * result would reference an undefined identifier (a typing error the
	 * re-parse cannot catch), so the removal is refused.
	 */
	public function testRefuseParamStillUsedInBody():Void {
		final source:String =
			'class C {\n'
			+ '\tpublic function f(a:Int, b:Int):Void {\n'
			+ '\t\ttrace(b);\n'
			+ '\t}\n'
			+ '}';
		// Remove `b` (index 1), but `b` is read in the body.
		assertRefused(source, 2, 8, 1);
	}

	/**
	 * Refuse when the removed parameter is referenced by a later
	 * parameter's default value — removing it would leave that default
	 * referencing an undefined identifier.
	 */
	public function testRefuseParamUsedInLaterDefault():Void {
		final source:String =
			'class C {\n'
			+ '\tpublic function f(a:Int, b:Int = a):Void {}\n'
			+ '}';
		// Remove `a` (index 0), but `b`'s default references `a`.
		assertRefused(source, 2, 8, 0);
	}

	/**
	 * Refuse a receiver-qualified `obj.f(...)` call (non-`this` receiver):
	 * the call cannot be proven to target this method, so the whole removal
	 * is refused rather than silently leaving its arguments stale.
	 */
	public function testRefuseNonThisReceiverCall():Void {
		final source:String =
			'class C {\n'
			+ '\tpublic function f(a:Int, b:Int):Void {}\n'
			+ '\tpublic function caller(o:C):Void {\n'
			+ '\t\tf(1, 2);\n'
			+ '\t\to.f(3, 4);\n'
			+ '\t}\n'
			+ '}';
		assertRefused(source, 2, 8, 1);
	}

	/**
	 * Refuse a local-function removal when the name is ambiguous: a second
	 * local function of the same name shadows it in a nested block, so a
	 * bare call cannot be proven to target the first declaration. Refusing
	 * is the only safe outcome — deleting the shadowing call's argument
	 * would be a silent miscompile.
	 */
	public function testRefuseAmbiguousLocalFunctionName():Void {
		final source:String =
			'class C {\n'
			+ '\tpublic function run():Void {\n'
			+ '\t\tfunction add(x:Int, y:Int):Int return x;\n'
			+ '\t\tvar r = add(1, 2);\n'
			+ '\t\t{\n'
			+ '\t\t\tfunction add(p:Int, q:Int):Int return p;\n'
			+ '\t\t\tvar z = add(3, 4);\n'
			+ '\t\t}\n'
			+ '\t}\n'
			+ '}';
		assertRefused(source, 3, 11, 1);
	}

	/**
	 * Refuse an arity-mismatched call — a call that omits an optional /
	 * defaulted argument cannot have its slot removed unambiguously, so the
	 * removal is refused.
	 */
	public function testRefuseArityMismatchCall():Void {
		final source:String =
			'class C {\n'
			+ '\tpublic function f(a:Int, ?b:Int):Void {}\n'
			+ '\tpublic function caller():Void {\n'
			+ '\t\tf(1, 2);\n'
			+ '\t\tf(7);\n'
			+ '\t}\n'
			+ '}';
		assertRefused(source, 2, 8, 0);
	}

	/** Refuse a cursor that is not on a function (a plain field). */
	public function testRefuseCursorOnNonFunction():Void {
		final source:String =
			'class C {\n'
			+ '\tvar field:Int = 0;\n'
			+ '}';
		assertRefused(source, 2, 5, 0);
	}

	/**
	 * Refuse when a method is referenced as a first-class value (not just
	 * called): `var fn = f;` captures `f`, and an indirect `fn(...)` call
	 * keeps the now-deleted argument — remove-param cannot track it, so the
	 * removal is refused.
	 */
	public function testRefuseMethodReferencedAsValue():Void {
		final source:String =
			'class C {\n'
			+ '\tpublic function f(a:Int, b:Int):Void {}\n'
			+ '\tpublic function caller():Void {\n'
			+ '\t\tf(1, 2);\n'
			+ '\t\tvar fn = f;\n'
			+ '\t}\n'
			+ '}';
		assertRefused(source, 2, 8, 1);
	}

	/**
	 * Refuse when the parameter is used ONLY in single-quote string
	 * interpolation (`'$a'`). The interpolated identifier projects as an
	 * `Ident` node, NOT an `IdentExpr`, so the body-usage guard must count
	 * it — otherwise the removal silently leaves a dangling `$a` reference
	 * (the re-parse still succeeds; it is a typing error). The fixture's
	 * inner string is single-quoted (interpolating) while the outer Haxe
	 * literal is double-quoted so `$a` is not interpolated at test-compile.
	 */
	public function testRefuseParamUsedOnlyInInterpolation():Void {
		final source:String =
			'class C {\n'
			+ '\tpublic function f(a:Int):Void {\n'
			+ "\t\ttrace('value: $a');\n"
			+ '\t}\n'
			+ '}';
		assertRefused(source, 2, 8, 0);
	}

	private function assertRemove(source:String, line:Int, col:Int, index:Int, expected:String, advisoryNonNull:Bool):Void {
		final result:RemoveParamResult = removeOf(source, line, col, index);
		switch result {
			case Ok(text, advisory):
				Assert.equals(expected, text);
				if (advisoryNonNull) Assert.notNull(advisory);
				else Assert.isNull(advisory);
				// Every accepted rewrite must itself re-parse.
				assertReparses(text);
			case Err(message): Assert.fail('expected Ok, got Err: $message');
		}
	}

	private function assertRefused(source:String, line:Int, col:Int, index:Int):Void {
		final result:RemoveParamResult = removeOf(source, line, col, index);
		switch result {
			case Ok(text, _): Assert.fail('expected Err (refusal), got Ok:\n$text');
			case Err(_): Assert.pass();
		}
	}

	private function assertReparses(text:String):Void {
		final plugin:HaxeQueryPlugin = new HaxeQueryPlugin();
		try {
			plugin.parseFile(text);
			Assert.pass();
		} catch (exception:Exception) {
			Assert.fail('removed-param output failed to re-parse: ${exception.message}\n$text');
		}
	}

	private static function removeOf(source:String, line:Int, col:Int, index:Int):RemoveParamResult {
		final plugin:HaxeQueryPlugin = new HaxeQueryPlugin();
		final shape:RefShape = plugin.refShape();
		return RemoveParam.removeParam(source, line, col, index, plugin, shape);
	}
}
