package devkit;

import anyparse.core.TempScratch;
import haxe.Exception;
import haxe.io.Path;

/**
 * A scratch directory of this run's own under the temp root (`mkdtemp`, so no other process can have named it first),
 * stamped with this process's pid the way `devkit.TmpLifecycle` reads it: a run SIGKILLed before `dispose` leaves a
 * directory the next sweep reclaims. Owned by whoever created it — nothing process-wide keeps a list of them.
 */
@:nullSafety(Strict)
final class TempDir {

	/** The basename prefix `devkit.TmpLifecycle` knows this tool's directories by. */
	public static inline final PREFIX: String = 'apq-dev';

	/** The owner stamp the sweep reads (`TMPL_STAMP`). */
	public static inline final STAMP: String = '.apq-owner';

	public final path: String;

	private function new(path: String) {
		this.path = path;
	}

	/** Remove the directory and everything in it; removing it twice is harmless. */
	public inline function dispose(): Void {
		js.Syntax.code("require('fs').rmSync({0}, { recursive: true, force: true })", path);
	}

	/** The path of `name` inside this directory. */
	public function file(name: String): String {
		return Path.join([path, name]);
	}

	/** A new, empty, stamped directory. */
	public static function create(): TempDir {
		final dir: String = js.node.Fs.mkdtempSync(Path.join([TempScratch.root(), '$PREFIX.']));
		sys.io.File.saveContent(Path.join([dir, STAMP]), 'pid ${js.Node.process.pid}\ntool $PREFIX\nstarted ${Std.int(Sys.time())}\n');
		return new TempDir(dir);
	}

	/** `body` over a new directory that is removed once `body` returns or throws. */
	public static function with<T>(body: TempDir -> T): T {
		final dir: TempDir = create();
		final result: T = try {
			body(dir);
		} catch (exception: Exception) {
			dir.dispose();
			throw exception;
		};
		dir.dispose();
		return result;
	}

}
