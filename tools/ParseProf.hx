import anyparse.check.Check.Violation;
import anyparse.check.Linter;
import anyparse.grammar.haxe.HaxeFormat;
import anyparse.grammar.haxe.HaxeFormatConfigLoader;
import anyparse.grammar.haxe.HaxeModuleTriviaParser;
import anyparse.grammar.haxe.HaxeModuleTriviaWriter;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.grammar.haxe.HxModuleWriteOptions;
import anyparse.query.FormatConfigDiscovery;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;

using StringTools;

/**
 * One source file, read once and reused by every workload.
 */
typedef Src = {
	var file: String;
	var source: String;
}

/**
 * Fast-parse / writer profiling and A-B harness for the anyparse core.
 *
 * Built straight out of `src/`, like `tools/JvmPortability.hx`, and deliberately
 * portable except for one js-only clock: `haxe.Timer.stamp()` on js resolves to
 * milliseconds and a single file parses in about one, so per-file numbers need
 * `performance.now()`.
 *
 * Build and run:
 *
 * ```sh
 * haxe tools/parse-prof.hxml                       # -> bin/parse-prof.js
 * node bin/parse-prof.js tparse src 1 hxformat.json
 * node --cpu-prof --cpu-prof-interval=200 bin/parse-prof.js tparse src 1 hxformat.json
 * TM_SRC=<other-tree>/src node bin/parse-prof.js rt tools/bench-corpus.txt 6 hxformat.json
 * ```
 *
 * Arguments are `<mode> <dir-or-manifest> [reps] [hxformat.json]`. A directory is
 * walked recursively for `.hx`; anything else is read as a manifest, one path per
 * line, `#` comments skipped and `${NAME}` expanded from the environment.
 *
 * Modes:
 *
 * - `read` — read every file, no parse: the IO floor.
 * - `tparse` — `HaxeModuleTriviaParser.parse` only: the Fast-mode parser.
 * - `walk` — `GrammarPlugin.parseFile`: parse plus the `QueryNode` projection.
 * - `write` — `HaxeModuleTriviaWriter.write` over PRE-parsed trees: the writer
 *   alone. The parse that feeds it is subtracted from the reported time.
 * - `rt` — `GrammarPlugin.writeRoundTrip`: parse plus write plus the comment and
 *   formatter-off guards, i.e. exactly what `hxq fmt` runs.
 * - `lint` — `Linter.run` over the whole set with every builtin check.
 * - `perfile` — one TSV row per file: bytes, lines, parse and round-trip
 *   microseconds, node count and a node-kind census. Feeds corpus stratification.
 *
 * Each workload runs inside its own named `phaseXxx` function so a V8 `--cpu-prof`
 * tree can be attributed by nearest phase ancestor.
 *
 * Measurement hygiene lives in `tools/bench-ab.sh`: measured runs are sequential
 * and interleaved, and the median is what counts.
 */
final class ParseProf {

	/** Microseconds in a second: per-file costs are reported in microseconds. */
	private static inline final US_PER_SECOND: Float = 1000000;

	/** Milliseconds in a second, for the js high-resolution clock. */
	private static inline final MS_PER_SECOND: Float = 1000.0;

	/** Round milliseconds to two decimals: scale up, round, scale back down. */
	private static inline final MS_ROUND_SCALE: Float = 100000;

	private static inline final MS_ROUND_DIVISOR: Float = 100;

	/** `\n`, counted to report a file's line count. */
	private static inline final NEWLINE: Int = 10;

	/** Seconds spent in untimed setup (`preparse`), subtracted from the phase total. */
	private static var excluded: Float = 0;

	public static function main(): Void {
		final args: Array<String> = Sys.args();
		final mode: String = args.length > 0 ? args[0] : 'tparse';
		final target: String = args.length > 1 ? args[1] : 'src';
		final reps: Int = args.length > 2 ? (Std.parseInt(args[2]) ?? 1) : 1;
		final config: Null<String> = args.length > 3 ? args[3] : null;
		final files: Array<String> = resolveTargets(target);
		final sources: Array<Src> = [for (f in files) { file: f, source: sys.io.File.getContent(f) }];
		var bytes: Int = 0;
		for (s in sources) bytes += s.source.length;
		final optsJson: Null<String> = config != null && sys.FileSystem.exists(config) ? sys.io.File.getContent(config) : null;
		final plugin: GrammarPlugin = new HaxeQueryPlugin();
		final t0: Float = now();
		final tally: String = switch mode {
			case 'read': 'noop=1';
			case 'tparse': phaseParse(sources, reps);
			case 'walk': phaseWalk(plugin, sources, reps);
			case 'write': phaseWrite(sources, optsJson, reps);
			case 'rt': phaseRt(plugin, sources, optsJson, reps);
			case 'lint': phaseLint(plugin, sources, reps);
			case 'perfile': phasePerFile(plugin, sources, optsJson, reps);
			case _: 'unknown-mode=$mode';
		}
		final elapsed: Float = now() - t0 - excluded;
		Sys.println('MODE=$mode files=${sources.length} reps=$reps bytes=$bytes ms=${ms(elapsed)} msPerRep=${ms(elapsed / reps)} $tally');
	}

