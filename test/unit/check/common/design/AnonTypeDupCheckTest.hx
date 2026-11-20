package unit.check.common.design;

import anyparse.check.Check.CrossFileEdits;
import anyparse.check.LintConfig;
import anyparse.check.Severity;
import anyparse.check.SourceEntry;
import anyparse.check.common.design.AnonTypeDup;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CanonicalEdit;
import sys.io.File;
import unit.cli.CliFixture;

using StringTools;

/**
 * The `anon-type-dup` check: an anonymous structure TYPE written out three or
 * more times across the lint scope is flagged `Info` once, at its
 * scope-earliest occurrence. The typedef's NAME is intent a human supplies, so
 * the fix runs only for a structure the config names — and the rule is OFF by
 * default, like every new rule.
 *
 * The load-bearing property is that the grouping key is STRUCTURAL: two field
 * orders are the SAME Haxe type and must group, while two different field TYPES
 * under the same names must NOT — the second is only expressible because the
 * query tree now carries anon field types.
 */
class AnonTypeDupCheckTest extends Test {

	private static inline final SHAPE: String = 'class C { var a:{ xml:Xml, text:String }; }';
	private static inline final NAMED: String = '{ actions: Array<Array<Item>>, manager: Array<Array<Item>>, object: Item }';
	private static inline final CONFIG: String = '{"rules":{"anon-type-dup":{"enabled":true,"named":{"types.Receivers":'
		+ '["actions: Array<Array<Item>>","manager: Array<Array<Item>>","object: Item"]}}}}';

	public function testThreeOccurrencesFlaggedOnce(): Void {
		final vs: Array<Violation> = violations([SHAPE, SHAPE, SHAPE]);
		Assert.equals(1, vs.length);
		Assert.equals('anon-type-dup', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('a0.hx', vs[0].file);
		Assert.isTrue(vs[0].message.contains('written 3 times across 3 files'), vs[0].message);
	}

	public function testTwoOccurrencesBelowThreshold(): Void {
		Assert.equals(0, violations([SHAPE, SHAPE]).length);
	}

	/**
	 * The discriminating case for the whole slice: same field NAMES, different
	 * field TYPES. Before the anon field types reached the query tree these six
	 * occurrences were one group of six; they must be two groups of three.
	 */
	public function testDifferentFieldTypesDoNotGroup(): Void {
		final other: String = 'class C { var a:{ xml:Int, text:Int }; }';
		final vs: Array<Violation> = violations([SHAPE, SHAPE, other, other]);
		Assert.equals(0, vs.length, 'two occurrences each — neither group reaches the threshold');

		final six: Array<Violation> = violations([SHAPE, SHAPE, SHAPE, other, other, other]);
		Assert.equals(2, six.length, 'two DISTINCT shapes, each flagged once');
		Assert.isTrue(six[0].message.contains('{ xml:Xml, text:String }'), six[0].message);
		Assert.isTrue(six[1].message.contains('{ xml:Int, text:Int }'), six[1].message);
	}

	/** Field ORDER is not part of a Haxe structural type, so the two spellings are one group. */
	public function testFieldOrderIsNormalised(): Void {
		final reordered: String = 'class C { var a:{ text:String, xml:Xml }; }';
		final vs: Array<Violation> = violations([SHAPE, reordered, SHAPE]);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('written 3 times'), vs[0].message);
		// The message quotes the ANCHOR's own source spelling; normalisation is what
		// GROUPED the reordered occurrence with it, not what the report prints.
		Assert.isTrue(vs[0].message.contains('{ xml:Xml, text:String }'), vs[0].message);
	}

