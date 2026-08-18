package anyparse.query;

import anyparse.runtime.Span;

using Lambda;
using StringTools;

/** One class placed on one shard — the `<shard>\t<class>` row `--format lines` prints. */
typedef ShardPlacement = {
	shard: Int,
	cls: String
};

/**
 * Everything `ShardPlan.plan` reads: the parsed runner, its text (hit
 * positions in a refusal are resolved against it), the path the messages
 * name, and how many shards to deal onto.
 */
typedef ShardPlanRequest = {
	tree: QueryNode,
	source: String,
	runner: String,
	shards: Int
};

/** A finished plan, or the refusal that stopped it — already formatted for stderr. */
enum ShardPlanResult {
	Planned(placements: Array<ShardPlacement>);
	Refused(message: String);
}

/** One registered class carrying the two keys the scheduler orders on. */
private typedef ShardEntry = {
	sticky: Bool,
	weight: Int,
	cls: String
};

/**
 * `apq shard-plan` — deal every class registered in `test/RunTests.hx` onto
 * N `APQ_TEST` shards, or refuse.
 *
 * This lives here, and not in `tools/suite-shard.sh`, for the reason
 * `apq mutation-verdict` lives here: the script's gates are the only thing
 * between a silently-shrunken run and a green report, and a shell function
 * is not testable. `ShardPlanTest` is the first cover these gates have ever
 * had.
 *
 * The pipeline, in the order the refusals fire:
 *
 *  1. **Extraction.** `addCase(new X())` is read as an AST shape, never as
 *     text. The script matched it with a search pattern and then stripped
 *     the name with a regex, and the pattern's `()` does NOT constrain
 *     arity — `addCase(new X(1))` matched too, and the naive strip yielded
 *     the filter string `unit.X(1))`, which selects no class at all: the
 *     shard silently runs fewer tests while class parity still passes,
 *     because the bogus name is in the plan. Here arity is structure (a
 *     `NewExpr` with children is a constructor call with arguments) and so
 *     is a dotted vs bare name. Any registration this cannot name stops the
 *     run — a silent skip is the failure mode the gate exists for.
 *  2. **Duplicates.** Two registrations of one class cannot be reproduced
 *     by a split that runs each class once.
 *  3. **Substring collisions.** `APQ_TEST` is a SUBSTRING filter over the
 *     fully-qualified class name, so `unit.Foo` also selects `unit.FooBar`.
 *     In one process that is harmless; split across shards the class runs
 *     TWICE and the aggregate silently exceeds the monolith. O(n^2) over
 *     ~600 names is a few milliseconds.
 *  4. **Pinned classes.** Every name in `STICKY_CLASSES` must still be
 *     registered — a rename would otherwise un-pin a class in silence and
 *     bring the race back.
 *  5. **The split**, then parity on its result: every registered class
 *     placed exactly once, and the placed set equal to the registered set.
 */
@:nullSafety(Strict)
final class ShardPlan {

	/**
	 * Classes that share MUTABLE STATE outside their own process, pinned to
	 * shard 0 as ONE group. Two such paths are fixed constants, not per-test
	 * temps: `/tmp/anyparse-last-probe.hx` (`Cli.STAGE_PROBE_PATH`, a single
	 * slot that `apq probe` overwrites and the Tier-5 tests read back
	 * byte-for-byte) and `bin/.last-sweep.json` (the corpus delta baseline,
	 * rewritten by `HxFormatterCorpusTest` and read by `ApqDxTier5CliTest`).
	 *
	 * The list is DERIVED, not remembered. Every class holding an exact
	 * `probe` string leaf calls the subcommand that writes the staging slot:
	 * `hxq lit 'probe' test/ --kind Literal`, then READ each hit — one of
	 * them is a fixture method named `probe`, not a subcommand. `hxq lit
	 * '.last-sweep.json' test/` finds the corpus baseline's users. Re-derive
	 * when adding a test that stages a probe or touches that baseline: a
	 * writer left outside the group does not fail, it races a byte-for-byte
	 * read-back in a sub-millisecond window and surfaces later as an
	 * unreproducible flake.
	 *
	 * Everything else uses unique per-test temp directories and random
	 * compiler-server ports, so it parallelises freely.
	 */
	public static final STICKY_CLASSES: Array<String> = [
		'unit.HxFormatterCorpusTest',
		'unit.ApqDxTier5CliTest',
		'unit.ApqDxTier4CliTest',
		'unit.ApqProbeCliTest',
		'unit.ApqReconCliTest',
		'unit.ApqWriterProbeCliTest',
		'unit.ApqAstTypeRefsCliTest',
		'unit.ApqHxtestSection1ConfigTest'
	];

