package unit.cli;

import anyparse.query.cli.CliIo;
import haxe.Exception;

/**
 * `CliIo.writeFully`, the loop under `CliIo.stderr`: a write that meets a full pipe (`EAGAIN`) is offered again from
 * the offset still owed, and nothing else is swallowed.
 *
 * The writer is a substitute that fails and truncates on a script, so the contract is stated against exact bytes: a
 * retry that restarted at the beginning, or skipped the failed call's share, shows as a different output.
 */
@:nullSafety(Strict)
class CliIoWriteFullyTest extends Test {

	private static final TEXT: String = 'abcdefghij';

	public function testBlockedWritesAreRetriedFromTheOffsetOwed(): Void {
		final out: StringBuf = new StringBuf();
		final script: Array<String> = ['ok', 'EAGAIN', 'EAGAIN', 'ok', 'EAGAIN', 'ok'];
		var waits: Int = 0;
		CliIo.writeFully(TEXT.length, at -> {
			final step: String = script.shift() ?? 'ok';
			if (step == 'EAGAIN') throw native('EAGAIN');
			final n: Int = Math.round(Math.min(4, TEXT.length - at));
			out.add(TEXT.substr(at, n));
			return n;
		}, () -> waits++);
		Assert.equals(TEXT, out.toString());
		Assert.equals(3, waits);
	}

	public function testAWriteThatNeverBlocksNeverWaits(): Void {
		var calls: Int = 0;
		CliIo.writeFully(TEXT.length, at -> {
			calls++;
			return TEXT.length - at;
		}, () -> Assert.fail('waited with nothing blocked'));
		Assert.equals(1, calls);
	}

	public function testNothingToWriteCallsNothing(): Void {
		CliIo.writeFully(0, at -> {
			Assert.fail('wrote nothing owed');
			return 0;
		}, () -> Assert.fail('waited with nothing owed'));
		Assert.pass();
	}

	public function testAnyOtherFailurePropagatesWithoutWaiting(): Void {
		for (code in ['EPIPE', 'EACCES', 'ENOSPC']) {
			var thrown: Null<Exception> = null;
			try
				CliIo.writeFully(TEXT.length, at -> throw native(code), () -> Assert.fail('waited on $code'))
			catch (exception: Exception)
				thrown = exception;
			Assert.notNull(thrown, code);
			Assert.equals(code, thrown == null ? '' : Reflect.field(thrown.native, 'code'));
		}
	}

	public function testAWriteThatMakesNoProgressIsAnErrorNotARetry(): Void {
		var calls: Int = 0;
		var thrown: Null<Exception> = null;
		try
			CliIo.writeFully(TEXT.length, at -> {
				calls++;
				return 0;
			}, () -> Assert.fail('waited on a write that answered nothing'))
		catch (exception: Exception)
			thrown = exception;
		Assert.notNull(thrown);
		Assert.equals(1, calls);
	}

	private static function native(code: String): Exception {
		return new Exception('write $code', null, { code: code });
	}

}