	/** Optionality IS part of the type — `?x:Int` and `x:Int` are different structures. */
	public function testOptionalFieldIsPartOfTheKey(): Void {
		final optional: String = 'class C { var a:{ ?xml:Xml, text:String }; }';
		Assert.equals(0, violations([SHAPE, SHAPE, optional]).length);
		final vs: Array<Violation> = violations([optional, optional, optional]);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('{ ?xml:Xml, text:String }'), vs[0].message);
	}

	/** A `typedef`'s own body is the naming TARGET, never one of the duplicates. */
	public function testTypedefBodyIsNotAnOccurrence(): Void {
		final decl: String = 'typedef T = { xml:Xml, text:String }';
		Assert.equals(0, violations([decl, decl, decl]).length);
		Assert.equals(0, violations([decl, SHAPE, SHAPE]).length, 'the two inline uses are still only two');
		Assert.equals(1, violations([decl, SHAPE, SHAPE, SHAPE]).length);
	}

	/** A single-field structure is below `minFields` — naming it would flood the report. */
	public function testSingleFieldStructureIgnored(): Void {
		final one: String = 'class C { var a:{ xml:Xml }; }';
		Assert.equals(0, violations([one, one, one]).length);
	}

	/**
	 * A structure carrying a member this rule cannot key structurally — a
	 * `> Base` extension, a class-notation `var` field — is skipped whole rather
	 * than keyed approximately, which would group two different types.
	 */
	public function testUnkeyableMembersSkipTheWholeStructure(): Void {
		final extend: String = 'typedef T = { > Base, xml:Xml, text:String }\nclass C { var a:{ > Base, xml:Xml, text:String }; }';
		Assert.equals(0, violations([extend, extend, extend]).length);
		final varForm: String = 'class C { var a:{ var xml:Xml; var text:String; }; }';
		Assert.equals(0, violations([varForm, varForm, varForm]).length);
	}

	/** Nested structures are reduced by the same function, so an inner shape difference splits the group. */
	public function testNestedStructureIsPartOfTheKey(): Void {
		final inner: String = 'class C { var a:{ p:{ q:Int }, r:Bool }; }';
		final innerB: String = 'class C { var a:{ p:{ q:String }, r:Bool }; }';
		Assert.equals(0, violations([inner, inner, innerB]).length);
		final vs: Array<Violation> = violations([inner, inner, inner]);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('{ p:{ q:Int }, r:Bool }'), vs[0].message);
	}

	/** A parameterised field type is rendered head-and-arguments, so two argument lists split. */
	public function testTypeArgumentsArePartOfTheKey(): Void {
		final ab: String = 'class C { var a:{ m:Map<A, B>, n:Int }; }';
		final ba: String = 'class C { var a:{ m:Map<B, A>, n:Int }; }';
		Assert.equals(0, violations([ab, ab, ba]).length);
		final vs: Array<Violation> = violations([ab, ab, ab]);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('{ m:Map<A, B>, n:Int }'), vs[0].message);
	}

	/**
	 * Grouping is CROSS-FILE by design: a shape spread over a package is exactly
	 * the one worth naming. The flip side, stated as a test so nobody reads a
	 * single-file zero as a gate refusing: three occurrences in ONE file report,
	 * and the same shape linted one file at a time reports nothing.
	 */
	public function testScopeDecidesTheCount(): Void {
		final threeInOne: String =
			'class C { var a:{ xml:Xml, text:String }; var b:{ xml:Xml, text:String }; var c:{ xml:Xml, text:String }; }';
		final vs: Array<Violation> = violations([threeInOne]);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('written 3 times in this file'), vs[0].message);
		Assert.equals(0, violations([SHAPE]).length, 'one occurrence per file, linted alone, is not a duplicate');
	}

	public function testRegisteredInBuiltinsAndOffByDefault(): Void {
		Assert.notNull(Linter.byId('anon-type-dup'));
		final files: Array<{ file: String, source: String }> = [ for (i in 0...3) { file: 'a$i.hx', source: SHAPE } ];
		final config: LintConfig = LintConfig.parse('{}');
		final off: Array<Violation> = Linter.run(files, new HaxeQueryPlugin(), null, _ -> config, true);
		Assert.equals(0, off.filter(v -> v.rule == 'anon-type-dup').length, 'a new rule is OFF until a project opts in');
		final on: LintConfig = LintConfig.parse('{"rules": {"anon-type-dup": {"enabled": true}}}');
		final reported: Array<Violation> = Linter.run(files, new HaxeQueryPlugin(), null, _ -> on, true);
		Assert.equals(1, reported.filter(v -> v.rule == 'anon-type-dup').length, 'and ON once the project opts in');
	}

	/**
	 * The message quotes SOURCE, so a nested generic reads as written. The
	 * structural key flattens it (`Array`, `Array`, `InteractiveObject`), which
	 * would spell the nonexistent `Array<Array, InteractiveObject>` if the report
	 * rendered the key.
	 */
	public function testNestedGenericIsQuotedFromSource(): Void {
		final nested: String = 'class C { var a:{\n\tactions:Array<Array<Obj>>,\n\tobject:Obj\n}; }';
		final vs: Array<Violation> = violations([nested, nested, nested]);
		Assert.equals(1, vs.length);
		Assert.isTrue(vs[0].message.contains('{ actions:Array<Array<Obj>>, object:Obj }'), vs[0].message);
	}

	public function testSkipParseNoCrash(): Void {
		Assert.equals(0, violations(['class Bad { function f() { ']).length);
	}

	public function testMessageIdentityMasksBothTallies(): Void {
		// THE 1-TO-32 AMPLIFIER, closed. Both numbers in this message are PROJECT-WIDE
		// populations, so one new anonymous structure anywhere re-keyed every finding the rule
		// had. Pinned against messages `run` produced, as `Check.VolatileMessage` requires.
		final check: AnonTypeDup = new AnonTypeDup();
		final three: String = CheckFixture.violationsIn(check, [ for (i in 0...3) { file: 'a$i.hx', source: SHAPE } ])[0].message;
		final four: String = CheckFixture.violationsIn(check, [ for (i in 0...4) { file: 'a$i.hx', source: SHAPE } ])[0].message;
		Assert.isTrue(three.contains('written 3 times across 3 files'), three);
		Assert.notEquals(three, four);
		final identity: String = check.messageIdentity(three);
		Assert.isTrue(identity.contains('written # times across # files'), identity);
		Assert.equals(identity, check.messageIdentity(four));
		Assert.equals(identity, check.messageIdentity(identity));
	}

	/**
	 * Two config chains: each file's shapes are held to its own `minOccurrences`, whichever file the run lists first.
	 */
	@:pin('control')
	@:killer('M-ANON-FIRST-FILE-CONFIG')
	public function testEachFileHeldToItsOwnChainThreshold(): Void {
		final low: LintConfig = LintConfig.parse('{"rules":{"anon-type-dup":{"enabled":true,"minOccurrences":2,"minFields":2}}}');
		final high: LintConfig = LintConfig.parse('{"rules":{"anon-type-dup":{"enabled":true,"minOccurrences":50,"minFields":2}}}');
		final x: { file: String, source: String } = {
			file: 'x/X.hx',
			source: 'class X { static var a:{p:Int, q:Int}; static var b:{p:Int, q:Int}; }'
		};
		final y: { file: String, source: String } = {
			file: 'y/Y.hx',
			source: 'class Y { static var a:{r:Int, s:Int}; static var b:{r:Int, s:Int}; }'
		};
		for (files in [[x, y], [y, x]]) {
			final check: AnonTypeDup = new AnonTypeDup();
			check.setConfigResolver(f -> f.startsWith('x/') ? low : high);
			Assert.same(['x/X.hx'], CheckFixture.violationsIn(check, files).map(v -> v.file));
		}
	}

	/**
	 * A group whose earliest occurrence sits in a file that disables the rule is anchored at the first file that keeps
	 * it, so the finding survives in either file order.
	 */
	@:pin('control')
	@:killer('M-ANON-ANCHOR-UNGATED')
	public function testAGroupIsAnchoredWhereTheRuleIsEnabled(): Void {
		final on: LintConfig = LintConfig.parse('{"rules":{"anon-type-dup":{"enabled":true,"minOccurrences":3}}}');
		final off: LintConfig = LintConfig.parse('{"rules":{"anon-type-dup":{"enabled":false,"minOccurrences":3}}}');
		final x: { file: String, source: String } = {
			file: 'x/X.hx',
			source: 'class X { static var a:{p:Int, q:Int}; static var b:{p:Int, q:Int}; }'
		};
		final y: { file: String, source: String } = {
			file: 'y/Y.hx',
			source: 'class Y { static var a:{p:Int, q:Int}; static var b:{p:Int, q:Int}; }'
		};
		for (files in [[x, y], [y, x]]) {
			final found: Array<Violation> = Linter.run(
				files, new HaxeQueryPlugin(), [new AnonTypeDup()], f -> f.startsWith('x/') ? on : off, true
			);
			Assert.same(['x/X.hx'], found.map(v -> v.file));
		}
	}

	/** A structure the config names is created as its own module and every occurrence, in every file, becomes that type. */
	@:pin('control')
	@:killer('M-ANON-NO-PLAN')
	public function testANamedStructureIsExtractedAcrossFiles(): Void {
		final files: Array<SourceEntry> = project();
		final groups: Array<Array<CrossFileEdits>> = fixGroups(files, CONFIG);
		Assert.equals(1, groups.length);
		Assert.same(['src/types/Receivers.hx', 'src/app/A.hx', 'src/app/B.hx'], groups[0].map(s -> s.file));
		final after: Map<String, String> = applied(files, groups[0]);
		final created: String = after['src/types/Receivers.hx'] ?? '';
		Assert.isTrue(
			created.contains('package types;') && created.contains('typedef Receivers') && created.contains('import lib.Item;'), created
		);
		for (file in ['src/app/A.hx', 'src/app/B.hx']) {
			final text: String = after[file] ?? '';
			Assert.isFalse(text.contains('actions:'), text);
			Assert.isTrue(text.contains('import types.Receivers;') && text.contains(': Receivers'), text);
		}
		Assert.equals(2, (after['src/app/A.hx'] ?? '').split(': Receivers').length - 1);
		Assert.equals(
			0,
			fixGroups(
				files.map(f -> { file: f.file, source: after[f.file] ?? f.source })
					.concat([{ file: 'src/types/Receivers.hx', source: created }]),
				CONFIG
			).length
		);
	}

	/** A structure differing in one optional field is a different type: it is not in the group and its file is untouched. */
	@:pin('guard')
	public function testADifferentOptionalFieldIsUntouched(): Void {
		final variant: String = '{ ?actions: Array<Array<Item>>, manager: Array<Array<Item>>, object: Item }';
		final other: Array<SourceEntry> = [
			{
				file: 'src/app/C.hx',
				source: 'package app;\n\nimport lib.Item;\n\nclass C {\n\tpublic function four(p: $variant): Void {}\n}\n'
			}
		];
		final files: Array<SourceEntry> = project(other);
		final groups: Array<Array<CrossFileEdits>> = fixGroups(files, CONFIG);
		Assert.equals(1, groups.length);
		Assert.isFalse(groups[0].map(s -> s.file).contains('src/app/C.hx'));
	}

	/** The written field order is part of the match: a reordered spelling of the same type stays as it is. */
	@:pin('control')
	@:killer('M-ANON-ORDER-LOOSE')
	public function testAReorderedStructureIsNotRewritten(): Void {
		final reordered: String = '{ object: Item, actions: Array<Array<Item>>, manager: Array<Array<Item>> }';
		final other: Array<SourceEntry> = [
			{
				file: 'src/app/C.hx',
				source: 'package app;\n\nimport lib.Item;\n\nclass C {\n\tpublic function four(p: $reordered): Void {}\n}\n'
			}
		];
		final groups: Array<Array<CrossFileEdits>> = fixGroups(project(other), CONFIG);
		Assert.equals(1, groups.length);
		Assert.isFalse(groups[0].map(s -> s.file).contains('src/app/C.hx'));
	}

	/** Without a name in the config the finding stays a report that says how to name the structure, and no fix is offered. */
	@:pin('control')
	@:killer('M-ANON-UNNAMED-FIXED')
	public function testWithoutANameThereIsNoFix(): Void {
		final files: Array<SourceEntry> = project();
		Assert.equals(0, fixGroups(files, null).length);
		final found: Array<Violation> = CheckFixture.violationsIn(new AnonTypeDup(), files);
		Assert.equals(1, found.length);
		Assert.isTrue(found[0].message.contains('named'), found[0].message);
	}

	/** A module already at the configured path is never overwritten: no group is offered. */
	@:pin('control')
	@:killer('M-ANON-EXISTING-TARGET')
	public function testAnExistingModuleIsNotOverwritten(): Void {
		final taken: Array<SourceEntry> = [
			{ file: 'src/types/Receivers.hx', source: 'package types;\n\nclass Receivers {}\n' }
		];
		Assert.equals(0, fixGroups(project(taken), CONFIG).length);
	}

	/** The per-file seam offers nothing: the structure's occurrences sit in many files and the typedef is new. */
	public function testThePerFileSeamHasNoEdits(): Void {
		final files: Array<SourceEntry> = [ for (i in 0...3) { file: 'a$i.hx', source: SHAPE } ];
		final check: AnonTypeDup = new AnonTypeDup();
		Assert.isTrue(CheckFixture.violationsIn(check, files).length > 0);
		for (f in files) Assert.equals(0, CheckFixture.fixRun(check, files, f.file).edits.length);
	}

	/**
	 * The real `lint --fix` path, where the run's resolution index cannot know the module the fix creates: every file still
	 * gets the short name and the import, and the new module carries the imports its fields need.
	 */
	@:pin('control')
	@:killer('M-ANON-PRINTER-HOST')
	public function testTheCliFixImportsTheNewTypeInEveryFile(): Void {
		final shape: String = '{actions:Array<Array<Item>>, manager:Array<Array<Item>>, object:Item}';
		final dir: String = CliFixture.writeTree('anon-type-dup-fix', [
			{ name: 'apq.json', source: CONFIG },
			{ name: 'src/lib/Item.hx', source: 'package lib;\n\nclass Item {}\n' },
			{
				name: 'src/app/A.hx',
				source: 'package app;\n\nimport lib.Item;\n\nclass A {\n\tpublic function one():$shape {\n\t\treturn null;\n\t}\n\n'
				+ '\tpublic function two(p:$shape):Void {}\n}\n'
			},
			{
				name: 'src/app/B.hx',
				source: 'package app;\n\nimport lib.Item;\n\nclass B {\n\tpublic function three(p:$shape):Void {}\n}\n'
			}
		]);
		CliFixture.always(CliFixture.removeDir.bind(dir), () -> {
			CliFixture.runIn(dir, ['lint', 'src', '--rule', 'anon-type-dup', '--all', '--fix']);
			final created: String = File.getContent('$dir/src/types/Receivers.hx');
			Assert.isTrue(created.contains('package types;') && created.contains('import lib.Item;'), created);
			for (name in ['A', 'B']) {
				final text: String = File.getContent('$dir/src/app/$name.hx');
				Assert.isTrue(
					text.contains('import types.Receivers;') && !text.contains('actions:') && !text.contains('types.Receivers:'), text
				);
			}
		});
	}

	/**
	 * A malformed `named` option reaches the run's notes, never dropped: the command says each distinct line once, and a session
	 * editing the key needs to be told what was ignored.
	 */
	@:pin('control')
	@:killer('M-ANON-NOTES-DROPPED')
	public function testAMalformedNamedEntryIsSaidThroughTheRunsNotes(): Void {
		final wrongEntry: String = '{"rules":{"anon-type-dup":{"enabled":true,"named":{"types.Receivers":["a: Int",5]}}}}';
		final wrongKey: String = '{"rules":{"anon-type-dup":{"enabled":true,"named":3}}}';
		Assert.same([
			'apq lint: anon-type-dup: "named" entry "types.Receivers" is not a non-empty list of field strings — ignored\n'
		], notesOf(wrongEntry));
		Assert.same(['apq lint: anon-type-dup: "named" is not an object — ignored\n'], notesOf(wrongKey));
		Assert.same([], notesOf(CONFIG));
	}

	/**
	 * The new module's imports come from the first occurrence: a type its package reaches without an import is found through the
	 * resolution index, and an occurrence inside the typedef's own package gets the short name with no import of it.
	 */
	@:pin('control')
	@:killer('M-ANON-IMPORT-INDEX-OFF')
	public function testAnImportIsResolvedThroughTheIndexAndTheOwnPackageNeedsNone(): Void {
		final shape: String = '{actions:Array<Array<Item>>, manager:Array<Array<Item>>, object:Item}';
		final files: Array<SourceEntry> = [
			{ file: 'src/app/Item.hx', source: 'package app;\n\nclass Item {}\n' },
			{
				file: 'src/app/A.hx',
				source: 'package app;\n\nclass A {\n\tpublic function one():$shape {\n\t\treturn null;\n\t}\n\n\tpublic function two(p:'
					+ '$shape):Void {}\n}\n'
			},
			{
				file: 'src/types/B.hx',
				source: 'package types;\n\nimport app.Item;\n\nclass B {\n\tpublic static function three(p:$shape):Void {}\n}\n'
			}
		];
		final groups: Array<Array<CrossFileEdits>> = fixGroups(files, CONFIG);
		Assert.equals(1, groups.length);
		final after: Map<String, String> = applied(files, groups[0]);
		final created: String = after['src/types/Receivers.hx'] ?? '';
		Assert.isTrue(created.contains('import app.Item;'), created);
		final own: String = after['src/types/B.hx'] ?? '';
		Assert.isTrue(own.contains(':Receivers') && !own.contains('import types.Receivers;') && !own.contains('actions:'), own);
		final other: String = after['src/app/A.hx'] ?? '';
		Assert.isTrue(other.contains('import types.Receivers;') && !other.contains('actions:'), other);
	}

	private function violations(sources: Array<String>): Array<Violation> {
		return CheckFixture.violationsIn(new AnonTypeDup(), [ for (i in 0...sources.length) { file: 'a$i.hx', source: sources[i] } ]);
	}

	/** The slices of the one fix group over `files` under `config`, or none when the rule offers no fix. */
	private function fixGroups(files: Array<SourceEntry>, config: Null<String>): Array<Array<CrossFileEdits>> {
		final check: AnonTypeDup = new AnonTypeDup();
		final resolve: (String) -> LintConfig = _ -> LintConfig.parse(config ?? '{"rules":{"anon-type-dup":{"enabled":true}}}');
		final plugin: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final found: Array<Violation> = CheckFixture.violationsIn(check, files, plugin, resolve);
		return check.crossFileFix(files, found, plugin, CheckFixture.index(files, plugin));
	}

	/** The notes a run over the three-occurrence project collects under `config`. */
	private function notesOf(config: String): Array<String> {
		final notes: Array<ConfigNote> = [];
		final found: Array<Violation> = Linter.run(
			project(), new HaxeQueryPlugin(), [new AnonTypeDup()], _ -> LintConfig.parse(config), false, null, notes
		);
		Assert.equals(1, found.length);
		final said: Array<String> = [];
		for (n in notes) if (!said.contains(n.message)) said.push(n.message);
		return said;
	}

	/** A project: the type the structure spells, two files using it (three occurrences) and a bystander with a different shape. */
	private static function project(?extra: Array<SourceEntry>): Array<SourceEntry> {
		final files: Array<SourceEntry> = [
			{ file: 'src/lib/Item.hx', source: 'package lib;\n\nclass Item {}\n' },
			{
				file: 'src/app/A.hx',
				source: 'package app;\n\nimport lib.Item;\n\nclass A {\n\tpublic function one(): $NAMED return null;\n'
					+ '\tpublic function two(p: $NAMED): Void {}\n}\n'
			},
			{
				file: 'src/app/B.hx',
				source: 'package app;\n\nimport lib.Item;\n\nclass B {\n\tpublic function three(p: $NAMED): Void {}\n}\n'
			}
		];
		return extra == null ? files : files.concat(extra);
	}

	/** `files` with the slices applied: a create adds its file, an edit list is spliced into the file's source. */
	private static function applied(files: Array<SourceEntry>, slices: Array<CrossFileEdits>): Map<String, String> {
		final out: Map<String, String> = [ for (f in files) f.file => f.source ];
		for (slice in slices) {
			final created: Null<String> = slice.create;
			out[slice.file] = created ?? CanonicalEdit.applyEdits(out[slice.file] ?? '', slice.edits);
		}
		return out;
	}

}
