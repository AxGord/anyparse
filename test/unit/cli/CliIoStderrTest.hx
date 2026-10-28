package unit.cli;

import anyparse.query.cli.CliIo;
import haxe.Exception;

/**
 * `CliIo.stderr` itself goes through the retry loop: a write to fd 2 that meets a full pipe is offered again from the
 * offset still owed, and a short write is continued at the byte it stopped on.
 *
 * The text is non-ASCII on purpose — the offsets are BYTE offsets into the encoded text, and a character count would
 * land inside a different place. A `stderr` that wrote through `Sys.stderr()` again would lose the first write's retry
 * (the exception escapes) and fail the exact-bytes assertion.
 */
@:nullSafety(Strict)
class CliIoStderrTest extends Test {

	public function testStderrRetriesABlockedWriteAndContinuesAShortOne(): Void {
		#if nodejs
		final text: String = 'é…';
		final offsets: Array<Int> = [];
		final bytes: Array<js.node.Buffer> = [];
		final fs: Dynamic = js.Syntax.code('require("fs")'); // noqa: avoid-dynamic
		final original: Dynamic = fs.writeSync; // noqa: avoid-dynamic
		fs.writeSync = (fd: Int, data: js.node.Buffer, offset: Int, length: Int) -> {
			if (fd != 2) return Reflect.callMethod(null, original, [fd, data, offset, length]);
			offsets.push(offset);
			if (offsets.length == 1) throw new Exception('write EAGAIN', null, { code: 'EAGAIN' });
			final taken: Int = offsets.length == 2 ? 3 : length;
			bytes.push(data.slice(offset, offset + taken));
			return taken;
		};
		try CliIo.stderr(text) catch (exception: Exception) {
			fs.writeSync = original;
			throw exception;
		}
		fs.writeSync = original;
		Assert.same([0, 0, 3], offsets);
		Assert.equals(text, js.node.Buffer.concat(bytes).toString('utf8'));
		#else
		Assert.pass('fd 2 writes need the node target');
		#end
	}

}