	/** What a class not in `CLASS_WEIGHTS` costs — the tail is flat, so one number covers it. */
	private static inline final DEFAULT_WEIGHT: Int = 30;

	/** Package a bare `addCase(new X())` registration belongs to. */
	private static inline final DEFAULT_PACKAGE: String = 'unit';

	/** The call this reads out of the runner. */
	private static inline final REGISTER_CALL: String = 'addCase';

	/** Every message this module produces carries the subcommand's own prefix. */
	private static inline final TAG: String = 'apq shard-plan: ';

	/** Longest source fragment quoted back for a registration that cannot be named. */
	private static inline final QUOTE_LIMIT: Int = 120;

	/** Why a registration was refused — the two halves of one message shape. */
	private static inline final NAME_REASON: String = 'cannot derive an APQ_TEST filter from';

	private static inline final CONDITIONAL_REASON: String = 'registration inside a conditional-compilation region';

	/**
	 * The base of each band in `primaryWeight`, in the order a UTF-8 locale
	 * collates them: connector punctuation, then `.`, then the ten digits, then
	 * the twenty-six letters, and finally anything a qualified Haxe identifier
	 * cannot contain. The bands only have to be disjoint and increasing; the
	 * exact numbers are arbitrary beyond leaving each band room for its members.
	 */
	private static inline final RANK_UNDERSCORE: Int = 1;

	private static inline final RANK_DOT: Int = 2;
	private static inline final RANK_DIGIT: Int = 10;
	private static inline final RANK_LETTER: Int = 30;
	private static inline final RANK_OTHER: Int = 1000;

	/**
	 * Measured in-suite self-times from the suite profile (2026-08-17, HEAD
	 * `ff3f20ae`), in milliseconds. In-suite rather than isolated: an
	 * isolated run re-pays the ~2.4 s resolution warm-up that the monolith
	 * pays once, which overstates every class touching the resolution
	 * library and produces a worse split.
	 *
	 * `unit.ApqDxTier5CliTest` reads 40 rather than the 4510 in that profile:
	 * `testSelfStatusSourceFlagAccepted` walked the whole `src/` to assert one
	 * exit code, and has been scoped to a fixture since.
	 *
	 * Stale weights cost BALANCE, never correctness — no gate reads them, so
	 * a class whose cost has drifted lands on a busier shard and nothing else.
	 * That property is why this table needs no maintenance schedule, and it is
	 * a property the TESTS have to preserve too: assert that the split is
	 * balanced, never that a particular class count vector comes out.
	 */
	private static final CLASS_WEIGHTS: Map<String, Int> = [
		'unit.ApqDxTier5CliTest' => 40,
		'unit.LintConfigCliTest' => 2370,
		'unit.CompilerOracleE2ETest' => 2100,
		'unit.ExplicitLocalTypeOracleE2ETest' => 1900,
		'unit.HxFormatterCorpusTest' => 1400,
		'unit.ExplicitTypeReturnOracleTest' => 1310,
		'unit.ApqDxTier4CliTest' => 1180,
		'unit.AvoidDynamicBagOracleE2ETest' => 950,
		'unit.PreferInlineOracleTest' => 730,
		'unit.LintFixFixedPointCliTest' => 530,
		'unit.FixVerifierGroupE2ETest' => 520,
		'unit.ResolutionScopeCliTest' => 500,
		'unit.LintPerFileConfigCliTest' => 350,
		'unit.PreferCaseGuardOracleE2ETest' => 280,
		'unit.AvoidDynamicRiskyFixE2ETest' => 280,
		'unit.ResolutionLibraryCacheTest' => 250,
		'unit.ImplicitStdScopeTest' => 210,
		'unit.GuardContinueCheckTest' => 190,
		'unit.FixVerifierScopeE2ETest' => 170,
		'unit.PreferStaticExtensionCheckTest' => 150
	];

