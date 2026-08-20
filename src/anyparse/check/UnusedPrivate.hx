package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.NamingPolicy.NamedDecl;
import anyparse.query.NamingPolicy.NamingCategory;
import anyparse.query.NamingPolicy.NamingSupport;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.StringLiteral;
import anyparse.query.SymbolIndex;
import anyparse.query.SymbolIndexHost;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * Flags `private` class members (fields / methods) that are never referenced —
 * dead members the formatter cannot remove. The completion of the unused-*
 * family (import -> local -> private member) and the second consumer of the
 * cross-file `SymbolIndex`.
 *
 * ## Confinement is occurrence-based, not structure-based
 *
 * A Haxe `private` member is reachable only from its own class — UNLESS a
 * subtype, an `@:access` grant, or an `@:allow` exposes it across files, or a
 * file the parser skipped hides one of those. When
 * `RefactorSupport.isPrivateMemberConfined` proves none of those apply, the
 * member's only possible references live in its declaring file, so a raw
 * word-boundary scan of that file outside the declaration
 * (`RefactorSupport.referencedInRange`) is a complete usage test.
 *
 * When the type is NOT structurally confined, the member is still flagged if the
 * STRONGER cross-file proof holds (a project-owner decision): a raw word-boundary
 * scan over EVERY file in report UNION resolution scope finds ZERO occurrences of
 * the name outside its own declaration (`provablyDeadProjectWide`). A subtype /
 * `@:access` grantee / `@:allow`ed type can only reach the member by NAMING it, so
 * a name that appears nowhere is dead regardless of structure. The one arm that
 * stays coarse is skip-parse: a skip-parsed report file could hide a reference the
 * scan cannot see, so any skip-parse in report scope keeps structural confinement.
 *
 * ## Implicitly-reachable members are skipped
 *
 * Constructors, property accessors (`get_` / `set_`, reached via `(get, set)`,
 * not by name), and annotation-bearing members (`@:keep`, abstract `@:from` /
 * `@:op`, ...) can be used without an in-source identifier reference. The
 * grammar marks these via `NamedDecl.implicitlyReachable`; the check never flags
 * them — a missed dead member, never a deleted live one. Members reachable only through a framework or macro across files are skipped too: a `static final` macro-force field (`= SomeType`, via `implicitlyReachable`), and a utest `test*` method whose class transitively extends `Test` (via `NamingSupport.frameworkReachable`, resolved through the cross-file index).
 *
 * ## Members that are public despite no `public` keyword
 *
 * Three shapes carry no visibility keyword yet are not private, so they are exempt
 * from the reference scan (`violationFor`): an `override` member inherits the
 * base's visibility and is invoked polymorphically from unseen code; an
 * `extern class` member is PUBLIC by the extern rule and reached from outside
 * the file (`collectExternTypes` names its enclosing type); an `abstract` member is a contract implemented by
 * subclasses, reachable through every implementor.
 *
 * ## Autofix
 *
 * Deletion is CONSERVATIVE: the report stays broad (a member is flagged as soon as
 * it is unreferenced and confined), but `fix` removes one only when every doubt is
 * ruled out, so it never breaks another platform's build. A member is deleted only
 * when its initializer is side-effect-free (a body-bearing method always qualifies, a body-less declaration never —
 * `RefactorSupport.isSideEffectFree`), it is not an abstract-method impl of an
 * `extends` class (`mayImplementAbstractMethod`: Haxe impls carry no `override` and
 * the base's call is invisible to a single-file scan), its enclosing type carries no
 * `@:rtti` (drill-Node serialization by field name), `@:keep`, or `@:build`, and its
 * name appears in no string literal in scope (a possible `Reflect.field` target).
 *
 * Conditional compilation (`#if` / `#elseif` / `#else`) refines the reference scan
 * rather than vetoing the file wholesale: a member in a `#if`-carrying file is deleted
 * only when a raw word-boundary scan over EVERY file in report UNION resolution scope
 * finds ZERO occurrences of its name outside its own declaration (`referencedElsewhere`)
 * — raw text sees inside `#if` regions and comments, so zero hits proves it unreferenced
 * in every branch; any occurrence keeps the whole-file veto in force. A separate arm
 * deletes a `private function new() {}` that `run` proved never instantiated (the
 * static-utility idiom), keeping the coarse whole-file `#if` veto (no-`#if` / no-`@:build`
 * gates). The member is removed with its modifier / meta group and whole line, batched
 * per file by the caller.
 */
@:nullSafety(Strict)
final class UnusedPrivate implements Check {

	/**
	 * Cross-file string-literal contents gathered by the last `run`, consulted by
	 * `fix`'s reflection gate. Null until `run` populates it; `fix` then falls back
	 * to the single file it is handed.
	 */
	private var _reflectedContents: Null<Array<String>> = null;

	public function new() {}

	public function id(): String {
		return 'unused-private';
	}

	public function description(): String {
		return 'private field/method declared but never referenced';
	}

	/**
	 * Report every unused private member (the `violationFor` reference test — an in-file
	 * scan for a confined type, else the report-UNION-resolution zero-occurrence proof)
	 * plus a deletable private empty constructor: a `private function new() {}` in a
	 * never-instantiated all-static utility class (no structural `new C`, no reflection
	 * mention of the class name, no `@:build`, no subtype). The
	 * cross-file string-literal contents gathered here are stashed for `fix`'s
	 * reflection gate.
	 */
	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final support: Null<NamingSupport> = plugin.namingSupport();
		if (support == null) return [];
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final scopeIndex: SymbolIndex = widestScopeIndex(plugin, index) ?? index;
		final stringFold: Null<StringFoldSupport> = plugin.stringFoldSupport();
		final reflected: Array<String> = [];
		final violations: Array<Violation> = [];
		final ctorCandidates: Array<{ file: String, className: String, span: Span }> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			if (stringFold != null) collectStringContents(tree, entry.source, stringFold, reflected);
			final externTypes: Array<String> = [];
			collectExternTypes(tree, externTypes);
			for (decl in support.project(tree)) {
				final v: Null<Violation> = violationFor(entry.file, entry.source, decl, index, scopeIndex, support, externTypes);
				if (v != null) violations.push(v);
			}
			collectCtorCandidates(tree, entry.file, ctorCandidates);
		}
		_reflectedContents = reflected;
		if (index.skippedFiles().length == 0) for (c in ctorCandidates) if (
			!index.hasSubtype(c.className) && !isInstantiatedAnywhere(c.className, files) && !mentionedInStrings(c.className, reflected)
		) violations.push({
			file: c.file,
			span: c.span,
			rule: 'unused-private',
			severity: Severity.Warning,
			message: 'unused private constructor \'new\' of never-instantiated \'${c.className}\''
		});
		return violations;
	}

	/**
	 * Delete the auto-fixable subset of `violations` under conservative gates: a
	 * doubtful case stays report-only, so `--fix` never breaks another platform's
	 * build. A flagged MEMBER is removed only when its initializer is side-effect-free (a body-bearing method always
	 * qualifies, a body-less declaration never), it is not an abstract-method impl of an `extends`
	 * class (`mayImplementAbstractMethod`), its enclosing type carries no `@:rtti`
	 * (drill-Node field-name serialization, via the index), `@:keep`, or `@:build`, and
	 * its name appears in no string literal in scope (a possible `Reflect.field` target).
	 *
	 * Conditional compilation refines rather than vetoes wholesale: a file carrying ANY
	 * `#if` makes the single-file reference scan branch-blind, so a MEMBER in such a file
	 * is deleted only when the raw word-boundary scan over EVERY file in report UNION
	 * resolution scope finds ZERO occurrences of its name outside its own declaration
	 * (`referencedElsewhere` over `widestScopeIndex`) — raw text sees inside `#if` regions
	 * and comments, so zero hits proves it unreferenced in every branch. When an occurrence
	 * exists (code under a `#if` arm, or a comment mention) the whole-file veto stands and
	 * the member is kept. The private empty constructor arm keeps the coarse whole-file
	 * `#if` veto (deleted only under no-`#if` / no-`@:build`). Each removal folds in the
	 * member's modifier / meta group and whole line; the caller batches them into one
	 * canonicalize per file.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return edits;
		final hasConditional: Bool = fileHasConditional(source);
		final scopeIndex: Null<SymbolIndex> = widestScopeIndex(plugin, index);

		final memberByFrom: Map<Int, { node: QueryNode, parent: QueryNode, inExtends: Bool }> = [];
		collectMembers(tree, false, memberByFrom);
		final classMeta: Map<String, { hasBuild: Bool, hasKeep: Bool }> = [];
		collectClassMeta(tree, classMeta);
		final reflected: Array<String> = _reflectedContents ?? inFileStringContents(source, plugin);

		for (v in violations) if (v.severity == Severity.Warning) {
			final span: Null<Span> = v.span;
			if (span == null) continue;
			final hit: Null<{ node: QueryNode, parent: QueryNode, inExtends: Bool }> = memberByFrom[span.from];
			if (hit == null) continue;
			final node: QueryNode = hit.node;
			final owner: Null<String> = hit.parent.name;
			if (isPrivateEmptyCtor(node)) {
				if (hasConditional) continue;
				final ctorMeta: Null<{ hasBuild: Bool, hasKeep: Bool }> = owner == null ? null : classMeta[owner];
				if (ctorMeta == null || !ctorMeta.hasBuild) edits.push(CheckScan.deletionEdit(source, node, hit.parent, span));
				continue;
			}
			if (hasConditional && referencedElsewhere(node.name, v.file, span, scopeIndex, source)) continue;
			if (memberDeletable(node, owner, hit.inExtends, index, classMeta, reflected))
				edits.push(CheckScan.deletionEdit(source, node, hit.parent, span));
		}
		return edits;
	}

	/**
	 * Whether `node` is a class body whose direct children carry the members and any
	 * `extends` clause — `CheckScan.isClassBodyKind`: a plain, `final` / modified, or `abstract class`.
	 */
	private static inline function isClassScopeNode(kind: String): Bool {
		return CheckScan.isClassBodyKind(kind);
	}

	/**
	 * Raw-text presence of ANY conditional-compilation directive. In a file carrying one
	 * the single-file reference scan is branch-blind, so a member used only under a `#if`
	 * arm (and members declared inside one) would read as unused. A flagged MEMBER survives
	 * this only via the report-UNION-resolution zero-occurrence proof (`referencedElsewhere`);
	 * the empty-constructor arm keeps the coarse whole-file veto.
	 */
	private static inline function fileHasConditional(source: String): Bool {
		return source.indexOf('#if') >= 0 || source.indexOf('#else') >= 0 || source.indexOf('#elseif') >= 0;
	}

	/** Space / tab / newline / carriage-return. */
	private static inline function isWhitespace(c: Int): Bool {
		return c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code;
	}

	/**
	 * The widest source scope available for the zero-occurrence proof: the host's resolution-scoped
	 * index (report UNION the DECLARED library roots) when `plugin` is a `SymbolIndexHost` carrying a
	 * declared scope, else the report-scoped `index` the caller passed, else null (a direct `fix` call
	 * with no index — the caller falls back to the single file it was handed).
	 *
	 * Deliberately gated on `hasDeclaredResolutionScope`, NOT on `hasAnyResolutionScope` the way
	 * `RefactorSupport.lazySymbolIndex` is. The proof this index feeds is `referencedElsewhere`, a
	 * TEXTUAL occurrence scan used to lift a `#if`-carrying file's whole-file veto — and a private
	 * member of this project can never legitimately be referenced from the Haxe std. Admitting the
	 * implicit std scope would therefore add only false positives: a private member named `write` or
	 * `get` occurs all over std, the veto stands, and `unused-private --fix` silently stops deleting
	 * it. Conservative either way (more occurrences means fewer deletions, never a wrong one), so the
	 * cost is usefulness rather than correctness — which is exactly why it must not happen by
	 * accident. A DECLARED library is a different matter: the project chose it, and a file the run
	 * does not lint can legitimately be where the reference lives.
	 */
	private static function widestScopeIndex(plugin: GrammarPlugin, index: Null<SymbolIndex>): Null<SymbolIndex> {
		final host: Null<SymbolIndexHost> = plugin is SymbolIndexHost ? cast plugin : null;
		if (host != null && host.hasDeclaredResolutionScope()) {
			final res: Null<SymbolIndex> = host.resolutionIndex();
			if (res != null) return res;
		}
		return index;
	}

	/**
	 * Whether `name` is referenced anywhere in scope outside its own declaration `span` —
	 * the gate that decides if a `#if`-carrying file's whole-file veto can be lifted. Scans
	 * every file in `scopeIndex` (report UNION resolution) when present, excluding the
	 * member's own declaration in its own `file`; falls back to the single `source` the
	 * caller was handed when no index is available (a direct `fix` call). A null `name` has
	 * nothing to prove absent, so the veto stands (`true`). Conservative: any occurrence —
	 * code under a `#if` arm, a comment or string mention — keeps the member.
	 */
	private static function referencedElsewhere(
		name: Null<String>, file: String, span: Span, scopeIndex: Null<SymbolIndex>, source: String
	): Bool {
		if (name == null) return true;
		return scopeIndex != null
			? scopeIndex.nameOccursOutside(name, file, span)
			: RefactorSupport.referencedInRange(source, name, 0, source.length, [span]);
	}

	/**
	 * A `Warning` for `decl` if it is an unreferenced, non-implicitly-reachable private
	 * member, else null. Skips public members, non-members (types / locals / params),
	 * implicitly-reachable members.
	 *
	 * The usage test is OCCURRENCE-based, not structure-based (a project-owner decision):
	 * a subtype, an `@:access` grant, or an `@:allow` could in principle reach a private
	 * member across files, but only if it actually NAMES it — so the coarse structural
	 * confinement gate is lifted whenever the STRONGER cross-file proof holds. When the
	 * enclosing type is index-confined (`isPrivateMemberConfined`) an in-file reference
	 * scan is a complete usage test; otherwise the member is flagged only when a raw
	 * word-boundary scan over EVERY file in report UNION resolution finds ZERO occurrences
	 * of the name outside its own declaration (`provablyDeadProjectWide`) — an unreferenced
	 * name cannot be referenced by a subtype / grantee / allowed type either. That path
	 * RETAINS the skip-parse veto (a skip-parsed report file could hide a reference the
	 * scan cannot see, so any skip-parse in report scope keeps structural confinement).
	 *
	 * Three visibility carve-outs never reach the reference scan: an `abstract` member is a
	 * contract implemented by subclasses, reachable through every implementor; an `override`
	 * member inherits the base's visibility (not private) and is invoked polymorphically from
	 * code a single-file scan cannot see; an `extern class` member carries no visibility
	 * keyword yet is PUBLIC by the extern rule, and is reached from outside the file
	 * (`externTypes` names its enclosing type).
	 *
	 * A FOURTH carve-out cannot be read off the modifiers at all: the IMPLEMENTATION of an abstract
	 * member carries neither keyword, because Haxe rejects `override` on one. It is recognised by asking
	 * the widest index whether a supertype declares the name — the question `prefer-inline` already asks
	 * for the same reason.
	 */
	private static function violationFor(
		file: String, source: String, decl: NamedDecl, index: SymbolIndex, scopeIndex: SymbolIndex, support: NamingSupport,
		externTypes: Array<String>
	): Null<Violation> {
		final category: NamingCategory = decl.category;
		if (category != NamingCategory.Field && category != NamingCategory.Method && category != NamingCategory.Constant) return null;
		// An `abstract` member is a contract implemented by subclasses — reachable
		// through every implementor, so never dead from the declaring class alone.
		if (
			decl.mods.contains('public') || decl.mods.contains('override') || decl.mods.contains('abstract')
			|| decl.implicitlyReachable == true || support.frameworkReachable(decl, index)
		)
			return null;
		final owner: Null<String> = decl.enclosingType;
		final span: Null<Span> = decl.span;
		if (owner == null || span == null || externTypes.contains(owner)) return null;
		// An IMPLEMENTATION of an abstract supertype member carries neither `abstract` nor
		// `override` — Haxe rejects `override` on one — so the modifier carve-outs above miss it
		// while the base invokes it polymorphically through its own declaration. Asked of the
		// WIDEST index, because the declaring base may live in a resolution library rather than
		// the report scope. An unresolvable supertype leaves the member flaggable, as before.
		if (scopeIndex.supertypeDeclaresMember(owner, decl.name)) return null;
		final unused: Bool = RefactorSupport.isPrivateMemberConfined(owner, source, index)
			? !RefactorSupport.referencedInRange(source, decl.name, 0, source.length, [span])
			: provablyDeadProjectWide(decl.name, file, source, span, index, scopeIndex);
		return unused ? {
			file: file,
			span: span,
			rule: 'unused-private',
			severity: Severity.Warning,
			message: 'unused private \'${decl.name}\''
		} : null;
	}

	/**
	 * The unconfined-member usage test: whether `name` is provably dead across the whole
	 * project — zero word-boundary occurrences outside its own declaration `span` in EVERY
	 * file of report UNION resolution scope. A private member is reachable only from its own
	 * class or a subtype / `@:access` grantee / `@:allow`ed type; if the raw scan (which sees
	 * inside `#if` regions and comments) finds the name nowhere but its declaration, none of
	 * those name it. The report index must be fully parsed (`skippedFiles == 0`) — a
	 * skip-parsed report file could hide the reference, so any skip in report scope keeps the
	 * structural confinement gate. A cheap own-file pre-scan short-circuits the common
	 * referenced case before the cross-file walk; the library scan runs only for a name
	 * already unique in report scope.
	 */
	private static function provablyDeadProjectWide(
		name: String, file: String, source: String, span: Span, index: SymbolIndex, scopeIndex: SymbolIndex
	): Bool {
		return index.skippedFiles().length == 0 && !RefactorSupport.referencedInRange(source, name, 0, source.length, [span])
			&& !index.nameOccursOutside(name, file, span) && (scopeIndex == index || !scopeIndex.nameOccursOutside(name, file, span));
	}

	/**
	 * Whether removing `member`'s declaration drops no behaviour: a body-bearing
	 * method never executes at its site (deletable); a body-less declaration is a
	 * contract whose implementation lives elsewhere (never deletable); a field is
	 * deletable only when it has no initializer or a side-effect-free one (its
	 * first child is the initializer expression).
	 */
	private static function deletableMember(member: QueryNode): Bool {
		// A body-less declaration has no dead code to remove — its implementation
		// lives elsewhere (an `extern`'s in native code; an `abstract`'s in
		// subclasses, though those are already exempt in `violationFor`).
		for (c in member.children) if (c.kind == 'NoBody') return false;
		if (member.kind != 'VarMember' && member.kind != 'FinalMember') return true;
		final init: Null<QueryNode> = member.children.length > 0 ? member.children[0] : null;
		return init == null || RefactorSupport.isSideEffectFree(init);
	}

	/**
	 * Whether `member` might implement an abstract method of a base class — a method
	 * (`FnMember` / `FinalModifiedMember`) that is lexically inside a class carrying
	 * an `extends` clause (`inExtendsClass`, threaded through `#if` wrappers by
	 * `collectMembers`). A Haxe abstract-method impl carries no `override` keyword
	 * (so `violationFor`'s override carve-out does not catch it) and the base's call
	 * is invisible to a single-file scan, so `--fix` must NOT auto-delete it: the
	 * finding is still reported, but the declaration is kept. Conservative — every
	 * method of a subclass is spared, since a single file cannot see which one the
	 * base declares abstract, whether or not the base is in the linted file set.
	 */
	private static function mayImplementAbstractMethod(member: QueryNode, inExtendsClass: Bool): Bool {
		if (member.kind != 'FnMember' && member.kind != 'FinalModifiedMember') return false;
		return inExtendsClass;
	}

	/**
	 * Whether a class-scope `node` carries an `extends` clause among its direct
	 * children (`(ClassForm C (ExtendsClause …) …)`).
	 */
	private static function classDeclaresExtends(node: QueryNode): Bool {
		return node.children.exists(child -> child.kind == 'ExtendsClause');
	}

	/**
	 * Index every field / method member node by its span's `from` offset, each with
	 * its direct parent (the context `declGroupSpan` needs to fold the member's
	 * modifier / meta siblings) and whether it is lexically inside a class carrying
	 * an `extends` clause. The extends flag is threaded top-down through transparent
	 * wrappers: a member-level `#if … #end` region projects its members as children
	 * of a `Conditional` node, so the enclosing class's `ExtendsClause` is a sibling
	 * of that wrapper, NOT of the member — only a class-scope node
	 * (`isClassScopeNode`) recomputes the flag from its own `extends` clause.
	 */
	private static function collectMembers(
		node: QueryNode, inExtends: Bool, out: Map<Int, { node: QueryNode, parent: QueryNode, inExtends: Bool }>
	): Void {
		final childExtends: Bool = isClassScopeNode(node.kind) ? classDeclaresExtends(node) : inExtends;
		for (child in node.children) {
			if (RefactorSupport.isFieldMemberKind(child.kind)) {
				final span: Null<Span> = child.span;
				if (span != null) out[span.from] = { node: child, parent: node, inExtends: childExtends };
			}
			if (RefactorSupport.descendsToMemberHost(node.kind, child.kind)) collectMembers(child, childExtends, out);
		}
	}

	/**
	 * Collect the simple names of every `extern class` in `node`'s subtree. The
	 * `extern` keyword projects as a modifier sibling (`Extern`) preceding the
	 * class decl (`(Extern) (ClassDecl C …)`), possibly after `Private` / `@:meta`
	 * siblings, so the run of preceding modifier / meta siblings is scanned for it.
	 * An extern member has no visibility keyword yet is PUBLIC, so its enclosing
	 * type must be exempt from the private-member reference scan.
	 */
	private static function collectExternTypes(node: QueryNode, out: Array<String>): Void {
		final siblings: Array<QueryNode> = node.children;
		for (i in 0...siblings.length) {
			final child: QueryNode = siblings[i];
			final name: Null<String> = child.name;
			if (name != null && isClassScopeNode(child.kind) && precededByExtern(siblings, i)) out.push(name);
			collectExternTypes(child, out);
		}
	}

	/**
	 * Whether an `Extern` modifier sibling precedes the child at `index` — scanning
	 * back over the contiguous run of modifier / meta siblings (`Private` / `Extern`
	 * / `@:meta`) that a class decl may carry, stopping at the first non-modifier.
	 */
	private static function precededByExtern(siblings: Array<QueryNode>, index: Int): Bool {
		var i: Int = index - 1;
		while (i >= 0) {
			final kind: String = siblings[i].kind;
			if (kind == 'Extern') return true;
			if (kind != 'Private' && kind != 'Meta' && kind != 'MetaCall') return false;
			i--;
		}
		return false;
	}

	/**
	 * Whether `node` is the private empty constructor `private function new() {}` — a
	 * `FnMember` named `new` with no parameters and an empty block body. Such a member
	 * is only ever a violation via the constructor arm (`run` skips it for the member
	 * scan), so a `new` finding in `fix` routes here.
	 */
	private static function isPrivateEmptyCtor(node: QueryNode): Bool {
		return node.kind == 'FnMember' && node.name == 'new' && isEmptyCtorBody(node);
	}

	/** Whether a `FnMember`'s only child is an empty block body (no params, no statements). */
	private static function isEmptyCtorBody(node: QueryNode): Bool {
		return node.children.length == 1 && node.children[0].kind == 'BlockBody' && node.children[0].children.length == 0;
	}

	/** Collect every plain string-literal's raw content in `node`'s subtree into `out`. */
	private static function collectStringContents(
		node: QueryNode, source: String, stringFold: StringFoldSupport, out: Array<String>
	): Void {
		final lit: Null<StringLiteral> = stringFold.literalOf(node, source);
		if (lit != null) out.push(lit.content);
		for (child in node.children) collectStringContents(child, source, stringFold, out);
	}

	/** The single-file string-literal contents — `fix`'s fallback when `run` left no cross-file stash. */
	private static function inFileStringContents(source: String, plugin: GrammarPlugin): Array<String> {
		final stringFold: Null<StringFoldSupport> = plugin.stringFoldSupport();
		if (stringFold == null) return [];
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		final out: Array<String> = [];
		if (tree != null) collectStringContents(tree, source, stringFold, out);
		return out;
	}

	/** Whether `name` occurs as a word inside any collected string-literal content (a possible reflection target). */
	private static function mentionedInStrings(name: String, contents: Array<String>): Bool {
		return contents.exists(c -> RefactorSupport.referencedInRange(c, name, 0, c.length, []));
	}

	/**
	 * The class-scope node a decl child represents: itself for a plain `class` /
	 * `abstract class`, the inner `ClassForm` for a `final class` (`FinalDecl`
	 * wrapper), else null.
	 */
	private static function classFormOf(child: QueryNode): Null<QueryNode> {
		if (isClassScopeNode(child.kind)) return child;
		if (child.kind == 'FinalDecl') for (c in child.children) if (isClassScopeNode(c.kind)) return c;
		return null;
	}

	/**
	 * Whether a `@:meta` sibling named `metaName` precedes the class-decl child at
	 * `index`, scanning back over the class's leading meta / visibility run
	 * (`@:meta` / `Private` / `Extern`) and stopping at the first other sibling.
	 */
	private static function metaPrecedesClass(siblings: Array<QueryNode>, index: Int, metaName: String): Bool {
		var i: Int = index - 1;
		while (i >= 0) {
			final kind: String = siblings[i].kind;
			if ((kind == 'Meta' || kind == 'MetaCall') && siblings[i].name == metaName) return true;
			if (kind != 'Meta' && kind != 'MetaCall' && kind != 'Private' && kind != 'Extern') return false;
			i--;
		}
		return false;
	}

	/**
	 * Index each class by name with its `@:build` / `@:keep` presence. Recurses into a
	 * class BODY (never the `FinalDecl` wrapper) so a `final class`'s leading meta —
	 * a sibling of the wrapper, not of the inner form — is read once at the right level.
	 */
	private static function collectClassMeta(tree: QueryNode, out: Map<String, { hasBuild: Bool, hasKeep: Bool }>): Void {
		forEachClassDecl(
			tree, (classNode, name, siblings, index) -> out[name] = {
				hasBuild: metaPrecedesClass(siblings, index, '@:build'),
				hasKeep: metaPrecedesClass(siblings, index, '@:keep')
			}
		);
	}

	/**
	 * Collect every class with a deletable-candidate private empty constructor: an
	 * all-static-shaped utility class (has a `static` member) whose `private function
	 * new() {}` exists purely to forbid instantiation, and which carries no `@:build`
	 * macro. Instantiation / reflection are filtered by the caller (needs the full
	 * file set).
	 */
	private static function collectCtorCandidates(
		tree: QueryNode, file: String, out: Array<{ file: String, className: String, span: Span }>
	): Void {
		forEachClassDecl(tree, (classNode, name, siblings, index) -> {
			// An abstract class is never instantiated by definition and its private
			// empty ctor is the subclass-only idiom — `new` stays for `super()`.
			if (classNode.kind == 'AbstractClassDecl') return;
			if (metaPrecedesClass(siblings, index, '@:build')) return;
			final ctor: Null<QueryNode> = privateEmptyCtorOf(classNode);
			final cspan: Null<Span> = ctor?.span;
			if (ctor != null && cspan != null && hasStaticMember(classNode)) out.push({ file: file, className: name, span: cspan });
		});
	}

	/** The class's `private function new() {}` (empty body, no params), or null. */
	private static function privateEmptyCtorOf(classNode: QueryNode): Null<QueryNode> {
		final kids: Array<QueryNode> = classNode.children;
		for (i in 0...kids.length) {
			final child: QueryNode = kids[i];
			if (child.kind == 'FnMember' && child.name == 'new' && isEmptyCtorBody(child) && precededByPrivate(kids, i)) return child;
		}
		return null;
	}

	/** Whether the member at `index` is preceded by a `Private` modifier (and not `Public`) in its meta / modifier run. */
	private static function precededByPrivate(siblings: Array<QueryNode>, index: Int): Bool {
		var i: Int = index - 1;
		var sawPrivate: Bool = false;
		while (i >= 0) {
			final kind: String = siblings[i].kind;
			if (kind == 'Private')
				sawPrivate = true;
			else if (kind == 'Public')
				return false;
			else if (kind != 'Meta' && kind != 'MetaCall')
				break;
			i--;
		}
		return sawPrivate;
	}

	/** Whether the class carries at least one `static` member (the utility-class shape). */
	private static function hasStaticMember(classNode: QueryNode): Bool {
		return classNode.children.exists(child -> child.kind == 'Static');
	}

	/** Whether `className` is instantiated (`new ClassName`) anywhere in the file set. */
	private static function isInstantiatedAnywhere(className: String, files: Array<{ file: String, source: String }>): Bool {
		return files.exists(entry -> containsInstantiation(entry.source, className));
	}

	/**
	 * Raw-text scan for `new ClassName` in `source`: an occurrence of `className` at
	 * an identifier boundary, immediately preceded (past whitespace) by the `new`
	 * keyword. Sees inside `#if` regions (unlike the AST walkers), so a
	 * conditionally-compiled instantiation is not missed.
	 */
	private static function containsInstantiation(source: String, className: String): Bool {
		final len: Int = className.length;
		if (len == 0) return false;
		var i: Int = 0;
		while (i + len <= source.length) {
			final at: Int = source.indexOf(className, i);
			if (at < 0) return false;
			final afterIdx: Int = at + len;
			final beforeOk: Bool = at == 0 || !RefactorSupport.isIdentChar(source.fastCodeAt(at - 1));
			final afterOk: Bool = afterIdx >= source.length || !RefactorSupport.isIdentChar(source.fastCodeAt(afterIdx));
			if (beforeOk && afterOk && precededByNew(source, at)) return true;
			i = at + 1;
		}
		return false;
	}

	/** Whether the token ending just before `pos` (past whitespace) is the `new` keyword at a word boundary. */
	private static function precededByNew(source: String, pos: Int): Bool {
		final kw: String = 'new';
		var j: Int = pos - 1;
		while (j >= 0 && isWhitespace(source.fastCodeAt(j))) j--;
		final start: Int = j + 1 - kw.length;
		if (start < 0) return false;
		for (k in 0...kw.length) if (source.fastCodeAt(start + k) != kw.fastCodeAt(k)) return false;
		return start == 0 || !RefactorSupport.isIdentChar(source.fastCodeAt(start - 1));
	}

	/**
	 * Whether a flagged MEMBER (not the constructor) clears every deletion gate: a
	 * side-effect-free declaration (`deletableMember`), not an abstract-method impl of
	 * an `extends` class (`mayImplementAbstractMethod`), an enclosing type with no
	 * `@:rtti` / `@:keep` / `@:build`, and a name in no in-scope string literal (a
	 * possible reflection target). Any doubt keeps the member (still reported).
	 */
	private static function memberDeletable(
		node: QueryNode, owner: Null<String>, inExtends: Bool, index: Null<SymbolIndex>,
		classMeta: Map<String, { hasBuild: Bool, hasKeep: Bool }>, reflected: Array<String>
	): Bool {
		if (!deletableMember(node)) return false;
		if (mayImplementAbstractMethod(node, inExtends)) return false;
		if (owner != null) {
			if (index != null && index.transitivelyCarriesRtti(owner)) return false;
			final meta: Null<{ hasBuild: Bool, hasKeep: Bool }> = classMeta[owner];
			if (meta != null && (meta.hasBuild || meta.hasKeep)) return false;
		}
		final name: Null<String> = node.name;
		return name == null || !mentionedInStrings(name, reflected);
	}

	/**
	 * Visit each class declaration in `node`'s subtree, passing the class-scope node,
	 * its name (guaranteed non-null), and its sibling run + index (for a leading-meta
	 * scan). Descends into a class BODY, never the `FinalDecl` wrapper, so a `final
	 * class`'s leading meta is read once at the right level.
	 */
	private static function forEachClassDecl(node: QueryNode, visit: (QueryNode, String, Array<QueryNode>, Int) -> Void): Void {
		final kids: Array<QueryNode> = node.children;
		for (i in 0...kids.length) {
			final child: QueryNode = kids[i];
			final classNode: Null<QueryNode> = classFormOf(child);
			final name: Null<String> = classNode?.name;
			if (classNode != null && name != null) {
				visit(classNode, name, kids, i);
				forEachClassDecl(classNode, visit);
			} else {
				forEachClassDecl(child, visit);
			}
		}
	}

}
