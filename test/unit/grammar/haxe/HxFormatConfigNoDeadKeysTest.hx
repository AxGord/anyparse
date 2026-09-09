package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeFormatConfigDiagnostics;
import anyparse.grammar.haxe.HaxeFormatConfigIssues;
import utest.Assert;
import utest.Test;
#if (sys || nodejs)
import unit.cli.CliFixture;
#end

/**
 * This repo's OWN `hxformat.json` declares nothing hxq drops on the floor.
 *
 * A GUARD, not a control: it must stay green, and no mutant of the diagnostic makes it fail
 * usefully — an arm that broke `diagnose` would only make it pass harder.
 *
 * It exists because the config carried TWELVE such keys (`afterBlocks`, `interfaceEmptyLines`'s
 * `beginType` / `endType`, `commaPolicy`, `catchPolicy`, the two bracket policies, three
 * `bracesConfig` entries and two `parenConfig` entries), and `HaxeFormatConfigDiagnostics` said
 * so on stderr on EVERY hxq invocation that loaded the config — measured 412 bytes, ~100 tokens,
 * per write op, per lint, per `fmt`. `tools/battery.sh` carries a comment about working around
 * it, because merging that line into the `fmt` gate's stdout made the gate read "some file
 * drifted" on every run. The keys were removed and hxq's answer for this tree did not move,
 * because a key with no schema field never reached the writer in the first place.
 *
 * So the line is gone, and this is what keeps it gone: a key hxq cannot act on fails HERE, at
 * the moment someone adds it, instead of quietly re-taxing every command.
 */
@:nullSafety(Strict)
class HxFormatConfigNoDeadKeysTest extends Test {

	public function testTheProjectConfigDeclaresNothingHxqIgnores(): Void {
		#if (sys || nodejs)
		final issues: HaxeFormatConfigIssues = HaxeFormatConfigDiagnostics.diagnose(
			sys.io.File.getContent('${CliFixture.repoRoot()}/hxformat.json')
		);
		Assert.equals(0, issues.keys.length, 'unimplemented key(s): ${issues.keys.join(', ')}');
		Assert.equals(0, issues.wrapValues.length, 'unimplemented wrap setting(s): ${issues.wrapValues.join(', ')}');
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

}
