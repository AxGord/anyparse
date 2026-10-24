package unit.query;

import anyparse.query.DeclaredSortedLists.SortedListPart;
import anyparse.query.ModuleMove;
import anyparse.query.MoveSymbol.MoveChange;
import anyparse.query.TypePathRegistries.TypePathRegistry;

using StringTools;
using Lambda;

/**
 * `ModuleMove.run` — whole modules relocated to another package, driven PURE over in-memory files whose paths exist
 * nowhere on disk (`src/` is the source root, so `src/pkg/A.hx` is the module `pkg.A`). A module not on disk takes its
 * ambient chain from the analysed set (`ModuleMoveBindings.attachVirtualAmbient`), so an `import.hx` in the set governs
 * the modules under it here as a file on disk does in a real run.
 */
class ModuleMoveTest extends Test {

	@:pin('control')
	@:killer('M-MODMOVE-PACKAGE-KEPT')
	public function testAModuleMovesWithItsPrivateNeighbourAndItsReadersFollow(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function f(): Int return Seams.N;\n}\n\nprivate class Seams {\n'
			+ '\tpublic static final N: Int = 1;\n}\n\ntypedef Sub = { var x: Int; }\n';
		final user: String =
			'package other;\n\nimport pkg.A;\nimport pkg.A.Sub;\n\nclass User {\n\tvar s: Sub;\n\tfunction g(): Int return A.f();\n}\n';
		final out: ModuleMoveOutcome = moved(
			[move('src/pkg/A.hx', 'src/pkg/sub/A.hx')],
			[file('src/pkg/A.hx', a), file('src/other/User.hx', user)]
		);
		Assert.equals(a.replace('package pkg;', 'package pkg.sub;'), textOf(out, 'src/pkg/sub/A.hx'));
		Assert.equals(
			user.replace('import pkg.A;', 'import pkg.sub.A;').replace('import pkg.A.Sub;', 'import pkg.sub.A.Sub;'),
			textOf(out, 'src/other/User.hx')
		);
		Assert.same(['src/pkg/A.hx'], out.removed);
	}

