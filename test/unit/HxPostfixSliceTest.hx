package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeFastParser;
import anyparse.grammar.haxe.HaxeModuleFastParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxClassMember;
import anyparse.grammar.haxe.HxDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxVarDecl;
import anyparse.runtime.ParseError;

/**
 * Phase 3 postfix-slice (δ) tests for the macro-generated Haxe parser.
 *
 * Covers three postfix operators — field access `.name`, index access
 * `[expr]`, and no-arg call `()` — added on top of the 31 binary +
 * 3 unary-prefix baseline. A new `Postfix` strategy (annotate-only,
 * `postfix.*` namespace) and a new `lowerPostfixLoop` helper in
 * `Lowering` generate a left-recursive loop around an inner atom-core
 * call. For HxExpr, which has both Pratt and postfix, `lowerRule` now
 * emits THREE functions instead of two: `parseHxExpr` (the Pratt loop
 * — public entry), `parseHxExprAtom` (the new wrapper: calls Core then
 * runs the postfix loop), and `parseHxExprAtomCore` (the old atom body
 * holding the non-operator tryBranch chain over leaves and prefix).
 *
 * Binding-tightness invariants this file locks in:
 *
 *  - **Postfix binds tighter than Pratt infix.** `a.b + c` parses as
 *    `Add(FieldAccess(a, b), c)`. The Pratt loop only ever sees the
 *    postfix-extended atom that the wrapper returns.
 *  - **Postfix binds tighter than unary prefix.** `-a.b` parses as
 *    `Neg(FieldAccess(a, b))`. The prefix branch's `recurseFnName`
 *    targets `parseHxExprAtom` (the wrapper), so postfix is applied
 *    to `a` before the prefix ctor wraps the result.
 *  - **Postfix is left-recursive.** `a.b.c` parses as
 *    `FieldAccess(FieldAccess(a, b), c)`. The loop keeps extending
 *    `left` until no further postfix matches.
 *
 * Helpers `parseSingleVarDecl`, `expectVarMember`, `expectClassDecl`
 * remain inlined per sibling convention; debt #5b still tracks the
 * extraction into a shared `HxExprTestBase`.
 */
class HxPostfixSliceTest extends Test {

	public function new() {
		super();
	}

