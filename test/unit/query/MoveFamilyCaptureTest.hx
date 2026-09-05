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
 * refactor of the shared lexical seam could hand the destination collision scan
 * (`MoveSymbol.referencedInDest` then, `NameMentionScan.destinationNamesType` since S81) the CURSOR
 * file's comment regions while it was scanning the DESTINATION's text, ship it across 109 files, and
 * leave the whole suite green — the defect was caught by the worker's own forwarding audit, not by a
 * gate.
 *
 * So this class is the gate that was missing: seventeen fixtures driven through the four ops, with
 * the FULL resulting bytes of every changed file pinned. It is deliberately not a set of `contains`
 * assertions — the regression it exists for changed a decision, not a token, and the only assertion
 * that catches "a decision moved" without knowing which decision is the whole file.
 *
 * The fixtures carry, between them, what the family's span arithmetic actually reads: a doc block on
 * the moved declaration, a `using` line to carry, an importer to repoint, a `#if`-guarded member, a
 * cross-package static move, and comments and string literals that spell the moved names. The last
 * four are the comment-policy defects, and their discriminator is the CHANGED-FILE COUNT rather than
 * any byte: a file whose only mention of the moved type sits inside a comment must not appear in the
 * list at all, in either direction (T511 refused the move over one, T512 wrote a real import into
 * one), a destination must never be handed an import of its own module (T518), and a destination
 * whose only mention of a CARRIED dependency is a comment must not veto the carry (T535).
 *
 * S90 added four more for the REPOINT side of the module-static wildcard S88 taught the CARRY
 * side (T568): a bare caller that only that wildcard bound, a rival wildcard that outranks it, a
 * local that shadows it, and a sub-module source type it never bound at all. Three are RED at
 * base; the fourth says in its own doc that it is not, and why it is here anyway.
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
	 * a STRING that spells the moved name. Both of the last two feed `NameMentionScan.sourceNamesAny`,
	 * which is what decides whether the source file gets its repair import.
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
	 * `move` over a scope file whose ONLY mention of the moved type is a fully-qualified path inside a
	 * COMMENT — T511, which the base engine refused at rc 1 with advice ("convert it to a bare Mover,
	 * with an import") that means nothing for prose.
	 *
	 * Captured in full rather than as an `Ok` assertion because the interesting half is what does NOT
	 * appear: `r/Doc.hx` is absent from the change list, and only the count assertion in `capture`
	 * catches a version that starts writing it.
	 */
	public function testACommentOnlyFullyQualifiedMentionLeavesTheMoveByteIdentical(): Void {
		final scope: Array<{ file: String, source: String }> = [
			{ file: 'p/Mover.hx', source: 'package p;\n\nclass Mover {\n\n\tpublic static function tag(): Int return 3;\n\n}\n' },
			{ file: 'q/Host.hx', source: 'package q;\n\nclass Host {\n\n\tpublic function new() {}\n\n}\n' },
			{
				file: 'r/Doc.hx',
				source: 'package r;\n\n/**\n * Once produced by p.Mover, and by nothing since.\n */\nclass Doc {\n\n\tpublic '
					+ 'function new() {}\n\n}\n'
			}
		];
		capture(MoveSymbol.moveType('p/Mover.hx', 3, 7, 'q/Host.hx', scope, plugin(), typeRefShape()), [
			{
				file: 'q/Host.hx',
				source: 'package q;\n\nclass Host {\n\n\tpublic function new() {}\n\n}\n\nclass Mover {\n\n\tpublic static funct'
				+ 'ion tag(): Int return 3;\n\n}\n'
			},
			{ file: 'p/Mover.hx', source: 'package p;\n' }
		]);
	}

	/**
	 * `move` over a same-package sibling whose ONLY mention of the moved type is a bare name inside a
	 * COMMENT — T512, the silent half: the base engine wrote a real `import b.Holder.Thing;` into that
	 * file at rc 0 and said nothing, creating the coupling the move was removing.
	 *
	 * The discriminator is again the change COUNT: two files here, three on the base engine.
	 */
	public function testACommentOnlyBareMentionBuysNoImportByteIdentically(): Void {
		final scope: Array<{ file: String, source: String }> = [
			{ file: 'a/Thing.hx', source: 'package a;\n\nclass Thing {\n\n\tpublic static function go(): Int return 1;\n\n}\n' },
			{ file: 'b/Holder.hx', source: 'package b;\n\nclass Holder {\n\n\tpublic function new() {}\n\n}\n' },
			{
				file: 'a/Reader.hx',
				source: 'package a;\n\n/**\n * Does not use Thing at all; only mentions it in this doc.\n */\nclass Reader {'
					+ '\n\n\tpublic function new() {}\n\n}\n'
			}
		];
		capture(MoveSymbol.moveType('a/Thing.hx', 3, 7, 'b/Holder.hx', scope, plugin(), typeRefShape()), [
			{
				file: 'b/Holder.hx',
				source: 'package b;\n\nclass Holder {\n\n\tpublic function new() {}\n\n}\n\nclass Thing {\n\n\tpublic static fun'
				+ 'ction go(): Int return 1;\n\n}\n'
			},
			{ file: 'a/Thing.hx', source: 'package a;\n' }
		]);
	}

	/**
	 * `move-member` into a destination whose OWN module declares both dependencies the moved body
	 * reaches — its main type and a typedef beside it. The base engine carried the source's statements
	 * verbatim and wrote `import b.Dest;` and `import b.Dest.Payload;` into `b/Dest.hx` itself (T518).
	 *
	 * The whole destination is pinned because the absence of two lines is not the only thing at stake:
	 * an import edit and a member insertion share the same file, and a guard that skips the wrong one
	 * moves the member too.
	 */
	public function testTheDestinationGetsNoImportOfItsOwnModuleByteIdentically(): Void {
		final scope: Array<{ file: String, source: String }> = [
			{
				file: 'a/Src.hx',
				source: 'package a;\n\nimport b.Dest;\nimport b.Dest.Payload;\n\nclass Src {\n\n\tpublic static function label('
					+ 'p: Payload): Int return Dest.existing() + p.n;\n\n}\n'
			},
			{
				file: 'b/Dest.hx',
				source: 'package b;\n\nclass Dest {\n\n\tpublic static function existing(): Int return 1;\n\n}\n\ntypedef Payloa'
					+ 'd = {\n\tvar n: Int;\n}\n'
			}
		];
		capture(MoveMember.move('a/Src.hx', 'Src', ['label'], 'Dest', null, false, false, scope, plugin(), typeRefShape()), [
			{ file: 'a/Src.hx', source: 'package a;\n\nimport b.Dest;\nimport b.Dest.Payload;\n\nclass Src {\n\n}\n' },
			{
				file: 'b/Dest.hx',
				source: 'package b;\n\nclass Dest {\n\n\tpublic static function existing(): Int return 1;\n\n\tpublic static fun'
				+ 'ction label(p: Payload): Int return Dest.existing() + p.n;\n\n}\n\ntypedef Payload = {\n\tvar n: Int;\n}\n'
			}
		]);
	}

	/**
	 * `move` into a destination whose ONLY mention of the carried dependency sits inside a COMMENT —
	 * T535, the third and last of the family's drifted comment policies and the one S80 left standing
	 * because flipping it turns a REFUSAL into a WRITE.
	 *
	 * The base engine exits 1 here with "references \"Dep\" while nothing in the indexed scope binds it
	 * there", advice about aliasing an import that names nothing in the file. Compile-proved on 4.3.7
	 * that there is nothing to protect: carrying `import c.Dep;` past a destination whose only `Dep` is
	 * a doc line left every observable value unchanged, while the same carry past a destination that
	 * really calls an ambient `Dep.x()` changed its answer from 2 to 1 at rc 0 — which is the refusal
	 * this gate keeps, pinned beside this one in `NameMentionScanTest`.
	 *
	 * Captured in full because the carry writes TWO things into the destination — the import line and
	 * the declaration — at two offsets a shared anchor computes, and a count assertion alone would miss
	 * either drifting.
	 */
	public function testACommentOnlyDestinationMentionCarriesTheImportByteIdentically(): Void {
		final scope: Array<{ file: String, source: String }> = [
			{ file: 'q/Dep.hx', source: 'package q;\n\nclass Dep {\n\n\tpublic static function tag(): Int return 1;\n\n}\n' },
			{
				file: 'p/Mover.hx',
				source: 'package p;\n\nimport q.Dep;\n\nclass Mover {\n\n\tpublic static function m(): Int return Dep.tag();\n\n}\n'
			},
			{
				file: 'p/Host.hx',
				source: 'package p;\n\nclass Host {\n\n\tpublic function new() {}\n\n\tpublic function h(): Int {\n\t\t// Nothing '
					+ 'here reaches Dep any more.\n\t\treturn 1;\n\t}\n\n}\n'
			}
		];
		capture(MoveSymbol.moveType('p/Mover.hx', 5, 7, 'p/Host.hx', scope, plugin(), typeRefShape()), [
			{
				file: 'p/Host.hx',
				source: 'package p;\n\nimport q.Dep;\n\nclass Host {\n\n\tpublic function new() {}\n\n\tpublic function h(): Int {'
				+ '\n\t\t// Nothing here reaches Dep any more.\n\t\treturn 1;\n\t}\n\n}\n\nclass Mover {\n\n\tpublic static fun'
				+ 'ction m(): Int return Dep.tag();\n\n}\n'
			},
			{ file: 'p/Mover.hx', source: 'package p;\n\nimport q.Dep;\n' }
		]);
	}

	/**
	 * `move-member` of a body that reaches a name through a MODULE-STATIC wildcard
	 * (`import a.Names.*;`) — the statement is carried, so the destination compiles (T559).
	 *
	 * The base engine writes both files at rc 0 and leaves the destination reading
	 * `Unknown identifier : packOf`; its advisory called the whole class best-effort. Captured in
	 * full because two things are at stake at once and only the bytes hold both: WHICH statement is
	 * carried (the wildcard, not an `import a.Names;` that would bind the type and not the static)
	 * and WHERE the moved body keeps its bare spelling.
	 */
	public function testAModuleStaticWildcardCarriesByteIdentically(): Void {
		final scope: Array<{ file: String, source: String }> = [
			{
				file: 'a/Names.hx',
				source: 'package a;\n\nclass Names {\n\n\tpublic static function packOf(s: String): String return s + \'!\';\n\n}\n'
			},
			{
				file: 'a/Src.hx',
				source: 'package a;\n\nimport a.Names.*;\n\nclass Src {\n\n\tpublic static function label(s: String): String return '
					+ 'packOf(s);\n\n}\n'
			},
			{ file: 'b/Dest.hx', source: 'package b;\n\nclass Dest {\n\n\tpublic static function keep(): Int return 0;\n\n}\n' }
		];
		capture(MoveMember.move('a/Src.hx', 'Src', ['label'], 'Dest', null, false, false, scope, plugin(), typeRefShape()), [
			{ file: 'a/Src.hx', source: 'package a;\n\nimport a.Names.*;\n\nclass Src {\n\n}\n' },
			{
				file: 'b/Dest.hx',
				source: 'package b;\n\nimport a.Names.*;\n\nclass Dest {\n\n\tpublic static function keep(): Int return 0;\n\n\tpu'
				+ 'blic static function label(s: String): String return packOf(s);\n\n}\n'
			}
		]);
	}

	/**
	 * `move-member` into a destination whose WHOLE body — imports, declaration and all — sits inside
	 * one `#if macro`, carrying a `#if`-guarded import into it (T558).
	 *
	 * The shape `src/anyparse/macro` is written in, and the one the merge seat was blind to: the
	 * region's `#end` is the last line of the file, so seating above it wrote the carried import
	 * BELOW the class — `import and using may not appear after a declaration`, at rc 0,
	 * `wrote 2 file(s)`. Reproduced on this tree by moving
	 * `WriterPolicyLowering.buildCaseBodyFitPredicate` into `WriterBraceSymmetryLowering`, where the
	 * base engine's write turned 1 compile error into 11.
	 *
	 * Captured in full because the discriminator is a POSITION, not a token: the same line, one
	 * declaration further up.
	 */
	public function testAGuardedCarryIntoAWholeFileRegionSeatsByteIdentically(): Void {
		final scope: Array<{ file: String, source: String }> = [
			{
				file: 'p/Src.hx',
				source: 'package p;\n\n#if macro\nimport haxe.crypto.Md5;\n\nclass Src {\n\n\tpublic static function util(): String r'
					+ 'eturn Md5.encode(\'x\');\n\n}\n#end\n'
			},
			{
				file: 'q/Host.hx',
				source: 'package q;\n\n#if macro\nimport haxe.io.Path;\n\nclass Host {\n\n\tpublic function new() {}\n\n}\n#end\n'
			}
		];
		capture(MoveMember.move('p/Src.hx', 'Src', ['util'], 'Host', null, false, false, scope, plugin(), typeRefShape()), [
			{ file: 'p/Src.hx', source: 'package p;\n\n#if macro\nimport haxe.crypto.Md5;\n\nclass Src {\n\n}\n#end\n' },
			{
				file: 'q/Host.hx',
				source: 'package q;\n\n#if macro\nimport haxe.io.Path;\nimport haxe.crypto.Md5;\n\nclass Host {\n\n\tpublic function n'
				+ 'ew() {}\n\n\tpublic static function util(): String return Md5.encode(\'x\');\n\n}\n#end\n'
			}
		]);
	}

	/**
	 * `move-member` of a body reading a PRIVATE static sibling into a destination whose type already
	 * grants `@:access` to the source — the member-level copy the base engine writes is dead text
	 * (T560), and S87 landed 10 of them across 3 files in one slice.
	 *
	 * Captured in full rather than as an absence assertion because the meta is not the only thing
	 * the arm decides: the sibling call is qualified back to `Src.hidden()` in the same pass, and a
	 * skip that took the qualification with it would still satisfy a `!contains('@:access')` test.
	 */
	public function testARedundantMemberAccessIsOmittedByteIdentically(): Void {
		final scope: Array<{ file: String, source: String }> = [
			{
				file: 'a/Src.hx',
				source: 'package a;\n\nclass Src {\n\n\tprivate static function hidden(): Int return 4;\n\n\tpublic static function l'
					+ 'abel(): Int return hidden();\n\n}\n'
			},
			{
				file: 'b/Dest.hx',
				source: 'package b;\n\nimport a.Src;\n\n@:access(a.Src)\nclass Dest {\n\n\tpublic static function keep(): Int return '
					+ 'Src.hidden();\n\n}\n'
			}
		];
		capture(MoveMember.move('a/Src.hx', 'Src', ['label'], 'Dest', null, false, false, scope, plugin(), typeRefShape()), [
			{ file: 'a/Src.hx', source: 'package a;\n\nclass Src {\n\n\tprivate static function hidden(): Int return 4;\n\n}\n' },
			{
				file: 'b/Dest.hx',
				source: 'package b;\n\nimport a.Src;\n\n@:access(a.Src)\nclass Dest {\n\n\tpublic static function keep(): Int return S'
				+ 'rc.hidden();\n\n\tpublic static function label(): Int return Src.hidden();\n\n}\n'
			}
		]);
	}

	/**
	 * The T568 headline: a caller that reached the moved STATIC as a BARE name through the source
	 * module's own `import a.Src.*;`. Neither existing scan could see it — `qualifiedReceiverEdits`
	 * needs a receiver and `collectBareCallerHits` only walks the SOURCE file — so the base engine
	 * returned Ok with TWO changed files and left `helper(1)` standing over a type that no longer
	 * declares it (`Unknown identifier : helper`, compile-proved).
	 *
	 * RED at base on both halves: the changed-file count (2, not 3) and, once that is satisfied,
	 * `a/User.hx`'s bytes. `stays(2)` is the discriminator inside the file — it comes through the
	 * SAME wildcard and is not moved, so a repoint that qualified by import rather than by member
	 * would rewrite it too. Killed by the arm `no-wildcard-repoint` (drop the
	 * `collectWildcardBareEdits` call from `move`).
	 */
	public function testABareWildcardCallerIsRepointedByteIdentically(): Void {
		final scope: Array<{ file: String, source: String }> = [
			{
				file: 'a/Src.hx',
				source: 'package a;\n\nclass Src {\n\n\tpublic static function helper(n: Int): Int return'
					+ ' n + 1;\n\n\tpublic static function stays(n: Int): Int return n - 1;\n\n}\n'
			},
			{
				file: 'a/User.hx',
				source: 'package a;\n\nimport a.Src.*;\n\nclass User {\n\n\tpublic function new() {}\n\n'
					+ '\tpublic function go(): Int return helper(1) + stays(2);\n\n}\n'
			},
			{
				file: 'b/Dest.hx',
				source: 'package b;\n\nclass Dest {\n\n\tpublic function new() {}\n\n}\n'
			}
		];
		capture(MoveMember.move('a/Src.hx', 'Src', ['helper'], 'Dest', null, false, false, scope, plugin(), typeRefShape()), [
			{
				file: 'a/Src.hx',
				source: 'package a;\n\nclass Src {\n\n\tpublic static function stays(n: Int): Int return n - 1;\n\n}\n'
			},
			{
				file: 'a/User.hx',
				source: 'package a;\n\nimport a.Src.*;\nimport b.Dest;\n\nclass User {\n\n\tpublic functi'
				+ 'on new() {}\n\n\tpublic function go(): Int return Dest.helper(1) + stays(2);\n\n}\n'
			},
			{
				file: 'b/Dest.hx',
				source: 'package b;\n\nclass Dest {\n\n\tpublic function new() {}\n\n\tpublic static func'
				+ 'tion helper(n: Int): Int return n + 1;\n\n}\n'
			}
		]);
	}

	/**
	 * Two files reach a bare `helper` through a module-static wildcard and only ONE of them meant the
	 * source module. `a/Rival.hx` declares `import c.Other.*;` BELOW `import a.Src.*;`, and Haxe
	 * resolves the LAST wildcard — measured on 4.3.7, two files differing only in that order printed
	 * `B` and `A` — so its call never named `Src` and must survive the move untouched.
	 *
	 * RED at base (2 changed files, not 3, and `a/Wild.hx` absent). The discriminator for the
	 * ordering filter is the COUNT: dropping it repoints `a/Rival.hx` too and the list grows to 4.
	 * Killed by the arm `no-rival-order-filter` (drop the `providers.exists` clause from
	 * `DependencyCarry.wildcardBareReferences`).
	 */
	public function testARivalWildcardKeepsItsBareCallerByteIdentically(): Void {
		final scope: Array<{ file: String, source: String }> = [
			{
				file: 'a/Rival.hx',
				source: 'package a;\n\nimport a.Src.*;\nimport c.Other.*;\n\nclass Rival {\n\n\tpublic fu'
					+ 'nction new() {}\n\n\tpublic function go(): Int return helper(1);\n\n}\n'
			},
			{
				file: 'a/Src.hx',
				source: 'package a;\n\nclass Src {\n\n\tpublic static function helper(n: Int): Int return'
					+ ' n + 1;\n\n\tpublic static function stays(n: Int): Int return n - 1;\n\n}\n'
			},
			{
				file: 'a/Wild.hx',
				source: 'package a;\n\nimport a.Src.*;\n\nclass Wild {\n\n\tpublic function new() {}\n\n'
					+ '\tpublic function go(): Int return helper(1);\n\n}\n'
			},
			{
				file: 'b/Dest.hx',
				source: 'package b;\n\nclass Dest {\n\n\tpublic function new() {}\n\n}\n'
			},
			{
				file: 'c/Other.hx',
				source: 'package c;\n\nclass Other {\n\n\tpublic static function helper(n: Int): Int return n + 2;\n\n}\n'
			}
		];
		capture(MoveMember.move('a/Src.hx', 'Src', ['helper'], 'Dest', null, false, false, scope, plugin(), typeRefShape()), [
			{
				file: 'a/Src.hx',
				source: 'package a;\n\nclass Src {\n\n\tpublic static function stays(n: Int): Int return n - 1;\n\n}\n'
			},
			{
				file: 'a/Wild.hx',
				source: 'package a;\n\nimport a.Src.*;\nimport b.Dest;\n\nclass Wild {\n\n\tpublic functi'
				+ 'on new() {}\n\n\tpublic function go(): Int return Dest.helper(1);\n\n}\n'
			},
			{
				file: 'b/Dest.hx',
				source: 'package b;\n\nclass Dest {\n\n\tpublic function new() {}\n\n\tpublic static func'
				+ 'tion helper(n: Int): Int return n + 1;\n\n}\n'
			}
		]);
	}

	/**
	 * One file, two bare `helper` reads, one binder each. `shadowed()` declares a local of that name,
	 * so its read is resolved by the file itself; `free()` has no such binder and came through the
	 * wildcard. The answer has to be per OCCURRENCE — a per-NAME verdict would have to rewrite both or
	 * neither, and rewriting the local read produces `Dest.helper` where an Int was meant.
	 *
	 * RED at base (2 changed files, not 3). The local read is the discriminator, and it is a BYTE one:
	 * an arm that drops the binding test keeps the count at 3 and only the file's bytes move. Killed
	 * by the arm `no-binding-filter` (drop `h.bindingSpan == null` from
	 * `DependencyCarry.wildcardBareReferences`).
	 */
	public function testALocalShadowKeepsItsBareReadByteIdentically(): Void {
		final scope: Array<{ file: String, source: String }> = [
			{
				file: 'a/Local.hx',
				source: 'package a;\n\nimport a.Src.*;\n\nclass Local {\n\n\tpublic function new() {}\n\n\tpublic function shadowed(): Int '
					+ '{\n\t\tfinal helper: Int = 5;\n\t\treturn helper;\n\t}\n\n\tpublic function free(): Int return helper(1);\n\n}\n'
			},
			{
				file: 'a/Src.hx',
				source: 'package a;\n\nclass Src {\n\n\tpublic static function helper(n: Int): Int return'
					+ ' n + 1;\n\n\tpublic static function stays(n: Int): Int return n - 1;\n\n}\n'
			},
			{
				file: 'b/Dest.hx',
				source: 'package b;\n\nclass Dest {\n\n\tpublic function new() {}\n\n}\n'
			}
		];
		capture(MoveMember.move('a/Src.hx', 'Src', ['helper'], 'Dest', null, false, false, scope, plugin(), typeRefShape()), [
			{
				file: 'a/Local.hx',
				source: 'package a;\n\nimport a.Src.*;\nimport b.Dest;\n\nclass Local {\n\n\tpublic funct'
				+ 'ion new() {}\n\n\tpublic function shadowed(): Int {\n\t\tfinal helper: Int = 5;\n\t\treturn helper;'
				+ '\n\t}\n\n\tpublic function free(): Int return Dest.helper(1);\n\n}\n'
			},
			{
				file: 'a/Src.hx',
				source: 'package a;\n\nclass Src {\n\n\tpublic static function stays(n: Int): Int return n - 1;\n\n}\n'
			},
			{
				file: 'b/Dest.hx',
				source: 'package b;\n\nclass Dest {\n\n\tpublic function new() {}\n\n\tpublic static func'
				+ 'tion helper(n: Int): Int return n + 1;\n\n}\n'
			}
		]);
	}

	/**
	 * A move out of a SUB-MODULE type, which a module-static wildcard never bound: measured on 4.3.7,
	 * `import a.Src.*;` brings in the MAIN type's statics only, so `a/User.hx`'s bare `helper` resolves
	 * through the `z.Free.*` wildcard above it and is none of this move's business — it prints 10, not
	 * 2. `mainStatic()` in the same expression is what the `a.Src.*` statement is actually there for.
	 *
	 * GREEN at base, and says so: the base engine repoints no wildcard caller at all, so it cannot get
	 * this one wrong either. It is here as the arm-discriminator for the binds-it filter — killed by
	 * the arm `no-binds-filter` (drop `src.names.contains(name)` from
	 * `DependencyCarry.wildcardBareReferences`), which repoints `a/User.hx` and takes the count to 3.
	 */
	public function testASubModuleMoveRepointsNoWildcardCallerByteIdentically(): Void {
		final scope: Array<{ file: String, source: String }> = [
			{
				file: 'a/Src.hx',
				source: 'package a;\n\nclass Src {\n\n\tpublic static function mainStatic(): Int return 1'
					+ ';\n\n}\n\nclass Extra {\n\n\tpublic static function helper(n: Int): Int return n + 1;\n\n\tpublic st'
					+ 'atic function stays(n: Int): Int return n - 1;\n\n}\n'
			},
			{
				file: 'a/User.hx',
				source: 'package a;\n\nimport z.Free.*;\nimport a.Src.*;\n\nclass User {\n\n\tpublic func'
					+ 'tion new() {}\n\n\tpublic function go(): Int return helper(1) + mainStatic();\n\n}\n'
			},
			{
				file: 'b/Dest.hx',
				source: 'package b;\n\nclass Dest {\n\n\tpublic function new() {}\n\n}\n'
			},
			{
				file: 'z/Free.hx',
				source: 'package z;\n\nclass Free {\n\n\tpublic static function helper(n: Int): Int return n + 9;\n\n}\n'
			}
		];
		capture(MoveMember.move('a/Src.hx', 'Extra', ['helper'], 'Dest', null, false, false, scope, plugin(), typeRefShape()), [
			{
				file: 'a/Src.hx',
				source: 'package a;\n\nclass Src {\n\n\tpublic static function mainStatic(): Int return 1'
				+ ';\n\n}\n\nclass Extra {\n\n\tpublic static function stays(n: Int): Int return n - 1;\n\n}\n'
			},
			{
				file: 'b/Dest.hx',
				source: 'package b;\n\nclass Dest {\n\n\tpublic function new() {}\n\n\tpublic static func'
				+ 'tion helper(n: Int): Int return n + 1;\n\n}\n'
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
