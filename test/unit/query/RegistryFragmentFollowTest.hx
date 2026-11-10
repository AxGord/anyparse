package unit.query;

import anyparse.grammar.json.JsonText;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberRegistryRename.RegistryFollow;
import anyparse.query.QueryNode;
import anyparse.query.RegistryFragmentFollow;
import anyparse.query.TypePathRegistries.MemberKeys;
import anyparse.query.cli.CliArgs;

/** `RegistryFragmentFollow`: a registry fragment follows a mechanical rewrite of the member it cuts. */
final class RegistryFragmentFollowTest extends Test {

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
	private static final BEFORE: String =
		'package p;\n\nclass C {\n\tfunction f(a: Bool, b: Bool, c: Bool): Bool {\n\t\treturn a && b || c;\n\t}\n}\n';
	private static final AFTER: String =
		'package p;\n\nclass C {\n\tfunction f(a: Bool, b: Bool, c: Bool): Bool {\n\t\treturn (a && b) || c;\n\t}\n}\n';

	@:pin('control')
	@:killer('M-REGISTRY-FOLLOW-REPLACE-SHARES-FIND')
	public function testAFragmentThroughANewParenCarriesItIntoFindAndReplace(): Void {
		final out: RegistryFollow = follow('b || c', 'b && c');
		Assert.equals(2, out.count);
		Assert.equals(0, out.notes.length);
		Assert.isTrue(out.text.indexOf('"find":"b) || c"') >= 0);
		Assert.isTrue(out.text.indexOf('"replace":"b) && c"') >= 0);
	}

	@:pin('control')
	@:killer('M-REGISTRY-FOLLOW-SPLICE-CHECKED')
	public function testAReplaceThatWouldUnbalanceTheSpliceIsNamedNotWritten(): Void {
		final out: RegistryFollow = follow('b || c', 'false');
		Assert.isNull(out.text);
		Assert.equals(1, out.notes.length);
	}

	public function testAFragmentAlreadySpelledForTheNewTextIsSilent(): Void {
		final out: RegistryFollow = follow('b) || c', 'b) && c');
		Assert.isNull(out.text);
		Assert.equals(0, out.notes.length);
	}

	@:pin('control')
	@:killer('M-REGISTRY-FOLLOW-FIND-MAPS-TO-WRITTEN')
	public function testAMultiLineFindKeepsItsWholeExtentThroughAnIndentTolerantCut(): Void {
		final out: RegistryFollow = followIn(
			'if (a) return b;\n\t\treturn c;', 'if (a) return (b);\n\t\treturn c;', 'if (a) return b;\nreturn c;',
			'if (a) return b;\nreturn x;'
		);
		Assert.equals('', out.notes.join('\n'));
		final text: String = out.text ?? '';
		Assert.isTrue(text.indexOf('return (b);\\n\\t\\treturn c;"') >= 0, text);
		Assert.isTrue(text.indexOf('return (b);\\n\\t\\treturn x;"') >= 0, text);
	}

	@:pin('control')
	@:killer('M-REGISTRY-FOLLOW-BOUNDARY-TAKES-INSERTED')
	public function testAClosingParenInsertedAtTheCutsEndJoinsItsPartner(): Void {
		assertCarried('return x || a && b;', 'return x || (a && b);', ' || a && b', '', ' || (a && b)', '');
	}

	@:pin('control')
	@:killer('M-REGISTRY-FOLLOW-KEEPS-UNCHANGED-REPLACE')
	public function testAReplaceDroppingANewGroupStaysAsWritten(): Void {
		assertCarried(
			'if (x || a && b) return a;\n\t\treturn b;', 'if (x || (a && b)) return a;\n\t\treturn b;', '(x || a && b)', '(x)',
			'(x || (a && b))', '(x)'
		);
		assertCarried('return x && a || c;', 'return (x && a) || c;', 'x && a || c', 'x || c', '(x && a) || c', 'x || c');
	}

	@:pin('control')
	@:killer('M-REGISTRY-FOLLOW-AS-WRITTEN-FIRST')
	public function testAFindThatStillAppliesIsLeftAlone(): Void {
		final out: RegistryFollow = followIn('return x && (a) || c;', 'return (x && (a)) || c;', '(a)', '(b)');
		Assert.isNull(out.text);
		Assert.equals(0, out.notes.length);
	}

	private static function follow(find: String, replace: String): RegistryFollow {
		final plugin: GrammarPlugin = CliArgs.pickPluginFor('haxe', 'C.hx');
		final tree: QueryNode = plugin.parseFile(BEFORE);
		final json: String = '{"arms":[{"name":"A","type":"p.C","method":"f","find":"$find","replace":"$replace"}]}';
		return RegistryFragmentFollow.follow(LAYOUT, json, [
			{
				path: 'p.C',
				source: BEFORE,
				tree: tree,
				newSource: AFTER,
				newTree: plugin.parseFile(AFTER)
			}
		], plugin);
	}

	private static function assertCarried(
		before: String, after: String, find: String, replace: String, newFind: String, newReplace: String
	): Void {
		final out: RegistryFollow = followIn(before, after, find, replace);
		Assert.equals('', out.notes.join('\n'));
		final text: String = out.text ?? '';
		Assert.isTrue(text.indexOf('"find":${JsonText.quote(newFind)}') >= 0, text);
		Assert.isTrue(text.indexOf('"replace":${JsonText.quote(newReplace)}') >= 0, text);
	}

	private static function followIn(before: String, after: String, find: String, replace: String): RegistryFollow {
		final plugin: GrammarPlugin = CliArgs.pickPluginFor('haxe', 'C.hx');
		final head: String = 'package p;\n\nclass C {\n\tfunction f(a: Bool, b: Bool, c: Bool, x: Bool): Bool {\n\t\t';
		final tail: String = '\n\t}\n}\n';
		final old: String = head + before + tail;
		final now: String = head + after + tail;
		final json: String =
			'{"arms":[{"name":"A","type":"p.C","method":"f","find":${JsonText.quote(find)},"replace":${JsonText.quote(replace)}}]}';
		return RegistryFragmentFollow.follow(LAYOUT, json, [
			{
				path: 'p.C',
				source: old,
				tree: plugin.parseFile(old),
				newSource: now,
				newTree: plugin.parseFile(now)
			}
		], plugin);
	}

}