	public function testFieldAccessSmoke():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a.b; }');
		switch decl.init {
			case FieldAccess(IdentExpr(o), f):
				Assert.equals('a', (o : String));
				Assert.equals('b', (f : String));
			case null, _:
				Assert.fail('expected FieldAccess(IdentExpr(a), b), got ${decl.init}');
		}
	}

	public function testIndexAccessSmoke():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a[1]; }');
		switch decl.init {
			case IndexAccess(IdentExpr(o), IntLit(i)):
				Assert.equals('a', (o : String));
				Assert.equals(1, (i : Int));
			case null, _:
				Assert.fail('expected IndexAccess(IdentExpr(a), IntLit(1)), got ${decl.init}');
		}
	}

	public function testCallNoArgsSmoke():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = f(); }');
		switch decl.init {
			case CallNoArgs(IdentExpr(o)): Assert.equals('f', (o : String));
			case null, _:
				Assert.fail('expected CallNoArgs(IdentExpr(f)), got ${decl.init}');
		}
	}

	public function testFieldChain():Void {
		// `a.b.c` → FieldAccess(FieldAccess(a, b), c). Left-recursion
		// proof: the postfix loop keeps matching `.` on the growing
		// `left`, so each `.name` wraps the previous accumulator.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a.b.c; }');
		switch decl.init {
			case FieldAccess(FieldAccess(IdentExpr(a), b), c):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
				Assert.equals('c', (c : String));
			case null, _:
				Assert.fail('expected FieldAccess(FieldAccess(a, b), c), got ${decl.init}');
		}
	}

	public function testIndexChain():Void {
		// `a[1][2]` → IndexAccess(IndexAccess(a, 1), 2). Same
		// left-recursion property for the bracketed form.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a[1][2]; }');
		switch decl.init {
			case IndexAccess(IndexAccess(IdentExpr(a), IntLit(one)), IntLit(two)):
				Assert.equals('a', (a : String));
				Assert.equals(1, (one : Int));
				Assert.equals(2, (two : Int));
			case null, _:
				Assert.fail('expected IndexAccess(IndexAccess(a, 1), 2), got ${decl.init}');
		}
	}

	public function testCallChain():Void {
		// `f()()` → CallNoArgs(CallNoArgs(f)). Currying the no-arg
		// call case.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = f()(); }');
		switch decl.init {
			case CallNoArgs(CallNoArgs(IdentExpr(f))):
				Assert.equals('f', (f : String));
			case null, _:
				Assert.fail('expected CallNoArgs(CallNoArgs(f)), got ${decl.init}');
		}
	}

	public function testMixedChainFieldIndex():Void {
		// `a.b[c]` → IndexAccess(FieldAccess(a, b), c). Postfix loop
		// extends `left` with `.b` first, then `[c]` on the result.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a.b[c]; }');
		switch decl.init {
			case IndexAccess(FieldAccess(IdentExpr(a), b), IdentExpr(c)):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
				Assert.equals('c', (c : String));
			case null, _:
				Assert.fail('expected IndexAccess(FieldAccess(a, b), c), got ${decl.init}');
		}
	}

	public function testMixedChainIndexField():Void {
		// `a[b].c` → FieldAccess(IndexAccess(a, b), c). Order reversed.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a[b].c; }');
		switch decl.init {
			case FieldAccess(IndexAccess(IdentExpr(a), IdentExpr(b)), c):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
				Assert.equals('c', (c : String));
			case null, _:
				Assert.fail('expected FieldAccess(IndexAccess(a, b), c), got ${decl.init}');
		}
	}

	public function testMixedChainCallField():Void {
		// `f().x` → FieldAccess(CallNoArgs(f), x). Postfix loop
		// handles mixed shapes as they appear.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = f().x; }');
		switch decl.init {
			case FieldAccess(CallNoArgs(IdentExpr(f)), x):
				Assert.equals('f', (f : String));
				Assert.equals('x', (x : String));
			case null, _:
				Assert.fail('expected FieldAccess(CallNoArgs(f), x), got ${decl.init}');
		}
	}

	public function testMixedChainFieldCall():Void {
		// `a.b()` → CallNoArgs(FieldAccess(a, b)). The idiomatic
		// method-call-on-member case that dominates real Haxe code.
		// Symmetric to `f().x` (testMixedChainCallField) on the
		// other combination — the postfix loop extends `left` with
		// `.b` first, then applies `()` to the result.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a.b(); }');
		switch decl.init {
			case CallNoArgs(FieldAccess(IdentExpr(a), b)):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
			case null, _:
				Assert.fail('expected CallNoArgs(FieldAccess(a, b)), got ${decl.init}');
		}
	}

	public function testPrefixBindsLooserThanFieldAccess():Void {
		// `-a.b` → Neg(FieldAccess(a, b)). **Load-bearing**: the
		// prefix classifier case's `recurseFnName` now targets
		// `parseHxExprAtom` (the wrapper that includes the postfix
		// loop). When Neg recurses for its operand, the wrapper
		// applies `.b` to `a` first, then Neg wraps the FieldAccess
		// result. A recurseFnName pointing at the core function
		// (which does not run the postfix loop) would give
		// `FieldAccess(Neg(a), b)` instead.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = -a.b; }');
		switch decl.init {
			case Neg(FieldAccess(IdentExpr(a), b)):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
			case null, _:
				Assert.fail('expected Neg(FieldAccess(a, b)), got ${decl.init}');
		}
	}

	public function testPrefixBindsLooserThanCall():Void {
		// `!f()` → Not(CallNoArgs(f)). Same binding-tightness
		// invariant verified against the no-arg call form.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = !f(); }');
		switch decl.init {
			case Not(CallNoArgs(IdentExpr(f))):
				Assert.equals('f', (f : String));
			case null, _:
				Assert.fail('expected Not(CallNoArgs(f)), got ${decl.init}');
		}
	}

	public function testPostfixBindsTighterThanAddLeft():Void {
		// `a.b + c` → Add(FieldAccess(a, b), c). **Load-bearing**:
		// the Pratt loop calls `parseHxExprAtom` (the wrapper) for
		// the left operand and receives `FieldAccess(a, b)` in one
		// step, then sees `+` at prec 8 and folds. The `+` is NEVER
		// inside the `.b` parse because postfix only runs between
		// the core result and the Pratt loop — not recursively from
		// within the field-access body.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a.b + c; }');
		switch decl.init {
			case Add(FieldAccess(IdentExpr(a), b), IdentExpr(c)):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
				Assert.equals('c', (c : String));
			case null, _:
				Assert.fail('expected Add(FieldAccess(a, b), c), got ${decl.init}');
		}
	}

	public function testPostfixBindsTighterThanAddRight():Void {
		// `c + a.b` → Add(c, FieldAccess(a, b)). Same invariant on
		// the right side — the Pratt loop's right-operand recursion
		// also goes through the atom wrapper, so the right side sees
		// the postfix-extended atom.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = c + a.b; }');
		switch decl.init {
			case Add(IdentExpr(c), FieldAccess(IdentExpr(a), b)):
				Assert.equals('c', (c : String));
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
			case null, _:
				Assert.fail('expected Add(c, FieldAccess(a, b)), got ${decl.init}');
		}
	}

	public function testIndexContainsInfixExpression():Void {
		// `a[b + 1]` → IndexAccess(a, Add(b, 1)). The inner recursion
		// on `[expr]` targets `parseHxExpr` (the Pratt loop public
		// entry), not `parseHxExprAtom`, so arbitrary operators are
		// allowed inside the brackets.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a[b + 1]; }');
		switch decl.init {
			case IndexAccess(IdentExpr(a), Add(IdentExpr(b), IntLit(one))):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
				Assert.equals(1, (one : Int));
			case null, _:
				Assert.fail('expected IndexAccess(a, Add(b, 1)), got ${decl.init}');
		}
	}

	public function testPostfixAfterParens():Void {
		// `(a + b).c` → FieldAccess(ParenExpr(Add(a, b)), c). Parens
		// are an atom form (Case 3 `@:wrap('(', ')')`), so after the
		// core returns `ParenExpr(Add(a, b))` the wrapper's postfix
		// loop runs `.c` on the accumulator. Proves parens compose
		// with postfix through the same wrapper path.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = (a + b).c; }');
		switch decl.init {
			case FieldAccess(ParenExpr(Add(IdentExpr(a), IdentExpr(b))), c):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
				Assert.equals('c', (c : String));
			case null, _:
				Assert.fail('expected FieldAccess(ParenExpr(Add(a, b)), c), got ${decl.init}');
		}
	}

	public function testFieldAccessInModule():Void {
		// End-to-end through `HaxeModuleFastParser`. Confirms the
		// new Postfix strategy ships through the module-root pipeline
		// identically to the isolated `HaxeFastParser`.
		final module:HxModule = HaxeModuleFastParser.parse('class Foo { var x:Int = a.b; }');
		Assert.equals(1, module.decls.length);
		final cls:HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals(1, cls.members.length);
		final decl:HxVarDecl = expectVarMember(cls.members[0]);
		switch decl.init {
			case FieldAccess(IdentExpr(a), b):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
			case null, _:
				Assert.fail('expected FieldAccess(a, b), got ${decl.init}');
		}
	}

	public function testRejectsTrailingDot():Void {
		// `var x:Int = a.;` — postfix loop matches `.`, commits, and
		// the suffix parse for `HxIdentLit` trips on `;` (the regex
		// `[A-Za-z_][A-Za-z0-9_]*` needs at least one identifier
		// character). A ParseError propagates out of the commit.
		Assert.raises(() -> HaxeFastParser.parse('class Foo { var x:Int = a.; }'), ParseError);
	}

	public function testRejectsUnclosedBracket():Void {
		// `var x:Int = a[1;` — postfix loop matches `[`, parses
		// `1` as IntLit, expects `]`, and trips on `;`. Hard error.
		Assert.raises(() -> HaxeFastParser.parse('class Foo { var x:Int = a[1; }'), ParseError);
	}

	private function parseSingleVarDecl(source:String):HxVarDecl {
		final ast:HxClassDecl = HaxeFastParser.parse(source);
		Assert.equals(1, ast.members.length);
		return expectVarMember(ast.members[0]);
	}

	private function expectVarMember(member:HxClassMember):HxVarDecl {
		return switch member {
			case VarMember(decl): decl;
			case _: throw 'expected VarMember, got $member';
		};
	}

	private function expectClassDecl(decl:HxDecl):HxClassDecl {
		return switch decl {
			case ClassDecl(c): c;
		};
	}
}
