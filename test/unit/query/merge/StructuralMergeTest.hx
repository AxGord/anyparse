package unit.query.merge;

import anyparse.grammar.json.JsonQueryPlugin;
import anyparse.query.GrammarPlugin;
import anyparse.query.cli.command.MergeFileCommand;
import anyparse.query.merge.KeyedMerge.LineMerge;
import anyparse.query.merge.KeyedMerge.MergeChoice;
import anyparse.query.merge.KeyedMerge.MergeConflict;
import anyparse.query.merge.StructuralMerge;

/**
 * `StructuralMerge` over three versions of a Haxe module and of a JSON registry: a file clean by lines takes the line
 * merge; what merges by key — imports, members and records both sides added, a change against the other side's silence, a
 * layout-only side, a body edited on different lines by each side — and what stays a conflict for a choice: one line both
 * sides changed, an edit against a removal, two replacements of one child; source with a conditional between members goes
 * to the line merge.
 */
@:nullSafety(Strict)
final class StructuralMergeTest extends Test {

	private static final HAXE: GrammarPlugin = new HaxeQueryPlugin();
	private static final JSON: GrammarPlugin = new JsonQueryPlugin();

	public function testImportsBothSidesAddedAreUnitedInTheirOrder(): Void {
		final base: String = module(['a.B', 'a.D'], [member('f', '1')]);
		final ours: String = module(['a.B', 'a.C', 'a.D'], [member('f', '1')]);
		final theirs: String = module(['a.A', 'a.B', 'a.D'], [member('f', '1')]);
		Assert.equals(module(['a.A', 'a.B', 'a.C', 'a.D'], [member('f', '1')]), mergedHaxe(base, ours, theirs));
	}

	@:pin('control')
	@:killer('M-KEYED-MERGE-NO-RECURSION')
	public function testMembersBothSidesAddedAtOnePlaceKeepOursFirst(): Void {
		final base: String = module([], [member('f', '1'), member('g', '2')]);
		final ours: String = module([], [member('f', '1'), member('h', '3'), member('g', '2')]);
		final theirs: String = module([], [member('f', '1'), member('k', '4'), member('g', '2')]);
		Assert.equals(module([], [member('f', '1'), member('h', '3'), member('k', '4'), member('g', '2')]), mergedHaxe(base, ours, theirs));
	}

	@:pin('control')
	@:killer('M-DECLARATION-TREE-SPACING-IS-CONTENT')
	public function testAMemberAddedAboveOneTheOtherSideEditedMerges(): Void {
		final base: String = module([], [member('f', '1'), member('g', '2')]);
		final ours: String = module([], [member('e', '0'), member('f', '1'), member('g', '2')]);
		final theirs: String = module([], [member('f', '11'), member('g', '2')]);
		Assert.equals(module([], [member('e', '0'), member('f', '11'), member('g', '2')]), mergedHaxe(base, ours, theirs));
	}

	@:pin('control')
	@:killer('M-KEYED-MERGE-THEIRS-LOST')
	public function testAMemberOnlyTheirsChangedTakesTheirs(): Void {
		final base: String = module([], [member('f', '1'), member('g', '2')]);
		final ours: String = module([], [member('f', '10'), member('g', '2')]);
		final theirs: String = module([], [member('f', '1'), member('g', '20')]);
		Assert.equals(module([], [member('f', '10'), member('g', '20')]), mergedHaxe(base, ours, theirs));
	}

	public function testOneLineBothSidesChangedIsAConflictBetweenMarkers(): Void {
		final base: String = module([], [member('f', '1'), member('g', '2')]);
		final ours: String = module([], [member('f', '1'), member('h', '5'), member('g', '3')]);
		final theirs: String = module([], [member('f', '1'), member('k', '6'), member('g', '4')]);
		switch merge(HAXE, base, ours, theirs, null, MergeFileCommand.linesMerged) {
			case Conflicted(text, conflicts):
				Assert.same([{ key: 'C.g', ours: 'changed', theirs: 'changed' }], plain(conflicts));
				Assert.isTrue(
					text.indexOf('<<<<<<< ours C.g') >= 0 && text.indexOf('return 3;') >= 0 && text.indexOf('return 4;') >= 0, text
				);
			case other:
				Assert.fail('expected a conflict, got $other');
		}
	}

	public function testAFileCleanByLinesTakesTheLineMerge(): Void {
		#if nodejs
		final base: String = module([], [traces('a', ['1', '2', '3', '4', '5'])]);
		final ours: String = module([], [traces('a', ['10', '2', '3', '4', '5'])]);
		final theirs: String = module([], [traces('a', ['1', '2', '3', '4', '50'])]);
		switch merge(HAXE, base, ours, theirs, null, MergeFileCommand.linesMerged) {
			case Merged(text, how):
				Assert.equals(module([], [traces('a', ['10', '2', '3', '4', '50'])]), text);
				Assert.same(['line merge'], how);
			case other:
				Assert.fail('expected the line merge, got $other');
		}
		#else
		Assert.pass('git needs the nodejs target');
		#end
	}

