package anyparse.query.cli.command;

import anyparse.query.Cli.ReconCluster;
import anyparse.query.cli.CliContext;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;
using Lambda;

#if (sys || nodejs)
import sys.FileSystem;
#end

/**
 * Per-failure record captured during the recon sweep. Mode-dependent
 * output (histogram / cluster drill / predict-strip) reads these
 * after the walk instead of printing inline, so cluster filtering
 * and substitution prediction stay decoupled from the file-system
 * traversal loop.
 */
typedef ReconRecord = {
	var path: String;
	var clusterKey: String;
	var source: String;
	var skipLine: String;

	/**
	 * 1-indexed line of the parse-fail locus inside `source`. `0` when
	 * the record came from a non-`ParseError` exception (no span); the
	 * `--source` drill prints `<no locus>` for those.
	 */
	var line: Int;

	/** 1-indexed column at the parse-fail locus; `0` for non-`ParseError`. */
	var col: Int;
};

/**
 * Result of one corpus walk. `wired == false` means the plugin's recon
 * parser is missing — both `runReconSweep` and `strip --from-cluster`
 * surface that as a hard runtime error before consuming the records.
 */
typedef ReconWalkResult = {
	var wired: Bool;
	var records: Array<ReconRecord>;
	var clusters: Map<String, ReconCluster>;
};

/**
 * Parsed options for `apq recon` — `lang`, `topN`, the probe / cluster filters, and the family of analysis-mode flags (`predictStrip` / `regressionProbe` / `predictRelax` / `permissiveConstruct` / writer-equals). `errExit` non-null means arg parsing hit a terminal case the caller returns immediately.
 */
@:nullSafety(Strict)
typedef ReconOpts = {
	var lang: String;
	var topN: Int;
	var probePath: Null<String>;
	var rootDir: Null<String>;
	var clusterFilter: Null<String>;
	var predictStrip: Bool;
	var regressionProbe: Bool;
	var candidatesRegex: Null<String>;
	var predictRelax: Bool;
	var permissiveConstruct: Bool;
	var showSource: Bool;
	var noTargetClusterFilter: Null<String>;
	var patterns: Array<String>;
	var replacements: Array<String>;
	var regexMode: Bool;
	var compiledRegex: Null<Array<EReg>>;
	var writerEqualsAfter: Bool;
	var writerEqualsPlain: Bool;
	var expectedPath: Null<String>;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag / validation
	// failure -> EXIT_USAGE); the caller returns this immediately and ignores the rest.
	var errExit: Null<Int>;
};

/**
 * `apq recon` — skip-parse drill — corpus sweep + locus-cluster histogram.
 *
 * A READ-ONLY command: it reports and never writes.
 */
@:nullSafety(Strict)
final class ReconCommand implements CliCommand {

	private static inline final RECON_TOP_N_DEFAULT: Int = 30;

	private static inline final RECON_EXAMPLES_PER_CLUSTER: Int = 2;

	private static inline final RECON_HEAD_LEN: Int = 70;

	private static inline final RECON_LOCUS_LEN: Int = 20;

	private static inline final RECON_SOURCE_WINDOW_RADIUS: Int = 3;

	public static inline final CLUSTER_PREVIEW_LIMIT: Int = 10;

	public function new() {}

	public function name(): String {
		return 'recon';
	}

	public function summary(): String {
		return 'Skip-parse drill — corpus sweep + locus-cluster histogram';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		#if (sys || nodejs)
		return runRecon(args);
		#else
		CliIo.stderr('apq recon: requires a sys target (filesystem walk)\n');
		return EXIT_USAGE;
		#end
	}

	public function usage(): Void {
		#if (sys || nodejs)
		printReconUsage();
		#end
	}

	#if (sys || nodejs)
	/**
	 * NO-TARGET diagnostic list cap — both `--no-target-cluster` 0-match
	 * stderr and the sweep footer breakdown surface at most this many
	 * keys before truncating.
	 */
	public static inline final NO_TARGET_TOP_N: Int = 10;
	#end

	/** Terminal-case ReconOpts: a flag/usage path the caller returns immediately, ignoring every other field. */
	private static inline function reconParseExit(code: Int): ReconOpts {
		return {
			lang: '',
			topN: 0,
			probePath: null,
			rootDir: null,
			clusterFilter: null,
			predictStrip: false,
			regressionProbe: false,
			candidatesRegex: null,
			predictRelax: false,
			permissiveConstruct: false,
			showSource: false,
			noTargetClusterFilter: null,
			patterns: [],
			replacements: [],
			regexMode: false,
			compiledRegex: null,
			writerEqualsAfter: false,
			writerEqualsPlain: false,
			expectedPath: null,
			errExit: code
		};
	}

