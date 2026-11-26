package unit.check.haxe.expressions;

import anyparse.check.Check;
import anyparse.check.Severity;
import anyparse.check.haxe.expressions.DuplicateComparator;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.query.Cli;
import anyparse.query.GrammarPlugin;
import sys.FileSystem;
import sys.io.File;
import unit.cli.CliFixture;

using StringTools;

/** The findings of one run and every file after the fix. */
private typedef Found = { final violations: Array<Violation>; final fixed: Map<String, String>; }

/**
 * The `duplicate-comparator` check: the same comparator lambda, up to parameter names and on one resolved element type, at
 * two or more sort calls is flagged at each site, and the fix extracts one named static that every site passes by reference.
 */
class DuplicateComparatorTest extends Test {

	private static final ROW: String = 'typedef Row = { k:Int, j:Int }\n';
	private static final ORDER_IMPORT: String = 'import lib.Order;\n\n';

	/** A project's compare function and key macros, as the options name them. */
	private static final ORDER: String = 'package lib;\n\nclass Order {\n\tpublic static function ints(a:Int, b:Int):Int return 0;\n\n'
		+ '\tpublic static macro function asc(keys:Array<Expr>):Expr return null;\n\n'
		+ '\tpublic static macro function desc(keys:Array<Expr>):Expr return null;\n}\n';

	private static final NAMED: String = '{"rules":{"duplicate-comparator":{"enabled":true,"compare":{"Int":"lib.Order.ints"},'
		+ '"keyed":{"asc":"lib.Order.asc","desc":"lib.Order.desc"}}}}';
	private static final COMPARE_ONLY: String = '{"rules":{"duplicate-comparator":{"enabled":true,"compare":{"Int":"lib.Order.ints"}}}}';
	private static final BARE: String = '{"rules":{"duplicate-comparator":true}}';

	/** Two sorts of one comparator in one class: one private static there, both sites pass it by name. */
	@:pin('control')
	@:killer('M-DUPCMP-FIX-DROPPED')
	public function testTwoIdenticalSitesExtracted(): Void {
		final found: Found = run([{
			file: 'C.hx',
			source: inClass('xs.sort((a, b) -> a.k - b.k);\n\t\tys.sort((p, q) -> p.k - q.k);')
		}]);
		Assert.equals(2, found.violations.length);
		Assert.equals('duplicate-comparator', found.violations[0].rule);
		Assert.equals(Severity.Info, found.violations[0].severity);
		Assert.equals(
			fixedClass('xs.sort(byK);\n\t\tys.sort(byK);', 'private static function byK(a: Row, b: Row): Int return a.k - b.k;'),
			found.fixed['C.hx']
		);
	}

	/** A site the fix is not handed (a suppressed one) keeps its lambda, and so does every other site of its group. */
	@:pin('control')
	@:killer('M-DUPCMP-PARTIAL-GROUP')
	public function testSuppressedSiteKeepsTheGroupWhole(): Void {
		final files: Array<{ file: String, source: String }> = [{
			file: 'C.hx',
			source: inClass('xs.sort((a, b) -> a.k - b.k);\n\t\tys.sort((a, b) -> a.k - b.k);')
		}];
		final plugin: GrammarPlugin = new HaxeQueryPlugin();
		final rule: DuplicateComparator = new DuplicateComparator();
		final violations: Array<Violation> = CheckFixture.violationsIn(rule, files, plugin);
		Assert.equals(2, violations.length);
		Assert.equals(0, rule.crossFileFix(files, violations.slice(1), plugin).length);
	}

	/** One sort of a comparator is no duplicate. */
	@:pin('control')
	@:killer('M-DUPCMP-SINGLE-SITE')
	public function testSingleSiteLeftAlone(): Void {
		Assert.equals(0, run([{ file: 'C.hx', source: inClass('xs.sort((a, b) -> a.k - b.k);') }]).violations.length);
	}

	/** The same body over two element types is two comparators. */
	@:pin('control')
	@:killer('M-DUPCMP-ELEMENT-BLIND')
	public function testSameBodyOnDifferentElementTypesLeftAlone(): Void {
		final source: String = 'class C {\n\tfunction f(xs:Array<Row>, ys:Array<Col>) {\n\t\txs.sort((a, b) -> a.k - b.k);\n'
			+ '\t\tys.sort((a, b) -> a.k - b.k);\n\t}\n}\n${ROW}typedef Col = { k:Int }\n';
		Assert.equals(0, run([{ file: 'C.hx', source: source }]).violations.length);
	}

