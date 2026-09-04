package anyparse.query.cli;

import anyparse.query.LexicalRegions.LexRegion;
import anyparse.query.RefactorSupport.EditResult;
import anyparse.query.ReplaceNode;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.query.ExitCode.*;

/**
 * The edit pipeline every mutating `apq` command ends in: resolve the address
 * the user gave (`--select` / `--match` / `--at` / `--nth`) to a node or a
 * position, then turn the resulting `EditResult` into the one thing the user
 * sees — a written file, a preview on stdout, or a diagnostic and a non-zero
 * exit.
 *
 * Keeping it in one place is what makes `--write` mean the same thing in all
 * 35 mutating commands, and what lets a command that has moved onto the
 * `CliCommand` registry finish an edit without reaching back into `Cli`.
 */
@:nullSafety(Strict)
final class CliEdit {

	/**
	 * The print-only tail every writer-emit op shares: the rewritten source goes to
	 * STDOUT, and — the half that was missing — a line on stderr saying the file was
	 * NOT touched.
	 *
	 * Without it the two outcomes a caller most needs to tell apart, "the edit
	 * landed" and "the edit was a preview", were distinguished only by output nobody
	 * is obliged to read: `--write` reports on stderr, a preview reported nothing
	 * there at all. A caller that keeps stderr and drops stdout — the documented way
	 * to run these ops without drowning in source — saw the same silence either way,
	 * and silence reads as success.
	 */
	public static function previewEdit(opName: String, filePath: String, text: String, detail: String = ''): Void {
		CliIo.sysPrint(text);
		CliIo.stderr('apq $opName: $filePath NOT written — this is a preview on stdout$detail; re-run with --write to apply\n');
	}

	/**
	 * Report a writer that needed more than one round trip to settle the content
	 * an op is about to write, in `apq fmt`'s exact words.
	 *
	 * Silent for the healthy counts and for a `null` — an `EditResult.Ok` from a
	 * producer that never ran the loop measured nothing, and inventing a "1" for it
	 * would claim a measurement nobody made.
	 *
	 * Called on the FINALISE, not on the write, so it fires in preview mode too:
	 * the finding is about the WRITER, and a preview is where a user is still
	 * deciding. It also has to be said here rather than left for the user's next
	 * `fmt --list`, which will say nothing — by then the file IS the fixed point.
	 *
	 * A caller that makes several passes over one file gates the call on its own
	 * "already told them about this file" set — `FormatFixedPoint.rewritesNote` is
	 * the same predicate, asked directly.
	 */
	public static function warnRewrites(opName: String, filePath: String, rewrites: Null<Int>): Void {
		final note: Null<String> = FormatFixedPoint.rewritesNote(rewrites);
		if (note != null) CliIo.stderr('apq $opName: $filePath: $note\n');
	}

	/** Shared Ok/Err + write/preview tail for the single-result writer-emit ops. */
	public static function finishEdit(opName: String, filePath: String, write: Bool, result: EditResult, ?detail: String): Int {
		switch result {
			case Ok(text, rewrites):
				warnRewrites(opName, filePath, rewrites);
				// `detail` reaches the PREVIEW too: a preview leaves no file to inspect, so it is
				// the mode where "did all of them land?" has no other answer.
				final tail: String = detail == null ? '' : ' ($detail)';
				if (write) {
					CliIo.writeFile(filePath, text);
					CliIo.stderr('apq $opName: wrote $filePath$tail\n');
				} else
					previewEdit(opName, filePath, text, tail);
				return EXIT_OK;
			case Err(message):
				CliIo.stderr('apq $opName: $message\n');
				return EXIT_RUNTIME;
		}
	}

	/**
	 * Resolve the shared addressing flags (`--select` / `--match` / `--at`, plus
	 * the `--kind` narrow / lift) to a `ReplaceTarget` — the common front half of
	 * `replace-node` and `patch`. Exactly one addressing mode must be given.
	 * Returns null after printing the reason to stderr.
	 */
	public static function resolveEditTarget(
		opName: String, source: String, filePath: String, plugin: GrammarPlugin, selectExpr: Null<String>, matchExpr: Null<String>,
		atSpec: Null<String>, nth: Null<Int>, kind: Null<String>
	): Null<ReplaceTarget> {
		final modes: Int = (selectExpr != null ? 1 : 0) + (matchExpr != null ? 1 : 0) + (atSpec != null ? 1 : 0);
		if (modes != 1) {
			CliIo.stderr('apq $opName: provide exactly one of --select \'<sel>\', --match \'<pattern>\', or --at <line>[:<col>]\n');
			return null;
		}
		if (atSpec != null) {
			// `--kind` with `--at` narrows to the innermost node of that kind at the cursor.
			final pos: Null<Position> = resolveAddressPos(opName, source, plugin, atSpec, null, null, null);
			return if (pos == null)
				null
			else if (kind != null)
				ByKindPosition(pos.line, pos.col, kind)
			else
				ByPosition(pos.line, pos.col);
		}
		// --select / --match resolve through the shared address layer (exactly-one
		// discipline, --nth pick, candidate-listing errors); the caching plugin
		// guarantees the resolved node belongs to the op's own parse. `--kind`
		// here LIFTS the resolved node to its innermost enclosing node of that
		// kind — a pattern matches the expression (`addCase(x)` = the Call),
		// while a statement edit wants the ExprStmt.
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (exception: ParseError) null catch (exception: Exception) null;
		if (tree != null) return switch Address.resolve(tree, source, plugin, { select: selectExpr, match: matchExpr, nth: nth }) {
			case Ok(_, node):
				if (node == null) {
					null;
				} else if (kind != null) {
					final lifted: Null<QueryNode> = Address.liftToKind(tree, node, kind, plugin.selectKindEquivalence());
					if (lifted == null) {
						CliIo.stderr('apq $opName: the resolved ${node.kind} node has no enclosing "$kind" node\n');
						null;
					} else
						ByNode(lifted);
				} else
					ByNode(node);
			case Err(message):
				CliIo.stderr('apq $opName: $message\n');
				null;
		};
		CliIo.stderr('apq $opName: $filePath does not parse\n');
		return null;
	}

