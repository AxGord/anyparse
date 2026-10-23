package unit.query;

import anyparse.query.OperatorOverloads.OperatorResult;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeTerm.TypeEnd;
import unit.CheckFixture;

/**
 * The `@:op` overload a binary operator over an abstract selects (`OperatorOverloads`, step T4b of the typer by
 * specification; `operators.ml`), each answer first compiled on Haxe 4.3.7 `--interp` and `-js` (FU24 probes,
 * `docs/decisions.md`): the left operand's abstract first, then the right one's, the overloads in declaration order, the
 * first one taking the operands binding — and no answer for anything not decided.
 */
@:nullSafety(Strict)
class OperatorOverloadsTest extends Test {

	/** Abstracts overloading `-` and `*` in each of the shapes the walk decides, and in shapes it leaves undecided. */
	private static final FIXTURE: String = 'package p;\n\nabstract U(Int) from Int to Float {\n'
		+ '\t@:op(A - B) static function sub(a:U, b:U):U return 0;\n}\n\nabstract S(Int) from Int to Float {\n'
		+ '\t@:op(A - B) static function sub(a:S, b:S):String return \'s\';\n\n'
		+ '\t@:op(A - B) static function subF(a:S, b:Float):S return 0;\n}\n\nabstract C(Int) from Int {\n'
		+ '\t@:commutative @:op(A * B) static function mulI(a:C, b:Int):String return \'s\';\n}\n\nabstract N(Int) from Int {\n'
		+ '\t@:op(A * B) static function mulI(a:N, b:Int):String return \'s\';\n}\n\nabstract R(Int) from Int {\n'
		+ '\t@:op(A - B) static function rsub(a:Int, b:R):String return \'s\';\n}\n\nabstract X(Int) from Int to Int {\n'
		+ '\t@:op(A - B) static function subI(a:Int, b:X):String return \'s\';\n\n'
		+ '\t@:op(A - B) static function sub(a:X, b:X):X return 0;\n}\n\n#if js\nabstract D(Int) from Int {\n'
		+ '\t@:op(A - B) static function sub(a:D, b:D):String return \'s\';\n}\n#else\nabstract D(Int) from Int {\n'
		+ '\t@:op(A - B) static function sub(a:D, b:D):D return 0;\n}\n#end\n\nabstract G(Int) from Int {\n#if js\n'
		+ '\t@:op(A - B) static function sub(a:G, b:G):String return \'s\';\n#end\n}\n\nabstract I(Int) from Int {\n'
		+ '\t@:op(A - B) function sub(b:I):String return \'s\';\n}\n\nabstract M(Int) from Int {\n'
		+ '\t@:op(A - B) static function sub(a:M, b:Array<Int>):String return \'s\';\n}\n\nclass A0 {}\n\nabstract Q(Int) {\n#if js\n'
		+ '\t@:from static function fromA(a:A0):Q return null;\n#end\n}\n\nabstract Z(Int) {\n'
		+ '\t@:op(A - B) static function sub(a:Z, b:Q):String return \'s\';\n\n'
		+ '\t@:op(A - B) static function subA(a:Z, b:A0):Z return null;\n}\n\nabstract C3(Int) {\n'
		+ '\t@:commutative @:op(A * B) static function mulX(a:Int, b:C3):String return \'s\';\n\n'
		+ '\t@:op(A * B) static function mulD(a:C3, b:Dynamic):C3 return null;\n}\n\nabstract RA(Int) {\n'
		+ '\t@:op(A - B) static function sub(a:RA, b:RA):Array<Int> return null;\n}\n';

	/** `U - U` takes `sub` and yields `U`; `U - Int` casts the `Int` to `U` through `from Int`. */
	@:pin('control') @:killer('M-OPS-LEFT-OFF')
	public function testTheLeftOperandsOverloadTypesTheOperation(): Void {
		final index: SymbolIndex = indexOf();
		Assert.equals('U', resultName(index, 'Sub', decl(index, 'U'), decl(index, 'U')));
		Assert.equals('U', resultName(index, 'Sub', decl(index, 'U'), Core('Int')), 'the right operand cast');
		Assert.isNull(result(index, 'Add', decl(index, 'U'), decl(index, 'U')), 'no overload of the operator');
	}

