package anyparse.query.cli;

import anyparse.check.LintConfig;
import anyparse.check.common.members.FieldInitAtDeclaration;
import anyparse.grammar.json.JsonFormat;
import anyparse.query.Cli;
import anyparse.query.ExitCode;
import sys.io.File;

/**
 * The one answer to "run several `apq` invocations in one engine process": `apq --batch <calls.json> <answers.json>` runs
 * each call through `Cli.run` the way the process entry does, in the call's working directory, with its stdin, both output
 * streams and `process.exit` taken over for that call, and writes every call's exit status and streams.
 * A call answers as a fresh process would only because the process-scoped state a call can observe is forgotten before it
 * (`forgetRun`, docs/design-principles.md § 2): a call whose answer differs from its own process's is a state leak to fix there.
 * A call whose config runs a compiler oracle is outside that promise: the generation holds it takes last until the batch exits.
 */
@:nullSafety(Strict)
final class BatchRun {

	/** The argv head that selects this entry instead of a command. */
	public static inline final FLAG: String = '--batch';

	/** The field of the value a redirected `process.exit` throws, holding the status it was called with. */
	private static inline final EXIT_FIELD: String = 'apqBatchExit';

	/** The encoding of every stream and of the standard input a call is given. */
	private static inline final UTF8: String = 'utf8';

	/** `apq --batch <calls> <answers>`; the status is the batch's own, each call's status is in its answer. */
	public static function main(args: Array<String>): Int {
		if (args.length != 3) {
			CliIo.stderr('usage: apq ${FLAG} <calls.json> <answers.json>\n');
			return EXIT_USAGE;
		}
		final calls: Array<BatchCall> = BatchCallsParser.parse(CliIo.readFile(args[1])).calls;
		final answers: BatchAnswers = { answers: calls.map(answer) };
		File.saveContent(args[2], BatchAnswersWriter.write(answers, JsonFormat.instance.compactWriteOptions));
		return EXIT_OK;
	}

	/** One call, answered as its own process would answer it: exit status, standard output and standard error. */
	public static function answer(call: BatchCall): BatchAnswer {
		#if nodejs
		final out: Array<js.node.Buffer> = [];
		final err: Array<js.node.Buffer> = [];
		final home: String = Sys.getCwd();
		final restore: () -> Void = redirect(call.stdin ?? '', out, err);
		var status: Int = EXIT_RUNTIME;
		try {
			forgetRun();
			Sys.setCwd(call.cwd);
			status = Cli.entry(call.argv);
		} catch (exception: Exception) {
			final exit: Null<Int> = Reflect.field(exception.native, EXIT_FIELD);
			if (exit != null)
				status = exit;
			else
				err.push(js.node.Buffer.from('apq ${FLAG}: uncaught ${exception.details()}\n', UTF8));
		}
		restore();
		Sys.setCwd(home);
		return { status: status, out: text(out), err: text(err) };
		#else
		throw new UsageFailure('${FLAG} runs on nodejs only');
		#end
	}

	/**
	 * Forgets what earlier calls left in process-scoped state a call can observe: the `hxformat.json` found per directory (the tree
	 * may have changed since) and the warn-once ledgers (a second call must warn again). The parse tiers, the std index and the
	 * compiler probe are keyed by content or by the toolchain, so they answer every call alike and are kept.
	 */
	private static function forgetRun(): Void {
		FormatConfigDiscovery.forgetRun();
		LintConfig.warnedConfigs.resize(0);
		FieldInitAtDeclaration.skipsReported.resize(0);
	}

	#if nodejs
	/**
	 * Takes over standard output and error (the stream writes and a synchronous write to fd 1 or 2), standard input (a whole or a
	 * partial read of fd 0) and `process.exit` for one call; the function returned puts every one of them back.
	 */
	private static inline function redirect(stdin: String, out: Array<js.node.Buffer>, err: Array<js.node.Buffer>): () -> Void {
		return js.Syntax.code("(function (stdin, out, err, exitField) {
	const fs = require('fs');
	const proc = process;
	const saved = [proc.stdout.write, proc.stderr.write, fs.writeSync, fs.readFileSync, fs.readSync, proc.exit];
	const input = Buffer.from(stdin, 'utf8');
	let read = 0;
	const bytes = (data, encoding) => typeof data === 'string' ? Buffer.from(data, typeof encoding === 'string' ? encoding : 'utf8')
		: Buffer.from(Buffer.from(data.buffer, data.byteOffset, data.byteLength));
	const stream = into => function (data, encoding, done) {
		into.push(bytes(data, encoding));
		const callback = typeof encoding === 'function' ? encoding : done;
		if (typeof callback === 'function') callback();
		return true;
	};
	proc.stdout.write = stream(out);
	proc.stderr.write = stream(err);
	fs.writeSync = function (fd, data, a, b) {
		if (fd !== 1 && fd !== 2) return saved[2].apply(fs, arguments);
		let chunk;
		if (typeof data === 'string') chunk = bytes(data, b);
		else {
			const offset = typeof a === 'number' ? a : 0;
			const length = typeof b === 'number' ? b : data.byteLength - offset;
			chunk = Buffer.from(Buffer.from(data.buffer, data.byteOffset + offset, length));
		}
		(fd === 1 ? out : err).push(chunk);
		return chunk.length;
	};
	fs.readFileSync = function (path, options) {
		if (path !== 0 && path !== '/dev/stdin') return saved[3].apply(fs, arguments);
		read = input.length;
		const encoding = typeof options === 'string' ? options : options && options.encoding;
		return encoding ? input.toString(encoding) : Buffer.from(input);
	};
	fs.readSync = function (fd, buffer, a, b) {
		if (fd !== 0) return saved[4].apply(fs, arguments);
		const offset = typeof a === 'number' ? a : (a && a.offset) || 0;
		const length = typeof b === 'number' ? b : (a && a.length) || buffer.byteLength - offset;
		const n = input.copy(buffer, offset, read, Math.min(input.length, read + length));
		read += n;
		return n;
	};
	proc.exit = code => { throw { [exitField]: code == null ? (proc.exitCode || 0) : code }; };
	return () => {
		[proc.stdout.write, proc.stderr.write, fs.writeSync, fs.readFileSync, fs.readSync, proc.exit] = saved;
	};
})({0}, {1}, {2}, {3})", stdin, out, err, EXIT_FIELD);
	}

	/** What `chunks` hold, decoded as one text, so a character split across two writes reads whole. */
	private static function text(chunks: Array<js.node.Buffer>): String {
		return js.node.Buffer.concat(chunks).toString(UTF8);
	}
	#end

}
