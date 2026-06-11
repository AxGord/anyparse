package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.Inline;
import anyparse.query.Inline.InlineResult;
import haxe.Exception;

/**
 * `Inline.inline` — scope-correct, format-preserving inline-variable.
 *
 * Each test inlines one local binding in a fixture and asserts the EXACT
 * rewritten text: every read of the targeted binding is replaced with
 * the binding's initializer source (parenthesised when the initializer
 * root is an operator), and the declaration line is removed with no
 * blank line left behind. Refusal cases assert `Err` and that the source
 * is never emitted. Every `Ok` result is additionally re-parsed by the
 * inline itself, so an accepted rewrite is guaranteed valid Haxe.
 *
 * Coordinates are the positions `apq refs --decls` prints (the inline
 * interprets the column in the same `Span.lineCol().col - 1` convention
 * as `rename`).
 */
class InlineSliceTest extends Test {

	/**
	 * Inline a literal: the local `x = 5` decl is removed and both reads
	 * (`return x + x`) become `5`.
	 */
	public function testInlineLiteralIntoAllReads(): Void {
		final source: String = 'class C {\n' + '\tfunction f():Int {\n' + '\t\tvar x = 5;\n' + '\t\treturn x + x;\n' + '\t}\n' + '}';
		final expected: String = 'class C {\n' + '\tfunction f():Int {\n' + '\t\treturn 5 + 5;\n' + '\t}\n' + '}';
		assertInline(source, 3, 2, expected);
	}

	/**
	 * Inline a binary initializer into a tighter (multiplicative) context:
	 * the `a + b` initializer is parenthesised so precedence is preserved
	 * — `x * 2` becomes `(a + b) * 2`.
	 */
	public function testInlineBinaryParenthesisesInTighterContext(): Void {
		final source: String = 'class C {\n'
			+ '\tfunction f(a:Int, b:Int):Int {\n' + '\t\tvar x = a + b;\n' + '\t\treturn x * 2;\n' + '\t}\n' + '}';
		final expected: String = 'class C {\n' + '\tfunction f(a:Int, b:Int):Int {\n' + '\t\treturn (a + b) * 2;\n' + '\t}\n' + '}';
		assertInline(source, 3, 2, expected);
	}

	/**
	 * Inline an atomic (bare-identifier) initializer: `x = a` has an
	 * `IdentExpr` root, which never needs parentheses — `x + 1` becomes
	 * `a + 1`.
	 */
	public function testInlineAtomicIdentStaysUnparenthesised(): Void {
		final source: String = 'class C {\n' + '\tfunction f(a:Int):Int {\n' + '\t\tvar x = a;\n' + '\t\treturn x + 1;\n' + '\t}\n' + '}';
		final expected: String = 'class C {\n' + '\tfunction f(a:Int):Int {\n' + '\t\treturn a + 1;\n' + '\t}\n' + '}';
		assertInline(source, 3, 2, expected);
	}

	/**
	 * A cursor placed on a READ of the binding (not the decl) resolves to
	 * the same binding and inlines identically.
	 */
	public function testCursorOnReadStillInlines(): Void {
		final source: String = 'class C {\n' + '\tfunction f(a:Int):Int {\n' + '\t\tvar x = a + 1;\n' + '\t\treturn x;\n' + '\t}\n' + '}';
		final expected: String = 'class C {\n' + '\tfunction f(a:Int):Int {\n' + '\t\treturn (a + 1);\n' + '\t}\n' + '}';
		// Line 4 col 9 — the `x` in `return x;`.
		assertInline(source, 4, 9, expected);
	}

	/**
	 * Multiple reads across statements are all substituted and the decl
	 * line vanishes cleanly (no orphan blank line).
	 */
	public function testInlineMultipleReadsRemovesDeclLine(): Void {
		final source: String = 'class C {\n'
			+ '\tfunction f(a:Int):Int {\n' + '\t\tvar x = a + 2;\n' + '\t\tvar y = x;\n' + '\t\treturn y + x;\n' + '\t}\n' + '}';
		final expected: String = 'class C {\n'
			+ '\tfunction f(a:Int):Int {\n' + '\t\tvar y = (a + 2);\n' + '\t\treturn y + (a + 2);\n' + '\t}\n' + '}';
		assertInline(source, 3, 2, expected);
	}

