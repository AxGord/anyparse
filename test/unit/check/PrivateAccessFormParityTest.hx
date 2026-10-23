package unit.check;

import anyparse.check.Check.CrossFileFix;
import anyparse.check.UnusedPrivate;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * Every spelling by which a second file takes access to a type's private members must stop the same rewrites of them.
 *
 * Haxe opens a private member to another module through `@:access` naming the TYPE, its PACKAGE (any enclosing one) or
 * the MEMBER itself — on the reaching class or on one of its methods — and through an expression-level `@:privateAccess`,
 * which names nothing at all. A rule that deletes, renames or re-scopes a private member on the strength of nothing else
 * reaching it has to read all five, and the rules read one: `FileInfo.accessGrants` used to keep the LAST segment of each
 * grant, so a package grant recorded `pkg`, a member grant the member's own name, and `@:privateAccess` nothing, and every
 * consumer asking "does a file grant itself access to `A`" answered no. `trivial-getter` read none of them, because its
 * gate asked the subtype graph alone.
 *
 * The assertion is a differential over `Linter.builtins()` so that a rule joins it by being registered: per cell, every
 * finding and edit a rule produces on the declaring file under another form must also be produced under the type grant.
 * The other direction is the conservative one and stays open — a member grant spells the member itself, and `naming`
 * refuses the cross-file rename it cannot extend to that spelling.
 * A second assertion holds the type grant itself to the contract the differential takes for granted — a rewrite that
 * touches the reached member's declaration carries the reaching file along — and a control member nothing reaches keeps
 * every cell from passing on a rule that simply stopped firing.
 */
class PrivateAccessFormParityTest extends Test {

	/** The declaring file. */
	private static inline final DECL_FILE: String = 'pkg/A.hx';

	/** The reaching file, in ANOTHER package so no package-level privilege could stand in for the grant. */
	private static inline final REACH_FILE: String = 'other/B.hx';

	/** The form every other one is compared with — the grant the rules already read. */
	private static inline final TYPE_GRANT: String = 'type';

	/** The member each cell's reacher names. */
	private static inline final REACHED: String = '_reached';

	/** The member of the same shape nothing outside its type names — the control. */
	private static inline final LONELY: String = '_lonely';

	/** Two read-only properties over private backing fields, each getter trivial — `trivial-getter`'s collapse shape. */
	private static final A_PROPERTY: String = 'package pkg;\n\nclass A {\n\n\tpublic var reached(get, never): Int;\n'
		+ '\tpublic var lonely(get, never): Int;\n\n\tprivate var _reached: Int = 0;\n\tprivate var _lonely: Int = 0;\n\n'
		+ '\tpublic function new() {}\n\n\tprivate function get_reached(): Int {\n\t\treturn _reached;\n\t}\n\n'
		+ '\tprivate function get_lonely(): Int {\n\t\treturn _lonely;\n\t}\n\n}\n';

	/** Two private fields nothing in the file reads — `unused-private`'s deletion shape. */
	private static final A_UNUSED: String = 'package pkg;\n\nclass A {\n\n\tprivate var _reached: Int = 0;\n'
		+ '\tprivate var _lonely: Int = 0;\n\n\tpublic function new() {}\n\n}\n';

	/** Two instance finals initialized to a literal — `static-constant`'s promotion shape. */
	private static final A_INSTANCE_CONSTANT: String = 'package pkg;\n\nclass A {\n\n\tprivate final _reached: Int = 1;\n'
		+ '\tprivate final _lonely: Int = 2;\n\n\tpublic function new() {}\n\n\tpublic function read(): Int {\n'
		+ '\t\treturn _reached + _lonely;\n\t}\n\n}\n';

	/** Two private vars never reassigned in the file — `prefer-final-field`'s shape, reached by a WRITE. */
	private static final A_NEVER_REASSIGNED: String = 'package pkg;\n\nclass A {\n\n\tprivate var _reached: Int = 0;\n'
		+ '\tprivate var _lonely: Int = 0;\n\n\tpublic function new() {}\n\n\tpublic function read(): Int {\n'
		+ '\t\treturn _reached + _lonely;\n\t}\n\n}\n';

	/** Two fields each written then read inside one method — `scratch-field`'s shape. */
	private static final A_SCRATCH: String = 'package pkg;\n\nclass A {\n\n\tprivate var _reached: Int = 0;\n'
		+ '\tprivate var _lonely: Int = 0;\n\n\tpublic function new() {}\n\n\tpublic function run(): Int {\n'
		+ '\t\t_reached = 3;\n\t\t_lonely = 4;\n\t\treturn _reached + _lonely;\n\t}\n\n}\n';

	/** Two private fields named against the convention — `naming`'s rename shape. */
	private static final A_MISNAMED: String = 'package pkg;\n\nclass A {\n\n\tprivate var _reached_x: Int = 0;\n'
		+ '\tprivate var _lonely_x: Int = 0;\n\n\tpublic function new() {}\n\n\tpublic function read(): Int {\n'
		+ '\t\treturn _reached_x + _lonely_x;\n\t}\n\n}\n';