	@:pin('control')
	@:killer('M-KEYED-MERGE-NO-PLACE-LINE-MERGE')
	public function testEditsOnDifferentLinesOfOneBodyMergeByLinesBesideImportsBothAdded(): Void {
		#if nodejs
		final base: String = module(['a.B'], [traces('a', ['1', '2', '3', '4', '5'])]);
		final ours: String = module(['a.B', 'a.C'], [traces('a', ['10', '2', '3', '4', '5'])]);
		final theirs: String = module(['a.B', 'a.D'], [traces('a', ['1', '2', '3', '4', '50'])]);
		Assert.equals(
			module(['a.B', 'a.C', 'a.D'], [traces('a', ['10', '2', '3', '4', '50'])]),
			mergedText(merge(HAXE, base, ours, theirs, null, MergeFileCommand.linesMerged))
		);
		#else
		Assert.pass('git needs the nodejs target');
		#end
	}

	@:pin('control')
	@:killer('M-DECLARATION-TREE-CONDITIONAL-BLIND')
	public function testAConditionalBetweenMembersIsLeftToTheLineMerge(): Void {
		final base: String = canon('class C {\n\tfunction a():Void {}\n\n\t#if js\n\tfunction b():Void {}\n\t#end\n}\n');
		final ours: String = canon(
			'class C {\n\tfunction a():Void {}\n\n\t#if js\n\tfunction b():Void {}\n\t#end\n\n\tfunction d():Void {}\n}\n'
		);
		final theirs: String = canon(
			'class C {\n\tfunction a():Void {}\n\n\t#if js\n\tfunction b():Void {}\n\n\tfunction c():Void {}\n\t#end\n}\n'
		);
		Assert.isTrue(merge(HAXE, base, ours, theirs).match(Unreadable(_)));
	}

	@:pin('control')
	@:killer('M-KEYED-MERGE-REPLACEMENTS-UNITED')
	public function testTwoRenamesOfOneMemberAreAConflict(): Void {
		final base: String = module([], [member('a', '1')]);
		switch merge(HAXE, base, module([], [member('a1', '1')]), module([], [member('a2', '1')])) {
			case Conflicted(_, conflicts):
				Assert.same([{ key: 'C', ours: 'changed', theirs: 'changed' }], plain(conflicts));
			case other:
				Assert.fail('expected a conflict, got $other');
		}
	}

	@:pin('control')
	@:killer('M-KEYED-MERGE-RENAME-AGAINST-DELETE')
	public function testARenameAgainstADeletionIsAConflict(): Void {
		#if nodejs
		final base: String = module(['a.A'], [member('a', '1'), member('b', '2')]);
		final ours: String = module(['a.A', 'b.B'], [member('a1', '1'), member('b', '2')]);
		final theirs: String = module(['a.A', 'c.C'], [member('b', '2')]);
		switch merge(HAXE, base, ours, theirs, null, MergeFileCommand.linesMerged) {
			case Conflicted(_, conflicts):
				Assert.same([{ key: 'C', ours: 'changed', theirs: 'changed' }], plain(conflicts));
			case other:
				Assert.fail('expected a conflict, got $other');
		}
		#else
		Assert.pass('git needs the nodejs target');
		#end
	}

	public function testTwoReplacementsOfOneListValueAreAConflict(): Void {
		final base: String = canonJson('{\n\t"roots": ["src", "test"],\n\t"x": 1\n}\n');
		final ours: String = canonJson('{\n\t"roots": ["lib", "test"],\n\t"x": 1\n}\n');
		final theirs: String = canonJson('{\n\t"roots": ["source", "test"],\n\t"x": 1\n}\n');
		switch merge(JSON, base, ours, theirs) {
			case Conflicted(_, conflicts):
				Assert.same([{ key: 'roots', ours: 'changed', theirs: 'changed' }], plain(conflicts));
			case other:
				Assert.fail('expected a conflict, got $other');
		}
	}

	public function testAChoiceSettlesTheConflictingPlace(): Void {
		final base: String = module([], [member('f', '1'), member('g', '2')]);
		final ours: String = module([], [member('f', '5'), member('g', '3')]);
		final theirs: String = module([], [member('f', '1'), member('g', '4')]);
		Assert.equals(module([], [member('f', '5'), member('g', '4')]), mergedHaxe(base, ours, theirs, ['C.g' => Theirs]));
	}

	public function testAnEditAgainstARemovalIsAConflict(): Void {
		final base: String = module([], [member('f', '1'), member('g', '2')]);
		switch merge(HAXE, base, module([], [member('f', '1')]), module([], [member('f', '1'), member('g', '4')])) {
			case Conflicted(_, conflicts):
				Assert.same([{ key: 'C.g', ours: 'removed', theirs: 'changed' }], plain(conflicts));
			case other:
				Assert.fail('expected a conflict, got $other');
		}
	}

