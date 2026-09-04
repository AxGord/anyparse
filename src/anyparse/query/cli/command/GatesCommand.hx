package anyparse.query.cli.command;

import anyparse.query.GrammarPlugin.MetaShape;
import anyparse.query.Meta.MetaHit;
import anyparse.query.cli.CliArgs;
import anyparse.query.cli.CliContext;
import anyparse.query.cli.CliWalk;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.ExitCode.*;

using StringTools;
using Lambda;

/**
 * Per-field format-mechanism summary the `recon` walk projects from a schema field's `@:fmt` / `@:lit` metadata: whether it is optional plus its lead / trail / kw / sep tokens and `absentOn` flag. Feeds cluster keying and relaxation prediction.
 */
typedef MechanismMetas = {
	var hasOptional: Bool;
	var lead: Null<String>;
	var trail: Null<String>;
	var kw: Null<String>;
	var absentOn: Null<String>;
	var sep: Null<String>;
};

/**
 * One trail-opt gate annotation hit surfaced by `apq gates`. `line`/`col`
 * point at the decl host the `@:fmt` is attached to (1-indexed, derived
 * from the decl span via `Span.lineCol`). `gateKind` is the call name
 * (`trailOptParseGate` / `trailOptShapeGate`), `predicate` the quoted
 * inner symbol — the field name to look up on the schema instance.
 */
typedef GateHit = {
	var line: Int;
	var col: Int;
	var declKind: String;
	var declName: Null<String>;
	var gateKind: String;
	var predicate: String;
};

/**
 * Intermediate parse result of `extractGate` — `gateKind` is the call
 * name without parens, `predicate` the quoted inner symbol. `null` from
 * the extractor means the `@:fmt` argument is not a gate call.
 */
typedef GateExtract = { gateKind: String, predicate: String };

/**
 * Parsed options for `apq gates` — `lang`, `flat`, `limit`, the `mechanism` to inspect, and `inputSpecs`. `errExit` non-null means arg parsing hit a terminal case the caller returns immediately.
 */
@:nullSafety(Strict)
typedef GatesOpts = {
	var lang: String;
	var flat: Bool;
	var limit: Int;
	var mechanism: String;
	var inputSpecs: Array<String>;
	// Non-null = parsing hit a terminal case (`-h` -> EXIT_OK, a bad flag -> EXIT_USAGE);
	// the caller returns this immediately and ignores the rest of the struct.
	var errExit: Null<Int>;
};

/**
 * `apq gates` — list @:fmt(trailOptParseGate/trailOptShapeGate) annotations + predicate names.
 *
 * A multi-file WALK: the path specs go through `CliArgs`, the files through `CliWalk`,
 * and an empty result answers `ctx.emptyExit` so a script can tell "found nothing"
 * from "ran fine".
 */
@:nullSafety(Strict)
final class GatesCommand implements CliCommand {

	public function new() {}

	public function name(): String {
		return 'gates';
	}

	public function summary(): String {
		return 'List @:fmt(trailOptParseGate/trailOptShapeGate) annotations + predicate names';
	}

	public function run(args: Array<String>, ctx: CliContext): Int {
		return runGates(args);
	}

	public function usage(): Void {
		printGatesUsage();
	}

	private static inline function gatesParseExit(code: Int): GatesOpts {
		return {
			lang: '',
			flat: false,
			limit: -1,
			mechanism: 'trail-opt',
			inputSpecs: [],
			errExit: code
		};
	}

