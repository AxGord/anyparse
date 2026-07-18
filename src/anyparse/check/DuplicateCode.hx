package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a run of three or more consecutive statements that appears, byte-for-byte
 * identical up to whitespace, in two or more places — a copy-paste clone the user's
 * rule says to always extract into a helper ("duplication is a bug, not a design
 * choice"). Two passes over the same normalized statement stream: a SAME-FILE pass
 * (`scanBlocks`) and a project-wide CROSS-FILE pass (`scanCrossFile`); a same-file
 * pair is reported by the first pass only, never by both. Purely structural (no type
 * information needed). `Info`, REPORT-ONLY — extraction is a refactoring (`hxq
 * extract-method`), and across a file boundary whether to introduce a shared helper is
 * a design decision the tool must not force, so `fix` produces no edits.
 *
 * ## What is a clone
 *
 * - **Same-file and cross-file.** The same-file pass hashes each file's own block
 *   three-grams; the cross-file pass concatenates every scoped file's blocks into ONE
 *   global three-gram index built in a single pass (no O(N²) file-pair comparison) and
 *   reports a clone only when its two occurrences sit in DIFFERENT files, pointing the
 *   later at the globally-earliest occurrence. Same-file pairs are skipped by the
 *   cross-file pass, so the two passes partition the clone space with no double-report.
 * - **Whitespace-only normalization.** Two statements are equal when their source
 *   text matches after every run of spaces / tabs / newlines is collapsed to a
 *   single space (and the ends trimmed). There is NO identifier normalization
 *   (alpha-renaming): only exact-logic clones match, so the check has zero false
 *   positives by construction. A comment inside a statement's span makes it
 *   textually different — not a clone; a comment BETWEEN
 *   statements is trivia outside every statement span and does not affect equality.
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
 *   one-liners (`i++; j++; k++;`) is not flagged.
 * - Runs entirely inside an `opaqueKinds` (macro reification) subtree are skipped —
 *   their identifiers may be spliced from elsewhere.
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
final class DuplicateCode implements Check {

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

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'three or more consecutive statements duplicated (whitespace-insensitive) within the same file or across files';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return [];
		final blockKinds: Array<String> = support.blockKinds();
		final opaqueKinds: Array<String> = plugin.refShape().opaqueKinds ?? [];
		final violations: Array<Violation> = [];
		final perFile: Array<DupFile> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final blocks: Array<Array<DupStmt>> = [];
			collectBlocks(tree, entry.source, blockKinds, opaqueKinds, blocks);
			perFile.push({ file: entry.file, source: entry.source, blocks: blocks });
		}
		for (pf in perFile) scanBlocks(violations, pf.file, pf.source, pf.blocks);
		scanCrossFile(violations, perFile);
		return violations;
	}

	/** Extraction is a refactoring (`hxq extract-method`), not a mechanical span edit — report-only. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/**
	 * The same-file pass: hash this file's own block statement three-grams to find clone
	 * starts, extend each to its maximal run, drop overlapping and sub-window runs, and emit
	 * one `Info` per surviving later occurrence WITHIN the file. `blocks` was collected once by
	 * `run` (`collectBlocks`) and is shared with the cross-file pass, so the tree is walked once.
	 */
	private static function scanBlocks(out: Array<Violation>, file: String, source: String, blocks: Array<Array<DupStmt>>): Void {
		final grams: Map<String, Array<DupPos>> = buildGrams(blocks);
		final findings: Array<DupFinding> = [];
		for (bucket in grams) if (bucket.length >= 2) collectFindings(blocks, source, bucket, findings);

		final kept: Array<DupFinding> = dropOverlapping(findings);
		kept.sort((a, b) -> a.span.from - b.span.from);
		for (f in kept) out.push({
			file: file,
			span: f.span,
			rule: RULE_ID,
			severity: Severity.Info,
			message: '${f.count} statements duplicated from line ${f.origLine} — extract a helper (hxq extract-method)'
		});
	}

	/**
	 * Append each block (a `blockKinds` node's direct-child statement sequence) with
	 * at least `MIN_STATEMENTS` statements to `out`, skipping `opaqueKinds` subtrees.
	 */
	private static function collectBlocks(
		node: QueryNode, source: String, blockKinds: Array<String>, opaqueKinds: Array<String>, out: Array<Array<DupStmt>>
	): Void {
		if (opaqueKinds.contains(node.kind)) return;
		if (blockKinds.contains(node.kind)) {
			final stmts: Array<DupStmt> = [];
			for (child in node.children) {
				final span: Null<Span> = child.span;
				if (span != null) stmts.push(normalizeStmt(source, span));
			}
			if (stmts.length >= MIN_STATEMENTS) out.push(stmts);
		}
		for (child in node.children) collectBlocks(child, source, blockKinds, opaqueKinds, out);
	}

	/**
	 * Whitespace-normalized view of the statement at `span`: every run of spaces /
	 * tabs / newlines collapsed to a single space with the ends trimmed, plus the
	 * count of non-whitespace characters (the content-gate metric).
	 */
	private static function normalizeStmt(source: String, span: Span): DupStmt {
		final buf: StringBuf = new StringBuf();
		var nonWs: Int = 0;
		var pendingSpace: Bool = false;
		for (i in span.from ... span.to) {
			final c: Int = StringTools.fastCodeAt(source, i);
			if (c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code) {
				pendingSpace = true;
			} else {
				if (pendingSpace && nonWs > 0) buf.addChar(' '.code);
				pendingSpace = false;
				buf.addChar(c);
				nonWs++;
			}
		}
		return { norm: buf.toString(), span: span, nonWs: nonWs };
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
			if (len < MIN_STATEMENTS) continue;
			if (anchor.b == later.b && later.i - anchor.i < len) continue;
			if (runNonWs(blocks[anchor.b], anchor.i, len) < MIN_NON_WS_CHARS) continue;
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

	/** Length of the maximal run of normalized-equal statements from `a` and `b` in parallel. */
	private static function commonRun(blocks: Array<Array<DupStmt>>, a: DupPos, b: DupPos): Int {
		final sa: Array<DupStmt> = blocks[a.b];
		final sb: Array<DupStmt> = blocks[b.b];
		var len: Int = 0;
		while (a.i + len < sa.length && b.i + len < sb.length && sa[a.i + len].norm == sb[b.i + len].norm) len++;
		return len;
	}

	/** Total non-whitespace characters across `len` statements of `stmts` from `start`. */
	private static function runNonWs(stmts: Array<DupStmt>, start: Int, len: Int): Int {
		var total: Int = 0;
		for (i in start ... start + len) total += stmts[i].nonWs;
		return total;
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
	private static function scanCrossFile(out: Array<Violation>, perFile: Array<DupFile>): Void {
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
			rule: RULE_ID,
			severity: Severity.Info,
			message: '${f.count} statements duplicated from ${f.origFile}:${f.origLine} — extract a shared helper (report-only, cross-file)'
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
		bucket.sort((a, b) ->
			blockFile[a.b] != blockFile[b.b] ? blockFile[a.b] - blockFile[b.b] : blocks[a.b][a.i].span.from - blocks[b.b][b.i].span.from
		);
		final anchor: DupPos = bucket[0];
		final anchorFile: Int = blockFile[anchor.b];
		for (k in 1...bucket.length) {
			final later: DupPos = bucket[k];
			final laterFile: Int = blockFile[later.b];
			if (laterFile == anchorFile) continue;
			final len: Int = commonRun(blocks, anchor, later);
			if (len < MIN_STATEMENTS) continue;
			if (runNonWs(blocks[anchor.b], anchor.i, len) < MIN_NON_WS_CHARS) continue;
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
	 * Hash every three-gram of consecutive normalized statements across `blocks` into
	 * start-position buckets — the shared index both the same-file pass (one file's blocks)
	 * and the cross-file pass (every scoped file's blocks concatenated) probe for clones.
	 */
	private static function buildGrams(blocks: Array<Array<DupStmt>>): Map<String, Array<DupPos>> {
		final grams: Map<String, Array<DupPos>> = [];
		for (b in 0...blocks.length) {
			final stmts: Array<DupStmt> = blocks[b];
			for (i in 0...stmts.length - (MIN_STATEMENTS - 1)) {
				final key: String = stmts[i].norm + GRAM_SEP + stmts[i + 1].norm + GRAM_SEP + stmts[i + 2].norm;
				final bucket: Null<Array<DupPos>> = grams[key];
				if (bucket == null)
					grams[key] = [{ b: b, i: i }];
				else
					bucket.push({ b: b, i: i });
			}
		}
		return grams;
	}

}

/** A block statement: its whitespace-normalized text, source span, and non-whitespace-character count. */
typedef DupStmt = {
	var norm: String;
	var span: Span;
	var nonWs: Int;
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
