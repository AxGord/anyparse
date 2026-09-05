package unit;

import testkit.MutationArms;
import utest.Assert;
import utest.Test;

/**
 * `testkit.MutationArms` — the read that decides whether a `@:killer` name
 * means anything.
 *
 * Every fixture here asks its question of a SECOND arm table, written in this
 * file, and never of `test/testkit/mutation-arms.json`. That is the whole
 * discipline: the build macro already validated the real table, so a fixture
 * reading it back could not fail — it would be derived from the same
 * declaration the acceptance is generated from (S66). A table of its own is a
 * second instance, and a defect can actually be put in it.
 *
 * These pins guard behaviour this slice INTRODUCES, so they are red against
 * `4626138c` only in the sense that nothing they name exists there. What makes
 * them evidence is the arm: `M-ARM-ANYNAME` and `M-ARM-ROW-OK` cut the two
 * functions below, and each fixture's leading assertion is chosen to survive
 * the cut so a kill proves the fixture reached the code rather than missed it.
 */
@:nullSafety(Strict)
final class MutationArmsTest extends Test {

	/** Two well-formed arms, one of each cut — the shape the real table is made of. */
	private static final TWO_ARMS: String = '{"arms": [{"name": "X-FORCE", "type": "pack.Layer", "method": "answer", "force": "false", '
		+ '"note": "the layer stops answering"},{"name": "X-FRAGMENT", "type": "pack.Other", "method": '
		+ '"shape", "find": "a", "replace": "b", "note": "the shape reads b"}]}';

	/** A valid row beside one that says nothing about what it cuts. */
	private static final NO_CUT: String = '{"arms": [{"name": "X-FORCE", "type": "pack.Layer", "method": "answer", "force": "false", '
		+ '"note": "the layer stops answering"},'
		+ '{"name": "X-NOCUT", "type": "pack.Layer", "method": "answer", "note": "nobody can run this"}]}';

	/** A valid row beside one that claims both cuts at once. */
	private static final BOTH_CUTS: String = '{"arms": [{"name": "X-FORCE", "type": "pack.Layer", "method": "answer", "force": "false", '
		+ '"note": "the layer stops answering"},{"name": "X-BOTH", "type": "pack.Layer", "method": '
		+ '"answer", "force": "false", "find": "a", "note": "which one"}]}';

	/** Two rows that are each well-formed and share a name. */
	private static final DUPLICATE: String = '{"arms": ['
		+ '{"name": "X-TWICE", "type": "pack.Layer", "method": "answer", "force": "false", "note": "first"},'
		+ '{"name": "X-TWICE", "type": "pack.Other", "method": "shape", "force": "true", "note": "second"}]}';

	/** A clean table parses whole, and a name asked for is the arm that comes back. */
	@:pin('control')
	@:killer('M-ARM-ANYNAME')
	public function testAWellFormedTableAnswersByName(): Void {
		final table: ArmTable = MutationArms.parse(TWO_ARMS);
		Assert.same([], table.errors, 'the second table is clean, so the fixture reaches the lookup');
		Assert.equals(2, table.arms.length, 'both rows are admitted');
		final fragment: Null<MutationArm> = MutationArms.find(table.arms, 'X-FRAGMENT');
		Assert.notNull(fragment);
		Assert.equals('X-FRAGMENT', fragment == null ? '' : fragment.name, 'the name asked for is the arm returned');
		Assert.equals('a', fragment == null ? '' : fragment.find, 'and it carries its own cut, not a neighbour\'s');
	}

	/** The question a `@:killer` really asks: an undeclared name has no arm behind it. */
	@:pin('control')
	@:killer('M-ARM-ANYNAME')
	public function testAnUndeclaredNameResolvesToNoArm(): Void {
		final table: ArmTable = MutationArms.parse(TWO_ARMS);
		Assert.equals(2, table.arms.length, 'the table the lookup is asked about');
		Assert.isNull(MutationArms.find(table.arms, 'X-ABSENT'), 'a name the table does not declare resolves to nothing');
	}

