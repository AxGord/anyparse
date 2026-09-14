package anyparse.check;

import anyparse.check.Check.NoAutofix;
import anyparse.check.Check.Violation;
import anyparse.check.Check.VolatileMessage;
import anyparse.check.SpanRender.SpanOverride;
import anyparse.query.BinderScan;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberKinds;
import anyparse.query.QueryNode;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

using Lambda;

/**
 * Flags a run of three or more consecutive statements that appears, byte-for-byte
 * identical up to LAYOUT (a literal's own interior compares exactly), in two or
 * more places — a copy-paste clone the user's rule says to always extract into a
 * helper ("duplication is a bug, not a design choice"). Two passes over the same
 * normalized statement stream: a SAME-FILE pass (`scanBlocks`) and a project-wide
 * CROSS-FILE pass (`scanCrossFile`); a same-file pair is reported by the first pass
 * only, never by both. Purely structural (no type information needed). `Info`,
 * REPORT-ONLY — extraction is a refactoring (`hxq extract-method`), and across a
 * file boundary whether to introduce a shared helper is a design decision the tool
 * must not force, so `fix` produces no edits.
 *
 * ## What is a clone
 *
 * - **Same-file and cross-file.** The same-file pass hashes each file's own block
 *   three-grams; the cross-file pass concatenates every scoped file's blocks into ONE
 *   global three-gram index built in a single pass (no O(N²) file-pair comparison) and
 *   reports a clone only when its two occurrences sit in DIFFERENT files, pointing the
 *   later at the PATH-earliest occurrence — path-earliest and not scan-earliest,
 *   because the scan order is the order the caller listed the scope, and picking by
 *   it would make `lint src test` and `lint test src` name opposite ends of the same
 *   clone. Same-file pairs are skipped by the cross-file pass, so the two passes
 *   partition the clone space with no double-report.
 * - **Token-exact normalization.** Two statements are equal when their source
 *   text matches after every run of spaces / tabs / newlines BETWEEN tokens is
 *   collapsed to a single space (and the ends trimmed), while whitespace INSIDE a
 *   token — a string or regex literal's own content — is compared byte for byte
 *   (`SpanRender`). Layout is not code; a literal's interior is. There is NO
 *   identifier normalization (alpha-renaming): only exact-logic clones match, so the
 *   check has zero false positives by construction — a claim the interior half is
 *   what makes true: two `--help` blocks whose option column is padded to a different
 *   width are not a clone, since no shared helper could produce both. A comment
 *   inside a statement's span makes it textually different — not a clone; a comment
 *   BETWEEN statements is trivia outside every statement span and does not affect
 *   equality.
 * - **Consecutive statements, one block.** A run is a maximal sequence of direct-child
 *   statements of a `ControlFlowSupport.blockKinds()` node (function body / nested
 *   block); the two occurrences may sit in different blocks and different block
 *   kinds (a method body vs an `if` body). A five-statement clone is reported ONCE
 *   as its maximal run, not as three overlapping three-statement windows.
 * - **Non-overlapping occurrences.** Within one clone family the earliest occurrence
 *   is the original; each later occurrence that does not overlap it is a finding
 *   (`a; a; a; a` with window `a; a; a` yields no report — the only second window
 *   overlaps the first). Occurrence selection is earliest-first greedy, so a later
 *   disjoint clone pair whose bucket was already consumed by containment dedup
 *   can go unreported — a sound under-report, never a false clone.
 * - **Content gate.** A run must hold at least `MIN_STATEMENTS` statements AND at
 *   least `MIN_NON_WS_CHARS` non-whitespace characters, so a triple of trivial
 *   one-liners (`i++; j++; k++;`) is not flagged. The count is taken on the text the
 *   comparison keys on (`gateNonWs`), so under the renamed reading a binder weighs what its
 *   placeholder does and both copies of a clone measure the same.
 * - Runs entirely inside an `opaqueKinds` (macro reification) subtree are skipped —
 *   their identifiers may be spliced from elsewhere.
 * - **Bare runs are not clones.** A run whose every statement is a local declaration or a plain
 *   assignment to a name (dotted or not), with no value, a name or a literal on the right, is not
 *   reported under either reading: a row of slot fills has nothing to extract. A statement the seams
 *   (`bareKinds`) cannot place is not bare, so an unclassifiable run stays a finding.
 *
 * ## Grammar-agnostic
 *
 * Blocks and their statement sequences come from `GrammarPlugin.controlFlowSupport`
 * (`blockKinds`), the same seam `dead-code` uses; a grammar with no statement / block
 * concept (a binary format) returns null and the check is a no-op.
 *
 * ## Reporting
 *
 * The finding is spanned from the first to the last statement of the duplicated
 * run at the LATER occurrence (the duplicated region itself); a same-file message
 * points at the first occurrence's line, a cross-file message names the other file
 * and line (`file A line X ↔ this file line Y`). One violation per duplicate
 * occurrence, not one per statement — so three occurrences of a clone produce two
 * findings.
 */