	/** A descending comparator is not the ascending one over the same key. */
	@:pin('control')
	@:killer('M-DUPCMP-PARAMS-MERGED')
	public function testDescendingAndAscendingNotMerged(): Void {
		Assert.equals(
			0,
			run([{
				file: 'C.hx',
				source: inClass('xs.sort((a, b) -> a.k - b.k);\n\t\tys.sort((a, b) -> b.k - a.k);')
			}]).violations.length
		);
	}

	/** A lambda reading a local of its enclosing function cannot become a static. */
	@:pin('control')
	@:killer('M-DUPCMP-CAPTURE-BLIND')
	public function testCapturingLambdaLeftAlone(): Void {
		final body: String = 'final d:Int = 1;\n\t\txs.sort((a, b) -> a.k - b.k + d);\n\t\tys.sort((a, b) -> a.k - b.k + d);';
		Assert.equals(0, run([{ file: 'C.hx', source: inClass(body) }]).violations.length);
	}

	/** Sites whose receiver has no known type are left alone and counted in a config note. */
	@:pin('control')
	@:killer('M-DUPCMP-UNRESOLVED-UNCOUNTED')
	public function testUnresolvedElementCounted(): Void {
		final notes: Array<ConfigNote> = [];
		final source: String =
			'class C {\n\tfunction f(xs, ys) {\n\t\txs.sort((a, b) -> a.k - b.k);\n\t\tys.sort((a, b) -> a.k - b.k);\n\t}\n}\n';
		Assert.equals(0, run([{ file: 'C.hx', source: source }], notes).violations.length);
		final said: String = notes.map(n -> n.message).join('');
		Assert.isTrue(said.indexOf('2 sort callback(s) left alone') != -1, said);
	}

	/** An element type that is a type parameter of the enclosing function cannot be named by a static, so it counts as unresolved. */
	@:pin('control')
	@:killer('M-DUPCMP-TYPE-PARAMETER-BLIND')
	public function testTypeParameterElementCounted(): Void {
		final notes: Array<ConfigNote> = [];
		final source: String = 'class C {\n\tfunction f<T:{ k:Int }>(xs:Array<T>, ys:Array<T>) {\n\t\txs.sort((a, b) -> a.k - b.k);\n'
			+ '\t\tys.sort((a, b) -> a.k - b.k);\n\t}\n}\n';
		Assert.equals(0, run([{ file: 'C.hx', source: source }], notes).violations.length);
		final said: String = notes.map(n -> n.message).join('');
		Assert.isTrue(said.indexOf('2 sort callback(s) left alone') != -1, said);
	}

	/** A lambda returning the configured compare function of one key is extracted in the configured macro form. */
	@:pin('control')
	@:killer('M-DUPCMP-MACRO-FORM-DROPPED')
	public function testKeyComparatorTakesMacroForm(): Void {
		final body: String = 'xs.sort((a, b) -> Order.ints(a.k, b.k));\n\t\tys.sort((p, q) -> Order.ints(p.k, q.k));';
		final found: Found = run(ordered(body), null, NAMED);
		Assert.equals(2, found.violations.length);
		Assert.equals(
			ORDER_IMPORT
			+ fixedClass('xs.sort(byK);\n\t\tys.sort(byK);', 'private static final byK: (Row, Row) -> Int = Order.asc(a -> a.k);'),
			found.fixed['C.hx']
		);
	}

	/** The configured `desc` macro over a key and a lambda comparing that key the other way round are one comparator. */
	@:pin('control')
	@:killer('M-DUPCMP-MACRO-FORM-DROPPED')
	public function testSameKeysAreOneComparator(): Void {
		final body: String = 'xs.sort(Order.desc(r -> r.k));\n\t\tys.sort((a, b) -> Order.ints(b.k, a.k));';
		final found: Found = run(ordered(body), null, NAMED);
		Assert.equals(2, found.violations.length);
		Assert.equals(
			ORDER_IMPORT
			+ fixedClass(
				'xs.sort(byKDesc);\n\t\tys.sort(byKDesc);', 'private static final byKDesc: (Row, Row) -> Int = Order.desc(r -> r.k);'
			),
			found.fixed['C.hx']
		);
	}

