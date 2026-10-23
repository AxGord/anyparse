package dev;

import anyparse.check.CheckScan;
import anyparse.check.FactsTypeOracle;
import anyparse.check.LintConfig;
import anyparse.check.OracleGeneration;
import anyparse.check.RunScan;
import anyparse.check.TypedFactsProbe;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CompilerFacts.FactNode;
import anyparse.query.CompilerFacts.FactPos;
import anyparse.query.CompilerFacts.TypeFact;
import anyparse.query.ComposedValues;
import anyparse.query.CtorFieldFold;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.HaxelibResolver;
import anyparse.query.IndexScope;
import anyparse.query.MemberLookup.MemberDeclaration;
import anyparse.query.NominalTypes;
import anyparse.query.OperatorOverloads.OperatorResult;
import anyparse.query.ParseGate;
import anyparse.query.QueryNode;
import anyparse.query.Refs;
import anyparse.query.SourceText;
import anyparse.query.StdResolver;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoMemo;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.query.TypingService;
import anyparse.runtime.Span;
import haxe.Exception;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * The typer's conformance harness, step T1 of the typer by specification (`docs/typing-service.md`): it asks the typing
 * layers questions the compiler has answered and scores every answer MATCH (the compiler's), UNKNOWN (the typer
 * declined) or DIFFERENT (anything else, the one outcome a typer that fails closed must never give). The UNKNOWN share
 * of an area is the typer's coverage there.
 *
 * Two sources, neither copied into this repository. `upstream` reads a pinned Haxe 4.3.7 clone: `tests/display` (the
 * `type`, `position` and `usage` assertions on `{-N-}` markers; every other display assertion is counted, unanswered)
 * and `tests/misc` (the `$type` warnings and `A should be B` errors of every `compile-fail` stderr). `facts`, run in a
 * project root, compiles the project's oracles (`apqlint.json`) with the facts hook and asks the type of every range the
 * compiler typed.
 *
 * `--census` roots every UNKNOWN type answer (`UnknownCauses`) and prints the tallies after the table, which it leaves
 * byte-identical: the share of each inference form and of each gap that needs none, the denominator the typer's next steps
 * are measured against.
 *
 *   haxe tools/dev.hxml
 *   node bin/dev.js typer-conformance upstream <haxe-4.3.7-clone> [--list] [--census]
 *   (cd <project> && node <anyparse>/bin/dev.js typer-conformance facts [<configuration-substring>] [--list] [--census])
 */
@:nullSafety(Strict)
final class TyperConformance {

	public static inline final USAGE: String =
		'usage: dev typer-conformance upstream <haxe-4.3.7-clone> | facts [<configuration>] | probes [<dir>]  [--list] [--census]';

	/** The probe corpus `probes` runs when it is given no directory: the tree's own, one project per directory. */
	private static inline final PROBES_DIR: String = 'tools/typer-facts';

	/** The group of the test function's name in `displayTests`' header pattern. */
	private static inline final TEST_NAME_GROUP: Int = 3;

	/** The group of `POSITION_ASSERT` / `FIRST_USAGE_ASSERT` holding the marker the query is made at. */
	private static inline final QUERY_MARKER_GROUP: Int = 3;

	/** The groups of `MESSAGE`: the line, the first and the end character, the text. */
	private static inline final MESSAGE_LINE_GROUP: Int = 2;

	private static inline final MESSAGE_FROM_GROUP: Int = 3;
	private static inline final MESSAGE_TO_GROUP: Int = 4;
	private static inline final MESSAGE_TEXT_GROUP: Int = 5;

	/** The access of a call fact whose callee the compiler inlined at the call site (`CompilerFacts.CallFact`). */
	private static inline final INLINED_ACCESS: String = 'inlined';

	/** The type a class read as a value has, and an enum's (`Class<T>`, `Enum<T>`). */
	private static inline final CLASS_VALUE: String = 'Class';

	private static inline final ENUM_VALUE: String = 'Enum';

	/** The kind the facts give a typedef (`CompilerFacts.TypeFact`). */
	private static inline final TYPEDEF_KIND: String = 'typedef';

