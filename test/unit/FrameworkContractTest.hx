package unit;

import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.Naming;
import anyparse.check.UnusedPrivate;
import anyparse.check.UnusedPublicMember;
import anyparse.grammar.haxe.HaxeNamingSupport;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.NamingPolicy.FrameworkContract;
import anyparse.query.NamingPolicy.NamedDecl;
import anyparse.query.NamingPolicy.NamingCategory;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/**
 * The FRAMEWORK CONTRACT seam: a project declares in `apqlint.json` (`frameworks`) which root types
 * a framework drives and which member names it reaches BY NAME, and one seam (`NamingSupport.frameworkReachable` for the unused-* rules, the narrower
 * `frameworkOwnsName` for `naming`) serves all three rules that ask the question — `naming`,
 * `unused-private` and `unused-public-member`.
 *
 * The driver fixture is Godot-shaped rather than Unity-shaped ON PURPOSE. A Unity callback is
 * PascalCase (`Start`), and the built-in Method normalizer is `stripUnderscorePrefix`, which derives
 * nothing from it — so a Unity fixture would be spared by an accident of the normalizer and could
 * not tell the gate from its absence. Godot's `_ready` strips to a conforming `ready`, so the rename
 * genuinely fires without the contract; both arms of that are asserted in ONE test.
 *
 * The engine root is declared IN the fixture scope because the RENAME needs it: the correction is
 * gated on `SymbolIndex.typeProvablyLacksMember`, which cannot clear a closure through a root it
 * cannot see. On a tree where the root is an out-of-scope extern the rename is already refused —
 * for a reason that has nothing to do with the framework, which is exactly the luck this seam
 * replaces.
 */
