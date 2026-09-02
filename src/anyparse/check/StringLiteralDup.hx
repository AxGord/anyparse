package anyparse.check;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.Violation;
import anyparse.check.Check.VolatileMessage;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.StringLiteral;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;

/**
 * Flags a plain string literal that appears three or more times (configurable)
 * in ONE file — a repeated literal the project rule says to hoist into a single
 * named constant, so an edit to the value happens in one place. Report-only:
 * like `magic-number`, the constant's NAME is intent a human supplies, not a
 * mechanical rewrite, so `fix` produces no edits.
 *
 * ## What is flagged
 *
 * A literal whose file-local occurrence count reaches `minOccurrences`
 * (default 3) yields ONE finding, anchored at its FIRST occurrence with the
 * total count in the message (the SonarQube-S1192 idiom — one advisory names
 * the whole duplication, not N redundant per-site copies), when ALL hold:
 *
 *  1. it is a PLAIN string literal — one carrying no interpolation. The check
 *     reads literals through `StringFoldSupport.literalOf` (the same seam
 *     `fold-adjacent-string-literals` / `prefer-single-quotes` use), which
 *     yields null for an interpolated string (`'total $n'`) and for a
 *     non-literal node. An interpolated literal is not a constant candidate —
 *     it captures surrounding values — so it never counts toward a group, in
 *     EITHER direction (three `'total $n'` do not group, and an interpolated
 *     occurrence does not inflate a plain literal's count). An escaped `$$`
 *     stays plain (no substitution) and is eligible.
 *  2. its raw inner content is at least `minLength` characters (default 4).
 *     Empty (`""`) and single-character (`"x"`) literals are therefore exempt
 *     BY CONSTRUCTION — a one-letter delimiter or an empty string carries no
 *     naming value and hoisting it into a constant would hurt readability, not
 *     help it. The length is measured on the RAW source between the quotes, so
 *     an escape sequence (`\n`) counts by its source characters, not its
 *     decoded length — a conservative, spelling-stable metric.
 *  3. it is NOT inside a metadata argument (a `MetaShape.metaKinds` ancestor —
 *     Haxe `@:meta('…')`). A string in metadata is usually a contract token (a
 *     `@:native` name, a `@:build` macro path) bound to that annotation, not a
 *     value duplicated across logic; extracting it would break the annotation's
 *     meaning. Such a literal neither counts toward a group nor is reported.
 *  4. it is NOT an entry of a DATA TABLE — a node of the grammar's OWN
 *     `RefShape.arrayLiteralKind`, outside a case PATTERN, holding `MIN_TABLE_ENTRIES` or
 *     more children, every one of them a plain string literal. A grammar kind-name vocabulary (`['ClassDecl',
 *     'FnMember', …]`), a keyword list, a MIME table: those literals are DATA, and the
 *     array IS already the single named place the advisory asks for, so hoisting one of 34
 *     entries into a constant leaves the table unreadable and the value no more centralised
 *     than it was. Such an entry neither counts toward a group nor is reported — the same
 *     treatment metadata gets above.
 *
 * ### What the table carve-out costs
 *
 * Measured over this project's `src/` when it landed: 375 findings to 262, and 89 to 9 in
 * the grammar plugin whose kind vocabularies motivated it. Nothing was ADDED, and the
 * movement splits two ways: 113 groups disappear outright, and 43 more keep their finding
 * with a LOWER count (their table entries stopped counting but enough logic occurrences
 * remain). The blast-radius gate reads that second bucket as no movement, because this same
 * slice masks the repetition count — under the pre-S15 identity the same pair reads 43 added
 * / 156 removed, which is the honest way to describe it. Of the 113 groups it
 * removed, 16 were PURE vocabulary (every occurrence a table entry, so nothing was lost),
 * 44 keep one occurrence outside a table, and 53 keep TWO — one short of the default
 * threshold. That last bucket is the honest price and it has a real shape:
 * `'SingleStringExpr'` in `HaxeStringFoldSupport` occurs three times, once as an entry of
 * the primary-kind array and twice in logic (a `case` pattern and a `!=`), and is no longer
 * reported. A project that wants that bucket back sets
 * `string-literal-dup.minOccurrences: 2`.
 *
 * ## Grouping
 *
 * Literals group by their RAW inner content, so quote STYLE is ignored — a
 * `"foo"` and a `'foo'` are the same string value and count together. Two
 * differently-ESCAPED spellings of the same value (`"a'b"` vs `'a\'b'`) have
 * different raw content and are treated as distinct groups — a sound
 * under-count (never a false group), acceptable for v1.
 *
 * ## Grammar-agnostic
 *
 * The string semantics live behind `GrammarPlugin.stringFoldSupport`; a grammar
 * with no string-literal concept (a binary format) returns null and the check
 * no-ops. Metadata exclusion reads `GrammarPlugin.metaShape().metaKinds`; a
 * grammar with no metadata leaves the set empty and simply excludes nothing.
 *
 * ## Configuration
 *
 * Both thresholds are read per-file from a discovered `apqlint.json`:
 * `string-literal-dup.minOccurrences` and `string-literal-dup.minLength`
 * (integer options). An absent or malformed value falls back to the default.
 *
 * ## Why there is no autofix — declined on evidence, 2026-08-21
 *
 * The hoist needs a NAME, and the name IS the change: `PNG8`, `TRIM_MODE`,
 * `WORKSPACE_FOLDER` are decisions about what a value MEANS, and a mechanical
 * `LITERAL_PNG8` reads worse than the repetition it replaces. That is the same
 * argument `magic-number` makes. Three more came out of driving the report over the
 * 851-file Pony tree (105 groups in 52 files) and READING every site; each is a
 * PRECONDITION a future fixer must clear, not a caveat it may document.
 *
 *  - **3 of the 105 anchors are already a constant declaration.** `VSCode.hx` opens
 *    with `private static inline final PRELAUNCH_TASK: String = 'default';`, and the
 *    other 13 occurrences in that group are unrelated uses of the same word in the
 *    JSON the file emits — so the advisory fires ON the extraction that already
 *    happened, and a fixer would hoist a constant's own initialiser into a second
 *    constant.
 *  - **14 of them sit in a module that declares no type at all.** `docgen/DocInclude.hx`
 *    is module-level fields and functions (`apq symbols` reports nothing there), so
 *    there is no host for a `static final` — and the literals are the KEYS of the
 *    table immediately below where a module-level one would go.
 *  - **17 are map-literal keys, and most of the remainder are wire tokens** — a MIME
 *    table, a VS Code `tasks.json` / `launch.json` emitter, `:asset` / `:puper`
 *    metadata names a build macro reads back. The literal IS the format, and naming
 *    it hides the correspondence with the file or annotation it has to match.
 *
 * The mechanism a caller is likeliest to have heard of — a literal feeding a MACRO
 * cannot be hoisted, because a macro parameter is `Expr` and a macro wanting a
 * literal rejects an identifier (`haxe.macro.Expr should be String … For function
 * argument 'inModule'`) — is real, and did NOT fire here: no Pony group feeds one of
 * the 38 macro functions that tree declares. It is a precondition to gate on when the
 * fixer is written, not the reason the rule stays report-only.
 *
 * One shape that is NOT a blocker, checked on 4.3.7 rather than assumed: a hoisted
 * `static final` is legal in a `case` pattern (10 of the groups have an occurrence in
 * one) — Haxe resolves it as a constant there, and a `static var` in that position is
 * a compile ERROR (`pattern variables must be lower-case or with 'var ' prefix`), not
 * a silent capture. Only a lower-case name would capture.
 */
