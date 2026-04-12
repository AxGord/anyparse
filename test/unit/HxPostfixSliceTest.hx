package unit;

import utest.Assert;
import anyparse.grammar.haxe.HaxeFastParser;
import anyparse.grammar.haxe.HaxeModuleFastParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxVarDecl;
import anyparse.runtime.ParseError;

/**
 * Phase 3 postfix-slice (δ + δ2) tests for the macro-generated Haxe
 * parser.
 *
 * Covers three postfix operators — field access `.name`, index access
 * `[expr]`, and function call `f(a, b)` — added on top of the 31
 * binary + 3 unary-prefix baseline. Slice δ1 shipped the Postfix
 * strategy, three-function split, and the basic postfix loop with
 * three shape variants (pair-lit, single-Ref-suffix, wrap-with-recurse).
 * Slice δ2 replaced `CallNoArgs` with `Call(operand, args:Array<HxExpr>)`
 * and added the fourth shape variant (Star-suffix with sep-loop) in
 * `lowerPostfixLoop`.
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
 */
class HxPostfixSliceTest extends HxTestHelpers {

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

	public function testCallZeroArgs():Void {
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = f(); }');
		switch decl.init {
			case Call(IdentExpr(o), args):
				Assert.equals('f', (o : String));
				Assert.equals(0, args.length);
			case null, _:
				Assert.fail('expected Call(IdentExpr(f), []), got ${decl.init}');
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
		// `f()()` → Call(Call(f, []), []). Currying the zero-arg
		// call case.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = f()(); }');
		switch decl.init {
			case Call(Call(IdentExpr(f), inner), outer):
				Assert.equals('f', (f : String));
				Assert.equals(0, inner.length);
				Assert.equals(0, outer.length);
			case null, _:
				Assert.fail('expected Call(Call(f, []), []), got ${decl.init}');
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
		// `f().x` → FieldAccess(Call(f, []), x). Postfix loop
		// handles mixed shapes as they appear.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = f().x; }');
		switch decl.init {
			case FieldAccess(Call(IdentExpr(f), args), x):
				Assert.equals('f', (f : String));
				Assert.equals(0, args.length);
				Assert.equals('x', (x : String));
			case null, _:
				Assert.fail('expected FieldAccess(Call(f, []), x), got ${decl.init}');
		}
	}

	public function testMixedChainFieldCall():Void {
		// `a.b()` → Call(FieldAccess(a, b), []). The idiomatic
		// method-call-on-member case that dominates real Haxe code.
		// Symmetric to `f().x` (testMixedChainCallField) on the
		// other combination — the postfix loop extends `left` with
		// `.b` first, then applies `()` to the result.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a.b(); }');
		switch decl.init {
			case Call(FieldAccess(IdentExpr(a), b), args):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
				Assert.equals(0, args.length);
			case null, _:
				Assert.fail('expected Call(FieldAccess(a, b), []), got ${decl.init}');
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
		// `!f()` → Not(Call(f, [])). Same binding-tightness
		// invariant verified against the zero-arg call form.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Bool = !f(); }');
		switch decl.init {
			case Not(Call(IdentExpr(f), args)):
				Assert.equals('f', (f : String));
				Assert.equals(0, args.length);
			case null, _:
				Assert.fail('expected Not(Call(f, [])), got ${decl.init}');
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
		final decl:HxVarDecl = expectVarMember(cls.members[0].member);
		switch decl.init {
			case FieldAccess(IdentExpr(a), b):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
			case null, _:
				Assert.fail('expected FieldAccess(a, b), got ${decl.init}');
		}
	}

	public function testCallSingleArg():Void {
		// `f(1)` → Call(f, [IntLit(1)]). Simplest non-empty arg list.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = f(1); }');
		switch decl.init {
			case Call(IdentExpr(o), args):
				Assert.equals('f', (o : String));
				Assert.equals(1, args.length);
				switch args[0] {
					case IntLit(v): Assert.equals(1, (v : Int));
					case null, _: Assert.fail('expected IntLit(1), got ${args[0]}');
				}
			case null, _:
				Assert.fail('expected Call(f, [1]), got ${decl.init}');
		}
	}

	public function testCallTwoArgs():Void {
		// `f(a, b)` → Call(f, [IdentExpr(a), IdentExpr(b)]).
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = f(a, b); }');
		switch decl.init {
			case Call(IdentExpr(o), args):
				Assert.equals('f', (o : String));
				Assert.equals(2, args.length);
				switch args[0] {
					case IdentExpr(v): Assert.equals('a', (v : String));
					case null, _: Assert.fail('expected IdentExpr(a)');
				}
				switch args[1] {
					case IdentExpr(v): Assert.equals('b', (v : String));
					case null, _: Assert.fail('expected IdentExpr(b)');
				}
			case null, _:
				Assert.fail('expected Call(f, [a, b]), got ${decl.init}');
		}
	}

	public function testCallThreeArgs():Void {
		// `f(1, 2, 3)` → Call(f, [IntLit(1), IntLit(2), IntLit(3)]).
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = f(1, 2, 3); }');
		switch decl.init {
			case Call(IdentExpr(o), args):
				Assert.equals('f', (o : String));
				Assert.equals(3, args.length);
				switch args[0] {
					case IntLit(v): Assert.equals(1, (v : Int));
					case null, _: Assert.fail('expected IntLit(1)');
				}
				switch args[1] {
					case IntLit(v): Assert.equals(2, (v : Int));
					case null, _: Assert.fail('expected IntLit(2)');
				}
				switch args[2] {
					case IntLit(v): Assert.equals(3, (v : Int));
					case null, _: Assert.fail('expected IntLit(3)');
				}
			case null, _:
				Assert.fail('expected Call(f, [1, 2, 3]), got ${decl.init}');
		}
	}

	public function testCallWithExprArgs():Void {
		// `f(a + 1, b * 2)` → Call(f, [Add(a, 1), Mul(b, 2)]).
		// Arguments are full expressions — the inner parse enters
		// `parseHxExpr` (the Pratt loop), resetting precedence.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = f(a + 1, b * 2); }');
		switch decl.init {
			case Call(IdentExpr(o), args):
				Assert.equals('f', (o : String));
				Assert.equals(2, args.length);
				switch args[0] {
					case Add(IdentExpr(a), IntLit(one)):
						Assert.equals('a', (a : String));
						Assert.equals(1, (one : Int));
					case null, _: Assert.fail('expected Add(a, 1), got ${args[0]}');
				}
				switch args[1] {
					case Mul(IdentExpr(b), IntLit(two)):
						Assert.equals('b', (b : String));
						Assert.equals(2, (two : Int));
					case null, _: Assert.fail('expected Mul(b, 2), got ${args[1]}');
				}
			case null, _:
				Assert.fail('expected Call(f, [Add(a, 1), Mul(b, 2)]), got ${decl.init}');
		}
	}

	public function testCallChainWithArgs():Void {
		// `f(1)(2)` → Call(Call(f, [1]), [2]). Chained calls with
		// arguments — the left-recursive postfix loop applies `(1)`
		// first, then `(2)` on the result.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = f(1)(2); }');
		switch decl.init {
			case Call(Call(IdentExpr(f), inner), outer):
				Assert.equals('f', (f : String));
				Assert.equals(1, inner.length);
				Assert.equals(1, outer.length);
				switch inner[0] {
					case IntLit(v): Assert.equals(1, (v : Int));
					case null, _: Assert.fail('expected IntLit(1)');
				}
				switch outer[0] {
					case IntLit(v): Assert.equals(2, (v : Int));
					case null, _: Assert.fail('expected IntLit(2)');
				}
			case null, _:
				Assert.fail('expected Call(Call(f, [1]), [2]), got ${decl.init}');
		}
	}

	public function testMethodCallWithArgs():Void {
		// `a.b(1, 2)` → Call(FieldAccess(a, b), [1, 2]). The
		// idiomatic method-call-with-arguments pattern that dominates
		// real Haxe code.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a.b(1, 2); }');
		switch decl.init {
			case Call(FieldAccess(IdentExpr(a), b), args):
				Assert.equals('a', (a : String));
				Assert.equals('b', (b : String));
				Assert.equals(2, args.length);
				switch args[0] {
					case IntLit(v): Assert.equals(1, (v : Int));
					case null, _: Assert.fail('expected IntLit(1)');
				}
				switch args[1] {
					case IntLit(v): Assert.equals(2, (v : Int));
					case null, _: Assert.fail('expected IntLit(2)');
				}
			case null, _:
				Assert.fail('expected Call(FieldAccess(a, b), [1, 2]), got ${decl.init}');
		}
	}

	public function testCallWithSpaces():Void {
		// `f( a , b )` — whitespace around arguments and commas.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = f( a , b ); }');
		switch decl.init {
			case Call(IdentExpr(o), args):
				Assert.equals('f', (o : String));
				Assert.equals(2, args.length);
				switch args[0] {
					case IdentExpr(v): Assert.equals('a', (v : String));
					case null, _: Assert.fail('expected IdentExpr(a)');
				}
				switch args[1] {
					case IdentExpr(v): Assert.equals('b', (v : String));
					case null, _: Assert.fail('expected IdentExpr(b)');
				}
			case null, _:
				Assert.fail('expected Call(f, [a, b]), got ${decl.init}');
		}
	}

	public function testCallInIndex():Void {
		// `a[f(1)]` → IndexAccess(a, Call(f, [1])). Call inside
		// index — the index expression recursion enters the Pratt
		// loop, which returns Call as a postfix-extended atom.
		final decl:HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a[f(1)]; }');
		switch decl.init {
			case IndexAccess(IdentExpr(a), Call(IdentExpr(f), args)):
				Assert.equals('a', (a : String));
				Assert.equals('f', (f : String));
				Assert.equals(1, args.length);
				switch args[0] {
					case IntLit(v): Assert.equals(1, (v : Int));
					case null, _: Assert.fail('expected IntLit(1)');
				}
			case null, _:
				Assert.fail('expected IndexAccess(a, Call(f, [1])), got ${decl.init}');
		}
	}

	public function testRejectsTrailingComma():Void {
		// `f(a,)` — trailing comma leaves `)` as the next token,
		// which fails the argument expression parse and throws.
		Assert.raises(() -> HaxeFastParser.parse('class Foo { var x:Int = f(a,); }'), ParseError);
	}

	public function testCallInModule():Void {
		// End-to-end through `HaxeModuleFastParser`. Confirms the
		// Star-suffix postfix variant ships through the module-root
		// pipeline.
		final module:HxModule = HaxeModuleFastParser.parse('class Foo { var x:Int = f(1, 2); }');
		Assert.equals(1, module.decls.length);
		final cls:HxClassDecl = expectClassDecl(module.decls[0]);
		Assert.equals(1, cls.members.length);
		final decl:HxVarDecl = expectVarMember(cls.members[0].member);
		switch decl.init {
			case Call(IdentExpr(f), args):
				Assert.equals('f', (f : String));
				Assert.equals(2, args.length);
			case null, _:
				Assert.fail('expected Call(f, [_, _]), got ${decl.init}');
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

}
