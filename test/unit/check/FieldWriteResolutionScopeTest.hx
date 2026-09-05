package unit.check;

import anyparse.check.PreferFinalPublicField;
import anyparse.check.PreferReadOnlyField;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import utest.Assert;
import utest.Test;

/**
 * Which HALF of a resolution scope the two field-immutability rules read, and with what owner
 * narrowing.
 *
 * S95 put the write proof on the PROJECT scope (report UNION the declared `resolutionRoots`) and
 * measured the obvious wider variant — the whole resolution scope, library included — down. That
 * measurement re-run on this slice's base: a whole-scope index costs 12 of 121 findings and gains
 * none, and the losses are NOT one mechanism — 10 from `SymbolIndex.text.skippedMayReference` (a
 * skip-parsing library source that merely SPELLS the member name), 2 from structural conformance
 * against a library anonymous structure, and 0 from `declarationSiteOf`, whose 5 the write index
 * had already absorbed by holding the resolution-scoped index itself.
 *
 * So the two halves answer different questions, and the split is per QUESTION, not per rule:
 *
 *  - The WRITE index spans the whole resolution scope, with the library half tagged third-party.
 *    That is the question that WANTS the library: a third-party SUBTYPE of a project type is
 *    written through a third-party receiver in a third file, which is invisible to the subtype's
 *    own declaration slice and to a project-scoped index alike.
 *  - The name/type index spans it too — a library supertype, an implemented library interface and
 *    a library `@:build` are vetoes the project scope cannot see, and the skip-parse scan joins
 *    once it is narrowed per owner.
 *  - STRUCTURAL conformance alone stays PROJECT-scoped: it matches an anonymous structure by
 *    member NAME set alone, so the library's structures veto far past what they can unify with.
 *  - Every question a rule asks about ITS OWN candidate carries that candidate's file, so what a
 *    third-party source recorded is narrowed back out (`FieldWriteIndex.admits` for a write,
 *    `RawSourceScan.admits` for the skip-parse scan) — a haxelib can neither name a project type
 *    nor hold a statically-typed write into one.
 */
class FieldWriteResolutionScopeTest extends Test {

	/** A project class whose public field is written only inside its own body — `prefer-read-only-field`'s candidate. */
	private static final BASE: String = 'package proj;\n\nclass Base {\n\n\tpublic var slot: Int = 0;\n\n\tpublic function new() {}\n\n'
		+ '\tpublic function bump(): Void {\n\t\tthis.slot = 1;\n\t}\n\n}\n';

	/** A project class whose public field is never written at all — `prefer-final-public-field`'s candidate. */
	private static final CTX: String = 'package proj;\n\nclass Ctx {\n\n\tpublic var mode: Int = 0;\n\n\tpublic function new() {}\n\n}\n';

	/** A third-party subtype of `Base` that writes nothing itself — its declaration slice holds no `slot`. */
	private static final SUB: String = 'package ext;\n\nimport proj.Base;\n\nclass Sub extends Base {}\n';

	/** A third-party subtype of `Ctx`, likewise silent about the inherited field. */
	private static final CTX_SUB: String = 'package ext;\n\nimport proj.Ctx;\n\nclass CtxSub extends Ctx {}\n';

	/** A THIRD third-party file writing the inherited field through a subtype-typed receiver. */
	private static final SUB_WRITER: String = 'package ext;\n\nclass SubWriter {\n\n\tpublic function new() {}\n\n'
		+ '\tpublic function go(): Void {\n\t\tfinal s: Sub = new Sub();\n\t\ts.slot = 2;\n\t}\n\n}\n';

	/** The same, for the `final` rule's candidate. */
	private static final CTX_SUB_WRITER: String = 'package ext;\n\nclass CtxSubWriter {\n\n\tpublic function new() {}\n\n'
		+ '\tpublic function go(): Void {\n\t\tfinal c: CtxSub = new CtxSub();\n\t\tc.mode = 2;\n\t}\n\n}\n';

	/** A write through a `Dynamic` receiver — unresolvable, so it poisons the field NAME and nothing narrower. */
	private static final DYN_WRITER: String = 'package ext;\n\nclass DynWriter {\n\n\tpublic function new() {}\n\n'
		+ '\tpublic function go(d: Dynamic): Void {\n\t\td.slot = 3;\n\t}\n\n}\n';

	/** An unrelated third-party type sharing the project candidate's SIMPLE name. */
	private static final LIB_BASE: String =
		'package ext;\n\nclass Base {\n\n\tpublic var other: Int = 0;\n\n\tpublic function new() {}\n\n}\n';

	/** A third-party source the grammar cannot read, whose bytes SPELL the project candidate's member name. */
	private static final BROKEN_LIB: String = 'package ext;\n\nclass Broken {\n\tpublic var slot = ((;\n}\n';

