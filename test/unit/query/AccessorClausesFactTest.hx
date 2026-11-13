package unit.query;

import anyparse.query.AccessorClause;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;

/**
 * Pins `TypeInfoProvider.accessorClauses`: the two identifiers of a property's accessor clause as the grammar parsed
 * them, keyed by the declaring member's own span start — the key a check holds for the member it is looking at.
 */
class AccessorClausesFactTest extends Test {

	private static final SOURCE: String = 'class P {\n\tpublic var p(get, never): Int;\n\t@:isVar var q(default, null): String;\n'
		+ '\tvar plain: Int;\n\tstatic var s(get, set): Int;\n\tfinal f(get, never): Int;\n'
		+ '\tvar a(null, set): Int, b(default, never): Int;\n}';

	/**
	 * Every member with a two-slot clause carries its read and write identifiers in written order — a `final` member and
	 * a `VarMore` continuation included — and a plain field carries none.
	 */
	@:pin('control')
	@:killer('M-SPANINFO-CLAUSE-SLOTS-SWAPPED')
	public function testEachClauseIsKeyedByItsDeclaringMember(): Void {
		Assert.same([
			'VarMember:p=get,never',
			'VarMember:q=default,null',
			'VarMember:s=get,set',
			'FinalMember:f=get,never',
			'VarMember:a=null,set',
			'VarMore:b=default,never'
		], clausesByMember(SOURCE, new HaxeQueryPlugin().accessorClauses(SOURCE)));
	}

	/** A clause naming one slot only says nothing about either: the member has an accessor fact but no clause. */
	@:pin('control')
	@:killer('M-SPANINFO-CLAUSE-ONE-SLOT')
	public function testAOneSlotClauseCarriesNoClause(): Void {
		final src: String = 'class P {\n\tvar x(get): Int;\n}';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		Assert.equals(1, [for (_ in plugin.propertyAccessors(src).keys()) 1].length);
		Assert.same([], clausesByMember(src, plugin.accessorClauses(src)));
	}

	/** The caching decorator answers the bundle's own map, read off the same walk. */
	public function testTheCachingPluginForwardsTheBundleMap(): Void {
		final caching: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		Assert.isTrue(caching.accessorClauses(SOURCE) == caching.spanTypeInfo(SOURCE).accessorClauses);
		Assert.same(
			clausesByMember(SOURCE, new HaxeQueryPlugin().accessorClauses(SOURCE)),
			clausesByMember(SOURCE, caching.accessorClauses(SOURCE))
		);
	}

	/** `kind:name=read,write` for each node of `src`'s tree whose span start keys a clause, in document order. */
	private static function clausesByMember(src: String, clauses: Map<Int, AccessorClause>): Array<String> {
		final seen: Array<String> = [];
		function walk(node: QueryNode): Void {
			final span: Null<Span> = node.span;
			final clause: Null<AccessorClause> = span == null ? null : clauses[span.from];
			if (clause != null) seen.push('${node.kind}:${node.name}=${clause.read},${clause.write}');
			for (c in node.children) walk(c);
		}
		walk(new HaxeQueryPlugin().parseFile(src));
		return seen;
	}

}