	/** Sites in two modules on a class the scope declares: a public static on that class, each site naming it. */
	@:pin('control')
	@:killer('M-DUPCMP-ELEMENT-HOST-DROPPED')
	public function testAcrossModulesOnTheElementClass(): Void {
		final row: String = 'package p;\n\nclass Row {\n\tpublic var k:Int = 0;\n\n\tpublic function new() {}\n}\n';
		final found: Found = run([
			{ file: 'p/Row.hx', source: row },
			{ file: 'q/A.hx', source: sorter('A') },
			{ file: 'q/B.hx', source: sorter('B') }
		]);
		Assert.equals(2, found.violations.length);
		Assert.equals(
			'package p;\n\nclass Row {\n\tpublic var k:Int = 0;\n\n\tpublic function new() {}\n'
			+ '\npublic static function byK(a: Row, b: Row): Int return a.k - b.k;\n}\n',
			found.fixed['p/Row.hx']
		);
		Assert.equals(sorter('A').replace('(a, b) -> a.k - b.k', 'Row.byK'), found.fixed['q/A.hx']);
	}

	/** A key comparator moved onto an element class whose module does not import the macro's type brings the import along. */
	@:pin('control')
	@:killer('M-DUPCMP-IMPORTS-DROPPED')
	public function testAcrossModulesImportsWhatTheHostLacks(): Void {
		final row: String = 'package p;\n\nclass Row {\n\tpublic var k:Int = 0;\n}\n';
		function keyed(name: String): String {
			return 'package q;\n\n${ORDER_IMPORT}import p.Row;\n\nclass $name {\n\tfunction f(xs:Array<Row>) {\n'
				+ '\t\txs.sort((a, b) -> Order.ints(a.k, b.k));\n\t}\n}\n';
		}
		final found: Found = run([
			{ file: 'p/Row.hx', source: row },
			{ file: 'q/A.hx', source: keyed('A') },
			{ file: 'q/B.hx', source: keyed('B') },
			{ file: 'lib/Order.hx', source: ORDER }
		], null, NAMED);
		Assert.equals(2, found.violations.length);
		Assert.equals(
			'package p;\n\n${ORDER_IMPORT}class Row {\n\tpublic var k:Int = 0;\n'
			+ '\npublic static final byK: (Row, Row) -> Int = Order.asc(a -> a.k);\n}\n',
			found.fixed['p/Row.hx']
		);
	}

	/** A body naming a type the host module cannot be shown to bind the same way stays at its sites. */
	@:pin('control')
	@:killer('M-DUPCMP-UNSEEN-TYPE-BLIND')
	public function testBodyNamingAnUnseenTypeRefused(): Void {
		final row: String = 'package p;\n\nclass Row {\n\tpublic var k:Int = 0;\n}\n';
		function sorting(name: String): String {
			return 'package q;\n\nimport p.Row;\n\nclass $name {\n\tfunction f(xs:Array<Row>) {\n'
				+ '\t\txs.sort((a, b) -> Unknown.cmp(a.k, b.k));\n\t}\n}\n';
		}
		final found: Found = run([
			{ file: 'p/Row.hx', source: row },
			{ file: 'q/A.hx', source: sorting('A') },
			{ file: 'q/B.hx', source: sorting('B') }
		]);
		Assert.equals(2, found.violations.length);
		Assert.isTrue(found.violations[0].message.indexOf('no fix, its body names Unknown') != -1, found.violations[0].message);
		Assert.equals(row, found.fixed['p/Row.hx']);
	}

	/** A host that already declares the name gets no fix, and the finding says why. */
	@:pin('control')
	@:killer('M-DUPCMP-CLASH-BLIND')
	public function testNameTakenRefused(): Void {
		final source: String = 'class C {\n\tstatic function byK() {}\n\n\tfunction f(xs:Array<Row>, ys:Array<Row>) {\n'
			+ '\t\txs.sort((a, b) -> a.k - b.k);\n\t\tys.sort((a, b) -> a.k - b.k);\n\t}\n}\n$ROW';
		final found: Found = run([{ file: 'C.hx', source: source }]);
		Assert.equals(2, found.violations.length);
		Assert.isTrue(found.violations[0].message.indexOf('no fix, C already declares byK') != -1, found.violations[0].message);
		Assert.equals(source, found.fixed['C.hx']);
	}

