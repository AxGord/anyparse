package unit.cli;

import anyparse.query.Cli;
import anyparse.query.cli.CliIo;
import utest.Assert;
import utest.Test;

/**
 * The walk progress heartbeat, gated on stderr being a TERMINAL.
 *
 * `scanned N/M files…` was written for a human watching a long walk and for a
 * watchdog reading a redirected stream. It is also, unconditionally, 38 stderr
 * lines / 1289 bytes per `src`-wide walk of this tree — measured 2026-09-07 at
 * 935 files, `lit` / `refs` / `mentions` alike — and a model pays that on every
 * walk. `2>/dev/null` is not the answer and that is the whole point: the same
 * stream carries the `--limit` cap line, the `refs` member-access warning, and
 * for a mutation op the ONLY channel a refusal has, so silencing the channel
 * silences a refusal too.
 *
 * The decision is `CliIo.progressEnabled`, a pure function of the two env vars
 * and the TTY answer, so the rule can be stated as a TABLE rather than observed
 * as a side effect. The table below is a SECOND instance of that rule, written
 * out by hand from the contract rather than derived from the implementation.
 *
 * `testNoEnvAndNoTerminalIsSilent` is the control: it is the one cell that
 * changed behaviour in this slice, and the arm below puts the pre-slice rule
 * back.
 */
@:nullSafety(Strict)
class ApqProgressTtyCliTest extends Test {

	/** Enough files that `streamProgress`'s `total <= PROGRESS_INTERVAL` early return does not fire. */
	private static inline final FILES_PAST_INTERVAL: Int = 26;

	/**
	 * The rule, restated: `{progressEnv, noProgressSet, stderrTty}` and what
	 * `progressEnabled` owes each combination. Read as prose — an explicit
	 * `HXQ_PROGRESS` decides, else `HXQ_NO_PROGRESS` forces off, else the
	 * terminal answers; an EMPTY `HXQ_PROGRESS` counts as unset, because
	 * restoring a saved-null env var in a test writes exactly that.
	 */
	private static final EXPECTED: Array<{
		env: Null<String>,
		noProgress: Bool,
		tty: Bool,
		want: Bool
	}> = [
		{
			env: null,
			noProgress: false,
			tty: true,
			want: true
		},
		{
			env: null,
			noProgress: false,
			tty: false,
			want: false
		},
		{
			env: null,
			noProgress: true,
			tty: true,
			want: false
		},
		{
			env: null,
			noProgress: true,
			tty: false,
			want: false
		},
		{
			env: '',
			noProgress: false,
			tty: true,
			want: true
		},
		{
			env: '',
			noProgress: false,
			tty: false,
			want: false
		},
		{
			env: '',
			noProgress: true,
			tty: false,
			want: false
		},
		{
			env: '1',
			noProgress: false,
			tty: false,
			want: true
		},
		{
			env: '1',
			noProgress: true,
			tty: false,
			want: true
		},
		{
			env: 'yes',
			noProgress: true,
			tty: false,
			want: true
		},
		{
			env: '0',
			noProgress: false,
			tty: true,
			want: false
		},
		{
			env: '0',
			noProgress: false,
			tty: false,
			want: false
		}
	];

	/**
	 * KILLED by arm `M-PROGRESS-TTY-BLIND`, which restores the pre-slice rule
	 * (`on unless HXQ_NO_PROGRESS`) and so prints the heartbeat into a pipe again.
	 */
	@:pin('control')
	@:killer('M-PROGRESS-TTY-BLIND')
	public function testNoEnvAndNoTerminalIsSilent(): Void {
		Assert.isFalse(CliIo.progressEnabled(null, false, false), 'a redirected stderr gets no heartbeat');
		Assert.isFalse(CliIo.progressEnabled('', false, false), 'an empty HXQ_PROGRESS counts as unset');
	}

	public function testTheWholeRuleTable(): Void {
		for (row in EXPECTED)
			Assert.equals(
				row.want, CliIo.progressEnabled(row.env, row.noProgress, row.tty),
				'HXQ_PROGRESS=${row.env}, HXQ_NO_PROGRESS=${row.noProgress}, tty=${row.tty}'
			);
	}

	public function testAnExplicitEnvOutranksBothTheLegacyVarAndTheTerminal(): Void {
		Assert.isTrue(CliIo.progressEnabled('1', true, false), 'HXQ_PROGRESS=1 wins over HXQ_NO_PROGRESS');
		Assert.isFalse(CliIo.progressEnabled('0', false, true), 'HXQ_PROGRESS=0 wins over a terminal');
	}

	/**
	 * End to end: a walk over more files than the heartbeat interval prints no
	 * `scanned` line into a pipe, and prints them again under `HXQ_PROGRESS=1`.
	 *
	 * The suite's own stderr is a pipe, which is exactly the condition under
	 * test — so this asserts the DEFAULT, not a contrived one.
	 */
	public function testAWalkIntoAPipeIsSilentUnlessAskedOtherwise(): Void {
		#if (sys || nodejs)
		final files: Array<{ name: String, source: String }> = [
			for (i in 0...FILES_PAST_INTERVAL) { name: 'F$i.hx', source: 'class F$i { var progressProbeField: Int = $i; }\n' }
		];
		final dir: String = CliFixture.writeDir('progresstty', files);
		final savedProgress: Null<String> = Sys.getEnv('HXQ_PROGRESS');
		final savedNoProgress: Null<String> = Sys.getEnv('HXQ_NO_PROGRESS');
		Sys.putEnv('HXQ_PROGRESS', '');
		Sys.putEnv('HXQ_NO_PROGRESS', '');
		final quiet: String = CliFixture.captureStderr(() -> Cli.run(['lit', 'progressProbeField', dir]));
		Sys.putEnv('HXQ_PROGRESS', '1');
		final loud: String = CliFixture.captureStderr(() -> Cli.run(['lit', 'progressProbeField', dir]));
		Sys.putEnv('HXQ_PROGRESS', savedProgress ?? '');
		Sys.putEnv('HXQ_NO_PROGRESS', savedNoProgress ?? '');
		CliFixture.removeDir(dir);
		#if nodejs
		Assert.isFalse(quiet.indexOf('scanned') >= 0, 'a redirected walk stays silent: $quiet');
		Assert.stringContains('scanned 25/$FILES_PAST_INTERVAL files', loud);
		Assert.stringContains('scanned $FILES_PAST_INTERVAL/$FILES_PAST_INTERVAL files', loud);
		#end
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	/**
	 * `HXQ_NO_PROGRESS` predates the TTY gate and still forces silence — the
	 * callers that merge streams with `2>&1` set it, and they must keep working.
	 */
	public function testTheLegacyVariableStillForcesSilence(): Void {
		Assert.isFalse(CliIo.progressEnabled(null, true, true), 'HXQ_NO_PROGRESS beats a terminal');
	}

}
