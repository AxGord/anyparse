package anyparse.query;

import anyparse.query.StdlibDupScan.CandidateParam;
import anyparse.query.StdlibDupScan.StdlibCandidate;
import haxe.Exception;

using Lambda;
using StringTools;

#if nodejs
import js.node.ChildProcess.ChildProcessSpawnSyncResult;
#end

/**
 * One entry of the stdlib pool: the call a candidate might be a hand-rolled copy of. `params` is
 * the slot types in call order; for an `instance` entry slot 0 is the RECEIVER, and a `property`
 * entry has that receiver as its only slot and emits no parentheses.
 */
typedef StdlibFn = {
	final id: String;
	final ret: String;
	final params: Array<String>;
	final instance: Bool;
	final property: Bool;
	final markers: Array<String>;
};

/**
 * One filling of a pool entry's slots. `code` is what the probe program calls (over the generated
 * binder names `a0`, `a1`, ...); `display` is the same call written with the candidate's own
 * parameter names, which is what a report shows a human.
 */
typedef Mapping = {
	final fn: StdlibFn;
	final code: String;
	final display: String;
};

/** What one differential run decided about a candidate. */
enum DifferentialOutcome {
	Matched(hits: Array<Mapping>, inputs: Int);
	NoMatch(inputs: Int, mappings: Int);
	Skipped(reason: String);
}

/**
 * The DIFFERENTIAL HARNESS behind `apq stdlib-dup`: given a candidate from `StdlibDupScan`, it
 * enumerates every stdlib call the candidate could be equivalent to, generates ONE Haxe program
 * that runs both forms over a value grid, and reports the mappings that never disagreed.
 *
 * ## Why the search is finite
 *
 * The naive framing ("is this function some stdlib function?") is unbounded. Four bounds make it
 * a small search:
 *
 * 1. The pool is indexed by RETURN TYPE, and each bucket holds at most a few dozen entries.
 * 2. Arity is capped at three by the candidate filter, on both sides.
 * 3. Each slot's argument pool is TYPE-FILTERED: only an argument whose type (after one of the
 *    fixed coercions) equals the slot type is tried. This is what collapses the enumeration --
 *    for `padDigit(i: Int, digits: Int): String` against `lpad(String, String, Int)` the two
 *    string slots draw from four spellings and the `Int` slot from two, so the whole entry
 *    contributes 32 mappings, not thousands.
 * 4. The constants come from the CANDIDATE'S OWN BODY (`StdlibDupScan` lifts them), never from an
 *    invented set. A zero-pad loop supplies exactly `'0'`.
 *
 * A mapping must also USE EVERY CANDIDATE PARAMETER at least once. A mapping that drops one is
 * describing a different function, and admitting it multiplies the search for no gain.
 *
 * ## The one coercion that matters
 *
 * `Int -> String` by interpolation (`i` becomes `'$i'`). It is the adapter the motivating case
 * needs and the reason a same-signature differential misses that case entirely. `Int -> Float` is
 * carried too because Haxe already performs it. Nothing else is invented: an adapter the harness
 * cannot name is an adapter a reader would not accept in a report either.
 *
 * ## The verdict, and what it is not
 *
 * Agreement over the grid is EVIDENCE, not proof -- the grid is finite and a divergence can live
 * outside it. That is exactly why the finding level is Info and why nothing here writes an edit:
 * the output is "this looks like `StringTools.lpad`, check it". A rewrite that a project should
 * apply automatically needs a per-idiom recognizer with a proved gate, which is what
 * `prefer-lpad` is.
 *
 * ## Compilation is the terminal self-containment proof
 *
 * The generated program contains the candidate VERBATIM in a module holding nothing else. If the
 * candidate reads project code, the compile fails and the run reports `Skipped` -- so the scan's
 * name-level self-containment gate only has to be a cheap prefilter, never the guarantee.
 */
@:nullSafety(Strict)
final class StdlibDifferential {

	/** The class name the generated probe module declares; a candidate of this name is skipped. */
	public static inline final PROBE_CLASS: String = 'Probe';

