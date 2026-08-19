package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.PreferSafeNav;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;
import anyparse.query.RefactorSupport;

/**
 * The `prefer-safe-nav` check: a null guard on an accessor-free SUBJECT — a plain identifier
 * that is a LOCAL / PARAM / `this` / a FIELD the enclosing type declares as a plain `var` /
 * `final`, or a one-step `<ident>.<field>` path whose step the resolution index proves
 * physical — is flagged `Info` and rewritten to safe navigation (only the dot off the
 * subject becomes `?.`). Three arms: the statement form `if (x != null) x.m(...)` →
 * `x?.m(...);`, the ternary form `x == null ? null : x.m(...)` /
 * `x != null ? x.m(...) : null` → `x?.m(...)`, and the assignment form
 * `var r = null; if (x != null) r = x.m(...);` → `var r = x?.m(...);`.
 *
 * A get-accessor property, a member of another kind, a name the enclosing type does not
 * declare, an `extern` host, a path step on a getter or on a type the index cannot resolve,
 * a path deeper than one step, a multi-statement block, an `else` branch, an assignment
 * l-value, a compound condition (statement arm: unless the null-check is the last conjunct;
 * assignment arm: never), an already-safe-nav body and a comment in the removed region are
 * all safe misses; so is a ternary whose guarded branch is not itself the chain (`x.f + 1`)
 * or whose other branch is not `null`, and an assignment arm whose declaration is not
 * null-initialized, not adjacent, multi-declarator, in a different `#if` branch, or
 * referenced by the right-hand side.
 */
class PreferSafeNavCheckTest extends Test {

