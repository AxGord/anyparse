package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.QueryNode;
import anyparse.query.ShardPlan;
import testkit.TestRegistry;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * Unit cover for `apq shard-plan` — the split `tools/suite-shard.sh` used to
 * carry as fifteen awk blocks.
 *
 * The gates are the point. Every one of them exists because its absence is
 * SILENT: a registration the old text extractor could not name became a
 * filter matching no class, so a shard ran fewer tests while class parity
 * still passed; a name that is a substring of another runs TWICE once the two
 * land on different shards; a renamed pinned class un-pins itself and brings
 * back a race over a single-slot temp file. None of that was reachable by a
 * test while it lived in a shell function — this class is the first cover any
 * of it has had.
 *
 * Fixtures always register the whole pinned group, because a plan that omits
 * one is (correctly) refused; `runnerWithout` is the one that leaves a pinned
 * class out on purpose.
 */
@:nullSafety(Strict)
class ShardPlanTest extends Test {

	/** A floor the real runner cannot fall under without something being very wrong. */
	private static inline final MIN_REAL_REGISTRATIONS: Int = 500;

	public function testBareRegistrationTakesTheUnitPackage(): Void {
		final rows: Array<ShardPlacement> = planned(registering(['AlphaTest']), 2);
		Assert.isTrue(names(rows).contains('unit.AlphaTest'));
	}

	public function testDottedRegistrationKeepsItsOwnPackage(): Void {
		final rows: Array<ShardPlacement> = planned(registering(['zeta.OmegaTest']), 2);
		final placed: Array<String> = names(rows);
		Assert.isTrue(placed.contains('zeta.OmegaTest'));
		Assert.isFalse(placed.contains('unit.zeta.OmegaTest'));
	}

	/**
	 * The runner's own filtering wrapper calls `runner.addCase(...)` — a
	 * `FieldAccess` callee, not a registration. The fixture gives that call a
	 * `new` argument so that dropping the callee-shape guard makes it a
	 * nameable registration, and the count assertion below is what fires.
	 */
	public function testCallOnAReceiverIsNotARegistration(): Void {
		final rows: Array<ShardPlacement> = planned(registering(['AlphaTest']), 2);
		Assert.equals(ShardPlan.STICKY_CLASSES.length + 1, rows.length);
	}

	/**
	 * The upgrade over the text extractor: the old search pattern matched
	 * `addCase(new X(1))` too, and the strip produced the filter `unit.X(1))`,
	 * which selects no class at all.
	 */
	public function testConstructorArgumentIsRefused(): Void {
		final message: String = refusal(runnerWith(['addCase(new AlphaTest(1));']), 2);
		Assert.stringContains('cannot derive an APQ_TEST filter from', message);
		Assert.stringContains('holds a registration this generator cannot name', message);
	}

	public function testRegistrationThatIsNotANewExprIsRefused(): Void {
		final message: String = refusal(runnerWith(['addCase(alreadyBuilt);']), 2);
		Assert.stringContains('cannot derive an APQ_TEST filter from', message);
	}

	public function testDuplicateRegistrationIsRefused(): Void {
		final message: String = refusal(registering(['AlphaTest', 'AlphaTest']), 2);
		Assert.stringContains('registers the same class twice', message);
	}

	public function testSubstringCollisionIsRefused(): Void {
		final message: String = refusal(registering(['AlphaTest', 'AlphaTestExtra']), 2);
		Assert.stringContains('APQ_TEST filter collision', message);
		Assert.stringContains('unit.AlphaTest is a substring of unit.AlphaTestExtra', message);
	}

	public function testMissingPinnedClassIsRefused(): Void {
		final omitted: String = ShardPlan.STICKY_CLASSES[0];
		final message: String = refusal(runnerWithout(omitted), 2);
		Assert.stringContains('pinned class $omitted is not registered', message);
	}

	public function testNoRegistrationsAtAllIsRefused(): Void {
		final message: String = refusal('class RunTests {\n\tstatic function main(): Void {}\n}\n', 2);
		Assert.stringContains('found no addCase(new X()) registrations', message);
	}