	/**
	 * Deal the runner's registered classes onto `request.shards` shards.
	 *
	 * The sticky group goes onto shard 0 as one block before the greedy pass
	 * starts filling it; every other class then goes to whichever shard is
	 * lightest so far. Greedy longest-processing-time-first is within 4/3 of
	 * optimal and needs no search.
	 */
	public static function plan(request: ShardPlanRequest): ShardPlanResult {
		if (request.shards < 1) return Refused('${TAG}--shards must be >= 1, got ${request.shards}');

		final imports: Array<String> = [];
		collectImports(request.tree, imports);
		final registered: Array<String> = [];
		final unnameable: Array<String> = [];
		collect(request, request.tree, false, imports, registered, unnameable);
		if (unnameable.length > 0) return Refused(
			unnameable.concat([
				'$TAG${request.runner} holds a registration this generator cannot name — fix the shape or teach the parser'
			])
				.join('\n')
		);
		if (registered.length == 0) return Refused('${TAG}found no $REGISTER_CALL(new X()) registrations in ${request.runner}');
		// Bounded here rather than only by the empty-shard gate below: a wild
		// --shards reaches `deal`'s per-shard load array first, and a V8 fatal
		// allocation error is a poor answer to a typo.
		if (request.shards > registered.length)
			return Refused(
				'${TAG}--shards ${request.shards} exceeds the ${registered.length} registered classes'
				+ ' — every plan would leave an empty shard'
			);

		final sorted: Array<String> = registered.copy();
		sorted.sort(compareNames);
		final unique: Array<String> = dedupe(sorted);
		if (unique.length != registered.length)
			return Refused(
				'$TAG${request.runner} registers the same class twice (${registered.length} registrations, ${unique.length}'
				+ ' distinct) — a sharded run cannot reproduce that'
			);

		final collisions: Array<String> = findCollisions(unique);
		if (collisions.length > 0)
			return Refused(
				'${TAG}APQ_TEST filter collision — these names cannot be split across shards without double-running:\n'
				+ collisions.join('\n')
			);

		for (sticky in STICKY_CLASSES) if (!unique.contains(sticky))
			return Refused(
				'${TAG}pinned class $sticky is not registered in ${request.runner} — renamed or removed? update the sticky list'
			);

		final placements: Array<ShardPlacement> = deal(unique, request.shards);
		final parity: Null<String> = checkParity(unique, placements, request.shards);
		return parity == null ? Planned(placements) : Refused(parity);
	}

	/** `<shard>\t<class>` per line, in placement order. */
	public static function renderLines(placements: Array<ShardPlacement>): String {
		final buf: StringBuf = new StringBuf();
		for (p in placements) buf.add('${p.shard}\t${p.cls}\n');
		return buf.toString();
	}

	/** One line per shard: the comma-joined `APQ_TEST` value that shard runs with. */
	public static function renderFilters(placements: Array<ShardPlacement>, shards: Int): String {
		final buf: StringBuf = new StringBuf();
		for (s in 0...shards) {
			final names: Array<String> = [for (p in placements) if (p.shard == s) p.cls];
			buf.add('${names.join(',')}\n');
		}
		return buf.toString();
	}

	/**
		 * `sort(1)`'s order under a UTF-8 locale, pinned so the plan no longer
		 * depends on the machine's `LC_COLLATE`: primary weights compare the base
		 * character (punctuation, then digits, then letters case-folded), and case
		 * decides only when the primaries tie, lowercase first. The shell version
		 * inherited whatever collation the caller's locale supplied — the same
		 * tree produced a different split under `LC_ALL=C` than under a UTF-8
		 * locale, since C orders every uppercase letter ahead of every lowercase
		 * one and this does not.
		 *
		  * Only the tiebreak between classes of equal weight rides on this, so a
	 * disagreement would cost balance rather than correctness — but a plan
	 * that is reproducible across machines is worth the twenty lines.
	 *
	 * The claim is scoped to a qualified Haxe identifier, which is all
	 * `isDottedIdentifier` admits. Outside that alphabet this sorts by code
	 * point AFTER everything else, where real collation puts most punctuation
	 * BEFORE digits — so do not reach for it as a general collator.
	 */
	public static function compareNames(a: String, b: String): Int {
		final shortest: Int = a.length < b.length ? a.length : b.length;
		for (i in 0...shortest) {
			final left: Int = primaryWeight(a.fastCodeAt(i));
			final right: Int = primaryWeight(b.fastCodeAt(i));
			if (left != right) return left < right ? -1 : 1;
		}
		if (a.length != b.length) return a.length < b.length ? -1 : 1;
		for (i in 0...shortest) {
			final left: Int = caseWeight(a.fastCodeAt(i));
			final right: Int = caseWeight(b.fastCodeAt(i));
			if (left != right) return left < right ? -1 : 1;
		}
		return 0;
	}

