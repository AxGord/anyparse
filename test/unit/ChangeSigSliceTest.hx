package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.ChangeSig;
import anyparse.query.ChangeSig.ChangeSigResult;
import haxe.Exception;

/**
 * `ChangeSig.changeSig` — scope-correct, format-preserving
 * change-signature (parameter reorder), the fourth refactoring operation
 * built on the query engine, the sibling of `Rename` / `Inline` /
 * `ExtractVar`.
 *
 * Each test points a cursor at a function declaration in a fixture, asks
 * for a parameter permutation, and asserts the EXACT rewritten text: the
 * declaration's parameters and every resolvable call site's positional
 * arguments are slot-swapped per the permutation, with the commas and
 * whitespace between slots left in place. Refusal cases assert `Err` and
 * that no source is emitted. Every `Ok` result is additionally re-parsed,
 * so an accepted rewrite is guaranteed valid Haxe.
 *
 * Coordinates are the positions `apq refs` prints (change-sig interprets
 * the column in the same 1-based convention as
 * `rename` / `inline` / `extract-var`).
 */
class ChangeSigSliceTest extends Test {

	/**
	 * Reorder a method's three parameters `2,0,1` (new order c, a, b). The
	 * fixture has a bare `g(...)` call and a `this.g(...)` call; both must
	 * be permuted to match, with commas / spacing intact. A method reorder
	 * carries a non-null cross-file advisory.
	 */
	public function testReorderMethodWithBareAndThisCalls(): Void {
		final source: String = 'class C {\n' + '\tpublic function g(a:Int, ?b:String, c:Int = 5):Void {\n' + '\t\ttrace(a);\n' + '\t}\n'
			+ '\tpublic function caller():Void {\n' + '\t\tg(1, "x", 3);\n' + '\t\tthis.g(7, "y", 9);\n' + '\t}\n' + '}';
		final expected: String = 'class C {\n' + '\tpublic function g(c:Int = 5, a:Int, ?b:String):Void {\n' + '\t\ttrace(a);\n' + '\t}\n'
			+ '\tpublic function caller():Void {\n' + '\t\tg(3, 1, "x");\n' + '\t\tthis.g(9, 7, "y");\n' + '\t}\n' + '}';
		// Line 2 col 9 — the method `g` decl, as `apq refs --decls` prints.
		assertChangeSig(source, 2, 9, '2,0,1', expected, true);
	}

	/**
	 * Reorder a two-parameter named local function `1,0` (swap). The
	 * fixture has one bare call; the decl and the call are swapped. A local
	 * function cannot escape its file, so the advisory is null.
	 */
	public function testReorderLocalFunction(): Void {
		final source: String = 'class C {\n' + '\tpublic function run():Void {\n' + '\t\tfunction add(x:Int, y:Int):Int {\n'
			+ '\t\t\treturn x + y;\n' + '\t\t}\n' + '\t\tvar r = add(1, 2);\n' + '\t}\n' + '}';
		final expected: String = 'class C {\n' + '\tpublic function run():Void {\n' + '\t\tfunction add(y:Int, x:Int):Int {\n'
			+ '\t\t\treturn x + y;\n' + '\t\t}\n' + '\t\tvar r = add(2, 1);\n' + '\t}\n' + '}';
		// Line 3 col 12 — the local function `add` name token.
		assertChangeSig(source, 3, 12, '1,0', expected, false);
	}

	/**
	 * Format preservation: an oddly-spaced (multi-space) parameter list
	 * keeps its exact layout — only the slot contents move, the gaps
	 * between them stay byte-for-byte. The call site's spacing is likewise
	 * preserved.
	 */
	public function testFormatPreservationOddSpacing(): Void {
		final source: String = 'class C {\n' + '\tpublic function g(a:Int,   b:String,   c:Float):Void {}\n'
			+ '\tpublic function caller():Void {\n' + '\t\tg(1,   "x",   2.5);\n' + '\t}\n' + '}';
		final expected: String = 'class C {\n' + '\tpublic function g(c:Float,   a:Int,   b:String):Void {}\n'
			+ '\tpublic function caller():Void {\n' + '\t\tg(2.5,   1,   "x");\n' + '\t}\n' + '}';
		assertChangeSig(source, 2, 9, '2,0,1', expected, true);
	}

