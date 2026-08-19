package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferTryExpressionAssignment;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;
import anyparse.check.Linter;

/**
 * The `prefer-try-expression-assignment` check: a statement-position `try` assigning the SAME
 * target with a plain `=` on every path collapses to one try-expression assignment — folding
 * in the target's immediately preceding declaration (the decl arm) or hoisting the target out
 * of the bodies (the l-value arm). Covers the arm boundary, the decl arm's three
 * initializer-drop gates, and the branch-aware `#if` reach.
 */
class PreferTryExpressionAssignmentCheckTest extends Test {

	private static final DECL_PAIR: String = 'class C {\n\tfunction f(nameText:String, argList:Array<String>):Void {\n'
		+ '\t\tvar p:Runner = null;\n\t\ttry {\n\t\t\tp = new Runner(nameText, argList);\n'
		+ '\t\t} catch (msg:String) {\n\t\t\tp = null;\n\t\t}\n\t}\n}';
	private static final STANDALONE: String =
		'class C {\n\tfunction f():Void {\n\t\ttry {\n\t\t\tp = build();\n\t\t} catch (msg:String) {\n\t\t\tp = null;\n\t\t}\n\t}\n}';

	/**
	 * The target is unified by SOURCE TEXT, so a catch whose exception variable shadows it
	 * reads as "the same target" while writing the SHADOW — a value the original discards and
	 * the collapse would promote to the outer assignment. Verified against the compiler: the
	 * original leaves `msg` as `'init'`, the naive collapse leaves it `'err'`.
	 */
	public function testCatchVariableShadowsTargetNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():String {\n\t\tvar msg:String = \'init\';\n\t\ttry {\n\t\t\tmsg = build();\n'
				+ '\t\t} catch (msg:String) {\n\t\t\tmsg = \'err\';\n\t\t}\n\t\treturn msg;\n\t}\n}'
			).length
		);
	}

	/**
	 * A WRITE nested elsewhere in the try (inside a lambda) uses a not-yet-initialized target
	 * once the fold makes the `try` its initializer — `var p:Int = try go(() -> p = 5) …` does
	 * not compile. A read-only gate let this through; the l-value arm, which folds nothing,
	 * still takes the site.
	 */
	public function testNestedWriteInTryFallsBackToLvalueArm(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tfunction f():Void {\n\t\tvar p:Int = 0;\n\t\ttry {\n\t\t\tp = go(() -> p = 5);\n\t\t} catch (e:String) {\n'
			+ '\t\t\tp = 1;\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.equals('this try/catch that assigns the same target in every path can be a single try-expression assignment', vs[0].message);
	}

	/** A LINE comment anywhere in the `try` would comment out what the one-line rebuild appends after it. */
	public function testLineCommentInCatchHeaderNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\ttry {\n\t\t\tp = build();\n\t\t} catch (msg:String) // why\n\t\t{\n'
				+ '\t\t\tp = null;\n\t\t}\n\t}\n}'
			).length
		);
	}

	/** A nested try-expression r-value is parenthesised, or the following `catch` re-parents onto it. */
	public function testNestedTryValueParenthesised(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f():Void {\n\t\ttry {\n\t\t\tp = try build() catch (e1:String) 7;\n\t\t} catch (e2:Int) {\n'
			+ '\t\t\tp = 9;\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('p = try (try build() catch (e1:String) 7) catch (e2:Int) 9;', es[0].text);
	}

	/** Every clause is kept, in source order, with its header verbatim. */
	public function testMultiCatchFixed(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f():Void {\n\t\ttry {\n\t\t\tp = build();\n\t\t} catch (msg:String) {\n\t\t\tp = 1;\n'
			+ '\t\t} catch (other:Exception) {\n\t\t\tp = 2;\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('p = try build() catch (msg:String) 1 catch (other:Exception) 2;', es[0].text);
	}

	/**
	 * Un-braced bodies: the same shape with the block level absent, which `singleBody` normalises
	 * away. (Haxe still projects this as `TryCatchStmt` -- the bodies are statements; the
	 * `TryCatchStmtBare` ctor is for bare EXPRESSION bodies, which no assignment shape reaches.)
	 */
	public function testBareBodyFixed(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Void {\n\t\ttry p = build(); catch (msg:String) p = null;\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('p = try build() catch (msg:String) null;', es[0].text);
	}

	/**
	 * A multi-declarator `var a = 0, p = 0;` cannot be folded (the `= try …` would attach to the
	 * whole list), so the decl arm declines and the l-value arm, which folds nothing, takes it.
	 */
	public function testMultiDeclaratorFallsBackToLvalueArm(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tfunction f():Void {\n\t\tvar a:Int = 0, p:Int = 0;\n\t\ttry {\n\t\t\tp = build();\n\t\t} catch (msg:String) {\n'
			+ '\t\t\tp = 1;\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.equals('this try/catch that assigns the same target in every path can be a single try-expression assignment', vs[0].message);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-try-expression-assignment'));
		Assert.isTrue([for (c in Linter.builtins()) c.id()].contains('prefer-try-expression-assignment'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testDeclPairFlagged(): Void {
		final vs: Array<Violation> = violations(DECL_PAIR);
		Assert.equals(1, vs.length);
		Assert.equals('prefer-try-expression-assignment', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this declaration and its following try/catch assignment can be a single try-expression assignment', vs[0].message);
	}

	/** The `var` keyword survives — the `final` upgrade is `prefer-final`'s job in the fixed point. */
	public function testFixDeclPairKeepsVarAndType(): Void {
		final es: Array<{ span: Span, text: String }> = edits(DECL_PAIR);
		Assert.equals(1, es.length);
		Assert.equals('var p:Runner = try new Runner(nameText, argList) catch (msg:String) null;', es[0].text);
	}

	/**
	 * The TM fixture sits inside `#if sys`, where the declaration and the `try` are children of
	 * a conditional node rather than of a block — invisible to a plain-tree adjacency scan.
	 */
	public function testDeclPairInsideConditionalFixed(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f(nameText:String, argList:Array<String>):Void {\n\t\t#if sys\n\t\tvar p:Runner = null;\n\t\ttry {\n'
			+ '\t\t\tp = new Runner(nameText, argList);\n\t\t} catch (msg:String) {\n\t\t\tp = null;\n\t\t}\n\t\t#end\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('var p:Runner = try new Runner(nameText, argList) catch (msg:String) null;', es[0].text);
	}

	public function testBareDeclarationPairFixed(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f():Void {\n\t\tvar p:Runner;\n\t\ttry {\n\t\t\tp = build();\n\t\t} catch (msg:String) {\n'
			+ '\t\t\tp = null;\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('var p:Runner = try build() catch (msg:String) null;', es[0].text);
	}

	/** No preceding declaration: the l-value arm hoists the target and drops nothing. */
	public function testStandaloneFlagged(): Void {
		final vs: Array<Violation> = violations(STANDALONE);
		Assert.equals(1, vs.length);
		Assert.equals('this try/catch that assigns the same target in every path can be a single try-expression assignment', vs[0].message);
	}

	public function testFixStandalone(): Void {
		final es: Array<{ span: Span, text: String }> = edits(STANDALONE);
		Assert.equals(1, es.length);
		Assert.equals('p = try build() catch (msg:String) null;', es[0].text);
	}

	public function testFieldAccessTargetFixed(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f():Void {\n\t\ttry {\n\t\t\tthis.runner = build();\n\t\t} catch (msg:String) {\n'
			+ '\t\t\tthis.runner = null;\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('this.runner = try build() catch (msg:String) null;', es[0].text);
	}

	/** An impure receiver would move from after the guarded work to before it. */
	public function testImpureReceiverNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\ttry {\n\t\t\thost().runner = build();\n\t\t} catch (msg:String) {\n'
				+ '\t\t\thost().runner = null;\n\t\t}\n\t}\n}'
			).length
		);
	}

	/**
	 * A statement between the declaration and the `try` would be reordered by the fold, so the
	 * decl arm declines — and the l-value arm, which drops nothing, takes the site instead.
	 */
	public function testStatementBetweenFallsBackToLvalueArm(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tfunction f():Void {\n\t\tvar p:Runner = null;\n\t\tprepare();\n\t\ttry {\n\t\t\tp = build();\n'
			+ '\t\t} catch (msg:String) {\n\t\t\tp = null;\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.equals('this try/catch that assigns the same target in every path can be a single try-expression assignment', vs[0].message);
	}

	/** Dropping an impure initializer would change what runs, so the decl arm declines. */
	public function testImpureInitializerFallsBackToLvalueArm(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tfunction f():Void {\n\t\tvar p:Runner = spawn();\n\t\ttry {\n\t\t\tp = build();\n\t\t} catch (msg:String) {\n'
			+ '\t\t\tp = null;\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.equals('this try/catch that assigns the same target in every path can be a single try-expression assignment', vs[0].message);
	}

	/** After the fold `p` would reference itself in its own initializer, which the compiler rejects. */
	public function testTargetReadInsideTryFallsBackToLvalueArm(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tfunction f():Void {\n\t\tvar p:Int = 0;\n\t\ttry {\n\t\t\tp = build();\n\t\t} catch (msg:String) {\n'
			+ '\t\t\tp = p + 1;\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.equals('this try/catch that assigns the same target in every path can be a single try-expression assignment', vs[0].message);
	}

	/**
	 * Inside an enclosing `try` an escaping exception is observable by that handler, so the
	 * dropped initializer is no longer provably dead — the decl arm declines and the l-value arm
	 * takes over.
	 */
	public function testInsideEnclosingTryFallsBackToLvalueArm(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tfunction f():Void {\n\t\ttry {\n\t\t\tvar p:Runner = null;\n\t\t\ttry {\n\t\t\t\tp = build();\n'
			+ '\t\t\t} catch (msg:String) {\n\t\t\t\tp = null;\n\t\t\t}\n\t\t} catch (outer:Exception) {\n\t\t\tlog(outer);\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.equals('this try/catch that assigns the same target in every path can be a single try-expression assignment', vs[0].message);
	}

	public function testCompoundAssignmentNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\tvar p:Int = 0;\n\t\ttry {\n\t\t\tp += build();\n\t\t} catch (msg:String) {\n'
				+ '\t\t\tp += 1;\n\t\t}\n\t}\n}'
			).length
		);
	}

	public function testDifferentTargetsNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\ttry {\n\t\t\tp = build();\n\t\t} catch (msg:String) {\n\t\t\tq = null;\n\t\t}\n'
				+ '\t}\n}'
			).length
		);
	}

	public function testEmptyCatchNotFlagged(): Void {
		Assert.equals(
			0, violations('class C {\n\tfunction f():Void {\n\t\ttry {\n\t\t\tp = build();\n\t\t} catch (msg:String) {}\n\t}\n}').length
		);
	}

	public function testRethrowingCatchNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\ttry {\n\t\t\tp = build();\n\t\t} catch (msg:String) {\n\t\t\tthrow msg;\n\t\t}\n'
				+ '\t}\n}'
			).length
		);
	}

	/**
	 * A deliberately grouped body is never collapsed. The assignment comes FIRST here so the
	 * single-statement gate is what rejects it -- with the extra statement first, the r-value
	 * gate rejects the clause before that gate is reached.
	 */
	public function testMultiStatementCatchNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\ttry {\n\t\t\tp = build();\n\t\t} catch (msg:String) {\n\t\t\tp = null;\n'
				+ '\t\t\tlog(msg);\n\t\t}\n\t}\n}'
			).length
		);
	}

	/** The `try` keyword, the braces and every `p =` prefix are dropped, so a comment there fails the guard closed. */
	public function testCommentInDroppedRegionNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction f():Void {\n\t\ttry {\n\t\t\t/* build it */\n\t\t\tp = build();\n\t\t} catch (msg:String) {\n'
				+ '\t\t\tp = null;\n\t\t}\n\t}\n}'
			).length
		);
	}

	/** A comment INSIDE a copied r-value rides along, so the site still fires. */
	public function testCommentInsideRvalueFlagged(): Void {
		Assert.equals(
			1,
			violations(
				'class C {\n\tfunction f():Void {\n\t\ttry {\n\t\t\tp = build(/* raw */ text);\n\t\t} catch (msg:String) {\n'
				+ '\t\t\tp = null;\n\t\t}\n\t}\n}'
			).length
		);
	}

	private function violations(src: String): Array<Violation> {
		return new PreferTryExpressionAssignment().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: PreferTryExpressionAssignment = new PreferTryExpressionAssignment();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

}