	/**
	 * Resolve the shared address flags (`<line>[:<col>]` / `--select` /
	 * `--match` [+ `--nth`]) to a 1-based position, printing the op-prefixed
	 * error on failure. The file is parsed here — pass a CACHING plugin so the
	 * op's own parse reuses the identical tree (node identity matters to
	 * `RefactorSupport.parentOf`-based span logic downstream, and the shared
	 * cache makes this parse free). `preferName` shifts a select/match-resolved
	 * NAMED node's position to its name token — the cursor-based fn-ops
	 * (rename / change-sig / …) resolve an identifier at the cursor, so the
	 * address must land on the name, not the `function` keyword; element ops
	 * keep the first-token position.
	 *
	 * A position / pattern resolution also echoes the target's CANONICAL
	 * selector (`Address.describe`) to stderr — the edit-stable address a
	 * follow-up op can use without re-locating after this edit shifts lines.
	 */
	public static function resolveAddressPos(
		op: String, source: String, plugin: GrammarPlugin, at: Null<String>, select: Null<String>, matchPat: Null<String>, nth: Null<Int>,
		preferName: Bool = false
	): Null<Position> {
		final tree: QueryNode = try plugin.parseFile(source) catch (exception: Exception) {
			CliIo.stderr('apq $op: source does not parse: ${exception.message}\n');
			return null;
		};
		return switch Address.resolve(tree, source, plugin, {
			at: at,
			select: select,
			match: matchPat,
			nth: nth
		}) {
			case Ok(offset, node):
				if (node != null && select == null)
					CliIo.stderr('apq $op: target ${Address.describe(tree, source, node, plugin.selectKindEquivalence())}\n');
				final named: Null<Int> = preferName && at == null && node != null ? Address.nameTokenOffset(source, node) : null;
				new Span(named ?? offset, named ?? offset).lineCol(source);
			case Err(message):
				CliIo.stderr('apq $op: $message\n');
				null;
		};
	}

	/**
	 * The window each match's `--source` / `--doc` block is cut from — one per match, in `Patch`'s own
	 * order: `declGroupSpan` folds in the modifier / `@:meta` run the grammar projects as SIBLINGS of a
	 * declaration, then `trailingTrimmedSpan` drops the run a `@:trailOpt` decl written without its
	 * terminator swallows past its own closing brace.
	 *
	 * That is byte-for-byte the span `patch` searches and `replace-node` overwrites, and the same fold
	 * `resolveNodeLineBounds` applies before widening it to whole LINES for `apq source --select` — so
	 * the two reads agree about which declaration they mean, though `source --select` prints whole
	 * lines and this prints exact bytes. Cutting the BARE node span instead handed back a declaration
	 * without its `@:keep` / `public` / `#if … enum #end`, and feeding that straight to `replace-node`
	 * dropped them at rc 0 — the hazard the ops' documentation blames on the caller, produced by a read
	 * the documentation offers as the copy source. `--doc` and `--source` also stopped agreeing about
	 * the same declaration: the doc block is found by walking BACK over the annotation lines, so with
	 * both flags on the `@:keep` between them was printed by neither, and below a `#if … enum #end`
	 * prefix the walk hit the `#end` and reported no doc at all.
	 *
	 * `--spans` is untouched: it reports the node's own span, which is what an AST view owes. So does
	 * the JSON `span` key, which is emitted unconditionally — a JSON consumer that slices `span` out of
	 * the file and one that reads the `source` key get different bytes for the same match, by design:
	 * `span` describes the NODE, `source` describes the declaration it belongs to.
	 *
	 * The `refs` / `uses` `--source` opt-in still cuts the bare hit span. A hit is an OCCURRENCE in a
	 * multi-file listing rather than a node the caller addressed, its entry record carries no tree to
	 * fold against, and for every non-declaration hit the fold is a no-op; a caller that wants op-ready
	 * text should read it with `apq source --select` or `apq ast --select`.
	 *
	 * The spans are taken from the RAW matches, before `--depth` / `--children-limit` reshape them: a
	 * reshaped node is a COPY and has no parent in the tree. The caller computes them only when a flag
	 * asks, since `trailingTrimmedSpan` lexes the whole file per match.
	 */
	public static function sourceWindows(
		tree: QueryNode, nodes: Array<QueryNode>, source: String, regions: () -> Array<LexRegion>
	): Array<Null<Span>> {
		return [
			for (n in nodes) {
				final raw: Null<Span> = n.span;
				raw == null ? null : RefactorSupport.declEditSpan(source, tree, n, raw, regions);
			}
		];
	}

}