	// ------------------------------------------------------------- workloads

	/** The Fast-mode parser and nothing else. */
	private static function phaseParse(sources: Array<Src>, reps: Int): String {
		var failed: Int = 0;
		var ok: Int = 0;
		for (r in 0...reps) {
			for (s in sources) {
				try {
					final tree: Any = HaxeModuleTriviaParser.parse(s.source);
					if (tree != null) ok++;
				} catch (exception: haxe.Exception)
					failed++;
			}
		}
		return 'parsed=$ok parseFail=$failed';
	}

	/** Parse plus the generated walker projection into `QueryNode`. */
	private static function phaseWalk(plugin: GrammarPlugin, sources: Array<Src>, reps: Int): String {
		var failed: Int = 0;
		var roots: Int = 0;
		for (r in 0...reps) {
			for (s in sources) {
				try {
					final tree: QueryNode = plugin.parseFile(s.source);
					roots += tree.children.length;
				} catch (exception: haxe.Exception)
					failed++;
			}
		}
		return 'rootChildren=$roots parseFail=$failed';
	}

	/** The writer alone: trees are parsed once up front, outside the timed loop. */
	private static function phaseWrite(sources: Array<Src>, optsJson: Null<String>, reps: Int): String {
		final trees: Array<Any> = preparse(sources);
		final opts: HxModuleWriteOptions = writeOptionsOf(optsJson);
		var written: Int = 0;
		var outBytes: Int = 0;
		for (r in 0...reps) {
			for (tree in trees) if (tree != null) {
				final emitted: Null<String> = HaxeModuleTriviaWriter.write(tree, opts);
				if (emitted != null) {
					written++;
					outBytes += emitted.length;
				}
			}
		}
		return 'written=$written outBytes=$outBytes';
	}

	/** The whole round trip the formatter actually runs. */
	private static function phaseRt(plugin: GrammarPlugin, sources: Array<Src>, optsJson: Null<String>, reps: Int): String {
		var written: Int = 0;
		var threw: Int = 0;
		var equal: Int = 0;
		for (r in 0...reps) {
			for (s in sources) {
				try {
					final out: Null<String> = plugin.writeRoundTrip(s.source, optsJson);
					if (out != null) {
						written++;
						if (out == s.source) equal++;
					}
				} catch (exception: haxe.Exception)
					threw++;
			}
		}
		return 'written=$written equal=$equal threw=$threw';
	}

	/** Every builtin check over the whole set. */
	private static function phaseLint(plugin: GrammarPlugin, sources: Array<Src>, reps: Int): String {
		var found: Int = 0;
		for (r in 0...reps) {
			final violations: Array<Violation> = Linter.run(sources, plugin);
			found = violations.length;
		}
		return 'violations=$found';
	}

	/** One TSV row per file: bytes, parse microseconds, round-trip microseconds. */
	private static function phasePerFile(plugin: GrammarPlugin, sources: Array<Src>, optsJson: Null<String>, reps: Int): String {
		Sys.println('file\tbytes\tlines\tparseUs\trtUs\tnodes\tcond\tmeta\tstr\tfn\ttype');
		// Warm the JIT over the whole set first: without it the first files carry the
		// tier-up cost and read an order of magnitude slower than the same file later.
		for (w in 0...2) for (s in sources) {
			try HaxeModuleTriviaParser.parse(s.source) catch (exception: haxe.Exception) {}
			try plugin.writeRoundTrip(s.source, optsJson) catch (exception: haxe.Exception) {}
		}
		for (s in sources) {
			var parseUs: Float = 0;
			var rtUs: Float = 0;
			var nodes: Int = 0;
			for (r in 0...reps) {
				final p0: Float = now();
				try HaxeModuleTriviaParser.parse(s.source) catch (exception: haxe.Exception) {}
				parseUs += (now() - p0) * US_PER_SECOND;
				final w0: Float = now();
				try plugin.writeRoundTrip(s.source, optsJson) catch (exception: haxe.Exception) {}
				rtUs += (now() - w0) * US_PER_SECOND;
			}
			final kinds: Map<String, Int> = [];
			try {
				final tree: QueryNode = plugin.parseFile(s.source);
				nodes = count(tree);
				tally(tree, kinds);
			} catch (exception: haxe.Exception)
				nodes = -1;
			Sys.println(
				'${s.file}\t${s.source.length}\t${lineCount(s.source)}\t${Math.round(parseUs / reps)}\t${Math.round(rtUs / reps)}\t$nodes'
				+ '\t${group(kinds, ['Conditional'])}\t${group(kinds, ['Meta', 'MetaCall', 'MetaStmt', 'MetaExpr'])}\t'
				+ '${group(kinds, ['DoubleStringExpr', 'SingleStringExpr', 'StringExpr', 'InterpStringExpr'])}\t'
				+ '${group(kinds, ['FnMember', 'FnDecl'])}\t' + group(kinds, [
					'ClassDecl',
					'ClassForm',
					'InterfaceDecl',
					'EnumDecl',
					'TypedefDecl',
					'AbstractDecl',
					'EnumAbstractDecl'
				])
			);
		}
		return 'rows=${sources.length}';
	}

