package anyparse.grammar.haxe;

import anyparse.format.ArrayMatrixWrap;
import anyparse.format.BodyPolicy;
import anyparse.format.BracePlacement;
import anyparse.format.CommentEmptyLinesPolicy;
import anyparse.format.CommentStyle;
import anyparse.format.ConditionalIndentationPolicy;
import anyparse.format.EmptyCurly;
import anyparse.format.Encoding;
import anyparse.format.KeepEmptyLinesPolicy;
import anyparse.format.KeywordPlacement;
import anyparse.format.MetadataLineEndPolicy;
import anyparse.format.OperatorSpacing;
import anyparse.format.OptionalSemicolon;
import anyparse.format.RightCurlyPlacement;
import anyparse.format.SameLinePolicy;
import anyparse.format.TrailingCommaPolicy;
import anyparse.format.UniformStatementBlanksPolicy;
import anyparse.format.WhitespacePolicy;
import anyparse.format.text.FieldLookup;
import anyparse.format.text.KeySyntax;
import anyparse.format.text.MissingPolicy;
import anyparse.format.text.TextFormat;
import anyparse.format.text.TrailingSepPolicy;
import anyparse.format.text.UnknownPolicy;
import anyparse.format.wrap.WrapConditionType;
import anyparse.format.wrap.WrapMode;
import anyparse.format.wrap.WrapRules;
import anyparse.format.wrap.WrappingLocation;
import anyparse.grammar.haxe.format.HxBetweenImportsLevel;
import haxe.Exception;

using StringTools;

/**
 * Text-format descriptor for the Haxe programming language.
 *
 * **Known debt**: the `TextFormat` interface was designed for structured-
 * text formats in the JSON family (mapping open/close, sequence open/close,
 * quote characters, key/value separator, trailing-separator policy, …).
 * These concepts do not apply cleanly to a programming language — `{}` in
 * Haxe delimits a class body, not a JSON mapping, and the literal
 * vocabulary of the language is far richer than anything a `TextFormat`
 * can express.
 *
 * `FormatReader.resolveText` in the Phase 2 macro pipeline reads the WHOLE descriptor —
 * `whitespace`, the JSON-family literal vocabulary, `spacedLeads` / `tightLeads`, and
 * `lineComment` / `blockComment`, which become `FormatInfo.commentPatterns`. The doc here
 * used to claim only `whitespace` was read; anyone evaluating whether a comment or
 * lexical pass could be GENERATED from this declaration got the wrong answer from that
 * sentence, since the delimiters it would need are declared right here. (That derivation
 * was measured and refused for a different reason — the `${ … }` hole boundary no
 * declaration expresses; the verdict is on `HaxeLexicalRegions`'s class doc.) Placeholder
 * values for the JSON-shaped fields are still enough to drive the pipeline. A dedicated
 * `LanguageFormat` interface will appear once the Pratt / Indent strategies demand
 * format-provided data that cannot be expressed as a `TextFormat` shape; until then this
 * class lives in the grammar package rather than polluting `anyparse.format.text.*`.
 *
 * Singleton for the same reason as `JsonFormat`: the fields are pure
 * configuration with no per-parse state.
 */
@:nullSafety(Strict)
final class HaxeFormat implements TextFormat {

	public static final instance: HaxeFormat = new HaxeFormat();

	public var name(default, null): String = 'Haxe';
	public var version(default, null): String = '4';
	public var encoding(default, null): Encoding = Encoding.UTF8;
	public var mappingOpen(default, null): String = '{';
	public var mappingClose(default, null): String = '}';
	public var sequenceOpen(default, null): Null<String> = null;
	public var sequenceClose(default, null): Null<String> = null;
	public var keyValueSep(default, null): String = ':';
	public var entrySep(default, null): String = ',';
	public var whitespace(default, null): String = ' \t\n\r';

	/**
	 * This format supplies the generated `AstPreds` / `AstPredsT` /
	 * `AstPredsS` typed-predicate marker classes (see `HxPredBuild`).
	 * Read at macro time by `FormatReader` into `FormatInfo.astPreds`;
	 * gates the emission sites without a per-Star `@:fmt` opt-in.
	 */
	public var astPreds(default, null): Bool = true;

	public var lineComment(default, null): Null<String> = '//';
	public var blockComment(default, null): Null<BlockCommentDelims> = { open: '/*', close: '*/' };
	public var keySyntax(default, null): KeySyntax = KeySyntax.Unquoted;
	public var stringQuote(default, null): Array<String> = ['"', "'"];
	public var fieldLookup(default, null): FieldLookup = FieldLookup.ByName;
	public var trailingSep(default, null): TrailingSepPolicy = TrailingSepPolicy.Disallowed;
	public var onMissing(default, null): MissingPolicy = MissingPolicy.Error;
	public var onUnknown(default, null): UnknownPolicy = UnknownPolicy.Error;

	/**
	 * Star struct field open-delimiters that take a leading space from
	 * the preceding token. For Haxe only `{` block-opens do — `(` and
	 * `[` stay tight against the previous identifier, yielding
	 * `function main()` / `a[0]` / `new Foo(x)` rather than
	 * `function main ()` / `a [0]` / `new Foo (x)`.
	 */
	public var spacedLeads(default, null): Array<String> = ['{'];

	/**
	 * Optional `@:lead(...)` strings that emit tight — no leading
	 * separator, no trailing space. For Haxe the type-annotation colon
	 * is the canonical tight lead, so `function f():Int` and
	 * `var x:Type` keep their compact native layout instead of the
	 * spaced ` : ` that would be applied to keyword-like leads
	 * (`else`, `catch`).
	 */
	public var tightLeads(default, null): Array<String> = [':'];

	public var intLiteral(default, null): EReg = ~/^-?(?:0|[1-9][0-9]*)/;
	public var floatLiteral(default, null): EReg = ~/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?/;
	public var boolLiterals(default, null): Null<BoolLiterals> = { trueLit: 'true', falseLit: 'false' };
	public var nullLiteral(default, null): Null<String> = 'null';

