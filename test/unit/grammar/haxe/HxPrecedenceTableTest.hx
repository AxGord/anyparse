package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeModuleParser;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.grammar.haxe.HxExpr;
import anyparse.grammar.haxe.HxModule;
import anyparse.grammar.haxe.HxModuleWriter;
import anyparse.grammar.haxe.HxVarDecl;
import utest.Assert;

/**
 * The binary-operator precedence table against the compiler.
 *
 * Every expected tree is what Haxe 4.3.7 itself produced for the source: `Context.parse` in an
 * initialization macro, every binary operator printed parenthesised, an arrow lambda printed as
 * `(x -> body)`. The rows are the relations this grammar used to get wrong — each one failed on
 * the grammar before `fix/grammar-precedence-rest`:
 *
 *  - `...` binds one tier LOOSER than the comparisons (`a ... b == c` is `a ... (b == c)`);
 *  - `in` is the tightest binary operator on its LEFT and takes a whole expression on its
 *    RIGHT (`a + b in c` is `a + (b in c)`, `a in b = c` is `a in (b = c)`);
 *  - the arrow lambda's parameter binds tighter than any operator to its left and its body is a
 *    whole expression (`a ?? x -> b` is `a ?? (x -> b)`).
 *
 * What this grammar still reads differently, all recorded in `docs/decisions.md`: the compiler
 * rotates a ternary OUT of `in`'s right operand (`a in b ? c : d`), binds a metadata annotation to
 * the immediate primary (`@:m a + b` is `(@:m a) + b`) and ends a `cast` at a leading `(e : T)`.
 */
class HxPrecedenceTableTest extends HxTestHelpers {

