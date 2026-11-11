package unit.query;

import anyparse.query.ModuleMove;
import anyparse.query.MoveSymbol.MoveChange;

using Lambda;
using StringTools;

/**
 * `ModuleMove.run` over a directory's ambient chain: the source (`import.hx`) travels with the modules it governs, and
 * a `using` the new chain gives a module is refused only where it could take a call over from a statement it outranks.
 */
class ModuleMoveAmbientChainTest extends Test {

	private static final PLAIN: String = 'package p;\n\nclass M {\n\tpublic static function f(w: W): Int return w.zq();\n}\n';

	/** A directory moved whole: its ambient source goes with the modules, so none of them gains or loses what it gave. */
	@:pin('control')
	@:killer('M-MODMOVE-AMBIENT-SOURCE-REFUSED')
	public function testAnAmbientSourceTravelsWithTheModulesItGoverns(): Void {
		final a: String = 'package pkg;\n\nclass A {\n\tvar d: Dep;\n}\n';
		final out: ModuleMoveOutcome = moved(
			[
				move('src/pkg/A.hx', 'src/up/pkg/A.hx'),
				move('src/pkg/import.hx', 'src/up/pkg/import.hx')
			],
			[
				file('src/pkg/A.hx', a),
				file('src/pkg/import.hx', 'import dep.Dep;\n'),
				file('src/dep/Dep.hx', 'package dep;\n\nclass Dep {}\n')
			]
		);
		Assert.equals(a.replace('package pkg;', 'package up.pkg;'), textOf(out, 'src/up/pkg/A.hx'));
		Assert.equals('import dep.Dep;\n', textOf(out, 'src/up/pkg/import.hx'));
		Assert.isTrue(out.removed.contains('src/pkg/import.hx'), out.removed.join(', '));
		Assert.same([], out.imports);
	}

	/** A module the source governs that stays behind would lose the chain unseen: the move is refused, naming the module. */
	@:pin('control')
	@:killer('M-MODMOVE-AMBIENT-GOVERNED-STRANDED')
	public function testAnAmbientSourceLeavingAGovernedModuleBehindIsRefused(): Void {
		final reasons: Array<String> = refused(
			[
				move('src/pkg/A.hx', 'src/up/pkg/A.hx'),
				move('src/pkg/import.hx', 'src/up/pkg/import.hx')
			],
			[
				file('src/pkg/A.hx', 'package pkg;\n\nclass A {\n\tvar d: Dep;\n}\n'),
				file('src/pkg/B.hx', 'package pkg;\n\nclass B {\n\tvar d: Dep;\n}\n'),
				file('src/pkg/import.hx', 'import dep.Dep;\n'),
				file('src/dep/Dep.hx', 'package dep;\n\nclass Dep {}\n')
			]
		);
		Assert.isTrue(reasons.exists(r -> r.contains('src/pkg/B.hx') && r.contains('does not move with it')), reasons.join(' | '));
	}

	/** A `using` the new chain adds under one the module spells itself is outranked by it: the move is admitted. */
	@:pin('control')
	@:killer('M-MODMOVE-USING-GAIN-ALWAYS')
	public function testAGainedUsingNothingBelowItContestsIsAdmitted(): Void {
		final own: String = 'package p;\n\nusing p.Own;\n\nclass M {\n\tpublic static function f(w: W): Int return w.zq();\n}\n';
		final out: ModuleMoveOutcome = moved([move('src/p/M.hx', 'src/s/t/M.hx')], gainShape(own, 'p.Gain', ''));
		Assert.isTrue(textOf(out, 'src/s/t/M.hx').contains('class M'));
	}

	/** A gained `using` that outranks one both may offer a call through takes the call over: still refused. */
	@:pin('control')
	@:killer('M-MODMOVE-USING-GAIN-OUTRANKED-ALL')
	public function testAGainedUsingThatWinsAContestedCallIsRefused(): Void {
		final reasons: Array<String> = refused([move('src/p/M.hx', 'src/s/t/M.hx')], gainShape(PLAIN, 'p.Rival', 'p.Gain'));
		Assert.isTrue(reasons.exists(r -> r.contains('gains `using p.Gain`')), reasons.join(' | '));
	}

	/** A gained `using` above one offering no access of the module's that it offers is admitted: no call can change hands. */
	@:pin('control')
	@:killer('M-MODMOVE-USING-CONTEST-IGNORED')
	public function testAGainedUsingAboveARivalSharingNoNameWithItIsAdmitted(): Void {
		final out: ModuleMoveOutcome = moved([move('src/p/M.hx', 'src/s/t/M.hx')], gainShape(PLAIN, 'p.Other', 'p.Gain'));
		Assert.isTrue(textOf(out, 'src/s/t/M.hx').contains('class M'));
	}

	/**
	 * A module staying in the directory a source arrives in would read its names through a chain it never had (here `Dep`
	 * would turn from the sibling `up.pkg.Dep` into `dep.Dep`): the move is refused, naming it.
	 */
	@:pin('control')
	@:killer('M-MODMOVE-AMBIENT-ARRIVAL-BLIND')
	public function testAnAmbientSourceArrivingBesideAStationaryModuleIsRefused(): Void {
		final reasons: Array<String> = refused(
			[
				move('src/pkg/A.hx', 'src/up/pkg/A.hx'),
				move('src/pkg/import.hx', 'src/up/pkg/import.hx')
			],
			[
				file('src/pkg/A.hx', 'package pkg;\n\nclass A {}\n'),
				file('src/pkg/import.hx', 'import dep.Dep;\n'),
				file('src/dep/Dep.hx', 'package dep;\n\nclass Dep {}\n'),
				file('src/up/pkg/X.hx', 'package up.pkg;\n\nclass X {\n\tvar d: Dep;\n}\n'),
				file('src/up/pkg/Dep.hx', 'package up.pkg;\n\nclass Dep {}\n')
			]
		);
		Assert.isTrue(reasons.exists(r -> r.contains('src/up/pkg/X.hx') && r.contains('stay where they are')), reasons.join(' | '));
	}

