package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.GrammarPlugin.TypeRefShape;
import anyparse.query.InheritanceMove;
import anyparse.query.MoveMember;
import anyparse.query.MoveSymbol;
import utest.Assert;
import utest.Test;

using Lambda;

/**
 * The byte-identity capture for the MOVE family — `move`, `move-member`, `pull-up`, `push-down`.
 *
 * Every other campaign-wide capture (`lint --all`, a `--fix` tree, `fmt --list`, the refs / rename /
 * safe-delete fixtures) runs a check or a fixer; none of them ever calls a move op. That is why a
 * refactor of the shared lexical seam could hand `MoveSymbol.referencedInDest` the CURSOR file's
 * comment regions while it was scanning the DESTINATION's text, ship it across 109 files, and leave
 * the whole suite green — the defect was caught by the worker's own forwarding audit, not by a gate.
 *
 * So this class is the gate that was missing: five fixtures driven through the four ops, with the
 * FULL resulting bytes of every changed file pinned. It is deliberately not a set of `contains`
 * assertions — the regression it exists for changed a decision, not a token, and the only assertion
 * that catches "a decision moved" without knowing which decision is the whole file.
 *
 * The fixtures carry, between them, what the family's span arithmetic actually reads: a doc block on
 * the moved declaration, a `using` line to carry, an importer to repoint, a `#if`-guarded member, a
 * cross-package static move, and comments and string literals that spell the moved names.
 *
 * Pure and in-memory: each op is driven through its own `Array<{file, source}>` entry point, so
 * there is no temp directory, no ordering between tests and no cost worth measuring. Run it alone
 * with `APQ_TEST=MoveFamilyCapture node bin/test.js`.
 *
 * WHEN ONE OF THESE FAILS: the diff is the answer — read the expected against the actual and decide
 * whether the new bytes are an improvement (then re-capture) or a regression (then fix the op). Do
 * NOT re-capture to make it green without reading it; that is the one way this class stops working.
 */
@:nullSafety(Strict)
final class MoveFamilyCaptureTest extends Test {

	/**
	 * `move` of a type into another package, with everything the family's span arithmetic touches in
	 * one fixture: a doc block on the moved declaration, a `using` line the destination lacks (carried),
	 * an importer whose statement is repointed, a destination whose own leading comment must survive the
	 * paste, and — in the source file — a comment ending in a period directly above a real reference plus
	 * a STRING that spells the moved name. Both of the last two feed `namesAnyOf`, which is what decides
	 * whether the source file gets its repair import.
	 */
	public function testMoveOfATypeAcrossPackagesIsByteIdentical(): Void {
		final scope: Array<{ file: String, source: String }> = [
			{
				file: 'p/Tools.hx',
				source: 'package p;\n\nclass Tools {\n\n\tpublic static function twice(v: Int): Int return v * 2;\n\n}\n'
			},
			{
				file: 'p/Mover.hx',
				source: 'package p;\n\nusing p.Tools;\n\n/**\n * The one that moves.\n */\nclass Moved {\n\n\tpublic stat'
					+ 'ic function tag(): Int return 3.twice();\n\n}\n\nclass Keep {\n\n\tpublic function new() {}\n\n'
					+ '\tpublic function use(): Int {\n\t\t// The registry key ends here.\n\t\tMoved.tag();\n\t\treturn'
					+ ' 0;\n\t}\n\n\tpublic function label(): String return "Moved by hand";\n\n}\n'
			},
			{ file: 'q/Host.hx', source: 'package q;\n\n// Host of the moved type.\nclass Host {\n\n\tpublic function new() {}\n\n}\n' },
			{
				file: 'r/User.hx',
				source: 'package r;\n\nimport p.Mover.Moved;\n\nclass User {\n\n\tpublic function new() {}\n\n\tpublic fu'
					+ 'nction go(): Int return Moved.tag();\n\n}\n'
			}
		];
		capture(MoveSymbol.moveType('p/Mover.hx', 8, 7, 'q/Host.hx', scope, plugin(), typeRefShape()), [
			{
				file: 'q/Host.hx',
				source: 'package q;\n\nusing p.Tools;\n\n// Host of the moved type.\nclass Host {\n\n\tpublic function new() {}\n\n}\n\n'
				+ '/**\n * The one that moves.\n */\nclass Moved {\n\n\tpublic static function tag(): Int return 3.twice();\n\n}\n'
			},
			{
				file: 'r/User.hx',
				source: 'package r;\n\nimport q.Host.Moved;\n\nclass User {\n\n\tpublic function new() {}\n\n\tpublic fun'
				+ 'ction go(): Int return Moved.tag();\n\n}\n'
			},
			{
				file: 'p/Mover.hx',
				source: 'package p;\n\nusing p.Tools;\nimport q.Host.Moved;\n\nclass Keep {\n\n\tpublic function new() {}'
				+ '\n\n\tpublic function use(): Int {\n\t\t// The registry key ends here.\n\t\tMoved.tag();\n\t\tre'
				+ 'turn 0;\n\t}\n\n\tpublic function label(): String return "Moved by hand";\n\n}\n'
			}
		]);
	}