	public function testBinaryPrecedenceMatchesTheCompiler(): Void {
		final cases: Array<{ src: String, tree: String }> = [
			{ src: 'a % b in c', tree: '(a % (b in c))' },
			{ src: 'a * b in c', tree: '(a * (b in c))' },
			{ src: 'a / b in c', tree: '(a / (b in c))' },
			{ src: 'a + b in c', tree: '(a + (b in c))' },
			{ src: 'a - b in c', tree: '(a - (b in c))' },
			{ src: 'a << b in c', tree: '(a << (b in c))' },
			{ src: 'a >> b in c', tree: '(a >> (b in c))' },
			{ src: 'a >>> b in c', tree: '(a >>> (b in c))' },
			{ src: 'a | b in c', tree: '(a | (b in c))' },
			{ src: 'a & b in c', tree: '(a & (b in c))' },
			{ src: 'a ^ b in c', tree: '(a ^ (b in c))' },
			{ src: 'a ?? b in c', tree: '(a ?? (b in c))' },
			{ src: 'a == b in c', tree: '(a == (b in c))' },
			{ src: 'a != b in c', tree: '(a != (b in c))' },
			{ src: 'a < b in c', tree: '(a < (b in c))' },
			{ src: 'a <= b in c', tree: '(a <= (b in c))' },
			{ src: 'a > b in c', tree: '(a > (b in c))' },
			{ src: 'a >= b in c', tree: '(a >= (b in c))' },
			{ src: 'a ... b == c', tree: '(a ... (b == c))' },
			{ src: 'a ... b != c', tree: '(a ... (b != c))' },
			{ src: 'a ... b < c', tree: '(a ... (b < c))' },
			{ src: 'a ... b <= c', tree: '(a ... (b <= c))' },
			{ src: 'a ... b > c', tree: '(a ... (b > c))' },
			{ src: 'a ... b >= c', tree: '(a ... (b >= c))' },
			{ src: 'a ... b in c', tree: '(a ... (b in c))' },
			{ src: 'a && b in c', tree: '(a && (b in c))' },
			{ src: 'a || b in c', tree: '(a || (b in c))' },
			{ src: 'a in b => c', tree: '(a in (b => c))' },
			{ src: 'a in b in c', tree: '(a in (b in c))' },
			{ src: 'a in b = c', tree: '(a in (b = c))' },
			{ src: 'a in b += c', tree: '(a in (b += c))' },
			{ src: 'a in b -= c', tree: '(a in (b -= c))' },
			{ src: 'a in b *= c', tree: '(a in (b *= c))' },
			{ src: 'a in b /= c', tree: '(a in (b /= c))' },
			{ src: 'a in b %= c', tree: '(a in (b %= c))' },
			{ src: 'a in b <<= c', tree: '(a in (b <<= c))' },
			{ src: 'a in b >>= c', tree: '(a in (b >>= c))' },
			{ src: 'a in b >>>= c', tree: '(a in (b >>>= c))' },
			{ src: 'a in b |= c', tree: '(a in (b |= c))' },
			{ src: 'a in b &= c', tree: '(a in (b &= c))' },
			{ src: 'a in b ^= c', tree: '(a in (b ^= c))' },
			{ src: 'a in b ??= c', tree: '(a in (b ??= c))' },
			{ src: 'a in b &&= c', tree: '(a in (b &&= c))' },
			{ src: 'a in b ||= c', tree: '(a in (b ||= c))' },
			{ src: 'a % x -> b', tree: '(a % (x -> b))' },
			{ src: 'a % x -> b % c', tree: '(a % (x -> (b % c)))' },
			{ src: 'a % b -> c', tree: '(a % (b -> c))' },
			{ src: 'a * x -> b', tree: '(a * (x -> b))' },
			{ src: 'a * x -> b * c', tree: '(a * (x -> (b * c)))' },
			{ src: 'a * b -> c', tree: '(a * (b -> c))' },
			{ src: 'a / x -> b', tree: '(a / (x -> b))' },
			{ src: 'a / x -> b / c', tree: '(a / (x -> (b / c)))' },
			{ src: 'a / b -> c', tree: '(a / (b -> c))' },
			{ src: 'a + x -> b', tree: '(a + (x -> b))' },
			{ src: 'a + x -> b + c', tree: '(a + (x -> (b + c)))' },
			{ src: 'a + b -> c', tree: '(a + (b -> c))' },
			{ src: 'a - x -> b', tree: '(a - (x -> b))' },
			{ src: 'a - x -> b - c', tree: '(a - (x -> (b - c)))' },
			{ src: 'a - b -> c', tree: '(a - (b -> c))' },
			{ src: 'a << x -> b', tree: '(a << (x -> b))' },
			{ src: 'a << x -> b << c', tree: '(a << (x -> (b << c)))' },
			{ src: 'a << b -> c', tree: '(a << (b -> c))' },
			{ src: 'a >> x -> b', tree: '(a >> (x -> b))' },
			{ src: 'a >> x -> b >> c', tree: '(a >> (x -> (b >> c)))' },
			{ src: 'a >> b -> c', tree: '(a >> (b -> c))' },
			{ src: 'a >>> x -> b', tree: '(a >>> (x -> b))' },
			{ src: 'a >>> x -> b >>> c', tree: '(a >>> (x -> (b >>> c)))' },
			{ src: 'a >>> b -> c', tree: '(a >>> (b -> c))' },
			{ src: 'a | x -> b', tree: '(a | (x -> b))' },
			{ src: 'a | x -> b | c', tree: '(a | (x -> (b | c)))' },
			{ src: 'a | b -> c', tree: '(a | (b -> c))' },
			{ src: 'a & x -> b', tree: '(a & (x -> b))' },
			{ src: 'a & x -> b & c', tree: '(a & (x -> (b & c)))' },
			{ src: 'a & b -> c', tree: '(a & (b -> c))' },
			{ src: 'a ^ x -> b', tree: '(a ^ (x -> b))' },
			{ src: 'a ^ x -> b ^ c', tree: '(a ^ (x -> (b ^ c)))' },
			{ src: 'a ^ b -> c', tree: '(a ^ (b -> c))' },
			{ src: 'a ?? x -> b', tree: '(a ?? (x -> b))' },
			{ src: 'a ?? x -> b ?? c', tree: '(a ?? (x -> (b ?? c)))' },
			{ src: 'a ?? b -> c', tree: '(a ?? (b -> c))' },
			{ src: 'a == x -> b', tree: '(a == (x -> b))' },
			{ src: 'a == x -> b == c', tree: '(a == (x -> (b == c)))' },
			{ src: 'a == b -> c', tree: '(a == (b -> c))' },
			{ src: 'a != x -> b', tree: '(a != (x -> b))' },
			{ src: 'a != x -> b != c', tree: '(a != (x -> (b != c)))' },
			{ src: 'a != b -> c', tree: '(a != (b -> c))' },
			{ src: 'a < x -> b', tree: '(a < (x -> b))' },
			{ src: 'a < x -> b < c', tree: '(a < (x -> (b < c)))' },
			{ src: 'a < b -> c', tree: '(a < (b -> c))' },
			{ src: 'a <= x -> b', tree: '(a <= (x -> b))' },
			{ src: 'a <= x -> b <= c', tree: '(a <= (x -> (b <= c)))' },
			{ src: 'a <= b -> c', tree: '(a <= (b -> c))' },
			{ src: 'a > x -> b', tree: '(a > (x -> b))' },
			{ src: 'a > x -> b > c', tree: '(a > (x -> (b > c)))' },
			{ src: 'a > b -> c', tree: '(a > (b -> c))' },
			{ src: 'a >= x -> b', tree: '(a >= (x -> b))' },
			{ src: 'a >= x -> b >= c', tree: '(a >= (x -> (b >= c)))' },
			{ src: 'a >= b -> c', tree: '(a >= (b -> c))' },
			{ src: 'a ... x -> b', tree: '(a ... (x -> b))' },
			{ src: 'a ... x -> b ... c', tree: '(a ... (x -> (b ... c)))' },
			{ src: 'a ... b -> c', tree: '(a ... (b -> c))' },
			{ src: 'a && x -> b', tree: '(a && (x -> b))' },
			{ src: 'a && x -> b && c', tree: '(a && (x -> (b && c)))' },
			{ src: 'a && b -> c', tree: '(a && (b -> c))' },
			{ src: 'a || x -> b', tree: '(a || (x -> b))' },
			{ src: 'a || x -> b || c', tree: '(a || (x -> (b || c)))' },
			{ src: 'a || b -> c', tree: '(a || (b -> c))' },
			{ src: 'a in x -> b', tree: '(a in (x -> b))' },
			{ src: 'a in x -> b in c', tree: '(a in (x -> (b in c)))' },
			{ src: 'a in b -> c', tree: '(a in (b -> c))' }
		];
		for (c in cases) Assert.equals(c.tree, shape(parseSingleVarDecl('class Foo { var x:Int = ${c.src}; }').init), c.src);
	}

