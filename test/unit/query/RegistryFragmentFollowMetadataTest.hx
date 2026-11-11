package unit.query;

import anyparse.grammar.json.JsonText;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberRegistryRename.RegistryFollow;
import anyparse.query.RegistryFragmentFollow;
import anyparse.query.TypePathRegistries.MemberKeys;
import anyparse.query.cli.CliArgs;

/** `RegistryFragmentFollow`: a fragment over metadata follows a rewrite that put each metadata on its own line. */
final class RegistryFragmentFollowMetadataTest extends Test {

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
	private static final BEFORE: String = 'package p;\n\ntypedef T = {\n\t@:queryType @:fmt(propagateNestedType) var type: Int;\n}\n\n'
		+ "enum E {\n\tA;\n\t@:wrap('(', ')') @:fmt(propagateNestedType)\n\tParens(inner: Int);\n}\n"
		+ '\ntypedef U = {\n\t@:a @:b var swap: Int;\n}\n';
	private static final AFTER: String = 'package p;\n\ntypedef T = {\n\t@:queryType\n\t@:fmt(propagateNestedType)\n\tvar type: Int;\n}\n\n'
		+ "enum E {\n\tA;\n\t@:wrap('(', ')')\n\t@:fmt(propagateNestedType)\n\tParens(inner: Int);\n}\n"
		+ '\ntypedef U = {\n\t@:a\n\t@:b\n\tvar swap: Int;\n}\n';

	@:pin('control')
	@:killer('M-REGISTRY-FOLLOW-SHARED-EDGE-REPLACED')
	public function testAReplaceKeepsTheSeparatorTheNewTextHasWhereItsFindLostMetadata(): Void {
		final out: RegistryFollow = followArm(
			'TypedefDecl', 'T', '@:queryType @:fmt(propagateNestedType) var type', '@:queryType var type'
		);
		Assert.equals('', out.notes.join('\n'));
		final text: String = out.text ?? '';
		Assert.isTrue(text.indexOf('"find":${JsonText.quote('@:queryType\n\t@:fmt(propagateNestedType)\n\tvar type')}') >= 0, text);
		Assert.isTrue(text.indexOf('"replace":${JsonText.quote('@:queryType\n\tvar type')}') >= 0, text);
	}

	@:pin('control')
	@:killer('M-REGISTRY-FOLLOW-SHARED-SUFFIX-EDGE-REPLACED')
	public function testASharedSuffixKeepsTheSeparatorTheRewriteReplacedAtItsStart(): Void {
		final out: RegistryFollow = followArm('TypedefDecl', 'U', '@:a @:b var swap', '@:c @:b var swap');
		Assert.equals('', out.notes.join('\n'));
		final text: String = out.text ?? '';
		Assert.isTrue(text.indexOf('"find":${JsonText.quote('@:a\n\t@:b\n\tvar swap')}') >= 0, text);
		Assert.isTrue(text.indexOf('"replace":${JsonText.quote('@:c\n\t@:b\n\tvar swap')}') >= 0, text);
	}

	@:pin('control')
	@:killer('M-REGISTRY-FOLLOW-ALIGNS-WITH-METADATA')
	public function testAFindOverAConstructorsOwnMetadataAlignsAcrossTheirNewLines(): Void {
		final out: RegistryFollow = followArm('ParamCtor', 'Parens', "@:wrap('(', ')') @:fmt(propagateNestedType)", "@:wrap('(', ')')");
		Assert.equals('', out.notes.join('\n'));
		final text: String = out.text ?? '';
		Assert.isTrue(text.indexOf('"find":${JsonText.quote("@:wrap('(', ')')\n\t@:fmt(propagateNestedType)")}') >= 0, text);
		Assert.equals(1, out.count);
	}

	private static function followArm(kind: String, member: String, find: String, replace: String): RegistryFollow {
		final plugin: GrammarPlugin = CliArgs.pickPluginFor('haxe', 'T.hx');
		final json: String = '{"arms":[{"name":"A","type":"p.T","method":${JsonText.quote(member)},"kind":${JsonText.quote(kind)},'
			+ '"find":${JsonText.quote(find)},"replace":${JsonText.quote(replace)}}]}';
		return RegistryFragmentFollow.follow(LAYOUT, json, [
			{
				path: 'p.T',
				source: BEFORE,
				tree: plugin.parseFile(BEFORE),
				newSource: AFTER,
				newTree: plugin.parseFile(AFTER)
			}
		], plugin);
	}

}
