package unit.query;

import anyparse.query.AbstractCasts.TypeEnd;
import anyparse.query.ArgumentSlots;
import anyparse.query.CallSelection;
import anyparse.query.CallSignature;
import anyparse.query.MemberLookup.HostedMembers;
import anyparse.query.SymbolIndex;
import unit.CheckFixture;

using Lambda;

/**
 * The signatures a call may select (`MemberInfo.signatures`), whether a call compiles against one
 * (`ArgumentSlots.compiles`) and the one it binds (`CallSelection`, step T5 of the typer by specification;
 * `callUnification.ml`), each rule first compiled on Haxe 4.3.7 `--interp` and `-js` (FU25 probes, `docs/decisions.md`).
 */
@:nullSafety(Strict)
class CallSelectionTest extends Test {

	/** An extern overloading in each shape the selection reads, and a class with plain and `overload` members. */
	private static final FIXTURE: String = 'package p;\n\nextern class O {\n'
		+ '\t@:overload(function<T:Int>(a:String, ?b:Int, c:Float = 1.5):Array<T> {})\n\t@:overload(function(a:Int):Int -> Void {})\n'
		+ '\tstatic function f(x:Int):Void;\n\n\t@:overload(function(a:Float):String {})\n\t@:overload(function(a:Int):Bool {})\n'
		+ '\tstatic function h(a:String):Int;\n\n\t@:overload\n\tstatic function bare(a:String):Int;\n\n'
		+ '\toverload static function k(a:Int):Int;\n\n\toverload static function k(a:String):String;\n\n'
		+ '\tfunction r(...rest:Int):Void;\n}\n\nclass P {\n\tfunction g<T:Int>(x:T) {}\n}\n';

	/**
	 * A function's signatures are its own, then each `@:overload` annotation's as written: their parameters' types and forms
	 * (`?b` optional, `c = 1.5` defaulted, `...rest`), their return types — a type parameter's bound, which the query tree
	 * flattens beside them, never read as one — their type parameters and where their types are written.
	 */
	@:pin('control') @:killer('M-INDEX-SIGNATURES-META') @:killer('M-SIGNATURE-FORM-OPTIONAL') @:killer('M-SIGNATURE-FORM-DEFAULTED')
	@:killer('M-SIGNATURE-RETURN-SOURCE') @:killer('M-SPANINFO-RETURN-SOURCES') @:killer('M-SIGNATURE-RETURN-TRIM')
	public function testAFunctionsSignaturesAreItsOwnThenEachAnnotations(): Void {
		final f: MemberInfo = member('f')[0];
		Assert.equals(3, f.signatures.length);
		Assert.same(['Int'], [for (p in f.signatures[0].params) p.type], 'its own first');
		Assert.equals('Void', f.signatures[0].returnSource);
		final first: CallSignature = f.signatures[1];
		Assert.same(['String', 'Int', 'Float'], [for (p in first.params) p.type], 'then the annotations in written order');
		Assert.same([ParamForm.Plain, ParamForm.Optional, ParamForm.Defaulted], [for (p in first.params) p.form]);
		Assert.equals('Array<T>', first.returnSource);
		Assert.same(['T'], first.typeParamNames);
		Assert.equals(FIXTURE.indexOf('function<T:Int>'), first.at, 'written at the annotation\'s function');
		Assert.equals('Int -> Void', f.signatures[2].returnSource, 'a function type returned, trimmed');
		Assert.same([ParamForm.Rest], [for (p in member('r')[0].signatures[0].params) p.form], 'the rest parameter');
		final p: Null<ResolvedType> = index().refs.findDeclaredType('p/O.hx', 'P');
		final g: Null<MemberInfo> = p?.type.members.find(m -> m.name == 'g');
		Assert.isNull(g?.signatures[0].returnSource, 'no return type, though `<T:Int>` writes a type beside it');
		Assert.notNull(g);
	}

	/** An annotation that writes no one function (a bare `@:overload`) leaves the candidates unknown. */
	@:pin('control') @:killer('M-INDEX-SIGNATURES-BARE')
	public function testAnAnnotationWritingNoFunctionLeavesNoSignatures(): Void {
		Assert.same([], member('bare')[0].signatures);
		Assert.isNull(index().typing.calls.candidates(hosted('bare'), true));
	}

