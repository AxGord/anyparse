package unit;

import utest.Assert;
import anyparse.check.Check.Violation;
import anyparse.check.Naming;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;
import anyparse.query.SymbolIndex;
import anyparse.check.Check.CrossFileEdits;
import anyparse.query.CachingGrammarPlugin;

/**
 * The `naming` autofix crossing FILE boundaries: a private field renamed in its
 * declaring file must also be rewritten wherever a subtype in another file reads or
 * writes it through a typed receiver.
 *
 * Covered here: which receivers resolve to the owner (a subtype, a `final` or
 * `abstract` subtype, an unrelated same-named sibling type), what blocks the whole
 * rename (an ambiguous subtype or receiver name, a typedef-aliased receiver, a
 * conditional-compilation branch, a reflection string, an unresolvable receiver, a
 * real binding of the target name), what is left alone (a comment mention, a
 * different typed receiver), and the ATOMICITY of the staged multi-file edit —
 * every file commits or none does.
 */
class NamingCheckCrossFileFixTest extends NamingCheckTestBase {

	/** The owner of the ambiguity fixtures: a non-confined private `size` read through `this.`. */
	private static final AMBIGUITY_OWNER_SRC: String =
		'package pkg;\nclass C {\n\tprivate var size:Int;\n\tpublic function f() { return this.size; }\n}';

	/** The claim fixture's base: `A` declares a private `CAPS`, which corrects to `_caps`. */
	private static final CLAIM_BASE_SRC: String =
		'package pkg;\nclass A {\n\tprivate var CAPS:Int = 1;\n\tpublic function a():Int { return CAPS; }\n}';

	/** The claim fixture's subclass: `B extends A` declares a private `Caps`, correcting to the SAME `_caps`. */
	private static final CLAIM_SUB_SRC: String =
		'package pkg;\nclass B extends A {\n\tprivate var Caps:Int = 2;\n\tpublic function b():Int { return Caps; }\n}';

	/**
	 * HALF-APPLIED HAZARD: the subtype's simple name is AMBIGUOUS in the scope (a secondary type
	 * elsewhere in the set shares it), so the positive `isSubtype` proof MISSES - it needs a unique
	 * decl at every closure step. The occurrence must then stay UNCOVERED so the completeness gate
	 * blocks; attributing it to the "different owner" ignore bucket instead drops it silently and the
	 * rename commits the declaring file ALONE, leaving the subtype reading a name that no longer
	 * exists (`Unknown identifier`). Observed live on a 798-file tree where the subtype's simple name
	 * collided with a secondary type in another module.
	 */
	public inline function testCrossFileFixBlocksWhenSubtypeNameIsAmbiguous(): Void {
		// A bare inherited read in the subtype, attributed by its ENCLOSING class.
		assertAmbiguousSubtypeBlocks('package pkg;\nclass D extends C {\n\tpublic function g() { return size; }\n}');
	}

	/**
	 * The typed-receiver twin of the ambiguous-subtype hazard: `d.size` where `d:D` and `D`'s simple
	 * name is ambiguous. `isSubtype('D', 'C')` misses, and the old `else` arm swept EVERY resolvable
	 * non-subtype receiver into the ignore bucket, so the access was dropped and the rename
	 * half-applied. A receiver type that is not PROVABLY unrelated must block instead.
	 */
	public inline function testCrossFileFixBlocksOnAmbiguousReceiverType(): Void {
		assertAmbiguousSubtypeBlocks('package pkg;\nclass D extends C {\n\tpublic function g(d:D) { return d.size; }\n}');
	}

	/**
	 * A receiver typed to a SUBTYPE of the owner reaches the same declaration and is renamed too. The
	 * subtype's mere existence makes the private field non-confined, so this shape only ever reaches
	 * the CROSS-FILE path (`isPrivateMemberConfined`) — the single-file `fix` refuses it earlier.
	 */
	public function testCrossFileFixRenamesSubtypeReceiverAccess(): Void {
		final cSrc: String =
			'package pkg;\nclass C {\n\tprivate var bottom:Int = 0;\n\tpublic function f(d:CSub):Int { return bottom + d.bottom; }\n}';
		final dSrc: String = 'package pkg;\nclass CSub extends C {\n\tpublic function new() {}\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: cSrc },
			{ file: 'pkg/CSub.hx', source: dSrc }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		final renames: Array<Array<CrossFileEdits>> = check.crossFileFix(files, vs, new HaxeQueryPlugin(), index);
		Assert.equals(1, renames.length);
		assertRenameSlice(renames[0], 'pkg/C.hx', cSrc, 'return _bottom + d._bottom', 'd.bottom');
	}

