package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.AncestorTable;
import anyparse.query.ArgumentSlots.ArgumentFit;
import anyparse.query.SymbolIndex;
import unit.CheckFixture;
import utest.Assert;
import utest.Test;

/**
 * The typing service's signature tables of step T2 (`docs/typing-service.md`): the ancestor table — what a declaration's
 * supertype chain passes to an ancestor's type parameters (`AncestorTable.argumentsTo`) — and the unification of plain
 * types it answers (`Unification.unifies`), each against the compiler's `tUnification.ml` (Haxe 4.3.7).
 */
@:nullSafety(Strict)
class UnificationTest extends Test {

	/** The chain most fixtures here walk: a generic base, a generic middle passing an applied type, a concrete leaf. */
	private static final CHAIN: String = 'package p;\n\nclass Base<T> {}\n\nclass Mid<U> extends Base<Array<U>> {}\n\n'
		+ 'class Leaf extends Mid<String> {}\n\nclass Raw extends Base {}\n';

	/** Classes, an interface, enums, an abstract, a generic class, an alias and a class whose superclass the index lacks. */
	private static final PLAIN: String = 'package p;\n\ninterface I {}\n\nclass A implements I {}\n\nclass B extends A {}\n\n'
		+ 'class Other {}\n\nenum E {\n\tE1;\n}\n\nenum F {\n\tF1;\n}\n\nabstract Ab(Int) {}\n\nclass G<T> {}\n\ntypedef TA = A;\n\n'
		+ 'class Out extends Missing {}\n';

	@:pin('control') @:killer('M-ANCESTOR-ARGS-OFF')
	public function testTheChainPassesItsArgumentsInTheStartsTerms(): Void {
		final index: SymbolIndex = indexOf(CHAIN);
		final table: AncestorTable = index.typing.ancestors;
		Assert.same(['Array<String>'], table.argumentsTo(decl(index, 'Leaf'), decl(index, 'Base')), 'through Mid');
		Assert.same(['Array<U>'], table.argumentsTo(decl(index, 'Mid'), decl(index, 'Base')), 'in Mid\'s terms');
		Assert.same(['U'], table.argumentsTo(decl(index, 'Mid'), decl(index, 'Mid')), 'a type\'s own parameters');
		Assert.isNull(table.argumentsTo(decl(index, 'Base'), decl(index, 'Leaf')), 'not an ancestor');
	}

	@:pin('control') @:killer('M-ANCESTOR-SHORT-ARGS')
	public function testALinkWritingTooFewArgumentsBindsNothing(): Void {
		final index: SymbolIndex = indexOf(CHAIN);
		Assert.isNull(index.typing.ancestors.argumentsTo(decl(index, 'Raw'), decl(index, 'Base')), '`extends Base` binds no T');
	}

	@:pin('control') @:killer('M-UNIFY-CHAIN-OPEN')
	public function testAClassUnifiesWithWhatItsChainReaches(): Void {
		final index: SymbolIndex = indexOf(PLAIN);
		Assert.equals(Fits, unifies(index, 'B', 'A'), 'a subclass');
		Assert.equals(Fits, unifies(index, 'B', 'I'), 'an interface its superclass implements');
		Assert.equals(Misfits, unifies(index, 'A', 'B'), 'a superclass is no subclass');
		Assert.equals(Misfits, unifies(index, 'A', 'Other'), 'an unrelated class');
		Assert.equals(MayFit, unifies(index, 'Out', 'A'), 'a superclass the index does not resolve');
	}

	@:pin('control') @:killer('M-UNIFY-CHAIN-OPEN')
	public function testAnEnumUnifiesWithItselfAlone(): Void {
		final index: SymbolIndex = indexOf(PLAIN);
		Assert.equals(Fits, unifies(index, 'E', 'E'), 'itself');
		Assert.equals(Misfits, unifies(index, 'E', 'F'), 'another enum');
		Assert.equals(Misfits, unifies(index, 'A', 'E'), 'a class is no enum');
	}

	@:pin('control') @:killer('M-UNIFY-ALIAS-STOP')
	public function testOnlyPlainTypesAreDecided(): Void {
		final index: SymbolIndex = indexOf(PLAIN);
		Assert.equals(Fits, unifies(index, 'B', 'TA'), 'an alias of a plain class is followed');
		Assert.equals(MayFit, unifies(index, 'A', 'Ab'), 'an abstract: its casts are not modelled');
		Assert.equals(MayFit, unifies(index, 'G', 'A'), 'a type with parameters');
	}

	@:pin('control') @:killer('M-UNIFY-GUARDED-PLAIN')
	public function testADeclarationUnderIfIsNotPlain(): Void {
		final index: SymbolIndex = indexOf('package p;\n\nclass A {}\n\n#if x\nclass P extends A {}\n#else\nclass P {}\n#end\n');
		Assert.equals(MayFit, unifies(index, 'P', 'A'), 'its branches extend different types');
	}

	private static function unifies(index: SymbolIndex, given: String, wanted: String): ArgumentFit {
		return index.typing.unification.unifies(decl(index, given), decl(index, wanted));
	}

	/** The declaration named `name` of the fixture file. */
	private static function decl(index: SymbolIndex, name: String): ResolvedType {
		final found: Null<ResolvedType> = index.refs.findDeclaredType('p/M.hx', name);
		if (found == null) throw 'no declaration $name';
		return found;
	}

	private static function indexOf(source: String): SymbolIndex {
		return CheckFixture.index([{ file: 'p/M.hx', source: source }], new HaxeQueryPlugin());
	}

}
