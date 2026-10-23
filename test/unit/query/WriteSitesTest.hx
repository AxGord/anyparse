package unit.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.WriteSites;

/**
 * `WriteSites`: every write a tree performs, with the storage it writes as a path the binder names, the paths an
 * expression reads, and whether a write can reach a read. Offsets are masked (`@N`): the binding is the binder's.
 */
class WriteSitesTest extends Test {

	public function testEveryWriteSpellingIsASiteOfItsRoot(): Void {
		final paths: Array<String> = writtenPaths(
			'class C { var x:Int; function m(a:A, arr:Array<A>, k:Int) { var i = 0; i = 1; i += 1; i++; --i; (i) -= 1; '
			+ 'a.b = 1; arr[k] = null; this.x = 1; cast(a, A).y = 1; (a : A).w = 1; f().z = 1; } }'
		);
		Assert.same([
			'i@N',
			'i@N',
			'i@N',
			'i@N',
			'i@N',
			'a@N.b',
			'arr@N.[]',
			'x@*',
			'a@N.y',
			'a@N.w',
			'null'
		], paths);
	}

	public function testAWriteInAMacroReificationIsNoSite(): Void {
		Assert.same(['i@N'], writtenPaths('class C { function m() { var i = 0; final e = macro i = 5; i = 1; } }'));
	}

	public function testAWriteTakesEffectAtTheEndOfItsNode(): Void {
		final source: String = 'class C { function m() { var i = 0.5; i = Std.int(i) + 1; } }';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final sites: Array<WriteSite> = WriteSites.of(plugin.parseFile(source), plugin.refShape());
		Assert.equals(1, sites.length);
		Assert.equals(source.indexOf(' + 1') + ' + 1'.length, sites[0].effect);
	}

	public function testReadPathsTakeEachChainAtItsLongest(): Void {
		final source: String =
			'class C { var y:Int; function m(item:A, arr:Array<A>, k:Int) { g(Math.abs(item.x - this.y) + arr[k].z); } }';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(source);
		final shape: RefShape = plugin.refShape();
		final call: QueryNode = firstOfKind(tree, 'Add') ?? throw 'no Add node';
		final paths: Null<Array<String>> = WriteSites.readPaths(call, tree, shape);
		Assert.same(['Math@N.abs', 'item@N.x', 'y@*', 'arr@N.[].z', 'k@N'], paths?.map(masked));
	}

	public function testAWriteReachesAReadAboveBelowAndThroughTheSelfReference(): Void {
		Assert.isTrue(WriteSites.mayOverlap('a@1.b', 'a@1.b.c', false), 'above');
		Assert.isTrue(WriteSites.mayOverlap('a@1.b.c', 'a@1.b', false), 'below a value computed from it');
		Assert.isFalse(WriteSites.mayOverlap('a@1.b.c', 'a@1.b', true), 'below a reference');
		Assert.isFalse(WriteSites.mayOverlap('a@1.x', 'a@1.y', false), 'siblings');
		Assert.isTrue(WriteSites.mayOverlap('arr@1.[]', 'arr@1.length', false), 'an index write reaches any step');
		Assert.isTrue(WriteSites.mayOverlap('x@*', 'x@7.y', false), 'this.x reaches a bare x');
		Assert.isTrue(WriteSites.mayOverlap('x@7', 'x@*.y', false), 'a bare x reaches this.x');
		Assert.isFalse(WriteSites.mayOverlap('x@3', 'x@7', false), 'two bindings of one name');
		Assert.equals(7, WriteSites.rootBinding('x@7.y'));
		Assert.equals(-1, WriteSites.rootBinding('x@*.y'));
	}

	private static function writtenPaths(source: String): Array<String> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return [
			for (site in WriteSites.of(plugin.parseFile(source), plugin.refShape())) site.path == null ? 'null' : masked(site.path)
		];
	}

	private static function masked(path: String): String {
		return ~/@-?[0-9]+/g.replace(path, '@N');
	}

	private static function firstOfKind(node: QueryNode, kind: String): Null<QueryNode> {
		if (node.kind == kind) return node;
		for (c in node.children) {
			final hit: Null<QueryNode> = firstOfKind(c, kind);
			if (hit != null) return hit;
		}
		return null;
	}

}
