package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.MemberKinds;
import anyparse.query.QueryNode;
import utest.Assert;
import utest.Test;

/**
 * `MemberKinds.precedingModifiers` and `MemberKinds.invocationKinds` — the modifier run before a
 * member, nearest first and stopping at the first non-modifier sibling, and the call kinds the
 * grammar names. Green at base by construction: three modifier walks and two kind lists spelled
 * these inline.
 */
@:nullSafety(Strict)
class MemberKindsModifierRunTest extends Test {

	private static final SHAPE: RefShape = new HaxeQueryPlugin().refShape();

	public function testTheRunBeforeTheMemberNearestFirst(): Void {
		final pub: QueryNode = new QueryNode('Public', null, []);
		final stat: QueryNode = new QueryNode('Static', null, []);
		final fn: QueryNode = new QueryNode('FnMember', 'f', []);
		final other: QueryNode = new QueryNode('VarMember', 'v', []);
		final parent: QueryNode = new QueryNode('ClassDecl', 'C', [other, pub, stat, fn]);
		final run: Array<QueryNode> = MemberKinds.precedingModifiers(fn, parent, ['Public', 'Static']);
		Assert.equals(2, run.length);
		Assert.equals(stat, run[0]);
		Assert.equals(pub, run[1]);
	}

	public function testTheRunStopsAtTheFirstOtherSibling(): Void {
		final pub: QueryNode = new QueryNode('Public', null, []);
		final other: QueryNode = new QueryNode('VarMember', 'v', []);
		final stat: QueryNode = new QueryNode('Static', null, []);
		final fn: QueryNode = new QueryNode('FnMember', 'f', []);
		final parent: QueryNode = new QueryNode('ClassDecl', 'C', [pub, other, stat, fn]);
		Assert.equals(1, MemberKinds.precedingModifiers(fn, parent, ['Public', 'Static']).length);
		Assert.equals(0, MemberKinds.precedingModifiers(fn, parent, ['Public']).length);
	}

	public function testAStrangerAndAFirstChildHaveNoRun(): Void {
		final fn: QueryNode = new QueryNode('FnMember', 'f', []);
		final parent: QueryNode = new QueryNode('ClassDecl', 'C', [new QueryNode('Public', null, [])]);
		Assert.equals(0, MemberKinds.precedingModifiers(fn, parent, ['Public']).length);
		Assert.equals(0, MemberKinds.precedingModifiers(fn, new QueryNode('ClassDecl', 'C', [fn]), ['Public']).length);
	}

	public function testInvocationKindsAreTheCallAndNewKindsTheGrammarNames(): Void {
		final kinds: Array<String> = MemberKinds.invocationKinds(SHAPE);
		Assert.same([SHAPE.callKind, SHAPE.newExprKind], kinds);
		final bare: RefShape = new HaxeQueryPlugin().refShape();
		bare.newExprKind = null;
		Assert.same([SHAPE.callKind], MemberKinds.invocationKinds(bare));
	}

}