	/** A project class implementing an interface the LIBRARY half declares — and which declares no `slot`. */
	private static final IMPL: String = 'package proj;\n\nimport ext.Marker;\n\nclass Impl implements Marker {\n\n'
		+ '\tpublic var slot: Int = 0;\n\n\tpublic function new() {}\n\n}\n';

	/** That interface, declaring nothing at all — so it pins no member of anything implementing it. */
	private static final MARKER: String = 'package ext;\n\ninterface Marker {}\n';

	/** A third-party anonymous structure `Ctx` genuinely conforms to — same member NAME and same declared type. */
	private static final SHAPE: String = 'package ext;\n\ntypedef Shape = { mode: Int }\n';

	/** The same shape for the write-restriction rule: the field is written, but only inside its own type. */
	private static final IMPL_RO: String = 'package proj;\n\nimport ext.Marker;\n\nclass ImplRo implements Marker {\n\n'
		+ '\tpublic var slot: Int = 0;\n\n\tpublic function new() {}\n\n\tpublic function bump(): Void {\n\t\tthis.slot = 1;\n\t}\n\n}\n';

	/** A project class whose candidate is annotated with a plain class declared in ANOTHER package. */
	private static final HOLDER: String =
		'package proj;\n\nclass Holder {\n\n\tpublic var slot: Token = null;\n\n\tpublic function new() {}\n\n}\n';

	/** The same, with the import that actually brings `Token` into `Holder`'s scope. */
	private static final HOLDER_IMPORTING: String =
		'package proj;\n\nimport other.Token;\n\nclass Holder {\n\n\tpublic var slot: Token = null;\n\n\tpublic function new() {}\n\n}\n';

	/** The only `Token` the scope declares — a plain class, in a package `Holder` neither shares nor imports. */
	private static final TOKEN: String = 'package other;\n\nclass Token {\n\n\tpublic function new() {}\n\n}\n';

	/** A PROJECT write of the same member NAME through a `Dynamic` — unresolvable, so it poisons the name. */
	private static final PROJ_DYN_WRITER: String = 'package proj;\n\nclass ProjDynWriter {\n\n\tpublic function new() {}\n\n'
		+ '\tpublic function go(d: Dynamic): Void {\n\t\td.slot = 3;\n\t}\n\n}\n';

	private static final SUB_FILE: SourceFile = { file: 'ext/Sub.hx', source: SUB };
	private static final CTX_SUB_FILE: SourceFile = { file: 'ext/CtxSub.hx', source: CTX_SUB };
	private static final SUB_WRITER_FILE: SourceFile = { file: 'ext/SubWriter.hx', source: SUB_WRITER };
	private static final CTX_SUB_WRITER_FILE: SourceFile = { file: 'ext/CtxSubWriter.hx', source: CTX_SUB_WRITER };
	private static final DYN_WRITER_FILE: SourceFile = { file: 'ext/DynWriter.hx', source: DYN_WRITER };
	private static final LIB_BASE_FILE: SourceFile = { file: 'ext/Base.hx', source: LIB_BASE };
	private static final BROKEN_LIB_FILE: SourceFile = { file: 'ext/Broken.hx', source: BROKEN_LIB };
	private static final MARKER_FILE: SourceFile = { file: 'ext/Marker.hx', source: MARKER };
	private static final TOKEN_FILE: SourceFile = { file: 'other/Token.hx', source: TOKEN };
	private static final PROJ_DYN_WRITER_FILE: SourceFile = { file: 'proj/ProjDynWriter.hx', source: PROJ_DYN_WRITER };
	private static final SHAPE_FILE: SourceFile = { file: 'ext/Shape.hx', source: SHAPE };

	/**
	 * The blind spot both rules' docs described until this slice: the subtype is third-party, it
	 * writes the inherited field nowhere in its own body, and the write lives in a third
	 * third-party file. A project-scoped write index cannot hold that write, and the subtype's
	 * declaration slice does not spell the name, so the rule used to report a rewrite the
	 * subtype's writer forbids.
	 */
	@:pin('control')
	@:killer('M-WRITEINDEX-PROJECT-READONLY')
	public function testThirdPartySubtypeWriteVetoesReadOnly(): Void {
		// Leading assertion — the fixture reaches the code: the subtype ALONE leaves the finding standing.
		Assert.equals(1, readOnly([SUB_FILE]), 'a third-party subtype that writes nothing must not veto');
		Assert.equals(0, readOnly([SUB_FILE, SUB_WRITER_FILE]), 'a third-party write through that subtype vetoes (default, null)');
	}

