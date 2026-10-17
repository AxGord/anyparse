package unit.check;

#if (sys || nodejs)
import sys.io.File;
#end
import anyparse.check.Check.RiskyCrossFileEdit;
import anyparse.check.Check.Violation;
import anyparse.check.CompilerOracle;
import anyparse.check.FixVerifierCrossFile;
import anyparse.check.Naming;
import anyparse.check.NamingCrossRename;
import anyparse.check.NamingRenames.RenameRefusal;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeIdentifierCase;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.query.Cli;
import anyparse.query.GrammarPlugin;
import anyparse.runtime.Span;
import unit.CheckFixture;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

using StringTools;
using Lambda;

/**
 * `naming`'s CROSS-FILE rename arm (`NamingCrossRename`): a type or an enum-abstract value is renamed in
 * every file that names it through the `rename --scope` engines, and only through the compiler oracle
 * (`FixVerifierCrossFile`). The unit fixtures read the arm's answer off the check; the CLI fixtures at
 * the end drive `lint --fix` with an oracle and without one.
 *
 * Every refusal fixture is the CONTROL fixture with one thing changed, so a refusal there is about that
 * one thing.
 */
@:nullSafety(Strict)
final class NamingCrossRenameTest extends Test {

	/** A module whose sub-type `JSON_POINT` is a typedef, read through its qualified path elsewhere. */
	private static final TYPES: String = 'package pkg;\n\nclass T {\n\tpublic static function make():JSON_POINT {\n\t\treturn {x: 1, y: 2};\n\t}\n}\n\n'
		+ 'typedef JSON_POINT = {\n\tx:Float,\n\ty:Float\n}\n';

	/** A reader naming the typedef through its module. */
	private static final USER: String =
		'package pkg;\n\nclass U {\n\tpublic static function sum(p:T.JSON_POINT):Float {\n\t\treturn p.x + p.y;\n\t}\n}\n';

	/** An enum abstract with an explicitly-valued value, one over `Int` with an implicit one, one over `String` with an implicit one. */
	private static final ENUMS: String = 'package pkg;\n\nclass E {}\n\nenum abstract MY_ACTIONS(String) to String {\n\tfinal goals = \'g\';\n}\n\n'
		+ 'enum abstract Levels(Int) {\n\tvar Low;\n\tvar high;\n}\n\nenum abstract Mode(String) {\n\tvar fast;\n}\n';

	/** A reader of the enum abstracts. */
	private static final ENUM_USER: String = 'package pkg;\n\nclass F {\n\tpublic static function f():String {\n'
		+ '\t\treturn MY_ACTIONS.goals + Levels.high + Mode.fast;\n\t}\n}\n';