@:nullSafety(Strict)
final class StringLiteralDup implements Check implements ConfigAware implements VolatileMessage {

	/** Least repetitions of a literal before its occurrences are flagged. */
	private static inline final DEFAULT_MIN_OCCURRENCES: Int = 3;

	/** Least raw-content length a literal must have to be a candidate (excludes empty / single-char by construction). */
	private static inline final DEFAULT_MIN_LENGTH: Int = 4;

	/** Longest literal content echoed verbatim in a finding message before it is elided. */
	private static inline final MESSAGE_PREVIEW: Int = 40;

	/**
	 * Least entries a collection literal must hold, ALL of them plain string literals, before it
	 * is read as a data TABLE rather than as logic. Three rather than two because a
	 * two-element array is as readable inline as it is behind a name, so treating it as a
	 * vocabulary buys nothing and only widens the exemption.
	 *
	 * (An earlier revision defended the threshold as keeping a binary concatenation of two
	 * literals out. That reason is dead: the kind gate in `isTable` excludes `"a" + "b"`
	 * whatever the threshold says, because its node is not the grammar's collection literal.
	 * Stated so nobody lowers the constant on the strength of an argument that no longer
	 * applies.)
	 */
	private static inline final MIN_TABLE_ENTRIES: Int = 3;

	/**
	 * The tail of a finding message, shared by the builder and by `messageIdentity` so the
	 * mask anchor cannot drift from the wording it points at. Read BACKWARDS from, because
	 * the repetition count precedes it — anchoring on ` repeated ` instead would also mask a
	 * digit run inside a literal that happens to spell that word.
	 */
	private static inline final REPEAT_TAIL: String = ' times — extract into a named constant';

