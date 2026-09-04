package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.CtorFieldFold;
import anyparse.query.CtorFieldWrite;
import anyparse.query.FieldWriteIndex;
import anyparse.query.GrammarPlugin;
import anyparse.query.MemberWriteScan;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a PUBLIC `var` field, assigned only at its declaration (or by a sole
 * constructor statement) and never reassigned anywhere in the project, that the
 * immutable `final` should replace — and rewrites `var` to `final`. `Severity.Info` (a
 * modernization cleanup toward immutability), with an autofix. The public-visibility
 * counterpart of `prefer-final-field`: where that check proves single-assignment for a
 * file-confined private field with a single-file text scan, this one proves it for
 * a public field — writable from any file — with a cross-file, type-resolved
 * `FieldWriteIndex`.
 *
 * ## Soundness — why a missed write is impossible
 *
 * A false negative (a wrong `final` the compiler rejects) is the dangerous
 * direction, so the candidate must be PROVABLY single-assignment:
 *
 * 1. The field's single assignment is proven by one of two arms. WITH a declaration
 *    initializer, that initializer is the one assignment and `writtenAnywhere` must
 *    find no other. WITHOUT one, the shared
 *    `RefactorSupport.ctorSoleAssignmentFinalizable` proves the sole write is exactly
 *    one unconditional constructor assignment (the arm `prefer-final-field`
 *    always had); `writtenAnywhere` — which the constructor write itself trips — is
 *    replaced by `FieldWriteIndex.writtenOutsideDeclaration`: every resolved write
 *    must lie inside the declaring file's decl range, bailing too when that range
 *    cannot be pinned for an ambiguous simple name, while the predicate's in-file
 *    text scan covers the declaring file itself. `prefer-read-only-field` cedes
 *    exactly these candidates (same predicate), so the two rules stay disjoint. A
 *    THIRD arm, `RefactorSupport.ctorConditionalDefaultFinalEdits`, claims an
 *    INITIALIZED field (a `(default, null)` property included) whose only write
 *    beyond that initializer is one top-level `if (p != null) x = p;` constructor
 *    statement: it is single-assignment once the declaration default moves into the
 *    constructor, which is what its TWO-edit fix does (`final x:T;` plus
 *    `x = p ?? <default>;`). Its whole single-file proof lives in that predicate, and
 *    `prefer-read-only-field` cedes these candidates through the same call.
 * 2. No subtype of it can write the field (`MemberWriteScan.subtypeWriteReaches`). A
 *    `this.field` write in a subtype, and any write through a subtype-typed receiver,
 *    are attributed to the SUBTYPE rather than to this type, so the write index alone
 *    would miss them; the gate scans each subtype's body and asks the index about the
 *    subtype. Merely HAVING a subtype no longer bails. The two arms have DIFFERENT reach:
 *    the body scan runs over the resolution scope, so a subtype declared in a configured
 *    library root counts, while the `writtenAnywhere(subtype, …)` arm reads the
 *    report-scoped `FieldWriteIndex` — a library-side write through a library subtype is
 *    the residual blind spot. The same gate also bails when a SUPERtype declares
 *    the same field (`SymbolIndex.supertypeDeclaresMember`): its property access is
 *    then fixed by that interface / superclass var, which final would violate. An interface-mutability gate extends this to an UNRESOLVABLE implemented interface (which supertypeDeclaresMember treats as absent): out of scope it may still declare a mutable member, so the rewrite is skipped conservatively.
 * 3. No unresolved write can target the field
 *    (`FieldWriteIndex.hasUnresolvedWriteTargeting`): a write to the field NAME
 *    whose receiver could not be attributed to a type could be a hidden write to
 *    this field, so any such write bails the candidate — UNLESS every one is a
 *    plain `=` of a builtin-typed literal AND the candidate's declared type is a
 *    plain project class no builtin can convert into (then the write provably
 *    targets some other type). The index over-counts toward "written".
 * 4. No resolved write targets this type's field — `FieldWriteIndex.writtenAnywhere`
 *    for the initializer arm; the constructor arm substitutes
 *    `writtenOutsideDeclaration` (see 1). Receiver resolution covers `this`,
 *    typed identifiers, field-access chains, index accesses, inherited-field and
 *    static roots — see `FieldWriteIndex`'s receiver-resolution doc.
 * 5. No STRUCTURAL type pins the field mutable — `SymbolIndex.structuralConformanceForbidsFinal`.
 *    Haxe unifies a class with an anonymous structure by member set, and a `final` field
 *    satisfies neither a structural `var x:T` nor a structural `function x():T` (both
 *    measured). That unification is a READ position, so every write gate above is blind to
 *    it. The gate is conservative by construction: it answers CONFORMANCE — does the type
 *    declare the whole member set some structure naming this field requires? — not use.
 *
 * Together these prove the single assignment is the sole one. Residual blind spots —
 * the library-side subtype write in item 2, a `@:build` macro injecting a writer,
 * and the two shapes item 5 cannot see — an anonymous structure written INLINE in an
 * annotation, and a structural type declared in a configured library root — surface as loud
 * compile errors, never silent corruption.
 *
 * ## Whole-project scope required
 *
 * The write-index and the subtype gate are only sound when the lint scope contains
 * EVERY file that can reference the type. Run over a single file in isolation, an
 * external writer / subtype is invisible and the field would be wrongly flagged.
 * This is the same limitation `unused-private` / `prefer-final-field` carry; like
 * them, this is a full-scope check and the sound usage is linting the whole
 * project (`lint src/`).
 */
