package unit.query;

import anyparse.grammar.json.JValue;
import anyparse.grammar.json.JValueParser;
import anyparse.grammar.json.JValueTools;
import anyparse.grammar.json.JsonText;
import anyparse.query.CrossRename.CrossRenameResult;
import anyparse.query.CrossRenameMember;
import anyparse.query.MemberRegistryRename;
import anyparse.query.TypePathRegistries.MemberKeys;

using StringTools;

/**
 * `MemberRegistryRename`: a registry value follows what the rename's own edit set proved. A find follows the tokens it
 * located, a replace its paired find, a member value the edited declaration; anything else stays and what cannot be
 * mapped is named.
 */
final class MemberRegistryRenameTest extends Test {

	private static final LAYOUT: MemberKeys = {
		records: 'arms',
		name: 'name',
		type: 'type',
		member: 'method',
		kind: 'kind',
		defaultKind: 'FnMember',
		find: 'find',
		replace: 'replace',
		opaque: ['force']
	};
	private static final BASE: String = 'package p;\n\nclass Base {\n\tpublic function new() {}\n\n\tpublic function walk(): Int {\n'
		+ '\t\treturn 1;\n\t}\n\n\tpublic function other(o: Base): Int {\n\t\tfinal a: Int = 2;\n\t\tif (a > 1)\n'
		+ '\t\t\treturn walk();\n\t\treturn a + o.walk() + 7;\n\t}\n\n'
		+ '\t/** The label, not the walk method. */\n\tpublic function label(): String {\n\t\ttrace(\'walk\');\n'
		+ '\t\treturn \'walk\' + walk();\n\t}\n}\n';
	private static final SUB: String =
		'package p;\n\nclass Sub extends Base {\n\toverride public function walk(): Int {\n\t\treturn 2;\n\t}\n}\n';
	private static final CALLER: String =
		'package p;\n\nclass Caller {\n\tpublic static function run(b: Base): Int {\n\t\treturn b.walk();\n\t}\n}\n';
	private static final SHADOW: String = 'package p;\n\nclass Shadow {\n\tpublic function walk(): Int {\n\t\treturn 1;\n\t}\n\n'
		+ '\tpublic function local(o: Other): Int {\n\t\tfinal walk: Int = o.walk;\n\t\treturn walk;\n\t}\n}\n\n'
		+ 'class Other {\n\tpublic var walk: Int = 0;\n\n\tpublic function helper(): Int {\n\t\treturn walk;\n\t}\n\n'
		+ '\tpublic function aux(): Int {\n\t\treturn 7;\n\t}\n}\n';
	private static final SCOPE: Array<{ file: String, source: String }> = [
		{ file: 'src/p/Base.hx', source: BASE },
		{ file: 'src/p/Sub.hx', source: SUB },
		{ file: 'src/p/Caller.hx', source: CALLER },
		{ file: 'src/p/Shadow.hx', source: SHADOW }
	];

	public function testAMemberValueFollowsItsDeclarationAndItsOverride(): Void {
		final out: ArmsAfter = followBase([
			{ name: 'OWNER', type: 'p.Base', method: 'walk' },
			{
				name: 'OVERRIDE',
				type: 'p.Sub',
				method: 'walk',
				find: 'return 2;',
				replace: 'return 3;'
			},
			{ name: 'CALLER', type: 'p.Caller', method: 'run' },
			{ name: 'UNRELATED', type: 'p.Shadow', method: 'walk' },
			{
				name: 'OTHER-KIND',
				type: 'p.Base',
				kind: 'MetaCall',
				method: 'walk'
			}
		]);
		Assert.equals('step', out.arm('OWNER').method);
		Assert.equals('step', out.arm('OVERRIDE').method);
		Assert.equals('run', out.arm('CALLER').method);
		Assert.equals('walk', out.arm('UNRELATED').method);
		Assert.equals('walk', out.arm('OTHER-KIND').method);
		Assert.equals(0, out.notes.length);
	}

