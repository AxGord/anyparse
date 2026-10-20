package anyparse.query;

import anyparse.query.AbstractCasts.CastGraph;
import anyparse.query.AncestorTable.AncestorLink;
import anyparse.query.ArgumentSlots.ArgumentFit;
import anyparse.query.CallSelection.CallArgument;
import anyparse.query.MemberLookup.DeclaredMember;
import anyparse.query.MemberLookup.HostedMembers;
import anyparse.query.SymbolIndex.ResolvedType;

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

	/** A type's direct supertype links, each resolved once where the type writes it (`AncestorTable.links`). */
	public final ancestorLinks: DeclarationQuery<Array<AncestorLink>> = new DeclarationQuery();

	/** The declaration a plain alias re-points at, resolved where the alias writes it (`AncestorTable.aliasTarget`). */
	public final aliasTargets: DeclarationQuery<Null<ResolvedType>> = new DeclarationQuery();

	/** What a type's supertype chain passes to an ancestor's type parameters, by the pair (`AncestorTable.argumentsTo`). */
	public final ancestorArguments: DeclarationQuery<Null<Array<String>>> = new DeclarationQuery();

	/** Whether a value of one plain type unifies with another, by the pair (`Unification.unifies`). */
	public final unifies: DeclarationQuery<ArgumentFit> = new DeclarationQuery();

	/** The cast graph of an abstract declaration, by the declaration (`AbstractCasts.graph`). */
	public final castGraphs: DeclarationQuery<Null<CastGraph>> = new DeclarationQuery();

	/** Whether an argument of one declaration's type is accepted where another's is expected, by the pair (`Unification.casts`). */
	public final casts: DeclarationQuery<ArgumentFit> = new DeclarationQuery();

	/** The static extension `recv.name` binds in a file on a receiver of a declaration (`StaticExtensions.binding`). */
	public final extensionBindings: DeclarationQuery<Null<HostedMembers>> = new DeclarationQuery();

	/**
	 * BODY: what a call site hands its callee, each argument typed once with no expected type (`CallArgument`), by the site
	 * and the declaration it is written in (`DeclarationKey.ofSite`): what every candidate signature is tried against.
	 */
	public final callArguments: DeclarationQuery<Array<CallArgument>> = new DeclarationQuery();

	public function new() {}

}