@:nullSafety(Strict)
final class DuplicateCode implements Check implements NoAutofix implements VolatileMessage {

	/** The shortest run of consecutive statements considered a clone. */
	private static inline final MIN_STATEMENTS: Int = 3;

	/**
	 * The least non-whitespace characters a run must total to be reported — filters
	 * triples of trivial one-liners whose duplication carries no extraction value.
	 */
	private static inline final MIN_NON_WS_CHARS: Int = 40;

	/** Separator between statement norms in a three-gram key — a byte no source text contains. */
	private static inline final GRAM_SEP: String = '\x1e';

	private static inline final RULE_ID: String = 'duplicate-code';

	/**
	 * The prefix both wordings share, spelled once so the two message builders cannot drift.
	 *
	 * The statement COUNT in front of it is deliberately NOT masked, unlike the other tallies
	 * `lint-diff` masks. The reason is local to this rule: `lint-diff` keys on
	 * `(file, rule, severity, message)` with no span; whichever wording a finding uses, its
	 * one coordinate is already masked (the partner's line in the cross-file form, the
	 * original's line in the same-file form), and the cross-file partner PATH is shared by
	 * every clone against that file while the same-file form names no path at all. So the
	 * count is the LAST thing distinguishing two different clones of one file, and blanking
	 * it makes a substitution invisible. The count is also stable: it moves only when the
	 * code moves.
	 */
	private static inline final STATEMENT_COUNT_UNIT: String = ' statements duplicated from ';

	/**
	 * The fragment that precedes the ORIGINAL's line in a same-file message, and the one that
	 * follows it in a cross-file message. Shared by the message builders and by
	 * `messageIdentity`, so an anchor cannot drift away from the wording it points at.
	 */
	private static inline final SAME_FILE_ORIGIN: String = '${STATEMENT_COUNT_UNIT}line ';

	/**
	 * Anchors the OTHER direction: the cross-file message writes its coordinate before this
	 * tail, so the mask reads backwards from it while the same-file one reads forwards.
	 */
	private static inline final CROSS_FILE_TAIL: String = ' — extract a shared helper (report-only, cross-file)';

	/** The same-file wording's tail, after the original's line. */
	private static inline final SAME_FILE_HELPER_TAIL: String = ' — extract a helper (hxq extract-method)';

	/**
	 * Wraps a normalized binder name inside a statement's comparison text — a byte no source text
	 * contains, so a text carrying none is its own type-1 key.
	 */
	private static inline final HOLE: String = '\x1f';