	/** A display assertion the harness scores: `eq("<type>", type(pos(N)))`. */
	private static final TYPE_ASSERT: EReg = ~/^eq\("((?:[^"\\]|\\.)*)",\s*type\(pos\((\d+)\)\)\)$/;

	/** `eq(range(A, B), position(pos(N)))`. */
	private static final POSITION_ASSERT: EReg = ~/^eq\(range\((\d+),\s*(\d+)\),\s*position\(pos\((\d+)\)\)\)$/;

	/** `arrayEq([range(A, B), …], usage(pos(N)))`. */
	private static final USAGE_ASSERT: EReg = ~/^arrayEq\(\[((?:\s*range\(\d+,\s*\d+\)\s*,?)*)\],\s*usage\(pos\((\d+)\)\)\)$/;

	/** `eq(range(A, B), usage(pos(N))[0])`: the first usage alone. */
	private static final FIRST_USAGE_ASSERT: EReg = ~/^eq\(range\((\d+),\s*(\d+)\),\s*usage\(pos\((\d+)\)\)\[0\]\)$/;

	/** One `range(A, B)` of a usage list. */
	private static final RANGE: EReg = ~/range\((\d+),\s*(\d+)\)/;

	/** The display API calls an assertion may make, by area; the first one a statement calls decides its area. */
	private static final DISPLAY_AREAS: Array<String> = [
		'type',
		'position',
		'usage',
		'fields',
		'toplevel',
		'signature',
		'doc',
		'metadataDoc',
		'diagnostics',
		'documentSymbols',
		'noCompletionPoint',
		'typeNotFound'
	];

	/** A classic compiler message: `<file>:<line>: characters <a>-<b> : <text>`. */
	private static final MESSAGE: EReg = ~/^(.+?):(\d+): characters (\d+)-(\d+) : (.*)$/;

	/** A `$type` warning's text. */
	private static final TYPE_WARNING: EReg = ~/^Warning : (.+)$/;

	/** A unification error's text, at the top of its chain: `<A> should be <B>`. */
	private static final SHOULD_BE: EReg = ~/^(?:error: )?(.+) should be (.+)$/;

	public static function main(argv: Array<String>): Int {
		final args: Array<String> = argv.copy();
		final list: Bool = args.remove('--list');
		final report: Report = new Report(list, args.remove('--census'));
		var gated: Bool = false;
		var refused: Array<String> = [];
		switch args {
			case ['upstream', clone]:
				upstream(clone, report);
			case ['facts']:
				facts(null, report);
			case ['facts', configuration]:
				facts(configuration, report);
			case ['probes']:
				gated = true;
				refused = probes(Path.join([Repo.resolve(null), PROBES_DIR]), report);
			case ['probes', dir]:
				gated = true;
				refused = probes(dir, report);
			case _:
				Sys.println(USAGE);
				return 2;
		}
		report.print();
		for (r in refused) Sys.println('REFUSED  $r');
		// the probe corpus is a gate: one answer that is not the compiler's fails it, and so does a project it could not read
		return gated && (report.differences() > 0 || refused.length > 0) ? 1 : 0;
	}

	/**
	 * Why a probe project's run is no reading of the typer, or null when it is one: a configuration the compiler dropped (a
	 * type error, a compiler that did not start), none compiled, no project file compiled, or no case scored. A run that
	 * read nothing has no DIFFERENT to show, so a gate counting DIFFERENT alone would pass it.
	 */
	public static function probeRefusal(run: FactsRun): Null<String> {
		return if (run.dropped.length > 0)
			'a configuration did not compile (${run.dropped.join('; ')})'
		else if (run.configurations == 0)
			'no configuration compiled'
		else if (run.compiled == 0)
			'0 of ${run.files} project files compiled'
		else if (run.cases == 0)
			'no case was scored'
		else
			null;
	}

	/**
	 * Every probe project under `dir` — each directory holding an `apqlint.json` that names a compiler oracle — run as
	 * `facts` in it, into one report: shapes no census tree holds, each compiled by the compiler and asked of the typer.
	 * Returns one line per project whose run is no reading (`probeRefusal`), each printed as it is found.
	 */
	private static function probes(dir: String, report: Report): Array<String> {
		final start: String = Sys.getCwd();
		final root: String = FileSystem.fullPath(dir);
		final names: Array<String> = FileSystem.readDirectory(root).filter(n -> FileSystem.exists(Path.join([root, n, 'apqlint.json'])));
		names.sort(Reflect.compare);
		final refused: Array<String> = [];
		for (name in names) {
			Sys.setCwd(Path.join([root, name]));
			final why: Null<String> = try probeRefusal(facts(null, report)) catch (e: Exception) 'the run threw: ${e.message}';
			if (why == null) continue;
			refused.push('$name: $why');
			Sys.println('probes: $name is no reading — $why');
		}
		Sys.setCwd(start);
		if (names.length == 0) refused.push('no probe project under $root');
		return refused;
	}

	/** The display and misc suites of the clone at `clone`. */
	private static function upstream(clone: String, report: Report): Void {
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final std: Array<{ file: String, source: String }> = evalStd();
		final cases: Array<String> = [];
		collectPaths(Path.join([clone, 'tests/display/src/cases']), '.hx', cases);
		cases.sort(Reflect.compare);
		for (path in cases) for (test in displayTests(path)) displayCase(test, plugin, std, report);
		final stderrs: Array<String> = [];
		collectPaths(Path.join([clone, 'tests/misc/projects']), '-fail.hxml.stderr', stderrs);
		stderrs.sort(Reflect.compare);
		for (path in stderrs) miscCase(path, plugin, std, report);
	}

	/** The standard library as the `--interp` target sees it: the top level, `haxe`, `sys` and `eval`. */
	private static function evalStd(): Array<{ file: String, source: String }> {
		final dir: Null<String> = StdResolver.stdDir();
		final out: Array<{ file: String, source: String }> = [];
		if (dir == null) return out;
		for (entry in FileSystem.readDirectory(dir)) {
			final path: String = Path.join([dir, entry]);
			if (FileSystem.isDirectory(path)) {
				if (['haxe', 'sys', 'eval'].contains(entry)) collect(path, out);
			} else if (entry.endsWith('.hx')) {
				out.push({ file: path, source: File.getContent(path) });
			}
		}
		return out;
	}

	/** Every test of the display case file `path` that carries its code in its doc comment. */
	private static function displayTests(path: String): Array<DisplayTest> {
		final text: String = File.getContent(path);
		final packageLine: EReg = ~/^package\s+([\w.]+)\s*;/m;
		final pack: Null<String> = packageLine.match(text) ? packageLine.matched(1) : null;
		final head: EReg = ~/\/\*\*([\s\S]*?)\*\*\/\s*((?:@:[A-Za-z]+(?:\([^)]*\))?\s*)*)function\s+(\w+)\s*\(\)[^{]*\{/;
		final out: Array<DisplayTest> = [];
		var at: Int = 0;
		while (head.matchSub(text, at)) {
			final pos: { pos: Int, len: Int } = head.matchedPos();
			final bodyFrom: Int = pos.pos + pos.len;
			final bodyTo: Int = closingBrace(text, bodyFrom);
			final metas: String = head.matched(2);
			final doc: String = head.matched(1).replace('**\\/', '**/');
			final wrapped: String = metas.contains('@:funcCode') ? 'class Main { static function main() { $doc}}' : doc;
			final code: String = (pack == null ? '' : 'package $pack;\n') + wrapped;
			final file: EReg = ~/@:filename\("([^"]+)"\)/;
			out.push({
				label: '${Path.withoutDirectory(path)}#${head.matched(TEST_NAME_GROUP)}',
				file: file.match(metas) ? file.matched(1) : Path.withoutDirectory(path),
				code: code,
				statements: statementsOf(text.substring(bodyFrom, bodyTo))
			});
			at = bodyTo;
		}
		return out;
	}

	/** One display test: its code with the markers taken out, scored assertion by assertion. */
	private static function displayCase(
		test: DisplayTest, plugin: CachingGrammarPlugin, std: Array<{ file: String, source: String }>, report: Report
	): Void {
		final markers: Map<Int, Int> = [];
		final marker: EReg = ~/\{-(\d+)-\}/;
		var source: String = '';
		var rest: String = test.code;
		while (marker.match(rest)) {
			source += marker.matchedLeft();
			final n: Null<Int> = Std.parseInt(marker.matched(1));
			if (n != null) markers[n] = source.length;
			rest = marker.matchedRight();
		}
		source += rest;
		final typer: Null<FileTyper> = FileTyper.over(plugin, [{ file: test.file, source: source }], std, test.file);
		for (statement in test.statements) {
			final area: Null<String> = DISPLAY_AREAS.find(a -> statement.contains('$a('));
			if (area == null) continue;
			final label: String = '${test.label}: $statement';
			if (typer == null)
				report.unscored('display/$area', '$label (the code does not parse)')
			else
				displayAssertion(statement, 'display/$area', label, markers, typer, report);
		}
	}

	/** One display assertion of `area`: a `type`, `position` or `usage` one is asked of `typer`, any other is unanswered. */
	private static function displayAssertion(
		statement: String, area: String, label: String, markers: Map<Int, Int>, typer: FileTyper, report: Report
	): Void {
		if (TYPE_ASSERT.match(statement)) {
			final at: Null<Int> = markers[group(TYPE_ASSERT, 2)];
			final node: Null<QueryNode> = at == null ? null : typer.displayed(at);
			if (node == null)
				report.unscored(area, '$label (the position sits on a seam between two expressions)')
			else
				typeAt(report, area, label, unescape(TYPE_ASSERT.matched(1)), typer, node);
		} else if (POSITION_ASSERT.match(statement)) {
			final expected: Null<Span> = rangeOf(markers, POSITION_ASSERT.matched(1), POSITION_ASSERT.matched(2));
			final at: Null<Int> = markers[group(POSITION_ASSERT, QUERY_MARKER_GROUP)];
			if (expected != null && at != null) report.score(area, label, positionVerdict(expected, typer.definitionAt(at)));
		} else if (USAGE_ASSERT.match(statement)) {
			final at: Null<Int> = markers[group(USAGE_ASSERT, 2)];
			final expected: Array<Span> = rangesOf(markers, USAGE_ASSERT.matched(1));
			if (at != null) report.score(area, label, usageVerdict(expected, typer.usagesAt(at), false));
		} else if (FIRST_USAGE_ASSERT.match(statement)) {
			final expected: Null<Span> = rangeOf(markers, FIRST_USAGE_ASSERT.matched(1), FIRST_USAGE_ASSERT.matched(2));
			final at: Null<Int> = markers[group(FIRST_USAGE_ASSERT, QUERY_MARKER_GROUP)];
			if (expected != null && at != null) report.score(area, label, usageVerdict([expected], typer.usagesAt(at), true));
		} else {
			report.score(area, label, Unknown);
		}
	}

	/** The `$type` warnings and the top `should be` error of one `compile-fail` stderr, typed in its project's files. */
	private static function miscCase(
		stderr: String, plugin: CachingGrammarPlugin, std: Array<{ file: String, source: String }>, report: Report
	): Void {
		final dir: String = Path.directory(stderr);
		final files: Array<{ file: String, source: String }> = [];
		collect(dir, files);
		final project: Array<{ file: String, source: String }> = [
			for (f in files)
				{
					file: f.file.substr(dir.length + 1),
					source: f.source
				}
		];
		final typers: Map<String, Null<FileTyper>> = [];
		final projectName: String = Path.withoutDirectory(dir);
		final lines: Array<String> = File.getContent(stderr).split('\n');
		for (at => line in lines) {
			if (!MESSAGE.match(line.trim())) continue;
			final file: String = Path.normalize(MESSAGE.matched(1));
			final text: String = MESSAGE.matched(MESSAGE_TEXT_GROUP);
			// a `... ` line continues the chain of the error above it, about a part of that type, not the expression's
			if (text.startsWith('... ')) continue;
			final warning: Bool = TYPE_WARNING.match(text);
			final expected: Null<String> = warning ? TYPE_WARNING.matched(1) : SHOULD_BE.match(text) ? SHOULD_BE.matched(1) : null;
			final area: String = warning ? 'misc/$$type' : 'misc/should-be';
			final label: String = '$projectName/${Path.withoutDirectory(stderr)}: ${line.trim()}';
			if (expected == null) {
				report.unscored('misc/other', label);
				continue;
			}
			// a chain under the error (`... have:` / `... want:`) makes its own pair the innermost one that failed, a part
			if (!warning && chained(lines, at)) {
				report.unscored(area, '$label (the error names a part of the type, its chain the whole)');
				continue;
			}
			if (!typers.exists(file)) typers[file] = FileTyper.over(plugin, project, std, file);
			final typer: Null<FileTyper> = typers[file];
			final span: Null<Span> = typer?.spanOfColumns(
				group(MESSAGE, MESSAGE_LINE_GROUP), group(MESSAGE, MESSAGE_FROM_GROUP), group(MESSAGE, MESSAGE_TO_GROUP)
			);
			final node: Null<QueryNode> = span == null ? null : typer?.exactly(span);
			if (typer == null || node == null || span == null) {
				report.unscored(area, '$label (no node at that range)');
				continue;
			}
			// a warning is a `$$type` answer only when `$$type(` encloses that range; any other is a macro's own message
			if (warning && !typer.typeProbed(span)) {
				report.unscored('misc/other', label);
				continue;
			}
			if (warning)
				typeAt(report, area, label, expected, typer, node)
			else
				shouldBe(report, area, label, expected, typer, node);
		}
	}

	/**
	 * The `should be` error `label` at the range of `node`, its value of type `expected`, asked of `typer`: the value failing
	 * the type written there for an ascription's range; not asked at an operator's range, where the compiler reports an
	 * operand failing what the operator wants (`operators.ml`), not the operator's own value.
	 */
	private static function shouldBe(
		report: Report, area: String, label: String, expected: String, typer: FileTyper, node: QueryNode
	): Void {
		if (typer.isOperator(node))
			report.unscored(area, '$label (an operand\'s error, reported at the operator\'s range)')
		else
			typeAt(report, area, label, expected, typer, typer.failingValue(node));
	}

	/**
	 * Whether the chain under the error at `lines[at]` — its `... ` lines — holds a `have:` line: the error's own
	 * `A should be B` then names the innermost pair that failed, a part of the expression's type, and `have` a view of
	 * the whole that is not the type's own spelling (a class shown as the structure it was unified as).
	 */
	private static function chained(lines: Array<String>, at: Int): Bool {
		for (line in lines.slice(at + 1)) {
			if (!line.contains(' : ... ')) return false;
			if (line.contains(' : ... have: ')) return true;
		}
		return false;
	}

	/**
	 * Compiles the project in the working directory with the facts hook and scores every case of it into `report`; what the
	 * run read — the configurations that compiled and those dropped, the files, the cases — is returned, so a caller that
	 * gates on the reading can refuse one that read nothing (`probeRefusal`).
	 */
	private static function facts(configuration: Null<String>, report: Report): FactsRun {
		final config: LintConfig = LintConfig.discover(Path.join([Sys.getCwd(), 'TyperConformance.hx']));
		final project: Array<{ file: String, source: String }> = [];
		for (root in config.resolutionRoots()) collect(root, project);
		final library: Array<{ file: String, source: String }> = libraryOf(config, project);
		final asked: Array<OracleConfig> = [
			for (o in config.compilerOracles()) if (configuration == null || o.hxml.contains(configuration)) o
		];
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final sources: Map<String, String> = [for (f in project) FileSystem.fullPath(f.file) => f.source];
		final oracle: Null<FactsTypeOracle> = switch TypedFactsProbe.probeAll(OracleGeneration.prepare(asked).oracles) {
			case null: null;
			case table: new FactsTypeOracle(table, key -> sources[key], null, plugin);
		};
		if (oracle == null) {
			Sys.println('facts: no configuration compiled');
			return {
				configurations: 0,
				dropped: [for (o in asked) '${o.hxml}: no facts'],
				files: project.length,
				compiled: 0,
				cases: 0
			};
		}
		Sys.println('facts: configurations ${oracle.facts.configurations}, dropped ${oracle.facts.dropped}');
		final index: SymbolIndex = IndexScope.over(project.concat(library), plugin, [for (f in library) f.file]);
		final aliases: Map<String, Array<Array<String>>> = typedefTargets(oracle);
		final before: Int = report.scored();
		var compiledFiles: Int = 0;
		for (f in project) {
			final key: String = FileSystem.fullPath(f.file);
			final typer: Null<FileTyper> = FileTyper.within(plugin, index, f.file, f.source);
			if (typer == null || !oracle.facts.compiled(key)) continue;
			compiledFiles++;
			typer.visit(factsCase.bind(report, oracle, aliases, key, f.file, typer));
		}
		Sys.println('facts: ${project.length} project files under ${config.resolutionRoots()}, $compiledFiles of them compiled');
		return {
			configurations: oracle.facts.configurations.length,
			dropped: [for (d in oracle.facts.dropped) '${d.name}: ${d.reason}'],
			files: project.length,
			compiled: compiledFiles,
			cases: report.scored() - before
		};
	}

	/** The libraries and the standard library the project in `config` resolves against, its own files left out. */
	private static function libraryOf(
		config: LintConfig, project: Array<{ file: String, source: String }>
	): Array<{ file: String, source: String }> {
		final libs: Array<{ file: String, source: String }> = [];
		for (name in config.resolutionLibs()) {
			final dir: Null<String> = HaxelibResolver.libSourceDir(name);
			if (dir != null) collect(dir, libs);
		}
		final std: Null<String> = StdResolver.stdDir();
		if (std != null) collect(std, libs);
		final held: Map<String, Bool> = [for (f in project) FileSystem.fullPath(f.file) => true];
		return [for (f in libs) if (!held.exists(FileSystem.fullPath(f.file))) f];
	}

	/**
	 * The facts case of `node` of `file` (table key `key`): the compiler's value type there asked of `typer`, unless the
	 * facts at that range are not the text's own — the body an inlined call spliced there, a copy of an inline body typed in
	 * a caller's terms, the compiler's own code lowered into the range, the implicit `this` a bare member read shares it with,
	 * the `haxe.PosInfos` object the compiler hands a `?pos` parameter at the call's own range, the value an inlined call hands
	 * a parameter it leaves out (`leavesAnInlinedArgumentOut`).
	 */
	private static function factsCase(
		report: Report, oracle: FactsTypeOracle, aliases: Map<String, Array<Array<String>>>, key: String, file: String, typer: FileTyper,
		node: QueryNode
	): Void {
		final at: Null<Span> = node.span;
		final compiled: Null<String> = at == null
			? null
			: switch oracle.valueType(key, at) {
				case Typed(type): type;
				case Declined(_): null;
			};
		if (at == null || compiled == null) return;
		final label: String = '$file:${at.from}: $compiled';
		// an operator an inlined overload takes holds the overload's body at its range, its operands bound there
		final spliced: Bool = typer.inlinedOverload(node)
			|| oracle.facts.nodesAround(key, at).exists(
				n ->
					n.inlinedFrom != null
					|| n.calls.exists(c -> c.access == INLINED_ACCESS && c.site?.span.from == at.from && c.site?.span.to == at.to)
			);
		if (spliced)
			report.unscored('facts/${node.kind}', '$label (inlined code)')
		else if (typer.namesNoValueOf(node, compiled, CLASS_VALUE))
			report.unscored('facts/${node.kind}', '$label (the compiler\'s own code at that range)')
		else if (typer.isIdentifier(node) && typer.namesNoValueOf(node, compiled, ENUM_VALUE))
			report.unscored('facts/${node.kind}', '$label (the enum value a constructor read bare is read off)')
		else if (typer.implicitReceiver(node, outerOf(normalized(compiled))))
			report.unscored('facts/${node.kind}', '$label (the implicit receiver of a member read)')
		else if (typer.isCall(node) && isPosInfos(normalized(compiled)))
			report.unscored('facts/${node.kind}', '$label (the haxe.PosInfos argument the compiler adds at a call)')
		else if (leavesAnInlinedArgumentOut(oracle, key, node, at, compiled, typer))
			report.unscored('facts/${node.kind}', '$label (an inlined call leaving an argument out: the value it hands it, not the call)')
		else
			typeAt(report, 'facts/${node.kind}', label, compiled, typer, node, aliases);
	}

	/**
	 * Whether `node`, at `at` of the file `key`, is a call the compiler inlined leaving out an argument of the type it typed
	 * there (`compiled`): an `inlined` call fact of a method of the callee's name whose site holds the range, that method's
	 * node declaring a parameter of that type past the arguments the call passes. The facts record an inlined call at the
	 * innermost expression around it (`CallFact.site`, the enclosing statement), never at the call itself, so that type is the
	 * value the compiler hands the parameter left out — its default — and not the call's: a limit of this harness, not an
	 * answer of the typer.
	 */
	private static function leavesAnInlinedArgumentOut(
		oracle: FactsTypeOracle, key: String, node: QueryNode, at: Span, compiled: String, typer: FileTyper
	): Bool {
		final callee: Null<String> = typer.isCall(node) && node.children.length > 0 ? node.children[0].name : null;
		final passed: Int = node.children.length - 1;
		final want: String = normalized(compiled);
		return callee != null && oracle.facts.nodesAround(key, at).exists(n -> n.calls.exists(c -> {
			final site: Null<FactPos> = c.site;
			final target: Null<String> = c.target;
			final method: Null<FactNode> = target == null ? null : oracle.facts.node(target);
			c.access == INLINED_ACCESS && site != null && site.span.from <= at.from && at.to <= site.span.to && target != null
				&& SourceText.lastSegment(target) == callee && method != null
				&& method.params.slice(passed).exists(p -> normalized(p.type) == want);
		}));
	}

	/**
	 * The typer's two answers for `node` — written source and nominal — scored against the compiler's `expected` type. A
	 * typer name that is a typedef the compiler printed through (`Signal0` for `Priority<Listener0>`), or the class a
	 * `@:generic` one expands to (`TypedPool_pony_ui_touch_Touch`), is the same type spelled another way: the nominal
	 * follows the alias, and a source the harness cannot expand to the same text is unscored, not a match. A typedef whose
	 * alias the index cannot follow — one declared in several `#if` branches — but which every typedef of its name the
	 * compiled build typed aliases to the compiler's type (`aliases`, `typedefTargets`) is unscored in both currencies: the
	 * same type in that build, not shown to be in every one.
	 */
	private static function typeAt(
		report: Report, area: String, label: String, expected: String, typer: FileTyper, node: Null<QueryNode>,
		?aliases: Map<String, Array<Array<String>>>
	): Void {
		final want: String = normalized(expected);
		final outer: String = outerOf(want);
		final typedefs: Map<String, Array<Array<String>>> = aliases ?? [];
		final compiledAlias: (String) -> Bool = name -> {
			final targets: Null<Array<Array<String>>> = typedefs[name];
			targets != null && targets.length > 0 && targets.foreach(t -> t.length > 0 && t.foreach(x -> x == outer));
		};
		final source: Null<String> = node == null ? null : typer.source(node);
		final nominal: Null<String> = node == null ? null : typer.nominal(node);
		final named: Null<String> = nominal == null ? null : SourceText.lastSegment(nominal);
		final sourceOuter: Null<String> = source == null ? null : outerOf(normalized(source));
		if (source == null)
			report.score('$area (source)', label, Unknown)
		else if (normalized(source) == want)
			report.score('$area (source)', label, Match)
		else if (sourceOuter != null && (typer.spellsAlike(sourceOuter, outer) || compiledAlias(sourceOuter)))
			report.unscored('$area (source)', '$label (an alias or a generic expansion of $source)')
		else
			report.score('$area (source)', label, Different(source));
		if (named == null)
			report.score('$area (nominal)', label, Unknown)
		else if (named == outer || typer.aliased(named) == outer)
			report.score('$area (nominal)', label, Match)
		else if (typer.spellsAlike(named, outer))
			report.unscored('$area (nominal)', '$label (a generic expansion of $named)')
		else if (compiledAlias(named))
			report.unscored('$area (nominal)', '$label (a typedef the compiled build aliases to it: $named)')
		else
			report.score('$area (nominal)', label, Different(named));
		censusRoots(report, area, label, typer, node, source == null, named == null);
	}

	/**
	 * Every typedef the compiled build typed, by simple name: for each, the outer simple names of the types a configuration
	 * aliased it to (`TypeFact.targets`), in the spelling `typeAt` compares in.
	 */
	private static function typedefTargets(oracle: FactsTypeOracle): Map<String, Array<Array<String>>> {
		final out: Map<String, Array<Array<String>>> = [];
		for (id in oracle.facts.typeIds()) {
			final t: Null<TypeFact> = oracle.facts.type(id);
			if (t == null || t.kind != TYPEDEF_KIND) continue;
			final name: String = SourceText.lastSegment(id);
			final all: Array<Array<String>> = out[name] ?? [];
			all.push([for (target in t.targets) outerOf(normalized(target))]);
			out[name] = all;
		}
		return out;
	}

	private static function positionVerdict(expected: Span, found: Null<Span>): Verdict {
		return found == null
			? Unknown
			: found.from == expected.from && found.to == expected.to ? Match : Different('${found.from}-${found.to}');
	}

	/** `found` against `expected`, the whole list or (`firstOnly`) its first range. */
	private static function usageVerdict(expected: Array<Span>, found: Null<Array<Span>>, firstOnly: Bool): Verdict {
		if (found == null) return Unknown;
		final got: Array<String> = [for (s in found) '${s.from}-${s.to}'];
		got.sort(Reflect.compare);
		final want: Array<String> = [for (s in expected) '${s.from}-${s.to}'];
		want.sort(Reflect.compare);
		final same: Bool = firstOnly ? got.length > 0 && got[0] == want[0] : got.join(',') == want.join(',');
		return same ? Match : Different(got.join(','));
	}

	/** `type` in the one spelling both sides are compared in (`TypeText`), or the text itself when it does not read as one. */
	private static function normalized(type: String): String {
		return TypeText.canonical(type) ?? type;
	}

	/** The outermost type name of a normalized type text. */
	private static function outerOf(type: String): String {
		final open: Int = type.indexOf('<');
		return open < 0 ? type : type.substring(0, open);
	}

	/** Whether the normalized `type` is `haxe.PosInfos` as the compiler prints it: the structure of its four fields and more. */
	private static function isPosInfos(type: String): Bool {
		return ['className:String', 'fileName:String', 'lineNumber:Int', 'methodName:String'].foreach(f -> type.contains(f))
			&& type.startsWith('{');
	}

	/** `r`'s group `n` read as a number, -1 when it is none. */
	private static function group(r: EReg, n: Int): Int {
		return Std.parseInt(r.matched(n)) ?? -1;
	}

	private static function unescape(text: String): String {
		return text.replace('\\"', '"').replace('\\\\', '\\');
	}

	private static function rangeOf(markers: Map<Int, Int>, from: String, to: String): Null<Span> {
		final a: Null<Int> = markers[Std.parseInt(from) ?? -1];
		final b: Null<Int> = markers[Std.parseInt(to) ?? -1];
		return a == null || b == null ? null : new Span(a, b);
	}

	private static function rangesOf(markers: Map<Int, Int>, list: String): Array<Span> {
		final out: Array<Span> = [];
		var rest: String = list;
		while (RANGE.match(rest)) {
			final r: Null<Span> = rangeOf(markers, RANGE.matched(1), RANGE.matched(2));
			if (r != null) out.push(r);
			rest = RANGE.matchedRight();
		}
		return out;
	}

	/** The offset of the `}` closing the block whose body starts at `from`. */
	private static function closingBrace(text: String, from: Int): Int {
		var depth: Int = 1;
		var i: Int = from;
		while (i < text.length && depth > 0) {
			final c: String = text.charAt(i);
			if (c == '"' || c == "'") {
				i = text.indexOf(c, i + 1) + 1;
				if (i == 0) return text.length;
				continue;
			}
			if (c == '{') depth++;
			if (c == '}') depth--;
			i++;
		}
		return i - 1;
	}

	/** The top-level statements of a function body, each trimmed and without its `;`. */
	private static function statementsOf(body: String): Array<String> {
		final out: Array<String> = [];
		var depth: Int = 0;
		var start: Int = 0;
		var i: Int = 0;
		while (i < body.length) {
			final c: String = body.charAt(i);
			if (c == '"' || c == "'") {
				final end: Int = body.indexOf(c, i + 1);
				i = end < 0 ? body.length : end + 1;
				continue;
			}
			if (c == '(' || c == '[' || c == '{') depth++;
			if (c == ')' || c == ']' || c == '}') depth--;
			if (c == ';' && depth == 0) {
				out.push(~/\s+/g.replace(body.substring(start, i), ' ').trim());
				start = i + 1;
			}
			i++;
		}
		return out;
	}

	/** The paths under `dir` ending in `suffix`. */
	private static function collectPaths(dir: String, suffix: String, into: Array<String>): Void {
		if (!FileSystem.exists(dir)) return;
		for (entry in FileSystem.readDirectory(dir)) {
			final path: String = Path.join([dir, entry]);
			if (FileSystem.isDirectory(path))
				collectPaths(path, suffix, into)
			else if (entry.endsWith(suffix))
				into.push(path);
		}
	}

	/** Every `.hx` file under `dir`, read. */
	private static function collect(dir: String, into: Array<{ file: String, source: String }>): Void {
		final paths: Array<String> = [];
		collectPaths(dir, '.hx', paths);
		for (path in paths) into.push({ file: path, source: File.getContent(path) });
	}

	/** Under `--census`, the roots of the typer's UNKNOWN answers for `node`: in the written-source currency, the nominal one. */
	private static function censusRoots(
		report: Report, area: String, label: String, typer: FileTyper, node: Null<QueryNode>, unknownSource: Bool, unknownNominal: Bool
	): Void {
		if (unknownSource) report.unknownRoot('source', area, label, rootOf.bind(typer, node, true));
		if (unknownNominal) report.unknownRoot('nominal', area, label, rootOf.bind(typer, node, false));
	}

	/** The root of the typer's UNKNOWN for `node` in the written-source (`sourceCurrency`) or the nominal currency. */
	private static function rootOf(typer: FileTyper, node: Null<QueryNode>, sourceCurrency: Bool): UnknownCause {
		return node == null ? { root: Other, detail: 'no node asked' } : typer.unknownCause(node, sourceCurrency);
	}

}