	/**
	 * Default `WriteOptions` for Haxe output: tab indent, 4-column tab width, terminal newline.
	 * Generated Haxe writers use this struct when the caller omits the `options` argument to
	 * `write()`. Declared as `HxModuleWriteOptions` (not the base `WriteOptions`) so the
	 * Haxe-specific knobs are present in the defaulted struct — generated writers cast this
	 * value to `HxModuleWriteOptions` at entry.
	 *
	 * Every default MIRRORS haxe-formatter's `@:default` for the same key (its `sameLine`,
	 * `lineEnds`, `whitespace`, `emptyLines`, `indentation` and `wrapping` sections, including the
	 * ported wrap-rule cascades), so an unconfigured tree formats the way the fork formats it;
	 * the value semantics live on `HxModuleWriteOptions` and on the grammar fields that consume
	 * each knob. The deliberate DIVERGENCES, each a decision rather than an omission:
	 *
	 * - `returnBody` is `FitLine` where the fork says `Same` — the fork's `Same` wraps long
	 *   values via its separate `wrapping.maxLineLength` pass, which corresponds to our `FitLine`.
	 * - `throwBody` is `Same` — the fork has no `throwBody` knob and leaves `throw <expr>` inline
	 *   regardless of length, deferring any wrap to the value's own chain / fill rules.
	 * - `expressionCase` is `Keep` where the fork says `Same` — `Keep` gates on source
	 *   same-line-ness, so a multi-line source body keeps its `VarStmt` `@:trailOpt(';')`
	 *   cascade instead of collapsing.
	 * - `leftCurly` exposes only `Same` / `Next` — the fork's `Before` / `Both` collapse to `Next`,
	 *   and its inline `None` shape is not modelled; the global value cascades into every
	 *   per-construct `*LeftCurly` / `*EmptyCurly` / `*RightCurly` knob, a per-construct sub-key
	 *   overriding the cascade (the fork's `getCurlyPolicy` precedence).
	 * - `anonFuncParens` is `None` — the fork's `auto` heuristic is not modelled and collapses to
	 *   tight `function(args)`.
	 * - `objectFieldColon` is `After` (`{a: 0}`), `typeHintColon` `None` (`x:Int`) and
	 *   `typeCheckColon` `Both` (`("" : String)`) — three `:` sites with three upstream
	 *   conventions, each mirrored separately.
	 * - `betweenImportsLevel` is `All` and the inter-member blank counts collapse any positive
	 *   value to one blank (the emission path is a boolean contributor, not a count loop).
	 * - The `multiline` predicate behind `afterMultilineDecl` / `beforeMultilineDecl` /
	 *   `betweenSingleLineTypes` is grammar-derived at compile time by
	 *   `WriterLowering.buildMultilinePredicate` from the `@:fmt(multilineWhen*)` /
	 *   `@:fmt(multilineCtor)` annotations — zero runtime reflection.
	 */
	public var defaultWriteOptions(default, null): HxModuleWriteOptions = {
		indentChar: Tab,
		indentSize: 1,
		tabWidth: 4,
		lineWidth: 160,
		lineEnd: '\n',
		finalNewline: true,
		trailingWhitespace: false,
		maxConsecutiveBlanks: 1,
		commentStyle: CommentStyle.Verbatim,
		sameLineElse: SameLinePolicy.Same,
		sameLineCatch: SameLinePolicy.Same,
		sameLineDoWhile: SameLinePolicy.Same,
		sameLineExpressionElse: SameLinePolicy.Same,
		trailingCommaArrays: false,
		trailingCommaArgs: false,
		trailingCommaParams: false,
		trailingCommaObjectLits: false,
		trailingCommaAnonTypes: false,
		ifBody: BodyPolicy.Keep,
		elseBody: BodyPolicy.Keep,
		forBody: BodyPolicy.Keep,
		whileBody: BodyPolicy.Keep,
		doBody: BodyPolicy.Keep,
		returnBody: BodyPolicy.FitLine,
		returnBodySingleLine: BodyPolicy.FitLine,
		throwBody: BodyPolicy.Same,
		catchBody: BodyPolicy.Next,
		tryBody: BodyPolicy.Next,
		caseBody: BodyPolicy.Keep,
		expressionCase: BodyPolicy.Keep,
		functionBody: BodyPolicy.Next,
		anonFunctionBody: BodyPolicy.Same,
		untypedBody: BodyPolicy.Same,
		expressionIfBody: BodyPolicy.Same,
		expressionElseBody: BodyPolicy.Same,
		expressionForBody: BodyPolicy.Keep,
		expressionIfWithBlocks: false,
		expressionIfWithBrackets: false,
		dropSingleStmtBraces: false,
		singleStmtBraceSymmetry: false,
		condDirectiveOpSpacing: OperatorSpacing.Keep,
		dropSwitchSubjectParens: false,
		optionalSemicolon: OptionalSemicolon.Preserve,
		semicolonBeforeElse: OptionalSemicolon.Preserve,
		leftCurly: BracePlacement.Same,
		emptyCurly: EmptyCurly.Same,
		objectLiteralLeftCurly: BracePlacement.Same,
		anonTypeLeftCurly: BracePlacement.Same,
		anonFunctionLeftCurly: BracePlacement.Same,
		anonFunctionEmptyCurly: EmptyCurly.Same,
		blockLeftCurly: BracePlacement.Same,
		blockEmptyCurly: EmptyCurly.Same,
		blockRightCurly: RightCurlyPlacement.Same,
		anonFunctionRightCurly: RightCurlyPlacement.Same,
		anonTypeRightCurly: RightCurlyPlacement.Same,
		objectLiteralRightCurly: RightCurlyPlacement.Same,
		objectFieldColon: WhitespacePolicy.After,
		typeHintColon: WhitespacePolicy.None,
		typeCheckColon: WhitespacePolicy.Both,
		funcParamParens: WhitespacePolicy.None,
		callParens: WhitespacePolicy.None,
		anonFuncParens: WhitespacePolicy.None,
		anonFuncParamParensKeepInnerWhenEmpty: false,
		ifPolicy: WhitespacePolicy.After,
		forPolicy: WhitespacePolicy.After,
		whilePolicy: WhitespacePolicy.After,
		switchPolicy: WhitespacePolicy.After,
		switchKwLeadingSpace: false,
		tryPolicy: WhitespacePolicy.After,
		elseIf: KeywordPlacement.Same,
		elseSwitch: KeywordPlacement.Keep,
		fitLineIfWithElse: false,
		expressionIfArrowBodyReflow: false,
		expressionIfFit: false,
		expressionIfFitMaxBranches: 0,
		elseIfCommentReflow: false,
		fitLineBodyGlue: false,
		loopBodyIfElseNext: false,
		conditionalExprFit: false,
		ifElseSemicolonNextLine: true,
		afterFieldsWithDocComments: CommentEmptyLinesPolicy.One,
		existingBetweenFields: KeepEmptyLinesPolicy.Keep,
		externExistingBetweenFields: KeepEmptyLinesPolicy.Keep,
		beforeDocCommentEmptyLines: CommentEmptyLinesPolicy.One,
		betweenVars: 0,
		betweenFunctions: 1,
		afterVars: 1,
		afterStaticVars: 1,
		betweenStaticFunctions: 1,
		interfaceBetweenVars: 0,
		interfaceBetweenFunctions: 0,
		interfaceAfterVars: 0,
		betweenEnumCtors: 0,
		beginType: 0,
		endType: 0,
		enumBeginType: 0,
		enumEndType: 0,
		enumAbstractBeginType: 0,
		enumAbstractEndType: 0,
		typedefBeginType: 0,
		typedefBetweenFields: 0,
		typedefExistingBetweenFields: KeepEmptyLinesPolicy.Keep,
		typedefEndType: 0,
		afterLeftCurly: KeepEmptyLinesPolicy.Keep,
		beforeRightCurly: KeepEmptyLinesPolicy.Keep,
		uniformStatementBlanks: UniformStatementBlanksPolicy.Keep,
		typedefAssign: WhitespacePolicy.Both,
		typedefIntersection: WhitespacePolicy.After,
		typeParamDefaultEquals: WhitespacePolicy.Both,
		typeParamOpen: WhitespacePolicy.None,
		typeParamClose: WhitespacePolicy.None,
		anonTypeBracesOpen: WhitespacePolicy.None,
		anonTypeBracesClose: WhitespacePolicy.None,
		objectLiteralBracesOpen: WhitespacePolicy.None,
		objectLiteralBracesClose: WhitespacePolicy.None,
		objectLiteralArrowBodyOpenPad: false,
		objectLiteralArrowBodyReflow: false,
		accessBracketsOpen: WhitespacePolicy.None,
		accessBracketsClose: WhitespacePolicy.None,
		arrayLiteralBracketsOpen: WhitespacePolicy.None,
		arrayLiteralBracketsClose: WhitespacePolicy.None,
		mapLiteralBracketsOpen: WhitespacePolicy.None,
		mapLiteralBracketsClose: WhitespacePolicy.None,
		comprehensionBracketsOpen: WhitespacePolicy.None,
		comprehensionBracketsClose: WhitespacePolicy.None,
		callParensInsideOpen: WhitespacePolicy.None,
		callParensInsideClose: WhitespacePolicy.None,
		ifCondParensInsideOpen: WhitespacePolicy.None,
		ifCondParensInsideClose: WhitespacePolicy.None,
		whileCondParensInsideOpen: WhitespacePolicy.None,
		whileCondParensInsideClose: WhitespacePolicy.None,
		switchCondParensInsideOpen: WhitespacePolicy.None,
		switchCondParensInsideClose: WhitespacePolicy.None,
		catchParensGap: WhitespacePolicy.After,
		catchParensInsideOpen: WhitespacePolicy.None,
		catchParensInsideClose: WhitespacePolicy.None,
		sharpCondParensGap: WhitespacePolicy.After,
		sharpCondParensInsideOpen: WhitespacePolicy.None,
		sharpCondParensInsideClose: WhitespacePolicy.None,
		objectLiteralWrap: HaxeFormat.defaultObjectLiteralWrap(),
		callParameterWrap: HaxeFormat.defaultCallParameterWrap(),
		arrayLiteralWrap: HaxeFormat.defaultArrayLiteralWrap(),
		// A MAP literal (`[k => v, …]`) reads its own cascade, the way the fork
		// splits `mapLiteralWrapping` off `arrayLiteralWrapping`. The fork's
		// `wrapping.mapWrap` DEFAULT is character-for-character its `arrayWrap`
		// default, so there is nothing to restate here — and the builder returns
		// a fresh struct per call, so the two never share mutable state.
		mapLiteralWrap: HaxeFormat.defaultArrayLiteralWrap(),
		multiVarWrap: HaxeFormat.defaultMultiVarWrap(),
		casePatternWrap: HaxeFormat.defaultCasePatternWrap(),
		anonTypeWrap: HaxeFormat.defaultAnonTypeWrap(),
		methodChainWrap: HaxeFormat.defaultMethodChainWrap(),
		opBoolChainWrap: HaxeFormat.defaultOpBoolChainWrap(),
		opAddSubChainWrap: HaxeFormat.defaultOpAddSubChainWrap(),
		conditionWrap: HaxeFormat.defaultConditionWrap(),
		ternaryWrap: HaxeFormat.defaultTernaryWrap(),
		functionSignatureWrap: HaxeFormat.defaultFunctionSignatureWrap(),
		anonFunctionSignatureWrap: HaxeFormat.defaultAnonFunctionSignatureWrap(),
		metadataCallParameterWrap: HaxeFormat.defaultMetadataCallParameterWrap(),
		typeParameterWrap: HaxeFormat.defaultTypeParameterWrap(),
		expressionWrappingWrap: HaxeFormat.defaultExpressionWrappingWrap(),
		implementsExtendsWrap: HaxeFormat.defaultImplementsExtendsWrap(),
		arrayMatrixWrap: ArrayMatrixWrap.MatrixWrapWithAlign,
		trailingComma: TrailingCommaPolicy.Keep,
		conditionalPolicy: ConditionalIndentationPolicy.Aligned,
		alignInlineSwitchCaseBody: false,
		comprehensionCuddledOpen: false,
		soleItemCuddledBrackets: false,
		methodChainCuddledLinks: false,
		ternaryCuddledBraces: false,
		addLineCommentSpace: true,
		normalizeLineCommentIndent: false,
		compressSuccessiveParenthesis: true,
		expressionTry: SameLinePolicy.Same,
		indentCaseLabels: true,
		indentObjectLiteral: true,
		indentComplexValueExpressions: false,
		indentVarTypeHintAnon: true,
		functionTypeHaxe4: WhitespacePolicy.Both,
		functionTypeHaxe3: WhitespacePolicy.None,
		intervalPolicy: WhitespacePolicy.None,
		arrowFunctions: WhitespacePolicy.Both,
		afterPackage: 1,
		beforePackage: 0,
		beforeUsing: 1,
		betweenImports: 0,
		betweenImportsLevel: HxBetweenImportsLevel.All,
		keepSourceBlankAcrossConditional: false,
		beforeType: 1,
		afterMultilineDecl: 1,
		beforeMultilineDecl: 1,
		afterConditionalBlock: 0,
		afterFileHeaderComment: 1,
		betweenMultilineComments: 0,
		betweenSingleLineTypes: 0,
		aroundMultilineFields: 0,
		formatStringInterpolation: true,
		metadataFunctionLineEnd: MetadataLineEndPolicy.None,
		_inExprPosition: false,
		_caseSiblingFlatWidth: -1,
		_inElseIfBranch: false,
		_inValueIfBranch: false,
		_inArrowLambdaBody: false,
		_arrowValueIfBlocked: false,
		_arrowValueIfElemTrailComment: false,
		_classExtern: false,
		_inAnonFnBody: false,
		_inTypedefBody: false,
		_inEnumAbstract: false,
		_chainModeOverride: null,
		_callArgChainNest: false,
		_suppressMore: false,
		_parenInCondition: false,
		_inTernaryCond: false,
		_suppressCallRestProbe: false,
		_suppressComplexItems: false,
		_suppressPatternRestProbe: false,
		_varKwNewline: false,
		_inFieldLevelVar: false,
		_ssbSuppress: false,
		_ssbChainSuppress: false,
		_keepFlatInner: false,
		_keepChainInParen: false,
		_intersectionOperandBreak: false,
		blockCommentAdapter: anyparse.format.comment.BlockCommentNormalizer.processCapturedBlockComment,
		lineCommentAdapter: anyparse.format.comment.LineCommentNormalizer.normalizeLineComment,
		betweenImportsPathDiffers: HxBetweenImportsLevel.pathDiffers
	};

