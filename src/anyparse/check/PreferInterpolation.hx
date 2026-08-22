package anyparse.check;

import anyparse.check.Check.OracleRelaxable;
import anyparse.check.Check.RiskyFix;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

using StringTools;

/**
 * Flags `Std.string(x)` and rewrites it to string interpolation — `'$x'` for a simple
 * identifier, `'${expr}'` for any other interpolation-safe expression — `Severity.Info`
 * (a modernization cleanup matching the Haxe idiom: direct conversion, no reflection
 * overhead), with an autofix.
 *
 * Minimal safe subset: only a single-argument `Std.string(...)` call is touched. An
 * argument whose source contains a quote, a `$`, or a newline is left alone — wrapping it
 * in `'${ … }'` could break the string (an inner `'` would close it). A call that is a
 * DIRECT operand of a `+` chain `fold-adjacent-string-literals` CLAIMS (`"a" +
 * Std.string(x)`) is skipped entirely: that rule owns the whole chain and peels the
 * `Std.string` wrapper off itself while re-segmenting, so a finding here would be one
 * question answered twice, with two fixes over overlapping spans. The claim is asked of
 * that rule directly (`FoldStringLiterals.ownsChain`), never guessed from the parent node
 * KIND: a chain with no string literal in it (`Std.string(a) + Std.string(b)`) is one it
 * never reports, so deferring there left the call flagged by nobody.
 *
 * ## Inside a string literal's `${...}` interpolation block
 *
 * The walk descends into interpolation BLOCKS (never into plain text segments) — a
 * `Std.string(x)` there is the same redundancy, sitting in a position that already
 * stringifies. Two rewrite modes:
 *
 * - the call IS the block's sole expression (`'v=${Std.string(x)}'`) — the wrapper is
 *   PEELED to `'v=${x}'`: a pure text motion within the block (the argument keeps its
 *   exact bytes and escape context), so it needs no `interpolationSafe` gate;
 * - the call sits deeper (a ternary branch, a call argument — a position that must stay
 *   String-typed) — the standard `'${expr}'` / `'$x'` rewrite nests an interpolated
 *   string inside the block. The compiler lexes nested same-quote strings via brace/quote
 *   balancing WITHOUT processing escapes inside them (compile-and-run verified at
 *   arbitrary nesting depth, byte-identical output) — which is exactly why
 *   `interpolationSafe`'s quote / dollar / backslash / newline refusals make the nested
 *   form sound.
 *
 * The fold hand-off is SUPPRESSED inside a string: `fold-adjacent-string-literals` never
 * descends into string literals (folding a chain there would nest the whole chain
 * interp-in-interp), so a `+` chain inside a block is one it would claim but never
 * visits — deferring would leave the call flagged by nobody. An annotation argument
 * (`metaKinds`) is the same hole spelled differently.
 *
 * ## Not equivalence-preserving for every argument
 *
 * `Std.string` accepts `Null<Dynamic>` and never rejects a nullable argument; the
 * interpolation form compiles to a `+`-concatenation that DOES, under
 * `@:nullSafety(Strict)`, reject a nullable operand — and field access never narrows
 * (a preceding `obj.field != null` guard does not make `obj.field` provably non-null to
 * the checker), so rewriting `Std.string(obj.field)` to `'${obj.field}'` can turn
 * working code into a null-safety compile error. A bare field access (`Std.string(o.f)`)
 * is therefore left alone unconditionally. A simple-identifier argument (a local /
 * parameter) is rewritten only when its resolved declaration is provably not itself
 * nullable — a known nominal type (unannotated / inferred locals are conservatively
 * skipped, their type being unknown) that is not `Null<…>` / `Dynamic` / `Any`, not an
 * optional parameter (`?p`), and not a default-null parameter (`p: T = null`). Any other
 * argument shape (a call, a binary expression, …) keeps the pre-existing
 * `interpolationSafe`-gated braced rewrite.
 *
 * ## Oracle-relaxed candidate set (`RiskyFix` + `OracleRelaxable`)
 *
 * That gate exists only to keep the rewrite COMPILE-safe under `@:nullSafety(Strict)`;
 * the value is never at stake (`'${x}'` compiles to the same conversion, and a `null`
 * prints `null` either way). With a compiler oracle configured (`apqlint.json`
 * `compilerOracle`), `Cli.applyLintFixes` moves this check into the verified `RiskyFix`
 * path and widens the candidate set (`setOracleRelaxed`): the `isSafeArg` gate drops, so
 * a bare field access and an unproven identifier become candidates — every edit is then
 * applied through the typecheck-and-revert pipeline, never unverified. Without an oracle
 * the check stays in the unverified safe loop with the gate ON (the `OracleRelaxable`
 * carve-out in `Cli.partitionChecks`), byte-identical to its pre-seam behavior.
 *
 * ## Grammar-agnostic
 *
 * Driven by `RefShape.callKind`, `fieldAccessKind`, and `identKind` (a missing optional
 * kind → no-op), plus `StringFoldSupport.concatKind` for the hand-off above; the receiver
 * `Std` and member `string` are matched on node names, not kinds. The interpolation
 * descent needs `RefShape.stringInterpBlockKind` — a grammar without it keeps the walk
 * stopping at string literals. The outermost matching call is flagged and not descended
 * into, so a nested `Std.string(Std.string(x))` yields one non-overlapping fix. The
 * identifier-safety gate degrades gracefully when `plugin` is not a `TypeInfoProvider`
 * (no declared-type map, treated as empty) — a simple identifier is then never proven
 * safe and is left alone.
 */