	/** Beyond this the enumeration stops being worth generating; such a candidate is skipped. */
	public static inline final MAX_MAPPINGS: Int = 4000;

	/**
	 * The pool id every TRIVIAL baseline carries. A candidate that agrees with one of these across
	 * the whole grid returns an argument -- or a body constant -- unchanged, and is therefore not a
	 * reimplementation of anything: it is a setter, an accessor, or a guard whose interesting
	 * behaviour lies outside the grid. Measured on a real 806-file tree: WITHOUT this gate five
	 * such functions produced 55 of 161 findings, each agreeing with a fistful of identity-shaped
	 * stdlib calls at once (`urlDecode`, `htmlEscape`, `htmlUnescape`, `Std.string`,
	 * `replace(v, v, v)`) for one and the same reason.
	 */
	public static inline final TRIVIAL_ID: String = '(unchanged)';

	/**
	 * How many values one parameter is driven over, by the candidate's arity. The product is what
	 * the probe actually runs, so the cap shrinks as the arity grows -- one parameter gets a wide
	 * grid, three get a narrow one, and neither run takes more than seconds.
	 */
	private static final GRID_CAP_BY_ARITY: Array<Int> = [36, 36, 22, 14];

	/** Identifiers the generated program owns; a candidate carrying one of these names is skipped. */
	private static final RESERVED_NAMES: Array<String> = ['Probe', 'main', 'live', '__apqEval', '__apqBase'];

	/**
	 * The stdlib surface, indexed by return type at lookup time. Deterministic, side-effect-free,
	 * primitive-signature members only: an entry whose behaviour depends on anything but its
	 * arguments could never be confirmed by a differential, and one taking a non-primitive could
	 * never be fed by a candidate the filter admits. `Std.string` takes `Any`, the one slot type
	 * every argument fits.
	 */
	private static final POOL: Array<StdlibFn> = [
		fn('StringTools.lpad', 'String', ['String', 'String', 'Int']),
		fn('StringTools.rpad', 'String', ['String', 'String', 'Int']),
		fn('StringTools.replace', 'String', ['String', 'String', 'String']),
		fn('StringTools.trim', 'String', ['String']),
		fn('StringTools.ltrim', 'String', ['String']),
		fn('StringTools.rtrim', 'String', ['String']),
		fn('StringTools.hex', 'String', ['Int']),
		fn('StringTools.hex', 'String', ['Int', 'Int']),
		fn('StringTools.urlEncode', 'String', ['String']),
		fn('StringTools.urlDecode', 'String', ['String']),
		fn('StringTools.htmlEscape', 'String', ['String']),
		fn('StringTools.htmlUnescape', 'String', ['String']),
		fn('Std.string', 'String', ['Any']),
		fn('String.fromCharCode', 'String', ['Int']),
		method('String.toUpperCase', 'String', ['String']),
		method('String.toLowerCase', 'String', ['String']),
		method('String.charAt', 'String', ['String', 'Int']),
		method('String.substr', 'String', ['String', 'Int']),
		method('String.substr', 'String', ['String', 'Int', 'Int']),
		method('String.substring', 'String', ['String', 'Int']),
		method('String.substring', 'String', ['String', 'Int', 'Int']),
		fn('Std.int', 'Int', ['Float']),
		fn('Std.parseInt', 'Int', ['String']),
		fn('Math.round', 'Int', ['Float']),
		fn('Math.floor', 'Int', ['Float']),
		fn('Math.ceil', 'Int', ['Float']),
		fn('StringTools.fastCodeAt', 'Int', ['String', 'Int']),
		property('String.length', 'Int', ['String']),
		method('String.indexOf', 'Int', ['String', 'String']),
		method('String.indexOf', 'Int', ['String', 'String', 'Int']),
		method('String.lastIndexOf', 'Int', ['String', 'String']),
		method('String.charCodeAt', 'Int', ['String', 'Int']),
		fn('Std.parseFloat', 'Float', ['String']),
		fn('Math.abs', 'Float', ['Float']),
		fn('Math.min', 'Float', ['Float', 'Float']),
		fn('Math.max', 'Float', ['Float', 'Float']),
		fn('Math.pow', 'Float', ['Float', 'Float']),
		fn('Math.sqrt', 'Float', ['Float']),
		fn('Math.fround', 'Float', ['Float']),
		fn('Math.ffloor', 'Float', ['Float']),
		fn('Math.fceil', 'Float', ['Float']),
		fn('StringTools.startsWith', 'Bool', ['String', 'String']),
		fn('StringTools.endsWith', 'Bool', ['String', 'String']),
		fn('StringTools.contains', 'Bool', ['String', 'String']),
		fn('StringTools.isSpace', 'Bool', ['String', 'Int']),
		fn('Math.isNaN', 'Bool', ['Float']),
		fn('Math.isFinite', 'Bool', ['Float'])
	];