	public function testCrossFileFixRenamesSubtypeField(): Void {
		// A non-confined private field read by a subclass renames in BOTH the declaring file and
		// the subclass as one atomic cross-file rename — the single-file `fix` leaves it report-only.
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n\tpublic function f() { return this.shape; }\n}';
		final dSrc: String = 'package pkg;\nclass D extends C {\n\tpublic function g() { return shape; }\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: cSrc }, { file: 'pkg/D.hx', source: dSrc }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		// The single-file fix still refuses the non-confined field.
		Assert.equals(0, check.fix(cSrc, vs.filter(v -> v.file == 'pkg/C.hx'), new HaxeQueryPlugin(), index).length);
		final renames: Array<Array<CrossFileEdits>> = check.crossFileFix(files, vs, new HaxeQueryPlugin(), index);
		Assert.equals(1, renames.length);
		final rename: Array<CrossFileEdits> = renames[0];
		Assert.equals(2, rename.length);
		assertRenameSlice(rename, 'pkg/C.hx', cSrc, '_shape', 'var shape');
		assertRenameSlice(rename, 'pkg/D.hx', dSrc, '_shape', 'return shape');
	}

	public function testCrossFileFixBlocksOnSubtypeConditional(): Void {
		// A `#if...#end` occurrence of the field name in a subtype is platform-conditional and
		// invisible to the resolver — the whole cross-file rename is refused (report-only).
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n\tpublic function f() { return this.shape; }\n}';
		final dSrc: String = 'package pkg;\nclass D extends C {\n\tpublic function g():Int {\n\t\t#if flag\n\t\treturn shape;\n\t\t#else\n'
			+ '\t\treturn 0;\n\t\t#end\n\t}\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: cSrc }, { file: 'pkg/D.hx', source: dSrc }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(0, check.crossFileFix(files, vs, new HaxeQueryPlugin(), index).length);
	}

	public function testCrossFileFixBlocksOnReflectionString(): Void {
		// A subtype naming the field as a reflection string (`Reflect.field(this, "shape")`) would
		// break silently after a rename — the string occurrence turns the whole rename report-only.
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n\tpublic function f() { return this.shape; }\n}';
		final dSrc: String = 'package pkg;\nclass D extends C {\n\tpublic function g():Dynamic { return Reflect.field(this, "shape"); }\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: cSrc }, { file: 'pkg/D.hx', source: dSrc }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(0, check.crossFileFix(files, vs, new HaxeQueryPlugin(), index).length);
	}

	public function testCrossFileFixIgnoresDifferentTypedReceiver(): Void {
		// A subtype method accessing a SAME-NAMED field on a DIFFERENT-typed receiver (`o.size` where
		// `o` is `Other`, not the owner `C` nor a subtype of it) provably binds to a different owner, so
		// it is IGNORED — neither renamed nor a blocker. The cross-file rename proceeds, rewriting only
		// the declaring file; the subtype's `o.size` is left untouched.
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var size:Int;\n\tpublic function f() { return this.size; }\n}';
		final otherSrc: String = 'package pkg;\nclass Other {\n\tpublic var size:Int;\n}';
		final dSrc: String = 'package pkg;\nclass D extends C {\n\tpublic function g(o:Other) { return o.size; }\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: cSrc },
			{ file: 'pkg/Other.hx', source: otherSrc },
			{ file: 'pkg/D.hx', source: dSrc }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		final renames: Array<Array<CrossFileEdits>> = check.crossFileFix(files, vs, new HaxeQueryPlugin(), index);
		Assert.equals(1, renames.length);
		final rename: Array<CrossFileEdits> = renames[0];
		Assert.equals(1, rename.length);
		assertRenameSlice(rename, 'pkg/C.hx', cSrc, '_size', 'var size');
	}

	public function testCrossFileFixRenamesSubtypeTypedReceiver(): Void {
		// A subtype method accessing the inherited field through a receiver typed as the OWNER (or a
		// subtype of it) — here `d:D`, a subtype of `C` — DOES bind to the inherited field, so the
		// cross-file rename rewrites the declaring file AND the `d.size` access.
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var size:Int;\n\tpublic function f() { return this.size; }\n}';
		final dSrc: String = 'package pkg;\nclass D extends C {\n\tpublic function g(d:D) { return d.size; }\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: cSrc }, { file: 'pkg/D.hx', source: dSrc }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		final renames: Array<Array<CrossFileEdits>> = check.crossFileFix(files, vs, new HaxeQueryPlugin(), index);
		Assert.equals(1, renames.length);
		final rename: Array<CrossFileEdits> = renames[0];
		Assert.equals(2, rename.length);
		assertRenameSlice(rename, 'pkg/C.hx', cSrc, '_size', 'var size');
		assertRenameSlice(rename, 'pkg/D.hx', dSrc, 'd._size', 'd.size');
	}

	public function testStageCrossFileRenameRevertsAllOnCanonicalizationFailure(): Void {
		// Any one file's canonicalization failure reverts the WHOLE multi-file edit set.
		final slices: Array<{ file: String, edits: Array<{ span: Span, text: String }> }> = [
			{ file: 'A.hx', edits: [{ span: new Span(0, 1), text: 'X' }] },
			{ file: 'B.hx', edits: [{ span: new Span(0, 1), text: 'Y' }] }
		];
		final sources: Map<String, String> = ['A.hx' => 'a', 'B.hx' => 'b'];
		final staged: Null<Array<{ file: String, source: String }>> = RefactorSupport.stageCrossFileRename(
			slices, file -> sources[file], (file, source, edits) -> file == 'B.hx' ? EditResult.Err('boom') : EditResult.Ok('X')
		);
		Assert.isNull(staged);
	}

	public function testStageCrossFileRenameCommitsAllOnSuccess(): Void {
		// When every file canonicalizes to a changed result, all rewrites are returned together.
		final slices: Array<{ file: String, edits: Array<{ span: Span, text: String }> }> = [
			{ file: 'A.hx', edits: [{ span: new Span(0, 1), text: 'X' }] },
			{ file: 'B.hx', edits: [{ span: new Span(0, 1), text: 'Y' }] }
		];
		final sources: Map<String, String> = ['A.hx' => 'a', 'B.hx' => 'b'];
		final staged: Null<Array<{ file: String, source: String }>> = RefactorSupport.stageCrossFileRename(
			slices, file -> sources[file], (file, source, edits) -> EditResult.Ok(file == 'A.hx' ? 'X' : 'Y')
		);
		Assert.notNull(staged);
		if (staged != null) Assert.equals(2, staged.length);
	}

	public function testCrossFileFixRenamesUnrelatedSameNamedFieldsIndependently(): Void {
		// Two UNRELATED classes A and B each declare a private `size` and are each subclassed, so both
		// are non-confined cross-file candidates. Each subtype reaches the OTHER class's same-named field
		// through a differently-typed receiver (`b.size` in A's subtype, `a.size` in B's) — a provably
		// DIFFERENT owner that is IGNORED, so neither blocks the other. Both renames proceed in one run.
		final aSrc: String = 'package pkg;\nclass A {\n\tprivate var size:Int;\n\tpublic function f() { return this.size; }\n}';
		final subASrc: String = 'package pkg;\nclass SubA extends A {\n\tpublic function g(b:B) { return b.size; }\n}';
		final bSrc: String = 'package pkg;\nclass B {\n\tprivate var size:Int;\n\tpublic function f() { return this.size; }\n}';
		final subBSrc: String = 'package pkg;\nclass SubB extends B {\n\tpublic function g(a:A) { return a.size; }\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/A.hx', source: aSrc },
			{ file: 'pkg/SubA.hx', source: subASrc },
			{ file: 'pkg/B.hx', source: bSrc },
			{ file: 'pkg/SubB.hx', source: subBSrc }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		final renames: Array<Array<CrossFileEdits>> = check.crossFileFix(files, vs, new HaxeQueryPlugin(), index);
		Assert.equals(2, renames.length);
		var renamedA: Bool = false;
		var renamedB: Bool = false;
		for (rename in renames) {
			Assert.equals(1, rename.length);
			if (rename[0].file == 'pkg/A.hx') {
				renamedA = true;
				assertRenameSlice(rename, 'pkg/A.hx', aSrc, '_size', 'var size');
			}
			if (rename[0].file != 'pkg/B.hx') continue;
			renamedB = true;
			assertRenameSlice(rename, 'pkg/B.hx', bSrc, '_size', 'var size');
		}
		Assert.isTrue(renamedA);
		Assert.isTrue(renamedB);
	}

	public function testCrossFileFixBlocksOnUnresolvableReceiver(): Void {
		// A subtype method reaching `.size` through a receiver whose type cannot be resolved (an untyped
		// parameter) is an occurrence whose owner cannot be proven — it is left uncovered, so the
		// completeness gate blocks the whole cross-file rename (fail-closed, unchanged behaviour).
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var size:Int;\n\tpublic function f() { return this.size; }\n}';
		final dSrc: String = 'package pkg;\nclass D extends C {\n\tpublic function g(o) { return o.size; }\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: cSrc }, { file: 'pkg/D.hx', source: dSrc }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(0, check.crossFileFix(files, vs, new HaxeQueryPlugin(), index).length);
	}

	/**
	 * The subtype lives as a SECONDARY type in a module whose PRIMARY type belongs to an
	 * UNRELATED hierarchy that already uses the target name (`_w`, inherited from its own
	 * `Base`). That occurrence cannot clash with the owner's renamed field - different class,
	 * different inherited member - so it must NOT block the cross-file rename. The old guard
	 * was a blunt WHOLE-FILE textual scan and refused the whole rename.
	 */
	public function testCrossFileFixIgnoresTargetNameInUnrelatedSiblingType(): Void {
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var __w:Int;\n\tpublic function f() { return this.__w; }\n}';
		final baseSrc: String = 'package pkg;\nclass Base {\n\tprivate var _w:Int;\n}';
		final hostSrc: String = 'package pkg;\nclass Host extends Base {\n\tpublic function h() { return _w; }\n}\n\n'
			+ 'class Sub extends C {\n\tpublic function g() { return __w; }\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: cSrc },
			{ file: 'pkg/Base.hx', source: baseSrc },
			{ file: 'pkg/Host.hx', source: hostSrc }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		final renames: Array<Array<CrossFileEdits>> = check.crossFileFix(files, vs, new HaxeQueryPlugin(), index);
		Assert.equals(1, renames.length);
		final rename: Array<CrossFileEdits> = renames[0];
		Assert.equals(2, rename.length);
		assertRenameSlice(rename, 'pkg/C.hx', cSrc, '_w', 'var __w');
		assertRenameSlice(rename, 'pkg/Host.hx', hostSrc, '_w', 'return __w');
	}

	/**
	 * The mirror: the target name is already declared INSIDE the subtype itself, where the
	 * renamed inherited field would hit Haxe's "Redefinition of variable in subclass" - a real
	 * collision, so the rename stays report-only even under the scope-aware guard.
	 */
	public function testCrossFileFixBlocksOnTargetNameInsideSubtype(): Void {
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var __w:Int;\n\tpublic function f() { return this.__w; }\n}';
		final dSrc: String = 'package pkg;\nclass D extends C {\n\tprivate var _w:Int;\n\tpublic function g() { return __w + _w; }\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: cSrc }, { file: 'pkg/D.hx', source: dSrc }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(0, check.crossFileFix(files, vs, new HaxeQueryPlugin(), index).length);
	}

	/**
	 * The POSITIVE control for both blockers: the identical fixture WITHOUT the ambiguity-creating
	 * twin module renames completely, across both files. It pins the AMBIGUITY as the reason the two
	 * tests above see zero renames — without it they would stay green if anything upstream (the
	 * policy, `crossFileCandidate`, the rename-safety gate) stopped producing the candidate at all.
	 */
	public function testCrossFileFixRenamesUnambiguousSubtypeControl(): Void {
		final dSrc: String = 'package pkg;\nclass D extends C {\n\tpublic function g() { return size; }\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: AMBIGUITY_OWNER_SRC },
			{ file: 'pkg/D.hx', source: dSrc }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		final renames: Array<Array<CrossFileEdits>> = check.crossFileFix(files, vs, new HaxeQueryPlugin(), index);
		Assert.equals(1, renames.length);
		assertNotHalfApplied(renames, 'pkg/C.hx', 'pkg/D.hx');
		assertRenameSlice(renames[0], 'pkg/C.hx', AMBIGUITY_OWNER_SRC, '_size', 'var size');
		assertRenameSlice(renames[0], 'pkg/D.hx', dSrc, '_size', 'return size');
	}

	/**
	 * An ALIASING decl reaches its target through a link no `extends` / `implements` clause records,
	 * so its indexed `supertypes` is EMPTY — and an empty closure "excludes" everything. Here the
	 * subtype reads the inherited field through a receiver typed `Alias`, a `typedef` for the owner
	 * itself: reading that vacuous closure as a proof of unrelatedness filed a genuine owner-bound
	 * access under "different owner" and half-applied the rename. The proof must refuse an aliasing
	 * decl outright, leaving the access uncovered so the completeness gate blocks.
	 */
	public function testCrossFileFixBlocksOnTypedefAliasedReceiver(): Void {
		final aliasSrc: String = 'package pkg;\ntypedef Alias = C;';
		final dSrc: String = 'package pkg;\nclass D extends C {\n\tpublic function g(a:Alias) { return a.size; }\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: AMBIGUITY_OWNER_SRC },
			{ file: 'pkg/Alias.hx', source: aliasSrc },
			{ file: 'pkg/D.hx', source: dSrc }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		final renames: Array<Array<CrossFileEdits>> = check.crossFileFix(files, vs, new HaxeQueryPlugin(), index);
		assertNotHalfApplied(renames, 'pkg/C.hx', 'pkg/D.hx');
		Assert.equals(0, renames.length);
	}

	/**
	 * The collision-scan face of the same non-proof. The subtype already declares the TARGET name
	 * (`_size`), which is exactly the clash the target-name scan exists to catch — but that scan
	 * subtracts the spans of types deemed "unrelated" to the owner, and deeming them so from a false
	 * `isSubtype` excluded the REAL subtype's whole body under an ambiguous simple name. The clash
	 * went unseen and the rename emitted `Redefinition of variable _size in subclass` (verified).
	 * Unlike the ignore-bucket arms, nothing downstream re-checks what this set drops.
	 */
	public function testCrossFileFixBlocksOnTargetNameInAmbiguouslyNamedSubtype(): Void {
		final dSrc: String = 'package pkg;\nclass D extends C {\n\tprivate var _size:Int;\n\tpublic function g() { return _size; }\n}';
		final twinSrc: String = 'package pkg;\nclass Twin {}\n\nclass D {\n\tpublic var other:Int;\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: AMBIGUITY_OWNER_SRC },
			{ file: 'pkg/D.hx', source: dSrc },
			{ file: 'pkg/Twin.hx', source: twinSrc }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		final renames: Array<Array<CrossFileEdits>> = check.crossFileFix(files, vs, new HaxeQueryPlugin(), index);
		assertNotHalfApplied(renames, 'pkg/C.hx', 'pkg/D.hx');
		Assert.equals(0, renames.length);
	}

	public function testCrossFileFixRenamesFinalAndAbstractSubtypeField(): Void {
		// The subtype reads live inside a `final class` (ClassForm) and an `abstract class`
		// (AbstractClassDecl) — receiver attribution must recognise both class shapes, else
		// the completeness gate fails closed and the cross-file rename silently no-ops.
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n\tpublic function f() { return this.shape; }\n}';
		final dSrc: String = 'package pkg;\nfinal class D extends C {\n\tpublic function g() { return shape; }\n}';
		final eSrc: String = 'package pkg;\nabstract class E extends C {\n\tpublic function h() { return shape; }\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: cSrc },
			{ file: 'pkg/D.hx', source: dSrc },
			{ file: 'pkg/E.hx', source: eSrc }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		final renames: Array<Array<CrossFileEdits>> = check.crossFileFix(files, vs, new HaxeQueryPlugin(), index);
		Assert.equals(1, renames.length);
		final rename: Array<CrossFileEdits> = renames[0];
		Assert.equals(3, rename.length);
		assertRenameSlice(rename, 'pkg/C.hx', cSrc, '_shape', 'var shape');
		assertRenameSlice(rename, 'pkg/D.hx', dSrc, '_shape', 'return shape');
		assertRenameSlice(rename, 'pkg/E.hx', eSrc, '_shape', 'return shape');
	}

	/**
	 * A COMMENT in an affected file that spells the rename TARGET is not a binding of
	 * it, so it must not refuse the cross-file rename. The collision gate asked a raw
	 * word-boundary text scan, which counted the comment and turned the whole rename
	 * report-only; it now asks `RefactorSupport.nameBoundInRange`.
	 */
	public function testCrossFileFixIgnoresTargetNameInComment(): Void {
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n\tpublic function f() { return this.shape; }\n}';
		final dSrc: String =
			'package pkg;\nclass D extends C {\n\t// _shape is inherited from C\n\tpublic function g() { return shape; }\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: cSrc }, { file: 'pkg/D.hx', source: dSrc }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		final renames: Array<Array<CrossFileEdits>> = check.crossFileFix(files, vs, new HaxeQueryPlugin(), index);
		Assert.equals(1, renames.length);
		assertRenameSlice(renames[0], 'pkg/D.hx', dSrc, '_shape', 'return shape');
	}

	/**
	 * GUARD: a REAL binding of the target name in an affected file still refuses the
	 * whole cross-file rename.
	 */
	public function testCrossFileFixBlocksOnRealTargetBinding(): Void {
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate var shape:Int;\n\tpublic function f() { return this.shape; }\n}';
		final dSrc: String =
			'package pkg;\nclass D extends C {\n\tprivate var _shape:Int;\n\tpublic function g() { return shape + _shape; }\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/C.hx', source: cSrc }, { file: 'pkg/D.hx', source: dSrc }];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(0, check.crossFileFix(files, vs, new HaxeQueryPlugin(), index).length);
	}

	/**
	 * A PUBLIC field reached through a typed receiver in another file renames in both. The
	 * single-file `fix` refuses every public declaration (`isRenameSafe`), so this shape only ever
	 * reaches the CROSS-FILE path — and the consumer file joins the affected set by MENTIONING the
	 * old name, not by being a subtype (`Consumer` is unrelated to `Holder`).
	 */
	public function testCrossFileFixRenamesPublicFieldThroughTypedReceiver(): Void {
		final hSrc: String = 'package pkg;\nclass Holder {\n\tpublic final __size:Int;\n\tpublic function new(n:Int) { __size = n; }\n}';
		final cSrc: String = 'package pkg;\nclass Consumer {\n\tpublic function read(h:Holder):Int { return h.__size + 1; }\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/Holder.hx', source: hSrc },
			{ file: 'pkg/Consumer.hx', source: cSrc }
		];
		final rename: Array<CrossFileEdits> = crossFileRename(files);
		assertRenameSlice(rename, 'pkg/Holder.hx', hSrc, 'public final size:Int', '__size');
		// The renamed access next to its untouched neighbour: only the rename can produce this.
		assertRenameSlice(rename, 'pkg/Consumer.hx', cSrc, 'return h.size + 1', '__size');
	}

	/**
	 * THE REPORTED CASE. `__position` renamed to `position` collides with the constructor PARAMETER
	 * of that name, which would make the write the self-assignment `position = position` — valid,
	 * silently wrong code no re-parse or typecheck rejects. The declaring file's collision is
	 * REPAIRED by qualifying through `this.` rather than refusing the whole rename.
	 */
	public function testCrossFileFixQualifiesPublicFieldCapturedByCtorParam(): Void {
		final src: String =
			'package pkg;\nclass Holder {\n\tpublic final __size:Int;\n\tpublic function new(size:Int) { __size = size; }\n}';
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/Holder.hx', source: src }];
		// One string spanning both halves: the declaration renamed AND the write qualified.
		assertRenameSlice(crossFileRename(files), 'pkg/Holder.hx', src, 'this.size = size', '__size');
	}

	/**
	 * A NON-confined PRIVATE method — one a subtype in another file inherits and calls — renames
	 * across both files. Only a subtype can reach it, so the single-file `fix` refuses it as
	 * unconfined and this is its only path; the bare inherited call is attributed by its enclosing
	 * class and renamed along.
	 */
	public function testCrossFileFixRenamesNonConfinedPrivateMethod(): Void {
		final cSrc: String = 'package pkg;\nclass C {\n\tprivate function __helper():Int { return 1; }\n\t'
			+ 'public function f():Int { return __helper(); }\n}';
		final dSrc: String = 'package pkg;\nclass D extends C {\n\tpublic function g():Int { return __helper() + 1; }\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: cSrc },
			{ file: 'pkg/D.hx', source: dSrc }
		];
		final rename: Array<CrossFileEdits> = crossFileRename(files);
		assertRenameSlice(rename, 'pkg/C.hx', cSrc, 'private function helper():Int', '__helper');
		// The renamed inherited call next to its untouched arithmetic: only the rename produces this.
		assertRenameSlice(rename, 'pkg/D.hx', dSrc, 'return helper() + 1', '__helper');
	}

	/** A PUBLIC method renames across files too, through a receiver typed to its owner. */
	public function testCrossFileFixRenamesPublicMethod(): Void {
		final bSrc: String = 'package pkg;\nclass Base {\n\tpublic function __draw():Int { return 1; }\n}';
		final cSrc: String = 'package pkg;\nclass Caller {\n\tpublic function go(b:Base):Int { return b.__draw(); }\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/Base.hx', source: bSrc },
			{ file: 'pkg/Caller.hx', source: cSrc }
		];
		final rename: Array<CrossFileEdits> = crossFileRename(files);
		assertRenameSlice(rename, 'pkg/Base.hx', bSrc, 'public function draw():Int', '__draw');
		assertRenameSlice(rename, 'pkg/Caller.hx', cSrc, 'return b.draw();', '__draw');
	}

	/**
	 * A method a subtype OVERRIDES renames as a FAMILY, not as one declaration: base and override move
	 * in ONE edit set. Renaming either half alone leaves `override function __draw` overriding nothing,
	 * which does not compile.
	 *
	 * Both declarations sit in ONE file on purpose: that is the spelling the completeness gate does NOT
	 * catch. Across files the subtype's declaration is an occurrence no receiver attributes and the
	 * rename bails there; in the same file it used to be dropped silently, so this fixture renamed the
	 * base and emitted code that no longer compiled.
	 */
	public function testCrossFileFixRenamesOverrideFamilyInOneFile(): Void {
		final src: String = 'package pkg;\nclass OBase {\n\tpublic function __draw():Int { return 1; }\n}\n\n'
			+ 'class OSub extends OBase {\n\toverride public function __draw():Int { return 2; }\n}';
		final rename: Array<CrossFileEdits> = crossFileRename([{ file: 'pkg/OBase.hx', source: src }]);
		// Base and override renamed in ONE string - neither declaration alone can satisfy this.
		assertRenameSlice(
			rename, 'pkg/OBase.hx', src,
			'public function draw():Int { return 1; }\n}\n\nclass OSub extends OBase {\n\toverride public function draw():Int', '__draw'
		);
	}

	/**
	 * The cross-FILE spelling of the same family: the subtype lives in its own module and also CALLS
	 * the member it overrides. The override's declaration and that call both move with the base.
	 */
	public function testCrossFileFixRenamesOverrideFamilyAcrossFiles(): Void {
		final baseSrc: String = 'package pkg;\nclass FBase {\n\tpublic function __draw():Int { return 1; }\n}';
		final subSrc: String = 'package pkg;\nclass FSub extends FBase {\n\toverride public function __draw():Int { return 2; }\n'
			+ '\tpublic function again():Int { return __draw() + 1; }\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/FBase.hx', source: baseSrc },
			{ file: 'pkg/FSub.hx', source: subSrc }
		];
		final rename: Array<CrossFileEdits> = crossFileRename(files);
		assertRenameSlice(rename, 'pkg/FBase.hx', baseSrc, 'public function draw():Int { return 1; }', '__draw');
		// The renamed OVERRIDE next to the renamed call it makes - one string neither half produces alone.
		assertRenameSlice(
			rename, 'pkg/FSub.hx', subSrc,
			'override public function draw():Int { return 2; }\n\tpublic function again():Int { return draw() + 1; }', '__draw'
		);
	}

	/**
	 * A same-named declaration whose relation to the owner cannot be PROVEN must not be renamed around.
	 * `Foreign` extends a type this scope does not declare, so it is neither proven family nor proven
	 * unrelated.
	 *
	 * Measured, so the doc does not overclaim: this fixture is refused by the COMPLETENESS gate as well —
	 * the public member's affected set includes every file mentioning the name, and `Foreign`'s own
	 * declaration is an occurrence no receiver attributes. It guards that the family feature did not turn
	 * this case into a rename; the unprovable-family refusal ITSELF is discriminated by
	 * `SymbolIndexSliceTest.testOverrideFamilyOfRefusesUnprovable` and
	 * `CrossRenameMemberSliceTest.testUnprovableFamilyRefused`.
	 */
	public function testCrossFileFixRefusesUnprovableOverrideFamily(): Void {
		final baseSrc: String = 'package pkg;\nclass UBase {\n\tpublic function __draw():Int { return 1; }\n}';
		final foreignSrc: String = 'package pkg;\nclass Foreign extends Unknown {\n\tpublic function __draw():Int { return 2; }\n}';
		assertCrossFileRefused([
			{ file: 'pkg/UBase.hx', source: baseSrc },
			{ file: 'pkg/Foreign.hx', source: foreignSrc }
		]);
	}

	/**
	 * An override living OUTSIDE the edited scope refuses the base's rename. The family is resolved
	 * against the RESOLUTION index (report UNION library), which sees the subtype; the edit set can
	 * only reach report files, so renaming the base here would emit a library override of a name that
	 * no longer exists. The only fixture where the two indices genuinely disagree.
	 */
	public function testCrossFileFixRefusesOverrideOutsideTheEditedScope(): Void {
		final baseSrc: String = 'package pkg;\nclass SBase {\n\tpublic function __draw():Int { return 1; }\n}';
		final libSrc: String =
			'package ext;\nimport pkg.SBase;\nclass SSub extends SBase {\n\toverride public function __draw():Int { return 2; }\n}';
		final report: Array<{ file: String, source: String }> = [{ file: 'pkg/SBase.hx', source: baseSrc }];
		final lib: Array<{ file: String, source: String }> = [{ file: 'ext/SSub.hx', source: libSrc }];
		final scoped: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		scoped.setResolutionScope({ declared: true, sources: () -> {report: report, library: new LibrarySources(lib) } });
		final reportIndex: SymbolIndex = SymbolIndex.build(report, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(report, scoped);
		// The finding MUST exist, or the zero below would prove nothing.
		Assert.equals(1, vs.length);
		Assert.equals(0, check.crossFileFix(report, vs, scoped, reportIndex).length);
	}

	/**
	 * An `implicitlyReachable` member — one carrying metadata a macro / `@:keep` / framework can
	 * reach by NAME — has references no identifier-level completeness proof sees.
	 */
	public function testCrossFileFixRefusesImplicitlyReachablePublicMethod(): Void {
		final src: String = 'package pkg;\nclass K {\n\t@:keep public function __draw():Int { return 1; }\n}';
		assertCrossFileRefused([{ file: 'pkg/K.hx', source: src }]);
	}

	/**
	 * A reflection call naming the member in ANOTHER file would break silently after a rename. No
	 * dedicated guard handles it: a public member's affected set is every scope file MENTIONING the name,
	 * so the reflection string's file is scanned and its name-shaped string literal refuses the whole
	 * rename through the ordinary occurrence classification. This asserts that the public path inherits
	 * that refusal — verified by removing a duplicate AST-projected guard and finding this shape, and its
	 * same-file twin, still refused.
	 */
	public function testCrossFileFixRefusesPublicFieldNamedByStringLiteral(): Void {
		final hSrc: String = 'package pkg;\nclass Holder {\n\tpublic final __size:Int;\n\tpublic function new(n:Int) { __size = n; }\n}';
		final rSrc: String =
			'package pkg;\nclass RUser {\n\tpublic function get(h:Holder):Dynamic { return Reflect.field(h, \'__size\'); }\n}';
		assertCrossFileRefused([{ file: 'pkg/Holder.hx', source: hSrc }, { file: 'pkg/RUser.hx', source: rSrc }]);
	}

	/**
	 * The owner's own HIERARCHY stays in a public member's affected set even when a subtype file
	 * never MENTIONS the old name: renaming `__size` to `size` would turn the subtype's own `size`
	 * into Haxe's "Redefinition of variable in subclass". Drop the hierarchy half of the union and
	 * this file is never scanned, so the rename commits and the build breaks.
	 */
	public function testCrossFileFixRefusesPublicFieldWhenSubtypeBindsTargetName(): Void {
		final hSrc: String = 'package pkg;\nclass Holder {\n\tpublic var __size:Int;\n}';
		final sSrc: String = 'package pkg;\nclass Sub extends Holder {\n\tprivate var size:Int;\n}';
		assertCrossFileRefused([{ file: 'pkg/Holder.hx', source: hSrc }, { file: 'pkg/Sub.hx', source: sSrc }]);
	}

	/**
	 * A file that only MENTIONS the old name — every occurrence attributed to a PROVABLY unrelated
	 * type, so it receives no edit — is not scanned for a target-name collision. `Other` carries the
	 * mention; `Mystery`, whose supertype does not resolve, is not provably unrelated to the owner
	 * and binds the target name. Without the no-edit skip that binding refuses the whole rename,
	 * even though nothing is ever written to this file.
	 */
	public function testCrossFileFixIgnoresTargetBindingInAFileItDoesNotEdit(): Void {
		final hSrc: String = 'package pkg;\nclass Holder {\n\tpublic final __size:Int;\n\tpublic function new(n:Int) { __size = n; }\n}';
		final oSrc: String = 'package pkg;\nclass Other {\n\tpublic function f():String { return \'reads the __size of it\'; }\n}\n\n'
			+ 'class Mystery extends Unknown {\n\tpublic var size:Int;\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/Holder.hx', source: hSrc },
			{ file: 'pkg/Other.hx', source: oSrc }
		];
		final rename: Array<CrossFileEdits> = crossFileRename(files);
		// The renamed write beside its untouched parameter: only the rename produces this string.
		assertRenameSlice(rename, 'pkg/Holder.hx', hSrc, 'public function new(n:Int) { size = n; }', '__size');
		// Nothing is written to the mentioning file — its only occurrence is inert literal text.
		for (slice in rename) Assert.notEquals('pkg/Other.hx', slice.file);
	}

	/**
	 * RUN-SCOPED CLAIM: a rename decided in ONE file must be visible when a SECOND file's rename is
	 * decided in the same pass. `A.CAPS` and `B.Caps` both correct to `_caps`, and the two take
	 * DIFFERENT paths — `A` is non-confined (it has a subtype) so it renames cross-file, while `B`
	 * is confined so it renames through the per-file `fix`. Both consult the SAME pass's index,
	 * where `A` still spells `CAPS`, so the inherited-member gate (`typeProvablyLacksMember`)
	 * cleared `B` and both landed `_caps`: `haxe` then rejects the tree with "Redefinition of
	 * variable _caps in subclass is not allowed" (verified live). The second must DEFER — it
	 * re-fires next pass, judged against a source that finally holds the name.
	 */
	public function testCrossFileClaimBlocksASingleFileRenameToTheSameInheritedName(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/A.hx', source: CLAIM_BASE_SRC },
			{ file: 'pkg/B.hx', source: CLAIM_SUB_SRC }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		// BOTH findings MUST exist, or the per-file zero below would be `fix`'s empty-violations
		// early return rather than the claim gate.
		Assert.equals(2, vs.length);
		// The driver's own order: every cross-file rename of the pass first, then the per-file fixes.
		final renames: Array<Array<CrossFileEdits>> = check.crossFileFix(files, vs, new HaxeQueryPlugin(), index);
		Assert.equals(1, renames.length);
		assertRenameSlice(renames[0], 'pkg/A.hx', CLAIM_BASE_SRC, '_caps', 'CAPS');
		Assert.equals(0, check.fix(CLAIM_SUB_SRC, vs.filter(v -> v.file == 'pkg/B.hx'), new HaxeQueryPlugin(), index).length);
	}

	/**
	 * The same claim with BOTH renames on the cross-file path: `C extends B` makes `B.Caps`
	 * non-confined too, so one `crossFileFix` call decides both against one index and emitted two
	 * renames to `_caps` — the identical redefinition error. Exactly one may be claimed.
	 */
	public function testOnlyOneCrossFileRenameClaimsAnInheritedTargetNamePerPass(): Void {
		final subSrc: String = 'package pkg;\nclass C extends B {\n\tpublic function c():Int { return 0; }\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/A.hx', source: CLAIM_BASE_SRC },
			{ file: 'pkg/B.hx', source: CLAIM_SUB_SRC },
			{ file: 'pkg/C.hx', source: subSrc }
		];
		// BOTH must still be flagged, or the single rename below would be one candidate rather than
		// two candidates of which one deferred.
		Assert.equals(2, new Naming().run(files, new HaxeQueryPlugin()).length);
		assertRenameSlice(crossFileRename(files), 'pkg/A.hx', CLAIM_BASE_SRC, '_caps', 'CAPS');
	}

	/**
	 * The CONTROL for both claim tests: two flagged privates correcting to the same `_caps` in
	 * UNRELATED types still BOTH rename in one pass. The claim is a hierarchy question, not a bare
	 * name one — refusing on the name alone would strand every unrelated twin in the tree.
	 */
	public function testUnrelatedTypesMayBothClaimTheSameTargetNameInOnePass(): Void {
		final xSrc: String = 'package pkg;\nclass X {\n\tprivate var Caps:Int = 2;\n\tpublic function x():Int { return Caps; }\n}';
		final renames: Array<Array<CrossFileEdits>> = crossFileRenames([
			{ file: 'pkg/A.hx', source: CLAIM_BASE_SRC },
			{ file: 'pkg/X.hx', source: xSrc },
			{ file: 'pkg/ASub.hx', source: 'package pkg;\nclass ASub extends A {\n\tpublic function s():Int { return 0; }\n}' },
			{ file: 'pkg/XSub.hx', source: 'package pkg;\nclass XSub extends X {\n\tpublic function s():Int { return 0; }\n}' }
		]);
		Assert.equals(2, renames.length);
		assertRenameSlice(renames[0], 'pkg/A.hx', CLAIM_BASE_SRC, '_caps', 'CAPS');
		assertRenameSlice(renames[1], 'pkg/X.hx', xSrc, 'return _caps', 'Caps');
	}

	/**
	 * The OTHER half of the claim design: a claim is a promise about ONE index, so the NEXT pass —
	 * which the driver gives a freshly built index — must start from an empty ledger. Without that,
	 * a deferral is a permanent refusal and the "deferral is not refusal" contract is a lie no test
	 * would catch, since every other fixture here uses a single index.
	 *
	 * The fixture makes pass 1 defer a rename that is actually SAFE: `X` is an `abstract class`, a kind
	 * `unrelatedClasses` refuses to certify (`isUniqueClass` demands a plain class), so it cannot prove
	 * what is plainly true and `X.Caps` yields to `A.CAPS`'s claim on `_caps`. Pass 2 runs the SAME `Naming`
	 * over the sources pass 1 produced, against a new index: the ledger retires, and `X` — whose own
	 * supertype closure never reaches `_caps` — finally renames. A ledger that outlived its index
	 * would return zero renames here.
	 */
	public function testANewIndexRetiresThePreviousPassClaims(): Void {
		final xSrc: String = 'package pkg;\nabstract class X {\n\tprivate var Caps:Int = 2;\n\tpublic function x():Int { return Caps; }\n}';
		final subSrc: String = 'package pkg;\nclass ASub extends A {\n\tpublic function s():Int { return 0; }\n}';
		final xSubSrc: String = 'package pkg;\nclass XSub extends X {\n\tpublic function s():Int { return 0; }\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/A.hx', source: CLAIM_BASE_SRC },
			{ file: 'pkg/X.hx', source: xSrc },
			{ file: 'pkg/ASub.hx', source: subSrc },
			{ file: 'pkg/XSub.hx', source: xSubSrc }
		];
		final check: Naming = new Naming();
		Assert.equals(2, check.run(files, new HaxeQueryPlugin()).length);
		final first: Array<Array<CrossFileEdits>> = check.crossFileFix(
			files, check.run(files, new HaxeQueryPlugin()), new HaxeQueryPlugin(), SymbolIndex.build(files, new HaxeQueryPlugin())
		);
		// Only `A` lands: `X` is an `abstract class`, which `unrelatedClasses` will not certify, so it
		// defers rather than risk the duplicate. That deferral is what the second pass has to undo.
		Assert.equals(1, first.length);
		assertRenameSlice(first[0], 'pkg/A.hx', CLAIM_BASE_SRC, '_caps', 'CAPS');
		files[0].source = RefactorSupport.applyEdits(CLAIM_BASE_SRC, first[0][0].edits);
		final second: Array<Array<CrossFileEdits>> = check.crossFileFix(
			files, check.run(files, new HaxeQueryPlugin()), new HaxeQueryPlugin(), SymbolIndex.build(files, new HaxeQueryPlugin())
		);
		Assert.equals(1, second.length);
		assertRenameSlice(second[0], 'pkg/X.hx', xSrc, 'return _caps', 'Caps');
	}

	/** The single cross-file rename `files` yields, as its per-file slices. */
	private function crossFileRename(files: Array<{ file: String, source: String }>): Array<CrossFileEdits> {
		final renames: Array<Array<CrossFileEdits>> = crossFileRenames(files);
		Assert.equals(1, renames.length);
		return renames.length == 1 ? renames[0] : [];
	}

	/** `files` carries at least one finding and the cross-file rename refuses it outright. */
	private function assertCrossFileRefused(files: Array<{ file: String, source: String }>): Void {
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		// The finding MUST exist, or the zero below would prove nothing.
		Assert.isTrue(vs.length >= 1);
		Assert.equals(0, check.crossFileFix(files, vs, new HaxeQueryPlugin(), index).length);
	}

	/** Apply one file's slice of a cross-file rename and assert the `present` name appears and `absent` is gone. */
	private function assertRenameSlice(rename: Array<CrossFileEdits>, file: String, source: String, present: String, absent: String): Void {
		var slice: Null<CrossFileEdits> = null;
		for (s in rename) if (s.file == file) slice = s;
		Assert.notNull(slice);
		if (slice == null) return;
		final applied: String = RefactorSupport.applyEdits(source, slice.edits);
		Assert.isTrue(applied.indexOf(present) >= 0, 'expected "$present" in: $applied');
		Assert.isTrue(applied.indexOf(absent) == -1, 'unexpected "$absent" in: $applied');
	}

	/**
	 * Run the cross-file rename over `dSrc` (a subtype of `C` reading the inherited `size`) alongside
	 * a module declaring a SECOND type named `D`, and assert the rename is refused outright. The twin
	 * makes `declsNamed('D')` ambiguous, which is what defeats the positive `isSubtype` proof.
	 */
	private function assertAmbiguousSubtypeBlocks(dSrc: String): Void {
		final twinSrc: String = 'package pkg;\nclass Twin {}\n\nclass D {\n\tpublic var other:Int;\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'pkg/C.hx', source: AMBIGUITY_OWNER_SRC },
			{ file: 'pkg/D.hx', source: dSrc },
			{ file: 'pkg/Twin.hx', source: twinSrc }
		];
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		final vs: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		// The candidate MUST exist, or the zero below would prove nothing.
		Assert.equals(1, vs.length);
		final renames: Array<Array<CrossFileEdits>> = check.crossFileFix(files, vs, new HaxeQueryPlugin(), index);
		// Either a COMPLETE rename (both files) or none - never the declaring file alone.
		assertNotHalfApplied(renames, 'pkg/C.hx', 'pkg/D.hx');
		Assert.equals(0, renames.length);
	}

	/**
	 * A cross-file rename touching `declFile` must also carry `subFile`: committing the declaring
	 * file alone orphans the subtype's inherited read and breaks the build.
	 */
	private function assertNotHalfApplied(renames: Array<Array<CrossFileEdits>>, declFile: String, subFile: String): Void {
		for (rename in renames) {
			var hasDecl: Bool = false;
			var hasSub: Bool = false;
			for (slice in rename) {
				if (slice.file == declFile) hasDecl = true;
				if (slice.file == subFile) hasSub = true;
			}
			if (hasDecl) Assert.isTrue(hasSub, 'half-applied: $declFile renamed without $subFile');
		}
	}

	/** Every cross-file rename `files` yields in ONE pass, from a fresh check. */
	private function crossFileRenames(files: Array<{ file: String, source: String }>): Array<Array<CrossFileEdits>> {
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final check: Naming = new Naming();
		return check.crossFileFix(files, check.run(files, new HaxeQueryPlugin()), new HaxeQueryPlugin(), index);
	}

}
