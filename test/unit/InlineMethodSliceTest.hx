package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.InlineMethod;
import anyparse.query.RefactorSupport.EditResult;
import haxe.Exception;

/**
 * `InlineMethod.inlineMethod` — inline a single-return function into its
 * call sites and delete the declaration (the method analog of `Inline`).
 *
 * Each accepted test inlines one function and asserts the EXACT rewritten
 * text: every in-file call is replaced with the body expression with its
 * arguments substituted for the parameters (parenthesised to preserve
 * precedence), and the declaration's lines are removed. Refusal cases
 * assert `Err` and that no source is emitted. Every `Ok` result is
 * additionally re-parsed, so an accepted rewrite is guaranteed valid Haxe.
 *
 * Coordinates are the positions `apq refs --decls` prints (the op reads
 * the column in the same `Span.lineCol().col - 1` convention as `inline`).
 */
class InlineMethodSliceTest extends Test {

	/**
	 * A binary-body method inlined into two call sites: `add(a, b)` with
	 * body `a + b` is substituted at `add(1, 2)` and `add(3, 4)`, each
	 * parenthesised (operator root) in the multiplicative context, and the
	 * declaration is removed.
	 */
	public function testInlineBinaryBothCallSites():Void {
		final source:String =
			'class C {\n'
			+ '\tfunction add(a:Int, b:Int):Int return a + b;\n'
			+ '\tfunction use():Int {\n'
			+ '\t\tvar x = add(1, 2) * add(3, 4);\n'
			+ '\t\treturn x;\n'
			+ '\t}\n'
			+ '}';
		final expected:String =
			'class C {\n'
			+ '\tfunction use():Int {\n'
			+ '\t\tvar x = (1 + 2) * (3 + 4);\n'
			+ '\t\treturn x;\n'
			+ '\t}\n'
			+ '}';
		assertInline(source, 2, 10, expected);
	}

	/**
	 * A single-parameter atomic body needs no parentheses: `id(a)` with
	 * body `a` becomes the bare argument — `id(7) + 1` → `7 + 1`.
	 */
	public function testInlineAtomicBodyNoParens():Void {
		final source:String =
			'class C {\n'
			+ '\tfunction id(a:Int):Int return a;\n'
			+ '\tfunction u():Int { return id(7) + 1; }\n'
			+ '}';
		final expected:String =
			'class C {\n'
			+ '\tfunction u():Int { return 7 + 1; }\n'
			+ '}';
		assertInline(source, 2, 10, expected);
	}

	/**
	 * A `final` method, called both as `this.dbl(...)` and bare `dbl(...)`:
	 * both forms collect through `CallSites` and inline.
	 */
	public function testInlineFinalMethodThisAndBareCalls():Void {
		final source:String =
			'class C {\n'
			+ '\tfinal function dbl(a:Int):Int return a * 2;\n'
			+ '\tfunction use():Int { return this.dbl(5) + dbl(6); }\n'
			+ '}';
		final expected:String =
			'class C {\n'
			+ '\tfunction use():Int { return (5 * 2) + (6 * 2); }\n'
			+ '}';
		assertInline(source, 2, 16, expected);
	}

	/**
	 * A named local function inlined into its bare calls: the
	 * uniqueness-based local-function collector proves the set complete,
	 * and the declaration statement is removed.
	 */
	public function testInlineLocalFunction():Void {
		final source:String =
			'class C {\n'
			+ '\tfunction run():Void {\n'
			+ '\t\tfunction greet(n:String) return trace(n);\n'
			+ '\t\tgreet("a");\n'
			+ '\t\tgreet("b");\n'
			+ '\t}\n'
			+ '}';
		final expected:String =
			'class C {\n'
			+ '\tfunction run():Void {\n'
			+ '\t\ttrace("a");\n'
			+ '\t\ttrace("b");\n'
			+ '\t}\n'
			+ '}';
		assertInline(source, 3, 12, expected);
	}

