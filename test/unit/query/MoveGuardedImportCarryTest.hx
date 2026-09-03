package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.MoveSymbol;
import utest.Assert;
import utest.Test;

using StringTools;
using Lambda;

/**
 * `move` and the `#if`-GUARDED half of its dependency-import carry.
 *
 * A guarded import cannot be reproduced as an unconditional statement, so the carry skipped it —
 * silently. One campaign sweep moved 767 modules and 72 destinations lost
 * `#if (sys || nodejs) import sys.FileSystem; import sys.io.File; #end` with nothing naming a
 * file; the loss showed one compile error at a time, long after the refactor. The op's own
 * advisory admitted the class and never named an instance, which is the delete-gating failure
 * shape one op over: a rewrite that cannot be proven must REFUSE by name, not proceed quietly.
 *
 * These fixtures drive the pure `MoveSymbol.moveType` over in-memory scope files. Each asserts on
 * the destination's own bytes rather than on a count, because the regression they exist for
 * changed a decision (carry / refuse) and not a token.
 *
 * The same file carries the SAME-PACKAGE pins: a dependency the destination's own package already
 * provides needs no statement, and one reached through a MODULE import still does.
 */
@:nullSafety(Strict)
final class MoveGuardedImportCarryTest extends Test {

	/** The source module every guarded fixture moves out of: two guarded imports, both referenced. */
	private static final GUARDED_SRC: String = 'package a;\n\n#if (sys || nodejs)\nimport sys.FileSystem;\nimport sys.io.File;\n#end\n'
		+ 'import haxe.io.Path;\n\nclass Src {\n\tpublic static function read(p: String): String {\n'
		+ '\t\tfinal n: String = Path.withoutDirectory(p);\n\t\t#if (sys || nodejs)\n'
		+ '\t\tif (FileSystem.exists(p)) return File.getContent(p);\n\t\t#end\n\t\treturn n;\n\t}\n}\n';

	/** The block the carry owes the destination — condition, both statements, terminator. */
	private static final CARRIED_BLOCK: String = '#if (sys || nodejs)\nimport sys.FileSystem;\nimport sys.io.File;\n#end';

	/**
	 * The headline shape, reproduced from the 767-module sweep: the moved body reaches two names
	 * only through a `#if`-guarded import block, and the destination is a bare module.
	 *
	 * At base the destination received `import haxe.io.Path;` and NOT the guarded pair, so
	 * `FileSystem` and `File` were unbound under `sys` / `nodejs` — compile-proved on 4.3.7
	 * (`Type not found : FileSystem`) against the same fixture moved by the base engine.
	 */
	public function testAGuardedImportTravelsWithTheDeclarationUnderItsOwnCondition(): Void {
		final dest: String = movedInto('package b;\n');
		Assert.isTrue(dest.contains(CARRIED_BLOCK), 'the guarded pair should arrive under its own condition, got:\n$dest');
		Assert.isTrue(dest.contains('import haxe.io.Path;'), 'the unguarded import should still be carried');
		Assert.isTrue(dest.contains('class Src'), 'the declaration itself should arrive');
	}

	/**
	 * The destination already spells the same condition, so the carry MERGES into that region
	 * instead of writing a second one beside it: one `#if` in the file, the statement it already
	 * held not repeated.
	 */
	public function testACarriedGuardedImportMergesIntoARegionSpellingTheSameCondition(): Void {
		final dest: String = movedInto('package b;\n\n#if (sys || nodejs)\nimport sys.io.File;\n#end\n');
		// Counted on the region that OPENS with an import: the moved body carries a `#if` of its
		// own under the same condition, so counting the directive alone would always answer two.
		Assert.equals(1, countOf(dest, '#if (sys || nodejs)\nimport'), 'the destination should hold ONE import region, got:\n$dest');
		Assert.equals(1, countOf(dest, 'import sys.io.File;'), 'the statement it already held should not be repeated');
		Assert.isTrue(
			dest.contains('#if (sys || nodejs)\nimport sys.io.File;\nimport sys.FileSystem;\n#end'),
			'the missing statement should land inside the existing region, got:\n$dest'
		);
	}

