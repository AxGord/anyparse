package anyparse.grammar.haxe;

/**
 * Metadata-tag name terminal with a positive lookahead requiring an
 * immediately-following `(`. Used by the structural `MetaCall` branch
 * of `HxMetadata` to disambiguate `@:meta(args)` from `@:meta (X)`
 * where the `(X)` is a separate expression in the meta-expr context.
 *
 * The tag itself is a dot path (`@:flash.property`), matching
 * `HxMetaName`; the lookahead applies after the whole path so
 * `@:pack.name(args)` still routes through `MetaCall`.
 *
 * The lookahead `(?=\()` does NOT consume the `(`; the structural
 * branch's `@:lead('(')` field consumes it as the open of the args
 * list. Any whitespace between name and `(` breaks the lookahead, the
 * branch rolls back via `tryBranch`, and parsing falls through to the
 * paren-less `Meta(name:HxMetaName)` branch — preserving the Haxe
 * source-level rule that `@:meta args` has whitespace separating the
 * meta from a paren expression in value position.
 *
 * `from String to String` keeps test call-site literals compiling.
 * `@:rawString` routes the matched slice through `Lowering.lower-
 * Terminal` without the JSON-style unescape loop.
 */
@:re('@:?[A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*(?=\\()')
@:rawString
abstract HxMetaNameTight(String) from String to String {}
