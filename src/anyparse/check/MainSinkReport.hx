package anyparse.check;

import anyparse.check.Check.FindingData;
import anyparse.check.Check.RepeatSite;
import anyparse.check.Check.Violation;
import anyparse.check.ErrorPaths.PathCosts;
import anyparse.check.LockTaint.BlockingTrail;
import anyparse.check.MainRepeats.MainClimb;
import anyparse.check.MainRepeats.RepeatOwner;
import anyparse.check.ThreadSafety.CostNote;
import anyparse.check.ThreadSafety.FindingFamily;
import anyparse.query.CallGraph;
import anyparse.runtime.Span;

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
 * call run once is info; one long only because a caller up the main thread's way repeats it is
 * info too, its warning moved to each nearest repeating call on a way up (`MainRepeats.climb`),
 * unless that call is the member's own; one whose repetition nothing resolves warns itself.
 */
@:nullSafety(Strict)
final class MainSinkReport {

	/**
	 * Each of finding (a) over `graph`, under the plain `taints` and the costed `costs`, into `violations`. A call long
	 * only where a `catch` runs — itself inside one, or a take of a lock long over the normal paths of no hold — is
	 * graded as if short, and info, naming that catch, when no repeating caller owns it. Returns, by `siteKey`, the
	 * warning that reports each main-thread sink call: its own, the repeating call's that owns it, or the one its sibling
	 * calls fold into (`oneWarningPerWay`).
	 */
	public static function report(
		graph: CallGraph, sites: LockSites, taints: LockTaint, costs: PathCosts, repeats: MainRepetition, states: ThreadStates,
		violations: Array<Violation>
	): Map<String, Violation> {
		final reportedBy: Map<String, Violation> = [];
		final moved: Map<String, Violation> = [];
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
		final direct: Array<{ edge: CallEdge, finding: Violation }> = [];
		for (site in order) {
			final edge: CallEdge = site.edge;
			// a call a sink's own body makes is the sink's machinery: the finding is the call of that sink
			final inSink: Bool = inside.exists(edge.from) || taints.listsOf(edge.file).sinkIds.contains(edge.from);
			final finding: Violation = reportSite(
				graph, edge, targets[site.key] ?? [edge.to], siteCost(sites, costs, edge, long.exists(site.key), normal.exists(site.key)),
				inSink, repeats, states, { owned: owned, moved: moved }, violations
			);
			if (finding.severity == Severity.Warning) (taints.takesLock(edge) ? takes : direct).push({ edge: edge, finding: finding });
			noteReporter(reportedBy, edge, finding, moved);
		}
		oneTakePerLock(graph, sites, takes);
		oneWarningPerWay(direct, states, reportedBy);
		noteRepeats(takes.concat(direct));

		for (notice in repeats.repetition.notices()) violations.push({
			file: '',
			span: null,
			rule: 'thread-safety',
			severity: Severity.Info,
			message: notice
		});
		return reportedBy;
	}

	/** Records in `reportedBy` the warning that reports the sink call `edge`: its own `finding`, or the owner's it `moved` to. */
	private static function noteReporter(
		reportedBy: Map<String, Violation>, edge: CallEdge, finding: Violation, moved: Map<String, Violation>
	): Void {
		final by: Null<Violation> = finding.severity == Severity.Warning ? finding : moved[siteKey(edge)];
		if (by != null) reportedBy[siteKey(edge)] = by;
	}

