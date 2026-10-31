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

	/** A catch with no braces is a handler like any other: under a statement `try`, in the `;`-terminated and the bare spelling. */
	public function testBareCatchBodyFlagged(): Void {
		for (src in [
			'class C { function f() { try g(); catch (e:Exception) log("x"); } }',
			'class C { function f() { try g() catch (e:Exception) log("x"); } }',
			'class C { function f() { try g(); catch (e:Exception) if (c) log("x"); } }'
		]) Assert.equals(1, violations(src).length, src);
	}

	/** A bare body that uses the variable, returns, throws or jumps handles the exception. */
	public function testBareCatchBodyHandledNotFlagged(): Void {
		for (body in [
			'log(e)',
			'return false',
			'return',
			'throw new Foo()',
			'continue',
			'break'
		]) Assert.equals(0, violations('class C { function f() { for (x in xs) { try g(x) catch (e:Exception) $body; } } }').length, body);
	}

	/** A bare body that only yields a value is the recovery value of the try, in a `case` body as well as after the try. */
	@:pin('control')
	@:killer('M-SWALLOW-BARE-VALUE', 'M-SWALLOW-BARE-DEFAULT-ARM')
	public function testBareValueBodyNotFlagged(): Void {
		for (src in [
			'class C { function f() { return switch (x) { case 1: try g() catch (e:Exception) null; case _: 0; }; } }',
			'class C { function f() { return switch (x) { case 1: try g() catch (e:Exception) MISSING; case _: 0; }; } }',
			'class C { function f() { return switch (x) { case 1: 0; default: try g() catch (e:Exception) null; }; } }',
			'class C { function f() { try g() catch (e:Exception) null; } }'
		]) Assert.equals(0, violations(src).length, src);
	}

	/** A value body mid-list is no result: the statements after the try run on, and nobody reads what it yielded. */
	@:pin('control')
	@:killer('M-SWALLOW-BARE-TAIL')
	public function testBareValueBodyMidListStillFlagged(): Void {
		for (src in [
			'class C { function f() { try g() catch (e:Exception) null; h(); } }',
			'class C { function f() { return switch (x) { case 1: try g() catch (e:Exception) null; h(); case _: 0; }; } }'
		]) Assert.equals(1, violations(src).length, src);
	}

	/** A try EXPRESSION recovers with its catch body's value, whatever the body does. */
	@:pin('control')
	@:killer('M-SWALLOW-BARE-STMT-ONLY')
	public function testBareBodyOfATryExpressionNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f() { final x = try g() catch (e:Exception) fallback("x"); } }').length);
	}

	/** A catch that counts the failure in a local the code after the try reads has made it a value the code acts on. */
	@:pin('control')
	@:killer('M-SWALLOW-OUTCOME-COUNTER')
	public function testCountedFailureReadAfterTheTryNotFlagged(): Void {
		for (catchClause in [
			'catch (e:Exception) { failed++; }',
			'catch (e:Exception) { --failed; }',
			'catch (e:Exception) failed++;',
			'catch (e:Exception) failed = -1;',
			'catch (e:Exception) { failed += 1; }',
			'catch (e:Exception) failed -= 1;'
		])
			Assert.equals(
				0, violations('class C { function f() { var failed = 0; try { g(); } $catchClause report(failed); } }').length, catchClause
			);
	}

	/** A counter nothing reads after the try, or a field, or counting next to other work, handles nothing. */
	public function testCountedFailureNotActedOnStillFlagged(): Void {
		for (src in [
			'class C { function f() { var failed = 0; try { g(); } catch (e:Exception) { failed++; } } }',
			'class C { var failed = 0; function f() { try { g(); } catch (e:Exception) { failed++; } report(failed); } }',
			'class C { function f() { var failed = 0; try { g(); } catch (e:Exception) { failed++; log("x"); } report(failed); } }'
		]) Assert.equals(1, violations(src).length, src);
	}

	/** An expected-exception test records the caught exception as its result: the catch body is only `Assert.pass()` / `Assert.fail(…)`. */
	@:pin('control')
	@:killer('M-SWALLOW-TEST-OUTCOME')
	public function testTestOutcomeCallsNotFlagged(): Void {
		for (catchClause in [
			'catch (e:Exception) { Assert.pass(); }',
			'catch (e:Exception) { Assert.fail("unexpected"); }',
			'catch (e:Exception) Assert.pass();'
		]) Assert.equals(0, violations('class C { function f() { try { g(); } $catchClause } }').length, catchClause);
		for (catchClause in [
			'catch (e:Exception) { Foo.pass(); }',
			'catch (e:Exception) { Assert.pass(); log("x"); }',
			'catch (e:Exception) { pass(); }'
		]) Assert.equals(1, violations('class C { function f() { try { g(); } $catchClause } }').length, catchClause);
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
	@:killer('M-SWALLOW-OUTCOME-VALUE')
	public function testComputedValueStillFlagged(): Void {
		for (assign in [
			'threw = compute();',
			'threw = other;',
			'threw += compute();',
			'threw += other;',
			'threw = \'a$$b\';'
		])
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

	/** A counter or flag only the loop head (or an earlier statement of the loop body) reads is read by the next iteration. */
	public function testCatchOutcomeReadByTheNextIterationNotFlagged(): Void {
		for (src in [
			'class C { function f() { var tries = 0; while (true) { if (tries > 3) break; try { g(); break; } catch (e:Exception) '
			+ 'tries++; } } }',
			'class C { function f() { var tries = 0; while (tries < 3) { try { g(); break; } catch (e:Exception) { tries++; } } } }',
			'class C { function f() { var threw = false; for (i in 0...3) { if (threw) break; try { g(); } catch (e:Exception) {'
			+ ' threw = true; } } } }'
		]) Assert.equals(0, violations(src).length, src);
	}

	/** A loop around the try does not make an unread counter handled, nor one declared inside the loop and read nowhere. */
	public function testCatchOutcomeReadNowhereInLoopStillFlagged(): Void {
		for (src in [
			'class C { function f() { var tries = 0; while (true) { try { g(); break; } catch (e:Exception) tries++; } } }',
			'class C { function f() { for (i in 0...3) { var n = 0; try { g(); } catch (e:Exception) { n++; } } } }',
			'class C { function f() { for (i in 0...3) { var failed = false; trace(failed); try { g(); } catch (e:Exception) {'
			+ ' failed = true; } } } }',
			'class C { function f() { var n = 3; for (i in 0...n) { try { g(); } catch (e:Exception) { n++; } } } }'
		]) Assert.equals(1, violations(src).length, src);
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new SwallowedException(), src);
	}

}