	/** The value grid each parameter type is driven over, as the source spelling of each value. */
	private static final GRID: Map<String, Array<String>> = [
		'Int' => [
			'-1000', '-100', '-10', '-3', '-1', '0', '1', '2', '3', '5', '9', '10', '11', '99', '100', '1234'
		],
		'Float' => ['-100.5', '-1.5', '-1.0', '-0.5', '0.0', '0.5', '1.0', '1.5', '3.25', '100.5'],
		'String' => [
			"''",
			"'a'",
			"'ab'",
			"'abc'",
			"'0'",
			"'00'",
			"'007'",
			"' x '",
			"'123'",
			"'-5'",
			"'Hello'",
			"'A_b'",
			"'a/b/c.txt'",
			"'/x/y/'",
			"'name.ext'",
			"'  pad  '",
			"'a+b'",
			"'a&b'",
			"'%20z'",
			"'<i>t</i>'",
			"'A B C'",
			"'.hidden'",
			"'a\\\\b'",
			"'\"q'"
		],
		'Bool' => ['true', 'false']
	];

	/** Whether a mapping is one of the trivial baselines rather than a pooled stdlib call. */
	public static inline function isTrivial(mapping: Mapping): Bool {
		return mapping.fn.id == TRIVIAL_ID;
	}

	/**
	 * The baselines a real finding has to beat: each parameter of the return type passed straight
	 * through, and each body literal of the return type returned as-is. Empty when the candidate's
	 * return type matches neither, which is the common case and costs nothing.
	 */
	public static function trivials(candidate: StdlibCandidate): Array<Mapping> {
		final entry: StdlibFn = {
			id: TRIVIAL_ID,
			ret: candidate.returnType,
			params: [],
			instance: false,
			property: false,
			markers: []
		};
		final out: Array<Mapping> = [];
		for (index in 0...candidate.params.length) {
			final param: CandidateParam = candidate.params[index];
			if (param.type == candidate.returnType) out.push({ fn: entry, code: 'a$index', display: param.name });
		}
		for (literal in candidate.literals) if (literal.type == candidate.returnType)
			out.push({ fn: entry, code: literal.code, display: literal.code });
		return out;
	}

	/**
	 * Every stdlib call the candidate could be equivalent to, with every type-consistent filling of
	 * its slots that uses all of the candidate's parameters. A pool entry whose own spelling already
	 * occurs in the candidate's body is dropped: a function that calls `Std.parseInt` and adds a
	 * fallback is a thin WRAPPER, not a reimplementation, and reporting it is the exact false
	 * positive the name channel produced.
	 */
	public static function mappings(candidate: StdlibCandidate): Array<Mapping> {
		final out: Array<Mapping> = [];
		for (entry in POOL) {
			if (entry.ret != candidate.returnType) continue;
			if (mentionsAny(candidate.source, entry.markers)) continue;
			fill(entry, candidate, [], out);
			if (out.length > MAX_MAPPINGS) return out;
		}
		return out.length == 0 ? out : trivials(candidate).concat(out);
	}

