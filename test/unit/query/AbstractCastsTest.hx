package unit.query;

import anyparse.query.ArgumentSlots.ArgumentFit;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeTerm.TypeEnd;
import unit.CheckFixture;

/**
 * The implicit cast an argument takes (`Unification.casts`, step T4 of the typer by specification): a unification, else
 * the cast `abstractCast.ml`'s `do_check_cast` inserts — an `@:from` / `@:to` member, then the first clause unequal to the
 * abstract cast to again — each answer first compiled on Haxe 4.3.7 `--interp` (FU18 probes, `docs/decisions.md`).
 */
@:nullSafety(Strict)
class AbstractCastsTest extends Test {

	/** Classes, a conversion abstract, a chain of `from` clauses over members, header clauses, a core-number abstract. */
	private static final FIXTURE: String = 'package p;\n\nclass A {}\n\nclass B extends A {}\n\nclass Other {}\n\nabstract Conv(Other) {\n'
		+ '\t@:from static function fromA(a:A):Conv return null;\n\n\t@:to function toA():A return null;\n}\n\nabstract Bs(Int) to Int {\n'
		+ '\t@:from static function fromS(s:String):Bs return null;\n}\n\nabstract Dz(Int) to Int {\n'
		+ '\t@:from static function fromB(b:Bool):Dz return null;\n}\n\nabstract Ab(Int) from Bs from Dz {}\n\n'
		+ 'abstract Ad(Int) from Dz from Bs {}\n\nabstract Sb(String) from String to String {}\n\nabstract Sa(String) from Sb {}\n\n'
		+ '@:transitive abstract St(String) from Sb {}\n\nabstract U(Int) from Int to Int {}\n\nabstract H(Int) {\n#if js\n'
		+ '\t@:from static function fromA(a:A):H return null;\n#end\n}\n\n@:build(p.M.b()) abstract K(Int) {}\n';

	@:pin('control') @:killer('M-CASTS-MEMBERS-OFF')
	public function testAnArgumentCastsThroughAConversionMember(): Void {
		final index: SymbolIndex = indexOf();
		Assert.equals(Fits, casts(index, decl(index, 'A'), decl(index, 'Conv')), '`@:from`');
		Assert.equals(Fits, casts(index, decl(index, 'B'), decl(index, 'Conv')), '`@:from` taking a superclass');
		Assert.equals(Fits, casts(index, decl(index, 'Conv'), decl(index, 'A')), '`@:to`');
		Assert.equals(Misfits, casts(index, decl(index, 'Other'), decl(index, 'Conv')), 'no member takes it');
		Assert.equals(Misfits, casts(index, decl(index, 'Conv'), decl(index, 'B')), 'the `@:to` type is no subclass');
	}

	/**
	 * Past the members, the compiler casts to the FIRST `from` clause unequal to the abstract and to no other (`loop2`):
	 * `Ab from Bs from Dz` takes a `String` through `Bs.fromS` but not a `Bool` through `Dz.fromB`, and `Ad from Dz from Bs`
	 * neither — a `Bool` is an abstract itself, so its cast tries the members alone (`TAbstract, TAbstract`).
	 */
	@:pin('control') @:killer('M-CASTS-FIRST-FROM') @:killer('M-CASTS-FIRST-ONLY') @:killer('M-CASTS-CORE-ABSTRACT')
	public function testTheFirstUnequalFromAloneIsCastTo(): Void {
		final index: SymbolIndex = indexOf();
		Assert.equals(Fits, casts(index, Core('String'), decl(index, 'Ab')), 'the first clause, `Bs`');
		Assert.equals(Misfits, casts(index, Core('Bool'), decl(index, 'Ab')), 'a core abstract is cast by members alone');
		Assert.equals(Misfits, casts(index, Core('String'), decl(index, 'Ad')), '`Dz` is first and takes no `String`');
		Assert.equals(Misfits, casts(index, Core('Bool'), decl(index, 'Ad')), 'nor a `Bool`, a core abstract');
	}

	/**
	 * A header clause is no cast path of its own (`find_from` answers a unification by `Not_found`): `String` reaches `Sa`
	 * only through `Sb`'s clause, a second abstract cast a plain abstract does not allow, and a transitive one does.
	 */
	@:pin('control') @:killer('M-UNIFY-CAST-TRANSITIVE')
	public function testAHeaderClauseChainsOnlyThroughATransitiveAbstract(): Void {
		final index: SymbolIndex = indexOf();
		Assert.equals(Misfits, casts(index, Core('String'), decl(index, 'Sa')), 'not transitive');
		Assert.equals(Fits, casts(index, Core('String'), decl(index, 'St')), '`@:transitive`');
		Assert.equals(Fits, casts(index, decl(index, 'Sb'), decl(index, 'Sa')), 'the clause\'s own type');
	}

	/** A core number cast through a clause meets the widening of core numbers: `UInt`'s `to Int` takes it to `Float`. */
	@:pin('control') @:killer('M-UNIFY-CORE-WIDENS')
	public function testACoreClauseWidens(): Void {
		final index: SymbolIndex = indexOf();
		Assert.equals(Fits, casts(index, decl(index, 'U'), Core('Float')), '`to Int`, and `Int` widens');
		Assert.equals(Misfits, casts(index, decl(index, 'U'), Core('String')), 'no clause reaches it');
		Assert.equals(Fits, casts(index, Core('Int'), decl(index, 'U')), '`from Int`');
		Assert.equals(Misfits, casts(index, Core('Float'), decl(index, 'U')), '`Float` does not narrow to `Int`');
	}

	/** A member under `#if`, and a build macro that may add one, may cast in another build: not decided. */
	@:pin('control') @:killer('M-CASTS-MEMBER-CERTAIN') @:killer('M-CASTS-BUILD-OPEN')
	public function testAMemberNotInEveryBuildIsNotDecided(): Void {
		final index: SymbolIndex = indexOf();
		Assert.equals(MayFit, casts(index, decl(index, 'A'), decl(index, 'H')), 'a `@:from` under `#if`');
		Assert.equals(MayFit, casts(index, decl(index, 'A'), decl(index, 'K')), 'a build macro');
		Assert.equals(Misfits, casts(index, decl(index, 'Other'), decl(index, 'H')), 'no build\'s member takes it');
	}

	private static function casts(index: SymbolIndex, given: TypeEnd, wanted: TypeEnd): ArgumentFit {
		return index.typing.unification.casts(given, wanted);
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
