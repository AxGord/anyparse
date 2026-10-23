package unit.query;

import anyparse.query.ImplicitSites;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

/**
 * `ImplicitSites` — where the language runs a member implicitly. The landing half (`landings`): a value a build may
 * convert to a string at the place it lands, which for a construction is each VALUE argument it passes.
 */
@:nullSafety(Strict)
class ImplicitSitesTest extends Test {

	/**
	 * A construction's TYPE arguments are no values: `new Box<Int>(d)` lands `d` — a catch-all, which may hold any object —
	 * and nothing at `Int`. The walk read every child of the `new` as an argument, and a type node, of no type the syntax
	 * reads, was a landing of an unknown value: a string conversion of ANY object at every construction written with type
	 * arguments.
	 */
	@:pin('control')
	@:killer('M-LANDING-TYPE-ARGS-AS-VALUES')
	public function testAConstructionLandsItsValueArgumentsOnly(): Void {
		final source: String = 'class Box<T> {\n\tpublic function new(v: T) {}\n}\n\n'
			+ 'class C {\n\tfunction f(d: Dynamic): Void {\n\t\tvar b = new Box<Int>(d);\n\t}\n}\n';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(source);
		final sites: ImplicitSites = new ImplicitSites(plugin, CheckFixture.index([{ file: 'C.hx', source: source }], plugin));
		final landed: Array<String> = [
			for (s in sites.sitesIn(
				'C.hx', tree, source, new Span(0, source.length)
			)) if (s.landing == true) source.substring(s.span.from, s.span.to)
		];
		Assert.same(['d'], landed);
	}

}
