package unit.query;

import anyparse.query.CanonicalEdit.EditResult;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.InlineMethod;
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
 * the column in the same 1-based convention as `inline`).
 */
class InlineMethodSliceTest extends Test {

	/** The path every fixture is inlined as; a scope entry under it is the fixture's own file. */
	private static inline final FIXTURE_FILE: String = 'Fixture.hx';

	/**
	 * A binary-body method inlined into two call sites: `add(a, b)` with
	 * body `a + b` is substituted at `add(1, 2)` and `add(3, 4)`, each
	 * parenthesised (operator root) in the multiplicative context, and the
	 * declaration is removed.
	 */
	public function testInlineBinaryBothCallSites(): Void {
		final source: String = 'class C {\n\tfunction add(a:Int, b:Int):Int return a + b;\n\tfunction use():Int {\n'
			+ '\t\tvar x = add(1, 2) * add(3, 4);\n\t\treturn x;\n\t}\n}';
		final expected: String = 'class C {\n\tfunction use():Int {\n\t\tvar x = (1 + 2) * (3 + 4);\n\t\treturn x;\n\t}\n}';
		assertInline(source, 2, 11, expected);
	}

	/**
	 * A single-parameter atomic body needs no parentheses: `id(a)` with
	 * body `a` becomes the bare argument — `id(7) + 1` → `7 + 1`.
	 */
	public function testInlineAtomicBodyNoParens(): Void {
		final source: String = 'class C {\n\tfunction id(a:Int):Int return a;\n\tfunction u():Int { return id(7) + 1; }\n}';
		final expected: String = 'class C {\n\tfunction u():Int { return 7 + 1; }\n}';
		assertInline(source, 2, 11, expected);
	}

	/**
	 * A `final` method, called both as `this.dbl(...)` and bare `dbl(...)`:
	 * both forms collect through `CallSites` and inline.
	 */
	public function testInlineFinalMethodThisAndBareCalls(): Void {
		final source: String =
			'class C {\n\tfinal function dbl(a:Int):Int return a * 2;\n\tfunction use():Int { return this.dbl(5) + dbl(6); }\n}';
		final expected: String = 'class C {\n\tfunction use():Int { return (5 * 2) + (6 * 2); }\n}';
		assertInline(source, 2, 17, expected);
	}

	/**
	 * A named local function inlined into its bare calls: the
	 * uniqueness-based local-function collector proves the set complete,
	 * and the declaration statement is removed.
	 */
	public function testInlineLocalFunction(): Void {
		final source: String =
			'class C {\n\tfunction run():Void {\n\t\tfunction greet(n:String) return trace(n);\n\t\tgreet("a");\n\t\tgreet("b");\n\t}\n}';
		final expected: String = 'class C {\n\tfunction run():Void {\n\t\ttrace("a");\n\t\ttrace("b");\n\t}\n}';
		assertInline(source, 3, 13, expected);
	}

	/**
	 * A parameter referenced inside a COMPLEX `${ ... }` interpolation is a
	 * normal `IdentExpr` and is substituted — `'x=${a + 1}'` with arg `7`
	 * becomes `'x=${7 + 1}'`.
	 */
	public function testInlineComplexInterpolationSubstituted(): Void {
		final source: String = 'class C {\n\tfunction cpx(a:Int):String return \'x=$${a + 1}\';\n\tfunction u() { cpx(7); }\n}';
		final expected: String = 'class C {\n\tfunction u() { \'x=$${7 + 1}\'; }\n}';
		assertInline(source, 2, 11, expected);
	}

	/** A multi-statement body cannot be reduced to one expression — refused. */
	public function testRefuseMultiStatementBody(): Void {
		final source: String = 'class C {\n\tfunction f(a:Int):Int { var t = a; return t + 1; }\n\tfunction u() { f(1); }\n}';
		assertRefused(source, 2, 11);
	}

