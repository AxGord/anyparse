package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;
#if (sys || nodejs)
import sys.io.File;
import sys.FileSystem;
#end

/**
 * End-to-end probes for two read-only query additions:
 *
 *  - `apq source <file> [--range SPEC] [--number]` — RAW verbatim line
 *    emit with no AST parse. Range forms `L` / `L:L2` / `L:` / `:L2` are
 *    1-based inclusive and clamp to the file bounds; a missing file or a
 *    directory is a clean EXIT_RUNTIME; a malformed `--range` is
 *    EXIT_USAGE.
 *  - `apq meta '@:tag(arg)'` — inline arg filter on the annotation
 *    positional. Keeps only hits whose meta has a top-level argument that
 *    is the bare ident `arg` OR a call `arg(...)`. `@:fmt` is the driving
 *    case; the no-arg `@:fmt` form is unchanged.
 *
 * Mirrors `ApqPrefilterCliTest`: gated on `#if (sys || nodejs)` (the
 * default test binary is the `-lib hxnodejs` JS build where `sys` is NOT
 * defined), drives `Cli.run([...])`, and asserts the exit-code contract —
 * stdout is written directly via `Sys.print`, so byte-level output is
 * proven by the manual demo rather than intercepted here. Fixtures are
 * written via `sys.io.File` (the project's `CliFixture` is `#if sys`-only
 * and would no-op on this build).
 */
class ApqSourceMetaArgCliTest extends Test {

	#if (sys || nodejs)
	private static var counter: Int = 0;
	#end

	// ===== apq source =====