	public function testLocalFlaggedBare(): Void {
		final vs: Array<Violation> = violations(local('if (x != null) x.command("a");'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-safe-nav', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('this null guard can be safe navigation (?.)', vs[0].message);
	}

	public function testLocalFixedBare(): Void {
		Assert.equals(local('x?.command("a");'), applyFix(local('if (x != null) x.command("a");')));
	}

	public function testBracedSingleStmtFlaggedAndFixed(): Void {
		Assert.equals(1, violations(local('if (x != null) { x.command("b"); }')).length);
		Assert.equals(local('x?.command("b");'), applyFix(local('if (x != null) { x.command("b"); }')));
	}

	public function testChainFixed(): Void {
		Assert.equals(1, violations(local('if (x != null) x.a.b("c");')).length);
		Assert.equals(local('x?.a.b("c");'), applyFix(local('if (x != null) x.a.b("c");')));
	}

	public function testReversedConditionFlaggedAndFixed(): Void {
		Assert.equals(1, violations(local('if (null != x) x.command("r");')).length);
		Assert.equals(local('x?.command("r");'), applyFix(local('if (null != x) x.command("r");')));
	}

	public function testParamReceiverFlagged(): Void {
		final source: String = 'class C {\n\tfunction f(p:Sys):Void {\n\t\tif (p != null) p.command("k");\n\t}\n}';
		final vs: Array<Violation> = violations(source);
		Assert.equals(1, vs.length);
		Assert.isTrue(applyFix(source).indexOf('p?.command("k");') != -1);
	}

	public function testPlainFieldReceiverFlaggedAndFixed(): Void {
		final source: String = 'class C {\n\tvar fld:Sys;\n\tfunction f():Void {\n\t\tif (fld != null) fld.command("z");\n\t}\n}';
		final expected: String = 'class C {\n\tvar fld:Sys;\n\tfunction f():Void {\n\t\tfld?.command("z");\n\t}\n}';
		Assert.equals(1, violations(source).length);
		Assert.equals(expected, applyFix(source));
	}

	public function testFinalFieldReceiverFlagged(): Void {
		Assert.equals(
			1, violations('class C {\n\tfinal fld:Sys;\n\tfunction f():Void {\n\t\tif (fld != null) fld.command("z");\n\t}\n}').length
		);
	}

	public function testSetterOnlyPropertyFieldFlagged(): Void {
		// A `(default, set)` write accessor does not run code on a READ, so the double read is
		// still a no-op — only a get-accessor moves the receiver out of reach.
		Assert.equals(
			1,
			violations('class C {\n\tvar fld(default, set):Sys;\n\tfunction f():Void {\n\t\tif (fld != null) fld.command("z");\n\t}\n}')
				.length
		);
	}

	public function testGetterPropertyFieldNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tvar fld(get, never):Sys;\n\tfunction f():Void {\n\t\tif (fld != null) fld.command("z");\n\t}\n}')
				.length
		);
	}

	public function testMethodMemberReceiverNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tfunction fld():Sys return null;\n\tfunction f():Void {\n\t\tif (fld != null) fld.command("z");\n\t}\n}'
			).length
		);
	}

	public function testUnresolvedReceiverNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tfunction f():Void {\n\t\tif (fld != null) fld.command("z");\n\t}\n}').length);
	}

	public function testExternFieldReceiverNotFlagged(): Void {
		// An extern declaration's `var` is a foreign slot whose read may run host code, so the
		// double-read proof does not hold. `extern inline` is how an extern member legally
		// carries a body, so the fixture is real Haxe and the gate is its only rejector.
		Assert.equals(
			0,
			violations('extern class C {\n\tvar fld:Sys;\n\tinline function f():Void {\n\t\tif (fld != null) fld.command("z");\n\t}\n}')
				.length
		);
	}

	public function testThisQualifiedReceiverFlaggedAndFixed(): Void {
		final source: String = 'class C {\n\tvar fld:Sys;\n\tfunction f():Void {\n\t\tif (this.fld != null) this.fld.command("z");\n\t}\n}';
		final expected: String = 'class C {\n\tvar fld:Sys;\n\tfunction f():Void {\n\t\tthis.fld?.command("z");\n\t}\n}';
		Assert.equals(1, violations(source).length);
		Assert.equals(expected, applyFix(source));
	}

	public function testQualifiedFieldPathFlaggedAndFixed(): Void {
		final source: String = 'class C {\n\tvar fld:P;\n\tfunction f():Void {\n\t\tif (fld.next != null) fld.next.command("z");\n\t}\n}\n'
			+ '\nclass P {\n\tpublic var next:Sys;\n}';
		final expected: String =
			'class C {\n\tvar fld:P;\n\tfunction f():Void {\n\t\tfld.next?.command("z");\n\t}\n}\n\nclass P {\n\tpublic var next:Sys;\n}';
		Assert.equals(1, violations(source).length);
		Assert.equals(expected, applyFix(source));
	}

	public function testQualifiedGetterStepNotFlagged(): Void {
		final source: String = 'class C {\n\tvar fld:P;\n\tfunction f():Void {\n\t\tif (fld.next != null) fld.next.command("z");\n\t}\n}\n'
			+ '\nclass P {\n\tpublic var next(get, never):Sys;\n\n\tfunction get_next():Sys {\n\t\treturn null;\n\t}\n}';
		Assert.equals(0, violations(source).length);
	}

	public function testQualifiedStepOnUnresolvedTypeNotFlagged(): Void {
		// `Absent` reaches no declaration, so the index cannot prove `next` physical.
		final source: String =
			'class C {\n\tvar fld:Absent;\n\tfunction f():Void {\n\t\tif (fld.next != null) fld.next.command("z");\n\t}\n}';
		Assert.equals(0, violations(source).length);
	}

	public function testDeepQualifiedPathNotFlagged(): Void {
		final source: String = 'class C {\n\tvar fld:P;\n\tfunction f():Void {\n\t\tif (fld.mid.next != null) fld.mid.next.command("z");\n'
			+ '\t}\n}\n\nclass P {\n\tpublic var mid:Q;\n}\n\nclass Q {\n\tpublic var next:Sys;\n}';
		Assert.equals(0, violations(source).length);
	}

	public function testQualifiedSubjectInArgumentsNotFlagged(): Void {
		final source: String = 'class C {\n\tvar fld:P;\n\tfunction f():Void {\n\t\tif (fld.next != null) fld.next.command(fld.next);\n'
			+ '\t}\n}\n\nclass P {\n\tpublic var next:Sys;\n}';
		Assert.equals(0, violations(source).length);
	}

	public function testQualifiedTernaryFlaggedAndFixed(): Void {
		final source: String = 'class C {\n\tvar fld:P;\n\tfunction f():Int {\n'
			+ '\t\treturn fld.next == null ? null : fld.next.command("z");\n\t}\n}\n\nclass P {\n\tpublic var next:Sys;\n}';
		Assert.equals(1, violations(source).length);
		Assert.isTrue(applyFix(source).indexOf('return fld.next?.command("z");') != -1);
	}

	public function testThisQualifiedSubjectWithBareMentionNotFlagged(): Void {
		// `this.fld` and `fld` are one narrowed value under two spellings — `this.fld?.use(fld)`
		// would leave the argument back at `Null<T>`.
		final source: String = 'class C {\n\tvar fld:Sys;\n\tfunction f():Void {\n\t\tif (this.fld != null) this.fld.use(fld);\n\t}\n}';
		Assert.equals(0, violations(source).length);
	}

	public function testBareFieldSubjectWithThisMentionNotFlagged(): Void {
		final source: String = 'class C {\n\tvar fld:Sys;\n\tfunction f():Void {\n\t\tif (fld != null) fld.use(this.fld);\n\t}\n}';
		Assert.equals(0, violations(source).length);
	}

	public function testAssignmentArmQualifiedSubjectFixed(): Void {
		// The self-reference gate compares the subject's ROOT, so a step whose name merely
		// coincides with the declared local (`next` / `next`) still folds.
		final source: String = 'class C {\n\tvar fld:P;\n\tfunction f():Void {\n\t\tvar next:Null<Int> = null;\n'
			+ '\t\tif (fld.next != null) next = fld.next.count();\n\t}\n}\n\nclass P {\n\tpublic var next:Sys;\n}';
		Assert.equals(1, violations(source).length);
		Assert.isTrue(fixCanonical(source).indexOf('var next:Null<Int> = fld.next?.count();') != -1);
	}

	public function testAssignmentArmQualifiedSubjectRootIsTargetNotFlagged(): Void {
		// Folding would make the declaration reference itself through the guard's root.
		final source: String = 'class C {\n\tfunction f():Void {\n\t\tvar r:Null<P> = null;\n\t\tif (r.next != null) r = r.next.self();\n'
			+ '\t}\n}\n\nclass P {\n\tpublic var next:P;\n}';
		Assert.equals(0, violations(source).length);
	}

	public function testMultiStatementBlockNotFlagged(): Void {
		Assert.equals(0, violations(local('if (x != null) { x.command("a"); x.command("b"); }')).length);
	}

	public function testElseBranchNotFlagged(): Void {
		Assert.equals(0, violations(local('if (x != null) x.command("a") else x.command("b");')).length);
	}

	public function testAssignmentLValueNotFlagged(): Void {
		Assert.equals(0, violations(local('if (x != null) x.f = 1;')).length);
	}

	public function testGuardFirstConjunctNotFlagged(): Void {
		Assert.equals(0, violations(local('if (x != null && ok) x.command("q");')).length);
	}

	public function testAlreadySafeNavBodyNotFlagged(): Void {
		Assert.equals(0, violations(local('if (x != null) x?.command("s");')).length);
	}

	public function testCommentInGapNotFlagged(): Void {
		Assert.equals(0, violations(local('if (x != null) /* why */ x.command("a");')).length);
	}

	public function testApplyFixByteExact(): Void {
		final input: String = 'class C {\n\tfunction f():Void {\n\t\tvar x:Sys = mk();\n\t\tif (x != null) x.a.b("c");\n\t}\n}';
		final expected: String = 'class C {\n\tfunction f():Void {\n\t\tvar x:Sys = mk();\n\t\tx?.a.b("c");\n\t}\n}';
		Assert.equals(expected, applyFix(input));
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('prefer-safe-nav'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('prefer-safe-nav'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { if (x != null) x.').length);
	}

	public function testParenthesizedConditionFlaggedAndFixed(): Void {
		Assert.equals(1, violations(local('if ((x != null)) x.command("p");')).length);
		Assert.equals(local('x?.command("p");'), applyFix(local('if ((x != null)) x.command("p");')));
	}

	public function testConjunctionGuardLastFlaggedAndFixed(): Void {
		Assert.equals(1, violations(local('if (ok && x != null) x.command("q");')).length);
		Assert.equals(local('if (ok) x?.command("q");'), applyFix(local('if (ok && x != null) x.command("q");')));
	}

	public function testThreeConjunctsGuardLastFixed(): Void {
		Assert.equals(1, violations(local('if (a && b && x != null) x.command("t");')).length);
		Assert.equals(local('if (a && b) x?.command("t");'), applyFix(local('if (a && b && x != null) x.command("t");')));
	}

	public function testConjunctionBracedFixed(): Void {
		Assert.equals(1, violations(local('if (ok && x != null) { x.command("b"); }')).length);
		Assert.equals(local('if (ok) x?.command("b");'), applyFix(local('if (ok && x != null) { x.command("b"); }')));
	}

	public function testOrderSensitiveGuardNotLastNotFlagged(): Void {
		Assert.equals(0, violations(local('if (x != null && x.n > 0) x.command("o");')).length);
	}

	public function testSoleGuardArgumentNotFlagged(): Void {
		Assert.equals(0, violations(local('if (x != null) x.command(x);')).length);
		Assert.equals(local('if (x != null) x.command(x);'), applyFix(local('if (x != null) x.command(x);')));
	}

	public function testConjunctionGuardArgumentNotFlagged(): Void {
		Assert.equals(0, violations(local('if (ok && x != null) x.command(x);')).length);
	}

	public function testGuardInReceiverChainArgNotFlagged(): Void {
		Assert.equals(0, violations(local('if (x != null) x.a(x).b();')).length);
		Assert.equals(local('if (x != null) x.a(x).b();'), applyFix(local('if (x != null) x.a(x).b();')));
	}

	public function testConjunctionArgumentStaysGuarded(): Void {
		final source: String =
			'class C {\n\tfunction f(c:Sys, axis:Sys):Void {\n\t\tif (c != null && axis != null) axis.setScrollPos(c, value, h());\n\t}\n}';
		final expected: String =
			'class C {\n\tfunction f(c:Sys, axis:Sys):Void {\n\t\tif (c != null) axis?.setScrollPos(c, value, h());\n\t}\n}';
		Assert.equals(1, violations(source).length);
		Assert.equals(expected, applyFix(source));
	}

	public function testCommentInDroppedConjunctNotFlagged(): Void {
		Assert.equals(0, violations(local('if (ok && /* c */ x != null) x.command("q");')).length);
	}

	public function testTernaryEqLocalFlaggedAndFixed(): Void {
		final vs: Array<Violation> = violations(local('trace(x == null ? null : x.a.b("c"));'));
		Assert.equals(1, vs.length);
		Assert.equals('prefer-safe-nav', vs[0].rule);
		Assert.equals(local('trace(x?.a.b("c"));'), applyFix(local('trace(x == null ? null : x.a.b("c"));')));
	}

	public function testTernaryNotEqLocalFlaggedAndFixed(): Void {
		Assert.equals(1, violations(local('trace(x != null ? x.f : null);')).length);
		Assert.equals(local('trace(x?.f);'), applyFix(local('trace(x != null ? x.f : null);')));
	}

	public function testTernaryReversedNullOperandFixed(): Void {
		Assert.equals(local('trace(x?.f);'), applyFix(local('trace(null == x ? null : x.f);')));
		Assert.equals(local('trace(x?.f);'), applyFix(local('trace(null != x ? x.f : null);')));
	}

	public function testTernaryAbstractThisReceiverFlaggedAndFixed(): Void {
		final source: String = abstractSelf("return this == null ? null : this.map(p -> '${p.x}').join(',');");
		final expected: String = abstractSelf("return this?.map(p -> '${p.x}').join(',');");
		Assert.equals(1, violations(source).length);
		Assert.equals(expected, applyFix(source));
	}

	public function testTernaryPlainFieldReceiverFlaggedAndFixed(): Void {
		final source: String =
			'class C {\n\tvar fld:Sys;\n\tfunction f():Void {\n\t\ttrace(fld == null ? null : fld.command("z"));\n\t}\n}';
		final expected: String = 'class C {\n\tvar fld:Sys;\n\tfunction f():Void {\n\t\ttrace(fld?.command("z"));\n\t}\n}';
		Assert.equals(1, violations(source).length);
		Assert.equals(expected, applyFix(source));
	}

	public function testTernaryGetterPropertyFieldNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tvar fld(get, never):Sys;\n\tfunction f():Void {\n\t\ttrace(fld == null ? null : fld.command("z"));\n\t}\n}'
			).length
		);
	}

	public function testTernaryNonChainBranchNotFlagged(): Void {
		Assert.equals(0, violations(local('trace(x == null ? null : x.f + 1);')).length);
	}

	public function testTernaryOtherReceiverNotFlagged(): Void {
		Assert.equals(0, violations(local('trace(x == null ? null : y.f);')).length);
	}

	public function testTernaryNonNullBranchNotFlagged(): Void {
		Assert.equals(0, violations(local('trace(x == null ? 0 : x.f);')).length);
	}

	public function testTernaryGuardInArgumentNotFlagged(): Void {
		Assert.equals(0, violations(local('trace(x == null ? null : x.command(x));')).length);
	}

	public function testTernaryAlreadySafeNavNotFlagged(): Void {
		Assert.equals(0, violations(local('trace(x == null ? null : x?.f);')).length);
	}

	public function testTernaryIndexJunctionNotFlagged(): Void {
		Assert.equals(0, violations(local('trace(x == null ? null : x[0].f);')).length);
	}

	public function testTernaryCommentInDroppedRegionNotFlagged(): Void {
		Assert.equals(0, violations(local('trace(x == null ? null /* c */ : x.f);')).length);
	}

	/** The `!=` polarity puts the dropped `null` AFTER the kept branch — the suffix half of the comment gate. */
	public function testTernaryCommentAfterKeptBranchNotFlagged(): Void {
		Assert.equals(0, violations(local('trace(x != null ? x.f /* c */ : null);')).length);
	}

	public function testTernaryMidChainIndexFixed(): Void {
		Assert.equals(1, violations(local('trace(x == null ? null : x.arr[0].c);')).length);
		Assert.equals(local('trace(x?.arr[0].c);'), applyFix(local('trace(x == null ? null : x.arr[0].c);')));
	}

	public function testStatementThisReceiverFixed(): Void {
		final source: String = 'abstract A(Array<P>) {\n\tpublic function f():Void {\n\t\tif (this != null) this.m();\n\t}\n}';
		final expected: String = 'abstract A(Array<P>) {\n\tpublic function f():Void {\n\t\tthis?.m();\n\t}\n}';
		Assert.equals(1, violations(source).length);
		Assert.equals(expected, applyFix(source));
	}

	/** A `cast` on the receiver spine breaks the chain — `(cast x?.a).m()` dereferences null. */
	public function testStatementCastOnSpineNotFlagged(): Void {
		Assert.equals(0, violations(local('if (x != null) (cast x.a).m();')).length);
	}

	/** An operator on the receiver spine breaks the chain — `(x?.a + b).m()` adds to a `Null<T>`. */
	public function testStatementOperatorOnSpineNotFlagged(): Void {
		Assert.equals(0, violations(local('if (x != null) (x.a + b).m();')).length);
	}

	public function testStatementMidChainIndexFixed(): Void {
		Assert.equals(1, violations(local('if (x != null) x.arr[0].b();')).length);
		Assert.equals(local('x?.arr[0].b();'), applyFix(local('if (x != null) x.arr[0].b();')));
	}

	/** A comment between the receiver and its dot would swallow the inserted `?` — reported, left unfixed. */
	public function testCommentBeforeDotNotFixed(): Void {
		final source: String = local('trace(x == null ? null : x /* a.b */ .f);');
		Assert.equals(1, violations(source).length);
		Assert.equals(source, applyFix(source));
	}

	public function testAssignmentArmFlaggedAndFixed(): Void {
		// Byte-exact: the deleted `if` must take its whole line with it, leaving no blank one.
		final source: String = local('var r:Null<Int> = null;\n\t\tif (x != null) r = x.count();');
		Assert.equals(1, violations(source).length);
		Assert.equals('${local('var r:Null<Int> = x?.count();')}\n', fixCanonical(source));
	}

	public function testAssignmentArmChainFixed(): Void {
		final source: String = local('var r:Null<Int> = null;\n\t\tif (x != null) r = x.a.b("c");');
		Assert.equals(1, violations(source).length);
		Assert.equals('${local('var r:Null<Int> = x?.a.b("c");')}\n', fixCanonical(source));
	}

	public function testAssignmentArmMultiDeclaratorNotFlagged(): Void {
		// A continuation declarator makes the declaration node multi-child, so the `= null`
		// initializer is no longer the whole of it and the fold has no single slot to write.
		Assert.equals(0, violations(local('var r:Null<Int> = null, b:Int = 1;\n\t\tif (x != null) r = x.count();')).length);
		Assert.equals(0, violations(local('var b:Int = 1, r:Null<Int> = null;\n\t\tif (x != null) r = x.count();')).length);
	}

	public function testAssignmentArmAcrossConditionalBranchesNotFlagged(): Void {
		// The two branches of a `#if` region project as FLATTENED siblings, so the declaration
		// and the guard LOOK adjacent while no execution ever sees both.
		Assert.equals(
			0,
			violations(
				'class C {\n\tvar r:Null<Int>;\n\tfunction f(x:Null<Sys>):Void {\n\t\t#if js\n\t\tvar r:Null<Int> = null;\n\t\t#else\n'
				+ '\t\tif (x != null) r = x.count();\n\t\t#end\n\t}\n}'
			).length
		);
	}

	public function testAssignmentArmFieldReceiverFixed(): Void {
		final source: String =
			'class C {\n\tvar fld:Sys;\n\tfunction f():Void {\n\t\tvar r:Null<Int> = null;\n\t\tif (fld != null) r = fld.count();\n\t}\n}';
		Assert.equals(1, violations(source).length);
		Assert.isTrue(fixCanonical(source).indexOf('var r:Null<Int> = fld?.count();') != -1);
	}

	public function testAssignmentArmNonNullInitNotFlagged(): Void {
		// Skipping the assignment must be equivalent to assigning null — only a null initializer
		// makes that true; `0` would be silently overwritten by the folded `?.` result.
		Assert.equals(0, violations(local('var r:Null<Int> = 0;\n\t\tif (x != null) r = x.count();')).length);
	}

	public function testAssignmentArmNonAdjacentDeclNotFlagged(): Void {
		Assert.equals(0, violations(local('var r:Null<Int> = null;\n\t\ttrace(1);\n\t\tif (x != null) r = x.count();')).length);
	}

	public function testAssignmentArmOtherTargetNotFlagged(): Void {
		Assert.equals(0, violations(local('var r:Null<Int> = null;\n\t\tif (x != null) q = x.count();')).length);
	}

	public function testAssignmentArmSelfTargetNotFlagged(): Void {
		// `var x = x?.self();` would reference the declaration inside its own initializer.
		Assert.equals(0, violations(local('var x:Null<Sys> = null;\n\t\tif (x != null) x = x.self();')).length);
	}

	public function testAssignmentArmTargetInRightHandSideNotFlagged(): Void {
		Assert.equals(0, violations(local('var r:Null<Int> = null;\n\t\tif (x != null) r = x.count(r);')).length);
	}

	public function testAssignmentArmConjunctionGuardNotFlagged(): Void {
		Assert.equals(0, violations(local('var r:Null<Int> = null;\n\t\tif (ok && x != null) r = x.count();')).length);
	}

	public function testAssignmentArmElseBranchNotFlagged(): Void {
		Assert.equals(0, violations(local('var r:Null<Int> = null;\n\t\tif (x != null) r = x.count() else r = 0;')).length);
	}

	public function testAssignmentArmNonChainRightHandSideNotFlagged(): Void {
		Assert.equals(0, violations(local('var r:Null<Sys> = null;\n\t\tif (x != null) r = x;')).length);
	}

	public function testAssignmentArmCommentInDroppedRegionNotFlagged(): Void {
		Assert.equals(0, violations(local('var r:Null<Int> = null;\n\t\tif (x != null) /* why */ r = x.count();')).length);
	}

	private function fixCanonical(source: String): String {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final check: PreferSafeNav = new PreferSafeNav();
		final edits: Array<{ span: Span, text: String }> = check.fix(source, check.run([{ file: 'C.hx', source: source }], plugin), plugin);
		switch RefactorSupport.canonicalize(source, edits, true, plugin) {
			case Ok(text):
				return text;
			case Err(message):
				Assert.fail('canonicalize Err: $message');
		}
		return '';
	}

	private function local(stmt: String): String {
		return 'class C {\n\tfunction f():Void {\n\t\tvar x:Sys = mk();\n\t\t$stmt\n\t}\n}';
	}

	private function abstractSelf(stmt: String): String {
		return 'abstract A(Array<P>) {\n\t@:to public function toString():String {\n\t\t$stmt\n\t}\n}';
	}

	private function violations(source: String): Array<Violation> {
		return new PreferSafeNav().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function applyFix(source: String): String {
		return CheckFixture.fixedSource(new PreferSafeNav(), source);
	}

}