	/**
	 * Refuse a receiver-qualified `obj.g(...)` call (non-`this` receiver):
	 * the call cannot be proven to target this method, so the whole reorder
	 * is refused rather than silently leaving its argument order stale.
	 */
	public function testRefuseNonThisReceiverCall(): Void {
		final source: String = 'class C {\n' + '\tpublic function g(a:Int, b:Int):Void {}\n' + '\tpublic function caller(o:C):Void {\n'
			+ '\t\tg(1, 2);\n' + '\t\to.g(3, 4);\n' + '\t}\n' + '}';
		assertRefused(source, 2, 9, '1,0');
	}

	/**
	 * Refuse an arity-mismatched call — a call that omits an optional /
	 * defaulted argument cannot be slot-swapped, so the reorder is refused.
	 */
	public function testRefuseArityMismatchCall(): Void {
		final source: String = 'class C {\n' + '\tpublic function g(a:Int, ?b:Int):Void {}\n' + '\tpublic function caller():Void {\n'
			+ '\t\tg(1, 2);\n' + '\t\tg(7);\n' + '\t}\n' + '}';
		assertRefused(source, 2, 9, '1,0');
	}

	/** Refuse the identity permutation — a no-op. */
	public function testRefuseIdentityPerm(): Void {
		final source: String = 'class C {\n' + '\tpublic function g(a:Int, b:Int, c:Int):Void {}\n' + '}';
		assertRefused(source, 2, 9, '0,1,2');
	}

	/** Refuse a malformed (non-integer) permutation. */
	public function testRefuseMalformedPerm(): Void {
		final source: String = 'class C {\n' + '\tpublic function g(a:Int, b:Int):Void {}\n' + '}';
		assertRefused(source, 2, 9, 'a,b');
	}

	/** Refuse a permutation whose arity does not match the parameter count. */
	public function testRefuseWrongArityPerm(): Void {
		final source: String = 'class C {\n' + '\tpublic function g(a:Int, b:Int, c:Int):Void {}\n' + '}';
		assertRefused(source, 2, 9, '1,0');
	}

	/** Refuse a permutation that repeats an index (not a true permutation). */
	public function testRefuseRepeatedPermIndex(): Void {
		final source: String = 'class C {\n' + '\tpublic function g(a:Int, b:Int, c:Int):Void {}\n' + '}';
		assertRefused(source, 2, 9, '0,0,1');
	}

	/** Refuse a cursor that is not on a function (a plain field). */
	public function testRefuseCursorOnNonFunction(): Void {
		final source: String = 'class C {\n' + '\tvar field:Int = 0;\n' + '}';
		assertRefused(source, 2, 6, '1,0');
	}

	/** Refuse a function with fewer than two parameters — nothing to reorder. */
	public function testRefuseFewerThanTwoParams(): Void {
		final source: String = 'class C {\n' + '\tpublic function g(a:Int):Void {}\n' + '}';
		assertRefused(source, 2, 9, '1,0');
	}

	/**
	 * Refuse a local-function reorder when the name is ambiguous: a second
	 * local function of the same name shadows it in a nested block, so a
	 * bare call cannot be proven to target the first declaration. Refusing
	 * is the only safe outcome — permuting the shadowing call's arguments
	 * would be a silent miscompile.
	 */
	public function testRefuseAmbiguousLocalFunctionName(): Void {
		final source: String = 'class C {\n' + '\tpublic function run():Void {\n' + '\t\tfunction add(x:Int, y:Int):Int return x + y;\n'
			+ '\t\tvar r = add(1, 2);\n' + '\t\t{\n' + '\t\t\tfunction add(p:Int, q:Int):Int return p - q;\n' + '\t\t\tvar z = add(3, 4);\n'
			+ '\t\t}\n' + '\t}\n' + '}';
		assertRefused(source, 3, 12, '1,0');
	}