	/**
	 * Collect one `addCase(new X())` per call, and one complaint per call
	 * whose shape cannot become an `APQ_TEST` filter.
	 *
	 * The callee must be a bare `IdentExpr`, which is what keeps the runner's
	 * own `runner.addCase(testCase)` — a `FieldAccess` callee inside the
	 * filtering wrapper — out of the list.
	 */
	private static function collect(
		request: ShardPlanRequest, node: QueryNode, conditional: Bool, imports: Array<String>, out: Array<String>, bad: Array<String>
	): Void {
		final kids: Array<QueryNode> = node.children;
		if (node.kind == 'Call' && kids.length > 0 && kids[0].kind == 'IdentExpr' && kids[0].name == REGISTER_CALL) {
			final name: Null<String> = conditional ? null : registrationName(kids, imports);
			if (name == null)
				bad.push('${TAG}${conditional ? CONDITIONAL_REASON : NAME_REASON}: ${locate(request, node)}');
			else
				out.push(name);
		}
		// A `Conditional` node holds EVERY branch's statements flattened as
		// siblings, with no marker for which one compiles. Planning them all
		// invents a filter matching nothing for the branches that are off, and
		// one class registered under two exclusive branches reads as a duplicate
		// — so the whole region is a refusal rather than a guess.
		final inside: Bool = conditional || node.kind == 'Conditional';
		for (c in kids) collect(request, c, inside, imports, out, bad);
	}

	/** Every module path the runner imports — how a bare registration is qualified. */
	private static function collectImports(node: QueryNode, out: Array<String>): Void {
		final path: Null<String> = node.name;
		if (node.kind == 'ImportDecl' && path != null) out.push(path);
		for (c in node.children) collectImports(c, out);
	}

	/**
	 * The `APQ_TEST` filter for one `addCase(...)` call's children, or null
	 * when the shape cannot produce one: anything but a single argument, an
	 * argument that is not `new`, a constructor call carrying arguments, or a
	 * type name that is not a plain (optionally dotted) identifier.
	 */
	private static function registrationName(kids: Array<QueryNode>, imports: Array<String>): Null<String> {
		if (kids.length != 2) return null;
		final arg: QueryNode = kids[1];
		if (arg.kind != 'NewExpr' || arg.children.length != 0) return null;
		final raw: Null<String> = arg.name;
		if (raw == null || !isDottedIdentifier(raw)) return null;
		if (raw.indexOf('.') >= 0) return raw;
		// `APQ_TEST` matches the FULLY-QUALIFIED name, so a bare registration has
		// to be qualified the way the runner itself resolves it — through its
		// imports. Guessing `unit.` unconditionally is what the shell did, and a
		// class imported from anywhere else then got a filter matching nothing:
		// a silent skip that class parity cannot see, because the bogus name IS
		// in the plan.
		final imported: Null<String> = imports.find(path -> path.endsWith('.$raw'));
		return imported ?? '$DEFAULT_PACKAGE.$raw';
	}

	/** `<runner>:<line>:<col>: <source>` for a registration a message has to quote. */
	private static function locate(request: ShardPlanRequest, node: QueryNode): String {
		final span: Null<Span> = node.span;
		if (span == null) return '${request.runner}: (no span) ${node.kind}';
		final pos: Position = span.lineCol(request.source);
		final end: Int = span.to < request.source.length ? span.to : request.source.length;
		final raw: String = request.source.substring(span.from, end).replace('\n', ' ').replace('\t', ' ');
		final text: String = raw.length > QUOTE_LIMIT ? '${raw.substr(0, QUOTE_LIMIT)}…' : raw;
		return '${request.runner}:${pos.line}:${pos.col}: $text';
	}

	/**
	 * Is `name` a plain identifier, or a dot-joined run of them?
	 *
	 * Also the reason no quote, `$`, backtick or newline can reach the shell's
	 * `APQ_TEST=` value — check that before relaxing the pattern.
	 *
	 * Built per call on purpose: `EReg` carries mutable match state, so a
	 * shared static instance would be exactly the global mutable state
	 * invariant 1 forbids.
	 */
	private static function isDottedIdentifier(name: String): Bool {
		return new EReg('^[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)*$', '').match(name);
	}

	/** Sorted input in, sorted input without adjacent repeats out. */
	private static function dedupe(sorted: Array<String>): Array<String> {
		final out: Array<String> = [];
		for (name in sorted) if (out.length == 0 || out[out.length - 1] != name) out.push(name);
		return out;
	}

