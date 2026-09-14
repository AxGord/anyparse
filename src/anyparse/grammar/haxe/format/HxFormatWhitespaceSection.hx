package anyparse.grammar.haxe.format;

/**
 * `whitespace` section of a haxe-formatter `hxformat.json` config. Only keys whose runtime
 * knob exists on `HxModuleWriteOptions` are modelled; missing keys (`catchPolicy`,
 * `ternaryPolicy`, …) are silently dropped by the ByName struct parser's `UnknownPolicy.Skip`
 * and land with their writer knob. Each policy key feeds the knob of the same name
 * (`objectFieldColonPolicy` → `objectFieldColon`, `typeHintColonPolicy` → `typeHintColon`,
 * `typeCheckColonPolicy` → `typeCheckColon`, `typeParamOpenPolicy` / `typeParamClosePolicy`,
 * `functionTypeHaxe4Policy` / `functionTypeHaxe3Policy`, `arrowFunctionsPolicy`, `ifPolicy` /
 * `forPolicy` / `whilePolicy` / `switchPolicy` / `tryPolicy`); the nested `parenConfig.*.
 * openingPolicy` sub-keys feed `funcParamParens` / `callParens` / `anonFuncParens`, and
 * `bracesConfig.anonTypeBraces` / `objectLiteralBraces` feed the `*BracesOpen` / `*BracesClose`
 * pair. The knob's site and value semantics live on `HxModuleWriteOptions` and the grammar
 * field that consumes it.
 *
 * Two mappings are not one-to-one. `binopPolicy` feeds `typeParamDefaultEquals` — upstream's
 * key controls spacing of every binary operator, and it routes to the only binop site the
 * writer exposes as a knob; a future binop site adopting its own `@:fmt` flag should extend
 * this mapping rather than introduce a separate JSON key. `typeCheckColonPolicy` is kept
 * separate from `typeHintColonPolicy` so the type-annotation default can stay `None`
 * (`x:Int`) while the type-check default stays `Around` (`(e : T)`) — upstream's two `:` sites
 * use opposite conventions.
 *
 * `addLineCommentSpace` rewrites `//foo` to `// foo` while decoration runs (`//*****`,
 * `//----`) survive tight. `normalizeLineCommentIndent` (default `false`, an anyparse
 * extension) normalises the leading whitespace of a `//` body to one space, and across a
 * CONTIGUOUS run of `//` entries strips the run's common post-`//` indent first, so a block
 * of commented-out code keeps its relative indentation and loses only the shared
 * over-indent; only an ASCII-letter/digit-headed body feeds the fold, every other body (an
 * empty `//`, a divider, a `//!` marker, a `///`, a `}` closer) rides the run's shift when
 * its own indent opens with the common prefix and is otherwise left to the
 * `addLineCommentSpace` path, and a block-comment entry breaks the run. Both are consumed by
 * `anyparse.format.comment.LineCommentNormalizer.normalizeLineComment`.
 * `compressSuccessiveParenthesis` (`true` by default) glues a call-arg `(` to a following
 * object-literal `{`. `formatStringInterpolation` and `optionalSemicolon` are documented on
 * their `HxModuleWriteOptions` fields.
 */
@:peg typedef HxFormatWhitespaceSection = {

	@:optional var objectFieldColonPolicy: HxFormatWhitespacePolicy;

	@:optional var typeHintColonPolicy: HxFormatWhitespacePolicy;

	@:optional var typeCheckColonPolicy: HxFormatWhitespacePolicy;

	@:optional var typeParamOpenPolicy: HxFormatWhitespacePolicy;

	@:optional var typeParamClosePolicy: HxFormatWhitespacePolicy;

	@:optional var binopPolicy: HxFormatWhitespacePolicy;

	@:optional var conditionalCompilationBinop: Bool;

	@:optional var intervalPolicy: HxFormatWhitespacePolicy;

	@:optional var functionTypeHaxe4Policy: HxFormatWhitespacePolicy;

	@:optional var functionTypeHaxe3Policy: HxFormatWhitespacePolicy;

	@:optional var arrowFunctionsPolicy: HxFormatWhitespacePolicy;

	@:optional var ifPolicy: HxFormatWhitespacePolicy;

	@:optional var forPolicy: HxFormatWhitespacePolicy;

	@:optional var whilePolicy: HxFormatWhitespacePolicy;

	@:optional var switchPolicy: HxFormatWhitespacePolicy;

	@:optional var tryPolicy: HxFormatWhitespacePolicy;

	@:optional var addLineCommentSpace: Bool;

	@:optional var normalizeLineCommentIndent: Bool;

	@:optional var compressSuccessiveParenthesis: Bool;

	@:optional var formatStringInterpolation: Bool;

	@:optional var optionalSemicolon: HxFormatOptionalSemicolonPolicy;

	/**
	 * The optional `;` between a value-`if`'s then-branch and its `else`
	 * (`final x = if (c) a; else b;`) -- a separate key from
	 * `optionalSemicolon`, sharing only its three-way policy type. Default
	 * `"preserve"` re-emits what the source had; `"never"` drops it wherever
	 * an `else` follows; `"always"` writes it there. With no `else` the `;`
	 * can belong to the enclosing statement, so every value keeps source
	 * presence in that shape. Feeds `opt.semicolonBeforeElse`.
	 */
	@:optional var semicolonBeforeElse: HxFormatOptionalSemicolonPolicy;

	@:optional var parenConfig: HxFormatParenConfigSection;

	@:optional var bracesConfig: HxFormatBracesConfigSection;

	@:optional var bracketConfig: HxFormatBracketConfigSection;
};
