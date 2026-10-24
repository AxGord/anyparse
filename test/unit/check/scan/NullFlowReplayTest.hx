package unit.check.scan;

import anyparse.check.scan.NullFlow;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefsCache;
import anyparse.query.TypeInfoProvider;

using Lambda;

/**
 * A seedless `NullFlow.analyze` walk over a tree the run's `RefsCache` holds is recorded once and replayed to every
 * later consumer. The contract: a replay hands each consumer exactly the visits, in exactly the order, with exactly
 * the facts a live walk would have — and a walk that a seed, a `declaredNullable` or `typeSources` makes different is
 * never answered from the recording.
 *
 * Every fact is read through a TRANSCRIPT: one line per visit naming the node and, for every name in the file, which
 * of the four accessors answer true, plus `indexPresent` of the node. The live transcript comes from the bare
 * plugin's shape, which carries no cache.
 */
@:nullSafety(Strict)
final class NullFlowReplayTest extends Test {

	/** Narrowing by early exit, assignment, a branch, an exists-guard, a loop, a switch, a try and a lambda unit. */
	private static final FLOW: String = '
		class C {
			function f(a: Foo, b: Foo, m: Map<String, Foo>, k: String) {
				var x = null;
				if (a == null) return;
				a.go();
				x = new Foo();
				x.go();
				x = null;
				if (b != null) b.go() else trace(b);
				if (m.exists(k)) m[k].go();
				var y = b;
				while (y != null) y = y.next;
				switch (a.kind) {
					case 1: x = new Foo();
					case _:
				}
				try {
					x = a;
				} catch (e: Dynamic) {}
				(v -> v?.go())(a);
			}
		}
	';

	/** A nullable source the seed recognises (an index read), a declared `Null<T>` local, and a non-null predicate. */
	private static final SEEDED: String = '
		class C {
			static function ok(p: Foo): Bool return p != null;

			function f(m: Map<String, Foo>, k: String, z: Foo) {
				var u = m[k];
				u.go();
				var w: Null<Foo> = make();
				w.go();
				if (ok(z)) z.go();
			}
		}
	';

	/** The first walk records and the second replays; both answer what the live walk answered, visit for visit. */
	@:pin('control')
	@:killer('M-NULLFLOW-FROZEN-STALE')
	public function testAReplayAnswersWhatTheLiveWalkAnswered(): Void {
		final f: Fixture = fixture(FLOW);
		final live: Array<String> = transcript(f.tree, f.bare, FLOW);
		Assert.isTrue(live.length > 20, 'the fixture must visit enough nodes to discriminate, got ${live.length}');
		Assert.same(live, transcript(f.tree, f.cached, FLOW), 'recording walk');
		Assert.same(live, transcript(f.tree, f.cached, FLOW), 'replayed walk');
	}

	/** A walk with a seed is its own walk: after a seedless recording it still reports the `MaybeNull` the seed makes. */
	@:pin('control')
	@:killer('M-NULLFLOW-MEMO-SEED-BLIND')
	public function testASeededWalkIsNeverReplayed(): Void {
		final f: Fixture = fixture(SEEDED);
		final index: Null<String> = f.bare.indexAccessKind;
		final seed: QueryNode -> Bool = node -> node.kind == index;
		final live: Array<String> = transcript(f.tree, f.bare, SEEDED, seed);
		Assert.isTrue(live.exists(answers.bind(_, 'maybe', 'u')), 'the seed must make u MaybeNull somewhere: $live');
		Assert.isTrue(transcript(f.tree, f.cached, SEEDED).length > 0, 'the seedless walk records');
		Assert.same(live, transcript(f.tree, f.cached, SEEDED, seed));
	}

	/** Likewise a `declaredNullable` walk, whose annotation seed makes `w` MaybeNull. */
	@:pin('control')
	@:killer('M-NULLFLOW-MEMO-DECLARED-BLIND')
	public function testADeclaredNullableWalkIsNeverReplayed(): Void {
		final f: Fixture = fixture(SEEDED);
		final declared: QueryNode -> Bool = node -> node.name == 'w';
		final live: Array<String> = transcript(f.tree, f.bare, SEEDED, null, declared);
		Assert.isTrue(live.exists(answers.bind(_, 'maybe', 'w')), 'the annotation must make w MaybeNull somewhere: $live');
		Assert.isTrue(transcript(f.tree, f.cached, SEEDED).length > 0, 'the seedless walk records');
		Assert.same(live, transcript(f.tree, f.cached, SEEDED, null, declared));
	}