	/** Sites in two packages on an anonymous element type have no module to share, so they get no fix. */
	@:pin('control')
	@:killer('M-DUPCMP-PACKAGES-BLIND')
	public function testAcrossPackagesOnAnonymousElementRefused(): Void {
		function anon(pkg: String): String {
			return 'package $pkg;\n\nclass S {\n\tfunction f(xs:Array<{ k:Int }>) {\n\t\txs.sort((a, b) -> a.k - b.k);\n\t}\n}\n';
		}
		final found: Found = run([{ file: 'p/S.hx', source: anon('p') }, { file: 'q/S.hx', source: anon('q') }]);
		Assert.equals(2, found.violations.length);
		Assert.isTrue(found.violations[0].message.indexOf('no fix, the sites span packages') != -1, found.violations[0].message);
		Assert.equals(anon('p'), found.fixed['p/S.hx']);
	}

	/** With no `keyed` option a key comparator is extracted as a static function, the configured compare spelled for the host. */
	@:pin('control')
	@:killer('M-DUPCMP-KEYED-DEFAULTED')
	public function testNoKeyedOptionTakesFunctionForm(): Void {
		final body: String = 'xs.sort((a, b) -> Order.ints(a.k, b.k));\n\t\tys.sort((p, q) -> Order.ints(p.k, q.k));';
		final expected: String = ORDER_IMPORT
			+ fixedClass(
				'xs.sort(byK);\n\t\tys.sort(byK);', 'private static function byK(a: Row, b: Row): Int return Order.ints(a.k, b.k);'
			);
		Assert.equals(expected, run(ordered(body), null, COMPARE_ONLY).fixed['C.hx']);
		Assert.equals(expected, run(ordered(body), null, BARE).fixed['C.hx']);
	}

	/** A `Null<Int>` key, which the key macro refuses at compile time, keeps the compare function in a static function. */
	@:pin('control')
	@:killer('M-DUPCMP-NULL-KEY-MACRO')
	public function testNullableKeyTakesFunctionForm(): Void {
		final body: String = 'xs.sort((a, b) -> Order.ints(a.k, b.k));\n\t\tys.sort((p, q) -> Order.ints(p.k, q.k));';
		final files: Array<{ file: String, source: String }> = ordered(body);
		final c: String = files[0].source.replace('k:Int', 'k:Null<Int>');
		final found: Found = run([{ file: 'C.hx', source: c }, files[1]], null, NAMED);
		Assert.equals(2, found.violations.length);
		Assert.equals(
			ORDER_IMPORT
			+ fixedClass(
				'xs.sort(byK);\n\t\tys.sort(byK);', 'private static function byK(a: Row, b: Row): Int return Order.ints(a.k, b.k);'
			).replace('k:Int', 'k:Null<Int>'),
			found.fixed['C.hx']
		);
	}

	/** A `keyed` path the index does not declare is a configuration error, and the rule stops on the files it governs. */
	@:pin('control')
	@:killer('M-DUPCMP-BROKEN-OPTION-RUNS')
	public function testUnknownKeyedPathIsAConfigError(): Void {
		final json: String = NAMED.replace('lib.Order.asc', 'lib.Order.nope');
		final found: Found = run(ordered('xs.sort((a, b) -> a.k - b.k);\n\t\tys.sort((a, b) -> a.k - b.k);'), null, json);
		Assert.equals(1, found.violations.length);
		Assert.equals(Severity.Error, found.violations[0].severity);
		Assert.equals('keyed.asc: the resolution index declares no "lib.Order.nope"', found.violations[0].message);
	}

	/** A `keyed` path naming a plain function, not a macro, is a configuration error. */
	@:pin('control')
	@:killer('M-DUPCMP-KEYED-NOT-MACRO')
	public function testKeyedPathToAFunctionIsAConfigError(): Void {
		final json: String = NAMED.replace('lib.Order.asc', 'lib.Order.ints');
		final found: Found = run(ordered('xs.sort((a, b) -> a.k - b.k);'), null, json);
		Assert.equals(1, found.violations.length);
		Assert.equals('keyed.asc: "lib.Order.ints" is not one public static macro function', found.violations[0].message);
	}