	/** The same blind spot on `prefer-final-public-field`'s never-written arm. */
	@:pin('control')
	@:killer('M-WRITEINDEX-PROJECT-FINAL')
	public function testThirdPartySubtypeWriteVetoesFinal(): Void {
		// Leading assertion — the subtype alone must still leave the rewrite reportable.
		Assert.equals(1, finalPublic([CTX_SUB_FILE]), 'a third-party subtype that writes nothing must not veto');
		Assert.equals(0, finalPublic([CTX_SUB_FILE, CTX_SUB_WRITER_FILE]), 'a third-party write through that subtype vetoes var -> final');
	}

	/**
	 * The owner narrowing, in the direction that keeps findings: an UNRESOLVED write recorded in a
	 * third-party file names only a member, and a haxelib cannot name a project type, so it must
	 * not poison a project candidate. Passes at base too — there the library is not in the write
	 * index at all — so this guards what admitting the library must not cost; the arm that kills it
	 * is the one making `FieldWriteIndex.admits` unconditionally true.
	 */
	@:pin('control')
	@:killer('M-ADMITS-TRUE')
	public function testThirdPartyUnresolvedWriteDoesNotVeto(): Void {
		// Leading assertion — the candidate is reportable with no library at all.
		Assert.equals(1, readOnly([]), 'the bare candidate is reported');
		Assert.equals(1, readOnly([DYN_WRITER_FILE]), 'a third-party Dynamic write to the same NAME must not veto');
	}

	/**
	 * The same unresolved write in a declared `resolutionRoots` module DOES veto: those are the
	 * project's own files, which is the whole reason S95 widened past the lint scope. The arm that
	 * kills it is the one tagging the project roots third-party — the library array carries them,
	 * so the partition has to subtract them explicitly.
	 */
	@:pin('control')
	@:killer('M-ROOTS-THIRDPARTY')
	public function testProjectRootUnresolvedWriteVetoes(): Void {
		Assert.equals(0, readOnly([], [DYN_WRITER_FILE]), 'a project-root Dynamic write vetoes');
	}

	/**
	 * A third-party type of the same SIMPLE name must not cost the finding. `declarationSiteOf`
	 * answers only for a name the scope declares exactly once, so widening the write index makes it
	 * null and every caller reads that as "possibly written externally"; the candidate's own file
	 * is the per-owner answer. Passes at base (no library in the index there); the arm that kills
	 * it drops the owner-file pin.
	 */
	@:pin('control')
	@:killer('M-DECLSITE-SCOPEWIDE')
	public function testSameSimpleNameThirdPartyTypeDoesNotVeto(): Void {
		Assert.equals(1, readOnly([LIB_BASE_FILE]), 'an unrelated third-party Base must not veto the project Base');
	}

	/**
	 * The skip-parse scan, narrowed per OWNER. A library source the grammar cannot read is a
	 * hole in every proof — but only for a candidate it could reach, and a haxelib cannot name
	 * a project type, so it reaches none of them. Unnarrowed the scan is keyed on the member
	 * NAME alone, so any library source that merely SPELLS `slot` silences the rule: over the
	 * Pony fork that is 11 of 121 findings, from seven skip-parsing haxelib sources.
	 *
	 * This is what admitting the library to the checks' index must not cost, so it passes
	 * before the slice too — there the library is not in that index at all. The arm that kills
	 * it is the one making the narrowing unconditional.
	 */
	@:pin('control')
	@:killer('M-SKIPSCAN-SCOPEWIDE')
	public function testSkipParsingLibrarySourceDoesNotVetoProjectCandidate(): Void {
		// Leading assertion — the candidate is reportable with no library at all.
		Assert.equals(1, readOnly([]), 'the bare candidate is reported');
		Assert.equals(1, readOnly([BROKEN_LIB_FILE]), 'an unreadable third-party source spelling the member must not veto');
	}

	/**
	 * What admitting the library BUYS, on the nominal half of the index: an implemented
	 * interface the resolution scope can read is proved to declare no `slot`, so the
	 * conservative unresolvable-interface bail no longer fires. Before this slice the checks
	 * held a project-scoped index, `Marker` resolved to nothing there, and the candidate was
	 * withheld.
	 */
	@:pin('control')
	@:killer('M-CHECKINDEX-PROJECT-FINAL')
	public function testResolvableLibraryInterfaceStopsVetoing(): Void {
		// Leading assertion — the interface has to be OUT of scope for the bail to be the subject.
		Assert.equals(0, finalPublicImpl([]), 'an unresolvable implemented interface withholds the rewrite');
		Assert.equals(1, finalPublicImpl([MARKER_FILE]), 'the same interface, readable, declares no slot and stops vetoing');
	}

	/** The write-restriction twin of the interface case — the same bail, the same relief. */
	@:pin('control')
	@:killer('M-CHECKINDEX-PROJECT-READONLY')
	public function testResolvableLibraryInterfaceStopsVetoingWriteRestriction(): Void {
		// Leading assertion — the interface has to be OUT of scope for the bail to be the subject.
		Assert.equals(0, readOnlyImpl([]), 'an unresolvable implemented interface withholds the restriction');
		Assert.equals(1, readOnlyImpl([MARKER_FILE]), 'the same interface, readable, declares no slot and stops vetoing');
	}