	/**
	 * The whole probe module: the candidate verbatim as a static, the value grid as nested loops,
	 * and one live-flagged comparison per mapping. Pure -- a test drives it without a compiler.
	 */
	public static function program(candidate: StdlibCandidate, maps: Array<Mapping>): String {
		final buf: StringBuf = new StringBuf();
		final arity: Int = candidate.params.length;
		buf.add('using StringTools;\n\nclass ${PROBE_CLASS} {\n\n');
		buf.add('\tstatic final live: Array<Bool> = [${[for (unused in maps) 'true'].join(', ')}];\n\n');
		buf.add('\tstatic var inputs: Int = 0;\n\n');
		buf.add("\tstatic var constant: String = '';\n\n");
		buf.add('\tstatic var varying: Bool = false;\n\n');
		buf.add('\tstatic ${candidate.source}\n\n');
		buf.add('\tstatic function main(): Void {\n');
		for (slot in 0...arity) {
			final values: Array<String> = grid(candidate, candidate.params[slot].type);
			buf.add('${tabs(slot + 2)}for (a$slot in [${values.join(', ')}]) {\n');
		}
		final args: String = [for (slot in 0...arity) 'a$slot'].join(', ');
		final body: String = tabs(arity + 2);
		buf.add('${body}inputs++;\n');
		buf.add('${body}final base: String = __apqEval(() -> ${candidate.name}($args));\n');
		buf.add('${body}if (inputs == 1) constant = base else if (base != constant) varying = true;\n');
		for (index in 0...maps.length)
			buf.add('${body}if (live[$index] && __apqEval(() -> ${maps[index].code}) != base) live[$index] = false;\n');
		for (slot in 0...arity) buf.add('${tabs(arity + 1 - slot)}}\n');
		buf.add("\t\tSys.println('INPUTS ' + inputs);\n");
		buf.add("\t\tif (!varying) Sys.println('CONSTANT');\n");
		buf.add("\t\tfor (index in 0...live.length) if (live[index]) Sys.println('MATCH ' + index);\n");
		buf.add('\t}\n\n');
		buf.add('\tstatic function __apqEval(produce: () -> Dynamic): String {\n');
		buf.add("\t\ttry return 'V' + Std.string(produce()) catch (exception: Dynamic) return 'E';\n");
		buf.add('\t}\n\n}\n');
		return buf.toString();
	}

	/** The mapping indices and input count a finished probe run printed. */
	public static function verdict(stdout: String, maps: Array<Mapping>): DifferentialOutcome {
		var inputs: Int = 0;
		final hits: Array<Mapping> = [];
		for (line in stdout.split('\n')) {
			final text: String = line.trim();
			if (text.startsWith('INPUTS ')) inputs = Std.parseInt(text.substr(7)) ?? 0;
			if (text == 'CONSTANT') return Skipped('constant over all $inputs generated inputs — the grid does not discriminate it');
			if (!text.startsWith('MATCH ')) continue;
			final index: Null<Int> = Std.parseInt(text.substr(6));
			if (index != null && index >= 0 && index < maps.length) hits.push(maps[index]);
		}
		return hits.length > 0 ? Matched(hits, inputs) : NoMatch(inputs, maps.length);
	}

	/** Why the harness refuses this candidate outright, or null when it will drive it. */
	public static function refusal(candidate: StdlibCandidate, maps: Array<Mapping>): Null<String> {
		return if (RESERVED_NAMES.contains(candidate.name))
			'the probe module owns the name "${candidate.name}"';
		else if (maps.length == 0)
			'no type-consistent mapping onto any pooled stdlib call';
		else if (maps.length > MAX_MAPPINGS)
			'${maps.length} mappings exceeds the ${MAX_MAPPINGS} cap';
		else
			null;
	}

	/**
	 * Generates the probe into `dir`, compiles and runs it on the Haxe interpreter, and reads back
	 * the surviving mappings. A compile failure is `Skipped` with the compiler's own text -- that
	 * is the terminal proof the candidate was not self-contained after all.
	 */
	public static function run(candidate: StdlibCandidate, maps: Array<Mapping>, dir: String): DifferentialOutcome {
		final refused: Null<String> = refusal(candidate, maps);
		if (refused != null) return Skipped(refused);
		#if (sys || nodejs)
		final path: String = '$dir/${PROBE_CLASS}.hx';
		try {
			sys.io.File.saveContent(path, program(candidate, maps));
		} catch (exception: Exception) {
			return Skipped('could not stage the probe (${exception.message})');
		}
		return interpret(dir, maps);
		#else
		return Skipped('the differential harness requires a sys or nodejs target');
		#end
	}

