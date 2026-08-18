package unit;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.QueryNode;
import anyparse.query.ShardPlan;
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
	 * `runner.addCase(testCase)` inside the runner own filtering wrapper is a
	 * `FieldAccess` callee, not a registration — counting it would place a
	 * class named after a local parameter.
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
		for (sticky in ShardPlan.STICKY_CLASSES) for (row in rows) if (row.cls == sticky)
			Assert.equals(0, row.shard, 'pinned $sticky landed on shard ${row.shard}');
	}

	/**
	 * 30 default-weight classes over four shards: the pinned group already
	 * loads shard 0 far past what 30 x 30 ms can reach, so the greedy pass
	 * splits the tail evenly over the other three and shard 0 gains nothing.
	 */
	public function testGreedySplitIsBalanced(): Void {
		final rows: Array<ShardPlacement> = planned(registering(generated(30)), 4);
		Assert.same([ShardPlan.STICKY_CLASSES.length, 10, 10, 10], counts(rows, 4));
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
		Assert.equals(5, lines.length);
		for (s in 0...4) Assert.equals(counts(rows, 4)[s], lines[s].split(',').length);
	}

	#if (sys || nodejs)
	/**
	 * The pleasing recursion: this class is registered in the very file the
	 * subcommand reads, so the end-to-end fixture is the suite itself. It also
	 * makes every gate above a live guard on the real registration list —
	 * adding a colliding or unnameable registration now turns the suite red
	 * instead of quietly shrinking a shard.
	 */
	public function testTheRealRunnerPlansWithoutRefusal(): Void {
		final path: String = 'test/RunTests.hx';
		final source: String = sys.io.File.getContent(path);
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(source);
		final rows: Array<ShardPlacement> = unwrap(ShardPlan.plan({
			tree: tree,
			source: source,
			runner: path,
			shards: 4
		}));
		final placed: Array<String> = names(rows);
		Assert.isTrue(placed.length > MIN_REAL_REGISTRATIONS);
		Assert.equals(placed.length, distinct(placed).length);
		Assert.isTrue(placed.contains('unit.ShardPlanTest'));
	}
	#end

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
		buf.add('class RunTests {\n');
		buf.add('\tstatic function main(): Void {\n');
		// The wrapper the real runner declares — its call must not be read as
		// a registration.
		buf.add('\t\trunner.addCase(testCase);\n');
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

	private function distinct(names: Array<String>): Array<String> {
		final out: Array<String> = [];
		for (name in names) if (!out.contains(name)) out.push(name);
		return out;
	}

}