	public function testEmptyShardIsRefused(): Void {
		// Every pinned class is dealt onto shard 0 as one block, so a runner
		// holding nothing else leaves shard 1 with no filter to run.
		final message: String = refusal(registering([]), 2);
		Assert.stringContains('shard 1 is empty — reduce --shards below 2', message);
	}

	public function testShardCountBelowOneIsRefused(): Void {
		Assert.stringContains('--shards must be >= 1', refusal(registering(['AlphaTest']), 0));
	}

	public function testEveryClassLandsExactlyOnce(): Void {
		final registered: Array<String> = generated(30);
		final rows: Array<ShardPlacement> = planned(registering(registered), 4);
		final placed: Array<String> = names(rows);
		Assert.equals(ShardPlan.STICKY_CLASSES.length + registered.length, placed.length);
		Assert.equals(placed.length, distinct(placed).length);
		for (name in registered) Assert.isTrue(placed.contains('unit.$name'));
	}

	/**
	 * The pinned group is dealt first, so it is all on shard 0 before the
	 * greedy pass starts filling anything.
	 */
	public function testStickyGroupLandsTogetherOnShardZero(): Void {
		final rows: Array<ShardPlacement> = planned(registering(generated(30)), 4);
		for (sticky in ShardPlan.STICKY_CLASSES)
			for (row in rows)
				if (row.cls == sticky) Assert.equals(0, row.shard, 'pinned $sticky landed on shard ${row.shard}');
	}

	/**
	 * 30 default-weight classes over four shards, asserted as a PROPERTY and
	 * never as a count vector: the vector depends on the
	 * production weight table, and `CLASS_WEIGHTS` promises that no gate reads
	 * it. Pinning `[8, 10, 10, 10]` here quietly made that promise false — a
	 * weight correction would have reddened the suite.
	 *
	 * The tail shards see only default-weight classes, so a working greedy pass
	 * splits them to within one class of each other; remove the min-scan and
	 * everything lands on shard 0, which the empty-shard gate refuses instead.
	 */
	public function testGreedySplitIsBalanced(): Void {
		final rows: Array<ShardPlacement> = planned(registering(generated(30)), 4);
		final perShard: Array<Int> = counts(rows, 4);
		Assert.equals(ShardPlan.STICKY_CLASSES.length + 30, perShard[0] + perShard[1] + perShard[2] + perShard[3]);
		final tail: Array<Int> = [perShard[1], perShard[2], perShard[3]];
		tail.sort((x, y) -> x - y);
		Assert.isTrue(tail[2] - tail[0] <= 1, 'tail split is unbalanced: $perShard');
	}

	/**
	 * The one direct cover of the pinned collation. Byte-identity of the plan
	 * across the port rode entirely on this order, and every other test reaches
	 * it only through a tiebreak nothing asserts.
	 *
	 * Expected order verified against `LC_ALL=ru_RU.UTF-8 sort` on the same six
	 * strings: punctuation before digits before letters, and lowercase before
	 * uppercase once the letters agree.
	 */
	public function testCompareNamesPinsTheUtf8Order(): Void {
		final names: Array<String> = ['unit.b', 'unit.B', 'unit.A', 'unit.a', 'unit._x', 'unit.0x'];
		names.sort(ShardPlan.compareNames);
		Assert.same(['unit._x', 'unit.0x', 'unit.a', 'unit.A', 'unit.b', 'unit.B'], names);
	}

	/**
	 * `APQ_TEST` matches the fully-qualified name, so a bare registration must
	 * be qualified the way the runner resolves it. Guessing `unit.` produced a
	 * filter matching no class — a skip class parity cannot see, since the
	 * bogus name is in the plan.
	 */
	public function testBareRegistrationFollowsTheRunnerImport(): Void {
		final rows: Array<ShardPlacement> = planned(runnerImporting('other.pkg.ForeignTest'), 2);
		final placed: Array<String> = names(rows);
		Assert.isTrue(placed.contains('other.pkg.ForeignTest'));
		Assert.isFalse(placed.contains('unit.ForeignTest'));
	}

