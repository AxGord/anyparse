package anyparse.check.oracle;

import anyparse.check.oracle.ReachBuildsCache.ReachBuildsKey;
import anyparse.check.oracle.ReachDefinesProbe.DefinesProbe;
import anyparse.query.OracleProvider.StartedProbe;
import anyparse.query.ReachLiveness.ReachBuilds;

/**
 * The one answer to "how does a run's probe of the builds pair with their stored record": the key is taken before the
 * compiles begin and the builds are stored under it when they are read, so a tree that moved meanwhile stores nothing.
 */
@:nullSafety(Strict)
final class ReachBuildsRun implements StartedProbe<ReachBuilds> {

	/** The define probe compiling. */
	public final probe: DefinesProbe;

	private final _oracles: Array<OracleConfig>;
	private final _key: Null<ReachBuildsKey>;

	public function new(oracles: Array<OracleConfig>) {
		_oracles = oracles;
		_key = ReachBuildsCache.fingerprint(oracles);
		probe = ReachDefinesProbe.start(oracles);
	}

	public function finish(): Null<ReachBuilds> {
		final found: Null<ReachBuilds> = ReachDefinesProbe.finish(probe);
		ReachBuildsCache.store(_oracles, _key, found);
		return found;
	}

	public function abandon(): Void {
		ReachDefinesProbe.abandon(probe);
	}

	/** The builds of `oracles`, probed now and stored under the input they read. */
	public static function probeNow(oracles: Array<OracleConfig>): Null<ReachBuilds> {
		final key: Null<ReachBuildsKey> = ReachBuildsCache.fingerprint(oracles);
		final found: Null<ReachBuilds> = ReachDefinesProbe.probeAll(oracles);
		ReachBuildsCache.store(oracles, key, found);
		return found;
	}

}
