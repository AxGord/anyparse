package dev;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.IndexScope;
import anyparse.query.ShardPlan;
import anyparse.query.SymbolIndex;
import dev.ArmRegistry.ArmRecord;
import dev.GateTree.ChangedPaths;
import devkit.Args;
import devkit.Cmd.cmd;
import devkit.Result;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * The one answer to "which test classes does a diff need": a touched module reaches every file whose text names it (an
 * import, a qualified path, a simple name in its package or one below, a build output that runs it) and the test classes among them run;
 * a touch no text dependency bounds runs every class.
 */
@:nullSafety(Strict)
final class SuiteImpact {

	public static inline final USAGE: String =
		'usage: dev suite-impact [<base>[..<tip>]] [--list | --why <class>] [--repo <dir>] | --census <N> [--weights <tsv>] [--repo <dir>] | --arm-census [--repo <dir>]';

	/** The macros, which build code no text of the module they build ever names. */
	public static inline final MACROS: String = 'src/anyparse/macro/';

	/** The build output the suite runs as: its main module is the runner every test class runs inside. */
	public static inline final SUITE_OUTPUT: String = 'test.js';

	/** The call that sets an environment variable: it reaches the next class only through a key some file reads. */
	public static inline final ENV_WRITER: String = 'Sys.putEnv';

	/** The classpath roots, a nested root before the one holding it so a file takes its own package. */
	public static final ROOTS: Array<String> = ['tools/src', 'src', 'test'];

	/**
	 * The roots from the bottom layer up: code depends only on its own layer and those below, so a name of a higher layer's
	 * module in a lower one (a test class in a shard plan, a tool in a help text) is data, never a link.
	 */
	public static final LAYERS: Array<String> = ['src', 'tools/src', 'test'];

	/** Where a change reaches generated code or the harness every class runs in: no text dependency bounds it. */
	public static final WHOLE_PREFIXES: Array<String> = [MACROS, 'src/anyparse/runtime/', 'src/anyparse/grammar/', 'test/testkit/'];

	/** The configuration a build or a run reads whatever the module. */
	public static final WHOLE_FILES: Array<String> = ['apq.json', 'apqlint.json', 'hxformat.json', 'haxelib.json'];

	/** The calls that leave a working directory behind for whatever runs next in the process, whatever they name. */
	public static final STATE_WRITERS: Array<String> = ['Sys.setCwd'];

	private static inline final BUILD_EXTENSION: String = 'hxml';
	private static inline final TEST_ROOT: String = 'test/';
	private static inline final TEST_SUFFIX: String = 'Test.hx';
	private static inline final HX: String = '.hx';
	private static inline final MS_PER_SECOND: Float = 1000;
	private static inline final SHORT_HASH: Int = 9;
	private static inline final SUBJECT_WIDTH: Int = 70;

	public static inline function isTest(path: String): Bool {
		return path.startsWith(TEST_ROOT);
	}

	/** The layer of `path`'s root, past the top for a path under none. */
	public static function layer(path: String): Int {
		for (root in ROOTS) if (path.startsWith('$root/')) return LAYERS.indexOf(root);
		return LAYERS.length;
	}

	public static function main(argv: Array<String>): Int {
		final args: Args = new Args(argv);
		final repo: String = Repo.resolve(args.option('--repo'));
		final census: Null<String> = args.option('--census');
		final armCensus: Bool = args.flag('--arm-census');
		final weights: String = args.option('--weights') ?? Path.join([repo, Shard.WEIGHTS]);
		final list: Bool = args.flag('--list');
		final why: Null<String> = args.option('--why');
		final base: Null<String> = args.positionals([], ['<base>'])[0];
		if (armCensus) return armCensusOf(repo, Sys.println);
		if (census != null) {
			final count: Null<Int> = Std.parseInt(census);
			if (count == null || count < 1) throw new UsageError('--census expects a positive count, got \'$census\'');
			return censusOf(repo, count, weights, Sys.println);
		}
		final from: String = base ?? GateTree.gitIn(repo, ['merge-base', 'HEAD', 'main']).trim();
		final sources: Array<ImpactSource> = sourcesOf(repo);
		final ends: Array<String> = from.split('..');
		final touched: Array<String> = ends.length == 2 ? changedIn(repo, ends) : touchedSince(repo, from);
		if (why != null) {
			final path: String = sources.find(s -> moduleOf(s.path)?.qualified == why)?.path ?? why;
			final chain: Array<String> = explain(sources, entriesOf(repo), touched, path);
			Sys.println(chain.length == 0 ? '$why: not reached' : chain.join('\n  <- '));
			return 0;
		}
		final scope: SuiteScope = SuiteImpact.scope(sources, entriesOf(repo), touched);
		Sys.println(describe(scope, testClassCount(sources)));
		if (list) switch scope {
			case Selected(classes):
				for (name in classes) Sys.println('  $name');
			case WholeSuite(_):
		}
		return 0;
	}

