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
 * in the same 1-based convention).
 */
class RenameSliceTest extends Test {

	private static final FIXTURE: String = 'class C {\n\tvar count:Int = 0;\n\tfunction f(count:Int):Int {\n\t\tvar total = count;\n'
		+ '\t\tfor (count in 0...10) total += count;\n' + '\t\treturn total + this.count;\n' + '\t}\n' + '}';

	/**
	 * Param `count` (decl `3:13`) → `n`: only the param decl and its sole
	 * read (`var total = count`) change. The field (`var count` /
	 * `this.count`) and the loop var (`for (count …) … += count`) keep
	 * `count` — they are separate bindings that shadow / are shadowed.
	 */
	public function testRenameParamTouchesOnlyParamBinding(): Void {
		final expected: String = 'class C {\n\tvar count:Int = 0;\n\tfunction f(n:Int):Int {\n\t\tvar total = n;\n'
			+ '\t\tfor (count in 0...10) total += count;\n' + '\t\treturn total + this.count;\n' + '\t}\n' + '}';
		assertRename(FIXTURE, 3, 13, 'n', expected);
	}

	/**
	 * Loop var `count` (decl `5:3`) → `j`: only the loop iterator decl and
	 * its body read (`total += count`) change. The field and the param
	 * keep `count`.
	 */
	public function testRenameLoopVarTouchesOnlyLoopBinding(): Void {
		final expected: String = 'class C {\n\tvar count:Int = 0;\n\tfunction f(count:Int):Int {\n\t\tvar total = count;\n'
			+ '\t\tfor (j in 0...10) total += j;\n' + '\t\treturn total + this.count;\n' + '\t}\n' + '}';
		assertRename(FIXTURE, 5, 3, 'j', expected);
	}

	/**
	 * Local `total` (decl `4:3`) → `sum`: all three occurrences change —
	 * the decl, the compound-assign write (`total += count`), and the
	 * read (`return total + …`).
	 */
	public function testRenameSingleBindingTouchesAllOccurrences(): Void {
		final expected: String = 'class C {\n\tvar count:Int = 0;\n\tfunction f(count:Int):Int {\n\t\tvar sum = count;\n'
			+ '\t\tfor (count in 0...10) sum += count;\n' + '\t\treturn sum + this.count;\n' + '\t}\n' + '}';
		assertRename(FIXTURE, 4, 3, 'sum', expected);
	}

	/**
	 * Field `count` (decl `2:2`) → `n`: the field decl and the explicit
	 * `this.count` read change. The shadowing param `count` and loop var
	 * `count` stay — they are separate bindings, and the bare `count`
	 * reads inside `f` resolve to those locals, not the field.
	 */
	public function testRenameFieldTouchesDeclAndThisAccess(): Void {
		final expected: String = 'class C {\n\tvar n:Int = 0;\n\tfunction f(count:Int):Int {\n\t\tvar total = count;\n'
			+ '\t\tfor (count in 0...10) total += count;\n' + '\t\treturn total + this.n;\n' + '\t}\n' + '}';
		assertRename(FIXTURE, 2, 2, 'n', expected);
	}

	/**
	 * A position on whitespace (the indent before `var count`) is not on a
	 * renameable identifier: the rename returns `Err` and the source is
	 * never produced as output.
	 */
	public function testPositionOnWhitespaceIsError(): Void {
		// Line 2 column 1 maps to the leading tab.
		final result: RenameResult = renameOf(FIXTURE, 2, 1, 'n');
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
		final result: RenameResult = renameOf(FIXTURE, 1, 9, 'n');
		switch result {
			case Ok(text):
				Assert.fail('expected Err on delimiter position, got Ok:\n$text');
			case Err(_):
				Assert.pass();
		}
	}

	/** An invalid new name is rejected without touching the source. */
	public function testInvalidNewNameIsError(): Void {
		final result: RenameResult = renameOf(FIXTURE, 3, 13, '1bad');
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
		final source: String = 'class C {\n\tfinal function d(a:Int):Void {}\n\tfunction caller():Void {\n\t\td(1);\n\t\tthis.d(2);\n'
			+ '\t}\n' + '}';
		final expected: String = 'class C {\n\tfinal function ren(a:Int):Void {}\n\tfunction caller():Void {\n\t\tren(1);\n'
			+ '\t\tthis.ren(2);\n' + '\t}\n' + '}';
		// Line 2 col 2 — the `final` method decl, as `apq refs --decls` prints.
		assertRename(source, 2, 2, 'ren', expected);
	}

	/**
	 * Field in a FINAL class, referenced BARE (no `this.`): renaming the field
	 * must touch the decl AND every bare write/read. Regression for `final class`
	 * projecting as `ClassForm`, which was absent from `scopeKinds` so bare field
	 * references stayed unbound and the rename silently dropped them (the real
	 * `KindEquivalence.canonOf` build break the field-rename autofix surfaced).
	 */
	public function testRenameFieldInFinalClassTouchesBareRefs(): Void {
		final source: String = 'final class C {\n\tfinal v:Int;\n\tpublic function new() {\n\t\tv = 1;\n\t}\n'
			+ '\tpublic function g():Int {\n' + '\t\treturn v;\n' + '\t}\n' + '}';
		final expected: String = 'final class C {\n\tfinal _v:Int;\n\tpublic function new() {\n\t\t_v = 1;\n\t}\n'
			+ '\tpublic function g():Int {\n' + '\t\treturn _v;\n' + '\t}\n' + '}';
		// Line 2 col 2 — the `final v` field decl, as `apq refs --decls` prints.
		assertRename(source, 2, 2, '_v', expected);
	}

