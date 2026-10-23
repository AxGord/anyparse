package unit.query;

import anyparse.query.Monomorphs;
import anyparse.query.TypeTerm;

/**
 * The cells of one inference (`Monomorphs`): the first binding wins and a second one of another type poisons the cell, a
 * free or a poisoned cell answers nothing, and a unification binds the cells a wanted type names argument by argument,
 * through what the language reads a given type of another head as.
 */
@:nullSafety(Strict)
class MonomorphsTest extends Test {

	@:pin('control') @:killer('M-MONO-LAST-BINDING-WINS')
	public function testTheFirstBindingWinsAndAnotherTypePoisons(): Void {
		final monos: Monomorphs = new Monomorphs();
		final kept: Int = monos.fresh();
		final poisoned: Int = monos.fresh();
		monos.bind(kept, named('Int'));
		monos.bind(kept, named('Int'));
		Assert.equals('Int', textOf(monos.resolved(kept)), 'the same type again keeps the binding');
		monos.bind(poisoned, named('Int'));
		monos.bind(poisoned, named('String'));
		Assert.isNull(monos.resolved(poisoned), 'a second binding to another type poisons the cell');
	}

	public function testAFreeCellAnswersNothing(): Void {
		final monos: Monomorphs = new Monomorphs();
		Assert.isNull(monos.resolved(monos.fresh()));
	}

	@:pin('control') @:killer('M-MONO-DYNAMIC-BINDS')
	public function testTheDynamicTypeLeavesACellFree(): Void {
		final monos: Monomorphs = new Monomorphs();
		final cell: Int = monos.fresh();
		monos.bind(cell, Of(Dyn, [], 'Dynamic'));
		Assert.isNull(monos.resolved(cell), '`link` unifies a monomorph with the dynamic type binding nothing');
		monos.bind(cell, named('Int'));
		Assert.equals('Int', textOf(monos.resolved(cell)), 'a later type binds it');
	}

	public function testMergedCellsShareOneBinding(): Void {
		final monos: Monomorphs = new Monomorphs();
		final a: Int = monos.fresh();
		final b: Int = monos.fresh();
		monos.bind(a, Mono(b));
		monos.bind(b, named('Int'));
		Assert.equals(monos.find(a), monos.find(b));
		Assert.equals('Int', textOf(monos.resolved(a)));
		monos.bind(a, Of(Core('Box'), [Mono(a)], 'Box<A>'));
		Assert.isNull(monos.resolved(b), 'a type naming the cell itself poisons it');
	}

	@:pin('control') @:killer('M-MONO-UNIFY-ARGUMENTS-SKIPPED')
	public function testAUnificationBindsTheCellsTheWantedTypeNames(): Void {
		final monos: Monomorphs = new Monomorphs();
		final element: Int = monos.fresh();
		final unread: Int = monos.fresh();
		final read: Int = monos.fresh();
		final opaque: Int = monos.fresh();
		final none: (wanted:TypeTerm, given:TypeTerm) -> Null<TypeTerm> = (_, _) -> null;
		monos.unify(Of(Core('Box'), [Mono(element)], 'Box<A>'), Of(Core('Box'), [named('Int')], 'Box<Int>'), none);
		Assert.equals('Int', textOf(monos.resolved(element)), 'one head: argument by argument');
		monos.unify(Of(Core('Wrap'), [Mono(unread)], 'Wrap<B>'), Of(Core('Other'), [named('String')], 'Other<String>'), none);
		Assert.isNull(monos.resolved(unread), 'another head read as none: the cell is poisoned');
		final asWrap: (wanted:TypeTerm, given:TypeTerm) -> Null<TypeTerm> = (_, _) -> Of(Core('Wrap'), [named('Float')], 'Wrap<Float>');
		monos.unify(Of(Core('Wrap'), [Mono(read)], 'Wrap<C>'), Of(Core('Other'), [named('String')], 'Other<String>'), asWrap);
		Assert.equals('Float', textOf(monos.resolved(read)), 'another head read as the wanted one');
		monos.unify(Opaque('D -> Void', [opaque]), named('Int'), none);
		Assert.isNull(monos.resolved(opaque), 'a type the term does not take apart binds nothing it names');
	}

	/** A plain type named `name`. */
	private static function named(name: String): TypeTerm {
		return Of(Core(name), [], name);
	}

	/** The spelling of `term`, or null. */
	private static function textOf(term: Null<TypeTerm>): Null<String> {
		return switch term {
			case Of(_, _, text): text;
			case _: null;
		};
	}

}
