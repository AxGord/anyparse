package unit;

import utest.Assert;
import anyparse.grammar.haxe.HxCaseBranch;
import anyparse.grammar.haxe.HxCasePatternBody;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxStatement;
import anyparse.grammar.haxe.HxSwitchCase;
import anyparse.grammar.haxe.HxSwitchStmt;

/**
 * Slice apq-P5-K3: multi-value `case A, B, C:` patterns.
 *
 * `HxCaseBranch.pattern:HxExpr` became
 * `patterns:Array<HxCasePattern>` with `@:sep(',') @:trail(':')` —
 * the same Star+sep+trail shape as `HxFnDecl.typeParams`. A single
 * `case A:` is the one-element form (strict regression guard against
 * the probed pre-slice contract); `case A, B, C:` is the
 * multi-element form. Each element's pattern expression is reached
 * via `.expr` (slice M widened the element to `HxCasePattern` to
 * carry an optional guard).
 *
 * Navigation mirrors `HxSwitchNewSliceTest` (which was updated for the
 * `.pattern` → `.patterns` field reshape).
 */
class HxMultiPatternCaseSliceTest extends HxTestHelpers {

	private function parseSwitch(source:String):HxSwitchStmt {
		final body:Array<HxStatement> = fnBodyStmts(parseSingleFnDecl(source));
		Assert.equals(1, body.length);
		return switch body[0] {
			case SwitchStmt(stmt): stmt;
			case null, _: throw 'expected SwitchStmt, got ${body[0]}';
		};
	}

	private function caseBranch(c:HxSwitchCase):HxCaseBranch {
		return switch c {
			case CaseBranch(b): b;
			case null, _: throw 'expected CaseBranch, got $c';
		};
	}

	// regression: single pattern is now a one-element list

	public function testSinglePatternIsOneElementList():Void {
		final sw:HxSwitchStmt = parseSwitch('class C { function f(x:Int):Void { switch (x) { case 1: y(); case _: z(); } } }');
		final b:HxCaseBranch = caseBranch(sw.cases[0]);
		Assert.equals(1, b.patterns.length);
		switch b.patterns[0].expr {
			case Plain(IntLit(v)): Assert.equals(1, v);
			case null, _: Assert.fail('expected Plain(IntLit) pattern, got ${b.patterns[0].expr}');
		}
	}

	// multi-value cases

	public function testTwoPatternCase():Void {
		final sw:HxSwitchStmt = parseSwitch('class C { function f(x:Int):Void { switch (x) { case 1, 2: y(); case _: z(); } } }');
		final b:HxCaseBranch = caseBranch(sw.cases[0]);
		Assert.equals(2, b.patterns.length);
		switch b.patterns[0].expr {
			case Plain(IntLit(v)): Assert.equals(1, v);
			case null, _: Assert.fail('expected Plain(IntLit 1)');
		}
		switch b.patterns[1].expr {
			case Plain(IntLit(v)): Assert.equals(2, v);
			case null, _: Assert.fail('expected Plain(IntLit 2)');
		}
	}

	public function testThreePatternStringCase():Void {
		final sw:HxSwitchStmt = parseSwitch('class C { function f(s:String):Void { switch (s) { case "a", "b", "c": y(); case _: z(); } } }');
		final b:HxCaseBranch = caseBranch(sw.cases[0]);
		Assert.equals(3, b.patterns.length);
	}

	public function testMultiPatternWithBody():Void {
		final sw:HxSwitchStmt = parseSwitch('class C { function f(x:Int):Void { switch (x) { case 1, 2, 3: { a(); b(); } case _: z(); } } }');
		final b:HxCaseBranch = caseBranch(sw.cases[0]);
		Assert.equals(3, b.patterns.length);
		Assert.equals(1, b.body.length);
	}

	public function testMixedMultiSingleAndDefault():Void {
		final sw:HxSwitchStmt = parseSwitch('class C { function f(x:Int):Void { switch (x) { case 1, 2: a(); case 3: b(); default: c(); } } }');
		Assert.equals(3, sw.cases.length);
		Assert.equals(2, caseBranch(sw.cases[0]).patterns.length);
		Assert.equals(1, caseBranch(sw.cases[1]).patterns.length);
		switch sw.cases[2] {
			case DefaultBranch(_): Assert.pass();
			case null, _: Assert.fail('expected DefaultBranch, got ${sw.cases[2]}');
		}
	}

	public function testConstructorPatternsInMultiCase():Void {
		final sw:HxSwitchStmt = parseSwitch('class C { function f(e:E):Void { switch (e) { case Foo(a), Bar(b): y(); case _: z(); } } }');
		final b:HxCaseBranch = caseBranch(sw.cases[0]);
		Assert.equals(2, b.patterns.length);
		switch b.patterns[0].expr {
			case Plain(Call(operand, _)):
				switch operand {
					case IdentExpr(v): Assert.equals('Foo', (v : String));
					case null, _: Assert.fail('expected IdentExpr Foo');
				}
			case null, _: Assert.fail('expected Plain(Call) pattern Foo(a)');
		}
	}
}
