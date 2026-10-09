package anyparse.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.Violation;
import anyparse.check.ErrorPaths.PathCosts;
import anyparse.check.LockTaint.BlockingTrail;
import anyparse.check.ThreadSafety.CostNote;
import anyparse.check.ThreadSafety.FindingFamily;
import anyparse.query.CallGraph;

using Lambda;

/** A repeating call's finding (a), with the short sinks below it it names and the main-thread path to it. */
private typedef OwnedFinding = {
	final finding: Violation;
	var sinks: Array<String>;
	final path: Array<String>;
}

/** How the main thread repeats calls: where (`repetition`), which of its states may run more than once (`main`), and the edges it runs (`runs`). */
typedef MainRepetition = {
	final repetition: CallRepetition;
	final main: MainRepeats;
	final runs: (CallEdge) -> Bool;
}

/**
 * Finding (a) of `thread-safety`: a MAIN-context function directly calls a sink — one taking a lock only when that lock
 * is long or unknown — one finding per call site, naming every sink a dispatch there may reach. Graded by cost: a short
 * call run once is info; one long only because a caller up the main thread's way repeats it is info too, its warning
 * moved to the nearest repeating call (`MainRepeats.ownersOf`), unless that call is the member's own.
 */
@:nullSafety(Strict)
final class MainSinkReport {

	/**
	 * Each of finding (a) over `graph`, under the plain `taints` and the costed `costs`, into `violations`. A call long
	 * only where a `catch` runs — itself inside one, or a take of a lock long over the normal paths of no hold — is
	 * graded as if short, and info, naming that catch, when no repeating caller owns it. Returns, by `siteKey`, the
	 * member whose warning reports each main-thread sink call: its own, or the repeating call's that owns it.
	 */
	public static function report(
		graph: CallGraph, sites: LockSites, taints: LockTaint, costs: PathCosts, repeats: MainRepetition, states: ThreadStates,
		violations: Array<Violation>
	): Map<String, String> {
		final reportedBy: Map<String, String> = [];
		final moved: Map<String, String> = [];
		final targets: Map<String, Array<String>> = [];
		final long: Map<String, Bool> = [];
		final normal: Map<String, Bool> = [];
		final order: Array<{ key: String, edge: CallEdge }> = [];
		for (edge in graph.edges) if (edge.kind.isInvocation()) {
			if (!taints.blocks(edge, null)) continue;
			// a `marshals` function IS the thread boundary — its body dispatches
			// between contexts in ways the graph cannot see; sinks inside it are
			// the primitive's own machinery, not application-level main calls
			if (taints.listsOf(edge.file).marshalIds.contains(edge.from)) continue;
			if (states.edgeContext(edge) & ThreadSafety.CTX_MAIN == 0) continue;
			final key: String = '${edge.file}:${edge.span?.from ?? -1}:${edge.from}';
			final known: Null<Array<String>> = targets[key];
			if (known == null) {
				targets[key] = [edge.to];
				order.push({ key: key, edge: edge });
			} else if (!known.contains(edge.to)) {
				known.push(edge.to);
			}
			// long here: a long sink, or a short one this very call repeats
			final repeated: Bool = repeats.repetition.repeated(edge);
			if (costs.all.costsLong(edge, null) || repeated) long[key] = true;
			if (!costs.errors.inCatch(edge) && (costs.normal.costsLong(edge, null) || repeated)) normal[key] = true;
		}
		final inside: Map<String, Bool> = insideSinks(graph, taints, repeats.runs);
		final owned: Map<String, OwnedFinding> = [];
		final takes: Array<{ edge: CallEdge, finding: Violation }> = [];
		for (site in order) {
			final edge: CallEdge = site.edge;
			// a call a sink's own body makes is the sink's machinery: the finding is the call of that sink
			final inSink: Bool = inside.exists(edge.from) || taints.listsOf(edge.file).sinkIds.contains(edge.from);
			final finding: Violation = reportSite(
				graph, edge, targets[site.key] ?? [edge.to], siteCost(sites, costs, edge, long.exists(site.key), normal.exists(site.key)),
				inSink, repeats, states, { owned: owned, moved: moved }, violations
			);
			if (finding.severity == Severity.Warning && taints.takesLock(edge)) takes.push({ edge: edge, finding: finding });
			noteReporter(reportedBy, edge, finding, moved);
		}
		oneTakePerLock(graph, sites, takes);
		return reportedBy;
	}

	/** Records in `reportedBy` the member whose warning reports the sink call `edge`: its own `finding`'s, or the owner it `moved` to. */
	private static function noteReporter(
		reportedBy: Map<String, String>, edge: CallEdge, finding: Violation, moved: Map<String, String>
	): Void {
		final by: Null<String> = finding.severity == Severity.Warning ? finding.data?.member : moved[siteKey(edge)];
		if (by != null) reportedBy[siteKey(edge)] = by;
	}

	/** `<file>:<offset>` of the site of `edge`. */
	public static inline function siteKey(edge: CallEdge): String {
		return '${edge.file}:${edge.span?.from ?? -1}';
	}