	/**
	 * The overloads are tried in declaration order and the first taking the operands binds: `S - S` takes `sub`
	 * (`String`) though `subF` takes them too; `X - X` passes `subI` over — its first parameter must EQUAL the left
	 * operand's type, a cast is not enough — and takes `sub` (`X`).
	 */
	@:pin('control') @:killer('M-OPS-FIRST-TAKEN') @:killer('M-OPS-EXACT-EQUAL')
	public function testTheFirstOverloadTakingTheOperandsBinds(): Void {
		final index: SymbolIndex = indexOf();
		Assert.equals('String', resultName(index, 'Sub', decl(index, 'S'), decl(index, 'S')));
		Assert.equals('X', resultName(index, 'Sub', decl(index, 'X'), decl(index, 'X')), 'the first parameter is exact');
	}

	/**
	 * With no overload on the left operand's type, the right one's abstract is asked: `Int - R` takes `rsub`; a
	 * `@:commutative` overload takes the operands swapped (`Int * C`), one without the annotation does not (`Int * N`).
	 */
	@:pin('control') @:killer('M-OPS-RIGHT-OFF') @:killer('M-OPS-COMMUTATIVE-OFF') @:killer('M-SHAPE-COMMUTATIVE-UNSET')
	public function testTheRightOperandsOverloadAndACommutativeOne(): Void {
		final index: SymbolIndex = indexOf();
		Assert.equals('String', resultName(index, 'Sub', Core('Int'), decl(index, 'R')), 'the right abstract');
		Assert.equals('String', resultName(index, 'Mul', decl(index, 'C'), Core('Int')), 'as written');
		Assert.equals('String', resultName(index, 'Mul', Core('Int'), decl(index, 'C')), 'swapped');
		Assert.isNull(result(index, 'Mul', Core('Int'), decl(index, 'N')), 'not commutative: the language\'s own `*`');
	}

	/**
	 * No answer where the walk does not decide: branches that yield different types (`D - D` is `D` on `--interp`, a
	 * `String` on `-js`), an overload under `#if`, an instance overload, a parameter type the cast graph does not model,
	 * a return type it does not model, an operand whose cast another build decides (`Z - A0` takes `sub` where `Q`'s
	 * `@:from` is, `subA` elsewhere), and an operand of a type it does not model in a swapped `@:commutative` overload.
	 */
	@:pin('control') @:killer('M-OPS-BRANCHES-AGREE') @:killer('M-OPS-GUARDED') @:killer('M-OPS-INSTANCE')
	@:killer('M-CASTS-BRANCH-MEMBERS') @:killer('M-OPS-RETURN-OPEN') @:killer('M-OPS-MAYFIT') @:killer('M-OPS-OPEN-OPERAND')
	public function testAnOverloadNotDecidedInEveryBuildAnswersNothing(): Void {
		final index: SymbolIndex = indexOf();
		Assert.isNull(result(index, 'Sub', decl(index, 'D'), decl(index, 'D')), 'the branches disagree');
		Assert.isNull(result(index, 'Sub', decl(index, 'G'), decl(index, 'G')), 'an overload under `#if`');
		Assert.isNull(result(index, 'Sub', decl(index, 'I'), decl(index, 'I')), 'an instance overload');
		Assert.isNull(result(index, 'Sub', decl(index, 'M'), decl(index, 'M')), 'a parameter of a generic type');
		Assert.isNull(result(index, 'Sub', decl(index, 'RA'), decl(index, 'RA')), 'a generic return type');
		Assert.isNull(result(index, 'Sub', decl(index, 'Z'), decl(index, 'A0')), 'a cast another build decides');
		Assert.isNull(result(index, 'Mul', decl(index, 'C3'), Open), 'an operand of an unmodelled type, swapped');
	}

	private static function result(index: SymbolIndex, kind: String, left: TypeEnd, right: TypeEnd): Null<OperatorResult> {
		return index.typing.operators.binaryResult(kind, left, right);
	}

	/** The name of the type `result` yields: a declaration's or a core type's; null for no answer. */
	private static function resultName(index: SymbolIndex, kind: String, left: TypeEnd, right: TypeEnd): Null<String> {
		final found: Null<OperatorResult> = result(index, kind, left, right);
		return found == null
			? null
			: switch found.end {
				case Declared(r): r.type.name;
				case Core(name): name;
				case _: null;
			};
	}

	/** The fixture's declaration named `name`, as an end. */
	private static function decl(index: SymbolIndex, name: String): TypeEnd {
		final found: Null<ResolvedType> = index.refs.findDeclaredType('p/M.hx', name);
		if (found == null) throw 'no declaration $name';
		return Declared(found);
	}

	private static function indexOf(): SymbolIndex {
		return CheckFixture.index([{ file: 'p/M.hx', source: FIXTURE }], new HaxeQueryPlugin());
	}

}