	/**
	 * A `Conditional` flattens every branch as siblings with no marker for
	 * which one compiles, so planning them all invents a dead filter for the
	 * branches that are off — and one class registered under two exclusive
	 * branches reads as a duplicate.
	 */
	public function testRegistrationInsideAConditionalIsRefused(): Void {
		final message: String = refusal(runnerWith([
			'#if debug',
			'addCase(new DebugOnlyTest());',
			'#else',
			'addCase(new ReleaseOnlyTest());',
			'#end'
		]), 2);
		Assert.stringContains('registration inside a conditional-compilation region', message);
		Assert.stringContains('DebugOnlyTest', message);
		Assert.stringContains('ReleaseOnlyTest', message);
	}

	public function testShardCountAboveTheClassCountIsRefused(): Void {
		final message: String = refusal(registering(['AlphaTest']), ShardPlan.STICKY_CLASSES.length + 2);
		Assert.stringContains('exceeds the ${ShardPlan.STICKY_CLASSES.length + 1} registered classes', message);
	}

	public function testRenderLinesIsTabSeparatedInPlacementOrder(): Void {
		final rows: Array<ShardPlacement> = planned(registering(['AlphaTest']), 2);
		final lines: Array<String> = ShardPlan.renderLines(rows).split('\n');
		Assert.equals(rows.length + 1, lines.length);
		Assert.equals('', lines[lines.length - 1]);
		for (i in 0...rows.length) Assert.equals('${rows[i].shard}\t${rows[i].cls}', lines[i]);
	}

	public function testRenderFiltersIsOneCommaJoinedLinePerShard(): Void {
		final rows: Array<ShardPlacement> = planned(registering(generated(30)), 4);
		final lines: Array<String> = ShardPlan.renderFilters(rows, 4).split('\n');
		final perShard: Array<Int> = counts(rows, 4);
		Assert.equals(5, lines.length);
		for (s in 0...4) Assert.equals(perShard[s], lines[s].split(',').length);
	}

	/**
	 * The pleasing recursion: this class is in the very registry the subcommand
	 * plans, so the end-to-end fixture is the suite itself. It also makes every
	 * gate above a live guard on the real class list — a colliding or duplicated
	 * name now turns the suite red instead of quietly shrinking a shard.
	 *
	 * It reaches `planClasses` rather than `plan` because that is the door
	 * `tools/suite-shard.sh` uses since the registration layer became generated:
	 * the script asks the runner itself (`node bin/test.js --list-classes`) and
	 * hands the answer to `apq shard-plan --classes`. Planning the list the run
	 * will ACTUALLY register is the whole point of that door — parsing
	 * `test/RunTests.hx` would now find no registrations at all, and did, which
	 * is how this test found the coupling.
	 */
	public function testTheRealRegistryPlansWithoutRefusal(): Void {
		final registered: Array<String> = TestRegistry.classNames();
		final rows: Array<ShardPlacement> = unwrap(ShardPlan.planClasses(registered, 4, 'testkit.TestRegistry'));
		final placed: Array<String> = names(rows);
		Assert.equals(registered.length, placed.length);
		Assert.isTrue(placed.length > MIN_REAL_REGISTRATIONS);
		Assert.equals(placed.length, distinct(placed).length);
		Assert.isTrue(placed.contains('unit.query.ShardPlanTest'));
	}

	/**
	 * The `--classes` door reaches the same gates the `--runner` door does. A
	 * duplicate is the cheapest of them to state, and the one a name list can
	 * carry that an `addCase` list cannot: the runner would have thrown.
	 */
	public function testAClassListWithADuplicateIsRefused(): Void {
		final listed: Array<String> = ShardPlan.STICKY_CLASSES.concat(['unit.AlphaTest', 'unit.AlphaTest']);
		final message: String = switch ShardPlan.planClasses(listed, 2, 'a list') {
			case Planned(_):
				Assert.fail('expected a refusal');
				'';
			case Refused(text):
				text;
		};
		Assert.stringContains('registers the same class twice', message);
	}

