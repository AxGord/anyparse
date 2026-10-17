package unit.check;

import anyparse.check.MemberSlots;
import anyparse.check.MemberSpacing;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * `MemberSpacing` against a hand-built writer policy (`MemberGapPolicy`), for the two answers no real config can
 * reach: a slot the multi-line measure cannot read, and a container kind the policy does not cover.
 */
@:nullSafety(Strict)
class MemberSpacingPolicyTest extends Test {

	/** Two same-rank fields set off by a blank line - the shape the multi-line rule decides. */
	private static final OPEN_PAIR: String = 'class C {\n\tvar a:Int = 0;\n\n\tvar b:Int = 0;\n}';

	/**
	 * A pair whose answer depends on a measure that cannot read either slot is left to the source - neither the
	 * blank the check's own rule would remove nor a blank the writer might force is reported. Killed by
	 * `M-MO-WRITER-UNMEASURABLE-GUESS`.
	 */
	@:pin('control')
	@:killer('M-MO-WRITER-UNMEASURABLE-GUESS')
	public function testAnUnmeasurableSlotLeavesThePairToTheSource(): Void {
		Assert.isNull(issueOf(OPEN_PAIR, multilineAnswering(null)));
		Assert.isNull(issueOf(OPEN_PAIR, multilineAnswering(true)), 'a multi-line member keeps its blank');
		final tight: Null<String> = issueOf(OPEN_PAIR, multilineAnswering(false));
		Assert.equals('members of one rank group are separated by a blank line', tight, 'two one-line fields stay a tight group');
	}

	/** The writer policy is read only on the container kinds it names. Killed by `M-MO-WRITER-CONTAINER-KIND`. */
	@:pin('control')
	@:killer('M-MO-WRITER-CONTAINER-KIND')
	public function testTheWriterPolicyIsReadOnlyOnTheKindsItCovers(): Void {
		final policy: MemberGapPolicy = multilineAnswering(true);
		final spacing: SpacingPolicy = { separateInline: false, writer: policy };
		Assert.equals(policy, MemberSpacing.forContainer(spacing, 'ClassDecl').writer);
		Assert.isNull(MemberSpacing.forContainer(spacing, 'AbstractDecl').writer);
	}

	/**
	 * A policy covering `ClassDecl` that forces nothing for doc comments,
	 * lifts a tight gap to one blank, and measures every slot as `multiline`.
	 */
	private static function multilineAnswering(multiline: Null<Bool>): MemberGapPolicy {
		return {
			containerKinds: ['ClassDecl'],
			docBlanks: (_, _) -> null,
			multilineBlanks: (_, _) -> 1,
			multiline: _ -> multiline
		};
	}

	/** The spacing finding's message for the single class in `src` under `writer`, or null. */
	private static function issueOf(src: String, writer: MemberGapPolicy): Null<String> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final root: QueryNode = plugin.parseFile(src);
		final container: QueryNode = root.children.find(c -> c.kind == 'ClassDecl') ?? root;
		final members: Array<OrderedMember> = MemberSlots.collectMembers(container, src, plugin.refShape(), [], plugin.lexicalRegions(src));
		return MemberSpacing.firstSpacingIssue(members, src, { separateInline: false, writer: writer })?.message;
	}

}
