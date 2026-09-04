package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.FieldRefScan;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.MemberKinds;
import anyparse.query.QueryNode;
import utest.Assert;
import utest.Test;

/**
 * `FieldRefScan` — the by-name recognizers the backing-field rewrites share, pinned against the
 * two declarations each of them is a hand copy of.
 *
 * Both pins here work the same way, and it is the way a copy has to be pinned: the fixture is a
 * SECOND instance of the declaration, never the declaration itself. `FN_SCOPE_KINDS` is checked
 * against the grammar plugin's own scope vocabulary in BOTH directions;
 * `writeTargetField` is checked against real Haxe source for every operator `isWriteNodeKind`
 * names, so the kind list cannot certify itself.
 */
class FieldRefScanTest extends Test {

	/**
	 * Every write operator `FieldRefScan.isWriteNodeKind` names, paired with a real Haxe
	 * spelling of it. The SECOND instance of that list — parsed by the grammar rather than
	 * read off the same array — is what makes the pin below discriminate.
	 */
	private static final WRITE_SPELLINGS: Array<{ kind: String, code: String }> = [
		{ kind: 'Assign', code: '_x = 1' },
		{ kind: 'AddAssign', code: '_x += 1' },
		{ kind: 'SubAssign', code: '_x -= 1' },
		{ kind: 'MulAssign', code: '_x *= 1' },
		{ kind: 'DivAssign', code: '_x /= 1' },
		{ kind: 'ModAssign', code: '_x %= 1' },
		{ kind: 'BitAndAssign', code: '_x &= 1' },
		{ kind: 'BitOrAssign', code: '_x |= 1' },
		{ kind: 'BitXorAssign', code: '_x ^= 1' },
		{ kind: 'ShlAssign', code: '_x <<= 1' },
		{ kind: 'ShrAssign', code: '_x >>= 1' },
		{ kind: 'UShrAssign', code: '_x >>>= 1' },
		{ kind: 'PreIncr', code: '++_x' },
		{ kind: 'PostIncr', code: '_x++' },
		{ kind: 'PreDecr', code: '--_x' },
		{ kind: 'PostDecr', code: '_x--' }
	];

	/**
	 * `FN_SCOPE_KINDS` is a HAND COPY of a derivable set, and this is what pays for that: it is
	 * checked against the grammar in BOTH directions, so a plugin adding or dropping a
	 * function-value spelling fails here instead of silently changing which references the rename
	 * walk treats as shadowed. (The copy exists because `isFnScope` is called from three points
	 * inside a rename walk carrying no context object — deriving it would add a parameter to eight
	 * signatures and thirteen call sites, in a module that decides its other node kinds by literal.)
	 *
	 * The one documented extra over `RefactorSupport.nestedFunctionKinds` is the METHOD-declaration
	 * half: `functionKinds` minus the local functions (already function VALUES) and minus the
	 * module-level declarations, which are deliberately excluded — a shadowed reference is
	 * rewritten to `this.` / `C.`, and neither is spellable at module level. `FnDecl` is exactly
	 * that exclusion, not an omission.
	 */
	@:access(anyparse.query.FieldRefScan)
	public function testFnScopeKindsMatchTheGrammarAuthority(): Void {
		final shape: RefShape = new HaxeQueryPlugin().refShape();
		final expected: Array<String> = MemberKinds.nestedFunctionKinds(shape);
		final localOrModule: Array<String> = (shape.localFunctionKinds ?? []).concat(shape.moduleValueDeclKinds);
		for (kind in shape.functionKinds ?? []) if (!localOrModule.contains(kind) && !expected.contains(kind)) expected.push(kind);
		Assert.isTrue(expected.length > 0, 'the plugin must declare at least one function scope kind');
		for (kind in expected)
			Assert.isTrue(FieldRefScan.FN_SCOPE_KINDS.contains(kind), 'FN_SCOPE_KINDS is missing the grammar scope kind $kind');
		for (kind in FieldRefScan.FN_SCOPE_KINDS)
			Assert.isTrue(expected.contains(kind), 'FN_SCOPE_KINDS carries $kind, which the grammar no longer names a function scope');
	}

	/**
	 * `writeTargetField` sees the write target of every operator `isWriteNodeKind` names.
	 *
	 * The two used to carry SEPARATE copies of the same sixteen-kind list, one in each function,
	 * and nothing compared them: a kind added to one and forgotten in the other would have made
	 * the collapse silently treat a write as a read (`hasExternalRead`) or drop it from the
	 * bypass census (`collectExternalWrites`) — a wrong rewrite, not a missed one. `writeTargetField`
	 * now asks `isWriteNodeKind`, and this pin is the second half: each kind is reached from REAL
	 * source, so the shared list still has to be right rather than merely consistent.
	 */
	public function testWriteTargetFieldSeesEveryWriteOperatorSpelling(): Void {
		for (spelling in WRITE_SPELLINGS) {
			final node: QueryNode = firstWriteNode(spelling.code);
			Assert.equals(spelling.kind, node.kind, 'the grammar must spell ${spelling.code} as ${spelling.kind}');
			Assert.isTrue(FieldRefScan.isWriteNodeKind(node.kind), '${spelling.kind} must be a write node kind');
			Assert.equals('_x', FieldRefScan.writeTargetField(node), 'writeTargetField must see the target of ${spelling.code}');
		}
	}

	/** A receiver other than `this` is not provably the field, in a read or in a write position. */
	public function testForeignReceiverIsNotTheField(): Void {
		Assert.equals('_x', FieldRefScan.writeTargetField(firstWriteNode('this._x = 1')));
		Assert.equals(null, FieldRefScan.writeTargetField(firstWriteNode('other._x = 1')));
		Assert.isFalse(FieldRefScan.mentionsField(firstWriteNode('other._x = 1'), '_x'));
	}

	/**
	 * `code` as the single statement of a method body, and the expression that statement holds.
	 *
	 * Located as "the `ExprStmt`'s only child", NOT as "the first node `isWriteNodeKind` accepts":
	 * a locator that asked the predicate under test would stop FINDING the node the moment the
	 * predicate lost a kind, and the pin would die by exception instead of by its own assertion.
	 */
	private static function firstWriteNode(code: String): QueryNode {
		final tree: QueryNode = new HaxeQueryPlugin().parseFile('class C {\n\tfunction m():Void {\n\t\t$code;\n\t}\n}');
		final stmt: Null<QueryNode> = firstOfKind(tree, 'ExprStmt');
		if (stmt == null || stmt.children.length != 1) throw 'no single-expression statement parsed out of "$code"';
		return stmt.children[0];
	}

	/** The first node of `kind` in pre-order, or null. */
	private static function firstOfKind(node: QueryNode, kind: String): Null<QueryNode> {
		if (node.kind == kind) return node;
		for (c in node.children) {
			final hit: Null<QueryNode> = firstOfKind(c, kind);
			if (hit != null) return hit;
		}
		return null;
	}

}
