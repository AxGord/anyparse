package unit.query;

import anyparse.check.oracle.CompilerDisplayOracle;
import anyparse.core.TempScratch;
import anyparse.query.SymbolIndex;
import anyparse.query.TypingService;
import anyparse.query.TypingService.Resolution;
import haxe.DynamicAccess;
import haxe.Json;
import haxe.io.Path;
import js.node.ChildProcess;
import sys.FileSystem;
import sys.io.File;
import unit.CheckFixture;

/**
 * The name-resolution traps (`test/traps/resolve.json`): at every probe the resolver (`TypingService.resolveAt`) answers
 * the declaration Haxe 4.3.7 names there or `Unknown`, never another one, and an `answered` probe the compiler's own; the
 * catalog's expectations are the compiler's (`--display …@position`, asked here); where the resolver is `Unknown`, the
 * display oracle answers the compiler's declaration (`CompilerDisplayOracle.resolveAt`).
 */
@:nullSafety(Strict)
class ResolveTrapsTest extends Test {

	/** The catalog, relative to the suite's working directory (the repository root). */
	private static inline final CATALOG: String = 'test/traps/resolve.json';

	@:pin('control') @:killer('M-RESOLVE-VALUE-FALLS-THROUGH') @:killer('M-RESOLVE-WILDCARDS-UNASKED')
	@:killer('M-RESOLVE-HYBRID-OFF') @:killer('M-REF-MODULE-NEAREST-LOST') @:killer('M-RESOLVE-HEAD-MEMBER-BLIND')
	public function testTheResolverAnswersTheCompilersDeclarationOrUnknown(): Void {
		final wrong: Array<String> = [];
		for (trap in catalog()) for (probe in trap.probes) {
			final got: Null<String> = resolved(trap, probe);
			final expect: Null<String> = probe.expect;
			if (got != expect && (got != null || probe.answered == true))
				wrong.push('${trap.name} @ ${probe.at}: $got, the compiler $expect');
		}
		Assert.isTrue(wrong.length == 0, 'every answer is the compiler\'s, or Unknown where the probe allows it:\n${wrong.join('\n')}');
	}

	public function testTheCatalogExpectsTheCompilersAnswer(): Void {
		final wrong: Array<String> = [];
		for (trap in catalog()) for (probe in trap.probes) {
			final dir: String = written(trap, probe);
			final source: String = File.getContent(Path.join([dir, probe.file]));
			final reply: String = display(dir, probe.file, offsetOf(source, probe));
			final pos: Null<TypeReplyPosition> = CompilerDisplayOracle.parsePositionResponse(reply);
			final got: Null<String> = pos == null ? null : named(CompilerDisplayOracle.declarationAt(indexOf(trap, probe), pos));
			if (got != probe.expect) wrong.push('${trap.name} @ ${probe.at}: the compiler $got, the catalog ${probe.expect}');
			FileSystem.deleteDirectory(dir);
		}
		Assert.isTrue(wrong.length == 0, 'every expectation is what 4.3.7 names at the probe:\n${wrong.join('\n')}');
	}

	public function testTheOracleAnswersWhereTheResolverCannot(): Void {
		final trap: Trap = catalog().filter(t -> t.name == 'a-value-shadows-the-head')[0];
		final probe: TrapProbe = trap.probes.filter(p -> p.expect != null && p.answered != true)[0];
		Assert.isNull(resolved(trap, probe), 'a member of the head\'s name in the file leaves the resolver Unknown');
		final dir: String = written(trap, probe);
		final main: String = Path.withoutExtension(probe.file).split('/').join('.');
		File.saveContent(Path.join([dir, 'build.hxml']), '-cp .\n-main $main\n--no-output\n');
		final oracle: Null<CompilerDisplayOracle> = CompilerDisplayOracle.start(new HaxeQueryPlugin().typeSyntax, 'build.hxml', dir);
		Assert.notNull(oracle, 'a display server comes up');
		if (oracle != null) {
			final source: String = textOf(trap, probe).get(probe.file) ?? '';
			final index: SymbolIndex = indexOf(trap, probe);
			final got: Resolution = CompilerDisplayOracle.resolveAt(
				oracle, index, new HaxeQueryPlugin(), probe.file, offsetOf(source, probe)
			);
			oracle.stop();
			Assert.equals(probe.expect, named(got), 'the compiler\'s declaration, mapped onto the index');
		}
		FileSystem.deleteDirectory(dir);
	}

