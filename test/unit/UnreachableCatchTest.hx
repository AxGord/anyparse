package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.check.UnreachableCatch;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `unreachable-catch` check: a `catch` clause that can never run because an earlier
 * clause in the same `try` already catches everything it would — a duplicate type, a
 * supertype/interface it extends, or a catch-all (`Dynamic` / `Any`). Order matters: a
 * narrower clause AFTER a broader one is dead; the reverse is fine.
 */
class UnreachableCatchTest extends Test {

	public function testDuplicateCatchFlagged(): Void {
		Assert.equals(1, violations('class E {} class C { function f() { try { g(); } catch (e:E) {} catch (e:E) {} } }').length);
	}

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
			'class Base {} class Sub extends Base {} class Other {} class C { function f() { try { g(); } catch (e:Base) {} catch (e:Sub) {} catch (e:Other) {} } }'
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

	public function testFixIsNoop(): Void {
		final check: UnreachableCatch = new UnreachableCatch();
		final src: String = 'class E {} class C { function f() { try { g(); } catch (e:E) {} catch (e:E) {} } }';
		final vs: Array<Violation> = check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
		final edits: Array<{ span: Span, text: String }> = check.fix(src, vs, new HaxeQueryPlugin());
		Assert.equals(0, edits.length);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0,
			new UnreachableCatch().run(
				[{ file: 'Bad.hx', source: 'class Bad { function f() { try { g(); } catch (e: ' }], new HaxeQueryPlugin()
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
			violations('interface I {} class A implements I {} class C { function f() { try { g(); } catch (e:I) {} catch (e:A) {} } }').length
		);
	}

	private function violations(src: String): Array<Violation> {
		return new UnreachableCatch().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