	/**
	 * A call compiles against a signature when the compiler's own way — the argument unifying binds the parameter it meets,
	 * one that does not skips an optional parameter while fewer arguments than parameters are left — is decided and ends
	 * bound; it does not when no way binds; it may otherwise, and it may when that way skips a parameter whose type is not
	 * nullable (Flash refuses that skip).
	 */
	@:pin('control') @:killer('M-SLOTS-COMPILES-DECIDED') @:killer('M-SLOTS-COMPILES-NONE') @:killer('M-SLOTS-COMPILES-UNSAFE-SKIP')
	@:killer('M-SLOTS-COMPILES-MAYFIT')
	public function testWhetherACallCompilesAgainstASignature(): Void {
		final optional: SlotParam = { optional: true, rest: false };
		final plain: SlotParam = { optional: false, rest: false };
		final fits: (Int, Int) -> ArgumentFit = (_, _) -> Fits;
		Assert.equals(Fits, ArgumentSlots.compiles([plain, optional], 1, fits, _ -> true), 'the optional left out');
		Assert.equals(Misfits, ArgumentSlots.compiles([plain], 2, fits, _ -> true), 'too many arguments');
		Assert.equals(Misfits, ArgumentSlots.compiles([plain, plain], 1, fits, _ -> true), 'too few');
		final skipFirst: (Int, Int) -> ArgumentFit = (_, p) -> p == 0 ? Misfits : Fits;
		Assert.equals(Fits, ArgumentSlots.compiles([optional, plain], 1, skipFirst, _ -> true), 'a skip');
		Assert.equals(MayFit, ArgumentSlots.compiles([optional, plain], 1, skipFirst, _ -> false), 'a skip Flash refuses');
		Assert.equals(MayFit, ArgumentSlots.compiles([plain], 1, (_, _) -> MayFit, _ -> true), 'an undecided fit');
		Assert.equals(Misfits, ArgumentSlots.compiles([plain], 2, (_, _) -> MayFit, _ -> true), 'no way binds two, undecided');
	}

	/**
	 * The candidate a call binds: for `@:overload` the first one that may compile, when it surely does or none after it
	 * may; for `overload` the only one that may compile.
	 */
	@:pin('control') @:killer('M-CALLS-CHOSEN-FIRST') @:killer('M-CALLS-CHOSEN-LAST-OPEN') @:killer('M-CALLS-CHOSEN-PROPER')
	public function testTheCandidateACallBinds(): Void {
		Assert.equals(1, CallSelection.chosen(Meta, [Misfits, Fits, Fits]), 'the first compiling');
		Assert.equals(1, CallSelection.chosen(Meta, [Misfits, MayFit, Misfits]), 'the only one left');
		Assert.isNull(CallSelection.chosen(Meta, [MayFit, Fits]), 'an undecided one before another');
		Assert.isNull(CallSelection.chosen(Meta, [Misfits, Misfits]), 'none');
		Assert.equals(1, CallSelection.chosen(Proper, [Misfits, MayFit]), 'the only `overload` member left');
		Assert.isNull(CallSelection.chosen(Proper, [Fits, Fits]), 'two `overload` members compiling');
	}

	/**
	 * The selection over typed arguments (`Unification.casts`): `O.h(1)` — the own `(a:String)` refuses the `Int` — takes
	 * `(a:Float)`, written before `(a:Int)`; an `overload` static takes the one member compiling; an untyped argument leaves
	 * `h`'s three open, their returns disagreeing.
	 */
	@:pin('control') @:killer('M-CALLS-FIT-CAST') @:killer('M-CALLS-PROPER-STATIC') @:killer('M-CALLS-RETURN-AGREE')
	public function testTheSelectionOverTypedArguments(): Void {
		final idx: SymbolIndex = index();
		final calls: CallSelection = idx.typing.calls;
		final o: ResolvedType = decl(idx);
		final h: Null<CallCandidates> = calls.candidates(hosted('h', idx), true);
		Assert.notNull(h);
		if (h == null) return;
		Assert.equals('String', calls.returnOf(o, h, [Typed(Core('Int'))], []), 'the first annotation compiling');
		Assert.equals('Int', calls.returnOf(o, h, [Typed(Core('String'))], []), 'the own signature');
		Assert.isNull(calls.returnOf(o, h, [Untyped], []), 'three open, disagreeing');
		Assert.isTrue(calls.excludes(h, [Typed(Core('Int')), Typed(Core('Int'))]), 'no candidate takes two');
		final k: Null<CallCandidates> = calls.candidates(hosted('k', idx), true);
		Assert.notNull(k);
		if (k == null) return;
		Assert.equals(OverloadKind.Proper, k.kind);
		Assert.equals('String', calls.returnOf(o, k, [Typed(Core('String'))], []), 'the one `overload` member taking it');
		Assert.isNull(calls.candidates(hosted('k', idx), false), 'off a value: the supertypes\' take part');
	}