	/** Likewise a walk given the written types, under which the predicate call `ok(z)` narrows `z`. */
	@:pin('control')
	@:killer('M-NULLFLOW-MEMO-TYPES-BLIND')
	public function testATypeSourcesWalkIsNeverReplayed(): Void {
		final f: Fixture = fixture(SEEDED);
		final typed: TypeInfoProvider = cast f.plugin;
		final types: Map<Int, String> = typed.declaredTypeSources(SEEDED);
		final live: Array<String> = transcript(f.tree, f.bare, SEEDED, null, null, types);
		Assert.isTrue(live.exists(answers.bind(_, 'nn', 'z')), 'the predicate must narrow z somewhere: $live');
		Assert.isTrue(transcript(f.tree, f.cached, SEEDED).length > 0, 'the seedless walk records');
		Assert.same(live, transcript(f.tree, f.cached, SEEDED, null, null, types));
	}

	/** A tree asked about with another source is not answered from the recording made over the first. */
	@:pin('control')
	@:killer('M-NULLFLOW-MEMO-SOURCE-BLIND')
	public function testARecordingIsKeptForItsOwnSourceOnly(): Void {
		final cache: RefsCache = new RefsCache();
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(FLOW);
		final first: Array<NullFlowVisit> = [];
		final second: Array<NullFlowVisit> = [];
		Assert.equals(first, cache.nullFlowVisits(tree, 'a', () -> first));
		Assert.equals(second, cache.nullFlowVisits(tree, 'b', () -> second));
		Assert.equals(first, cache.nullFlowVisits(tree, 'a', () -> []));
	}

	/** `forget` drops a tree's recording with the rest of its memos, so a new pass records again. */
	@:pin('control')
	@:killer('M-NULLFLOW-MEMO-NOT-FORGOTTEN')
	public function testForgetDropsTheRecording(): Void {
		final cache: RefsCache = new RefsCache();
		final tree: QueryNode = new HaxeQueryPlugin().parseFile(FLOW);
		final first: Array<NullFlowVisit> = [];
		final second: Array<NullFlowVisit> = [];
		Assert.equals(first, cache.nullFlowVisits(tree, FLOW, () -> first));
		cache.forget([tree]);
		Assert.equals(second, cache.nullFlowVisits(tree, FLOW, () -> second));
	}

	/** Whether transcript `line` lists `name` under `field` (`nn`, `vis`, `null` or `maybe`). */
	private static function answers(line: String, field: String, name: String): Bool {
		for (part in line.split(' ')) if (part.indexOf('$field=') == 0) return part.substr(field.length + 1).split(',').contains(name);
		return false;
	}

	private static function fixture(source: String): Fixture {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		return {
			plugin: plugin,
			tree: plugin.parseFile(source),
			bare: plugin.refShape(),
			cached: new CachingGrammarPlugin(plugin).refShape()
		};
	}

	private static function transcript(
		tree: QueryNode, shape: RefShape, source: String, ?seed: QueryNode -> Bool, ?declared: QueryNode -> Bool, ?types: Map<Int, String>
	): Array<String> {
		final collected: Array<String> = [];
		RefsCache.collectNames(tree, collected);
		final names: Array<String> = [];
		for (name in collected) if (!names.contains(name)) names.push(name);
		names.sort(Reflect.compare);
		final out: Array<String> = [];
		NullFlow.analyze(tree, shape, source, (node, facts) -> {
			final at: Null<Span> = node.span;
			final span: String = at == null ? '?' : '${at.from}-${at.to}';
			out.push(
				'${node.kind}@$span nn=${names.filter(facts.nonNull).join(',')} vis=${names.filter(facts.nonNullVisible).join(',')}'
				+ ' null=${names.filter(facts.isNull).join(',')} maybe=${names.filter(facts.isMaybeNull).join(',')}'
				+ ' present=${facts.indexPresent(node)}'
			);
		}, seed, declared, types);
		return out;
	}

}

private typedef Fixture = {
	plugin: HaxeQueryPlugin,
	tree: QueryNode,
	bare: RefShape,
	cached: RefShape
};