	/**
	 * `move-member` of a STATIC member into another package: the doc block travels with the member, the
	 * dependency import is carried into the destination, and the qualified caller is repointed and given
	 * its own import.
	 */
	public function testStaticMemberMoveAcrossPackagesIsByteIdentical(): Void {
		final scope: Array<{ file: String, source: String }> = [
			{ file: 'q/Dep.hx', source: 'package q;\n\nclass Dep {\n\n\tpublic static function n(): Int return 7;\n\n}\n' },
			{
				file: 'p/Src.hx',
				source: 'package p;\n\nimport q.Dep;\n\nclass Src {\n\n\tpublic function new() {}\n\n\t/**\n\t * Doc that'
					+ ' travels.\n\t */\n\tpublic static function util(): Int return Dep.n();\n\n}\n'
			},
			{ file: 's/Dest.hx', source: 'package s;\n\nclass Dest {\n\n\tpublic function new() {}\n\n}\n' },
			{
				file: 'p/User.hx',
				source: 'package p;\n\nclass User {\n\n\tpublic function new() {}\n\n\tpublic function go(): Int return Src.util();\n\n}\n'
			}
		];
		capture(MoveMember.move('p/Src.hx', 'Src', ['util'], 'Dest', null, false, false, scope, plugin(), typeRefShape()), [
			{
				file: 'p/User.hx',
				source: 'package p;\n\nimport s.Dest;\n\nclass User {\n\n\tpublic function new() {}\n\n\tpublic function '
				+ 'go(): Int return Dest.util();\n\n}\n'
			},
			{ file: 'p/Src.hx', source: 'package p;\n\nimport q.Dep;\n\nclass Src {\n\n\tpublic function new() {}\n\n}\n' },
			{
				file: 's/Dest.hx',
				source: 'package s;\n\nimport q.Dep;\n\nclass Dest {\n\n\tpublic function new() {}\n\n\t/**\n\t * Doc tha'
				+ 't travels.\n\t */\n\tpublic static function util(): Int return Dep.n();\n\n}\n'
			}
		]);
	}

