package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.Rename;
import anyparse.query.Rename.RenameResult;

/**
 * `Rename.rename` — scope-correct, format-preserving symbol rename.
 *
 * Each test renames one binding in the shared fixture and asserts the
 * EXACT rewritten text: only the occurrences that resolve to the
 * targeted binding change; every shadowing same-named binding (field /
 * param / loop var) is left verbatim. The output is also re-parsed by
 * the rename itself (a rewrite that fails to parse is rejected and
 * surfaces as `Err`), so an `Ok` result is guaranteed valid Haxe.
 *
 * The fixture deliberately overloads the name `count` across three
 * distinct bindings — the class field, the function parameter, and the
 * loop iterator — plus the single-binding local `total`. Renaming one
 * must touch exactly that binding's occurrences. Coordinates are the
 * positions `apq refs --decls` prints (the rename interprets the column
 * in the same `Span.lineCol().col - 1` convention).
 */
class RenameSliceTest extends Test {

	private static final FIXTURE: String = 'class C {\n' + '\tvar count:Int = 0;\n' + '\tfunction f(count:Int):Int {\n'
		+ '\t\tvar total = count;\n' + '\t\tfor (count in 0...10) total += count;\n' + '\t\treturn total + this.count;\n' + '\t}\n' + '}';

	/**
	 * Param `count` (decl `3:12`) → `n`: only the param decl and its sole
	 * read (`var total = count`) change. The field (`var count` /
	 * `this.count`) and the loop var (`for (count …) … += count`) keep
	 * `count` — they are separate bindings that shadow / are shadowed.
	 */
	public function testRenameParamTouchesOnlyParamBinding(): Void {
		final expected: String = 'class C {\n' + '\tvar count:Int = 0;\n' + '\tfunction f(n:Int):Int {\n' + '\t\tvar total = n;\n'
			+ '\t\tfor (count in 0...10) total += count;\n' + '\t\treturn total + this.count;\n' + '\t}\n' + '}';
		assertRename(FIXTURE, 3, 12, 'n', expected);
	}

	/**
	 * Loop var `count` (decl `5:2`) → `j`: only the loop iterator decl and
	 * its body read (`total += count`) change. The field and the param
	 * keep `count`.
	 */
	public function testRenameLoopVarTouchesOnlyLoopBinding(): Void {
		final expected: String = 'class C {\n' + '\tvar count:Int = 0;\n' + '\tfunction f(count:Int):Int {\n' + '\t\tvar total = count;\n'
			+ '\t\tfor (j in 0...10) total += j;\n' + '\t\treturn total + this.count;\n' + '\t}\n' + '}';
		assertRename(FIXTURE, 5, 2, 'j', expected);
	}

	/**
	 * Local `total` (decl `4:2`) → `sum`: all three occurrences change —
	 * the decl, the compound-assign write (`total += count`), and the
	 * read (`return total + …`).
	 */
	public function testRenameSingleBindingTouchesAllOccurrences(): Void {
		final expected: String = 'class C {\n' + '\tvar count:Int = 0;\n' + '\tfunction f(count:Int):Int {\n' + '\t\tvar sum = count;\n'
			+ '\t\tfor (count in 0...10) sum += count;\n' + '\t\treturn sum + this.count;\n' + '\t}\n' + '}';
		assertRename(FIXTURE, 4, 2, 'sum', expected);
	}

	/**
	 * Field `count` (decl `2:1`) → `n`: the field decl and the explicit
	 * `this.count` read change. The shadowing param `count` and loop var
	 * `count` stay — they are separate bindings, and the bare `count`
	 * reads inside `f` resolve to those locals, not the field.
	 */
	public function testRenameFieldTouchesDeclAndThisAccess(): Void {
		final expected: String = 'class C {\n' + '\tvar n:Int = 0;\n' + '\tfunction f(count:Int):Int {\n' + '\t\tvar total = count;\n'
			+ '\t\tfor (count in 0...10) total += count;\n' + '\t\treturn total + this.n;\n' + '\t}\n' + '}';
		assertRename(FIXTURE, 2, 1, 'n', expected);
	}

	/**
	 * A position on whitespace (the indent before `var count`) is not on a
	 * renameable identifier: the rename returns `Err` and the source is
	 * never produced as output.
	 */
	public function testPositionOnWhitespaceIsError(): Void {
		// Line 2 column 0 (display convention) maps to the leading tab.
		final result: RenameResult = renameOf(FIXTURE, 2, 0, 'n');
		switch result {
			case Ok(text):
				Assert.fail('expected Err on whitespace position, got Ok:\n$text');
			case Err(_):
				Assert.pass();
		}
	}

	/**
	 * A position on a delimiter (the opening brace of the class body) is
	 * likewise not renameable.
	 */
	public function testPositionOnDelimiterIsError(): Void {
		// Line 1: `class C {` — the `{` sits past the class name.
		final result: RenameResult = renameOf(FIXTURE, 1, 8, 'n');
		switch result {
			case Ok(text):
				Assert.fail('expected Err on delimiter position, got Ok:\n$text');
			case Err(_):
				Assert.pass();
		}
	}

	/** An invalid new name is rejected without touching the source. */
	public function testInvalidNewNameIsError(): Void {
		final result: RenameResult = renameOf(FIXTURE, 3, 12, '1bad');
		switch result {
			case Ok(text):
				Assert.fail('expected Err on invalid new name, got Ok:\n$text');
			case Err(_):
				Assert.pass();
		}
	}

	/**
	 * Rename a `final` METHOD (`FinalModifiedMember`) → `ren`: the decl, the
	 * bare `d(...)` call, and the `this.d(...)` access all change. The query
	 * projection surfaces the method name off the inner
	 * `HxFinalModifierMember.fn`, and `FinalModifiedMember` is a
	 * `FIELD_MEMBER_KINDS` member, so the `this.<name>` augmentation fires
	 * exactly like a plain `FnMember`.
	 */
	public function testRenameFinalMethod(): Void {
		final source: String = 'class C {\n'
			+ '\tfinal function d(a:Int):Void {}\n' + '\tfunction caller():Void {\n' + '\t\td(1);\n' + '\t\tthis.d(2);\n' + '\t}\n' + '}';
		final expected: String = 'class C {\n'
			+ '\tfinal function ren(a:Int):Void {}\n' + '\tfunction caller():Void {\n' + '\t\tren(1);\n' + '\t\tthis.ren(2);\n' + '\t}\n' + '}';
		// Line 2 col 1 — the `final` method decl, as `apq refs --decls` prints.
		assertRename(source, 2, 1, 'ren', expected);
	}

	private function assertRename(source: String, line: Int, col: Int, newName: String, expected: String): Void {
		final result: RenameResult = renameOf(source, line, col, newName);
		switch result {
			case Ok(text):
				Assert.equals(expected, text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	private static function renameOf(source: String, line: Int, col: Int, newName: String): RenameResult {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final shape: RefShape = plugin.refShape();
		return Rename.rename(source, line, col, newName, plugin, shape);
	}

}
