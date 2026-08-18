/** One `callFrame` of a V8 `--cpu-prof` capture. */
typedef ProfileFrame = {
	var functionName: Null<String>;
	var url: Null<String>;
};

/** One node of the capture's call tree. */
typedef ProfileNode = {
	var id: Int;
	var callFrame: ProfileFrame;
	var children: Null<Array<Int>>;
};

/**
 * The subset of a `.cpuprofile` this tool reads. `haxe.Json.parse` answers
 * `Dynamic`, which unifies with this — so the boundary is typed at the one
 * place it enters, and nothing downstream is `Dynamic`.
 */
typedef Profile = {
	var nodes: Array<ProfileNode>;
	var samples: Array<Int>;
	var timeDeltas: Array<Float>;
};

/**
 * Roll a V8 `--cpu-prof` capture up by SELF time per function.
 *
 * ```sh
 * node --cpu-prof --cpu-prof-dir=/tmp/prof --cpu-prof-interval=200 bin/parse-prof.js tparse tools/bench-corpus.txt 2 hxformat.json
 * haxe -cp tools --run ProfTop /tmp/prof/*.cpuprofile 20 [--under <fn>]
 * ```
 *
 * No build: it is a `--run` script over the std library, the tier the language
 * policy puts standalone logic in. `--interp` would NOT work — it consumes the
 * trailing arguments as its own.
 *
 * Self time is summed from `samples` + `timeDeltas` rather than `hitCount`, so a
 * capture whose sampling interval was overridden still reports real
 * microseconds. `--under <fn>` restricts the rollup to samples whose stack
 * passes through a frame of that name — the way to attribute one phase of a
 * harness that runs several in one process. It matches the RENDERED row label
 * (`functionName  [file]`), not a Haxe type name: class names do not survive
 * into JS frame names, so `--under CompilerServer` matches nothing while
 * `--under phaseWrite` works.
 *
 * READ `spawnSync` AND FRIENDS AS BLOCKED WAIT, NOT CPU. A profile samples the
 * frame that is on the stack, and a synchronous child-process call sits there
 * for the whole child's lifetime — so `spawnSync` at 54.6% means "we waited on
 * children for 54.6% of the run". That is exactly the finding worth having, but
 * it is not our CPU and it does not shrink by optimising our code. That reading
 * produced the two largest wins of 2026-08-18 — the warm compiler server bought
 * nothing, and a single-file lint was paying for a project-wide typecheck;
 * misreading it as CPU would have sent the work into the analyser instead.
 *
 * Read the profile for SHARES and measure deltas with a separate unprofiled
 * run: `--cpu-prof` overhead is not uniform (+7% on anyparse, +15% on the TM
 * tree), so a profiled before/after pair is not a delta.
 */
class ProfTop {

	/** Rows printed when the caller names no count. */
	private static inline final DEFAULT_TOP: Int = 25;

	/** Stack-walk bound for `--under`, so a cyclic parent map cannot hang the run. */
	private static inline final MAX_STACK_HOPS: Int = 4096;

	/** One decimal place, the precision every printed number here carries. */
	private static inline final ROUND_SCALE: Float = 10;

	/** `timeDeltas` are microseconds; every printed duration is milliseconds. */
	private static inline final US_PER_MS: Float = 1000;

	private static inline final PERCENT: Float = 100;

	/** Column widths, chosen so the two numeric columns stay aligned. */
	private static inline final PCT_WIDTH: Int = 6;

	private static inline final MS_WIDTH: Int = 9;

	public static function main(): Void {
		final args: Array<String> = Sys.args();
		if (args.length < 1) {
			Sys.println('usage: ProfTop <file.cpuprofile> [topN] [--under <fn>]');
			Sys.exit(2);
			return;
		}
		var top: Int = DEFAULT_TOP;
		var under: String = '';
		var i: Int = 1;
		while (i < args.length) {
			switch args[i] {
				case '--under':
					under = i + 1 < args.length ? args[++i] : '';
				case arg:
					final n: Null<Int> = Std.parseInt(arg);
					if (n != null) top = n;
			}
			i++;
		}
		report(args[0], top, under);
	}

	/** Parse one capture, roll it up, print the top `top` rows by self time. */
	private static function report(path: String, top: Int, under: String): Void {
		final profile: Profile = haxe.Json.parse(sys.io.File.getContent(path));
		final labelOf: Map<Int, String> = [];
		final parentOf: Map<Int, Int> = [];
		for (node in profile.nodes) {
			labelOf[node.id] = label(node.callFrame);
			final children: Null<Array<Int>> = node.children;
			if (children != null) for (child in children) parentOf[child] = node.id;
		}
		final samples: Array<Int> = profile.samples;
		final deltas: Array<Float> = profile.timeDeltas;
		final self: Map<String, Float> = [];
		var total: Float = 0;
		for (s in 0...samples.length) {
			final delta: Float = s < deltas.length ? deltas[s] : 0;
			if (delta <= 0) continue;
			final id: Int = samples[s];
			if (under != '' && !passesThrough(id, under, labelOf, parentOf)) continue;
			final key: String = labelOf.exists(id) ? labelOf[id] : '(unknown $id)';
			self[key] = (self.exists(key) ? self[key] : 0.0) + delta;
			total += delta;
		}
		final rows: Array<{ label: String, us: Float }> = [for (key => us in self) { label: key, us: us }];
		rows.sort((a, b) -> b.us > a.us ? 1 : (b.us < a.us ? -1 : 0));
		final scope: String = under == '' ? '' : ' (under $under)';
		Sys.println('total ${round(total / US_PER_MS)} ms across ${samples.length} samples$scope');
		final shown: Int = rows.length < top ? rows.length : top;
		for (r in 0...shown) {
			final row: { label: String, us: Float } = rows[r];
			final pct: Float = total > 0 ? row.us * PERCENT / total : 0;
			Sys.println('  ${pad(round(pct), PCT_WIDTH)}%  ${pad(round(row.us / US_PER_MS), MS_WIDTH)} ms  ${row.label}');
		}
	}

	/** `name  [file]` — the row label, and what `--under` matches against. */
	private static function label(frame: ProfileFrame): String {
		final name: Null<String> = frame.functionName;
		final shown: String = name == null || name == '' ? '(anonymous)' : name;
		final url: Null<String> = frame.url;
		if (url == null || url == '') return shown;
		final slash: Int = url.lastIndexOf('/');
		final file: String = slash >= 0 ? url.substr(slash + 1) : url;
		return file == '' ? shown : '$shown  [$file]';
	}

	/** Does the stack above `id` carry a frame whose label contains `want`? */
	private static function passesThrough(id: Int, want: String, labelOf: Map<Int, String>, parentOf: Map<Int, Int>): Bool {
		var current: Int = id;
		var hops: Int = 0;
		while (hops++ < MAX_STACK_HOPS) {
			final name: String = labelOf.exists(current) ? labelOf[current] : '';
			if (name.indexOf(want) >= 0) return true;
			if (!parentOf.exists(current)) return false;
			current = parentOf[current];
		}
		return false;
	}

	private static function round(value: Float): String {
		return '${Math.round(value * ROUND_SCALE) / ROUND_SCALE}';
	}

	private static function pad(text: String, width: Int): String {
		var out: String = text;
		while (out.length < width) out = ' $out';
		return out;
	}

}