	/** The scope of the suite `touched` needs over `sources`; `entries` names the module each build output runs. */
	public static function scope(
		sources: Array<ImpactSource>, entries: Map<String, String>, touched: Array<String>, ?declared: DeclaredTypes
	): SuiteScope {
		return scopeOn(sources, entries, touched, declared ?? declaredTypes(sources));
	}

	/** The scope of the suite the change of `tree` since `base` needs, committed or not. */
	public static function ofTree(tree: String, base: String): SuiteScope {
		return scope(sourcesOf(tree), entriesOf(tree), touchedSince(tree, base));
	}

	/**
	 * Why a change of `path` runs every class, or null when the files that depend on it bound it. Only code under a whole
	 * prefix counts: a data file there has readers that name it.
	 */
	public static function wholeReason(path: String): Null<String> {
		if (path.endsWith(HX)) for (prefix in WHOLE_PREFIXES) if (path.startsWith(prefix)) return '$path is under $prefix';
		final name: String = Path.withoutDirectory(path);
		return WHOLE_FILES.contains(name) || Path.extension(name) == BUILD_EXTENSION ? '$path is a build or configuration file' : null;
	}

	/**
	 * Every file a change of `touched` reaches over `sources`, the touched ones among them. A file in `sinks` is reached but
	 * passes the change on to no file: the reader that only lists what it holds.
	 */
	public static function reached(
		sources: Array<ImpactSource>, touched: Array<String>, sinks: Array<String>, ?declared: DeclaredTypes
	): Array<String> {
		return new ImpactGraph(sources, [], declared ?? declaredTypes(sources), sinks).dependents(touched);
	}

	/** The files a change of `touched` reaches `path` through, `path` first; empty when it does not reach it. */
	public static function explain(
		sources: Array<ImpactSource>, entries: Map<String, String>, touched: Array<String>, path: String
	): Array<String> {
		final graph: ImpactGraph = new ImpactGraph(sources, entries, declaredTypes(sources));
		return graph.dependents(withReaders(sources, touched)).contains(path) ? graph.chain(path) : [];
	}

	/** The module `path` holds, or null when it is no `.hx` under a root. */
	public static function moduleOf(path: String): Null<ImpactModule> {
		if (!path.endsWith(HX)) return null;
		for (root in ROOTS) if (path.startsWith('$root/')) {
			final parts: Array<String> = path.substring(root.length + 1, path.length - HX.length).split('/');
			final name: String = parts.pop() ?? '';
			final pack: String = parts.join('.');
			return {
				path: path,
				pack: pack,
				name: name,
				qualified: pack == '' ? name : '$pack.$name'
			};
		}
		return null;
	}

	public static function isTestClass(path: String): Bool {
		return isTest(path) && path.endsWith(TEST_SUFFIX);
	}

	/** Whether `text` holds `needle` as a whole name: no name character runs on into it on either side. */
	public static function names(text: String, needle: String): Bool {
		var at: Int = text.indexOf(needle);
		while (at >= 0) {
			final before: Null<Int> = at == 0 ? null : text.charCodeAt(at - 1);
			final after: Null<Int> = text.charCodeAt(at + needle.length);
			if (!isNameCode(before) && !isNameCode(after)) return true;
			at = text.indexOf(needle, at + 1);
		}
		return false;
	}

	/**
	 * What a file names a path with no module by: its own name and each directory above it below the top one, which alone is
	 * too common a word to tell a reader.
	 */
	public static function needles(path: String): Array<String> {
		final out: Array<String> = [Path.withoutDirectory(path)];
		final parts: Array<String> = path.split('/');
		parts.pop();
		while (parts.length > 1) {
			out.push(parts.join('/'));
			parts.pop();
		}
		return out;
	}

