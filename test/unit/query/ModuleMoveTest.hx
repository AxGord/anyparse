package unit.query;

import anyparse.query.DeclaredSortedLists.SortedListPart;
import anyparse.query.ModuleMove;
import anyparse.query.MoveDeclaration;
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
	@:killer('M-MODMOVE-MAIN-TYPE-WIDENED')
	public function testAReaderNamingAModulesTypesOneByOneGainsItsMainTypeTheSameWay(): Void {
		final a: String = 'package pkg;\n\nclass A {}\n\ntypedef Sub = { var x: Int; }\n';
		final user: String = 'package pkg;\n\nimport pkg.A.Sub;\n\nclass User {\n\tvar a: A;\n\tvar s: Sub;\n}\n';
		final out: ModuleMoveOutcome = moved(
			[move('src/pkg/A.hx', 'src/pkg/sub/A.hx')],
			[file('src/pkg/A.hx', a), file('src/pkg/User.hx', user)]
		);
		Assert.equals(
			'package pkg;\n\nimport pkg.sub.A.A;\nimport pkg.sub.A.Sub;\n\nclass User {\n\tvar a: A;\n\tvar s: Sub;\n}\n',
			textOf(out, 'src/pkg/User.hx')
		);
		Assert.same(['src/pkg/User.hx: import pkg.sub.A.A;'], out.imports);
	}

	@:pin('control')
	@:killer('M-MODMOVE-SORTED-GUARD-OFF')
	public function testAnUndeclaredSortedListTheMoveWouldUnsortIsRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {}\n';
		final b: String = 'package pkg;\n\nclass B {}\n';
		final reg: String = "package reg;\n\nclass Reg {\n\tpublic static final ALL: Array<String> = ['pkg.A', 'pkg.B'];\n}\n";
		final reasons: Array<String> = refused(
			[move('src/pkg/A.hx', 'src/pkg/zz/A.hx')],
			[file('src/pkg/A.hx', a), file('src/pkg/B.hx', b), file('src/reg/Reg.hx', reg)]
		);
		Assert.equals(1, reasons.length);
		Assert.isTrue(reasons[0].contains('src/reg/Reg.hx:4 holds a sorted list the move would leave unsorted'), reasons[0]);
	}

	@:pin('control')
	@:killer('M-MODMOVE-HOLES-MASKED')
	public function testANameInAnInterpolationHoleIsProbedLikeCode(): Void {
		final a: String = "package p;\n\nclass A {\n\tpublic static function f(): String return 'v=${Helper.x}';\n}\n";
		final helper: String = 'package p;\n\nclass Helper {\n\tpublic static final x: Int = 1;\n}\n';
		final namesake: String = 'package p.q;\n\nclass Helper {\n\tpublic static final x: Int = 2;\n}\n';
		final reader: String = "package r;\n\nimport p.*;\n\nclass Reader {\n\tstatic function g(): String return '${A.f()}';\n}\n";
		final out: ModuleMoveOutcome = moved([move('src/p/A.hx', 'src/p/q/A.hx')], [
			file('src/p/A.hx', a),
			file('src/p/Helper.hx', helper),
			file('src/p/q/Helper.hx', namesake),
			file('src/r/Reader.hx', reader)
		]);
		Assert.isTrue(textOf(out, 'src/p/q/A.hx').contains('import p.Helper;'), 'the hole keeps reading p.Helper');
		Assert.isTrue(textOf(out, 'src/r/Reader.hx').contains('import p.q.A;'), 'a reader naming A only in a hole gains its import');
	}

	@:pin('control')
	@:killer('M-MODMOVE-USING-GAIN-BLIND')
	public function testAnAmbientUsingTheNewDirectoryAddsIsRefused(): Void {
		final a: String = 'package p;\n\nclass A {\n\tpublic static function f(): Int return 3.twice();\n}\n';
		final tools: String = 'package p.q;\n\nclass Tools3 {\n\tpublic static function twice(n: Int): Int return n * 3;\n}\n';
		final reasons: Array<String> = refused([move('src/p/A.hx', 'src/p/q/A.hx')], [
			file('src/p/A.hx', a),
			file('src/p/q/Tools3.hx', tools),
			file('src/p/q/import.hx', 'using p.q.Tools3;\n')
		]);
		Assert.equals(1, reasons.length);
		Assert.isTrue(reasons[0].contains('gains `using p.q.Tools3`'), reasons[0]);
	}

	@:pin('control')
	@:killer('M-MODMOVE-USING-LOST-DROPPED')
	public function testAnAmbientUsingTheModuleLeavesIsCarried(): Void {
		final a: String = 'package p;\n\nclass A {\n\tpublic static function f(): Int return 3.twice();\n}\n';
		final tools: String = 'package p;\n\nclass Tools {\n\tpublic static function twice(n: Int): Int return n * 2;\n}\n';
		final out: ModuleMoveOutcome = moved([move('src/p/A.hx', 'src/s/A.hx')], [
			file('src/p/A.hx', a),
			file('src/p/Tools.hx', tools),
			file('src/p/import.hx', 'using p.Tools;\n')
		]);
		Assert.equals(
			'package s;\n\nusing p.Tools;\n\nclass A {\n\tpublic static function f(): Int return 3.twice();\n}\n',
			textOf(out, 'src/s/A.hx')
		);
	}

	@:pin('control')
	@:killer('M-MODMOVE-GRANT-BLIND')
	public function testAPackageGrantTheModuleLeavesIsRefused(): Void {
		final a: String = 'package p;\n\nclass A {\n\tpublic static function f(): Int return Helper.secret();\n}\n';
		final helper: String = 'package p;\n\nclass Helper {\n\t@:allow(p) static function secret(): Int return 1;\n}\n';
		final reasons: Array<String> =
			refused([move('src/p/A.hx', 'src/s/A.hx')], [file('src/p/A.hx', a), file('src/p/Helper.hx', helper)]);
		Assert.equals(1, reasons.length);
		Assert.isTrue(reasons[0].contains('src/p/Helper.hx:4 grants package p private access, and p.A leaves it'), reasons[0]);
	}

	@:pin('control')
	@:killer('M-MODMOVE-PACKAGE-VALUE-BLIND')
	public function testAPackageNameHeldAsAValueIsRefused(): Void {
		final a: String = 'package p;\n\nclass A {}\n';
		final user: String = "package other;\n\nclass User {\n\tstatic final PK: String = 'p';\n"
			+ "\tstatic function f(): Dynamic return Type.resolveClass(PK + '.A');\n}\n";
		final reasons: Array<String> = refused(
			[move('src/p/A.hx', 'src/p/q/A.hx')],
			[file('src/p/A.hx', a), file('src/other/User.hx', user)]
		);
		Assert.equals(1, reasons.length);
		Assert.isTrue(reasons[0].contains('src/other/User.hx:4 composes a path from "p"'), reasons[0]);
	}

	@:pin('control')
	@:killer('M-MODMOVE-DECL-UNKNOWN-KEY')
	public function testADeclarationWithAnUnknownKeyIsRefused(): Void {
		switch MoveDeclaration.read('{"move": {"scope": ["src"], "txt": ["docs"]}}', '/project') {
			case Left(message):
				Assert.isTrue(message.contains('declares unknown key "txt"'), message);
			case Right(_):
				Assert.fail('a misspelt key must not be dropped in silence');
		}
	}

	@:pin('control')
	@:killer('M-MODMOVE-USING-CARRY-APPENDED')
	public function testACarriedUsingKeepsItsPlaceBeforeTheModulesOwn(): Void {
		final a: String = 'package p;\n\nusing p.Own;\n\nclass A {\n\tpublic static function f(): Int return 3.twice();\n}\n';
		final own: String = 'package p;\n\nclass Own {\n\tpublic static function twice(n: Int): Int return n * 10;\n}\n';
		final tools: String = 'package p;\n\nclass Tools {\n\tpublic static function twice(n: Int): Int return n * 2;\n}\n';
		final out: ModuleMoveOutcome = moved([move('src/p/A.hx', 'src/s/A.hx')], [
			file('src/p/A.hx', a),
			file('src/p/Own.hx', own),
			file('src/p/Tools.hx', tools),
			file('src/p/import.hx', 'using p.Tools;\n')
		]);
		Assert.equals(
			'package s;\n\nusing p.Tools;\nusing p.Own;\n\nclass A {\n\tpublic static function f(): Int return 3.twice();\n}\n',
			textOf(out, 'src/s/A.hx')
		);
	}

	@:pin('control')
	@:killer('M-MODMOVE-USING-ORDER-BLIND')
	public function testAUsingOrderNoCarryReproducesIsRefused(): Void {
		final a: String = 'package p;\n\nclass A {\n\tpublic static function f(): Int return 3.twice();\n}\n';
		final tools: String = 'package p;\n\nclass Tools {\n\tpublic static function twice(n: Int): Int return n * 2;\n}\n';
		final other: String = 'package other;\n\nclass Other {\n\tpublic static function twice(n: Int): Int return n * 100;\n}\n';
		final reasons: Array<String> = refused([move('src/p/A.hx', 'src/s/A.hx')], [
			file('src/p/A.hx', a),
			file('src/p/Tools.hx', tools),
			file('src/other/Other.hx', other),
			file('src/p/import.hx', 'using p.Tools;\nusing other.Other;\n'),
			file('src/s/import.hx', 'using other.Other;\n')
		]);
		Assert.equals(1, reasons.length);
		Assert.isTrue(reasons[0].contains('order'), reasons[0]);
	}

	@:pin('control')
	@:killer('M-MODMOVE-QUALIFIED-BLIND')
	public function testAQualifiedSubTypeInATypePositionIsWrittenInFull(): Void {
		final spawn: String =
			'package pkg;\n\nclass Spawn {\n\tpublic static function run(): Run return null;\n}\n\ntypedef Run = { var out: String; }\n';
		final user: String =
			'package pkg;\n\nclass User {\n\tfunction f(): String {\n\t\tfinal r: Spawn.Run = Spawn.run();\n\t\treturn r.out;\n\t}\n}\n';
		final out: ModuleMoveOutcome = moved(
			[move('src/pkg/Spawn.hx', 'src/pkg/sub/Spawn.hx')],
			[file('src/pkg/Spawn.hx', spawn), file('src/pkg/User.hx', user)]
		);
		Assert.equals(
			'package pkg;\n\nimport pkg.sub.Spawn;\n\nclass User {\n\tfunction f(): String {\n'
			+ '\t\tfinal r: pkg.sub.Spawn.Run = Spawn.run();\n\t\treturn r.out;\n\t}\n}\n',
			textOf(out, 'src/pkg/User.hx')
		);
		Assert.same(['src/pkg/User.hx: import pkg.sub.Spawn;'], out.imports);
	}

	@:pin('control')
	@:killer('M-MODMOVE-QUALIFIED-BLIND')
	public function testAQualifiedSubTypeInAnExpressionIsWrittenInFull(): Void {
		final tool: String = 'package pkg;\n\nclass Tool {}\n\nclass Helper {\n\tpublic static function go(): Int return 1;\n}\n';
		final a: String = 'package pkg;\n\nclass A {\n\tpublic static function f(): Int return Tool.Helper.go();\n}\n';
		final user: String = 'package pkg;\n\nclass User {\n\tpublic static function g(): Int return Tool.Helper.go();\n}\n';
		final out: ModuleMoveOutcome = moved(
			[
				move('src/pkg/Tool.hx', 'src/pkg/sub/Tool.hx'),
				move('src/pkg/A.hx', 'src/other/A.hx')
			],
			[
				file('src/pkg/Tool.hx', tool),
				file('src/pkg/A.hx', a),
				file('src/pkg/User.hx', user)
			]
		);
		Assert.equals(
			'package other;\n\nclass A {\n\tpublic static function f(): Int return pkg.sub.Tool.Helper.go();\n}\n',
			textOf(out, 'src/other/A.hx')
		);
		Assert.equals(
			'package pkg;\n\nclass User {\n\tpublic static function g(): Int return pkg.sub.Tool.Helper.go();\n}\n',
			textOf(out, 'src/pkg/User.hx')
		);
		Assert.same([], out.imports);
	}

	@:pin('control')
	@:killer('M-MODMOVE-QUALIFIED-BLIND')
	public function testAQualifiedSubTypeTheNewPackageWouldResolveDifferentlyIsRefused(): Void {
		final a: String = 'package p;\n\nclass A {\n\tvar s: Mod.Sub;\n}\n';
		final mod: String = 'package q;\n\nclass Mod {}\n\ntypedef Sub = { var x: Int; }\n';
		final reasons: Array<String> = refused([move('src/p/A.hx', 'src/q/A.hx')], [file('src/p/A.hx', a), file('src/q/Mod.hx', mod)]);
		Assert.equals(1, reasons.length);
		Assert.isTrue(reasons[0].contains('Mod.Sub'), reasons[0]);
	}

	@:pin('control')
	@:killer('M-MODMOVE-SHADOW-BLIND')
	public function testAQualifiedSubTypeWhoseFullPathALocalNameShadowsIsRefused(): Void {
		final tool: String = 'package pkg;\n\nclass Tool {}\n\nclass Helper {\n\tpublic static function go(): Int return 1;\n}\n';
		final user: String = 'package pkg;\n\nclass User {\n\tpublic static function g(pkg: Int): Int return Tool.Helper.go() + pkg;\n}\n';
		final reasons: Array<String> = refused(
			[move('src/pkg/Tool.hx', 'src/pkg/sub/Tool.hx')],
			[file('src/pkg/Tool.hx', tool), file('src/pkg/User.hx', user)]
		);
		Assert.equals(1, reasons.length);
		Assert.isTrue(reasons[0].contains('"pkg" is also a name this file declares'), reasons[0]);
	}

	@:pin('control')
	@:killer('M-MODMOVE-IMPORTS-APPENDED')
	public function testImportsAReaderGainsTakeTheirSortedPlaces(): Void {
		final a: String = 'package pkg;\n\nclass A {}\n';
		final m: String = 'package pkg;\n\nclass M {}\n';
		final user: String = 'package pkg;\n\nimport haxe.ds.StringMap;\nimport zz.Q;\n\nclass User {\n\tvar a: A;\n\tvar m: M;\n}\n';
		final out: ModuleMoveOutcome = moved([move('src/pkg/A.hx', 'src/aa/A.hx'), move('src/pkg/M.hx', 'src/pkg/sub/M.hx')], [
			file('src/pkg/A.hx', a),
			file('src/pkg/M.hx', m),
			file('src/zz/Q.hx', 'package zz;\n\nclass Q {}\n'),
			file('src/pkg/User.hx', user)
		]);
		Assert.equals(
			'package pkg;\n\nimport aa.A;\nimport haxe.ds.StringMap;\nimport pkg.sub.M;\nimport zz.Q;\n\nclass User {\n\tvar a: A;\n'
			+ '\tvar m: M;\n}\n',
			textOf(out, 'src/pkg/User.hx')
		);
	}

	@:pin('control')
	@:killer('M-MODMOVE-UNREADABLE-ACCEPTED')
	public function testANameAnImportOutsideTheScopeMayBindIsRefused(): Void {
		final a: String = 'package pkg;\n\nclass A {}\n';
		final user: String = 'package pkg;\n\nimport zz.Q;\n\nclass User {\n\tvar a: A;\n}\n';
		final reasons: Array<String> = refused(
			[move('src/pkg/A.hx', 'src/aa/A.hx')],
			[file('src/pkg/A.hx', a), file('src/pkg/User.hx', user)]
		);
		Assert.equals(1, reasons.length);
		Assert.isTrue(reasons[0].contains('"A"') && reasons[0].contains('cannot'), reasons[0]);
	}

	@:pin('guard')
	public function testANameOnlyALibraryCouldBindKeepsItsUnreadableMeaning(): Void {
		final a: String = 'package pkg;\n\nimport zz.Q;\n\nclass A {\n\tvar t: Thing;\n}\n';
		final out: ModuleMoveOutcome = moved([move('src/pkg/A.hx', 'src/aa/A.hx')], [file('src/pkg/A.hx', a)]);
		Assert.equals('package aa;\n\nimport zz.Q;\n\nclass A {\n\tvar t: Thing;\n}\n', textOf(out, 'src/aa/A.hx'));
	}

	@:pin('control')
	@:killer('M-MODMOVE-MEMBER-BLIND')
	public function testAStaticFieldOfAnImportedModuleStaysWhenTheSameNamedModuleMoves(): Void {
		final out: ModuleMoveOutcome = moved([move('src/p/Mod.hx', 'src/p/sub/Mod.hx')], staticFieldShape());
		Assert.isFalse(out.changes.exists(c -> c.file == 'src/p/Main.hx'), [for (c in out.changes) c.file].join(', '));
	}

	@:pin('control')
	@:killer('M-MODMOVE-MEMBER-BLIND')
	public function testAStaticFieldOfAnImportedModuleStaysWhenItsReaderMoves(): Void {
		final out: ModuleMoveOutcome = moved([move('src/p/Main.hx', 'src/q/Main.hx')], staticFieldShape());
		Assert.equals(
			'package q;\n\nimport a.Mod;\n\nclass Main {\n\tstatic function main(): Void {\n\t\ttrace(Mod.Sub.go());\n\t}\n}\n',
			textOf(out, 'src/q/Main.hx')
		);
	}

	@:pin('control')
	@:killer('M-MODMOVE-MEMBER-BLIND')
	public function testAnEnumConstructorALibraryModuleNamesAsASubTypeIsABareName(): Void {
		final expr: String = 'package pkg;\n\nenum Expr {\n\tField(name: String);\n\tConst(v: Int);\n}\n';
		final user: String = 'package pkg;\n\nclass User {\n\tstatic function main(): Void {\n\t\ttrace(Expr.Field(\'x\'));\n\t}\n}\n';
		final std: String = 'package haxe.macro;\n\ntypedef Expr = { var pos: Int; }\n\ntypedef Field = { var name: String; }\n';
		final out: ModuleMoveOutcome = moved(
			[move('src/pkg/Expr.hx', 'src/pkg/sub/Expr.hx')],
			[file('src/pkg/Expr.hx', expr), file('src/pkg/User.hx', user)],
			null, null, null, null,
			[file('std/haxe/macro/Expr.hx', std)]
		);
		Assert.equals(
			'package pkg;\n\nimport pkg.sub.Expr;\n\nclass User {\n\tstatic function main(): Void {\n\t\ttrace(Expr.Field(\'x\'));\n\t}\n'
			+ '}\n',
			textOf(out, 'src/pkg/User.hx')
		);
	}

	@:pin('control')
	@:killer('M-MODMOVE-MEMBER-AFTER-BLIND')
	public function testASpellingWhoseHeadComesToBindAMemberIsWrittenInFull(): Void {
		final out: ModuleMoveOutcome = moved([move('src/p/x/R.hx', 'src/p/y/R.hx')], [
			file('src/p/Mod.hx', 'package p;\n\nclass Mod {}\n\nclass Sub {\n\tpublic static function go(): Int return 1;\n}\n'),
			file('src/p/y/Mod.hx', 'package p.y;\n\nclass Mod {\n\tpublic static final Sub: Int = 2;\n}\n'),
			file('src/p/x/R.hx', 'package p.x;\n\nclass R {\n\tpublic static function f(): Int return Mod.Sub.go();\n}\n')
		]);
		Assert.equals(
			'package p.y;\n\nclass R {\n\tpublic static function f(): Int return p.Mod.Sub.go();\n}\n', textOf(out, 'src/p/y/R.hx')
		);
	}

	private static inline function move(from: String, to: String): ModuleRelocation {
		return { from: from, to: to };
	}

	private static inline function file(path: String, source: String): { file: String, source: String } {
		return { file: path, source: source };
	}

	private static function run(
		moves: Array<ModuleRelocation>, files: Array<{ file: String, source: String }>, ?texts: Array<{ file: String, source: String }>,
		?registries: Array<TypePathRegistry>, ?lists: Array<Array<SortedListPart>>, ?mirrors: Array<TestMirror>,
		?library: Array<{ file: String, source: String }>
	): ModuleMoveResult {
		return ModuleMove.run({
			moves: moves,
			scopeFiles: files,
			libraryFiles: library ?? [],
			textFiles: texts ?? [],
			registries: registries ?? [],
			sortedLists: lists ?? [],
			mirrors: mirrors ?? []
		}, new HaxeQueryPlugin());
	}

	private static function moved(
		moves: Array<ModuleRelocation>, files: Array<{ file: String, source: String }>, ?texts: Array<{ file: String, source: String }>,
		?registries: Array<TypePathRegistry>, ?lists: Array<Array<SortedListPart>>, ?mirrors: Array<TestMirror>,
		?library: Array<{ file: String, source: String }>
	): ModuleMoveOutcome {
		return switch run(moves, files, texts, registries, lists, mirrors, library) {
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

	/** `a.Mod` holds a static field `Sub`; `p.Mod` sits beside a type `Sub`; `p.Main` imports `a.Mod` and reads `Mod.Sub` — the field. */
	private static function staticFieldShape(): Array<{ file: String, source: String }> {
		return [
			file(
				'src/a/Mod.hx',
				'package a;\n\nclass Mod {\n\tpublic static final Sub: Helper = new Helper();\n}\n\nclass Helper {\n'
				+ '\tpublic function new() {}\n\n\tpublic function go(): String return \'field\';\n}\n'
			),
			file('src/p/Mod.hx', 'package p;\n\nclass Mod {}\n\nclass Sub {\n\tpublic static function go(): String return \'type\';\n}\n'),
			file(
				'src/p/Main.hx',
				'package p;\n\nimport a.Mod;\n\nclass Main {\n\tstatic function main(): Void {\n\t\ttrace(Mod.Sub.go());\n\t}\n}\n'
			)
		];
	}

}