	@:pin('control')
	@:killer('M-MODMOVE-TOKENS-NONE')
	@:killer('M-MODMOVE-DOTTED-UNBOUNDED')
	public function testEverySpellingOfTheModulePathIsRewrittenAndNoNeighbourOfIt(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function f(): Int return 1;\n}\n';
		final user: String = 'package other;\n\n/** Reads pkg.A, never pkg.AB. */\n@:access(pkg.A)\nclass User {\n'
			+ '\tstatic final NAME: String = \'pkg.A.f\';\n\tstatic final PATH: String = \'src/pkg/A.hx\';\n'
			+ '\tfunction g(): Int return pkg.A.f() + pkg.AB.h();\n}\n';
		final ab: String = 'package pkg;\n\nclass AB {\n\tpublic static function h(): Int return 2;\n}\n';
		final out: ModuleMoveOutcome = moved([move('src/pkg/A.hx', 'src/pkg/sub/A.hx')], [
			file('src/pkg/A.hx', a),
			file('src/pkg/AB.hx', ab),
			file('src/other/User.hx', user)
		]);
		Assert.equals(
			'package other;\n\n/** Reads pkg.sub.A, never pkg.AB. */\n@:access(pkg.sub.A)\nclass User {\n'
			+ '\tstatic final NAME: String = \'pkg.sub.A.f\';\n\tstatic final PATH: String = \'src/pkg/sub/A.hx\';\n'
			+ '\tfunction g(): Int return pkg.sub.A.f() + pkg.AB.h();\n}\n',
			textOf(out, 'src/other/User.hx')
		);
	}

	@:pin('control')
	@:killer('M-MODMOVE-TEXT-FILES-SKIPPED')
	public function testADeclaredTextFileAndARegistryFollowTheModule(): Void {
		final a: String = 'package pkg;\n\nclass A {}\n';
		final arms: String =
			'{"arms": [{"name": "M-A", "type": "pkg.A", "method": "f"}, {"name": "M-AB", "type": "pkg.AB", "method": "g"}]}';
		final script: String = 'probe src/pkg/A.hx and pkg.A.run(\n';
		final out: ModuleMoveOutcome = moved(
			[move('src/pkg/A.hx', 'src/pkg/sub/A.hx')],
			[file('src/pkg/A.hx', a)],
			[file('arms.json', arms), file('tools/run.sh', script)],
			[{ file: 'arms.json', keys: ['arms.type'] }]
		);
		Assert.equals(arms.replace('"pkg.A"', '"pkg.sub.A"'), textOf(out, 'arms.json'));
		Assert.equals('probe src/pkg/sub/A.hx and pkg.sub.A.run(\n', textOf(out, 'tools/run.sh'));
	}

	@:pin('control')
	@:killer('M-MODMOVE-REPAIR-OFF')
	public function testASamePackageReaderGainsTheImportItsPackageNoLongerGives(): Void {
		final a: String = 'package pkg;\n\nclass A {}\n';
		final user: String = 'package pkg;\n\nimport haxe.ds.StringMap;\n\nclass User {\n\tvar a: A;\n}\n';
		final out: ModuleMoveOutcome = moved(
			[move('src/pkg/A.hx', 'src/pkg/sub/A.hx')],
			[file('src/pkg/A.hx', a), file('src/pkg/User.hx', user)]
		);
		Assert.equals(
			'package pkg;\n\nimport haxe.ds.StringMap;\nimport pkg.sub.A;\n\nclass User {\n\tvar a: A;\n}\n',
			textOf(out, 'src/pkg/User.hx')
		);
		Assert.same(['src/pkg/User.hx: import pkg.sub.A;'], out.imports);
	}

	@:pin('guard')
	public function testAMoveIntoASubpackageStillSeesItsOldPackage(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tvar b: B;\n}\n';
		final b: String = 'package pkg;\n\nclass B {}\n';
		final out: ModuleMoveOutcome = moved(
			[move('src/pkg/A.hx', 'src/pkg/sub/A.hx')],
			[file('src/pkg/A.hx', a), file('src/pkg/B.hx', b)]
		);
		Assert.equals('package pkg.sub;\n\nclass A {\n\tvar b: B;\n}\n', textOf(out, 'src/pkg/sub/A.hx'));
		Assert.same([], out.imports);
	}

	@:pin('control')
	@:killer('M-MODMOVE-REPAIR-OFF')
	public function testAMoveToASiblingPackageImportsWhatItsOldPackageGave(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tvar b: B;\n}\n';
		final b: String = 'package pkg;\n\nclass B {}\n';
		final out: ModuleMoveOutcome = moved([move('src/pkg/A.hx', 'src/other/A.hx')], [file('src/pkg/A.hx', a), file('src/pkg/B.hx', b)]);
		Assert.equals('package other;\n\nimport pkg.B;\n\nclass A {\n\tvar b: B;\n}\n', textOf(out, 'src/other/A.hx'));
	}

	@:pin('control')
	@:killer('M-MODMOVE-DRIFTS-NONE')
	public function testANameTheDestinationPackageWouldTakeAndNoImportGivesBackIsRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tvar l: Lst;\n}\n';
		final lst: String = 'package pkg.sub;\n\nclass Lst {}\n';
		final reasons: Array<String> = refused(
			[move('src/pkg/A.hx', 'src/pkg/sub/A.hx')],
			[file('src/pkg/A.hx', a), file('src/pkg/sub/Lst.hx', lst)]
		);
		Assert.equals(1, reasons.length);
		Assert.isTrue(reasons[0].contains('"Lst" means free before the move and pkg.sub.Lst#Lst after it'), reasons[0]);
	}

	@:pin('control')
	@:killer('M-MODMOVE-RUNS-UNSORTED')
	public function testASortedImportRunStaysSorted(): Void {
		final a: String = 'package pkg;\n\nclass A {}\n';
		final z: String = 'package pkg;\n\nclass Z {}\n';
		final user: String = 'package other;\n\nimport pkg.A;\nimport pkg.Z;\n\nclass User {\n\tvar a: A;\n\tvar z: Z;\n}\n';
		final out: ModuleMoveOutcome = moved([move('src/pkg/A.hx', 'src/pkg/zz/A.hx')], [
			file('src/pkg/A.hx', a),
			file('src/pkg/Z.hx', z),
			file('src/other/User.hx', user)
		]);
		Assert.equals(
			'package other;\n\nimport pkg.Z;\nimport pkg.zz.A;\n\nclass User {\n\tvar a: A;\n\tvar z: Z;\n}\n',
			textOf(out, 'src/other/User.hx')
		);
	}

	@:pin('control')
	@:killer('M-MODMOVE-GLOB-BLIND')
	public function testARegistryGlobWhoseReachTheMoveChangesIsRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {}\n';
		final config: String = '{"ownedTypes": [{"types": ["pkg.B"], "owners": ["pkg.A*"]}]}';
		final reasons: Array<String> = refused(
			[move('src/pkg/A.hx', 'src/pkg/sub/A.hx')],
			[file('src/pkg/A.hx', a)],
			[file('apqlint.json', config)],
			[{ file: 'apqlint.json', keys: ['ownedTypes.owners'] }]
		);
		Assert.equals(1, reasons.length);
		Assert.isTrue(reasons[0].contains('holds the pattern "pkg.A*", which matches pkg.A but not pkg.sub.A'), reasons[0]);
	}

	@:pin('control')
	@:killer('M-MODMOVE-LIST-UNSORTED')
	@:killer('M-MODMOVE-LIST-ONE-PART')
	public function testADeclaredSortedListTakesTheRewrittenEntryToItsPlaceInTheRightPart(): Void {
		final a: String = 'package pkg;\n\nclass A {}\n';
		final low: String =
			"package reg;\n\nclass Low {\n\tpublic static final ALL: Array<String> = [\n\t\t'pkg.A',\n\t\t'pkg.B'\n\t];\n}\n";
		final high: String =
			"package reg;\n\nclass High {\n\tpublic static final ALL: Array<String> = [\n\t\t'pkg.Y',\n\t\t'pkg.Z'\n\t];\n}\n";
		final parts: Array<SortedListPart> = [
			{ file: 'src/reg/Low.hx', select: 'FinalMember:ALL >> ArrayExpr' },
			{ file: 'src/reg/High.hx', select: 'FinalMember:ALL >> ArrayExpr' }
		];
		final out: ModuleMoveOutcome = moved(
			[move('src/pkg/A.hx', 'src/pkg/sub/A.hx')],
			[file('src/pkg/A.hx', a), file('src/reg/Low.hx', low), file('src/reg/High.hx', high)],
			[], [], [parts]
		);
		Assert.equals(
			"package reg;\n\nclass Low {\n\tpublic static final ALL: Array<String> = [\n\t\t'pkg.B'\n\t];\n}\n",
			textOf(out, 'src/reg/Low.hx')
		);
		Assert.equals(
			"package reg;\n\nclass High {\n\tpublic static final ALL: Array<String> = [\n\t\t'pkg.Y',\n\t\t'pkg.Z',\n\t\t'pkg.sub.A'\n"
			+ '\t];\n}\n',
			textOf(out, 'src/reg/High.hx')
		);
	}

	@:pin('control')
	@:killer('M-MODMOVE-MIRROR-OFF')
	public function testAMovedModuleTakesItsMirroredTestAlong(): Void {
		final a: String = 'package pkg;\n\nclass A {}\n';
		final test: String = 'package unit.pkg;\n\nimport pkg.A;\n\nclass ATest {\n\tvar a: A;\n}\n';
		final out: ModuleMoveOutcome = moved(
			[move('src/pkg/A.hx', 'src/pkg/sub/A.hx')],
			[file('src/pkg/A.hx', a), file('test/unit/pkg/ATest.hx', test)],
			[], [], [], [{ source: 'src', test: 'test/unit', suffixes: ['Test'] }]
		);
		Assert.same(['src/pkg/A.hx', 'test/unit/pkg/ATest.hx'], out.removed);
		Assert.equals(
			'package unit.pkg.sub;\n\nimport pkg.sub.A;\n\nclass ATest {\n\tvar a: A;\n}\n', textOf(out, 'test/unit/pkg/sub/ATest.hx')
		);
	}

	@:pin('control')
	@:killer('M-MODMOVE-COMPOSE-BLIND')
	public function testAPathComposedFromTheOldPackageAtRunTimeIsRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {}\n';
		final user: String =
			"package other;\n\nclass User {\n\tstatic function f(n: String): Dynamic return Type.resolveClass('pkg.' + n);\n}\n";
		final reasons: Array<String> = refused(
			[move('src/pkg/A.hx', 'src/pkg/sub/A.hx')],
			[file('src/pkg/A.hx', a), file('src/other/User.hx', user)]
		);
		Assert.equals(1, reasons.length);
		Assert.isTrue(reasons[0].contains('src/other/User.hx:4 composes a path from "pkg."'), reasons[0]);
	}

	@:pin('control')
	@:killer('M-MODMOVE-SHADOW-BLIND')
	public function testAQualifiedPathWhoseHeadALocalNameShadowsIsRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function f(): Int return 1;\n}\n';
		final user: String = 'package other;\n\nclass User {\n\tfunction g(pkg: Dynamic): Int return pkg.A.f();\n}\n';
		final reasons: Array<String> = refused(
			[move('src/pkg/A.hx', 'src/pkg/sub/A.hx')],
			[file('src/pkg/A.hx', a), file('src/other/User.hx', user)]
		);
		Assert.equals(1, reasons.length);
		Assert.isTrue(reasons[0].contains('"pkg" is also a name this file declares'), reasons[0]);
	}

	@:pin('control')
	@:killer('M-MODMOVE-DEST-OVERWRITE')
	public function testAnExistingDestinationIsRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {}\n';
		final there: String = 'package pkg.sub;\n\nclass A {}\n';
		final reasons: Array<String> = refused(
			[move('src/pkg/A.hx', 'src/pkg/sub/A.hx')],
			[file('src/pkg/A.hx', a), file('src/pkg/sub/A.hx', there)]
		);
		Assert.same(['src/pkg/sub/A.hx already exists'], reasons);
	}

	@:pin('control')
	@:killer('M-MODMOVE-AT-IGNORED')
	public function testAWholeModuleConditionalRegionGetsItsImportInsideTheRegion(): Void {
		final a: String = 'package pkg;\n\nclass A {}\n';
		final user: String = 'package pkg;\n\n#if macro\nimport haxe.macro.Expr;\n\nclass User {\n\tvar a: A;\n}\n#end\n';
		final out: ModuleMoveOutcome = moved(
			[move('src/pkg/A.hx', 'src/pkg/sub/A.hx')],
			[file('src/pkg/A.hx', a), file('src/pkg/User.hx', user)]
		);
		Assert.equals(
			'package pkg;\n\n#if macro\nimport haxe.macro.Expr;\nimport pkg.sub.A;\n\nclass User {\n\tvar a: A;\n}\n#end\n',
			textOf(out, 'src/pkg/User.hx')
		);
	}

	@:pin('control')
	@:killer('M-MODMOVE-AMBIENT-DISK-ONLY')
	public function testAModuleLeavingItsAmbientSourceImportsWhatTheSourceGave(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tvar d: Dep;\n}\n';
		final ambient: String = 'import dep.Dep;\n';
		final dep: String = 'package dep;\n\nclass Dep {}\n';
		final out: ModuleMoveOutcome = moved([move('src/pkg/A.hx', 'src/other/A.hx')], [
			file('src/pkg/A.hx', a),
			file('src/pkg/import.hx', ambient),
			file('src/dep/Dep.hx', dep)
		]);
		Assert.equals('package other;\n\nimport dep.Dep;\n\nclass A {\n\tvar d: Dep;\n}\n', textOf(out, 'src/other/A.hx'));
	}

	@:pin('control')
	@:killer('M-MODMOVE-SUBTYPE-KEPT')
	public function testTheImportAReaderGainsReplacesItsSubTypeImportsOfThatModule(): Void {
		final a: String = 'package pkg;\n\nclass A {}\n\ntypedef Sub = { var x: Int; }\n';
		final user: String = 'package pkg;\n\nimport pkg.A.Sub;\n\nclass User {\n\tvar a: A;\n\tvar s: Sub;\n}\n';
		final out: ModuleMoveOutcome = moved(
			[move('src/pkg/A.hx', 'src/pkg/sub/A.hx')],
			[file('src/pkg/A.hx', a), file('src/pkg/User.hx', user)]
		);
		Assert.equals('package pkg;\n\nimport pkg.sub.A;\n\nclass User {\n\tvar a: A;\n\tvar s: Sub;\n}\n', textOf(out, 'src/pkg/User.hx'));
	}

	private static inline function move(from: String, to: String): ModuleRelocation {
		return { from: from, to: to };
	}

	private static inline function file(path: String, source: String): { file: String, source: String } {
		return { file: path, source: source };
	}

	private static function run(
		moves: Array<ModuleRelocation>, files: Array<{ file: String, source: String }>, ?texts: Array<{ file: String, source: String }>,
		?registries: Array<TypePathRegistry>, ?lists: Array<Array<SortedListPart>>, ?mirrors: Array<TestMirror>
	): ModuleMoveResult {
		return ModuleMove.run({
			moves: moves,
			scopeFiles: files,
			textFiles: texts ?? [],
			registries: registries ?? [],
			sortedLists: lists ?? [],
			mirrors: mirrors ?? []
		}, new HaxeQueryPlugin());
	}

	private static function moved(
		moves: Array<ModuleRelocation>, files: Array<{ file: String, source: String }>, ?texts: Array<{ file: String, source: String }>,
		?registries: Array<TypePathRegistry>, ?lists: Array<Array<SortedListPart>>, ?mirrors: Array<TestMirror>
	): ModuleMoveOutcome {
		return switch run(moves, files, texts, registries, lists, mirrors) {
			case Moved(outcome): outcome;
			case Refused(reasons):
				Assert.fail('expected the move, got refused: ${reasons.join(' | ')}');
				{
					changes: [],
					removed: [],
					moves: [],
					renames: [],
					imports: []
				};
		};
	}

	private static function refused(
		moves: Array<ModuleRelocation>, files: Array<{ file: String, source: String }>, ?texts: Array<{ file: String, source: String }>,
		?registries: Array<TypePathRegistry>
	): Array<String> {
		return switch run(moves, files, texts, registries) {
			case Refused(reasons): reasons;
			case Moved(outcome):
				Assert.fail('expected a refusal, got ${outcome.changes.length} change(s)');
				[];
		};
	}

	private static function textOf(out: ModuleMoveOutcome, path: String): String {
		final change: Null<MoveChange> = out.changes.find(c -> c.file == path);
		if (change != null) return change.newSource;
		Assert.fail('no change for $path among ${[for (c in out.changes) c.file].join(', ')}');
		return '';
	}

}
