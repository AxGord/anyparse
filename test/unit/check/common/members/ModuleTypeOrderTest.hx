package unit.check.common.members;

import anyparse.check.Severity;
import anyparse.check.common.members.ModuleTypeOrder;

/**
 * The `module-type-order` check over a module `C.hx`, whose main type is `C`: under the default
 * `mainType: last` a secondary type written after it is flagged and moved before it, `first`
 * asks the opposite, `kindOrder` orders the secondary types by declaration word, and the fix
 * moves whole declarations - doc comment, metadata, modifiers, a comment closing the line - with
 * the blank lines staying where they were. Declarations of one conditional region move among
 * themselves; a move across a region's boundary, or a gap holding anything but whitespace,
 * withholds the fix and keeps the finding with its reason.
 */
@:nullSafety(Strict)
final class ModuleTypeOrderTest extends Test {

	private static inline final MAIN_FIRST: String = '{"rules":{"module-type-order":{"mainType":"first"}}}';
	private static inline final MAIN_ANY: String = '{"rules":{"module-type-order":{"mainType":"any"}}}';
	private static inline final KIND_ORDER: String =
		'{"rules":{"module-type-order":{"kindOrder":["typedef","enum","abstract","interface","class"]}}}';

	/** Under the default, the types after the main one are flagged once and moved before it, in their own order. */
	@:killer('M-MTO-MAIN-LAST-UNREAD')
	@:pin('control')
	public function testTheMainTypeFirstIsFlaggedAndMovedLast(): Void {
		final src: String = 'package p;\n\nclass C {}\n\ntypedef T = Int;\n\nenum E {\n\tA;\n}\n';
		final found: Array<Violation> = CheckFixture.violations(new ModuleTypeOrder(), src);
		Assert.equals(1, found.length);
		Assert.equals('module-type-order', found[0].rule);
		Assert.equals(Severity.Info, found[0].severity);
		Assert.equals('typedef T follows class C: mainType "last" puts every other type before the main type', found[0].message);
		final fixed: String = CheckFixture.fixedSource(new ModuleTypeOrder(), src);
		Assert.equals('package p;\n\ntypedef T = Int;\n\nenum E {\n\tA;\n}\n\nclass C {}\n', fixed);
		Assert.equals(0, CheckFixture.violations(new ModuleTypeOrder(), fixed).length, 'one pass converges');
	}

	/** `mainType: first` flags the main type written after a secondary one and moves it to the front. */
	@:killer('M-MTO-MAIN-FIRST-PLACED-LAST')
	@:pin('control')
	public function testMainTypeFirstMovesTheMainTypeToTheFront(): Void {
		final src: String = 'package p;\n\ntypedef T = Int;\n\nclass C {}\n';
		Assert.equals(0, CheckFixture.violations(new ModuleTypeOrder(), src).length, 'the default accepts it');
		final run: FixRun = CheckFixture.fixRunUnder(new ModuleTypeOrder(), src, MAIN_FIRST);
		Assert.equals(1, run.violations.length);
		Assert.equals('class C follows typedef T: mainType "first" puts the main type before every other type', run.violations[0].message);
		Assert.equals('package p;\n\nclass C {}\n\ntypedef T = Int;\n', CheckFixture.fixedUnder(new ModuleTypeOrder(), src, MAIN_FIRST));
	}

	/** A moved declaration carries its doc comment, metadata, modifiers and the comment closing its line; so does the main type. */
	@:killer('M-MTO-DOC-LEFT-BEHIND')
	@:pin('control')
	public function testAMovedDeclarationCarriesItsDocAndMetadata(): Void {
		final src: String = 'package p;\n\n/** The main type. */\nfinal class C {}\n\n/** About T. */\n@:keep\n'
			+ 'typedef T = Int; // the alias\n\n/* about E */\nprivate enum E {\n\tA;\n}\n';
		Assert.equals(
			'package p;\n\n/** About T. */\n@:keep\ntypedef T = Int; // the alias\n\n/* about E */\nprivate enum E {\n\tA;\n}\n\n'
			+ '/** The main type. */\nfinal class C {}\n',
			CheckFixture.fixedSource(new ModuleTypeOrder(), src)
		);
	}

