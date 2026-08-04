package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.GroupedEdit;
import anyparse.check.Check.GroupedFix;
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
import anyparse.query.TypeRefPrinter.PrintedTypeRef;
import anyparse.query.TypeResolver;
import anyparse.query.TypeRefPrinter.PendingImportEdit;

/**
 * One written occurrence of a qualified type path: the exact byte range of the path ITSELF
 * (never the construct around it), the path as written, and whether it sits inside a
 * `#if … #end` region.
 */
private typedef Occurrence = {
	var path: String;
	var span: Span;
	var conditional: Bool;
}

/**
 * The verdict for ONE written path in one file: how `TypeRefPrinter` says it should be spelled,
 * the import that spelling needs (null when none), whether the resolution index proves the
 * original names the declaration the reprint denotes, and the occurrences this rule rewrites.
 */
private typedef PathPlan = {
	var path: String;
	var text: String;
	var importPath: Null<String>;
	var proven: Bool;
	var targets: Array<Span>;
}

/**
 * One file's plan: every path verdict, plus the printer that produced them — it carries the
 * pending-import set the add-import arm promised, which is what `fix` materialises.
 */
private typedef FilePlan = {
	var printer: TypeRefPrinter;
	var plans: Array<PathPlan>;
}

/** The immutable inputs the occurrence scan reads, threaded through the recursion. */
private typedef ScanContext = {
	var source: String;
	var shape: RefShape;
	var typeKinds: Array<String>;
	var metaKinds: Array<String>;
	var opaqueKinds: Array<String>;
	var comments: Array<Span>;
	var tree: QueryNode;
}

