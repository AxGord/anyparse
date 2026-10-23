package unit.cli;

import anyparse.query.cli.CodeCacheLauncher;
import devkit.TempDir;
import js.Node;
import js.node.Buffer;
import js.node.ChildProcess;
import js.node.Fs.Fs;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * The code-cache launcher (`bin/apq-launch.js`): a cache is offered to V8 only when it was filed under this binary's
 * content and this runtime and is intact, it is published by rename, and a run of an engine rebuilt under it saves
 * nothing. The `guard` half runs the built launcher as a process — output, exit status, stack positions, concurrent
 * writers — and passes without a word where no launcher is built.
 */
@:nullSafety(Strict)
final class CodeCacheLauncherTest extends Test {

	/** The global a probe engine assigns at its top level. */
	private static inline final PROBE: String = '__apqCodeCacheProbe';

	/** The launcher a build writes beside the engine. */
	private static inline final LAUNCHER: String = 'bin/apq-launch.js';

	private static inline final ENGINE: String = 'bin/apq.js';

	/**
	 * A rebuild whose source has the SAME LENGTH as the cached one gets no cache: V8 checks only the length, and would
	 * run the old engine's top level in place of the new one.
	 */
	@:pin('control')
	@:killer('M-CODE-CACHE-KEY-IGNORES-SOURCE')
	public function testASameLengthRebuildNeverRunsTheOldEngine(): Void {
		TempDir.with(dir -> {
			final binary: String = dir.file('apq.js');
			File.saveContent(binary, probeSource(dir.path, 'A'));
			final first: CompiledEngine = CodeCacheLauncher.compile(binary, true);
			CodeCacheLauncher.run(first.script, binary);
			Assert.equals(CacheUse.Miss, first.cache, 'nothing was cached yet');
			Assert.isTrue(CodeCacheLauncher.persist(first, binary), 'the first run saves its cache');
			File.saveContent(binary, probeSource(dir.path, 'B'));
			final second: CompiledEngine = CodeCacheLauncher.compile(binary, true);
			CodeCacheLauncher.run(second.script, binary);
			Assert.equals(CacheUse.Miss, second.cache, 'the cache of the old source is not offered');
			Assert.equals('${dir.path}B', probe(), 'the rebuilt engine runs');
		});
	}

	/** A cache filed under another node, V8 or flag set is not read, and the tag names the running node and its flags. */
	@:pin('control')
	@:killer('M-CODE-CACHE-KEY-IGNORES-RUNTIME')
	@:killer('M-CODE-CACHE-KEY-IGNORES-EXECPATH')
	public function testACacheFiledUnderAnotherRuntimeIsNotRead(): Void {
		TempDir.with(dir -> {
			final path: String = dir.file('apq.js.v8cache');
			final source: Buffer = Buffer.from('engine');
			final payload: Buffer = Buffer.from('bytecode');
			CodeCacheLauncher.writeCache(path, CodeCacheLauncher.cacheKey(source, 'node one'), payload);
			Assert.equals('bytecode', '${CodeCacheLauncher.readCache(path, CodeCacheLauncher.cacheKey(source, 'node one'))}');
			Assert.isNull(CodeCacheLauncher.readCache(path, CodeCacheLauncher.cacheKey(source, 'node two')));
			final tag: String = CodeCacheLauncher.runtimeTag();
			Assert.isTrue(tag.contains(Node.process.version), tag);
			Assert.isTrue(tag.contains(Node.process.execArgv.join(' ')), tag);
			Assert.isTrue(tag.contains(Node.process.execPath), 'two node builds of one version string are told apart: $tag');
		});
	}

	/**
	 * A cache that is missing, truncated, foreign to the format or flipped in one payload byte reads as none: V8 does not
	 * verify a payload, and a damaged one can abort the process.
	 */
	@:pin('control')
	@:killer('M-CODE-CACHE-NO-CHECKSUM')
	public function testADamagedCacheIsNeverHandedToV8(): Void {
		TempDir.with(dir -> {
			final path: String = dir.file('apq.js.v8cache');
			final key: Buffer = CodeCacheLauncher.cacheKey(Buffer.from('engine'), 'node');
			Assert.isNull(CodeCacheLauncher.readCache(path, key), 'missing');
			final payload: Buffer = Buffer.from('a payload long enough to damage in the middle');
			CodeCacheLauncher.writeCache(path, key, payload);
			final whole: Buffer = Fs.readFileSync(path);
			Assert.equals('$payload', '${CodeCacheLauncher.readCache(path, key)}', 'intact');
			final flipped: Buffer = Buffer.from(whole);
			final middle: Int = whole.length - Std.int(payload.length / 2);
			flipped[middle] = flipped[middle] ^ 1;
			Fs.writeFileSync(path, flipped);
			Assert.isNull(CodeCacheLauncher.readCache(path, key), 'one payload byte flipped');
			Fs.writeFileSync(path, whole.slice(0, whole.length - 1));
			Assert.isNull(CodeCacheLauncher.readCache(path, key), 'truncated');
			Fs.writeFileSync(path, Buffer.from('not a cache at all, though long enough to hold a header of one'));
			Assert.isNull(CodeCacheLauncher.readCache(path, key), 'foreign');
		});
	}

