package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.GraphScoped;
import anyparse.check.Check.NoAutofix;
import anyparse.check.Check.Violation;
import anyparse.check.ErrorPaths.PathCosts;
import anyparse.check.HoldGrade.FoldHold;
import anyparse.check.HoldGrade.GradedHold;
import anyparse.check.HoldGrade.HoldJudges;
import anyparse.check.LockSites.LockAcquire;
import anyparse.check.LockSites.LockPair;
import anyparse.check.LockTaint.ChainLists;
import anyparse.check.LongLockExplain.LongLockReport;
import anyparse.check.LongLockExplain.MainTake;
import anyparse.query.CallGraph;
import anyparse.query.CallGraphTypes;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberKinds;
import anyparse.query.QueryNode;
import anyparse.query.ReachAdmission;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import haxe.Exception;
import haxe.ds.ObjectMap;

using Lambda;
using StringTools;

/**
 * Config-driven thread-context analysis over the approximate `CallGraph` — finds the two classic main-thread stalls:
 * (a) a MAIN-context function calling a configured blocking sink; (b) a function holding a configured lock across a
 * call that transitively reaches a sink, while the main thread takes that lock somewhere and some other thread runs the
 * hold (or the main thread works long under it itself) — and the two ways a lock hangs a thread for good: (c) a lock
 * still held where an exception leaves the function that took it; (d) two locks taken in opposite orders on the main
 * thread and on a background one (`LockOrder`).
 *
 * Context propagation (`ThreadStates`): graph roots start MAIN; a callback passed to a `spawns` target runs BG, one
 * passed to a `marshals` target runs MAIN, any other inherits its registrar's context. A node nothing reached is
 * ASSUMED main. A call runs only where the code around it lets it (`EdgeConditions`); a value stored into a `dynamic`
 * member runs where the member runs (`deriveStoredCalls`). Sinks inside a `marshals` function are its own machinery.
 *
 * Locks are told apart by the OBJECT (`LockSites`: the sealed member holding it). A sink that TAKES a `lockPairs` lock
 * stalls only when the lock is LONG: some function holds it, on some path (`LockWindow`), across a call that blocks;
 * leaves it held on a path out of the function; or releases it without taking it. A lock no sealed member names is
 * always long; a hold in the owner's constructor before the object escapes blocks no one. Holding a long lock is itself
 * blocking, so the locks and the taint are solved together (`solveLongLocks`).
 *
 * Configured per project in `apqlint.json` under `"thread-safety"` (inert without `sinks`), read
 * and checked by `ThreadSafetyOptions`, which says every option it drops: `sinks`, `spawns`,
 * `marshals` and `throwers` (`ThrowReach`) are call patterns, matched by their last two dot-segments (`Type.*` covers a
 * type); a `lockPairs` entry is `<lock pattern>/<unlock member name>`, and a lock WRAPPER's call takes or gives its
 * lock with no entry of its own; `quietRoots` are handlers that block on purpose — the main thread
 * is QUIET in them while no loud main-thread code calls them (`settleContexts`), and a hold only
 * they run is reported by no finding (b); `reentrantLocks` are takes the holder may repeat on the
 * SAME object; `neverInvokes` calls run no function value handed to them; `mainThreadChecks` answer whether the running
 * thread is the main one; `closedWorld` says every caller and every write is in the run (`sealedFromOutside`,
 * `FieldWrites`), held only by a run covering the project it closes (`ProjectCoverage`); `exclude` drops files by
 * a '/'-bounded path-segment run before the graph is built; `shortSinks` are the sinks one call of which waits briefly,
 * `compilerFacts: true` builds the graph through the run's compiler facts when it has them
 * (`ThreadGraph.build`) — the ONE graph of the run, so for every file once any chain asks;
 * `iterates` the calls running a function value handed to them once per element, and `registers` the calls keeping one to
 * run later, once per event however often it was registered, and `runsOnce` the calls running one at most once per
 * call — a value handed to any other call may repeat (`CallRepetition`); `sharedLocks` are the `lockPairs` take
 * members taking their lock shared — a lock only ever taken through them never waits (`QuietLocks`); `nonThrowing` are
 * the calls that never throw, so a `catch` around nothing else runs no call (`DeadCatches`).
 *
 * Findings are grouped: one per hold, at its first blocking call or its first escape, one per main-thread sink call
 * site, and one per pair of locks taken in both orders. Each carries its identity as data (`Check.FindingData`): its
 * family (`FindingFamily`), the member it sits in, its subject (the sinks, the lock, the two locks) and its whole
 * chain, which a tool keys by in place of the message. Asked to (`explainLongLocks`), a run also keeps why each lock is
 * long (`LongLockExplain`) in `longLocks`, without moving a finding.
 *
 * Each finding is graded by what it costs. Locks are solved twice: once over every blocking call, which decides what is
 * reported at all, and once over the LONG ones — a sink `shortSinks` does not list, a take of a long lock, or a short
 * call that repeats (`CallRepetition`) — which decides what warns. A main-thread call of a short sink, or a take of a
 * lock held only across short calls, that no main-thread path repeats, and a hold spanning only such calls each once,
 * are reported at `info`, the reason in the message: brief, never dropped.
 */
@:nullSafety(Strict)
final class ThreadSafety implements Check implements ConfigAware implements NoAutofix implements GraphScoped {

	public static inline final CTX_MAIN: Int = 1;
	public static inline final CTX_BG: Int = 2;

	/** The main thread on a path through a `quietRoots` function: reached, but never reported. */
	public static inline final CTX_QUIET: Int = 4;

	/** Joins the ids of a subject naming several (the sinks of one call site, the two locks of an inversion), sorted. */
	public static inline final SUBJECT_SEPARATOR: String = ' / ';

	/** The hops a finding's text names of a chain; its data keeps them all. */
	public static inline final CHAIN_CAP: Int = 8;

	/** The name of a program's entry point, which the runtime calls. */
	public static inline final ENTRY_POINT: String = 'main';

	private static inline final EVIDENCE_CAP: Int = 8;

	/** Why each lock of the last run is long, when the run was asked to say (`explainLongLocks`); null otherwise. */
	public var longLocks(default, null): Null<LongLockReport> = null;

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	/** Whether a run explains its long locks into `longLocks` (`explainLongLocks`). */
	private var _explainLong: Bool = false;