/** One display test: where it is, the module its doc comment compiles to, and its body's statements. */
private typedef DisplayTest = {
	final label: String;
	final file: String;
	final code: String;
	final statements: Array<String>;
}

/** How one answer of the typer compares to the compiler's. */
private enum Verdict {
	Match;
	Unknown;
	Different(got: String);
}

/** The typer's answers over ONE file of an index: the written-source and nominal currencies, a definition, its uses. */
@:nullSafety(Strict)
private final class FileTyper {

	/** The kind of a written type annotation among a node's children. */
	private static inline final ANNOTATION_KIND: String = ':';

	private final _file: String;
	private final _source: String;
	private final _tree: QueryNode;
	private final _shape: RefShape;
	private final _index: SymbolIndex;
	private final _declared: Map<Int, String>;
	private final _chain: ChainTypeContext;
	private final _nominal: Null<(QueryNode) -> Null<String>>;

	private var _causes: Null<UnknownCauses> = null;

	private function new(
		plugin: CachingGrammarPlugin, index: SymbolIndex, file: String, source: String, tree: QueryNode, provider: TypeInfoProvider
	) {
		_file = file;
		_source = source;
		_tree = tree;
		_shape = plugin.refShape();
		_index = index;
		_declared = provider.declaredTypes(source);
		_chain = {
			declaredTypeSources: provider.declaredTypeSources(source),
			source: source,
			castTargetSources: TypeInfoMemo.castTargetSources(provider, source),
			typeSyntax: plugin.typeSyntax
		};
		_nominal = CheckScan.typeNominalResolver(source, plugin, tree, file, index, false, false);
	}