	/**
	 * The functions the main thread runs (`runs`) only from inside a sink's own body: every call into one comes from a
	 * sink or from another such function. The least such set, so a cycle no outside call enters is none of them.
	 */
	private static function insideSinks(graph: CallGraph, taints: LockTaint, runs: (CallEdge) -> Bool): Map<String, Bool> {
		final inside: Map<String, Bool> = [];
		var grew: Bool = true;
		while (grew) {
			grew = false;
			for (id => _ in graph.nodes) if (!inside.exists(id)) {
				final ins: Array<CallEdge> = [for (e in graph.inEdges(id)) if (e.kind != Contains && runs(e)) e];
				if (ins.length == 0 || !ins.foreach(e -> inside.exists(e.from) || taints.listsOf(e.file).sinkIds.contains(e.from)))
					continue;
				inside[id] = true;
				grew = true;
			}
		}
		return inside;
	}

	/**
	 * Every main-thread take of one named lock waits for the same holders: of its warnings, one stays — the take inside a
	 * lock wrapper of it (`LockAcquire.delegated`) when there is one, else the first by member, file and offset — and the
	 * others turn info, naming that one.
	 */
	private static function oneTakePerLock(graph: CallGraph, sites: LockSites, takes: Array<{ edge: CallEdge, finding: Violation }>): Void {
		final byLock: Map<String, Array<{ edge: CallEdge, finding: Violation }>> = [];
		for (t in takes) {
			final lock: Null<String> = sites.lockOf(t.edge);
			if (lock == null) continue;
			final list: Array<{ edge: CallEdge, finding: Violation }> = byLock[lock] ?? [];
			list.push(t);
			byLock[lock] = list;
		}
		for (lock => list in byLock) if (list.length > 1) {
			final rank: ({ edge: CallEdge, finding: Violation }) -> String = t ->
				(sites.acquires.exists(a -> a.edge == t.edge && a.delegated) ? '0' : '1')
					+ '${ThreadSafety.memberOf(graph, t.edge.from)}\n${t.edge.file}';
			list.sort(
				(a, b) -> rank(a) == rank(b) ? (a.edge.span?.from ?? 0) - (b.edge.span?.from ?? 0) : Reflect.compare(rank(a), rank(b))
			);
			final kept: String = ThreadSafety.memberOf(graph, list[0].edge.from);
			for (t in list.slice(1)) {
				t.finding.severity = Severity.Info;
				t.finding.message += ' — the same lock $lock as $kept waits for the same holders, reported there';
			}
		}
	}

	/**
	 * The cost of the main-thread call site `edge`: long (`long`), long over the normal paths too (`normal`), and where
	 * it is long only on an error path — a call inside a `catch` runs only there, repeated or not (`caught`).
	 */
	private static function siteCost(
		sites: LockSites, costs: PathCosts, edge: CallEdge, long: Bool, normal: Bool
	): { long: Bool, error: Null<String>, caught: Bool } {
		final caught: Null<String> = costs.errors.placeOf([edge]);
		final error: Null<String> = caught ?? (long && !normal ? errorPlace(sites, costs, edge) : null);
		return { long: long && error == null, error: error, caught: caught != null };
	}

	/**
	 * Where the main-thread take `edge` of a lock long only where a `catch` runs meets that catch: around an unresolved
	 * call a hold of the lock spans, or on the way one blocks long (`file:line`); null when none is found, and the call
	 * stays long.
	 */
	private static function errorPlace(sites: LockSites, costs: PathCosts, edge: CallEdge): Null<String> {
		final lock: Null<String> = sites.lockOf(edge);
		if (lock == null) return null;
		for (a in sites.acquires.concat(sites.helperHolds)) if (a.lock == lock) {
			// an unresolved call long only where a `catch` runs it
			for (c in a.blindCalls) if (!costs.all.briefBlind(a, c)) {
				final place: Null<String> = costs.errors.placeAt(a.edge.file, c.span);
				if (place != null) return place;
			}
			final held: Null<String> = costs.all.reentrantHeld(a);
			for (e in a.window) {
				final trail: Null<BlockingTrail> = costs.all.blockingTrail(a, e, held);
				final place: Null<String> = trail == null ? null : costs.errors.placeOf(trail.edges);
				if (place != null) return place;
			}
		}
		return null;
	}