	/**
	 * `text` without the comments that start a line: a doc names what it explains, which does not run it. A block that never
	 * closes was no comment (a string holding `/*`), so its lines stay.
	 */
	public static function uncommented(text: String): String {
		final kept: Array<String> = [];
		final block: Array<String> = [];
		var inBlock: Bool = false;
		for (line in text.split('\n')) {
			var rest: String = line;
			if (inBlock) {
				block.push(line);
				final end: Int = rest.indexOf('*/');
				if (end < 0) continue;
				inBlock = false;
				block.resize(0);
				rest = rest.substr(end + 2);
			}
			final lead: String = rest.ltrim();
			if (lead.startsWith('//')) continue;
			if (lead.startsWith('/*')) {
				final end: Int = lead.indexOf('*/', 2);
				if (end < 0) {
					inBlock = true;
					block.push(line);
					continue;
				}
				rest = lead.substr(end + 2);
			}
			kept.push(rest);
		}
		for (line in block) kept.push(line);
		return kept.join('\n');
	}

	/** Every `.hx` under the roots of `tree`, by its path from `tree`. */
	public static function sourcesOf(tree: String): Array<ImpactSource> {
		final out: Array<ImpactSource> = [];
		function walk(dir: String): Void {
			final full: String = Path.join([tree, dir]);
			if (!FileSystem.exists(full) || !FileSystem.isDirectory(full)) return;
			final entries: Array<String> = FileSystem.readDirectory(full);
			entries.sort(Reflect.compare);
			for (entry in entries) {
				final path: String = '$dir/$entry';
				if (FileSystem.isDirectory(Path.join([tree, path])))
					walk(path)
				else if (entry.endsWith(HX))
					out.push({ path: path, text: File.getContent(Path.join([tree, path])) });
			}
		}
		for (root in ROOTS) walk(root);
		return out;
	}

	/** Each build output's file name with the module its build runs, read off the build files of `tree` and those they include. */
	public static function entriesOf(tree: String): Map<String, String> {
		final out: Map<String, String> = [];
		for (dir in ['', 'bin', 'tools']) {
			final full: String = Path.join([tree, dir]);
			if (!FileSystem.exists(full) || !FileSystem.isDirectory(full)) continue;
			for (name in FileSystem.readDirectory(full)) if (Path.extension(name) == BUILD_EXTENSION) {
				final entry: Null<BuildEntry> = entryOf(buildWords(tree, Path.join([dir, name]), []));
				if (entry != null) out[Path.withoutDirectory(entry.output)] = entry.main;
			}
		}
		return out;
	}

	/** The main module and the JavaScript output a build's words name, or null when they name no such pair. */
	public static function entryOf(words: Array<String>): Null<BuildEntry> {
		var main: Null<String> = null;
		var output: Null<String> = null;
		for (i in 0...words.length - 1) switch words[i] {
			case '-main', '--main':
				main = words[i + 1];
			case '-js', '--js':
				output = words[i + 1];
			case _:
		}
		return main == null || output == null ? null : { main: main, output: output };
	}

	/** The paths a change of `tree` since `base` touched: changed, removed, renamed from, and untracked. */
	public static function touchedSince(tree: String, base: String): Array<String> {
		final out: Array<String> = changedIn(tree, [base]);
		for (name in GateTree.gitIn(tree, ['ls-files', '--others', '--exclude-standard']).split('\n')) out.push(name);
		final unique: Array<String> = [];
		for (name in out) if (name != '' && !unique.contains(name)) unique.push(name);
		return unique;
	}

	/** The line a gate or a census prints for `scope` out of `total` test classes. */
	public static function describe(scope: SuiteScope, total: Int): String {
		return switch scope {
			case WholeSuite(why): 'suite: whole — $why';
			case Selected(classes): 'suite: impact — ${classes.length} of $total test classes';
		};
	}

	public static function testClassCount(sources: Array<ImpactSource>): Int {
		return sources.count(source -> isTestClass(source.path));
	}