	/** The simple name `name` stands for through its typedef alias hops (`TypeRefIndex.aliasedName`). */
	public inline function aliased(name: String): String {
		return _index.refs.aliasedName(name);
	}

	/** Every node of the file, outer before inner. */
	public inline function visit(f: (QueryNode) -> Void): Void {
		visitUnder(_tree, f);
	}

	/** Whether `node` is a bare identifier of the grammar. */
	public inline function isIdentifier(node: QueryNode): Bool {
		return node.kind == _shape.identKind;
	}

	/** Whether `node` is an operator the walk types by its operands (`TypingService.isArithmetic`). */
	public inline function isOperator(node: QueryNode): Bool {
		return TypingService.isArithmetic(node, _shape);
	}

	/** Whether `node` is a call of the grammar. */
	public inline function isCall(node: QueryNode): Bool {
		return node.kind == _shape.callKind;
	}

	/**
	 * Whether `node` is an operator (`isOperator`) an `inline` overload of its kind may take — the one the typer picks
	 * (`ComposedValues.operatorOverload`), else any an operand's type declares: the compiler splices the overload's body in at
	 * the operator's range, its operands bound there, so the facts at that range type the spliced code, not the operator's value.
	 */
	public function inlinedOverload(node: QueryNode): Bool {
		if (!isOperator(node)) return false;
		final operands: Array<String> = [for (operand in node.children) source(operand) ?? ''];
		final typing: IndexTyping = {
			root: _tree,
			shape: _shape,
			declaredTypes: _declared,
			chain: _chain,
			index: _index,
			file: _file,
			seen: []
		};
		// the overload the typer takes decides; where it takes none, any inline one of the kind may have been spliced
		final chosen: Null<OperatorResult> = operands.contains('') ? null : ComposedValues.operatorOverload(node, operands, typing);
		if (chosen != null) return chosen.member.isInline;
		for (written in operands) {
			final peeled: Null<String> = written == ''
				? null
				: NominalTypes.memberLookupReceiverSource(written, _shape.memberTransparentWrapperTypeNames ?? [], _chain.typeSyntax);
			final name: Null<String> = peeled == null ? null : NominalTypes.outerNominalOf(peeled, _chain.typeSyntax);
			final declares: ResolvedType -> Bool = d -> d.type.members.exists(m -> m.isInline && m.operatorOverloads.contains(node.kind));
			if (name != null && _index.refs.resolvedDeclsNamed(name).exists(declares)) return true;
		}
		return false;
	}

	/** The written type source the deep walk gives `node` (`NominalTypes.expressionTypeSource`), or null. */
	public function source(node: QueryNode): Null<String> {
		return try NominalTypes.expressionTypeSource(
			node, _tree, _shape, _declared, _index, _file, _chain
		) catch (exception: Exception) null;
	}

	/** The nominal the checks' door gives `node` (`CheckScan.typeNominalResolver`), or null. */
	public function nominal(node: QueryNode): Null<String> {
		final resolve: Null<(QueryNode) -> Null<String>> = _nominal;
		return resolve == null ? null : try resolve(node) catch (exception: Exception) null;
	}

	/** The innermost node whose range holds `at`, its end included: the expression a display query at `at` types. */
	public function innermost(at: Int): Null<QueryNode> {
		var found: Null<QueryNode> = null;
		var cur: Null<QueryNode> = _tree;
		while (cur != null) {
			found = cur;
			cur = cur.children.find(c -> c.span != null && c.span.from <= at && at <= c.span.to);
		}
		return found == _tree ? null : found;
	}

	/**
	 * The expression a display query at `at` types, or null where the harness cannot tell which one the compiler means:
	 * the innermost node holding `at` before its end, or — when that is a statement or a block — the innermost node
	 * ending at `at` (the cursor after `a` of `a;`). A node ending at `at` inside an expression that goes on (`f(1|)`,
	 * `a|+0.1`) is a seam whose display answer is the outer one's, and a cursor on the type name of a construction is
	 * answered with the constructor's signature: both null.
	 */
	public function displayed(at: Int): Null<QueryNode> {
		var inside: Null<QueryNode> = null;
		var cur: Null<QueryNode> = _tree;
		while (cur != null) {
			inside = cur;
			cur = cur.children.find(c -> c.span != null && c.span.from <= at && at < c.span.to);
		}
		if (inside == null || inside == _tree) return null;
		final container: QueryNode = inside;
		var ending: Null<QueryNode> = null;
		visitUnder(container, n -> if (n != container && n.span != null && n.span.to == at) ending = n);
		final statements: Array<String> = [for (k in [_shape.blockStmtKind, _shape.exprStatementKind]) if (k != null) k];
		if (ending != null) return statements.contains(container.kind) ? ending : null;
		return container.kind == _shape.newExprKind ? null : container;
	}

	/** Whether `$type(` encloses `span`: the compiler's warning there is the type it gave that expression. */
	public function typeProbed(span: Span): Bool {
		final open: String = '$$type(';
		return span.from >= open.length && _source.substring(span.from - open.length, span.from) == open && _source.charAt(span.to) == ')';
	}