	/** A pinned class missing from the list is refused through `--classes` too. */
	public function testAClassListMissingAPinnedClassIsRefused(): Void {
		final listed: Array<String> = ShardPlan.STICKY_CLASSES.filter(name -> name != 'unit.cli.ApqProbeCliTest');
		final message: String = switch ShardPlan.planClasses(listed, 2, 'a list') {
			case Planned(_):
				Assert.fail('expected a refusal');
				'';
			case Refused(text):
				text;
		};
		Assert.stringContains('pinned class unit.cli.ApqProbeCliTest is not registered in a list', message);
	}

	/** A runner registering every pinned class, then `statements` verbatim. */
	private inline function runnerWith(statements: Array<String>): String {
		return build(ShardPlan.STICKY_CLASSES, statements);
	}

	/** Parse `source` as a runner and plan it, failing the test on a refusal. */
	private function planned(source: String, shards: Int): Array<ShardPlacement> {
		return unwrap(plan(source, shards));
	}

	/** Parse `source` as a runner and return the refusal, failing the test on a plan. */
	private function refusal(source: String, shards: Int): String {
		return switch plan(source, shards) {
			case Planned(_):
				Assert.fail('expected a refusal');
				'';
			case Refused(message):
				message;
		};
	}

	private function unwrap(result: ShardPlanResult): Array<ShardPlacement> {
		return switch result {
			case Planned(placements):
				placements;
			case Refused(message):
				Assert.fail('unexpected refusal: $message');
				[];
		};
	}

	private function plan(source: String, shards: Int): ShardPlanResult {
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(source);
		return ShardPlan.plan({
			tree: tree,
			source: source,
			runner: 'test/RunTests.hx',
			shards: shards
		});
	}

	/** A runner registering every pinned class except `omitted`. */
	private function runnerWithout(omitted: String): String {
		return build(ShardPlan.STICKY_CLASSES.filter(name -> name != omitted), []);
	}

	/** A runner registering every pinned class, then one `addCase(new X());` per name. */
	private function registering(extras: Array<String>): String {
		return runnerWith(extras.map(name -> 'addCase(new $name());'));
	}

	private function build(sticky: Array<String>, statements: Array<String>): String {
		final buf: StringBuf = new StringBuf();
		// The sticky classes live in `unit.*` SUBPACKAGES since the test tree was
		// laid out by package, and a bare registration is qualified through the
		// runner's imports — so the synthetic runner has to carry them, exactly as
		// the real one's generated registry does.
		for (name in sticky) buf.add('import $name;\n');
		buf.add('class RunTests {\n');
		buf.add('\tstatic function main(): Void {\n');
		// The wrapper the real runner declares — its call must not be read as a
		// registration. The argument is a `new` on purpose: with the callee-shape
		// guard removed this becomes a NAMEABLE registration and inflates the
		// count, so the class-count assertion is what fires rather than a generic
		// refusal from somewhere else.
		buf.add('\t\trunner.addCase(new WrapperTest());\n');
		for (name in sticky) buf.add('\t\taddCase(new ${bareName(name)}());\n');
		for (statement in statements) buf.add('\t\t$statement\n');
		buf.add('\t}\n');
		buf.add('}\n');
		return buf.toString();
	}

	/** `unit.FooTest` -> `FooTest`, so a fixture exercises the bare-name path. */
	private function bareName(qualified: String): String {
		final dot: Int = qualified.lastIndexOf('.');
		return dot < 0 ? qualified : qualified.substr(dot + 1);
	}

	/** `Gen00Test` … — same length, so none is a substring of another. */
	private function generated(count: Int): Array<String> {
		return [for (i in 0...count) 'Gen${i < 10 ? '0$i' : '$i'}Test'];
	}

	private function names(placements: Array<ShardPlacement>): Array<String> {
		return [for (p in placements) p.cls];
	}

	private function counts(placements: Array<ShardPlacement>, shards: Int): Array<Int> {
		return [for (s in 0...shards) placements.count(p -> p.shard == s)];
	}

	private function distinct(input: Array<String>): Array<String> {
		final out: Array<String> = [];
		for (name in input) if (!out.contains(name)) out.push(name);
		return out;
	}

	/** A runner that imports `path` and registers it by its bare simple name. */
	private function runnerImporting(path: String): String {
		return 'import $path;\n\n${build(ShardPlan.STICKY_CLASSES, ['addCase(new ${bareName(path)}());'])}';
	}

}