	/**
	 * Of the warnings at sink calls in one function the main thread reaches by one way (`ThreadStates.mainPath`) — TM's
	 * `FSUtil.deleteRecursive`, whose `readDirectory`, `deleteDirectory` and `deleteFile` run on every run of it — the
	 * first by offset stays, naming the others, and they turn info naming it: one trigger, one warning. Lock takes are
	 * left to `oneTakePerLock`. `reportedBy` follows each turned one to the warning that stays.
	 */
	private static function oneWarningPerWay(
		direct: Array<{ edge: CallEdge, finding: Violation }>, states: ThreadStates, reportedBy: Map<String, Violation>
	): Void {
		final byWay: Map<String, Array<{ edge: CallEdge, finding: Violation }>> = [];
		final ways: Array<String> = [];
		for (d in direct) {
			final way: String = '${d.edge.file}\n${d.edge.from}\n${states.mainPath(d.edge).join('\n')}';
			final list: Null<Array<{ edge: CallEdge, finding: Violation }>> = byWay[way];
			if (list == null) {
				byWay[way] = [d];
				ways.push(way);
			} else {
				list.push(d);
			}
		}
		for (way in ways) {
			final list: Array<{ edge: CallEdge, finding: Violation }> = byWay[way] ?? [];
			if (list.length < 2) continue;
			list.sort((a, b) -> (a.edge.span?.from ?? 0) - (b.edge.span?.from ?? 0));
			final kept: Violation = list[0].finding;
			final named: Array<String> = [];
			for (d in list.slice(1)) if (d.finding != kept) {
				d.finding.severity = Severity.Info;
				d.finding.message += ' — run on the same main-thread way into ${d.edge.from} as "${kept.data?.subject}", reported there';
				mergeRepeats(kept, d.finding);
				for (k => v in reportedBy) if (v == d.finding) reportedBy[k] = kept;
				final subject: String = d.finding.data?.subject ?? d.edge.to;
				if (!named.contains(subject)) named.push(subject);
			}
			if (named.length > 0) kept.message += ' — with ${[for (n in named) '"$n"'].join(', ')} on the same way, reported here';
		}
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
	 * thread's way repeats it (`MainRepeats.climb`): each NEAREST repeating call owns a warning, a farther one counted — one per call
	 * site, moved, never multiplied by every loop above — unless that call is the member's own (a recursion, a callback
	 * it hands a call that may repeat it), and then the call warns itself. A way ending at a function only an assumption
	 * runs repeats it as often as that function runs, which nothing says: a warning, saying so. Info only when every way
	 * is proven once — up to the entry point, or to a registration (`registers`), which the note names. A call inside a
	 * `catch` itself repeats nothing over the normal paths. `owners.owned` keeps the owners' findings once each,
	 * `owners.moved` the first warning each moved site went to.
	 */
	private static function reportSite(
		graph: CallGraph, edge: CallEdge, sinks: Array<String>, cost: { long: Bool, error: Null<String>, caught: Bool }, inSink: Bool,
		repeats: MainRepetition, states: ThreadStates, owners: { owned: Map<String, OwnedFinding>, moved: Map<String, Violation> },
		violations: Array<Violation>
	): Violation {
		final long: Bool = cost.long;

		final climb: Null<MainClimb> = long || inSink || cost.caught ? null : repeats.main.climb(edge);
		final found: Array<RepeatOwner> = climb?.owners ?? [];
		// the nearest owners each warn; one farther up another way is counted in the note
		final repeaters: Array<RepeatOwner> = found.filter(o -> o.path.length == found[0].path.length);
		final assumed: Array<String> = climb?.assumed ?? [];
		final member: String = ThreadSafety.memberOf(graph, edge.from);
		final elsewhere: Array<String> = [];
		for (r in repeaters) {
			final by: String = ThreadSafety.memberOf(graph, r.edge.from);
			if (by == member) continue;
			final finding: Violation = reportRepeater(graph, r, sinks, repeats, states, owners.owned, violations);
			if (!owners.moved.exists(siteKey(edge))) owners.moved[siteKey(edge)] = finding;
			if (!elsewhere.contains(by)) elsewhere.push(by);
		}
		final own: Bool = long || assumed.length > 0 || repeaters.exists(r -> ThreadSafety.memberOf(graph, r.edge.from) == member);
		final note: String = if (inSink)
			CostNote.InsideSink
		else if (own)
			assumed.length > 0 && !long ? unknownNote(assumed) : ''
		else
			shortNote(elsewhere, found.length - repeaters.length, cost.error, climb?.registered == true);
		final finding: Violation = mainSinkFinding(
			graph, edge, sinks, states.mainPath(edge), states.edgeContext(edge), note, own && !inSink
		);
		attachRepeats(graph, finding, edge, repeats, climb);
		violations.push(finding);
		return finding;
	}