	public function testAFindFollowsTheTokensTheOpEditedAndNoOthers(): Void {
		final out: ArmsAfter = followBase([
			{
				name: 'FOREIGN',
				type: 'p.Caller',
				method: 'run',
				find: 'b.walk()',
				replace: 'b.walk() + 1'
			},
			{
				name: 'SHADOW',
				type: 'p.Shadow',
				method: 'local',
				find: 'final walk: Int = o.walk;',
				replace: 'final walk: Int = o.walk + 1;'
			},
			{
				name: 'STRING',
				type: 'p.Base',
				method: 'label',
				find: 'trace(\'walk\');',
				replace: 'trace(\'walk!\');'
			},
			{
				name: 'MIXED',
				type: 'p.Base',
				method: 'label',
				find: 'return \'walk\' + walk();',
				replace: 'return \'walk\' + walk() + 1;'
			},
			{
				name: 'DOC',
				type: 'p.Base',
				method: 'label',
				find: 'not the walk method',
				replace: 'not a walk method'
			}
		]);
		Assert.equals('b.step()', out.arm('FOREIGN').find);
		Assert.equals('b.step() + 1', out.arm('FOREIGN').replace);
		Assert.equals('final walk: Int = o.walk;', out.arm('SHADOW').find);
		Assert.equals('final walk: Int = o.walk + 1;', out.arm('SHADOW').replace);
		Assert.equals('trace(\'walk\');', out.arm('STRING').find);
		Assert.equals('return \'walk\' + step();', out.arm('MIXED').find);
		Assert.equals('return \'walk\' + step() + 1;', out.arm('MIXED').replace);
		Assert.equals('not the walk method', out.arm('DOC').find);
		Assert.equals(0, out.notes.length);
	}

	public function testASecondaryTypeIsReachedByItsModulePath(): Void {
		final out: ArmsAfter = follow('src/p/Shadow.hx', SHADOW, 'public var walk', 'count', [
			{
				name: 'FIELD',
				type: 'p.Shadow',
				kind: 'VarMember',
				method: 'walk'
			},
			{ name: 'FN', type: 'p.Shadow', method: 'walk' },
			{
				name: 'HELPER',
				type: 'p.Shadow',
				method: 'helper',
				find: 'return walk;',
				replace: 'return walk + 1;'
			},
			{
				name: 'LOCAL',
				type: 'p.Shadow',
				method: 'local',
				find: 'final walk: Int = o.walk;',
				replace: 'final walk: Int = o.walk + 1;'
			}
		]);
		Assert.equals('count', out.arm('FIELD').method);
		Assert.equals('walk', out.arm('FN').method);
		Assert.equals('return count;', out.arm('HELPER').find);
		Assert.equals('return count + 1;', out.arm('HELPER').replace);
		Assert.equals('final walk: Int = o.count;', out.arm('LOCAL').find);
		Assert.equals('final walk: Int = o.count + 1;', out.arm('LOCAL').replace);
	}

	public function testAnEscapedFindIsRewrittenOnItsRawBytes(): Void {
		final source: String = 'package p;\n\nclass Mod {\n\tpublic function n(): Int {\n\t\treturn 1;\n\t}\n\n'
			+ '\tpublic function user(): Int {\n\t\tfinal a: Int = 1;\n\t\treturn n() + a;\n\t}\n}\n';
		final arms: Array<ArmRow> = [
			{
				name: 'TAB',
				type: 'p.Mod',
				method: 'user',
				find: '\treturn n() + a;',
				replace: '\treturn n() + a + 1;'
			},
			{
				name: 'LINES',
				type: 'p.Mod',
				method: 'user',
				find: 'final a: Int = 1;\n\t\treturn n()',
				replace: 'final a: Int = 2;\n\t\treturn n()'
			}
		];
		final out: ArmsAfter = follow('src/p/Mod.hx', source, 'function n', 'count', arms);
		Assert.isTrue(out.text.contains('"\\treturn count() + a;"'), out.text);
		Assert.isTrue(out.text.contains('"final a: Int = 1;\\n\\t\\treturn count()"'), out.text);
		Assert.isFalse(out.text.contains('\\count'), out.text);
		Assert.equals('\treturn count() + a + 1;', out.arm('TAB').replace);
		Assert.equals('final a: Int = 2;\n\t\treturn count()', out.arm('LINES').replace);
	}

