package anyparse.query;

import anyparse.query.ImportBindings.ImportBinding;
import anyparse.query.ImportOrder.ImportLine;

using Lambda;

/**
 * Which WILDCARD import lines may sit inside an import RUN as ordinary members — sorted like any
 * other line by `import-order`, and offered as a slot by the insert seat (`ImportOrder.runsIn`).
 *
 * A wildcard used to END every run it touched, so `import tink.unit.Assert.*;` above a sorted
 * block was a fixed point no finding could describe. It may join the run exactly when NO
 * permutation of the run can change what any simple name means: it binds a set the index can
 * enumerate, and against every other member no RANK holds a name both lines bind, or one the
 * other line's unlisted set cannot rule out. The ranks, the measured precedence behind them and
 * the residual limit are `ImportBindings`' — the one reader `import-order`'s own plain-pair refusal
 * asks too, so a wildcard and an explicit import are judged by the same names. In short:
 *
 *  - a package wildcard binds the MODULE names of its package, at a rank every explicit import
 *    outranks in either order — only another package wildcard can share one with it;
 *  - a field wildcard binds every static its type DECLARES (private ones too, not the inherited
 *    ones), every enum constructor and every abstract value, at the rank of the module-level
 *    fields and field imports — the LAST of them wins — while the constructors and abstract values
 *    an explicit TYPE import brings in outrank it in either order;
 *  - a statement outside the run keeps its position relative to every member under any
 *    permutation of the run, so `import.hx`, same-package and module-local types are not
 *    questions this gate has to ask.
 *
 * POSITIVE whitelist — a wildcard the index cannot enumerate stays a run boundary (the pre-gate
 * reading): a package no indexed module belongs to; a field wildcard whose type does not resolve
 * to exactly one declaration, is a `typedef`, carries a build macro, or has any supertype or
 * interface. A wildcard beside an explicit member whose value names cannot be listed (an
 * unindexed module, an unparseable module source) is a boundary too whenever it binds a value at
 * that member's rank. The index's own residual: a package split across a root the index does not
 * hold, and a GLOBAL build macro (`--macro addGlobalMetadata`) adding statics no source spells.
 *
 * A wildcard that fails is cut out of the run together with the lines that move with it, which
 * splits the run there. One pass decides every line: a cut only removes neighbours, so it never
 * turns a wildcard that passed into one that fails.
 */
@:nullSafety(Strict)
final class WildcardImportGate {

	/** The reader every import-moving check shares — what each line binds, by rank. */
	private final _bindings: ImportBindings;

	public function new(bindings: ImportBindings) {
		_bindings = bindings;
	}

	/**
	 * `run` — directly adjacent plain AND wildcard lines — split into the runs it really is: every
	 * wildcard that may not join is cut out, and a piece left holding wildcards alone stays a run
	 * only when it holds two or more. A run with no wildcard is returned as is, and a lone wildcard
	 * is no run at all — neither ever asks the index.
	 */
	public function split(run: Array<ImportLine>): Array<Array<ImportLine>> {
		if (!run.exists(line -> isWildcard(line.path))) return [run];
		if (run.length == 1) return [];
		final pieces: Array<Array<ImportLine>> = [];
		var current: Array<ImportLine> = [];
		for (line in run) {
			if (!isWildcard(line.path) || joins(line, run)) {
				current.push(line);
				continue;
			}
			if (current.length > 0) pieces.push(current);
			current = [];
		}
		if (current.length > 0) pieces.push(current);
		return pieces.filter(piece -> piece.length > 1 || !isWildcard(piece[0].path));
	}

	/**
	 * Whether the wildcard `line` may stay in `piece`: it binds something the index can enumerate, and
	 * against every other member no rank holds a name both bind or one the other cannot rule out
	 * (`ImportBindings.collision`).
	 */
	private function joins(line: ImportLine, piece: Array<ImportLine>): Bool {
		final mine: Null<ImportBinding> = _bindings.ofImport(line.path);
		if (mine == null) return false;
		for (other in piece) if (other != line) {
			final theirs: Null<ImportBinding> = _bindings.ofImport(other.path);
			if (theirs == null || ImportBindings.collision(mine, line.path, theirs, other.path) != null) return false;
		}
		return true;
	}

	/** Whether `path` is a wildcard import's path. */
	public static inline function isWildcard(path: String): Bool {
		return ImportBindings.isWildcard(path);
	}

	/**
	 * The gate an insert seat holding only `plugin` can build: over the host's RESOLUTION index when
	 * the run carries one, else null — no index, no proof, and every wildcard stays a boundary.
	 */
	public static function forPlugin(plugin: GrammarPlugin): Null<WildcardImportGate> {
		final bindings: Null<ImportBindings> = ImportBindings.forPlugin(plugin);
		return bindings == null ? null : new WildcardImportGate(bindings);
	}

}
