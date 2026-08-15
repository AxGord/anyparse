package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Address;
import anyparse.query.QueryNode;
import anyparse.runtime.Span;
import anyparse.query.Pattern.KindEquivalence;
import anyparse.query.Engine;
import anyparse.query.Selector;

using Lambda;

/**
 * Unit tests for the shared target-address resolver (`Address.resolve`) — the
 * `<line>[:<col>]` / `--select` / `--match` / `--nth` layer of the mutation
 * ops — plus the `--kind` ancestor lift (`Address.liftToKind`).
 */
class AddressTest extends Test {

	private static final SRC: String =
		'class C {\n\tfunction f():Int {\n\t\tvar x = 1;\n\t\ttrace(x);\n\t\ttrace(x);\n\t\treturn x;\n\t}\n}\n';

	public function testAtLineCol(): Void {
		// 3:3 = `var x = 1;` first token.
		switch resolve({ at: '3:3' }) {
			case Ok(offset, _):
				Assert.equals('v', SRC.charAt(offset));
			case Err(message):
				Assert.fail(message);
		}
	}

	public function testAtLineOnlySnapsToFirstToken(): Void {
		// Column omitted — snaps past the leading tabs to `var`.
		switch resolve({ at: '3' }) {
			case Ok(offset, node):
				Assert.equals('v', SRC.charAt(offset));
				Assert.notNull(node);
			case Err(message):
				Assert.fail(message);
		}
	}

	/**
	 * A bare line number snaps to the line's first non-whitespace character, which for a
	 * declaration is its modifier prefix. Modifiers project as SIBLINGS before the decl, so
	 * `Engine.at` landed on `Public` and every op refused an address copied straight out of
	 * lint or compiler output.
	 */
	public function testAtLineOnlySkipsModifierPrefix(): Void {
		final src: String = 'class C {\n\tpublic static function f(): Int {\n\t\treturn 1;\n\t}\n}\n';
		assertBareLineHitsFnMember(src, '2');
	}

	/** The `@:meta` run is part of the same prefix — a decl's annotations sit on their own lines. */
	public function testAtLineOnlySkipsMetaPrefix(): Void {
		final src: String = 'class C {\n\t@:keep\n\tpublic function f(): Int {\n\t\treturn 1;\n\t}\n}\n';
		assertBareLineHitsFnMember(src, '2');
	}

	/**
	 * A comment between the prefix and the declaration is trivia, so the offset after the
	 * prefix belongs to no node of its own and `Engine.at` answers with the enclosing type.
	 * The walk keeps the prefix node instead — widening a bare-line address to a whole class
	 * would let `remove-element --at <line>` delete the type instead of one annotation.
	 */
	public function testAtLineOnlyKeepsPrefixWhenTriviaFollows(): Void {
		final src: String = 'class C {\n\t@:keep\n\t// note\n\tpublic function f(): Int {\n\t\treturn 1;\n\t}\n}\n';
		switch resolveIn(src, { at: '2' }) {
			case Ok(offset, node):
				Assert.equals('@:keep', src.substr(offset, 6));
				Assert.notEquals('ClassDecl', node == null ? 'null' : node.kind);
			case Err(message):
				Assert.fail(message);
		}
	}

	/** The explicit `<line>:<col>` form stays exact, so a modifier node is still addressable. */
	public function testAtLineColStillResolvesTheModifier(): Void {
		final src: String = 'class C {\n\tpublic static function f(): Int {\n\t\treturn 1;\n\t}\n}\n';
		switch resolveIn(src, { at: '2:2' }) {
			case Ok(offset, node):
				Assert.equals('public', src.substr(offset, 6));
				Assert.equals('Public', node == null ? 'null' : node.kind);
			case Err(message):
				Assert.fail(message);
		}
	}

	public function testAtBlankLineErrs(): Void {
		final src: String = 'class C {\n\n\tvar x: Int;\n}\n';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(src);
		switch Address.resolve(tree, src, plugin, { at: '2' }) {
			case Ok(_, _):
				Assert.fail('blank line resolved');
			case Err(message):
				Assert.isTrue(message.indexOf('blank') >= 0);
		}
	}

	public function testAtMalformedErrs(): Void {
		switch resolve({ at: '3:x' }) {
			case Ok(_, _):
				Assert.fail('malformed position resolved');
			case Err(message):
				Assert.isTrue(message.indexOf('malformed') >= 0);
		}
	}