	public function testAListOfCutsFollowsPairByPair(): Void {
		final out: ArmsAfter = followBase([
			{
				name: 'LIST',
				type: 'p.Base',
				method: 'other',
				finds: ['return walk();', 'final a: Int = 2;'],
				replaces: ['return walk() + 1;', 'final a: Int = walk();']
			}
		]);
		Assert.same(['return step();', 'final a: Int = 2;'], out.arm('LIST').finds);
		Assert.same(['return step() + 1;', 'final a: Int = step();'], out.arm('LIST').replaces);
	}

	public function testADedentedFindKeepsItsOwnIndentation(): Void {
		final out: ArmsAfter = followBase([
			{
				name: 'DEDENTED',
				type: 'p.Base',
				method: 'other',
				find: 'if (a > 1)\n\treturn walk();',
				replace: 'if (a > 2)\n\treturn walk();'
			}
		]);
		Assert.equals('if (a > 1)\n\treturn step();', out.arm('DEDENTED').find);
		Assert.equals('if (a > 2)\n\treturn step();', out.arm('DEDENTED').replace);
		Assert.equals(0, out.notes.length);
	}

	public function testATokenOfTheMutationsOwnTakesTheVerdictTheFindAgreesOn(): Void {
		final out: ArmsAfter = followBase([
			{
				name: 'AGREE',
				type: 'p.Base',
				method: 'other',
				find: 'return walk();',
				replace: 'return 0 + walk() - walk();'
			},
			{
				name: 'REFUSED',
				type: 'p.Shadow',
				method: 'local',
				find: 'o.walk;',
				replace: 'walk + 1;'
			}
		]);
		Assert.equals('return 0 + step() - step();', out.arm('AGREE').replace);
		Assert.equals('walk + 1;', out.arm('REFUSED').replace);
		Assert.equals(0, out.notes.length);
	}

	public function testMixedVerdictsLeaveTheReplaceAndNameTheRecord(): Void {
		final out: ArmsAfter = followBase([
			{
				name: 'MIXED',
				type: 'p.Base',
				method: 'label',
				find: 'return \'walk\' + walk();',
				replace: 'walk() + 1;'
			}
		]);
		Assert.equals('return \'walk\' + step();', out.arm('MIXED').find);
		Assert.equals('walk() + 1;', out.arm('MIXED').replace);
		Assert.isTrue(
			out.notes.length == 1 && out.notes[0].startsWith('arm MIXED: ') && out.notes[0].endsWith('re-aim it'), out.notes.join('|')
		);
	}

	public function testAFindWithoutTheNameProvesOnlyAnOwnMemberOfTheRenamedType(): Void {
		final out: ArmsAfter = followBase([
			{
				name: 'BARE',
				type: 'p.Base',
				method: 'other',
				find: 'final a: Int = 2;',
				replace: 'final a: Int = walk();'
			},
			{
				name: 'SELF',
				type: 'p.Base',
				method: 'other',
				find: 'final a: Int = 2;',
				replace: 'final a: Int = this.walk();'
			},
			{
				name: 'QUALIFIED',
				type: 'p.Base',
				method: 'other',
				find: 'final a: Int = 2;',
				replace: 'final a: Int = o.walk();'
			}
		]);
		Assert.equals('final a: Int = step();', out.arm('BARE').replace);
		Assert.equals('final a: Int = this.step();', out.arm('SELF').replace);
		Assert.equals('final a: Int = o.walk();', out.arm('QUALIFIED').replace);
		Assert.isTrue(out.notes.length == 1 && out.notes[0].startsWith('arm QUALIFIED: '), out.notes.join('|'));
		final secondary: ArmsAfter = follow('src/p/Shadow.hx', SHADOW, 'public function walk', 'count', [
			{
				name: 'SIBLING',
				type: 'p.Shadow',
				method: 'aux',
				find: 'return 7;',
				replace: 'return walk;'
			}
		]);
		Assert.equals('return walk;', secondary.arm('SIBLING').replace);
		Assert.isTrue(secondary.notes.length == 1 && secondary.notes[0].startsWith('arm SIBLING: '), secondary.notes.join('|'));
	}