	/** One declaration shape per rule whose license is "nothing outside the type reaches this private member". */
	private static final CELLS: Array<Cell> = [
		{
			name: 'trivial-getter',
			decl: A_PROPERTY,
			member: REACHED,
			body: 'return a._reached;'
		},
		{
			name: 'unused-private',
			decl: A_UNUSED,
			member: REACHED,
			body: 'return a._reached;'
		},
		{
			name: 'static-constant',
			decl: A_INSTANCE_CONSTANT,
			member: REACHED,
			body: 'return a._reached;'
		},
		{
			name: 'prefer-final-field',
			decl: A_NEVER_REASSIGNED,
			member: REACHED,
			body: 'a._reached = 5;\n\t\treturn 0;'
		},
		{
			name: 'scratch-field',
			decl: A_SCRATCH,
			member: REACHED,
			body: 'return a._reached;'
		},
		{
			name: 'naming',
			decl: A_MISNAMED,
			member: '_reached_x',
			body: 'return a._reached_x;'
		}
	];

	/**
	 * The five spellings of the privilege; the type grant is the baseline.
	 */
	private static final FORMS: Array<String> = [TYPE_GRANT, 'package', 'member', 'method', 'expression'];

	/**
	 * No form licenses a finding or an edit on the declaring file that the type grant does not.
	 */
	@:pin('control')
	@:killer('M-ACCESS-GRANT-LAST-SEGMENT')
	@:killer('M-PRIVATE-ACCESS-UNSEEN')
	public function testEveryFormOfThePrivilegeStopsWhatTheTypeGrantStops(): Void {
		final out: Array<String> = [];
		for (cell in CELLS) {
			final baseline: Array<String> = declOutcome(cell, TYPE_GRANT);
			for (form in FORMS)
				if (form != TYPE_GRANT)
					for (line in declOutcome(cell, form))
						if (!baseline.contains(line)) out.push('$form@${cell.name} +$line');
		}
		Assert.equals('', out.join('\n'));
	}

	/**
	 * Under every form, a cell rule that rewrites the reached member also rewrites the reacher, and still rewrites the control.
	 */
	@:pin('control')
	@:killer('M-TRIVIAL-GETTER-GRANTEE-UNSEEN')
	public function testARewriteOfTheReachedMemberCarriesTheReachingFile(): Void {
		final out: Array<String> = [];
		for (cell in CELLS) for (form in FORMS) {
			final run: CellRun = runCell(cell, form);
			final reached: Span = declarationLine(cell.decl, cell.member);
			final lonely: Span = declarationLine(cell.decl, cell.member.replace('reached', 'lonely'));
			final rule: String = cell.name;
			final declEdits: Array<Span> = run.declEdits[rule] ?? [];
			final reachEdits: Int = run.reachEdits[rule] ?? 0;
			if (declEdits.exists(s -> overlaps(s, reached)) && reachEdits == 0) out.push('$form@$rule rewrites $REACHED alone');
			if (!declEdits.exists(s -> overlaps(s, lonely))) out.push('$form@$rule leaves the control $LONELY alone — the cell is vacuous');
		}
		Assert.equals('', out.join('\n'));
	}

	/**
	 * A waiver reaches only the expression it annotates: a reacher that waives privacy for one statement and spells the
	 * member's name in another (a local of its own) leaves the member unreached, so `unused-private` still deletes it.
	 */
	@:pin('control')
	@:killer('M-WAIVER-WHOLE-FILE')
	public function testAWaiverReachesOnlyTheExpressionItAnnotates(): Void {
		final reacher: String = 'package other;\n\nimport pkg.A;\n\nclass B {\n\n\tpublic function new() {}\n\n'
			+ '\tpublic function reach(a: A): Int {\n\t\t@:privateAccess a.toString();\n\t\tfinal _reached: Int = 1;\n'
			+ '\t\treturn _reached;\n\t}\n\n}\n';
		final files: Array<SourceFile> = [{ file: DECL_FILE, source: A_UNUSED }, { file: REACH_FILE, source: reacher }];
		final plugin: CachingGrammarPlugin = scoped(files);
		final found: Array<Violation> = CheckFixture.violationsIn(new UnusedPrivate(), files, plugin).filter(v -> v.file == DECL_FILE);
		Assert.equals(2, found.length, 'both private fields are unreached: ${[for (v in found) v.message]}');
	}