	public function new() {}

	/** Makes each later run explain its long locks into `longLocks` (`LongLockExplain`); its findings stay the same. */
	public inline function explainLongLocks(on: Bool): Void {
		_explainLong = on;
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function id(): String {
		return 'thread-safety';
	}

	public function description(): String {
		return 'main-thread-reachable blocking calls, locks held across blocking calls or left held by a throw, and lock-order'
			+ ' inversions between threads (config-driven)';
	}

	/**
	 * ONE graph over every file of the run, whatever config chains they span — a file whose chain names no `sinks`
	 * included, since its calls and registrations shape the other files' contexts — and each SITE judged by the chain
	 * of its own file: a call is a sink call when its call site's chain lists that sink, a callback is spawned or
	 * marshalled when the registering site's chain lists that target, a lock window opens under its file's
	 * `lockPairs`. Reachability stays whole-graph, so a single-chain run is unchanged and a main-thread caller in one
	 * chain still reaches a sink call in another.
	 */
	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		longLocks = null;
		if (files.length == 0) return [];
		// `Linter.collect` hands over every file but an `exclude`d one (`scanSkipReason`), and drops the findings in a
		// file with no `sinks` of its own afterwards (`skipReason`).
		final useFacts: Bool = files.exists(
			f -> LintConfig.resolveWith(_resolveConfig, f.file).boolOption('thread-safety', 'compilerFacts') == true
		);
		final graph: CallGraph = ThreadGraph.build(files, plugin, useFacts);
		final sets: Array<ChainLists> = [];
		final problems: Array<String> = [];
		final byFile: Map<String, ChainLists> = listsByFile(files, graph, sets, plugin.refShape().accessorMethodPrefixes ?? [], problems);
		final sinkIds: Array<String> = [];
		for (lists in sets) for (id in lists.sinkIds) if (!sinkIds.contains(id)) sinkIds.push(id);
		if (sinkIds.length == 0) return [];
		final listsOf: (String) -> ChainLists = listsOfFile.bind(byFile);
		final unresolvedNames: Array<String> = [for (u in graph.unresolved) for (n in ReachAdmission.admittedNames(u)) n];
		final sealedSlots: Array<String> = deriveStoredCalls(graph, unresolvedNames);

		final trees: FunctionTrees = new FunctionTrees(graph, plugin);
		final conditions: EdgeConditions = new EdgeConditions(
			graph, trees, plugin, file -> listsOf(file).mainCheckIds, new DeadCatches(graph, trees, plugin, listsOf).holds
		);
		final inertRef: (CallEdge) -> Bool = runsNothing.bind(graph, sealedSlots, listsOf);
		final seedable: (String) -> Bool = mayRunFromOutside.bind(graph, plugin, unresolvedNames, byFile);
		// a quiet root is judged by the chain of the file declaring it
		final states: ThreadStates = settleContexts(graph, listsOf, [
			for (id => node in graph.nodes) if (byFile[node.file]?.quietIds.contains(id) == true) id
		], conditions, inertRef, seedable);

		final throws: ThrowReach = new ThrowReach(graph, plugin.refShape(), file -> listsOf(file).throwerIds, trees);
		// every write of the project, seen only when the run covers a closed project (`listsByFile`)
		final writes: FieldWrites = new FieldWrites(graph, plugin, files.foreach(f -> byFile[f.file]?.closedWorld == true));
		final sites: LockSites = new LockSites(
			graph, [for (f in files) f.file],
			plugin, file -> listsOf(file).pairs, throws, trees, new ExhaustiveSwitches(graph, plugin, writes, seedable)
		);
		// a hold whose take no thread runs holds nothing: a function nothing invokes, a take a condition rules out
		final acquires: Array<LockAcquire> = [for (a in sites.acquires) if (states.edgeContext(a.edge) != 0) a];
		final helperHolds: Array<LockAcquire> = [for (a in sites.helperHolds) if (states.edgeContext(a.edge) != 0) a];
		final judged: Array<LockAcquire> = HoldGrade.judged(acquires, helperHolds);
		// the locks whose take blocks at all: held across any blocking call, short ones included
		final blocking: Array<String> = [];
		final taints: LockTaint = new LockTaint(
			graph, sinkIds, listsOf, sites, blocking, conditions, states, null, new AllocationSets(graph, plugin, sites, writes)
		);
		solveLongLocks(sites, judged, blocking, taints);
		// the locks whose take blocks LONG: held across a call that blocks long, or a short one that repeats
		final repetition: CallRepetition = new CallRepetition(graph, trees, plugin.refShape(), listsOf);
		final holds: Array<LockAcquire> = acquires.concat(helperHolds);
		final must: MustHeld = new MustHeld(
			graph, plugin, trees, sites, states, conditions, repetition, holds, inertRef, unresolvedNames, seedable, writes
		);
		final dominance: LockDominance = new LockDominance(sites, states, conditions, repetition, must, holds, taints.quiet);
		final settled: { long: Array<String>, costs: LockTaint } = dominance.settle(
			taints, (long, costs) -> solveLongLocks(sites, judged, long, costs)
		);
		final long: Array<String> = settled.long;
		final costs: LockTaint = settled.costs;
		// the same question over the normal paths: a call only a `catch` runs leads nowhere
		final errors: ErrorPaths = new ErrorPaths(graph, trees, plugin.refShape());
		final paths: PathCosts = {
			all: costs,
			normal: new LockDominance(
				sites, states, conditions, repetition, must, holds, taints.quiet
			).settle(taints, (l, c) -> solveLongLocks(sites, judged, l, c), errors).costs,
			errors: errors
		};

		final violations: Array<Violation> = [];
		// a value stored or handed where it never runs from repeats nothing, wherever it is written
		final runsMain: (CallEdge) -> Bool = e -> !(e.kind == Ref && inertRef(e)) && states.edgeContext(e) & CTX_MAIN != 0;
		final repeatsOnMain: MainRepeats = new MainRepeats(graph, repetition, states, conditions, runsMain);
		final reported: Map<String, Violation> = MainSinkReport.report(
			graph, sites, taints, paths, { repetition: repetition, main: repeatsOnMain, runs: runsMain }, states, violations
		);
		if (must.unsettled)
			problems.push(
				'the locks held on entry did not settle within the bound, so no function is taken to hold any on its way in:'
				+ ' no take is brief for being made under another lock'
			);
		reportConfigProblems(problems, violations);
		reportLockHeld(graph, sites, judged, taints, {
			costs: paths,
			reported: reported,
			enclosed: dominance.enclosed,
			threads: states.origins(inertRef)
		}, states, violations);
		reportThrowHeld(graph, acquires.concat(helperHolds), throws, violations);
		final order: LockOrder = new LockOrder(graph, conditions, acquires.concat(helperHolds));
		for (v in order.report(states, inertRef, CTX_MAIN | CTX_QUIET, CTX_BG, CHAIN_CAP)) violations.push(v);
		// after every finding: the counterfactual solves fill taints of their own, which must not shape a report
		longLocks = explained(sites, judged, long, costs, states, dominance.dominators, { taint: paths.normal, errors: errors });
		return violations;
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	public function noAutofixReason(): String {
		return 'moving the work off the main thread, or narrowing what the lock covers, is a concurrency design change no span'
			+ ' rewrite expresses';
	}

	/** `needs-config` without a `sinks` list — there is nothing to find — and `config-excluded` for a path under `exclude`. */
	public function skipReason(file: String, config: LintConfig): Null<String> {
		return (config.stringListOption('thread-safety', 'sinks') ?? []).length == 0 ? 'needs-config' : scanSkipReason(file, config);
	}

	/**
	 * `config-excluded` for a path under `exclude`, the one file the graph leaves out: `exclude` says the code is no
	 * part of the analysis. A file with no `sinks` stays in the graph — its calls and `spawns` registrations decide the
	 * contexts of the files that do report.
	 */
	public function scanSkipReason(file: String, config: LintConfig): Null<String> {
		return ProjectCoverage.excluded(file, config.stringListOption('thread-safety', 'exclude') ?? []) ? 'config-excluded' : null;
	}

	/**
	 * Why each lock is long (`LongLockExplain.report`) when this check was asked (`explainLongLocks`), null otherwise: the
	 * holds `acquires` of `sites` judged against the converged `long` and `taints`, the takes a main-thread state — loud or
	 * quiet — runs (`states`), each lock's counterfactual solved without its own reasons on a fresh taint like `taints`,
	 * and the `normal` taint marking a reason that blocks only through a `catch`.
	 */
	private function explained(
		sites: LockSites, acquires: Array<LockAcquire>, long: Array<String>, taints: LockTaint, states: ThreadStates,
		dominators: Map<String, Array<String>>, normal: { taint: LockTaint, errors: ErrorPaths }
	): Null<LongLockReport> {
		if (!_explainLong) return null;
		final mainTakes: Array<MainTake> = [];
		for (a in acquires) {
			final ctx: Int = states.edgeContext(a.edge);
			if (ctx & (CTX_MAIN | CTX_QUIET) != 0) mainTakes.push({ take: a, quiet: ctx & CTX_MAIN == 0 });
		}
		return LongLockExplain.report(sites, acquires, long, taints, mainTakes, lock -> {
			final without: Array<String> = [];
			final fresh: LockTaint = taints.withLong(without);
			solveLongLocks(sites, acquires, without, fresh, lock);
			fresh;
		}, dominators, normal);
	}

	/**
	 * Each file's `ChainLists`, one record per DISTINCT option set: `sets` receives them in the order their first file
	 * appears, so a single-chain run holds exactly one. The options are read and checked once per config
	 * (`ThreadSafetyOptions`); what a REPORTING chain's read left out lands in `problems`, each line once.
	 *
	 * `closedWorld` holds only for a run that covers the project the declaration closes (`ProjectCoverage`): a run over
	 * part of it sees neither every caller nor every write, and reads the chain as open — said in `problems`.
	 */
	private function listsByFile(
		files: Array<{ file: String, source: String }>, graph: CallGraph, sets: Array<ChainLists>, accessorPrefixes: Array<String>,
		problems: Array<String>
	): Map<String, ChainLists> {
		final bySignature: Map<String, ChainLists> = [];
		final byFile: Map<String, ChainLists> = [];
		final read: ObjectMap<LintConfig, ThreadSafetyOptions> = new ObjectMap();
		final coverage: ProjectCoverage = new ProjectCoverage([for (f in files) f.file]);
		final factsAsked: Array<Bool> = [];
		for (entry in files) {
			final config: LintConfig = LintConfig.resolveWith(_resolveConfig, entry.file);
			final options: ThreadSafetyOptions = read.get(config) ?? ThreadSafetyOptions.read(config);
			read.set(config, options);
			final option: (String) -> Array<String> = options.list;
			final declaredClosed: Bool = options.flag('closedWorld');
			final closedWorld: Bool = declaredClosed && coverage.covers(entry.file, option('exclude'));
			final signature: String = options.signature() + (closedWorld ? '\tcovered' : '');
			final known: Null<ChainLists> = bySignature[signature];
			if (known != null) {
				byFile[entry.file] = known;
				continue;
			}
			final found: Array<String> = options.problems.copy();
			final lists: ChainLists = chainLists(options, graph, accessorPrefixes, closedWorld, found);
			bySignature[signature] = lists;
			sets.push(lists);
			byFile[entry.file] = lists;
			if (!lists.reports) continue;
			if (declaredClosed && !closedWorld)
				found.push(
					'option "closedWorld" holds only for a run over the whole project it closes — this run leaves part of it out, so'
					+ ' it is read as false'
				);
			final facts: Bool = options.flag('compilerFacts');
			if (!factsAsked.contains(facts)) factsAsked.push(facts);
			for (p in found) if (!problems.contains(p)) problems.push(p);
		}
		// one graph serves every chain, so the facts one chain asks for (`run`'s `useFacts`) build it for all of them
		if (factsAsked.length > 1)
			problems.push(
				'option "compilerFacts" is set by some chains of the run only — the graph is one, built with the facts for every' + ' file'
			);
		return byFile;
	}

	/**
	 * The `ChainLists` of one option set `options`, resolved over `graph`, its `closedWorld` as the run covers it; a
	 * `boundedRepeats` entry matching no function lands in `found`.
	 */
	private static function chainLists(
		options: ThreadSafetyOptions, graph: CallGraph, accessorPrefixes: Array<String>, closedWorld: Bool, found: Array<String>
	): ChainLists {
		final option: (String) -> Array<String> = options.list;
		final shortSinks: Array<String> = option('shortSinks');
		final iterates: Array<String> = option('iterates');
		final registers: Array<String> = option('registers');
		final runsOnce: Array<String> = option('runsOnce');
		final nonThrowing: Array<String> = option('nonThrowing');
		final neverInvokes: Array<String> = option('neverInvokes');
		final mainChecks: Array<String> = option('mainThreadChecks');
		final lockPairs: Array<String> = option('lockPairs');
		final sinks: Array<String> = option('sinks');
		return {
			reports: sinks.length > 0,
			bounded: BoundedRepeats.entries(options.boundedRepeats, graph, found),
			repeatBudgetMs: options.repeatBudgetMs,
			sinkIds: matchAll(graph, sinks),
			shortSinkIds: matchAll(graph, shortSinks),
			shortNames: [for (p in shortSinks) if (p.indexOf('.') < 0) p],
			iterateIds: matchAll(graph, iterates),
			iterateNames: [for (p in iterates) if (p.indexOf('.') < 0) p],
			registerIds: matchAll(graph, registers),
			registerNames: [for (p in registers) if (p.indexOf('.') < 0) p],
			runsOnceIds: matchAll(graph, runsOnce),
			runsOnceNames: [for (p in runsOnce) if (p.indexOf('.') < 0) p],
			sharedIds: matchAll(graph, option('sharedLocks')),
			nonThrowingIds: matchAll(graph, nonThrowing),
			nonThrowingNames: [for (p in nonThrowing) if (p.indexOf('.') < 0) p],
			spawnIds: matchAll(graph, option('spawns')),
			marshalIds: matchAll(graph, option('marshals')),
			quietIds: matchAll(graph, option('quietRoots')),
			reentrantIds: matchAll(graph, option('reentrantLocks')),
			throwerIds: matchAll(graph, option('throwers')),
			neverInvokeIds: matchAll(graph, neverInvokes),
			neverInvokeNames: [for (p in neverInvokes) if (p.indexOf('.') < 0) p],
			mainCheckIds: matchAll(graph, mainChecks.concat([for (c in mainChecks) getterOf(c, accessorPrefixes)])),
			closedWorld: closedWorld,
			lockPairs: lockPairs,
			pairs: resolvePairs(graph, lockPairs)
		};
	}

	/** A subject naming several ids (the two locks of an inversion), sorted and joined by `SUBJECT_SEPARATOR`. */
	public static inline function subjectOf(ids: Array<String>): String {
		return sortedIds(ids).join(SUBJECT_SEPARATOR);
	}

	/**
	 * `parts` joined as a call chain, at most `cap` of them: the head says where the chain leaves its function, the
	 * last two what it ends in.
	 */
	public static function elided(parts: Array<String>, cap: Int): String {
		return (parts.length <= cap ? parts : parts.slice(0, cap - 2).concat(['...']).concat(parts.slice(-2))).join(' -> ');
	}

	/**
	 * The member a function id belongs to: a lambda's or a local function's id (`Type.member#…`) is its
	 * enclosing member's, and a field initializer's lambda (`Type#n`) the initializer pseudo-node's that
	 * holds it (`Type.<init>`, `Type.<static>`) — where the calls an initializer makes directly sit too.
	 */
	public static function memberOf(graph: CallGraph, id: String): String {
		var cursor: String = id;
		while (true) {
			final hash: Int = cursor.indexOf('#');
			if (hash < 0) return cursor;
			final head: String = cursor.substring(0, hash);
			if (head.indexOf('.') >= 0) return head;
			// a field initializer's lambda (`Type#n`) sits in the type's initializer pseudo-node, which owns its direct calls too
			final container: Null<String> = graph.inEdges(cursor).find(e -> e.kind == Contains)?.from;
			if (container == null) return head;
			cursor = container;
		}
	}

	/** `ids` sorted: the order a subject or a chain names several ids in, whatever order the graph met them. */
	public static function sortedIds(ids: Array<String>): Array<String> {
		final sorted: Array<String> = ids.copy();
		sorted.sort(Reflect.compare);
		return sorted;
	}

	/** The lists of the chain `file` sits under — every edge's file is one the graph was built from. */
	private static function listsOfFile(byFile: Map<String, ChainLists>, file: String): ChainLists {
		final lists: Null<ChainLists> = byFile[file];
		if (lists == null) throw new Exception('thread-safety: an edge sits in "$file", which no run file resolved a config for');
		return lists;
	}

	/**
	 * The getter a property pattern `T.p` reads through (`T.get_p`, by the grammar's first accessor prefix): a check
	 * written as the property matches the accessor its reads call.
	 */
	private static function getterOf(pattern: String, accessorPrefixes: Array<String>): String {
		final dot: Int = pattern.lastIndexOf('.');
		return accessorPrefixes.length == 0 ? pattern : pattern.substring(0, dot + 1) + accessorPrefixes[0] + pattern.substring(dot + 1);
	}

	/** Union of `graph.matchIds` over `patterns`, deduplicated. */
	private static function matchAll(graph: CallGraph, patterns: Array<String>): Array<String> {
		final result: Array<String> = [];
		for (p in patterns) for (id in graph.matchIds(p)) if (!result.contains(id)) result.push(id);
		return result;
	}

	/** Every well-formed `lockPairs` entry as the graph's lock ids, each paired with the same type's unlock member. */
	private static function resolvePairs(graph: CallGraph, lockPairs: Array<String>): Array<LockPair> {
		final pairs: Array<LockPair> = [];
		for (entry in lockPairs) {
			final slash: Int = entry.lastIndexOf('/');
			if (slash <= 0) continue;
			for (lockId in graph.matchIds(entry.substring(0, slash))) {
				final dot: Int = lockId.lastIndexOf('.');
				if (dot > 0) pairs.push({ lockId: lockId, unlockId: lockId.substring(0, dot + 1) + entry.substring(slash + 1) });
			}
		}
		return pairs;
	}

	/**
	 * Whether the `Ref` edge `edge` runs its value from nowhere: a value stored into a member of `sealedSlots`, which
	 * runs where that member runs (`deriveStoredCalls`), one handed to a call that never runs it (`neverInvoked`), or the
	 * compiler facts' record of a value made at a site the syntax already records handing it to a call — the same value
	 * at the same span, said once with its `via` (`ThreadGraph.madeWhereHanded`).
	 */
	private static function runsNothing(
		graph: CallGraph, sealedSlots: Array<String>, listsOf: (String) -> ChainLists, edge: CallEdge
	): Bool {
		return sealedSlots.contains(edge.storedInto ?? '') || neverInvoked(edge, listsOf(edge.file))
			|| ThreadGraph.madeWhereHanded(graph, edge);
	}


	/**
	 * Whether a function the walk reaches through no edge may still run, ASSUMED on the main thread: any function, unless
	 * its file's chain declares `closedWorld` and nothing outside the run can invoke it (`sealedFromOutside`).
	 */
	private static function mayRunFromOutside(
		graph: CallGraph, plugin: GrammarPlugin, unresolvedNames: Array<String>, byFile: Map<String, ChainLists>, id: String
	): Bool {
		return !(byFile[graph.node(id)?.file ?? '']?.closedWorld == true && sealedFromOutside(graph, plugin, unresolvedNames, id));
	}

	/**
	 * Whether the call the value of the `Ref` edge `edge` is handed to never runs it: one its chain's `neverInvokes`
	 * names — a `Type.member` entry by the graph's target, a bare member name by the name the call is written with,
	 * resolved or not.
	 */
	private static function neverInvoked(edge: CallEdge, lists: ChainLists): Bool {
		final via: String = edge.via ?? '';
		final member: String = edge.viaMember ?? '';
		return lists.neverInvokeIds.contains(via) || lists.neverInvokeNames.contains(member);
	}

	/**
	 * The context a callback `edge` registers from `ctx` runs in: a `spawns` target's BG, a `marshals` target's MAIN,
	 * any other the registrar's own — quiet never among them: a callback runs later, from whatever invokes it.
	 */
	private static function callbackContext(edge: CallEdge, lists: ChainLists, ctx: Int): Int {
		final via: Null<String> = edge.via;
		final loud: Int = (ctx & CTX_QUIET != 0 ? CTX_MAIN : 0) | (ctx & (CTX_MAIN | CTX_BG));
		return if (via != null && lists.spawnIds.contains(via))
			CTX_BG
		else if (via != null && lists.marshalIds.contains(via))
			CTX_MAIN
		else
			loud;
	}

	/**
	 * The contexts (`ThreadStates`) with the `quiet` roots only the main thread never enters loud: a root some invocation
	 * reaches from loud MAIN code is dropped, and the contexts are solved again until none is. A root's registration as a
	 * callback (a `Ref`, as a handler is) does not make it loud: declaring how such a callback runs is what the list is for.
	 */
	private static function settleContexts(
		graph: CallGraph, listsOf: (String) -> ChainLists, quiet: Array<String>, conditions: EdgeConditions, inertRef: (CallEdge) -> Bool,
		seedable: (String) -> Bool
	): ThreadStates {
		var roots: Array<String> = quiet;
		while (true) {
			final states: ThreadStates = new ThreadStates(
				graph, conditions, roots, (e, ctx) -> callbackContext(e, listsOf(e.file), ctx), inertRef, seedable
			);
			final loud: Array<String> = [
				for (q in roots) if (graph.inEdges(q).exists(e -> e.kind.isInvocation() && states.edgeContext(e) & CTX_MAIN != 0)) q
			];
			if (loud.length == 0) return states;
			roots = roots.filter(q -> !loud.contains(q));
		}
	}

	/**
	 * A function value assigned to a `dynamic` method (`CallEdge.storedInto`) runs wherever that member runs: each
	 * invocation of the member, or of an override of it, is a call of the value too, and each read of the member as a
	 * value a reference to it. Those edges join the graph, at the member's own sites. Returns the members whose every
	 * run the graph sees — no call or read of their name it could not resolve — where the assignment itself runs nothing.
	 */
	private static function deriveStoredCalls(graph: CallGraph, unresolvedNames: Array<String>): Array<String> {
		final sealed: Array<String> = [];
		final stores: Array<CallEdge> = [for (e in graph.edges) if (e.kind == Ref && e.storedInto != null) e];
		for (store in stores) {
			final slotId: String = store.storedInto ?? '';
			final slot: Null<FnNode> = graph.node(slotId);
			final name: Null<String> = slot?.name;
			final type: Null<String> = slot?.typeName;
			if (slot == null || name == null || type == null) continue;
			final runs: Array<String> = [slotId].concat(graph.virtualTargets(type, name));
			for (id in runs) for (e in graph.inEdges(id).copy()) if (e.kind != Contains) graph.deriveEdge({
				from: e.from,
				to: store.to,
				kind: e.kind,
				via: e.via,
				file: e.file,
				span: e.span,
				dispatchType: null,
				receiverField: null
			});
			if (!sealed.contains(slotId) && !unresolvedNames.contains(name) && graph.unresolvedAccessesRunning([slot]).length == 0)
				sealed.push(slotId);
		}
		return sealed;
	}

	/**
	 * Whether nothing outside the run's files can invoke `id`, so that under `closedWorld` a function nothing in them
	 * reaches runs on no thread at all: a member method (no lambda, no local function, no constructor, no field
	 * initializer, no `main`) no supertype may declare (`inheritsNothingNamed`), carrying no `override` and no metadata,
	 * whose name no unresolved call or access may mean.
	 */
	private static function sealedFromOutside(graph: CallGraph, plugin: GrammarPlugin, unresolvedNames: Array<String>, id: String): Bool {
		final node: Null<FnNode> = graph.node(id);
		final name: Null<String> = node?.name;
		final type: Null<String> = node?.typeName;
		if (node == null || name == null || type == null || node.isExternal || node.isBodyless || id.indexOf('#') >= 0) return false;
		final shape: RefShape = plugin.refShape();
		if (name == (shape.constructorName ?? 'new') || name == ENTRY_POINT || name.startsWith('<')) return false;
		if (graph.ownMember(type, name) != id || !inheritsNothingNamed(graph, type, name, [])) return false;
		if (unresolvedNames.contains(name) || graph.unresolvedAccessesRunning([node]).length > 0) return false;
		final declarations: Array<FnDeclaration> = graph.declarationsOf(id);
		return declarations.length > 0 && declarations.foreach(d -> plainMember(graph, plugin, d));
	}

	/**
	 * Whether no supertype of `type` may declare `name`: every one the index holds declares none, and every one it does
	 * not hold is the superclass of a class — whose members the class can only reach by an `override`, which a sealed
	 * member never carries. An interface the index does not hold may declare anything.
	 */
	private static function inheritsNothingNamed(graph: CallGraph, type: String, name: String, seen: Array<String>): Bool {
		if (seen.contains(type)) return true;
		seen.push(type);
		final types: CallGraphTypes = graph.types;
		final superclass: Null<String> = types.isInterface(type) ? null : types.superclassOf(type);
		for (s in types.supertypesOf(type)) {
			if (types.declarationCount(s) == 0) {
				if (s != superclass) return false;
				continue;
			}
			if (types.declaringTypeOf(s, name) != null || !inheritsNothingNamed(graph, s, name, seen)) return false;
		}
		return true;
	}

	/** Whether the member declared at `d` carries neither `override` nor any metadata. */
	private static function plainMember(graph: CallGraph, plugin: GrammarPlugin, d: FnDeclaration): Bool {
		final tree: Null<QueryNode> = graph.treeOf(d.file);
		if (tree == null) return false;
		final host: Null<{ parent: QueryNode, member: QueryNode }> = memberAt(tree, d.span);
		if (host == null) return false;
		final shape: RefShape = plugin.refShape();
		final kinds: Array<String> = (shape.modifierKinds ?? []).concat(plugin.metaShape().metaKinds);
		final leading: Array<QueryNode> = MemberKinds.precedingModifiers(host.member, host.parent, kinds);
		return !leading.exists(m -> m.kind == shape.overrideModifierKind || plugin.metaShape().metaKinds.contains(m.kind));
	}

	/** The node spanning exactly `span` in `tree`, with its parent; null when there is none. */
	private static function memberAt(tree: QueryNode, span: Span): Null<{ parent: QueryNode, member: QueryNode }> {
		var node: QueryNode = tree;
		while (true) {
			final child: Null<QueryNode> = node.children.find(c -> c.span != null && c.span.from <= span.from && c.span.to >= span.to);
			if (child == null) return null;
			if (child.span?.from == span.from && child.span?.to == span.to) return { parent: node, member: child };
			node = child;
		}
	}

	/**
	 * The long locks and the taint they imply, solved together: a call blocks when it reaches a sink, and a lock taken
	 * by a sink call blocks only when it is long, while a lock is long when a hold of it spans a call that blocks. Grows
	 * from the locks long on their own (`LongLockExplain.leaks`, `LockTaint.blindLong`, `LockSites.crossing`) until
	 * nothing changes. `aside` names a lock whose own such reasons are left out — the counterfactual `--explain-long`
	 * asks: is it long by a blocking call too?
	 */
	private static function solveLongLocks(
		sites: LockSites, acquires: Array<LockAcquire>, long: Array<String>, taints: LockTaint, ?aside: String
	): Void {
		// a multi-lock helper's give is its caller's release, never a release of a hold begun elsewhere
		for (c in sites.crossing) if (c.lock != aside && !long.contains(c.lock) && !sites.helpers.contains(c.edge.from)) long.push(c.lock);
		for (a in acquires) if (
			(LongLockExplain.leaks(a) || taints.blindLong(a)) && a.lock != null && a.lock != aside && !long.contains(a.lock)
		)
			long.push(a.lock);
		var grew: Bool = true;
		// the taint is rebuilt from scratch each round: a lock turning long adds sink edges anywhere in the graph, and the
		// rounds are bounded by the number of locks, so a worklist would buy little over the plain recompute
		while (grew) {
			taints.clear();
			grew = false;
			for (a in acquires) {
				final lock: Null<String> = a.lock;
				if (lock == null || a.uncontended || long.contains(lock)) continue;
				final held: Null<String> = taints.reentrantHeld(a);
				if (!a.window.exists(e -> taints.blockingPath(a, e, held) != null)) continue;
				long.push(lock);
				grew = true;
			}
		}
	}

	/** One `info` finding naming no file per line of `problems` (`listsByFile`): what the options' read left out. */
	private static function reportConfigProblems(problems: Array<String>, violations: Array<Violation>): Void {
		for (p in problems) violations.push({
			file: '',
			span: null,
			rule: 'thread-safety',
			severity: Severity.Info,
			message: p
		});
	}

	/**
	 * Finding (b): on some path of one function body a lock is held across calls that block — one finding per hold,
	 * anchored at its first blocking call and naming the lock object (the pair's take member for a lock no member
	 * names). Reported for a lock the main thread takes somewhere — for one no sealed member names, a take of the pair
	 * on the main thread at all — since only then does the hold stall main; a hold in the owner's constructor before the object escapes stalls no one. The main thread
	 * never waits for its own hold, so a hold of a named lock that only the main thread runs — on no background thread,
	 * and not in a function the walk only assumes runs there (`ThreadStates.assumed`) — stays only when the main thread
	 * itself works long under it (`LockTaint.ownWork`), and says so. Graded by cost: a hold whose blocking calls are all
	 * brief is info, a long one names only the calls that block long.
	 */
	private static function reportLockHeld(
		graph: CallGraph, sites: LockSites, acquires: Array<LockAcquire>, taints: LockTaint, judged: {
			costs: PathCosts,
			reported: Map<String, Violation>,
			enclosed: (LockAcquire) -> Bool,
			threads: (String) -> Array<String>
		},
		states: ThreadStates, violations: Array<Violation>
	): Void {
		final paths: PathCosts = judged.costs;
		final costs: LockTaint = paths.all;
		// what a hold only the main thread runs is judged by: its own work, every take left out
		final own: { long: LockTaint, normal: LockTaint } = { long: ownWorkOf(costs), normal: ownWorkOf(paths.normal) };
		final any: { long: LockTaint, normal: LockTaint } = { long: costs, normal: paths.normal };
		final mainTaken: Array<String> = HoldGrade.mainTaken(acquires, states, taints);
		final reported: Array<WarnedHold> = [];
		final folds: Array<FoldHold> = [];
		final made: Map<String, Violation> = [];
		for (a in acquires) {
			final lock: Null<String> = a.lock;
			final fold: FoldHold = RootCauseFold.unreported(a, paths.normal);
			folds.push(fold);
			// a hold only a quiet root runs waits on purpose, on the main thread, which never waits for its own hold
			if (a.uncontended || !mainTaken.contains(HoldGrade.takenKey(a)) || states.edgeContext(a.edge) & (CTX_MAIN | CTX_BG) == 0)
				continue;
			// the main thread never waits for a hold of a lock it alone holds there: such a hold stays only as the main thread's
			// own long work; who else holds a lock no member names is unknown
			final mainOnly: Bool = lock != null && states.edgeContext(a.edge) & CTX_BG == 0 && !states.assumed.exists(a.edge.from);
			final held: Null<String> = taints.reentrantHeld(a);
			final pick: { long: LockTaint, normal: LockTaint } = mainOnly ? own : any;
			final judges: HoldJudges = {
				plain: taints,
				long: pick.long,
				normal: pick.normal,
				errors: paths.errors,
				reported: judged.reported
			};
			final graded: Null<GradedHold> = HoldGrade.grade(sites, a, held, judges, mainOnly);
			if (graded == null) continue;
			final blocking: Array<{ edge: CallEdge, path: Array<String> }> = graded.calls;
			final short: Bool = graded.info;
			final calls: String = blocking.length == 1 ? 'a call' : '${blocking.length} calls';
			final holder: String = a.edge.from;
			final message: String = '"$holder" holds "${lock ?? a.pair.lockId}" across $calls that can block: '
				+ evidenceOf(blocking, held, graded.taint) + graded.note;
			final anchor: CallEdge = blocking[0].edge;
			final key: String = '${anchor.file}:${anchor.span?.from}:$message';
			final known: Null<Violation> = made[key];
			final finding: Violation = known ?? HoldGrade.finding(graph, anchor, short, message, lock ?? a.pair.lockId, [holder].concat(
				blocking[0].path
			));
			folds[folds.length - 1] = RootCauseFold.judgedAs(fold, finding, graded, held, pick.normal, graded.note == CostNote.HandOff);
			if (known != null) continue;
			violations.push(finding);
			made[key] = finding;
			if (!short) reported.push({
				hold: a,
				calls: [for (b in blocking) b.edge],
				finding: finding,
				handOff: graded.note == CostNote.HandOff,
				taint: graded.taint,
				held: held
			});
		}
		final covers: Array<{ finding: Violation, by: Array<Violation> }> = [];
		nestHolds(reported, covers);
		foldEnclosed(reported, judged.enclosed, covers);
		new RootCauseFold([for (c in sites.crossing) c.lock], covers, judged.threads).fold(folds);
	}

	/**
	 * Each warned hold a hold of the same lock its every caller keeps encloses (`LockDominance.enclosed`) turns info,
	 * recorded in `covers` — when a warned hold of that lock in another function is long through a call into this hold's
	 * function: that warning reports the work this hold does. Such a hold says so, naming those holds; one no warning
	 * of an enclosing hold reaches stays.
	 */
	private static function foldEnclosed(
		reported: Array<WarnedHold>, enclosed: (LockAcquire) -> Bool, covers: Array<{ finding: Violation, by: Array<Violation> }>
	): Void {
		final warned: Array<WarnedHold> = [for (r in reported) if (r.finding.severity == Severity.Warning) r];
		for (r in warned) if (enclosed(r.hold)) {
			final fn: String = r.hold.edge.from;
			final around: Array<WarnedHold> = warned.filter(
				w ->
					w != r && w.hold.lock == r.hold.lock && w.hold.edge.from != fn
					&& w.calls.exists(c -> w.taint.blockingTrail(w.hold, c, w.held)?.path.contains(fn) == true)
			);
			if (around.length == 0) continue;
			final members: Array<String> = [];
			for (w in around) if (!members.contains(w.finding.data?.member ?? w.hold.edge.from))
				members.push(w.finding.data?.member ?? w.hold.edge.from);
			r.finding.severity = Severity.Info;
			r.finding.message += ' — taken inside a hold of ${r.hold.lock ?? r.hold.pair.lockId} every caller keeps, whose warning at '
				+ '${members.join(', ')} is long through the call into this one';
			covers.push({ finding: r.finding, by: [for (w in around) w.finding] });
		}
	}


	/** The own-work taint of the costed taint `costs` (`LockTaint.ownWork`). */
	private static function ownWorkOf(costs: LockTaint): LockTaint {
		final own: Null<LockTaint> = costs.ownWork();
		if (own == null) throw new Exception('thread-safety: the costed taint has no own-work taint');
		return own;
	}

	/**
	 * Finding (c): on some path of one function body a lock may still be held where an exception leaves the body — a
	 * `throw`, or a call `ThrowReach` knows may raise, with no `catch` of the body around it — so nothing on that path
	 * gives it back and the next take waits forever. One finding per hold, at its
	 * first escape, the holds a multi-lock helper opens in its caller included.
	 */
	private static function reportThrowHeld(
		graph: CallGraph, holds: Array<LockAcquire>, throws: ThrowReach, violations: Array<Violation>
	): Void {
		final seen: Array<String> = [];
		// an escape leaks the hold, so none is the owner's constructor's (`LockAcquire.uncontended`)
		for (a in holds) if (a.escapes.length > 0) {
			final evidence: Array<String> = [];
			for (escape in a.escapes) {
				final raiser: Null<CallEdge> = escape.raiser;
				final shown: String = raiser == null ? 'a throw' : elided(throws.chain(raiser), CHAIN_CAP);
				if (!evidence.contains(shown)) evidence.push(shown);
			}
			final holder: String = a.edge.from;
			final message: String =
				'"$holder" leaves "${a.lock ?? a.pair.lockId}" held when it throws, with no catch to release it: ${capped(evidence)}';
			final anchor: Span = a.escapes[0].span;
			final key: String = '${a.edge.file}:${anchor.from}:$message';
			if (seen.contains(key)) continue;
			seen.push(key);
			final raiser: Null<CallEdge> = a.escapes[0].raiser;
			violations.push({
				file: a.edge.file,
				span: anchor,
				rule: 'thread-safety',
				severity: Severity.Warning,
				message: message,
				data: {
					family: FindingFamily.ThrowHeld,
					member: memberOf(graph, holder),
					subject: a.lock ?? a.pair.lockId,
					chain: [holder].concat(raiser == null ? [] : throws.chain(raiser))
				}
			});
		}
	}

	/** What each of `blocking` reaches, by the path `LockTaint.blockingPath` found for it, distinct, capped (`capped`). */
	private static function evidenceOf(
		blocking: Array<{ edge: CallEdge, path: Array<String> }>, held: Null<String>, taints: LockTaint
	): String {
		final evidence: Array<String> = [];
		for (b in blocking) {
			final e: CallEdge = b.edge;
			final shown: String = if (taints.blocks(e, held))
				e.to
			else if (b.path.length == 1 && taints.retakesElsewhere(e, held))
				'${e.to} (the held lock, on another object)'
			else if (b.path.length <= CHAIN_CAP + 1)
				b.path.join(' -> ')
			else
				b.path.slice(0, CHAIN_CAP + 1).concat(['...']).join(' -> ');
			if (!evidence.contains(shown)) evidence.push(shown);
		}
		return capped(evidence);
	}

	/** `evidence` joined, the first `EVIDENCE_CAP` named and the rest counted. */
	private static function capped(evidence: Array<String>): String {
		final more: Int = evidence.length - EVIDENCE_CAP;
		return evidence.slice(0, EVIDENCE_CAP).join('; ') + (more > 0 ? '; +$more more' : '');
	}

	/**
	 * Of two warned holds in one function, the one taken inside the other's window whose every long call that window spans
	 * too turns info, naming the outer one: the outer hold's finding names the same calls. In take order, so an outer hold
	 * is never itself turned by a hold it encloses; each turned one is recorded in
	 * `covers`. A hold its function hands off (`HoldGrade.handsOff`) outlives the outer
	 * window, across calls no finding of it names, and stays.
	 */
	private static function nestHolds(reported: Array<WarnedHold>, covers: Array<{ finding: Violation, by: Array<Violation> }>): Void {
		reported.sort((x, y) -> (x.hold.edge.span?.from ?? 0) - (y.hold.edge.span?.from ?? 0));
		final turned: Array<LockAcquire> = [];
		for (inner in reported) if (!inner.handOff) {
			final outer: Null<WarnedHold> = reported.find(
				o ->
					o.hold != inner.hold && !turned.contains(o.hold) && o.hold.edge.from == inner.hold.edge.from
					&& o.hold.window.contains(inner.hold.edge) && inner.calls.foreach(c -> o.hold.window.contains(c))
			);
			if (outer == null) continue;
			turned.push(inner.hold);
			inner.finding.severity = Severity.Info;
			inner.finding.message += ' — taken inside the hold of ${outer.hold.lock ?? outer.hold.pair.lockId}, whose finding names these calls';
			covers.push({ finding: inner.finding, by: [outer.finding] });
		}
	}

}

/** The `FindingData.family` of each kind of `thread-safety` finding, as its class doc letters them. */
enum abstract FindingFamily(String) to String {