	/** Whether any disqualifying spelling occurs in the candidate's own text. */
	private static function mentionsAny(source: String, markers: Array<String>): Bool {
		return markers.exists(marker -> source.indexOf(marker) >= 0);
	}

	/**
	 * A static call entry: `Recv.member(...)`, disqualified by its own spelling appearing in a body.
	 * The per-parameter value list one candidate is driven over: its OWN body literals of that
	 * type first (each also affixed on both sides, so an equality can be told apart from a
	 * `startsWith` / `endsWith` / `contains` that agrees with it on the bare literal), then the
	 * fixed grid, deduplicated and capped so the cartesian product stays interpretable in seconds.
	 *
	 * Seeding from the body is the same idea that bounds the mapping search, applied to the INPUT
	 * axis: a function branching on `'.drl'` is decided by strings around `'.drl'`, and by nothing
	 * in a generic grid. Measured on a real tree: unseeded, six string predicates returned the same
	 * answer for every grid value and therefore "matched" every shape-compatible pooled call.
	 */
	private static function grid(candidate: StdlibCandidate, type: String): Array<String> {
		final values: Array<String> = [];
		inline function add(value: String): Void if (!values.contains(value)) values.push(value);
		for (literal in candidate.literals) if (literal.type == type) {
			add(literal.code);
			if (type == 'String') {
				add('\'~\' + ${literal.code}');
				add('${literal.code} + \'~\'');
			}
		}
		for (value in GRID[type] ?? []) add(value);
		final arity: Int = candidate.params.length;
		final cap: Int = arity < GRID_CAP_BY_ARITY.length ? GRID_CAP_BY_ARITY[arity] : GRID_CAP_BY_ARITY[GRID_CAP_BY_ARITY.length - 1];
		return values.length > cap ? values.slice(0, cap) : values;
	}

	/**
	 * A static-call entry. A `StringTools` static also carries its STATIC-EXTENSION spelling as a
	 * disqualifier: a body written `path.endsWith('.drl')` is already calling
	 * `StringTools.endsWith`, and reporting that back is the thin-wrapper false positive in its
	 * most convincing disguise -- the finding is literally true and completely useless.
	 */
	private static function fn(id: String, ret: String, params: Array<String>): StdlibFn {
		final markers: Array<String> = id.indexOf('StringTools.') == 0 ? [id, '.${member(id)}'] : [id];
		return {
			id: id,
			ret: ret,
			params: params,
			instance: false,
			property: false,
			markers: markers
		};
	}

	/** An instance-method entry: slot 0 is the receiver, and the disqualifying spelling is `.member`. */
	private static function method(id: String, ret: String, params: Array<String>): StdlibFn {
		return {
			id: id,
			ret: ret,
			params: params,
			instance: true,
			property: false,
			markers: ['.${member(id)}']
		};
	}

	/** An instance-property entry: slot 0 is the receiver and the call emits no parentheses. */
	private static function property(id: String, ret: String, params: Array<String>): StdlibFn {
		return {
			id: id,
			ret: ret,
			params: params,
			instance: true,
			property: true,
			markers: ['.${member(id)}']
		};
	}

	/** The member half of a pooled entry's dotted id. */
	private static function member(id: String): String {
		final dot: Int = id.lastIndexOf('.');
		return dot < 0 ? id : id.substr(dot + 1);
	}

	/**
	 * Fills `entry`'s remaining slots depth-first, appending one mapping per complete filling that
	 * uses every candidate parameter. `chosen` is the arguments picked so far, in slot order.
	 */
	private static function fill(entry: StdlibFn, candidate: StdlibCandidate, chosen: Array<Argument>, out: Array<Mapping>): Void {
		if (out.length > MAX_MAPPINGS) return;
		if (chosen.length == entry.params.length) {
			if (!coversEveryParameter(candidate, chosen)) return;
			out.push({
				fn: entry,
				code: render(entry, [for (argument in chosen) argument.code]),
				display: render(entry, [for (argument in chosen) argument.display])
			});
			return;
		}
		for (argument in pool(entry.params[chosen.length], candidate)) {
			fill(entry, candidate, chosen.concat([argument]), out);
			if (out.length > MAX_MAPPINGS) return;
		}
	}

