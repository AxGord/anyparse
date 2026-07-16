package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags a run of three or more consecutive statements that appears, byte-for-byte
 * identical up to whitespace, in two or more places within the SAME file — a
 * copy-paste clone the user's rule says to always extract into a helper
 * ("duplication is a bug, not a design choice"). Purely structural (no type
 * information needed). `Info`, REPORT-ONLY — extraction is a refactoring (`hxq
 * extract-method`), not a mechanical span edit, so `fix` produces no edits.
 *
 * ## What is a clone (v1 scope)
 *
 * - **In-file only.** Cross-file clone detection is a future axis — it needs a
 *   project-wide index and noise control; a per-file scan has zero coordination
 *   cost and no false positives from unrelated files.
 * - **Whitespace-only normalization.** Two statements are equal when their source
 *   text matches after every run of spaces / tabs / newlines is collapsed to a
 *   single space (and the ends trimmed). There is NO identifier normalization
 *   (alpha-renaming): only exact-logic clones match, so the check has zero false
 *   positives by construction. A comment inside a statement's span makes it
 *   textually different — not a clone (acceptable for v1); a comment BETWEEN
 *   statements is trivia outside every statement span and does not affect equality.
 * - **Consecutive statements, one block.** A run is a maximal sequence of direct-child
 *   statements of a `ControlFlowSupport.blockKinds()` node (function body / nested
 *   block); the two occurrences may sit in different blocks and different block
 *   kinds (a method body vs an `if` body). A five-statement clone is reported ONCE
 *   as its maximal run, not as three overlapping three-statement windows.
 * - **Non-overlapping occurrences.** Within one clone family the earliest occurrence
 *   is the original; each later occurrence that does not overlap it is a finding
 *   (`a; a; a; a` with window `a; a; a` yields no report — the only second window
 *   overlaps the first).
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
 * run at the LATER occurrence (the duplicated region itself), and its message
 * points at the first occurrence's line. One violation per duplicate occurrence,
 * not one per statement — so three occurrences of a clone produce two findings.
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

	public function new() {}

	public function id(): String {
		return 'duplicate-code';
	}

	public function description(): String {
		return 'three or more consecutive statements duplicated (whitespace-insensitive) elsewhere in the same file';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return [];
		final blockKinds: Array<String> = support.blockKinds();
		final opaqueKinds: Array<String> = plugin.refShape().opaqueKinds ?? [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) scanFile(violations, entry.file, entry.source, tree, blockKinds, opaqueKinds);
		}
		return violations;
	}

	/** Extraction is a refactoring (`hxq extract-method`), not a mechanical span edit — report-only. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/**
	 * Collect every block's statement sequence, hash three-grams to find clone
	 * starts, extend each to its maximal run, drop overlapping and sub-window
	 * runs, and emit one `Info` per surviving later occurrence.
	 */
	private static function scanFile(
		out: Array<Violation>, file: String, source: String, tree: QueryNode, blockKinds: Array<String>, opaqueKinds: Array<String>
	): Void {
		final blocks: Array<Array<DupStmt>> = [];
		collectBlocks(tree, source, blockKinds, opaqueKinds, blocks);

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

		final findings: Array<DupFinding> = [];
		for (bucket in grams) if (bucket.length >= 2) collectFindings(blocks, source, bucket, findings);

		final kept: Array<DupFinding> = dropContained(findings);
		kept.sort((a, b) -> a.span.from - b.span.from);
		for (f in kept) out.push({
			file: file,
			span: f.span,
			rule: 'duplicate-code',
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
				origLine: blocks[anchor.b][anchor.i].span.lineCol(source).line
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
	 * Keep only the maximal findings: drop any whose span is strictly contained in
	 * another's, so a five-statement clone's three- and four-statement sub-windows
	 * fall away and it reports once. Raw findings never share a start, so equal-span
	 * ties cannot arise.
	 */
	private static function dropContained(findings: Array<DupFinding>): Array<DupFinding> {
		return [for (i in 0...findings.length) if (!isContained(findings, i)) findings[i]];
	}

	private static function isContained(findings: Array<DupFinding>, i: Int): Bool {
		final e: Span = findings[i].span;
		for (j in 0...findings.length) if (j != i) {
			final o: Span = findings[j].span;
			if (o.from <= e.from && e.to <= o.to && (o.from < e.from || e.to < o.to)) return true;
		}
		return false;
	}

}

/** A block statement: its whitespace-normalized text, source span, and non-whitespace-character count. */
typedef DupStmt = {
	var norm: String;
	var span: Span;
	var nonWs: Int;
}

/** A three-gram start position: block index `b` and statement index `i` within it. */
typedef DupPos = {
	var b: Int;
	var i: Int;
}

/** A recorded clone occurrence: its span, statement count, and the original's line. */
typedef DupFinding = {
	var span: Span;
	var count: Int;
	var origLine: Int;
}
