package anyparse.check;

import anyparse.query.NamingPolicy.NamedDecl;
import anyparse.query.NamingPolicy.NamingCategory;
import anyparse.query.SymbolIndex;

/**
 * The member renames one `apq lint --fix` PASS has already accepted, so a rename decided later in
 * that pass can see them.
 *
 * The gap this closes. A pass builds its `SymbolIndex` once and then drives `naming` over TWO
 * seams: `Naming.crossFileFix` for a member whose references leave its declaring file, and
 * `Naming.fix` for a confined one. Those are not the same code path even for two members of ONE
 * hierarchy — a type with a subtype is never confined, so a superclass renames cross-file while its
 * subclass renames per-file. Both ask the pass-start index whether the new name is already
 * inherited (`MemberLookup.typeProvablyLacksMember`), and in that snapshot neither new name exists
 * yet: `class A { private var CAPS; }` plus `class B extends A { private var Caps; }` therefore both
 * cleared the proof and both landed `_caps`, which Haxe rejects with "Redefinition of variable
 * _caps in subclass is not allowed" (verified). `Naming`'s own same-pass claim list is local to one
 * `fix(source, ...)` call and can see neither seam.
 *
 * The ledger is keyed on the INDEX it was decided against: every claim is a promise about that one
 * snapshot, so a different index retires the whole ledger. The `--fix` driver rebuilds its index
 * once per pass, which is exactly the scope the claims are good for — a rename accepted in pass N
 * is IN the sources pass N+1 indexes, where the ordinary inherited-member proof sees it unaided.
 *
 * Both seams pass the index THEIR OWN decision was made against (`resolutionIndexOf(plugin) ?? index`,
 * computed once per seam), so a claim is always keyed to the snapshot that justified it. The two
 * seams agreeing on that object is what keeps one ledger spanning the pass; if a future edit made
 * them disagree, the ledger would retire between them and this gap would re-open silently.
 *
 * Deferral is not refusal: the loser re-fires on a later pass or run and is judged against sources
 * that finally hold the name, where it is either allowed or refused for the real reason.
 */
@:nullSafety(Strict)
final class RenameClaims {

	/** The snapshot `_claims` was decided against; a different one retires them all. */
	private var _index: Null<SymbolIndex> = null;

	/** The accepted renames, in acceptance order. */
	private var _claims: Array<MemberClaim> = [];

	public function new() {}

	/**
	 * Whether a rename of `owner`'s member to `newName` must DEFER to one this pass already
	 * accepted on a type in the same inheritance chain.
	 *
	 * The test is a HIERARCHY one, not a bare-name one: two unrelated types may both take `_caps` in
	 * one pass, and refusing that would strand every same-named twin in the tree. Unrelatedness must
	 * be PROVEN (`SubtypeGraph.unrelatedClasses` — both names unique, both supertype closures fully
	 * enumerated, neither reaching the other), so an ambiguous or unresolvable pair defers rather
	 * than lands. A declaration that cannot collide by inheritance at all (null `owner`), or a run
	 * with no index to prove a hierarchy with, defers to nothing.
	 */
	public function defers(owner: Null<String>, newName: String, index: Null<SymbolIndex>): Bool {
		if (owner == null || index == null) return false;
		for (c in ledger(index)) if (c.newName == newName && !index.subtypes.unrelatedClasses(owner, c.owner)) return true;
		return false;
	}

	/**
	 * Record an accepted member rename, so the rest of the pass defers to it. A declaration `defers`
	 * could never veto anyway - one with no owning type, or a run with no index to prove a hierarchy
	 * with - claims nothing.
	 *
	 * The claim records the DECISION, not the commit: the driver can still drop the rename afterwards
	 * (an edit set overlapping another check's, a canonicalisation `Err`, a cross-file component that
	 * fails to stage), and the claim stands for the rest of the pass regardless. That direction is the
	 * safe one - it defers a rename rather than landing a duplicate - but it means a winner that keeps
	 * failing to commit keeps its loser deferred.
	 */
	public function claim(owner: Null<String>, newName: String, index: Null<SymbolIndex>): Void {
		if (owner == null || index == null) return;
		// Re-bound: a narrowed local does not stay narrowed inside an anonymous structure literal.
		final own: String = owner;
		ledger(index).push({ owner: own, newName: newName });
	}

	/** The claims decided against `index`, emptied the moment a DIFFERENT index arrives. */
	private function ledger(index: SymbolIndex): Array<MemberClaim> {
		if (_index != index) {
			_index = index;
			_claims = [];
		}
		return _claims;
	}

	/**
	 * The type whose inheritance chain a rename of `decl` would introduce the new name into - the owner
	 * of a FIELD or a METHOD, the two categories Haxe forbids redeclaring in a subclass and the two
	 * `Naming.renameEditsFor` already holds to the inherited-member proof. Null for anything else: a
	 * local / param / catch var only SHADOWS an inherited member (which Haxe permits), a type has no
	 * owner, and a static constant is not inherited at all.
	 *
	 * The CROSS-FILE seam does not route through here - it claims with the candidate's own owner, and
	 * `crossFileCandidate` admits a static Constant too. That asymmetry is over-deferral only (a static
	 * cannot be a subclass redefinition), never a missed collision.
	 */
	public static inline function memberOwnerOf(decl: NamedDecl): Null<String> {
		return decl.category == NamingCategory.Field || decl.category == NamingCategory.Method ? decl.enclosingType : null;
	}

}

/**
 * One accepted member rename: the type the new name lands on, and the name itself.
 */
private typedef MemberClaim = {
	final owner: String;
	final newName: String;
};