	public function testSourceWholeFileExitsOk(): Void {
		#if (sys || nodejs)
		final f: String = writeFile('a\nb\nc\nd\ne\n');
		Assert.equals(0, Cli.run(['source', f]));
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	public function testSourceRangeFormsExitOk(): Void {
		#if (sys || nodejs)
		final f: String = writeFile('a\nb\nc\nd\ne\n');
		Assert.equals(0, Cli.run(['source', f, '--range', '2:4']), 'L:L2 range');
		Assert.equals(0, Cli.run(['source', f, '--range', '3:']), 'L: to EOF');
		Assert.equals(0, Cli.run(['source', f, '--range', ':2']), ':L2 start');
		Assert.equals(0, Cli.run(['source', f, '--range', '4']), 'single L');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	public function testSourceNumberFlagExitsOk(): Void {
		#if (sys || nodejs)
		final f: String = writeFile('a\nb\nc\n');
		Assert.equals(0, Cli.run(['source', f, '--number']), '--number whole file');
		Assert.equals(0, Cli.run(['source', f, '--range', '2:3', '-n']), '-n alias with range');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	public function testSourceOutOfRangeClampsCleanly(): Void {
		#if (sys || nodejs)
		// Both bounds past EOF clamp to the last line — no crash, exit 0.
		final f: String = writeFile('a\nb\nc\n');
		Assert.equals(0, Cli.run(['source', f, '--range', '99:200']), 'past-EOF clamps');
		Assert.equals(0, Cli.run(['source', f, '--range', ':999']), 'past-EOF hi clamps');
		Assert.equals(0, Cli.run(['source', f, '--range', '0:1']), 'below-1 lo clamps');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	public function testSourceMissingFileIsRuntimeError(): Void {
		#if (sys || nodejs)
		Assert.equals(1, Cli.run(['source', '${tempDir()}/tmp_apq_src_definitely_absent_$counter.txt']));
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	public function testSourceMalformedRangeIsUsageError(): Void {
		#if (sys || nodejs)
		final f: String = writeFile('a\nb\n');
		Assert.equals(2, Cli.run(['source', f, '--range', 'foo']), 'non-int range');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	public function testSourceMissingFileArgIsUsageError(): Void {
		Assert.equals(2, Cli.run(['source']));
	}

	public function testSourceHelpExitsOk(): Void {
		Assert.equals(0, Cli.run(['source', '--help']));
	}

	public function testSourceLangFlagAcceptedAndIgnored(): Void {
		#if (sys || nodejs)
		// The hxq shim auto-injects `--lang haxe`; `source` does no parsing
		// so it must accept and ignore the flag rather than treat it (or its
		// value) as the file argument.
		final f: String = writeFile('only line\n');
		Assert.equals(0, Cli.run(['source', '--lang', 'haxe', f]));
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	// ===== apq meta '@:tag(arg)' inline arg filter =====

	public function testMetaArgFilterFindsPropagateExprPosition(): Void {
		#if (sys || nodejs)
		// A field carrying `@:fmt(propagateExprPosition)` matches; sibling
		// `@:fmt` fields without that arg do not. Both forms parse and the
		// walk exits 0 (a match) — proving the inline `(arg)` split does not
		// break the annotation tag itself.
		final f: String = writeFile(
			'class X {\n' + '  @:fmt(propagateExprPosition) var a:Int = 0;\n' + '  @:fmt(somethingElse) var b:Int = 0;\n' + '}\n'
		);
		Assert.equals(0, Cli.run(['meta', '@:fmt(propagateExprPosition)', f]));
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	public function testMetaArgFilterCalleeFormMatches(): Void {
		#if (sys || nodejs)
		// `@:tag(arg)` also matches a call-form top-level arg `arg(...)`
		// (callee match), not just the bare ident.
		final f: String = writeFile('class X {\n' + '  @:fmt(trailingComma(\'trailingCommaArrays\')) var a:Int = 0;\n' + '}\n');
		Assert.equals(0, Cli.run(['meta', '@:fmt(trailingComma)', f]));
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	public function testMetaNoArgFormUnchanged(): Void {
		#if (sys || nodejs)
		// Bare `@:fmt` (no inline arg) behaves exactly as before — every
		// `@:fmt` field is in scope, exit 0.
		final f: String = writeFile(
			'class X {\n' + '  @:fmt(propagateExprPosition) var a:Int = 0;\n' + '  @:fmt(somethingElse) var b:Int = 0;\n' + '}\n'
		);
		Assert.equals(0, Cli.run(['meta', '@:fmt', f]));
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	public function testMetaArgFilterNoMatchIsCleanEmpty(): Void {
		#if (sys || nodejs)
		// An inline arg that matches no top-level argument anywhere is a
		// clean "0 hits, exit 0" (nudge to stderr) — NOT a parse-failure
		// hard error. The substring `propagate` (a prefix of the real flag)
		// must NOT match: the filter is exact per arg, not a substring scan.
		final f: String = writeFile('class X {\n' + '  @:fmt(propagateExprPosition) var a:Int = 0;\n' + '}\n');
		Assert.equals(0, Cli.run(['meta', '@:fmt(zzzNoSuchFlag)', f]), 'unknown arg → empty');
		Assert.equals(0, Cli.run(['meta', '@:fmt(propagate)', f]), 'prefix is not a match');
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	public function testMetaArgFilterComposesWithOnKind(): Void {
		#if (sys || nodejs)
		// Inline arg filter composes with `--on` (decl-kind scope).
		final f: String = writeFile('class X {\n' + '  @:fmt(propagateExprPosition) var a:Int = 0;\n' + '}\n');
		Assert.equals(0, Cli.run(['meta', '@:fmt(propagateExprPosition)', '--on', 'VarMember', f]));
		FileSystem.deleteFile(f);
		#else
		Assert.pass('non-sys/nodejs target');
		#end
	}

	#if (sys || nodejs)
	private static function tempDir(): String {
		final tmp: Null<String> = Sys.getEnv('TMPDIR');
		if (tmp != null && tmp.length > 0) return StringTools.endsWith(tmp, '/') ? tmp.substring(0, tmp.length - 1) : tmp;
		return '/tmp';
	}

	private static function writeFile(source: String): String {
		counter++;
		final path: String = '${tempDir()}/tmp_apq_srcmeta_${Sys.time()}_$counter.hx';
		File.saveContent(path, source);
		return path;
	}
	#end

}
