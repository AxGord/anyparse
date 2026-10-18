package anyparse.check;

import anyparse.check.NullFlow.NullFacts;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;
import haxe.Exception;
import haxe.io.Path;
import sys.io.File;

using Lambda;
using StringTools;

/**
 * Whether the compiler's null-safety may judge a flow-proven rewrite, and so whether a proof it does not follow must
 * keep its finding with no edit — the one answer every `NullFlow` consumer that REWRITES on a non-null proof shares:
 * `dead-safe-nav` (`?.` to `.`), `dead-null-guard` (a guard dropped) and `dead-null-coalescing` (a fallback dropped).
 *
 * The proof half is `NullFacts.nonNullVisible`, a POSITIVE list of the narrowings the compiler is probed to perform.
 * This half says where that list matters: under a `@:nullSafety` scope (`TypeResolver.nullSafetyActiveAt`), or in a
 * project whose compiler-oracle build may switch null-safety on beyond what the sources say. Without either, nothing
 * typechecks the narrowing and the runtime-sound rewrite stands.
 *
 * Run-scoped: one per `run`, memoising the oracle hxml texts it read and the verdict per config directory.
 */
@:nullSafety(Strict)
final class NullSafetyGate {

	/** The head of a `declineReason` for a non-null proof the compiler's null-safety does not share. */
	public static inline final UNSEEN_PROOF: String = 'null-safety may be on here and does not follow this proof';

	/** How deep an oracle hxml's own `.hxml` includes are followed — a bound that ends an include cycle. */
	private static inline final MAX_INCLUDE_DEPTH: Int = 8;

	/**
	 * The hxml flags that cannot turn null-safety on: class paths, defines, the main class, a target and its output, and
	 * the switches that only tune a compile. A `--macro` or a `-lib` is absent on purpose — either can add `@:nullSafety`.
	 */
	private static final PLAIN_HXML_FLAGS: Array<String> = [
		'-cp',
		'-p',
		'--class-path',
		'-D',
		'--define',
		'-main',
		'-m',
		'--main',
		'-js',
		'--js',
		'-cpp',
		'--cpp',
		'-neko',
		'--neko',
		'-hl',
		'--hl',
		'--jvm',
		'-java',
		'--java',
		'-cs',
		'--cs',
		'-python',
		'--python',
		'-lua',
		'--lua',
		'-php',
		'--php',
		'-swf',
		'--swf',
		'--interp',
		'--no-output',
		'-debug',
		'--debug',
		'-dce',
		'--dce',
		'-v',
		'--verbose',
		'--times',
		'--no-traces',
		'--no-inline',
		'--no-opt',
		'-r',
		'--resource',
		'--each',
		'--next'
	];

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private final _resolveConfig: Null<(String) -> LintConfig>;

	/** Every oracle hxml read so far, by path; null for one that could not be read. */
	private final _hxmlText: Map<String, Null<String>> = [];

	/** `buildMayEnableNullSafety`'s verdict per config directory. */
	private final _buildMay: Map<String, Bool> = [];

	public function new(resolveConfig: Null<(String) -> LintConfig>) {
		_resolveConfig = resolveConfig;
	}

	/**
	 * The `declineReason` of a finding at `at` in `file` whose rewrite rests on `name` being non-null — `UNSEEN_PROOF`
	 * followed by the check's own `consequence` — or null when the rewrite stands: the proof is one the compiler
	 * follows too (`facts.nonNullVisible`), or null-safety cannot be on there.
	 */
	public function unseenProofReason(
		file: String, root: QueryNode, at: Span, shape: RefShape, facts: NullFacts, name: String, consequence: String
	): Null<String> {
		return facts.nonNullVisible(name) || !mayBeOn(file, root, at, shape) ? null : '$UNSEEN_PROOF$consequence';
	}

	/** Whether null-safety may be on at `at` in `file`: the file's oracle build may enable it, or a `@:nullSafety` scope covers it. */
	private function mayBeOn(file: String, root: QueryNode, at: Span, shape: RefShape): Bool {
		final configDir: String = Path.directory(file);
		if (!_buildMay.exists(configDir)) _buildMay[configDir] = buildMayEnableNullSafety(file);
		if (_buildMay[configDir] == true) return true;
		final metaName: Null<String> = shape.nullSafetyMetaName;
		return metaName != null && TypeResolver.nullSafetyActiveAt(root, at, metaName, shape.nullSafetyDisableArg);
	}

	/**
	 * Whether one of `file`'s compiler-oracle builds may turn null-safety on beyond what the sources say. Read positively: a
	 * build is plain only when every line of its hxml, and of each hxml it includes, is blank, a comment, a module name or a
	 * `PLAIN_HXML_FLAGS` flag not mentioning `nullSafety`. A `--macro`, a `-lib` whose extraParams are not read, any other flag
	 * or an unreadable hxml counts as on. A project with no oracle has no build to read and counts as off.
	 */
	private function buildMayEnableNullSafety(file: String): Bool {
		final texts: Map<String, Null<String>> = _hxmlText;
		function mayEnable(hxml: String, base: String, depth: Int): Bool {
			if (!texts.exists(hxml)) texts[hxml] = try File.getContent(hxml) catch (exception: Exception) null;
			final text: Null<String> = texts[hxml];
			if (text == null) return true;
			for (raw in text.split('\n')) {
				final line: String = raw.trim();
				if (line == '' || line.startsWith('#')) continue;
				if (line.contains('nullSafety')) return true;
				if (line.endsWith('.hxml')) {
					if (depth >= MAX_INCLUDE_DEPTH || mayEnable(LintDocuments.resolveAgainstConfigDir(base, line), base, depth + 1))
						return true;
				} else if (line.startsWith('-') && !PLAIN_HXML_FLAGS.contains(line.split(' ')[0]))
					return true;
			}
			return false;
		}
		return LintConfig.resolveWith(_resolveConfig, file)
			.compilerOracles()
			.exists(oracle -> mayEnable(oracle.hxml, oracle.dir ?? Path.directory(oracle.hxml), 0));
	}

}
