package unit.cli;

import anyparse.query.Cli;
import anyparse.query.ExitCode;
import anyparse.query.cli.CliRegistry;
import utest.Assert;
import utest.Test;

/**
 * `apq <not-a-command>` answers with the nearest real names, not with the whole help page.
 *
 * The dispatcher used to call `printUsage()` here: `apq members Foo` printed 5440 bytes —
 * ~1360 tokens — of the full command listing at a reader who mistyped one word. The listing is
 * still one command away and the second line names it; what arrives by default is the answer.
 *
 * `CliRegistry.unknownCommandLines` returns the lines instead of printing them for the reason
 * `LintFixLedger.ledgerLines` does: `CliIo.stderr` is a process write with no seam a test can
 * read, so the composition is the only part of it a pin can hold. The end-to-end half — that
 * `dispatch` routes THROUGH it and stops at EXIT_USAGE — is asserted separately below.
 */
@:nullSafety(Strict)
class CliUnknownSubcommandTest extends Test {

	private static inline final NOTICE_BYTE_BOUND: Int = 400;

	/**
	 * The near-miss list, over the case that motivated the whole function.
	 *
	 * `members` is FIVE edits from `add-member` — past `CliWalk`'s distance ceiling — and is
	 * not a substring of it either, so the shared matcher alone answers nothing here. Its
	 * SINGULAR stem is a substring of three real commands, which is what the plural probe
	 * exists to find. The typo arm beside it is the ordinary case the distance tier already
	 * handled, and it is here so a fix aimed at the plural probe cannot cost it.
	 */
	@:pin('control')
	@:killer('M-CLI-UNKNOWN-NO-PLURAL-PROBE')
	public function testAPluralMissNamesTheSingularCommands(): Void {
		final hints: Array<String> = CliRegistry.nearest('members');
		Assert.equals('add-member, move-member, remove-member', hints.join(', '));
		Assert.equals('lint', CliRegistry.nearest('lnt')[0], 'a one-edit typo still leads with its own command');
		Assert.equals(0, CliRegistry.nearest('zzzqqq').length, 'and nothing close means no fabricated hint');
	}

	/**
	 * The notice is TWO lines and neither of them is the command listing.
	 *
	 * The byte bound is the point of the slice, so it is asserted rather than described: the
	 * full help page is 5440 bytes and every plausible rewording of two lines fits far under
	 * the bound below, so this can only fail by someone printing the listing again.
	 */
	public function testTheNoticeIsTwoShortLinesAndPointsAtTheHelp(): Void {
		final lines: Array<String> = CliRegistry.unknownCommandLines('members');
		Assert.equals(2, lines.length);
		Assert.stringContains('unknown subcommand "members"', lines[0]);
		Assert.stringContains('add-member', lines[0]);
		Assert.stringContains('apq --help', lines[1]);
		final all: String = lines.join('');
		Assert.isTrue(all.length < NOTICE_BYTE_BOUND, 'the notice grew to ${all.length} bytes: $all');
		// A summary only the listing carries — proof the listing is not in here.
		Assert.equals(-1, all.indexOf('Dump parsed AST'), 'the command listing came back: $all');
	}

	/** A name with no near miss still says where the list is, and still exits EXIT_USAGE. */
	public function testAnUnrelatedNameKeepsThePointerAndTheExitCode(): Void {
		final lines: Array<String> = CliRegistry.unknownCommandLines('zzzqqq');
		Assert.equals(2, lines.length);
		Assert.equals(-1, lines[0].indexOf('did you mean'), 'no candidate, no invitation: ${lines[0]}');
		Assert.stringContains('apq --help', lines[1]);
		Assert.equals(ExitCode.EXIT_USAGE, Cli.run(['zzzqqq', 'x']), 'and dispatch still refuses');
	}

}
