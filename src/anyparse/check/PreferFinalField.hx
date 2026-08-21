package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberWriteScan;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.runtime.Span;

/**
 * Flags a private `var` field that the immutable `final` should replace, and rewrites
 * `var` to `final`. `Severity.Info` (a modernization cleanup toward immutability), with
 * an autofix. Structurally a sibling of `unused-private`: same confinement gate, same
 * conservative in-file scan. Two cases qualify: a field whose declaration initializer is
 * its only assignment, and a no-initializer field whose sole write is exactly one unconditional
 * constructor assignment.
 *
 * ## Soundness — why a missed write is impossible
 *
 * A false negative (a wrong `final` the compiler rejects) is the dangerous
 * direction, so the candidate must be PROVABLY single-assignment:
 *
 * 1. The field has a declaration initializer (one assignment), OR is a no-initializer
 *    field assigned by exactly one unconditional constructor assignment (the
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
 * A structural-conformance gate (`SymbolIndex.structuralConformanceForbidsFinal`, shared with `prefer-final-public-field` and the `make-final` op, whose write-restriction twin `prefer-read-only-field` takes) applies too. It looks unnecessary here and is not: a PRIVATE member
 * takes no part in structural unification, and NO access grant changes that — `@:allow` on the
 * type and `@:access` on the reader both leave `var` failing with "The field x is not public",
 * with `final` only changing which error prints first. What DOES expose the field is
 * `@:publicFields`, which publishes an unmarked member: there `var` unifies and `final` is
 * "Inconsistent setter for field x : ctor should be default" (all four measured). That meta is
 * not modelled by `RefactorSupport.eachFieldMember`, so such a field is routed to this rule as
 * non-exported — hence the gate runs unconditionally, at the cost of over-declining an
 * ordinary private field whose owner happens to declare a conforming member set.
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
 * A no-initializer field is ALSO flagged when its sole write is exactly one unconditional
 * constructor assignment (`x = expr` / `this.x = expr`, not nested in a branch / loop /
 * closure) and no other write exists. The write need not be a top-level STATEMENT: an
 * assignment EXPRESSION consumed in place — `super([_a = new Row(…)])`, the layout-tree
 * idiom — qualifies too, since the keyword swap changes no evaluation. `field-init-at-
 * declaration` cannot move such a write to the declaration on its own, so this is often
 * the only rule that reaches those fields — Haxe allows a
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
 * ordering converges to the same fixpoint. (c) A THIRD arm,
 * `RefactorSupport.ctorConditionalDefaultFinalEdits`, folds an INITIALIZED field whose
 * only other write is one top-level `if (p != null) x = p;` constructor statement into
 * `final x:T;` plus `x = p ?? <default>;` — the declaration default moves into the
 * constructor, so the single assignment becomes unconditional. Checked before the
 * initializer case (which that constructor write would bail anyway), and gated by the
 * same confinement and abstract-mutability checks.
 */
@:nullSafety(Strict)
final class PreferFinalField implements Check {

	public function new() {}

	public function id(): String {
		return 'prefer-final-field';
	}