	public function testSelectExactlyOne(): Void {
		switch resolve({ select: 'FnMember:f' }) {
			case Ok(offset, node):
				final n: Null<QueryNode> = node;
				Assert.notNull(n);
				if (n != null) Assert.equals('FnMember', n.kind);
				final span: Null<Span> = n?.span;
				Assert.equals(span?.from, offset);
			case Err(message):
				Assert.fail(message);
		}
	}

	public function testSelectDescendantChain(): Void {
		switch resolve({ select: 'FnMember:f >> VarStmt:x' }) {
			case Ok(_, node):
				Assert.equals('VarStmt', node?.kind);
			case Err(message):
				Assert.fail(message);
		}
	}

	public function testSelectNoMatchErrs(): Void {
		switch resolve({ select: 'FnMember:missing' }) {
			case Ok(_, _):
				Assert.fail('resolved a missing name');
			case Err(message):
				Assert.isTrue(message.indexOf('matched no nodes') >= 0);
		}
	}

	public function testSelectAmbiguousListsCandidates(): Void {
		// Two `trace(x)` statements — the Call selector matches both.
		switch resolve({ select: 'Call' }) {
			case Ok(_, _):
				Assert.fail('ambiguous select resolved');
			case Err(message):
				Assert.isTrue(message.indexOf('matched 2 nodes') >= 0);
				Assert.isTrue(message.indexOf('#1 ') >= 0);
				Assert.isTrue(message.indexOf('--nth') >= 0);
		}
	}

	public function testSelectNthPicks(): Void {
		switch resolve({ select: 'Call', nth: 2 }) {
			case Ok(offset, node):
				Assert.equals('Call', node?.kind);
				// The second trace is on line 5 — later in the file than the first.
				switch resolve({ select: 'Call', nth: 1 }) {
					case Ok(first, _): Assert.isTrue(offset > first);
					case Err(message): Assert.fail(message);
				}
			case Err(message):
				Assert.fail(message);
		}
	}

	public function testNthOutOfRangeErrs(): Void {
		switch resolve({ select: 'Call', nth: 3 }) {
			case Ok(_, _):
				Assert.fail('out-of-range nth resolved');
			case Err(message):
				Assert.isTrue(message.indexOf('out of range') >= 0);
		}
	}

	public function testMatchResolvesNode(): Void {
		switch resolve({ match: 'var x = 1' }) {
			case Ok(_, node):
				Assert.equals('VarStmt', node?.kind);
			case Err(message):
				Assert.fail(message);
		}
	}

	public function testMatchWithMetavarNth(): Void {
		switch resolve({ match: "trace($_)", nth: 1 }) {
			case Ok(_, node):
				Assert.equals('Call', node?.kind);
			case Err(message):
				Assert.fail(message);
		}
	}

	public function testMatchMalformedErrs(): Void {
		switch resolve({ match: ')(' }) {
			case Ok(_, _):
				Assert.fail('malformed pattern resolved');
			case Err(message):
				Assert.isTrue(message.length > 0);
		}
	}

	public function testNoModeErrs(): Void {
		switch resolve({}) {
			case Ok(_, _):
				Assert.fail('empty spec resolved');
			case Err(message):
				Assert.isTrue(message.indexOf('no target address') >= 0);
		}
	}

	public function testTwoModesErr(): Void {
		switch resolve({ at: '3:3', select: 'Call' }) {
			case Ok(_, _):
				Assert.fail('two modes resolved');
			case Err(message):
				Assert.isTrue(message.indexOf('exactly one') >= 0);
		}
	}

	public function testNthWithAtErrs(): Void {
		switch resolve({ at: '3:3', nth: 1 }) {
			case Ok(_, _):
				Assert.fail('nth with at resolved');
			case Err(message):
				Assert.isTrue(message.indexOf('--nth') >= 0);
		}
	}

	public function testLiftToKind(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(SRC);
		switch Address.resolve(tree, SRC, plugin, { match: "trace($_)", nth: 1 }) {
			case Ok(_, node):
				final n: Null<QueryNode> = node;
				Assert.notNull(n);
				if (n != null) {
					final lifted: Null<QueryNode> = Address.liftToKind(tree, n, 'ExprStmt', plugin.selectKindEquivalence());
					Assert.equals('ExprStmt', lifted?.kind);
					final missing: Null<QueryNode> = Address.liftToKind(tree, n, 'SwitchStmt', plugin.selectKindEquivalence());
					Assert.isNull(missing);
				}
			case Err(message):
				Assert.fail(message);
		}
	}