	/**
	 * Records in the data of `finding`, at the main-thread call `edge`, what repeats that call (`repeatersOf`) when it
	 * warns: a long call warns at itself, and this says it runs per item, which ranks it. `climb` is the walk already
	 * made, if any.
	 */
	private static function attachRepeats(
		graph: CallGraph, finding: Violation, edge: CallEdge, repeats: MainRepetition, climb: Null<MainClimb>
	): Void {
		final data: Null<FindingData> = finding.data;
		if (data == null || finding.severity != Severity.Warning) return;
		final by: Array<RepeatSite> = repeatersOf(graph, edge, repeats, climb);
		if (by.length > 0) data.repeatedBy = by;
	}

	/**
	 * The nearest repeating calls up the main thread's ways that run the call `edge` more than once — the call itself
	 * when it repeats where it stands (`CallRepetition.repeated`) — each by its member and what repeats there
	 * (`repeatSubject`); `climb` is the walk already made, if any.
	 */
	private static function repeatersOf(
		graph: CallGraph, edge: CallEdge, repeats: MainRepetition, climb: Null<MainClimb>
	): Array<RepeatSite> {
		final repetition: CallRepetition = repeats.repetition;
		if (repetition.repeated(edge)) return [
			{ member: ThreadSafety.memberOf(graph, edge.from), at: repeatSubject(edge, repetition) }
		];
		final found: Array<RepeatOwner> = (climb ?? repeats.main.climb(edge)).owners;
		final by: Array<RepeatSite> = [];
		for (o in found) if (o.path.length == found[0].path.length) {
			final site: RepeatSite = { member: ThreadSafety.memberOf(graph, o.edge.from), at: repeatSubject(o.edge, repetition) };
			if (!by.exists(r -> r.member == site.member && r.at == site.at)) by.push(site);
		}
		return by;
	}

	/** Adds to the warning `kept` the repeating calls of the finding `folded` it now reports. */
	private static function mergeRepeats(kept: Violation, folded: Violation): Void {
		final into: Null<FindingData> = kept.data;
		final from: Array<RepeatSite> = folded.data?.repeatedBy ?? [];
		if (into == null || from.length == 0) return;
		final by: Array<RepeatSite> = into.repeatedBy ?? [];
		for (r in from) if (!by.exists(x -> x.member == r.member && x.at == r.at)) by.push(r);
		into.repeatedBy = by;
	}

	/** Says in the message of each warning of `warned` what repeats its call (`FindingData.repeatedBy`), when anything does. */
	private static function noteRepeats(warned: Array<{ edge: CallEdge, finding: Violation }>): Void {
		for (w in warned) {
			final by: Array<RepeatSite> = w.finding.data?.repeatedBy ?? [];
			if (w.finding.severity == Severity.Warning && by.length > 0)
				w.finding.message += ' — repeated by ${[for (r in by) '${r.member} at ${r.at}'].join(', ')}';
		}
	}

	/**
	 * The note of a short main-thread call that warns nowhere itself: long only as the members `elsewhere` repeat it,
	 * `further` more repeating callers farther up counted; long only where the catch at `error` runs; or once per run —
	 * per event of a registration when `registered`.
	 */
	private static function shortNote(elsewhere: Array<String>, further: Int, error: Null<String>, registered: Bool): String {
		return if (elsewhere.length > 0)
			' — short each time, long only as repeated by ${elsewhere.join(', ')}, reported there'
				+ (further > 0 ? ' ($further more repeating caller(s) further away)' : '')
		else if (error != null)
			ErrorPaths.note(error)
		else
			registered ? CostNote.ShortRegisteredCall : CostNote.ShortMainCall;
	}

