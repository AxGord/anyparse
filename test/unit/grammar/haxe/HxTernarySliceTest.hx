package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeParser;
import anyparse.grammar.haxe.HxClassDecl;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxFnDecl;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.grammar.haxe.HxStatement;
import anyparse.grammar.haxe.HxVarDecl;
import anyparse.runtime.ParseError;
import haxe.Exception;
import utest.Assert;

/**
 * Phase 3 ternary + null-coalescing slice tests for the macro-generated
 * Haxe parser.
 *
 * Covers:
 *  - `??` (null-coalescing, binary infix, prec 5, left-assoc — Haxe 4.3 own slot)
 *  - `? :` (ternary, mixfix, prec 1, right-assoc by construction)
 *  - Precedence renumber (assignments from prec 1 to prec 0)
 *  - D33 longest-match disambiguation: `??` (len 2) before `?` (len 1)
 */
class HxTernarySliceTest extends HxTestHelpers {

	// ---- ?? basics ----

	public function testNullCoalSmoke(): Void {
		final decl: HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a ?? b; }');
		switch decl.init {
			case NullCoal(IdentExpr(l), IdentExpr(r)):
				Assert.equals('a', (l: String));
				Assert.equals('b', (r: String));
			case null, _:
				Assert.fail('expected NullCoal, got ${decl.init}');
		}
	}

	public function testNullCoalLeftAssoc(): Void {
		final decl: HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a ?? b ?? c; }');
		switch decl.init {
			case NullCoal(NullCoal(IdentExpr(l), IdentExpr(m)), IdentExpr(r)):
				Assert.equals('a', (l: String));
				Assert.equals('b', (m: String));
				Assert.equals('c', (r: String));
			case null, _:
				Assert.fail('expected NullCoal(NullCoal(a, b), c), got ${decl.init}');
		}
	}

	public function testNullCoalLooserThanAdd(): Void {
		final decl: HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a ?? b + c; }');
		switch decl.init {
			case NullCoal(IdentExpr(_), Add(IdentExpr(_), IdentExpr(_))):
				Assert.pass();
			case null, _:
				Assert.fail('expected NullCoal(a, Add(b, c)), got ${decl.init}');
		}
	}

	public function testAddTighterThanNullCoal(): Void {
		final decl: HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a + b ?? c; }');
		switch decl.init {
			case NullCoal(Add(IdentExpr(_), IdentExpr(_)), IdentExpr(r)):
				Assert.equals('c', (r: String));
			case null, _:
				Assert.fail('expected NullCoal(Add(a, b), c), got ${decl.init}');
		}
	}

	public function testNullCoalTighterThanOr(): Void {
		final decl: HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a || b ?? c; }');
		switch decl.init {
			case Or(IdentExpr(l), NullCoal(IdentExpr(_), IdentExpr(_))):
				Assert.equals('a', (l: String));
			case null, _:
				Assert.fail('expected Or(a, NullCoal(b, c)), got ${decl.init}');
		}
	}

	/**
	 * Every relation of `??` against the compiler. Each expected tree is what Haxe 4.3.7 itself
	 * produced for the source (`Context.parse` in an initialization macro, every binary operator
	 * printed parenthesised): `??` is left-associative, binds tighter than the comparisons, `...`,
	 * `&&`, `||`, `?:`, `=>` and assignment, and looser than the bitwise, shift and arithmetic
	 * tiers; `is` binds tighter than every binary operator.
	 */
	public function testNullCoalPrecedenceMatchesTheCompiler(): Void {
		final cases: Array<{ src: String, tree: String }> = [
			{ src: 'a ?? b ?? c ?? d', tree: '(((a ?? b) ?? c) ?? d)' },
			{ src: 'a ?? b == c', tree: '((a ?? b) == c)' },
			{ src: 'a == b ?? c', tree: '(a == (b ?? c))' },
			{ src: 'a ?? b != c', tree: '((a ?? b) != c)' },
			{ src: 'a < b ?? c', tree: '(a < (b ?? c))' },
			{ src: 'a ?? b == c ?? d', tree: '((a ?? b) == (c ?? d))' },
			{ src: 'a ?? b && c', tree: '((a ?? b) && c)' },
			{ src: 'a && b ?? c', tree: '(a && (b ?? c))' },
			{ src: 'a ?? b || c', tree: '((a ?? b) || c)' },
			{ src: 'a || b ?? c && d', tree: '(a || ((b ?? c) && d))' },
			{ src: 'a ?? b ... c ?? d', tree: '((a ?? b) ... (c ?? d))' },
			{ src: 'a ?? b + c', tree: '(a ?? (b + c))' },
			{ src: 'a * b ?? c', tree: '((a * b) ?? c)' },
			{ src: 'a ?? b % c', tree: '(a ?? (b % c))' },
			{ src: 'a ?? b | c', tree: '(a ?? (b | c))' },
			{ src: 'a & b ?? c', tree: '((a & b) ?? c)' },
			{ src: 'a ?? b << c', tree: '(a ?? (b << c))' },
			{ src: 'a ?? b ? c ?? d : e ?? f', tree: '((a ?? b) ? (c ?? d) : (e ?? f))' },
			{ src: 'x = a ?? b', tree: '(x = (a ?? b))' },
			{ src: 'x ??= a ?? b', tree: '(x ??= (a ?? b))' },
			{ src: 'a ?? b => c', tree: '((a ?? b) => c)' },
			{ src: 'a ?? b is T', tree: '(a ?? (b is T))' },
			{ src: 'a is T ?? b', tree: '((a is T) ?? b)' },
			{ src: 'a + b is T', tree: '(a + (b is T))' },
			{ src: 'a is T % b', tree: '((a is T) % b)' },
			{ src: '!a is T', tree: '((!a) is T)' },
			{ src: '!a ?? b', tree: '((!a) ?? b)' },
		];
		for (c in cases) Assert.equals(c.tree, shape(parseSingleVarDecl('class Foo { var x:Int = ${c.src}; }').init), c.src);
	}

	/**
	 * The writer parenthesises a constructed tree by the same table: an operand that would re-read
	 * bare gets its pair, a redundant one does not. Each tree is built from a parenthesised parse
	 * with the pair stripped, so the input is the same tree whatever the grammar's precedence.
	 */
	public function testWriterParenthesisesNullCoalByPrecedence(): Void {
		Assert.equals('a ?? (b == c)', writtenBare('a ?? (b == c)', true));
		Assert.equals('a ?? b == c', writtenBare('(a ?? b) == c', false));
		Assert.equals('a ?? (b && c)', writtenBare('a ?? (b && c)', true));
		Assert.equals('a ?? b | c', writtenBare('a ?? (b | c)', true));
		Assert.equals('a | b ?? c', writtenBare('(a | b) ?? c', false));
		Assert.equals('(a ?? b) | c', writtenBare('(a ?? b) | c', false));
		Assert.equals('(a + b) is T', writtenBare('(a + b) is T', false));
	}

	// ---- ternary basics ----

	public function testTernarySmoke(): Void {
		final decl: HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a ? b : c; }');
		switch decl.init {
			case Ternary(IdentExpr(cond), IdentExpr(then), IdentExpr(els)):
				Assert.equals('a', (cond: String));
				Assert.equals('b', (then: String));
				Assert.equals('c', (els: String));
			case null, _:
				Assert.fail('expected Ternary(a, b, c), got ${decl.init}');
		}
	}

	public function testTernaryRightAssoc(): Void {
		final decl: HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a ? b : c ? d : e; }');
		switch decl.init {
			case Ternary(IdentExpr(cond), IdentExpr(then), Ternary(IdentExpr(c2), IdentExpr(t2), IdentExpr(e2))):
				Assert.equals('a', (cond: String));
				Assert.equals('b', (then: String));
				Assert.equals('c', (c2: String));
				Assert.equals('d', (t2: String));
				Assert.equals('e', (e2: String));
			case null, _:
				Assert.fail('expected Ternary(a, b, Ternary(c, d, e)), got ${decl.init}');
		}
	}

	public function testTernaryOperatorInMiddle(): Void {
		final decl: HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a ? b + c : d; }');
		switch decl.init {
			case Ternary(IdentExpr(_), Add(IdentExpr(_), IdentExpr(_)), IdentExpr(e)):
				Assert.equals('d', (e: String));
			case null, _:
				Assert.fail('expected Ternary(a, Add(b, c), d), got ${decl.init}');
		}
	}

	public function testTernaryOperatorInCondition(): Void {
		final decl: HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a + b ? c : d; }');
		switch decl.init {
			case Ternary(Add(IdentExpr(_), IdentExpr(_)), IdentExpr(t), IdentExpr(e)):
				Assert.equals('c', (t: String));
				Assert.equals('d', (e: String));
			case null, _:
				Assert.fail('expected Ternary(Add(a, b), c, d), got ${decl.init}');
		}
	}

	public function testTernaryOperatorInRight(): Void {
		final decl: HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a ? b : c + d; }');
		switch decl.init {
			case Ternary(IdentExpr(_), IdentExpr(_), Add(IdentExpr(_), IdentExpr(r))):
				Assert.equals('d', (r: String));
			case null, _:
				Assert.fail('expected Ternary(a, b, Add(c, d)), got ${decl.init}');
		}
	}

	// ---- cross-operator ----

	public function testNullCoalTighterThanTernary(): Void {
		final decl: HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a ?? b ? c : d; }');
		switch decl.init {
			case Ternary(NullCoal(IdentExpr(_), IdentExpr(_)), IdentExpr(t), IdentExpr(e)):
				Assert.equals('c', (t: String));
				Assert.equals('d', (e: String));
			case null, _:
				Assert.fail('expected Ternary(NullCoal(a, b), c, d), got ${decl.init}');
		}
	}

	public function testNullCoalInTernaryRight(): Void {
		final decl: HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a ? b : c ?? d; }');
		switch decl.init {
			case Ternary(IdentExpr(_), IdentExpr(_), NullCoal(IdentExpr(_), IdentExpr(r))):
				Assert.equals('d', (r: String));
			case null, _:
				Assert.fail('expected Ternary(a, b, NullCoal(c, d)), got ${decl.init}');
		}
	}

	public function testAssignInTernaryRight(): Void {
		final decl: HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a ? b : c = d; }');
		switch decl.init {
			case Ternary(IdentExpr(_), IdentExpr(_), Assign(IdentExpr(_), IdentExpr(r))):
				Assert.equals('d', (r: String));
			case null, _:
				Assert.fail('expected Ternary(a, b, Assign(c, d)), got ${decl.init}');
		}
	}

	// ---- integration ----

	public function testTernaryInReturnStmt(): Void {
		final ast: HxClassDecl = HaxeParser.parse('class Foo { function f():Int { return a ? b : c; } }');
		Assert.equals(1, ast.members.length);
		final fn: HxFnDecl = expectFnMember(ast.members[0].member);
		final stmts: Array<HxStatement> = fnBodyStmts(fn);
		Assert.equals(1, stmts.length);
		switch stmts[0] {
			case ReturnStmt(Ternary(IdentExpr(cond), IdentExpr(then), IdentExpr(els))):
				Assert.equals('a', (cond: String));
				Assert.equals('b', (then: String));
				Assert.equals('c', (els: String));
			case _:
				Assert.fail('expected ReturnStmt with Ternary');
		}
	}

	public function testTernaryThroughModuleRoot(): Void {
		final mod: HxModule = HaxeModuleParser.parse('class A { var x:Int = a ?? b ? c : d; }');
		Assert.equals(1, mod.decls.length);
		final cls: HxClassDecl = expectClassDecl(mod.decls[0]);
		Assert.equals(1, cls.members.length);
		final decl: HxVarDecl = expectVarMember(cls.members[0].member);
		switch decl.init {
			case Ternary(NullCoal(_, _), _, _):
				Assert.pass();
			case null, _:
				Assert.fail('expected Ternary(NullCoal(...), ..., ...), got ${decl.init}');
		}
	}

	// ---- assignment renumber sanity ----

	public function testAssignStillWorks(): Void {
		final decl: HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a = b; }');
		switch decl.init {
			case Assign(IdentExpr(l), IdentExpr(r)):
				Assert.equals('a', (l: String));
				Assert.equals('b', (r: String));
			case null, _:
				Assert.fail('expected Assign, got ${decl.init}');
		}
	}

	public function testAssignRightAssocChainStillWorks(): Void {
		final decl: HxVarDecl = parseSingleVarDecl('class Foo { var x:Int = a = b = c; }');
		switch decl.init {
			case Assign(IdentExpr(_), Assign(IdentExpr(_), IdentExpr(r))):
				Assert.equals('c', (r: String));
			case null, _:
				Assert.fail('expected Assign(a, Assign(b, c)), got ${decl.init}');
		}
	}

	// ---- rejections ----

	public function testRejectsMissingMiddleAndColon(): Void {
		Assert.raises(HaxeParser.parse.bind('class Foo { var x:Int = a ? ; }'), ParseError);
	}

	public function testRejectsMissingColon(): Void {
		Assert.raises(HaxeParser.parse.bind('class Foo { var x:Int = a ? b ; }'), ParseError);
	}

	public function testRejectsMissingRightOperand(): Void {
		Assert.raises(HaxeParser.parse.bind('class Foo { var x:Int = a ? b : ; }'), ParseError);
	}

	/**
	 * `src` parsed, the pair around its RIGHT (`right`) or LEFT operand dropped from the tree, and
	 * the result written back — the initializer text alone.
	 */
	private function writtenBare(src: String, right: Bool): String {
		final mod: HxModule = HaxeModuleParser.parse('class F { var x:Int = $src; }');
		final decl: HxVarDecl = expectVarMember(expectClassDecl(mod.decls[0]).members[0].member);
		decl.init = switch decl.init {
			case NullCoal(ParenExpr(l), r) if (!right): NullCoal(l, r);
			case NullCoal(l, ParenExpr(r)) if (right): NullCoal(l, r);
			case Eq(ParenExpr(l), r) if (!right): Eq(l, r);
			case BitOr(ParenExpr(l), r) if (!right): BitOr(l, r);
			case Is(ParenExpr(l), t) if (!right): Is(l, t);
			case null, _: throw new Exception('no parenthesised operand to strip in $src');
		};
		final written: String = HxModuleWriter.write(mod);
		final head: String = 'var x:Int = ';
		final from: Int = written.indexOf(head) + head.length;
		return written.substring(from, written.indexOf(';', from));
	}

	/** `e` with every binary operator parenthesised — the spelling the compiler probe printed. */
	private static function shape(e: Null<HxExpr>): String {
		return switch e {
			case null: '<null>';
			case IdentExpr(name): (name: String);
			case NullCoal(l, r): binary(l, '??', r);
			case Eq(l, r): binary(l, '==', r);
			case NotEq(l, r): binary(l, '!=', r);
			case Lt(l, r): binary(l, '<', r);
			case And(l, r): binary(l, '&&', r);
			case Or(l, r): binary(l, '||', r);
			case BitOr(l, r): binary(l, '|', r);
			case BitAnd(l, r): binary(l, '&', r);
			case Shl(l, r): binary(l, '<<', r);
			case Add(l, r): binary(l, '+', r);
			case Mul(l, r): binary(l, '*', r);
			case Mod(l, r): binary(l, '%', r);
			case Interval(l, r): binary(l, '...', r);
			case Assign(l, r): binary(l, '=', r);
			case NullCoalAssign(l, r): binary(l, '??=', r);
			case Arrow(l, r): binary(l, '=>', r);
			case Is(l, _): '(${shape(l)} is T)';
			case Ternary(c, t, f): '(${shape(c)} ? ${shape(t)} : ${shape(f)})';
			case Not(x): '(!${shape(x)})';
			case _: '<$e>';
		};
	}

	private static function binary(l: HxExpr, op: String, r: HxExpr): String {
		return '(${shape(l)} $op ${shape(r)})';
	}

}
