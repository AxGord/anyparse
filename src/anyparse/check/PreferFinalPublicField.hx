package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.FieldWriteIndex;
import anyparse.runtime.Span;

/**
 * Flags a PUBLIC `var` field, assigned only at its declaration and never
 * reassigned anywhere in the project, that the immutable `final` should replace —
 * and rewrites `var` to `final`. `Severity.Info` (a modernization cleanup toward
 * immutability), with an autofix. The public-visibility counterpart of
 * `prefer-final-field`: where that check proves single-assignment for a
 * file-confined private field with a single-file text scan, this one proves it for
 * a public field — writable from any file — with a cross-file, type-resolved
 * `FieldWriteIndex`.
 *
 * ## Soundness — why a missed write is impossible
 *
 * A false negative (a wrong `final` the compiler rejects) is the dangerous
 * direction, so the candidate must be PROVABLY single-assignment:
 *
 * 1. The field has a declaration initializer (one assignment). A no-initializer
 *    field would need a definite-assignment-in-constructor proof this check does
 *    not attempt, and is skipped.
 * 2. Its enclosing type has NO subtype in the index (`SymbolIndex.hasSubtype`). A
 *    subtype writing the inherited field via `this.field` / a bare `field` resolves
 *    to the SUBTYPE, not this type — so an inherited write could be misattributed;
 *    the gate rules that out. The same gate also bails when a SUPERtype declares
 *    the same field (`SymbolIndex.supertypeDeclaresMember`): its property access is
 *    then fixed by that interface / superclass var, which final would violate.
 * 3. No unresolved write can target the field
 *    (`FieldWriteIndex.hasUnresolvedWriteTargeting`): a write to the field NAME
 *    whose receiver could not be attributed to a type could be a hidden write to
 *    this field, so any such write bails the candidate — UNLESS every one is a
 *    plain `=` of a builtin-typed literal AND the candidate's declared type is a
 *    plain project class no builtin can convert into (then the write provably
 *    targets some other type). The index over-counts toward "written".
 * 4. No resolved write targets this type's field
 *    (`FieldWriteIndex.writtenAnywhere`). Receiver resolution covers `this`, typed
 *    identifiers, field-access chains, index accesses, inherited-field and static
 *    roots — see `FieldWriteIndex`'s receiver-resolution doc.
 *
 * Together these prove the initializer is the sole assignment, so `var → final` is
 * always sound; any gap is a loud compile error, never silent corruption.
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
		return 'a public var field assigned only at its declaration that is never reassigned and can be final';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final writeIndex: FieldWriteIndex = FieldWriteIndex.build(files, plugin, index);
		final violations: Array<Violation> = [];
		RefactorSupport.eachFieldMember(files, plugin, (owner, field, source, file, exported) -> {
			if (exported) considerField(violations, file, source, field, owner, index, writeIndex);
		});
		return violations;
	}

	/**
	 * Rewrite each flagged field's `var` keyword to `final`. The candidate is by
	 * construction never reassigned, so the swap is always safe; the edit fires only
	 * when the bytes at the declaration start are literally the keyword.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return RefactorSupport.varKeywordToFinalEdits(source, [for (v in violations) v.span]);
	}

	/**
	 * Flag `field` when it has an initializer, is not a property, its enclosing type
	 * has no subtype, and no write — resolved, or unresolved-but-possibly-targeting
	 * (`hasUnresolvedWriteTargeting`, which re-derives the candidate's declared type
	 * and applies the type-parameter / unique-plain-class / import-shadow guards) —
	 * targets it.
	 */
	private static function considerField(
		out: Array<Violation>, file: String, source: String, field: QueryNode, owner: String, index: SymbolIndex,
		writeIndex: FieldWriteIndex
	): Void {
		final name: Null<String> = field.name;
		final span: Null<Span> = field.span;
		if (name == null || span == null) return;
		if (!RefactorSupport.isInitializedNonPropertyField(source, field)) return;
		if (index.hasSubtype(owner) || index.supertypeDeclaresMember(owner, name)) return;
		if (writeIndex.hasUnresolvedWriteTargeting(name, owner, file)) return;
		if (writeIndex.writtenAnywhere(owner, name)) return;
		out.push({
			file: file,
			span: span,
			rule: 'prefer-final-public-field',
			severity: Severity.Info,
			message: 'public field \'$name\' is never reassigned; use final'
		});
	}

}
