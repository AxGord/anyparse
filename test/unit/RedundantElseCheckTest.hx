package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.RedundantElse;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `redundant-else-after-return` check: an `else` whose `if` then-branch
 * always exits (`return` / `throw` / `break` / `continue`) is flagged `Info`,
 * only when the `if` is a direct block statement. `fix` de-nests the else body,
 * skipping only when an else-body local name collides with the enclosing scope
 * (a sibling local or a function parameter) — a same-scope redeclaration.
 */
class RedundantElseCheckTest extends Test {

	public function testElseAfterReturnFlagged(): Void {
		final vs: Array<Violation> = violations('class C {\n\tfunction f():Int {\n\t\tif (a) return 1;\n\t\telse b();\n\t}\n}');
		Assert.equals(1, vs.length);
		Assert.equals('redundant-else-after-return', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this else is redundant — the if branch always exits', vs[0].message);
	}

	public function testNarrowingLapseWithholdsTheDeNest(): Void {
		// An `if / else` chain evaluates the else branch in the state the CONDITION left; a de-nested
		// statement runs after the whole `if`, and Haxe drops a FIELD's non-null narrowing at the first
		// call it cannot see through. `if (p != null) { if (a) { g(); return; } else p.length; }`
		// compiles and its de-nested form does not — the two `Cannot access "length" of a nullable
		// value` errors that rolled a 190-file `--fix` wave back over one file.
		final lapse: String = 'class C {\n\tfunction f(a:Bool):Void {\n\t\tif (p != null) {\n\t\t\tif (a) {\n\t\t\t\tg();\n'
			+ '\t\t\t\treturn;\n\t\t\t} else trace(p.length);\n\t\t}\n\t}\n}';
		Assert.equals(1, violations(lapse).length);
		Assert.equals(0, edits(lapse).length);
		// With nothing in the kept then-branch that can reset it, the narrowing survives the gap and
		// the de-nest goes ahead — verified against the compiler, not assumed.
		final safe: String = 'class C {\n\tfunction f(a:Bool):Void {\n\t\tif (p != null) {\n\t\t\tif (a) return;\n'
			+ '\t\t\telse trace(p.length);\n\t\t}\n\t}\n}';
		Assert.equals(1, violations(safe).length);
		Assert.equals(1, edits(safe).length);
		// And an else body that never touches the guarded subject is unaffected by any of it.
		final other: String = 'class C {\n\tfunction f(a:Bool):Void {\n\t\tif (p != null) {\n\t\t\tif (a) {\n\t\t\t\tg();\n'
			+ '\t\t\t\treturn;\n\t\t\t} else trace(q.length);\n\t\t}\n\t}\n}';
		Assert.equals(1, violations(other).length);
		Assert.equals(1, edits(other).length);
	}

	public function testElseAfterThrowFlagged(): Void {
		Assert.equals(1, violations('class C {\n\tfunction f():Int {\n\t\tif (a) throw "e";\n\t\telse b();\n\t}\n}').length);
	}

	public function testElseAfterBreakFlagged(): Void {
		Assert.equals(
			1, violations('class C {\n\tfunction f():Void {\n\t\twhile (c) {\n\t\t\tif (a) break;\n\t\t\telse b();\n\t\t}\n\t}\n}').length
		);
	}

	public function testThenBlockEndingInReturnFlagged(): Void {
		Assert.equals(
			1,
			violations(
				'class C {\n\tfunction f():Int {\n\t\tif (a) {\n\t\t\tx();\n\t\t\treturn 1;\n\t\t} else {\n\t\t\tb();\n\t\t}\n\t}\n}'
			).length
		);
	}

	public function testNoElseNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Int {\n\t\tif (a) return 1;\n\t\treturn 0;\n\t}\n}').length);
	}

	public function testThenFallsThroughNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (a) b();\n\t\telse c();\n\t}\n}').length);
	}

	public function testInlineNonBlockIfNotFlagged(): Void {
		// The inner `if` is the un-braced body of the outer `if`, not a block
		// statement — de-nesting its else would corrupt the outer's control flow.
		Assert.equals(0, violations('class C {\n\tfunction f():Int {\n\t\tif (outer)\n\t\t\tif (a) return 1; else b();\n\t}\n}').length);
	}

	public function testIfExpressionNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Int {\n\t\tvar x = if (a) 1 else 2;\n\t\treturn x;\n\t}\n}').length);
	}

	public function testElseIfChainFlagsOuterOnly(): Void {
		// The inner `if` sits in the outer's else slot (not a block statement), so
		// only the outer else is flagged; the inner surfaces after a de-nest pass.
		Assert.equals(
			1,
			violations('class C {\n\tfunction f():Int {\n\t\tif (a) return 1;\n\t\telse if (b) return 2;\n\t\telse return 3;\n\t}\n}')
				.length
		);
	}

	public function testFixDeNestsSingleStatementElse(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Int {\n\t\tif (a) return 1;\n\t\telse b();\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('if (a) return 1;\nb();', es[0].text);
	}

	public function testFixDeNestsBlockElse(): Void {
		final es: Array<{ span: Span, text: String }> = edits(
			'class C {\n\tfunction f():Int {\n\t\tif (a) {\n\t\t\treturn 1;\n\t\t} else {\n\t\t\tb();\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, es.length);
		Assert.equals('if (a) {\n\t\t\treturn 1;\n\t\t}\nb();', es[0].text);
	}

	public function testFixEmptyElseDropped(): Void {
		final es: Array<{ span: Span, text: String }> =
			edits('class C {\n\tfunction f():Int {\n\t\tif (a) {\n\t\t\treturn 1;\n\t\t} else {}\n\t}\n}');
		Assert.equals(1, es.length);
		Assert.equals('if (a) {\n\t\t\treturn 1;\n\t\t}', es[0].text);
	}

	public function testFixScopeUnsafeSkipped(): Void {
		// The enclosing block already declares `n` (a sibling of the `if`), so de-nesting the
		// else-body `var n` would redeclare `n` in the same scope — a real collision, skipped.
		final src: String = 'class C {\n\tfunction f():Int {\n\t\tvar n = 0;\n\t\tif (a) {\n\t\t\treturn n;\n\t\t} else {\n'
			+ '\t\t\tvar n = 1;\n\t\t\tb(n);\n\t\t}\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testFixParamCollisionSkipped(): Void {
		// The else-body `var n` collides with the function parameter `n` — de-nesting it into the
		// function-body block would redeclare a parameter name in the same scope, so it is skipped.
		final src: String = 'class C {\n\tfunction f(n:Int):Int {\n\t\tif (a) {\n\t\t\treturn n;\n\t\t} else {\n\t\t\tvar n = 1;\n'
			+ '\t\t\tb(n);\n\t\t}\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	public function testFixLocalNoCollisionDeNested(): Void {
		// The else declares `n`, but nothing named `n` exists in the enclosing scope — de-nesting
		// is safe (no widening collision), so the redundant else IS removed.
		final src: String = 'class C {\n\tfunction f():Int {\n\t\tif (a) {\n\t\t\treturn 1;\n\t\t} else {\n\t\t\tvar n = 1;\n'
			+ '\t\t\treturn b(n);\n\t\t}\n\t}\n}';
		Assert.equals(1, violations(src).length);
		final es: Array<{ span: Span, text: String }> = edits(src);
		Assert.equals(1, es.length);
		Assert.equals('if (a) {\n\t\t\treturn 1;\n\t\t}\nvar n = 1;\n\t\t\treturn b(n);', es[0].text);
	}

	/** An `else` after an exiting `if` inside one `#if` branch is flagged — the branch is its own statement list. */
	public function testElseInsideConditionalBranchFlagged(): Void {
		final src: String = 'class C {\n\tfunction f():Int {\n\t\t#if A\n\t\tif (a) return 1;\n\t\telse b();\n\t\t#end\n\t}\n}';
		Assert.equals(1, violations(src).length);
		final es: Array<{ span: Span, text: String }> = edits(src);
		Assert.equals(1, es.length);
		Assert.equals('if (a) return 1;\nb();', es[0].text);
	}

	/**
	 * The collision gate must see the enclosing FUNCTION's parameters through the `CondBranch`:
	 * `x` is a parameter, so de-nesting the else-body `var x` would redeclare it. Report-only.
	 *
	 * No compiler oracle covers this — the file compiles under `!A` and breaks only under `-D A`.
	 */
	public function testConditionalBranchSeesFunctionParams(): Void {
		final src: String =
			'class C {\n\tfunction f(x:Int):Int {\n\t\t#if A\n\t\tif (c) return 1;\n\t\telse { var x = 2; g(x); }\n\t\t#end\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	/** The gate must also see the enclosing block's own locals, declared BEFORE the `#if`. */
	public function testConditionalBranchSeesBlockLocalBeforeTheRegion(): Void {
		final src: String = 'class C {\n\tfunction f():Int {\n\t\tvar n = 0;\n\t\t#if A\n\t\tif (c) return n;\n'
			+ '\t\telse { var n = 1; b(n); }\n\t\t#end\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	/** … and the ones declared AFTER the `#end`, which are siblings of the region all the same. */
	public function testConditionalBranchSeesBlockLocalAfterTheRegion(): Void {
		final src: String = 'class C {\n\tfunction f():Int {\n\t\t#if A\n\t\tif (c) return 1;\n\t\telse { var n = 1; b(n); }\n\t\t#end\n'
			+ '\t\tvar n = 0;\n\t\treturn n;\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	/** An INTERMEDIATE real block between the function and the region contributes its locals too. */
	public function testConditionalBranchSeesIntermediateBlockLocal(): Void {
		final src: String = 'class C {\n\tfunction f():Int {\n\t\t{\n\t\t\tvar n = 0;\n\t\t\t#if A\n\t\t\tif (c) return n;\n'
			+ '\t\t\telse { var n = 1; b(n); }\n\t\t\t#end\n\t\t}\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	/**
	 * A SIBLING branch's local is not a collision — the two branches are mutually exclusive
	 * configurations and never coexist, so the de-nest goes ahead.
	 */
	public function testSiblingBranchLocalIsNotACollision(): Void {
		final src: String = 'class C {\n\tfunction f():Int {\n\t\t#if A\n\t\tvar n = 0;\n\t\t#else\n\t\tif (c) return 1;\n'
			+ '\t\telse { var n = 1; b(n); }\n\t\t#end\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(1, edits(src).length);
	}

	/** A branch-local name that clashes with nothing de-nests normally. */
	public function testConditionalBranchLocalNoCollisionDeNested(): Void {
		final src: String =
			'class C {\n\tfunction f():Int {\n\t\t#if A\n\t\tif (c) return 1;\n\t\telse { var n = 1; return b(n); }\n\t\t#end\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(1, edits(src).length);
	}

	/**
	 * A local declared in a DIFFERENT `#if` region of the same block is bound in that block's own
	 * frame, so de-nesting a same-named else-body local would shadow it wherever both regions are
	 * active. Report-only.
	 *
	 * No compiler oracle covers this — the file compiles under every single define, and only
	 * `-D A -D B` together changes the returned value.
	 */
	public function testSiblingRegionLocalIsACollision(): Void {
		final src: String = 'class C {\n\tfunction f(c:Bool):Int {\n\t\t#if A\n\t\tvar n = 0;\n\t\t#end\n\t\t#if B\n\t\tif (c) return 1;\n'
			+ '\t\telse {\n\t\t\tvar n = 1;\n\t\t\tb(n);\n\t\t}\n\t\t#end\n\t\t#if A\n\t\treturn n;\n\t\t#end\n\t\treturn 0;\n' + '\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	/** The same collision with no `#if` around the flagged `if` at all — the region-local still binds to the block. */
	public function testRegionLocalCollidesWithAPlainElseBody(): Void {
		final src: String = 'class C {\n\tfunction f(c:Bool):Int {\n\t\t#if A\n\t\tvar n = 0;\n\t\t#end\n\t\tif (c) return 1;\n\t\telse {\n'
			+ '\t\t\tvar n = 1;\n\t\t\tb(n);\n\t\t}\n\t\treturn 0;\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(0, edits(src).length);
	}

	/**
	 * A real `{ … }` block RESETS the inherited names, so an else-body local inside it may legally
	 * shadow the enclosing function's parameter — the de-nest goes ahead. Pins the `scopeKinds`
	 * reset in `collectDeNests`: without it `n` reads as a collision and the fix is withheld.
	 */
	public function testNestedBlockResetsInheritedScope(): Void {
		final src: String = 'class C {\n\tfunction f(n:Int):Int {\n\t\t{\n\t\t\tif (c) return 1;\n\t\t\telse {\n\t\t\t\tvar n = 1;\n'
			+ '\t\t\t\treturn b(n);\n\t\t\t}\n\t\t}\n\t}\n}';
		Assert.equals(1, violations(src).length);
		Assert.equals(1, edits(src).length);
	}

	/**
	 * A comment-only else body carries nothing the de-nest could rebuild from statement spans, so
	 * the fix is withheld and the finding says why.
	 */
	public function testCommentOnlyElseBodyWithheld(): Void {
		final src: String = 'class C {\n\tfunction f():Int {\n\t\tif (a) {\n\t\t\treturn 1;\n\t\t} else {\n\t\t\t// keep me\n\t\t}\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('comment in the else body') != -1);
		Assert.equals(0, edits(src).length);
	}

	/** A comment LEADING the else body sits outside the rebuilt statement run, so the fix is withheld too. */
	public function testLeadingCommentInElseBodyWithheld(): Void {
		final src: String =
			'class C {\n\tfunction f():Int {\n\t\tif (a) {\n\t\t\treturn 1;\n\t\t} else {\n\t\t\t// TODO: later\n\t\t\tb();\n\t\t}\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('comment in the else body') != -1);
		Assert.equals(0, edits(src).length);
	}

	/** A comment BETWEEN two de-nested statements is inside the verbatim run, so it survives and the fix still applies. */
	public function testCommentBetweenDeNestedStatementsIsKept(): Void {
		final src: String = 'class C {\n\tfunction f():Int {\n\t\tif (a) {\n\t\t\treturn 1;\n\t\t} else {\n\t\t\tb();\n'
			+ '\t\t\t// still here\n\t\t\tc();\n\t\t}\n\t}\n}';
		final vs: Array<Violation> = violations(src);
		Assert.equals(1, vs.length);
		Assert.isFalse(vs[0].message.indexOf('comment in the else body') != -1);
		final es: Array<{ span: Span, text: String }> = edits(src);
		Assert.equals(1, es.length);
		Assert.isTrue(es[0].text.indexOf('// still here') != -1);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { ').length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('redundant-else-after-return'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('redundant-else-after-return'));
	}

	private function violations(src: String): Array<Violation> {
		return new RedundantElse().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

	private function edits(src: String): Array<{ span: Span, text: String }> {
		final check: RedundantElse = new RedundantElse();
		return check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin());
	}

}