@:nullSafety(Strict)
final class PreferInterpolation implements Check implements RiskyFix implements OracleRelaxable {

	private var _oracleRelaxed: Bool = false;

	public function new() {}

	/**
	 * Enable RELAXED candidate selection: drop the `isSafeArg` null-safety gate, so a bare
	 * field access (`Std.string(o.f)`) and an identifier without a provably non-null
	 * declaration also become candidates. Set by `Cli.applyLintFixes` ONLY when this check
	 * runs as a verified `RiskyFix` (a compiler oracle is configured), so the extra
	 * candidates are always applied through the typecheck-and-revert pipeline, never
	 * unverified.
	 */
	public function setOracleRelaxed(relaxed: Bool): Void {
		_oracleRelaxed = relaxed;
	}

	public function id(): String {
		return 'prefer-interpolation';
	}

	public function description(): String {
		return "a Std.string(x) call replaceable with string interpolation ('$x')";
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final violations: Array<Violation> = [];
		for (entry in files) {
			final matches: Null<Array<ScanMatch>> = scanSource(entry.source, plugin, _oracleRelaxed, false);
			if (matches == null) continue;
			for (m in matches) violations.push({
				file: entry.file,
				span: m.span,
				rule: 'prefer-interpolation',
				severity: Severity.Info,
				message: 'this Std.string() call can be string interpolation'
			});
		}
		return violations;
	}

