package unit.check;

import anyparse.check.ConfigNotes;
import anyparse.check.LintConfig;
import anyparse.ds.Set;
import anyparse.query.RunLedger;
import unit.cli.CliFixture;

/**
 * Config diagnostics ride on the discovery call as notes: a caller that collects them gets them and the
 * stderr fallback stays silent, `ConfigNotes.say` prints each key once per run, and `ConfigNotes.warn` once per `said` set.
 */
class ConfigNotesTest extends Test {

	@:pin('control')
	@:killer('M-CONFIG-NOTE-STATIC')
	public function testACollectingCallerGetsTheNoteAsANote(): Void {
		#if (sys || nodejs)
		final dir: String = CliFixture.writeDir('confignotes', [
			{ name: 'apq.json', source: '{"rules": [' },
			{ name: 'Foo.hx', source: 'class Foo {}\n' }
		]);
		final notes: Array<ConfigNote> = [];
		final config: LintConfig = LintConfig.discover('$dir/Foo.hx', notes);
		CliFixture.removeDir(dir);
		Assert.isTrue(config.enabledFor('naming'), 'the broken document is skipped, not fatal');
		Assert.equals(1, notes.length, 'the broken document is one note');
		final message: String = notes.length == 1 ? notes[0].message : '';
		Assert.isTrue(message.indexOf('failed to parse') >= 0, message);
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-CONFIG-NOTE-REPEATS')
	public function testSaySaysEachKeyOncePerRun(): Void {
		final ledger: RunLedger = new RunLedger();
		final said: Array<String> = [];
		ConfigNotes.say(ledger, [{ key: 'confignotes-key', message: 'one\n' }], said.push);
		ConfigNotes.say(ledger, [{ key: 'confignotes-key', message: 'one\n' }], said.push);
		Assert.equals(1, said.length);
	}

	@:pin('control')
	@:killer('M-CONFIG-NOTE-SAYS-LATEST')
	public function testSayAnswersToTheLedgerItIsGiven(): Void {
		final earlier: RunLedger = new RunLedger();
		final said: Array<String> = [];
		Assert.isTrue(earlier.first(LintConfig.WARNED_TOPIC, 'confignotes-own'));
		ConfigNotes.say(earlier, [{ key: 'confignotes-own', message: 'one\n' }], said.push);
		Assert.equals(0, said.length, 'the ledger it was given already holds the key');
	}

	@:pin('control')
	@:killer('M-CONFIG-NOTE-INTO-DROPS')
	public function testAReaderWithNoCollectorSaysItsNoteOnStderr(): Void {
		final collected: Array<ConfigNote> = [];
		final heldOut: String = CliFixture.captureStderr(
			() -> ConfigNotes.into(collected, notes -> ConfigNotes.note(notes, 'confignotes-into-held', 'apq: held\n'))
		);
		Assert.equals(1, collected.length, 'a collecting caller keeps the note');
		Assert.equals('', heldOut, 'a collected note is not said by the fallback');
		final said: String = CliFixture.captureStderr(
			() -> ConfigNotes.into(null, notes -> ConfigNotes.note(notes, 'confignotes-into-own', 'apq: no collector\n'))
		);
		#if nodejs
		Assert.equals('apq: no collector\n', said, 'no collector: the fallback says it on stderr');
		#else
		Assert.pass('stderr is captured on node only');
		#end
	}

	/** A caller that warns more than once with one `said` says each key once over all its calls. */
	@:pin('control')
	@:killer('M-CONFIG-NOTE-WARN-REPEATS')
	public function testWarnSaysEachKeyOnceOverTheCallsSharingItsSaidSet(): Void {
		final seen: Set<String> = new Set();
		final said: Array<String> = [];
		ConfigNotes.warn([
			{ key: 'confignotes-warn-key', message: 'one\n' },
			{ key: 'confignotes-warn-key', message: 'one\n' }
		], seen, said.push);
		ConfigNotes.warn([{ key: 'confignotes-warn-key', message: 'one\n' }], seen, said.push);
		ConfigNotes.warn([{ key: 'confignotes-warn-other', message: 'two\n' }], seen, said.push);
		Assert.same(['one\n', 'two\n'], said);
	}

}
