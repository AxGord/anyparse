package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.ImportOrder;
import anyparse.query.ModuleScan;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags an `import` / `using` written ABOVE the `#if … #end` region that guards the module's
 * WHOLE body — the island a debug- or platform-only module ends up with when a header line is
 * added by hand, or by a fixer that could not see the guarded header. `Severity.Info`; `--fix`
 * MOVES the stranded declarations inside the guard, next to the ones the guarded code already
 * reads.
 *
 * The shape is decided by `UsingScan.headerOf`, whose `guard` is exactly "the region that holds
 * every type this module declares": one region at the top level with no type outside it, the
 * region declaring a type itself, and no `#else` / `#elseif` seam of its own. Those three gates
 * are what makes the move sound — every build that compiles any of this file's code has the
 * guard's condition true, so a header line inside the region is in scope for all of it, and one
 * outside it is in scope for nothing else.
 *
 * ## All-or-nothing, one finding per file
 *
 * The finding is reported ONCE, on the first stranded declaration, and the fix moves the whole
 * stranded header. That is not brevity: Haxe ranks static extensions in REVERSE declaration
 * order, so moving ONE of two `using` lines past the other would flip which module supplies a
 * same-named extension method. A per-declaration finding could be suppressed one line at a time
 * (`// noqa`), which is exactly the partial application that flip needs.
 *
 * ## Where each line lands
 *
 * A pure relocation — every moved line keeps its own text (leading whole-line `//` comments
 * included, via `ImportOrder`'s chunk) and the set keeps its relative order:
 *
 *  - imports go ABOVE the guard's first import, so the file's overall import order is the one it
 *    already had;
 *  - `using` lines go ABOVE the guard's first `using` — they were written earlier, which in
 *    Haxe's reverse ranking means LOWER priority, and above is where that stays true. With no
 *    guarded `using` to rank against they follow the guard's last import instead.
 *
 * With no guarded header at all both land right after the `#if` directive line — its own line
 * end, never the first child's span, which would splice between a declaration and its doc
 * comment.
 *
 * Blank lines are not computed here: the fix emits raw edits and the writer re-emits the file,
 * where the region body's own import↔using↔type blank-line policy applies.
 *
 * ## Refusals
 *
 * A declaration that cannot be lifted as a whole LINE (its line carries other code, a block
 * comment follows it, the file ends without a newline) leaves the finding REPORT-ONLY, and so
 * does an unliftable line anywhere else in the header — inside the guard, or in the rare tail
 * position after `#end`. The relocation is all-or-nothing, so one line it cannot move refuses
 * the whole move rather than reordering the rest around it.
 *
 * The merged import run is NOT re-sorted (`import-order` owns that, and it is default off) — a
 * moved import may land in a run whose order it does not fit.
 */
@:nullSafety(Strict)
final class ImportOutsideGuard implements Check {

	private static inline final RULE_ID: String = 'import-outside-guard';

	/** The plain / wildcard / aliased import kinds — the header half whose position carries no resolution order. */
	private static final IMPORT_KINDS: Array<String> = ['ImportDecl', 'ImportAliasDecl', 'ImportAliasInDecl', 'ImportWildDecl'];

	/** The `using` kind alone — its position among the other `using` lines IS semantics, so it moves on its own terms. */
	private static final USING_KINDS: Array<String> = [UsingScan.USING_DECL_KIND];

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'an import or using declared above the #if region that guards the module\'s whole body';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final violations: Array<Violation> = [];
		for (entry in files) {
			final stranded: Null<Span> = strandedHeadOf(entry.source, plugin);
			if (stranded != null) violations.push({
				file: entry.file,
				span: stranded,
				rule: RULE_ID,
				severity: Severity.Info,
				message: 'this declaration is written above the #if that guards the module\'s whole body, so it is in scope for no code '
				+ 'the file has — the header belongs inside the guard'
			});
		}
		return violations;
	}

	/**
	 * The whole stranded header moved inside the guard. Re-derived from `source` rather than
	 * from the reported span: the move needs both ends of every line and the guard's own
	 * anchors, none of which a `Violation` has a slot for. The file carries at most one finding,
	 * so the violation list is only ever a request to run.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return violations.length == 0 ? [] : relocationEdits(source, plugin);
	}

	/**
	 * `source`'s module paired with the region guarding its whole body, or null when it has no
	 * such region — the ordinary unguarded module, and every shape `UsingScan`'s coverage gates
	 * refuse.
	 */
	private static function guardedModule(source: String, plugin: GrammarPlugin): Null<{ tree: QueryNode, guard: QueryNode }> {
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return null;
		final guard: Null<QueryNode> = UsingScan.headerOf(tree, source, plugin).guard;
		return guard == null ? null : { tree: tree, guard: guard };
	}

	/** The span of the FIRST header declaration written above the guard, or null when the module strands none. */
	private static function strandedHeadOf(source: String, plugin: GrammarPlugin): Null<Span> {
		final guarded: Null<{ tree: QueryNode, guard: QueryNode }> = guardedModule(source, plugin);
		if (guarded == null) return null;
		final guardSpan: Null<Span> = guarded.guard.span;
		if (guardSpan == null) return null;
		for (child in guarded.tree.children) if (IMPORT_KINDS.contains(child.kind) || USING_KINDS.contains(child.kind)) {
			final span: Null<Span> = child.span;
			if (span != null && span.from < guardSpan.from) return span;
		}
		return null;
	}

	/** The delete + insert pairs that move the stranded header inside the guard, or none when any refusal applies. */
	private static function relocationEdits(source: String, plugin: GrammarPlugin): Array<{ span: Span, text: String }> {
		final guarded: Null<{ tree: QueryNode, guard: QueryNode }> = guardedModule(source, plugin);
		if (guarded == null) return [];
		final guardSpan: Null<Span> = guarded.guard.span;
		if (guardSpan == null) return [];
		final guardFrom: Int = guardSpan.from;
		final outerImports: Null<Array<ImportLine>> = ImportOrder.linesOfKinds(source, guarded.tree, IMPORT_KINDS);
		final outerUsings: Null<Array<ImportLine>> = ImportOrder.linesOfKinds(source, guarded.tree, USING_KINDS);
		final innerImports: Null<Array<ImportLine>> = ImportOrder.linesOfKinds(source, guarded.guard, IMPORT_KINDS);
		final innerUsings: Null<Array<ImportLine>> = ImportOrder.linesOfKinds(source, guarded.guard, USING_KINDS);
		if (outerImports == null || outerUsings == null || innerImports == null || innerUsings == null) return [];
		final movedImports: Array<ImportLine> = outerImports.filter(line -> line.declFrom < guardFrom);
		final movedUsings: Array<ImportLine> = outerUsings.filter(line -> line.declFrom < guardFrom);
		if (movedImports.length + movedUsings.length == 0) return [];
		final bodyStart: Int = ModuleScan.guardBodyStart(source, guarded.guard);
		if (bodyStart < 0) return [];
		final importAt: Int = innerImports.length == 0 ? bodyStart : innerImports[0].chunkFrom;
		final usingAt: Int = if (innerUsings.length > 0)
			innerUsings[0].chunkFrom;
		else if (innerImports.length > 0)
			innerImports[innerImports.length - 1].chunkTo;
		else
			bodyStart;
		final edits: Array<{ span: Span, text: String }> = [
			for (line in movedImports.concat(movedUsings)) { span: new Span(line.chunkFrom, line.chunkTo), text: '' }
		];
		final importText: String = textOf(source, movedImports);
		final usingText: String = textOf(source, movedUsings);
		// Two zero-width edits at one offset would apply in an unspecified order, so a shared
		// anchor carries both halves as ONE edit, imports first.
		if (importAt == usingAt)
			edits.push({ span: new Span(importAt, importAt), text: importText + usingText });
		else {
			if (importText != '') edits.push({ span: new Span(importAt, importAt), text: importText });
			if (usingText != '') edits.push({ span: new Span(usingAt, usingAt), text: usingText });
		}
		return edits;
	}

	/** The verbatim source of `lines` in order — each is a whole line, so the pieces already carry their newlines. */
	private static function textOf(source: String, lines: Array<ImportLine>): String {
		final buf: StringBuf = new StringBuf();
		for (line in lines) buf.add(source.substring(line.chunkFrom, line.chunkTo));
		return buf.toString();
	}

}