	/** This rule's reading: no binder normalization, so only exact-logic clones bucket together. */
	private static final EXACT: DupMode = {
		ruleId: RULE_ID,
		normalizeBinders: false,
		sameFileTail: SAME_FILE_HELPER_TAIL,
		crossFileTail: CROSS_FILE_TAIL
	};

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'three or more consecutive statements duplicated (layout-insensitive, literal-exact) within the same file or across files';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return scan(files, plugin, EXACT);
	}

	/** Extraction is a refactoring (`hxq extract-method`), not a mechanical span edit — report-only. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/**
	 * Two identical runs of statements may be one idea or a coincidence, and only a reader can
	 * tell. Extracting the common lines mechanically is how a wrong abstraction gets born.
	 */
	public function noAutofixReason(): String {
		return 'whether the copies are one idea or a coincidence — and where the shared factor belongs — is a design judgement';
	}

	/**
	 * The ORIGINAL's line is masked; the statement COUNT and the partner FILENAME are not.
	 *
	 * Both message shapes name a position in the file the clone was copied FROM, so any edit
	 * above that position renames every finding pointing at it — a shift in one file re-keys
	 * clones reported in others. The count and the partner path move only when the code moves.
	 *
	 * The masks are anchored rather than blanket: masking every digit run in this rule's
	 * messages also eats the count and any digit in the partner filename, most findings then
	 * share a key with a sibling, and a substitution inside such a group is invisible to the
	 * gate.
	 */
	public function messageIdentity(message: String): String {
		return maskCoordinate(message, EXACT);
	}

	/** `renumber` for a statement carrying markers, the statement's own render for one that carries none. */
	private static inline function renumbered(stmt: DupStmt, names: Array<String>): String {
		return stmt.renamed ? renumber(stmt.text, names) : stmt.text;
	}

	/** A value that fills a slot without computing anything: a name or a literal. */
	private static inline function isSlotValue(k: DupBareKinds, node: QueryNode): Bool {
		return isName(k, node) || isLiteral(k, node);
	}

	/**
	 * Both readings of one clone engine over a file set: collect each file's blocks once, then run
	 * the same-file and the cross-file pass over that single collection. `mode` decides the rule id
	 * the findings carry, their message tails, and whether a LOCAL binding's name is normalized away
	 * before two statements are compared — with normalization off the key is the raw render, so the
	 * type-2 reading degenerates to the type-1 one.
	 */
	private static function scan(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin, mode: DupMode): Array<Violation> {
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return [];
		final shape: RefShape = plugin.refShape();
		final binders: Null<DupBinders> = mode.normalizeBinders ? {
			shape: shape,
			scopeKinds: BinderScan.bindingScopeKinds(shape),
			binderKinds: BinderScan.binderKinds(shape),
			identKind: shape.identKind
		} : null;
		final blockKinds: Array<String> = support.blockKinds();
		final opaqueKinds: Array<String> = shape.opaqueKinds ?? [];
		final bare: DupBareKinds = bareKinds(shape);
		final violations: Array<Violation> = [];
		final perFile: Array<DupFile> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final blocks: Array<Array<DupStmt>> = [];
			final ctx: DupCtx = {
				source: entry.source,
				blockKinds: blockKinds,
				opaqueKinds: opaqueKinds,
				binders: binders,
				bare: bare
			};
			collectBlocks(tree, ctx, null, blocks);
			perFile.push({ file: entry.file, source: entry.source, blocks: blocks });
		}
		for (pf in perFile) scanBlocks(violations, pf.file, pf.source, pf.blocks, mode);
		scanCrossFile(violations, perFile, mode);
		return violations;
	}

	/**
	 * Both wordings' masked form, shared so a rule reading this engine cannot anchor its mask on a
	 * fragment it does not write: the same-file coordinate is the text after the shared origin
	 * fragment, the cross-file one the text before that mode's own tail.
	 */
	private static function maskCoordinate(message: String, mode: DupMode): String {
		return MessageMask.maskBefore(MessageMask.maskAfter(message, SAME_FILE_ORIGIN), mode.crossFileTail);
	}

	/**
	 * The same-file pass: hash this file's own block statement three-grams to find clone
	 * starts, extend each to its maximal run, drop overlapping and sub-window runs, and emit
	 * one `Info` per surviving later occurrence WITHIN the file. `blocks` was collected once by
	 * `run` (`collectBlocks`) and is shared with the cross-file pass, so the tree is walked once.
	 */
	private static function scanBlocks(
		out: Array<Violation>, file: String, source: String, blocks: Array<Array<DupStmt>>, mode: DupMode
	): Void {
		final grams: Map<String, Array<DupPos>> = buildGrams(blocks);
		final findings: Array<DupFinding> = [];
		for (bucket in grams) if (bucket.length >= 2) collectFindings(blocks, source, bucket, findings);

		final kept: Array<DupFinding> = dropOverlapping(findings);
		kept.sort((a, b) -> a.span.from - b.span.from);
		for (f in kept) out.push({
			file: file,
			span: f.span,
			rule: mode.ruleId,
			severity: Severity.Info,
			message: '${f.count}$SAME_FILE_ORIGIN${f.origLine}${mode.sameFileTail}'
		});
	}

	/**
	 * Append each block (a `blockKinds` node's direct-child statement sequence) with
	 * at least `MIN_STATEMENTS` statements to `out`, skipping `opaqueKinds` subtrees.
	 */
	private static function collectBlocks(node: QueryNode, ctx: DupCtx, names: Null<Array<String>>, out: Array<Array<DupStmt>>): Void {
		if (ctx.opaqueKinds.contains(node.kind)) return;
		final binders: Null<DupBinders> = ctx.binders;
		// The names in scope come from the OUTERMOST binding scope containing the block: a nested
		// function's own bindings already lie inside that subtree, so the first one answers for all.
		final scoped: Null<Array<String>> = names == null && binders != null && binders.scopeKinds.contains(node.kind)
			? BinderScan.boundNames(node, binders.shape)
			: names;
		if (ctx.blockKinds.contains(node.kind)) {
			final stmts: Array<DupStmt> = [];
			for (child in node.children) {
				final span: Null<Span> = child.span;
				if (span != null) stmts.push(normalizeStmt(ctx, child, span, scoped));
			}
			if (stmts.length >= MIN_STATEMENTS) out.push(stmts);
		}
		for (child in node.children) collectBlocks(child, ctx, scoped, out);
	}

	/**
	 * The comparison view of the statement at `span`: `SpanRender.renderSpan` — whitespace
	 * BETWEEN tokens collapsed to a single space, whitespace INSIDE a token copied byte for
	 * byte, the ends trimmed.
	 *
	 * The render and not the norm, because the norm is the key this rule REPORTS on with no
	 * further test. `tail-merge` and `redundant-case-body` pair it with
	 * `MemberKinds.structurallyEqual` and `prefer-case-guard` refuses content carrying a
	 * backslash or a quote; this one bucketed three-gram norms outright, so `f("a  b")` and
	 * `f("a b")` compared equal and two runs that are not the same code were reported as a
	 * clone. A leaf has no structure inside it, so whitespace in its span is content by
	 * construction — which is what makes the render an exact-token key without a second tree
	 * to compare against, and what lets the type doc's "zero false positives" claim stand.
	 */
	private static function normalizeStmt(ctx: DupCtx, node: QueryNode, span: Span, names: Null<Array<String>>): DupStmt {
		final holes: Array<SpanOverride> = holeOverrides(ctx, node, names);
		return {
			text: SpanRender.renderSpan(ctx.source, span.from, span.to, node, holes),
			renamed: holes.length > 0,
			bare: isBareStmt(ctx.bare, node),
			span: span
		};
	}

	/**
	 * Where `node`'s subtree spells a name from `names`, and the marker text that stands in for it:
	 * an identifier leaf whole, and a binder node's own name token where the grammar writes it
	 * between the node's start and its first child. A binding the grammar spells some other way is
	 * left alone, which can only cost a clone and never invent one.
	 */
	private static function holeOverrides(ctx: DupCtx, node: QueryNode, names: Null<Array<String>>): Array<SpanOverride> {
		final out: Array<SpanOverride> = [];
		final binders: Null<DupBinders> = ctx.binders;
		if (binders == null) return out;
		if (names == null || names.length == 0) return out;
		collectHoles(ctx.source, node, names, binders, out);
		return out;
	}

	/**
	 * Recursive worker of `holeOverrides`. The vocabularies travel as arguments rather than as a
	 * closure's captures: a captured nullable local loses its narrowing, and the checks belong to the
	 * caller anyway.
	 */
	private static function collectHoles(
		source: String, node: QueryNode, names: Array<String>, binders: DupBinders, out: Array<SpanOverride>
	): Void {
		final name: Null<String> = node.name;
		final span: Null<Span> = node.span;
		if (name != null && span != null && names.contains(name)) {
			final nodeSpan: Span = span;
			if (node.kind == binders.identKind && node.children.length == 0)
				out.push({ span: nodeSpan, text: '$HOLE$name$HOLE' });
			else if (binders.binderKinds.contains(node.kind)) {
				final at: Int = binderNameOffset(source, node, nodeSpan, name);
				if (at >= 0) out.push({ span: new Span(at, at + name.length), text: '$HOLE$name$HOLE' });
			}
		}
		for (child in node.children) collectHoles(source, child, names, binders, out);
	}

	/**
	 * Where a binder node writes its OWN name, or -1. Only the stretch from the node's start to its
	 * first child can hold it — every later byte belongs to a child — so the search cannot reach into
	 * a default value or a body.
	 */
	private static function binderNameOffset(source: String, node: QueryNode, span: Span, name: String): Int {
		var to: Int = span.to;
		for (child in node.children) {
			final childSpan: Null<Span> = child.span;
			if (childSpan == null) continue;
			to = childSpan.from;
			break;
		}
		return SourceText.identTokenOffset(source, new Span(span.from, to), name);
	}

	/**
	 * `text` with each marked binder name replaced by its position in `names`, and every name new to
	 * the run appended there. Two runs are clones under renaming exactly when their renumbered texts
	 * match, so the mapping is bijective with no second table to check.
	 */
	private static function renumber(text: String, names: Array<String>): String {
		final parts: Array<String> = text.split(HOLE);
		final buf: StringBuf = new StringBuf();
		for (i in 0...parts.length) if (i % 2 == 0)
			buf.add(parts[i]);
		else {
			final name: String = parts[i];
			var index: Int = names.indexOf(name);
			if (index < 0) {
				index = names.length;
				names.push(name);
			}
			buf.add('$$$index');
		}
		return buf.toString();
	}

	/**
	 * From a bucket of three-gram starts (≥2), take the document-earliest as the
	 * original and, for every later start, extend the shared run to its maximal
	 * length, skip it when it overlaps the original within one block or falls under
	 * the content gate, and record a finding at the later occurrence.
	 */
	private static function collectFindings(
		blocks: Array<Array<DupStmt>>, source: String, bucket: Array<DupPos>, findings: Array<DupFinding>
	): Void {
		bucket.sort((a, b) -> blocks[a.b][a.i].span.from - blocks[b.b][b.i].span.from);
		final anchor: DupPos = bucket[0];
		for (k in 1...bucket.length) {
			final later: DupPos = bucket[k];
			final len: Int = commonRun(blocks, anchor, later);
			if (!reportableRun(blocks, anchor, len)) continue;
			if (anchor.b == later.b && later.i - anchor.i < len) continue;
			final laterStmts: Array<DupStmt> = blocks[later.b];
			findings.push({
				span: new Span(laterStmts[later.i].span.from, laterStmts[later.i + len - 1].span.to),
				count: len,
				origLine: blocks[anchor.b][anchor.i].span.lineCol(source).line,
				b: later.b,
				startIdx: later.i,
				origFile: '',
				laterFile: -1
			});
		}
	}

	/**
	 * Length of the maximal run of equal statements from `a` and `b` in parallel, each side's binder
	 * names renumbered from its own run START — so the renaming a run establishes has to hold for
	 * every statement of it, and a crossed pair of names ends the run instead of extending it. A
	 * statement carrying no marker compares as its own text.
	 */
	private static function commonRun(blocks: Array<Array<DupStmt>>, a: DupPos, b: DupPos): Int {
		final sa: Array<DupStmt> = blocks[a.b];
		final sb: Array<DupStmt> = blocks[b.b];
		final namesA: Array<String> = [];
		final namesB: Array<String> = [];
		var len: Int = 0;
		while (a.i + len < sa.length && b.i + len < sb.length && renumbered(sa[a.i + len], namesA) == renumbered(sb[b.i + len], namesB))
			len++;
		return len;
	}

	/**
	 * Non-whitespace characters across `len` statements of `stmts` from `start`, counted on the text
	 * the comparison keys on (`gateNonWs`), so both copies of a clone measure the same and renaming a
	 * binder in either cannot flip the gate.
	 */
	private static function runNonWs(stmts: Array<DupStmt>, start: Int, len: Int): Int {
		final names: Array<String> = [];
		var total: Int = 0;
		for (i in start ... start + len) total += gateNonWs(stmts[i], names);
		return total;
	}

	/**
	 * What the content gate measures of one statement: its non-whitespace characters as `commonRun`
	 * compares it, a renamed-away binder weighing what its placeholder does rather than what the copy
	 * happened to call it.
	 */
	private static function gateNonWs(stmt: DupStmt, names: Array<String>): Int {
		final text: String = renumbered(stmt, names);
		return CheckScan.normalizeSpan(text, 0, text.length).nonWs;
	}

	/**
	 * Keep the document-earliest finding of each overlapping group WITHIN a block: a later
	 * finding whose statement-index range intersects one already kept in the same block is
	 * dropped. So a maximal clone's shorter sub-windows fall away (it reports once) AND a
	 * diverging-tail shape — one later block sharing a longer run while another shares only a
	 * shorter prefix — reports once per later block, not as partially-overlapping windows.
	 * Findings in different blocks never share a byte-span, so they never interfere.
	 */
	private static function dropOverlapping(findings: Array<DupFinding>): Array<DupFinding> {
		final sorted: Array<DupFinding> = findings.copy();
		sorted.sort((a, b) -> a.span.from - b.span.from);
		final kept: Array<DupFinding> = [];
		for (f in sorted) if (!overlapsKept(kept, f)) kept.push(f);
		return kept;
	}

	/** Whether `f`'s statement-index range intersects an already-kept finding within the same block. */
	private static function overlapsKept(kept: Array<DupFinding>, f: DupFinding): Bool {
		final fEnd: Int = f.startIdx + f.count - 1;
		for (k in kept) if (k.b == f.b) {
			final kEnd: Int = k.startIdx + k.count - 1;
			if (f.startIdx <= kEnd && k.startIdx <= fEnd) return true;
		}
		return false;
	}

	/**
	 * The cross-file pass (report-only). Concatenate every scoped file's blocks into ONE global
	 * index and hash three-grams project-wide in a single pass — there is no O(N²) file-pair
	 * comparison; two occurrences meet only by landing in the same three-gram bucket. For each
	 * three-gram shared across TWO DIFFERENT files, extend the shared run to its maximal length,
	 * apply the same content gate, and emit one `Info` per later-file occurrence pointing at the
	 * globally-earliest occurrence (file A line X ↔ this file line Y). Same-file pairs are skipped
	 * here — `scanBlocks` owns those — so no clone is reported by both passes.
	 *
	 * Cross-file extraction crosses a module / package boundary; whether to introduce a shared
	 * helper there is a design decision the tool must not force, so this pass is REPORT-ONLY
	 * (`fix` emits nothing) — the finding names both sites and leaves the call.
	 */
	private static function scanCrossFile(out: Array<Violation>, perFile: Array<DupFile>, mode: DupMode): Void {
		final blocks: Array<Array<DupStmt>> = [];
		final blockFile: Array<Int> = [];
		for (fi in 0...perFile.length) for (blk in perFile[fi].blocks) {
			blocks.push(blk);
			blockFile.push(fi);
		}

		final grams: Map<String, Array<DupPos>> = buildGrams(blocks);
		final findings: Array<DupFinding> = [];
		for (bucket in grams) if (bucket.length >= 2) collectCrossFindings(blocks, blockFile, perFile, bucket, findings);

		final kept: Array<DupFinding> = dropOverlapping(findings);
		kept.sort((a, b) -> a.laterFile != b.laterFile ? a.laterFile - b.laterFile : a.span.from - b.span.from);
		for (f in kept) out.push({
			file: perFile[f.laterFile].file,
			span: f.span,
			rule: mode.ruleId,
			severity: Severity.Info,
			message: '${f.count}$STATEMENT_COUNT_UNIT${f.origFile}:${f.origLine}${mode.crossFileTail}'
		});
	}

	/**
	 * From a global three-gram bucket (≥2 starts), take the globally-earliest position (by file
	 * order, then span) as the anchor and, for every later start in a DIFFERENT file, extend the
	 * shared run to its maximal length, skip it under the content gate, and record a cross-file
	 * finding at the later occurrence pointing at the anchor's file and line. Same-file starts are
	 * skipped — the same-file pass reports those — so a pure within-file repeat yields nothing here.
	 */
	private static function collectCrossFindings(
		blocks: Array<Array<DupStmt>>, blockFile: Array<Int>, perFile: Array<DupFile>, bucket: Array<DupPos>, findings: Array<DupFinding>
	): Void {
		// Ordered by file PATH, never by the index the file happened to get from the scan: the
		// index is the order the CLI handed the scope over, so `lint src test` and `lint test src`
		// would pick opposite ends of every cross-tree clone as the "original", and each such
		// flip is an added + a removed line in the blast-radius gate. The path is a property of
		// the file SET, so the pair agrees. `fa - fb` breaks a tie only when one path is listed
		// twice, which keeps the comparator total.
		bucket.sort((a, b) -> {
			final fa: Int = blockFile[a.b];
			final fb: Int = blockFile[b.b];
			if (fa == fb) return blocks[a.b][a.i].span.from - blocks[b.b][b.i].span.from;
			final pa: String = perFile[fa].file;
			final pb: String = perFile[fb].file;
			return if (pa < pb)
				-1
			else if (pa > pb)
				1
			else
				fa - fb;
		});
		final anchor: DupPos = bucket[0];
		final anchorFile: Int = blockFile[anchor.b];
		for (k in 1...bucket.length) {
			final later: DupPos = bucket[k];
			final laterFile: Int = blockFile[later.b];
			if (laterFile == anchorFile) continue;
			final len: Int = commonRun(blocks, anchor, later);
			if (!reportableRun(blocks, anchor, len)) continue;
			final laterStmts: Array<DupStmt> = blocks[later.b];
			findings.push({
				span: new Span(laterStmts[later.i].span.from, laterStmts[later.i + len - 1].span.to),
				count: len,
				origLine: blocks[anchor.b][anchor.i].span.lineCol(perFile[anchorFile].source).line,
				b: later.b,
				startIdx: later.i,
				origFile: perFile[anchorFile].file,
				laterFile: laterFile
			});
		}
	}

	/**
	 * Hash every three-gram of consecutive RENDERED statements across `blocks` into
	 * start-position buckets — the shared index both the same-file pass (one file's blocks)
	 * and the cross-file pass (every scoped file's blocks concatenated) probe for clones.
	 */
	private static function buildGrams(blocks: Array<Array<DupStmt>>): Map<String, Array<DupPos>> {
		final grams: Map<String, Array<DupPos>> = [];
		final names: Array<String> = [];
		for (b => stmts in blocks) {
			for (i in 0...stmts.length - (MIN_STATEMENTS - 1)) {
				// Numbering restarts at every window, so a name's index is a property of the window
				// and not of where the block happens to declare it.
				names.resize(0);
				final key: String = renumbered(stmts[i], names) + GRAM_SEP + renumbered(stmts[i + 1], names) + GRAM_SEP
					+ renumbered(stmts[i + 2], names);
				final bucket: Null<Array<DupPos>> = grams[key];
				if (bucket == null)
					grams[key] = [{ b: b, i: i }];
				else
					bucket.push({ b: b, i: i });
			}
		}
		return grams;
	}

	/**
	 * Whether a shared run of `len` statements from `anchor` is a clone worth reporting: long
	 * enough, over the content gate, and not bare.
	 */
	private static function reportableRun(blocks: Array<Array<DupStmt>>, anchor: DupPos, len: Int): Bool {
		if (len < MIN_STATEMENTS) return false;
		final stmts: Array<DupStmt> = blocks[anchor.b];
		return runNonWs(stmts, anchor.i, len) >= MIN_NON_WS_CHARS && !bareRun(stmts, anchor.i, len);
	}

	/**
	 * Whether every statement of the `len` from `start` is bare — a row of slot fills, which has
	 * nothing to extract and is not a finding under either reading.
	 */
	private static function bareRun(stmts: Array<DupStmt>, start: Int, len: Int): Bool {
		for (i in start ... start + len) if (!stmts[i].bare) return false;
		return true;
	}

	/**
	 * The seams the bare-run filter reads, unioned once per scan: every local declaration spelling
	 * (statement, static and continuation), the constant literal kinds with the inert text literals
	 * (a regex among them), and the collection literal kinds an empty spelling can carry.
	 */
	private static function bareKinds(shape: RefShape): DupBareKinds {
		final declKinds: Array<String> = [];
		final literalKinds: Array<String> = MemberKinds.constantLiteralKinds(shape);
		final emptyCollectionKinds: Array<String> = [];
		inline function addOne(out: Array<String>, kind: Null<String>): Void if (kind != null && !out.contains(kind)) out.push(kind);
		inline function add(out: Array<String>, kinds: Null<Array<String>>): Void if (kinds != null) for (kind in kinds) addOne(out, kind);
		add(declKinds, shape.localDeclKinds);
		add(declKinds, shape.staticLocalDeclKinds);
		add(declKinds, shape.localDeclContinuationKinds);
		add(literalKinds, shape.inertTextLiteralKinds);
		addOne(emptyCollectionKinds, shape.arrayLiteralKind);
		addOne(emptyCollectionKinds, shape.objectLiteralKind);
		return {
			shape: shape,
			declKinds: declKinds,
			continuationKinds: shape.localDeclContinuationKinds ?? [],
			typeChildKinds: shape.declTypeChildKinds ?? [],
			literalKinds: literalKinds,
			emptyCollectionKinds: emptyCollectionKinds
		};
	}

	/**
	 * Whether `stmt` is BARE: a local declaration, or a plain assignment to a name, whose value is
	 * absent, a name or a literal — a slot fill. A statement the seams cannot place is not bare, so
	 * an unclassifiable run stays a finding.
	 */
	private static function isBareStmt(k: DupBareKinds, stmt: QueryNode): Bool {
		if (k.declKinds.contains(stmt.kind)) return isBareDecl(k, stmt);
		if (stmt.kind != k.shape.exprStatementKind || stmt.children.length != 1) return false;
		final assign: QueryNode = stmt.children[0];
		return assign.kind == k.shape.assignKind && assign.children.length == 2 && isName(k, assign.children[0])
			&& isSlotValue(k, assign.children[1]);
	}

	/**
	 * A declaration is bare when its own value, if any, is a slot value and every continuation
	 * declaration it carries is bare in turn; a type annotation child is not a value.
	 */
	private static function isBareDecl(k: DupBareKinds, decl: QueryNode): Bool {
		var values: Int = 0;
		for (child in decl.children) if (!k.typeChildKinds.contains(child.kind)) {
			if (k.continuationKinds.contains(child.kind)) {
				if (!isBareDecl(k, child)) return false;
			} else {
				values++;
				if (values > 1 || !isSlotValue(k, child)) return false;
			}
		}
		return true;
	}

	/** An identifier leaf, or a field access whose only child is a name — a dotted path is one name. */
	private static function isName(k: DupBareKinds, node: QueryNode): Bool {
		return node.kind == k.shape.identKind
			? node.children.length == 0
			: node.kind == k.shape.fieldAccessKind && node.children.length == 1 && isName(k, node.children[0]);
	}

	/**
	 * A literal kind whose segments, if any, are all inert text (an interpolation hole is a read), a
	 * negated numeric literal, or an empty collection literal.
	 */
	private static function isLiteral(k: DupBareKinds, node: QueryNode): Bool {
		final shape: RefShape = k.shape;
		if (k.literalKinds.contains(node.kind))
			return node.children.foreach(segment -> MemberKinds.isInertStringSegmentKind(segment.kind, shape));
		if (k.emptyCollectionKinds.contains(node.kind)) return node.children.length == 0;
		final numeric: Null<Array<String>> = shape.numericLiteralKinds;
		return node.kind == shape.negationKind && node.children.length == 1 && numeric != null && numeric.contains(node.children[0].kind);
	}

}

