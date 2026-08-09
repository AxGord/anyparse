package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.TryCatchNullGuard;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `try-catch-null-guard` check: a declaration initialized by a `try E catch (…) null`
 * whose EVERY catch clause yields the bare `null`, immediately followed by
 * `if (x == null) return/throw`, is flagged `Info` and `fix` folds the terminator into every
 * catch clause, deleting the guard. `E` must be non-null BY CONSTRUCTION (a `new T(…)` or an
 * object / array / string literal) — a call, a non-adjacent guard, a non-`null` catch, an
 * inverted or foreign guard and a comment in a dropped region are all left alone.
 */
class TryCatchNullGuardCheckTest extends Test {

	/** The canary shape (`TM-Haxe4/src/crashdumper/SystemData.hx:158`, anonymized). */
	private static final BASIC: String = 'class C {\n\tfunction f():Void {\n'
		+ '\t\tfinal p:Process = try new Process(cmd, args) catch (msg:String) null;\n\t\tif (p == null) return;\n'
		+ '\t\tp.exitCode();\n\t}\n}';

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('try-catch-null-guard'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('try-catch-null-guard'));
		Assert.equals(151, Linter.builtins().length);
	}

	/** DEFAULT OFF: the rule ships opt-in, so a project only sees it after enabling it. */
	public function testDefaultOff(): Void {
		Assert.isTrue(Linter.byId('try-catch-null-guard') is DefaultOff);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testBasicFlagged(): Void {
		final vs: Array<Violation> = violations(BASIC);
		Assert.equals(1, vs.length);
		Assert.equals('try-catch-null-guard', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testFixBasic(): Void {
		final es: Array<{ span: Span, text: String }> = edits(BASIC);
		Assert.equals(1, es.length);
		Assert.equals('final p:Process = try new Process(cmd, args) catch (msg:String) return;', es[0].text);
	}

	/** The declaration keyword is copied VERBATIM — the `var` -> `final` upgrade is `prefer-final`'s job. */
	public function testVarKeywordKept(): Void {
		Assert.equals(
			'var p = try new Process() catch (msg:String) return;',
			one(
				'class C {\n\tfunction f():Void {\n\t\tvar p = try new Process() catch (msg:String) null;\n\t\tif (p == null) return;\n\t}\n}'
			)
		);
	}

	/** The written `:type` rides along with the keyword, `Null<…>` wrapper included (no tightening). */
	public function testNullAnnotationKeptVerbatim(): Void {
		Assert.equals(
			'final p:Null<Process> = try new Process() catch (msg:String) return;',
			one(
				'class C {\n\tfunction f():Void {\n\t\tfinal p:Null<Process> = try new Process() catch (msg:String) null;\n\t\tif (p == null) return;\n\t}\n}'
			)
		);
	}

	/** `if (null == x)` is the same guard written the other way round. */
	public function testReversedPolarityFlagged(): Void {
		Assert.equals(
			'final p = try new Process() catch (msg:String) return;',
			one(
				'class C {\n\tfunction f():Void {\n\t\tfinal p = try new Process() catch (msg:String) null;\n\t\tif (null == p) return;\n\t}\n}'
			)
		);
	}

	public function testThrowTerminatorFlagged(): Void {
		Assert.equals(
			"final p = try new Process() catch (msg:String) throw new Error('no');",
			one(
				"class C {\n\tfunction f():Void {\n\t\tfinal p = try new Process() catch (msg:String) null;\n\t\tif (p == null) throw new Error('no');\n\t}\n}"
			)
		);
	}

	public function testValuedReturnTerminatorFlagged(): Void {
		Assert.equals(
			'final p = try new Process() catch (msg:String) return 0;',
			one(
				'class C {\n\tfunction f():Int {\n\t\tfinal p = try new Process() catch (msg:String) null;\n\t\tif (p == null) return 0;\n\t\treturn 1;\n\t}\n}'
			)
		);
	}

	/** EVERY catch clause takes the terminator, and each header is sliced verbatim. */
	public function testTwoCatchesBothTakeTerminator(): Void {
		Assert.equals(
			'final p = try new Process() catch (m:String) return catch (e:Exception) return;',
			one(
				'class C {\n\tfunction f():Void {\n\t\tfinal p = try new Process() catch (m:String) null catch (e:Exception) null;\n\t\tif (p == null) return;\n\t}\n}'
			)
		);
	}

	/** A braced guard body is the same shape with the block level present; the braces are dropped. */
	public function testBracedGuardBodyFlagged(): Void {
		Assert.equals(
			'final p = try new Process() catch (msg:String) return;',
			one(
				'class C {\n\tfunction f():Void {\n\t\tfinal p = try new Process() catch (msg:String) null;\n\t\tif (p == null) {\n\t\t\treturn;\n\t\t}\n\t}\n}'
			)
		);
	}

	/** The pair is read off the BRANCH-AWARE projection, so a `#if` region's own statement list works. */
	public function testInsideConditionalFlagged(): Void {
		Assert.equals(
			'final p = try new Process() catch (msg:String) return;',
			one(
				'class C {\n\tfunction f():Void {\n\t\t#if sys\n\t\tfinal p = try new Process() catch (msg:String) null;\n\t\tif (p == null) return;\n\t\t#end\n\t}\n}'
			)
		);
	}

	public function testArrayLiteralInitializerFlagged(): Void {
		Assert.equals(
			'final p = try [1, 2] catch (msg:String) return;',
			one('class C {\n\tfunction f():Void {\n\t\tfinal p = try [1, 2] catch (msg:String) null;\n\t\tif (p == null) return;\n\t}\n}')
		);
	}

	public function testObjectLiteralInitializerFlagged(): Void {
		Assert.equals(
			'final p = try {x: 1} catch (msg:String) return;',
			one('class C {\n\tfunction f():Void {\n\t\tfinal p = try {x: 1} catch (msg:String) null;\n\t\tif (p == null) return;\n\t}\n}')
		);
	}

	public function testStringLiteralInitializerFlagged(): Void {
		Assert.equals(
			"final p = try 'a' catch (msg:String) return;",
			one("class C {\n\tfunction f():Void {\n\t\tfinal p = try 'a' catch (msg:String) null;\n\t\tif (p == null) return;\n\t}\n}")
		);
	}

	/**
	 * A CALL initializer is refused: before the collapse a null RESULT also hit the guard, after
	 * it would flow through — the behaviour change the non-null-by-construction gate exists for.
	 */
	public function testCallInitializerNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tfinal p = try open(path) catch (msg:String) null;\n\t\tif (p == null) return;\n\t}\n}'
			).length
		);
	}

	/** An identifier initializer is equally unprovable. */
	public function testIdentInitializerNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tfinal p = try cached catch (msg:String) null;\n\t\tif (p == null) return;\n\t}\n}'
			).length
		);
	}

	/** A catch yielding anything but the bare `null` has a value the guard never saw. */
	public function testNonNullCatchNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tfinal p = try new Process() catch (msg:String) fallback;\n\t\tif (p == null) return;\n\t}\n}'
			).length
		);
	}

	/** One non-`null` clause refuses the whole `try`, the others notwithstanding. */
	public function testSecondCatchNotNullNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tfinal p = try new Process() catch (m:String) null catch (e:Exception) fallback;\n\t\tif (p == null) return;\n\t}\n}'
			).length
		);
	}

	/** A statement in the gap means the guard is not the declaration's immediate successor. */
	public function testNonAdjacentGuardNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tfinal p = try new Process() catch (msg:String) null;\n\t\tlog(p);\n\t\tif (p == null) return;\n\t}\n}'
			).length
		);
	}

	/** A comment in the gap sits in a region the rebuild drops, so the pair is left alone. */
	public function testCommentInGapNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tfinal p = try new Process() catch (msg:String) null;\n\t\t// spawn may fail\n\t\tif (p == null) return;\n\t}\n}'
			).length
		);
	}

	/**
	 * A comment sitting between a `catch (…)` header and its `null` is INSIDE the verbatim-copied
	 * header slice (which runs up to the clause body), so it rides along in front of the
	 * terminator that replaces the `null` — nothing is lost and the site fires.
	 */
	public function testCommentBeforeCatchValueFlagged(): Void {
		Assert.equals(
			'final p = try new Process() catch (msg:String) /* give up */ return;',
			one(
				'class C {\n\tfunction f():Void {\n\t\tfinal p = try new Process() catch (msg:String) /* give up */ null;\n\t\tif (p == null) return;\n\t}\n}'
			)
		);
	}

	/**
	 * A comment in a BRACED guard body sits between the terminator and the `}` — a region the
	 * rebuild drops entirely, so the pair is left alone rather than losing it.
	 */
	public function testCommentInBracedGuardBodyNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tfinal p = try new Process() catch (msg:String) null;\n\t\tif (p == null) {\n\t\t\treturn; // gone\n\t\t}\n\t}\n}'
			).length
		);
	}

	/**
	 * A DANGLING line comment in the copied declaration prefix comments out the `= try …` the
	 * one-line rebuild appends after it.
	 */
	public function testDanglingLineCommentInDeclPrefixNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tfinal p:Process // spawned\n\t\t\t= try new Process() catch (msg:String) null;\n\t\tif (p == null) return;\n\t}\n}'
			).length
		);
	}

	/** A comment INSIDE the copied initializer rides along, so the site still fires. */
	public function testCommentInsideInitializerFlagged(): Void {
		Assert.equals(
			1,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tfinal p = try new Process(/* argv */ cmd) catch (msg:String) null;\n\t\tif (p == null) return;\n\t}\n}'
			).length
		);
	}

	/** A guard with an `else` keeps a branch the collapse has nowhere to put. */
	public function testGuardWithElseNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tfinal p = try new Process() catch (msg:String) null;\n\t\tif (p == null) return; else log(p);\n\t}\n}'
			).length
		);
	}

	/** A guard on a DIFFERENT name is not this declaration's guard. */
	public function testGuardOnOtherNameNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tfinal p = try new Process() catch (msg:String) null;\n\t\tif (q == null) return;\n\t}\n}'
			).length
		);
	}

	/** `!=` is the opposite guard — its body runs on the NON-null path. */
	public function testNotEqGuardNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tfinal p = try new Process() catch (msg:String) null;\n\t\tif (p != null) return;\n\t}\n}'
			).length
		);
	}

	/**
	 * A terminator that READS the declared name becomes a self-reference in the name's own
	 * initializer, which the compiler rejects.
	 */
	public function testTerminatorReferencingNameNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Dynamic {\n\t\tfinal p = try new Process() catch (msg:String) null;\n\t\tif (p == null) return p;\n\t}\n}'
			).length
		);
	}

	/**
	 * A BRACELESS `$x` interpolation is a read of the declared name like any other — and the one
	 * `Refs` does not project, so the self-reference gate needs its structural scan too. Without
	 * it the emitted initializer referred to its own variable (`Unknown identifier : p`).
	 */
	public function testTerminatorInterpolatingNameNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				"class C {\n\tfunction f():Void {\n\t\tfinal p = try new Process() catch (msg:String) null;\n\t\tif (p == null) throw new Error('bad: $p');\n\t}\n}"
			).length
		);
	}

	/** The braced `${x}` form projects a plain identifier, so either scan alone would catch it. */
	public function testTerminatorBracedInterpolatingNameNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				"class C {\n\tfunction f():Void {\n\t\tfinal p = try new Process() catch (msg:String) null;\n\t\tif (p == null) throw new Error('bad: ${p}');\n\t}\n}"
			).length
		);
	}

	/** `break` / `continue` are not terminators here: they mean nothing inside an initializer expression. */
	public function testBreakTerminatorNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tfor (i in 0...2) {\n\t\t\tfinal p = try new Process() catch (msg:String) null;\n\t\t\tif (p == null) break;\n\t\t}\n\t}\n}'
			).length
		);
	}

	/** A multi-declarator list carries its continuation as a SECOND child, so the arity check refuses it. */
	public function testMultiDeclaratorNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tvar p = try new Process() catch (msg:String) null, q = 2;\n\t\tif (p == null) return;\n\t}\n}'
			).length
		);
	}

	/**
	 * A terminator whose RIGHT EDGE is an open try-expression would absorb the `catch (…)` header
	 * the rebuild appends after it — and unlike a value, a `return` cannot be parenthesised. TWO
	 * clauses, so a header really does follow the first terminator: with one clause nothing but
	 * the `;` is appended and the hazard the gate names could not arise.
	 */
	public function testTerminatorEndingInOpenTryNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Int {\n\t\tfinal p = try new Process() catch (m:String) null catch (i:Int) null;\n\t\tif (p == null) return try g() catch (e:String) 0;\n\t}\n}'
			).length
		);
	}

	/**
	 * A comment TRAILING the guard is past the replaced region's end, so it survives the edit
	 * untouched and does not gate the site.
	 */
	public function testTrailingCommentAfterGuardFlagged(): Void {
		Assert.equals(
			'final p = try new Process() catch (msg:String) return;',
			one(
				'class C {\n\tfunction f():Void {\n\t\tfinal p = try new Process() catch (msg:String) null;\n\t\tif (p == null) return; // gave up\n\t}\n}'
			)
		);
	}

	/**
	 * An EMPTY catch yields no `null`, so nothing proves the guarded path. In expression position
	 * the `{}` parses as an empty OBJECT literal rather than a block, so it is the "every clause
	 * is the bare `null`" gate that refuses it -- not a body-shape check.
	 */
	public function testEmptyCatchNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tfinal p = try new Process() catch (msg:String) {};\n\t\tif (p == null) return;\n\t}\n}'
			).length
		);
	}

	/**
	 * The terminator is moved INSIDE the catch clause, so a name that clause BINDS captures it:
	 * `return msg` would stop naming the outer `msg` and start naming the caught exception.
	 */
	public function testTerminatorCapturedByCatchVariableNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				"class C {\n\tfunction f():String {\n\t\tfinal msg:String = 'default';\n\t\tfinal p = try new Process() catch (msg:String) null;\n\t\tif (p == null) return msg;\n\t\treturn 'ok';\n\t}\n}"
			).length
		);
	}

	/** The capture scan reaches a braceless `$name` read inside a single-quoted string too. */
	public function testTerminatorCapturedThroughInterpolationNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				"class C {\n\tfunction f():Void {\n\t\tfinal msg:String = 'default';\n\t\tfinal p = try new Process() catch (msg:String) null;\n\t\tif (p == null) throw new Error('bad: $msg');\n\t}\n}"
			).length
		);
	}

	/** Only the clause that BINDS the name captures it — a different exception variable is no hazard. */
	public function testTerminatorReadingUncapturedNameFlagged(): Void {
		Assert.equals(
			'final p = try new Process() catch (e:String) return msg;',
			one(
				"class C {\n\tfunction f():String {\n\t\tfinal msg:String = 'default';\n\t\tfinal p = try new Process() catch (e:String) null;\n\t\tif (p == null) return msg;\n\t\treturn 'ok';\n\t}\n}"
			)
		);
	}

	/**
	 * A `//` in the terminator's TRIMMED tail (the region between its last token and the `;` the
	 * rebuild strips) would sit in front of the emitted `;`. The span the guard tests is the
	 * EMITTED one, not the node's, so it sees this.
	 */
	public function testLineCommentBeforeTerminatorSemicolonNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tfinal p = try new Process() catch (msg:String) null;\n\t\tif (p == null) return // give up\n\t\t\t;\n\t}\n}'
			).length
		);
	}

	/** A declaration whose initializer is not a `try` at all is outside the rule. */
	public function testPlainDeclarationNotFlagged(): Void {
		Assert.equals(
			0, violations('class C {\n\tfunction f():Void {\n\t\tfinal p = new Process();\n\t\tif (p == null) return;\n\t}\n}').length
		);
	}

	private function violations(src: String): Array<Violation> {
		return new TryCatchNullGuard().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: TryCatchNullGuard = new TryCatchNullGuard();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

	/** The single edit `src` produces, asserted to be exactly one. */
	private function one(src: String): String {
		final es: Array<{ span: Span, text: String }> = edits(src);
		Assert.equals(1, es.length);
		return es.length == 1 ? es[0].text : '';
	}

}