	/**
	 * A cache is replaced by renaming a finished file over it, never rewritten in place — so a hard link to the old file
	 * keeps the old content, and no temporary file is left behind.
	 */
	@:pin('control')
	@:killer('M-CODE-CACHE-WRITE-IN-PLACE')
	public function testACacheIsReplacedByRenameNeverRewrittenInPlace(): Void {
		TempDir.with(dir -> {
			final path: String = dir.file('apq.js.v8cache');
			final alias: String = dir.file('alias');
			final key: Buffer = CodeCacheLauncher.cacheKey(Buffer.from('engine'), 'node');
			CodeCacheLauncher.writeCache(path, key, Buffer.from('old'));
			Fs.linkSync(path, alias);
			CodeCacheLauncher.writeCache(path, key, Buffer.from('new'));
			Assert.equals('old', '${CodeCacheLauncher.readCache(alias, key)}', 'the old file is untouched');
			Assert.equals('new', '${CodeCacheLauncher.readCache(path, key)}', 'the path names the new one');
			Assert.equals(0, FileSystem.readDirectory(dir.path).filter(name -> name.endsWith('.tmp')).length);
		});
	}

	/** A run of an engine rewritten on disk since it was read saves no cache: it would replace a fresh build's. */
	@:pin('control')
	@:killer('M-CODE-CACHE-PERSIST-IGNORES-STAMP')
	public function testARunOfAnEngineRebuiltUnderItSavesNoCache(): Void {
		TempDir.with(dir -> {
			final binary: String = dir.file('apq.js');
			File.saveContent(binary, probeSource(dir.path, 'A'));
			final engine: CompiledEngine = CodeCacheLauncher.compile(binary, true);
			CodeCacheLauncher.run(engine.script, binary);
			File.saveContent(binary, probeSource(dir.path, 'A') + '// rebuilt\n');
			Assert.isFalse(CodeCacheLauncher.persist(engine, binary));
			Assert.isFalse(FileSystem.exists(CodeCacheLauncher.cachePath(binary)));
		});
	}

	/**
	 * The built launcher answers as the engine does — same output, same exit status — and after a warm run it reads its
	 * cache instead of compiling the source.
	 */
	@:pin('guard')
	public function testTheLauncherAnswersAsTheEngineDoes(): Void {
		withLauncher((launcher, dir) -> {
			final binary: String = dir.file('apq.js');
			File.copy(ENGINE, binary);
			final fixture: String = dir.file('Fixture.hx');
			File.saveContent(fixture, 'class Fixture {\n\tfunction f():Int return 1;\n}\n');
			final warm: Run = node([launcher, CodeCacheLauncher.WARM, binary]);
			Assert.equals(0, warm.status, warm.stderr);
			Assert.isTrue(warm.stdout.contains('warmed'), warm.stdout);
			for (args in [
				['fmt', '--lang', 'haxe', fixture],
				['ast', '--lang', 'haxe', fixture],
				['no-such-command']
			]) {
				final plain: Run = node([binary].concat(args));
				final launched: Run = node([launcher, binary].concat(args));
				Assert.equals(plain.status, launched.status, args.join(' '));
				Assert.equals(plain.stdout, launched.stdout, args.join(' '));
				Assert.isTrue(launched.stderr.contains('apq-launch: code cache hit'), launched.stderr);
			}
		});
	}

	/**
	 * An error the engine throws reports the engine's own file and line, and the exit status node gives it — on a cache
	 * hit too: V8 keeps the script name in a cache, so a cache written beside another copy of the engine must not be read.
	 */
	@:pin('guard')
	public function testAnEngineErrorKeepsItsOwnFileAndLine(): Void {
		withLauncher((launcher, dir) -> {
			final first: String = dir.file('a/apq.js');
			final second: String = dir.file('b/apq.js');
			FileSystem.createDirectory(dir.file('a'));
			FileSystem.createDirectory(dir.file('b'));
			File.saveContent(first, '// header\nthrow new Error("boom");\n');
			final plain: Run = node([first]);
			Assert.equals(plain.status, node([launcher, first]).status);
			File.copy(first, second);
			File.copy(CodeCacheLauncher.cachePath(first), CodeCacheLauncher.cachePath(second));
			Assert.equals(plain.status, node([launcher, second]).status, 'the copy runs, and writes a cache of its own');
			final hit: Run = node([launcher, second]);
			Assert.isTrue(hit.stderr.contains('apq-launch: code cache hit'), hit.stderr);
			Assert.isTrue(hit.stderr.contains('${FileSystem.fullPath(second)}:2'), hit.stderr);
			Assert.isFalse(hit.stderr.contains(FileSystem.fullPath(first)), hit.stderr);
		});
	}