	private function new() {}

	public function escapeChar(c: Int): String {
		return switch c {
			case '"'.code: '\\"';
			case '\\'.code: '\\\\';
			case '\n'.code: '\\n';
			case '\r'.code: '\\r';
			case '\t'.code: '\\t';
			case _:
				if (c < ' '.code)
					'\\x${c.hex(2)}';
				else
					String.fromCharCode(c);
		};
	}

	/**
	 * Escape a single character for emission inside a SINGLE-quoted Haxe
	 * string segment (`'...'`).
	 *
	 * Asymmetry with `escapeChar` (which targets double-quoted strings):
	 *  - `'` is the delimiter → escape as `\'`
	 *  - `"` is a literal character inside single-quoted strings → bare
	 *  - `$` triggers interpolation → escape as `\$` so a literal dollar
	 *    in the parsed segment doesn't accidentally start interpolation
	 *    on re-parse. (Currently the segment parser regex excludes `$`
	 *    from `HxStringLitSegment`, but the writer guards defensively.)
	 *  - `\` and control chars (`\n`, `\r`, `\t`, `\xNN`) — same as
	 *    `escapeChar`.
	 *
	 * Used by `HxStringLitSegment`'s writer (`@:unescape("singleQuoteRaw")`
	 * mode) to round-trip Haxe single-quoted strings whose literal body
	 * may contain bare `"` (very common in code that builds SQL / HTML
	 * snippets in single-quoted strings).
	 */
	public function escapeSingleQuoteChar(c: Int): String {
		return switch c {
			case '\''.code: '\\\'';
			case '\\'.code: '\\\\';
			case '$'.code: '\\$';
			case '\n'.code: '\\n';
			case '\r'.code: '\\r';
			case '\t'.code: '\\t';
			case _:
				if (c < ' '.code)
					'\\x${c.hex(2)}';
				else
					String.fromCharCode(c);
		};
	}

