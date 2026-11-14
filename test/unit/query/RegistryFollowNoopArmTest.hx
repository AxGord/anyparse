package unit.query;

import anyparse.query.GrammarPlugin;
import anyparse.query.MemberRegistryRename.RegistryFollow;
import anyparse.query.RegistryFragmentFollow;
import anyparse.query.TypePathRegistries.MemberKeys;
import anyparse.query.cli.CliArgs;

/** `RegistryFragmentFollow` never writes a record whose find would equal its replace: that arm cuts nothing. */
final class RegistryFollowNoopArmTest extends Test {

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
	@:killer('M-REGISTRY-FOLLOW-NOOP-ARM-REFUSED')
	public function testAFollowThatWouldMakeFindEqualReplaceIsNamedNotWritten(): Void {
		final out: RegistryFollow = follow('x + 2', 'x - 2');
		Assert.isNull(out.text);
		Assert.equals(1, out.notes.length);
		Assert.isTrue(out.notes[0].indexOf('arm A') >= 0, out.notes[0]);
		Assert.isTrue(out.notes[0].indexOf('re-aim') >= 0, out.notes[0]);
	}

	@:pin('guard')
	public function testAFollowThatKeepsFindAndReplaceApartIsWritten(): Void {
		final out: RegistryFollow = follow('x + 2', 'x * 2');
		Assert.equals(0, out.notes.length);
		Assert.notNull(out.text);
	}

	private static function follow(find: String, replace: String): RegistryFollow {
		final plugin: GrammarPlugin = CliArgs.pickPluginFor('haxe', 'C.hx');
		final head: String = 'package p;\n\nclass C {\n\tfunction f(x: Int): Int {\n\t\treturn ';
		final tail: String = ';\n\t}\n}\n';
		final old: String = '${head}x + 2$tail';
		final now: String = '${head}x - 2$tail';
		final json: String = '{"arms":[{"name":"A","type":"p.C","method":"f","find":"$find","replace":"$replace"}]}';
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