	/**
	 * An arm that says nothing about what it cuts cannot be run, so it is not an arm.
	 *
	 * Two killers, because two cuts reach it: `M-ARM-ROW-OK` takes the complaint
	 * away, and `M-ARM-ANYNAME` makes the refused row resolvable by name anyway.
	 * A fixture one arm kills is not thereby the property of that arm alone, and
	 * naming both is what keeps a later run from reading the second as collateral.
	 */
	@:pin('control')
	@:killer('M-ARM-ROW-OK')
	@:killer('M-ARM-ANYNAME')
	public function testARowDeclaringNeitherCutIsRefused(): Void {
		final table: ArmTable = MutationArms.parse(NO_CUT);
		Assert.notNull(MutationArms.find(table.arms, 'X-FORCE'), 'the valid sibling row is admitted, so the read reached the table');
		Assert.equals(1, table.errors.length, 'the row without a cut is one complaint');
		Assert.stringContains('X-NOCUT', table.errors[0]);
		Assert.stringContains('declares neither "force" nor "find"', table.errors[0]);
		Assert.isNull(MutationArms.find(table.arms, 'X-NOCUT'), 'and it is not admitted as an arm');
	}

	/** Nor can one that claims both cuts — the runner would have to guess which. */
	@:pin('control')
	@:killer('M-ARM-ROW-OK')
	public function testARowDeclaringBothCutsIsRefused(): Void {
		final table: ArmTable = MutationArms.parse(BOTH_CUTS);
		Assert.notNull(MutationArms.find(table.arms, 'X-FORCE'), 'the valid sibling row is admitted, so the read reached the table');
		Assert.equals(1, table.errors.length, 'the row claiming both cuts is one complaint');
		Assert.stringContains('X-BOTH', table.errors[0]);
		Assert.stringContains('declares both "force" and "find"', table.errors[0]);
	}

	/**
	 * Two arms under one name make the name useless, so the table is refused.
	 *
	 * NO DECLARED ARM KILLS THIS ONE, and the role says so rather than a reader
	 * having to notice. The check is in `parse`, not in `rowErrors`: forcing
	 * `parse` to a constant takes the whole arm table with it, every `@:killer`
	 * in the tree stops resolving, and the mutant does not COMPILE — a
	 * `BUILD-FAIL`, which is the absence of a verdict rather than a kill.
	 * Measured, not reasoned: run
	 * `hxq patch test/testkit/MutationArms.hx --select 'FnMember:parse'` with
	 * `return { arms: [], errors: [] };` and the test build stops in
	 * `TestDiscovery`.
	 */
	@:pin('guard')
	public function testADuplicateArmNameIsRefused(): Void {
		final table: ArmTable = MutationArms.parse(DUPLICATE);
		Assert.equals(2, table.arms.length, 'each row is well-formed on its own, so both reach the duplicate check');
		Assert.equals(1, table.errors.length, 'the collision is one complaint');
		Assert.stringContains('declared more than once', table.errors[0]);
	}

	/** A table that is not JSON at all is one complaint, not a thrown exception a build macro cannot report. */
	@:pin('guard')
	public function testANonJsonTableIsOneComplaint(): Void {
		final table: ArmTable = MutationArms.parse('{"arms": [');
		Assert.equals(0, table.arms.length);
		Assert.equals(1, table.errors.length);
		Assert.stringContains('not valid JSON', table.errors[0]);
	}

	/** The `--list-arms` line: name, member, cut and reason, in the order a reader needs them. */
	@:pin('guard')
	public function testRenderNamesTheMemberAndTheCut(): Void {
		final table: ArmTable = MutationArms.parse(TWO_ARMS);
		Assert.equals(2, table.arms.length);
		Assert.equals('X-FORCE :: pack.Layer#answer :: return false; :: the layer stops answering', MutationArms.render(table.arms[0]));
		Assert.equals('X-FRAGMENT :: pack.Other#shape :: fragment :: the shape reads b', MutationArms.render(table.arms[1]));
	}

}
