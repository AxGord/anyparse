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

	/** A local `v` shadowed by the VALUE binder of a key-value loop — the two are separate bindings. */
	private static final KV_FIXTURE: String = 'class C {\n\tfunction f(m:Map<String, Int>):Void {\n\t\tvar v:Int = 0;\n\t\tg(v);\n'
		+ '\t\tfor (k => v in m) g(k + v);\n' + '\t}\n' + '}';

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

	public function testInterpolationReadRefused(): Void {
		// The resolution index does not yet track `$name` interpolation reads —
		// renaming the binding would silently re-bind them to an outer name (or
		// leave them dangling), so the rename must REFUSE, not partially apply.
		final src: String =
			"class C {\n\tfunction f():String {\n\t\tvar path = \"a\";\n\t\tpath = \"b\" + path;\n\t\treturn 'x/$path';\n\t}\n}";
		switch renameOf(src, 3, 7, 'relPath') {
			case Ok(text):
				Assert.fail('expected Err, got Ok: $text');
			case Err(message):
				Assert.isTrue(message.indexOf('interpolation') != -1, message);
		}
	}

	public function testSameBlockRedeclarationRefused(): Void {
		// Haxe allows re-declaring a name in the same block; the resolution index
		// mis-binds the references that follow the second declaration, so renaming
		// either binding must REFUSE until the scopes are split.
		final src: String = 'class C {\n\tfunction f(v:String):String {\n\t\tfinal path = v + "!";\n\t\ttrace(path);\n'
			+ '\t\t@:nullSafety(Off) var path = v;\n\t\treturn path;\n\t}\n}';
		switch renameOf(src, 5, 21, 'relPath') {
			case Ok(text):
				Assert.fail('expected Err, got Ok: $text');
			case Err(message):
				Assert.isTrue(message.indexOf('declared more than once') != -1, message);
		}
	}

	public function testSiblingFunctionInterpReadDoesNotRefuse(): Void {
		// A `$name` read in ANOTHER function is a different binding — the net is
		// scoped to the enclosing function and must not refuse this rename.
		final src: String =
			"class C {\n\tfunction g():String {\n\t\tvar y = 'a';\n\t\treturn 'y/$y';\n\t}\n\tfunction h():Int {\n\t\tvar y = 2;\n\t\treturn y;\n\t}\n}";
		final expected: String =
			"class C {\n\tfunction g():String {\n\t\tvar y = 'a';\n\t\treturn 'y/$y';\n\t}\n\tfunction h():Int {\n\t\tvar z = 2;\n\t\treturn z;\n\t}\n}";
		assertRename(src, 7, 7, 'z', expected);
	}

	public function testSiblingFunctionSameNameDeclDoesNotRefuse(): Void {
		// One declaration per block, in two different functions — no redeclaration.
		final src: String =
			'class C {\n\tfunction g():Int {\n\t\tvar y = 1;\n\t\treturn y;\n\t}\n\tfunction h():Int {\n\t\tvar y = 2;\n\t\treturn y;\n\t}\n}';
		final expected: String =
			'class C {\n\tfunction g():Int {\n\t\tvar y = 1;\n\t\treturn y;\n\t}\n\tfunction h():Int {\n\t\tvar z = 2;\n\t\treturn z;\n\t}\n}';
		assertRename(src, 7, 7, 'z', expected);
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

	/**
	 * The regression this slice closes, on the rename side. In `for (k => v in m)` the loop
	 * node named only the KEY, so the body's `v` resolved OUTWARD to the enclosing local —
	 * and renaming that local rewrote the loop body's read while leaving the binder alone,
	 * producing `for (k => v in m) g(k + w)`: valid-looking, unparseable-by-meaning, silent.
	 */
	public function testRenameOuterLocalLeavesKeyValueBinderVerbatim(): Void {
		final expected: String = 'class C {\n\tfunction f(m:Map<String, Int>):Void {\n\t\tvar w:Int = 0;\n\t\tg(w);\n'
			+ '\t\tfor (k => v in m) g(k + v);\n' + '\t}\n' + '}';
		assertRename(KV_FIXTURE, 3, 3, 'w', expected);
	}

	/** The value binder is addressable in its own right: renaming it rewrites the binder and its body reads only. */
	public function testRenameKeyValueBinderTouchesOnlyItsBinding(): Void {
		final expected: String = 'class C {\n\tfunction f(m:Map<String, Int>):Void {\n\t\tvar v:Int = 0;\n\t\tg(v);\n'
			+ '\t\tfor (k => w in m) g(k + w);\n' + '\t}\n' + '}';
		assertRename(KV_FIXTURE, 5, 13, 'w', expected);
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


	/**
	 * In a Haxe `abstract`, `this` IS the underlying value, so `this.<member>` looks the name up
	 * on THAT type and never reaches the abstract's own members. The qualification repair must
	 * refuse there even though the shape is otherwise the param idiom - the emitted
	 * `this.run()` fails to compile with `Int has no field run` (verified).
	 */
	public function testQualifyShadowedRefusesInAbstract(): Void {
		final source: String =
			'abstract A(Int) {\n\tfunction m_run():Int return this + 1;\n\tpublic function f(run:Int):Int return m_run() + run;\n}';
		switch renameQualified(source, 2, 11, 'run') {
			case Ok(text):
				Assert.fail('expected Err, got Ok:\n$text');
			case Err(message):
				Assert.isTrue(message.indexOf('capture') >= 0, 'message lacks "capture": $message');
		}
	}

	/**
	 * A STATIC binding is not a field of `this`, whatever the capture site is. The static gate
	 * asked only whether the function CONTAINING the capture is static, so a static member
	 * captured by a param of a NON-static method was qualified to `this.run()` - which fails to
	 * compile with `Cannot access static field run from a class instance` (verified).
	 */
	public function testQualifyShadowedRefusesStaticBindingInInstanceFunction(): Void {
		final source: String =
			'class C {\n\tstatic function m_run():Int return 1;\n\tpublic function f(run:Int):Int {\n\t\treturn m_run() + run;\n\t}\n}';
		switch renameQualified(source, 2, 18, 'run') {
			case Ok(text):
				Assert.fail('expected Err, got Ok:\n$text');
			case Err(message):
				Assert.isTrue(message.indexOf('capture') >= 0, 'message lacks "capture": $message');
		}
	}


	/** Assert that the qualifying rename at `line:col` is REFUSED with a capture diagnostic. */
	private function assertQualifyRefused(source: String, line: Int, col: Int, newName: String): Void {
		switch renameQualified(source, line, col, newName) {
			case Ok(text):
				Assert.fail('expected Err, got Ok:\n$text');
			case Err(message):
				Assert.isTrue(message.indexOf('capture') >= 0, 'message lacks "capture": $message');
		}
	}

	/**
	 * The MIRROR of the param idiom: renaming a LOCAL onto a name the enclosing type's own
	 * INSTANCE member holds captures that member's bare reads. Qualifying them through `this.`
	 * keeps them bound to the member, so the rename proceeds instead of being refused.
	 */
	public function testQualifyShadowedRepairsOwnMemberCapture(): Void {
		final source: String =
			'class C {\n\tvar width:Int = 0;\n\tfunction f():Void {\n\t\tfinal wIDTH:Int = 1;\n\t\ttrace(width + wIDTH);\n\t}\n}';
		final expected: String =
			'class C {\n\tvar width:Int = 0;\n\tfunction f():Void {\n\t\tfinal width:Int = 1;\n\t\ttrace(this.width + width);\n\t}\n}';
		assertQualified(source, 4, 9, 'width', expected);
	}

	/**
	 * A captured STATIC member cannot be named through `this.`, so the local rename stays refused.
	 * The enclosing type's OWN declaration decides the staticness question, ahead of any inherited
	 * member of the same name.
	 */
	public function testQualifyShadowedRefusesCapturedStaticMember(): Void {
		final source: String =
			'class C {\n\tstatic var width:Int = 0;\n\tfunction f():Void {\n\t\tfinal wIDTH:Int = 1;\n\t\ttrace(width + wIDTH);\n\t}\n}';
		assertQualifyRefused(source, 4, 9, 'width');
	}

	/**
	 * Inside a Haxe `abstract` `this` IS the underlying value, so `this.width` would look the name
	 * up on `Int`. The captured-member arm must refuse there exactly as the member-rename arm does.
	 */
	public function testQualifyShadowedRefusesCapturedAbstractMember(): Void {
		final source: String = 'abstract A(Int) {\n\tfunction width():Int return this + 1;\n'
			+ '\tpublic function f():Int {\n\t\tfinal wIDTH:Int = 1;\n\t\treturn width() + wIDTH;\n\t}\n}';
		assertQualifyRefused(source, 4, 9, 'width');
	}

	/**
	 * The captured name resolves to nothing this file declares: an INHERITED member needs the
	 * project resolution index, which the in-file op does not carry, so the rename is refused
	 * rather than qualified on a guess.
	 */
	public function testQualifyShadowedRefusesUnprovableInheritedMember(): Void {
		final source: String = 'class C extends B {\n\tfunction f():Void {\n\t\tfinal wIDTH:Int = 1;\n\t\ttrace(width + wIDTH);\n\t}\n}';
		assertQualifyRefused(source, 3, 9, 'width');
	}

}