	/**
	 * Over the last `count` commits of `repo`'s first-parent line: what each would have run, the class time it saves by
	 * `weights`, and each test class the commit changed that the closure of its other paths misses — the back-test.
	 */
	public static function censusOf(repo: String, count: Int, weights: String, print: String -> Void): Int {
		final sources: Array<ImpactSource> = sourcesOf(repo);
		final entries: Map<String, String> = entriesOf(repo);
		final declared: DeclaredTypes = declaredTypes(sources);
		final measured: Map<String, ClassWeight> = FileSystem.exists(weights) ? ShardPlan.parseWeights(File.getContent(weights)) : [];
		final all: Array<String> = [];
		for (source in sources) {
			final module: Null<ImpactModule> = isTestClass(source.path) ? moduleOf(source.path) : null;
			if (module != null) all.push(module.qualified);
		}
		final total: Float = classTime(all, measured);
		final head: String = GateTree.gitIn(repo, ['rev-parse', 'HEAD']).trim();
		print(
			'suite-impact census: the last $count commits, graph read at ${head.substr(0, SHORT_HASH)}, ${all.length} test classes, '
			+ '${seconds(total)}s of class time by $weights'
		);
		final log: Array<String> = GateTree.gitIn(repo, ['log', '--first-parent', '--format=%H%x09%s', '-n', '$count', 'HEAD']).split('\n');
		var rows: Int = 0;
		var selected: Int = 0;
		var saved: Float = 0;
		var misses: Int = 0;
		for (line in log) {
			final cells: Array<String> = line.split('\t');
			if (cells.length < 2) continue;
			rows++;
			final sha: String = cells[0];
			final touched: Array<String> = changedIn(repo, ['$sha^', sha]);
			final subject: String = cells[1].length > SUBJECT_WIDTH ? '${cells[1].substr(0, SUBJECT_WIDTH)}…' : cells[1];
			final short: String = sha.substr(0, SHORT_HASH);
			switch scope(sources, entries, touched, declared) {
				case WholeSuite(why):
					print('$short  whole   $why — $subject');
				case Selected(classes):
					selected++;
					final time: Float = classTime(classes, measured);
					saved += total - time;
					print('$short  impact  ${classes.length} classes, ${seconds(time)}s — $subject');
			}
			for (miss in missed(sources, entries, touched, declared)) {
				misses++;
				print('  miss: $miss — the commit changed it, the closure of its other paths does not reach it');
			}
		}
		print('--- census: $selected of $rows commit(s) impact-selected, ${seconds(saved)}s of class time saved, $misses miss(es)');
		return 0;
	}

	/**
	 * The test classes among `touched` that the closure of its other paths does not reach: a slice that changes a test with
	 * the code it tests says the test depends on that code, so a test the graph cannot reach from it is a dependency no text
	 * carries.
	 */
	public static function missed(
		sources: Array<ImpactSource>, entries: Map<String, String>, touched: Array<String>, ?declared: DeclaredTypes
	): Array<String> {
		final others: Array<String> = touched.filter(p -> !isTestClass(p));
		final tests: Array<String> = touched.filter(isTestClass);
		if (others.length == 0 || tests.length == 0) return [];
		final reached: Array<String> = switch scope(sources, entries, others, declared) {
			case WholeSuite(_): return [];
			case Selected(classes): classes;
		};
		final out: Array<String> = [];
		for (path in tests) {
			final module: Null<ImpactModule> = moduleOf(path);
			if (module != null && !reached.contains(module.qualified) && sources.exists(s -> s.path == path)) out.push(module.qualified);
		}
		return out;
	}

	/**
	 * Why a change of `path`, whose text is `text`, runs every class for the process-wide state it writes, or null. Classes
	 * share a shard's process, so a working directory one leaves behind reaches the next whatever either names; an environment
	 * variable reaches only the files that spell its key, so it runs everything only when one of them is the harness every class
	 * runs in (`runner` is its module) or generated code, and otherwise `stateReaders` bounds it. A test class's own change
	 * still runs only itself, since the land's whole suite meets its neighbours.
	 */
	public static function stateReason(path: String, text: String, sources: Array<ImpactSource>, runner: Null<String>): Null<String> {
		if (!path.endsWith(HX) || isTestClass(path)) return null;
		final code: String = uncommented(text);
		for (writer in STATE_WRITERS) if (code.indexOf('$writer(') >= 0) return '$path writes process-wide state ($writer)';
		final keys: Null<Array<String>> = envKeys(code);
		if (keys == null) return '$path writes process-wide state ($ENV_WRITER) under a key it computes';
		for (key in keys)
			for (reader in envReaders(sources, path, key))
				if (wholeReason(reader) != null || moduleOf(reader)?.qualified == runner) return '$path sets $key, which $reader reads';
		return null;
	}

	/** The files that spell a key `path`, whose text is `text`, sets in the environment, which a change of `path` reaches. */
	public static function stateReaders(path: String, text: String, sources: Array<ImpactSource>): Array<String> {
		if (!path.endsWith(HX) || isTestClass(path)) return [];
		final out: Array<String> = [];
		for (key in envKeys(uncommented(text)) ?? [])
			for (reader in envReaders(sources, path, key))
				if (!out.contains(reader)) out.push(reader);
		return out;
	}