	/**
	 * `apq gates [<file-or-dir-or-glob>...]` — list every ctor decl
	 * carrying `@:fmt(trailOptParseGate('<predicate>'))` or
	 * `@:fmt(trailOptShapeGate('<predicate>'))`. THE structural answer
	 * to "which ctors gate their trailing terminator on a runtime
	 * predicate, and what predicate?" — the data you need before
	 * picking a gate-relaxation change. Without
	 * this, the gate predicate is invisible until you grep the grammar
	 * by hand.
	 *
	 * Default scope: `src/anyparse/grammar/<lang>/` when run with no
	 * positional. Otherwise walks every file/dir/glob given.
	 *
	 * Output (per hit, grouped by file):
	 *   <file>:
	 *     <L>:<C>: <DeclKind> <name?> → <gate-call>
	 *
	 * Two recognised gate flavours:
	 *  - `trailOptParseGate('<predicate>')` — drives the runtime gate
	 *    on `@:trailOpt` (parser-side). The predicate is the generated
	 *    `AstPreds*.<predicate>` (or the schema plugin's instance).
	 *  - `trailOptShapeGate('<predicate>')` — drives the writer-side
	 *    decision for `var x = …` rhs and similar.
	 *
	 * Mutually intelligible with `apq meta @:fmt <dir>
	 * --arg-contains trailOptParseGate` — `gates` is the focused view
	 * that extracts just the predicate name and groups by gate flavour.
	 */
	private static function runGates(args: Array<String>): Int {
		final o: GatesOpts = parseGatesArgs(args);
		if (o.errExit != null) return o.errExit;
		final lang: String = o.lang;
		final flat: Bool = o.flat;
		final limit: Int = o.limit;
		final mechanism: String = o.mechanism;
		final validMechanisms: Array<String> = [
			'trail-opt',
			'optional-ref',
			'optional-ref-trail',
			'mandatory-ref-lead-trail',
			'kw-lead'
		];
		if (!validMechanisms.contains(mechanism)) {
			CliIo.stderr('apq gates: unknown --mechanism "$mechanism" (valid: ${validMechanisms.join(', ')})\n');
			return EXIT_USAGE;
		}
		// Default scope: the grammar tree for the selected lang.
		final effectiveSpecs: Array<String> = o.inputSpecs.length > 0 ? o.inputSpecs : ['src/anyparse/grammar/$lang/'];

		final plugin: GrammarPlugin = CliArgs.pickPlugin(lang);
		final shape: MetaShape = plugin.metaShape();
		final expanded: ExpandedInputs = CliArgs.expandInputs(effectiveSpecs, '.hx');
		final paths: Array<String> = expanded.paths;
		if (paths.length == 0) {
			CliIo.stderr('apq gates: no input files matched ${CliArgs.quotedSpecs(effectiveSpecs)}\n');
			return EXIT_RUNTIME;
		}

		final singleFile: Bool = expanded.singleFile;
		final skipEntries: Array<SkipEntry> = [];
		final allHits: Array<{ file: String, source: String, hits: Array<GateHit> }> = [];
		var totalHits: Int = 0;
		for (path in paths) {
			final source: String = CliIo.readSourceForParse(path);
			final tree: Null<QueryNode> = CliWalk.parseWalked('gates', plugin.parseFile, path, source, singleFile, skipEntries);
			if (tree == null) {
				if (singleFile) return EXIT_RUNTIME;
				continue;
			}
			final raw: Array<MetaHit> = Meta.find(tree, shape, source);
			final fileHits: Array<GateHit> = mechanism == 'trail-opt'
				? collectTrailOptHits(raw, source, limit, totalHits)
				: collectMechanismHits(raw, source, mechanism, limit, totalHits);
			totalHits += fileHits.length;
			if (fileHits.length > 0) allHits.push({ file: path, source: source, hits: fileHits });
		}

		if (allHits.length == 0) {
			CliIo.stderr('apq gates: no ${gatesNoHitsLabel(mechanism)} in ${paths.length} file(s) scanned\n');
			return EXIT_OK;
		}

		emitGateHits(allHits, mechanism, flat);
		return EXIT_OK;
	}

