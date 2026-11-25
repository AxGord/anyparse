package unit.query;

import anyparse.query.GrammarPlugin;
import anyparse.query.MemberRegistryRename.RegistryFollow;
import anyparse.query.RegistryFragmentFollow;
import anyparse.query.TypePathRegistries.MemberKeys;
import anyparse.query.cli.CliArgs;

/**
 * `RegistryFragmentFollow` re-spells a replace with the text the rewrite added at one edge of its find's edited part. Every
 * such fixture reaches a candidate that carries it, because the boundary choices always offer the wide cut, so no fixture can
 * make `mirrorsEdit` turn every candidate down: the lossy candidate is only ever passed over.
 */
final class RegistryFollowRespellLossTest extends Test {

	private static final LAYOUT: MemberKeys = {
		records: 'arms',
		name: 'name',
		type: 'type',
		member: 'method',
		kind: 'kind',
		defaultKind: 'FnMember',
		find: 'find',
		replace: 'replace',
		opaque: []
	};

	@:pin('control')
	@:killer('M-REGISTRY-FOLLOW-RESPELL-KEEPS-EDIT')
	public function testAReplaceKeepsTheArgumentsTheRewriteAddedToItsFind(): Void {
		final out: RegistryFollow = follow(
			'restFrom(x + 1, false)', 'restFrom(y, false)', 'restFrom(x + 1, false)', 'groupRest(stack, width, x + 1, false)'
		);
		Assert.equals(0, out.notes.length);
		Assert.notNull(out.text);
		Assert.isTrue(out.text.indexOf('"replace":"groupRest(stack, width, y, false)"') >= 0, out.text);
	}

	@:pin('guard')
	public function testARewriteThatLeavesTheEditedPartAloneCarriesTheReplace(): Void {
		final out: RegistryFollow = follow(
			'restFrom(x + 1, false)', 'restFrom(y, false)', 'restFrom(x + 1, false)', 'groupRest(x + 1, false)'
		);
		Assert.equals(0, out.notes.length);
		Assert.notNull(out.text);
		Assert.isTrue(out.text.indexOf('groupRest(y, false)') >= 0, out.text);
	}

	private static function follow(find: String, replace: String, was: String, now: String): RegistryFollow {
		final plugin: GrammarPlugin = CliArgs.pickPluginFor('haxe', 'C.hx');
		final head: String = 'package p;\n\nclass C {\n\tfunction f(x: Int): Int {\n\t\treturn ';
		final tail: String = ';\n\t}\n}\n';
		final old: String = '$head$was$tail';
		final next: String = '$head$now$tail';
		final json: String = '{"arms":[{"name":"A","type":"p.C","method":"f","find":"$find","replace":"$replace"}]}';
		return RegistryFragmentFollow.follow(LAYOUT, json, [{
			path: 'p.C',
			source: old,
			tree: plugin.parseFile(old),
			newSource: next,
			newTree: plugin.parseFile(next)
		}], plugin);
	}

}
