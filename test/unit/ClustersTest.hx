package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.CallGraph;
import anyparse.query.Clusters;
import anyparse.query.Clusters.ClusterReport;
import anyparse.query.CallGraph.FnNode;
import anyparse.query.CallGraph.EdgeKind;
import anyparse.query.Clusters.HubUse;

/**
 * Partition analytics behind `apq clusters`: connected components over
 * aggregated intra-type call edges, hub extraction (auto / explicit / off),
 * lambda condensation into the enclosing member, hub-traffic accounting and
 * the resolved/unresolved coverage counts.
 */
@:nullSafety(Strict)
class ClustersTest extends Test {

	/**
	 * Two call-islands with no hub worth extracting: auto mode leaves the
	 * members alone and reports the natural split.
	 * Two 2-member islands glued by a logger every member calls.
	 */
	private static final HUB_GLUED: String = 'class A { function a():Void { b(); log(); } function b():Void log(); function c():Void { d(); log(); } function d():Void log(); function log():Void {} }';

	/**
	 * HUB_GLUED with the hub calling back into the second island.
	 */
	private static final HUB_CALLBACK: String = 'class A { function a():Void { b(); log(); } function b():Void log(); function c():Void { d(); log(); } function d():Void log(); function log():Void d(); }';

	public function testTwoIslandsSplitWithoutHubs(): Void {
		final r: Null<ClusterReport> = analyzeOf([
			'class A { function a():Void b(); function b():Void {} function c():Void d(); function d():Void {} }',
		], 'A');
		Assert.notNull(r);
		if (r == null) return;
		Assert.equals(4, r.memberCount);
		Assert.equals(0, r.hubs.length);
		Assert.equals(2, r.components.length);
		Assert.equals('A.a,A.b', ids(r.components[0]));
		Assert.equals('A.c,A.d', ids(r.components[1]));
	}

	/**
	 * A logger called by everyone glues both islands into one blob; auto
	 * mode extracts it by fan-in and the islands separate.
	 */
	public function testAutoHubExtractionSeparatesIslands(): Void {
		final r: Null<ClusterReport> = analyzeOf([HUB_GLUED], 'A');
		Assert.notNull(r);
		if (r == null) return;
		Assert.isTrue(r.autoHubs);
		Assert.equals(1, r.hubs.length);
		Assert.equals('A.log', r.hubs[0].id);
		Assert.equals(4, r.hubs[0].fanIn);
		Assert.equals(6, r.intraEdgeSites);
		Assert.equals(2, r.components.length);
		Assert.equals('A.a,A.b', ids(r.components[0]));
		Assert.equals('A.c,A.d', ids(r.components[1]));
	}

	public function testHubsZeroKeepsTheBlob(): Void {
		final r: Null<ClusterReport> = analyzeOf([HUB_GLUED], 'A', 0);
		Assert.notNull(r);
		if (r == null) return;
		Assert.equals(0, r.hubs.length);
		Assert.equals(1, r.components.length);
		Assert.equals(5, r.components[0].length);
	}

	public function testExplicitHubCountMatchesAuto(): Void {
		final r: Null<ClusterReport> = analyzeOf([HUB_GLUED], 'A', 1);
		Assert.notNull(r);
		if (r == null) return;
		Assert.isFalse(r.autoHubs);
		Assert.equals(1, r.hubs.length);
		Assert.equals('A.log', r.hubs[0].id);
		Assert.equals(2, r.components.length);
	}

	/**
	 * Each component's hub traffic is directional: both islands call the
	 * log hub twice (one aggregated site per member), the hub calls no one.
	 */
	public function testHubTrafficPerComponent(): Void {
		final r: Null<ClusterReport> = analyzeOf([HUB_GLUED], 'A');
		Assert.notNull(r);
		if (r == null) return;
		Assert.equals(2, r.hubUses.length);
		Assert.equals(1, r.hubUses[0].component);
		Assert.equals(2, r.hubUses[1].component);
		for (u in r.hubUses) {
			Assert.equals('A.log', u.hubId);
			Assert.equals(2, u.toHub);
			Assert.equals(0, u.fromHub);
		}
	}