	/**
	 * Field -> the name of a ctor PARAM in a scope that reads the field: the
	 * rewrite would produce `x = x;` — legal Haxe (a param self-assignment), so
	 * neither the re-parse nor a typecheck catches it and the field silently stays
	 * unassigned. Must be refused.
	 */
	public function testRenameRefusedWhenParamCapturesFieldOccurrence(): Void {
		final source: String = 'class C {\n\tvar m_x:Int;\n\tfunction new(x:Int) {\n\t\tm_x = x;\n\t}\n}';
		assertRenameErr(source, 2, 2, 'x', 'capture');
	}

	/**
	 * The inverse direction — PARAM -> the name of a field it was disambiguating
	 * (the trailing-underscore idiom): `v = v_` becomes `v = v`, and the field
	 * write silently becomes a param self-assignment. Must be refused.
	 */
	public function testRenameRefusedWhenFieldWriteIsCapturedByParam(): Void {
		final source: String = 'class C {\n\tvar v:Int;\n\tfunction new(v_:Int) {\n\t\tv = v_;\n\t}\n}';
		assertRenameErr(source, 3, 15, 'v', 'capture');
	}

	/**
	 * Field -> the name of a LOCAL declared in a method that reads the field: the
	 * field read is captured by the local, so the rewrite compiles and reads the
	 * wrong value. Must be refused.
	 */
	public function testRenameRefusedWhenLocalCapturesFieldRead(): Void {
		final source: String = 'class C {\n\tvar f:Int;\n\tfunction g():Int {\n\t\tvar t:Int = 1;\n\t\treturn f + t;\n\t}\n}';
		assertRenameErr(source, 2, 2, 't', 'capture');
	}

	/**
	 * The guard must not over-refuse: a same-named binding in a scope that never
	 * touches the renamed one cannot capture anything. `h`'s local `a` is
	 * unrelated to the field, so the rename proceeds — this is what a whole-file
	 * textual scan for the new name would wrongly block.
	 */
	public function testRenameAllowedWhenSameNamedLocalLivesInAnotherScope(): Void {
		final source: String = 'class C {\n\tvar m_a:Int;\n\tfunction g():Int {\n\t\treturn m_a;\n\t}\n'
			+ '\tfunction h():Int {\n\t\tvar a:Int = 1;\n\t\treturn a;\n\t}\n}';
		final expected: String = 'class C {\n\tvar a:Int;\n\tfunction g():Int {\n\t\treturn a;\n\t}\n'
			+ '\tfunction h():Int {\n\t\tvar a:Int = 1;\n\t\treturn a;\n\t}\n}';
		assertRename(source, 2, 2, 'a', expected);
	}

	/**
	 * `--qualify-shadowed` on the param idiom: the field takes its ctor param's
	 * name and the assignment becomes `this.x = x` - the form a human writes when
	 * the param and the member are the same concept.
	 */
	public function testQualifyShadowedRepairsParamCapture(): Void {
		final source: String = 'class C {\n\tvar m_x:Int;\n\tfunction new(x:Int) {\n\t\tm_x = x;\n\t}\n}';
		final expected: String = 'class C {\n\tvar x:Int;\n\tfunction new(x:Int) {\n\t\tthis.x = x;\n\t}\n}';
		assertQualified(source, 2, 2, 'x', expected);
	}

	/**
	 * The flag does NOT rescue a capture by a LOCAL: `return this.t + t` would be
	 * correct but confusing, so a local capture stays a refusal even with the flag.
	 */
	public function testQualifyShadowedStillRefusesLocalCapture(): Void {
		final source: String = 'class C {\n\tvar f:Int;\n\tfunction g():Int {\n\t\tvar t:Int = 1;\n\t\treturn f + t;\n\t}\n}';
		switch renameQualified(source, 2, 2, 't') {
			case Ok(text):
				Assert.fail('expected Err, got Ok:\n$text');
			case Err(message):
				Assert.isTrue(message.indexOf('capture') >= 0, 'message lacks "capture": $message');
		}
	}

	/**
	 * A STATIC function cannot say `this.`, so the flag must refuse there rather
	 * than emit code that parses and fails to typecheck.
	 */
	public function testQualifyShadowedRefusesInStaticFunction(): Void {
		final source: String = 'class C {\n\n\tstatic var m_x:Int;\n\n\tstatic function set(x:Int):Void {\n\t\tm_x = x;\n\t}\n\n}';
		switch renameQualified(source, 3, 9, 'x') {
			case Ok(text):
				Assert.fail('expected Err, got Ok:\n$text');
			case Err(message):
				Assert.isTrue(message.indexOf('capture') >= 0, 'message lacks "capture": $message');
		}
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

	private function assertRenameErr(source: String, line: Int, col: Int, newName: String, fragment: String): Void {
		switch renameOf(source, line, col, newName) {
			case Ok(text):
				Assert.fail('expected Err, got Ok:\n$text');
			case Err(message):
				Assert.isTrue(message.indexOf(fragment) >= 0, 'message lacks "$fragment": $message');
		}
	}

	private function assertQualified(source: String, line: Int, col: Int, newName: String, expected: String): Void {
		switch renameQualified(source, line, col, newName) {
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

	private static function renameQualified(source: String, line: Int, col: Int, newName: String): RenameResult {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return Rename.rename(source, line, col, newName, plugin, plugin.refShape(), true);
	}

}