	public function description(): String {
		return 'a private var field never reassigned — assigned only at its declaration or by a sole constructor assignment — that can be '
			+ 'final';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final lazyIndex: () -> Null<SymbolIndex> = RefactorSupport.lazySymbolIndex(files, plugin, index);
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
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
	 * The edits for each flagged field, through the shared `RefactorSupport.finalizeFieldEdits`:
	 * a `var` -> `final` keyword swap for the initializer and constructor arms, and the
	 * two-edit conditional-default fold for the third (the declaration loses its property
	 * head and default, the constructor's guarded assignment becomes `x = p ?? <default>`).
	 * Every candidate is by construction assigned exactly once after the rewrite, so both
	 * shapes are safe; each fires only when the declaration's bytes still match what the
	 * check saw, and a fold's edits are emitted together or not at all.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return RefactorSupport.finalizeFieldEdits(source, [for (v in violations) v.span], plugin);
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
	 * Whether `name` is written anywhere in `source` outside `exclude` (its own
	 * declaration) — the in-file half of the proof, over the whole file.
	 */
	private static inline function writtenInFile(source: String, name: String, exclude: Span): Bool {
		return MemberWriteScan.writtenInRange(source, name, exclude, 0, source.length);
	}

	/**
	 * Flag `field` for `var → final` in either case: a field WITH an initializer that is
	 * not a property, confined, not written elsewhere, and not an abstract's mutable
	 * underlying (`abstractMethodMayMutate`); OR a no-initializer field whose sole write
	 * is exactly one unconditional constructor assignment — the shared
	 * `RefactorSupport.ctorSoleAssignmentFinalizable` predicate, wrapped in this check's
	 * `writesConfined` gate.
	 */
	private static function considerField(
		out: Array<Violation>, file: String, source: String, field: QueryNode, owner: String, index: SymbolIndex,
		lazyIndex: () -> Null<SymbolIndex>, plugin: GrammarPlugin, declaredTypes: Null<Map<Int, String>>, abstractKinds: Array<String>
	): Void {
		final name: Null<String> = field.name;
		final span: Null<Span> = field.span;
		if (name == null || span == null) return;
		// Core-API gate, FIRST because it is the only gate here that asks nothing of the index: a
		// `@:coreApi` type's members are pinned to the property access of a core type in the
		// compiler's std path that no scope here holds, and `var` -> `final` is "Field <name> has
		// different property access than core type". Core types DO declare private fields
		// (`haxe.Timer.id`, `haxe.ds.List.h`), so this rule needs the gate exactly like its public
		// sibling.
		if (MemberWriteScan.coreApiPinsMemberShape(source)) return;
		// Interface-mutability gate: a field an implemented interface declares (or ANY
		// unresolvable implemented interface) is pinned to that interface's property
		// access — `var → final` would break parity ("different property access than in
		// <Interface>"). Applies to both the init and no-init cases below.
		if (index.implementsInterfaceDeclaringMember(owner, name)) return;
		// Structural-conformance gate, the same shared predicate `prefer-final-public-field` and
		// `make-final` use.
		// Unconditional, though a PRIVATE member normally takes no part in structural unification
		// at all: `@:publicFields` publishes an unmarked field, and `eachFieldMember` does not
		// model that meta, so such a field arrives HERE as non-exported and `final` on it is a
		// hard error the write gates cannot see. See the class doc for the measured matrix.
		if (index.structuralConformanceForbidsFinal(owner, name)) return;
		// A macro-built type's fields are not what the declaration says: an `@:autoBuild`
		// builder may strip the initializer and move the assignment into the constructor,
		// after which `var` -> `final` is `Static final variable must be initialized`. The
		// grant is inherited through `implements`, so the class itself carries no metadata.
		if (index.transitivelyCarriesBuildMacro(owner)) return;
		// The conditional-default arm, checked FIRST: an initialized field whose only other
		// write is one `if (p != null) x = p;` constructor statement folds to `final` plus
		// `x = p ?? <default>`. It is disjoint from the initializer arm either way (that
		// constructor write makes `writtenInFile` bail), but only this order lets it fire.
		final folded: Bool = RefactorSupport.ctorConditionalDefaultFinalEdits(source, span, plugin) != null;
		if (folded) {
			if (!writesConfined(owner, name, source, index, plugin)) return;
			final foldDeclType: Null<String> = declaredTypes == null ? null : declaredTypes[span.from];
			if (RefactorSupport.abstractMethodMayMutate(source, name, foldDeclType, span, lazyIndex, abstractKinds)) return;
			flag(out, file, span, name, 'has a null-guarded constructor default');
			return;
		}
		if (RefactorSupport.isInitializedNonPropertyField(source, field)) {
			if (!writesConfined(owner, name, source, index, plugin)) return;
			if (writtenInFile(source, name, span)) return;
			final declType: Null<String> = declaredTypes == null ? null : declaredTypes[span.from];
			if (RefactorSupport.abstractMethodMayMutate(source, name, declType, span, lazyIndex, abstractKinds)) return;
			flag(out, file, span, name, 'is assigned only at its declaration');
			return;
		}
		if (!RefactorSupport.ctorSoleAssignmentFinalizable(source, field, plugin)) return;
		if (!writesConfined(owner, name, source, index, plugin)) return;
		flag(out, file, span, name, 'is assigned only in the constructor');
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
	 *
	 * The two write scans take `plugin` so they can resolve the resolution scope themselves — a subtype or
	 * grantee living in a configured library root is seen; `privateMemberScanIsSound` keeps
	 * the report-scope `index`, whose `skippedFiles` describes the files under report and
	 * would otherwise be permanently non-empty on any project with libraries configured.
	 */
	private static function writesConfined(owner: String, name: String, source: String, index: SymbolIndex, plugin: GrammarPlugin): Bool {
		return RefactorSupport.privateMemberScanIsSound(source, index, name)
			&& !MemberWriteScan.accessGrantMayWrite(owner, name, index, plugin)
			&& !MemberWriteScan.subtypeMayWrite(owner, name, index, plugin);
	}

}
