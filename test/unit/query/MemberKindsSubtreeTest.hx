package unit.query;

import anyparse.query.MemberKinds;
import anyparse.query.QueryNode;

/**
 * `MemberKinds.subtreeContainsAnyKind` and `MemberKinds.isMemberDeclNode` — the one any-of-kinds
 * subtree walk and the node form of the member-declaration test that the check rules share.
 */
@:nullSafety(Strict)
class MemberKindsSubtreeTest extends Test {

	/** KILLED by `M-ANY-KIND-NO-ROOT`: the walk then answers for the descendants only. */
	@:pin('control')
	@:killer('M-ANY-KIND-NO-ROOT')
	public function testTheRootItselfMatches(): Void {
		Assert.isTrue(MemberKinds.subtreeContainsAnyKind(tree(), ['Root']));
	}

	/** KILLED by `M-ANY-KIND-NO-DESCENT`: the walk then tests the root alone. */
	@:pin('control')
	@:killer('M-ANY-KIND-NO-DESCENT')
	public function testADeepDescendantMatchesWhicheverKindOfTheSetItIs(): Void {
		Assert.isTrue(MemberKinds.subtreeContainsAnyKind(tree(), ['Leaf']));
		Assert.isTrue(MemberKinds.subtreeContainsAnyKind(tree(), ['Absent', 'Leaf']));
		Assert.isFalse(MemberKinds.subtreeContainsAnyKind(tree(), ['Absent', 'Missing']));
	}

	/** KILLED by `M-ANY-KIND-EMPTY-TRUE`: an empty set then answers true. */
	@:pin('control')
	@:killer('M-ANY-KIND-EMPTY-TRUE')
	public function testAnEmptyKindSetMatchesNothing(): Void {
		Assert.isFalse(MemberKinds.subtreeContainsAnyKind(tree(), []));
		Assert.isFalse(MemberKinds.subtreeContainsAnyKind(new QueryNode('Root', null, []), []));
	}

	/** KILLED by `M-MEMBER-DECL-NODE-FALSE`. */
	@:pin('control')
	@:killer('M-MEMBER-DECL-NODE-FALSE')
	public function testAMemberNodeIsADeclaration(): Void {
		Assert.isTrue(MemberKinds.isMemberDeclNode(new QueryNode('FnMember', 'f', [])));
		Assert.isTrue(MemberKinds.isMemberDeclNode(new QueryNode('VarMember', 'v', [])));
	}

	/** KILLED by `M-MEMBER-DECL-NODE-TRUE`. */
	@:pin('control')
	@:killer('M-MEMBER-DECL-NODE-TRUE')
	public function testANonMemberNodeIsNotADeclaration(): Void {
		Assert.isFalse(MemberKinds.isMemberDeclNode(new QueryNode('ClassDecl', 'C', [])));
	}

	private static function tree(): QueryNode {
		final leaf: QueryNode = new QueryNode('Leaf', null, []);
		final mid: QueryNode = new QueryNode('Mid', null, [leaf]);
		return new QueryNode('Root', null, [new QueryNode('Other', null, []), mid]);
	}

}