	public function testAFindCuttingARenamedTokenAtItsEdgeStaysAndIsNamed(): Void {
		final out: ArmsAfter = followBase([
			{
				name: 'EDGE',
				type: 'p.Caller',
				method: 'run',
				find: 'return b.wal',
				replace: 'return b.sta'
			}
		]);
		Assert.equals('return b.wal', out.arm('EDGE').find);
		Assert.isTrue(
			out.notes.length == 1 && out.notes[0].startsWith('arm EDGE: ') && out.notes[0].endsWith('re-aim it'), out.notes.join('|')
		);
	}

	public function testAFindTheRenameMadeAmbiguousIsNamed(): Void {
		final source: String = 'package p;\n\nclass Mod {\n\tpublic function walk(): Int {\n\t\treturn 1;\n\t}\n\n'
			+ '\tpublic function user(o: Far): Int {\n\t\treturn walk() + o.step();\n\t}\n}\n\nclass Far {\n'
			+ '\tpublic function step(): Int {\n\t\treturn 1;\n\t}\n}\n';
		final out: ArmsAfter = follow('src/p/Mod.hx', source, 'function walk', 'step', [
			{
				name: 'TWICE',
				type: 'p.Mod',
				method: 'user',
				find: 'walk()',
				replace: 'walk() + 1'
			}
		]);
		Assert.equals('step()', out.arm('TWICE').find);
		Assert.isTrue(
			out.notes.length == 1 && out.notes[0].startsWith('arm TWICE: ') && out.notes[0].contains('p.Mod#user'), out.notes.join('|')
		);
	}

	public function testAForceValueIsNeverRewrittenAndNamedOnAnyRecord(): Void {
		final out: ArmsAfter = followBase([
			{
				name: 'FORCED',
				type: 'p.Base',
				method: 'walk',
				force: 'walk() + 1'
			},
			{
				name: 'FAR',
				type: 'q.Far',
				method: 'x',
				force: 'walk'
			},
			{
				name: 'QUIET',
				type: 'q.Far',
				method: 'x',
				force: 'walker'
			}
		]);
		Assert.equals('step', out.arm('FORCED').method);
		Assert.equals('walk() + 1', out.arm('FORCED').force);
		Assert.equals(2, out.notes.length);
		Assert.isTrue(out.notes[0].startsWith('arm FORCED: its "force" value'), out.notes[0]);
		Assert.isTrue(out.notes[1].startsWith('arm FAR: '), out.notes[1]);
	}

	public function testARecordThatDoesNotApplyBeforeTheRenameStaysSilently(): Void {
		final out: ArmsAfter = followBase([
			{
				name: 'STALE',
				type: 'p.Base',
				method: 'other',
				find: 'walk() * 2',
				replace: 'walk() * 3'
			},
			{
				name: 'NO-MEMBER',
				type: 'p.Base',
				method: 'gone',
				find: 'walk()',
				replace: 'walk() + 1'
			},
			{
				name: 'BAD-ADDRESS',
				type: 'p.Base',
				kind: 'not a kind >',
				method: 'other',
				find: 'walk()',
				replace: 'walk() + 1'
			},
			{
				name: 'LENGTHS',
				type: 'p.Base',
				method: 'other',
				find: 'return walk();',
				replaces: ['a', 'b']
			}
		]);
		Assert.equals('walk() * 2', out.arm('STALE').find);
		Assert.equals('walk()', out.arm('NO-MEMBER').find);
		Assert.equals('walk()', out.arm('BAD-ADDRESS').find);
		Assert.equals('return step();', out.arm('LENGTHS').find);
		Assert.same(['a', 'b'], out.arm('LENGTHS').replaces);
		Assert.equals(0, out.notes.length);
	}

