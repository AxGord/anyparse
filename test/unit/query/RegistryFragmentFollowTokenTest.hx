package unit.query;

import anyparse.grammar.json.JsonText;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberRegistryRename.RegistryFollow;
import anyparse.query.RegistryFragmentFollow;
import anyparse.query.TypePathRegistries.MemberKeys;
import anyparse.query.cli.CliArgs;

/** `RegistryFragmentFollow` carries an edit the rewrite deleted only when one token was replaced by one token. */
final class RegistryFragmentFollowTokenTest extends Test {

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

	@:pin('control')
	@:killer('M-REGISTRY-FOLLOW-ONE-TOKEN-REPLACED')
	public function testACallReplacedByANameIsNotOneTokenReplaced(): Void {
		final out: RegistryFollow = followIn('return a.b(c) > 0;', 'return x > 0;', 'return a.b(c)', 'return a.b(d)');
		Assert.isNull(out.text, out.text);
		Assert.equals(1, out.notes.length);
	}

	@:pin('control')
	@:killer('M-REGISTRY-FOLLOW-LEAF-KEEPS-BLANK-TEST')
	public function testAnArrayLiteralReplacedByANameIsNotOneTokenReplaced(): Void {
		final out: RegistryFollow = followIn(
			'trace([ ]); return c > 0;', 'trace(x); return c > 0;', 'trace([ ]); return c > 0', 'trace([1]); return c > 0'
		);
		Assert.isNull(out.text, out.text);
		Assert.equals(1, out.notes.length);
	}

	private static function followIn(before: String, after: String, find: String, replace: String): RegistryFollow {
		final plugin: GrammarPlugin = CliArgs.pickPluginFor('haxe', 'C.hx');
		final head: String = 'package p;\n\nclass C {\n\tfunction f(a: Dynamic, c: Int, d: Int, x: Int): Bool {\n\t\t';
		final tail: String = '\n\t}\n}\n';
		final old: String = head + before + tail;
		final now: String = head + after + tail;
		final json: String =
			'{"arms":[{"name":"A","type":"p.C","method":"f","find":${JsonText.quote(find)},"replace":${JsonText.quote(replace)}}]}';
		return RegistryFragmentFollow.follow(LAYOUT, json, [{
			path: 'p.C',
			source: old,
			tree: plugin.parseFile(old),
			newSource: now,
			newTree: plugin.parseFile(now)
		}], plugin, null);
	}

}