/**
 * A block statement: its RENDERED comparison text (`SpanRender`), whether
 * that text carries a hole, whether it is bare, and its source span.
 */
typedef DupStmt = {
	var text: String;
	var renamed: Bool;
	var bare: Bool;
	var span: Span;
}

/** A (block-index, statement-index) coordinate into the per-file collected block list. */
typedef DupPos = {
	var b: Int;
	var i: Int;
}

/**
 * A recorded clone occurrence: its span, statement count, and the original's line. For a
 * cross-file finding `origFile` names the anchor's file and `laterFile` the later occurrence's
 * `perFile` index; a same-file finding leaves `origFile` empty and `laterFile` `-1`.
 */
typedef DupFinding = {
	var span: Span;
	var count: Int;
	var origLine: Int;
	var b: Int;
	var startIdx: Int;
	var origFile: String;
	var laterFile: Int;
}

/**
 * One scoped file: its path, source, and the block statement sequences `run` collected once
 * (`collectBlocks`) for BOTH the same-file and the cross-file pass, so the tree is walked once.
 */
typedef DupFile = {
	var file: String;
	var source: String;
	var blocks: Array<Array<DupStmt>>;
}

/**
 * What separates the two readings of one clone engine: the rule id its findings carry, whether a
 * LOCAL binding's name is normalized away before comparison, and each wording's tail — the
 * cross-file tail doubling as that rule's `messageIdentity` mask anchor.
 */