	/**
	 * A parameter referenced inside a COMPLEX `${ ... }` interpolation is a
	 * normal `IdentExpr` and is substituted — `'x=${a + 1}'` with arg `7`
	 * becomes `'x=${7 + 1}'`.
	 */
	public function testInlineComplexInterpolationSubstituted():Void {
		final source:String =
			'class C {\n'
			+ '\tfunction cpx(a:Int):String return \'x=$${a + 1}\';\n'
			+ '\tfunction u() { cpx(7); }\n'
			+ '}';
		final expected:String =
			'class C {\n'
			+ '\tfunction u() { \'x=$${7 + 1}\'; }\n'
			+ '}';
		assertInline(source, 2, 10, expected);
	}

	/** A multi-statement body cannot be reduced to one expression — refused. */
	public function testRefuseMultiStatementBody():Void {
		final source:String =
			'class C {\n'
			+ '\tfunction f(a:Int):Int { var t = a; return t + 1; }\n'
			+ '\tfunction u() { f(1); }\n'
			+ '}';
		assertRefused(source, 2, 10);
	}

	/** A recursive body would outlive the deleted declaration — refused. */
	public function testRefuseRecursion():Void {
		final source:String =
			'class C {\n'
			+ '\tfunction rec(a:Int):Int return rec(a - 1);\n'
			+ '\tfunction u() { rec(3); }\n'
			+ '}';
		assertRefused(source, 2, 10);
	}

	/**
	 * A 0-use parameter with a side-effecting argument would silently drop
	 * that side effect — refused.
	 */
	public function testRefuseDroppedImpureArgument():Void {
		final source:String =
			'class C {\n'
			+ '\tfunction ignore(a:Int):Int return 0;\n'
			+ '\tfunction side():Int return 9;\n'
			+ '\tfunction u() { ignore(side()); }\n'
			+ '}';
		assertRefused(source, 2, 10);
	}

	/** A call omitting an optional argument has the wrong arity — refused. */
	public function testRefuseArityMismatch():Void {
		final source:String =
			'class C {\n'
			+ '\tfunction f(a:Int, ?b:Int):Int return a;\n'
			+ '\tfunction u() { f(1); }\n'
			+ '}';
		assertRefused(source, 2, 10);
	}

	/**
	 * A parameter used via SIMPLE `'$a'` interpolation cannot be replaced
	 * by an arbitrary argument expression — refused.
	 */
	public function testRefuseSimpleInterpolation():Void {
		final source:String =
			'class C {\n'
			+ '\tfunction interp(a:Int):String return \'x=$$a\';\n'
			+ '\tfunction u() { interp(7); }\n'
			+ '}';
		assertRefused(source, 2, 10);
	}

	/** A cursor not on a function declaration / call is refused. */
	public function testRefuseCursorNotOnFunction():Void {
		final source:String =
			'class C {\n'
			+ '\tvar n:Int = 0;\n'
			+ '}';
		assertRefused(source, 2, 5);
	}

	private function assertInline(source:String, line:Int, col:Int, expected:String):Void {
		final result:EditResult = methodOf(source, line, col);
		switch result {
			case Ok(text):
				Assert.equals(expected, text);
				assertReparses(text);
			case Err(message): Assert.fail('expected Ok, got Err: $message');
		}
	}

	private function assertRefused(source:String, line:Int, col:Int):Void {
		final result:EditResult = methodOf(source, line, col);
		switch result {
			case Ok(text): Assert.fail('expected Err (refusal), got Ok:\n$text');
			case Err(_): Assert.pass();
		}
	}

	private function assertReparses(text:String):Void {
		final plugin:HaxeQueryPlugin = new HaxeQueryPlugin();
		try {
			plugin.parseFile(text);
			Assert.pass();
		} catch (exception:Exception) {
			Assert.fail('inlined output failed to re-parse: ${exception.message}\n$text');
		}
	}

	private static function methodOf(source:String, line:Int, col:Int):EditResult {
		final plugin:HaxeQueryPlugin = new HaxeQueryPlugin();
		final shape:RefShape = plugin.refShape();
		return InlineMethod.inlineMethod(source, line, col, plugin, shape);
	}
}