	/** This check's stable id — named once so the literal is not itself a repeated string. */
	private static inline final RULE_ID: String = 'string-literal-dup';

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a plain string literal repeated many times in one file that should be a named constant';
	}

	public function messageIdentity(message: String): String {
		return MessageMask.maskBefore(message, REPEAT_TAIL);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final support: Null<StringFoldSupport> = plugin.stringFoldSupport();
		if (support == null) return [];
		// Re-bound: a narrowed local never reaches an anonymous-structure literal whose expected
		// field type is non-nullable.
		final folds: StringFoldSupport = support;
		// Both shape lookups are per-RUN, not per-file, and both build a fresh struct on every
		// call — `refShape()` a 227-field one. Hoisted out of the loop for that reason; only
		// `minLen` below is genuinely per-file, since it comes from the discovered config.
		final metaKinds: Array<String> = plugin.metaShape().metaKinds;
		final shape: RefShape = plugin.refShape();
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final config: LintConfig = LintConfig.resolveWith(_resolveConfig, entry.file);
			final minOcc: Int = positiveOr(config.intOption(RULE_ID, 'minOccurrences'), DEFAULT_MIN_OCCURRENCES);
			final ctx: ScanCtx = {
				support: folds,
				metaKinds: metaKinds,
				arrayLiteralKind: shape.arrayLiteralKind,
				casePatternKind: shape.plainCasePatternKind,
				minLen: positiveOr(config.intOption(RULE_ID, 'minLength'), DEFAULT_MIN_LENGTH)
			};
			scanFile(violations, entry.file, entry.source, tree, ctx, minOcc);
		}
		return violations;
	}

	/** No mechanical autofix — the constant's name is intent a human supplies (like `magic-number`). */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/** A configured value when it is a positive integer, else the built-in default (a zero / negative option is ignored). */
	private static inline function positiveOr(value: Null<Int>, fallback: Int): Int {
		return value != null && value > 0 ? value : fallback;
	}

	/**
	 * Collect every eligible plain literal grouped by its content, then emit one
	 * `Info` for each group whose size reaches `minOcc`, anchored at the group's
	 * FIRST occurrence (the SonarQube-S1192 idiom): the message carries the total
	 * count, so a single advisory names the whole duplication rather than N
	 * redundant per-site copies. Findings are span-sorted so the report is
	 * deterministic regardless of map iteration order.
	 */
	private static function scanFile(
		out: Array<Violation>, file: String, source: String, tree: QueryNode, ctx: ScanCtx, minOcc: Int
	): Void {
		final groups: Map<String, Array<Span>> = [];
		collect(tree, source, ctx, false, false, groups);
		final findings: Array<Finding> = [
			for (content => spans in groups)
				if (spans.length >= minOcc)
					{ at: earliest(spans), message: 'string literal ${preview(content)} repeated ${spans.length}$REPEAT_TAIL' }
		];
		findings.sort((a, b) -> a.at.from - b.at.from);
		for (finding in findings) out.push({
			file: file,
			span: finding.at,
			rule: RULE_ID,
			severity: Severity.Info,
			message: finding.message
		});
	}

	/**
	 * Walk `node`, recording each eligible plain literal's span under its content
	 * key. `inMeta` is sticky: once a `metaKinds` node is entered, every literal in
	 * its subtree is a contract token and is skipped. A literal shorter than
	 * `minLen`, or interpolated / non-literal (`literalOf` null), is not recorded.
	 */
	private static function collect(
		node: QueryNode, source: String, ctx: ScanCtx, inMeta: Bool, inPattern: Bool, groups: Map<String, Array<Span>>
	): Void {
		final here: Bool = inMeta || ctx.metaKinds.contains(node.kind);
		// Sticky, like `inMeta`: once inside a case PATTERN, no descendant collection literal is
		// a data table. The literals themselves stay candidates — `case 'aaaa':` is a real
		// occurrence — only the table gate is switched off.
		final pattern: Bool = inPattern || node.kind == ctx.casePatternKind;
		if (!here) {
			final literal: Null<StringLiteral> = ctx.support.literalOf(node, source);
			final span: Null<Span> = node.span;
			if (literal != null && span != null && literal.content.length >= ctx.minLen) {
				final at: Span = span;
				final bucket: Null<Array<Span>> = groups[literal.content];
				if (bucket == null)
					groups[literal.content] = [at];
				else
					bucket.push(at);
			}
		}
		// A data table's entries are not candidates, and the whole run is skipped rather than
		// walked: every child of a table is a node `literalOf` accepted, and this check's only
		// candidate IS a `literalOf`-positive node, so descending could only find one nested
		// inside another — which the seam's own contract rules out (a PLAIN literal carries no
		// interpolated expression, and an interpolated one is not `literalOf`-positive).
		if (isTable(node, source, ctx, pattern)) return;
		for (child in node.children) collect(child, source, ctx, here, pattern, groups);
	}

	/**
	 * Whether `node` IS a data TABLE: a COLLECTION LITERAL the grammar itself names
	 * (`RefShape.arrayLiteralKind`) holding `MIN_TABLE_ENTRIES` or more children, every single
	 * one a plain string literal.
	 *
	 * Both halves are load-bearing and each was learned the hard way. The kind gate makes the
	 * carve-out POSITIVE — only a construct the grammar declares to be a collection literal can
	 * ever be a table — which is what keeps it from leaking into shapes nobody enumerated. A
	 * first version tested the SHAPE alone ("every child is a plain literal") and leaked into two
	 * whole classes on the first review: `new Foo("a", "b", "c")` carries its type as the node's
	 * NAME rather than as a child, and a conditional-compilation expression
	 * (`#if js "a" #else "b" #end`) is a run of sibling branch values — both all-literal, neither
	 * a table. Measured on this project's `src/`, the tighter gate removes exactly the same 113
	 * findings the shape-only one did, so closing the leak cost nothing.
	 *
	 * The homogeneity half then keeps LOGIC out of the collection kind itself, which in Haxe is
	 * shared with the map literal: a map entry pairs its key with a value under an `Arrow`, so
	 * `['kkkk' => 1, 'llll' => 2, 'mmmm' => 3]` has no bare-literal child and its keys stay
	 * candidates.
	 *
	 * One shape the KIND gate cannot reach, because the grammar spells it with the same kind: an
	 * array destructuring PATTERN (`case ["aaaa", "bbbb"]:`) is a collection literal by kind and
	 * logic by meaning. `collect` therefore carries a sticky `inPattern`, set from the grammar's
	 * `plainCasePatternKind`, and `isTable` refuses beneath it — the literals still COUNT there,
	 * only the table gate is off. A grammar naming no case-pattern kind simply never sets the
	 * flag.
	 *
	 * A grammar that declares no `arrayLiteralKind` gets NO carve-out at all and the rule behaves
	 * exactly as it did before — a missing seam disables the exemption, never the rule.
	 */
	private static function isTable(node: QueryNode, source: String, ctx: ScanCtx, inPattern: Bool): Bool {
		final kids: Array<QueryNode> = node.children;
		return !inPattern && node.kind == ctx.arrayLiteralKind && kids.length >= MIN_TABLE_ENTRIES
			&& kids.foreach(kid -> ctx.support.literalOf(kid, source) != null);
	}

	/** `content` quoted for a message, elided to `MESSAGE_PREVIEW` characters so a long literal does not bloat the report. */
	private static function preview(content: String): String {
		final shown: String = content.length > MESSAGE_PREVIEW ? '${content.substr(0, MESSAGE_PREVIEW)}…' : content;
		return '\'$shown\'';
	}

	/** The document-earliest span of a group — the first occurrence the single finding anchors to. */
	private static function earliest(spans: Array<Span>): Span {
		var first: Span = spans[0];
		for (span in spans) if (span.from < first.from) first = span;
		return first;
	}

}

/** A pending finding: the anchor span of a repeated literal and its rendered message. */
private typedef Finding = {
	final at: Span;
	final message: String;
};

/** The per-file scan ingredients, resolved once per file rather than threaded one by one. */
private typedef ScanCtx = {
	final support: StringFoldSupport;
	final metaKinds: Array<String>;
	final arrayLiteralKind: Null<String>;
	final casePatternKind: Null<String>;
	final minLen: Int;
};
