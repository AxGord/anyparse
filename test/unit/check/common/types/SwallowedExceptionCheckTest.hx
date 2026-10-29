package unit.check.common.types;

import anyparse.check.Severity;
import anyparse.check.common.types.SwallowedException;

/**
 * The `swallowed-exception` check: a `catch` whose non-empty body ignores the
 * caught exception (neither references the variable nor rethrows) is flagged
 * `Warning`. A handler that uses the variable, rethrows, has an empty body
 * (left to `empty-block`), or names the variable `_` (intentional discard) is
 * not flagged. Report-only — `fix` yields no edits.
 */
class SwallowedExceptionCheckTest extends Test {

	public function testSwallowingCatchFlagged(): Void {
		final vs: Array<Violation> = violations(
			'class C {\n\tpublic function f():Void {\n\t\ttry { g(); } catch (e:Exception) {\n\t\t\ttrace("oops");\n\t\t}\n\t}\n}'
		);
		Assert.equals(1, vs.length);
		Assert.equals('swallowed-exception', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('exception \'e\' is caught but ignored', vs[0].message);
	}

	public function testRecoveryReturnNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tpublic function f():Int {\n\t\ttry { return g(); } catch (e:Exception) {\n\t\t\treturn 0;\n\t\t}\n\t}\n}'
			).length
		);
	}

	public function testBareReturnNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tpublic function f():Void {\n\t\ttry { g(); } catch (e:Exception) {\n\t\t\tcleanup();\n\t\t\treturn;\n'
				+ '\t\t}\n\t}\n}'
			).length
		);
	}

	public function testExpressionRecoveryNotFlagged(): Void {
		Assert.equals(
			0, violations('class C {\n\tpublic function f():Void {\n\t\tfinal x = try g() catch (e:Exception) null;\n\t}\n}').length
		);
	}

	public function testCatchUsingVariableNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tpublic function f():Void {\n\t\ttry { g(); } catch (e:Exception) {\n\t\t\ttrace(e);\n\t\t}\n\t}\n}')
				.length
		);
	}

	public function testRethrowNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C {\n\tpublic function f():Void {\n\t\ttry { g(); } catch (e:Exception) {\n\t\t\tthrow new Foo();\n\t\t}\n\t}\n}'
			).length
		);
	}

	public function testEmptyCatchNotFlagged(): Void {
		Assert.equals(0, violations('class C {\n\tpublic function f():Void {\n\t\ttry { g(); } catch (e:Exception) {}\n\t}\n}').length);
	}

	public function testUnderscoreDiscardNotFlagged(): Void {
		Assert.equals(
			0,
			violations('class C {\n\tpublic function f():Void {\n\t\ttry { g(); } catch (_:Exception) {\n\t\t\ttrace("x");\n\t\t}\n\t}\n}')
				.length
		);
	}

	/**
	 * client `ApplicationSettingsStoragePathTest`: a catch that only records the outcome in a local the code after the try
	 * reads has handled the exception — the failure is now a value the function acts on.
	 */
	public function testOutcomeFlagReadAfterTheTryNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C { function f():Assertions { var threw:Bool = false; try { g(); g(); } catch (exception:Exception) {'
				+ ' threw = true; } return [assert(!threw, "must not throw")]; } }'
			).length
		);
	}

	/** Several outcome locals, each a constant — a negative number, a string, null — and each read after the try. */
	public function testSeveralOutcomeLocalsReadAfterTheTryNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C { function f() { var ok = true; var code = 0; var why:String = "none"; var last = 1; try { g(); } '
				+ 'catch (exception:Exception) { ok = false; code = -1; why = "failed"; last = null; } report(ok, code, why, last); } }'
			).length
		);
	}

	/** The read follows the loop the try sits in: the flag set in any iteration reaches it. */
	public function testOutcomeFlagReadAfterTheEnclosingLoopNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C { function f() { var failed = false; for (x in xs) { try { g(x); } catch (exception:Exception) {'
				+ ' failed = true; } } if (failed) h(); } }'
			).length
		);
	}

	/** A FIELD is no outcome local — whoever reads it, and when, the function does not say — and a parameter is not one either. */
	@:pin('control')
	@:killer('M-SWALLOW-OUTCOME-DECL-KIND')
	public function testAssignedFieldOrParameterStillFlagged(): Void {
		Assert.equals(
			1,
			violations('class C { function f(threw:Bool) { try { g(); } catch (exception:Exception) { threw = true; } trace(threw); } }')
				.length
		);
		Assert.equals(
			1,
			violations(
				'class C { var threw:Bool = false; function f() { try { g(); } catch (exception:Exception) { threw = true; } '
				+ 'trace(threw); } }'
			).length
		);
		Assert.equals(
			1,
			violations(
				'class C { var threw:Bool = false; function f() { var threw = false; try { g(); } catch (exception:Exception)'
				+ ' { this.threw = true; } trace(threw); } }'
			).length
		);
	}

	/** A flag nothing reads after the try records an outcome nobody acts on: read only before it, or written again after it. */
	@:pin('control')
	@:killer('M-SWALLOW-OUTCOME-READ-KIND', 'M-SWALLOW-OUTCOME-READ-AFTER')
	public function testFlagNotReadAfterTheTryStillFlagged(): Void {
		for (after in ['', 'threw = false;'])
			Assert.equals(
				1,
				violations(
					'class C { function f() { var threw = false; try { g(); } catch (exception:Exception) { threw = true; } $after } }'
				).length,
				after
			);
		Assert.equals(
			1,
			violations(
				'class C { function f() { var threw = false; trace(threw); try { g(); } catch (exception:Exception) { threw = true; } } }'
			).length
		);
	}

	/** Anything besides the outcome assignments — a call — is a handler that does something else with the failure. */
	@:pin('control')
	@:killer('M-SWALLOW-OUTCOME-EVERY-STMT')
	public function testCallInTheBodyStillFlagged(): Void {
		Assert.equals(
			1,
			violations(
				'class C { function f() { var threw = false; try { g(); } catch (exception:Exception) { threw = true; log("x"); }'
				+ ' trace(threw); } }'
			).length
		);
	}

	/** Only a body that IS the assignments: one under a condition or inside an inner block is not. */
	public function testAssignmentInANestedStatementStillFlagged(): Void {
		for (body in ['if (c) threw = true;', '{ threw = true; }'])
			Assert.equals(
				1,
				violations(
					'class C { function f() { var threw = false; try { g(); } catch (exception:Exception) { $body } trace(threw); } }'
				).length,
				body
			);
	}

	/** The value assigned must be a constant: a call, another local, a compound assignment, an interpolation. */
	@:pin('control')
	@:killer('M-SWALLOW-OUTCOME-COMPOUND', 'M-SWALLOW-OUTCOME-VALUE')
	public function testComputedValueStillFlagged(): Void {
		for (assign in ['threw = compute();', 'threw = other;', 'threw += 1;', 'threw = \'a$$b\';'])
			Assert.equals(
				1,
				violations('class C { function f() { var threw = 0; try { g(); } catch (exception:Exception) { $assign } trace(threw); } }')
					.length,
				assign
			);
	}

	/** Every assigned local must be read after the try — one that is not is a write nobody acts on. */
	public function testOneOutcomeLocalUnreadStillFlagged(): Void {
		Assert.equals(
			1,
			violations(
				'class C { function f() { var a = false; var b = false; try { g(); } catch (exception:Exception) { a = true; b = true; }'
				+ ' trace(a); } }'
			).length
		);
	}

	/** A read of the NAME after the try that binds another declaration is no read of the flag. */
	@:pin('control')
	@:killer('M-SWALLOW-OUTCOME-READ-BINDING')
	public function testReadOfAnotherBindingStillFlagged(): Void {
		Assert.equals(
			1,
			violations(
				'class C { function f() { var threw = false; try { g(); } catch (exception:Exception) { threw = true; }'
				+ ' { var threw = 1; trace(threw); } } }'
			).length
		);
	}

	/**
	 * A read after the closure the try sits in: the closure runs whenever it is called, so that read is not ordered after it.
	 */
	@:pin('control')
	@:killer('M-SWALLOW-OUTCOME-FN-BOUND')
	public function testReadOnlyAfterTheEnclosingClosureStillFlagged(): Void {
		Assert.equals(
			1,
			violations(
				'class C { function f() { var failed = false;'
				+ ' h(() -> { try { g(); } catch (exception:Exception) { failed = true; } }); trace(failed); } }'
			).length
		);
	}

	/** A local captured by the closure the try sits in, read after the try inside that closure: an outcome like any other. */
	public function testCapturedLocalReadAfterTheTryInsideTheClosureNotFlagged(): Void {
		Assert.equals(
			0,
			violations(
				'class C { function f() { var failed = false;'
				+ ' h(() -> { try { g(); } catch (exception:Exception) { failed = true; } trace(failed); }); } }'
			).length
		);
	}

	/** A read in the other arm of the branch the try sits in follows it in the text and on no path. */
	@:pin('control')
	@:killer('M-SWALLOW-OUTCOME-STMT-LIST')
	public function testReadInASiblingBranchStillFlagged(): Void {
		Assert.equals(
			1,
			violations(
				'class C { function f() { var failed = false;'
				+ ' if (c) { try { g(); } catch (exception:Exception) { failed = true; } } else { trace(failed); } } }'
			).length
		);
	}

	public function testFixReturnsEmpty(): Void {
		final src: String =
			'class C {\n\tpublic function f():Void {\n\t\ttry { g(); } catch (e:Exception) {\n\t\t\ttrace("oops");\n\t\t}\n\t}\n}';
		final check: SwallowedException = new SwallowedException();
		Assert.equals(0, CheckFixture.edits(check, src).length);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('swallowed-exception'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('swallowed-exception'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations('class Bad { function f() { try {').length);
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new SwallowedException(), src);
	}

}
