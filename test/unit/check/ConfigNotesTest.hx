package unit.check;

import anyparse.check.ConfigNotes;
import anyparse.check.LintConfig;
import anyparse.query.RunLedger;
import unit.cli.CliFixture;

/**
 * Config diagnostics ride on the discovery call as notes: a caller that collects them gets them and the
 * stderr fallback stays silent, and `ConfigNotes.say` prints each key once per run.
 */
class ConfigNotesTest extends Test {

	@:pin('control')
	@:killer('M-CONFIG-NOTE-STATIC')
	public function testACollectingCallerGetsTheNoteInsteadOfTheFallback(): Void {
		#if (sys || nodejs)
		RunLedger.begin();
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
		final key: String = notes.length == 1 ? notes[0].key : '';
		Assert.isTrue(message.indexOf('failed to parse') >= 0, message);
		Assert.isFalse(RunLedger.said(LintConfig.WARNED_TOPIC, key), 'the fallback did not say it');
		#else
		Assert.pass('non-sys target');
		#end
	}

	@:pin('control')
	@:killer('M-CONFIG-NOTE-REPEATS')
	public function testSaySaysEachKeyOncePerRun(): Void {
		RunLedger.begin();
		final said: Array<String> = [];
		ConfigNotes.say([{ key: 'confignotes-key', message: 'one\n' }], said.push);
		ConfigNotes.say([{ key: 'confignotes-key', message: 'one\n' }], said.push);
		Assert.equals(1, said.length);
	}

}