	/**
	 * Finding (a) at the main-thread call `edge` of `sinks`, long on its own or not (`cost.long`), or long only where the
	 * `catch` at `cost.error` runs — inside it when `cost.caught`. Short once and long only as some caller up the main
	 * thread's way repeats it: the nearest repeating call owns the warning — one per call site, moved, never multiplied by
	 * every loop above — unless that call is the member's own (a recursion, a callback it hands an `iterates` call). A
	 * call inside a `catch` itself repeats nothing over the normal paths. `owners.owned` keeps the owners' findings once
	 * each, `owners.moved` the member each moved site's warning went to.
	 */
	private static function reportSite(
		graph: CallGraph, edge: CallEdge, sinks: Array<String>, cost: { long: Bool, error: Null<String>, caught: Bool }, inSink: Bool,
		repeats: MainRepetition, states: ThreadStates, owners: { owned: Map<String, OwnedFinding>, moved: Map<String, String> },
		violations: Array<Violation>
	): Violation {
		final long: Bool = cost.long;
		final error: Null<String> = cost.error;
		final repeaters: Array<{ edge: CallEdge, path: Array<String> }> = long || inSink || cost.caught || !repeats.main.repeatedAt(edge)
			? []
			: repeats.main.ownersOf(edge);
		final owner: Null<String> = repeaters.length > 0 ? ThreadSafety.memberOf(graph, repeaters[0].edge.from) : null;
		final own: Bool = long || owner == ThreadSafety.memberOf(graph, edge.from);
		if (repeaters.length > 0 && !own) {
			reportRepeater(graph, repeaters[0], sinks, states, owners.owned, violations);
			if (owner != null) owners.moved[siteKey(edge)] = owner;
		}
		final note: String = if (inSink)
			CostNote.InsideSink
		else if (own)
			''
		else if (repeaters.length == 0)
			error == null ? CostNote.ShortMainCall : ErrorPaths.note(error)
		else
			' — short each time, long only as repeated by $owner, reported there'
				+ (repeaters.length > 1 ? ' (${repeaters.length - 1} more repeating caller(s) further away)' : '');
		final finding: Violation = mainSinkFinding(graph, edge, sinks, states.mainPath(edge), states.edgeContext(edge), note);
		violations.push(finding);
		return finding;
	}

	/** Finding (a) at the main-thread call `edge` of `sinks` reached by `path`, a warning unless `note` says why it is not. */
	private static function mainSinkFinding(
		graph: CallGraph, edge: CallEdge, sinks: Array<String>, path: Array<String>, ctx: Int, note: String
	): Violation {
		final named: String = [for (t in sinks) '"$t"'].join(ThreadSafety.SUBJECT_SEPARATOR);
		final also: String = ctx & ThreadSafety.CTX_BG != 0 ? ' (also reachable from a background thread)' : '';
		final sorted: Array<String> = ThreadSafety.sortedIds(sinks);
		return {
			file: edge.file,
			span: edge.span,
			rule: 'thread-safety',
			severity: note == '' ? Severity.Warning : Severity.Info,
			message: 'main thread reaches blocking $named$also: ${ThreadStates.chainText(path, ThreadSafety.CHAIN_CAP)} -> ${sinks.join(ThreadSafety.SUBJECT_SEPARATOR)}$note',
			data: {
				family: FindingFamily.MainSink,
				member: ThreadSafety.memberOf(graph, edge.from),
				subject: sorted.join(ThreadSafety.SUBJECT_SEPARATOR),
				chain: path.concat(sorted)
			}
		};
	}

	/**
	 * Finding (a) owned by the repeating call `owner` (`MainRepeats.ownersOf`) of short `sinks`: the warning a short
	 * call below it is spared, at the loop, recursion or `iterates` call that repeats it — ONE per call site, keyed by
	 * the call it repeats (`owner.edge.to`), every short sink below it named in it; `owned` keeps them by site.
	 */
	private static function reportRepeater(
		graph: CallGraph, owner: { edge: CallEdge, path: Array<String> }, sinks: Array<String>, states: ThreadStates,
		owned: Map<String, OwnedFinding>, violations: Array<Violation>
	): Void {
		final edge: CallEdge = owner.edge;
		final key: String = siteKey(edge);
		final known: Null<OwnedFinding> = owned[key];
		if (known != null) {
			final grown: Array<String> = known.sinks.concat([for (t in sinks) if (!known.sinks.contains(t)) t]);
			if (grown.length == known.sinks.length) return;
			known.sinks = grown;
			fill(known);
			return;
		}
		final path: Array<String> = states.mainPath(edge).concat(owner.path);
		final finding: Violation = {
			file: edge.file,
			span: edge.span,
			rule: 'thread-safety',
			severity: Severity.Warning,
			message: '',
			data: {
				family: FindingFamily.MainSink,
				member: ThreadSafety.memberOf(graph, edge.from),
				subject: edge.to,
				chain: []
			}
		};
		final made: OwnedFinding = { finding: finding, sinks: ThreadSafety.sortedIds(sinks), path: path };
		fill(made);
		owned[key] = made;
		violations.push(finding);
	}

	/** Writes the message and chain of the repeating call's finding `owned` from the short sinks it names so far. */
	private static function fill(owned: OwnedFinding): Void {
		final sorted: Array<String> = ThreadSafety.sortedIds(owned.sinks);
		owned.sinks = sorted;
		owned.finding.message = 'main thread repeats short blocking ${[for (t in sorted) '"$t"'].join(ThreadSafety.SUBJECT_SEPARATOR)}'
			+ ' at this call: ${ThreadStates.chainText(owned.path, ThreadSafety.CHAIN_CAP)} -> ${sorted.join(ThreadSafety.SUBJECT_SEPARATOR)}';
		final data: Null<FindingData> = owned.finding.data;
		if (data != null) data.chain = owned.path.concat(sorted);
	}

}
