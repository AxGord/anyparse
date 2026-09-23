package unit.check;

import anyparse.check.CheckScan;
import anyparse.check.LoopScan;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.QueryNode;
import utest.Assert;
import utest.Test;

/**
 * The subtree scans `prefer-value-loop` and `prefer-keyvalue-loop` share, exercised DIRECTLY
 * rather than through a rule. `indexedHeaderOf` is the header both rules match, so a change to
 * it moves two rules at once; `countReads`, `collectIndexReads` and `bindsName` are the three
 * name questions a binder-deleting rewrite asks, and each answers about a different slot family.
 */
class LoopScanTest extends Test {

	public function testIndexedHeaderNamesBothSides(): Void {
		final h: Null<IndexedLoopHeader> = headerOf('for (i in 0...items.length) use(items[i]);');
		if (h == null) {
			Assert.fail('the header must match');
			return;
		}
		Assert.equals('i', h.index);
		Assert.equals('items', h.collection);
		Assert.equals('items', h.sizeReceiver.name);
	}

	public function testIndexedHeaderCarriesTheBodyUnexamined(): Void {
		// A bare statement body is returned as readily as a block: what each rule demands of the
		// body is that rule's own claim, never this predicate's.
		Assert.notNull(headerOf('for (i in 0...items.length) use(items[i]);'));
		Assert.notNull(headerOf('for (i in 0...items.length) {\n\t\t\tuse(items[i]);\n\t\t}'));
	}

	public function testIndexedHeaderRejectsNonZeroLowerBound(): Void {
		Assert.isNull(headerOf('for (i in 1...items.length) use(items[i]);'));
	}

	public function testIndexedHeaderRejectsNonSizeBound(): Void {
		Assert.isNull(headerOf('for (i in 0...total) use(items[i]);'));
		Assert.isNull(headerOf('for (i in 0...items.size) use(items[i]);'));
	}

	public function testIndexedHeaderRejectsPathReceiver(): Void {
		// The rewrite gate reads a BINDING's annotation, which a path has none of.
		Assert.isNull(headerOf('for (i in 0...a.b.length) use(a.b[i]);'));
	}

	public function testIndexedHeaderRejectsCollectionNamedLikeIndex(): Void {
		Assert.isNull(headerOf('for (items in 0...items.length) use(items[items]);'));
	}

	public function testIndexedHeaderRejectsKeyValueLoop(): Void {
		// A key-value loop carries its value binder as an EXTRA child, so the arity check rejects
		// the very form `prefer-keyvalue-loop` produces.
		Assert.isNull(headerOf('for (i => v in items) use(v);'));
		Assert.isNull(headerOf('for (v in items) use(v);'));
	}

	public function testCountReadsSeesCodeAndInterpolatedIdentifiers(): Void {
		Assert.equals(1, readsOf('use(items[i]);', 'i'));
		Assert.equals(2, readsOf('use(items[i], i);', 'i'));
		// The interpolated read projects under a DIFFERENT kind from a code identifier, and a
		// counter keyed on the code kind alone would answer 1 here. Double-quoted fixture keeps the
		// interpolation trigger literal in the source under test.
		Assert.equals(2, readsOf("trace(items[i] + '$i');", 'i'));
	}

	public function testCountReadsCountsAWriteTargetAsARead(): Void {
		// An assignment target is an identifier occurrence like any other, which is why a
		// binder-deleting rule needs no separate write gate.
		Assert.equals(2, readsOf('use(items[i]);\n\t\t\ti = 0;', 'i'));
	}

	public function testCountReadsSkipsReification(): Void {
		// A `macro` subtree is pruned, which is exactly why a rule that DELETES a binding owes a
		// text scan on top of this count.
		Assert.equals(1, readsOf("use(items[i], macro trace($v{i}));", 'i'));
	}

	public function testCollectIndexReadsReturnsTheNodesItCounts(): Void {
		final nodes: Array<QueryNode> = indexReadsOf('use(items[i], other[i], items[k]);', 'items', 'i');
		Assert.equals(1, nodes.length);
		Assert.equals(1, LoopScan.countIndexReads(bodyOf('use(items[i], other[i], items[k]);'), 'items', 'i', seams().core));
		Assert.equals('i', nodes[0].children[1].name);
	}