	/** Calls that all find no cache and save one at once leave one whole cache, which the next call reads. */
	@:pin('guard')
	public function testConcurrentCallsLeaveOneWholeCache(): Void {
		withLauncher((launcher, dir) -> {
			final binary: String = dir.file('apq.js');
			File.saveContent(binary, probeSource(dir.path, 'C'));
			final calls: String = [for (_ in 0...8) 'node "$launcher" "$binary" &'].join(' ');
			ChildProcess.spawnSync('sh', ['-c', '$calls wait']);
			Assert.isTrue(node([launcher, binary]).stderr.contains('apq-launch: code cache hit'));
			Assert.equals(0, FileSystem.readDirectory(dir.path).filter(name -> name.endsWith('.tmp')).length);
		});
	}

	/**
	 * A warm run that cannot run, or cannot save its cache, still exits 0 — a build never fails on its cache — and says it
	 * did not warm rather than that it did.
	 */
	@:pin('guard')
	public function testAWarmRunThatCannotRunStillExitsZero(): Void {
		withLauncher((launcher, dir) -> {
			final missing: Run = node([launcher, CodeCacheLauncher.WARM, dir.file('missing.js')]);
			Assert.equals(0, missing.status);
			Assert.isTrue(missing.stdout.contains('not warmed'), missing.stdout);
			final locked: String = dir.file('locked');
			FileSystem.createDirectory(locked);
			File.saveContent('$locked/apq.js', '// engine\n');
			Fs.chmodSync(locked, '555');
			final unsaved: Run = node([launcher, CodeCacheLauncher.WARM, '$locked/apq.js']);
			Fs.chmodSync(locked, '755');
			Assert.equals(0, unsaved.status);
			Assert.isTrue(unsaved.stdout.contains('not warmed'), unsaved.stdout);
		});
	}

	/**
	 * A cache copied beside another copy of the engine is not read there, though the bytes match: V8 keeps the path it
	 * compiled in the cache, and a hit would report the other copy's file in every stack.
	 */
	@:pin('control')
	@:killer('M-CODE-CACHE-KEY-IGNORES-PATH')
	public function testACacheCopiedBesideAnotherEngineIsNotRead(): Void {
		TempDir.with(dir -> {
			final first: String = dir.file('apq.js');
			final second: String = dir.file('copy.js');
			File.saveContent(first, probeSource(dir.path, 'P'));
			final engine: CompiledEngine = CodeCacheLauncher.compile(first, true);
			CodeCacheLauncher.run(engine.script, first);
			Assert.isTrue(CodeCacheLauncher.persist(engine, first));
			File.copy(first, second);
			File.copy(CodeCacheLauncher.cachePath(first), CodeCacheLauncher.cachePath(second));
			Assert.equals(CacheUse.Miss, CodeCacheLauncher.compile(second, true).cache);
		});
	}

	/** A probe engine of `token` and `tail`: two tails of one length give two sources of one length. */
	private static function probeSource(token: String, tail: String): String {
		return '// probe\nglobalThis.$PROBE = "$token$tail";\n';
	}

	/** What the last probe engine run assigned. */
	private static function probe(): String {
		return '${Reflect.field(js.Lib.global, PROBE)}';
	}

	/** `node <args>` with the cache trace on, run to its end. */
	private static function node(args: Array<String>): Run {
		final env: haxe.DynamicAccess<String> = Reflect.copy(Node.process.env) ?? {};
		env[CodeCacheLauncher.TRACE_ENV] = '1';
		final result: Dynamic = ChildProcess.spawnSync('node', args, cast { encoding: 'utf8', env: env }); // noqa: avoid-dynamic
		return { status: result.status, stdout: '${result.stdout}', stderr: '${result.stderr}' };
	}

	/**
	 * `body` over the built launcher and a scratch directory, or a pass without a word where none is built — a test build
	 * alone writes no launcher, and a mutation track never has one.
	 */
	private static function withLauncher(body: (launcher:String, dir:TempDir) -> Void): Void {
		if (!FileSystem.exists(LAUNCHER) || !FileSystem.exists(ENGINE)) {
			Assert.pass('$LAUNCHER is not built — the process half needs `haxe bin/apq-js.hxml`');
			return;
		}
		final launcher: String = FileSystem.fullPath(LAUNCHER);
		TempDir.with(dir -> body(launcher, dir));
	}

}

/** One finished `node` process. */
private typedef Run = {

	final status: Null<Int>;

	final stdout: String;

	final stderr: String;

};
