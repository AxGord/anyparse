package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.Rename;

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
		+ '\t\tfor (count in 0...10) total += count;\n\t\treturn total + this.count;\n\t}\n}';

	/** A local `v` shadowed by the VALUE binder of a key-value loop — the two are separate bindings. */
	private static final KV_FIXTURE: String =
		'class C {\n\tfunction f(m:Map<String, Int>):Void {\n\t\tvar v:Int = 0;\n\t\tg(v);\n\t\tfor (k => v in m) g(k + v);\n\t}\n}';

	/**
	 * Param `count` (decl `3:13`) → `n`: only the param decl and its sole
	 * read (`var total = count`) change. The field (`var count` /
	 * `this.count`) and the loop var (`for (count …) … += count`) keep
	 * `count` — they are separate bindings that shadow / are shadowed.
	 */
	public function testRenameParamTouchesOnlyParamBinding(): Void {
		final expected: String = 'class C {\n\tvar count:Int = 0;\n\tfunction f(n:Int):Int {\n\t\tvar total = n;\n'
			+ '\t\tfor (count in 0...10) total += count;\n\t\treturn total + this.count;\n\t}\n}';
		assertRename(FIXTURE, 3, 13, 'n', expected);
	}

	/**
	 * Loop var `count` (decl `5:3`) → `j`: only the loop iterator decl and
	 * its body read (`total += count`) change. The field and the param
	 * keep `count`.
	 */
	public function testRenameLoopVarTouchesOnlyLoopBinding(): Void {
		final expected: String = 'class C {\n\tvar count:Int = 0;\n\tfunction f(count:Int):Int {\n\t\tvar total = count;\n'
			+ '\t\tfor (j in 0...10) total += j;\n\t\treturn total + this.count;\n\t}\n}';
		assertRename(FIXTURE, 5, 3, 'j', expected);
	}

	/**
	 * Local `total` (decl `4:3`) → `sum`: all three occurrences change —
	 * the decl, the compound-assign write (`total += count`), and the
	 * read (`return total + …`).
	 */
	public function testRenameSingleBindingTouchesAllOccurrences(): Void {
		final expected: String = 'class C {\n\tvar count:Int = 0;\n\tfunction f(count:Int):Int {\n\t\tvar sum = count;\n'
			+ '\t\tfor (count in 0...10) sum += count;\n\t\treturn sum + this.count;\n\t}\n}';
		assertRename(FIXTURE, 4, 3, 'sum', expected);
	}

	public function testInterpolationReadRenamesAlongToLongerName(): Void {
		// `Refs` indexes a braceless `$name` read, so the rename rewrites it in place — the
		// identifier token inside the `$name` span, never the `$`. `$$path` beside it is an
		// ESCAPED dollar (literal text `$path`), and stays verbatim.
		final src: String = 'class C {\n\tfunction f():String {\n\t\tvar path = \"a\";\n\t\tpath = \"b\" + path;\n'
			+ "\t\treturn 'x/$path and $$path';\n\t}\n}";
		final expected: String = 'class C {\n\tfunction f():String {\n\t\tvar relPath = \"a\";\n\t\trelPath = \"b\" + relPath;\n'
			+ "\t\treturn 'x/$relPath and $$path';\n\t}\n}";
		assertRename(src, 3, 7, 'relPath', expected);
	}

	public function testInterpolationReadRenamesAlongToShorterName(): Void {
		// The same splice with a SHORTER new name: the interpolation occurrence is one more
		// span in the edit list, so the running offset shift must stay right across it.
		final src: String = 'class C {\n\tfunction f():String {\n\t\tvar path = \"a\";\n\t\tpath = \"b\" + path;\n'
			+ "\t\treturn 'x/$path and $$path';\n\t}\n}";
		final expected: String =
			"class C {\n\tfunction f():String {\n\t\tvar p = \"a\";\n\t\tp = \"b\" + p;\n\t\treturn 'x/$p and $$path';\n\t}\n}";
		assertRename(src, 3, 7, 'p', expected);
	}

	public function testDoubleQuotedDollarNameNotRenamed(): Void {
		// A double-quoted literal never interpolates, so `"$path"` is plain text with no read
		// in it — the rename must leave the literal alone.
		final src: String = "class C {\n\tfunction f():String {\n\t\tvar path = \"a\";\n\t\ttrace(path);\n\t\treturn \"x/$path\";\n\t}\n}";
		final expected: String = "class C {\n\tfunction f():String {\n\t\tvar p = \"a\";\n\t\ttrace(p);\n\t\treturn \"x/$path\";\n\t}\n}";
		assertRename(src, 3, 7, 'p', expected);
	}

	public function testEscapeSpelledInterpolationReadRefused(): Void {
		// `\x24nm` decodes to `$nm`, so the projection reports a read — but the raw bytes do
		// not spell `nm` as a token, so no occurrence covers it and the splice would leave the
		// read behind. The one interpolation shape that still refuses.
		final src: String = "class C {\n\tfunction f():String {\n\t\tvar nm = \"a\";\n\t\ttrace(nm);\n\t\treturn 'v \\x24nm';\n\t}\n}";
		assertRenameErr(src, 3, 7, 'q', 'no locatable identifier token');
	}

	public function testEscapeSpelledInterpolationBlockRefused(): Void {
		// An escape-spelled `${ … }` hole is re-projected WITHOUT a parsed expression, so the
		// read of `nm` inside it is invisible to every scan — renaming would part-apply.
		final src: String = "class C {\n\tfunction f():String {\n\t\tvar nm = \"a\";\n\t\ttrace(nm);\n\t\treturn 'v \\x24{nm}';\n\t}\n}";
		assertRenameErr(src, 3, 7, 'q', 'no parsed expression');
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

	/**
	 * A local `function g()` declared twice in one block is the same mis-bind as a duplicated
	 * `var`: every later `g()` stays bound to the FIRST body, so renaming either declaration
	 * rewrites the declaration alone and silently changes which body the calls run. The
	 * position the message carries is the SECOND declaration's.
	 */
	public function testSameBlockLocalFunctionRedeclarationRefused(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tfunction g()\n\t\t\ttrace(1);\n\t\tg();\n'
			+ '\t\tfunction g()\n\t\t\ttrace(2);\n\t\tg();\n\t}\n}';
		assertRenameErr(src, 3, 3, 'h', 'declared more than once in the block at 6:3');
	}

	/** The `inline function` local form of that redeclaration refuses too. */
	public function testSameBlockInlineFunctionRedeclarationRefused(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tinline function g()\n\t\t\ttrace(1);\n\t\tg();\n'
			+ '\t\tinline function g()\n\t\t\ttrace(2);\n\t\tg();\n\t}\n}';
		assertRenameErr(src, 3, 3, 'h', 'declared more than once in the block at 6:3');
	}

	/**
	 * A local function redeclared in a NESTED block is ordinary shadowing — the compiler makes
	 * it a distinct binding and the index resolves it — so the rename proceeds. Asserted on the
	 * whole program, which carries both halves: the outer declaration and BOTH its calls become
	 * `h`, while the nested `function g` and its call stay put.
	 */
	public function testNestedBlockLocalFunctionShadowStillRenames(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tfunction g()\n\t\t\ttrace(1);\n\t\tg();\n\t\t{\n'
			+ '\t\t\tfunction g()\n\t\t\t\ttrace(2);\n\t\t\tg();\n\t\t}\n\t\tg();\n\t}\n}';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tfunction h()\n\t\t\ttrace(1);\n\t\th();\n\t\t{\n'
			+ '\t\t\tfunction g()\n\t\t\t\ttrace(2);\n\t\t\tg();\n\t\t}\n\t\th();\n\t}\n}';
		assertRename(src, 3, 3, 'h', expected);
	}

	/**
	 * Two sibling `for` loops binding the same iterator declare `i` twice under ONE parent, but
	 * each binds into the loop it opens — a self-scoped binder the net must not count, or every
	 * such rename would refuse. The first loop's binder and its use become `j`; the second
	 * loop's `i` is untouched.
	 */
	public function testSiblingLoopBindersStillRename(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar s = 0;\n\t\tfor (i in 0...3)\n\t\t\ts += i;\n'
			+ '\t\tfor (i in 0...2)\n\t\t\ts += i;\n\t\ttrace(s);\n\t}\n}';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tvar s = 0;\n\t\tfor (j in 0...3)\n\t\t\ts += j;\n'
			+ '\t\tfor (i in 0...2)\n\t\t\ts += i;\n\t\ttrace(s);\n\t}\n}';
		assertRename(src, 4, 8, 'j', expected);
	}

	public function testSiblingFunctionInterpReadDoesNotRefuse(): Void {
		// A `$name` read in ANOTHER function is a different binding — the net is
		// scoped to the enclosing function and must not refuse this rename.
		final src: String = "class C {\n\tfunction g():String {\n\t\tvar y = 'a';\n\t\treturn 'y/$y';\n\t}\n\tfunction h():Int {\n"
			+ '\t\tvar y = 2;\n\t\treturn y;\n\t}\n}';
		final expected: String = "class C {\n\tfunction g():String {\n\t\tvar y = 'a';\n\t\treturn 'y/$y';\n\t}\n\tfunction h():Int {\n"
			+ '\t\tvar z = 2;\n\t\treturn z;\n\t}\n}';
		assertRename(src, 7, 7, 'z', expected);
	}

	public function testSiblingFunctionSameNameDeclDoesNotRefuse(): Void {
		// One declaration per block, in two different functions — no redeclaration.
		final src: String = 'class C {\n\tfunction g():Int {\n\t\tvar y = 1;\n\t\treturn y;\n\t}\n\tfunction h():Int {\n\t\tvar y = 2;\n'
			+ '\t\treturn y;\n\t}\n}';
		final expected: String = 'class C {\n\tfunction g():Int {\n\t\tvar y = 1;\n\t\treturn y;\n\t}\n\tfunction h():Int {\n'
			+ '\t\tvar z = 2;\n\t\treturn z;\n\t}\n}';
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
			+ '\t\tfor (count in 0...10) total += count;\n\t\treturn total + this.n;\n\t}\n}';
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
		final source: String =
			'class C {\n\tfinal function d(a:Int):Void {}\n\tfunction caller():Void {\n\t\td(1);\n\t\tthis.d(2);\n\t}\n}';
		final expected: String =
			'class C {\n\tfinal function ren(a:Int):Void {}\n\tfunction caller():Void {\n\t\tren(1);\n\t\tthis.ren(2);\n\t}\n}';
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
		final source: String = 'final class C {\n\tfinal v:Int;\n\tpublic function new() {\n\t\tv = 1;\n\t}\n\tpublic function g():Int {\n'
			+ '\t\treturn v;\n\t}\n}';
		final expected: String = 'final class C {\n\tfinal _v:Int;\n\tpublic function new() {\n\t\t_v = 1;\n\t}\n'
			+ '\tpublic function g():Int {\n\t\treturn _v;\n\t}\n}';
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
		final expected: String =
			'class C {\n\tfunction f(m:Map<String, Int>):Void {\n\t\tvar w:Int = 0;\n\t\tg(w);\n\t\tfor (k => v in m) g(k + v);\n\t}\n}';
		assertRename(KV_FIXTURE, 3, 3, 'w', expected);
	}

	/** The value binder is addressable in its own right: renaming it rewrites the binder and its body reads only. */
	public function testRenameKeyValueBinderTouchesOnlyItsBinding(): Void {
		final expected: String =
			'class C {\n\tfunction f(m:Map<String, Int>):Void {\n\t\tvar v:Int = 0;\n\t\tg(v);\n\t\tfor (k => w in m) g(k + w);\n\t}\n}';
		assertRename(KV_FIXTURE, 5, 13, 'w', expected);
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

	/**
	 * A member of the target name that a PARAMETER already shadows was never what the captured
	 * occurrence read - qualifying it would rebind a param read to the field, which compiles and
	 * means something else. Existence of the member is not the proof; the absence of a shadowing
	 * binding is.
	 */
	public function testQualifyShadowedRefusesMemberShadowedByParam(): Void {
		final source: String =
			'class C {\n\tvar width:Int = 7;\n\tfunction f(width:Int):Void {\n\t\tfinal wIDTH:Int = 1;\n\t\ttrace(width + wIDTH);\n\t}\n}';
		assertQualifyRefused(source, 4, 9, 'width');
	}

	/**
	 * The captured-member repair under a NON-ZERO rename delta: the qualified rewrite's offsets are
	 * the rename's own length change accumulated per preceding occurrence PLUS one prefix per
	 * insertion, and a fixture whose old and new names happen to be the same length proves neither.
	 */
	public function testQualifyShadowedRepairsCaptureUnderNonZeroDelta(): Void {
		final source: String =
			'class C {\n\tvar width:Int = 0;\n\tfunction f():Void {\n\t\tfinal w:Int = 1;\n\t\ttrace(width + w);\n\t}\n}';
		final expected: String =
			'class C {\n\tvar width:Int = 0;\n\tfunction f():Void {\n\t\tfinal width:Int = 1;\n\t\ttrace(this.width + width);\n\t}\n}';
		assertQualified(source, 4, 9, 'width', expected);
	}

	/**
	 * An escape can also extend a `$name` run the PARSER already cut short: `'$n\x6d'` is a
	 * read of `nm`, not of `n`. Renaming `n` must therefore leave the literal alone — the
	 * projection re-reads the decoded text, so the tree names the read `nm`.
	 */
	public function testEscapeExtendedInterpolationNameBindsToTheLongerName(): Void {
		final src: String =
			'class C {\n\tfunction f():String {\n\t\tvar n = "N";\n\t\tvar nm = "NM";\n\t\treturn \'v $$n\\x6d\' + nm;\n\t}\n}';
		final expected: String =
			'class C {\n\tfunction f():String {\n\t\tvar q = "N";\n\t\tvar nm = "NM";\n\t\treturn \'v $$n\\x6d\' + nm;\n\t}\n}';
		assertRename(src, 3, 7, 'q', expected);
	}

	/** The same literal blocks a rename of the name it REALLY reads: its token is not in the raw bytes. */
	public function testEscapeExtendedInterpolationRefusesTheNameItReads(): Void {
		final src: String =
			'class C {\n\tfunction f():String {\n\t\tvar n = "N";\n\t\tvar nm = "NM";\n\t\treturn \'v $$n\\x6d\' + nm;\n\t}\n}';
		assertRenameErr(src, 4, 7, 'q', 'no locatable identifier token');
	}

	/**
	 * A `$count` read bound to a SHADOWING inner binding is none of the outer rename's
	 * business. Matching interpolation reads by NAME refused this; matching them by their
	 * resolved binding does not.
	 */
	public function testInterpolationReadOfShadowingBindingDoesNotRefuse(): Void {
		final src: String = 'class C {\n\tfunction f():String {\n\t\tvar count = 1;\n\t\tvar g = function():String {\n'
			+ '\t\t\tvar count = 2;\n\t\t\treturn \'v $$count\';\n\t\t};\n\t\treturn g() + count;\n\t}\n}';
		final expected: String = 'class C {\n\tfunction f():String {\n\t\tvar total = 1;\n\t\tvar g = function():String {\n'
			+ '\t\t\tvar count = 2;\n\t\t\treturn \'v $$count\';\n\t\t};\n\t\treturn g() + total;\n\t}\n}';
		assertRename(src, 3, 7, 'total', expected);
	}

	/**
	 * A read of `v` inside a nested local `function k` binds to the OUTER `v`, which `f`
	 * declares twice - the shape this guard exists for. Anchored on the CURSOR the sweep was
	 * confined to `k`'s body, which holds no redeclaration, so the rename went through: it
	 * rewrote the trailing `trace(v)` and left `var v = 9` behind, and the program silently
	 * printed the FIRST value there. Anchored on the resolved BINDING it refuses.
	 */
	public function testNestedLocalFunctionReadOfRedeclaredOuterLocalRefused(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar v = 1;\n\t\ttrace(v);\n\t\tfunction k()\n\t\t\ttrace(v);\n'
			+ '\t\tk();\n\t\tvar v = 9;\n\t\ttrace(v);\n\t}\n}';
		assertRenameErr(src, 6, 10, 'w', 'declared more than once in the block at 8:3');
	}

	/**
	 * The same nesting with NO redeclaration renames from the nested cursor. Asserted on the
	 * whole program, which carries both halves: the outer `var w = 1` the cursor never sat on,
	 * and the nested `trace(w)` it did.
	 */
	public function testNestedLocalFunctionReadStillRenamesWithoutRedeclaration(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar v = 1;\n\t\ttrace(v);\n\t\tfunction k()\n\t\t\ttrace(v);\n'
			+ '\t\tk();\n\t\ttrace(v);\n\t}\n}';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tvar w = 1;\n\t\ttrace(w);\n\t\tfunction k()\n\t\t\ttrace(w);\n'
			+ '\t\tk();\n\t\ttrace(w);\n\t}\n}';
		assertRename(src, 6, 10, 'w', expected);
	}

	/**
	 * The nested function's OWN local shadows the duplicated outer name. That binding is owned by
	 * `k`, which declares it once, so the rename proceeds and touches only `k`'s two occurrences.
	 * Asserted on the whole program: `var w = 5` inside `k` next to both surviving outer `var v`.
	 */
	public function testNestedFunctionOwnLocalRenamesDespiteOuterRedeclaration(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar v = 1;\n\t\ttrace(v);\n\t\tfunction k() {\n\t\t\tvar v = 5;\n'
			+ '\t\t\ttrace(v);\n\t\t}\n\t\tk();\n\t\tvar v = 9;\n\t\ttrace(v);\n\t}\n}';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tvar v = 1;\n\t\ttrace(v);\n\t\tfunction k() {\n\t\t\tvar w = 5;\n'
			+ '\t\t\ttrace(w);\n\t\t}\n\t\tk();\n\t\tvar v = 9;\n\t\ttrace(v);\n\t}\n}';
		assertRename(src, 6, 4, 'w', expected);
	}

	/** A LAMBDA body is the same blind spot as a named local function, and refuses the same way. */
	public function testLambdaReadOfRedeclaredOuterLocalRefused(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar v = 1;\n\t\ttrace(v);\n\t\tvar g = () -> trace(v);\n'
			+ '\t\tg();\n\t\tvar v = 9;\n\t\ttrace(v);\n\t}\n}';
		assertRenameErr(src, 5, 23, 'w', 'declared more than once in the block at 7:3');
	}

	/**
	 * A binding no function owns - a FIELD - keeps the cursor's own function as the sweep scope.
	 * A local `b` declared twice in ANOTHER method shadows the field and binds only to itself, so
	 * it says nothing about the field's occurrences; sweeping the whole module for it would refuse
	 * this rename for nothing. Asserted on the whole program: the field and its read become `q`
	 * while both `var b` in `g` stay.
	 */
	public function testFieldReadRenameIgnoresLocalRedeclarationElsewhere(): Void {
		final src: String = 'class C {\n\tvar b:Int = 3;\n\tfunction f():Void {\n\t\ttrace(b);\n\t\tg();\n\t}\n'
			+ '\tfunction g():Void {\n\t\tvar b = 1;\n\t\ttrace(b);\n\t\tvar b = 2;\n\t\ttrace(b);\n\t}\n}';
		final expected: String = 'class C {\n\tvar q:Int = 3;\n\tfunction f():Void {\n\t\ttrace(q);\n\t\tg();\n\t}\n'
			+ '\tfunction g():Void {\n\t\tvar b = 1;\n\t\ttrace(b);\n\t\tvar b = 2;\n\t\ttrace(b);\n\t}\n}';
		assertRename(src, 4, 9, 'q', expected);
	}

	/**
	 * A `#if … #end` region in EXPRESSION position that no structural conditional can
	 * represent is swallowed as a RAW byte span (`CondSpliceExpr`): its interior projects no
	 * nodes at all, so `Refs` never sees the `tag` read inside it and the splice would rewrite
	 * only the two occurrences outside. That is a silent miscompile in the build that defines
	 * the condition - refuse instead, naming the region.
	 */
	public function testExpressionSpliceOccurrenceRefused(): Void {
		final src: String = 'class B {\n\tstatic function f():String {\n\t\tvar tag:String = "a";\n'
			+ "\t\treturn 'x' + #if flash tag + #end 'y' + tag;\n\t}\n}";
		assertRenameErr(src, 3, 7, 'label', 'unparsed conditional-compilation region at 4:16');
	}

	/**
	 * The POSTFIX splice form (`CondSpliceTail` - an infix tail spliced onto a complete
	 * operand) hides an occurrence exactly the same way, and refuses the same way.
	 */
	public function testPostfixSpliceOccurrenceRefused(): Void {
		final src: String = 'class B {\n\tstatic function f():Int {\n\t\tvar tag:Int = 1;\n\t\treturn 2 + 3 #if flash + tag #end;\n\t}\n}';
		assertRenameErr(src, 3, 7, 'label', 'unparsed conditional-compilation region');
	}

	/**
	 * The same STATEMENT-position splice (`CondSpliceStmt` - an if-head whose else branch lives
	 * outside the region) is the same raw swallow, and refuses too. Distinct from the modelled
	 * statement conditional below, which keeps its interior as real nodes.
	 */
	public function testStatementSpliceOccurrenceRefused(): Void {
		final src: String = 'class B {\n\tstatic function f(c:Bool):Void {\n\t\tvar tag:Int = 1;\n'
			+ '\t\t#if flash if (c) trace(tag); else #end trace(tag);\n\t}\n}';
		assertRenameErr(src, 3, 7, 'label', 'unparsed conditional-compilation region');
	}

	/**
	 * An expression-position splice whose raw text CANNOT hold the renamed name proceeds - the
	 * gate is name-scoped, not a blanket refusal of every file carrying a splice. Asserted on
	 * the whole program: both `tag` occurrences move to `label` while the region keeps `other`
	 * byte for byte.
	 */
	public function testUnrelatedExpressionSpliceStillRenames(): Void {
		final src: String = 'class B {\n\tstatic function f(other:String):String {\n\t\tvar tag:String = "a";\n'
			+ "\t\treturn 'x' + #if flash other + #end 'y' + tag;\n\t}\n}";
		final expected: String = 'class B {\n\tstatic function f(other:String):String {\n\t\tvar label:String = "a";\n'
			+ "\t\treturn 'x' + #if flash other + #end 'y' + label;\n\t}\n}";
		assertRename(src, 3, 7, 'label', expected);
	}

	/**
	 * A STATEMENT-position `#if` region the grammar models structurally (`Conditional`, with the
	 * guarded statements as real children) is not a blind spot at all: `Refs` resolves the read
	 * inside it and the rename rewrites it. Must keep renaming - the guard's vocabulary names the
	 * raw-swallow kinds only.
	 */
	public function testModelledStatementConditionalStillRenames(): Void {
		final src: String = 'class C {\n\tstatic function f():Void {\n\t\tvar value:Int = 1;\n\t\t#if flash\n'
			+ '\t\ttrace(value);\n\t\t#end\n\t\ttrace(value);\n\t}\n}';
		final expected: String = 'class C {\n\tstatic function f():Void {\n\t\tvar val:Int = 1;\n\t\t#if flash\n'
			+ '\t\ttrace(val);\n\t\t#end\n\t\ttrace(val);\n\t}\n}';
		assertRename(src, 3, 7, 'val', expected);
	}

	/**
	 * Every splice region ENDS in `#end`, so a byte scan that counts a `#`-prefixed directive
	 * keyword as a mention would refuse every rename of a binding called `end` in any file
	 * carrying one - a blanket refusal wearing a name-scoped disguise. It renames.
	 */
	public function testDirectiveKeywordIsNotAMention(): Void {
		final src: String = 'class B {\n\tstatic function f(other:String):String {\n\t\tvar end:String = "a";\n'
			+ "\t\treturn 'x' + #if flash other + #end 'y' + end;\n\t}\n}";
		final expected: String = 'class B {\n\tstatic function f(other:String):String {\n\t\tvar last:String = "a";\n'
			+ "\t\treturn 'x' + #if flash other + #end 'y' + last;\n\t}\n}";
		assertRename(src, 3, 7, 'last', expected);
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

	/** Assert that the qualifying rename at `line:col` is REFUSED with a capture diagnostic. */
	private function assertQualifyRefused(source: String, line: Int, col: Int, newName: String): Void {
		switch renameQualified(source, line, col, newName) {
			case Ok(text):
				Assert.fail('expected Err, got Ok:\n$text');
			case Err(message):
				Assert.isTrue(message.indexOf('capture') >= 0, 'message lacks "capture": $message');
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
