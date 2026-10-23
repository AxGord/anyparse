package anyparse.query;

import anyparse.query.ReachLiveness.ReachBuilds;
import anyparse.query.SymbolIndex.DeclBranch;
import anyparse.query.SymbolIndex.MemberInfo;
import anyparse.query.SymbolIndex.ResolvedType;

using Lambda;

/**
 * Which `#if` branches of a declaration the run's builds compile (`docs/typing-service.md`, step T6): the branches of
 * `TypeDeclInfo.branches` some declared build may take. A branch every build provably leaves out (`ReachLiveness.live`:
 * a condition the defines each build reported decide against it) is code no build of the project compiles, so an answer
 * about what the type is — an abstract's casts, its enum values, its operator overloads — need not agree with it.
 *
 * The builds are known only to a run that compiles them (`SymbolIndexHost.reachBuilds`: the compiler oracle's
 * configurations, declared to be every build the project ships). With none known, under `--no-oracle` included, every
 * branch is read: the configuration's own lists name only the defines the command line sets, never those a library or an
 * initialization macro adds, so a define they leave out is no evidence that no build sets it. The builds are asked for
 * only when a declaration with more than one branch is, and once.
 */
@:nullSafety(Strict)
final class BuildBranches {

	/** The text of each indexed file, by path. */
	private final _sourceOf: String -> Null<String>;

	/** What decides a branch's liveness under the run's builds, read on first demand; null when the run knows none. */
	private final _liveness: () -> Null<ReachLiveness>;

	/** Built by the owning `SymbolIndex`, over its `plugin` — the run's host, when it is one — and its files' texts. */
	public function new(plugin: GrammarPlugin, sourceOf: String -> Null<String>) {
		_sourceOf = sourceOf;
		final host: Null<SymbolIndexHost> = plugin is SymbolIndexHost ? cast plugin : null;
		final read: () -> Null<ReachBuilds> = host == null ? () -> null : host.reachBuilds;
		var asked: Bool = false;
		var held: Null<ReachLiveness> = null;
		_liveness = () -> {
			if (!asked) {
				asked = true;
				final builds: Null<ReachBuilds> = read();
				held = builds == null ? null : new ReachLiveness(plugin, builds.configurations);
			}
			held;
		};
	}

	/**
	 * The branches of `r` some declared build may compile, in source order: every branch of a declaration written once,
	 * of one when no build is known, and of one no build compiles at all (no build declares the type, and nothing about it
	 * is asked of a build).
	 */
	public function of(r: ResolvedType): Array<DeclBranch> {
		final all: Array<DeclBranch> = r.type.branches;
		if (all.length < 2) return all;
		final liveness: Null<ReachLiveness> = _liveness();
		final file: String = r.file.file;
		final source: Null<String> = _sourceOf(file);
		if (liveness == null || source == null) return all;
		final kept: Array<DeclBranch> = all.filter(b -> liveness.live(file, source, b.span));
		return kept.length == 0 ? all : kept;
	}

	/**
	 * The declarations of the member `name` of `r` some declared build may compile: those inside a branch `of` answers, a
	 * member-level `#if` alternative each — every one of them for a declaration written once.
	 */
	public function declarations(r: ResolvedType, name: String): Array<MemberInfo> {
		final all: Array<MemberInfo> = r.type.members.filter(m -> m.name == name);
		if (r.type.branches.length < 2) return all;
		final live: Array<DeclBranch> = of(r);
		return all.filter(m -> live.exists(b -> b.span.from <= m.declFrom && m.declFrom < b.span.to));
	}

}