	/**
	 * Original trail-opt walker — extracted from `runGates` body to
	 * peer with `collectMechanismHits` under the `--mechanism` switch.
	 * Iterates raw MetaHits one at a time and pushes one `GateHit` per
	 * matching `@:fmt(trailOpt*Gate(...))` argument; preserves the
	 * pre-`--mechanism` output and limit semantics.
	 */
	private static function collectTrailOptHits(raw: Array<MetaHit>, source: String, limit: Int, sharedTotal: Int): Array<GateHit> {
		final out: Array<GateHit> = [];
		for (h in raw) if (h.annotation == '@:fmt') for (arg in h.args) {
			final extracted: Null<GateExtract> = extractGate(arg);
			if (extracted == null) continue;
			if (limit >= 0 && sharedTotal + out.length >= limit) break;
			out.push({
				line: h.declSpan != null ? h.declSpan.lineCol(source).line : 0,
				col: h.declSpan != null ? h.declSpan.lineCol(source).col : 0,
				declKind: h.declKind,
				declName: h.declName,
				gateKind: extracted.gateKind,
				predicate: extracted.predicate
			});
		}
		return out;
	}

	/**
	 * Bucket raw MetaHits by their `declSpan.from` — one bucket per
	 * field / branch / ctor that carries annotations. Returns the
	 * grouping map plus a parallel `order` array that preserves
	 * first-seen source order so downstream emitters render in file
	 * layout, not Map iteration order.
	 *
	 * Shared by `collectMechanismHits` (gates --mechanism) and
	 * `collectPermissiveCandidates` (recon --permissive-construct).
	 * Both consumers need the same grouping shape; factoring it out
	 * keeps the bucket-build logic single-sourced.
	 */
	public static function groupMetaHitsByDeclSpan(raw: Array<MetaHit>): { order: Array<Int>, groups: Map<Int, Array<MetaHit>> } {
		final order: Array<Int> = [];
		final groups: Map<Int, Array<MetaHit>> = [];
		for (h in raw) {
			final span: Null<Span> = h.declSpan;
			if (span == null) continue;
			final key: Int = span.from;
			var bucket: Null<Array<MetaHit>> = groups[key];
			if (bucket == null) {
				bucket = [];
				groups[key] = bucket;
				order.push(key);
			}
			bucket.push(h);
		}
		return { order: order, groups: groups };
	}

	/**
	 * `--mechanism <name>` walker. Groups raw MetaHits by their decl-host
	 * span (one group = all annotations on a single field / branch /
	 * ctor) and classifies each group by the requested mechanism's
	 * meta-set signature. Output's `predicate` field carries the
	 * rendered metas string (NOT a quoted symbol — the trail-opt
	 * formatter is bypassed via the `mechanism != 'trail-opt'` branch
	 * in the caller). Groups are emitted in source-order so the report
	 * matches the file layout.
	 */
	private static function collectMechanismHits(
		raw: Array<MetaHit>, source: String, mechanism: String, limit: Int, sharedTotal: Int
	): Array<GateHit> {
		final grouped: { order: Array<Int>, groups: Map<Int, Array<MetaHit>> } = groupMetaHitsByDeclSpan(raw);
		final out: Array<GateHit> = [];
		for (key in grouped.order) {
			if (limit >= 0 && sharedTotal + out.length >= limit) break;
			final metas: Null<Array<MetaHit>> = grouped.groups[key];
			if (metas == null) continue;
			final label: Null<String> = classifyMechanism(metas, mechanism);
			if (label == null) continue;
			final first: MetaHit = metas[0];
			final fspan: Null<Span> = first.declSpan;
			out.push({
				line: fspan != null ? fspan.lineCol(source).line : 0,
				col: fspan != null ? fspan.lineCol(source).col : 0,
				declKind: first.declKind,
				declName: first.declName,
				gateKind: '', // unused for non-trail-opt mechanisms
				predicate: (label: String)
			});
		}
		return out;
	}

	/**
	 * Mechanism classifier — returns the rendered metas label when the
	 * meta set on a single decl/field matches the requested mechanism's
	 * signature, `null` otherwise. The label is the small list of
	 * `@:annotation(...)` tokens that drive the mechanism, joined with
	 * single spaces — same shape a grammar author would see in the
	 * source. `@:fmt(...)` flags are NOT included (they're orthogonal
	 * to the mechanism dispatch); the label focuses on the parser-side
	 * structural metas.
	 */
	private static function classifyMechanism(metas: Array<MetaHit>, mechanism: String): Null<String> {
		final m: MechanismMetas = readMechanismMetas(metas);
		return mechanismMatches(m, mechanism) ? renderMetaList(m.hasOptional, m.kw, m.lead, m.trail, m.absentOn) : null;
	}

