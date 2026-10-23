package unit.query;

import anyparse.query.AncestorTable;
import anyparse.query.ArgumentSlots.ArgumentFit;
import anyparse.query.SymbolIndex;
import unit.CheckFixture;

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
		+ 'class Out extends Missing {}\n\ntypedef St = {\n\tvar x:Int;\n}\n';

	/** Abstracts casting through `from` / `to` clauses, a transitive one, conversion members, ones the graph does not model. */
	private static final CASTS: String = 'package p;\n\nclass A {}\n\nclass B extends A {}\n\nclass Other {}\n\n'
		+ 'abstract ToA(A) to A {}\n\nabstract FromB(B) from B {}\n\nabstract Mid(B) from B {}\n\nabstract Top(B) from Mid {}\n\n'
		+ '@:transitive abstract TTop(B) from Mid {}\n\nabstract Conv(Other) {\n\t@:from static function fromA(a:A):Conv return null;\n\n'
		+ '\t@:to function toA():A return null;\n}\n\nabstract Gen<T>(A) to A {}\n\n@:multiType abstract Multi(A) to A {}\n\n'
		+ '#if x\nabstract Split(A) from B {}\n#else\nabstract Split(A) {}\n#end\n\n'
		+ '#if x\nabstract Same(A) from B {}\n#else\nabstract Same(A) from B {}\n#end\n';

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

	@:pin('control') @:killer('M-UNIFY-ALIAS-STOP', 'M-UNIFY-SELF-OPEN')
	public function testOnlyPlainTypesAreDecided(): Void {
		final index: SymbolIndex = indexOf(PLAIN);
		Assert.equals(Fits, unifies(index, 'B', 'TA'), 'an alias of a plain class is followed');
		Assert.equals(Misfits, unifies(index, 'A', 'Ab'), 'an abstract with no clause takes no class (T4)');
		Assert.equals(Fits, unifies(index, 'Ab', 'Ab'), 'an abstract is itself');
		Assert.equals(Fits, unifies(index, 'St', 'St'), 'so is a structure');
		Assert.equals(MayFit, unifies(index, 'G', 'G'), 'one type with parameters: its arguments decide');
		Assert.equals(MayFit, unifies(index, 'A', 'G'), 'a wanted type with parameters');
	}

	@:pin('control') @:killer('M-UNIFY-GUARDED-PLAIN')
	public function testADeclarationUnderIfIsNotPlain(): Void {
		final index: SymbolIndex = indexOf('package p;\n\nclass A {}\n\n#if x\nclass P extends A {}\n#else\nclass P {}\n#end\n');
		Assert.equals(MayFit, unifies(index, 'P', 'A'), 'its branches extend different types');
		Assert.equals(Fits, unifies(index, 'P', 'P'), 'but it is itself in every branch');
	}

	/**
	 * A given type with type parameters against a plain wanted one is decided by its chain alone: `unify (TInst (c1, tl1))
	 * (TInst (c2, []))` looks for `c2` up `c1`'s supertypes and has no argument to compare there (Haxe 4.3.7, FU14 probes).
	 */
	@:pin('control') @:killer('M-UNIFY-GENERIC-GIVEN')
	public function testAGivenTypeWithParametersIsDecidedByItsChain(): Void {
		final index: SymbolIndex = indexOf(
			'package p;\n\ninterface I {}\n\nclass A implements I {}\n\nclass GA<T> extends A {}\n\nclass G<T> {}\n\nenum Opt<T> {\n\tNone;\n}\n'
		);
		Assert.equals(Fits, unifies(index, 'GA', 'A'), 'a generic subclass');
		Assert.equals(Fits, unifies(index, 'GA', 'I'), 'an interface its superclass implements');
		Assert.equals(Misfits, unifies(index, 'G', 'A'), 'a generic class its chain does not reach');
		Assert.equals(Misfits, unifies(index, 'Opt', 'A'), 'a generic enum');
		Assert.equals(MayFit, unifies(index, 'A', 'GA'), 'the wanted side has parameters');
	}

	/**
	 * An abstract unifies through its header's clauses (`tUnification.ml`, Haxe 4.3.7: `unify_to` / `unify_from`): a type a
	 * `to` clause writes that unifies with the wanted one, a `from` clause's type the given one unifies with.
	 */
	@:pin('control') @:killer('M-UNIFY-ABSTRACT-OFF')
	public function testAnAbstractUnifiesThroughItsClauses(): Void {
		final index: SymbolIndex = indexOf(CASTS);
		Assert.equals(Fits, unifies(index, 'ToA', 'A'), 'a `to` clause');
		Assert.equals(Misfits, unifies(index, 'ToA', 'B'), 'the `to` type is no subclass');
		Assert.equals(Misfits, unifies(index, 'ToA', 'Other'), 'an unrelated class');
		Assert.equals(Fits, unifies(index, 'B', 'FromB'), 'a `from` clause');
		Assert.equals(Misfits, unifies(index, 'A', 'FromB'), 'a superclass of the `from` type');
		Assert.equals(Misfits, unifies(index, 'FromB', 'B'), 'a `from` clause casts in, not out');
	}

	/**
	 * A cast through the clause of an abstract that is not transitive allows no second abstract cast (`get_abstract_context`):
	 * `B` reaches `Top` only through `Mid`, an abstract of its own; `@:transitive` allows it.
	 */
	@:pin('control') @:killer('M-UNIFY-CAST-TRANSITIVE')
	public function testAPlainAbstractsClauseAllowsNoSecondCast(): Void {
		final index: SymbolIndex = indexOf(CASTS);
		Assert.equals(Misfits, unifies(index, 'B', 'Top'), 'through `Mid`, not transitive');
		Assert.equals(Fits, unifies(index, 'B', 'TTop'), '`@:transitive`');
		Assert.equals(Fits, unifies(index, 'Mid', 'Top'), 'the clause\'s own type');
	}

	/**
	 * A unification reads no `@:from` / `@:to` member — those are an argument's implicit cast (`abstractCast.ml`) — and an
	 * abstract the graph does not model (type parameters, `@:multiType`) is not decided, nor is one whose `#if` branches
	 * write different clauses; branches that agree decide it.
	 */
	@:pin('control') @:killer('M-CASTS-GRAPH-PARAMS') @:killer('M-CASTS-BRANCHES-AGREE') @:killer('M-CASTS-TYPE-SELECTED')
	public function testAUnificationReadsTheClausesOfEveryBranchAndNoMember(): Void {
		final index: SymbolIndex = indexOf(CASTS);
		Assert.equals(Misfits, unifies(index, 'A', 'Conv'), 'a `@:from` member is no clause');
		Assert.equals(Misfits, unifies(index, 'Conv', 'A'), 'nor is a `@:to` one');
		Assert.equals(MayFit, unifies(index, 'Gen', 'A'), 'type parameters');
		Assert.equals(MayFit, unifies(index, 'Multi', 'A'), '`@:multiType`');
		Assert.equals(MayFit, unifies(index, 'B', 'Split'), 'one branch casts from B, the other does not');
		Assert.equals(Fits, unifies(index, 'B', 'Same'), 'both branches cast from B');
	}

	/** The standard library's `Any` (`abstract Any(Dynamic) from Dynamic`) takes every value: its `from` reaches the dynamic type. */
	@:pin('control') @:killer('M-CASTS-DYNAMIC-END')
	public function testAnyTakesEveryValue(): Void {
		final index: SymbolIndex = CheckFixture.index([
			{ file: 'p/M.hx', source: CASTS },
			{ file: 'Any.hx', source: 'abstract Any(Dynamic) from Dynamic {}\n' }
		], new HaxeQueryPlugin());
		final any: Null<ResolvedType> = index.refs.findDeclaredType('Any.hx', 'Any');
		if (any == null) throw 'no Any';
		Assert.equals(Fits, index.typing.unification.unifies(decl(index, 'A'), any), 'a class');
		Assert.equals(Fits, index.typing.unification.unifies(decl(index, 'ToA'), any), 'an abstract');
	}

	/**
	 * An abstract the compiler unifies by a hand-written arm (`EnumValue` takes every enum value) is not decided by its
	 * clauses, and neither is a cycle of transitive clauses (`abstract_cast_stack`).
	 */
	@:pin('control') @:killer('M-CASTS-HAND-UNIFIED') @:killer('M-UNIFY-CAST-STACK')
	public function testAHandUnifiedOrCyclicAbstractIsNotDecided(): Void {
		final index: SymbolIndex = CheckFixture.index([
			{
				file: 'p/M.hx',
				source: CASTS
				+ '\nenum En {\n\tE1;\n}\n\n@:transitive abstract C1(Int) from C2 {}\n\n@:transitive abstract C2(Int) from C1 {}\n'
			},
			{ file: 'EnumValue.hx', source: '@:coreType abstract EnumValue {}\n' }
		], new HaxeQueryPlugin());
		final enumValue: Null<ResolvedType> = index.refs.findDeclaredType('EnumValue.hx', 'EnumValue');
		if (enumValue == null) throw 'no EnumValue';
		Assert.equals(MayFit, index.typing.unification.unifies(decl(index, 'En'), enumValue), 'an enum is an `EnumValue` by hand');
		Assert.equals(MayFit, unifies(index, 'Other', 'C1'), 'a cycle of transitive clauses');
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