	/** A type that must move but sits under `#if` keeps the finding, gets no edit, and the reason names it. */
	@:killer('M-MTO-GUARDED-MOVES')
	@:pin('control')
	public function testADeclarationUnderIfIsReportedButNotMoved(): Void {
		final run: FixRun = CheckFixture.fixRunUnder(
			new ModuleTypeOrder(), 'package p;\n\nclass C {}\n\n#if js\ntypedef T = Int;\n#end\n', '{}'
		);
		Assert.equals(1, run.violations.length);
		Assert.equals(0, run.edits.length);
		final reason: String = run.violations[0].declineReason ?? '';
		Assert.isTrue(reason.indexOf('typedef T sits inside a conditional region') >= 0, reason);
	}

	/** A conditional block inside the range the reorder would permute withholds the fix, though the block itself stays put. */
	public function testAConditionalBlockTheMoveWouldCrossIsRefused(): Void {
		final src: String = 'package p;\n\nclass C {}\n\n#if js\ntypedef G = Int;\n#end\n\ntypedef T = Int;\n';
		final run: FixRun = CheckFixture.fixRunUnder(new ModuleTypeOrder(), src, '{}');
		Assert.equals(1, run.violations.length);
		Assert.equals(0, run.edits.length);
	}

	/** A comment between two slots that no declaration owns would land beside the wrong type, so the fix is withheld. */
	@:killer('M-MTO-STRAY-GAP-IGNORED')
	@:pin('control')
	public function testAStrayCommentBetweenTypesWithholdsTheFix(): Void {
		final run: FixRun = CheckFixture.fixRunUnder(
			new ModuleTypeOrder(), 'package p;\n\nclass C {}\n\n// helpers\n\ntypedef T = Int;\n', '{}'
		);
		Assert.equals(1, run.violations.length);
		Assert.equals(0, run.edits.length);
		final reason: String = run.violations[0].declineReason ?? '';
		Assert.isTrue(reason.indexOf('something other than blank lines separates C from T') >= 0, reason);
	}

	/** `kindOrder` ranks the secondary types by declaration word, read through the grammar's word table. */
	@:killer('M-MTO-KIND-RANK-UNREAD', 'M-MTO-KIND-WORDS-UNREAD')
	@:pin('control')
	public function testKindOrderSortsTheSecondaryTypes(): Void {
		final src: String = 'package p;\n\nenum E {\n\tA;\n}\n\ntypedef T = Int;\n\nclass C {}\n';
		Assert.equals(0, CheckFixture.violations(new ModuleTypeOrder(), src).length, 'no kind order by default');
		final run: FixRun = CheckFixture.fixRunUnder(new ModuleTypeOrder(), src, KIND_ORDER);
		Assert.equals(1, run.violations.length);
		Assert.equals('typedef T follows enum E: kindOrder puts typedef before enum', run.violations[0].message);
		Assert.equals(
			'package p;\n\ntypedef T = Int;\n\nenum E {\n\tA;\n}\n\nclass C {}\n',
			CheckFixture.fixedUnder(new ModuleTypeOrder(), src, KIND_ORDER)
		);
	}

	/** The gaps stay positional: the k-th gap of the moved range is still the k-th after the reorder. */
	public function testTheBlankLinesStayWhereTheyWere(): Void {
		Assert.equals(
			'package p;\n\ntypedef T = Int;\n\n\ntypedef U = Int;\n\nclass C {}\n',
			CheckFixture.fixedSource(new ModuleTypeOrder(), 'package p;\n\nclass C {}\n\n\ntypedef T = Int;\n\ntypedef U = Int;\n')
		);
	}

	/** `mainType: any` leaves the main type where it is. */
	public function testMainTypeAnyAcceptsEitherPlace(): Void {
		Assert.equals(
			0, CheckFixture.fixRunUnder(new ModuleTypeOrder(), 'package p;\n\nclass C {}\n\ntypedef T = Int;\n', MAIN_ANY).violations.length
		);
	}