	/** Whether every candidate parameter reaches at least one slot -- a mapping that drops one is a different function. */
	private static function coversEveryParameter(candidate: StdlibCandidate, chosen: Array<Argument>): Bool {
		for (param in candidate.params) {
			final used: Bool = chosen.exists(argument -> argument.param == param.name);
			if (!used) return false;
		}
		return true;
	}

	/**
	 * Every argument that can fill a slot of type `want`: each parameter directly, each parameter
	 * through one of the two coercions, and each body literal. Nothing else -- an argument the
	 * harness cannot name is one a reader would not accept.
	 */
	private static function pool(want: String, candidate: StdlibCandidate): Array<Argument> {
		final out: Array<Argument> = [];
		for (index in 0...candidate.params.length) {
			final param: CandidateParam = candidate.params[index];
			final binder: String = 'a$index';
			if (param.type == want || want == 'Any' || (param.type == 'Int' && want == 'Float'))
				out.push({ code: binder, display: param.name, param: param.name });
			else if (want == 'String')
				out.push({ code: '\'$$$binder\'', display: '\'$$${param.name}\'', param: param.name });
		}
		for (literal in candidate.literals) if (literal.type == want || want == 'Any' || (literal.type == 'Int' && want == 'Float'))
			out.push({ code: literal.code, display: literal.code, param: null });
		return out;
	}

	/** The call expression for `entry` over `args`, in the shape its `instance` / `property` flags demand. */
	private static function render(entry: StdlibFn, args: Array<String>): String {
		if (!entry.instance) return '${entry.id}(${args.join(', ')})';
		final receiver: String = '(${args[0]})';
		return entry.property ? '$receiver.${member(entry.id)}' : '$receiver.${member(entry.id)}(${args.slice(1).join(', ')})';
	}

	/** `count` tab characters, the generated program's indentation unit. */
	private static function tabs(count: Int): String {
		return ''.rpad('\t', count);
	}

	#if (sys || nodejs)
	/** Runs `haxe -cp <dir> --run Probe` and maps its result onto an outcome. */
	private static function interpret(dir: String, maps: Array<Mapping>): DifferentialOutcome {
		final args: Array<String> = ['-cp', dir, '--run', PROBE_CLASS];
		#if nodejs
		final res: ChildProcessSpawnSyncResult = js.node.ChildProcess.spawnSync('haxe', args, { encoding: 'utf8', timeout: 300000 });
		final launchError: Null<Dynamic> = (res.error: Dynamic);
		if (launchError != null) return Skipped('could not launch haxe (${Reflect.field(launchError, 'message')})');
		final status: Null<Int> = (res.status: Null<Int>);
		return status != 0 ? Skipped(firstLine(text(res.stderr) + text(res.stdout))) : verdict(text(res.stdout), maps);
		#else
		try {
			final process: sys.io.Process = new sys.io.Process('haxe', args);
			final out: String = process.stdout.readAll().toString();
			final err: String = process.stderr.readAll().toString();
			final code: Null<Int> = process.exitCode();
			process.close();
			return code != 0 ? Skipped(firstLine(err + out)) : verdict(out, maps);
		} catch (exception: Exception) {
			return Skipped('could not launch haxe (${exception.message})');
		}
		#end
	}

	/** The first non-empty line of a compiler transcript -- a report wants the reason, not the trace. */
	private static function firstLine(transcript: String): String {
		for (line in transcript.split('\n')) if (line.trim() != '') return line.trim();
		return 'the probe did not compile';
	}
	#end

	#if nodejs
	/** Coerce a possibly-null spawn stream field (Buffer|String under utf8) to a String. */
	private static function text(value: Dynamic): String {
		return value == null ? '' : '$value';
	}
	#end

}

/** One filling of one slot: what the probe writes, what a report writes, and which parameter it consumed. */
private typedef Argument = {
	final code: String;
	final display: String;
	final param: Null<String>;
};