	/**
	 * The plain-class proof, resolved FROM the candidate's own file. `Token` is declared exactly
	 * once in the scope, so a scope-blind uniqueness count calls it the candidate's type and
	 * frees the candidate from an unresolved builtin write — while `Holder` neither imports it
	 * nor shares its package, so its `Token` is some other type entirely. That is the shape the
	 * Pony fork's `Rotor.speed: Single` had, and the blind count got it right there only because
	 * the std happened to declare a second `Single`.
	 */
	@:pin('control')
	@:killer('M-PLAINCLASS-SCOPEBLIND')
	public function testOutOfScopePlainClassKeepsTheUnresolvedWritePoison(): Void {
		// Leading assertion — WITH the import the type really is the candidate's, and it frees it.
		Assert.equals(1, finalPublicHolder(HOLDER_IMPORTING), 'an in-scope plain class frees the candidate');
		Assert.equals(0, finalPublicHolder(HOLDER), 'a plain class the candidate file cannot name proves nothing');
	}

	/**
	 * What admitting the library buys on the STRUCTURAL half, which was the last question held
	 * back to a project-scoped index. A library anonymous structure the project candidate really
	 * does conform to — same member, same declared type — vetoes the rewrite once the gate reads
	 * the resolution index; before this slice the structure was invisible to it and the finding
	 * stood. The gate can only be joined now that it proves the conformance instead of matching a
	 * member NAME SET: name-set matching over an unresolvable supertype was withholding two Pony
	 * findings against library structures and three against project ones.
	 */
	@:pin('control')
	@:killer('M-CHECKINDEX-PROJECT-FINAL')
	public function testLibraryStructureVetoesOnceStructuralJoins(): Void {
		// Leading assertion — the structure has to be OUT of scope for the join to be the subject.
		Assert.equals(1, finalPublic([]), 'the bare candidate is reported');
		Assert.equals(0, finalPublic([SHAPE_FILE]), 'a library structure the candidate conforms to vetoes var -> final');
	}

	/** `prefer-final-public-field` over the `Impl` fixture, whose interface lives in the `library` half. */
	private static function finalPublicImpl(library: Array<SourceFile>): Int {
		final report: Array<SourceFile> = [{ file: 'proj/Impl.hx', source: IMPL }];
		return new PreferFinalPublicField().run(report, scoped(report, [], library)).length;
	}

	/** `prefer-read-only-field` over the `ImplRo` fixture, whose interface lives in the `library` half. */
	private static function readOnlyImpl(library: Array<SourceFile>): Int {
		final report: Array<SourceFile> = [{ file: 'proj/ImplRo.hx', source: IMPL_RO }];
		return new PreferReadOnlyField().run(report, scoped(report, [], library)).length;
	}

	/** `prefer-final-public-field` over one of the two `Holder` spellings, with the poisoning writer beside it. */
	private static function finalPublicHolder(holder: String): Int {
		final report: Array<SourceFile> = [{ file: 'proj/Holder.hx', source: holder }, PROJ_DYN_WRITER_FILE, TOKEN_FILE];
		return new PreferFinalPublicField().run(report, scoped(report, [], [])).length;
	}

	/** `prefer-read-only-field` over the `Base` fixture with `library` third-party files and `roots` project roots. */
	private static function readOnly(library: Array<SourceFile>, ?roots: Array<SourceFile>): Int {
		final report: Array<SourceFile> = [{ file: 'proj/Base.hx', source: BASE }];
		return new PreferReadOnlyField().run(report, scoped(report, roots ?? [], library)).length;
	}

	/** `prefer-final-public-field` over the `Ctx` fixture, same scope shape. */
	private static function finalPublic(library: Array<SourceFile>, ?roots: Array<SourceFile>): Int {
		final report: Array<SourceFile> = [{ file: 'proj/Ctx.hx', source: CTX }];
		return new PreferFinalPublicField().run(report, scoped(report, roots ?? [], library)).length;
	}

	/**
	 * A plugin hosting the scope in the shape `LintCommand` builds: the library half carries the
	 * declared roots too, which is exactly the overlap the third-party partition has to subtract.
	 */
	private static function scoped(report: Array<SourceFile>, roots: Array<SourceFile>, library: Array<SourceFile>): CachingGrammarPlugin {
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		plugin.setResolutionScope({
			declared: true,
			sources: () -> {report: report, projectRoots: roots, library: new LibrarySources(roots.concat(library)) }
		});
		return plugin;
	}

}

/** One source the scope holds — the shape every scope half in this file is an array of. */
private typedef SourceFile = {
	var file: String;
	var source: String;
};