	/**
	 * A call made inside a lambda belongs to the enclosing member: the
	 * clustering unit is the top-level member, never `A.a#1`.
	 */
	public function testLambdaCondensesToEnclosingMember(): Void {
		final r: Null<ClusterReport> = analyzeOf([
			'class A { function a():Void { final f = () -> b(); f(); } function b():Void {} }',
		], 'A');
		Assert.notNull(r);
		if (r == null) return;
		Assert.equals(2, r.memberCount);
		Assert.equals(1, r.components.length);
		Assert.equals('A.a,A.b', ids(r.components[0]));
	}

	/**
	 * An unresolvable call inside a member span counts against coverage;
	 * the resolved bare call still counts as a resolved site.
	 */
	public function testCoverageCountsUnresolvedInsideMembers(): Void {
		final r: Null<ClusterReport> = analyzeOf(['class A { function a():Void get().run(); function get():Thing return null; }',], 'A');
		Assert.notNull(r);
		if (r == null) return;
		Assert.equals(1, r.unresolvedSites);
		Assert.equals(1, r.resolvedSites);
	}

	public function testUnknownTypeReturnsNull(): Void {
		Assert.isNull(analyzeOf(['class A { function a():Void {} }'], 'Missing'));
	}

	public function testRenderSmoke(): Void {
		final g: CallGraph = QueryTestHelpers.graphOf([HUB_GLUED]);
		final r: Null<ClusterReport> = Clusters.analyze(g, 'A', null, null);
		Assert.notNull(r);
		if (r == null) return;
		final text: String = Clusters.render(g, r, f -> null);
		Assert.isTrue(text.indexOf('clusters for A') == 0);
		Assert.isTrue(text.indexOf('hubs (auto — 1 extracted):') != -1);
		Assert.isTrue(text.indexOf('component 1 — 2 member(s):') != -1);
		Assert.isTrue(text.indexOf('-> hubs: log ×2') != -1);
	}

	/**
	 * Members linked only by a method-value reference stay together under
	 * the default kinds and separate when narrowed to plain calls.
	 */
	public function testKindsFilterDropsRefEdges(): Void {
		final source: String = 'class A { function a():Void run(b); function run(f:() -> Void):Void f(); function b():Void {} }';
		final all: Null<ClusterReport> = analyzeOf([source], 'A');
		Assert.notNull(all);
		if (all == null) return;
		Assert.equals(1, all.components.length);
		final callOnly: Null<ClusterReport> = analyzeOf([source], 'A', null, [Call]);
		Assert.notNull(callOnly);
		if (callOnly == null) return;
		Assert.equals(2, callOnly.components.length);
		Assert.equals('A.b', ids(callOnly.components[1]));
	}

	/**
	 * A hub that also calls back into a component shows up as `fromHub` —
	 * the dispatcher-mis-bucketed-as-utility smell.
	 */
	public function testHubCallbackReportsFromHub(): Void {
		final r: Null<ClusterReport> = analyzeOf([HUB_CALLBACK], 'A');
		Assert.notNull(r);
		if (r == null) return;
		Assert.equals('A.log', r.hubs[0].id);
		final second: HubUse = r.hubUses[1];
		Assert.equals(2, second.component);
		Assert.equals('A.log', second.hubId);
		Assert.equals(2, second.toHub);
		Assert.equals(1, second.fromHub);
	}

	/**
	 * An explicit --hubs larger than the qualifying pool: fan-in-0 members
	 * never become hubs; ordering is fan-in desc with id tie-break.
	 */
	public function testExplicitHubsCappedByQualifyingMembers(): Void {
		final r: Null<ClusterReport> = analyzeOf([HUB_GLUED], 'A', 10);
		Assert.notNull(r);
		if (r == null) return;
		Assert.equals('A.log,A.b,A.d', [for (h in r.hubs) h.id].join(','));
		Assert.equals(2, r.components.length);
	}

	private function analyzeOf(sources: Array<String>, typeName: String, ?hubCount: Int, ?kinds: Array<EdgeKind>): Null<ClusterReport> {
		return Clusters.analyze(QueryTestHelpers.graphOf(sources), typeName, hubCount, kinds);
	}

	private function ids(component: Array<FnNode>): String {
		return [for (n in component) n.id].join(',');
	}

}