	/**
	 * Refuse when a method is referenced as a first-class value (not just
	 * called): `var fn = g;` captures `g`, and an indirect `fn(...)` call
	 * keeps the old argument order — change-sig cannot track it, so the
	 * reorder is refused rather than silently misordering the captured call.
	 */
	public function testRefuseMethodReferencedAsValue(): Void {
		final source: String = 'class C {\n' + '\tpublic function g(a:Int, b:Int):Void {}\n' + '\tpublic function caller():Void {\n'
			+ '\t\tg(1, 2);\n' + '\t\tvar fn = g;\n' + '\t}\n' + '}';
		assertRefused(source, 2, 9, '1,0');
	}

	/**
	 * Refuse when a (uniquely named) local function is referenced as a
	 * first-class value: `var fn = add;` captures it, so an indirect call
	 * cannot be tracked and the reorder is refused.
	 */
	public function testRefuseLocalFunctionReferencedAsValue(): Void {
		final source: String = 'class C {\n' + '\tpublic function run():Void {\n' + '\t\tfunction add(x:Int, y:Int):Int return x + y;\n'
			+ '\t\tvar r = add(1, 2);\n' + '\t\tvar fn = add;\n' + '\t}\n' + '}';
		assertRefused(source, 3, 12, '1,0');
	}

	/**
	 * Refuse when a method is captured via `this.g` as a first-class value
	 * (not just called): `var f = this.g;` — change-sig cannot track the
	 * indirect call, so the reorder is refused. (Bare `var f = g;` is
	 * caught by the binding-read guard; this exercises the `this.g` form.)
	 */
	public function testRefuseMethodCapturedViaThis(): Void {
		final source: String = 'class C {\n' + '\tpublic function g(a:Int, b:Int):Void {}\n' + '\tpublic function caller():Void {\n'
			+ '\t\tthis.g(1, 2);\n' + '\t\tvar f = this.g;\n' + '\t}\n' + '}';
		assertRefused(source, 2, 9, '1,0');
	}

	/**
	 * Reorder a `final` METHOD's three parameters `2,0,1` (new order c, a,
	 * b). The query projection surfaces the method name off the inner
	 * `HxFinalModifierMember.fn`, so `Refs` indexes the `FinalModifiedMember`
	 * decl like a plain method: the bare `d(...)` call binds to it and the
	 * `this.d(...)` call matches structurally. A method reorder carries a
	 * non-null cross-file advisory.
	 */
	public function testReorderFinalMethod(): Void {
		final source: String = 'class C {\n' + '\tfinal function d(a:Int, b:String, c:Int):Void {\n' + '\t\ttrace(a);\n' + '\t}\n'
			+ '\tpublic function caller():Void {\n' + '\t\td(1, "x", 3);\n' + '\t\tthis.d(7, "y", 9);\n' + '\t}\n' + '}';
		final expected: String = 'class C {\n' + '\tfinal function d(c:Int, a:Int, b:String):Void {\n' + '\t\ttrace(a);\n' + '\t}\n'
			+ '\tpublic function caller():Void {\n' + '\t\td(3, 1, "x");\n' + '\t\tthis.d(9, 7, "y");\n' + '\t}\n' + '}';
		// Line 2 col 2 — the `final` method decl, as `apq refs --decls` prints.
		assertChangeSig(source, 2, 2, '2,0,1', expected, true);
	}

	private function assertChangeSig(source: String, line: Int, col: Int, perm: String, expected: String, advisoryNonNull: Bool): Void {
		final result: ChangeSigResult = changeSigOf(source, line, col, perm);
		switch result {
			case Ok(text, advisory):
				Assert.equals(expected, text);
				if (advisoryNonNull)
					Assert.notNull(advisory);
				else
					Assert.isNull(advisory);
				// Every accepted rewrite must itself re-parse.
				assertReparses(text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	private function assertRefused(source: String, line: Int, col: Int, perm: String): Void {
		final result: ChangeSigResult = changeSigOf(source, line, col, perm);
		switch result {
			case Ok(text, _):
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
			Assert.fail('reordered output failed to re-parse: ${exception.message}\n$text');
		}
	}

	private static function changeSigOf(source: String, line: Int, col: Int, perm: String): ChangeSigResult {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final shape: RefShape = plugin.refShape();
		return ChangeSig.changeSig(source, line, col, perm, plugin, shape);
	}

}