	/** A recursive body would outlive the deleted declaration — refused. */
	public function testRefuseRecursion(): Void {
		final source: String = 'class C {\n\tfunction rec(a:Int):Int return rec(a - 1);\n\tfunction u() { rec(3); }\n}';
		assertRecursionRefused(source, 2, 11);
	}

	/** A self-call through `this` is the same declaration — refused as recursion. */
	public function testRefuseThisRecursion(): Void {
		assertRecursionRefused('class C {\n\tfunction rec(a:Int):Int return this.rec(a - 1);\n\tfunction u() { rec(3); }\n}', 2, 11);
	}

	/** A static calling itself through its own type's name is the same declaration — refused as recursion. */
	@:pin('control')
	@:killer('M-INLINE-METHOD-SELF-RECEIVER')
	public function testRefuseTypeQualifiedRecursion(): Void {
		assertRecursionRefused(
			'class C {\n\tstatic function rec(a:Int):Int return C.rec(a - 1);\n\tstatic function u() { rec(3); }\n}', 2, 18
		);
	}

	/**
	 * A body calling ANOTHER type's static of the same name is no recursion: the receiver resolves to that type, so the call
	 * stays and the declaration, its modifiers with it, is inlined at its own call sites.
	 */
	@:pin('control')
	@:killer('M-INLINE-METHOD-OTHER-RECEIVER')
	public function testInlineSameNamedStaticOfAnotherType(): Void {
		final source: String = 'class Other {\n\tpublic static function path(p:String):String return p + "/";\n}\nclass A {\n'
			+ '\tpublic static function path(p:String):String return Other.path(p);\n\tstatic function u():String return path("x");\n}';
		final expected: String = 'class Other {\n\tpublic static function path(p:String):String return p + "/";\n}\nclass A {\n'
			+ '\tstatic function u():String return Other.path("x");\n}';
		assertInline(source, 5, 25, expected, [{ file: FIXTURE_FILE, source: source }]);
	}

	/** A member another file of the project calls would be deleted under that caller — refused. */
	@:pin('control')
	@:killer('M-INLINE-METHOD-FOREIGN-REF')
	public function testRefuseMemberCalledFromAnotherFile(): Void {
		final source: String = 'class Z {\n\tpublic static function g(a:Int):Int return a + 1;\n\tstatic function u():Int return g(3);\n}';
		final other: String = 'class Y {\n\tstatic function w():Int return Z.g(2);\n}';
		assertRefusedWith(
			source, 2, 25, 'referenced from another file', [{ file: FIXTURE_FILE, source: source }, { file: 'Y.hx', source: other }]
		);
	}

	/** With no project scope to ask, a member carrying modifiers is not proven unreachable from other files — refused. */
	public function testRefuseModifiedMemberWithoutScope(): Void {
		assertRefusedWith(
			'class Z {\n\tpublic static function g(a:Int):Int return a + 1;\n\tstatic function u():Int return g(3);\n}', 2, 25,
			'no project resolution scope'
		);
	}

	/**
	 * A call through the declaring type's name from ANOTHER type of the file would receive a body written in the declaring
	 * type's scope (`k` is unqualified there) — refused.
	 */
	@:pin('control')
	@:killer('M-INLINE-METHOD-OUTSIDE-TYPE')
	public function testRefuseCallOutsideDeclaringType(): Void {
		final source: String = 'class K {\n\tstatic var k:Int = 1;\n\tpublic static function g(a:Int):Int return a + k;\n'
			+ '\tstatic function u():Int return g(3);\n}\nclass Q {\n\tstatic function w():Int return K.g(2);\n}';
		assertRefusedWith(source, 3, 25, 'outside the type declaring', [{ file: FIXTURE_FILE, source: source }]);
	}

