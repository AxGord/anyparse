package anyparse.query.cli;

import anyparse.query.ConfigFinder;
import haxe.io.Path;

/**
 * The one answer to "does a read-only run protect this path": `APQ_READ_ONLY` guards the tree a reviewing agent
 * judges, not the scratch directories its tools write beside it.
 *
 * The protected tree is `APQ_READ_ONLY_ROOT` when set, else the git work tree holding the process's working
 * directory. Outside any work tree nothing is protected: a harness runs the engine in a scratch directory of its
 * own, and a run that must guard such a directory names it with the variable. A path counts by its identity
 * (`FileIdentity.realPath`), so a symlink or a `..` cannot walk a write out of the tree. Nothing is cached: the root
 * is read from the environment at each ask.
 */
@:nullSafety(Strict)
final class ReadOnlyScope {

	/** The variable naming the protected tree explicitly, for a run whose working directory is not inside it. */
	public static inline final ROOT_ENV: String = 'APQ_READ_ONLY_ROOT';

	/** Whether `path` lies inside the protected tree (the tree itself included). */
	public static function protects(path: String): Bool {
		#if (sys || nodejs)
		final tree: Null<String> = rootDirectory();
		if (tree == null) return false;
		final root: String = Path.addTrailingSlash(FileIdentity.realPath(tree));
		final target: String = FileIdentity.realPath(path);
		return Path.addTrailingSlash(target).indexOf(root) == 0;
		#else
		return false;
		#end
	}

	#if (sys || nodejs)
	/** The directory the protected tree is rooted at. */
	private static function rootDirectory(): Null<String> {
		final declared: Null<String> = Sys.getEnv(ROOT_ENV);
		return declared != null && declared != '' ? declared : ConfigFinder.projectRoot(Sys.getCwd(), ConfigFinder.REPOSITORY_MARKERS);
	}
	#end

}
