package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.MemberWriteScan;
import anyparse.query.TypeInfoProvider;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags a private `var` field that the immutable `final` should replace, and rewrites
 * `var` to `final`. `Severity.Info` (a modernization cleanup toward immutability), with
 * an autofix. Structurally a sibling of `unused-private`: same confinement gate, same
 * conservative in-file scan. Two cases qualify: a field whose declaration initializer is
 * its only assignment, and a no-initializer field whose sole write is exactly one
 * unconditional top-level constructor statement.
 *
 * ## Soundness — why a missed write is impossible
 *
 * A false negative (a wrong `final` the compiler rejects) is the dangerous
 * direction, so the candidate must be PROVABLY single-assignment:
 *
 * 1. The field has a declaration initializer (one assignment), OR is a no-initializer
 *    field assigned by exactly one unconditional top-level constructor statement (the
 *    no-initializer case below).
 * 2. It is private and every write to it is confined to this file (`writesConfined`) —
 *    no skip-parsed file, no `@:access` grant, no `@:allow`, and no subtype writing the
 *    inherited member. A non-default visibility (public) is excluded: a public field
 *    is writable from another file regardless of confinement.
 * 3. No other write to the field name appears in the file. The scan is a
 *    conservative, COMPLETE text scan — it treats the name followed by any
 *    assignment operator (`=`, `+=`, … but not `==` / `<=` / `!=` / `=>`) or
 *    adjacent to `++` / `--` as a write, matching `this.x = …`, `obj.x = …`,
 *    `x++`, and `++x` alike, and skips whitespace AND interposed comments between
 *    the name and the operator (a write whose name is separated from `=` by a
 *    comment is still detected). It over-counts (a same-named local, or the name in
 *    a comment / string, reads as a write) which only ever KEEPS a `var`, never
 *    produces a wrong `final`.
 *
 * Together these prove the assignment is the sole one, so `var → final` is always sound. An interface-mutability gate additionally skips a field an implemented interface declares — or that ANY unresolvable implemented interface might declare — since the interface pins its property access and finalizing would break parity.
 *
 * ## Whole-project scope required
 *
 * Confinement is only sound when the lint scope contains EVERY file that can
 * reference the type — `writesConfined` can only rule out a cross-file `@:access` /
 * subtype writer it can SEE in the index. Run over a single file in isolation, an
 * external writer is invisible and the field would be wrongly flagged. The subtype
 * gate is what makes this bite in practice: a whole-project run sees subtypes a
 * single-file run cannot, so the two scopes must not disagree on an untouched one.
 * This is the same limitation `unused-private` carries; like it, this check is
 * registered as a full-scope check in the `--fix` loop, and the sound usage is
 * linting the whole project (`lint src/`).
 *
 * ## No-initializer case; properties skipped
 *
 * A no-initializer field is ALSO flagged when its sole write is exactly one
 * unconditional top-level constructor statement (`x = expr` / `this.x = expr`, not
 * nested in a branch / loop / closure) and no other write exists — Haxe allows a
 * `final` assigned once in the constructor. This covers the unmovable
 * constructor-argument-dependent fields (`_b = param`) that
 * `field-init-at-declaration` cannot move to the declaration. A property
 * (`var x(get, set)`, detected by a `(` in the declaration head) and a function-type
 * field are skipped in both cases.
 *
 * ## Fixpoint chain with `field-init-at-declaration`
 *
 * (a) `field-init-at-declaration` moves a context-free constructor init to the
 * declaration, and the declaration-initializer case above then rewrites the `var` to
 * `final`; (b) the no-initializer case here also covers the constructor-argument
 * fields that rule cannot move. Both rules handle `var` and `final`, so any pass
 * ordering converges to the same fixpoint.
 */
@:nullSafety(Strict)
final class PreferFinalField implements Check {

	public function new() {}

	public function id(): String {
		return 'prefer-final-field';
	}

	public function description(): String {
		return 'a private var field assigned only at its declaration that can be final';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final lazyIndex: () -> Null<SymbolIndex> = RefactorSupport.lazySymbolIndex(files, plugin, index);
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		final abstractKinds: Array<String> = plugin.refShape().underlyingThisTypeKinds ?? [];
		final declaredTypesByFile: Map<String, Map<Int, String>> = [];
		if (provider != null) for (entry in files) declaredTypesByFile[entry.file] = provider.declaredTypes(entry.source);
		final violations: Array<Violation> = [];
		RefactorSupport.eachFieldMember(files, plugin, (owner, field, source, file, exported) -> {
			if (!exported)
				considerField(violations, file, source, field, owner, index, lazyIndex, plugin, declaredTypesByFile[file], abstractKinds);
		});
		return violations;
	}