	public function testARecordOfAnUnchangedModuleIsNamedOnlyForAReceiverItsFindLacks(): Void {
		final out: ArmsAfter = followBase([
			{
				name: 'FOREIGN',
				type: 'p.Quiet',
				method: 'run',
				find: 'return 0;',
				replace: 'return new Base().walk();'
			},
			{
				name: 'BARE',
				type: 'p.Quiet',
				method: 'run',
				find: 'return 0;',
				replace: 'return walk();'
			},
			{
				name: 'SELF',
				type: 'p.Quiet',
				method: 'run',
				find: 'return 0;',
				replace: 'return this.walk();'
			},
			{
				name: 'SHARED',
				type: 'p.Quiet',
				method: 'run',
				find: 'return walk();',
				replace: 'return walk() + 1;'
			},
			{
				name: 'OWN-TOKEN',
				type: 'p.Quiet',
				method: 'run',
				find: 'final x: Int = walk();',
				replace: 'final x: Int = o.walk() + 1;'
			},
			{
				name: 'PAIRS',
				type: 'p.Quiet',
				method: 'run',
				finds: ['return walk();', 'return 0;'],
				replaces: ['return walk() + 1;', 'return o.walk();']
			},
			{
				name: 'LENGTHS',
				type: 'p.Quiet',
				method: 'run',
				find: 'return 0;',
				replaces: ['o.walk()', 'b']
			},
			{
				name: 'NO-REPLACE',
				type: 'p.Quiet',
				method: 'walk',
				find: 'return 0;'
			}
		]);
		Assert.equals('return new Base().walk();', out.arm('FOREIGN').replace);
		Assert.equals('return walk();', out.arm('BARE').replace);
		Assert.equals('return this.walk();', out.arm('SELF').replace);
		Assert.equals('return walk();', out.arm('SHARED').find);
		Assert.equals('return walk() + 1;', out.arm('SHARED').replace);
		Assert.equals('final x: Int = o.walk() + 1;', out.arm('OWN-TOKEN').replace);
		Assert.same(['return walk() + 1;', 'return o.walk();'], out.arm('PAIRS').replaces);
		Assert.equals('walk', out.arm('NO-REPLACE').method);
		final named: Array<String> = out.notes.map(note -> note.split(':')[0]);
		Assert.same(['arm FOREIGN', 'arm PAIRS'], named);
		Assert.isTrue(
			out.notes[0].endsWith('on a receiver the rename cannot read — re-aim it if that is this member'), out.notes.join('|')
		);
	}

	public function testNothingToFollowLeavesNoText(): Void {
		final rename: Null<MemberRename> = renameOf('src/p/Base.hx', BASE, 'function walk', 'step');
		if (rename == null) {
			Assert.fail('the fixture renames');
			return;
		}
		final doc: String = document([{ name: 'A', type: 'q.Far', method: 'x' }]);
		final followed: RegistryFollow = MemberRegistryRename.follow(LAYOUT, doc, rename, new HaxeQueryPlugin());
		Assert.isNull(followed.text);
		Assert.equals(0, followed.count);
		Assert.isNull(MemberRegistryRename.of([], SCOPE, 'step', new HaxeQueryPlugin()));
	}

	private static function followBase(arms: Array<ArmRow>): ArmsAfter {
		return follow('src/p/Base.hx', BASE, 'function walk', 'step', arms);
	}

	private static function follow(file: String, source: String, at: String, newName: String, arms: Array<ArmRow>): ArmsAfter {
		final doc: String = document(arms);
		final rename: Null<MemberRename> = renameOf(file, source, at, newName);
		if (rename == null) throw 'the fixture must rename';
		final followed: RegistryFollow = MemberRegistryRename.follow(LAYOUT, doc, rename, new HaxeQueryPlugin());
		return new ArmsAfter(followed.text ?? doc, followed.notes);
	}