	/**
	 * Refuse a reassigned variable: `x` is written after its decl, so
	 * duplicating its (now mutable) value would be incorrect.
	 */
	public function testRefuseReassignedVariable(): Void {
		final source: String = 'class C {\n'
			+ '\tfunction f(a:Int):Int {\n' + '\t\tvar x = 1;\n' + '\t\tx = 2;\n' + '\t\treturn x;\n' + '\t}\n' + '}';
		assertRefused(source, 3, 2);
	}

	/**
	 * Refuse an initializer with a side-effecting call: inlining `f()`
	 * across N reads would invoke it N times.
	 */
	public function testRefuseInitializerWithCall(): Void {
		final source: String = 'class C {\n'
			+ '\tfunction g():Int return 1;\n' + '\tfunction f():Int {\n' + '\t\tvar x = g();\n' + '\t\treturn x + x;\n' + '\t}\n' + '}';
		assertRefused(source, 4, 2);
	}

	/**
	 * Refuse when the initializer reads a free variable that is reassigned
	 * elsewhere: moving the read past the reassignment changes its value.
	 */
	public function testRefuseInitializerReadsReassignedFreeVar(): Void {
		final source: String = 'class C {\n'
			+ '\tfunction f(a:Int):Int {\n' + '\t\tvar x = a + 1;\n' + '\t\ta = 9;\n' + '\t\treturn x;\n' + '\t}\n' + '}';
		assertRefused(source, 3, 2);
	}

	/**
	 * Refuse when the cursor is on a parameter (not a local var / final):
	 * params are not inlinable bindings.
	 */
	public function testRefuseCursorOnParameter(): Void {
		final source: String = 'class C {\n' + '\tfunction f(a:Int):Int {\n' + '\t\treturn a + a;\n' + '\t}\n' + '}';
		// Line 2 col 12 — the param `a` decl.
		assertRefused(source, 2, 12);
	}

	/**
	 * Refuse when the cursor is on a for-loop iterator: a self-scoped
	 * loop binding is not an inlinable local var / final.
	 */
	public function testRefuseCursorOnForIterator(): Void {
		final source: String = 'class C {\n'
			+ '\tfunction f():Int {\n' + '\t\tvar t = 0;\n' + '\t\tfor (i in 0...10) t += i;\n' + '\t\treturn t;\n' + '\t}\n' + '}';
		// Line 4 col 2 — the `for` decl (iterator `i`).
		assertRefused(source, 4, 2);
	}

	/**
	 * Refuse a binding with no reads: inlining would only delete the decl,
	 * which is a different operation (dead-code removal).
	 */
	public function testRefuseNoReads(): Void {
		final source: String = 'class C {\n' + '\tfunction f():Int {\n' + '\t\tvar x = 5;\n' + '\t\treturn 0;\n' + '\t}\n' + '}';
		assertRefused(source, 3, 2);
	}

	private function assertInline(source: String, line: Int, col: Int, expected: String): Void {
		final result: InlineResult = inlineOf(source, line, col);
		switch result {
			case Ok(text):
				Assert.equals(expected, text);
				// Every accepted rewrite must itself re-parse.
				assertReparses(text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	private function assertRefused(source: String, line: Int, col: Int): Void {
		final result: InlineResult = inlineOf(source, line, col);
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
			Assert.fail('inlined output failed to re-parse: ${exception.message}\n$text');
		}
	}

	private static function inlineOf(source: String, line: Int, col: Int): InlineResult {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final shape: RefShape = plugin.refShape();
		return Inline.inlineVar(source, line, col, plugin, shape);
	}

}