	/**
	 * Rewrite each flagged field's `var` keyword to `final`. The candidate is by
	 * construction assigned only at its declaration, so the swap is always safe; the
	 * edit fires only when the bytes at the declaration start are literally the
	 * keyword (`substring` clamps, so an unexpected span simply fails the equality).
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return RefactorSupport.varKeywordToFinalEdits(source, [for (v in violations) v.span]);
	}

	/**
	 * Flag `field` for `var → final` in either case: a field WITH an initializer that is
	 * not a property, confined, not written elsewhere, and not an abstract's mutable
	 * underlying (`abstractMethodMayMutate`); OR a no-initializer field whose sole write
	 * is exactly one unconditional top-level constructor statement, delegated to
	 * `considerNoInitField`.
	 */
	private static function considerField(
		out: Array<Violation>, file: String, source: String, field: QueryNode, owner: String, index: SymbolIndex,
		lazyIndex: () -> Null<SymbolIndex>, plugin: GrammarPlugin, declaredTypes: Null<Map<Int, String>>, abstractKinds: Array<String>
	): Void {
		final name: Null<String> = field.name;
		final span: Null<Span> = field.span;
		if (name == null || span == null) return;
		// Interface-mutability gate: a field an implemented interface declares (or ANY
		// unresolvable implemented interface) is pinned to that interface's property
		// access — `var → final` would break parity ("different property access than in
		// <Interface>"). Applies to both the init and no-init cases below.
		if (index.implementsInterfaceDeclaringMember(owner, name)) return;
		if (RefactorSupport.isInitializedNonPropertyField(source, field)) {
			if (!writesConfined(owner, name, source, index)) return;
			if (writtenInFile(source, name, span)) return;
			final declType: Null<String> = declaredTypes == null ? null : declaredTypes[span.from];
			if (RefactorSupport.abstractMethodMayMutate(source, name, declType, span, lazyIndex, abstractKinds)) return;
			flag(out, file, span, name, 'is assigned only at its declaration');
			return;
		}
		if (field.children.length >= 1) return;
		if (source.substring(span.from, span.to).indexOf('(') >= 0) return;
		considerNoInitField(out, file, source, field, name, span, owner, index, plugin);
	}

	/**
	 * Flag a no-initializer private confined `var` whose sole write is exactly one
	 * unconditional top-level constructor statement — `final`-izable in place (the
	 * constructor keeps the single assignment). Any other write to the field name, or a
	 * shadowing local / parameter that owns the constructor assignment, leaves it a `var`.
	 */
	private static function considerNoInitField(
		out: Array<Violation>, file: String, source: String, field: QueryNode, name: String, span: Span, owner: String, index: SymbolIndex,
		plugin: GrammarPlugin
	): Void {
		if (!writesConfined(owner, name, source, index)) return;
		final tree: Null<QueryNode> = try plugin.parseFile(source) catch (_: Exception) null;
		if (tree == null) return;
		final loc: Null<{
			container: QueryNode,
			field: QueryNode,
			stmt: QueryNode,
			rhs: QueryNode,
			target: Span
		}> = RefactorSupport.constructorFieldInitAt(tree, span.from, plugin.refShape());
		if (loc == null) return;
		// A STATIC field cannot become final off a ctor assignment - `static final`
		// requires a declaration initializer, so the no-init case skips statics.
		if (RefactorSupport.staticMemberFroms(loc.container, plugin.refShape()).contains(span.from)) return;
		if (writtenInFile(source, name, loc.target)) return;
		flag(out, file, span, name, 'is assigned only in the constructor');
	}

	/** Push a `prefer-final-field` violation for `name` at `span` with the reason phrase `reason`. */
	private static inline function flag(out: Array<Violation>, file: String, span: Span, name: String, reason: String): Void {
		out.push({
			file: file,
			span: span,
			rule: 'prefer-final-field',
			severity: Severity.Info,
			message: 'field \'$name\' $reason; use final'
		});
	}

	/**
	 * Whether every write to the private field `name` of `owner` lives in `source`.
	 * `RefactorSupport.isPrivateMemberConfined`'s subtype veto is blanket — ANY indexed
	 * subtype keeps every private field of `owner` a `var`, even an empty `class D extends
	 * C {}` — so it is replaced here by the precise question `final` actually asks: a
	 * subtype may READ an inherited private field (a read survives the keyword), only a
	 * WRITE in one breaks it. The other confinement gates stay wholesale: a skip-parsed
	 * file, an `@:access` grant on the type and an `@:allow` in its own file can each hide
	 * a writer no bounded scan can see.
	 */
	private static function writesConfined(owner: String, name: String, source: String, index: SymbolIndex): Bool {
		return RefactorSupport.privateMemberScanIsSound(source, index) && !MemberWriteScan.accessGrantMayWrite(owner, name, index)
			&& !MemberWriteScan.subtypeMayWrite(owner, name, index);
	}

	/**
	 * Whether `name` is written anywhere in `source` outside `exclude` (its own
	 * declaration) — the in-file half of the proof, over the whole file.
	 */
	private static inline function writtenInFile(source: String, name: String, exclude: Span): Bool {
		return MemberWriteScan.writtenInRange(source, name, exclude, 0, source.length);
	}

}
