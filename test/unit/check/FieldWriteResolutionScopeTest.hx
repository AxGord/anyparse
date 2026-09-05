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
 * measured the obvious wider variant — the whole resolution scope, library included — down: over
 * the Pony fork it lost 18 of 112 findings and gained none. The census behind that number says the
 * losses are NOT one mechanism: 10 came from `SymbolIndex.text.skippedMayReference` (a
 * skip-parsing library file that merely SPELLS the member name), 3 from structural conformance
 * against a library anonymous structure, and 5 from `declarationSiteOf` going ambiguous once a
 * library declares a type of the same SIMPLE name (`Helper`, `Input`).
 *
 * So the two halves of the scope answer different questions, and the split here is per QUESTION,
 * not per rule:
 *
 *  - The name-keyed scans (`skippedMayReference`, structural conformance, supertype lookup) stay
 *    on the PROJECT-scoped `SymbolIndex`. Admitting the library there only suppresses.
 *  - The WRITE index spans the whole resolution scope, with the library half tagged third-party.
 *    That is the one question that WANTS the library: a third-party SUBTYPE of a project type is
 *    written through a third-party receiver in a third file, which is invisible to the subtype's
 *    own declaration slice and to a project-scoped index alike.
 *  - Every question a rule asks about ITS OWN candidate carries that candidate's file, so a write
 *    recorded in a third-party source is narrowed back out (`FieldWriteIndex.admits`) — a haxelib
 *    cannot name a project type, so it cannot hold a statically-typed write into one.
 */
class FieldWriteResolutionScopeTest extends Test {

	/** A project class whose public field is written only inside its own body — `prefer-read-only-field`'s candidate. */
	private static final BASE: String = 'package proj;\n\nclass Base {\n\n\tpublic var slot: Int = 0;\n\n\tpublic function new() {}\n\n'
		+ '\tpublic function bump(): Void {\n\t\tthis.slot = 1;\n\t}\n\n}\n';

	/** A project class whose public field is never written at all — `prefer-final-public-field`'s candidate. */
	private static final CTX: String = 'package proj;\n\nclass Ctx {\n\n\tpublic var mode: Int = 0;\n\n\tpublic function new() {}\n\n}\n';

	/** A third-party subtype of `Base` that writes nothing itself — its declaration slice holds no `slot`. */
	private static final SUB: String = 'package ext;\n\nimport proj.Base;\n\nclass Sub extends Base {\n\n\tpublic function new() {\n'
		+ '\t\tsuper();\n\t}\n\n}\n';

	/** A third-party subtype of `Ctx`, likewise silent about the inherited field. */
	private static final CTX_SUB: String = 'package ext;\n\nimport proj.Ctx;\n\nclass CtxSub extends Ctx {\n\n\tpublic function new() {\n'
		+ '\t\tsuper();\n\t}\n\n}\n';

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

	private static final SUB_FILE: { file: String, source: String } = { file: 'ext/Sub.hx', source: SUB };
	private static final CTX_SUB_FILE: { file: String, source: String } = { file: 'ext/CtxSub.hx', source: CTX_SUB };
	private static final SUB_WRITER_FILE: { file: String, source: String } = { file: 'ext/SubWriter.hx', source: SUB_WRITER };
	private static final CTX_SUB_WRITER_FILE: { file: String, source: String } = {
		file: 'ext/CtxSubWriter.hx',
		source: CTX_SUB_WRITER
	};
	private static final DYN_WRITER_FILE: { file: String, source: String } = { file: 'ext/DynWriter.hx', source: DYN_WRITER };
	private static final LIB_BASE_FILE: { file: String, source: String } = { file: 'ext/Base.hx', source: LIB_BASE };

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

	/** `prefer-read-only-field` over the `Base` fixture with `library` third-party files and `roots` project roots. */
	private static function readOnly(
		library: Array<{ file: String, source: String }>, ?roots: Array<{ file: String, source: String }>
	): Int {
		final report: Array<{ file: String, source: String }> = [{ file: 'proj/Base.hx', source: BASE }];
		return new PreferReadOnlyField().run(report, scoped(report, roots ?? [], library)).length;
	}

	/** `prefer-final-public-field` over the `Ctx` fixture, same scope shape. */
	private static function finalPublic(
		library: Array<{ file: String, source: String }>, ?roots: Array<{ file: String, source: String }>
	): Int {
		final report: Array<{ file: String, source: String }> = [{ file: 'proj/Ctx.hx', source: CTX }];
		return new PreferFinalPublicField().run(report, scoped(report, roots ?? [], library)).length;
	}

	/**
	 * A plugin hosting the scope in the shape `LintCommand` builds: the library half carries the
	 * declared roots too, which is exactly the overlap the third-party partition has to subtract.
	 */
	private static function scoped(
		report: Array<{ file: String, source: String }>, roots: Array<{ file: String, source: String }>,
		library: Array<{ file: String, source: String }>
	): CachingGrammarPlugin {
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		plugin.setResolutionScope({
			declared: true,
			sources: () -> {report: report, projectRoots: roots, library: new LibrarySources(roots.concat(library)) }
		});
		return plugin;
	}

}