	/**
	 * `move-member` of an INSTANCE member out of a type that also declares a `#if`-guarded static field of
	 * the destination's type. The guarded field is the one `membersOf` has to read branch-aware: its
	 * `static` keyword is what keeps it out of the `--via` candidate set, so the routing field is unique
	 * and the remaining bare caller is rewired through it.
	 */
	public function testInstanceMemberMovePastAGuardedSiblingIsByteIdentical(): Void {
		final scope: Array<{ file: String, source: String }> = [
			{ file: 'p/Dst.hx', source: 'package p;\n\nclass Dst {\n\n\tpublic function new() {}\n\n}\n' },
			{
				file: 'p/Src.hx',
				source: 'package p;\n\nclass Src {\n\n\tprivate final _dst: Dst;\n\n\t#if flag\n\tstatic var shared: Dst '
					+ '= null;\n\t#end\n\n\tpublic function new(d: Dst) {\n\t\t_dst = d;\n\t}\n\n\tpublic function keep'
					+ '(): Int return moveMe();\n\n\tpublic function moveMe(): Int return 1;\n\n}\n'
			}
		];
		capture(MoveMember.move('p/Src.hx', 'Src', ['moveMe'], 'Dst', null, false, false, scope, plugin(), typeRefShape()), [
			{
				file: 'p/Src.hx',
				source: 'package p;\n\nclass Src {\n\n\tprivate final _dst: Dst;\n\n\t#if flag\n\tstatic var shared: Dst '
				+ '= null;\n\t#end\n\n\tpublic function new(d: Dst) {\n\t\t_dst = d;\n\t}\n\n\tpublic function keep'
				+ '(): Int return _dst.moveMe();\n\n}\n'
			},
			{
				file: 'p/Dst.hx',
				source: 'package p;\n\nclass Dst {\n\n\tpublic function new() {}\n\n\tpublic function moveMe(): Int return 1;\n\n}\n'
			}
		]);
	}

	/** `pull-up` of a documented instance member: the doc block travels, both files keep their shape. */
	public function testPullUpIsByteIdentical(): Void {
		final scope: Array<{ file: String, source: String }> = [
			{ file: 'p/Base.hx', source: 'package p;\n\nclass Base {\n\n\tpublic function new() {}\n\n}\n' },
			{
				file: 'p/Kid.hx',
				source: 'package p;\n\nclass Kid extends Base {\n\n\tpublic function new() {\n\t\tsuper();\n\t}\n\n\t/**'
					+ '\n\t * Doc that travels up.\n\t */\n\tpublic function shared(): Int return 5;\n\n}\n'
			}
		];
		capture(InheritanceMove.pullUp('p/Kid.hx', 'Kid', 'shared', 'Base', scope, plugin()), [
			{ file: 'p/Kid.hx', source: 'package p;\n\nclass Kid extends Base {\n\n\tpublic function new() {\n\t\tsuper();\n\t}\n\n}\n' },
			{
				file: 'p/Base.hx',
				source: 'package p;\n\nclass Base {\n\n\tpublic function new() {}\n\n\t/**\n\t * Doc that travels up.\n\t'
				+ ' */\n\tpublic function shared(): Int return 5;\n\n}\n'
			}
		]);
	}

	/** `push-down`, the mirror: the documented member lands at the END of the subclass's member list. */
	public function testPushDownIsByteIdentical(): Void {
		final scope: Array<{ file: String, source: String }> = [
			{
				file: 'p/Base.hx',
				source: 'package p;\n\nclass Base {\n\n\tpublic function new() {}\n\n\t/**\n\t * Doc that travels down.\n'
					+ '\t */\n\tpublic function only(): Int return 9;\n\n}\n'
			},
			{ file: 'p/Kid.hx', source: 'package p;\n\nclass Kid extends Base {\n\n\tpublic function new() {\n\t\tsuper();\n\t}\n\n}\n' }
		];
		capture(InheritanceMove.pushDown('p/Base.hx', 'Base', 'only', 'Kid', scope, plugin()), [
			{ file: 'p/Base.hx', source: 'package p;\n\nclass Base {\n\n\tpublic function new() {}\n\n}\n' },
			{
				file: 'p/Kid.hx',
				source: 'package p;\n\nclass Kid extends Base {\n\n\tpublic function new() {\n\t\tsuper();\n\t}\n\n\t/**'
				+ '\n\t * Doc that travels down.\n\t */\n\tpublic function only(): Int return 9;\n\n}\n'
			}
		]);
	}