	/**
	 * Whether the typer's simple name `typer` and the compiler's `compiled` name one type two ways: `typer` a typedef whose
	 * alias hops land on `compiled`, or `compiled` the class a `@:generic` `typer` expands to (`TypedPool_pony_ui_Touch`).
	 */
	public function spellsAlike(typer: String, compiled: String): Bool {
		return typer != compiled && (aliased(typer) == compiled || compiled.startsWith('${typer}_'));
	}

	/**
	 * Whether `compiled` is the value of a type, `wrapper` applied to it (`Class<HxOverrides>`, `Enum<Doc>`), that the text of
	 * `node` does not name: the compiler lowered the expression into code of its own there (a std call into a call of its
	 * target's runtime class), or the text reads a constructor bare (`Text`) off the enum's value it types at that range.
	 */
	public function namesNoValueOf(node: QueryNode, compiled: String, wrapper: String): Bool {
		final at: Null<Span> = node.span;
		final named: EReg = new EReg('^$wrapper<([\\w.]+)>$$', '');
		return at != null && named.match(compiled) && !_source.substring(at.from, at.to).contains(SourceText.lastSegment(named.matched(1)));
	}

	/**
	 * Whether `node` is a bare identifier and `compiled` the simple name of the type declaration holding it: a bare read of
	 * a member shares its range with the implicit `this` the compiler records as that read's receiver.
	 */
	public function implicitReceiver(node: QueryNode, compiled: String): Bool {
		final at: Null<Span> = node.span;
		return at != null && node.kind == _shape.identKind && node.name != _shape.selfReferenceText
			&& TypeResolver.enclosingTypeName(_tree, at) == compiled;
	}

	/** The innermost node spanning exactly `span`, or null. */
	public function exactly(span: Span): Null<QueryNode> {
		var found: Null<QueryNode> = null;
		visit(n -> if (n.span != null && n.span.from == span.from && n.span.to == span.to) found = n);
		return found;
	}

	/** The range of 1-based `line`, characters `from`-`to` (the compiler's end exclusive), or null past the file. */
	public function spanOfColumns(line: Int, from: Int, to: Int): Null<Span> {
		var start: Int = 0;
		for (_ in 1...line) {
			final nl: Int = _source.indexOf('\n', start);
			if (nl < 0) return null;
			start = nl + 1;
		}
		return new Span(start + from - 1, start + to - 1);
	}

	/** The name range of the declaration the identifier at `at` binds to, or null when the binder resolves none. */
	public function definitionAt(at: Int): Null<Span> {
		final hit: Null<RefHit> = hitAt(at);
		final bound: Null<Span> = hit?.bindingSpan;
		return hit == null || bound == null ? null : nameIn(bound, hit.name);
	}

	/** The name ranges of every read and write of the value the identifier or declaration at `at` binds, or null. */
	public function usagesAt(at: Int): Null<Array<Span>> {
		final hit: Null<RefHit> = hitAt(at);
		final bound: Null<Span> = hit?.bindingSpan;
		if (hit == null || bound == null) return null;
		final out: Array<Span> = [];
		for (h in Refs.find(hit.name, _tree, _shape)) {
			final b: Null<Span> = h.bindingSpan;
			if (h.kind != Decl && b != null && b.from == bound.from && b.to == bound.to) {
				final name: Null<Span> = nameIn(h.span, h.name);
				if (name == null) return null;
				out.push(name);
			}
		}
		return out;
	}

	/**
	 * The value an ascription `node` holds — the expression of `(e : T)`, the initializer of a local declaration — or `node`
	 * itself for any other: a `should be` error at an ascription's range reports that value failing the type written there.
	 */
	public function failingValue(node: QueryNode): QueryNode {
		final types: Array<String> = (_shape.typeAnnotationKinds ?? []).concat([ANNOTATION_KIND]);
		final values: Array<QueryNode> = node.children.filter(c -> !types.contains(c.kind));
		final held: Null<QueryNode> = if (node.kind == _shape.checkTypeKind && values.length == 1)
			values[0]
		else if ((_shape.localDeclKinds ?? []).contains(node.kind))
			CtorFieldFold.declInitializer(node, _shape)
		else
			null;
		return held ?? node;
	}

	/** The root of the UNKNOWN this typer answers for `node` in the written-source (`sourceCurrency`) or the nominal currency. */
	public function unknownCause(node: QueryNode, sourceCurrency: Bool): UnknownCause {
		final causes: UnknownCauses = _causes ?? new UnknownCauses(this, _tree, _shape, _index);
		_causes = causes;
		return causes.of(node, sourceCurrency);
	}

	/** `root` and every node under it, outer before inner. */
	private function visitUnder(root: QueryNode, f: (QueryNode) -> Void): Void {
		final stack: Array<QueryNode> = [root];
		while (stack.length > 0) {
			final n: QueryNode = stack.pop() ?? root;
			f(n);
			for (i in 0...n.children.length) stack.push(n.children[n.children.length - 1 - i]);
		}
	}

	/**
	 * The reference hit whose name token holds `at` — a read, a write or a declaration — when it binds a LOCAL: a local
	 * declaration or a parameter, the bindings the reference walk resolves by scope. Any other binding (a member reached
	 * bare, a type, a capture) is not asked of it, so null.
	 */
	private function hitAt(at: Int): Null<RefHit> {
		final node: Null<QueryNode> = innermost(at);
		final name: Null<String> = node?.name;
		if (node == null || name == null) return null;
		for (h in Refs.find(name, _tree, _shape)) {
			final token: Null<Span> = nameIn(h.span, name);
			final kind: Null<String> = h.bindingNode?.kind;
			final locals: Array<String> = (_shape.localDeclKinds ?? []).concat(_shape.paramKinds ?? []);
			if (token != null && token.from <= at && at <= token.to) return kind != null && locals.contains(kind) ? h : null;
		}
		return null;
	}

	/** The range of the first whole-word `name` inside `span`. */
	private function nameIn(span: Span, name: String): Null<Span> {
		final at: Int = SourceText.identTokenOffset(_source, span, name);
		return at < 0 ? null : new Span(at, at + name.length);
	}

	/** The typer of `file` over an index of `files` and the library `std`; null when it does not parse. */
	public static function over(
		plugin: CachingGrammarPlugin, files: Array<{ file: String, source: String }>, std: Array<{ file: String, source: String }>,
		file: String
	): Null<FileTyper> {
		final own: Null<{ file: String, source: String }> = files.find(f -> f.file == file);
		if (own == null) return null;
		return within(plugin, IndexScope.over(files.concat(std), plugin, [for (f in std) f.file]), file, own.source);
	}

	/** The typer of `file` over `index`; null when it does not parse. */
	public static function within(plugin: CachingGrammarPlugin, index: SymbolIndex, file: String, source: String): Null<FileTyper> {
		final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, source);
		final provider: Null<TypeInfoProvider> = RunScan.typeInfoOf(plugin);
		return tree == null || provider == null ? null : new FileTyper(plugin, index, file, source, tree, provider);
	}

}

/**
 * Where an UNKNOWN answer of the typer comes from, as `--census` tallies it. The `F` roots are the inference forms
 * (`docs/typing-service.md`): a monomorph a local's body binds, a signature a body or an initializer gives, a type an
 * expected type gives; the others are what the typing layers do not answer yet without any inference.
 */
private enum abstract UnknownRoot(String) to String {

	/** A local declared without a type or a parameter of a local function: a monomorph its uses bind. */
	var LocalMonomorph = 'F1-local-monomorph';

	/** A member written without its return or its field type: the signature its body or initializer gives. */
	var InferredSignature = 'F2-inferred-signature';

	/** A lambda parameter written without a type: the one the lambda's expected type gives it. */
	var LambdaParameter = 'F3-lambda-parameter';

	/** A literal or a lambda value typed from the type expected where it stands. */
	var ExpectedLiteral = 'F3-literal-or-lambda-value';

	/** A declaration node (`final x: T = …`, a local function): the compiler types it, the typer is not asked it. */
	var DeclarationNode = 'declaration-node';

	/** A type name read as a value, `Class<T>`. */
	var TypeExpression = 'type-expression';

	/** A member the receiver's type does not declare: a static extension, a std gap, a structure. */
	var MemberNotFound = 'member-not-found';

	/** A member, a local or a parameter with its type written, read without that type. */
	var DeclaredTypeNotRead = 'declared-type-not-read';

	/** A name a pattern or another binder declares. */
	var PatternCapture = 'pattern-capture';

	var LoopElement = 'loop-element';
	var IndexAccess = 'index-access';

	/** A construction in the written-source currency. */
	var Construction = 'construction';

	var OperatorResult = 'operator-result';

	/** `(e : T)`, its type written. */
	var CheckType = 'check-type';

	/** A segment of an interpolated string. */
	var StringSegment = 'string-segment';

	var Other = 'other';
}

/** The root of one UNKNOWN answer and what in the code led to it. */
private typedef UnknownCause = {
	final root: UnknownRoot;
	final detail: String;
}

/** What one `facts` run read (`TyperConformance.probeRefusal`). */
typedef FactsRun = {
	/** The configurations the compiler compiled with the facts hook. */
	final configurations: Int;

	/** Each configuration it dropped, with the reason. */
	final dropped: Array<String>;

	/** The project's files. */
	final files: Int;

	/** The project files some configuration compiled. */
	final compiled: Int;

	/** The cases scored, every verdict counted. */
	final cases: Int;
}

/**
 * The roots of the UNKNOWN answers of one `FileTyper` (`--census`): from the expression asked through what it is made
 * of — an identifier to its binding, a call to its callee, a member access to its receiver, a declaration to its
 * initializer — to the first thing the typer could not answer. An estimate that measures the typer, never one of its
 * answers: a kind with no rule here is rooted at its first unanswered child, and a callee parameter naming a single
 * capital letter is taken for a class type parameter.
 */
@:nullSafety(Strict)
private final class UnknownCauses {

	/** Past this many hops a chain is cut and rooted as other. */
	private static inline final MAX_DEPTH: Int = 16;

	/** The wrapper a nullable receiver's type is read through. */
	private static inline final NULL_WRAPPER: String = 'Null<';

	/** The kind of the `k => v` binder of a `for`. */
	private static inline final KEY_VALUE_BINDER: String = 'KeyValueBinder';

	/** The kind of a written type annotation among a declaration's children. */
	private static inline final ANNOTATION_KIND: String = ':';