	public function testDescribeUniqueOwnSegment(): Void {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(SRC);
		switch Address.resolve(tree, SRC, plugin, { select: 'VarStmt:x' }) {
			case Ok(_, node):
				final n: Null<QueryNode> = node;
				if (n != null) Assert.equals('VarStmt:x', Address.describe(tree, SRC, n, plugin.selectKindEquivalence()));
			case Err(message):
				Assert.fail(message);
		}
	}

	public function testDescribeDisambiguatesWithNth(): Void {
		// Two identical `trace(x)` calls — names cannot tell them apart, so the
		// canonical address falls back to an --nth ordinal.
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(SRC);
		switch Address.resolve(tree, SRC, plugin, { select: 'Call', nth: 2 }) {
			case Ok(_, node):
				final n: Null<QueryNode> = node;
				if (n != null) {
					final address: String = Address.describe(tree, SRC, n, plugin.selectKindEquivalence());
					Assert.isTrue(address.indexOf('--nth 2') >= 0);
				}
			case Err(message):
				Assert.fail(message);
		}
	}

	public function testDescribePrefixesNamedAncestor(): Void {
		// Two same-named locals in different functions — the enclosing FnMember
		// segment disambiguates without an ordinal.
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar v = 1;\n\t\ttrace(v);\n\t}\n\tfunction g():Void {\n\t\tvar v = 2;\n'
			+ '\t\ttrace(v);\n\t}\n}\n';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(src);
		switch Address.resolve(tree, src, plugin, { select: 'FnMember:g >> VarStmt:v' }) {
			case Ok(_, node):
				final n: Null<QueryNode> = node;
				if (n != null) Assert.equals('FnMember:g >> VarStmt:v', Address.describe(tree, src, n, plugin.selectKindEquivalence()));
			case Err(message):
				Assert.fail(message);
		}
	}

	/**
	 * The address `describe` hands back must address the node it was asked about — checked
	 * for EVERY node of a source rich enough to reach statement, branch and binary-operator
	 * nodes. The check resolves through `Engine.select`, the whole-tree walk the index
	 * exists to replace, so the interval arithmetic is confirmed by an independent oracle
	 * rather than by itself.
	 */
	public function testEveryAddressResolvesBackToItsNode(): Void {
		final fixture = indexFixture();
		final position: EReg = ~/^\d+:\d+$/;
		var resolved: Int = 0;
		for (n in fixture.nodes) {
			final address: String = fixture.index.describe(fixture.src, n);
			if (position.match(address)) continue;
			final parts: Array<String> = address.split(' --nth ');
			final matches: Array<QueryNode> = Engine.select(fixture.tree, Selector.parse(parts[0]), fixture.equiv);
			if (parts.length == 2) {
				final nth: Null<Int> = Std.parseInt(parts[1]);
				Assert.notNull(nth);
				if (nth != null) Assert.equals(n, matches[nth - 1]);
			} else {
				Assert.equals(1, matches.length);
				Assert.equals(n, matches[0]);
			}
			resolved++;
		}
		Assert.isTrue(resolved > 20);
	}