	public function unescapeChar(input: String, pos: Int): UnescapeResult {
		final esc: Null<Int> = input.charCodeAt(pos);
		if (esc == null) throw new Exception('unterminated escape at $pos');
		return switch esc {
			case '"'.code: { char: '"'.code, consumed: 1 };
			case '\\'.code: { char: '\\'.code, consumed: 1 };
			case 'n'.code: { char: '\n'.code, consumed: 1 };
			case 'r'.code: { char: '\r'.code, consumed: 1 };
			case 't'.code: { char: '\t'.code, consumed: 1 };
			case '\''.code: { char: '\''.code, consumed: 1 };
			case '$'.code: { char: '$'.code, consumed: 1 };
			case _: throw new Exception('invalid escape: \\${String.fromCharCode(esc)}');
		};
	}

	/**
	 * Default `WrapRules` cascade for `HxObjectLit.fields` — ported
	 * verbatim from haxe-formatter's `wrapping.objectLiteral` rule set
	 * in `resources/default-hxformat.json` (AxGord fork). Returned as a
	 * fresh struct on each call so test code that mutates the
	 * `defaultWriteOptions.objectLiteralWrap` substruct doesn't corrupt
	 * the singleton.
	 */
	public static function defaultObjectLiteralWrap(): WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.NoWrap,
					conditions: [
						{ cond: WrapConditionType.ItemCountLessThan, value: 3 },
						{ cond: WrapConditionType.ExceedsMaxLineLength, value: 0 }
					]
				},
				{
					mode: WrapMode.OnePerLine,
					conditions: [{ cond: WrapConditionType.AnyItemLengthLargerThan, value: 30 }]
				},
				{
					mode: WrapMode.OnePerLine,
					conditions: [{ cond: WrapConditionType.TotalItemLengthLargerThan, value: 60 }]
				},
				{
					mode: WrapMode.OnePerLine,
					conditions: [{ cond: WrapConditionType.ItemCountLargerThan, value: 4 }]
				},
				{
					mode: WrapMode.OnePerLine,
					conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 1 }]
				}
			],
			defaultMode: WrapMode.NoWrap
		};
	}

	/**
	 * Default `WrapRules` cascade for `HxExpr.Call.args` — ported
	 * verbatim from haxe-formatter's `wrapping.callParameter` rule set
	 * in `resources/default-hxformat.json` (AxGord fork). Five rules in
	 * source order: `itemCount>=7`, `totalItemLength>=140`,
	 * `anyItemLength>=80`, `lineLength>=160`, `exceedsMaxLineLength==1`
	 * — all `FillLine`, defaultMode `NoWrap`. The `lineLength>=160`
	 * rule (slice ω-callparam-linelen-160) is functionally subsumed by
	 * `totalItemLength>=140` at this default — `LineLengthLargerThan`
	 * evaluates to `totalItemLen >= n` like its sibling — but is kept
	 * present for byte-exact alignment with upstream and so user-side
	 * `hxformat.json` tweaks that lower `totalItemLength` without
	 * touching `lineLength` keep the threshold intact. Returned as a
	 * fresh struct on each call so test code that mutates the
	 * `defaultWriteOptions.callParameterWrap` substruct doesn't corrupt
	 * the singleton.
	 */
	public static function defaultCallParameterWrap(): WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.FillLine,
					conditions: [{ cond: WrapConditionType.ItemCountLargerThan, value: 7 }]
				},
				{
					mode: WrapMode.FillLine,
					conditions: [{ cond: WrapConditionType.TotalItemLengthLargerThan, value: 140 }]
				},
				{
					mode: WrapMode.FillLine,
					conditions: [{ cond: WrapConditionType.AnyItemLengthLargerThan, value: 80 }]
				},
				{
					mode: WrapMode.FillLine,
					conditions: [{ cond: WrapConditionType.LineLengthLargerThan, value: 160 }]
				},
				{
					mode: WrapMode.FillLine,
					conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 1 }]
				}
			],
			defaultMode: WrapMode.NoWrap
		};
	}

	/**
	 * Default `WrapRules` cascade for `HxExpr.ArrayExpr.elems` — ported
	 * from haxe-formatter's `wrapping.arrayWrap` rule set in
	 * `resources/default-hxformat.json` (AxGord fork). Now matches the
	 * upstream first rule `hasMultilineItems → OnePerLine` directly,
	 * after `WrapList.emit` decoupled item-multiline detection from
	 * width measurement (slice ω-flatlength-decouple-tokenwidth) — items
	 * with hardlines anywhere (incl. `BodyGroup`-deferred bodies) feed
	 * `total`/`maxLen` as clean `flatTokenWidth` while `hasMultilineItems`
	 * triggers via the new `HasMultilineItems` cascade condition. The
	 * `equalItemLengths` condition and its `fillLineWithLeadingBreak`
	 * rule remain skipped — none of the current corpus fixtures depends
	 * on it. Returned as a fresh struct on each call so test code that
	 * mutates the `defaultWriteOptions.arrayLiteralWrap` substruct
	 * doesn't corrupt the singleton.
	 */
	public static function defaultArrayLiteralWrap(): WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.OnePerLine,
					conditions: [{ cond: WrapConditionType.HasMultilineItems, value: 1 }]
				},
				{
					mode: WrapMode.NoWrap,
					conditions: [{ cond: WrapConditionType.TotalItemLengthLessThan, value: 80 }]
				},
				{
					mode: WrapMode.FillLineWithLeadingBreak,
					conditions: [
						{ cond: WrapConditionType.EqualItemLengths, value: 1 },
						{ cond: WrapConditionType.AllItemLengthsLessThan, value: 30 },
						{ cond: WrapConditionType.ItemCountLargerThan, value: 10 }
					]
				},
				{
					mode: WrapMode.FillLineWithLeadingBreak,
					conditions: [
						{ cond: WrapConditionType.AllItemLengthsLessThan, value: 10 },
						{ cond: WrapConditionType.ItemCountLargerThan, value: 10 }
					]
				},
				{
					mode: WrapMode.OnePerLine,
					conditions: [{ cond: WrapConditionType.AnyItemLengthLargerThan, value: 30 }]
				},
				{
					mode: WrapMode.OnePerLine,
					conditions: [{ cond: WrapConditionType.ItemCountLargerThan, value: 4 }]
				},
				{
					mode: WrapMode.OnePerLine,
					conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 1 }]
				}
			],
			defaultMode: WrapMode.NoWrap
		};
	}

	/**
	 * Default `WrapRules` cascade for a `for`/`while` array COMPREHENSION
	 * (`[for (x in xs) body]`) under `sameLine.comprehensionFor: fitLine`. A
	 * comprehension has a single generator element whose flat width routinely
	 * exceeds the generic `defaultArrayLiteralWrap` fixed thresholds
	 * (`anyItemLength > 30`, `totalItemLength >= 80`); applying them breaks the
	 * `[` onto its own line as soon as the for-expr passes ~80 chars, ignoring
	 * `maxLineLength`. The fit policy instead keeps the comprehension flat while
	 * the physical line fits and breaks one-per-line only on genuine
	 * `maxLineLength` overflow. Returned as a fresh struct on each call for parity
	 * with the sibling `default*Wrap` builders.
	 */
	public static function defaultComprehensionWrap(): WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.OnePerLine,
					conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 1 }]
				}
			],
			defaultMode: WrapMode.NoWrap
		};
	}

	/**
	 * Whether `element` is the GENERATOR of an array comprehension — an
	 * `HxExpr.ForExpr` / `HxExpr.WhileExpr` sitting as an element of an
	 * `HxExpr.ArrayExpr`.
	 *
	 * The RUNTIME answer to "is this bracketed list a comprehension?", for the
	 * writer-side consumers that hold their element untyped: the sep-Star
	 * cascade swap and its source-newline scan
	 * (`TriviaSepLowering.triviaSepStarExpr` / `triviaSepPredicateScanExpr`)
	 * and the decl-RHS `=`-break disarm
	 * (`WriterLowering.breakAfterLeadOnOverflowWrap`). The macro-side
	 * `arrayBracketKind` predicate answers the same question for typed input;
	 * the two share only their ctor list, `HxComprehension.GENERATOR_CTORS`,
	 * which records why they cannot share a body.
	 *
	 * `Any` because the callers are generated by the grammar-agnostic writer
	 * lowering, which holds elements as untyped values. Two shapes arrive:
	 * the bare `HxExpr`, and the trivia-synth wrapper
	 * `{node: HxExpr, leadingComments: …}` that a `@:trivia` Star carries.
	 * Anything else — a non-array Star's struct element, a null slot —
	 * answers `false` rather than throwing, so a caller needs no shape gate
	 * of its own.
	 */
	public static function isComprehensionGenerator(element: Null<Any>): Bool {
		var node: Null<Any> = element;
		if (node != null && !Reflect.isEnumValue(node)) node = Reflect.field(node, 'node');
		if (node == null || !Reflect.isEnumValue(node)) return false;
		return HxComprehension.GENERATOR_CTORS.contains(Type.enumConstructor(node));
	}

	/**
	 * Default `WrapRules` cascade for `HxVarDecl.more` — the binding list
	 * of a multi-variable declaration (`var a = 1, b = 2, c = 3;`).
	 * Ported from haxe-formatter's `wrapping.multiVar` rule set in
	 * `resources/default-hxformat.json` (AxGord fork): short items pack
	 * via `FillLine`, wide bindings break one-per-line-after-first once
	 * the column or the configured `maxLineLength` is exceeded.
	 *
	 * Divergence note: the fork's rule 1 condition is `anyItemLength <= n`
	 * (MIN item length ≤ n — "at least one short binding"); anyparse has
	 * no min≤n `WrapConditionType`, so `AllItemLengthsLessThan` (MAX ≤ n —
	 * "every binding short") is used instead. The two coincide on every
	 * corpus target (issue_355 bindings ~30 > 15 → both miss; issue_430
	 * bindings ≤ 3 → both fire); they diverge only on mixed-width wide
	 * decls, which fail regardless. Returned as a fresh struct on each
	 * call so test code that mutates the
	 * `defaultWriteOptions.multiVarWrap` substruct doesn't corrupt the
	 * singleton.
	 */
	public static function defaultMultiVarWrap(): WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.FillLine,
					conditions: [{ cond: WrapConditionType.AllItemLengthsLessThan, value: 15 }]
				},
				{
					mode: WrapMode.OnePerLineAfterFirst,
					conditions: [{ cond: WrapConditionType.LineLengthLargerThan, value: 80 }]
				},
				{
					mode: WrapMode.OnePerLineAfterFirst,
					conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 1 }]
				}
			],
			defaultMode: WrapMode.NoWrap
		};
	}

	/**
	 * Default `WrapRules` cascade for `HxCaseBranch.patterns` — the
	 * comma-separated pattern list of a multi-value `case` label
	 * (`case A, B, C:`). Ported verbatim from haxe-formatter's
	 * `wrapping.casePattern` rule set in `config/WrapConfig.hx` (AxGord
	 * fork): single/double patterns stay flat (`NoWrap` default), lists
	 * of three or more pack Wadler-style via `FillLine`, and any list
	 * that overflows `maxLineLength` also fills. Consumed at the fork's
	 * `markSingleCasePatternChain`. Returned as a fresh struct on each
	 * call so test code that mutates the
	 * `defaultWriteOptions.casePattern` substruct doesn't corrupt the
	 * singleton.
	 */
	public static function defaultCasePatternWrap(): WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.FillLine,
					conditions: [{ cond: WrapConditionType.ItemCountLargerThan, value: 2 }]
				},
				{
					mode: WrapMode.FillLine,
					conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 1 }]
				}
			],
			defaultMode: WrapMode.NoWrap
		};
	}

	/**
	 * Default `WrapRules` cascade for `HxType.Anon.fields` — ported
	 * from haxe-formatter's `wrapping.anonType` rule set in
	 * `resources/default-hxformat.json` (AxGord fork). The full rule
	 * set encodes cleanly against the current `WrapConditionType`
	 * surface: short anon types stay flat via the AND-conjunction of
	 * `itemCount<=3` and `exceedsMaxLineLength==0`, with three
	 * cascading `OnePerLine` triggers (`anyItemLength>=30`,
	 * `totalItemLength>=60`, `itemCount>=4`) and `FillLine` as the
	 * `exceedsMaxLineLength==1` fallback. Returned as a fresh struct on
	 * each call so test code that mutates the
	 * `defaultWriteOptions.anonTypeWrap` substruct doesn't corrupt the
	 * singleton.
	 */
	public static function defaultAnonTypeWrap(): WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.NoWrap,
					conditions: [
						{ cond: WrapConditionType.ItemCountLessThan, value: 3 },
						{ cond: WrapConditionType.ExceedsMaxLineLength, value: 0 }
					]
				},
				{
					mode: WrapMode.OnePerLine,
					conditions: [{ cond: WrapConditionType.AnyItemLengthLargerThan, value: 30 }]
				},
				{
					mode: WrapMode.OnePerLine,
					conditions: [{ cond: WrapConditionType.TotalItemLengthLargerThan, value: 60 }]
				},
				{
					mode: WrapMode.OnePerLine,
					conditions: [{ cond: WrapConditionType.ItemCountLargerThan, value: 4 }]
				},
				{
					mode: WrapMode.NoWrap,
					conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 1 }]
				}
			],
			defaultMode: WrapMode.NoWrap
		};
	}

	/**
	 * Default `WrapRules` cascade for postfix `.method(args)` chains — ported from haxe-formatter's
	 * `wrapping.methodChain` rule set, the full cascade including the leading `lineLength >= 160`
	 * rule. That rule is sound only because `MethodChainEmit.chainItemLength` defers `BodyGroup`
	 * content the way the renderer's `fitsFlat` does: a static width that descends into a
	 * multi-line lambda / block / struct-literal body inflates the total and fires for chains
	 * the renderer keeps flat. `MethodChainEmit.emit` evaluates through
	 * `decideWithLineLengthState` + `IfWidthExceeds`, so at the default `lineWidth` the leading
	 * rule collapses to the `exceeds` semantic via the standard `IfBreak` pivot, and a modified
	 * `lineWidth` routes the answer through the renderer's column-aware probe.
	 *
	 * ω-methodchain-all-or-nothing DIVERGES FROM UPSTREAM here, by user decision: every break
	 * mode is `OnePerLine`, where the fork's rule set says `OnePerLineAfterFirst`. A broken chain
	 * therefore leaves its head line bare instead of gluing the first link to it — the companion
	 * half of `MethodChainEmit`'s head-end-column probe. This is the one place the ported cascade
	 * no longer matches the fork; read it before concluding that a disagreeing fork corpus
	 * fixture is a bug.
	 *
	 * Returned as a fresh struct on each call so test code that mutates the
	 * `defaultWriteOptions.methodChainWrap` substruct does not corrupt the singleton.
	 */
	public static function defaultMethodChainWrap(): WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.OnePerLine,
					conditions: [{ cond: WrapConditionType.LineLengthLargerThan, value: 160 }]
				},
				{
					mode: WrapMode.NoWrap,
					conditions: [
						{ cond: WrapConditionType.ItemCountLessThan, value: 3 },
						{ cond: WrapConditionType.ExceedsMaxLineLength, value: 0 }
					]
				},
				{
					mode: WrapMode.NoWrap,
					conditions: [
						{ cond: WrapConditionType.TotalItemLengthLessThan, value: 80 },
						{ cond: WrapConditionType.ExceedsMaxLineLength, value: 0 }
					]
				},
				{
					mode: WrapMode.OnePerLine,
					conditions: [
						{ cond: WrapConditionType.AnyItemLengthLargerThan, value: 30 },
						{ cond: WrapConditionType.ItemCountLargerThan, value: 4 }
					]
				},
				{
					mode: WrapMode.OnePerLine,
					conditions: [{ cond: WrapConditionType.ItemCountLargerThan, value: 7 }]
				},
				{
					mode: WrapMode.OnePerLine,
					conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 1 }]
				}
			],
			defaultMode: WrapMode.NoWrap,
			// ω-methodchain-all-or-nothing: this cascade is the Haxe layout
			// POLICY, so it uses fork's isDotAfterPClose item rule. A user
			// `wrapping.methodChain` section replaces the whole struct and does
			// not inherit the flag, keeping explicit modes on fork's literal
			// semantics; such a section opts back in with
			// `itemsAfterCloseParenOnly: true` (slice F3).
			chainItemsAfterCloseParenOnly: true
		};
	}

	/**
	 * Default `WrapRules` cascade for `||` / `&&` chains.
	 *
	 * **Pivot (slice ω-drop-soft-thresholds):** anyparse-core defaults
	 * adopt **one hard limit** (`lineWidth`) and drop fork's two leading
	 * soft-threshold rules (`lineLength >= 140 → OnePerLineAfterFirst`
	 * and `lineLength >= 140 → FillLine`). Soft thresholds are a
	 * Haxe-formatter author's stylistic choice (wrap proactively well
	 * short of the hard limit), not universal truth — JSON / AS3 / future
	 * grammars inherit anyparse-core defaults and should not pay the
	 * per-cascade `IfWidthExceeds(140, …)` render-probe cost or carry a
	 * Haxe-specific aesthetic. Users who want fork-style aesthetic for
	 * Haxe load a custom `hxformat.json` that re-introduces the
	 * `wrapping.opBoolChain.lineLength` rules.
	 *
	 * Rules (first-match):
	 *  1. `itemCount <= 3` + `!exceeds` → NoWrap
	 *  2. `totalItemLength <= 120` + `!exceeds` → NoWrap
	 *  3. `itemCount >= 4` → OnePerLineAfterFirst
	 *  4. `exceeds` → FillLine
	 *
	 * `defaultMode: NoWrap` preserves the cascade-level fallback for
	 * the rare case where no rule matches (only possible when the
	 * chain is exactly 0/1 items, which the engine short-circuits).
	 *
	 * Rule 4 mode is `FillLine` so a chain that exceeds the hard limit
	 * but has < 4 items packs Wadler-style rather than collapsing to
	 * one-per-line. Rule 3 fires first for ≥ 4 items.
	 *
	 * `location: BeforeLast` on every wrapping rule mirrors fork's
	 * per-rule setting and shields each rule from the cascade-level
	 * `defaultLocation: AfterLast` fallback.
	 *
	 * Divergence from upstream `default-hxformat.json wrapping.opBoolChain`:
	 * rules 1, 2 (`lineLength >= 140`) intentionally absent. Slice
	 * ω-drop-soft-thresholds confirmed Δ pass = 0 across all 3 corpus
	 * buckets (ws / sl / idn) on the AxGord fork fixtures — the dropped
	 * rules were redundant with rules 3 / 4 on the existing corpus and
	 * carried real per-cascade `IfWidthExceeds(140, …)` probe overhead.
	 */
	public static function defaultOpBoolChainWrap(): WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.NoWrap,
					conditions: [
						{ cond: WrapConditionType.ItemCountLessThan, value: 3 },
						{ cond: WrapConditionType.ExceedsMaxLineLength, value: 0 }
					]
				},
				{
					mode: WrapMode.NoWrap,
					conditions: [
						{ cond: WrapConditionType.TotalItemLengthLessThan, value: 120 },
						{ cond: WrapConditionType.ExceedsMaxLineLength, value: 0 }
					]
				},
				{
					mode: WrapMode.OnePerLineAfterFirst,
					location: WrappingLocation.BeforeLast,
					conditions: [{ cond: WrapConditionType.ItemCountLargerThan, value: 4 }]
				},
				{
					mode: WrapMode.FillLine,
					location: WrappingLocation.BeforeLast,
					conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 1 }]
				}
			],
			defaultMode: WrapMode.NoWrap
		};
	}

	/**
	 * Default `WrapRules` cascade for `+` / `-` chains.
	 *
	 * **Pivot (slice ω-drop-soft-thresholds):** sister of
	 * `defaultOpBoolChainWrap` — anyparse-core defaults adopt **one
	 * hard limit** and drop fork's two leading soft-threshold rules
	 * (`lineLength >= 160 → OnePerLineAfterFirst` and `lineLength >= 160
	 * → FillLine`). Rationale identical: soft thresholds bias plugin
	 * grammars toward Haxe-formatter aesthetic; users opt in via
	 * custom `hxformat.json`.
	 *
	 * Rules (first-match):
	 *  1. `itemCount <= 3` + `!exceeds` → NoWrap
	 *  2. `totalItemLength <= 120` + `!exceeds` → NoWrap
	 *  3. `itemCount >= 4` → OnePerLineAfterFirst
	 *  4. `exceeds` → OnePerLineAfterFirst
	 *
	 * `defaultMode: NoWrap` preserves the cascade-level fallback.
	 *
	 * Diverges from `defaultOpBoolChainWrap` only in rule 4 mode
	 * (`OnePerLineAfterFirst` vs `FillLine`) — matches fork's
	 * per-cascade choice and anyparse's pre-cascade behaviour for
	 * `+` / `-`.
	 *
	 * `location: BeforeLast` on every wrapping rule mirrors fork's
	 * per-rule setting and shields each rule from the cascade-level
	 * `defaultLocation: AfterLast` fallback.
	 *
	 * Divergence from upstream `default-hxformat.json wrapping.opAddSubChain`:
	 * rules 1, 2 (`lineLength >= 160`) intentionally absent. The dropped
	 * rule 2 (`exceeds → FillLine`) was the sole source of Wadler-style
	 * packing for `+` / `-` chains — long string-concat throws (e.g.
	 * issue_179) now apply rule 3 / 4 (one operand per line) when they
	 * exceed the hard limit. Slice ω-drop-soft-thresholds confirmed
	 * Δ pass = 0 across all 3 corpus buckets; issue_179 stays in the
	 * existing fail bucket as fork-divergence-by-design with a shifted
	 * byte-diff signature (see project memory).
	 */
	public static function defaultOpAddSubChainWrap(): WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.NoWrap,
					conditions: [
						{ cond: WrapConditionType.ItemCountLessThan, value: 3 },
						{ cond: WrapConditionType.ExceedsMaxLineLength, value: 0 }
					]
				},
				{
					mode: WrapMode.NoWrap,
					conditions: [
						{ cond: WrapConditionType.TotalItemLengthLessThan, value: 120 },
						{ cond: WrapConditionType.ExceedsMaxLineLength, value: 0 }
					]
				},
				{
					mode: WrapMode.OnePerLineAfterFirst,
					location: WrappingLocation.BeforeLast,
					conditions: [{ cond: WrapConditionType.ItemCountLargerThan, value: 4 }]
				},
				{
					mode: WrapMode.OnePerLineAfterFirst,
					location: WrappingLocation.BeforeLast,
					conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 1 }]
				}
			],
			defaultMode: WrapMode.NoWrap
		};
	}

	/**
	 * Default `WrapRules` cascade for statement-condition parens
	 * (`if (cond)`, `for (item in coll)`, `while (cond)`, `switch
	 * (expr)`). Slice ω-condition-wrap-ingest foundational scaffold —
	 * the writer does not consume this field yet, so the default is
	 * deliberately minimal: empty rules + `defaultMode: NoWrap`, which
	 * preserves pre-slice byte output. Engine + grammar wiring lands in
	 * a follow-up slice; user `hxformat.json` `wrapping.conditionWrapping`
	 * configs are still ingested by the loader so the cascade is
	 * available when the wiring slice ships.
	 *
	 * Returned as a fresh struct on each call so test code that mutates
	 * the `defaultWriteOptions.conditionWrap` substruct doesn't corrupt
	 * the singleton.
	 */
	public static function defaultConditionWrap(): WrapRules {
		return {
			rules: [],
			defaultMode: WrapMode.NoWrap
		};
	}

	/**
	 * Default `WrapRules` cascade for the `? :` ternary
	 * (haxe-formatter `ternaryExpression` class). Slice ω-ternary-wrap
	 * wires `WriterLowering`'s `@:ternary` branch into
	 * `BinaryChainEmit.emit` (items=[cond, then, else], ops=['?', ':']).
	 *
	 * Rule: `exceedsMaxLineLength=1 → OnePerLineAfterFirst, BeforeLast`
	 * mirrors fork's `resources/default-hxformat.json` ternary cascade
	 * verbatim — when the flat `cond ? then : else` line overflows the
	 * `wrapping.maxLineLength` budget, the condition stays inline with
	 * the parent and the `? then` / `: else` pair each take their own
	 * continuation line. Slice ω-ternary-default-rule.
	 *
	 * Returned as a fresh struct on each call so test code that mutates
	 * the `defaultWriteOptions.ternaryWrap` substruct doesn't corrupt
	 * the singleton.
	 */
	public static function defaultTernaryWrap(): WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.OnePerLineAfterFirst,
					location: WrappingLocation.BeforeLast,
					conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 1 }]
				}
			],
			defaultMode: WrapMode.NoWrap
		};
	}

	/**
	 * Default `WrapRules` cascade for parenthesised expressions
	 * (`(expr)` — haxe-formatter `expressionWrapping` class). Slice
	 * ω-expressionwrapping-cascade-ingest foundational scaffold —
	 * the writer does not consume this field yet, so the default is
	 * deliberately minimal: empty rules + `defaultMode: NoWrap`, which
	 * preserves pre-slice byte output. Engine + grammar wiring lands
	 * in a follow-up slice; user `hxformat.json`
	 * `wrapping.expressionWrapping` configs are still ingested by the
	 * loader so the cascade is available when the wiring slice ships.
	 *
	 * Returned as a fresh struct on each call so test code that mutates
	 * the `defaultWriteOptions.expressionWrappingWrap` substruct doesn't
	 * corrupt the singleton.
	 */
	public static function defaultExpressionWrappingWrap(): WrapRules {
		return {
			rules: [],
			defaultMode: WrapMode.NoWrap
		};
	}

	/**
	 * Default `WrapRules` cascade for named function parameter lists
	 * (haxe-formatter `functionSignature` class).
	 *
	 * Mirrors haxe-formatter's `default-hxformat.json`:
	 * `{rules: [], defaultWrap: fillLine, defaultAdditionalIndent: 1}` —
	 * empty rule set, `FillLine` mode, +1 indent unit on continuation
	 * lines. The `defaultAdditionalIndent: 1` keeps wrapped function
	 * parameters one indent level deeper than the function body so they
	 * remain visually distinct (matches the legacy `@:fmt(fill,
	 * fillDoubleIndent)` Wadler-fillSep emission this cascade replaces).
	 *
	 * Slice ω-functionsignature-wrap-ingest landed the foundational
	 * scaffold (field, default, JSON loader). Slice
	 * ω-wraplist-additional-indent extended `WrapList.emit` with the
	 * `defaultAdditionalIndent` knob, and the follow-up slice swapped
	 * `HxFnDecl.params` over to `@:fmt(wrapRules('functionSignatureWrap'))`.
	 *
	 * Returned as a fresh struct on each call so test code that mutates
	 * the `defaultWriteOptions.functionSignatureWrap` substruct doesn't
	 * corrupt the singleton.
	 */
	public static function defaultFunctionSignatureWrap(): WrapRules {
		return {
			rules: [],
			defaultMode: WrapMode.FillLine,
			defaultAdditionalIndent: 1
		};
	}

	/**
	 * Default `WrapRules` cascade for anonymous-function parameter
	 * lists — `HxFnExpr.params` (`function(...)`),
	 * `HxParenLambda.params` (`(...) => body`), and
	 * `HxThinParenLambda.params` (`(...) -> body`). Ported from
	 * haxe-formatter's `wrapping.anonFunctionSignature` rule set in
	 * `resources/default-hxformat.json` (AxGord fork): short anon-fn
	 * signatures stay flat (`defaultMode: NoWrap`) and break only when
	 * one of three cascade triggers fires — `itemCount >= 7`,
	 * `totalItemLength >= 80`, or `exceedsMaxLineLength`, all routing
	 * to `FillLine` with `+1 tab` continuation indent.
	 *
	 * Per-rule `additionalIndent` from fork's JSON is not modelled —
	 * the cascade-level `defaultAdditionalIndent: 1` is byte-equivalent
	 * because every rule in the fork's default carries the same `1`.
	 *
	 * Returned as a fresh struct on each call so test code that mutates
	 * the `defaultWriteOptions.anonFunctionSignatureWrap` substruct
	 * doesn't corrupt the singleton.
	 */
	public static function defaultAnonFunctionSignatureWrap(): WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.FillLine,
					conditions: [{ cond: WrapConditionType.ItemCountLargerThan, value: 7 }]
				},
				{
					mode: WrapMode.FillLine,
					conditions: [{ cond: WrapConditionType.TotalItemLengthLargerThan, value: 80 }]
				},
				{
					mode: WrapMode.FillLine,
					conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 1 }]
				}
			],
			defaultMode: WrapMode.NoWrap,
			defaultAdditionalIndent: 1
		};
	}

	/**
	 * Default `WrapRules` cascade for metadata-call argument lists —
	 * `HxMetaCallArgs.args` (`@:overload(args)`, `@:keep(args)`, …).
	 * Ported from haxe-formatter's `wrapping.metadataCallParameter` rule
	 * set in `resources/default-hxformat.json` (AxGord fork): meta args
	 * stay flat (`defaultMode: NoWrap`) and only break when one of three
	 * cascade triggers fires — `totalItemLength >= 140`, `lineLength >= 160`,
	 * or `exceedsMaxLineLength`, all routing to `FillLine`.
	 *
	 * The `lineLength >= 160` rule is functionally subsumed by
	 * `totalItemLength >= 140` at this default — `LineLengthLargerThan`
	 * evaluates as `totalItemLen >= n` like its sibling — but is kept
	 * present for byte-exact alignment with upstream and so user-side
	 * `hxformat.json` tweaks that lower `totalItemLength` without
	 * touching `lineLength` keep the threshold intact.
	 *
	 * Returned as a fresh struct on each call so test code that mutates
	 * the `defaultWriteOptions.metadataCallParameterWrap` substruct
	 * doesn't corrupt the singleton.
	 */
	public static function defaultMetadataCallParameterWrap(): WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.FillLine,
					conditions: [{ cond: WrapConditionType.TotalItemLengthLargerThan, value: 140 }]
				},
				{
					mode: WrapMode.FillLine,
					conditions: [{ cond: WrapConditionType.LineLengthLargerThan, value: 160 }]
				},
				{
					mode: WrapMode.FillLine,
					conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 1 }]
				}
			],
			defaultMode: WrapMode.NoWrap
		};
	}

	/**
	 * Default `WrapRules` cascade for type-parameter lists — declare-site
	 * (`HxClassDecl.typeParams`, `HxTypedefDecl.typeParams`,
	 * `HxFnDecl.typeParams`, `HxFnExpr.typeParams`,
	 * `HxEnumDecl.typeParams`, `HxAbstractDecl.typeParams`,
	 * `HxInterfaceDecl.typeParams`) and use-site (`HxTypeRef.params`).
	 * Ported from haxe-formatter's `wrapping.typeParameter` rule set in
	 * `resources/default-hxformat.json`: short `<T>` / `<K, V>` lists stay
	 * flat (`defaultMode: NoWrap`); a list breaks to Wadler-style FillLine
	 * packing when either soft threshold fires — `anyItemLength >= 50`
	 * (one very long type-param name) or `totalItemLength >= 70`
	 * (aggregate width across all entries).
	 *
	 * Returned as a fresh struct on each call so test code that mutates
	 * the `defaultWriteOptions.typeParameterWrap` substruct doesn't
	 * corrupt the singleton.
	 */
	public static function defaultTypeParameterWrap(): WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.FillLine,
					conditions: [{ cond: WrapConditionType.AnyItemLengthLargerThan, value: 50 }]
				},
				{
					mode: WrapMode.FillLine,
					conditions: [{ cond: WrapConditionType.TotalItemLengthLargerThan, value: 70 }]
				}
			],
			defaultMode: WrapMode.NoWrap
		};
	}

	/**
	 * B4 ω-implements-extends-wrap: default `wrapping.implementsExtends`
	 * cascade for class/interface heritage clauses, ported from the fork's
	 * `WrapConfig.implementsExtends` `@:default`. FillLine once the glued
	 * decl line exceeds 140 (or >4 clauses, or exceeds maxLineLength), at
	 * a continuation indent of 2 (8 spaces). anyparse `WrapRule` carries no
	 * per-rule `additionalIndent`, so the fork's per-rule `additionalIndent:
	 * 2` is modelled as `defaultAdditionalIndent: 2` (every break-mode
	 * shape in this cascade shares the same indent, so the per-rule vs
	 * default distinction is byte-equivalent here). Consumed by the
	 * dedicated heritage emit in `TriviaTryparseLowering.triviaTryparseStarExpr`.
	 *
	 * Fresh struct per call (mutation safety) — same convention as the
	 * other `default*Wrap` helpers.
	 */
	public static function defaultImplementsExtendsWrap(): WrapRules {
		return {
			rules: [
				{
					mode: WrapMode.FillLine,
					conditions: [{ cond: WrapConditionType.LineLengthLargerThan, value: 140 }]
				},
				{
					mode: WrapMode.FillLine,
					conditions: [{ cond: WrapConditionType.ItemCountLargerThan, value: 4 }]
				},
				{
					mode: WrapMode.FillLine,
					conditions: [{ cond: WrapConditionType.ExceedsMaxLineLength, value: 1 }]
				}
			],
			defaultMode: WrapMode.NoWrap,
			defaultAdditionalIndent: 2
		};
	}

}
