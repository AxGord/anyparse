package unit.dev;

import dev.Census;
import dev.Census.CensusMode;
import devkit.TempDir;
import haxe.Exception;
import haxe.Json;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;
import utest.Test;

/**
 * `dev census` over synthetic parts: how a census literal is read, how a list differs from its registry, where a new
 * name goes, and the text a rewrite leaves — every line ending in a comma, so a union merge can append.
 */
@:nullSafety(Strict)
final class CensusTest extends Test {

	/** A part with a continued entry, a blank line a merge left, and a last entry without its comma. */
	private static inline final PART: String =
		"package p;\n\nfinal class P {\n\n\tpublic static final PINS: Array<String> = [\n\t\t'a',\n\t\t'b :: '\n\t\t\t+ 'c',\n\n\t\t'd'\n\t];\n\n}\n";

	/** What the fake runner prints for each `--list-*` flag. */
	private static final FAKE_REGISTRY: Map<String, Array<String>> = [
		'--list-classes' => ['a.A', 'b.B'],
		'--list-pins' => ['p1'],
		'--list-arms' => ['M-ONE :: x.Y#z :: force :: note'],
		'--list-deferred' => ['M-TWO :: x.Y#z']
	];

	public function testAnEntryContinuedOnAPlusLineIsOneValue(): Void {
		Assert.same(['a', 'b :: c', 'd'], values(Census.entries(PART, 'PINS')));
	}

	public function testAPartWithoutTheLiteralHasNoEntries(): Void {
		Assert.isNull(Census.entries(PART, 'ARMS'));
	}

	public function testALiteralIsUnescaped(): Void {
		final text: String = "\tpublic static final PINS: Array<String> = [\n\t\t'it\\'s $$1 \\\\',\n\t];\n";
		Assert.same(['it\'s $1 \\'], values(Census.entries(text, 'PINS')));
	}

	public function testAnInterpolationIsRefused(): Void {
		Assert.raises(Census.entries.bind("\tstatic final PINS: Array<String> = [\n\t\t'$x',\n\t];\n", 'PINS'), Exception);
	}

	@:pin('control')
	@:killer('M-CENSUS-ORDER-BLIND')
	public function testAReorderIsADifference(): Void {
		final delta: ListDelta = Census.delta(['a', 'b'], ['b', 'a']);
		Assert.isFalse(delta.same, 'the parts must concatenate to the registry in its order');
		Assert.same([], delta.added.concat(delta.removed));
	}

	public function testTheNamesOnlyOneSideHoldsAreTheDelta(): Void {
		final delta: ListDelta = Census.delta(['a', 'b', 'x'], ['a', 'c', 'b']);
		Assert.same(['c'], delta.added);
		Assert.same(['x'], delta.removed);
	}

	public function testANewNameJoinsThePartOfItsPredecessor(): Void {
		final parts: Array<Array<CensusEntry>> = [[entry('a'), entry('b')], [entry('d')]];
		final placed: Array<Array<CensusEntry>> = Census.assign(parts, ['a', 'b', 'c', 'd', 'e']);
		Assert.same([['a', 'b', 'c'], ['d', 'e']], [for (part in placed) values(part)]);
	}

	public function testARewriteKeepsAKeptEntrysSourceAndEndsEveryEntryWithAComma(): Void {
		final kept: Array<CensusEntry> = Census.entries(PART, 'PINS') ?? [];
		final text: String = Census.rewrite(PART, 'PINS', kept.concat([{ value: 'e', lines: Census.render('e') }]));
		Assert.equals(
			"package p;\n\nfinal class P {\n\n\tpublic static final PINS: Array<String> = [\n\t\t'a',\n\t\t'b :: '\n\t\t\t+ 'c',\n"
			+ "\t\t'd',\n\t\t'e',\n\t];\n\n}\n",
			text
		);
	}

	public function testALongEntryIsCutAfterItsLastSeparatorThatFits(): Void {
		final head: String = 'unit.x.SomeTest#test' + [for (_ in 0...90) 'A'].join('') + ' :: control :: ';
		final lines: Array<String> = Census.render('${head}M-ONE,M-TWO');
		Assert.same(['\t\t\'$head\'', '\t\t\t+ \'M-ONE,M-TWO\','], lines);
	}

	@:pin('control')
	@:killer('M-CENSUS-ORDER-ONLY-WRITES-ANY-SET')
	public function testOrderOnlyRefusesANameTheRegistryLacksAndWritesNothing(): Void {
		TempDir.with(dir -> {
			final declared: Map<String, Array<String>> = inSync();
			declared['test/unit/census/PinsCheckAToO.hx'] = ['p1', 'p2'];
			final run: CensusRun = fakeRun(dir, declared, CensusMode.OrderOnly);
			Assert.isFalse(run.ok, 'a merge that lost or added a name is not repaired by putting the census in order');
			Assert.same([], run.written);
			Assert.equals(part('PINS', ['p1', 'p2']), File.getContent(dir.file('test/unit/census/PinsCheckAToO.hx')));
		});
	}

	public function testOrderOnlyPutsAPermutationBackInTheRegistrysOrder(): Void {
		TempDir.with(dir -> {
			final declared: Map<String, Array<String>> = inSync();
			declared['test/unit/census/RegisteredClasses.hx'] = ['b.B', 'a.A'];
			final run: CensusRun = fakeRun(dir, declared, CensusMode.OrderOnly);
			Assert.isTrue(run.ok);
			Assert.same(['test/unit/census/RegisteredClasses.hx'], run.written);
			Assert.equals(part('REGISTERED_CLASSES', ['a.A', 'b.B']), File.getContent(dir.file('test/unit/census/RegisteredClasses.hx')));
		});
	}

	private static function entry(value: String): CensusEntry {
		return { value: value, lines: Census.render(value) };
	}

	private static function values(entries: Null<Array<CensusEntry>>): Array<String> {
		return entries == null ? [] : [for (e in entries) e.value];
	}

	/** Every census part of a tree whose lists agree with `FAKE_RUNNER`'s registries: one entry per list, in its first part. */
	private static function inSync(): Map<String, Array<String>> {
		final declared: Map<String, Array<String>> = [];
		for (list in Census.LISTS) {
			final names: Array<String> = FAKE_REGISTRY[list.listing] ?? [];
			for (i => file in list.parts) declared[file] = if (i > 0)
				[]
			else if (list.nameOnly)
				names.map(n -> n.split(' :: ')[0])
			else
				names;
		}
		return declared;
	}

	/** `Census.run` in `mode` over a tree in `dir` holding the parts `declared`, its registries printed by a fake runner. */
	private static function fakeRun(dir: TempDir, declared: Map<String, Array<String>>, mode: CensusMode): CensusRun {
		FileSystem.createDirectory(dir.file('test/unit/census'));
		for (list in Census.LISTS) for (file in list.parts) File.saveContent(dir.file(file), part(list.constant, declared[file] ?? []));
		final lines: Array<String> = [
			for (flag => names in FAKE_REGISTRY) '${Json.stringify(flag)}: ${Json.stringify(names.join('\n'))}'
		];
		File.saveContent(dir.file('fake.js'), 'console.log({${lines.join(', ')}}[process.argv[2]]);\n');
		return Census.run(dir.path, dir.file('fake.js'), mode, _ -> {});
	}

	/** A census part declaring `constant` as `names`, every entry ending in its comma. */
	private static function part(constant: String, names: Array<String>): String {
		final entries: String = [for (n in names) '\t\t\'$n\',\n'].join('');
		return '\tpublic static final $constant: Array<String> = [\n$entries\t];\n';
	}

}