	/**
	 * The `CliFixture` shape, and the reason the carry re-emits the STATEMENT rather than copying
	 * the region: a module whose ENTIRE body sits inside one `#if` has its type declaration in that
	 * region and an `#if` inside a method body, so a whole-region reading refuses a move the op has
	 * always performed. Here the guarded region holds a type declaration; the import still carries.
	 */
	public function testAGuardedRegionThatAlsoDeclaresATypeStillCarriesTheImport(): Void {
		final src: String = 'package a;\n\n#if sys\nimport sys.io.File;\n\nclass Helper {\n\tpublic function new() {}\n}\n#end\n\n'
			+ 'class Src {\n\tpublic static function go(): String return File.getContent(\'x\');\n}\n';
		final dest: String = destinationOf(src, 11, 7, 'package b;\n');
		Assert.isTrue(dest.contains('#if sys\nimport sys.io.File;\n#end'), 'the statement should carry under its condition, got:\n$dest');
		Assert.isFalse(dest.contains('class Helper'), 'the region\'s own type declaration must not travel with the import');
	}

	/** Two guarded regions bind one name, so no single condition carries it — refused, both conditions named. */
	public function testTwoGuardedRegionsBindingOneNameRefuseByName(): Void {
		final src: String = 'package a;\n\n#if js\nimport js.html.Storage;\n#end\n#if sys\nimport sys.db.Storage;\n#end\n\n'
			+ 'class Src {\n\tpublic static function go(): Storage return null;\n}\n';
		final message: String = refusalOf(src, 10, 7);
		Assert.isTrue(message.contains('"Storage"'), 'the refusal should name the dependency, got: $message');
		Assert.isTrue(message.contains('`js`'), 'the refusal should name the first condition, got: $message');
		Assert.isTrue(message.contains('`sys`'), 'the refusal should name the second condition, got: $message');
		Assert.isTrue(message.contains('a/Src.hx'), 'the refusal should name the file, got: $message');
	}

	/** Two regions deep is a conjunction of conditions, and this op will not synthesise a spelling for one. */
	public function testAGuardedImportNestedInASecondRegionRefusesByName(): Void {
		final src: String = 'package a;\n\n#if sys\n#if !macro\nimport sys.io.File;\n#end\n#end\n\n'
			+ 'class Src {\n\tpublic static function go(): String return File.getContent(\'x\');\n}\n';
		final message: String = refusalOf(src, 9, 7);
		Assert.isTrue(message.contains('"File"'), 'the refusal should name the dependency, got: $message');
		Assert.isTrue(message.contains('2 `#if` regions deep'), 'the refusal should name the nesting, got: $message');
	}

	/** An `#else` branch means the NEGATION of the conditions above it, which one carried `#if` cannot spell. */
	public function testAGuardedImportInAnElseBranchRefusesByName(): Void {
		final src: String = 'package a;\n\n#if js\nimport js.Browser;\n#else\nimport sys.io.File;\n#end\n\n'
			+ 'class Src {\n\tpublic static function go(): String return File.getContent(\'x\');\n}\n';
		final message: String = refusalOf(src, 9, 7);
		Assert.isTrue(message.contains('"File"'), 'the refusal should name the dependency, got: $message');
		Assert.isTrue(message.contains('`#else` branch'), 'the refusal should name the branch, got: $message');
	}

	/** An inline region puts a directive on the statement's own line, which the move is not taking. */
	public function testAGuardedImportSharingItsLineWithADirectiveRefusesByName(): Void {
		final src: String = 'package a;\n\n#if sys import sys.io.File; #end\n\n'
			+ 'class Src {\n\tpublic static function go(): String return File.getContent(\'x\');\n}\n';
		final message: String = refusalOf(src, 5, 7);
		Assert.isTrue(message.contains('"File"'), 'the refusal should name the dependency, got: $message');
		Assert.isTrue(message.contains('shares its line'), 'the refusal should say why, got: $message');
		Assert.isTrue(message.contains('(`#if sys`)'), 'the refusal should name the condition, got: $message');
	}