	/** A source keeps its file name: another name would no longer be an ambient source. */
	@:pin('control')
	@:killer('M-MODMOVE-AMBIENT-RENAME-KEPT')
	public function testAnAmbientSourceIsNotRenamedByAMove(): Void {
		final reasons: Array<String> = refused([move('src/pkg/import.hx', 'src/up/pkg/other.hx')], [
			file('src/pkg/import.hx', 'import dep.Dep;\n'),
			file('src/dep/Dep.hx', 'package dep;\n\nclass Dep {}\n')
		]);
		Assert.isTrue(reasons.exists(r -> r.contains('keeps the file name')), reasons.join(' | '));
	}

	/** Two chains are not merged: a source moved onto an existing one is refused. */
	@:pin('control')
	@:killer('M-MODMOVE-AMBIENT-DESTINATION-FREE')
	public function testAnAmbientSourceMovedOntoAnExistingOneIsRefused(): Void {
		final reasons: Array<String> = refused(
			[
				move('src/pkg/A.hx', 'src/up/pkg/A.hx'),
				move('src/pkg/import.hx', 'src/up/pkg/import.hx')
			],
			[
				file('src/pkg/A.hx', 'package pkg;\n\nclass A {}\n'),
				file('src/pkg/import.hx', 'import dep.Dep;\n'),
				file('src/up/pkg/import.hx', 'import dep.Other;\n'),
				file('src/dep/Dep.hx', 'package dep;\n\nclass Dep {}\n'),
				file('src/dep/Other.hx', 'package dep;\n\nclass Other {}\n')
			]
		);
		Assert.isTrue(reasons.exists(r -> r.contains('src/up/pkg/import.hx already exists')), reasons.join(' | '));
	}

	/**
	 * A move that gains a `using` it outranks and loses one the old chain gave is admitted, and the lost one is written into
	 * the module: the gained statement never takes part in the order the lost one is carried by.
	 */
	@:pin('control')
	@:killer('M-MODMOVE-USING-GAIN-CARRIED')
	public function testAnOutrankedGainDoesNotStopALostUsingBeingCarried(): Void {
		final files: Array<SourceFile> = gainShape(PLAIN, 'p.Gain', '');
		files.push(file('src/p/import.hx', 'using p.Rival;\n'));
		final out: ModuleMoveOutcome = moved([move('src/p/M.hx', 'src/s/t/M.hx')], files);
		Assert.isTrue(textOf(out, 'src/s/t/M.hx').contains('using p.Rival;'), textOf(out, 'src/s/t/M.hx'));
		Assert.isFalse(textOf(out, 'src/s/t/M.hx').contains('using p.Gain;'));
	}

	private static inline function move(from: String, to: String): ModuleRelocation {
		return { from: from, to: to };
	}

	private static inline function file(path: String, source: String): SourceFile {
		return { file: path, source: source };
	}

	/**
	 * Module `p.M` calling `w.zq()`, moved into `src/s/t`, beside `p.W` and the modules `p.Own`, `p.Gain`, `p.Rival`
	 * (each extending W with `zq`) and `p.Other` (extending it with `other`). The chain there is `using outer;` in `src/s`,
	 * then `using inner;` in `src/s/t` when inner is not empty.
	 */
	private static function gainShape(module: String, outer: String, inner: String): Array<SourceFile> {
		final out: Array<SourceFile> = [
			file('src/p/M.hx', module),
			file('src/p/W.hx', 'package p;\n\nclass W {\n\tpublic function new() {}\n}\n'),
			file('src/s/import.hx', 'using $outer;\n')
		];
		for (name in ['Own', 'Gain', 'Rival'])
			out.push(file('src/p/$name.hx', 'package p;\n\nclass $name {\n\tpublic static function zq(w: W): Int return 1;\n}\n'));
		out.push(file('src/p/Other.hx', 'package p;\n\nclass Other {\n\tpublic static function other(w: W): Int return 1;\n}\n'));
		if (inner != '') out.push(file('src/s/t/import.hx', 'using $inner;\n'));
		return out;
	}

	private static function run(moves: Array<ModuleRelocation>, files: Array<SourceFile>): ModuleMoveResult {
		return ModuleMove.run({
			moves: moves,
			scopeFiles: files,
			libraryFiles: [],
			textFiles: [],
			registries: [],
			sortedLists: [],
			mirrors: []
		}, new HaxeQueryPlugin());
	}

	private static function moved(moves: Array<ModuleRelocation>, files: Array<SourceFile>): ModuleMoveOutcome {
		return switch run(moves, files) {
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

	private static function refused(moves: Array<ModuleRelocation>, files: Array<SourceFile>): Array<String> {
		return switch run(moves, files) {
			case Refused(reasons): reasons;
			case Moved(outcome):
				Assert.fail('expected a refusal, got ${outcome.changes.length} change(s)');
				[];
		};
	}

	private static function textOf(out: ModuleMoveOutcome, path: String): String {
		final change: Null<MoveChange> = out.changes.find(c -> c.file == path);
		if (change != null) return change.newSource;
		Assert.fail('no change for $path among ${out.changes.map(c -> c.file).join(', ')}');
		return '';
	}

}

/** One in-memory source file of a move's scope. */
private typedef SourceFile = { file: String, source: String }