	/** The keys the calls of `code` set in the environment, or null when one of them names its key by anything but a plain literal. */
	public static function envKeys(code: String): Null<Array<String>> {
		final call: String = '$ENV_WRITER(';
		final out: Array<String> = [];
		var at: Int = code.indexOf(call);
		while (at >= 0) {
			final rest: String = code.substr(at + call.length).ltrim();
			final quote: String = rest.charAt(0);
			final end: Int = quote == '\'' || quote == '"' ? rest.indexOf(quote, 1) : -1;
			final key: String = end < 0 ? '' : rest.substring(1, end);
			if (key == '' || key.indexOf('$$') >= 0) return null;
			out.push(key);
			at = code.indexOf(call, at + 1);
		}
		return out;
	}

	/** The types each of `sources` declares, read off one symbol index over them all. */
	public static function declaredTypes(sources: Array<ImpactSource>): DeclaredTypes {
		final index: SymbolIndex = IndexScope.over(
			sources.map(source -> {file: source.path, source: source.text }), new CachingGrammarPlugin(new HaxeQueryPlugin())
		);
		return {
			types: [for (info in index.allFiles()) info.file => [for (type in info.types) type.name]],
			unparsed: index.skippedFiles()
		};
	}

	/**
	 * The arm census over the registry of `repo`: each arm whose pinning classes an impact-selected suite would leave out
	 * when only the file declaring the arm's type changed, as `<arm> <file> <class>`, then the tally; 1 when any is missed.
	 */
	public static function armCensusOf(repo: String, print: String -> Void): Int {
		final test: String = Path.join([repo, 'bin/test.js']);
		if (!FileSystem.exists(test)) {
			print('$test missing — build it first (node bin/dev.js worker-build <dir>)');
			return 2;
		}
		final listed: Result = cmd('node $test --list-pins').run();
		if (!listed.ok) {
			print('--list-pins failed: ${listed.err}');
			return 2;
		}
		final arms: Array<ArmRecord> = ArmRegistry.read(Path.join([repo, ArmRegistry.DIRECTORY]));
		final pinned: Map<String, String> = MutationArm.pinTables(listed.out).classes;
		final reach: ArmReach = armMisses(sourcesOf(repo), entriesOf(repo), arms, pinned);
		for (miss in reach.misses) print(miss);
		print(
			'--- arm census: ${arms.count(arm -> pinned.exists(arm.key))} pinned arm(s) of ${arms.length}, ${reach.files} file(s) of which '
			+ '${reach.whole} run the whole suite, ${reach.misses.length} miss(es)'
		);
		return reach.misses.length == 0 ? 0 : 1;
	}

	/**
	 * Where an impact-selected suite fails a mutation arm: for every class `pinned` names for an arm (its `@:killer`s, comma
	 * separated), `<arm> <file> <class>` when a change of the file declaring the arm's type does not reach that class. A touch
	 * that runs every class misses none; an arm whose type no file declares names the type in the file's place, since nothing
	 * reaches its pins.
	 */
	public static function armMisses(
		sources: Array<ImpactSource>, entries: Map<String, String>, arms: Array<ArmRecord>, pinned: Map<String, String>,
		?declared: DeclaredTypes
	): ArmReach {
		final types: DeclaredTypes = declared ?? declaredTypes(sources);
		final graph: ImpactGraph = new ImpactGraph(sources, entries, types);
		final reach: Map<String, Null<Array<String>>> = [];
		final misses: Array<String> = [];
		var whole: Int = 0;
		for (arm in arms) {
			final classes: Array<String> = (pinned[arm.key] ?? '').split(',').filter(name -> name != '');
			if (classes.length == 0) continue;
			final type: String = ArmHeadParser.parse(arm.text).type ?? '';
			final file: Null<String> = fileOfType(sources, type);
			var reached: Array<String> = [];
			if (file != null) {
				if (!reach.exists(file)) reach[file] = switch scopeOn(sources, entries, [file], types, graph) {
					case WholeSuite(_):
						whole++;
						null;
					case Selected(selected): selected;
				};
				reached = reach[file] ?? continue;
			}
			for (name in classes) if (!reached.contains(name)) misses.push('${arm.key} ${file ?? type} $name');
		}
		misses.sort(Reflect.compare);
		return { misses: misses, files: reach.count(), whole: whole };
	}

