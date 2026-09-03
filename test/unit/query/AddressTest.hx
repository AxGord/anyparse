package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Address;
import anyparse.query.Engine;
import anyparse.query.Pattern.KindEquivalence;
import anyparse.query.QueryNode;
import anyparse.query.Selector;
import anyparse.runtime.Span;
import haxe.Exception;
import utest.Assert;
import utest.Test;

using Lambda;
using StringTools;

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

	/**
	 * `nodeAt` answers what `Engine.at` answers — the independent oracle — at EVERY offset
	 * of the fixture, the inter-token ones where neither finds a node included. The index
	 * prunes that walk rather than redefining it, so the agreement is offset-by-offset and
	 * not merely on the offsets a report happens to address.
	 */
	public function testNodeAtMatchesEngineAtAtEveryOffset(): Void {
		final fixture = indexFixture();
		// The fallback is output-identical to the fast path, so agreement alone cannot
		// tell which one ran: a real grammar tree that stopped being nested would revert
		// the whole optimisation with every assertion below still green. Pin the premise.
		Assert.isTrue(fixture.index.nested);
		var covered: Int = 0;
		for (offset in 0...fixture.src.length + 1) {
			final expected: Null<QueryNode> = Engine.at(fixture.tree, offset);
			Assert.equals(expected, fixture.index.nodeAt(offset));
			if (expected != null) covered++;
		}
		Assert.isTrue(covered > 100);
	}

	/**
	 * A node reached through two parents. The index records it once and keeps the FIRST
	 * parent, so the nesting test has to run before that skip — otherwise the second
	 * enclosure is never examined, the tree passes for nested, and the pruned walk cannot
	 * reach the node through the parent it did not record. `Engine.at` visits it twice and
	 * so wins the equal-width tie that the pruned walk would lose.
	 */
	public function testSharedNodeUnderTwoParentsIsNotNested(): Void {
		final shared: QueryNode = new QueryNode('Shared', null, [], new Span(0, 10));
		final first: QueryNode = new QueryNode('First', null, [shared], new Span(0, 20));
		final sibling: QueryNode = new QueryNode('Sibling', null, [], new Span(1, 11));
		final second: QueryNode = new QueryNode('Second', null, [shared], new Span(50, 60));
		final root: QueryNode = new QueryNode('Root', null, [first, sibling, second], new Span(0, 100));
		final index: AddressIndex = Address.describerFor(root);
		Assert.isFalse(index.nested);
		for (offset in 0...101) Assert.equals(Engine.at(root, offset), index.nodeAt(offset));
		Assert.equals(shared, index.nodeAt(5));
	}

	/**
	 * Two nested nodes of the SAME width: the deeper one wins, because a transparent
	 * wrapper and its sole child are indistinguishable by width and the innermost is what
	 * an address must name. `Engine.at` decides that with a later-visited-wins tie-break,
	 * and a pruned walk only agrees while it keeps the same rule — the fixture's real tree
	 * happens to hold no such pair, so the shape gets its own tree here.
	 */
	public function testNodeAtPicksTheInnermostOfEqualSpans(): Void {
		final inner: QueryNode = new QueryNode('Inner', null, [], new Span(0, 10));
		final wrapper: QueryNode = new QueryNode('Wrapper', null, [inner], new Span(0, 10));
		final root: QueryNode = new QueryNode('Root', null, [wrapper], new Span(0, 10));
		final index: AddressIndex = Address.describerFor(root);
		for (offset in 0...11) Assert.equals(Engine.at(root, offset), index.nodeAt(offset));
		Assert.equals(inner, index.nodeAt(5));
	}

	/**
	 * A child whose span escapes its parent's is the one shape the pruning cannot answer:
	 * the offset never reaches that child through a chain of containing parents. The index
	 * measures the nesting while it builds and defers to `Engine.at` when it fails, so what
	 * this pins is the safeguard — without it the escaping node is simply invisible.
	 */
	public function testNodeAtDefersWhenAChildEscapesItsParent(): Void {
		final escaping: QueryNode = new QueryNode('Escaping', null, [], new Span(20, 30));
		final parent: QueryNode = new QueryNode('Parent', null, [escaping], new Span(0, 10));
		final root: QueryNode = new QueryNode('Root', null, [parent], new Span(0, 10));
		final index: AddressIndex = Address.describerFor(root);
		for (offset in 0...31) Assert.equals(Engine.at(root, offset), index.nodeAt(offset));
		Assert.equals(escaping, index.nodeAt(25));
	}

	/**
	 * A node whose bare `Kind[:name]` segment other nodes share is never addressed by that
	 * segment alone. `describe` decides that by asking for at most TWO matches, so this
	 * pins that the cap still separates "one" from "more than one": a cap of one would call
	 * the first member of every shared group unique, and `Engine.select` is the independent
	 * oracle that says otherwise.
	 */
	public function testSharedSegmentWidensIntoAUniqueAncestorPath(): Void {
		final fixture = indexFixture();
		var shared: Int = 0;
		var claimed: Int = 0;
		for (n in fixture.nodes) {
			final bare: String = n.name != null ? '${n.kind}:${n.name}' : n.kind;
			final address: String = fixture.index.describe(fixture.src, n);
			if (selected(fixture, bare).length >= 2) {
				Assert.notEquals(bare, address);
				shared++;
			}
			if (address.indexOf(' >> ') < 0 || address.indexOf(' --nth ') >= 0) continue;
			final only: Array<QueryNode> = selected(fixture, address);
			Assert.equals(1, only.length);
			Assert.equals(n, only[0]);
			claimed++;
		}
		Assert.isTrue(shared > 10);
		Assert.isTrue(claimed > 5);
	}

	/**
	 * A selector whose NAME exists but under another KIND said only "matched no nodes", which reads
	 * as "there is no such declaration". A module-level `function` is an `FnDecl`, not the `FnMember`
	 * every in-type habit spells, so the tool answered a question about the KIND with an answer about
	 * the NAME. The error names the kinds that DO carry it, with the selector to use.
	 */
	public function testSelectKindMismatchNamesTheRealKind(): Void {
		final src: String = 'function topLevel(): Int {\n\treturn 1;\n}\n';
		switch resolveIn(src, { select: 'FnMember:topLevel' }) {
			case Ok(_, _):
				Assert.fail('expected Err for a kind that does not carry this name');
			case Err(message):
				Assert.isTrue(message.contains('FnDecl:topLevel'), message);
		}
	}

	/** A name that exists nowhere keeps the plain answer — there is no kind to suggest. */
	public function testSelectUnknownNameStaysPlain(): Void {
		final src: String = 'function topLevel(): Int {\n\treturn 1;\n}\n';
		switch resolveIn(src, { select: 'FnMember:absent' }) {
			case Ok(_, _):
				Assert.fail('expected Err');
			case Err(message):
				Assert.isFalse(message.contains('exists as'), message);
		}
	}

	/**
	 * A name that also exists as a REFERENCE must not be suggested: `QueryNode.name` is set on named
	 * references too, so a bare name walk answers the call site — `IdentExpr:topLevel` — ahead of the
	 * declaration it calls, and an op run on that suggestion addresses an identifier read.
	 */
	public function testSelectKindMismatchNamesTheDeclarationNotAReference(): Void {
		final src: String =
			'function topLevel(): Int {\n\treturn 1;\n}\n\nclass C {\n\tfunction f(): Int {\n\t\treturn topLevel();\n\t}\n}\n';
		switch resolveIn(src, { select: 'FnMember:topLevel' }) {
			case Ok(_, _):
				Assert.fail('expected Err for a kind that does not carry this name');
			case Err(message):
				Assert.isTrue(message.contains('FnDecl:topLevel'), message);
				Assert.isFalse(message.contains('IdentExpr'), message);
		}
	}

	/**
	 * A selector with an ANCESTOR chain says WHERE the node must sit, and a hint read off the bare
	 * name cannot honour it — suggesting `FnMember:bar` for a missed `ClassDecl:Foo >> FnMember:bar`
	 * points at another class's `bar`, and a mutation op run on the suggestion rewrites that one.
	 */
	public function testSelectScopedKindMismatchStaysPlain(): Void {
		final src: String = 'class Foo {\n\tfunction other(): Int {\n\t\treturn 1;\n\t}\n}\n\n'
			+ 'class Baz {\n\tfunction bar(): Int {\n\t\treturn 2;\n\t}\n}\n';
		switch resolveIn(src, { select: 'ClassDecl:Foo >> FnMember:bar' }) {
			case Ok(_, _):
				Assert.fail('expected Err');
			case Err(message):
				Assert.isFalse(message.contains('exists as'), message);
		}
	}

	/**
	 * `TreeAddresser` builds ONE index for a run of addresses in the same tree. The addresses it
	 * hands back are identical either way, so this counter is the only thing that can tell a live
	 * memo from a dead one — and it HAS been dead: an autofix pass read the two captured locals the
	 * class replaces as dead stores, and every JSON-report finding paid a whole-tree index from
	 * then on. Green at base BY CONSTRUCTION only if the memo is written; killed by arm M1.
	 */
	public function testTreeAddresserBuildsOneIndexForAWholeTree(): Void {
		final fixture: IndexFixture = indexFixture();
		final addresser: TreeAddresser = new TreeAddresser(fixture.equiv);
		var addressed: Int = 0;
		for (node in fixture.nodes) {
			final span: Null<Span> = node.span;
			if (span == null) continue;
			Assert.notNull(addresser.addressAt(fixture.tree, fixture.src, span.from));
			addressed++;
		}
		Assert.isTrue(addressed > 20, 'fixture must exercise many addresses, got $addressed');
		Assert.equals(1, addresser.indexBuilds);
	}

	/**
	 * The slot keys on the TREE OBJECT, so a second tree gets its own index and the first one's is
	 * dropped rather than reused — an index handed a node it never saw answers `<line>:<col>` for
	 * every address, in silence. Alternating the two trees therefore rebuilds each time, which is
	 * exactly the price the one-slot memo charges for interleaving.
	 */
	public function testTreeAddresserRebuildsForADifferentTree(): Void {
		final fixture: IndexFixture = indexFixture();
		final otherSrc: String = 'class D {\n\tfunction q(): Int {\n\t\treturn 7;\n\t}\n}\n';
		final other: QueryNode = new HaxeQueryPlugin().parseFile(otherSrc);
		final addresser: TreeAddresser = new TreeAddresser(fixture.equiv);
		Assert.notNull(addresser.addressAt(fixture.tree, fixture.src, fixture.src.indexOf('function f')));
		Assert.notNull(addresser.addressAt(fixture.tree, fixture.src, fixture.src.indexOf('function g')));
		Assert.equals(1, addresser.indexBuilds);
		Assert.notNull(addresser.addressAt(other, otherSrc, otherSrc.indexOf('function q')));
		Assert.equals(2, addresser.indexBuilds);
		Assert.notNull(addresser.addressAt(fixture.tree, fixture.src, fixture.src.indexOf('function f')));
		Assert.equals(3, addresser.indexBuilds);
	}

	/**
	 * The memo is a speed-up and nothing else: every address the reused index yields is the one a
	 * throwaway `Address.describe` yields for the same node. Asserted on the SAME nodes the count
	 * test walks, so the two together say "one index, same answers".
	 */
	public function testTreeAddresserAgreesWithAFreshDescribe(): Void {
		final fixture: IndexFixture = indexFixture();
		final addresser: TreeAddresser = new TreeAddresser(fixture.equiv);
		var compared: Int = 0;
		for (node in fixture.nodes) {
			final span: Null<Span> = node.span;
			if (span == null) continue;
			final hit: Null<QueryNode> = fixture.index.nodeAt(span.from);
			if (hit == null) continue;
			Assert.equals(
				Address.describe(fixture.tree, fixture.src, hit, fixture.equiv), addresser.addressAt(fixture.tree, fixture.src, span.from)
			);
			compared++;
		}
		Assert.isTrue(compared > 20, 'fixture must exercise many addresses, got $compared');
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

	/** What `Engine.select` — the independent oracle — makes of a `describe`-produced selector. */
	private function selected(fixture: { tree: QueryNode, equiv: KindEquivalence }, selector: String): Array<QueryNode> {
		return try Engine.select(fixture.tree, Selector.parse(selector), fixture.equiv) catch (exception: Exception) [];
	}

	/**
	 * The shared fixture of the two index-wide tests: a source rich enough to reach
	 * statement, branch and binary-operator nodes, its tree, an `AddressIndex` over that
	 * tree, and every node of it in pre-order.
	 */
	private function indexFixture(): IndexFixture {
		final src: String = 'class C {\n\tfunction f():Int {\n\t\tvar x = 1;\n\t\tvar y = 2;\n\t\ttrace(x);\n\t\ttrace(y);\n\t\tif (x > y) '
			+ 'trace(x); else trace(y);\n\t\treturn x + y;\n\t}\n\tfunction g():Void {\n\t\tvar x = 3;\n\t\ttrace(x);\n\t\tif (x > 0) {\n'
			+ '\t\t\ttrace(x);\n\t\t\ttrace(x);\n\t\t}\n\t}\n\tfunction h():Void {\n\t\ttrace(1);\n\t\ttrace(2);\n\t\ttrace(3);\n\t}\n}\n';
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

/**
 * What `AddressTest.indexFixture` hands its callers: one source, its tree, the kind equivalence
 * that tree's plugin declares, an `AddressIndex` over it, and every node of it in pre-order.
 *
 * A named type rather than the anonymous one written at each call site — the four index-wide
 * tests spell the same five fields, which is what `anon-type-dup` is for.
 */
private typedef IndexFixture = {
	var src: String;
	var tree: QueryNode;
	var equiv: KindEquivalence;
	var index: AddressIndex;
	var nodes: Array<QueryNode>;
};