	/** A lambda reading `this` captures the instance, which a static cannot see. */
	@:pin('control')
	@:killer('M-DUPCMP-THIS-BOUND')
	public function testThisReadingLambdaLeftAlone(): Void {
		final body: String = 'xs.sort((a, b) -> a.k * this.w - b.k * this.w);\n\t\tys.sort((a, b) -> a.k * this.w - b.k * this.w);';
		Assert.equals(0, run([{ file: 'C.hx', source: inClass(body) }]).violations.length);
	}

	/** Sites in two modules whose busiest module's class is private: the other module cannot name it, so no fix. */
	@:pin('control')
	@:killer('M-DUPCMP-PRIVATE-HOST')
	public function testPrivateHostRefused(): Void {
		final sort: String = '\t\txs.sort((a, b) -> a.k - b.k);\n';
		final a: String = 'package p;\n\nprivate class S {\n\tfunction f(xs:Array<{ k:Int }>) {\n$sort$sort\t}\n}\n';
		final b: String = 'package p;\n\nclass T {\n\tfunction f(xs:Array<{ k:Int }>) {\n$sort\t}\n}\n';
		final found: Found = run([{ file: 'p/A.hx', source: a }, { file: 'p/B.hx', source: b }]);
		Assert.equals(3, found.violations.length);
		Assert.isTrue(found.violations[0].message.indexOf('no fix, S is private to its module') != -1, found.violations[0].message);
		Assert.equals(a, found.fixed['p/A.hx']);
	}

	/** An element class the resolution scope declares outside the run's files is no host: the driver could not write it. */
	@:pin('control')
	@:killer('M-DUPCMP-HOST-OUTSIDE-RUN')
	public function testElementHostOutsideTheRunRefused(): Void {
		final row: { file: String, source: String } = {
			file: 'p/Row.hx',
			source: 'package p;\n\nclass Row {\n\tpublic var k:Int = 0;\n}\n'
		};
		final files: Array<{ file: String, source: String }> =
			[{ file: 'q/A.hx', source: sorter('A') }, { file: 'q/B.hx', source: sorter('B') }];
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		plugin.setResolutionScope(
			{ declared: true, sources: () -> { report: files.concat([row]), projectRoots: [], library: new LibrarySources([]) } }
		);
		final found: Found = run(files, null, null, plugin);
		Assert.equals(2, found.violations.length);
		Assert.isTrue(
			found.violations[0].message.indexOf('no fix, Row is declared in p/Row.hx, which this run does not cover') != -1,
			found.violations[0].message
		);
		Assert.equals(sorter('A'), found.fixed['q/A.hx']);
	}