	/** `scope` over the `types` the caller read, on `shared` when it keeps one graph of `sources` for many touches. */
	private static function scopeOn(
		sources: Array<ImpactSource>, entries: Map<String, String>, touched: Array<String>, types: DeclaredTypes, ?shared: ImpactGraph
	): SuiteScope {
		final runner: Null<String> = entries[SUITE_OUTPUT];
		for (path in touched) {
			final why: Null<String> = wholeReason(path) ?? stateReason(path, textOf(sources, path), sources, runner);
			if (why != null) return WholeSuite(why);
			if (runner != null && moduleOf(path)?.qualified == runner) return WholeSuite('$path is the runner every class runs inside');
		}
		if (types.unparsed.length > 0) return WholeSuite('${types.unparsed[0]} does not parse, so the types it declares are unknown');
		final graph: ImpactGraph = shared ?? new ImpactGraph(sources, entries, types);
		final reached: Array<String> = graph.dependents(withReaders(sources, touched));
		for (path in reached) if (path.startsWith(MACROS))
			return WholeSuite('a macro depends on the change: ${graph.chain(path).join(' <- ')}');
		final classes: Array<String> = [];
		for (path in reached) {
			final module: Null<ImpactModule> = isTestClass(path) ? moduleOf(path) : null;
			if (module != null) classes.push(module.qualified);
		}
		classes.sort(Reflect.compare);
		return Selected(classes);
	}

	private static function isNameCode(code: Null<Int>): Bool {
		return code != null && (code == '_'.code || code == '-'.code || ~/[A-Za-z0-9]/.match(String.fromCharCode(code)));
	}

	/** The paths of `repo`'s `git diff` over `range` (a base, or a base and a tip), a renamed one by both its names. */
	private static function changedIn(repo: String, range: Array<String>): Array<String> {
		final changed: ChangedPaths = GateTree.changedPaths(GateTree.gitIn(repo, ['diff', '--name-status', '-M'].concat(range)));
		return changed.paths.concat([for (old in changed.moved) old]);
	}

	private static function classTime(classes: Array<String>, measured: Map<String, ClassWeight>): Float {
		var sum: Float = 0;
		for (name in classes) sum += measured[name]?.ms ?? 0;
		return sum;
	}

	private static function seconds(ms: Float): String {
		return '${Math.round(ms / MS_PER_SECOND)}';
	}

	/** The words of the build file `file` of `tree`, with those of each build file it includes in place; `seen` breaks a cycle. */
	private static function buildWords(tree: String, file: String, seen: Array<String>): Array<String> {
		final full: String = Path.join([tree, file]);
		if (seen.contains(file) || !FileSystem.exists(full)) return [];
		seen.push(file);
		final out: Array<String> = [];
		for (line in File.getContent(full).split('\n')) {
			final text: String = line.trim();
			if (text == '' || text.startsWith('#')) continue;
			if (!text.startsWith('-') && Path.extension(text) == BUILD_EXTENSION) {
				for (word in buildWords(tree, text, seen)) out.push(word);
				continue;
			}
			for (word in ~/\s+/g.split(text)) if (word != '') out.push(word);
		}
		return out;
	}

	/** The source file declaring `type`, a module's own type or one it holds beside it; null when no file does. */
	private static function fileOfType(sources: Array<ImpactSource>, type: String): Null<String> {
		final parts: Array<String> = type.split('.');
		while (parts.length > 0) {
			final relative: String = parts.join('/') + HX;
			for (root in ROOTS) if (sources.exists(source -> source.path == '$root/$relative')) return '$root/$relative';
			parts.pop();
		}
		return null;
	}

	/** `touched` and the files that read an environment key a touched file sets. */
	private static function withReaders(sources: Array<ImpactSource>, touched: Array<String>): Array<String> {
		final out: Array<String> = touched.copy();
		for (path in touched)
			for (reader in stateReaders(path, textOf(sources, path), sources))
				if (!out.contains(reader)) out.push(reader);
		return out;
	}

	/** The files other than `writer` whose code spells `key` as a whole name. */
	private static function envReaders(sources: Array<ImpactSource>, writer: String, key: String): Array<String> {
		return [
			for (s in sources) if (s.path != writer && names(s.text, key) && names(uncommented(s.text), key)) s.path
		];
	}