	/**
	 * `move` of a type whose dependencies are reached through a `#if`-GUARDED import block, into a
	 * destination that already spells the SAME condition — the exact shape 72 destinations of one
	 * 767-module sweep lost, plus the merge that keeps the destination from ending up with two
	 * regions saying the same thing.
	 *
	 * Captured in full because both halves are decisions, not tokens: which statements the carry
	 * brings (`sys.FileSystem`, referenced; `sys.io.File`, referenced through a static receiver) and
	 * WHERE they land (inside the destination's own region, after the statement it already held).
	 */
	public function testAGuardedImportBlockCarriesAndMergesByteIdentically(): Void {
		final scope: Array<{ file: String, source: String }> = [
			{
				file: 'p/Src.hx',
				source: 'package p;\n\n#if (sys || nodejs)\nimport sys.FileSystem;\nimport sys.io.File;\n#end\nimport haxe.io.Path;'
					+ '\n\n/**\n * Reads a file when the target has one.\n */\nclass Src {\n\n\tpublic static function read(p: String): S'
					+ 'tring {\n\t\tfinal n: String = Path.withoutDirectory(p);\n\t\t#if (sys || nodejs)\n\t\tif (FileSystem.exists(p)) r'
					+ 'eturn File.getContent(p);\n\t\t#end\n\t\treturn n;\n\t}\n\n}\n'
			},
			{
				file: 'p/Other.hx',
				source: 'package p;\n\nclass Other {\n\n\tpublic static function go(): String return Src.read(\'x\');\n\n}\n'
			},
			{
				file: 'q/Host.hx',
				source: 'package q;\n\n#if (sys || nodejs)\nimport sys.io.File;\n#end\n\nclass Host {\n\n\tpublic function new() {}\n\n}\n'
			}
		];
		capture(MoveSymbol.moveType('p/Src.hx', 12, 7, 'q/Host.hx', scope, plugin(), typeRefShape()), [
			{
				file: 'q/Host.hx',
				source: 'package q;\n\nimport haxe.io.Path;\n#if (sys || nodejs)\nimport sys.io.File;\nimport sys.FileSystem;\n#end\n\n'
				+ 'class Host {\n\n\tpublic function new() {}\n\n}\n\n/**\n * Reads a file when the target has one.\n */\nclass Src {\n\n'
				+ '\tpublic static function read(p: String): String {\n\t\tfinal n: String = Path.withoutDirectory(p);\n\t\t'
				+ '#if (sys || nodejs)\n\t\tif (FileSystem.exists(p)) return File.getContent(p);\n\t\t#end\n\t\treturn n;\n\t}\n\n}\n'
			},
			{
				file: 'p/Src.hx',
				source: 'package p;\n\n#if (sys || nodejs)\nimport sys.FileSystem;\nimport sys.io.File;\n#end\nimport haxe.io.Path;\n'
			},
			{
				file: 'p/Other.hx',
				source: 'package p;\n\nimport q.Host.Src;\n\nclass Other {\n\n\tpublic static function go(): String return Src.read'
				+ '(\'x\');\n\n}\n'
			}
		]);
	}

	/**
	 * Require `result` to be `Ok` with EXACTLY the given files, each byte-for-byte. The count is
	 * asserted too: a change that stops being emitted at all is the same class of regression as one
	 * whose bytes drift, and only the count catches it.
	 */
	private function capture(result: MoveResult, expected: Array<{ file: String, source: String }>): Void {
		switch result {
			case Ok(changes, _):
				final got: String = [for (c in changes) c.file].join(', ');
				Assert.equals(expected.length, changes.length, 'changed-file count, got $got');
				for (e in expected) {
					final change: Null<MoveChange> = changes.find(c -> c.file == e.file);
					if (change == null)
						Assert.fail('no change for ${e.file}');
					else
						Assert.equals(e.source, change.newSource, 'byte capture for ${e.file}');
				}
			case Err(message):
				Assert.fail('expected Ok, got Err: $message');
		}
	}

	private static function plugin(): HaxeQueryPlugin {
		return new HaxeQueryPlugin();
	}

	private static function typeRefShape(): TypeRefShape {
		return new HaxeQueryPlugin().typeRefShape();
	}

}
