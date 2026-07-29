package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeRefPrinter;
import anyparse.runtime.Span;
import anyparse.check.Check.RiskyFix;

/**
 * One local annotation this rule would rewrite: the annotation's OWN span (the `:` payload,
 * whitespace trimmed), the reprinted text, and whether the resolution index proved EVERY
 * reference the reprint changed. `proven` false is a report-only finding — the span is
 * reported, the `text` never applied.
 */
private typedef Candidate = {
	var span: Span;
	var text: String;
	var proven: Bool;
}

/**
 * Flags a DOTTED type reference in a local `var` / `final` type annotation that the file
 * itself spells differently — the shared `TypeRefPrinter` decides how the reference SHOULD be
 * written here, and any disagreement is the finding. Two arms, and only the first is a
 * correctness matter:
 *
 * ## ARM 1 — the `pack.SubType` hybrid (why the rule exists)
 *
 * A SECONDARY (sub-module) type has two spellings that both compile:
 * `api.model.folders.FolderContent.FolderContentEntity` — the module-qualified path, which
 * always resolves — and `api.model.folders.FolderContentEntity`, the HYBRID a compiler prints
 * and a hand-written annotation copies. The hybrid resolves ONLY while an
 * `import api.model.folders.FolderContent.FolderContentEntity;` happens to be in the file: drop
 * that import (as an unused-import sweep eventually will, once the short name's last use goes)
 * and the annotation stops compiling, at a site that never changed. The fix repairs it to a
 * spelling that stands on its own — the short name when the import is there, the
 * module-qualified path when it is not.
 *
 * ## ARM 2 — plain over-qualification
 *
 * A dotted path written where the short name is already visible: an exact `import`, an alias,
 * a type declared in this module, the MAIN type of a same-package module, or an always-in-scope
 * builtin. `TypeRefPrinter` owns that judgement, `shadowedLocally` included — so a path kept
 * long BECAUSE the short name is taken (`api.model.folders.FolderContent` in a file whose bare
 * `FolderContent` means `api.namespace.FolderContent`, or any name a wildcard / `using` binds)
 * is left exactly as written.
 *
 * The printer's third route — ADD an import, then use the short name — is unreachable from
 * here, and the rule refuses it explicitly rather than relying on that. Route 3 requires the
 * simple name to occur NOWHERE in the source; the annotation being rewritten always contains it
 * as its own last segment, so the printer's freeness gate closes the route by construction. A
 * run that nonetheless comes back with an `importPath` is treated as unproven, so this rule
 * emits no import edits at all.
 *
 * ## Gates — fail closed
 *
 *  - **Same-declaration proof.** A changed reference is only fixed when
 *    `TypeRefPrinter.resolvePath` proves — against the resolution index — which DECLARATION the
 *    ORIGINAL text names. The printed form denotes the printer's canonical path by construction
 *    (that is its contract), and `resolvePath` answers the same canonical path for the original,
 *    so an equal, non-null answer IS "same module + name". No index, or no indexed declaration
 *    at that path, means unproven — the finding stays, the edit does not.
 *  - **Type parameters.** The annotation is reprinted through the printer's OWN run walk
 *    (`walkTypeExpr`), and EVERY run the reprint changes must pass the proof on its own. One
 *    unproven component makes the WHOLE annotation report-only, so an `Array<pkg.Mod.Sub>` is
 *    never half-rewritten.
 *  - **Conditional compilation.** A declaration inside a `#if … #end` region is skipped
 *    wholesale: what is in scope there depends on the build, which neither the import map nor
 *    the index models. The test is the DIRECTIVE, not a node kind — every conditional region
 *    opens with `#if` whichever of the grammar's dozen positional conditional ctors projects it
 *    (`opensConditionalRegion`). An annotation whose own text carries a `#` is skipped too.
 *  - **Imports.** Never touched (see route 3 above).
 *  - **Shape.** The annotation region is extracted textually — between the declaration's first
 *    `:` and the initializer's `=` (or, with no initializer, the closing `;`). A region carrying
 *    a DEPTH-0 comma is refused: the grammar projects `var a:Int, b = null;` as ONE node whose
 *    name slot holds only `a`, so that comma is a second declarator, not a generic argument, and
 *    the slice would span two of them. A `/` (a comment) or a `;` inside the region is refused
 *    too, as is a top-level anonymous-structure annotation (`final u:{x:T} = …`), whose `Anon`
 *    the grammar makes child 0 — the `=`-after-`:` requirement turns that into a refusal rather
 *    than a bad slice. A multi-declarator statement therefore only ever exposes its FIRST
 *    declarator's annotation — later ones are a KNOWN miss, not a hazard.
 *
 * ## Verified, not trusted — `RiskyFix`
 *
 * The proof above is `canonicalize`'s, so it inherits `canonicalize`'s precondition: a
 * `pack.SubType` is read as a hybrid only when the index declares no type AT that path, and a
 * module the index never saw (outside the lint scope, or one it could not parse) removes that
 * veto — a REAL `pack.SubType` main type would then be repaired onto an imported sub-type of the
 * same simple name. No index can detect its own incompleteness, so the rule is a `RiskyFix`:
 * `apq lint --fix` applies its edits speculatively, typechecks, and reverts any file the edit
 * breaks, and with no `compilerOracle` configured the rule stays report-only wholesale. This is
 * also what makes true the claim `TypeRefPrinter` makes about all of its callers.
 *
 * ## Scope — locals only
 *
 * `RefShape.localDeclKinds` plus `localDeclExprKinds`: statement- and expression-position
 * `var` / `final`. Parameter, return and field annotations are OUT OF SCOPE. The proof machinery
 * carries over unchanged, but the region extraction does not: a local's annotation is bounded by
 * its own initializer, while a parameter's is bounded by the next parameter or the parameter
 * list's `)`, a return type's by the body, and a field's by the member terminator — three
 * different textual searches, i.e. exactly the per-shape special-casing this rule was scoped to
 * avoid. Widening means giving the grammar a real annotation SPAN to hand out, at which point
 * every host shape is the same code.
 *
 * ## Default OFF — opt-in
 *
 * A `DefaultOff` marker: dropped from the default set and from a bare `lint … --all` report
 * unless a project opts in via `apqlint.json`
 * (`"rules": { "shorten-type-ref": { "enabled": true } }`), or an explicit
 * `--rule shorten-type-ref` selects it. How qualified a type reference should be is a project
 * style decision; only the hybrid arm is universal, and it is not separable from the print.
 */