@:nullSafety(Strict)
final class PreferFinalPublicField implements Check {

	public function new() {}

	public function id(): String {
		return 'prefer-final-public-field';
	}

	public function description(): String {
		return 'a public var field never reassigned — assigned only at its declaration or by a sole constructor assignment — that can be '
			+ 'final';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final writeIndex: FieldWriteIndex = FieldWriteIndex.build(files, plugin, index);
		final violations: Array<Violation> = [];
		CtorFieldWrite.eachFieldMember(files, plugin, (owner, field, source, file, exported) -> {
			if (exported) considerField(violations, file, source, field, owner, index, writeIndex, plugin);
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
		return CtorFieldFold.finalizeFieldEdits(source, [for (v in violations) v.span], plugin);
	}

	/**
	 * Flag `field` when it is provably single-assignment through one of two arms — WITH a
	 * declaration initializer (never written anywhere), or WITHOUT one when its sole
	 * write is exactly one unconditional constructor assignment
	 * (`RefactorSupport.ctorSoleAssignmentFinalizable`) — its enclosing type has no
	 * writing subtype, and no write — resolved, or unresolved-but-possibly-targeting
	 * (`hasUnresolvedWriteTargeting`, which re-derives the candidate's declared type
	 * and applies the type-parameter / unique-plain-class / import-shadow guards) —
	 * targets it outside that single assignment.
	 */
	private static function considerField(
		out: Array<Violation>, file: String, source: String, field: QueryNode, owner: String, index: SymbolIndex,
		writeIndex: FieldWriteIndex, plugin: GrammarPlugin
	): Void {
		final name: Null<String> = field.name;
		final span: Null<Span> = field.span;
		if (name == null || span == null) return;
		// A file the grammar could not read can hold any write, so no single-assignment proof
		// survives it — but only when it can reach this MEMBER, which it can only do by
		// spelling the name. A whole-project veto here silenced the rule for every file in a
		// scope holding one unparseable file.
		if (index.skippedMayReference(name)) return;
		// A macro-built type's fields are not what the declaration says — see
		// `SymbolIndex.transitivelyCarriesBuildMacro`.
		if (index.transitivelyCarriesBuildMacro(owner, file)) return;
		final initialized: Bool = CtorFieldWrite.isInitializedNonPropertyField(source, field);
		// The conditional-default arm: an initialized field (a `(default, null)` property
		// included) whose only other write is one `if (p != null) x = p;` constructor
		// statement, folded to `final` plus `x = p ?? <default>`. Its own proof is entirely
		// inside the shared predicate, which `prefer-read-only-field` cedes on.
		final folded: Bool = CtorFieldFold.ctorConditionalDefaultFinalEdits(source, span, plugin) != null;
		// The no-init arm's single-file proof embeds the cheap syntactic no-initializer /
		// non-property checks, so a field qualifying for NO arm bails here; the parse
		// behind the predicate is memoized by the caching plugin.
		if (!folded && !initialized && !CtorFieldWrite.ctorSoleAssignmentFinalizable(source, field, plugin)) return;
		if (index.supertypeDeclaresMember(owner, name)) return;
		// Interface-mutability gate — complements supertypeDeclaresMember (which resolves
		// a supertype member by name but treats an UNRESOLVABLE interface as absent): an
		// implemented interface that cannot be resolved may still declare a mutable
		// `name`, so `var → final` is unsafe and skipped conservatively.
		if (index.implementsInterfaceDeclaringMember(owner, name)) return;
		// Structural-conformance gate: the type may be passed where an anonymous structure
		// declaring `name` mutably is expected — a READ position, so every write gate below is
		// blind to it — and a `final` field satisfies neither a structural `var` nor a
		// structural method.
		if (index.structuralConformanceForbidsFinal(owner, name)) return;
		// Core-API gate: a `@:coreApi` type's members are pinned to the property access of a core
		// type in the compiler's std path that no scope here holds, and `var` -> `final` is
		// "Field <name> has different property access than core type".
		if (MemberWriteScan.coreApiPinsMemberShape(source)) return;
		if (writeIndex.hasUnresolvedWriteTargeting(name, owner, file)) return;
		if (initialized && !folded) {
			if (writeIndex.writtenAnywhere(owner, name)) return;
		} else {
			// The constructor assignment IS a write, so `writtenAnywhere` cannot gate this
			// arm; instead every RESOLVED write must lie inside the declaring file's decl
			// range — the in-file text scan inside the predicate already proved the
			// constructor statement is the only write there. Same for the folded arm.
			if (writeIndex.writtenOutsideDeclaration(owner, name)) return;
		}
		if (MemberWriteScan.subtypeWriteReaches(owner, name, index, writeIndex, plugin)) return;
		out.push({
			file: file,
			span: span,
			rule: 'prefer-final-public-field',
			severity: Severity.Info,
			message: folded
				? 'public field \'$name\' has a null-guarded constructor default; use final and default with ??'
				: initialized
					? 'public field \'$name\' is never reassigned; use final'
					: 'public field \'$name\' is assigned only in the constructor; use final'
		});
	}

}