	private static function renderMetaList(
		hasOptional: Bool, kw: Null<String>, lead: Null<String>, trail: Null<String>, absentOn: Null<String>
	): String {
		final parts: Array<String> = [];
		if (hasOptional) parts.push('@:optional');
		if (kw != null) parts.push('@:kw($kw)');
		if (lead != null) parts.push('@:lead($lead)');
		if (trail != null) parts.push('@:trail($trail)');
		if (absentOn != null) parts.push('@:absentOn($absentOn)');
		return parts.join(' ');
	}

	/**
	 * Parse `trailOptParseGate('<pred>')` or `trailOptShapeGate('<pred>')`
	 * out of a single `@:fmt` argument string. Returns `null` if the
	 * arg isn't a gate call — `@:fmt(...)` carries many other flags
	 * (`tightLead`, `wrapRules(...)`, `bodyPolicy(...)`, …) which
	 * `gates` deliberately ignores. Hand-rolled parser to keep the
	 * walker independent of the format/wrap plugin types.
	 */
	private static function extractGate(arg: String): Null<GateExtract> {
		final trimmed: String = arg.trim();
		final markers: Array<String> = ['trailOptParseGate', 'trailOptShapeGate'];
		for (m in markers) if (trimmed.startsWith(m)) {
			final after: String = trimmed.substr(m.length).trim();
			if (!after.startsWith('(')) continue;
			final inner: String = after.substring(1, after.lastIndexOf(')')).trim();
			// `trailOptShapeGate` takes multiple args (`'endsWithCloseBrace', 'init'`);
			// extract just the FIRST quoted string — that's the predicate
			// method name on the schema instance. Subsequent args are
			// flag-bearing (typically a field-name selector) and not part
			// of the predicate identity.
			final firstArg: String = sliceFirstQuotedArg(inner);
			final stripped: String = CliArgs.stripQuotes(firstArg);
			if (stripped.length == 0) continue;
			return { gateKind: m, predicate: stripped };
		}
		return null;
	}

	/**
	 * Pick the first comma-separated argument from a paren-list body.
	 * Quote-aware: a comma INSIDE a `'…'` / `"…"` doesn't terminate the
	 * arg. Returns the trimmed first segment; the whole string when no
	 * top-level comma exists.
	 */
	private static function sliceFirstQuotedArg(inner: String): String {
		var inSingle: Bool = false;
		var inDouble: Bool = false;
		for (i in 0...inner.length) {
			final c: Int = inner.fastCodeAt(i);
			if (!inDouble && c == "'".code)
				inSingle = !inSingle;
			else if (!inSingle && c == '"'.code)
				inDouble = !inDouble;
			else if (!inSingle && !inDouble && c == ','.code)
				return inner.substring(0, i).trim();
		}
		return inner.trim();
	}