	/** Through `lint --fix` on a canonical fixture: the group is extracted and the file written. */
	@:pin('control')
	@:killer('M-DUPCMP-FIX-DROPPED')
	public function testLintFixWritesTheExtraction(): Void {
		#if (sys || nodejs)
		final c: String = 'class C {\n\tpublic function f(xs:Array<Row>, ys:Array<Row>):Void {\n\t\txs.sort((a, b) -> a.k - b.k);\n'
			+ '\t\tys.sort((p, q) -> p.k - q.k);\n\t}\n}\n\ntypedef Row = {k:Int};\n';
		final dir: String = CliFixture.writeDir('dupcmpfix', [{ name: 'C.hx', source: c }]);
		Assert.equals(0, Cli.run(['lint', '--fix', '--no-oracle', '--rule', 'duplicate-comparator', dir]), 'lint --fix exits ok');
		final out: String = File.getContent('$dir/C.hx');
		CliFixture.removeDir(dir);
		Assert.isTrue(out.indexOf('xs.sort(byK);') != -1 && out.indexOf('ys.sort(byK);') != -1, out);
		Assert.isTrue(out.indexOf('static function byK(') != -1, out);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/**
	 * A group refused in the first `--fix` pass for spanning packages stays whole in a later pass, which re-lints only the files
	 * the first changed: the rule runs over the full set each pass.
	 */
	@:pin('control')
	@:killer('M-DUPCMP-ACTIVE-SCOPE')
	public function testGroupRefusedInPassOneIsNotPartlyFixedLater(): Void {
		#if (sys || nodejs)
		final a: String = 'package p;\n\nclass A {\n\tpublic function f(xs:Array<{k:Int}>, ys:Array<{k:Int}>, us:Array<{j:Int}>, '
			+ 'vs:Array<{j:Int}>):Void {\n\t\txs.sort((a, b) -> a.k - b.k);\n\t\tys.sort((a, b) -> a.k - b.k);\n'
			+ '\t\tus.sort((a, b) -> a.j - b.j);\n\t\tvs.sort((a, b) -> a.j - b.j);\n\t}\n}\n';
		final b: String =
			'package q;\n\nclass B {\n\tpublic function f(xs:Array<{k:Int}>):Void {\n\t\txs.sort((a, b) -> a.k - b.k);\n\t}\n}\n';
		final dir: String = CliFixture.writeDir('dupcmpscope', []);
		FileSystem.createDirectory('$dir/p');
		FileSystem.createDirectory('$dir/q');
		File.saveContent('$dir/p/A.hx', a);
		File.saveContent('$dir/q/B.hx', b);
		Assert.equals(0, Cli.run(['lint', '--fix', '--no-oracle', '--rule', 'duplicate-comparator', dir]), 'lint --fix exits ok');
		final out: String = File.getContent('$dir/p/A.hx');
		CliFixture.removeDir(dir);
		Assert.isTrue(out.indexOf('us.sort(byJ);') != -1, 'the package-local group is fixed in pass 1: $out');
		Assert.isTrue(out.indexOf('xs.sort((a, b) -> a.k - b.k);') != -1, 'the group spanning packages keeps its lambdas: $out');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Registered, and off unless a config turns it on. */
	public function testRegisteredDefaultOff(): Void {
		Assert.notNull(Linter.byId('duplicate-comparator'));
		Assert.isTrue(Std.isOfType(new DuplicateComparator(), DefaultOff));
	}

	/** The rule's findings over `files` under the config `json` and each file after its cross-file fix. */
	private static function run(
		files: Array<{ file: String, source: String }>, ?notes: Array<ConfigNote>, ?json: String, ?plugin: GrammarPlugin
	): Found {
		final host: GrammarPlugin = plugin ?? new HaxeQueryPlugin();
		final rule: DuplicateComparator = new DuplicateComparator();
		rule.setConfigNotes(notes ?? []);
		final config: LintConfig = LintConfig.parse(json ?? BARE);
		final violations: Array<Violation> = CheckFixture.violationsIn(rule, files, host, _ -> config);
		final edits: Map<String, Array<{ span: Span, text: String }>> = [];
		for (group in rule.crossFileFix(files, violations, host)) for (slice in group) {
			final known: Array<{ span: Span, text: String }> = edits[slice.file] ?? [];
			edits[slice.file] = known.concat(slice.edits);
		}
		return { violations: violations, fixed: [ for (f in files) f.file => CanonicalEdit.applyEdits(f.source, edits[f.file] ?? []) ] };
	}

	/** A class sorting two arrays of `Row` with `body`. */
	private static function inClass(body: String): String {
		return 'class C {\n\tfunction f(xs:Array<Row>, ys:Array<Row>) {\n\t\t$body\n\t}\n}\n$ROW';
	}

	/** `inClass(body)` with `member` inserted before the class's closing brace, as the fix inserts it. */
	private static function fixedClass(body: String, member: String): String {
		return 'class C {\n\tfunction f(xs:Array<Row>, ys:Array<Row>) {\n\t\t$body\n\t}\n\n$member\n}\n$ROW';
	}

	/** A module of package `q` declaring `name`, which sorts an array of `p.Row`. */
	private static function sorter(name: String): String {
		return 'package q;\n\nimport p.Row;\n\nclass $name {\n\tfunction f(xs:Array<Row>) {\n\t\txs.sort((a, b) -> a.k - b.k);\n\t}\n}\n';
	}

	/** `inClass(body)` importing the configured `Order`, with `Order` itself beside it. */
	private static function ordered(body: String): Array<{ file: String, source: String }> {
		return [
			{ file: 'C.hx', source: ORDER_IMPORT + inClass(body) },
			{ file: 'lib/Order.hx', source: ORDER }
		];
	}

}