	public function testCollectIndexReadsIsIndexSensitive(): Void {
		Assert.equals(2, indexReadsOf('use(items[i], items[i]);', 'items', 'i').length);
		Assert.equals(0, indexReadsOf('use(items[i + 1]);', 'items', 'i').length);
	}

	public function testBindsNameSeesEveryBinderTheTreeNames(): Void {
		Assert.isTrue(bindsIn('for (i in 0...other.length) use(i);', 'i'));
		Assert.isTrue(bindsIn('for (k => i in table) use(i);', 'i'));
		Assert.isTrue(bindsIn('queue(i -> use(i));', 'i'));
		Assert.isTrue(bindsIn('try f() catch (i:Exception) log(i);', 'i'));
		Assert.isTrue(bindsIn('switch v {\n\t\t\t\tcase var i: use(i);\n\t\t\t}', 'i'));
		Assert.isTrue(bindsIn('final i = 1;', 'i'));
	}

	public function testBindsNameIgnoresReadPositions(): Void {
		// A read is `countReads`' half of the question; together the two partition every occurrence.
		Assert.isFalse(bindsIn('use(items[i]);', 'i'));
		Assert.isFalse(bindsIn("trace('$i');", 'i'));
	}

	public function testBindsNameIgnoresLiteralText(): Void {
		// A literal's name slot carries TEXT, not a symbol — otherwise a string spelling the name
		// answers as a declaration of it and silences the caller outright.
		Assert.isFalse(bindsIn("use(items[k], 'i');", 'i'));
		Assert.isFalse(bindsIn('use(items[k], "items");', 'items'));
	}

	public function testBindsNameMissesABareCaseCapture(): Void {
		// The one binder the grammar spells as an ordinary identifier, so it lands in the READ half.
		Assert.isFalse(bindsIn('switch v {\n\t\t\t\tcase i: use(i);\n\t\t\t}', 'i'));
		Assert.isTrue(readsOf('switch v {\n\t\t\t\tcase i: use(i);\n\t\t\t}', 'i') > 0);
	}

	private function seams(): IntervalLoopSeams {
		final s: Null<IntervalLoopSeams> = LoopScan.intervalSeamsOf(new HaxeQueryPlugin().refShape());
		if (s == null) throw 'the Haxe grammar must answer every interval-loop seam';
		return s;
	}

	/** The `for` statement of a one-loop fixture, run through `indexedHeaderOf`. */
	private function headerOf(loop: String): Null<IndexedLoopHeader> {
		final s: IntervalLoopSeams = seams();
		final src: String = wrap(loop);
		final forNode: Null<QueryNode> = firstOfKind(parse(src), s.core.forStmtKind);
		if (forNode == null) throw 'the fixture must project a for statement';
		return LoopScan.indexedHeaderOf(forNode, src, 'length', s);
	}

	/** The BODY block of a fixture whose statements are wrapped in a loop-free block. */
	private function bodyOf(statements: String): QueryNode {
		final s: IntervalLoopSeams = seams();
		final block: Null<QueryNode> = firstOfKind(parse(wrap('{\n\t\t\t$statements\n\t\t}')), s.core.blockStmtKind);
		if (block == null) throw 'the fixture must project a block statement';
		return block;
	}

	private function readsOf(statements: String, name: String): Int {
		return LoopScan.countReads(bodyOf(statements), name, seams().core);
	}

	private function indexReadsOf(statements: String, collection: String, index: String): Array<QueryNode> {
		return LoopScan.collectIndexReads(bodyOf(statements), collection, index, seams().core);
	}

	private function bindsIn(statements: String, name: String): Bool {
		return LoopScan.bindsName(bodyOf(statements), name, seams().core);
	}

	private function wrap(body: String): String {
		return 'class C {\n\tfunction f(items:Array<Item>):Void {\n\t\t$body\n\t}\n}';
	}

	private function parse(source: String): QueryNode {
		final tree: Null<QueryNode> = CheckScan.parseOrNull(new HaxeQueryPlugin(), source);
		if (tree == null) throw 'the fixture must parse';
		return tree;
	}

	/** The first node of `kind` in document order, or null — the fixtures each hold exactly one. */
	private function firstOfKind(node: QueryNode, kind: String): Null<QueryNode> {
		if (node.kind == kind) return node;
		for (c in node.children) {
			final hit: Null<QueryNode> = firstOfKind(c, kind);
			if (hit != null) return hit;
		}
		return null;
	}

}
