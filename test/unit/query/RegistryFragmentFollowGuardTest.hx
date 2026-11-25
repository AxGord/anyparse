package unit.query;

import anyparse.grammar.json.JsonText;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberRegistryRename.RegistryFollow;
import anyparse.query.RegistryFragmentFollow;
import anyparse.query.TypePathRegistries.MemberKeys;
import anyparse.query.cli.CliArgs;

/** `RegistryFragmentFollow`: a cut statement `if (C) continue;` that a loop fold turned into a comprehension guard is re-aimed at `C`. */
final class RegistryFragmentFollowGuardTest extends Test {

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
	private static final BEFORE: String = 'for (d in ds) {\n\t\t\tif (refuses(d, x)) continue;\n\t\t\tout.push(d);\n\t\t}\n\t\treturn out;';
	private static final AFTER: String = 'return [ for (d in ds) if (!refuses(d, x)) d ];';
	private static final BREAKING: String = 'for (d in ds) {\n\t\t\tif (refuses(d, x)) break;\n\t\t\tout.push(d);\n\t\t}\n\t\treturn out;';
	private static final ELSING: String = 'for (d in ds) {\n\t\t\tif (refuses(d, x)) continue; else out.push(d);\n\t\t}\n\t\treturn out;';

	@:pin('control')
	@:killer('M-REGISTRY-FOLLOW-GUARD-REAIM-FALSE')
	public function testAGuardStatementFoldedIntoAComprehensionIsReAimedAtItsCondition(): Void {
		final out: RegistryFollow = follow('if (refuses(d, x)) continue;', '');
		Assert.equals('', out.notes.join('\n'));
		final text: String = out.text ?? '';
		Assert.isTrue(text.indexOf('"find":"refuses(d, x)"') >= 0, text);
		Assert.isTrue(text.indexOf('"replace":"false"') >= 0, text);
		Assert.equals(1, out.reaimed.length);
		Assert.isTrue(out.reaimed[0].indexOf('arm A: re-aimed') == 0, out.reaimed[0]);
	}

	@:pin('control')
	@:killer('M-REGISTRY-FOLLOW-GUARD-REAIM-EMPTY-REPLACE')
	public function testACutThatReplacesTheGuardWithTextIsNotReAimed(): Void {
		assertDeclined(follow('if (refuses(d, x)) continue;', 'if (refuses(d, x)) break;'));
	}

	@:pin('control')
	@:killer('M-REGISTRY-FOLLOW-GUARD-REAIM-BARE-CONTINUE')
	public function testAGuardThatDoesNotJustContinueIsNotReAimed(): Void {
		assertDeclined(follow('if (refuses(d, x)) break;', '', BREAKING));
		assertDeclined(follow('if (refuses(d, x)) continue; else out.push(d);', '', ELSING));
	}

	private static function follow(find: String, replace: String, ?before: Null<String>): RegistryFollow {
		final plugin: GrammarPlugin = CliArgs.pickPluginFor('haxe', 'C.hx');
		final head: String =
			'package p;\n\nclass C {\n\tfunction f(ds: Array<Int>, x: Bool): Array<Int> {\n\t\tfinal out: Array<Int> = [];\n\t\t';
		final tail: String = '\n\t}\n}\n';
		final old: String = head + (before ?? BEFORE) + tail;
		final now: String = head.split('final out: Array<Int> = [];\n\t\t').join('') + AFTER + tail;
		final json: String =
			'{"arms":[{"name":"A","type":"p.C","method":"f","find":${JsonText.quote(find)},"replace":${JsonText.quote(replace)}}]}';
		return RegistryFragmentFollow.follow(LAYOUT, json, [{
			path: 'p.C',
			source: old,
			tree: plugin.parseFile(old),
			newSource: now,
			newTree: plugin.parseFile(now)
		}], plugin);
	}

	private static function assertDeclined(out: RegistryFollow): Void {
		Assert.isNull(out.text);
		Assert.equals(0, out.reaimed.length);
		Assert.equals(1, out.notes.length);
		Assert.isTrue(out.notes[0].indexOf('no re-spelling of its cut applies to the rewritten source') >= 0, out.notes[0]);
	}

}
