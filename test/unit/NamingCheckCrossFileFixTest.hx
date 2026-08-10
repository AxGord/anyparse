package unit;

import utest.Assert;
import anyparse.check.Check.Violation;
import anyparse.check.Naming;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.RefactorSupport;
import anyparse.runtime.Span;
import anyparse.query.SymbolIndex;
import anyparse.check.Check.CrossFileEdits;

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

}
