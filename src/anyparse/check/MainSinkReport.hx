package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.check.ThreadSafety.CostNote;
import anyparse.check.ThreadSafety.FindingFamily;
import anyparse.query.CallGraph;

using Lambda;

/** How the main thread repeats calls: where (`repetition`), which functions it may run more than once (`on`), and the edges it runs (`runs`). */
typedef MainRepetition = {
	final repetition: CallRepetition;
	final on: Map<String, Bool>;
	final runs: (CallEdge) -> Bool;
}

/**
 * Finding (a) of `thread-safety`: a MAIN-context function directly calls a sink — one taking a lock only when that lock
 * is long or unknown — one finding per call site, naming every sink a dispatch there may reach. Graded by cost: a short
 * call run once is info; one long only because a caller up the main thread's way repeats it is info too, its warning
 * moved to the nearest repeating call (`CallRepetition.repeatersOf`), unless that call is the member's own.
 */
@:nullSafety(Strict)
final class MainSinkReport {

	/** Each of finding (a) over `graph`, under the plain `taints` and the costed `costs`, into `violations`. */
	public static function report(
		graph: CallGraph, taints: LockTaint, costs: LockTaint, repeats: MainRepetition, states: ThreadStates, violations: Array<Violation>
	): Void {
		final targets: Map<String, Array<String>> = [];
		final long: Map<String, Bool> = [];
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
			if (costs.costsLong(edge, null) || repeats.repetition.repeated(edge)) long[key] = true;
		}
		final owned: Array<String> = [];
		for (site in order)
			reportSite(graph, site.edge, targets[site.key] ?? [site.edge.to], long.exists(site.key), repeats, states, owned, violations);
	}

	/**
	 * Finding (a) at the main-thread call `edge` of `sinks`, long on its own or not (`long`). Short once and long only as
	 * some caller up the main thread's way repeats it: the nearest repeating call owns the warning — one per call site,
	 * moved, never multiplied by every loop above — unless that call is the member's own (a recursion, a callback it
	 * hands an `iterates` call). `owned` keeps the owners' findings once each.
	 */
	private static function reportSite(
		graph: CallGraph, edge: CallEdge, sinks: Array<String>, long: Bool, repeats: MainRepetition, states: ThreadStates,
		owned: Array<String>, violations: Array<Violation>
	): Void {
		final owners: Array<{ edge: CallEdge, path: Array<String> }> = long || !repeats.on.exists(edge.from)
			? []
			: repeats.repetition.repeatersOf(edge.from, repeats.runs);
		final owner: Null<String> = owners.length > 0 ? ThreadSafety.memberOf(graph, owners[0].edge.from) : null;
		final own: Bool = long || owner == ThreadSafety.memberOf(graph, edge.from);
		if (owners.length > 0 && !own) reportRepeater(graph, owners[0], sinks, states, owned, violations);
		final note: String = if (own)
			''
		else if (owners.length == 0)
			CostNote.ShortMainCall
		else
			' — short each time, long only as repeated by $owner, reported there'
				+ (owners.length > 1 ? ' (${owners.length - 1} more repeating caller(s) further away)' : '');
		violations.push(mainSinkFinding(graph, edge, sinks, states.mainPath(edge), states.edgeContext(edge), note));
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
	 * Finding (a) owned by the repeating call `owner` (`CallRepetition.repeatersOf`) of short `sinks`: the warning a short
	 * call below it is spared, at the loop, recursion or `iterates` call that repeats it — once per site and subject.
	 */
	private static function reportRepeater(
		graph: CallGraph, owner: { edge: CallEdge, path: Array<String> }, sinks: Array<String>, states: ThreadStates, owned: Array<String>,
		violations: Array<Violation>
	): Void {
		final edge: CallEdge = owner.edge;
		final sorted: Array<String> = ThreadSafety.sortedIds(sinks);
		final key: String = '${edge.file}:${edge.span?.from ?? -1}:${sorted.join(ThreadSafety.SUBJECT_SEPARATOR)}';
		if (owned.contains(key)) return;
		owned.push(key);
		final path: Array<String> = states.mainPath(edge).concat(owner.path);
		violations.push({
			file: edge.file,
			span: edge.span,
			rule: 'thread-safety',
			severity: Severity.Warning,
			message: 'main thread repeats short blocking ${[for (t in sinks) '"$t"'].join(ThreadSafety.SUBJECT_SEPARATOR)} at this call: '
			+ '${ThreadStates.chainText(path, ThreadSafety.CHAIN_CAP)} -> ${sinks.join(ThreadSafety.SUBJECT_SEPARATOR)}',
			data: {
				family: FindingFamily.MainSink,
				member: ThreadSafety.memberOf(graph, edge.from),
				subject: sorted.join(ThreadSafety.SUBJECT_SEPARATOR),
				chain: path.concat(sorted)
			}
		});
	}

}