	/** The registry document holding `arms`, its strings spelled as a JSON writer spells them. */
	private static function document(arms: Array<ArmRow>): String {
		final list: (Array<String>) -> String = items -> '[${items.map(JsonText.quote).join(', ')}]';
		final records: Array<String> = [
			for (arm in arms) {
				final fields: Array<String> = [
					'"name": ${JsonText.quote(arm.name)}',
					'"type": ${JsonText.quote(arm.type)}',
					'"method": ${JsonText.quote(arm.method)}'
				];
				if (arm.kind != null) fields.push('"kind": ${JsonText.quote(arm.kind)}');
				if (arm.find != null) fields.push('"find": ${JsonText.quote(arm.find)}');
				if (arm.finds != null) fields.push('"find": ${list(arm.finds)}');
				if (arm.replace != null) fields.push('"replace": ${JsonText.quote(arm.replace)}');
				if (arm.replaces != null) fields.push('"replace": ${list(arm.replaces)}');
				if (arm.force != null) fields.push('"force": ${JsonText.quote(arm.force)}');
				'{${fields.join(', ')}}';
			}
		];
		return '{"arms": [${records.join(', ')}]}\n';
	}

	/** The rename of the member whose name ends the fragment `at` of `source`, over a scope holding every fixture file. */
	private static function renameOf(file: String, source: String, at: String, newName: String): Null<MemberRename> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final offset: Int = source.indexOf(at) + at.length - 1;
		final before: String = source.substring(0, offset);
		final line: Int = before.split('\n').length;
		final col: Int = offset - before.lastIndexOf('\n');
		final sources: Array<{ file: String, source: String }> = SCOPE.filter(s -> s.file != file).concat([{ file: file, source: source }]);
		return switch CrossRenameMember.crossRenameMember(file, source, line, col, newName, sources, plugin, plugin.refShape()) {
			case Ok(changes, _): MemberRegistryRename.of(changes, sources, newName, plugin);
			case Err(message): throw message;
		};
	}

}

/**
 * A fixture record; `finds` and `replaces` spell `find` and `replace` as a list.
 */
private typedef ArmRow = {
	final name: String;
	final type: String;
	final method: String;
	@:optional final kind: String;
	@:optional final find: String;
	@:optional final replace: String;
	@:optional final finds: Array<String>;
	@:optional final replaces: Array<String>;
	@:optional final force: String;
}

/** One record of a followed document. */
private typedef ArmAfter = {
	final method: Null<String>;
	final find: Null<String>;
	final replace: Null<String>;
	final finds: Array<String>;
	final replaces: Array<String>;
	final force: Null<String>;
}

/** A followed document read back as JSON, so an assertion on it also proves it parses. */
private class ArmsAfter {

	public final text: String;
	public final notes: Array<String>;

	public function new(text: String, notes: Array<String>) {
		this.text = text;
		this.notes = notes;
	}

	/** The record `name`, a cut that is a list in `finds` / `replaces`. */
	public function arm(name: String): ArmAfter {
		final items: Array<JValue> = switch JValueTools.field(JValueParser.parse(text), 'arms') {
			case JArray(held): held;
			case _: [];
		};
		for (item in items) if (string(JValueTools.field(item, 'name')) == name) return {
			method: string(JValueTools.field(item, 'method')),
			find: string(JValueTools.field(item, 'find')),
			replace: string(JValueTools.field(item, 'replace')),
			finds: strings(JValueTools.field(item, 'find')),
			replaces: strings(JValueTools.field(item, 'replace')),
			force: string(JValueTools.field(item, 'force'))
		};
		throw 'no arm $name in $text';
	}

	private static function string(value: Null<JValue>): Null<String> {
		return switch value {
			case JString(text): (text: String);
			case _: null;
		};
	}

	private static function strings(value: Null<JValue>): Array<String> {
		return switch value {
			case JArray(items): [for (item in items) string(item) ?? ''];
			case _: [];
		};
	}

}