	private static function printReconUsage(): Void {
		CliIo.sysPrint('Usage: apq recon [<dir>] [--top N | --all] [--cluster <substr> [--source]]\n');
		CliIo.sysPrint('                 [--predict-strip --replace <pat> --with <repl> ... [--source]]\n');
		CliIo.sysPrint('                 [--probe <file>]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Sweep mode: walks every .hxtest under <dir> (section-2 auto-extracted),\n');
		CliIo.sysPrint('runs the trivia parser, clusters failures by normalised forward-locus,\n');
		CliIo.sysPrint('and prints SKIP lines + histogram. Default <dir> is\n');
		CliIo.sysPrint("$ANYPARSE_HXFORMAT_FORK/test/testcases when the env var is set.\n");
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Options:\n');
		CliIo.sysPrint('  --lang <name>           Grammar plugin (default: haxe)\n');
		CliIo.sysPrint('  --top N                 Show top N clusters (default: 30)\n');
		CliIo.sysPrint('  --all                   Show every cluster\n');
		CliIo.sysPrint('  --cluster <key>         Drill into ONE cluster: full path list instead of\n');
		CliIo.sysPrint('                          histogram. EXACT match against the cluster key\n');
		CliIo.sysPrint('                          shown in the histogram (with \\n / \\t escapes).\n');
		CliIo.sysPrint('                          0-match exits non-zero with top keys for ref.\n');
		CliIo.sysPrint('  --no-target-cluster <expected-msg>\n');
		CliIo.sysPrint('                          With --predict-relax: drill into ONE bucket of the\n');
		CliIo.sysPrint('                          footer NO TARGET breakdown — print every fixture\n');
		CliIo.sysPrint('                          whose predict-relax outcome is NoTarget with\n');
		CliIo.sysPrint('                          message == <expected-msg>. EXACT match against the\n');
		CliIo.sysPrint('                          key shown in the footer histogram. Bridges the\n');
		CliIo.sysPrint('                          footer aggregate to the file list — --cluster uses\n');
		CliIo.sysPrint('                          a different namespace (forward-locus on raw bytes).\n');
		CliIo.sysPrint('                          0-match exits non-zero with top NO TARGET keys.\n');
		CliIo.sysPrint('                          Mutex with --cluster / --probe.\n');
		CliIo.sysPrint('  --source                With --cluster, append a windowed source slice\n');
		CliIo.sysPrint('                          around the fail-locus for each path (L±3).\n');
		CliIo.sysPrint('                          With --predict-strip, also emits the window for\n');
		CliIo.sysPrint('                          each STILL FAIL entry around the NEW fail-locus\n');
		CliIo.sysPrint('                          (the moved-locus payload). With --predict-relax,\n');
		CliIo.sysPrint('                          emits the window for STILL FAIL (around NEW locus\n');
		CliIo.sysPrint('                          in patched source) and for NO TARGET entries in\n');
		CliIo.sysPrint('                          drill/probe modes (around the ORIGINAL fail-locus,\n');
		CliIo.sysPrint('                          which has no patch). Sweep-mode NO TARGET stays\n');
		CliIo.sysPrint('                          collapsed into the footer histogram. Usage error\n');
		CliIo.sysPrint('                          outside these modes.\n');
		CliIo.sysPrint('  --predict-strip         Apply substitutions to each skip-parse source\n');
		CliIo.sysPrint('                          and retry; print PREDICT UNBLOCK / STILL FAIL /\n');
		CliIo.sysPrint('                          NO MATCH per file. Requires --replace/--with or\n');
		CliIo.sysPrint('                          --delete; combinable with --cluster.\n');
		CliIo.sysPrint('  --replace <pat> --with <repl>\n');
		CliIo.sysPrint('                          Substitution pair (with --predict-strip; repeatable).\n');
		CliIo.sysPrint('  --delete <pat>          Shortcut for --replace <pat> --with "".\n');
		CliIo.sysPrint('  --regex                 Treat --replace / --delete patterns as EReg patterns\n');
		CliIo.sysPrint('                          (global, applies to every match) instead of literal\n');
		CliIo.sysPrint('                          substrings. Requires --predict-strip. One regex\n');
		CliIo.sysPrint('                          covers every site of a construct in the corpus.\n');
		CliIo.sysPrint('  --candidates <regex>    Cross-cluster enumeration: walk skip-parse fixtures,\n');
		CliIo.sysPrint('                          print `<path> :: N matches` for every file with ≥1\n');
		CliIo.sysPrint('                          regex hit (sorted by count desc) + summary. Use when\n');
		CliIo.sysPrint('                          the histogram clusters by exact forward-locus and a\n');
		CliIo.sysPrint('                          construct lives in differently-shaped multi-blocker\n');
		CliIo.sysPrint('                          fixtures. Mutually exclusive with --predict-strip /\n');
		CliIo.sysPrint('                          --cluster / --probe / --regression-probe.\n');
		CliIo.sysPrint('  --probe <file>          Single-file probe instead of sweep. Composes with\n');
		CliIo.sysPrint('                          --predict-strip: applies substitutions to the file and\n');
		CliIo.sysPrint('                          retries the parse, printing PREDICT UNBLOCK / STILL\n');
		CliIo.sysPrint('                          FAIL / NO MATCH + per-pattern totals + typo guard\n');
		CliIo.sysPrint('                          (same shape as sweep mode).\n');
		CliIo.sysPrint('  --regression-probe      Diff current corpus parse OK / SKIP_PARSE state against\n');
		CliIo.sysPrint('                          the prior sweep snapshot (`bin/.last-sweep.json`).\n');
		CliIo.sysPrint('                          Reports every fixture whose parse status FLIPPED since\n');
		CliIo.sysPrint('                          the snapshot — REGRESSED (was PASS / FAIL / SKIP_WRITE,\n');
		CliIo.sysPrint('                          now skip-parse) and UNBLOCKED (was SKIP_PARSE, now\n');
		CliIo.sysPrint('                          parses). Cheap pre-edit / post-edit sanity check —\n');
		CliIo.sysPrint('                          only runs the trivia parse, no writer / no expected-\n');
		CliIo.sysPrint('                          bytes diff. Non-zero exit when any regression found.\n');
		CliIo.sysPrint('                          Mutually exclusive with --probe / --predict-strip /\n');
		CliIo.sysPrint('                          --cluster.\n');
		CliIo.sysPrint('  --permissive-construct  Field-optionalization predictor for Slice 40\'s\n');
		CliIo.sysPrint('                          `@:optional + @:lead + @:trail` mechanism. Walks every\n');
		CliIo.sysPrint('                          `mandatory-ref-lead-trail` candidate from `apq gates\n');
		CliIo.sysPrint('                          --mechanism mandatory-ref-lead-trail`, strips the\n');
		CliIo.sysPrint('                          `<lead>...<trail>` bracket-pair from each skip-parse\n');
		CliIo.sysPrint('                          fixture, re-parses, and aggregates UNBLOCK / STILL FAIL\n');
		CliIo.sysPrint('                          / NO MATCH per candidate. THE pre-edit upper-bound\n');
		CliIo.sysPrint('                          view of which field-optionalization would unblock\n');
		CliIo.sysPrint('                          which fixtures. Mutually exclusive with every other\n');
		CliIo.sysPrint('                          recon mode.\n');
		CliIo.sysPrint('  --writer-equals         After --probe PARSE OK, also run writer round-trip +\n');
		CliIo.sysPrint('                          byte-equality check vs the fixture\'s expected section\n');
		CliIo.sysPrint('                          (or `--expected <path>` for plain .hx). Prints WRITER\n');
		CliIo.sysPrint('                          PASS / FAIL upfront so you see whether the slice would\n');
		CliIo.sysPrint('                          yield +1 PASS or skip→fail without running the corpus\n');
		CliIo.sysPrint('                          sweep. Incompatible with --predict-strip / --predict-\n');
		CliIo.sysPrint('                          relax (their patched source diverges from expected by\n');
		CliIo.sysPrint('                          construction). Requires --probe.\n');
		CliIo.sysPrint('  --writer-equals-plain   Same as --writer-equals but routes through the PLAIN\n');
		CliIo.sysPrint('                          (non-trivia) pipeline (HxModuleParser → HxModuleWriter).\n');
		CliIo.sysPrint('  --expected <path>       Override the expected-bytes source (default: .hxtest\n');
		CliIo.sysPrint('                          section 3, or the input itself for raw .hx). Requires\n');
		CliIo.sysPrint('                          --writer-equals.\n');
		CliIo.sysPrint('  -h, --help              Show this help.\n');
	}

	/**
	 * First validation group: `--source` drill-mode requirement, the
	 * `--regression-probe` mutex set, and the `--candidates` mutex set.
	 * Returns a non-null exit code (EXIT_USAGE) on the first violation,
	 * after printing the diagnostic; null when this group passes.
	 */
	private static function validateReconModesA(o: ReconOpts): Null<Int> {
		// `--source` is meaningful only in modes where the per-path window
		// adds signal — `--cluster <key>` drill, `--no-target-cluster
		// <key>` drill, `--predict-strip` STILL FAIL entries, or
		// `--predict-relax` (STILL FAIL in sweep mode, both STILL FAIL +
		// NO TARGET in probe / drill modes). In plain sweep mode without
		// any of those it would flood every SKIP line with a per-fixture
		// window, so make the misuse a hard usage error rather than a
		// silent no-op.
		if (o.showSource && o.clusterFilter == null && o.noTargetClusterFilter == null && !o.predictStrip && !o.predictRelax) {
			CliIo.stderr(
				'apq recon: --source requires --cluster <key> / --no-target-cluster <key> / --predict-strip / --predict-relax ('
				+ 'drill / STILL-FAIL modes only; would flood the sweep otherwise)\n'
			);
			return EXIT_USAGE;
		}
		// `--regression-probe` is its own mode — separate from probe /
		// predict / cluster / source. Reject the combinations with a clear
		// usage error instead of silently picking one path.
		if (o.regressionProbe) {
			if (o.probePath != null) {
				CliIo.stderr('apq recon: --regression-probe and --probe are mutually exclusive\n');
				return EXIT_USAGE;
			}
			if (o.predictStrip) {
				CliIo.stderr('apq recon: --regression-probe and --predict-strip are mutually exclusive\n');
				return EXIT_USAGE;
			}
			if (o.clusterFilter != null) {
				CliIo.stderr('apq recon: --regression-probe and --cluster are mutually exclusive\n');
				return EXIT_USAGE;
			}
		}
		if (
			o.candidatesRegex == null || o.probePath == null && !o.predictStrip && o.clusterFilter == null && !o.regressionProbe
			&& !o.predictRelax
		)
			return null;
		CliIo.stderr(
			'apq recon: --candidates is mutually exclusive with --probe / --predict-strip / --cluster / --regression-probe / '
			+ '--predict-relax\n'
		);
		return EXIT_USAGE;
	}