	/** (a) a main-thread function calls a blocking sink. */
	final MainSink = 'A';

	/** (b) a lock held across calls that can block. */
	final LockHeld = 'B';

	/** (c) a lock left held when an exception leaves its function. */
	final ThrowHeld = 'C';

	/** (d) two locks taken in opposite orders on two threads. */
	final OrderInversion = 'D';

}

/** What a `thread-safety` finding adds to its message when its cost or its thread is why it is graded as it is. */
enum abstract CostNote(String) to String {

	/**
	 * A main-thread call that waits too little to warn about (`shortSinks`), run once: every way up to it is a resolved
	 * call from the entry point that no loop, recursion or value handed to a repeating call repeats (`MainRepeats.climb`).
	 */
	final ShortMainCall = ' — short: a short sink or a take of a lock held only across short calls, once per main-thread run (every'
		+ ' caller up from the entry point resolved, none in a loop, a recursion or a value handed to a call not listed `runsOnce`),'
		+ ' so reported as info';

	/** A short main-thread call some way up to which is a registration (`registers`): once per event the runtime dispatches. */
	final ShortRegisteredCall = ' — short: a short sink or a take of a lock held only across short calls, once per event of a'
		+ ' registration (`registers`) — how often the runtime dispatches it is not known here — with no loop, recursion or value'
		+ ' handed to a call not listed `runsOnce` on the way down from it, so reported as info';