	/**
	 * The SOURCE keeps its guarded imports, exactly as it keeps every other import the departed
	 * declaration was the last user of. Measured while writing this slice: `lint --rule
	 * unused-import` reports the now-unused UNGUARDED import and says nothing about the guarded
	 * one, so the residue the op leaves is not fully swept by the pass its advisory points at.
	 */
	public function testTheSourceKeepsItsGuardedImportsAfterTheCarry(): Void {
		final changes: Array<MoveChange> = okChanges('a/Src.hx', 9, 7, 'b/Src.hx', [
			{ file: 'a/Src.hx', source: GUARDED_SRC },
			{ file: 'b/Src.hx', source: 'package b;\n' }
		]);
		final source: String = sourceOf(changes, 'a/Src.hx');
		Assert.isTrue(source.contains(CARRIED_BLOCK), 'the source keeps the block it no longer uses, got:\n$source');
	}

	/**
	 * T493: a dependency the DESTINATION's own package already provides needs no statement, and
	 * carrying one writes a line that binds nothing. 281 of the 767 modules one sweep moved
	 * received one of these, every one removed again by the `redundant-import` pass.
	 */
	public function testADependencyInTheDestinationsOwnPackageIsNotGivenARedundantImport(): Void {
		final changes: Array<MoveChange> = okChanges('a/Src.hx', 5, 7, 'b/Host.hx', [
			{
				file: 'a/Src.hx',
				source: 'package a;\n\nimport b.Dep;\n\nclass Src {\n\tpublic static function go(): Dep return null;\n}\n'
			},
			{ file: 'b/Dep.hx', source: 'package b;\n\nclass Dep {\n\tpublic function new() {}\n}\n' },
			{ file: 'b/Host.hx', source: 'package b;\n' }
		]);
		final dest: String = sourceOf(changes, 'b/Host.hx');
		Assert.isFalse(dest.contains('import b.Dep;'), 'a same-package module needs no import, got:\n$dest');
		Assert.isTrue(dest.contains('class Src'), 'the declaration itself should still arrive');
	}

	/**
	 * The same skip through an ANCESTOR package, which is where the sweep's own noise came from: the
	 * destination sits in `a.b` and the dependency in `a`. Verified on 4.3.7 rather than assumed — a
	 * `package p.q;` module reads a bare `Dep` declared `package p;` with no import at all, so an
	 * ancestor package IS visibility and the carried statement binds nothing new.
	 */
	public function testADependencyAnAncestorPackageProvidesIsNotGivenARedundantImport(): Void {
		final changes: Array<MoveChange> = okChanges('x/Src.hx', 5, 7, 'a/b/Host.hx', [
			{
				file: 'x/Src.hx',
				source: 'package x;\n\nimport a.Dep;\n\nclass Src {\n\tpublic static function go(): Dep return null;\n}\n'
			},
			{ file: 'a/Dep.hx', source: 'package a;\n\nclass Dep {\n\tpublic function new() {}\n}\n' },
			{ file: 'a/b/Host.hx', source: 'package a.b;\n' }
		]);
		final dest: String = sourceOf(changes, 'a/b/Host.hx');
		Assert.isFalse(dest.contains('import a.Dep;'), 'an ancestor package needs no import, got:\n$dest');
		Assert.isTrue(dest.contains('class Src'), 'the declaration itself should still arrive');
	}

	/**
	 * The counter-case that decides how narrow that skip has to be: a SUB-MODULE type is NOT
	 * visible from its own package without a statement, so `import b.Mod;` keeps carrying even
	 * though `b` is the destination's package. Green at base too — it pins the boundary, not a
	 * change.
	 */
	public function testASubModuleTypeKeepsItsModuleImportInTheDestinationsOwnPackage(): Void {
		final changes: Array<MoveChange> = okChanges('a/Src.hx', 5, 7, 'b/Host.hx', [
			{
				file: 'a/Src.hx',
				source: 'package a;\n\nimport b.Mod;\n\nclass Src {\n\tpublic static function go(): Sub return null;\n}\n'
			},
			{
				file: 'b/Mod.hx',
				source: 'package b;\n\nclass Mod {\n\tpublic function new() {}\n}\n\nclass Sub {\n\tpublic function new() {}\n}\n'
			},
			{ file: 'b/Host.hx', source: 'package b;\n' }
		]);
		Assert.isTrue(sourceOf(changes, 'b/Host.hx').contains('import b.Mod;'), 'a sub-module type needs its module import');
	}