	/** The note of a warning whose repetition is unknown: the functions on its ways `assumed` that no call the graph resolves runs. */
	private static function unknownNote(assumed: Array<String>): String {
		final named: Array<String> = assumed.slice(0, ThreadSafety.CHAIN_CAP);
		final more: Int = assumed.length - named.length;
		return ' — repetition unknown: no call the graph resolves runs ${named.join(', ')}${more > 0 ? ' (+$more more)' : ''}, which'
			+ ' may run any number of times';
	}

	/**
	 * Finding (a) at the main-thread call `edge` of `sinks` reached by `path`: a warning when `warn`, else info, `note` saying why.
	 */
	private static function mainSinkFinding(
		graph: CallGraph, edge: CallEdge, sinks: Array<String>, path: Array<String>, ctx: Int, note: String, warn: Bool
	): Violation {
		final named: String = [for (t in sinks) '"$t"'].join(ThreadSafety.SUBJECT_SEPARATOR);
		final also: String = ctx & ThreadSafety.CTX_BG != 0 ? ' (also reachable from a background thread)' : '';
		final sorted: Array<String> = ThreadSafety.sortedIds(sinks);
		return {
			file: edge.file,
			span: edge.span,
			rule: 'thread-safety',
			severity: warn ? Severity.Warning : Severity.Info,
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
	 * Finding (a) owned by the repeating call `owner` (`MainRepeats.climb`) of short `sinks`: the warning a short
	 * call below it is spared, at the loop, recursion or `iterates` call that repeats it — ONE per call site, or per
	 * loop for the calls one loop repeats (TM's `repairShareAttr`, whose session loop runs
	 * `getXML` and `setXML`), about what `repeatSubject` names — the loop, never its first
	 * call, so a call added to the loop moves no key — every short sink below it named in it;
	 * `owned` keeps them by site or loop. Returns that finding.
	 */
	private static function reportRepeater(
		graph: CallGraph, owner: RepeatOwner, sinks: Array<String>, repeats: MainRepetition, states: ThreadStates,
		owned: Map<String, OwnedFinding>, violations: Array<Violation>
	): Violation {
		final edge: CallEdge = owner.edge;
		final key: String = repeatKey(edge, repeats.repetition);
		final known: Null<OwnedFinding> = owned[key];
		if (known != null) {
			if ((edge.span?.from ?? 0) < (known.finding.span?.from ?? 0)) known.finding.span = edge.span;
			known.sinks = known.sinks.concat([for (t in sinks) if (!known.sinks.contains(t)) t]);
			fill(known);
			return known.finding;
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
				subject: repeatSubject(edge, repeats.repetition),
				chain: []
			}
		};
		final made: OwnedFinding = { finding: finding, sinks: ThreadSafety.sortedIds(sinks), path: path };
		fill(made);
		owned[key] = made;
		violations.push(finding);
		return finding;
	}

	/** The key a repeating call's finding is kept by: its innermost loop when one repeats it, else its site. */
	private static function repeatKey(edge: CallEdge, repetition: CallRepetition): String {
		final loops: Null<Array<Span>> = repetition.loopsAt(edge.file, edge.span?.from ?? -1);
		return loops == null || loops.length == 0 ? siteKey(edge) : '${edge.file}:loop:${loops[loops.length - 1].from}';
	}

	/**
	 * What a repeating call's finding is about, by name, never by position: the header of the innermost loop around it
	 * (`CallRepetition.loopLabel`) — whatever other calls that loop repeats — else the call a value is handed to, else the
	 * call's target, a lambda's positional number (`#3`) spelled `#fn`.
	 */
	private static function repeatSubject(edge: CallEdge, repetition: CallRepetition): String {
		final loop: Null<String> = repetition.loopLabel(edge.file, edge.span?.from ?? -1);
		if (loop != null) return loop;
		final target: String = edge.kind == Ref ? (edge.via ?? edge.viaMember ?? edge.to) : edge.to;
		return ~/#[0-9]+/g.replace(target, "#fn");
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