@:nullSafety(Strict) class FrameworkContractTest extends Test {

	/** The file the driver lives in — every assertion filters findings to it. */
	private static inline final DRIVER_FILE: String = 'game/Player.hx';

	/** The engine base class, declared in scope so the supertype closure and the rename gate are both provable. */
	private static inline final ROOT_SRC: String = 'class Node {\n\tpublic function new():Void {}\n}';

	/** A driver whose lifecycle callback the engine calls by that exact name, and whose spelling the built-in normalizer CAN correct. */
	private static inline final DRIVER_SRC: String = 'class Player extends Node {\n\n\tprivate var _hp:Int = 100;\n\n'
		+ '\tpublic function new():Void {\n\t\tsuper();\n\t}\n\n\tprivate function _ready():Void {\n\t\t_hp = 100;\n\t}\n\n}';

	/** The contract that owns `_ready`. */
	private static inline final GODOT_CONFIG: String = '{"frameworks":[{"root":"Node","names":["_ready","_process"]}]}';

	/** A second project's roster, used to show a declared roster does not displace the built-in one. */
	private static inline final UNITY_CONFIG: String = '{"frameworks":[{"root":"MonoBehaviour","names":["Start","Update"]}]}';

	/** The Unity engine base, in scope for the same reason `ROOT_SRC` is. */
	private static inline final UNITY_ROOT_SRC: String = 'class MonoBehaviour {\n\tpublic function new():Void {}\n}';

	// --- the discriminating pair ---

	/**
	 * Both arms in ONE test, so neither can pass alone: with no contract declared the `naming` autofix
	 * REWRITES the callback (`_ready` -> `ready`, which typechecks and which the engine then never
	 * calls); with the contract declared the finding does not exist at all.
	 */
	public function testDeclaredContractSuppressesTheCallbackRename(): Void {
		final files: Array<{ file: String, source: String }> = godotFixture();
		final plain: Naming = new Naming();
		// An explicit empty config, not an absent resolver: with none the check falls through to
		// `LintConfig.discover`, which walks up from a fixture path that exists nowhere and lands on
		// whatever `apqlint.json` the suite's cwd sits under — a real file deciding a unit assertion.
		plain.setConfigResolver(_ -> LintConfig.parse('{}'));
		final open: Array<Violation> = plain.run(files, new HaxeQueryPlugin()).filter(v -> v.file == DRIVER_FILE);
		Assert.equals(1, open.length, 'without a contract the callback is reported');
		if (open.length != 1) return;
		final index: SymbolIndex = SymbolIndex.build(files, new HaxeQueryPlugin());
		final edits: Array<{ span: Span, text: String }> = plain.fix(DRIVER_SRC, open, new HaxeQueryPlugin(), index);
		switch RefactorSupport.canonicalize(DRIVER_SRC, edits, true, new HaxeQueryPlugin()) {
			case Ok(text):
				Assert.isTrue(text.indexOf('function ready():Void') >= 0, 'without a contract the callback IS renamed');
				Assert.isTrue(text.indexOf('_ready') == -1, 'the old spelling is gone');
			case Err(message):
				Assert.fail('fix canonicalize Err: $message');
		}
		final guarded: Naming = new Naming();
		guarded.setConfigResolver(_ -> LintConfig.parse(GODOT_CONFIG));
		Assert.equals(0, guarded.run(files, new HaxeQueryPlugin()).filter(v -> v.file == DRIVER_FILE).length);
	}

	// --- each half of the contract is load-bearing ---

	/** The ROOT half: a contract rooted at a type the driver does not extend nominates nothing. */
	public function testAContractRootedElsewhereDoesNotSuppress(): Void {
		Assert.equals(1, namingFindings('{"frameworks":[{"root":"Sprite","names":["_ready"]}]}'));
	}

	/** The NAME half: a contract naming a sibling callback leaves this one reported. */
	public function testAContractNamingAnotherCallbackDoesNotSuppress(): Void {
		Assert.equals(1, namingFindings('{"frameworks":[{"root":"Node","names":["_process"]}]}'));
	}

	/**
	 * A PREFIX contract always REACHES, and owns the NAME only when a rename would DESTROY the fragment
	 * it claims — the one place the two seam questions genuinely differ, and the reason they are two
	 * methods. Both directions on one support instance, so neither can pass alone: `_r` cannot survive
	 * `stripUnderscorePrefix` (`_ready` corrects to `ready`, which Godot then never calls), while `ready`
	 * is a fragment every normalizer preserves, so the spelling after it stays the project's to choose —
	 * which is what leaves utest's `test_snake` to `testSnake` reportable.
	 */
	public function testAPrefixOwnsTheNameOnlyWhenARenameWouldDestroyIt(): Void {
		final support: HaxeNamingSupport = new HaxeNamingSupport();
		final index: SymbolIndex = SymbolIndex.build(godotFixture(), new HaxeQueryPlugin());
		final destroyed: Array<FrameworkContract> = [{ root: 'Node', names: [], prefixes: ['_r'] }];
		Assert.isTrue(support.frameworkReachable(driverDecl('_ready'), () -> index, destroyed));
		Assert.isTrue(support.frameworkOwnsName(driverDecl('_ready'), () -> index, destroyed), 'a `_` fragment survives no rename');
		final kept: Array<FrameworkContract> = [{ root: 'Node', names: [], prefixes: ['ready'] }];
		Assert.isTrue(support.frameworkReachable(driverDecl('readyState'), () -> index, kept));
		Assert.isFalse(support.frameworkOwnsName(driverDecl('readyState'), () -> index, kept), 'a lowercase fragment survives one');
	}

	/**
	 * The end-to-end half of the same split: the `_re` claim silences BOTH rules on the driver, because
	 * the only correction the built-in Method normalizer derives for `_ready` is the one that drops the
	 * claimed fragment. Without the claim the finding is there, so the arms discriminate.
	 */
	public function testAPrefixNoRenameCanKeepSuppressesTheCallbackToo(): Void {
		final config: String = '{"frameworks":[{"root":"Node","prefixes":["_re"]}]}';
		Assert.equals(1, namingFindings('{}'), 'without a claim the callback is reported');
		Assert.equals(0, namingFindings(config), 'a prefix no rename can keep owns the spelling');
		Assert.equals(1, unusedPrivateFindings('{}'), 'the callback is referenced nowhere');
		Assert.equals(0, unusedPrivateFindings(config), 'the same prefix claim spares it from unused-private');
	}

	/** Naming a FIELD does not suppress it: the predicate nominates methods only, so a roster cannot silence a field report. */
	public function testAContractNamingAFieldNominatesNothing(): Void {
		final src: String = 'class Player extends Node {\n\tprivate var badField:Int = 0;\n}';
		final files: Array<{ file: String, source: String }> = [
			{ file: 'godot/Node.hx', source: ROOT_SRC },
			{ file: DRIVER_FILE, source: src }
		];
		final check: Naming = new Naming();
		check.setConfigResolver(_ -> LintConfig.parse('{"frameworks":[{"root":"Node","names":["badField"]}]}'));
		Assert.equals(1, check.run(files, new HaxeQueryPlugin()).filter(v -> v.file == DRIVER_FILE).length);
	}

	// --- the other two consumers read the same roster ---

	/** `unused-private` honours a declared contract: a driver's private callback is not dead weight. */
	public function testUnusedPrivateHonoursADeclaredContract(): Void {
		final files: Array<{ file: String, source: String }> = unityFixture('private');
		Assert.equals(1, unconfigured().run(files, new HaxeQueryPlugin()).filter(v -> v.file == DRIVER_FILE).length);
		final guarded: UnusedPrivate = new UnusedPrivate();
		guarded.setConfigResolver(_ -> LintConfig.parse(UNITY_CONFIG));
		Assert.equals(0, guarded.run(files, new HaxeQueryPlugin()).filter(v -> v.file == DRIVER_FILE).length);
	}

	/** `unused-public-member` honours the same roster — one question, three consumers, one answer. */
	public function testUnusedPublicMemberHonoursADeclaredContract(): Void {
		final files: Array<{ file: String, source: String }> = unityFixture('public');
		final plain: UnusedPublicMember = new UnusedPublicMember();
		plain.setConfigResolver(_ -> LintConfig.parse('{}'));
		Assert.equals(1, plain.run(files, new HaxeQueryPlugin()).filter(v -> v.file == DRIVER_FILE).length);
		final guarded: UnusedPublicMember = new UnusedPublicMember();
		guarded.setConfigResolver(_ -> LintConfig.parse(UNITY_CONFIG));
		Assert.equals(0, guarded.run(files, new HaxeQueryPlugin()).filter(v -> v.file == DRIVER_FILE).length);
	}

	// --- the built-in framework is a default value, not a code path ---

	/** A declared roster ADDS to the grammar's own framework rather than replacing it: declaring Unity does not switch utest off. */
	public function testADeclaredRosterDoesNotDisplaceTheBuiltInFramework(): Void {
		final files: Array<{ file: String, source: String }> = [
			{ file: 'unit/CTest.hx', source: 'class C extends Test {\n\tprivate function testX():Void {}\n}' }
		];
		Assert.equals(0, unconfigured().run(files, new HaxeQueryPlugin()).length);
		final guarded: UnusedPrivate = new UnusedPrivate();
		guarded.setConfigResolver(_ -> LintConfig.parse(UNITY_CONFIG));
		Assert.equals(0, guarded.run(files, new HaxeQueryPlugin()).length);
	}

	// --- the seam itself ---

	/** An unprovable closure is not a contract: the name half alone must not nominate, and a null index is unprovable. */
	public function testAnUnprovableSupertypeClosureAnswersFalse(): Void {
		final support: HaxeNamingSupport = new HaxeNamingSupport();
		final decl: NamedDecl = {
			span: null,
			name: '_ready',
			category: NamingCategory.Method,
			mods: [],
			enclosingType: 'Player'
		};
		final contracts: Array<FrameworkContract> = [{ root: 'Node', names: ['_ready'], prefixes: [] }];
		Assert.isFalse(support.frameworkReachable(decl, () -> null, contracts));
		final index: SymbolIndex = SymbolIndex.build(godotFixture(), new HaxeQueryPlugin());
		Assert.isTrue(support.frameworkReachable(decl, () -> index, contracts));
	}

	// --- the config mapping ---

	/** `apqlint.json`'s `frameworks` maps onto the neutral contract; a half-stated entry is dropped, not half-applied. */
	public function testFrameworksKeyMapsAndDropsHalfStatedEntries(): Void {
		final stated: LintConfig = LintConfig.parse(
			'{"frameworks":[{"root":"MonoBehaviour","names":["Start","Update"],"prefixes":["On"]}]}'
		);
		final full: Array<FrameworkContract> = stated.frameworks();
		Assert.equals(1, full.length);
		if (full.length != 1) return;
		Assert.equals('MonoBehaviour', full[0].root);
		Assert.equals('Start,Update', full[0].names.join(','));
		Assert.equals('On', full[0].prefixes.join(','));
		Assert.equals(0, stated.drops().length, 'a well-stated roster leaves no diagnostic');
		final halfStated: LintConfig = LintConfig.parse(
			'{"frameworks":[{"names":["Start"]},{"root":"X"},"X",{"root":"Y","prefixes":[""]}]}'
		);
		Assert.equals(0, halfStated.frameworks().length, 'every half-stated entry is dropped');
		final expected: Array<String> = [
			'frameworks[0] declares no "root" — dropped',
			'frameworks[1] ("X") declares neither "names" nor "prefixes" — dropped',
			'frameworks[2] is not an object — dropped',
			'frameworks[3] ("Y") declares neither "names" nor "prefixes" — dropped'
		];
		Assert.equals(expected.join('\n'), halfStated.drops().join('\n'), 'each drop names its entry and its reason');
		Assert.equals(0, LintConfig.parse('{}').frameworks().length, 'the absent key is an empty roster');
		Assert.equals(0, LintConfig.parse('{}').drops().length, 'and leaves no diagnostic');
	}

	// --- fixtures ---

	/** The Godot-shaped driver plus its in-scope engine root. */
	private function godotFixture(): Array<{ file: String, source: String }> {
		return [
			{ file: 'godot/Node.hx', source: ROOT_SRC },
			{ file: DRIVER_FILE, source: DRIVER_SRC }
		];
	}

	/** A Unity-shaped driver whose `Start` callback carries `visibility`, plus its in-scope engine root. */
	private function unityFixture(visibility: String): Array<{ file: String, source: String }> {
		return [
			{ file: 'unityengine/MonoBehaviour.hx', source: UNITY_ROOT_SRC },
			{ file: DRIVER_FILE, source: 'class Player extends MonoBehaviour {\n\t$visibility function Start():Void {}\n}' }
		];
	}

	/**
	 * An `unused-private` check reading an EXPLICIT empty config, which is not the same as one with
	 * no resolver: with none it falls through to `LintConfig.discover`, which walks up from a fixture
	 * path that exists nowhere and lands on whatever `apqlint.json` the suite's cwd sits under — a
	 * real file on disk deciding a unit assertion.
	 */
	private function unconfigured(): UnusedPrivate {
		final check: UnusedPrivate = new UnusedPrivate();
		check.setConfigResolver(_ -> LintConfig.parse('{}'));
		return check;
	}

	/** A driver-owned method declaration named `name` — the seam's input, with no span because no rule reads one here. */
	private function driverDecl(name: String): NamedDecl {
		return {
			span: null,
			name: name,
			category: NamingCategory.Method,
			mods: [],
			enclosingType: 'Player'
		};
	}

	/** The `naming` findings the Godot driver keeps under `config`. */
	private function namingFindings(config: String): Int {
		final check: Naming = new Naming();
		check.setConfigResolver(_ -> LintConfig.parse(config));
		return check.run(godotFixture(), new HaxeQueryPlugin()).filter(v -> v.file == DRIVER_FILE).length;
	}


	/**
	 * The `unused-private` findings the Godot driver keeps under `config` — `{}` for a project that declares no roster.
	 */
	private function unusedPrivateFindings(config: String): Int {
		final check: UnusedPrivate = new UnusedPrivate();
		check.setConfigResolver(_ -> LintConfig.parse(config));
		return check.run(godotFixture(), new HaxeQueryPlugin()).filter(v -> v.file == DRIVER_FILE).length;
	}

}