	public function testASideThatChangedOnlyLayoutYieldsToTheOther(): Void {
		final base: String = module([], [member('f', '1')]);
		final ours: String = module([], [member('f', '2')]);
		final theirs: String = 'package a;\nclass C {  public function f():Int { return 1; } }\n';
		Assert.equals(ours, mergedHaxe(base, ours, theirs));
	}

	public function testOursOutOfTheWritersFormIsLeftToTheLineMerge(): Void {
		final base: String = module([], [member('f', '1')]);
		final ours: String = 'package a;\nclass C {  public function f():Int { return 2; } }\n';
		Assert.isTrue(merge(HAXE, base, ours, module([], [member('f', '3')])).match(Unreadable(_)));
	}

	@:pin('control')
	@:killer('M-KEYED-MERGE-APPEND-ORDER')
	public function testRecordsAppendedOnBothSidesKeepOursFirst(): Void {
		Assert.equals(
			registry([arm('A', '1'), arm('X', '1'), arm('Y', '1')]),
			mergedJson(registry([arm('A', '1')]), registry([arm('A', '1'), arm('X', '1')]), registry([arm('A', '1'), arm('Y', '1')]))
		);
	}

	public function testARecordChangedOnOneSideWinsOverTheOthersSilence(): Void {
		final base: String = registry([arm('A', '1'), arm('B', '1')]);
		Assert.equals(
			registry([arm('A', '2'), arm('B', '2')]),
			mergedJson(base, registry([arm('A', '2'), arm('B', '1')]), registry([arm('A', '1'), arm('B', '2')]))
		);
	}

	public function testARecordRemovedOnOneSideStaysRemoved(): Void {
		final base: String = registry([arm('A', '1'), arm('B', '1')]);
		Assert.equals(
			registry([arm('A', '1'), arm('Y', '1')]),
			mergedJson(base, registry([arm('A', '1')]), registry([arm('A', '1'), arm('B', '1'), arm('Y', '1')]))
		);
	}

	public function testTheSameAppendOnBothSidesIsOneRecord(): Void {
		final both: String = registry([arm('A', '1'), arm('X', '1')]);
		Assert.equals(both, mergedJson(registry([arm('A', '1')]), both, both));
	}

	public function testTwoDifferentEditsOfOneRecordConflict(): Void {
		switch merge(JSON, registry([arm('A', '1')]), registry([arm('A', '2')]), registry([arm('A', '3')])) {
			case Conflicted(_, conflicts):
				Assert.same([{ key: 'arms["A"].note', ours: 'changed', theirs: 'changed' }], plain(conflicts));
			case other:
				Assert.fail('expected a conflict, got $other');
		}
	}

	private static function mergedHaxe(base: String, ours: String, theirs: String, ?choices: Map<String, MergeChoice>): String {
		return mergedText(merge(HAXE, base, ours, theirs, choices));
	}

	private static function mergedJson(base: String, ours: String, theirs: String): String {
		return mergedText(merge(JSON, base, ours, theirs));
	}

	private static function merge(
		plugin: GrammarPlugin, base: String, ours: String, theirs: String, ?choices: Map<String, MergeChoice>, ?lineMerge: LineMerge
	): MergeResult {
		final shape: MergeShape = plugin == JSON ? Records : Declarations;
		return StructuralMerge.merge(plugin, shape, base, ours, theirs, null, choices, lineMerge);
	}

	private static function mergedText(result: MergeResult): String {
		return switch result {
			case Merged(text, _): text;
			case other: 'not merged: $other';
		};
	}

	/** The conflicts as plain records, for `Assert.same`. */
	private static function plain(conflicts: Array<MergeConflict>): Array<{ key: String, ours: String, theirs: String }> {
		return [
			for (c in conflicts) { key: c.key, ours: (c.ours: String), theirs: (c.theirs: String) }
		];
	}

	/** Module `a.C` importing `imports` and holding `members`, as the writer emits it. */
	private static function module(imports: Array<String>, members: Array<String>): String {
		final header: String = imports.length == 0 ? '' : [for (i in imports) 'import $i;\n'].join('') + '\n';
		final source: String = 'package a;\n\n${header}class C {\n${members.join('\n')}}\n';
		return HAXE.writeRoundTrip(source, null) ?? source;
	}

	private static function member(name: String, value: String): String {
		return '\tpublic function $name():Int {\n\t\treturn $value;\n\t}\n';
	}

	/** A function `name` tracing each of `values` on its own line. */
	private static function traces(name: String, values: Array<String>): String {
		return '\tpublic function $name():Void {\n${[for (v in values) '\t\ttrace($v);\n'].join('')}\t}\n';
	}

	private static function canon(source: String): String {
		return HAXE.writeRoundTrip(source, null) ?? source;
	}

	private static function canonJson(source: String): String {
		return JSON.writeRoundTrip(source, null) ?? source;
	}

	/** A registry holding `records`, laid out as the real one is. */
	private static function registry(records: Array<String>): String {
		return '{\n\t"arms": [\n\t\t${records.join(',\n\t\t')}\n\t]\n}\n';
	}

	private static function arm(name: String, note: String): String {
		return '{ "name": "$name", "note": "$note" }';
	}

}