	/**
	 * `cast e` takes a whole expression, as the compiler parses it — `cast (x)` included, whose
	 * pair the compiler keeps as the first operand of whatever follows. Source pairs are dropped
	 * from both spellings.
	 */
	public function testCastOperandMatchesTheCompiler(): Void {
		final cases: Array<{ src: String, tree: String }> = [
			{ src: 'cast a + b', tree: '(cast (a + b))' },
			{ src: 'a + cast b + c', tree: '(a + (cast (b + c)))' },
			{ src: 'a == cast b == c', tree: '(a == (cast (b == c)))' },
			{ src: 'cast (a) + b', tree: '(cast (a + b))' },
			{ src: 'cast (a) is T', tree: '(cast (a is T))' },
			{ src: 'cast a ?? b', tree: '(cast (a ?? b))' },
			{ src: 'cast a = b', tree: '(cast (a = b))' },
			{ src: 'cast a ? b : c', tree: '(cast (a ? b : c))' },
			{ src: '-cast a + b', tree: '(-(cast (a + b)))' },
			{ src: 'cast -a + b', tree: '(cast ((-a) + b))' },
			{ src: 'cast x -> y', tree: '(cast (x -> y))' },
			{ src: 'cast cast a + b', tree: '(cast (cast (a + b)))' }
		];
		for (c in cases) Assert.equals(c.tree, shape(parseSingleVarDecl('class Foo { var x:Int = ${c.src}; }').init), c.src);
	}

	/**
	 * The writer parenthesises a constructed tree by the same table, and only where the bare text
	 * would re-read: an asymmetric operator (`->`, `in`), a ternary or a keyword atom
	 * over a whole expression (`cast e`, `untyped e`) ending a LEFT operand runs on
	 * into the operator that follows it however tightly its own root binds, while as a RIGHT
	 * operand it needs nothing. Each written text re-parses to the tree it was written from.
	 */
	public function testWriterParenthesisesAsymmetricOperands(): Void {
		final x: HxExpr = IdentExpr('x');
		final a: HxExpr = IdentExpr('a');
		final b: HxExpr = IdentExpr('b');
		final c: HxExpr = IdentExpr('c');
		final d: HxExpr = IdentExpr('d');
		assertWritten('(x -> b) + c', Add(ThinArrow(x, b), c));
		assertWritten('a ?? x -> b', NullCoal(a, ThinArrow(x, b)));
		assertWritten('a ?? (x -> b) ?? c', NullCoal(NullCoal(a, ThinArrow(x, b)), c));
		assertWritten('(a * x -> b) + c', Add(Mul(a, ThinArrow(x, b)), c));
		assertWritten('(x -> b) ? c : d', Ternary(ThinArrow(x, b), c, d));
		assertWritten('(x -> b) || c', Or(ThinArrow(x, b), c));
		assertWritten('(x -> b) => c', Arrow(ThinArrow(x, b), c));
		assertWritten('x -> b -> c', ThinArrow(x, ThinArrow(b, c)));
		assertWritten('-(x -> b)', Neg(ThinArrow(x, b)));
		assertWritten('(a ? b : c) = d', Assign(Ternary(a, b, c), d));
		assertWritten('a = b ? c : d', Assign(a, Ternary(b, c, d)));
		assertWritten('(a in b) + c', Add(In(a, b), c));
		assertWritten('a + b in c', Add(a, In(b, c)));
		assertWritten('a in b + c', In(a, Add(b, c)));
		assertWritten('(a in b) in c', In(In(a, b), c));
		assertWritten('a...b == c', Interval(a, Eq(b, c)));
		assertWritten('(a...b) == c', Eq(Interval(a, b), c));
		assertWritten('a == b...c', Interval(Eq(a, b), c));
		assertWritten('a && b...c', And(a, Interval(b, c)));
		assertWritten('(a && b)...c', Interval(And(a, b), c));
		assertWritten('(cast a) + b', Add(CastExpr(a), b));
		assertWritten('cast a + b', CastExpr(Add(a, b)));
		assertWritten('a + cast b', Add(a, CastExpr(b)));
		assertWritten('(a * cast b) || c', Or(Mul(a, CastExpr(b)), c));
		assertWritten('(untyped a) ? b : c', Ternary(UntypedExpr(a), b, c));
	}

