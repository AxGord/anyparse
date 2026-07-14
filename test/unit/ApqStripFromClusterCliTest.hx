package unit;

import utest.Assert;
import utest.Test;
import anyparse.query.Cli;
#if sys
import sys.FileSystem;
import sys.io.File;
#end

/**
 * `apq strip --from-cluster <key>` — recon-walk-driven multi-file
 * apply. The direct complement of `apq recon --predict-strip`: predict
 * gives an upper-bound, `--from-cluster` does the actual sweep apply
 * across every file in a named cluster.
 *
 * Tests follow the same exit-code-only style as
 * `ApqReconCliTest` — stdout text is not asserted (the existing recon
 * tests verified manually against the haxe-formatter fork on disk).
 */
@:nullSafety(Strict)
class ApqStripFromClusterCliTest extends Test {

	#if sys
	private static var counter: Int = 0;
	#end
	public function testFromClusterRequiresCorpusRoot(): Void {
		#if sys
		final saved: Null<String> = Sys.getEnv('ANYPARSE_HXFORMAT_FORK');
		Sys.putEnv('ANYPARSE_HXFORMAT_FORK', '');
		Assert.equals(
			1, Cli.run(['strip', '--from-cluster', 'X', '--delete', 'foo']),
			'--from-cluster without a corpus root (positional or env) is a runtime error'
		);
		if (saved != null) Sys.putEnv('ANYPARSE_HXFORMAT_FORK', saved);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testFromClusterMissingDirIsRuntimeError(): Void {
		#if sys
		Assert.equals(
			1, Cli.run(['strip', '--from-cluster', 'X', '/no/such/dir/xyz123', '--delete', 'foo']),
			'--from-cluster with a non-existent root is a runtime error'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testFromClusterRequiresSubstitution(): Void {
		#if sys
		final dir: String = mkTempDir('apq_strip_fc_no_subs');
		Assert.equals(
			2, Cli.run(['strip', '--from-cluster', 'X', dir]), '--from-cluster without --replace/--with or --delete is a usage error'
		);
		cleanupDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testFromClusterMultiplePositionalsIsUsageError(): Void {
		#if sys
		Assert.equals(
			2, Cli.run(['strip', '--from-cluster', 'X', '/a', '/b', '--delete', 'foo']),
			'--from-cluster takes at most one positional (the corpus root)'
		);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testFromClusterEmptyCorpusIsCleanExit(): Void {
		#if sys
		final dir: String = mkTempDir('apq_strip_fc_empty');
		// Empty corpus → recon walk finds 0 skip-parse files → cluster
		// key never matches. resolveStripFromCluster surfaces the
		// no-key path (runtime). Mirrors `recon --cluster` semantics.
		Assert.equals(
			1, Cli.run(['strip', '--from-cluster', 'anything', dir, '--delete', 'foo']),
			'--from-cluster on an empty corpus is a runtime exit (no matching cluster key)'
		);
		cleanupDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	public function testFromClusterUnknownKeyIsRuntimeError(): Void {
		#if sys
		final dir: String = mkTempDir('apq_strip_fc_unknown_key');
		File.saveContent('$dir/bad.hxtest', brokenHxtest());
		Assert.equals(
			1, Cli.run(['strip', '--from-cluster', 'xyz-not-a-real-key', dir, '--delete', 'foo']),
			'--from-cluster with a missing cluster key is a runtime error'
		);
		cleanupDir(dir);
		#else
		Assert.pass('non-sys target');
		#end
	}

	#if sys
	private static function mkTempDir(prefix: String): String {
		counter++;
		final tmp: Null<String> = Sys.getEnv('TMPDIR');
		final base: String = (tmp != null && tmp.length > 0) ? stripTrailingSlash((tmp: String)) : '/tmp';
		final dir: String = '$base/${prefix}_${Sys.time()}_$counter';
		FileSystem.createDirectory(dir);
		return dir;
	}
	private static function cleanupDir(dir: String): Void {
		if (!FileSystem.exists(dir)) return;
		for (entry in FileSystem.readDirectory(dir)) {
			final p: String = '$dir/$entry';
			if (FileSystem.isDirectory(p))
				cleanupDir(p);
			else
				FileSystem.deleteFile(p);
		}
		FileSystem.deleteDirectory(dir);
	}
	private static inline function stripTrailingSlash(p: String): String {
		return StringTools.endsWith(p, '/') ? p.substring(0, p.length - 1) : p;
	}
	private static inline function brokenHxtest(): String {
		return '{}\n---\n\nclass C { var x:\n\n---\n\nclass C {\n\tvar x:Int;\n}\n';
	}
	#end

}