	/**
	 * Rewrite each flagged `Std.string(arg)` to its replacement. The scan re-finds the
	 * flagged calls on the (re-parsed) source with the safety gate fully relaxed — the
	 * violations passed in are authoritative about WHICH sites to touch (they already
	 * passed whatever gate `run` applied); the scan only recovers each site's rewrite
	 * mode (peel vs nested) and text.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final matches: Null<Array<ScanMatch>> = scanSource(source, plugin, true, true);
		if (matches == null) return [];
		final byKey: Map<String, ScanMatch> = [for (m in matches) '${m.span.from}:${m.span.to}' => m];
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final m: Null<ScanMatch> = byKey['${span.from}:${span.to}'];
			if (m != null) edits.push({ span: m.span, text: m.replacement });
		}
		return edits;
	}

	/**
	 * The scan matches for `source` — the shared `run` / `fix` preamble — or null when a
	 * required seam kind is unset or the source does not parse. `declaredTypes` is pulled
	 * only when the gate that reads it is active: a relaxed scan bypasses `isSafeArg`
	 * entirely, so it never pays for the map. The FIX-side re-scan passes
	 * `collectNested`: relaxing the gate moves the outermost-only stop (a gate-refused
	 * outer call does not stop `run`'s walk, so `run` may have flagged an inner call the
	 * relaxed re-scan would otherwise hide behind its outer match) — over-collection is
	 * harmless there, `fix` selects by the violations' own non-overlapping spans. A `run`
	 * scan never collects nested matches, oracle-relaxed or not: its matches ARE the
	 * findings, and nested ones would overlap.
	 */
	private static function scanSource(source: String, plugin: GrammarPlugin, relaxed: Bool, collectNested: Bool): Null<Array<ScanMatch>> {
		final resolved: Null<Seams> = resolveSeams(plugin);
		if (resolved == null) return null;
		final seams: Seams = resolved;
		final parsed: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (parsed == null) return null;
		final tree: QueryNode = parsed;
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		final matches: Array<ScanMatch> = [];
		scan(matches, {
			source: source,
			root: tree,
			seams: seams,
			shape: plugin.refShape(),
			declaredTypes: relaxed || provider == null ? [] : provider.declaredTypes(source),
			relaxed: relaxed,
			collectNested: collectNested
		}, tree, null, false, false, false);
		return matches;
	}

	/**
	 * Walk `node`; collect the outermost `Std.string(...)` call with its computed
	 * replacement and STOP — a nested one inside the argument would yield an overlapping
	 * fix, and is caught on the next `--fix` iteration. Under `ctx.collectNested` (the
	 * `fix`-side re-find) the walk continues into a flagged call instead — see `ScanCtx`.
	 *
	 * A call that is a DIRECT operand of a `+` chain `fold-adjacent-string-literals`
	 * CLAIMS (`deferredToFold`) is left alone: that rule owns the whole chain and peels
	 * the `Std.string` wrapper off itself while re-segmenting, so reporting the call
	 * here too would answer one question twice, with two fixes over overlapping spans.
	 *
	 * `chain` is the OUTERMOST `+` chain the walk has entered, null when `node` is not
	 * a direct operand of one — the outermost, because that is the node the fold check
	 * plans as a whole; and it resets to null under any other node, so a call nested
	 * inside a chain operand (a call argument, say) is not treated as an operand.
	 * `inMeta` records whether an ANNOTATION-argument ancestor has been entered;
	 * `inString` whether a string literal has been (both make the fold blind — see
	 * `deferredToFold`). At a string literal the walk enters ONLY the interpolation
	 * blocks (`stringInterpBlockKind`); `sole` marks a direct child of a block that
	 * holds exactly one expression — the peel position (`peelText`).
	 */
	private static function scan(
		out: Array<ScanMatch>, ctx: ScanCtx, node: QueryNode, chain: Null<QueryNode>, inMeta: Bool, inString: Bool, sole: Bool
	): Void {
		final opaque: Null<Array<String>> = ctx.shape.opaqueKinds;
		if (opaque != null && opaque.contains(node.kind)) return;
		if ((ctx.shape.stringLiteralKinds ?? []).contains(node.kind)) {
			scanInterpBlocks(out, ctx, node, inMeta);
			return;
		}
		final seams: Seams = ctx.seams;
		final arg: Null<QueryNode> = matchArg(node, seams.callKind, seams.fieldAccessKind, seams.identKind);
		if (
			arg != null && !deferredToFold(chain, inMeta || inString, ctx.source, seams, ctx.shape)
			&& (ctx.relaxed || isSafeArg(arg, ctx.root, seams.fieldAccessKind, seams.identKind, ctx.shape, ctx.declaredTypes))
			&& flagMatch(out, ctx, node, arg, sole) && !ctx.collectNested
		)
			return;
		final concatKind: Null<String> = seams.concatKind;
		final childChain: Null<QueryNode> = concatKind != null && node.kind == concatKind ? chain ?? node : null;
		final childMeta: Bool = inMeta || seams.metaKinds.contains(node.kind);
		for (c in node.children) scan(out, ctx, c, childChain, childMeta, inString, false);
	}

