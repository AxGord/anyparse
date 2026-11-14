package anyparse.grammar.haxe;

/**
 * Raw byte capture of a SELF-TERMINATING member-scope token-splice `#if` region: exactly what
 * `HxCondSpliceRaw` matches, narrowed to fragments whose last non-whitespace token before the
 * closing `#end` is a `;` or a `}` that no shared body follows.
 *
 * That closer is the discriminator between the two things a member-position region the balanced
 * `Conditional` cannot read can be: a fragment that DANGLES — a signature with no body, whose
 * shared body follows the `#end` (`HxCondSharedBodyMember`) — and a fragment that is COMPLETE at its
 * own `#end` (`#if false {} #end`). Nothing after the latter belongs to the region; leaving it to the
 * shared-body ctor makes that ctor's `HxFnBody` tail swallow the NEXT member (`function`, `var`) or
 * fail on its modifiers (`public`). A `}` closer is admitted only when the `#end` is not followed by
 * `{`, so a signature ending in an anonymous-structure return type keeps its block body after `#end`.
 *
 * ONLY the nesting-aware reading of `HxCondSpliceRaw` is kept: it ends at the same outermost `#end`
 * as the splice reading, so a closed match never disagrees with it. A shorter fallback would end at
 * an INNER `#end` and steal a dangling-signature region that holds a closed nested region.
 * `@:rawString` — byte-exact round-trip, no unescape pass.
 */
@:re('(?:(?:(?!#if|#end)[\\s\\S])*(?:#if(?:(?!#if|#end)[\\s\\S])*(?:#if(?:(?!#if|#end)[\\s\\S])*(?:#if(?:(?!#if|#end)[\\s\\S])*(?:#if(?:(?!#if|#end)[\\s\\S])*#end(?:(?!#if|#end)[\\s\\S])*)*#end(?:(?!#if|#end)[\\s\\S])*)*#end(?:(?!#if|#end)[\\s\\S])*)*#end(?:(?!#if|#end)[\\s\\S])*)*(?:;|\\}(?=\\s*#end(?!\\s*\\{)))\\s*#end)')
@:rawString
@:condRegionRaw
abstract HxCondClosedMemberRaw(String) from String to String {}