	@:pin('control')
	@:killer('M-XRENAME-NOT-CANDIDATE', 'M-XRENAME-FINDINGS-NONE', 'M-XRENAME-EDITS-DROPPED')
	public function testATypedefRenamesInEveryFileThatNamesIt(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/T.hx', source: TYPES },
			{ file: 'pkg/U.hx', source: USER }
		];
		final sets: Array<RiskyCrossFileEdit> = armSets(files, [], 'JSON_POINT');
		Assert.equals(1, sets.length);
		if (sets.length == 0) return;
		Assert.equals(2, sets[0].slices.length, 'the declaring file and the reader');
		for (slice in sets[0].slices) {
			final rewritten: String = CanonicalEdit.applyEdits(sourceOf(files, slice.file), slice.edits);
			Assert.stringContains('JsonPoint', rewritten, slice.file);
			Assert.isFalse(rewritten.contains('JSON_POINT'), slice.file);
		}
	}

	@:pin('control')
	@:killer('M-XRENAME-INDEXED-UNDERLYING')
	public function testAnEnumAbstractAndItsValuesRename(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/E.hx', source: ENUMS },
			{ file: 'pkg/F.hx', source: ENUM_USER }
		];
		for (name in ['MY_ACTIONS', 'goals', 'high']) Assert.equals(1, armSets(files, [], name).length, name);
		final fast: Array<RiskyCrossFileEdit> = armSets(files, [], 'fast');
		Assert.equals(0, fast.length, 'an implicit String value is its name');
		Assert.equals(NamingCrossRename.IMPLICIT_VALUE, _lastReason);
	}

	/** Each gate, alone on a control fixture, refuses with its own reason. */
	@:pin('control')
	@:killer('M-XRENAME-RUNTIME-TYPE', 'M-XRENAME-MAIN-TYPE', 'M-XRENAME-TYPE-META', 'M-XRENAME-SAFE-META', 'M-XRENAME-GUARDED',
		'M-XRENAME-ENUM-CTOR', 'M-XRENAME-STRING', 'M-XRENAME-TYPE-PATH', 'M-XRENAME-OLD-SHARED', 'M-XRENAME-NEW-DECLARED',
		'M-XRENAME-NEW-SPELLED', 'M-XRENAME-VALUE-OLD-SHARED', 'M-XRENAME-VALUE-NEW-SHARED', 'M-XRENAME-VALUE-BOUND', 'M-XRENAME-OUTSIDE',
		'M-XRENAME-VALUE-META')
	public function testEachGateRefusesWithItsReason(): Void {
		final types: { file: String, source: String } = { file: 'pkg/T.hx', source: TYPES };
		final user: { file: String, source: String } = { file: 'pkg/U.hx', source: USER };
		final enums: { file: String, source: String } = { file: 'pkg/E.hx', source: ENUMS };
		final enumUser: { file: String, source: String } = { file: 'pkg/F.hx', source: ENUM_USER };
		final cases: Array<{
			what: String,
			files: Array<{ file: String, source: String }>,
			roots: Array<{ file: String, source: String }>,
			name: String,
			reason: String
		}> = [
			{
				what: 'a class',
				files: [{ file: 'pkg/T.hx', source: TYPES + 'class Helper_Box {}\n' }],
				roots: [],
				name: 'Helper_Box',
				reason: NamingCrossRename.RUNTIME_TYPE
			},
			{
				what: 'a module main type',
				files: [
					{ file: 'pkg/JSON_MAIN.hx', source: 'package pkg;\n\ntypedef JSON_MAIN = {\n\tx:Int\n}\n' }
				],
				roots: [],
				name: 'JSON_MAIN',
				reason: NamingCrossRename.MAIN_TYPE
			},
			{
				what: 'metadata on the type',
				files: [
					{ file: 'pkg/T.hx', source: TYPES.replace('typedef JSON_POINT', '@:native(\'Pt\')\ntypedef JSON_POINT') },
					user
				],
				roots: [],
				name: 'JSON_POINT',
				reason: NamingCrossRename.TYPE_METADATA
			},
			{
				what: 'a keep',
				files: [
					{ file: 'pkg/T.hx', source: TYPES.replace('typedef JSON_POINT', '@:keep\ntypedef JSON_POINT') },
					user
				],
				roots: [],
				name: 'JSON_POINT',
				reason: NamingCrossRename.TYPE_METADATA
			},
			{
				what: 'a type only one build sees',
				files: [
					{ file: 'pkg/T.hx', source: TYPES.replace('typedef JSON_POINT', '#if js\ntypedef JSON_POINT') + '#end\n' },
					user
				],
				roots: [],
				name: 'JSON_POINT',
				reason: NamingCrossRename.GUARDED
			},
			{
				what: 'a plain enum constructor',
				files: [{ file: 'pkg/E.hx', source: ENUMS + 'enum Kind {\n\tsmall;\n}\n' }],
				roots: [],
				name: 'small',
				reason: NamingCrossRename.ENUM_CONSTRUCTOR
			},
			{
				what: 'a literal naming the type',
				files: [
					types,
					{ file: 'pkg/U.hx', source: USER.replace('return p.x + p.y;', 'trace(\'JSON_POINT\');\n\t\treturn p.x + p.y;') }
				],
				roots: [],
				name: 'JSON_POINT',
				reason: NamingCrossRename.STRING_LITERAL
			},
			{
				what: 'a runtime type path',
				files: [
					types,
					{
						file: 'pkg/U.hx',
						source: USER.replace('return p.x + p.y;', 'trace(Type.resolveClass(\'pkg.T.JSON_POINT\'));\n\t\treturn p.x + p.y;')
					}
				],
				roots: [],
				name: 'JSON_POINT',
				reason: NamingCrossRename.STRING_LITERAL
			},
			{
				what: 'another declaration of the old name',
				files: [
					types,
					user,
					{ file: 'pkg/V.hx', source: 'package pkg;\n\nclass V {}\n\ntypedef JSON_POINT = {\n\tz:Int\n}\n' }
				],
				roots: [],
				name: 'JSON_POINT',
				reason: NamingCrossRename.OLD_NAME_SHARED
			},
			{
				what: 'a declaration of the new name',
				files: [
					types,
					user,
					{ file: 'pkg/JsonPoint.hx', source: 'package pkg;\n\nclass JsonPoint {}\n' }
				],
				roots: [],
				name: 'JSON_POINT',
				reason: NamingCrossRename.NEW_NAME_TAKEN
			},
			{
				what: 'the new name spelled in code',
				files: [
					types,
					{ file: 'pkg/U.hx', source: USER.replace('return p.x + p.y;', 'trace(JsonPoint);\n\t\treturn p.x + p.y;') }
				],
				roots: [],
				name: 'JSON_POINT',
				reason: NamingCrossRename.NEW_NAME_TAKEN
			},
			{
				what: 'another enum value of the old name',
				files: [
					enums,
					enumUser,
					{ file: 'pkg/G.hx', source: 'package pkg;\n\nenum abstract G(Int) {\n\tvar goals = 1;\n}\n' }
				],
				roots: [],
				name: 'goals',
				reason: NamingCrossRename.OLD_NAME_SHARED
			},
			{
				what: 'another enum value of the new name',
				files: [
					enums,
					enumUser,
					{ file: 'pkg/G.hx', source: 'package pkg;\n\nenum abstract G(Int) {\n\tvar Goals = 1;\n}\n' }
				],
				roots: [],
				name: 'goals',
				reason: NamingCrossRename.NEW_NAME_TAKEN
			},
			{
				what: 'a binding of the new name where the value is read',
				files: [
					enums,
					{
						file: 'pkg/F.hx',
						source: ENUM_USER.replace('\t\treturn MY_ACTIONS', '\t\tfinal Goals:Int = 1;\n\t\treturn MY_ACTIONS')
					}
				],
				roots: [],
				name: 'goals',
				reason: NamingCrossRename.NEW_NAME_TAKEN
			},
			{
				what: 'metadata on the value',
				files: [
					{ file: 'pkg/E.hx', source: ENUMS.replace('\tfinal goals', '\t@:keep final goals') },
					enumUser
				],
				roots: [],
				name: 'goals',
				reason: RenameRefusal.CARRIES_METADATA
			},
			{
				what: 'a reader outside the run',
				files: [types],
				roots: [user],
				name: 'JSON_POINT',
				reason: RenameRefusal.crossOutsideScope('pkg/U.hx')
			}
		];
		for (c in cases) {
			Assert.equals(0, armSets(c.files, c.roots, c.name).length, c.what);
			Assert.equals(c.reason, _lastReason, c.what);
		}
		// A library declaring the new name: no project file spells it, the index still holds it.
		final library: Array<{ file: String, source: String }> = [
			{
				file: 'lib/ext/JsonPoint.hx',
				source: 'package ext;\n\nclass JsonPoint {}\n'
			}
		];
		Assert.equals(0, armSets([types, user], [], 'JSON_POINT', library).length, 'a library type of the new name');
		Assert.equals(NamingCrossRename.NEW_NAME_TAKEN, _lastReason, 'a library type of the new name');
	}

	/** Metadata the compiler reads and no tool resolves by name does not refuse, and neither does an enum abstract's PROPERTY of the old name. */
	@:pin('control')
	@:killer('M-XRENAME-SAFE-META', 'M-XRENAME-VALUE-PROPERTY')
	public function testInertNeighboursDoNotRefuse(): Void {
		final forward: String = 'package pkg;\n\nclass A {}\n\n@:forward\nabstract SMALL_LIST(Array<Int>) {}\n';
		Assert.equals(1, armSets([{ file: 'pkg/A.hx', source: forward }], [], 'SMALL_LIST').length, '@:forward');
		final property: String = 'package pkg;\n\nenum abstract Handle(Int) {\n\tvar Top;\n\n\tpublic var goals(get, never):Bool;\n\n'
			+ '\tinline function get_goals():Bool {\n\t\treturn true;\n\t}\n}\n';
		Assert.equals(
			1, armSets([
				{ file: 'pkg/E.hx', source: ENUMS },
				{ file: 'pkg/F.hx', source: ENUM_USER },
				{ file: 'pkg/Handle.hx', source: property }
			], [], 'goals').length,
			'a property is no value'
		);
	}

	/** Without the whole project indexed the arm refuses, and so it does for the engine's own refusals. */
	@:pin('control')
	@:killer('M-XRENAME-NO-PROJECT')
	public function testTheArmNeedsTheWholeProject(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/T.hx', source: TYPES },
			{ file: 'pkg/U.hx', source: USER }
		];
		final check: Naming = new Naming();
		final plugin: GrammarPlugin = new HaxeQueryPlugin();
		final own: Array<Violation> = check.riskyCrossFileFindings(findings(check, files, plugin, 'JSON_POINT'));
		Assert.equals(1, own.length);
		Assert.equals(0, check.riskyCrossFileFix(files, own, plugin).length);
		Assert.equals(NamingCrossRename.NO_PROJECT, own[0].declineReason);
		final capture: String = ENUMS.replace(
			'class E {}',
			'class E {\n\tpublic static function f(l:Levels):Int {\n\t\treturn switch l {\n'
			+ '\t\t\tcase high: 1;\n\t\t\tcase _: 0;\n\t\t}\n\t}\n}'
		);
		Assert.equals(0, armSets([{ file: 'pkg/E.hx', source: capture }], [], 'high').length);
		Assert.equals(NamingCrossRename.ENGINE_REFUSED, _lastReason, 'a case capture shares the name');
	}

	/** The safe paths still decline a type, now pointing at the arm. */
	public function testTheSafePathsPointAtTheArm(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/T.hx', source: TYPES },
			{ file: 'pkg/U.hx', source: USER }
		];
		final check: Naming = new Naming();
		final plugin: GrammarPlugin = scoped(files, []);
		final vs: Array<Violation> = findings(check, files, plugin, 'JSON_POINT');
		Assert.equals(0, check.crossFileFix(files, vs, plugin, CheckFixture.index(files, plugin)).length);
		Assert.equals(0, check.fix(TYPES, vs, plugin, CheckFixture.index(files, plugin)).length);
		Assert.equals(RenameRefusal.NOT_A_MEMBER, vs[0].declineReason);
	}

	public function testPascalCase(): Void {
		Assert.equals('Printer', HaxeIdentifierCase.pascalCase('__Printer'));
		Assert.equals('PitchActions', HaxeIdentifierCase.pascalCase('PITCH_ACTIONS'));
		Assert.equals('JsonField', HaxeIdentifierCase.pascalCase('JSON_FIELD'));
		Assert.equals('Goals', HaxeIdentifierCase.pascalCase('goals'));
		Assert.equals('MutliLineTextField', HaxeIdentifierCase.pascalCase('__MutliLineTextField'));
		Assert.isNull(HaxeIdentifierCase.pascalCase('__'));
	}

	/** Edit sets sharing a file are judged as one component, transitively; the others alone. */
	@:pin('control')
	@:killer('M-XVERIFY-NO-MERGE')
	@:access(anyparse.check.FixVerifierCrossFile)
	public function testSetsSharingAFileFormOneComponent(): Void {
		function set(name: String, files: Array<String>): RiskyCrossFileEdit {
			return {
				violation: {
					file: files[0],
					span: null,
					rule: 'naming',
					severity: Severity.Warning,
					message: name
				},
				slices: [for (f in files) { file: f, edits: [] }]
			};
		}
		final a: RiskyCrossFileEdit = set('a', ['f1', 'f2']);
		final b: RiskyCrossFileEdit = set('b', ['f3']);
		final c: RiskyCrossFileEdit = set('c', ['f4', 'f2']);
		final components: Array<Array<RiskyCrossFileEdit>> = FixVerifierCrossFile.componentsOf([a, b, c]);
		Assert.equals(2, components.length);
		Assert.isTrue(components.exists(g -> g.length == 2 && g.contains(a) && g.contains(c)));
		Assert.isTrue(components.exists(g -> g.length == 1 && g.contains(b)));
	}

	/**
	 * End to end through `lint --fix` with a compiler oracle: the typedef rename lands in both files; the
	 * one an aliased import makes the engine miss is rejected by the compiler and bisected out, alone.
	 */
	@:pin('control')
	@:killer('M-RISKYARM-CROSS-NOT-VERIFIED', 'M-XVERIFY-NO-BISECT')
	public function testTheOracleRunRenamesAndRevertsTheMiss(): Void {
		#if (sys || nodejs)
		if (!oracleWorks()) {
			Assert.pass('haxe unavailable — skipped');
			return;
		}
		final dir: String = writeProject('{"compilerOracle":"check.hxml","resolutionRoots":["."]}');
		Cli.run(['lint', '--fix', '--rule', 'naming', dir]);
		final types: String = File.getContent('$dir/pkg/T.hx');
		final main: String = File.getContent('$dir/Main.hx');
		final compiles: Bool = CompilerOracle.typecheck('check.hxml', dir).match(Confirmed);
		CliFixture.removeDir(dir);
		Assert.stringContains('typedef JsonPoint', types);
		Assert.stringContains('pkg.T.JsonPoint', main);
		Assert.stringContains('typedef JSON_RECT', types, 'the alias-import miss is reverted');
		Assert.stringContains('JR', main);
		Assert.isTrue(compiles, 'the tree still builds');
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** Without an oracle the arm is report-only: nothing is written. */
	public function testWithoutAnOracleTheArmIsReportOnly(): Void {
		#if (sys || nodejs)
		final dir: String = writeProject('{"resolutionRoots":["."]}');
		Cli.run(['lint', '--fix', '--rule', 'naming', dir]);
		final types: String = File.getContent('$dir/pkg/T.hx');
		CliFixture.removeDir(dir);
		Assert.equals(ORACLE_TYPES, types);
		#else
		Assert.pass('non-sys target');
		#end
	}

	/** The latest refusal `armSets` read off the arm's finding. */
	private var _lastReason: String = '';

	/**
	 * The arm's edit sets for the `name` finding `naming` reports in `report`'s FIRST file, with `roots` the project
	 * files outside the run and `libs` the library sources beside them.
	 */
	private function armSets(
		report: Array<{ file: String, source: String }>, roots: Array<{ file: String, source: String }>, name: String,
		?libs: Array<{ file: String, source: String }>
	): Array<RiskyCrossFileEdit> {
		final check: Naming = new Naming();
		final plugin: GrammarPlugin = scoped(report, roots, libs);
		final own: Array<Violation> = check.riskyCrossFileFindings(
			findings(check, report, plugin, name).filter(v -> v.file == report[0].file)
		);
		Assert.equals(1, own.length, 'the arm owns the finding on $name');
		final sets: Array<RiskyCrossFileEdit> = check.riskyCrossFileFix(report, own, plugin);
		_lastReason = own.length == 0 ? '' : own[0].declineReason ?? '';
		return sets;
	}

	/** `naming`'s findings on `name` over `files`. */
	private function findings(
		check: Naming, files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, name: String
	): Array<Violation> {
		return CheckFixture.violationsIn(check, files, plugin).filter(v -> v.message.endsWith('\'$name\''));
	}

	private static function sourceOf(files: Array<{ file: String, source: String }>, file: String): String {
		return files.find(f -> f.file == file)?.source ?? '';
	}

	/** A run host indexing the whole project: a declared scope, every root matched, `roots` its files outside `report`, `libs` a library. */
	private function scoped(
		report: Array<{ file: String, source: String }>, roots: Array<{ file: String, source: String }>,
		?libs: Array<{ file: String, source: String }>
	): GrammarPlugin {
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		plugin.setResolutionScope({
			declared: true,
			sources: () -> {
				report: report,
				projectRoots: roots,
				library: new LibrarySources(roots.concat(libs ?? [])),
				rootsMatched: true,
				rootsAllMatched: true
			}
		});
		return plugin;
	}

	/** The oracle project's module: two typedefs, the second read through an aliased import the type engine does not follow. */
	private static final ORACLE_TYPES: String =
		'package pkg;\n\nclass T {}\n\ntypedef JSON_POINT = {\n\tx:Int\n}\n\ntypedef JSON_RECT = {\n\tw:Int\n}\n';

	#if (sys || nodejs)
	/** A project directory: `pkg/T.hx`, a `Main` the oracle compiles that reads both typedefs, and `config` as its `apqlint.json`. */
	private function writeProject(config: String): String {
		final dir: String = CliFixture.writeDir('xrename', [
			{ name: 'apqlint.json', source: config },
			{ name: 'check.hxml', source: '-cp .\n-main Main\n' }
		]);
		sys.FileSystem.createDirectory('$dir/pkg');
		File.saveContent('$dir/pkg/T.hx', ORACLE_TYPES);
		File.saveContent(
			'$dir/Main.hx',
			'import pkg.T.JSON_RECT as JR;\n\nclass Main {\n\tstatic function main() {\n\t\tfinal p:pkg.T.JSON_POINT = {x: 1};\n'
			+ '\t\tfinal r:JR = {w: 2};\n\t\ttrace(p.x + r.w);\n\t}\n}\n'
		);
		return dir;
	}

	private function oracleWorks(): Bool {
		final dir: String = CliFixture.writeDir('xrenameoracle', [
			{ name: 'Main.hx', source: 'class Main {\n\tstatic function main() {}\n}\n' },
			{ name: 'check.hxml', source: '-cp .\n-main Main\n' }
		]);
		final ok: Bool = CompilerOracle.typecheck('check.hxml', dir).match(Confirmed);
		CliFixture.removeDir(dir);
		return ok;
	}
	#end

	/**
	 * A private member of a type whose SIMPLE name another package reuses: the namesake's subtypes are not
	 * this type's, so the member stays confined and the single-file rename takes it (TM `Zoom.IconButton.icon`
	 * beside `common.ui.components.IconButton`).
	 */
	@:pin('control')
	@:killer('M-CONFINED-NO-OWNER-FILE')
	public function testANamesakesSubtypesDoNotUnconfineAPrivate(): Void {
		final zoom: String = 'package pkg;\n\nclass Zoom {}\n\nprivate final class IconButton {\n\tprivate final icon:Int = 1;\n\n'
			+ '\tpublic function new() {}\n\n\tpublic function f():Int {\n\t\treturn icon;\n\t}\n}\n';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/Zoom.hx', source: zoom },
			{ file: 'other/IconButton.hx', source: 'package other;\n\nclass IconButton {}\n' },
			{ file: 'other/Sub.hx', source: 'package other;\n\nclass Sub extends IconButton {}\n' }
		];
		final plugin: GrammarPlugin = new HaxeQueryPlugin();
		final check: Naming = new Naming();
		final vs: Array<Violation> = CheckFixture.violationsIn(check, files, plugin).filter(v -> v.file == 'pkg/Zoom.hx');
		Assert.equals(1, vs.length);
		final edits: Array<{ span: Span, text: String }> = check.fix(zoom, vs, plugin, CheckFixture.index(files, plugin));
		Assert.stringContains('return _icon;', CanonicalEdit.applyEdits(zoom, edits));
	}

}