	/** The inlined declaration goes with its doc comment; the next member keeps its own. */
	@:pin('control')
	@:killer('M-INLINE-METHOD-KEEPS-DOC')
	public function testInlineRemovesTheDeclarationsDoc(): Void {
		final source: String =
			'class C {\n\t/** doc of g */\n\tfunction g(a:Int):Int return a + 1;\n\n\t/** doc of u */\n\tfunction u():Int return g(3);\n}';
		assertInline(source, 3, 11, 'class C {\n\t/** doc of u */\n\tfunction u():Int return (3 + 1);\n}');
	}

	/** The last member of a type body goes with the blank line that separated it from the member above. */
	@:pin('control')
	@:killer('M-ELEMENT-CUT-BRACE-EDGE')
	public function testInlineLastMemberLeavesNoBlankBeforeTheBrace(): Void {
		assertInline(
			'class C {\n\tfunction u():Int return g(3);\n\n\tfunction g(a:Int):Int return a + 1;\n}', 4, 11,
			'class C {\n\tfunction u():Int return (3 + 1);\n}'
		);
	}

	/**
	 * Another file calling a same-named static through ITS type's name calls that type's member, not this one: the receiver
	 * resolves over the project's sources, so the declaration is inlined and deleted.
	 */
	@:pin('control')
	@:killer('M-INLINE-METHOD-SCOPE-INDEX')
	public function testInlineDespiteAnotherFileCallingASameNamedStatic(): Void {
		final source: String = 'package q;\n\nclass A {\n\tstatic function path(p:String):String\n\t\treturn Other.path(p);\n\n'
			+ '\tstatic function u():String\n\t\treturn path("x");\n}';
		final other: String = 'package q;\n\nclass Other {\n\tpublic static function path(p:String):String\n\t\treturn p + "/";\n}';
		final caller: String = 'package q;\n\nclass B {\n\tstatic function w():String\n\t\treturn Other.path("y");\n}';
		assertInline(source, 4, 18, 'package q;\n\nclass A {\n\tstatic function u():String\n\t\treturn Other.path("x");\n}', [
			{ file: FIXTURE_FILE, source: source },
			{ file: 'Other.hx', source: other },
			{ file: 'B.hx', source: caller }
		]);
	}

	/** A same-named call through a VALUE receiver may be this declaration and is not provable — still refused. */
	public function testRefuseSameNamedCallThroughValue(): Void {
		assertRefusedWith(
			'class C {\n\tfunction f(o:C):Int return 1;\n\tfunction u(o:C):Int return f(o) + o.f(null);\n}', 2, 11,
			'cannot resolve receiver-qualified call'
		);
	}

	/**
	 * A 0-use parameter with a side-effecting argument would silently drop
	 * that side effect — refused.
	 */
	public function testRefuseDroppedImpureArgument(): Void {
		final source: String =
			'class C {\n\tfunction ignore(a:Int):Int return 0;\n\tfunction side():Int return 9;\n\tfunction u() { ignore(side()); }\n}';
		assertRefused(source, 2, 11);
	}

	/** A call omitting an optional argument has the wrong arity — refused. */
	public function testRefuseArityMismatch(): Void {
		final source: String = 'class C {\n\tfunction f(a:Int, ?b:Int):Int return a;\n\tfunction u() { f(1); }\n}';
		assertRefused(source, 2, 11);
	}

	/**
	 * A parameter used via SIMPLE `'$a'` interpolation cannot be replaced
	 * by an arbitrary argument expression — refused.
	 */
	public function testRefuseSimpleInterpolation(): Void {
		final source: String = 'class C {\n\tfunction interp(a:Int):String return \'x=$$a\';\n\tfunction u() { interp(7); }\n}';
		assertRefused(source, 2, 11);
	}

