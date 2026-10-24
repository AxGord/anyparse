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

	/** The file declaring the superclass every cell's `A` extends — in a third package, so its grants reach `A` only through it. */
	private static inline final BASE_FILE: String = 'base/Base.hx';

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

	/** Two read-write properties over private backing fields, both accessors trivial — `trivial-getter`'s `(get, set)` collapse. */
	private static final A_GET_SET: String = 'package pkg;\n\nclass A {\n\n\tpublic var reached(get, set): Int;\n'
		+ '\tpublic var lonely(get, set): Int;\n\n\tprivate var _reached: Int = 0;\n\tprivate var _lonely: Int = 0;\n\n'
		+ '\tpublic function new() {}\n\n\tprivate function get_reached(): Int {\n\t\treturn _reached;\n\t}\n\n'
		+ '\tprivate function set_reached(v: Int): Int {\n\t\treturn _reached = v;\n\t}\n\n'
		+ '\tprivate function get_lonely(): Int {\n\t\treturn _lonely;\n\t}\n\n'
		+ '\tprivate function set_lonely(v: Int): Int {\n\t\treturn _lonely = v;\n\t}\n\n}\n';

	/** The superclass, declaring nothing private of its own. */
	private static final BASE: String = 'package base;\n\nclass Base {\n\n\tpublic function new() {}\n\n}\n';

	/** Two private fields named against the convention — `naming`'s rename shape. */
	private static final A_MISNAMED: String = 'package pkg;\n\nclass A {\n\n\tprivate var _reached_x: Int = 0;\n'
		+ '\tprivate var _lonely_x: Int = 0;\n\n\tpublic function new() {}\n\n\tpublic function read(): Int {\n'
		+ '\t\treturn _reached_x + _lonely_x;\n\t}\n\n}\n';

	/** One declaration shape per rule whose license is "nothing outside the type reaches this private member". */
	private static final CELLS: Array<Cell> = [
		{
			name: 'trivial-getter',
			rule: 'trivial-getter',
			decl: extended(A_PROPERTY),
			member: REACHED,
			body: 'return a._reached;'
		},
		{
			name: 'trivial-getter-getter-call',
			rule: 'trivial-getter',
			decl: extended(A_PROPERTY),
			member: 'get_reached',
			body: 'return a.get_reached();'
		},
		{
			name: 'trivial-getter-setter-call',
			rule: 'trivial-getter',
			decl: extended(A_GET_SET),
			member: 'set_reached',
			body: 'a.set_reached(5);\n\t\treturn 0;'
		},
		{
			name: 'unused-private',
			rule: 'unused-private',
			decl: extended(A_UNUSED),
			member: REACHED,
			body: 'return a._reached;'
		},
		{
			name: 'static-constant',
			rule: 'static-constant',
			decl: extended(A_INSTANCE_CONSTANT),
			member: REACHED,
			body: 'return a._reached;'
		},
		{
			name: 'prefer-final-field',
			rule: 'prefer-final-field',
			decl: extended(A_NEVER_REASSIGNED),
			member: REACHED,
			body: 'a._reached = 5;\n\t\treturn 0;'
		},
		{
			name: 'scratch-field',
			rule: 'scratch-field',
			decl: extended(A_SCRATCH),
			member: REACHED,
			body: 'return a._reached;'
		},
		{
			name: 'naming',
			rule: 'naming',
			decl: extended(A_MISNAMED),
			member: '_reached_x',
			body: 'return a._reached_x;'
		}
	];

	/**
	 * The seven spellings of the privilege — five naming `A` or nothing, two naming only its superclass or that
	 * superclass's package; the type grant is the baseline.
	 */
	private static final FORMS: Array<String> = [
		TYPE_GRANT,
		'package',
		'member',
		'method',
		'expression',
		'ancestor',
		'ancestor-package'
	];

	/**
	 * No form licenses a finding or an edit on the declaring file that the type grant does not.
	 */
	@:pin('control')
	@:killer('M-ACCESS-GRANT-LAST-SEGMENT')
	@:killer('M-PRIVATE-ACCESS-UNSEEN')
	@:killer('M-ANCESTOR-GRANT-UNSEEN')
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
			final rule: String = cell.rule;
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
		final files: Array<SourceFile> = [
			{ file: BASE_FILE, source: BASE },
			{ file: DECL_FILE, source: extended(A_UNUSED) },
			{ file: REACH_FILE, source: reacher }
		];
		final plugin: CachingGrammarPlugin = scoped(files);
		final found: Array<Violation> = CheckFixture.violationsIn(new UnusedPrivate(), files, plugin).filter(v -> v.file == DECL_FILE);
		Assert.equals(2, found.length, 'both private fields are unreached: ${[for (v in found) v.message]}');
	}

	/**
	 * A subclass calling an accessor by its own name keeps it: the collapse deletes the accessors with the backing field, so
	 * `trivial-getter` refuses the property whose getter a subtype calls and still collapses the control.
	 */
	@:pin('control')
	@:killer('M-TRIVIAL-GETTER-ACCESSOR-UNSEEN')
	public function testASubclassCallingAnAccessorKeepsTheProperty(): Void {
		final subclass: String = 'package other;\n\nimport pkg.A;\n\nclass B extends A {\n\n\tpublic function new() {\n\t\tsuper();\n'
			+ '\t}\n\n\tpublic function reach(): Int {\n\t\treturn get_reached();\n\t}\n\n}\n';
		final decl: String = extended(A_PROPERTY);
		final run: CellRun = runFiles([
			{ file: BASE_FILE, source: BASE },
			{ file: DECL_FILE, source: decl },
			{ file: REACH_FILE, source: subclass }
		], decl);
		final edits: Array<Span> = run.declEdits['trivial-getter'] ?? [];
		Assert.isFalse(edits.exists(s -> overlaps(s, declarationLine(decl, 'get_reached'))), 'the called getter is deleted');
		Assert.isTrue(edits.exists(s -> overlaps(s, declarationLine(decl, 'get_lonely'))), 'the control is not collapsed — vacuous');
	}

	/**
	 * A private constructor another file reaches — by a waiver around `new A()` or under a grant — is never called unused:
	 * the construction spells the type, not the member name `new`.
	 */
	@:pin('guard')
	public function testAConstructorReachedFromAnotherFileStays(): Void {
		final decl: String =
			'package pkg;\n\nclass A {\n\n\tprivate function new() {}\n\n\tpublic function v(): Int {\n\t\treturn 6;\n\t}\n\n}\n';
		for (form in ['expression', TYPE_GRANT, 'package']) {
			final meta: String = if (form == TYPE_GRANT)
				'@:access(pkg.A)\n'
			else if (form == 'package')
				'@:access(pkg)\n'
			else
				'';
			final make: String = form == 'expression' ? '@:privateAccess new A()' : 'new A()';
			final reacher: String = 'package other;\n\nimport pkg.A;\n\n${meta}class B {\n\n\tpublic static function reach(): Int {\n'
				+ '\t\tfinal a: A = $make;\n\t\treturn a.v();\n\t}\n\n}\n';
			final files: Array<SourceFile> = [{ file: DECL_FILE, source: decl }, { file: REACH_FILE, source: reacher }];
			final found: Array<Violation> = CheckFixture.violationsIn(new UnusedPrivate(), files, scoped(files))
				.filter(v -> v.file == DECL_FILE);
			Assert.equals(0, found.length, '$form: ${[for (v in found) v.message]}');
		}
	}

	/**
	 * A private constructor another file reaches through a waiver without writing `new A` — an aliased `new M<Int>()`, a `A.new`
	 * reference — is never called unused; the same file with no construction leaves it reported (the control).
	 */
	@:pin('control')
	@:killer('M-WAIVER-CONSTRUCTION-UNSPELLED')
	@:killer('M-CTOR-PRIVILEGE-UNASKED')
	public function testAWaivedConstructionSpellsTheConstructor(): Void {
		final decl: String = 'package pkg;\n\nclass A<T> {\n\n\tprivate function new() {}\n\n\tpublic static function make(): A<Int> {\n'
			+ '\t\treturn null;\n\t}\n\n}\n';
		final shapes: Map<String, String> = [
			'alias' => 'final a: Null<M<Int>> = @:privateAccess new M<Int>();\n\t\treturn a != null;',
			'reference' => 'final f = @:privateAccess pkg.A.new;\n\t\treturn f != null;',
			'none' => 'return M.make() != null;'
		];
		for (shape => body in shapes) {
			final reacher: String = 'package other;\n\nimport pkg.A as M;\n\nclass B {\n\n\tpublic static function reach(): Bool {\n'
				+ '\t\t$body\n\t}\n\n\tpublic static function waived(): Void {\n\t\t@:privateAccess trace(0);\n\t}\n\n}\n';
			final files: Array<SourceFile> = [{ file: DECL_FILE, source: decl }, { file: REACH_FILE, source: reacher }];
			final found: Array<Violation> = CheckFixture.violationsIn(new UnusedPrivate(), files, scoped(files))
				.filter(v -> v.file == DECL_FILE);
			Assert.equals(shape == 'none' ? 1 : 0, found.length, '$shape: ${[for (v in found) v.message]}');
		}
	}

	/**
	 * A package grant reaches a subclass through a superclass the index does not hold (a library outside the roots): its
	 * package is unknown, so `@:access(fw)` and `@:access(fw.display)` may enclose it, and `unused-private` keeps the member a
	 * grantee reads while still deleting the control.
	 */
	@:pin('control')
	@:killer('M-UNRESOLVED-SUPER-PACKAGE-GRANT')
	public function testAPackageGrantReachesThroughAnUnindexedSuperclass(): Void {
		final decl: String = 'package pkg;\n\nimport fw.display.Base;\n\nclass A extends Base {\n\n\tprivate var _reached: Int = 0;\n'
			+ '\tprivate var _lonely: Int = 0;\n\n\tpublic function new() {\n\t\tsuper();\n\t}\n\n}\n';
		for (grant in ['fw', 'fw.display']) {
			final reacher: String = 'package other;\n\nimport pkg.A;\n\n@:access($grant)\nclass B {\n\n'
				+ '\tpublic static function reach(a: A): Int {\n\t\treturn a._reached;\n\t}\n\n}\n';
			assertUnusedPrivateKeepsReached([{ file: DECL_FILE, source: decl }, { file: REACH_FILE, source: reacher }], decl, grant);
		}
	}

	/**
	 * A macro's output is access-checked where it lands: a reification spelling the member — in a helper of the macro the
	 * privileged file calls, or in a build macro the privileged class inherits through `@:autoBuild` — reaches it though the
	 * privileged file never spells it.
	 */
	@:pin('control')
	@:killer('M-REIFIED-NAME-UNREAD')
	@:killer('M-BUILT-GRANTEE-UNSEEN')
	public function testAMacroExpandedUnderAPrivilegeReachesWhatItSpells(): Void {
		final decl: String = extended(A_UNUSED);
		final helper: String = 'package tools;\n\nimport haxe.macro.Expr;\n\nclass Macros {\n\n'
			+ '\tpublic static macro function peek(e: Expr): Expr {\n\t\treturn build(e);\n\t}\n\n'
			+ '\tstatic function build(e: Expr): Expr {\n\t\treturn macro $$e._reached;\n\t}\n\n}\n';
		final builder: String = 'package tools;\n\nimport haxe.macro.Expr;\n\nclass Builder {\n\n'
			+ '\tpublic static function build(): Array<Field> {\n\t\treturn [macro class X {\n\t\t\tfunction read(a: pkg.A) {\n'
			+ '\t\t\t\treturn a._reached;\n\t\t\t}\n\t\t}].concat([]).map(c -> c.fields[0]);\n\t}\n\n}\n';
		final auto: String = 'package tools;\n\n@:autoBuild(tools.Builder.build())\ninterface Auto {}\n';
		for (form in ['ancestor', 'expression', 'autoBuild']) {
			final meta: String = form == 'expression' ? '' : '@:access(base.Base)\n';
			final call: String = switch form {
				case 'ancestor': 'tools.Macros.peek(a)';
				case 'expression': '@:privateAccess tools.Macros.peek(a)';
				case _: '0';
			}
			final implementsClause: String = form == 'autoBuild' ? ' implements tools.Auto' : '';
			final reacher: String = 'package other;\n\nimport pkg.A;\n\n${meta}class B$implementsClause {\n\n'
				+ '\tpublic static function reach(a: A): Int {\n\t\treturn $call;\n\t}\n\n}\n';
			final files: Array<SourceFile> = [
				{ file: BASE_FILE, source: BASE },
				{ file: DECL_FILE, source: decl },
				{ file: 'tools/Macros.hx', source: helper },
				{ file: 'tools/Builder.hx', source: builder },
				{ file: 'tools/Auto.hx', source: auto },
				{ file: REACH_FILE, source: reacher }
			];
			assertUnusedPrivateKeepsReached(files, decl, form);
		}
	}

	/**
	 * A private constructor its own class builds by a qualified `new pkg.A()` stays — the construction scan reads past the
	 * qualifier; the same class with no construction is still reported (the control).
	 */
	@:pin('control')
	@:killer('M-QUALIFIED-CONSTRUCTION-UNSEEN')
	public function testAQualifiedConstructionKeepsThePrivateConstructor(): Void {
		for (built in [true, false]) {
			final made: String = built ? 'new pkg.A()' : 'null';
			final decl: String = 'package pkg;\n\nclass A {\n\n\tprivate function new() {}\n\n\tpublic static function make(): A {\n'
				+ '\t\treturn $made;\n\t}\n\n}\n';
			final files: Array<SourceFile> = [{ file: DECL_FILE, source: decl }];
			final found: Array<Violation> = CheckFixture.violationsIn(new UnusedPrivate(), files, scoped(files))
				.filter(v -> v.file == DECL_FILE);
			Assert.equals(built ? 0 : 1, found.length, 'built=$built: ${[for (v in found) v.message]}');
		}
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
		return runFiles(filesOf(cell, form), cell.decl);
	}

	/** `runCell` over an explicit file set whose declaring file holds `decl`. */
	private function runFiles(files: Array<SourceFile>, decl: String): CellRun {
		final plugin: CachingGrammarPlugin = scoped(files);
		final index: SymbolIndex = CheckFixture.index(files, plugin);
		final declEdits: Map<String, Array<Span>> = [];
		final reachEdits: Map<String, Int> = [];
		for (check in Linter.builtins()) {
			final id: String = check.id();
			final vs: Array<Violation> = CheckFixture.violationsIn(check, files, plugin);
			final mine: Array<Violation> = vs.filter(v -> v.file == DECL_FILE);
			final spans: Array<Span> = mine.length > 0 ? [for (e in check.fix(decl, mine, plugin, index)) e.span] : [];
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

	/** `unused-private` over `files` writes no edit on `decl`'s `_reached` line and still deletes `_lonely`. */
	private function assertUnusedPrivateKeepsReached(files: Array<SourceFile>, decl: String, label: String): Void {
		final edits: Array<Span> = runFiles(files, decl).declEdits['unused-private'] ?? [];
		Assert.isFalse(edits.exists(s -> overlaps(s, declarationLine(decl, REACHED))), '$label: the reached member is deleted');
		Assert.isTrue(edits.exists(s -> overlaps(s, declarationLine(decl, LONELY))), '$label: the control is kept — vacuous');
	}

	private static inline function overlaps(a: Span, b: Span): Bool {
		return a.from < b.to && b.from < a.to;
	}

	/** The two files of `cell` with its reacher spelled in `form`. */
	private static function filesOf(cell: Cell, form: String): Array<SourceFile> {
		return [
			{ file: BASE_FILE, source: BASE },
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
			case 'ancestor': '@:access(base.Base)\n';
			case 'ancestor-package': '@:access(base)\n';
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

	/** The span of the line declaring `member` — a field (`name:`) or a method (`name(`) — in `source`. */
	private static function declarationLine(source: String, member: String): Span {
		final field: Int = source.indexOf(' $member:');
		final at: Int = field >= 0 ? field : source.indexOf(' $member(');
		final from: Int = source.lastIndexOf('\n', at) + 1;
		return new Span(from, source.indexOf('\n', at));
	}

	/** `decl` with its `A` extending `base.Base` — the shape an ancestor's grant reaches it through. */
	private static function extended(decl: String): String {
		return decl.replace('class A {', 'class A extends base.Base {')
			.replace('\tpublic function new() {}', '\tpublic function new() {\n\t\tsuper();\n\t}');
	}

}

/** One declaring source, the member its reacher names, and the reacher's statement. */
private typedef Cell = {
	final name: String;
	final rule: String;
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