/**
 * Flags a DOTTED type reference the file itself spells differently — the shared
 * `TypeRefPrinter` decides how the reference SHOULD be written here, and any disagreement is
 * the finding. Three arms, and only the first is a correctness matter:
 *
 * ## ARM 1 — the `pack.SubType` hybrid (why the rule exists)
 *
 * A SECONDARY (sub-module) type has two spellings that both compile:
 * `api.model.folders.FolderContent.FolderContentEntity` — the module-qualified path, which
 * always resolves — and `api.model.folders.FolderContentEntity`, the HYBRID a compiler prints
 * and a hand-written annotation copies. The hybrid resolves ONLY while an
 * `import api.model.folders.FolderContent.FolderContentEntity;` happens to be in the file: drop
 * that import (as an unused-import sweep eventually will, once the short name's last use goes)
 * and the reference stops compiling, at a site that never changed. The fix repairs it to a
 * spelling that stands on its own — the short name when the import is there, the
 * module-qualified path when it is not.
 *
 * ## ARM 2 — plain over-qualification
 *
 * A dotted path written where the short name is ALREADY visible: an exact `import`, an alias,
 * a type declared in this module, the MAIN type of a same-package module, or an always-in-scope
 * builtin. `TypeRefPrinter` owns that judgement, `shadowedLocally` included — so a path kept
 * long BECAUSE the short name is taken (`api.model.folders.FolderContent` in a file whose bare
 * `FolderContent` means `api.namespace.FolderContent`, any name a wildcard / `using` binds, or
 * a name a `#if`-GUARDED import claims for a different path) is left exactly as written. No
 * occurrence threshold: one over-qualified use is one finding.
 *
 * ## ARM 3 — add the import (the printer's route 2)
 *
 * A path with NO short form in scope, written out at least `IMPORT_THRESHOLD` times OUTSIDE
 * `#if`, whose simple name nothing else in the file binds: the fix adds
 * `import <path>;` — placed by `ImportOrder`, so an already-sorted block keeps its sort — and
 * shortens those occurrences.
 *
 * The arm exists because the printer's freeness gate would otherwise close route 2 by
 * construction HERE and only here: the gate refuses an import whose simple name occurs anywhere
 * in the source, and the very text being shortened contains that name as its own last segment.
 * `print`'s `owned` parameter is the exemption — the occurrences of the path ITSELF, which are
 * bound to it by the qualification. Every OTHER occurrence of the simple name in CODE still
 * refuses the import, so a local type declaration, a second import, a type parameter or a
 * `#if`-guarded import of the same name all keep the path long; a mention in INERT text does
 * not, since neither a comment nor a literal TEXT binds anything (`TypeRefPrinter.inertRegions`).
 * Only the TEXT of a literal is inert: a single-quoted Haxe string interpolates, so a name
 * read through one is a reference and keeps the path long.
 *
 * ## What counts as an occurrence
 *
 * The scan runs over the grammar's TYPE-REFS projection (`parseFileTypeRefs`), which is the
 * plain tree plus one node per nominal in a declaration's `:Type` annotation. So every type
 * position is one node with an EXACT span — `is` right-hand sides, `new`, heritage,
 * type-parameter constraints, `from` / `to` clauses, typedef right-hand sides, and local, field,
 * parameter, return, anonymous-field and enum-constructor-parameter annotations alike, each
 * generic component on its own. A static-access chain in expression position
 * (`sys.FileSystem.exists(…)`) is the one shape the grammar spreads over several nodes; the path
 * is rebuilt from it and gated on a lower-initial receiver chain whose root resolves to no value
 * binding.
 *
 * ## Gates — fail closed
 *
 *  - **Same-declaration proof.** A changed reference is only fixed when
 *    `TypeRefPrinter.resolvePath` proves — against the resolution index — which DECLARATION the
 *    ORIGINAL text names. The printed form denotes the printer's canonical path by construction
 *    (that is its contract), and `resolvePath` answers the same canonical path for the original,
 *    so an equal, non-null answer IS "same module + name". No index, or no indexed declaration
 *    at that path, means unproven — the finding stays, the edit does not, and arm 3 is not even
 *    offered (an unproven path never receives the freeness exemption, so it never promises an
 *    import).
 *  - **Conditional compilation.** An occurrence inside a `#if … #end` region is never rewritten
 *    and never counted toward the import threshold: what is in scope there depends on the build,
 *    which neither the import map nor the index models — and the house preference is to keep a
 *    guarded `new haxe.Exception(…)` fully qualified anyway. It IS exempted from the freeness
 *    scan, since it is still the path's own text. The test is the DIRECTIVE, not a node kind —
 *    every conditional region opens with `#if` whichever of the grammar's dozen positional
 *    conditional ctors projects it (`opensConditionalRegion`).
 *  - **Metadata arguments.** Skipped wholesale. `@:access(pkg.Type)` and its siblings are
 *    dot-paths the compiler resolves WITHOUT the file's imports — verified against the compiler,
 *    `@:access(Type)` beside an `import pkg.Type;`, and even from inside `pkg` itself, silently
 *    grants nothing. An expression-position `@:privateAccess pkg.Type.f()` body is ordinary
 *    expression resolution and is NOT skipped.
 *  - **Sub-module access.** A static chain under an upper-initial field access
 *    (`a.b.Module.SubType`) is refused: shortening the module half has resolution semantics this
 *    rule does not model.
 *  - **Reification.** An `opaqueKinds` subtree (a `macro { … }` quotation) is skipped — its
 *    spliced code is not literal source.
 *
 * ## Locating a path the grammar gives no span for
 *
 * Every type-position node's span STARTS at the path, so the rewrite range is its leading `name`
 * bytes. ONE shape breaks that: a `new pkg.T(...)` node's span opens on the `new` keyword and the
 * grammar projects no separate node for the type name, so the path is SEARCHED for inside the
 * span — as a whole path token, and skipping COMMENT regions. The only thing that can sit between
 * `new` and the path is trivia, so a block comment naming the same path would otherwise win the
 * search; and losing that race is not a compile error but a silent one — the COMMENT gets
 * rewritten, the real path stays qualified, the file still compiles, the verifier confirms it, and
 * the next fixpoint pass shortens the real path with the mangled comment left behind.
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
 * ## Default OFF — opt-in
 *
 * A `DefaultOff` marker: dropped from the default set and from a bare `lint … --all` report
 * unless a project opts in via `apqlint.json`
 * (`"rules": { "shorten-type-ref": { "enabled": true } }`), or an explicit
 * `--rule shorten-type-ref` selects it. How qualified a type reference should be is a project
 * style decision; only the hybrid arm is universal, and it is not separable from the print.
 */
@:nullSafety(Strict)
final class ShortenTypeRef implements Check implements DefaultOff implements RiskyFix implements GroupedFix {

	/** The rule's stable identifier — the `apqlint.json` key and the `--rule` selector. */
	private static inline final RULE_ID: String = 'shorten-type-ref';

	/**
	 * How many occurrences OUTSIDE `#if` one path needs before ADDING an import for it is worth
	 * the line. One occurrence is a wash — the import trades a qualified use for an import line
	 * plus a bare name — so the add-import arm starts at the second.
	 */
	private static inline final IMPORT_THRESHOLD: Int = 2;