	/**
	 * A parameter re-bound by a multi-declarator CONTINUATION inside `E` shadows it. Until the
	 * shadow vocabulary was read off the grammar, `VarMore` was absent from it and the substitution
	 * rewrote the INNER binding's reads: `a + p` became `a + 3`, which parses and compiles.
	 */
	public function testRefuseShadowByDeclaratorContinuation(): Void {
		final source: String = 'class C {\n\tfunction run():Int {\n\t\tfunction f(p:Int) return { var a = 1, p = 2; a + p; };\n'
			+ '\t\treturn f(3) + f(4);\n\t}\n}';
		assertRefused(source, 3, 12);
	}

	/**
	 * A comprehension loop re-binding the parameter shadows it: substituting through it rewrote the
	 * LOOP variable's read too, so `[for (x in [1]) x]` became `[for (x in [1]) 5]` — a different
	 * value, in a file that still compiles.
	 */
	@:pin('control')
	@:killer('M-INLINE-METHOD-SHADOW-PARTIAL')
	public function testRefuseShadowByComprehensionLoop(): Void {
		assertShadowRefused(
			'class C {\n\tfunction f(x:Int):Int return [for (x in [1]) x][0] + x;\n\tfunction u():Int return f(5);\n}', 2, 11
		);
	}

	/** A `case` capture of the parameter's name shadows it: substituted, the capture became a constant pattern. */
	public function testRefuseShadowByCaseCapture(): Void {
		assertShadowRefused(
			'class C {\n\tfunction f(x:Int):Int return switch 3 { case x: x; } + x;\n\tfunction u():Int return f(6);\n}', 2, 11
		);
	}

	/** A `catch` binder of the parameter's name shadows it inside the handler. */
	public function testRefuseShadowByCatchBinder(): Void {
		assertShadowRefused('class C {\n\tfunction f(x:Int):Int return try x catch (x:Int) x;\n\tfunction u():Int return f(7);\n}', 2, 11);
	}

	/** A cursor not on a function declaration / call is refused. */
	public function testRefuseCursorNotOnFn(): Void {
		final source: String = 'class C {\n\tvar n:Int = 0;\n}';
		assertRefused(source, 2, 6);
	}

	private function assertInline(
		source: String, line: Int, col: Int, expected: String, ?scope: Array<{ file: String, source: String }>
	): Void {
		final result: EditResult = methodOf(source, line, col, scope);
		switch result {
			case Ok(text):
				Assert.equals(expected, text);
				assertReparses(text);
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	private function assertRefused(source: String, line: Int, col: Int): Void {
		final result: EditResult = methodOf(source, line, col);
		switch result {
			case Ok(text):
				Assert.fail('expected Err (refusal), got Ok:\n$text');
			case Err(_):
				Assert.pass();
		}
	}

	/** Refused, and refused AS recursion rather than for a reason that would mask a lost recursion check. */
	private function assertRecursionRefused(source: String, line: Int, col: Int): Void {
		assertRefusedWith(source, line, col, 'is recursive');
	}

	/** Refused with a message carrying `reason`, so a refusal for another cause does not pass. */
	private function assertRefusedWith(
		source: String, line: Int, col: Int, reason: String, ?scope: Array<{ file: String, source: String }>
	): Void {
		switch methodOf(source, line, col, scope) {
			case Ok(text):
				Assert.fail('expected a refusal ($reason), got Ok:\n$text');
			case Err(message):
				Assert.isTrue(message.indexOf(reason) >= 0, message);
		}
	}

	private function assertShadowRefused(source: String, line: Int, col: Int): Void {
		switch methodOf(source, line, col) {
			case Ok(text):
				Assert.fail('expected the shadow refusal, got Ok:\n$text');
			case Err(message):
				Assert.isTrue(message.indexOf('is shadowed') >= 0, 'refused for another reason: $message');
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

	private static function methodOf(source: String, line: Int, col: Int, ?scope: Array<{ file: String, source: String }>): EditResult {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final shape: RefShape = plugin.refShape();
		return InlineMethod.inlineMethod(source, line, col, plugin, shape, FIXTURE_FILE, scope);
	}

}