	private static function printGatesUsage(): Void {
		CliIo.sysPrint('Usage: apq gates [<file-or-dir-or-glob>...] [--flat] [--limit N] [--mechanism <name>]\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Default (--mechanism trail-opt): list ctor decls carrying\n');
		CliIo.sysPrint('`@:fmt(trailOptParseGate(\'<pred>\'))` / `trailOptShapeGate(\'<pred>\')` and\n');
		CliIo.sysPrint('the predicate name they dispatch. Pre-`--mechanism` output 1:1.\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Other --mechanism values inventory grammar surface by Lowering pattern:\n');
		CliIo.sysPrint('  optional-ref          — `@:optional` Ref fields with @:lead/@:kw/@:absentOn\n');
		CliIo.sysPrint('                          (already-relaxed precedent sites).\n');
		CliIo.sysPrint('  optional-ref-trail    — `@:optional @:lead @:trail` Ref bracket-pair\n');
		CliIo.sysPrint('                          (Slice 40 mechanism — current consumers).\n');
		CliIo.sysPrint('  mandatory-ref-lead-trail\n');
		CliIo.sysPrint('                        — mandatory Ref with @:lead+@:trail (no @:optional).\n');
		CliIo.sysPrint('                          THE predict-optional fallback candidate list —\n');
		CliIo.sysPrint('                          fields you could relax via Slice 40\'s mechanism.\n');
		CliIo.sysPrint('  kw-lead               — fields with @:kw (keyword-dispatched).\n');
		CliIo.sysPrint('\n');
		CliIo.sysPrint('Default scope: src/anyparse/grammar/<lang>/ (haxe by default).\n');
	}

	/**
	 * Read the @:optional / @:lead / @:trail / @:kw / @:absentOn / @:sep
	 * metas off one decl group (raw arg values, not unquoted).
	 */
	private static function readMechanismMetas(metas: Array<MetaHit>): MechanismMetas {
		var hasOptional: Bool = false;
		var lead: Null<String> = null;
		var trail: Null<String> = null;
		var kw: Null<String> = null;
		var absentOn: Null<String> = null;
		var sep: Null<String> = null;
		for (h in metas) switch h.annotation {
			case '@:optional':
				hasOptional = true;
			case '@:lead':
				lead = h.args.length > 0 ? h.args[0] : null;
			case '@:trail':
				trail = h.args.length > 0 ? h.args[0] : null;
			case '@:kw':
				kw = h.args.length > 0 ? h.args[0] : null;
			case '@:absentOn':
				absentOn = h.args.length > 0 ? h.args[0] : null;
			case '@:sep':
				sep = h.args.length > 0 ? h.args[0] : null;
			case _:
		}
		return {
			hasOptional: hasOptional,
			lead: lead,
			trail: trail,
			kw: kw,
			absentOn: absentOn,
			sep: sep
		};
	}

	/**
	 * Whether a decl group's metas qualify under the requested mechanism.
	 * `optional-ref` = optional single Ref (excluding Star @:sep); `optional-ref-trail` = the relaxed bracket-pair shape, `mandatory-ref-lead-trail` = its unrelaxed precursor; `kw-lead` = any keyword-dispatched field.
	 */
	private static function mechanismMatches(m: MechanismMetas, mechanism: String): Bool {
		return switch mechanism {
			case 'optional-ref':
				// Star fields with @:sep are excluded — they're the angle-
				// bracket array shape, not single Ref optional. Inspect
				// declName / declKind manually if you need both.
				m.hasOptional && (m.lead != null || m.kw != null || m.absentOn != null) && m.sep == null;
			case 'optional-ref-trail':
				// The relaxed bracket-pair signature: optional + lead + trail, no sep.
				m.hasOptional && m.lead != null && m.trail != null && m.sep == null;
			case 'mandatory-ref-lead-trail':
				// Unrelaxed bracket-pair shape on a single Ref — the predict-optional
				// fallback candidates (turn `@:lead + @:trail` into
				// `@:optional @:lead + @:trail`). Exclude Star (`@:sep`)
				// — angle-bracket arrays are not the target.
				!m.hasOptional && m.lead != null && m.trail != null && m.sep == null;
			case 'kw-lead':
				m.kw != null;
			case _:
				false;
		};
	}

