package anyparse.check;

import anyparse.check.MemberOrder.MemberRank;
import anyparse.check.MemberOrder.OrderedMember;

/**
 * The `compareOrder` keys for ONE pair of members, computed by `MemberOrder` and handed here.
 *
 * They are passed rather than recomputed: the ranking helpers (`sectionOf`, `rankedOrdinalOf`,
 * the whole `SortPlan`) belong to the check, and a second implementation of them here would be
 * free to drift - a message naming a DIFFERENT key than the comparator actually used is worse
 * than the old one that named no key at all.
 */
typedef OrderKeys = {
	var elseExempt: Bool;
	var section: Int;
	var otherSection: Int;
	var ranked: Null<Int>;
	var otherRanked: Null<Int>;
	var pinnedOrdinal: Int;
	var otherPinnedOrdinal: Int;
	var branch: Int;
}

/**
 * The sentence a `member-order` finding carries: WHICH member is out of place, and which ordering
 * rule put it there.
 *
 * The message this replaces was one frozen string - "type members are not in canonical order
 * (constants, fields, constructor, methods; public before private)" - on every finding of the
 * rule. It named no member, and its four-word summary is not what the check enforces: the rank
 * ladder is eighteen wide, instance methods lead static ones, property accessors have their own
 * rank, and WITHIN one rank the order is decided by `inline` and by whether a declaration carries
 * an initializer - keys no vocabulary of ranks can express. Four campaign workers in a row
 * reverse-engineered that from the source, and two of them read the `inline` sub-order as the
 * check reclassifying a member (it does not: `static final X` and `static inline final X` are the
 * same rank, the modifier only moves it within that rank).
 *
 * So the sentence names the flagged member, the neighbour whose comparison it lost, and the FIRST
 * `compareOrder` key on which the two differ - mirroring that function's key order, because the
 * most visible difference between two members is often not the one that decided their order.
 */
@:nullSafety(Strict)
final class MemberOrderReason {

	/** The member's own name, quoted for a message; a placeholder when the grammar projects none. */
	public static function nameOf(m: OrderedMember): String {
		final name: Null<String> = m.node.name;
		return name == null || name == '' ? '\'(unnamed)\'' : '\'$name\'';
	}

	/** Why `a` must sit before `b`: the first key of `compareOrder` on which the pair differs, in words. */
	public static function of(a: OrderedMember, b: OrderedMember, keys: OrderKeys): String {
		if (keys.elseExempt || keys.section != keys.otherSection) return rankReason(a, b);
		final pinned: Bool = a.condition != null && keys.ranked == null;
		final otherPinned: Bool = b.condition != null && keys.otherRanked == null;
		if (pinned != otherPinned) return pinReason(a, b, keys.section);
		if (pinned) return groupReason(a, b, keys.pinnedOrdinal, keys.otherPinnedOrdinal, keys.branch);
		if (a.rank != b.rank) return rankReason(a, b);
		return if ((keys.ranked == null) != (keys.otherRanked == null))
			plainVersusBlockReason(a, b, keys.ranked != null)
		else if (keys.ranked != null && keys.otherRanked != null)
			groupReason(a, b, keys.ranked, keys.otherRanked, keys.branch)
		else
			subOrderReason(a, b);
	}

	/** A rank named the way the user's own order spec names it - what the reader has to move the member past. */
	private static function rankLabel(rank: MemberRank): String {
		return switch rank {
			case StaticPublicImmutableField: 'public constant';
			case StaticPublicMutableField: 'public static var';
			case StaticPrivateImmutableField: 'private constant';
			case StaticPrivateMutableField: 'private static var';
			case PublicReadOnlyProperty: 'public read-only property';
			case PublicGetterProperty: 'public getter property';
			case PublicImmutableField: 'public final field';
			case PublicMutableField: 'public var field';
			case PrivateReadOnlyProperty: 'private read-only property';
			case PrivateGetterProperty: 'private getter property';
			case PrivateImmutableField: 'private final field';
			case PrivateMutableField: 'private var field';
			case Constructor: 'constructor';
			case Accessor: 'property accessor';
			case PublicMethod: 'public instance method';
			case PrivateMethod: 'private instance method';
			case StaticPublicMethod: 'public static method';
			case StaticPrivateMethod: 'private static method';
		}
	}

	/** A member named by rank and identity: `private instance method 'walk'`. */
	private static function describe(m: OrderedMember): String {
		return '${rankLabel(m.rank)} ${nameOf(m)}';
	}

	/** The section a rank sorts into, named for a message. */
	private static function sectionLabel(section: Int): String {
		return switch section {
			case 0: 'field';
			case 1: 'constructor';
			case _: 'method';
		}
	}

	/** The rank-difference reason: the two ranks, in the order the canonical sequence puts them. */
	private static function rankReason(a: OrderedMember, b: OrderedMember): String {
		return 'a ${rankLabel(a.rank)} must precede the ${describe(b)}';
	}

	/** The mixed-rank conditional block is pinned to the end of its section - one of the pair is inside it. */
	private static function pinReason(a: OrderedMember, b: OrderedMember, section: Int): String {
		return 'the ${describe(a)} belongs ahead of the conditional block pinned to the end of the ${sectionLabel(section)} section, '
			+ 'which holds ${nameOf(b)}';
	}

	/** The conditional-block reason: the same block (a branch flip) or a different one (block order). */
	private static function groupReason(a: OrderedMember, b: OrderedMember, ordinal: Int, otherOrdinal: Int, branch: Int): String {
		return if (ordinal != otherOrdinal)
			'its #if block sorts before the one holding ${nameOf(b)}, and a conditional block moves as one unit'
		else if (branch != 0)
			'it belongs to an earlier branch of the same #if block as ${nameOf(b)}, and branches are not interleaved'
		else
			rankReason(a, b);
	}

	/** One of the pair is a plain member and the other sits in a content-ranked `#if` block of the SAME rank. */
	private static function plainVersusBlockReason(a: OrderedMember, b: OrderedMember, leads: Bool): String {
		return leads
			? 'a conditional block of inline fields leads its rank, so ${nameOf(a)} must precede the plain ' + describe(b)
			: 'a plain member leads its rank, and ${nameOf(b)} sits in a conditional block that trails the plain members of that rank';
	}

	/**
	 * The within-rank reason - the half of the order the rank vocabulary cannot express, and the one
	 * every reader of the old message had to reverse-engineer: `inline` leads its rank group, then an
	 * initialized declaration leads an init-less one.
	 */
	private static function subOrderReason(a: OrderedMember, b: OrderedMember): String {
		return a.isInline != b.isInline
			? 'an inline member leads its rank group, so it must precede the non-inline ${describe(b)}'
			: 'a member with a declaration-site initializer leads an init-less one of the same rank, so it must precede the ' + describe(b);
	}

}
