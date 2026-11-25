package unit.query;

import anyparse.grammar.json.JsonText;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberRegistryRename.RegistryFollow;
import anyparse.query.RegistryFragmentFollow;
import anyparse.query.TypePathRegistries.MemberKeys;
import anyparse.query.cli.CliArgs;

/** `RegistryFragmentFollow` names a cut it cannot carry instead of carrying it into junk. */
final class RegistryFragmentFollowJunkTest extends Test {

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

	@:pin('guard')
	public function testAFindWhoseLineWasDeletedIsNamed(): Void {
		assertNamed('var y = a;\n\t\treturn b;', 'return b;', 'var y = a;', 'var y = c;');
	}

	@:pin('control')
	@:killer('M-REGISTRY-FOLLOW-CARRIES-CUT-WHOLE')
	public function testAFindWithoutAReplaceWhoseLineWasDeletedIsNamed(): Void {
		assertNamed('var y = a;\n\t\treturn b;', 'return b;', 'var y = a;', null);
	}

	@:pin('control')
	@:killer('M-REGISTRY-FOLLOW-CARRIES-CUT-WHOLE')
	public function testACarryThatWouldSplitATokenIsNamed(): Void {
		assertNamed('return 1 + 2 > 0;', 'final s = 1 + 2;\n\t\treturn s > 0;', 'return 1 + 2', 'return 1 - 2');
	}

	@:pin('control')
	@:killer('M-REGISTRY-FOLLOW-FIND-LEAVES-INDENT')
	public function testAMultiLineFindAndItsReplaceKeepOneIndentation(): Void {
		final out: RegistryFollow = followIn(
			'if (a)\n\t\t\treturn b;\n\t\treturn c;', 'if (a)\n\t\t\treturn (b);\n\t\treturn c;', 'return b;\nreturn c;',
			'return b;\nreturn x;'
		);
		final text: String = out.text ?? '';

		Assert.isTrue(text.indexOf('"find":"return (b);\\n\\t\\treturn c;"') >= 0, text);
		Assert.isTrue(text.indexOf('"replace":"return (b);\\n\\t\\treturn x;"') >= 0, text);
	}

	private static function assertNamed(before: String, after: String, find: String, replace: Null<String>): Void {
		final out: RegistryFollow = followIn(before, after, find, replace);
		Assert.isNull(out.text, out.text);
		Assert.equals(1, out.notes.length);
	}

	private static function followIn(before: String, after: String, find: String, replace: Null<String>): RegistryFollow {
		final plugin: GrammarPlugin = CliArgs.pickPluginFor('haxe', 'C.hx');
		final head: String = 'package p;\n\nclass C {\n\tfunction f(a: Bool, b: Bool, c: Bool, x: Bool): Bool {\n\t\t';
		final tail: String = '\n\t}\n}\n';
		final old: String = head + before + tail;
		final now: String = head + after + tail;
		final replaced: String = replace == null ? '' : ',"replace":${JsonText.quote(replace)}';
		final json: String = '{"arms":[{"name":"A","type":"p.C","method":"f","find":${JsonText.quote(find)}$replaced}]}';
		return RegistryFragmentFollow.follow(LAYOUT, json, [{
			path: 'p.C',
			source: old,
			tree: plugin.parseFile(old),
			newSource: now,
			newTree: plugin.parseFile(now)
		}], plugin, null);
	}

}