	/**
	 * A parameter written as the signature's type parameter takes any value, a bounded one one unifying with its bound, and
	 * the call's return names the type the arguments bind it to, spelled by its module path; two arguments binding it to two
	 * types leave the call undecided.
	 */
	@:pin('control') @:killer('M-CALLS-PARAM-FREE') @:killer('M-CALLS-PARAM-AGREE') @:killer('M-CALLS-PARAM-SPELLED')
	@:killer('M-SIGNATURE-PARAM-BOUNDS')
	public function testATypeParameterTheArgumentsBindIsTheirType(): Void {
		final source: String = 'package p;\n\nextern class T2 {\n\tstatic function id<T>(x:T):T;\n\n'
			+ '\tstatic function pair<T>(a:T, b:T):Array<T>;\n\n\tstatic function bounded<T:Int>(x:T):T;\n}\n';
		final idx: SymbolIndex = CheckFixture.index([
			{ file: 'p/T2.hx', source: source },
			{ file: 'p/Foo.hx', source: 'package p;\n\nclass Foo {}\n' }
		], new HaxeQueryPlugin());
		final calls: CallSelection = idx.typing.calls;
		final t2: ResolvedType = idx.refs.findDeclaredType('p/T2.hx', 'T2') ?? throw 'no declaration T2';
		final foo: ResolvedType = idx.refs.findDeclaredType('p/Foo.hx', 'Foo') ?? throw 'no declaration Foo';
		function of(name: String): CallCandidates {
			final found: Null<HostedMembers> = idx.typing.members.declaringMember(t2, name);
			final c: Null<CallCandidates> = found == null ? null : calls.candidates(found, true);
			if (c == null) throw 'no candidates of $name';
			return c;
		}
		Assert.equals('Int', calls.returnOf(t2, of('id'), [Typed(Core('Int'))], []), 'bound to a core type');
		Assert.equals('p.Foo', calls.returnOf(t2, of('id'), [Typed(Declared(foo))], []), 'bound to a declaration');
		Assert.equals(Fits, calls.verdict(of('id').candidates[0], [Untyped]), 'any value');
		Assert.isNull(calls.returnOf(t2, of('id'), [Untyped], []), 'bound to an untyped value');
		Assert.equals('Array<Int>', calls.returnOf(t2, of('pair'), [Typed(Core('Int')), Typed(Core('Int'))], []), 'agreeing');
		Assert.equals(MayFit, calls.verdict(of('pair').candidates[0], [Typed(Core('Int')), Typed(Core('String'))]), 'two types');
		Assert.equals(Misfits, calls.verdict(of('bounded').candidates[0], [Typed(Core('String'))]), 'the bound refuses');
		Assert.equals('Int', calls.returnOf(t2, of('bounded'), [Typed(Core('Int'))], []), 'the bound takes it');
	}

	/**
	 * An applied generic abstract unifies with itself applied alike and, its type parameters invariant, not with itself
	 * applied otherwise: `Box<String>` and `Box<Int>` of an `abstract Box<T>(Int)` writing no clause (4.3.7).
	 */
	@:pin('control') @:killer('M-CASTS-APPLIED-SAME')
	public function testAnAppliedAbstractIsItselfAppliedAlike(): Void {
		final idx: SymbolIndex = CheckFixture.index(
			[{ file: 'p/Box.hx', source: 'package p;\n\nabstract Box<T>(Int) {}\n' }], new HaxeQueryPlugin()
		);
		final box: ResolvedType = idx.refs.findDeclaredType('p/Box.hx', 'Box') ?? throw 'no declaration Box';
		final strings: TypeEnd = Applied(box, [Core('String')]);
		Assert.equals(Fits, idx.typing.unification.casts(strings, Applied(box, [Core('String')])), 'applied alike');
		Assert.equals(Misfits, idx.typing.unification.casts(strings, Applied(box, [Core('Int')])), 'applied otherwise');
	}

	private static function member(name: String): Array<MemberInfo> {
		return decl(index()).type.members.filter(m -> m.name == name);
	}

	private static function hosted(name: String, ?idx: SymbolIndex): HostedMembers {
		final within: SymbolIndex = idx ?? index();
		final found: Null<HostedMembers> = within.typing.members.declaringMember(decl(within), name);
		if (found == null) throw 'no member $name';
		return found;
	}

	private static function decl(idx: SymbolIndex): ResolvedType {
		final found: Null<ResolvedType> = idx.refs.findDeclaredType('p/O.hx', 'O');
		if (found == null) throw 'no declaration O';
		return found;
	}

	private static function index(): SymbolIndex {
		return CheckFixture.index([{ file: 'p/O.hx', source: FIXTURE }], new HaxeQueryPlugin());
	}

}
