package unit.dev;

import dev.SlotServer;
import unit.check.oracle.PortHolder.unusedPort;
import unit.check.oracle.PortHolder.watching;
import unit.cli.CliFixture;
import utest.Assert;
import utest.Test;

/** A slot's warm server takes a port only after `CompilerServer.freePort`, as every other starter does. */
final class SlotServerTest extends Test {

	/** Asking `freePort` never touches the held port; a slot that tried it and recovered would have connected. */
	@:pin('control')
	@:killer('M-SLOT-DRAWS-NO-FREE-PORT')
	public function testASlotServerComesUpOnTheNextPortWhenTheFirstIsHeld(): Void {
		final held: Int = unusedPort();
		final next: Int = unusedPort();
		final wt: String = slotTree();
		final candidates: Array<Int> = [held, next];
		final server: SlotServer = new SlotServer(wt, 0, () -> candidates.shift() ?? next);
		CliFixture.always(() -> {
			server.stop();
			CliFixture.removeDir(wt);
		}, () -> watching(held, connections -> {
			Assert.equals(next, server.port(wt), 'the slot serves past the held port');
			Assert.equals(0, connections(), 'and nothing ever connected to the held port');
		}));
	}

	/** A slot with every candidate held builds cold, and never touches one. */
	@:pin('control')
	@:killer('M-SLOT-DRAWS-NO-FREE-PORT')
	public function testNoSlotServerIsStartedWhenEveryCandidateIsHeld(): Void {
		final held: Int = unusedPort();
		final wt: String = slotTree();
		final server: SlotServer = new SlotServer(wt, 0, () -> held);
		CliFixture.always(() -> {
			server.stop();
			CliFixture.removeDir(wt);
		}, () -> watching(held, connections -> {
			Assert.isNull(server.port(wt), 'no port to bind: no server');
			Assert.equals(0, connections(), 'and nothing ever connected to the held port');
		}));
	}

	/** A tree of one module and the build file a slot's readiness poll names. */
	private static function slotTree(): String {
		return CliFixture.writeTree('apq_slot_server', [
			{ name: 'Main.hx', source: 'class Main {\n\tstatic function main() {}\n}\n' },
			{ name: 'test-js-common.hxml', source: '-cp .\n-main Main\n--no-output\n' }
		]);
	}

}