	/** The kind of a literal segment of an interpolated string. */
	private static inline final STRING_SEGMENT_KIND: String = 'Literal';

	private static inline final FN_MEMBER_KIND: String = 'FnMember';

	/** The kinds whose value is the result of an operator over typed operands. */
	private static final OPERATOR_KINDS: Array<String> = [
		'Add',
		'Sub',
		'Mul',
		'Div',
		'Neg',
		'Mod',
		'AddAssign',
		'SubAssign',
		'Interval',
		'NullCoal',
		'Ternary',
		'PostIncr',
		'PreIncr'
	];

	/** The operator kinds whose value is a `Bool` whatever their operands. */
	private static final BOOL_OPERATOR_KINDS: Array<String> = [
		'Eq', 'NotEq', 'Lt', 'Gt', 'LtEq', 'GtEq', 'Lte', 'Gte', 'And', 'Or', 'Not', 'Is'
	];

	/** The kinds a written return type of a function declaration takes. */
	private static final RETURN_TYPE_KINDS: Array<String> = ['Named', 'Anon', 'ArrowFn', 'Arrow', 'TypeRef'];

	private final _memo: Map<String, UnknownCause> = [];
	private final _hitsByName: Map<String, Array<RefHit>> = [];
	private final _parents: Map<QueryNode, QueryNode> = [];
	private final _typer: FileTyper;
	private final _shape: RefShape;
	private final _index: SymbolIndex;
	private final _tree: QueryNode;
	private final _lambdaKinds: Array<String>;
	private final _accessKinds: Array<String>;

	public function new(typer: FileTyper, tree: QueryNode, shape: RefShape, index: SymbolIndex) {
		_typer = typer;
		_tree = tree;
		_shape = shape;
		_index = index;
		_lambdaKinds = (shape.lambdaKinds ?? []).concat([
			for (k in [shape.fnExprKind, shape.namedFnExprKind, shape.parenLambdaKind]) if (k != null) k
		]);
		_accessKinds = [
			for (k in [shape.fieldAccessKind, shape.nullSafeAccessKind, shape.forceFieldAccessKind]) if (k != null) k
		];
		final stack: Array<QueryNode> = [tree];
		while (stack.length > 0) {
			final n: QueryNode = stack.pop() ?? tree;
			for (c in n.children) {
				_parents[c] = n;
				stack.push(c);
			}
		}
	}

	/** The root of the UNKNOWN the typer answers for `node` in the written-source (`sourceCurrency`) or the nominal currency. */
	public function of(node: QueryNode, sourceCurrency: Bool): UnknownCause {
		return try cause(node, sourceCurrency, 0) catch (exception: Exception) rooted(Other, 'exception ${exception.message}');
	}

	/** An initializer that leaves its local a monomorph: `null`, `[]`. */
	private inline function isMonomorphSeed(init: QueryNode): Bool {
		return init.kind == _shape.nullLiteralKind || init.kind == _shape.arrayLiteralKind && init.children.length == 0;
	}

	/** `node`'s root, memoised; a chain that comes back to a node it is still walking is rooted as a cycle. */
	private function cause(node: QueryNode, sc: Bool, depth: Int): UnknownCause {
		final at: Null<Span> = node.span;
		final key: String = '$sc:${node.kind}:${at?.from}:${at?.to}';
		final known: Null<UnknownCause> = _memo[key];
		if (known != null) return known;
		_memo[key] = rooted(Other, 'cycle');
		final found: UnknownCause = depth > MAX_DEPTH ? rooted(Other, 'deep chain') : causeOf(node, sc, depth);
		_memo[key] = found;
		return found;
	}

	private function causeOf(node: QueryNode, sc: Bool, depth: Int): UnknownCause {
		final k: String = node.kind;
		if (k == _shape.parenKind && node.children.length == 1) return cause(node.children[0], sc, depth + 1);
		if (_lambdaKinds.contains(k)) return rooted(ExpectedLiteral, 'lambda value${expectedTag(node)}');
		if (k == _shape.objectLiteralKind || k == _shape.nullLiteralKind) return rooted(ExpectedLiteral, '$k${expectedTag(node)}');
		if (k == _shape.arrayLiteralKind) return rooted(ExpectedLiteral, '${node.children.length == 0 ? '[]' : k}${expectedTag(node)}');
		if (k == _shape.newExprKind) return rooted(Construction, k);
		if (k == _shape.checkTypeKind) return rooted(CheckType, k);
		if (isLocalDeclaration(k)) return declarationCause(node, sc, depth);
		if ((_shape.localFunctionKinds ?? []).contains(k)) return rooted(DeclarationNode, 'local function');
		if (BOOL_OPERATOR_KINDS.contains(k)) return rooted(OperatorResult, 'bool-valued operator');
		if (k == _shape.identKind) return identCause(node, sc, depth);
		if (k == _shape.callKind) return callCause(node, sc, depth);
		if (_accessKinds.contains(k)) return accessCause(node, sc, depth, false);
		return childCause(node, sc, depth);
	}

	/** A kind with no rule of its own: its first unanswered operand, or the kind itself when the typer answers every one. */
	private function childCause(node: QueryNode, sc: Bool, depth: Int): UnknownCause {
		for (c in node.children) if (isExpr(c) && !typed(c, sc)) return cause(c, sc, depth + 1);
		final k: String = node.kind;
		final root: UnknownRoot = if (OPERATOR_KINDS.contains(k))
			OperatorResult
		else if (k == _shape.indexAccessKind)
			IndexAccess
		else if (k == STRING_SEGMENT_KIND)
			StringSegment
		else
			Other;
		return rooted(root, k);
	}

	/** A local declaration asked as a node: typed by its initializer, or the monomorph of one with none. */
	private function declarationCause(node: QueryNode, sc: Bool, depth: Int): UnknownCause {
		if (annotated(node)) return rooted(DeclarationNode, 'annotated declaration');
		final init: Null<QueryNode> = initOf(node);
		if (init == null) return rooted(LocalMonomorph, 'declaration without an initializer');
		if (isMonomorphSeed(init)) return rooted(LocalMonomorph, 'declaration initialized with ${init.kind}');
		if (typed(init, sc)) return rooted(DeclarationNode, 'unannotated declaration, its initializer typed');
		final inner: UnknownCause = cause(init, sc, depth + 1);
		final inferred: Bool = [LocalMonomorph, InferredSignature, LambdaParameter, ExpectedLiteral].contains(inner.root);
		return rooted(inferred ? inner.root : DeclarationNode, 'unannotated declaration <- ${inner.root}: ${inner.detail}');
	}

	private function identCause(node: QueryNode, sc: Bool, depth: Int): UnknownCause {
		final name: Null<String> = node.name;
		if (name == null) return rooted(Other, 'nameless identifier');
		if (name == _shape.selfReferenceText) return rooted(Other, name);
		final b: Null<QueryNode> = hitOf(node)?.bindingNode;
		if (b == null)
			return _index.refs.declsNamed(name).length > 0
				? rooted(TypeExpression, 'type name as value')
				: memberCause(enclosingType(node), name, false);
		final bk: String = b.kind;
		if ((_shape.localDeclKinds ?? []).contains(bk)) return localCause(b, sc, depth);
		if ((_shape.paramKinds ?? []).contains(bk)) return paramCause(b);
		if ((_shape.iterationBindingKinds ?? []).contains(bk) || bk == KEY_VALUE_BINDER) return loopCause(b, sc, depth);
		if ((_shape.localFunctionKinds ?? []).contains(bk)) return rooted(Other, 'local function value');
		if ((_shape.fieldDeclKinds ?? []).contains(bk))
			return annotated(b)
				? rooted(DeclaredTypeNotRead, 'annotated member read bare')
				: rooted(InferredSignature, 'member field without a type');
		if (bk == FN_MEMBER_KIND) return rooted(Other, 'method value');
		return rooted(PatternCapture, 'identifier bound to $bk');
	}

	/** A read of the local `decl` declares. */
	private function localCause(decl: QueryNode, sc: Bool, depth: Int): UnknownCause {
		if (annotated(decl)) return rooted(DeclaredTypeNotRead, 'annotated local');
		final init: Null<QueryNode> = initOf(decl);
		if (init == null) return rooted(LocalMonomorph, 'local without an initializer');
		if (isMonomorphSeed(init)) return rooted(LocalMonomorph, 'local initialized with ${init.kind}');
		return typed(init, sc) ? rooted(DeclaredTypeNotRead, 'local whose initializer is typed') : cause(init, sc, depth + 1);
	}

	/** A read of the parameter `param`: written, a lambda's (its expected type), or another function's. */
	private function paramCause(param: QueryNode): UnknownCause {
		if (annotated(param)) return rooted(DeclaredTypeNotRead, 'annotated parameter');
		final fn: Null<QueryNode> = _parents[param];
		final fk: String = fn?.kind ?? '?';
		if (fn != null && _lambdaKinds.contains(fk)) return rooted(LambdaParameter, 'lambda parameter${expectedTag(fn)}${calleeWhy(fn)}');
		if ((_shape.localFunctionKinds ?? []).contains(fk)) return rooted(LocalMonomorph, 'local function parameter without a type');
		return rooted(LocalMonomorph, 'parameter without a type in $fk');
	}

	/** A read of a loop's binder `binder`: the element of what the loop iterates. */
	private function loopCause(binder: QueryNode, sc: Bool, depth: Int): UnknownCause {
		final loop: Null<QueryNode> = binder.kind == KEY_VALUE_BINDER ? _parents[binder] : binder;
		final iterated: Null<QueryNode> = loop?.children.find(c -> c.kind != KEY_VALUE_BINDER);
		if (iterated == null) return rooted(LoopElement, 'loop binder');
		return typed(iterated, sc) ? rooted(LoopElement, 'loop binder, its iterable typed') : cause(iterated, sc, depth + 1);
	}

