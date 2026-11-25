package unit.query;

import anyparse.query.NodeTokens;
import anyparse.query.QueryNode;
import haxe.Exception;

using anyparse.util.Arrays;

/**
 * `NodeTokens.firstSpelling` / `lastSpelling` / `endsWithOwn`: a node's own tokens answer where its punctuation
 * sits, so a colon or a paren inside a comment of the node is none of them, and a terminator a child matched is not
 * the node's own.
 */
@:nullSafety(Strict)
class NodeTokensSpellingTest extends Test {

	private static final CATCH: String = 'class A {\n\tfunction f() {\n\t\ttry {} catch (e /* (a: b) */ : Dynamic) {}\n\t}\n}\n';

	@:pin('control')
	@:killer('M-NODE-TOKENS-FIRST-SPELLING')
	public function testTheFirstSpellingIsTheNodesOwnTokenNotACommentsByte(): Void {
		final clause: QueryNode = first(new HaxeQueryPlugin().parseFile(CATCH), 'CatchClause');
		Assert.equals(CATCH.indexOf('(e'), NodeTokens.firstSpelling(clause, CATCH, '('));
		Assert.equals(CATCH.indexOf(': Dynamic'), NodeTokens.firstSpelling(clause, CATCH, ':'));
		Assert.equals(-1, NodeTokens.firstSpelling(clause, CATCH, ';'), 'a spelling the node owns no token of answers -1');
	}

	@:pin('control')
	@:killer('M-NODE-TOKENS-LAST-SPELLING')
	public function testTheLastSpellingIsTheLastOwnTokenSpellingIt(): Void {
		final clause: QueryNode = first(new HaxeQueryPlugin().parseFile(CATCH), 'CatchClause');
		Assert.equals(CATCH.indexOf(': Dynamic'), NodeTokens.lastSpelling(clause, CATCH, ':'));
		Assert.equals(CATCH.indexOf('Dynamic)') + 'Dynamic'.length, NodeTokens.lastSpelling(clause, CATCH, ')'));
	}

	@:pin('control')
	@:killer('M-NODE-TOKENS-ENDS-WITH-OWN')
	public function testATerminatorAChildMatchedIsNotTheNodesOwnEnd(): Void {
		final source: String = 'class A {\n\tfunction k() return 1;\n\tfunction f() {\n\t\tvar x = 1;\n\t}\n}\n';
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(source);
		Assert.isTrue(NodeTokens.endsWithOwn(first(tree, 'VarStmt'), source, ';'));
		Assert.isFalse(NodeTokens.endsWithOwn(first(tree, 'FnMember'), source, ';'), 'the `;` is its expression body\'s');
	}

	/** The first node of `kind` in document order; throws when there is none. */
	private static function first(node: QueryNode, kind: String): QueryNode {
		final found: Null<QueryNode> = firstOrNull(node, kind);
		if (found == null) throw new Exception('no $kind node');
		return found;
	}

	private static function firstOrNull(node: QueryNode, kind: String): Null<QueryNode> {
		return node.kind == kind ? node : node.children.findMap(child -> firstOrNull(child, kind));
	}

}