	// --------------------------------------------------------------- support

	/** Parses every source once, untimed, so the writer phase measures only writing. */
	private static function preparse(sources: Array<Src>): Array<Any> {
		final p0: Float = now();
		final trees: Array<Any> = [
			for (s in sources) {
				var tree: Any = null;
				try tree = HaxeModuleTriviaParser.parse(s.source) catch (exception: haxe.Exception) {}
				tree;
			}
		];
		excluded += now() - p0;
		return trees;
	}

	/** Mirrors `HaxeQueryPlugin.writeOptionsOf`, which is private. */
	private static function writeOptionsOf(optsJson: Null<String>): HxModuleWriteOptions {
		final stated: Null<String> = FormatConfigDiscovery.normalize(optsJson);
		return stated == null ? HaxeFormat.instance.defaultWriteOptions : HaxeFormatConfigLoader.loadHxFormatJson(stated);
	}

	private static function count(node: QueryNode): Int {
		var n: Int = 1;
		for (c in node.children) n += count(c);
		return n;
	}

	/** Node-kind histogram of a projected tree, for corpus stratification. */
	private static function tally(node: QueryNode, into: Map<String, Int>): Void {
		into[node.kind] = (into.exists(node.kind) ? into[node.kind] : 0) + 1;
		for (c in node.children) tally(c, into);
	}

	/** Sum of the histogram over a group of kinds. */
	private static function group(kinds: Map<String, Int>, names: Array<String>): Int {
		var n: Int = 0;
		for (k in names) if (kinds.exists(k)) n += kinds[k];
		return n;
	}

	private static function lineCount(source: String): Int {
		var n: Int = 1;
		for (i in 0...source.length) if (source.charCodeAt(i) == NEWLINE) n++;
		return n;
	}

	/**
	 * A directory is walked recursively for `.hx`; anything else is read as a
	 * manifest with one path per line (blank lines and `#` comments skipped).
	 */
	private static function resolveTargets(target: String): Array<String> {
		final out: Array<String> = [];
		if (sys.FileSystem.isDirectory(target)) {
			collect(target, out);
			out.sort((a, b) -> a < b ? -1 : (a > b ? 1 : 0));
			return out;
		}
		for (line in sys.io.File.getContent(target).split('\n')) {
			final path: String = expandEnv(line.trim());
			if (path == '' || path.startsWith('#')) continue;
			out.push(path);
		}
		return out;
	}

	/**
	 * Substitutes `${NAME}` from the environment in a manifest line, and drops
	 * the line (empty result) when the variable is unset. The calibrated corpus
	 * spans two trees and only one of them lives in this repository, so the
	 * external half is written `${TM_SRC}/...` and simply disappears for anyone
	 * who has not exported it - a manifest that half-resolves is still a usable
	 * corpus, a manifest that dies on a missing checkout is not.
	 */
	private static function expandEnv(line: String): String {
		// Double-quoted on purpose: `'${'` opens an interpolation and does not compile.
		if (line.indexOf("${") < 0) return line;
		var out: String = line;
		while (true) {
			final open: Int = out.indexOf("${");
			if (open < 0) break;
			final close: Int = out.indexOf('}', open);
			if (close < 0) break;
			final name: String = out.substring(open + 2, close);
			final value: Null<String> = Sys.getEnv(name);
			if (value == null) {
				Sys.stderr().writeString('ParseProf: env $name is unset, skipping $line\n');
				return '';
			}
			out = out.substring(0, open) + value + out.substring(close + 1);
		}
		return out;
	}

	private static function collect(dir: String, out: Array<String>): Void {
		for (name in sys.FileSystem.readDirectory(dir)) {
			final path: String = '$dir/$name';
			if (sys.FileSystem.isDirectory(path))
				collect(path, out)
			else if (haxe.io.Path.extension(name) == 'hx')
				out.push(path);
		}
	}

	/** Milliseconds, two decimals, from a seconds-valued duration. */
	private static function ms(seconds: Float): String {
		return '${Math.round(seconds * MS_ROUND_SCALE) / MS_ROUND_DIVISOR}';
	}

	/** Seconds, but from a monotonic microsecond-resolution clock on js. */
	private static function now(): Float {
		#if js
		return (cast js.Syntax.code('performance.now()'): Float) / MS_PER_SECOND;
		#else
		return haxe.Timer.stamp();
		#end
	}

}