	private function callCause(node: QueryNode, sc: Bool, depth: Int): UnknownCause {
		if (node.children.length == 0) return rooted(Other, 'shapeless call');
		final callee: QueryNode = node.children[0];
		final ck: String = callee.kind;
		if (_accessKinds.contains(ck)) return accessCause(callee, sc, depth, true);
		if (ck != _shape.identKind) return typed(callee, sc) ? rooted(Other, 'call of a typed $ck') : cause(callee, sc, depth + 1);
		final b: Null<QueryNode> = hitOf(callee)?.bindingNode;
		if (b == null) return memberCause(enclosingType(node), callee.name ?? '', true);
		if ((_shape.localFunctionKinds ?? []).contains(b.kind))
			return returnAnnotated(b)
				? rooted(DeclaredTypeNotRead, 'call of an annotated local function')
				: rooted(InferredSignature, 'call of a local function without a return type');
		if (b.kind == FN_MEMBER_KIND)
			return returnAnnotated(b)
				? rooted(DeclaredTypeNotRead, 'bare call of an annotated member')
				: rooted(InferredSignature, 'call of a member function without a return type');
		return typed(callee, sc) ? rooted(Other, 'call of a typed function value') : cause(callee, sc, depth + 1);
	}

	/** A member access `access` (`call`: as a callee): the receiver's root while it is unanswered, else the member's. */
	private function accessCause(access: QueryNode, sc: Bool, depth: Int, call: Bool): UnknownCause {
		if (access.children.length == 0) return rooted(Other, 'shapeless member access');
		final recv: QueryNode = access.children[0];
		final named: Null<String> = staticReceiver(recv);
		if (named != null) return memberCause(named, access.name ?? '', call);
		if (!typed(recv, sc)) return cause(recv, sc, depth + 1);
		return memberCause(receiverType(recv, sc), access.name ?? '', call);
	}

	/** The member `name` of `typeName` read or (`call`) called. */
	private function memberCause(typeName: Null<String>, name: String, call: Bool): UnknownCause {
		final what: String = call ? 'call' : 'read';
		if (typeName == null) return rooted(Other, '$what with no receiver type');
		final decls: Array<MemberDeclaration> = _index.typing.members.receiverDeclarationsOf(SourceText.lastSegment(typeName), name);
		if (decls.length == 0) return rooted(MemberNotFound, '$what of a member the receiver type does not declare');
		if (!call) {
			final fields: Array<MemberDeclaration> = decls.filter(d -> d.member.signatures.length == 0);
			if (fields.length == 0) return rooted(Other, 'method value');
			return fields.exists(d -> d.member.typeSource == null)
				? rooted(InferredSignature, 'member field without a type')
				: rooted(DeclaredTypeNotRead, 'read of an annotated member');
		}
		if (decls.exists(d -> d.member.hasOverloadMeta || d.member.isOverload)) return rooted(Other, 'call of an overloaded member');
		final fns: Array<MemberDeclaration> = decls.filter(d -> d.member.signatures.length > 0);
		if (fns.length == 0) return rooted(Other, 'call of a field value');
		if (fns.exists(d -> d.member.returnSource == null && !d.member.isMacro && d.member.name != 'new'))
			return rooted(InferredSignature, 'call of a member function without a return type');
		if (fns.exists(d -> d.member.typeParamNames.length > 0)) return rooted(Other, 'call of a generic method');
		return rooted(DeclaredTypeNotRead, 'call of an annotated member');
	}

	/** Why `lambda`, an argument of a call, gets no expected type for its parameters: the callee and what it declares there. */
	private function calleeWhy(lambda: QueryNode): String {
		var arg: QueryNode = lambda;
		var p: Null<QueryNode> = _parents[lambda];
		while (p != null && p.kind == _shape.parenKind) {
			arg = p;
			p = _parents[p];
		}
		if (p == null || p.kind != _shape.callKind || p.children[0] == arg) return '';
		final index: Int = p.children.indexOf(arg) - 1;
		final callee: QueryNode = p.children[0];
		final name: String = callee.name ?? '';
		if (callee.kind == _shape.identKind) {
			final b: Null<QueryNode> = hitOf(callee)?.bindingNode;
			if (b != null) return ' / callee bound to ${b.kind}';
			final enclosing: Null<String> = enclosingType(callee);
			return enclosing == null ? ' / no enclosing type' : parameterWhy(enclosing, name, index);
		}
		if (callee.kind != _shape.fieldAccessKind && callee.kind != _shape.nullSafeAccessKind) return ' / callee ${callee.kind}';
		final recv: QueryNode = callee.children[0];
		final host: Null<String> = staticReceiver(recv) ?? (typed(recv, true) ? receiverType(recv, true) : null);
		return host == null ? ' / receiver untyped' : parameterWhy(host, name, index);
	}

	/** What the member `name` of `typeName` declares for its parameter `index`. */
	private function parameterWhy(typeName: String, name: String, index: Int): String {
		final decls: Array<MemberDeclaration> = _index.typing.members.receiverDeclarationsOf(SourceText.lastSegment(typeName), name);
		if (decls.length == 0) return ' / callee not declared on the receiver type (extension, std, structure)';
		final m: MemberInfo = decls[0].member;
		if (m.hasOverloadMeta || m.isOverload) return ' / overloaded callee';
		final pt: Null<String> = index >= 0 && index < m.paramTypeSources.length ? m.paramTypeSources[index] : null;
		if (pt == null) return ' / callee parameter untyped or out of range';
		final written: String = pt;
		if (m.typeParamNames.exists(t -> new EReg('\\b$t\\b', '').match(written)))
			return ' / callee parameter mentions a METHOD type parameter';
		if (~/\b[A-Z]\b/.match(written)) return ' / callee parameter mentions a CLASS type parameter';
		return ' / callee parameter concrete';
	}

	/** Where `node` stands, the slot its expected type would come from. */
	private function expectedTag(node: QueryNode): String {
		final p: Null<QueryNode> = _parents[node];
		if (p == null) return ' [no parent]';
		final pk: String = p.kind;
		if (pk == _shape.callKind) return p.children[0] == node ? ' [callee]' : ' [call argument]';
		if (pk == _shape.newExprKind) return ' [constructor argument]';
		if ((_shape.localDeclKinds ?? []).contains(pk)) return annotated(p) ? ' [annotated local]' : ' [unannotated local]';
		if ((_shape.fieldDeclKinds ?? []).contains(pk)) return annotated(p) ? ' [annotated member]' : ' [unannotated member]';
		if ((_shape.valueReturnKinds ?? []).contains(pk)) return ' [return]';
		if (pk == _shape.assignKind) return ' [assignment]';
		if (pk == _shape.objectFieldKind) return ' [object field]';
		if (pk == _shape.arrayLiteralKind) return ' [array element]';
		if (pk == _shape.parenKind) return expectedTag(p);
		return ' [$pk]';
	}

	/** Whether the typer answers `node` in the currency asked. */
	private function typed(node: QueryNode, sc: Bool): Bool {
		return (sc ? _typer.source(node) : _typer.nominal(node)) != null;
	}

	/** Whether `kind` declares a local as a statement of its own, not as the continuation of another's. */
	private function isLocalDeclaration(kind: String): Bool {
		return (_shape.localDeclKinds ?? []).contains(kind) && !(_shape.localDeclContinuationKinds ?? []).contains(kind);
	}

	/** A local declaration's initializer: its child that is neither its annotation nor a continuation declaring another local. */
	private function initOf(decl: QueryNode): Null<QueryNode> {
		final continuations: Array<String> = _shape.localDeclContinuationKinds ?? [];
		return decl.children.find(c -> c.kind != ANNOTATION_KIND && !continuations.contains(c.kind));
	}

	private function isExpr(c: QueryNode): Bool {
		return !c.kind.endsWith('Stmt') && !c.kind.endsWith('Body') && c.kind != ANNOTATION_KIND && c.kind != _shape.caseBranchKind;
	}

	/** The reference hit at `node`'s range, or the innermost one holding it. */
	private function hitOf(node: QueryNode): Null<RefHit> {
		final name: Null<String> = node.name;
		final at: Null<Span> = node.span;
		if (name == null || at == null) return null;
		final hits: Array<RefHit> = _hitsByName[name] ?? hitsNamed(name);
		return hits.find(h -> h.span.from == at.from && h.span.to == at.to) ?? hits.find(h -> h.span.from <= at.from && at.to <= h.span.to);
	}

	/** The reference walk's hits of `name` in the file, kept for the next identifier of that name. */
	private function hitsNamed(name: String): Array<RefHit> {
		final found: Array<RefHit> = try Refs.find(name, _tree, _shape) catch (exception: Exception) [];
		_hitsByName[name] = found;
		return found;
	}

	private function enclosingType(node: QueryNode): Null<String> {
		final at: Null<Span> = node.span;
		return at == null ? null : TypeResolver.enclosingTypeName(_tree, at);
	}

	/** The simple name of the type the typer gives `recv`, its `Null<>` and type arguments dropped. */
	private function receiverType(recv: QueryNode, sc: Bool): Null<String> {
		final answered: Null<String> = sc ? _typer.source(recv) : _typer.nominal(recv);
		if (answered == null) return null;
		var t: String = answered.trim();
		while (t.startsWith(NULL_WRAPPER) && t.endsWith('>')) t = t.substring(NULL_WRAPPER.length, t.length - 1).trim();
		final open: Int = t.indexOf('<');
		return SourceText.lastSegment(open < 0 ? t : t.substring(0, open));
	}

	/** The type `recv` names when it is an identifier binding no value but a type declaration of the index. */
	private function staticReceiver(recv: QueryNode): Null<String> {
		final name: Null<String> = recv.name;
		return recv.kind == _shape.identKind && name != null && hitOf(recv)?.bindingNode == null && _index.refs.declsNamed(name).length > 0
			? name
			: null;
	}

	private static inline function rooted(root: UnknownRoot, detail: String): UnknownCause {
		return { root: root, detail: detail };
	}

	private static function annotated(node: QueryNode): Bool {
		return node.type != null || node.children.exists(c -> c.kind == ANNOTATION_KIND);
	}

	private static function returnAnnotated(fn: QueryNode): Bool {
		return fn.children.exists(c -> RETURN_TYPE_KINDS.contains(c.kind));
	}

}

/**
 * A type text read and spelled ONE way, so that two spellings of one type compare equal: every qualifier dropped (a
 * package, a module, the type a type parameter belongs to — the compiler prints `AbGeneric.T`; the typer answers names as
 * written), a function type as `(A,B)->R` whichever syntax wrote it (`A -> B -> R`, `(a : A, b : B) -> R`, `Void -> R`
 * for no argument), a structure's fields in name order without `var` / `final`. Null for a text it does not read.
 */
@:nullSafety(Strict)
private final class TypeText {

	/** The wrapper an optional structure field's type is read through. */
	private static inline final NULL_TYPE: String = 'Null';

	private final _tokens: Array<String>;

	private var _at: Int = 0;