	/**
	 * Enter a string literal: walk ONLY its `${...}` interpolation blocks
	 * (`stringInterpBlockKind`) — the plain text segments hold no expressions — marking a
	 * block's single expression as the peel position (`sole`). A grammar without the kind
	 * keeps the walk stopping at string literals, as it always did.
	 */
	private static function scanInterpBlocks(out: Array<ScanMatch>, ctx: ScanCtx, literal: QueryNode, inMeta: Bool): Void {
		final blockKind: Null<String> = ctx.shape.stringInterpBlockKind;
		if (blockKind == null) return;
		for (block in literal.children) if (block.kind == blockKind) for (c in block.children)
			scan(out, ctx, c, null, inMeta, true, block.children.length == 1);
	}

	/**
	 * Whether `fold-adjacent-string-literals` claims the chain this node sits directly
	 * in, and so will peel the `Std.string` wrapper off itself while re-segmenting.
	 *
	 * The claim is asked of THAT rule (`FoldStringLiterals.ownsChain`) rather than
	 * guessed from the parent's kind. A chain carrying no string literal
	 * (`Std.string(a) + Std.string(b)`, `Std.string(a) + 1`) is one it never reports,
	 * and a kind-only hand-off deferred there anyway — leaving the call flagged by
	 * nobody. `foldBlind` covers the two positions the fold check never visits at all —
	 * an annotation argument (it skips `metaKinds` wholesale) and the inside of a string
	 * literal (it never descends into one) — where it owns nothing however many literals
	 * the chain carries.
	 *
	 * Null-safe on every side: a grammar with no concatenation concept
	 * (`concatKind == null`) and a node that is not a chain operand (`chain == null`)
	 * both answer false.
	 */
	private static function deferredToFold(chain: Null<QueryNode>, foldBlind: Bool, source: String, seams: Seams, shape: RefShape): Bool {
		final concatKind: Null<String> = seams.concatKind;
		return !foldBlind && chain != null && concatKind != null
			&& FoldStringLiterals.ownsChain(chain, source, concatKind, shape.stringLiteralKinds ?? []);
	}

	/**
	 * If `call` is a single-argument `Std.string(arg)`, its argument node; else null.
	 * Purely structural — the caller separately gates safety (`isSafeArg`, `run`-side
	 * only) and renders the replacement (`render` / `peelText`).
	 */
	private static function matchArg(call: QueryNode, callKind: String, fieldAccessKind: String, identKind: String): Null<QueryNode> {
		if (call.kind != callKind || call.children.length != 2) return null;
		final callee: QueryNode = call.children[0];
		if (callee.kind != fieldAccessKind || callee.name != 'string' || callee.children.length != 1) return null;
		final receiver: QueryNode = callee.children[0];
		return receiver.kind != identKind || receiver.name != 'Std' ? null : call.children[1];
	}