	/**
	 * A leading `(e : T)` ENDS a cast (`@:fmt(atomOperandWhen)`), so `Is(CastExpr(ECheckTypeExpr), T)`
	 * is written bare — the keyword atom is closed there — while a cast over a whole expression is not.
	 */
	public function testWriterKeepsACheckTypeCastBare(): Void {
		final written: String = HxModuleWriter.write(HaxeModuleParser.parse('class F { var x:Bool = cast (x:Int) is Bool; }'));
		Assert.isTrue(written.indexOf('var x:Bool = cast(x : Int) is Bool;') >= 0, written);
	}

	/**
	 * `RefShape.andLowerPrecedenceKinds` against the parser. A kind belongs to the list exactly when
	 * a node of it, written bare as the LEFT operand of `&&`, re-reads: the `&&` lands inside it.
	 * That is every operator looser than `&&`, the three that bind tight on the left but take a whole
	 * expression on the right (`->`, `in`, `=>`), and `cast`, whose operand is a whole expression.
	 */
	public function testAndLowerPrecedenceKindsMatchTheParser(): Void {
		final listed: Array<String> = new HaxeQueryPlugin().refShape().andLowerPrecedenceKinds ?? [];
		final samples: Array<{ kind: String, src: String }> = [
			{ kind: 'Mul', src: 'a * b' },
			{ kind: 'Div', src: 'a / b' },
			{ kind: 'Mod', src: 'a % b' },
			{ kind: 'Add', src: 'a + b' },
			{ kind: 'Sub', src: 'a - b' },
			{ kind: 'Shl', src: 'a << b' },
			{ kind: 'UShr', src: 'a >>> b' },
			{ kind: 'Shr', src: 'a >> b' },
			{ kind: 'BitOr', src: 'a | b' },
			{ kind: 'BitAnd', src: 'a & b' },
			{ kind: 'BitXor', src: 'a ^ b' },
			{ kind: 'NullCoal', src: 'a ?? b' },
			{ kind: 'Eq', src: 'a == b' },
			{ kind: 'NotEq', src: 'a != b' },
			{ kind: 'LtEq', src: 'a <= b' },
			{ kind: 'GtEq', src: 'a >= b' },
			{ kind: 'Lt', src: 'a < b' },
			{ kind: 'Gt', src: 'a > b' },
			{ kind: 'Interval', src: 'a ... b' },
			{ kind: 'And', src: 'a && b' },
			{ kind: 'Or', src: 'a || b' },
			{ kind: 'In', src: 'a in b' },
			{ kind: 'Assign', src: 'a = b' },
			{ kind: 'AddAssign', src: 'a += b' },
			{ kind: 'SubAssign', src: 'a -= b' },
			{ kind: 'MulAssign', src: 'a *= b' },
			{ kind: 'DivAssign', src: 'a /= b' },
			{ kind: 'ModAssign', src: 'a %= b' },
			{ kind: 'ShlAssign', src: 'a <<= b' },
			{ kind: 'UShrAssign', src: 'a >>>= b' },
			{ kind: 'ShrAssign', src: 'a >>= b' },
			{ kind: 'BitOrAssign', src: 'a |= b' },
			{ kind: 'BitAndAssign', src: 'a &= b' },
			{ kind: 'BitXorAssign', src: 'a ^= b' },
			{ kind: 'NullCoalAssign', src: 'a ??= b' },
			{ kind: 'BoolAndAssign', src: 'a &&= b' },
			{ kind: 'BoolOrAssign', src: 'a ||= b' },
			{ kind: 'ThinArrow', src: 'a -> b' },
			{ kind: 'Arrow', src: 'a => b' },
			{ kind: 'Ternary', src: 'a ? b : c' },
			{ kind: 'CastExpr', src: 'cast a' }
		];
		for (s in samples) {
			final bare: Bool = switch parseSingleVarDecl('class Foo { var x:Bool = ${s.src} && z; }').init {
				case And(l, _): shape(l) == shape(parseSingleVarDecl('class Foo { var x:Bool = ${s.src}; }').init);
				case _: false;
			};
			Assert.equals(!bare, listed.contains(s.kind), '${s.kind}: `${s.src} && z`');
		}
	}

