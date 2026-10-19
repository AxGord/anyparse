package anyparse.query;

import anyparse.query.MemberLookup.DeclaredMember;

/**
 * The answers the typing service remembers, one table per question, each keyed by the declaration the question is about.
 * Each question is a pure function of that declaration and the run's immutable index, so an answer computed once is the
 * answer every later asker gets: a cache changes when a question is computed, never what it answers.
 */
@:nullSafety(Strict)
final class QueryCache {

	/** No link of a type's resolvable closure declares a member of the name (`MemberLookup.declarationLacksMember`). */
	public final lacksMember: DeclarationQuery<Bool> = new DeclarationQuery();

	/** The declaration of a member of the name in a type's resolvable closure (`MemberLookup.declaredMemberClosure`). */
	public final declaredMember: DeclarationQuery<Null<DeclaredMember>> = new DeclarationQuery();

	/** The declared type source of a member of the name in a type's supertype closure (`MemberLookup.memberTypeSourceWalk`). */
	public final memberTypeSource: DeclarationQuery<Null<String>> = new DeclarationQuery();

	/** No type of a type's closure brings static extensions (`MemberLookup.declarationFreeOfExtensionTypes`). */
	public final freeOfExtensionTypes: DeclarationQuery<Bool> = new DeclarationQuery();

	public function new() {}

}
