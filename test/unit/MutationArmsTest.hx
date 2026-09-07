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

	/** A default-kind row beside one addressing a grammar declaration's `@:re` terminal. */
	private static final KINDED: String = '{"arms": [{"name": "X-FORCE", "type": "pack.Layer", "method": "answer", "force": "false", '
		+ '"note": "the layer stops answering"},{"name": "X-META", "type": "pack.Raw", "method": "@:re", "kind": "MetaCall", '
		+ '"find": "a", "replace": "b", "note": "the terminal never matches"}]}';

	/** A valid row beside one asking for a forced return on something that has no signature. */
	private static final FORCED_KIND: String = '{"arms": [{"name": "X-FORCE", "type": "pack.Layer", "method": "answer", '
		+ '"force": "false", "note": "the layer stops answering"},{"name": "X-FORCED-META", "type": "pack.Raw", '
		+ '"method": "@:re", "kind": "MetaCall", "force": "false", "note": "nothing to splice after"}]}';

	/** A valid row beside a two-pair cut — the shape a permutation of two statements needs. */
	private static final TWO_PAIRS: String = '{"arms": [{"name": "X-FORCE", "type": "pack.Layer", "method": "answer", "force": "false", '
		+ '"note": "the layer stops answering"},{"name": "X-PAIRS", "type": "pack.Other", "method": "shape", '
		+ '"find": ["a", "c"], "replace": ["b", "d"], "note": "the shape reads b and d"}]}';

	/** A valid row beside one whose two lists do not pair up. */
	private static final UNEVEN_PAIRS: String = '{"arms": [{"name": "X-FORCE", "type": "pack.Layer", "method": "answer", '
		+ '"force": "false", "note": "the layer stops answering"},{"name": "X-UNEVEN", "type": "pack.Other", "method": "shape", '
		+ '"find": ["a", "c"], "replace": ["b"], "note": "which fragment loses its replacement"}]}';

	/** A valid row beside one whose cut is an array with nothing in it. */
	private static final EMPTY_LISTS: String = '{"arms": [{"name": "X-FORCE", "type": "pack.Layer", "method": "answer", '
		+ '"force": "false", "note": "the layer stops answering"},{"name": "X-EMPTY", "type": "pack.Other", "method": "shape", '
		+ '"find": [], "replace": [], "note": "nothing to cut"}]}';

	/** A valid row beside one claiming a forced return AND a multi-pair fragment cut. */
	private static final FORCED_PAIRS: String = '{"arms": [{"name": "X-FORCE", "type": "pack.Layer", "method": "answer", '
		+ '"force": "false", "note": "the layer stops answering"},{"name": "X-FORCED-PAIRS", "type": "pack.Other", '
		+ '"method": "shape", "force": "false", "find": ["a", "c"], "replace": ["b", "d"], "note": "which one"}]}';

	/** A valid row beside one whose first pair replaces its fragment with itself. */
	private static final NOOP_PAIR: String = '{"arms": [{"name": "X-FORCE", "type": "pack.Layer", "method": "answer", '
		+ '"force": "false", "note": "the layer stops answering"},{"name": "X-NOOP", "type": "pack.Other", "method": "shape", '
		+ '"find": ["a", "c"], "replace": ["a", "d"], "note": "the first pair changes nothing"}]}';

	/** A valid row beside one whose "find" list holds something that is not a string. */
	private static final NON_STRING: String = '{"arms": [{"name": "X-FORCE", "type": "pack.Layer", "method": "answer", '
		+ '"force": "false", "note": "the layer stops answering"},{"name": "X-NONSTRING", "type": "pack.Other", '
		+ '"method": "shape", "find": [1], "replace": ["b"], "note": "a number is not a fragment"}]}';

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
		Assert.same(['a'], fragment == null ? [] : fragment.find, 'and it carries its own cut, not a neighbour\'s');
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

	/**
	 * A dotted type becomes the two files the runner tries, in classpath order.
	 *
	 * `tools/mutation-arm.sh` resolves an arm's `type` to a file by hand — `for root in
	 * src test`, first hit wins — and `unit.MutationArmAddressTest` parses whichever one
	 * exists. This is the pure half of that, asked of a type name written here rather
	 * than of the real registry, so `M-ARM-PATH-FLAT` has a second instance to break.
	 */
	@:pin('control')
	@:killer('M-ARM-PATH-FLAT')
	public function testAModulePathBecomesTheTwoCandidateFiles(): Void {
		Assert.same(['src/Bare.hx', 'test/Bare.hx'], MutationArms.candidateFiles('Bare'), 'a package-less type is one segment, not none');
		Assert.same(
			['src/pack/deep/Layer.hx', 'test/pack/deep/Layer.hx'],
			MutationArms.candidateFiles('pack.deep.Layer'), 'and every dot becomes a directory'
		);
	}

	/** The `--list-arms` line: name, member, cut and reason, in the order a reader needs them. */
	@:pin('guard')
	public function testRenderNamesTheMemberAndTheCut(): Void {
		final table: ArmTable = MutationArms.parse(TWO_ARMS);
		Assert.equals(2, table.arms.length);
		Assert.equals('X-FORCE :: pack.Layer#answer :: return false; :: the layer stops answering', MutationArms.render(table.arms[0]));
		Assert.equals('X-FRAGMENT :: pack.Other#shape :: fragment :: the shape reads b', MutationArms.render(table.arms[1]));
	}

	/**
	 * An arm that names no kind addresses a member, and one that names a kind spells it.
	 *
	 * The kind is what lets an arm reach a grammar DECLARATION: `HxCondBlockTailRaw` is an
	 * abstract with no method at all, and the cut that disables it lands on its `@:re`
	 * terminal, a module-level `MetaCall`. `address` is the only place the runner's selector
	 * is written down, so an arm that drops the kind there silently asks for
	 * `FnMember:@:re` and reaches nothing.
	 */
	@:pin('control')
	@:killer('M-ARM-KIND-UNSPELLED')
	public function testAKindedArmSpellsItsKindInTheAddress(): Void {
		final table: ArmTable = MutationArms.parse(KINDED);
		Assert.same([], table.errors, 'the second table is clean, so the fixture reaches the render');
		Assert.equals('pack.Layer#answer', MutationArms.address(table.arms[0]), 'the default kind stays unspelled');
		Assert.equals('pack.Raw#MetaCall:@:re', MutationArms.address(table.arms[1]), 'and a kinded arm carries it');
		Assert.equals('FnMember:answer', MutationArms.selectorOf('answer'), 'a bare member reads back as the default kind');
		Assert.equals(
			'MetaCall:@:re', MutationArms.selectorOf('MetaCall:@:re'), 'and a colon-bearing name splits once, not at every colon'
		);
	}

	/**
	 * A multi-pair cut reads back as its own list of fragments, and the rendered line says so.
	 *
	 * The scalar spelling is that same list with one element, which is what keeps all 161
	 * existing fragment records — and every `--list-arms` row they produce — byte-unchanged.
	 */
	@:pin('guard')
	public function testAMultiPairCutCarriesEveryFragment(): Void {
		final table: ArmTable = MutationArms.parse(TWO_PAIRS);
		Assert.same([], table.errors, 'the second table is clean, so the fixture reaches the read');
		final arm: Null<MutationArm> = MutationArms.find(table.arms, 'X-PAIRS');
		Assert.notNull(arm);
		Assert.same(['a', 'c'], arm == null ? [] : arm.find, 'both fragments come back, in the order written');
		Assert.same(['b', 'd'], arm == null ? [] : arm.replace, 'and each keeps its own replacement');
		Assert.equals(
			'X-PAIRS :: pack.Other#shape :: 2 fragments :: the shape reads b and d', arm == null ? '' : MutationArms.render(arm),
			'the rendered line counts the pairs'
		);
		final single: Null<MutationArm> = MutationArms.find(MutationArms.parse(TWO_ARMS).arms, 'X-FRAGMENT');
		Assert.equals(
			'X-FRAGMENT :: pack.Other#shape :: fragment :: the shape reads b', single == null ? '' : MutationArms.render(single),
			'and a one-pair cut still renders the word it always did'
		);
	}

	/**
	 * Two lists that do not pair up cannot be rendered into a payload, so the row is refused.
	 *
	 * `apq patch` alternates old / new sections and needs an EVEN count. A record with two
	 * fragments and one replacement would hand it an odd one, and the failure would arrive as
	 * a usage error about the payload rather than as a complaint naming the arm.
	 */
	@:pin('control')
	@:killer('M-ARM-ROW-OK')
	public function testAMismatchedPairCountIsRefused(): Void {
		final table: ArmTable = MutationArms.parse(UNEVEN_PAIRS);
		Assert.notNull(MutationArms.find(table.arms, 'X-FORCE'), 'the valid sibling row is admitted, so the read reached the table');
		Assert.equals(1, table.errors.length, 'the uneven row is one complaint');
		Assert.stringContains('X-UNEVEN', table.errors[0]);
		Assert.stringContains('2 "find" fragment(s) against 1 "replace"', table.errors[0]);
	}

	/** An array with no entry in it declares no cut at all, and is named by its key rather than by silence. */
	@:pin('control')
	@:killer('M-ARM-ROW-OK')
	public function testAnEmptyFragmentArrayIsRefused(): Void {
		final table: ArmTable = MutationArms.parse(EMPTY_LISTS);
		Assert.notNull(MutationArms.find(table.arms, 'X-FORCE'), 'the valid sibling row is admitted, so the read reached the table');
		Assert.equals(2, table.errors.length, 'each empty list is its own complaint');
		Assert.stringContains('empty "find" array', table.errors[0]);
		Assert.stringContains('empty "replace" array', table.errors[1]);
	}

	/**
	 * The list spelling opens no second way to claim both cuts at once.
	 *
	 * The exclusivity check read `find` as a STRING, so a record spelling it as an array would
	 * have gone straight past it and left the runner holding a forced return and a fragment
	 * payload with nothing to say which one it was asked for.
	 */
	@:pin('control')
	@:killer('M-ARM-ROW-OK')
	public function testAForcedRowWithFragmentListsIsRefused(): Void {
		final table: ArmTable = MutationArms.parse(FORCED_PAIRS);
		Assert.notNull(MutationArms.find(table.arms, 'X-FORCE'), 'the valid sibling row is admitted, so the read reached the table');
		Assert.equals(1, table.errors.length, 'the row claiming both cuts is one complaint');
		Assert.stringContains('X-FORCED-PAIRS', table.errors[0]);
		Assert.stringContains('declares both "force" and "find"', table.errors[0]);
	}

	/**
	 * A pair whose `replace` is its own `find` changes nothing, and `apq patch` refuses it —
	 * so the registry refuses it too, rather than leaving it for whoever runs the arm.
	 *
	 * The row is otherwise perfect: two fragments, two replacements, equal lengths. Only the
	 * pairing is wrong, which is a question no length comparison can reach.
	 */
	@:pin('control')
	@:killer('M-ARM-ROW-OK')
	public function testAPairThatChangesNothingIsRefused(): Void {
		final table: ArmTable = MutationArms.parse(NOOP_PAIR);
		Assert.notNull(MutationArms.find(table.arms, 'X-FORCE'), 'the valid sibling row is admitted, so the read reached the table');
		Assert.equals(1, table.errors.length, 'the second pair does change something, so only the first is a complaint');
		Assert.stringContains('X-NOOP', table.errors[0]);
		Assert.stringContains('in pair 1', table.errors[0]);
	}

	/**
	 * A malformed fragment list is named by its own key, and by that key ALONE.
	 *
	 * `strings` answers null for a list holding a non-string exactly as it does for an absent
	 * key, so the clauses that read absence as intent would pile "declares neither cut" and
	 * "replace without find" on top of the one complaint that is true — three errors for one
	 * defect, two of them pointing at the wrong key.
	 */
	@:pin('control')
	@:killer('M-ARM-ROW-OK')
	public function testAMalformedFragmentListIsNamedByItsKeyAlone(): Void {
		final table: ArmTable = MutationArms.parse(NON_STRING);
		Assert.notNull(MutationArms.find(table.arms, 'X-FORCE'), 'the valid sibling row is admitted, so the read reached the table');
		Assert.equals(1, table.errors.length, 'the malformed list is one complaint, not three');
		Assert.stringContains('X-NONSTRING', table.errors[0]);
		Assert.stringContains('"find" entry that is not a string', table.errors[0]);
	}

	/**
	 * A `force` cut cannot address anything but a member: the runner splices `return <x>;`
	 * after a function signature, and a metadata node has no signature to splice after.
	 * Refused at the ROW, where the arm has a name, rather than in the shell, where it would
	 * be a rendering failure with nothing to point at.
	 */
	@:pin('control')
	@:killer('M-ARM-ROW-OK')
	public function testAForcedCutWithANonDefaultKindIsRefused(): Void {
		final table: ArmTable = MutationArms.parse(FORCED_KIND);
		Assert.notNull(MutationArms.find(table.arms, 'X-FORCE'), 'the valid sibling row is admitted, so the read reached the table');
		Assert.equals(1, table.errors.length, 'the forced row with a kind is one complaint');
		Assert.stringContains('X-FORCED-META', table.errors[0]);
		Assert.stringContains('only FnMember can carry one', table.errors[0]);
	}

}