typedef DupMode = {
	var ruleId: String;
	var normalizeBinders: Bool;
	var sameFileTail: String;
	var crossFileTail: String;
}

/**
 * The vocabularies one file's block walk needs. `binders` null is the reading that normalizes
 * no name, where every statement's key is its raw render; `bare` is read under both.
 */
typedef DupCtx = {
	var source: String;
	var blockKinds: Array<String>;
	var opaqueKinds: Array<String>;
	var binders: Null<DupBinders>;
	var bare: DupBareKinds;
}

/**
 * The grammar seams a binder-normalizing render asks: the scopes a local binding can span, the
 * kinds that carry a binding on their own `name`, and the identifier kind a reference projects as.
 */
typedef DupBinders = {
	var shape: RefShape;
	var scopeKinds: Array<String>;
	var binderKinds: Array<String>;
	var identKind: String;
}

/**
 * The grammar seams the bare-run filter reads, beside the shape they come from: the local
 * declaration kinds with their continuation and type-annotation children, the literal kinds, and
 * the collection literal kinds whose empty spelling is a literal too.
 */
typedef DupBareKinds = {
	var shape: RefShape;
	var declKinds: Array<String>;
	var continuationKinds: Array<String>;
	var typeChildKinds: Array<String>;
	var literalKinds: Array<String>;
	var emptyCollectionKinds: Array<String>;
}