	/**
	 * With no oracle, `CompilerDisplayOracle.resolveAt` is the resolver's
	 * own answer: `Unknown` stays `Unknown`, a declaration stays it.
	 */
	@:pin('control')
	@:killer('M-ORACLE-RESOLVE-NO-ORACLE-DROPPED')
	public function testWithoutAnOracleTheResolversAnswerStands(): Void {
		final shadowed: Trap = catalog().filter(t -> t.name == 'a-value-shadows-the-head')[0];
		final unknown: TrapProbe = shadowed.probes.filter(p -> p.expect != null && p.answered != true)[0];
		final full: Trap = catalog().filter(t -> t.name == 'a-full-path-names-its-module')[0];
		final declared: TrapProbe = full.probes.filter(p -> p.answered == true)[0];
		Assert.same([null, declared.expect], [
			for (pair in [{ trap: shadowed, probe: unknown }, { trap: full, probe: declared }]) {
				final source: String = textOf(pair.trap, pair.probe).get(pair.probe.file) ?? '';
				named(CompilerDisplayOracle.resolveAt(
					null, indexOf(pair.trap, pair.probe), new HaxeQueryPlugin(), pair.probe.file, offsetOf(source, pair.probe)
				));
			}
		]);
	}

	/** What the resolver answers at `probe`, as `<file>#<Type>`, null for `Unknown`. */
	private static function resolved(trap: Trap, probe: TrapProbe): Null<String> {
		final source: String = textOf(trap, probe).get(probe.file) ?? '';
		return named(TypingService.resolveAt(indexOf(trap, probe), new HaxeQueryPlugin(), probe.file, offsetOf(source, probe)));
	}

	private static function named(r: Resolution): Null<String> {
		return switch r {
			case Declared(decl): '${decl.file.file}#${decl.type.name}';
			case Unknown: null;
		};
	}

	/** The index over the trap's files and the probe's own. */
	private static function indexOf(trap: Trap, probe: TrapProbe): SymbolIndex {
		return CheckFixture.index([for (file => source in textOf(trap, probe)) { file: file, source: source }], new HaxeQueryPlugin());
	}

	/** Each file of the trap with its text, the probe's file written as the probe gives it. */
	private static function textOf(trap: Trap, probe: TrapProbe): Map<String, String> {
		final out: Map<String, String> = [
			for (file in trap.files.keys()) file => (trap.files.get(file) ?? []).join('\n') + '\n'
		];
		final own: Null<Array<String>> = probe.text;
		if (own != null) out[probe.file] = own.join('\n') + '\n';
		return out;
	}

	/** The offset the probe asks at: its marker's first occurrence in its file, moved by its `offset`. */
	private static function offsetOf(source: String, probe: TrapProbe): Int {
		return source.indexOf(probe.at) + (probe.offset ?? 0);
	}

	/** A fresh directory holding the trap's files and the probe's own. */
	private static function written(trap: Trap, probe: TrapProbe): String {
		final dir: String = Path.join([TempScratch.root(), 'apq-resolve-traps-${Std.random(0x7fffffff)}']);
		for (file => text in textOf(trap, probe)) {
			final path: String = Path.join([dir, file]);
			FileSystem.createDirectory(Path.directory(path));
			File.saveContent(path, text);
		}
		return dir;
	}

	/** The compiler's `--display <file>@<at>@position` reply in `dir`, both streams. */
	private static function display(dir: String, file: String, at: Int): String {
		final args: Array<String> = ['-cp', '.', '--display', '$file@$at@position', '--no-output'];
		final run: Dynamic = ChildProcess.spawnSync('haxe', args, { cwd: dir, encoding: 'utf8' }); // noqa: avoid-dynamic
		return '${run.stdout ?? ''}${run.stderr ?? ''}';
	}

	private static function catalog(): Array<Trap> {
		final read: TrapCatalog = Json.parse(File.getContent(CATALOG));
		return read.traps;
	}

}

/** `test/traps/resolve.json`. */
private typedef TrapCatalog = {
	final traps: Array<Trap>;
}

/** One mini project and the positions a name is asked at in it. */
private typedef Trap = {
	final name: String;
	final files: DynamicAccess<Array<String>>;
	final probes: Array<TrapProbe>;
}

/**
 * One position: in `file` (written as `text` when given), at the first `at` moved by `offset`; `expect` the declaration
 * 4.3.7 names there as `<file>#<Type>`, null for none; `answered` when the resolver must name it.
 */
private typedef TrapProbe = {
	final file: String;
	final ?text: Array<String>;
	final at: String;
	final ?offset: Int;
	final expect: Null<String>;
	final ?answered: Bool;
}
