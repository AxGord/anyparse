package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.ConfigDisagreement;
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

	/** The roster nominating the callback of the same-simple-name collision fixture. */
	private static inline final COLLIDE_CONFIG: String = '{"frameworks":[{"root":"Base","names":["_ready"]}]}';

	/** Per-file configs for a scope spanning two roots: everything under `b/` nominates `Tick`, the rest `Start`. */
	private static final twoRootResolver: (String) -> LintConfig = path ->
		LintConfig.parse(
			path.indexOf('b/') == 0
				? '{"frameworks":[{"root":"Base","names":["Tick"]}]}'
				: '{"frameworks":[{"root":"Base","names":["Start"]}]}'
		);

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

	/**
	 * A wrong-TYPED value and an unknown key each name themselves — the silence one level below the
	 * half-stated entry above.
	 *
	 * The entry SURVIVES both, which is what kept them quiet: `"names": "Start"` leaves a contract
	 * claiming only its prefixes, a mis-spelled `"name"` leaves the same, and the roster that comes
	 * back reads like the one the project wrote. A wrong-typed `"root"` was worse than quiet — it fell
	 * through to the no-root drop, which then reported "declares no root" about an entry that declares
	 * one, sending the reader to fix a key that is already there.
	 */
	public function testAWrongTypedValueOrUnknownKeyNamesItself(): Void {
		final typed: LintConfig = LintConfig.parse('{"frameworks":[{"root":"Node","names":"_ready","prefixes":["on"]}]}');
		Assert.equals(1, typed.frameworks().length, 'the entry survives on the half it did state');
		Assert.equals('', typed.frameworks()[0].names.join(','), 'and claims no name at all');
		Assert.equals('frameworks[0] "names" is not an array of strings — ignored', typed.drops().join('\n'), 'which the run now says');
		final unknown: LintConfig = LintConfig.parse('{"frameworks":[{"root":"Node","name":["_ready"],"prefixes":["on"]}]}');
		Assert.equals(
			'frameworks[0] declares unknown key "name" — ignored', unknown.drops().join('\n'), 'a mis-spelled key is the same silence'
		);
		final rooted: LintConfig = LintConfig.parse('{"frameworks":[{"root":["Node"],"names":["_ready"]}]}');
		Assert.equals(
			'frameworks[0] "root" is not a string — ignored\nframeworks[0] declares no "root" — dropped', rooted.drops().join('\n'),
			'a wrong-typed root names the type error BEFORE the drop it causes'
		);
		final elements: LintConfig = LintConfig.parse('{"frameworks":[{"root":"Node","names":["_ready",7,null]}]}');
		Assert.equals('_ready', elements.frameworks()[0].names.join(','), 'the string elements still count');
		Assert.equals(
			'frameworks[0] "names" ignored 2 value(s) that are not strings', elements.drops().join('\n'),
			'and the ones that are not are counted rather than dropped in silence'
		);
	}

	/**
	 * A scope spanning two `apqlint.json` roots still applies the FIRST root's roster to every file —
	 * and now names the disagreement.
	 *
	 * The single resolution stays, for the reason `frameworksFor` gives: `unused-public-member` builds
	 * one whole-scope context before it sees a file, and a roster differing between two consumers would
	 * spare a member from one rule and delete it with its sibling. What was not deliberate is that the
	 * run said NOTHING about it — the observable half is asserted first, `Tick` being reported although
	 * its own root nominates it.
	 */
	@:access(anyparse.check.ConfigDisagreement)
	public function testATwoRootScopeAppliesTheFirstRosterAndNamesTheDisagreement(): Void {
		final files: Array<{ file: String, source: String }> = twoRootFixture();
		final roster: Array<FrameworkContract> = LintConfig.frameworksFor(twoRootResolver, files);
		Assert.equals(1, roster.length);
		if (roster.length != 1) return;
		Assert.equals('Start', roster[0].names.join(','), 'the first file resolves the roster for the whole scope');
		final check: UnusedPrivate = new UnusedPrivate();
		check.setConfigResolver(twoRootResolver);
		final reported: Array<Violation> = check.run(files, new HaxeQueryPlugin());
		Assert.equals(1, reported.length, 'the second root nominates Tick and gets no say');
		if (reported.length == 1) Assert.equals('b/B.hx', reported[0].file, 'and it is B, under the root that named Tick');
		final paths: Array<String> = [for (entry in files) entry.file];
		final message: Null<String> = ConfigDisagreement.rosterMessage(twoRootResolver, paths);
		Assert.notNull(message, 'a two-root scope with two rosters is a disagreement');
		if (message != null)
			Assert.equals(
				'apq: this scope spans apqlint.json roots that disagree about the framework roster — the one discovered for a/A.hx'
				+ ' applies to all 3 file(s), of which 1 file(s) sit under a root declaring one of 1 other value(s)\n',
				message
			);
		Assert.isNull(
			ConfigDisagreement.rosterMessage(_ -> LintConfig.parse(UNITY_CONFIG), paths), 'roots that agree are not a disagreement'
		);
		Assert.isNull(
			ConfigDisagreement.rosterMessage(twoRootResolver, ['a/A.hx']), 'and neither is a single-file scope, whatever its config says'
		);
		// The consumer reads a roster with `filter` / `exists`, so ORDER carries no meaning at
		// EITHER level; a signature that kept it would report two identical rosters as a
		// disagreement. Both levels in one fixture: the contracts are swapped AND `A`'s names are.
		Assert.isNull(
			ConfigDisagreement.rosterMessage(
				path ->
					LintConfig.parse(
						path == 'b/B.hx'
							? '{"frameworks":[{"root":"B","names":["z"]},{"root":"A","names":["y","x"]}]}'
							: '{"frameworks":[{"root":"A","names":["x","y"]},{"root":"B","names":["z"]}]}'
					),
				paths
			),
			'the same contracts, and the same names inside one, are the same roster whatever their order'
		);
	}

	/**
	 * Two files declaring the same SIMPLE type name no longer decide the carve-out by walk order.
	 *
	 * The supertype map behind `transitivelyExtends` is keyed by simple name (`extends utest.Test` is
	 * indexed as `Test`) and it used to keep the LAST declaration walked. A project holding a `Mid` of
	 * its own beside the framework's therefore answered "does Player's base reach the root" out of
	 * whichever file happened to come second — a verdict with no reason behind it, and on the wrong
	 * side of it a lifecycle callback is reported unused and offered for deletion.
	 *
	 * BOTH orders in one test, because either alone passes at base: the union is what makes the answer
	 * independent of the order, and reverting it flips exactly the arm whose twin comes last.
	 */
	public function testASimpleNameCollisionDoesNotDecideTheCarveOutByWalkOrder(): Void {
		final check: UnusedPrivate = new UnusedPrivate();
		check.setConfigResolver(_ -> LintConfig.parse(COLLIDE_CONFIG));
		Assert.equals(
			0, check.run(collisionFixture(true), new HaxeQueryPlugin()).length, 'spared when the non-extending twin is walked last'
		);
		Assert.equals(0, check.run(collisionFixture(false), new HaxeQueryPlugin()).length, 'and spared when the extending one is');
	}

	// --- fixtures ---

	/** Two drivers under two roots, plus the base both extend — the scope `frameworksFor` resolves once. */
	private function twoRootFixture(): Array<{ file: String, source: String }> {
		return [
			{ file: 'a/A.hx', source: 'class A extends Base {\n\tprivate function Start():Void {}\n}' },
			{ file: 'b/B.hx', source: 'class B extends Base {\n\tprivate function Tick():Void {}\n}' },
			{ file: 'base/Base.hx', source: 'class Base {\n\tpublic function new():Void {}\n}' }
		];
	}

	/**
	 * The engine base and the two same-named `Mid` types, ordered so `twinLast` decides which
	 * declaration the simple-name map used to keep. The driver's callback is nominated only through
	 * the extending one.
	 */
	private function collisionFixture(twinLast: Bool): Array<{ file: String, source: String }> {
		final extendingSrc: String = 'class Mid extends Base {\n\tpublic function new():Void {\n\t\tsuper();\n\t}\n}';
		final twinSrc: String = 'class Mid {\n\tpublic function new():Void {}\n}';
		return [
			{ file: 'engine/Base.hx', source: 'class Base {\n\tpublic function new():Void {}\n}' },
			{ file: twinLast ? 'engine/Mid.hx' : 'game/Mid.hx', source: twinLast ? extendingSrc : twinSrc },
			{ file: twinLast ? 'game/Mid.hx' : 'engine/Mid.hx', source: twinLast ? twinSrc : extendingSrc }
		].concat([
			{
				file: DRIVER_FILE,
				source: 'class Player extends Mid {\n\n\tpublic function new():Void {\n\t\tsuper();\n\t}\n\n'
				+ '\tprivate function _ready():Void {}\n\n}'
			}
		]);
	}

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
