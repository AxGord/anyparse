package unit;

import utest.Assert;
import utest.Test;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.check.RedundantAscription;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.runtime.Span;

/**
 * The `redundant-ascription` check: a parenthesised ascription `(new T(...) : T)` whose
 * ascribed type is byte-equal (whitespace-insensitive) to the constructed class name and
 * carries no type parameters — the ascription restates a type the construction already
 * carries, so `--fix` unwraps it to the bare `new T(...)`.
 *
 * HARD BOUNDARY: only the `new T(...)` operand shape is ever flagged. An ascription of a
 * plain identifier or any other expression is never touched, even when its written type
 * matches byte-for-byte — `(x : Int)` can be load-bearing (narrowing a `Null<Int>` local
 * for a context that demands a non-null `Int`), so treating an identifier ascription as
 * always-redundant would break real code.
 */
class RedundantAscriptionTest extends Test {

	public function testMatchingAscriptionFlagged(): Void {
		Assert.equals(1, violations('class C { function f():Row { return (new Row() : Row); } }').length);
	}

	public function testCanaryShapeFlagged(): Void {
		// Mirrors the reported canary: a multi-argument constructor call ascribed to its own type.
		Assert.equals(
			1,
			violations(
				'class C { function f(boxWidth:Int):Row { return (new Row([new Label(""), new Label("")], boxWidth, 11, X.Y) : Row); } }'
			).length
		);
	}

	public function testWhitespaceInsensitiveMatchFlagged(): Void {
		Assert.equals(1, violations('class C { function f():Row { return (new Row()   :    Row  ); } }').length);
	}

	public function testQualifiedNameMatchFlagged(): Void {
		Assert.equals(
			1, violations('class C { function f():haxe.ds.StringMap { return (new haxe.ds.StringMap() : haxe.ds.StringMap); } }').length
		);
	}

	public function testMismatchedNameNotFlagged(): Void {
		Assert.equals(0, violations('class Foo {} class Bar {} class C { function f():Bar { return (new Foo() : Bar); } }').length);
	}

	public function testAscribedGenericsNotFlagged(): Void {
		// The ascribed type carries type parameters — the hard "no type parameters" boundary refuses
		// even though the head name matches.
		Assert.equals(0, violations('class C { function f() { final m = (new Foo() : Foo<Int>); } }').length);
	}

	public function testQualifiedVsBareNotFlagged(): Void {
		// Deliberately NOT FQN-reconciled — a byte-identical spelling is the whole contract, so a bare
		// name is never equated with its qualified spelling here (unlike `redundant-cast`'s import
		// reconciliation, which this check does not adopt).
		Assert.equals(0, violations('class C { function f() { final m = (new haxe.ds.StringMap() : StringMap); } }').length);
	}

	public function testIdentifierOperandNeverFlagged(): Void {
		// HARD BOUNDARY, proven on real code: an identifier ascription can be a load-bearing
		// null-safety narrowing (a `Null<Int>` local ascribed to `Int` for a non-null-typed slot).
		// Anonymized from a real site that fails to compile without the ascription.
		Assert.equals(0, violations('class C { function f(id:Null<Int>):{ id:Int } { return { id: (id : Int) }; } }').length);
	}

	public function testBareIdentifierAscriptionSameNameNotFlagged(): Void {
		// Even when the ascribed type spelling equals a plain identifier operand's own name
		// byte-for-byte, the operand is not a `new T(...)` shape and must never be flagged.
		Assert.equals(0, violations('class C { function f(Row:Dynamic) { final m = (Row : Row); } }').length);
	}

	public function testOtherExpressionOperandNotFlagged(): Void {
		// A call expression operand — not a `new T(...)` shape.
		Assert.equals(0, violations('class C { function f():Row { return (g() : Row); } function g():Row return null; } }').length);
	}

	public function testCheckedCastNotFlagged(): Void {
		// `cast(new T(), T)` is a DIFFERENT node kind (`TypedCastExpr`) — `redundant-cast-type`'s
		// territory, not this check's.
		Assert.equals(0, violations('class C { function f():Row { return cast(new Row(), Row); } }').length);
	}

	public function testCommentBeforeColonNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f() { final m = (new Row() /* z */ : Row); } }').length);
	}

	public function testCommentAfterTypeNotFlagged(): Void {
		Assert.equals(0, violations('class C { function f() { final m = (new Row() : Row /* z */); } }').length);
	}

	public function testFixUnwrapsCanaryShape(): Void {
		final out: String = applyFix(
			'class C { function f(boxWidth:Int):Row { return (new Row([new Label("")], boxWidth, 11, X.Y) : Row); } }'
		);
		Assert.isTrue(
			out.indexOf('return new Row([new Label("")], boxWidth, 11, X.Y);') != -1, 'expected unwrapped `new Row(...)`, got: $out'
		);
		Assert.isTrue(out.indexOf(': Row)') == -1, 'ascription should be gone, got: $out');
	}

	public function testFixLeavesUnflaggedAscriptionAlone(): Void {
		final src: String = 'class Foo {} class Bar {} class C { function f():Bar { return (new Foo() : Bar); } }';
		final check: RedundantAscription = new RedundantAscription();
		Assert.equals(0, check.fix(src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()).length);
	}

	public function testFlaggedAsInfo(): Void {
		final vs: Array<Violation> = violations('class C { function f():Row { return (new Row() : Row); } }');
		Assert.equals(1, vs.length);
		Assert.equals('redundant-ascription', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
	}

	public function testIsDefaultOff(): Void {
		Assert.isTrue(new RedundantAscription() is DefaultOff);
	}

	public function testRegisteredInBuiltins(): Void {
		Assert.notNull(Linter.byId('redundant-ascription'));
		final ids: Array<String> = [for (c in Linter.builtins()) c.id()];
		Assert.isTrue(ids.contains('redundant-ascription'));
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(
			0,
			new RedundantAscription().run(
				[{ file: 'Bad.hx', source: 'class Bad { function f() { final a = (new Row(' }], new HaxeQueryPlugin()
			)
				.length
		);
	}

	private function applyFix(src: String): String {
		final check: RedundantAscription = new RedundantAscription();
		final edits: Array<{ span: Span, text: String }> = check.fix(
			src, check.run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin()), new HaxeQueryPlugin()
		);
		edits.sort((a, b) -> b.span.from - a.span.from);
		var out: String = src;
		for (e in edits) out = out.substring(0, e.span.from) + e.text + out.substring(e.span.to);
		return out;
	}

	private function violations(src: String): Array<Violation> {
		return new RedundantAscription().run([{ file: 'C.hx', source: src }], new HaxeQueryPlugin());
	}

}
