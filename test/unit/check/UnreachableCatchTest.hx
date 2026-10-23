package unit.check;

import anyparse.check.Severity;
import anyparse.check.UnreachableCatch;
import anyparse.query.CanonicalEdit;

/**
 * The `unreachable-catch` check: a `catch` clause that can never run because an earlier
 * clause in the same `try` already catches everything it would — a duplicate type, a
 * supertype/interface it extends, or a catch-all (`Dynamic` / `Any`). Order matters: a
 * narrower clause AFTER a broader one is dead; the reverse is fine.
 */
class UnreachableCatchTest extends Test {

	public inline function testFixDeletesDuplicateClause(): Void {
		// The later duplicate clause (its `dead()` body) is removed; the earlier one is kept.
		assertFix('class E {} class C { function f() { try { g(); } catch (e:E) { keep(); } catch (e:E) { dead(); } } }', 'keep', 'dead');
	}

	public inline function testFixCatchAllDeletesLater(): Void {
		// A catch-all first makes the later typed clause dead — it is deleted.
		assertFix(
			'class E {} class C { function f() { try { g(); } catch (e:Dynamic) { keep(); } catch (e:E) { dead(); } } }', 'keep', 'dead'
		);
	}

	public inline function testFixNestedOverlapKeepsOuterOnly(): Void {
		// The outer dead clause nests an inner dead clause; deleting the outer removes both — the
		// contained inner edit is dropped, so `inner`/`b` vanish with the outer and only `ok` stays.
		assertFix(
			'class C { function f() { try { risky(); } catch (e:Dynamic) { ok(); } catch (e:Dynamic) { try { inner(); } catch ('
			+ 'a:Dynamic) { fine(); } catch (b:Dynamic) { dead(); } } } }',
			'ok', 'dead'
		);
	}

	public function testDuplicateCatchFlagged(): Void {
		Assert.equals(1, violations('class E {} class C { function f() { try { g(); } catch (e:E) {} catch (e:E) {} } }').length);
	}

	@:pin('control') @:killer('M-ISSUBTYPE-FALSE')
	public function testSubtypeAfterSupertypeFlagged(): Void {
		// catch Base then Sub — Sub<:Base, so Base already caught it.
		Assert.equals(
			1,
			violations(
				'class Base {} class Sub extends Base {} class C { function f() { try { g(); } catch (e:Base) {} catch (e:Sub) {} } }'
			).length
		);
	}

	public function testSupertypeAfterSubtypeNotFlagged(): Void {
		// catch Sub then Base — Base catches MORE than Sub; not covered.
		Assert.equals(
			0,
			violations(
				'class Base {} class Sub extends Base {} class C { function f() { try { g(); } catch (e:Sub) {} catch (e:Base) {} } }'
			).length
		);
	}

	public function testCatchAllFirstFlagged(): Void {
		Assert.equals(1, violations('class E {} class C { function f() { try { g(); } catch (e:Dynamic) {} catch (e:E) {} } }').length);
	}

	public function testCatchAllLastNotFlagged(): Void {
		Assert.equals(0, violations('class E {} class C { function f() { try { g(); } catch (e:E) {} catch (e:Dynamic) {} } }').length);
	}

	public function testUnrelatedCatchesNotFlagged(): Void {
		Assert.equals(
			0, violations('class A2 {} class B2 {} class C { function f() { try { g(); } catch (e:A2) {} catch (e:B2) {} } }').length
		);
	}