	/** Every ordered pair where one filter string also selects another class. */
	private static function findCollisions(names: Array<String>): Array<String> {
		return [for (i in 0...names.length) for (j in 0...names.length) if (
			i != j && names[j].indexOf(names[i]) >= 0
		) '${names[i]} is a substring of ${names[j]}'];
	}

	/** Sticky group onto shard 0 as one block, then greedy longest-processing-time-first. */
	private static function deal(names: Array<String>, shards: Int): Array<ShardPlacement> {
		final entries: Array<ShardEntry> = [
			for (name in names) { sticky: STICKY_CLASSES.contains(name), weight: weightOf(name), cls: name }
		];
		entries.sort(compareEntries);

		final load: Array<Int> = [for (s in 0...shards) 0];
		final out: Array<ShardPlacement> = [];
		for (entry in entries) {
			var target: Int = 0;
			if (!entry.sticky) for (s in 1...shards) if (load[s] < load[target]) target = s;
			load[target] += entry.weight;
			out.push({ shard: target, cls: entry.cls });
		}
		return out;
	}

	/** Sticky first at any weight, then heaviest first, then by name. */
	private static function compareEntries(a: ShardEntry, b: ShardEntry): Int {
		return if (a.sticky != b.sticky)
			a.sticky ? -1 : 1
		else if (a.weight != b.weight)
			a.weight > b.weight ? -1 : 1
		else
			compareNames(a.cls, b.cls);
	}

	/** The measured weight of `name`, or the flat-tail default. */
	private static function weightOf(name: String): Int {
		final measured: Null<Int> = CLASS_WEIGHTS[name];
		return measured ?? DEFAULT_WEIGHT;
	}

	/**
	 * The plan's own post-conditions. Returns the refusal text, or null when
	 * the plan is sound.
	 *
	 * Two of them are STRUCTURAL: `deal` pushes exactly once per input, so the
	 * count and the set comparison cannot fail as it is written today. They
	 * stay as the contract any future scheduler still owes, not as live gates,
	 * and they cost one sort. The three that ARE live are the ones `deal` can
	 * break on its own: a shard index out of range, a pinned class off shard 0,
	 * and a shard nothing was dealt to.
	 */
	private static function checkParity(expected: Array<String>, placements: Array<ShardPlacement>, shards: Int): Null<String> {
		final placed: Array<String> = [for (p in placements) p.cls];
		placed.sort(compareNames);
		final placedUnique: Array<String> = dedupe(placed);
		if (placed.length != expected.length || placedUnique.length != expected.length)
			return
				'${TAG}PARITY FAIL — ${expected.length} registered classes, ${placed.length} placements, ${placedUnique.length} distinct';
		for (i in 0...expected.length) if (placedUnique[i] != expected[i])
			return '${TAG}PARITY FAIL — the shard plan does not cover the registered class list (${expected[i]} vs ${placedUnique[i]})';
		for (p in placements) {
			if (p.shard < 0 || p.shard >= shards) return '${TAG}PARITY FAIL — ${p.cls} placed on shard ${p.shard} of $shards';
			if (p.shard != 0 && STICKY_CLASSES.contains(p.cls))
				return '${TAG}PARITY FAIL — pinned ${p.cls} landed on shard ${p.shard}, not 0';
		}
		for (s in 0...shards) {
			final count: Int = placements.count(p -> p.shard == s);
			// An empty APQ_TEST match makes the runner exit 1, so an empty
			// shard is a hard error rather than a wasted process.
			if (count == 0) return '${TAG}shard $s is empty — reduce --shards below $shards';
		}
		return null;
	}

	/**
	 * Base-character rank: `_` then `.` then digits then letters, upper and
	 * lower folded together. Anything outside a qualified Haxe identifier
	 * ranks after all of them, by code point, so the order stays total.
	 */
	private static function primaryWeight(code: Int): Int {
		return if (code == '_'.code)
			RANK_UNDERSCORE
		else if (code == '.'.code)
			RANK_DOT
		else if (code >= '0'.code && code <= '9'.code)
			RANK_DIGIT + (code - '0'.code)
		else if (code >= 'a'.code && code <= 'z'.code)
			RANK_LETTER + (code - 'a'.code)
		else if (code >= 'A'.code && code <= 'Z'.code)
			RANK_LETTER + (code - 'A'.code)
		else
			RANK_OTHER + code;
	}

	/** The tiebreak once primaries agree: lowercase sorts before uppercase. */
	private static function caseWeight(code: Int): Int {
		return code >= 'A'.code && code <= 'Z'.code ? 1 : 0;
	}

}