	/** A module with no type named like the file has no main type to place. */
	public function testAModuleWithoutAMainTypeIsNotFlagged(): Void {
		Assert.equals(0, CheckFixture.violations(new ModuleTypeOrder(), 'package p;\n\nclass D {}\n\ntypedef T = Int;\n').length);
	}

	public function testRegisteredInBuiltins(): Void {
		CheckFixture.assertRegistered('module-type-order');
	}

	/** Under `mainType: any` the fix sorts the other types around the main one, which keeps its index. */
	@:killer('M-MTO-MAIN-ANY-PLACED-LAST')
	@:pin('control')
	public function testMainTypeAnyFixKeepsTheMainTypeInPlace(): Void {
		final json: String = '{"rules":{"module-type-order":{"mainType":"any","kindOrder":["interface","typedef"]}}}';
		final src: String = 'package p;\n\nenum E {\n\tA;\n}\n\nclass C {}\n\ntypedef T = Int;\n\ninterface I {}\n';
		Assert.equals(
			'package p;\n\ninterface I {}\n\nclass C {}\n\ntypedef T = Int;\n\nenum E {\n\tA;\n}\n',
			CheckFixture.fixedUnder(new ModuleTypeOrder(), src, json)
		);
	}

	/** A kind `kindOrder` does not list ranks after every listed one. */
	@:killer('M-MTO-UNLISTED-RANKS-FIRST')
	@:pin('control')
	public function testAnUnlistedKindRanksAfterTheListedOnes(): Void {
		final json: String = '{"rules":{"module-type-order":{"kindOrder":["typedef"]}}}';
		final src: String = 'package p;\n\nenum E {\n\tA;\n}\n\ntypedef T = Int;\n\nclass C {}\n';
		final run: FixRun = CheckFixture.fixRunUnder(new ModuleTypeOrder(), src, json);
		Assert.equals(1, run.violations.length);
		Assert.equals('typedef T follows enum E: kindOrder puts typedef before enum', run.violations[0].message);
		Assert.equals(
			'package p;\n\ntypedef T = Int;\n\nenum E {\n\tA;\n}\n\nclass C {}\n', CheckFixture.fixedUnder(new ModuleTypeOrder(), src, json)
		);
	}

	/** Declarations sharing one conditional region, such as a module wrapped whole in `#if macro`, are reordered inside it. */
	@:killer('M-MTO-REGION-NOT-MOVED')
	@:pin('control')
	public function testTypesOfOneConditionalRegionAreReorderedInsideIt(): Void {
		final src: String = 'package p;\n\n#if macro\nclass C {}\n\ntypedef T = Int;\n#end\n';
		Assert.equals(
			'package p;\n\n#if macro\ntypedef T = Int;\n\nclass C {}\n#end\n', CheckFixture.fixedSource(new ModuleTypeOrder(), src)
		);
	}

	/** Two branches of one conditional block are not one region a reorder may permute: the `#else` between them withholds the fix. */
	public function testTypesInTwoBranchesOfOneBlockAreNotMoved(): Void {
		final src: String = 'package p;\n\n#if js\nclass C {}\n#else\ntypedef T = Int;\n#end\n';
		final run: FixRun = CheckFixture.fixRunUnder(new ModuleTypeOrder(), src, '{}');
		Assert.equals(1, run.violations.length);
		Assert.equals(0, run.edits.length);
	}

	/** A main type under `#if` with a top-level type after it: the refusal names the guarded declaration, not the top-level one. */
	@:killer('M-MTO-DECLINE-NAMES-TOP')
	@:pin('control')
	public function testTheRefusalNamesTheDeclarationUnderIf(): Void {
		final src: String = 'package p;\n\n#if js\nclass C {}\n#end\n\ntypedef T = Int;\n';
		final run: FixRun = CheckFixture.fixRunUnder(new ModuleTypeOrder(), src, '{}');
		Assert.equals(1, run.violations.length);
		Assert.equals(0, run.edits.length);
		final reason: String = run.violations[0].declineReason ?? '';
		Assert.isTrue(reason.indexOf('class C sits inside a conditional region') >= 0, reason);
	}

}
