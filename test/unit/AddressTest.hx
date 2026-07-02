package unit;

import utest.Assert;
import utest.Test;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.Address;
import anyparse.query.Address.AddressResult;
import anyparse.query.QueryNode;
import anyparse.query.Address.AddressSpec;

/**
 * Unit tests for the shared target-address resolver (`Address.resolve`) — the
 * `<line>[:<col>]` / `--select` / `--match` / `--nth` layer of the mutation
 * ops — plus the `--kind` ancestor lift (`Address.liftToKind`).
 */
class AddressTest extends Test {

	private static final SRC: String = 'class C {\n\tfunction f():Int {\n\t\tvar x = 1;\n\t\ttrace(x);\n\t\ttrace(x);\n\t\treturn x;\n\t}\n}\n';

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
				final span = n?.span;
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
				if (n != null)
					Assert.equals('VarStmt:x', Address.describe(tree, SRC, n, plugin.selectKindEquivalence()));
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
		final src: String = 'class C {\n\tfunction f():Void {\n\t\tvar v = 1;\n\t\ttrace(v);\n\t}\n\tfunction g():Void {\n\t\tvar v = 2;\n\t\ttrace(v);\n\t}\n}\n';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(src);
		switch Address.resolve(tree, src, plugin, { select: 'FnMember:g >> VarStmt:v' }) {
			case Ok(_, node):
				final n: Null<QueryNode> = node;
				if (n != null)
					Assert.equals('FnMember:g >> VarStmt:v', Address.describe(tree, src, n, plugin.selectKindEquivalence()));
			case Err(message):
				Assert.fail(message);
		}
	}

	private function resolve(spec: AddressSpec): AddressResult {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final tree: QueryNode = plugin.parseFile(SRC);
		return Address.resolve(tree, SRC, plugin, spec);
	}

}