	/** The finding message when the short name is ALREADY reachable — the rewrite needs no import. */
	private static inline final MSG_FIXABLE: String = 'an over-qualified type reference - the file already spells this type shorter';

	/** The finding message when the rewrite comes WITH a fresh import (the add-import arm). */
	private static inline final MSG_IMPORTABLE: String =
		'a fully-qualified type reference repeated in this file - an import would let it be spelled short';

	/** The finding message when the index could not prove a changed reference names the same declaration. */
	private static inline final MSG_UNPROVEN: String =
		'an over-qualified type reference (report-only: the resolution index does not prove the shorter spelling names the same declaration)';

	public function new() {}

	public function id(): String {
		return RULE_ID;
	}

	public function description(): String {
		return 'a dotted type reference the file already spells shorter, or repeats often enough to import';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final index: Null<SymbolIndex> = RefactorSupport.resolutionIndexOf(plugin);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final plan: Null<FilePlan> = planFor(entry.source, plugin, index);
			if (plan == null) continue;
			for (path in plan.plans) for (target in path.targets) violations.push({
				file: entry.file,
				span: target,
				rule: RULE_ID,
				severity: Severity.Warning,
				message: messageFor(path)
			});
		}
		return violations;
	}

	/**
	 * The flat projection of `fixGrouped` — the `Check.fix` contract, for the callers that never
	 * split an edit set. Grouping is the ONLY thing dropped here, which is the obligation
	 * `GroupedFix` states: the two views can never disagree about WHICH edits a fix produces.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [
			for (edit in fixGrouped(source, violations, plugin, index)) { span: edit.span, text: edit.text }
		];
	}

	/**
	 * Rewrite each proven occurrence and splice the imports the short forms rely on, one atomic
	 * GROUP per import bucket. The decision is RE-DERIVED here rather than carried on the violation —
	 * `run`'s verdict travels only as the message, so a finding the report left unproven yields no edit
	 * even if this call sees a wider index.
	 *
	 * ATOMICITY. An import edit and every use-site rewrite that depends on it form ONE group, so
	 * `FixVerifier`'s bisect keeps or drops them together and can no longer strand an orphan import —
	 * which compiles, so the confirming typecheck would have accepted it. The printer MERGES paths
	 * landing on one anchor offset into a single edit, so the group is the whole BUCKET: every path in
	 * it binds its rewrites to the same unit, and no probe can split two shortenings that share an
	 * import line either.
	 *
	 * The cost is COARSENESS, and how coarse depends on the anchoring `ImportOrder.insertOffset`
	 * picks. Fresh paths that interleave into a sorted import run get distinct offsets and therefore
	 * independent buckets; paths that all sort past the run's end, and every path in a file whose block
	 * is unsorted (the fallback anchors them all after the last import), collapse into ONE bucket — and
	 * then a single failing path drags every import-driven shortening in the file back with it.
	 * Splitting a bucket is not available: `RefactorSupport.applyEdits` gives no defined relative order
	 * to several zero-width edits at one offset, which is exactly why the printer merges them.
	 *
	 * The residual is a caller that hands in a strict SUBSET of the file's findings. The plan — and
	 * with it the promised imports — is re-derived from the whole file, so an import can still be
	 * promised for a path whose rewrites this call was not asked for. It is then applied either alone
	 * in a bucket of its own, or, when it merged with a bucket a wanted path also uses, INSIDE that
	 * path's group, riding along with rewrites it has nothing to do with. No caller does that today
	 * (`FixVerifier` passes the whole rule-filtered set for the file), and nothing here can detect it.
	 */
	public function fixGrouped(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<GroupedEdit> {
		final wanted: Array<String> = [];
		for (violation in violations) {
			final span: Null<Span> = violation.span;
			if (span != null && violation.message != MSG_UNPROVEN) wanted.push(spanKey(span));
		}
		if (wanted.length == 0) return [];
		// The resolution index (report UNION libraries) is the wider proof. The `?? index` fallback
		// is defensive only: through `run` a null resolution index makes EVERY finding unproven, so
		// the empty `wanted` has already returned above — it exists for a caller that hands in
		// violations it built itself.
		final scope: Null<SymbolIndex> = RefactorSupport.resolutionIndexOf(plugin) ?? index;
		final plan: Null<FilePlan> = planFor(source, plugin, scope);
		if (plan == null) return [];
		// One bucket can serve SEVERAL paths (the printer merges imports landing on one anchor), so
		// the group is the bucket and every path in it binds its own rewrites to that same unit.
		final importEdits: Array<PendingImportEdit> = plan.printer.pendingImportEdits();
		final byPath: Map<String, Int> = [];
		for (group => importEdit in importEdits) for (importPath in importEdit.paths) byPath[importPath] = group;
		final edits: Array<GroupedEdit> = [
			for (path in plan.plans) if (path.proven) for (target in path.targets) if (wanted.contains(spanKey(target)))
				{ span: target, text: path.text, group: groupOf(byPath, path.importPath) }
		];
		if (edits.length == 0) return edits;
		// The PLANNING printer's pending set is already exactly right: `print` is handed the
		// freeness exemption only for a path that cleared both the threshold and the index proof,
		// and such a path always comes back with a changed spelling, so every promised import
		// belongs to a plan that contributed edits above.
		for (group => importEdit in importEdits) edits.push({ span: importEdit.span, text: importEdit.text, group: group });
		return edits;
	}

	/**
	 * The atomic group a use-site rewrite joins: the bucket of the import edit its short spelling
	 * needs, or null when the spelling needs no import and the rewrite stands alone. The map-miss arm
	 * is unreachable for a `planFor` plan — a non-null `importPath` is by construction the canonical
	 * `print` pushed onto the printer's pending set, and every pending path lands in some bucket — so
	 * it exists only for a caller that builds a plan itself, and it degrades to the pre-grouping
	 * per-edit behaviour rather than to anything less safe.
	 */
	private static inline function groupOf(byPath: Map<String, Int>, importPath: Null<String>): Null<Int> {
		return importPath == null ? null : byPath[importPath];
	}

	/** Which of the three messages `plan` earns — unproven first, then the import-free arm, then the add-import one. */
	private static function messageFor(plan: PathPlan): String {
		return if (!plan.proven)
			MSG_UNPROVEN;
		else if (plan.importPath == null)
			MSG_FIXABLE;
		else
			MSG_IMPORTABLE;
	}

	/**
	 * One file's verdicts: every qualified type path it writes, grouped, each carrying the
	 * printer's answer for it. Null when the file does not parse.
	 *
	 * ONE printer serves the whole file (its per-file state is the resolution input, so a second
	 * instance would answer the same), and its pending-import set is authoritative for the plan:
	 * `print` is handed the freeness exemption ONLY for a path that has already cleared the
	 * threshold and the index proof, so a promised import always belongs to a plan this rule will
	 * act on.
	 */
	private static function planFor(source: String, plugin: GrammarPlugin, index: Null<SymbolIndex>): Null<FilePlan> {
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		// The type-refs projection is the same tree PLUS one `TypeRef` node per nominal in a
		// declaration's `:Type` annotation — the positions the default projection drops. It is what
		// makes field / parameter / return annotations reachable with an exact span instead of the
		// three per-shape textual searches an annotation region slice would need.
		final refsTree: Null<QueryNode> = CheckScan.parseTypeRefsOrNull(plugin, source);
		if (tree == null || refsTree == null) return null;
		// Re-bind: a null-check does not narrow into an anonymous-structure literal.
		final scoped: QueryNode = tree;
		final shape: RefShape = plugin.refShape();
		final context: ScanContext = {
			source: source,
			shape: shape,
			typeKinds: plugin.typeRefShape().typeRefKinds,
			metaKinds: plugin.metaShape().metaKinds,
			opaqueKinds: shape.opaqueKinds ?? [],
			comments: RefactorSupport.collectCommentRegions(source),
			tree: scoped
		};
		final occurrences: Array<Occurrence> = [];
		scan(refsTree, context, false, false, occurrences);
		final printer: TypeRefPrinter = printerFor(source, scoped, plugin, index);
		final plans: Array<PathPlan> = [];
		for (path in distinctPaths(occurrences)) {
			final targets: Array<Span> = [for (o in occurrences) if (o.path == path && !o.conditional) o.span];
			if (targets.length == 0) continue;
			final proven: Bool = printer.resolvePath(path) != null;
			final importable: Bool = proven && targets.length >= IMPORT_THRESHOLD;
			final owned: Null<Array<Span>> = importable ? [for (o in occurrences) if (o.path == path) o.span] : null;
			final printed: PrintedTypeRef = printer.print(path, owned);
			if (printed.text == path) continue;
			plans.push({
				path: path,
				text: printed.text,
				importPath: printed.importPath,
				proven: proven,
				targets: targets
			});
		}
		return { printer: printer, plans: plans };
	}

	/** A printer over `source` with the file's plain-import map and the run's resolution index. */
	private static function printerFor(source: String, tree: QueryNode, plugin: GrammarPlugin, index: Null<SymbolIndex>): TypeRefPrinter {
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		return TypeRefPrinter.forFile(source, tree, provider != null ? provider.importMap(source) : [], index);
	}

	/** The written paths of `occurrences`, deduplicated, in first-seen order — the plan's iteration order. */
	private static function distinctPaths(occurrences: Array<Occurrence>): Array<String> {
		final out: Array<String> = [];
		for (occurrence in occurrences) if (!out.contains(occurrence.path)) out.push(occurrence.path);
		return out;
	}

	/**
	 * Visit every node of `node`'s subtree, collecting each qualified type-path occurrence. Three
	 * subtrees are skipped WHOLESALE:
	 *
	 *  - a reification (`opaqueKinds`), whose spliced code is not literal source;
	 *  - a metadata annotation's arguments (`metaShape().metaKinds` — `MetaCall` carries them as
	 *    its children). `@:access(pkg.Type)` and its siblings are dot-paths the compiler resolves
	 *    WITHOUT the file's imports: verified against the compiler, `@:access(Type)` beside an
	 *    `import pkg.Type;` — and even from inside `pkg` itself — silently grants nothing, and the
	 *    build then fails at the private access the annotation was written for. `MetaExpr` is not
	 *    one of these kinds, so a `@:privateAccess pkg.Type.f()` body, which IS ordinary expression
	 *    resolution, keeps being scanned.
	 *
	 * A `#if … #end` region is NOT skipped — it is FLAGGED. Its occurrences are exempted from the
	 * printer's short-name freeness scan (they are still the path's own text) but never rewritten
	 * and never counted toward the import threshold, since what is in scope inside a region
	 * depends on the build, which neither the import map nor the index models.
	 */
	private static function scan(
		node: QueryNode, context: ScanContext, conditional: Bool, underUpperField: Bool, out: Array<Occurrence>
	): Void {
		if (context.opaqueKinds.contains(node.kind) || context.metaKinds.contains(node.kind)) return;
		final region: Bool = conditional || CheckScan.opensConditionalRegion(node, context.source, context.shape.conditionalIfKeyword);
		final found: Null<Occurrence> = occurrenceOf(node, context, region, underUpperField);
		if (found != null) out.push(found);
		final upperReceiver: Bool = node.kind == context.shape.fieldAccessKind && RefactorSupport.isUpperInitial(node.name ?? '');
		for (c in node.children) scan(c, context, region, upperReceiver, out);
	}

	/**
	 * The occurrence `node` itself is, or null when it is not one. Two shapes reach here:
	 *
	 *  - a TYPE-POSITION node (`typeRefShape().typeRefKinds`), whose `name` slot already holds the
	 *    whole dotted path — an `is` right-hand side, a return type, heritage, a type-parameter
	 *    constraint, a `new`, and (through the type-refs projection) every `:Type` annotation;
	 *  - a static-access CHAIN in expression position (`pkg.sub.Type.member`), which the grammar
	 *    projects as nested field accesses rather than one node, so the path is rebuilt from it.
	 *
	 * `underUpperField` refuses the second shape under an upper-initial field access — the
	 * `a.b.Module.SubType` sub-module access, whose short form has resolution semantics this rule
	 * does not model.
	 */
	private static function occurrenceOf(
		node: QueryNode, context: ScanContext, conditional: Bool, underUpperField: Bool
	): Null<Occurrence> {
		final name: Null<String> = node.name;
		if (name == null) return null;
		if (context.typeKinds.contains(node.kind)) {
			if (name.indexOf('.') == -1 || !RefactorSupport.isUpperInitial(RefactorSupport.lastSegment(name))) return null;
			final span: Null<Span> = pathSpanOf(node, name, context);
			return span == null ? null : { path: name, span: span, conditional: conditional };
		}
		if (node.kind != context.shape.fieldAccessKind || underUpperField || !RefactorSupport.isUpperInitial(name)) return null;
		final path: Null<String> = staticChainPath(node, context);
		final span: Null<Span> = node.span;
		if (path == null || span == null) return null;
		// The chain's own span must BE the path verbatim. A chain broken by a comment or a newline
		// is refused rather than sliced: the rewrite replaces the whole span with the short name.
		return context.source.substring(span.from, span.to) == path ? {
			path: path,
			span: span,
			conditional: conditional
		} : null;
	}

	/**
	 * The exact byte range of the PATH inside `node`. A type-position node's span STARTS at the
	 * path (a generic head's span runs on past it, to the closing `>`), so the leading `name`
	 * bytes are the answer. A `new pkg.T(...)` node's span opens on the `new` keyword and closes
	 * after the argument list instead, so the path is located inside it — as a whole token, since
	 * a bare `indexOf` would also match a longer path's tail.
	 */
	private static function pathSpanOf(node: QueryNode, name: String, context: ScanContext): Null<Span> {
		final span: Null<Span> = node.span;
		if (span == null) return null;
		if (span.from + name.length <= span.to && context.source.substring(span.from, span.from + name.length) == name)
			return new Span(span.from, span.from + name.length);
		final at: Int = tokenOffset(context, name, span.from, span.to);
		return at < 0 ? null : new Span(at, at + name.length);
	}

	/**
	 * The dotted path a static-access chain rooted at `node` spells (`sys.FileSystem` for the
	 * `FileSystem` field access of `sys.FileSystem.exists(...)`), or null when the chain is not
	 * one. Every segment BELOW the type must be lower-initial — Haxe package names are — and the
	 * root must be a bare identifier that resolves to NO value binding: a receiver that resolves
	 * to a local, parameter or field is a value, so `holder.Member` is an instance field access
	 * that merely looks like a package path.
	 */
	private static function staticChainPath(node: QueryNode, context: ScanContext): Null<String> {
		final identKind: Null<String> = context.shape.identKind;
		if (identKind == null) return null;
		final segments: Array<String> = [node.name ?? ''];
		var cursor: QueryNode = node;
		while (cursor.children.length == 1) {
			final child: QueryNode = cursor.children[0];
			final name: Null<String> = child.name;
			if (name == null || name == '' || RefactorSupport.isUpperInitial(name)) return null;
			segments.unshift(name);
			if (child.kind == identKind) {
				final span: Null<Span> = child.span;
				if (span == null || TypeResolver.resolveBindingFrom(name, span, context.tree, context.shape) != null) return null;
				return segments.join('.');
			}
			if (child.kind != context.shape.fieldAccessKind) return null;
			cursor = child;
		}
		return null;
	}

	/**
	 * The offset of `token` inside `source[from...to)` as a whole PATH token in CODE — neither
	 * neighbour an identifier character or a `.`, so the tail of a longer dotted path never matches,
	 * and never inside a comment — or -1 when it does not occur.
	 *
	 * The comment mask is the whole point. The only caller is the `new pkg.T(...)` shape, whose node
	 * span opens on the `new` keyword, and the only thing that can sit between that keyword and the
	 * path is trivia — so a BLOCK COMMENT naming the same path is a first-match trap: the rewrite then
	 * lands in the COMMENT and leaves the real path qualified. That output COMPILES, so the `RiskyFix`
	 * verifier confirms it rather than reverting, and the next fixpoint pass shortens the real path
	 * with the mangled comment left behind.
	 */
	private static function tokenOffset(context: ScanContext, token: String, from: Int, to: Int): Int {
		final source: String = context.source;
		var i: Int = from;
		while (i + token.length <= to) {
			final at: Int = source.indexOf(token, i);
			if (at < 0 || at + token.length > to) return -1;
			final after: Int = at + token.length;
			final boundedLeft: Bool = at == 0 || !isPathChar(StringTools.fastCodeAt(source, at - 1));
			final boundedRight: Bool = after >= source.length || !isPathChar(StringTools.fastCodeAt(source, after));
			if (boundedLeft && boundedRight && !RefactorSupport.offsetWithinAny(at, context.comments)) return at;
			i = at + 1;
		}
		return -1;
	}

	/** Whether `c` can sit INSIDE a dotted type path — an identifier character or the separator itself. */
	private static inline function isPathChar(c: Int): Bool {
		return c == '.'.code || RefactorSupport.isIdentChar(c);
	}

	/** A span as the key `fix` matches a re-derived occurrence against the violation it was reported as. */
	private static inline function spanKey(span: Span): String {
		return '${span.from}:${span.to}';
	}

}