	/**
	 * A hold every blocking call of which waits too little to warn about (`shortSinks`), or takes a lock every long hold
	 * of which needs one held there (`LockDominance`) — directly in its window or in a callee, alike.
	 */
	final ShortHold = ' — short: every call it spans waits only on short sinks, on locks held only across short calls, or on a lock'
		+ ' whose every long hold needs a lock held here, each once per hold (no loop, `iterates` callback or recursion under the'
		+ ' lock), so reported as info';

	/**
	 * `ShortHold`, for a hold whose chain lists `boundedRepeats` entries: a repetition one binds counts as once, never as
	 * "no loop" — the bounds multiplied along each way under the budget (`CallRepetition.along`).
	 */
	final ShortBoundedHold = ' — short: every call it spans waits only on short sinks, on locks held only across short calls, or on a'
		+ ' lock whose every long hold needs a lock held here, each once per hold but for the repetitions `boundedRepeats` binds'
		+ ' (their bounds multiplied along each way under `repeatBudgetMs`), so reported as info';

	/** A call a sink's own body makes: the call of that sink is the finding. */
	final InsideSink = ' — inside a sink\'s own body, whose call is the finding, so reported as info';

	/** A hold only the main thread runs: no thread it stalls waits for it, but the main thread works long under it. */
	final MainOwnWork = ' — held on the main thread only, which never waits for its own hold: the stall is the main thread\'s own long'
		+ ' work under the lock';

	/** A hold no path of its function gives back: held past the function's end, across whatever runs until it is released. */
	final HandOff = ' — and no path of the function gives it back: held past its end until another function releases it, across'
		+ ' whatever runs until then';

}

/**
 * A hold whose finding (b) warns: the calls it names, whether it was graded as
 * handing its lock off, and the taint and re-held lock those calls were found under.
 */
private typedef WarnedHold = {
	final hold: LockAcquire;
	final calls: Array<CallEdge>;
	final finding: Violation;
	final handOff: Bool;
	final taint: LockTaint;
	final held: Null<String>;
}