	private function new(tokens: Array<String>) {
		_tokens = tokens;
	}

	private inline function peek(): String {
		return _tokens[_at] ?? '';
	}

	/** A type, an old-style function `A -> B` included. */
	private function type(): String {
		final first: Array<String> = primary();
		if (peek() != '->') return first.length == 1 ? first[0] : '(${first.join(',')})';
		final args: Array<String> = [first.length == 1 ? first[0] : '(${first.join(',')})'];
		var result: String = '';
		while (peek() == '->') {
			_at++;
			final next: Array<String> = primary();
			if (peek() == '->')
				args.push(next.join(','))
			else
				result = next.length == 1 ? next[0] : '(${next.join(',')})';
		}
		final parameters: Array<String> = args.length == 1 && args[0] == 'Void' ? [] : args;
		return '(${parameters.join(',')})->$result';
	}

	/** A primary type, or — for a parenthesised list — its elements (a new-style function's arguments). */
	private function primary(): Array<String> {
		final t: String = next();
		if (t == '(') {
			final items: Array<String> = [];
			var plain: Bool = true;
			while (peek() != ')') {
				plain = plain && peek() != '?' && !(_at + 1 < _tokens.length && _tokens[_at + 1] == ':');
				items.push(argument());
				if (peek() == ',') _at++;
			}
			_at++;
			// one unnamed type in parentheses before an arrow groups an argument of an old-style chain (4.3.7:
			// `(A -> B) -> C -> D` takes two arguments), any other list is a new-style function's
			if (peek() == '->' && !(plain && items.length == 1)) {
				_at++;
				return ['(${items.join(',')})->${type()}'];
			}
			return items;
		}
		if (t == '{') return [structure()];
		if (t == '?') return ['?' + primary().join(',')];
		var named: String = SourceText.lastSegment(t);
		if (peek() == '<') {
			_at++;
			final params: Array<String> = [type()];
			while (peek() == ',') {
				_at++;
				params.push(type());
			}
			expect('>');
			named += '<${params.join(',')}>';
		}
		return [named];
	}

	/** A function argument: `name : T`, `?name : T` or `T`, spelled by its type. */
	private function argument(): String {
		final optional: Bool = peek() == '?';
		if (optional) _at++;
		if (_at + 1 < _tokens.length && _tokens[_at + 1] == ':') _at += 2;
		return (optional ? '?' : '') + type();
	}

	/** A structure's fields, the opening brace read. */
	private function structure(): String {
		final fields: Array<String> = [];
		while (peek() != '}') {
			if (peek() == 'var' || peek() == 'final') _at++;
			final optional: Bool = peek() == '?';
			if (optional) _at++;
			final name: String = next();
			expect(':');
			final t: String = type();
			// an optional field's type is the optional value's (4.3.7: `{?a: Int}` is `{?a: Null<Int>}`, spelled so)
			fields.push(optional ? '?$name:${t.startsWith('$NULL_TYPE<') ? t : '$NULL_TYPE<$t>'}' : '$name:$t');
			if (peek() == ',' || peek() == ';') _at++;
		}
		_at++;
		fields.sort(Reflect.compare);
		return '{${fields.join(',')}}';
	}

	private function next(): String {
		if (_at >= _tokens.length) throw new Exception('the type ends early');
		return _tokens[_at++];
	}

	private function expect(token: String): Void {
		if (next() != token) throw new Exception('$token expected');
	}

	public static function canonical(text: String): Null<String> {
		final tokens: Array<String> = [];
		final token: EReg = ~/^\s*(->|[A-Za-z_$][A-Za-z0-9_$]*(?:\.[A-Za-z_$][A-Za-z0-9_$]*)*|[<>(){},:;?])/;
		var rest: String = text;
		while (token.match(rest)) {
			tokens.push(token.matched(1));
			rest = token.matchedRight();
		}
		if (rest.trim() != '') return null;
		final reader: TypeText = new TypeText(tokens);
		final read: Null<String> = try reader.type() catch (exception: Exception) null;
		return reader._at == tokens.length ? read : null;
	}

}

/** The tallies of one run, by area. */
@:nullSafety(Strict)
private final class Report {

	/** Tenths of a percent: the precision of an UNKNOWN share. */
	private static inline final PER_MILLE: Int = 1000;

	/** A share as a percentage. */
	private static inline final PERCENT: Int = 100;

	/** The labels `--census` keeps of one detail. */
	private static inline final CAUSE_SAMPLES: Int = 3;

	/** The two currencies a type answer is scored in, as the area names spell them. */
	private static final CURRENCIES: Array<String> = ['source', 'nominal'];

	private final _areas: Array<String> = [];
	private final _counts: Map<String, Array<Int>> = [];
	private final _different: Array<String> = [];
	private final _unscored: Map<String, Int> = [];

	/** The UNKNOWN answers `--census` rooted, by `<currency>\t<area>\t<root>`. */
	private final _roots: Map<String, Int> = [];

	/** Per currency, the UNKNOWN answers rooted, by root. */
	private final _rootTotals: Map<String, Map<String, Int>> = [];

	/** The UNKNOWN answers `--census` rooted, by `<currency>\t<root>\t<detail>`, and the first labels of each. */
	private final _causes: Map<String, Int> = [];

	private final _samples: Map<String, Array<String>> = [];
	private final _list: Bool;
	private final _census: Bool;

	public function new(list: Bool, census: Bool) {
		_list = list;
		_census = census;
	}

	/** How many answers were DIFFERENT. */
	public inline function differences(): Int {
		return _different.length;
	}

	/** One answer of `area` for the assertion `label`. */
	public function score(area: String, label: String, verdict: Verdict): Void {
		final c: Array<Int> = counts(area);
		c[0]++;
		switch verdict {
			case Match:
				c[1]++;
			case Unknown:
				c[2]++;
			case Different(got):
				c[3]++;
				_different.push('$area  $label  got: $got');
		}
		if (_list) Sys.println('$area\t${verdict.getName()}\t$label');
	}

	/** An assertion of `area` the harness cannot pose to the typer: a parse failure, a range no node spans. */
	public function unscored(area: String, label: String): Void {
		counts(area);
		_unscored[area] = (_unscored[area] ?? 0) + 1;
		if (_list) Sys.println('$area\tUNSCORED\t$label');
	}

	/**
	 * Under `--census`, the root of one UNKNOWN answer of `area` in `currency`, classified then and only then (`classify`):
	 * tallied by area and root, and by root and detail with the first labels of each as samples.
	 */
	public function unknownRoot(currency: String, area: String, label: String, classify: () -> UnknownCause): Void {
		if (!_census) return;
		final cause: UnknownCause = classify();
		final root: String = '$currency\t$area\t${cause.root}';
		_roots[root] = (_roots[root] ?? 0) + 1;
		final totals: Map<String, Int> = _rootTotals[currency] ?? [];
		totals[cause.root] = (totals[cause.root] ?? 0) + 1;
		_rootTotals[currency] = totals;
		final detail: String = '$currency\t${cause.root}\t${cause.detail}';
		_causes[detail] = (_causes[detail] ?? 0) + 1;
		final samples: Array<String> = _samples[detail] ?? [];
		if (samples.length < CAUSE_SAMPLES) samples.push(label);
		_samples[detail] = samples;
	}

	public function print(): Void {
		Sys.println('area\tcases\tmatch\tunknown\tdifferent\tunknown%\tunscored');
		for (area in _areas) {
			final c: Array<Int> = counts(area);
			Sys.println('$area\t${c[0]}\t${c[1]}\t${c[2]}\t${c[3]}\t${share(c[2], c[0])}\t${_unscored[area] ?? 0}');
		}
		for (d in _different) Sys.println('DIFFERENT  $d');
		if (_census) printCensus();
	}

	/** How many cases were scored, every area summed: a match, an unknown or a different answer. */
	public function scored(): Int {
		var total: Int = 0;
		for (area in _areas) total += counts(area)[0];
		return total;
	}

	/**
	 * The `--census` lines after the table: `CENSUS <currency> <area> <root> <n>`, `CENSUS-CAUSE <currency> <root> <detail>
	 * <n> <samples>`, and per currency `CENSUS-UNKNOWN <currency> <unknown> <cases> <unknown%>` (the share of the scored
	 * answers, the table's) then `CENSUS-TOTAL <currency> <root> <n> <share of its UNKNOWN>`. The roots of a currency
	 * sum to its UNKNOWN answers, or the run fails: an UNKNOWN left unrooted is a hole in the harness, not a reading.
	 */
	private function printCensus(): Void {
		for (key in sortedKeys(_roots)) Sys.println('CENSUS\t$key\t${_roots[key]}');
		for (key in sortedKeys(_causes)) Sys.println('CENSUS-CAUSE\t$key\t${_causes[key]}\t${(_samples[key] ?? []).join(' | ')}');
		for (currency in CURRENCIES) {
			var cases: Int = 0;
			var unknown: Int = 0;
			for (area in _areas) if (area.endsWith(' ($currency)')) {
				cases += counts(area)[0];
				unknown += counts(area)[2];
			}
			Sys.println('CENSUS-UNKNOWN\t$currency\t$unknown\t$cases\t${share(unknown, cases)}');
			final totals: Map<String, Int> = _rootTotals[currency] ?? [];
			var rooted: Int = 0;
			for (root in sortedKeys(totals)) {
				final n: Int = totals[root] ?? 0;
				rooted += n;
				Sys.println('CENSUS-TOTAL\t$currency\t$root\t$n\t${share(n, unknown)}');
			}
			if (rooted != unknown) throw new Exception('census: $rooted roots for $unknown UNKNOWN answers in the $currency currency');
		}
	}

	private function counts(area: String): Array<Int> {
		final found: Null<Array<Int>> = _counts[area];
		if (found != null) return found;
		final fresh: Array<Int> = [0, 0, 0, 0];
		_counts[area] = fresh;
		_areas.push(area);
		return fresh;
	}

	/** `part` of `whole` as a percentage to a tenth, `-` of nothing. */
	private static function share(part: Int, whole: Int): String {
		return whole == 0 ? '-' : '${Math.round(PER_MILLE * part / whole) * PERCENT / PER_MILLE}';
	}

	private static function sortedKeys<V>(map: Map<String, V>): Array<String> {
		final keys: Array<String> = [for (k in map.keys()) k];
		keys.sort(Reflect.compare);
		return keys;
	}

}
