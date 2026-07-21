package anyparse.grammar.haxe;

/**
 * Preprocessor-guarded region occupying the initializer slot of a
 * variable declaration — `HxVarDecl.condInit`'s optional Ref.
 *
 * A one-branch enum rather than a direct Ref to `HxConditionalVarInit`
 * because the `#if` / `#end` markers have to ride an enum BRANCH:
 * `@:fmt(spaceBeforeTrail)` — which keeps `#end` from fusing with the
 * last word character of the initializer expression — is read off the
 * branch in `WriterLowering`, and the struct-field emit path has no
 * equivalent. Same layering as `HxMetadata.Conditional` /
 * `HxMemberModifier.Conditional`: the ctor owns the markers, the
 * payload typedef owns the body.
 *
 * A second branch (an `#else`-bearing shape) is the natural extension
 * point if a source form ever pairs a guarded initializer with an
 * alternative one; see `HxConditionalVarInit` for why that is out of
 * scope today.
 */
@:peg
enum HxVarInitRegion {

	@:trail('#end') @:fmt(spaceBeforeTrail)
	Conditional(inner: HxConditionalVarInit);

}