	public function testThreeClausesOnlyMiddleFlagged(): Void {
		// Base, Sub, Other — only Sub is covered (by Base); Other is unrelated.
		final vs: Array<Violation> = violations(
			'class Base {} class Sub extends Base {} class Other {} class C { function f() { try { g(); } catch (e:Base) {} catch ('
			+ 'e:Sub) {} catch (e:Other) {} } }'
		);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.indexOf('Base') != -1);
	}

	public function testQualifiedDuplicateFlagged(): Void {
		// `e:Eof` and `e:haxe.io.Eof` reconcile via importMap → duplicate.
		Assert.equals(
			1,
			violations('import haxe.io.Eof;\nclass C { function f() { try { g(); } catch (e:Eof) {} catch (e:haxe.io.Eof) {} } }').length
		);
	}

	public function testFlaggedAsWarning(): Void {
		final vs: Array<Violation> = violations('class E {} class C { function f() { try { g(); } catch (e:E) {} catch (e:E) {} } }');
		Assert.equals(1, vs.length);
		Assert.equals('unreachable-catch', vs[0].rule);
		Assert.equals(Severity.Warning, vs[0].severity);
	}

	public function testFixNoDeadClauseNoEdit(): Void {
		// Unrelated clauses — nothing to fix.
		final check: UnreachableCatch = new UnreachableCatch();
		final src: String = 'class A2 {} class B2 {} class C { function f() { try { g(); } catch (e:A2) {} catch (e:B2) {} } }';
		final vs: Array<Violation> = CheckFixture.violations(check, src);
		Assert.equals(0, CheckFixture.fixOf(check, src, vs).length);
	}

	public function testFixSkipParseNoEdit(): Void {
		// An unparseable source yields no edits (no crash).
		final check: UnreachableCatch = new UnreachableCatch();
		final src: String = 'class Bad { function f() { try { g(); } catch (e: ';
		Assert.equals(0, CheckFixture.fixOf(check, src, []).length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0,
			CheckFixture.violationsIn(
				new UnreachableCatch(), [{ file: 'Bad.hx', source: 'class Bad { function f() { try { g(); } catch (e: ' }]
			)
				.length
		);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('unreachable-catch'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('unreachable-catch'));
	}

	public function testUntypedCatchAllFirstFlagged(): Void {
		// An untyped `catch (e)` is a Haxe catch-all; the later typed clause is dead.
		Assert.equals(1, violations('class E {} class C { function f() { try { g(); } catch (e) {} catch (e:E) {} } }').length);
	}

	public function testInterfaceImplementsFlagged(): Void {
		// catch I then a class implementing I — the implementor is already caught.
		Assert.equals(
			1,
			violations('interface I {} class A implements I {} class C { function f() { try { g(); } catch (e:I) {} catch (e:A) {} } }')
				.length
		);
	}

	/**
	 * An earlier clause covers a later one only when the later type really extends the DECLARATION the earlier clause
	 * names: another package's namesake in the later type's chain leaves the clause reachable, and deleting it would drop
	 * the handler that runs. The second assertion keeps the namesake in the index beside a real subtype.
	 */
	@:pin('control') @:killer('M-SUBTYPE-TARGET-SIMPLE-NAME')
	public function testNamesakeSupertypeDoesNotCoverTheLaterClause(): Void {
		Assert.equals(0, namesakeCovered('Base'), 'a subtype of another package\'s Base still reaches its own clause');
		Assert.equals(1, namesakeCovered('pkg.Base'), 'a subtype of this Base is caught by the earlier clause');
	}

	private function assertFix(src: String, present: String, absent: String): Void {
		final check: UnreachableCatch = new UnreachableCatch();
		final vs: Array<Violation> = CheckFixture.violations(check, src);
		switch CanonicalEdit.canonicalize(src, CheckFixture.fixOf(check, src, vs), true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf(present) >= 0);
				Assert.isTrue(text.indexOf(absent) == -1);
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
	}

	private function violations(src: String): Array<Violation> {
		return CheckFixture.violations(new UnreachableCatch(), src);
	}

	/** `unreachable-catch` findings over two `Base` classes in two packages, `other.Sub` extending `subExtends`. */
	private function namesakeCovered(subExtends: String): Int {
		return CheckFixture.violationsIn(new UnreachableCatch(), [
			{ file: 'pkg/Base.hx', source: 'package pkg;\n\nclass Base {}\n' },
			{ file: 'other/Base.hx', source: 'package other;\n\nclass Base {}\n' },
			{ file: 'other/Sub.hx', source: 'package other;\n\nclass Sub extends $subExtends {}\n' },
			{
				file: 'pkg/Main.hx',
				source: 'package pkg;\n\nimport other.Sub;\n\nclass Main {\n\n\tfunction f():Void {\n\t\ttry {\n\t\t\tg();\n'
				+ '\t\t} catch (e:Base) {\n\t\t\tone();\n\t\t} catch (e:Sub) {\n\t\t\ttwo();\n\t\t}\n\t}\n\n}\n'
			}
		]).length;
	}

}