	/**
	 * `Selector.parse` reads any `>` byte as a child separator, so a string literal whose
	 * TEXT contains one turns `segmentOf`'s own address into a selector no node can
	 * satisfy. `describe` must fall back to a bare position rather than emit that
	 * unresolvable selector. Probed first via `hxq probe`: a `DoubleStringExpr`'s `name`
	 * slot carries the raw quoted text (`"a > b"`), the exact slot `segmentOf` reads.
	 */
	public function testNameWithSelectorSeparatorFallsBackToPosition(): Void {
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar s = "a > b";\n\t}\n}\n';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(src);
		final nodes: Array<QueryNode> = [];
		collectAll(tree, nodes);
		final literal: Null<QueryNode> = nodes.find(n -> n.kind == 'DoubleStringExpr');
		Assert.notNull(literal);
		if (literal == null) return;
		final address: String = Address.describe(tree, src, literal, plugin.selectKindEquivalence());
		Assert.isTrue(~/^\d+:\d+$/.match(address));
	}

	/**
	 * Two `Call` nodes of identical kind, one nested inside the other's argument — no
	 * name anywhere disambiguates them, so `describe` falls back to a `--nth` ordinal.
	 * That ordinal must be the node's own rank among `Call` matches in document
	 * (pre-order) order — exactly what `descendantsOf`/`lowerBound` compute from
	 * pre-order intervals instead of a walk.
	 */
	public function testNestedSameKindKeepsDocumentOrderOrdinal(): Void {
		final src: String = 'class C {\n\tfunction h():Void {\n\t\tf(g(x));\n\t}\n}\n';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(src);
		final equiv: KindEquivalence = plugin.selectKindEquivalence();
		switch Address.resolve(tree, src, plugin, { match: 'g(x)' }) {
			case Ok(_, node):
				final inner: Null<QueryNode> = node;
				Assert.notNull(inner);
				if (inner == null) return;
				final address: String = Address.describe(tree, src, inner, equiv);
				final parts: Array<String> = address.split(' --nth ');
				Assert.equals(2, parts.length);
				final matches: Array<QueryNode> = Engine.select(tree, Selector.parse(parts[0]), equiv);
				Assert.equals(Std.parseInt(parts[1]), matches.indexOf(inner) + 1);
			case Err(message):
				Assert.fail(message);
		}
	}

	/**
	 * One `AddressIndex` reused across a whole file's addresses must answer exactly what a
	 * throwaway index per address answers. `Cli`'s JSON lint report keeps a single index
	 * alive for every finding of a file, so anything an address left behind in the shared
	 * per-kind groups would corrupt the next one — `Address.describe`, which builds a fresh
	 * index per call, is the reference.
	 */
	public function testSharedIndexMatchesFreshIndexPerCall(): Void {
		final fixture = indexFixture();
		Assert.isTrue(fixture.nodes.length > 20);
		for (n in fixture.nodes)
			Assert.equals(Address.describe(fixture.tree, fixture.src, n, fixture.equiv), fixture.index.describe(fixture.src, n));
	}

	private function resolve(spec: AddressSpec): AddressResult {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(SRC);
		return Address.resolve(tree, SRC, plugin, spec);
	}

	/** `resolve` for a one-off source that is not `SRC`. */
	private function resolveIn(src: String, spec: AddressSpec): AddressResult {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return Address.resolve(plugin.parseFile(src), src, plugin, spec);
	}

	/** Asserts a BARE line address lands on the `function` keyword of an `FnMember`, not on its prefix. */
	private function assertBareLineHitsFnMember(src: String, line: String): Void {
		switch resolveIn(src, { at: line }) {
			case Ok(offset, node):
				Assert.equals('function', src.substr(offset, 8));
				Assert.equals('FnMember', node == null ? 'null' : node.kind);
			case Err(message):
				Assert.fail(message);
		}
	}

	/** Every node of `node`'s subtree, in pre-order — the walk C1/C2 need to visit every node. */
	private function collectAll(node: QueryNode, out: Array<QueryNode>): Void {
		out.push(node);
		for (child in node.children) collectAll(child, out);
	}

	/**
	 * The shared fixture of the two index-wide tests: a source rich enough to reach
	 * statement, branch and binary-operator nodes, its tree, an `AddressIndex` over that
	 * tree, and every node of it in pre-order.
	 */
	private function indexFixture(): {
		src: String,
		tree: QueryNode,
		equiv: KindEquivalence,
		index: AddressIndex,
		nodes: Array<QueryNode>
	} {
		final src: String = 'class C {\n\tfunction f():Int {\n\t\tvar x = 1;\n\t\tvar y = 2;\n\t\ttrace(x);\n\t\ttrace(y);\n\t\t'
			+ 'if (x > y) trace(x); else trace(y);\n\t\treturn x + y;\n\t}\n'
			+ '\tfunction g():Void {\n\t\tvar x = 3;\n\t\ttrace(x);\n\t\tif (x > 0) {\n\t\t\ttrace(x);\n\t\t\ttrace(x);\n\t\t}\n\t}\n'
			+ '\tfunction h():Void {\n\t\ttrace(1);\n\t\ttrace(2);\n\t\ttrace(3);\n\t}\n}\n';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(src);
		final equiv: KindEquivalence = plugin.selectKindEquivalence();
		final nodes: Array<QueryNode> = [];
		collectAll(tree, nodes);
		return {
			src: src,
			tree: tree,
			equiv: equiv,
			index: Address.describerFor(tree, equiv),
			nodes: nodes
		};
	}

}