@:nullSafety(Strict)
final class ShortenTypeRef implements Check implements DefaultOff implements RiskyFix {

	/** The rule's stable identifier — the `apqlint.json` key and the `--rule` selector. */
	private static inline final RULE_ID: String = 'shorten-type-ref';

	/** The finding message when every changed reference is index-proven — the rewrite is available. */
	private static inline final MSG_FIXABLE: String =
		'an over-qualified type reference in a local annotation - the file spells this type shorter';

	/** The finding message when the index could not prove a changed reference names the same declaration. */
	private static inline final MSG_UNPROVEN: String =
		'an over-qualified type reference in a local annotation (report-only: the resolution index does not prove the shorter spelling names the same declaration)';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a dotted type reference in a local annotation the file already spells shorter';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final index: Null<SymbolIndex> = RefactorSupport.resolutionIndexOf(plugin);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			for (candidate in candidatesOf(entry.source, tree, plugin, index)) violations.push({
				file: entry.file,
				span: candidate.span,
				rule: RULE_ID,
				severity: Severity.Warning,
				message: candidate.proven ? MSG_FIXABLE : MSG_UNPROVEN
			});
		}
		return violations;
	}

	/**
	 * Replace each proven annotation with its reprinted form. The decision is RE-DERIVED here
	 * rather than carried on the violation — `run`'s verdict travels only as the message, so a
	 * finding the report left unproven yields no edit even if this call sees a wider index.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return [];
		final wanted: Map<String, Bool> = [];
		var anyFixable: Bool = false;
		for (violation in violations) {
			final span: Null<Span> = violation.span;
			if (span != null && violation.message == MSG_FIXABLE) {
				wanted['${span.from}:${span.to}'] = true;
				anyFixable = true;
			}
		}
		if (!anyFixable) return [];
		// The resolution index (report UNION libraries) is the wider proof. The `?? index` fallback
		// is defensive only: through `run` a null resolution index makes EVERY finding unproven, so
		// `anyFixable` has already returned above — it exists for a caller that hands in violations
		// it built itself.
		final scope: Null<SymbolIndex> = RefactorSupport.resolutionIndexOf(plugin) ?? index;
		return [
			for (candidate in candidatesOf(source, tree, plugin, scope))
				if (candidate.proven && wanted.exists('${candidate.span.from}:${candidate.span.to}'))
					{ span: candidate.span, text: candidate.text }
		];
	}

	/**
	 * Every local annotation in `tree` the file spells differently from `TypeRefPrinter`'s
	 * verdict. ONE printer serves the whole file (its per-file state is the resolution input, so
	 * a second instance would answer the same); its pending-import set stays empty because no
	 * candidate ever accepts an import-backed short form.
	 */
	private static function candidatesOf(
		source: String, tree: QueryNode, plugin: GrammarPlugin, index: Null<SymbolIndex>
	): Array<Candidate> {
		final shape: RefShape = plugin.refShape();
		final locals: Array<String> = (shape.localDeclKinds ?? []).concat(shape.localDeclExprKinds ?? []);
		if (locals.length == 0) return [];
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		final importMap: Map<String, String> = provider != null ? provider.importMap(source) : [];
		final printer: TypeRefPrinter = TypeRefPrinter.forFile(source, tree, importMap, index);
		final out: Array<Candidate> = [];
		walkLocals(tree, source, locals, shape.opaqueKinds ?? [], shape.conditionalIfKeyword, node -> {
			final region: Null<Span> = annotationSpan(node, source);
			if (region == null) return;
			final candidate: Null<Candidate> = reprint(source, region, printer);
			if (candidate != null) out.push(candidate);
		});
		return out;
	}

	/**
	 * Visit every local declaration in `node`'s subtree, skipping two subtrees wholesale: a
	 * reification (`opaqueKinds`), whose spliced locals are not literal source, and a
	 * conditional-compilation region (`opensConditionalRegion`), whose scope depends on the build.
	 */
	private static function walkLocals(
		node: QueryNode, source: String, locals: Array<String>, opaque: Array<String>, condIf: Null<String>, found: (QueryNode) -> Void
	): Void {
		if (opaque.contains(node.kind) || opensConditionalRegion(node, source, condIf)) return;
		if (locals.contains(node.kind)) found(node);
		for (c in node.children) walkLocals(c, source, locals, opaque, condIf, found);
	}

	/**
	 * Whether `node`'s source STARTS with the grammar's `#if` directive — i.e. it is a
	 * conditional-compilation region, whatever kind the grammar happens to project it as.
	 *
	 * A kind test cannot do this job. The Haxe grammar carries a dozen conditional ctors, one per
	 * host position (`Conditional` for members and statements, `ConditionalExpr` in expression
	 * position, `ConditionalArgs` in an argument list, five `CondSplice*` forms for a region that
	 * straddles a block or switch boundary, ...), and `RefShape` names only the member one. An
	 * enumerated list would go stale the next time a position is added; the DIRECTIVE cannot,
	 * because every region opens with it by definition. The `#` first-char test keeps it to one
	 * comparison per node before any substring is taken.
	 */
	private static function opensConditionalRegion(node: QueryNode, source: String, condIf: Null<String>): Bool {
		final span: Null<Span> = node.span;
		if (condIf == null || span == null) return false;
		// The null checks stay in their own guard: strict null-safety carries a narrowing fact into
		// a later `||` operand only from the chain's FIRST operand.
		final from: Int = span.from;
		if (from >= source.length || StringTools.fastCodeAt(source, from) != '#'.code) return false;
		return source.substring(from, from + condIf.length) == condIf;
	}

	/**
	 * The span of a local declaration's `:Type` payload — after the `:`, before the initializer's
	 * `=` (or, with no initializer, before the trailing `;`), whitespace trimmed off both ends —
	 * or null when the declaration carries no annotation, or its bounds cannot be located. Neither
	 * the keyword nor the name contains a `:`, so the first `:` before child 0 opens the annotation.
	 *
	 * Child 0 is USUALLY the initializer, but not always: `RefShape.declTypeChildKinds` makes an
	 * `Anon` structure ANNOTATION a child too, and the `=`-after-`:` requirement is what turns that
	 * case into a refusal rather than a bad slice.
	 */
	private static function annotationSpan(node: QueryNode, source: String): Null<Span> {
		final span: Null<Span> = node.span;
		if (span == null) return null;
		final hasChildren: Bool = node.children.length > 0;
		var cutoff: Int = span.to;
		if (hasChildren) {
			final firstSpan: Null<Span> = node.children[0].span;
			if (firstSpan == null) return null;
			cutoff = firstSpan.from;
		}
		final prefix: String = source.substring(span.from, cutoff);
		final colon: Int = prefix.indexOf(':');
		if (colon < 0) return null;
		var from: Int = span.from + colon + 1;
		var to: Int = cutoff;
		if (hasChildren) {
			// The `=` must follow the `:`. It does not when child 0 is the ANNOTATION rather than the
			// initializer (`RefShape.declTypeChildKinds` — an `Anon` structure type), which is what
			// refuses a top-level anonymous-structure annotation. See the class doc's Shape section.
			final eq: Int = prefix.lastIndexOf('=');
			if (eq < colon) return null;
			to = span.from + eq;
		}
		while (to > from && StringTools.isSpace(source, to - 1)) to--;
		// A declaration with no initializer ends on its own `;`, which its span carries.
		if (!hasChildren && to > from && StringTools.fastCodeAt(source, to - 1) == ';'.code) to--;
		while (to > from && StringTools.isSpace(source, to - 1)) to--;
		while (from < to && StringTools.isSpace(source, from)) from++;
		return to > from ? new Span(from, to) : null;
	}

	/**
	 * The annotation at `region` reprinted through `printer`, or null when nothing changes (or the
	 * region is not a plain single type). The walk is the printer's OWN (`walkTypeExpr`), with the
	 * per-run callback used to prove each CHANGED run against the resolution index — so what this
	 * rule writes can never drift from what the plain `printTypeExpr` would emit. One unproven run
	 * marks the whole candidate unproven.
	 */
	private static function reprint(source: String, region: Span, printer: TypeRefPrinter): Null<Candidate> {
		final text: String = source.substring(region.from, region.to);
		if (text.indexOf('.') == -1 || !isPlainTypeRegion(text)) return null;
		var changed: Bool = false;
		var proven: Bool = true;
		final printed: String = printer.walkTypeExpr(text, (run, ref) -> {
			if (ref.text == run) return;
			changed = true;
			// An import-backed short form resolves only once that import lands, and this rule adds
			// none; an unproven original leaves the declaration it names unknown. Either way the
			// annotation stays report-only.
			if (ref.importPath != null || printer.resolvePath(run) == null) proven = false;
		});
		return changed ? { span: region, text: printed, proven: proven } : null;
	}

	/**
	 * Whether `text` is ONE plain type expression this rule may slice and reprint. False for a
	 * DEPTH-0 comma (a second declarator of the same statement, not a generic argument — see the
	 * class doc), for a `#` (a conditional-compilation splice, whose scope depends on the build),
	 * for a `;` (the region overran its declaration), for a `/` (a comment, which the run walk
	 * would carry into the reprint unexamined), and for unbalanced brackets. A `>` preceded by
	 * `-` is the function-type arrow, not an angle close.
	 */
	private static function isPlainTypeRegion(text: String): Bool {
		var depth: Int = 0;
		for (i in 0...text.length) switch StringTools.fastCodeAt(text, i) {
			case '<'.code | '('.code | '['.code | '{'.code:
				depth++;
			case ')'.code | ']'.code | '}'.code:
				depth--;
			case '>'.code if (i == 0 || StringTools.fastCodeAt(text, i - 1) != '-'.code):
				depth--;
			case ','.code if (depth == 0):
				return false;
			case '#'.code | ';'.code | '/'.code:
				return false;
			case _:
		}
		return depth == 0;
	}

}