	/**
	 * Every finding and every edit the roster produces on the declaring file of `cell` under `form`, each as one line,
	 * sorted — findings as `report:<rule>|<severity>|<from>`, edits as `edit:<rule>|<from>:<to>:<text>` whichever seam
	 * (`fix` or `crossFileFix`) carries them, since a rule may route one rewrite through either.
	 */
	private function declOutcome(cell: Cell, form: String): Array<String> {
		final files: Array<SourceFile> = filesOf(cell, form);
		final plugin: CachingGrammarPlugin = scoped(files);
		final index: SymbolIndex = CheckFixture.index(files, plugin);
		final out: Array<String> = [];
		for (check in Linter.builtins()) {
			final vs: Array<Violation> = CheckFixture.violationsIn(check, files, plugin);
			for (v in vs) if (v.file == DECL_FILE) out.push('report:${v.rule}|${v.severity}|${v.span?.from}');
			final mine: Array<Violation> = vs.filter(v -> v.file == DECL_FILE);
			if (mine.length > 0) for (e in check.fix(cell.decl, mine, plugin, index))
				out.push('edit:${check.id()}|${e.span.from}:${e.span.to}:${e.text}');
			final cross: Null<CrossFileFix> = check is CrossFileFix ? cast check : null;
			if (cross != null)
				for (rename in cross.crossFileFix(files, vs, plugin, index))
					for (slice in rename)
						if (slice.file == DECL_FILE)
							for (e in slice.edits) out.push('edit:${check.id()}|${e.span.from}:${e.span.to}:${e.text}');
		}
		out.sort(Reflect.compare);
		return out;
	}

	/** The edits each rule writes into the declaring file (`fix` and `crossFileFix` alike) and how many it writes into the reacher. */
	private function runCell(cell: Cell, form: String): CellRun {
		final files: Array<SourceFile> = filesOf(cell, form);
		final plugin: CachingGrammarPlugin = scoped(files);
		final index: SymbolIndex = CheckFixture.index(files, plugin);
		final declEdits: Map<String, Array<Span>> = [];
		final reachEdits: Map<String, Int> = [];
		for (check in Linter.builtins()) {
			final id: String = check.id();
			final vs: Array<Violation> = CheckFixture.violationsIn(check, files, plugin);
			final mine: Array<Violation> = vs.filter(v -> v.file == DECL_FILE);
			final spans: Array<Span> = mine.length > 0 ? [for (e in check.fix(cell.decl, mine, plugin, index)) e.span] : [];
			final cross: Null<CrossFileFix> = check is CrossFileFix ? cast check : null;
			var reach: Int = 0;
			if (cross != null) for (rename in cross.crossFileFix(files, vs, plugin, index)) for (slice in rename) {
				if (slice.file == DECL_FILE) for (e in slice.edits) spans.push(e.span);
				if (slice.file == REACH_FILE) reach += slice.edits.length;
			}
			declEdits[id] = spans;
			reachEdits[id] = reach;
		}
		return { declEdits: declEdits, reachEdits: reachEdits };
	}

	private static inline function overlaps(a: Span, b: Span): Bool {
		return a.from < b.to && b.from < a.to;
	}

	/** The two files of `cell` with its reacher spelled in `form`. */
	private static function filesOf(cell: Cell, form: String): Array<SourceFile> {
		return [
			{ file: DECL_FILE, source: cell.decl },
			{ file: REACH_FILE, source: reacher(cell, form) }
		];
	}

	/** The reaching class: it names `cell.member` on an `A` it is handed, taking access by `form`. */
	private static function reacher(cell: Cell, form: String): String {
		final classMeta: String = switch form {
			case TYPE_GRANT: '@:access(pkg.A)\n';
			case 'package': '@:access(pkg)\n';
			case 'member': '@:access(pkg.A.${cell.member})\n';
			case _: '';
		}
		final fnMeta: String = form == 'method' ? '\t@:access(pkg.A)\n' : '';
		final body: String = form == 'expression'
			? '@:privateAccess {\n\t\t\t${cell.body.replace('\n\t\t', '\n\t\t\t')}\n\t\t}'
			: cell.body;
		return 'package other;\n\nimport pkg.A;\n\n${classMeta}class B {\n\n\tpublic function new() {}\n\n'
			+ '${fnMeta}\tpublic function reach(a: A): Int {\n\t\t$body\n\t}\n\n}\n';
	}

	/** A plugin whose declared resolution scope is the report itself — what a project-wide `lint --fix` runs under. */
	private static function scoped(report: Array<SourceFile>): CachingGrammarPlugin {
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		plugin.setResolutionScope({
			declared: true,
			sources: () -> {report: report, projectRoots: [], library: new LibrarySources([]) }
		});
		return plugin;
	}

	/** The span of the line declaring `member` in `source`. */
	private static function declarationLine(source: String, member: String): Span {
		final at: Int = source.indexOf('$member: ');
		final from: Int = source.lastIndexOf('\n', at) + 1;
		return new Span(from, source.indexOf('\n', at));
	}

}

/** One declaring source, the member its reacher names, and the reacher's statement. */
private typedef Cell = {
	final name: String;
	final decl: String;
	final member: String;
	final body: String;
};

/** The edits of one cell run, per rule. */
private typedef CellRun = {
	final declEdits: Map<String, Array<Span>>;
	final reachEdits: Map<String, Int>;
};

/** One source a scope half holds. */
private typedef SourceFile = {
	var file: String;
	var source: String;
};