	/**
	 * Whether `arg` is safe to rewrite into an interpolation under
	 * `@:nullSafety(Strict)` — `Std.string` accepts a nullable value; the
	 * interpolation's underlying `+`-concatenation does not, so an argument that
	 * is not provably non-null must be left alone.
	 *
	 * A bare field access (`fieldAccessKind`) never narrows and is always refused,
	 * guard or not. A simple identifier (`identKind`) is safe only when it resolves
	 * (via the scope resolver) to a local / parameter declaration with a KNOWN
	 * nominal type — an unresolved binding or an unannotated/inferred declaration
	 * (absent from `declaredTypes`) keeps the conservative default — that is not an
	 * optional parameter (`?p`), not a default-null parameter (`p: T = null`), and
	 * not one of `RefShape.nullableWrapperTypeNames` (`Null<…>` / `Dynamic` / `Any`).
	 * Any other argument shape (a call, a binary expression, …) is left to the
	 * pre-existing `interpolationSafe`-gated braced rewrite, unaffected by this gate.
	 * The whole gate is bypassed in oracle-relaxed mode (`setOracleRelaxed`).
	 */
	private static function isSafeArg(
		arg: QueryNode, root: QueryNode, fieldAccessKind: String, identKind: String, shape: RefShape, declaredTypes: Map<Int, String>
	): Bool {
		if (arg.kind == fieldAccessKind) return false;
		if (arg.kind != identKind) return true;
		final bindingFrom: Null<Int> = TypeResolver.identBindingFrom(arg, root, shape);
		if (bindingFrom == null) return false;
		final optionalParamKind: Null<String> = shape.optionalParamKind;
		if (optionalParamKind != null && TypeResolver.bindingIsOptionalParam(root, bindingFrom, optionalParamKind)) return false;
		final paramKinds: Null<Array<String>> = shape.paramKinds;
		final nullLiteralKind: Null<String> = shape.nullLiteralKind;
		if (
			paramKinds != null && nullLiteralKind != null
			&& TypeResolver.bindingIsNullInitialised(root, bindingFrom, paramKinds, nullLiteralKind)
		)
			return false;
		final typeName: Null<String> = declaredTypes[bindingFrom];
		if (typeName == null) return false;
		final nullableWrapperTypeNames: Array<String> = shape.nullableWrapperTypeNames ?? [];
		return !nullableWrapperTypeNames.contains(typeName);
	}

	/**
	 * The interpolation text for an already-approved `arg` (`'$x'` for a simple
	 * identifier, `'${expr}'` for an interpolation-safe expression); else null.
	 */
	private static function render(arg: QueryNode, source: String, identKind: String): Null<String> {
		final argName: Null<String> = arg.name;
		if (arg.kind == identKind && argName != null) return '\'$$$argName\'';
		final span: Null<Span> = arg.span;
		if (span == null) return null;
		final src: String = source.substring(span.from, span.to);
		return !interpolationSafe(src) ? null : '\'$${$src}\'';
	}

	/**
	 * The argument's own source text — the replacement when the call IS the sole
	 * expression of a string literal's `${...}` block, which already stringifies its
	 * expression (`'v=${Std.string(x)}'` -> `'v=${x}'`). A pure text motion within the
	 * block: the argument keeps its exact bytes and escape context, so no
	 * `interpolationSafe` gate applies.
	 */
	private static function peelText(arg: QueryNode, source: String): Null<String> {
		final span: Null<Span> = arg.span;
		return span == null ? null : source.substring(span.from, span.to);
	}

	/**
	 * Flag `node` (a gate-approved `Std.string` call): compute its replacement and
	 * record the match. False — and nothing recorded — when the call cannot be soundly
	 * rewritten: a missing span, an unrenderable argument, a comment between the
	 * parentheses; the caller's walk then continues into the argument.
	 */
	private static function flagMatch(out: Array<ScanMatch>, ctx: ScanCtx, node: QueryNode, arg: QueryNode, sole: Bool): Bool {
		final span: Null<Span> = node.span;
		final argSpan: Null<Span> = arg.span;
		final replacement: Null<String> = sole ? peelText(arg, ctx.source) : render(arg, ctx.source, ctx.seams.identKind);
		if (span == null || argSpan == null || replacement == null) return false;
		if (callCarriesComment(span, argSpan, ctx.source)) return false;
		final at: Span = span;
		final text: String = replacement;
		out.push({ span: at, replacement: text });
		return true;
	}

	/**
	 * Whether the call carries a COMMENT between its parentheses outside the argument's
	 * own span — `Std.string(<comment> x)`. Both rewrites replace the WHOLE call span
	 * with text derived from the argument alone, which would silently delete it, so
	 * such a call is left alone (the same refusal `redundant-tostring` makes). Only
	 * whitespace and comments can occupy the probed head / tail regions, so a marker
	 * hit is never a false positive.
	 */
	private static function callCarriesComment(call: Span, arg: Span, source: String): Bool {
		return hasCommentMarker(source.substring(call.from, arg.from)) || hasCommentMarker(source.substring(arg.to, call.to));
	}