	private static function textOf(sources: Array<ImpactSource>, path: String): String {
		return sources.find(s -> s.path == path)?.text ?? '';
	}

}

/**
 * The text dependencies among the sources of one tree, indexed once: the files each dotted path occurs in and the files of
 * each package, so a closure costs a lookup per module, not a scan.
 */
@:nullSafety(Strict)
private final class ImpactGraph {

	private static inline final AMBIENT: String = 'import.hx';
	private static inline final TOUCHED: Int = -1;
	private static final CHAIN: EReg = ~/[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+(?:\.\*)?/g;
	private static final WORD: EReg = ~/[A-Za-z_][A-Za-z0-9_]*/g;

	private final _paths: Array<String> = [];
	private final _texts: Array<String> = [];
	private final _at: Map<String, Int> = [];
	private final _chains: Map<String, Array<Int>> = [];
	private final _packs: Map<String, Array<Int>> = [];
	private final _words: Map<Int, Map<String, Bool>> = [];
	private final _outputs: Map<String, Array<String>> = [];

	/** Each file the last `dependents` reached, with the file it was reached from, `TOUCHED` for a touched path's own. */
	private final _via: Map<Int, Int> = [];

	private final _pending: Array<PendingModule> = [];
	private final _declared: DeclaredTypes;

	/** The files that are reached but pass the change on to no file. */
	private final _sinks: Array<String>;

	public function new(
		sources: Array<ImpactSource>, entries: Map<String, String>, declared: DeclaredTypes, ?sinks: Array<String>
	) {
		_declared = declared;
		_sinks = sinks ?? [];
		for (i => source in sources) {
			final text: String = SuiteImpact.uncommented(source.text);
			_paths.push(source.path);
			_texts.push(text);
			_at[source.path] = i;
			final module: Null<ImpactModule> = SuiteImpact.moduleOf(source.path);
			if (module != null) listed(_packs, module.pack, i);
			final seen: Map<String, Bool> = [];
			for (chain in matchesOf(CHAIN, text, 0)) {
				final parts: Array<String> = chain.split('.');
				var prefix: String = parts[0];
				for (k in 1...parts.length) {
					prefix += '.${parts[k]}';
					if (seen.exists(prefix)) continue;
					seen[prefix] = true;
					listed(_chains, prefix, i);
				}
			}
		}
		for (output => main in entries) {
			final outputs: Array<String> = _outputs[main] ?? [];
			outputs.push(output);
			_outputs[main] = outputs;
		}
	}

	/**
	 * Every file a change of `touched` reaches, the touched files among them: a module reaches the files that name it, a
	 * module-less path the files that name its path, and an ambient import file every file below it.
	 */
	public function dependents(touched: Array<String>): Array<String> {
		_via.clear();
		_pending.resize(0);
		for (path in touched) seed(path);
		while (_pending.length > 0) {
			final next: Null<PendingModule> = _pending.pop();
			if (next != null) spread(next.module, next.at);
		}
		final out: Array<String> = [for (i => _ in _via) _paths[i]];
		out.sort(Reflect.compare);
		return out;
	}

	/** The files the last `dependents` reached `path` through, `path` first and a touched one last; empty when it was not reached. */
	public function chain(path: String): Array<String> {
		final out: Array<String> = [];
		var at: Null<Int> = _at[path];
		while (at != null && at >= 0 && _via.exists(at) && !out.contains(_paths[at])) {
			out.push(_paths[at]);
			at = _via[at];
		}
		return out;
	}

	private function seed(path: String): Void {
		final module: Null<ImpactModule> = SuiteImpact.moduleOf(path);
		final at: Null<Int> = _at[path];
		if (at != null) reach(at, TOUCHED);
		if (module == null)
			for (i in mentioning(SuiteImpact.needles(path))) reach(i, TOUCHED)
		else if (at == null)
			queue(module, TOUCHED);
	}

	/** Reaches every file that names `module`, which the file at `from` holds. */
	private function spread(module: ImpactModule, from: Int): Void {
		for (i in _chains[module.qualified] ?? []) reach(i, from);
		if (module.pack != '') for (i in _chains['${module.pack}.*'] ?? []) reach(i, from);
		final names: Array<String> = declared(module);
		// a simple name resolves in the module's package and every package below it
		for (pack => files in _packs)
			if (module.pack == '' || pack == module.pack || pack.startsWith('${module.pack}.'))
				for (i in files)
					if (!_via.exists(i) && names.exists(name -> wordsOf(i).exists(name))) reach(i, from);
		// only a test runs a build's output inside the suite: elsewhere its name is help text or a path the code hands on
		for (output in _outputs[module.qualified] ?? []) for (i in mentioning([output])) if (SuiteImpact.isTest(_paths[i])) reach(i, from);
	}

	/**
	 * Marks file `i` reached from the file `from`, unless a lower layer would depend on a higher one: a test class passes a
	 * change on only to the test files that call it, and a name of it in a shard plan or a help text is data. An ambient
	 * import file passes the module on only to the files below it that use one of its names, or to all of them when it opens
	 * the module's statics with `using`.
	 */
	private function reach(i: Int, from: Int): Void {
		if (_via.exists(i) || (from != TOUCHED && SuiteImpact.layer(_paths[i]) < SuiteImpact.layer(_paths[from]))) return;
		_via[i] = from;
		final path: String = _paths[i];
		if (_sinks.contains(path)) return;
		final module: Null<ImpactModule> = SuiteImpact.moduleOf(path);
		if (Path.withoutDirectory(path) != AMBIENT) {
			if (module != null) queue(module, i);
			return;
		}
		final dir: String = '${Path.directory(path)}/';
		final opened: Null<ImpactModule> = from == TOUCHED ? null : SuiteImpact.moduleOf(_paths[from]);
		final names: Null<Array<String>> = opened == null || _texts[i].indexOf('using ${opened.qualified}') >= 0 ? null : declared(opened);
		for (j => other in _paths) if (other.startsWith(dir) && (names == null || names.exists(name -> wordsOf(j).exists(name))))
			reach(j, i);
	}

	/** The module's name and every type its file declares, the names a same-package file uses it by. */
	private function declared(module: ImpactModule): Array<String> {
		final names: Array<String> = [module.name];
		for (name in _declared.types[module.path] ?? []) if (!names.contains(name)) names.push(name);
		return names;
	}

	private function mentioning(needles: Array<String>): Array<Int> {
		return [
			for (i => text in _texts) if (needles.exists(needle -> SuiteImpact.names(text, needle))) i
		];
	}

	private function wordsOf(i: Int): Map<String, Bool> {
		final known: Null<Map<String, Bool>> = _words[i];
		if (known != null) return known;
		final words: Map<String, Bool> = [for (word in matchesOf(WORD, _texts[i], 0)) word => true];
		_words[i] = words;
		return words;
	}

	private function queue(module: ImpactModule, at: Int): Void {
		_pending.push({ module: module, at: at });
	}

	private static function listed(index: Map<String, Array<Int>>, key: String, i: Int): Void {
		final list: Array<Int> = index[key] ?? [];
		list.push(i);
		index[key] = list;
	}

	/** Group `group` of every match of the global `pattern` in `text`, in order. */
	private static function matchesOf(pattern: EReg, text: String, group: Int): Array<String> {
		final out: Array<String> = [];
		var from: Int = 0;
		while (pattern.matchSub(text, from)) {
			final span: { pos: Int, len: Int } = pattern.matchedPos();
			from = span.pos + span.len;
			out.push(pattern.matched(group));
		}
		return out;
	}

}

/** A source file of a tree: its path from the tree and its text. */
typedef ImpactSource = {
	var path: String;
	var text: String;
}

/** The types each parsed source declares, by path, and the sources that do not parse, whose types are unknown. */
typedef DeclaredTypes = {
	var types: Map<String, Array<String>>;
	var unparsed: Array<String>;
}

/** The module a `.hx` under a root holds. */
typedef ImpactModule = {
	var path: String;
	var pack: String;
	var name: String;
	var qualified: String;
}

/** A module whose dependents a closure has yet to reach, and the file that holds it, `-1` for a removed one. */
private typedef PendingModule = {
	var module: ImpactModule;
	var at: Int;
}

/** The main module a build runs and the file it writes. */
typedef BuildEntry = {
	var main: String;
	var output: String;
}

/** What the arm census read: the pins an impact selection leaves out, and how many files it selected for. */
typedef ArmReach = {
	var misses: Array<String>;
	var files: Int;
	var whole: Int;
}

/** What a suite runs for a change. */
enum SuiteScope {

	/** Every registered class: `why` names the touch no text dependency bounds. */
	WholeSuite(why: String);

	/** Only these test classes, by their qualified names; none when no class depends on the change. */
	Selected(classes: Array<String>);

}