	/**
	 * Second validation group: the `--predict-relax` mutex set, the
	 * `--no-target-cluster` requirement/mutex set, and the
	 * `--permissive-construct` mutex check. Returns a non-null exit code
	 * (EXIT_USAGE) on the first violation; null when this group passes.
	 */
	private static function validateReconModesB(o: ReconOpts): Null<Int> {
		if (o.predictRelax) {
			if (o.predictStrip) {
				CliIo.stderr(
					'apq recon: --predict-relax and --predict-strip are mutually exclusive ('
					+ 'opposite models — strip removes tokens, relax inserts the expected one)\n'
				);
				return EXIT_USAGE;
			}
			if (o.regressionProbe) {
				CliIo.stderr('apq recon: --predict-relax and --regression-probe are mutually exclusive\n');
				return EXIT_USAGE;
			}
			if (o.patterns.length > 0) {
				CliIo.stderr(
					'apq recon: --predict-relax does not take --replace/--with/--delete ('
					+ 'the injected token comes from the parser`s `expected` hint)\n'
				);
				return EXIT_USAGE;
			}
		}
		if (o.noTargetClusterFilter != null) {
			if (!o.predictRelax) {
				CliIo.stderr(
					'apq recon: --no-target-cluster requires --predict-relax ('
					+ 'the footer NO TARGET breakdown is only produced in predict-relax sweep mode)\n'
				);
				return EXIT_USAGE;
			}
			if (o.clusterFilter != null) {
				CliIo.stderr(
					'apq recon: --cluster and --no-target-cluster are mutually exclusive ('
					+ 'one drill at a time — --cluster drills by forward-locus, --no-target-cluster drills by expected-message)\n'
				);
				return EXIT_USAGE;
			}
			if (o.probePath != null) {
				CliIo.stderr(
					'apq recon: --no-target-cluster requires sweep mode ('
					+ 'no NO TARGET aggregation in --probe mode — pass a corpus directory instead)\n'
				);
				return EXIT_USAGE;
			}
		}
		if (
			o.permissiveConstruct && (
				o.probePath != null || o.predictStrip || o.predictRelax || o.regressionProbe || o.clusterFilter != null
				|| o.candidatesRegex != null || o.patterns.length > 0
			)
		) {
			CliIo.stderr(
				'apq recon: --permissive-construct is its own mode — mutually exclusive with --probe / --predict-strip / --predict-relax '
				+ '/ --regression-probe / --cluster / --candidates / --replace/--with/--delete\n'
			);
			return EXIT_USAGE;
		}
		return null;
	}

	/**
	 * Third validation group: `--writer-equals` requires `--probe` and is
	 * incompatible with `--predict-strip` / `--predict-relax`, and
	 * `--expected` requires `--writer-equals`. Returns a non-null exit
	 * code (EXIT_USAGE) on the first violation; null when it passes.
	 */
	private static function validateReconWriterEquals(o: ReconOpts): Null<Int> {
		if (o.writerEqualsAfter) {
			if (o.probePath == null) {
				CliIo.stderr(
					'apq recon: --writer-equals requires --probe <file> ('
					+ 'single-file mode; sweep mode already does byte-comparison via the corpus harness)\n'
				);
				return EXIT_USAGE;
			}
			if (o.predictStrip) {
				CliIo.stderr(
					'apq recon: --writer-equals is incompatible with --predict-strip (the stripped source diverges from expected by '
					+ 'construction — apply the slice first, then probe + writer-equals on the unstripped source)\n'
				);
				return EXIT_USAGE;
			}
			if (o.predictRelax) {
				CliIo.stderr(
					'apq recon: --writer-equals is incompatible with --predict-relax ('
					+ 'relax synthesises a missing token; expected bytes won`t match the patched source)\n'
				);
				return EXIT_USAGE;
			}
		}
		if (o.expectedPath == null || o.writerEqualsAfter) return null;
		CliIo.stderr('apq recon: --expected requires --writer-equals\n');
		return EXIT_USAGE;
	}