	/** Whether `src` contains a line- or block-comment opener. */
	private static function hasCommentMarker(src: String): Bool {
		return src.indexOf('//') != -1 || src.indexOf('/*') != -1;
	}

	/**
	 * Whether `src` can sit inside a single-quoted `'${ … }'` without breaking the
	 * string or changing what it says. A single-quote, double-quote, dollar or newline
	 * would close or re-interpolate the wrapping literal.
	 *
	 * A BACKSLASH is refused for a subtler reason, the same one
	 * `HaxeStringFoldSupport.interpolationBlockSafe` states: the compiler DECODES a
	 * literal's escapes before it reads the interpolation inside it, so an escape in the
	 * moved source is re-read one level up. `Std.string(~/\x24/)` is the regex for a
	 * literal `$`; `'${~/\x24/}'` decodes to `'${~/$/}'`, the end-of-input anchor — a
	 * silent VALUE change (compile-and-run verified). Only a regex literal can carry a
	 * backslash past the quote refusals above, so the cost of refusing all of them is
	 * nil.
	 */
	private static function interpolationSafe(src: String): Bool {
		for (i in 0...src.length) {
			final c: Int = src.fastCodeAt(i);
			if (c == "'".code || c == '"'.code || c == "$".code || c == '\n'.code || c == '\r'.code || c == '\\'.code) return false;
		}
		return true;
	}


	/** Resolve the call / field-access / ident seam kinds, or null when a required kind is unset. */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final callKind: Null<String> = shape.callKind;
		if (callKind == null) return null;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		if (fieldAccessKind == null) return null;
		final identKind: String = shape.identKind;
		final stringFold: Null<StringFoldSupport> = plugin.stringFoldSupport();
		return {
			callKind: callKind,
			fieldAccessKind: fieldAccessKind,
			identKind: identKind,
			concatKind: stringFold?.concatKind(),
			metaKinds: plugin.metaShape().metaKinds
		};
	}

}

/** The resolved seams `PreferInterpolation` reads in both `run` and `fix`. */
private typedef Seams = {
	final callKind: String;
	final fieldAccessKind: String;
	final identKind: String;

	/**
	 * The string-concatenation operator kind, or null when the grammar declares no
	 * `StringFoldSupport` — a `Std.string(x)` sitting directly under one belongs to
	 * `fold-adjacent-string-literals`, not to this rule.
	 */
	final concatKind: Null<String>;

	/**
	 * The ANNOTATION-argument kinds. `fold-adjacent-string-literals` skips them
	 * wholesale, so it claims no chain inside one and this rule must not defer there.
	 */
	final metaKinds: Array<String>;
};

/** The per-file inputs `scan` reads at every node. */
private typedef ScanCtx = {
	final source: String;
	final root: QueryNode;
	final seams: Seams;
	final shape: RefShape;
	final declaredTypes: Map<Int, String>;

	/**
	 * True to bypass the `isSafeArg` null-safety gate: the `run` of an oracle-relaxed
	 * check (`setOracleRelaxed`), and every `fix`-side re-find — there the violations
	 * already passed whatever gate their `run` applied.
	 */
	final relaxed: Bool;

	/**
	 * True to keep collecting INSIDE a matched call instead of stopping at the
	 * outermost — the `fix`-side re-find only (see `scanSource`): its relaxed gate can
	 * move the outermost stop above a call `run` flagged, and the finding's span must
	 * still be recoverable. A `run` scan stays outermost-only in both modes.
	 */
	final collectNested: Bool;
};

/** One flagged call: its span and the replacement text `fix` writes there. */
private typedef ScanMatch = {
	final span: Span;
	final replacement: String;
};
