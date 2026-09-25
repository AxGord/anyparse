package anyparse.query;

import anyparse.query.CondDirectives.CondDirective;
import anyparse.query.CondRegionLiveness.DefineFacts;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.runtime.Span;

using Lambda;

/**
 * One build a reach answer must hold under — one `compilerOracle` configuration — as the defines that decide its
 * conditional compilation: `defined` holds for every file the build parses (set on the command line or by an
 * initialization macro), and `everDefined` is every define it set at any point, a build macro's included. A name
 * outside `everDefined` is never defined while the build parses anything, since the compiler never removes one.
 * `compiled` is every file it parses.
 */
typedef ReachConfiguration = {
	var name: String;
	var defined: Array<String>;
	var everDefined: Array<String>;

	/** The absolute, link-resolved path of every source file the build parses: no other file's code runs in it. */
	var compiled: Array<String>;

	/** Every type the build's runtime context typed, by its simple name and the `compiled` file that declares it. */
	var types: Array<{ name: String, file: String }>;
}

/**
 * The builds a reach answer must hold under, and the source of every file any of them parses — the library code
 * that can run at all, the per-target standard-library copies included.
 */
typedef ReachBuilds = {
	var configurations: Array<ReachConfiguration>;
	var library: Array<{ file: String, source: String }>;
}

/**
 * Which code of a file some configuration may compile, for a reach walk that may SKIP the rest: a conditional
 * branch every configuration provably does not take (`CondRegionLiveness.deadSpans`) runs in no build the answer
 * covers. With no configuration nothing is skipped, and a branch a configuration cannot decide stays live.
 */
@:nullSafety(Strict)
final class ReachLiveness {

	/** A possibly-dotted flag name in a condition's text. */
	private static final FLAG: EReg = ~/[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*/g;

	/** File -> the ranges no configuration compiles, and its directives' spans, computed on first demand. */
	private final _dead: Map<String, Array<Span>> = [];

	/** File -> the spans of its conditional-compilation directives, read with `_dead`. */
	private final _directives: Map<String, Array<Span>> = [];

	private final _plugin: GrammarPlugin;
	private final _shape: RefShape;
	private final _configurations: Array<ReachConfiguration>;

	public function new(plugin: GrammarPlugin, configurations: Array<ReachConfiguration>) {
		_plugin = plugin;
		_shape = plugin.refShape();
		_configurations = configurations;
	}

	/** Drop what was computed for `file`, whose text changed. */
	public function forget(file: String): Void {
		_dead.remove(file);
		_directives.remove(file);
	}

	/** Whether code at `span` of `file` (whose text is `source`) may be compiled by some configuration. */
	public function live(file: String, source: String, span: Null<Span>): Bool {
		if (span == null || _configurations.length == 0) return true;
		return deadOf(file, source).foreach(d -> !(span.from >= d.from && span.to <= d.to));
	}

	/**
	 * Whether the raw conditional region `span` of `file` holds code some configuration compiles: a non-blank byte
	 * outside every range no configuration compiles and outside every directive.
	 */
	public function holdsLiveCode(file: String, source: String, span: Span): Bool {
		if (_configurations.length == 0) return true;
		final skipped: Array<Span> = deadOf(file, source).concat(_directives[file] ?? []);
		skipped.sort((a, b) -> a.from - b.from);
		var i: Int = span.from;
		var si: Int = 0;
		while (i < span.to) {
			// past every skipped range that ends by `i`; one that holds `i` moves `i` to its end
			while (si < skipped.length && skipped[si].to <= i) si++;
			if (si < skipped.length && skipped[si].from <= i) {
				i = skipped[si].to;
				continue;
			}
			final code: Int = StringTools.fastCodeAt(source, i);
			if (!(code == ' '.code || code == '\t'.code || code == '\n'.code || code == '\r'.code)) return true;
			i++;
		}
		return false;
	}

	private function deadOf(file: String, source: String): Array<Span> {
		final held: Null<Array<Span>> = _dead[file];
		if (held != null) return held;
		final regions: Array<LexRegion> = _plugin.lexicalRegions(source);
		final directives: Array<CondDirective> = CondDirectives.scan(source, _shape, () -> regions);
		final flags: Array<String> = [];
		for (d in directives) {
			final condition: Null<Span> = d.condition;
			if (condition == null) continue;
			final text: String = source.substring(condition.from, condition.to);
			var at: Int = 0;
			while (FLAG.matchSub(text, at)) {
				final flag: String = FLAG.matched(0);
				if (!flags.contains(flag)) flags.push(flag);
				final pos: { pos: Int, len: Int } = FLAG.matchedPos();
				at = pos.pos + pos.len;
			}
		}
		final facts: Array<DefineFacts> = [
			for (c in _configurations) { defined: c.defined, undefined: flags.filter(f -> !c.everDefined.contains(f)) }
		];
		final dead: Array<Span> = CondRegionLiveness.deadSpans(source, _shape, facts, regions);
		_dead[file] = dead;
		_directives[file] = [for (d in directives) d.span];
		return dead;
	}

}