	private static function parseGatesArgs(args: Array<String>): GatesOpts {
		var lang: String = 'haxe';
		var flat: Bool = false;
		var limit: Int = -1;
		// `--mechanism <name>` extends `gates` from its original
		// `trail-opt`-only scope (`@:fmt(trailOptParseGate(...))` /
		// `trailOptShapeGate(...)`) to other Lowering mechanisms whose
		// `--predict-relax`-style relaxation potential we want to
		// inventory ahead of a grammar change:
		//   - `optional-ref` — fields with `@:optional` + `@:lead` /
		//     `@:kw` / `@:absentOn`. Already-relaxed precedent sites.
		//   - `optional-ref-trail` — the relaxed bracket-pair pattern (`@:optional`
		//     + `@:lead` + `@:trail` on a single Ref), used by
		//     `HxAbstractDecl.underlyingType`. THE list of bracket-pair
		//     fields you could optionalize via this mechanism.
		//   - `mandatory-ref-lead-trail` — Ref fields with `@:lead` +
		//     `@:trail` (bracket pair) WITHOUT `@:optional`. The
		//     unrelaxed shape — candidates to relax via the optional-ref-trail
		//     mechanism. THIS IS THE PREDICT-OPTIONAL FALLBACK list.
		//   - `kw-lead` — fields with `@:kw`. Precedent sites for word-
		//     keyword dispatch on a single field.
		// Default value `trail-opt` preserves the bare `gates` output
		// 1:1 (existing tests assume this).
		var mechanism: String = 'trail-opt';
		final inputSpecs: Array<String> = [];

		var i: Int = 0;
		while (i < args.length) {
			final a: String = args[i];
			switch a {
				case '--lang':
					lang = CliArgs.expectValue(args, ++i, '--lang');
				case '--flat':
					flat = true;
				case '--limit':
					try limit = CliArgs.parseLimit(args, ++i) catch (e: Exception) {
						CliIo.stderr('${e.message}\n');
						return gatesParseExit(EXIT_USAGE);
					}
				case '--mechanism':
					mechanism = CliArgs.expectValue(args, ++i, '--mechanism');
				case '-h', '--help':
					printGatesUsage();
					return gatesParseExit(EXIT_OK);
				case _:
					if (a.startsWith('--')) {
						CliIo.stderr('apq gates: unknown option "$a"\n');
						return gatesParseExit(EXIT_USAGE);
					}
					inputSpecs.push(a);
			}
			i++;
		}
		return {
			lang: lang,
			flat: flat,
			limit: limit,
			mechanism: mechanism,
			inputSpecs: inputSpecs,
			errExit: null
		};
	}

	private static function gatesNoHitsLabel(mechanism: String): String {
		return switch mechanism {
			case 'trail-opt':
				'`@:fmt(trailOptParseGate(...))` / `@:fmt(trailOptShapeGate(...))` annotations';
			case 'optional-ref':
				'`@:optional` Ref fields with `@:lead` / `@:kw` / `@:absentOn`';
			case 'optional-ref-trail':
				'`@:optional @:lead @:trail` Ref fields (Slice 40 bracket-pair pattern)';
			case 'mandatory-ref-lead-trail':
				'mandatory Ref fields with `@:lead` + `@:trail` (relax candidates for Slice 40 mechanism)';
			case 'kw-lead':
				'fields with `@:kw`';
			case _: '<unknown mechanism>';
		};
	}

	private static function emitGateHits(
		allHits: Array<{ file: String, source: String, hits: Array<GateHit> }>, mechanism: String, flat: Bool
	): Void {
		for (entry in allHits) {
			if (!flat) CliIo.sysPrint('${entry.file}:\n');
			for (h in entry.hits) {
				final declLabel: String = h.declName == null ? h.declKind : '${h.declKind} ${h.declName}';
				final prefix: String = flat ? '${entry.file}:${h.line}:${h.col}: ' : '  ${h.line}:${h.col}: ';
				// trail-opt format preserved 1:1 for backwards-compat:
				// `<DeclKind> <name?> → trailOptParseGate('<pred>')`.
				// Other mechanisms render `<DeclKind> <name?> → <metas>`
				// where `<metas>` is the relevant subset of `@:` annotations
				// already-quoted in `predicate` (raw string from classifier).
				final tail: String = mechanism == 'trail-opt' ? '${h.gateKind}(\'${h.predicate}\')' : h.predicate;
				CliIo.sysPrint('$prefix$declLabel → $tail\n');
			}
		}
	}

}