	/**
	 * Parse `recon` argv into a ReconOpts. A terminal case (`-h`/`--help`
	 * or any usage error) prints its message and returns with `errExit`
	 * set; the caller returns that code immediately. The natural end runs
	 * the post-loop validations and returns the full struct with
	 * `errExit: null`.
	 */
	private static function parseReconArgs(args: Array<String>): ReconOpts {
		var lang: String = 'haxe';
		var topN: Int = RECON_TOP_N_DEFAULT;
		var probePath: Null<String> = null;
		var rootDir: Null<String> = null;
		var clusterFilter: Null<String> = null;
		var predictStrip: Bool = false;
		// `--regression-probe`: read the prior sweep snapshot's per-fixture
		// status map (`bin/.last-sweep.json` `fixtures` array) and diff
		// against the current corpus's parse-OK/FAIL state. Surfaces every
		// fixture whose parse status FLIPPED since the snapshot was
		// written. Catches "I edited the grammar, am I breaking anything
		// that was working?" pre-sweep — cheaper than a full corpus rerun
		// because it only does the trivia parse step (no writer / no
		// expected-bytes comparison). Mutually exclusive with --probe /
		// --predict-strip / --cluster (separate diagnostic mode).
		var regressionProbe: Bool = false;
		// `--candidates <regex>`: cross-cluster construct enumeration.
		// Walks the same skip-parse record set as the sweep, applies
		// the EReg against each fixture's source, and prints
		// `<path> :: N matches` for every file with ≥1 hit (sorted by
		// count desc). Closes the gap where the histogram clusters by
		// exact forward-locus, so a construct that lives in different
		// multi-blocker fixtures (e.g. `new T<...>(` sites split across
		// files) is undercounted. Mutually exclusive with
		// --predict-strip / --cluster / --probe / --regression-probe.
		var candidatesRegex: Null<String> = null;
		// `--predict-relax`: terminator-insertion predictor. For each
		// skip-parse fixture, take the ParseError's `expected` hint as
		// the missing token and INSERT it at the fail-locus. If the
		// patched source parses, the slice candidate is gate-relaxation
		// (make the terminator optional via `@:trailOpt` / `@:fmt(trailOptParseGate(…))`).
		// If STILL FAIL, the gap is deeper than the immediate terminator.
		// Complement to `--predict-strip` (which models the OPPOSITE —
		// remove tokens to advance past a syntax mismatch): predict-relax
		// models "the parser would accept missing X at this position".
		// Mutex with --predict-strip / --regression-probe / --candidates.
		var predictRelax: Bool = false;
		// `--permissive-construct`: field-optionalization predictor.
		// Walks every `mandatory-ref-lead-trail` candidate from
		// `gates --mechanism mandatory-ref-lead-trail` (the relax-
		// candidate inventory), strips the bracket-pair `<lead>...<trail>`
		// from each skip-parse fixture, and re-parses. Aggregates
		// UNBLOCK / STILL FAIL / NO MATCH per candidate so the user sees
		// which field-optionalization would unblock which fixtures
		// BEFORE committing to the grammar edit. Mutex with every
		// other recon mode — it's its own pipeline.
		var permissiveConstruct: Bool = false;
		// `--source`: drill-mode-only flag. When set in combination with
		// `--cluster <key>`, the per-path output gains a windowed source
		// snippet centred on the fail-locus. Outside drill it would
		// flood every SKIP line; usage error guards that.
		var showSource: Bool = false;
		// `--no-target-cluster <expected-msg>`: drill into ONE bucket of the
		// `--predict-relax` footer NO TARGET breakdown — the histogram that
		// aggregates per-file `NoTarget` outcomes by `res.message`
		// (`70× expected hint is empty after quote-strip` / `12× expected
		// HxDecl` / …). Footer keys live in a different namespace than
		// `--cluster <key>` (which drills by normalised forward-locus on
		// `r.clusterKey`); this flag is the only path from the footer
		// aggregate to the file list. Active only in sweep predict-relax
		// mode; mutex with `--cluster` (one drill at a time) and `--probe`
		// (single-file, no aggregation).
		var noTargetClusterFilter: Null<String> = null;
		// Twin of `runStrip`'s arg-parsing: --replace X --with Y pairs
		// plus --delete X shortcut. Patterns and replacements arrays
		// stay aligned by construction. Active only with --predict-strip.
		final patterns: Array<String> = [];
		final replacements: Array<String> = [];
		var pendingReplace: Null<String> = null;
		// --regex: same semantics as `apq strip --regex` — treat every
		// --replace / --delete pattern as an EReg pattern. Lets one
		// predict-strip call cover every site of a construct in the
		// corpus (e.g. `new [A-Z]\w*<[^>]+>\(` matches every templated
		// constructor call, not just one literal pair) — closes the
		// pain where a literal-only sweep under-counts because the
		// histogram clusters by exact forward-locus shape.
		var regexMode: Bool = false;
		// `--writer-equals [--writer-equals-plain] [--expected <path>]`:
		// chain a writer round-trip + byte-equality check onto a probe-mode
		// PARSE OK. Closes the "predicted +1 via predict-strip, got skip→fail
		// because the writer round-trip diverges" gap —
		// running predict-strip alone tells you ONLY about parse, not byte-
		// PASS. The combo flag is probe-only (single-file) because the
		// expected comparison needs a paired source/expected (sections 2/3
		// of an `.hxtest`, or `--expected <path>` for plain `.hx`). Sweep
		// mode already has the corpus harness doing this comparison.
		var writerEqualsAfter: Bool = false;
		var writerEqualsPlain: Bool = false;
		var expectedPath: Null<String> = null;
		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--top':
					final v: Null<Int> = Std.parseInt(CliArgs.expectValue(args, ++i, '--top'));
					if (v == null || v <= 0) {
						CliIo.stderr('apq recon: --top requires a positive integer\n');
						return reconParseExit(EXIT_USAGE);
					}
					topN = v;
				case '--all':
					topN = CliArgs.MAX_INT;
				case '--probe':
					probePath = CliArgs.expectValue(args, ++i, '--probe');
				case '--cluster':
					clusterFilter = CliArgs.expectValue(args, ++i, '--cluster');
				case '--no-target-cluster':
					noTargetClusterFilter = CliArgs.expectValue(args, ++i, '--no-target-cluster');
				case '--source':
					showSource = true;
				case '--predict-strip':
					predictStrip = true;
				case '--predict-relax':
					predictRelax = true;
				case '--regression-probe':
					regressionProbe = true;
				case '--permissive-construct':
					permissiveConstruct = true;
				case '--candidates':
					candidatesRegex = CliArgs.expectValue(args, ++i, '--candidates');
				case '--replace':
					if (pendingReplace != null) {
						CliIo.stderr('apq recon: --replace "$pendingReplace" needs a --with before the next --replace\n');
						return reconParseExit(EXIT_USAGE);
					}
					pendingReplace = CliArgs.expectValue(args, ++i, '--replace');
				case '--with':
					if (pendingReplace == null) {
						CliIo.stderr('apq recon: --with requires a preceding --replace\n');
						return reconParseExit(EXIT_USAGE);
					}
					patterns.push(pendingReplace);
					replacements.push(CliArgs.expectValue(args, ++i, '--with'));
					pendingReplace = null;
				case '--delete':
					if (pendingReplace != null) {
						CliIo.stderr('apq recon: --replace "$pendingReplace" needs a --with before --delete\n');
						return reconParseExit(EXIT_USAGE);
					}
					patterns.push(CliArgs.expectValue(args, ++i, '--delete'));
					replacements.push('');
				case '--regex':
					regexMode = true;
				case '--writer-equals':
					writerEqualsAfter = true;
				case '--writer-equals-plain':
					writerEqualsAfter = true;
					writerEqualsPlain = true;
				case '--expected':
					expectedPath = CliArgs.expectValue(args, ++i, '--expected');
				case '-h', '--help':
					printReconUsage();
					return reconParseExit(EXIT_OK);
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq recon: unknown option "$a"\n');
						return reconParseExit(EXIT_USAGE);
					}
					if (rootDir != null) {
						CliIo.stderr('apq recon: only one positional <dir> argument supported (got "$rootDir" and "$a")\n');
						return reconParseExit(EXIT_USAGE);
					}
					rootDir = a;
			}
			i++;
		}
		final o: ReconOpts = {
			lang: lang,
			topN: topN,
			probePath: probePath,
			rootDir: rootDir,
			clusterFilter: clusterFilter,
			predictStrip: predictStrip,
			regressionProbe: regressionProbe,
			candidatesRegex: candidatesRegex,
			predictRelax: predictRelax,
			permissiveConstruct: permissiveConstruct,
			showSource: showSource,
			noTargetClusterFilter: noTargetClusterFilter,
			patterns: patterns,
			replacements: replacements,
			regexMode: regexMode,
			compiledRegex: null,
			writerEqualsAfter: writerEqualsAfter,
			writerEqualsPlain: writerEqualsPlain,
			expectedPath: expectedPath,
			errExit: null
		};
		final sa: Null<Int> = validateReconStripArgs(o, pendingReplace);
		if (sa != null) return reconParseExit(sa);
		final mA: Null<Int> = validateReconModesA(o);
		if (mA != null) return reconParseExit(mA);
		final mB: Null<Int> = validateReconModesB(o);
		if (mB != null) return reconParseExit(mB);
		final we: Null<Int> = validateReconWriterEquals(o);
		return we != null ? reconParseExit(we) : o;
	}

	/**
	 * Post-loop validation of the `--replace`/`--with`/`--delete`/`--regex`
	 * predict-strip argument group, plus regex compilation. Mutates `o`
	 * with the compiled regex array on success. Returns a non-null exit
	 * code (EXIT_USAGE) on the first violation; null when the group passes.
	 */
	private static function validateReconStripArgs(o: ReconOpts, pendingReplace: Null<String>): Null<Int> {
		if (pendingReplace != null) {
			CliIo.stderr('apq recon: --replace "$pendingReplace" needs a --with\n');
			return EXIT_USAGE;
		}
		if (o.predictStrip && o.patterns.length == 0) {
			CliIo.stderr('apq recon: --predict-strip requires at least one --replace/--with or --delete\n');
			return EXIT_USAGE;
		}
		if (!o.predictStrip && o.patterns.length > 0) {
			CliIo.stderr('apq recon: --replace/--with/--delete require --predict-strip\n');
			return EXIT_USAGE;
		}
		if (o.regexMode && !o.predictStrip) {
			CliIo.stderr('apq recon: --regex requires --predict-strip (regex applies to --replace patterns)\n');
			return EXIT_USAGE;
		}
		final compiled: Null<Array<EReg>> = o.regexMode ? StripCommand.compileStripRegexes('recon', o.patterns) : null;
		if (o.regexMode && compiled == null) return EXIT_USAGE;
		o.compiledRegex = compiled;
		return null;
	}

	#if (sys || nodejs)
	/**
	 * `apq recon` — corpus skip-parse drill harness. Walks a directory
	 * looking for source files (`.hxtest` fixtures auto-extract section
	 * 2), tries each via the plugin's trivia parser, and clusters the
	 * failures by a normalised forward-locus key so the histogram shows
	 * the actual stuck CONSTRUCT, not the parser's terminator carousel
	 * (`expected="//"` is 90%+ of the raw signal and is dropped).
	 *
	 * Replaces the standalone `test/_ReconSkipParse.hx` + `/tmp/recon.js`
	 * dance — same clustering logic, but in-process with the rest of
	 * `hxq` so a single `haxe bin/apq-js.hxml` rebuild after a grammar
	 * edit picks up the new parser surface. No separate hxml.
	 *
	 * Modes:
	 *  - `apq recon <dir>` — sweep mode. Walks every `.hxtest` under
	 *    `<dir>` recursively, prints `SKIP path :: line:col <locus>` per
	 *    failure, then a histogram of the top clusters (--top default 30,
	 *    --all overrides).
	 *  - `apq recon --probe <file>` — single-file probe. Useful for
	 *    confirming a hypothesis about ONE fixture after a grammar edit.
	 */
	private static function runRecon(args: Array<String>): Int {
		final o: ReconOpts = parseReconArgs(args);
		if (o.errExit != null) return o.errExit;
		final plugin: GrammarPlugin = CliArgs.pickPlugin(o.lang);
		final probePath: Null<String> = o.probePath;
		if (o.predictRelax && probePath != null) return ReconPredict.runReconProbeRelax(plugin, probePath, o.showSource);
		if (probePath != null)
			return runReconProbe(
				plugin, probePath, o.predictStrip, o.patterns, o.replacements, o.compiledRegex, o.showSource, o.writerEqualsAfter,
				o.writerEqualsPlain, o.expectedPath, o.lang
			);
		final rootFinal: String = o.rootDir ?? defaultReconRoot();
		if (rootFinal == '') {
			CliIo.stderr(
				"apq recon: no <dir> given and $ANYPARSE_HXFORMAT_FORK env var is unset ("
				+ 'no cached path at ~/.config/anyparse/fork_path either).\n'
			);
			CliIo.stderr('  Either pass a directory:  apq recon /path/to/corpus\n');
			CliIo.stderr('  or export the fork root:  ANYPARSE_HXFORMAT_FORK=/path/to/haxe-formatter\n');
			CliIo.stderr(
				'  (first env-supplied run caches the path under ~/.config/anyparse/; subsequent runs work without re-exporting)\n'
			);
			return EXIT_USAGE;
		}
		if (!FileSystem.exists(rootFinal) || !FileSystem.isDirectory(rootFinal)) {
			CliIo.stderr('apq recon: "$rootFinal" is not a directory.\n');
			return EXIT_RUNTIME;
		}
		final candidatesRegex: Null<String> = o.candidatesRegex;
		return if (o.regressionProbe)
			ReconPredict.runReconRegressionProbe(plugin, rootFinal)
		else if (candidatesRegex != null)
			ReconPredict.runReconCandidates(plugin, rootFinal, candidatesRegex)
		else if (o.permissiveConstruct)
			ReconPredict.runReconPermissive(plugin, rootFinal, o.lang)
		else if (o.predictRelax)
			ReconPredict.runReconSweepRelax(plugin, rootFinal, o.clusterFilter, o.noTargetClusterFilter, o.showSource)
		else
			runReconSweep(
				plugin, rootFinal, o.topN, o.clusterFilter, o.predictStrip, o.patterns, o.replacements, o.compiledRegex, o.showSource
			);
	}

	private static function runReconProbe(
		plugin: GrammarPlugin, path: String, predictStrip: Bool, patterns: Array<String>, replacements: Array<String>,
		compiledRegex: Null<Array<EReg>>, showSource: Bool, writerEqualsAfter: Bool = false, writerEqualsPlain: Bool = false,
		?expectedPathOpt: String, lang: String = 'haxe'
	): Int {
		if (!FileSystem.exists(path)) {
			CliIo.stderr('apq recon: --probe path "$path" does not exist\n');
			return EXIT_RUNTIME;
		}
		final original: String = CliIo.readSourceForParse(path);
		// `--predict-strip --probe <file>` — apply substitutions to the
		// single probed file's source, then re-run the strict trivia parse
		// against the result. Mirrors the sweep-mode predict tag set
		// (`PREDICT UNBLOCK` / `PREDICT STILL FAIL` / `PREDICT NO MATCH`)
		// so a single-file dry-run stays semantically aligned with the
		// corpus walk. Per-pattern match totals are printed for the typo
		// guard (a `--replace` pattern matching 0 occurrences is the
		// canonical pre-edit signal of a typo or whitespace mismatch).
		// Without `--predict-strip`, the legacy PARSE OK / PARSE FAIL
		// output is byte-identical to before.
		if (predictStrip)
			return ReconPredict.runReconProbePredict(plugin, path, original, patterns, replacements, compiledRegex, showSource);
		try {
			if (!plugin.reconParse(original)) {
				CliIo.stderr('apq recon: no recon parser wired up for this grammar plugin\n');
				return EXIT_RUNTIME;
			}
			CliIo.sysPrint('PARSE OK\n');
			return writerEqualsAfter ? runProbeWriterCheck(plugin, path, original, writerEqualsPlain, expectedPathOpt, lang) : EXIT_OK;
		} catch (exception: ParseError) {
			final pos: Position = exception.span.lineCol(original);
			final exp: String = reconNormalize(exception.expected);
			final snip: String = reconNormalize(reconSnippet(original, exception.span.from));
			CliIo.sysPrint('PARSE FAIL :: ${pos.line}:${pos.col} expected="$exp" :: src="$snip"\n');
			return EXIT_RUNTIME;
		} catch (exception: Exception) {
			CliIo.sysPrint('PARSE FAIL :: <non-ParseError> ${reconNormalize(exception.message)}\n');
			return EXIT_RUNTIME;
		}
	}

	/**
	 * ω-probe-writer-check: chain a writer round-trip + byte-equality check
	 * onto a probe-mode PARSE OK. Reuses `runWriterEquals`'s machinery so
	 * the byte-diff format stays identical to the corpus harness's fail
	 * line. Closes the "predicted +1 via predict-strip, got skip→fail
	 * because writer round-trip diverges" gap.
	 *
	 * Expected bytes resolution:
	 *  - explicit `--expected <path>` always wins.
	 *  - `.hxtest` input → section 3 (the fork's reference formatted output).
	 *  - plain `.hx` → byte-identity round-trip (compare against source).
	 *
	 * Last case turns the call into a writer-idempotency check: parse the
	 * source, write back, expect the same bytes. Useful for sanity-probing
	 * a grammar edit's writer round-trip on hand-rolled scratch inputs
	 * (`/tmp/probe.hx`) without typing the expected bytes twice.
	 */
	private static function runProbeWriterCheck(
		plugin: GrammarPlugin, inputPath: String, source: String, plain: Bool, expectedPathOpt: Null<String>, lang: String
	): Int {
		// `.hxtest` expected sections drop one trailing `\n` via
		// `stripPadNewlines` (the corpus harness adds `finalNewline=true`
		// and trims back one `\n` from `actualRaw` to keep the compare
		// symmetric). Mirror that here so a corpus-PASS fixture round-trips
		// to `WRITER PASS` via the probe, not a spurious off-by-newline
		// mismatch. Raw `.hx` inputs skip the strip — the user supplied
		// expected bytes verbatim.
		final hxtestMode: Bool = expectedPathOpt == null && inputPath.endsWith('.hxtest');
		final expectedSource: String = if (expectedPathOpt != null) {
			WriterEqualsCommand.readExpectedForCompare((expectedPathOpt: String));
		} else if (hxtestMode) {
			WriterEqualsCommand.readExpectedForCompare(inputPath);
		} else {
			source;
		};
		final optsJson: Null<String> = CliArgs.readWriteOptionsJsonOrNull(inputPath);
		final emittedRaw: Null<String> = try (
			plain ? plugin.writeRoundTripPlain(source, optsJson) : plugin.writeRoundTrip(source, optsJson)
		) catch (e: ParseError) {
			CliIo.sysPrint('WRITER FAIL :: $e\n');
			return EXIT_RUNTIME;
		} catch (e: Exception) {
			CliIo.sysPrint('WRITER FAIL :: ${e.message}\n');
			return EXIT_RUNTIME;
		}
		if (emittedRaw == null) {
			final flagName: String = plain ? '--writer-equals-plain' : '--writer-equals';
			CliIo.stderr('apq recon: no writer wired up for lang "$lang" ($flagName)\n');
			return EXIT_USAGE;
		}
		final emitted: String = (emittedRaw: String);
		final emittedNormalised: String = hxtestMode && emitted.length > 0 && emitted.fastCodeAt(emitted.length - 1) == '\n'.code
			? emitted.substr(0, emitted.length - 1)
			: emitted;
		if (emittedNormalised == expectedSource) {
			CliIo.sysPrint('WRITER PASS\n');
			return EXIT_OK;
		}
		CliIo.sysPrint('WRITER FAIL :: ${WriterEqualsCommand.describeByteDiff(emittedNormalised, expectedSource)}\n');
		return EXIT_RUNTIME;
	}

	private static function runReconSweep(
		plugin: GrammarPlugin, root: String, topN: Int, clusterFilter: Null<String>, predictStrip: Bool, patterns: Array<String>,
		replacements: Array<String>, compiledRegex: Null<Array<EReg>>, showSource: Bool
	): Int {
		final walk: ReconWalkResult = collectReconSkipRecords(plugin, root);
		if (!walk.wired) {
			CliIo.stderr('apq recon: no recon parser wired up for this grammar plugin\n');
			return EXIT_RUNTIME;
		}
		final clusters: Map<String, ReconCluster> = walk.clusters;
		final records: Array<ReconRecord> = walk.records;
		// `--cluster <key>` filter: exact match against the normalised
		// cluster key (the histogram label, with `\n`/`\t` escaped).
		// Exact rather than substring because `}\n}` (canonical) would
		// substring-match every Haxe file's `…}\n}` tail. 0-match exits
		// non-zero; downstream output (SKIP / PREDICT / cluster drill)
		// walks the filtered records and the single-cluster map.
		var filteredRecords: Array<ReconRecord> = records;
		var filteredClusters: Map<String, ReconCluster> = clusters;
		if (clusterFilter != null) {
			final wanted: String = (clusterFilter: String);
			final hit: Null<ReconCluster> = clusters[wanted];
			if (hit == null) {
				CliIo.stderr('apq recon: --cluster "$wanted" matched no cluster key (exact match).\n');
				final keyEntries: Array<{ key: String, count: Int }> = [
					for (k => v in clusters) { key: k, count: v.count }
				];
				keyEntries.sort((a, b) -> b.count - a.count);
				final preview: Int = keyEntries.length > CLUSTER_PREVIEW_LIMIT ? CLUSTER_PREVIEW_LIMIT : keyEntries.length;
				if (preview == 0) {
					CliIo.stderr('  (no skip-parse failures in this sweep)\n');
				} else {
					CliIo.stderr('  available keys (${keyEntries.length} total, showing top $preview by frequency):\n');
					for (idx in 0...preview) CliIo.stderr('    "${keyEntries[idx].key}"  (${keyEntries[idx].count}×)\n');
					if (keyEntries.length > preview)
						CliIo.stderr('    … (${keyEntries.length - preview} more — run without --cluster to see the full histogram)\n');
				}
				return EXIT_RUNTIME;
			}
			filteredClusters = [wanted => hit];
			filteredRecords = [for (r in records) if (r.clusterKey == wanted) r];
		}
		if (predictStrip)
			return ReconPredict.runReconPredictStrip(
				filteredRecords, plugin, patterns, replacements, compiledRegex, clusterFilter, showSource
			);
		for (r in filteredRecords) CliIo.sysPrint('${r.skipLine}\n');
		return clusterFilter != null
			? printReconClusterDrill(filteredClusters, records.length, (clusterFilter: String), filteredRecords, showSource)
			: printReconHistogram(clusters, records.length, topN);
	}

	/**
	 * Corpus-walk extracted from `runReconSweep` so the same skip-parse
	 * record list drives both the recon sweep (histogram / cluster drill
	 * / predict-strip) and `strip --from-cluster` (apply substitutions
	 * to every file in a named cluster). Recurses into subdirs, parses
	 * each `.hxtest` via the plugin's trivia parser, and clusters
	 * failures by normalised forward-locus. `wired == false` when the
	 * plugin returns `false` from `reconParse` — surfaces the same
	 * "no recon parser for lang X" error in both callers.
	 */
	public static function collectReconSkipRecords(plugin: GrammarPlugin, root: String): ReconWalkResult {
		final clusters: Map<String, ReconCluster> = [];
		final records: Array<ReconRecord> = [];
		var wired: Bool = true;
		final stack: Array<String> = [root];
		while (stack.length > 0) {
			final dir: Null<String> = stack.pop();
			if (dir == null) break;
			final names: Array<String> = FileSystem.readDirectory(dir);
			names.sort((a: String, b: String) -> if (a < b)
				-1
			else if (a > b)
				1
			else
				0);
			for (name in names) {
				final path: String = '$dir/$name';
				if (FileSystem.isDirectory(path)) {
					stack.push(path);
					continue;
				}
				if (!name.endsWith('.hxtest')) continue;
				final source: String = CliIo.readSourceForParse(path);
				try {
					if (!plugin.reconParse(source)) {
						wired = false;
						break;
					}
				} catch (exception: ParseError) {
					final pos: Position = exception.span.lineCol(source);
					final relPath: String = stripRootPrefix(path, root);
					final exp: String = reconNormalize(exception.expected);
					final snip: String = reconNormalize(reconSnippet(source, exception.span.from));
					final rawLocus: String = reconRawLocus(source, exception.span.from);
					final key: String = reconNormalizeLocus(rawLocus);
					addReconCluster(clusters, key, relPath, rawLocus);
					records.push({
						path: relPath,
						clusterKey: key,
						source: source,
						skipLine: 'SKIP $relPath :: ${pos.line}:${pos.col} expected="$exp" :: src="$snip"',
						line: pos.line,
						col: pos.col
					});
				} catch (exception: Exception) {
					final relPath: String = stripRootPrefix(path, root);
					final key: String = '<non-ParseError> ${reconNormalize(exception.message)}';
					addReconCluster(clusters, key, relPath, '<exception>');
					records.push({
						path: relPath,
						clusterKey: key,
						source: source,
						skipLine: 'SKIP $relPath :: $key',
						line: 0,
						col: 0
					});
				}
			}
			if (!wired) break;
		}
		return { wired: wired, records: records, clusters: clusters };
	}

	private static function printReconHistogram(clusters: Map<String, ReconCluster>, total: Int, topN: Int): Int {
		final entries: Array<{ key: String, cluster: ReconCluster }> = [
			for (k => v in clusters) { key: k, cluster: v }
		];
		entries.sort((a, b) -> b.cluster.count - a.cluster.count);
		final shown: Int = entries.length > topN ? topN : entries.length;
		CliIo.sysPrint('\n');
		CliIo.sysPrint(
			'--- skip-parse construct-locus histogram (total $total, showing top $shown of ${entries.length}; --all overrides) ---\n'
		);
		for (idx in 0...shown) {
			final entry: { key: String, cluster: ReconCluster } = entries[idx];
			final c: ReconCluster = entry.cluster;
			final examplesStr: String = c.examples.length == 1 ? c.examples[0] : c.examples.join(', ');
			final raw: String = reconNormalize(c.rawSample);
			CliIo.sysPrint('  ${c.count}× "${entry.key}"  e.g. "$raw"  in: $examplesStr\n');
		}
		if (entries.length > shown) CliIo.sysPrint('  … (${entries.length - shown} more, use --top N or --all to see)\n');
		return EXIT_OK;
	}

	/**
	 * `--cluster <substr>` drill output: one block per matching
	 * cluster with the FULL path list (not the histogram's capped
	 * `examples` array). Sorted descending by cluster size; paths
	 * sorted ascending so output is stable. Replaces the global
	 * histogram in this mode.
	 *
	 * When `showSource` is true, each printed path is followed by a
	 * fenced window of source bytes around the fail-locus
	 * (`RECON_SOURCE_WINDOW_RADIUS` lines either side). Replaces the
	 * manual Read-per-path step after `--cluster` drill.
	 */
	private static function printReconClusterDrill(
		matches: Map<String, ReconCluster>, totalAcrossSweep: Int, needle: String, records: Array<ReconRecord>, showSource: Bool
	): Int {
		final entries: Array<{ key: String, cluster: ReconCluster }> = [
			for (k => v in matches) { key: k, cluster: v }
		];
		entries.sort((a, b) -> b.cluster.count - a.cluster.count);
		var matched: Int = 0;
		for (e in entries) matched += e.cluster.count;
		// Map path → record so the windowed source / locus lookup stays
		// O(1) per path even in clusters with hundreds of fixtures.
		// Built once for the drill block regardless of `showSource`
		// (cost is negligible vs the walk itself).
		final byPath: Map<String, ReconRecord> = [for (r in records) r.path => r];
		CliIo.sysPrint('\n');
		CliIo.sysPrint(
			'--- cluster drill for "$needle" (${entries.length} cluster${CliIo.plural(entries.length)}, $matched of $totalAcrossSweep'
			+ ' skip-parse paths) ---\n'
		);
		for (entry in entries) {
			final c: ReconCluster = entry.cluster;
			CliIo.sysPrint('  cluster "${entry.key}" — ${c.count} path${CliIo.plural(c.count)}:\n');
			final sorted: Array<String> = c.paths.copy();
			sorted.sort((a, b) -> if (a < b)
				-1
			else if (a > b)
				1
			else
				0);
			for (p in sorted) {
				if (!showSource) {
					CliIo.sysPrint('    $p\n');
					continue;
				}
				final rec: Null<ReconRecord> = byPath[p];
				if (rec == null) {
					CliIo.sysPrint('    $p   <no record>\n');
					continue;
				}
				if (rec.line <= 0) {
					CliIo.sysPrint('    $p   <no locus>\n');
					continue;
				}
				CliIo.sysPrint('    $p at ${rec.line}:${rec.col}\n');
				printReconSourceWindow(rec.source, rec.line);
			}
		}
		return EXIT_OK;
	}

	/**
	 * Emit a windowed source slice centred on `failLine` (1-indexed) to
	 * stdout, with a `>>` marker on the fail row and right-aligned line
	 * numbers. Window radius is `RECON_SOURCE_WINDOW_RADIUS` either
	 * side; lines past EOF are silently clipped so a fail near the top
	 * or bottom prints as much context as is available.
	 */
	public static function printReconSourceWindow(source: String, failLine: Int): Void {
		final lines: Array<String> = source.split('\n');
		final radius: Int = RECON_SOURCE_WINDOW_RADIUS;
		final start: Int = failLine - radius < 1 ? 1 : failLine - radius;
		final end: Int = failLine + radius > lines.length ? lines.length : failLine + radius;
		CliIo.sysPrint('      --- src window (L±$radius) ---\n');
		// Compute the gutter width from `end` so all rows line up; e.g.
		// a 3-digit end-line gives a 3-char gutter.
		final gutter: Int = ('$end').length;
		for (ln in start ... end + 1) {
			final marker: String = ln == failLine ? '>>' : '  ';
			final num: String = padLeft('$ln', gutter);
			final body: String = lines[ln - 1];
			CliIo.sysPrint('      $marker$num | $body\n');
		}
		CliIo.sysPrint('      --- end ---\n');
	}

	private static inline function padLeft(s: String, width: Int): String {
		var out: String = s;
		while (out.length < width) out = ' $out';
		return out;
	}

	/**
	 * Render the predict-strip "moved locus" suffix. Three regimes:
	 *  - Same locus → empty (no hint needed).
	 *  - NEW > ORIG (line strictly greater, or same line + col strictly
	 *    greater) → ` (was L:C, advanced)` — strip uncovered a downstream
	 *    blocker; the substitution's effect was forward, so the residual
	 *    fail is a real second blocker.
	 *  - NEW < ORIG (line less, or same line + col less) → ` (was L:C,
	 *    moved BACKWARD — strip may have damaged earlier syntax, or your
	 *    substitution model doesn't match the actual blocker mechanism;
	 *    verify with `apq probe` on the unstripped fragment)` — the
	 *    common failure mode where token substitution
	 *    can't model gate-relaxation.
	 *  - Same line, col differs → ` (was L:C)` — neutral; the strip
	 *    shifted things within one line, usually inconsequential.
	 *
	 * `origLine == 0` means the original error had no locus (rare —
	 * `<no locus>` already printed instead); guard returns empty.
	 */
	public static inline function movedLocusHint(origLine: Int, origCol: Int, newLine: Int, newCol: Int): String {
		if (origLine <= 0) return '';
		if (newLine == origLine && newCol == origCol) return '';
		final forward: Bool = newLine > origLine || (newLine == origLine && newCol > origCol);
		final backward: Bool = newLine < origLine || (newLine == origLine && newCol < origCol);
		return if (forward && newLine != origLine)
			' (was $origLine:$origCol, advanced)'
		else if (backward)
			' (was $origLine:$origCol'
				+ ', moved BACKWARD — strip may have damaged earlier syntax or modelled the wrong mechanism; verify with `apq probe`)'
		else
			' (was $origLine:$origCol)';
	}

	public static function defaultReconRoot(): String {
		final fork: Null<String> = resolveForkPath();
		if (fork == null || fork.length == 0) return '';
		final candidate: String = '$fork/test/testcases';
		final resolved: String = FileSystem.exists(candidate) && FileSystem.isDirectory(candidate) ? candidate : fork;
		// Write-cache: persist the env-supplied path to
		// `~/.config/anyparse/fork_path` so the next `apq recon` works
		// WITHOUT re-exporting the env var. Env always wins; the cache
		// is consulted only by `resolveForkPath` when env is unset.
		// `tryWriteForkPathCache` short-circuits when the on-disk value
		// already matches, so steady-state writes are no-ops.
		#if (sys || nodejs)
		final envFork: Null<String> = Sys.getEnv('ANYPARSE_HXFORMAT_FORK');
		if (envFork != null && envFork.length > 0) tryWriteForkPathCache(envFork);
		#end
		return resolved;
	}

	/**
	 * Resolve the haxe-formatter fork path with env > config-cache
	 * precedence. The env var IS the canonical source — the cache
	 * exists only to spare the user from re-exporting it on every
	 * session. A cached path that no longer points at a directory is
	 * dropped silently (a stale config should never block a `recon` run
	 * — the user gets the same `env var is unset` usage error as before).
	 */
	private static function resolveForkPath(): Null<String> {
		final env: Null<String> = Sys.getEnv('ANYPARSE_HXFORMAT_FORK');
		if (env != null && env.length > 0) return env;
		#if (sys || nodejs)
		final cached: Null<String> = readForkPathCache();
		if (cached != null && cached.length > 0 && FileSystem.exists(cached) && FileSystem.isDirectory(cached)) return cached;
		#end
		return null;
	}

	private static function forkPathCacheFile(): Null<String> {
		final home: Null<String> = Sys.getEnv('HOME');
		return home == null || home.length == 0 ? null : '$home/.config/anyparse/fork_path';
	}

	private static function readForkPathCache(): Null<String> {
		final path: Null<String> = forkPathCacheFile();
		if (path == null || !FileSystem.exists(path)) return null;
		try {
			final raw: String = sys.io.File.getContent(path);
			final trimmed: String = raw.trim();
			return trimmed.length > 0 ? trimmed : null;
		} catch (_: Exception) {
			return null;
		}
	}

	private static function tryWriteForkPathCache(value: String): Void {
		final path: Null<String> = forkPathCacheFile();
		if (path == null) return;
		// Skip write when the cache already matches — avoids a useless
		// disk hit on every recon invocation under the same env.
		try {
			if (FileSystem.exists(path)) {
				final existing: String = StringTools.trim(sys.io.File.getContent(path));
				if (existing == value) return;
			}
		} catch (_: Exception) {
			// best-effort: an unreadable existing file just proceeds to (over)write
		}
		try {
			final dir: String = haxe.io.Path.directory(path);
			if (dir.length > 0 && !FileSystem.exists(dir)) FileSystem.createDirectory(dir);
			sys.io.File.saveContent(path, value);
		} catch (_: Exception) {
			// Best-effort cache write — never block recon on a write
			// failure (read-only HOME, disk full, permission). The env
			// path stays valid for the current run.
		}
	}

	public static function stripRootPrefix(path: String, root: String): String {
		return if (path.startsWith('$root/'))
			path.substr(root.length + 1)
		else if (path == root)
			'.'
		else
			path;
	}

	private static function addReconCluster(map: Map<String, ReconCluster>, key: String, file: String, rawLocus: String): Void {
		final prev: Null<ReconCluster> = map[key];
		if (prev == null) {
			map[key] = {
				count: 1,
				examples: [file],
				paths: [file],
				rawSample: rawLocus
			};
		} else {
			prev.count++;
			prev.paths.push(file);
			if (prev.examples.length < RECON_EXAMPLES_PER_CLUSTER) prev.examples.push(file);
		}
	}

	/**
	 * Raw forward locus — `RECON_LOCUS_LEN` chars starting AT the fail
	 * position. Used both as the cluster's raw sample (display) and as
	 * input to the normaliser (cluster key).
	 */
	private static function reconRawLocus(input: String, offset: Int): String {
		final start: Int = offset > input.length ? input.length : offset;
		final end: Int = start + RECON_LOCUS_LEN > input.length ? input.length : start + RECON_LOCUS_LEN;
		return input.substring(start, end);
	}

	/**
	 * Normalise the forward locus into a cluster key — identifier runs
	 * of length > 4 collapse to `_`, shorter runs (Haxe short keywords
	 * `var`, `is`, `as`, `in`, `for`, `try`, `new`, `if`, `else`,
	 * `case`, etc.) are kept verbatim so they remain visible in the
	 * histogram. Punctuation, operators and whitespace pass through.
	 * `reconNormalize` then escapes whitespace for one-line display.
	 */
	private static function reconNormalizeLocus(raw: String): String {
		final buf: StringBuf = new StringBuf();
		var i: Int = 0;
		while (i < raw.length) {
			final c: Int = raw.fastCodeAt(i);
			final isIdStart: Bool = (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || c == '_'.code;
			if (isIdStart) {
				var j: Int = i + 1;
				while (j < raw.length) {
					final cj: Int = raw.fastCodeAt(j);
					final isIdCont: Bool = (cj >= 'a'.code && cj <= 'z'.code) || (cj >= 'A'.code && cj <= 'Z'.code)
						|| (cj >= '0'.code && cj <= '9'.code) || cj == '_'.code;
					if (!isIdCont) break;
					j++;
				}
				final identLen: Int = j - i;
				if (identLen > 4) // noqa: magic-number
					buf.add('_');
				else
					for (k in i ... j) buf.addChar(raw.fastCodeAt(k));
				i = j;
			} else {
				buf.addChar(c);
				i++;
			}
		}
		return reconNormalize(buf.toString());
	}

	/**
	 * Source window of `RECON_HEAD_LEN` characters centred on `offset`
	 * — the text around the farthest-failure locus, for the human-
	 * readable SKIP line. Whitespace is escaped by `reconNormalize`.
	 */
	public static function reconSnippet(input: String, offset: Int): String {
		final half: Int = Std.int(RECON_HEAD_LEN / 2);
		final centre: Int = offset > input.length ? input.length : offset;
		final start: Int = centre - half < 0 ? 0 : centre - half;
		final end: Int = centre + half > input.length ? input.length : centre + half;
		return input.substring(start, end);
	}

	public static function reconNormalize(message: Null<String>): String {
		return message == null || message == ''
			? '<no message>'
			: StringTools.replace(StringTools.replace(message, '\n', '\\n'), '\t', '\\t');
	}
	#end

}
