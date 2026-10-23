package anyparse.core;

/**
 * The engine code a stored reach answer depends on (`ReachBuildsCache`) — the probe and the arguments it compiles
 * with, how its transcript is read and its paths resolved, the fingerprint and its read check, the store itself —
 * hashed when the engine compiles, so a record another engine wrote misses. A class of its own: a macro
 * types its class in the macro context, where the store's own dependencies cannot be built.
 */
final class ReachBuildsEngine {

	/** md5 of the sources a stored answer depends on, read at compile time. */
	public static macro function digest(): haxe.macro.Expr {
		final modules: Array<String> = [
			'anyparse/check/ReachDefinesProbe.hx',
			'anyparse/check/ReachBuildsCache.hx',
			'anyparse/query/ReachLiveness.hx',
			'anyparse/check/OracleCoverage.hx',
			'anyparse/check/OracleDeclaration.hx',
			'anyparse/check/CompilerOracle.hx',
			'anyparse/check/OracleCache.hx'
		];
		final sources: Array<String> = [for (m in modules) sys.io.File.getContent(haxe.macro.Context.resolvePath(m))];
		return macro $v{haxe.crypto.Md5.encode(sources.join('\n'))};
	}

}