	/**
	 * T492, both arms. A MODULE import binding a SUB-MODULE type carries when the module is in the
	 * SCOPE index, and is silently skipped when it is not — the scope is the RESOLUTION index as
	 * well as the rewrite set, so a dependency outside it binds nothing the op can name. Green at
	 * base: this pins the boundary and the remedy (`widen --scope`), which is what the op's
	 * advisory now says.
	 */
	public function testAModuleImportCarriesOnlyWhenTheModuleIsInsideTheScope(): Void {
		final src: String = 'package a;\n\nimport c.Mod;\n\nclass Src {\n\tpublic static function go(): Sub return null;\n}\n';
		final modFile: { file: String, source: String } = {
			file: 'c/Mod.hx',
			source: 'package c;\n\nclass Mod {\n\tpublic function new() {}\n}\n\nclass Sub {\n\tpublic function new() {}\n}\n'
		};
		final inScope: Array<MoveChange> = okChanges('a/Src.hx', 5, 7, 'b/Host.hx', [
			{ file: 'a/Src.hx', source: src },
			modFile,
			{ file: 'b/Host.hx', source: 'package b;\n' }
		]);
		Assert.isTrue(sourceOf(inScope, 'b/Host.hx').contains('import c.Mod;'), 'a module in scope is carried');
		final outOfScope: Array<MoveChange> = okChanges('a/Src.hx', 5, 7, 'b/Host.hx', [
			{ file: 'a/Src.hx', source: src },
			{ file: 'b/Host.hx', source: 'package b;\n' }
		]);
		Assert.isFalse(sourceOf(outOfScope, 'b/Host.hx').contains('import c.Mod;'), 'a module outside the scope index is not carried');
	}

	/** `GUARDED_SRC` moved into `dest`, returning the destination's new bytes. */
	private inline function movedInto(dest: String): String {
		return destinationOf(GUARDED_SRC, 9, 7, dest);
	}

	/** `src` moved from `a/Src.hx` into a `b/Src.hx` holding `dest`, returning the destination's new bytes. */
	private function destinationOf(src: String, line: Int, col: Int, dest: String): String {
		return sourceOf(okChanges('a/Src.hx', line, col, 'b/Src.hx', [
			{ file: 'a/Src.hx', source: src },
			{
				file: 'a/Other.hx',
				source: 'package a;\n\nclass Other {\n\tpublic static function go(): String return Src.read(\'x\');\n}\n'
			},
			{ file: 'b/Src.hx', source: dest }
		]), 'b/Src.hx');
	}

	/** The refusal `src` produces when its `Src` type is moved to a bare `b/Host.hx`. */
	private function refusalOf(src: String, line: Int, col: Int): String {
		final result: MoveResult = MoveSymbol.moveType('a/Src.hx', line, col, 'b/Host.hx', [
			{ file: 'a/Src.hx', source: src },
			{ file: 'b/Host.hx', source: 'package b;\n' }
		], plugin(), typeRefShape());
		return switch result {
			case Ok(changes, _):
				Assert.fail('expected Err, got Ok with ${changes.length} change(s)');
				'';
			case Err(message): message;
		};
	}

	private function okChanges(
		cursorFile: String, line: Int, col: Int, destFile: String, scopeFiles: Array<{ file: String, source: String }>
	): Array<MoveChange> {
		return switch MoveSymbol.moveType(cursorFile, line, col, destFile, scopeFiles, plugin(), typeRefShape()) {
			case Ok(changes, _): changes;
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
				[];
		};
	}

	private function sourceOf(changes: Array<MoveChange>, file: String): String {
		final change: Null<MoveChange> = changes.find(c -> c.file == file);
		if (change != null) return change.newSource;
		Assert.fail('no change for $file');
		return '';
	}

	/** Occurrences of `needle` in `text` — the merge pins count regions, and one is the whole point. */
	private static function countOf(text: String, needle: String): Int {
		var count: Int = 0;
		var at: Int = text.indexOf(needle);
		while (at >= 0) {
			count++;
			at = text.indexOf(needle, at + needle.length);
		}
		return count;
	}

	private static function plugin(): HaxeQueryPlugin {
		return new HaxeQueryPlugin();
	}

	private static function typeRefShape(): TypeRefShape {
		return new HaxeQueryPlugin().typeRefShape();
	}

}
