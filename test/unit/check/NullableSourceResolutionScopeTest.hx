package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.PossibleNullDereference;
import anyparse.check.UnguardedNullableDeref;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import utest.Assert;
import utest.Test;

/**
 * Which INDEX the nullable-source cross-file return arc asks, and what the exclusion list still
 * means once that index is wide.
 *
 * Every member this family asks about — `Array.pop`, a library's `find` — is declared OUTSIDE the
 * files under report, so a REPORT-scoped index answers "unknown" for all of them by construction
 * and the arc was silently dead wherever it mattered. Measured on the Pony fork: 48 of 421
 * method-call questions resolved through the report index, 194 through the resolution index.
 *
 * The same widening is what makes `RefShape.nullableFlowExcludedCalls` load-bearing HERE: the
 * exclusion is applied to `instanceSigs` at build time, and this arc reaches the same call by an
 * index lookup that never sees that filter. `testExcludedArrayPopStaysUnseeded` is the fixture for
 * that, and it is the one an arm kills — it cannot be red against a base whose index is too narrow
 * to hold `Array` at all.
 */
class NullableSourceResolutionScopeTest extends Test {

	/** A library type whose `find` returns `Null<Item>` and whose `all` does not — the discriminator pair. */
	private static inline final LIB: String = 'class Lib {\n' + '\tpublic function find(k:String):Null<Item> { return null; }\n'
		+ '\tpublic function all():Array<Item> { return []; }\n' + '\tpublic static function make():Null<Item> { return null; }\n' + '}\n';

	/** The item `Lib.find` may or may not hand back. */
	private static inline final ITEM: String = 'class Item {\n\tpublic var name:String;\n}\n';

	/** The std collection the exclusion list names, declared where the resolution index can see it. */
	private static inline final ARRAY: String = 'class Array<T> {\n' + '\tpublic function pop():Null<T> { return null; }\n'
		+ '\tpublic function shift():Null<T> { return null; }\n' + '}\n';

	/**
	 * The whole point of the redirect: `Lib` is declared in the LIBRARY half, so the report index
	 * cannot name `Lib.find` at all and the arc answered "unknown" for it.
	 */
	@:pin('control')
	@:killer('M-NULLABLE-REPORT-INDEX')
	public function testLibraryReturnDerefFlagged(): Void {
		final vs: Array<Violation> = pointwise('class C { function f(l:Lib) { l.find(k).name; } }');
		Assert.equals(1, vs.length);
		Assert.equals('l.find() can be null; this dereference has no null check', vs[0].message);
	}

	public function testLibraryNonNullReturnNotFlagged(): Void {
		Assert.equals(0, pointwise('class C { function f(l:Lib) { l.all().length; } }').length);
	}

	/** The STATIC receiver route into the same lookup — the receiver's own NAME is the type. */
	@:pin('control')
	@:killer('M-NULLABLE-REPORT-INDEX')
	public function testLibraryStaticReturnDerefFlagged(): Void {
		final vs: Array<Violation> = pointwise('class C { function f() { Lib.make().name; } }');
		Assert.equals(1, vs.length);
		Assert.equals('Lib.make() can be null; this dereference has no null check', vs[0].message);
	}

	/** The same redirect on the FLOW seed's own index, which the point-wise arm cannot cover. */
	@:pin('control')
	@:killer('M-NULLABLE-FLOW-REPORT-INDEX')
	public function testLibraryReturnBindingSeeded(): Void {
		Assert.equals(1, flow('class C { function f(l:Lib) { var u = l.find(k); g(); u.name; } function g() {} }').length);
	}

	/**
	 * The exclusion, restored inside the redirected arc. `Array.pop` is dropped from `instanceSigs`
	 * at build time, so the arc that used to answer here is silent — and the index lookup behind it
	 * knows `Array` the moment the scope is wide enough. Without the guard this reports one, and it
	 * did on the Pony fork at `LangTable:42`, `TablePrepare:100-101` and `Renderer.hx` twenty times
	 * over.
	 */
	@:pin('control')
	@:killer('M-NULLABLE-INDEX-EXCLUSION')
	public function testExcludedArrayPopStaysUnseeded(): Void {
		Assert.equals(0, flow('class C { function f(arr:Array<Int>) { var u = arr.pop(); u.foo(); } }').length);
	}

	/**
	 * The exclusion is the FLOW seed's, not the family's: the point-wise check builds its config
	 * with no exclusion at all and still reports the same call. A guard placed one level too high
	 * would take this finding with it.
	 */
	public function testExcludedArrayPopStillPointwiseFlagged(): Void {
		Assert.equals(1, pointwise('class C { function f(arr:Array<Int>) { arr.pop().foo(); } }').length);
	}

	/** `possible-null-dereference` over `source`, with `Lib` / `Item` / `Array` reachable only through the resolution scope. */
	private function pointwise(source: String): Array<Violation> {
		final report: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: source }];
		return new PossibleNullDereference().run(report, scoped(report));
	}

	/** `unguarded-nullable-deref` over `source`, same scope shape. */
	private function flow(source: String): Array<Violation> {
		final report: Array<{ file: String, source: String }> = [{ file: 'C.hx', source: source }];
		return new UnguardedNullableDeref().run(report, scoped(report));
	}

	/** A plugin hosting the scope in the shape `LintCommand` builds: report under report, the rest in the library half. */
	private function scoped(report: Array<{ file: String, source: String }>): CachingGrammarPlugin {
		final library: Array<{ file: String, source: String }> = [
			{ file: 'lib/Lib.hx', source: LIB },
			{ file: 'lib/Item.hx', source: ITEM },
			{ file: 'lib/Array.hx', source: ARRAY }
		];
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		plugin.setResolutionScope(
			{ declared: true, sources: () -> {report: report, projectRoots: [], library: new LibrarySources(library) } }
		);
		return plugin;
	}

}