	private function assertWritten(expected: String, tree: HxExpr): Void {
		final mod: HxModule = HaxeModuleParser.parse('class F { var x:Int = 0; }');
		final decl: HxVarDecl = expectVarMember(expectClassDecl(mod.decls[0]).members[0].member);
		decl.init = tree;
		final written: String = HxModuleWriter.write(mod);
		final head: String = 'var x:Int = ';
		final from: Int = written.indexOf(head) + head.length;
		final text: String = written.substring(from, written.lastIndexOf(';'));
		Assert.equals(expected, text);
		Assert.equals(shape(tree), shape(parseSingleVarDecl('class Foo { var x:Int = $text; }').init), text);
	}

	/**
	 * `e` with every binary operator parenthesised and every source pair dropped — the spelling the
	 * compiler probe printed.
	 */
	private static function shape(e: Null<HxExpr>): String {
		return switch e {
			case null: '<null>';
			case IdentExpr(name): (name: String);
			case ParenExpr(inner): shape(inner);
			case Mul(l, r): binary(l, '*', r);
			case Div(l, r): binary(l, '/', r);
			case Mod(l, r): binary(l, '%', r);
			case Add(l, r): binary(l, '+', r);
			case Sub(l, r): binary(l, '-', r);
			case Shl(l, r): binary(l, '<<', r);
			case UShr(l, r): binary(l, '>>>', r);
			case Shr(l, r): binary(l, '>>', r);
			case BitOr(l, r): binary(l, '|', r);
			case BitAnd(l, r): binary(l, '&', r);
			case BitXor(l, r): binary(l, '^', r);
			case NullCoal(l, r): binary(l, '??', r);
			case Eq(l, r): binary(l, '==', r);
			case NotEq(l, r): binary(l, '!=', r);
			case LtEq(l, r): binary(l, '<=', r);
			case GtEq(l, r): binary(l, '>=', r);
			case Lt(l, r): binary(l, '<', r);
			case Gt(l, r): binary(l, '>', r);
			case Interval(l, r): binary(l, '...', r);
			case And(l, r): binary(l, '&&', r);
			case Or(l, r): binary(l, '||', r);
			case In(l, r): binary(l, 'in', r);
			case Assign(l, r): binary(l, '=', r);
			case AddAssign(l, r): binary(l, '+=', r);
			case SubAssign(l, r): binary(l, '-=', r);
			case MulAssign(l, r): binary(l, '*=', r);
			case DivAssign(l, r): binary(l, '/=', r);
			case ModAssign(l, r): binary(l, '%=', r);
			case ShlAssign(l, r): binary(l, '<<=', r);
			case UShrAssign(l, r): binary(l, '>>>=', r);
			case ShrAssign(l, r): binary(l, '>>=', r);
			case BitOrAssign(l, r): binary(l, '|=', r);
			case BitAndAssign(l, r): binary(l, '&=', r);
			case BitXorAssign(l, r): binary(l, '^=', r);
			case NullCoalAssign(l, r): binary(l, '??=', r);
			case BoolAndAssign(l, r): binary(l, '&&=', r);
			case BoolOrAssign(l, r): binary(l, '||=', r);
			case ThinArrow(l, r): binary(l, '->', r);
			case Arrow(l, r): binary(l, '=>', r);
			case Is(l, _): '(${shape(l)} is T)';
			case Ternary(c, t, f): '(${shape(c)} ? ${shape(t)} : ${shape(f)})';
			case Not(x): '(!${shape(x)})';
			case Neg(x): '(-${shape(x)})';
			case CastExpr(x): '(cast ${shape(x)})';
			case UntypedExpr(x): '(untyped ${shape(x)})';
			case _: '<$e>';
		};
	}

	private static function binary(l: HxExpr, op: String, r: HxExpr): String {
		return '(${shape(l)} $op ${shape(r)})';
	}

}
