package anyparse.grammar.haxe;

import anyparse.format.BodyPolicy;
import anyparse.format.BracePlacement;
import anyparse.format.CommentEmptyLinesPolicy;
import anyparse.format.IndentChar;
import anyparse.format.KeepEmptyLinesPolicy;
import anyparse.format.KeywordPlacement;
import anyparse.format.SameLinePolicy;
import anyparse.format.WhitespacePolicy;
import anyparse.grammar.haxe.format.HxFormatBodyPolicy;
import anyparse.grammar.haxe.format.HxFormatClassEmptyLinesConfig;
import anyparse.grammar.haxe.format.HxFormatCommentEmptyLinesPolicy;
import anyparse.grammar.haxe.format.HxFormatConfig;
import anyparse.grammar.haxe.format.HxFormatConfigParser;
import anyparse.grammar.haxe.format.HxFormatEmptyLinesSection;
import anyparse.grammar.haxe.format.HxFormatIndentationSection;
import anyparse.grammar.haxe.format.HxFormatKeepEmptyLinesPolicy;
import anyparse.grammar.haxe.format.HxFormatKeywordPlacement;
import anyparse.grammar.haxe.format.HxFormatLeftCurlyPolicy;
import anyparse.grammar.haxe.format.HxFormatLineEndsSection;
import anyparse.grammar.haxe.format.HxFormatParenConfigSection;
import anyparse.grammar.haxe.format.HxFormatParenPolicySection;
import anyparse.grammar.haxe.format.HxFormatSameLinePolicy;
import anyparse.grammar.haxe.format.HxFormatSameLineSection;
import anyparse.grammar.haxe.format.HxFormatTrailingCommaPolicy;
import anyparse.grammar.haxe.format.HxFormatTrailingCommasSection;
import anyparse.grammar.haxe.format.HxFormatWhitespacePolicy;
import anyparse.grammar.haxe.format.HxFormatWhitespaceSection;
import anyparse.grammar.haxe.format.HxFormatWrappingSection;

/**
 * Loads a haxe-formatter `hxformat.json` config and maps the subset of
 * fields the `HxModule` writer understands into `HxModuleWriteOptions`.
 *
 * The mapping is strictly additive: anything the loader does not
 * recognise is silently ignored (forward-compatible), and every field
 * it does not find falls back to `HaxeFormat.instance.defaultWriteOptions`.
 * This makes round-tripping `HaxeFormatConfigLoader.loadHxFormatJson('{}')`
 * byte-identical to using the defaults directly.
 *
 * Recognised key paths (all optional):
 *
 * - `indentation.character`: string — `"tab"` → `indentChar = Tab, indentSize = 1`;
 *   any string composed entirely of spaces → `indentChar = Space, indentSize = length`.
 *   Every other value is ignored.
 * - `indentation.tabWidth`: int → `tabWidth`.
 * - `indentation.trailingWhitespace`: bool → `trailingWhitespace`
 *   (opt-in — default `false` keeps `Renderer.render`'s deferred-indent
 *   behaviour, `true` preserves the surrounding indent on blank rows).
 * - `wrapping.maxLineLength`: int → `lineWidth`.
 * - `sameLine.ifElse` / `sameLine.tryCatch` / `sameLine.doWhile`: enum
 *   string — `"same"` → `SameLinePolicy.Same`, `"next"` →
 *   `SameLinePolicy.Next`, `"keep"` → `SameLinePolicy.Keep` (reads the
 *   trivia-mode parser's captured slot at runtime; degrades to `Same`
 *   in plain mode). `"fitLine"` still collapses to `Same` — no
 *   `FitLine` branch exists on these keyword-join sites yet.
 * - `sameLine.elseIf` (ψ₈): enum string — `"same"` (default) maps to
 *   `KeywordPlacement.Same`, `"next"` maps to `KeywordPlacement.Next`.
 *   `"keep"` degrades to `Same` (no per-node source-shape tracking).
 *   The knob only affects the `IfStmt` ctor of `elseBody` — non-if
 *   else branches still route through `sameLine.elseBody`.
 * - `sameLine.fitLineIfWithElse` (ψ₁₂): boolean — `true` keeps the
 *   `FitLine` body policy active for `if`s with an `else` clause,
 *   `false` (default) degrades those bodies to `Next`. Matches haxe-
 *   formatter's `sameLine.fitLineIfWithElse: @:default(false)`.
 * - `trailingCommas.arrayLiteralDefault` / `trailingCommas.callArgumentDefault`
 *   / `trailingCommas.functionParameterDefault`: enum string — `"yes"`
 *   maps to `true`, every other value (`"no"`, `"keep"`, `"ignore"`) to
 *   `false`. `keep` requires an AST that remembers whether the source
 *   had a trailing comma — a debt to address once the parser records
 *   that detail; for now the writer only knows "always" or "never".
 * - `lineEnds.leftCurly` (ψ₆): enum string — `"before"` / `"both"`
 *   map to `BracePlacement.Next`; `"after"` / `"none"` map to
 *   `BracePlacement.Same`. `"none"` degrades because the inline
 *   `{ ... }` shape is not representable by the current two-value
 *   surface without per-node source-shape tracking.
 * - `whitespace.objectFieldColonPolicy` (ψ₇): enum string —
 *   `"before"` / `"onlyBefore"` → `WhitespacePolicy.Before`,
 *   `"after"`  / `"onlyAfter"`  → `WhitespacePolicy.After`,
 *   `"around"` → `WhitespacePolicy.Both`,
 *   `"none"` / `"noneBefore"` / `"noneAfter"` → `WhitespacePolicy.None`.
 *   The `only*` / `none*` values in haxe-formatter encode extra
 *   semantics about the opposite side; the four-way collapse here
 *   matches the information content the generated writer actually
 *   exposes today.
 * - `whitespace.typeHintColonPolicy` (ω-E-whitespace): same enum /
 *   same collapse as `objectFieldColonPolicy`, routed to
 *   `opt.typeHintColon` (the type-annotation `:` on `HxVarDecl.type`,
 *   `HxParam.type`, `HxFnDecl.returnType`). Default `None` leaves
 *   `x:Int` / `f():Void` tight; `"around"` produces `x : Int` /
 *   `f() : Void`.
 * - `whitespace.parenConfig.funcParamParens.openingPolicy`
 *   (ω-E-whitespace): same enum, routed to `opt.funcParamParens`.
 *   `Before` / `Both` emit a single space before the `(` on
 *   `HxFnDecl.params` (`function main ()`); `After` / `None` leave the
 *   paren tight (the paren-after axis is not yet wired). The sibling
 *   `closingPolicy` key is parsed and silently ignored.
 * - `whitespace.parenConfig.callParens.openingPolicy`
 *   (ω-call-parens): same enum, routed to `opt.callParens`.
 *   `Before` / `Both` emit a single space before the `(` on
 *   `HxExpr.Call.args` (`trace (x)`); `After` / `None` leave the paren
 *   tight. The sibling `closingPolicy` key is parsed and silently
 *   ignored.
 * - `emptyLines.afterFieldsWithDocComments` (ω-C-empty-lines-doc):
 *   enum string — `"ignore"` → `CommentEmptyLinesPolicy.Ignore`,
 *   `"none"` → `CommentEmptyLinesPolicy.None`, `"one"` →
 *   `CommentEmptyLinesPolicy.One`. Routed to
 *   `opt.afterFieldsWithDocComments`. Default `One` adds one blank
 *   line after a class member whose leading trivia carries a doc
 *   comment even when the source had none; `Ignore` respects the
 *   captured source blank-line count; `None` strips any blank line
 *   after such a field.
 * - `emptyLines.classEmptyLines.existingBetweenFields`
 *   (ω-C-empty-lines-between-fields): enum string — `"keep"` →
 *   `KeepEmptyLinesPolicy.Keep`, `"remove"` →
 *   `KeepEmptyLinesPolicy.Remove`. Routed to
 *   `opt.existingBetweenFields`. Default `Keep` preserves source
 *   blank lines between class members; `Remove` strips every blank
 *   line between siblings regardless of source.
 * - `emptyLines.classEmptyLines.{betweenVars, betweenFunctions,
 *   afterVars}` (ω-interblank): non-negative Int counts routed to
 *   `opt.betweenVars`, `opt.betweenFunctions`, `opt.afterVars`.
 *   A positive count currently collapses to a single blank-line
 *   contribution on the grammar sites tagged with
 *   `@:fmt(interMemberBlankLines('classifierField', 'VarCtorName', 'FnCtorName'))` — multi-blank emission is a
 *   future extension. `HxClassDecl.members` is the only current
 *   consumer.
 * - `emptyLines.beforeDocCommentEmptyLines` (ω-C-empty-lines-before-doc):
 *   enum string — same three-way collapse as
 *   `afterFieldsWithDocComments` (`"ignore"` / `"none"` / `"one"`),
 *   routed to `opt.beforeDocCommentEmptyLines`. Default `One` adds one
 *   blank line before a class member whose leading trivia starts with
 *   a doc comment even when the source had none; `Ignore` respects the
 *   captured source blank-line count; `None` strips any blank line
 *   before such a field.
 *
 * Deliberately NOT supported in this slice (no corresponding
 * `HxModuleWriteOptions` field yet): `wrapping.*` beyond
 * `maxLineLength`, other `lineEnds.*` keys (`rightCurly`, `blockCurly`,
 * `objectLiteralCurly`, …), other `emptyLines.*` keys
 * (`finalNewline`, `maxAnywhereInFile`, `beforePackage`, `afterPackage`,
 * `betweenTypes`, per-type-kind sections
 * `macroClassEmptyLines` / `externClassEmptyLines` /
 * `abstractEmptyLines` / `interfaceEmptyLines` / `enumEmptyLines` /
 * `typedefEmptyLines`, other `classEmptyLines.*` sub-keys beyond
 * `existingBetweenFields`, …), other `whitespace.*` keys
 * (`ifPolicy`, `forPolicy`, `ternaryPolicy`, …), other
 * `whitespace.parenConfig.*` kinds (`ifParens`, `forParens`, …),
 * `indentation.conditionalPolicy`, `baseTypeHints`, `disableFormatting`,
 * `excludes`. They will land with the slices that introduce the
 * matching knobs.
 *
 * Two-stage pipeline: `HxFormatConfigParser` (macro-generated ByName
 * struct parser) reads the JSON into a typed `HxFormatConfig`, then
 * this class maps that struct onto `HxModuleWriteOptions` with no
 * `JValue` walks, no field-name strings, no runtime-typed switches.
 * Adding a new recognised key means extending the schema in
 * `HxFormatConfig.hx` and adding one line here.
 *
 * All-static utility: the loader holds no state.
 */
@:nullSafety(Strict)
final class HaxeFormatConfigLoader {

	/**
	 * Parses a `hxformat.json` document and returns the equivalent
	 * `HxModuleWriteOptions`, starting from the Haxe format defaults
	 * and overwriting only the fields the config explicitly sets.
	 */
	public static function loadHxFormatJson(json:String):HxModuleWriteOptions {
		final cfg:HxFormatConfig = HxFormatConfigParser.parse(json);
		final base:HxModuleWriteOptions = HaxeFormat.instance.defaultWriteOptions;
		final result:HxModuleWriteOptions = {
			indentChar: base.indentChar,
			indentSize: base.indentSize,
			tabWidth: base.tabWidth,
			lineWidth: base.lineWidth,
			lineEnd: base.lineEnd,
			finalNewline: base.finalNewline,
			trailingWhitespace: base.trailingWhitespace,
			commentStyle: base.commentStyle,
			sameLineElse: base.sameLineElse,
			sameLineCatch: base.sameLineCatch,
			sameLineDoWhile: base.sameLineDoWhile,
			trailingCommaArrays: base.trailingCommaArrays,
			trailingCommaArgs: base.trailingCommaArgs,
			trailingCommaParams: base.trailingCommaParams,
			ifBody: base.ifBody,
			elseBody: base.elseBody,
			forBody: base.forBody,
			whileBody: base.whileBody,
			doBody: base.doBody,
			leftCurly: base.leftCurly,
			objectFieldColon: base.objectFieldColon,
			typeHintColon: base.typeHintColon,
			funcParamParens: base.funcParamParens,
			callParens: base.callParens,
			elseIf: base.elseIf,
			fitLineIfWithElse: base.fitLineIfWithElse,
			afterFieldsWithDocComments: base.afterFieldsWithDocComments,
			existingBetweenFields: base.existingBetweenFields,
			beforeDocCommentEmptyLines: base.beforeDocCommentEmptyLines,
			betweenVars: base.betweenVars,
			betweenFunctions: base.betweenFunctions,
			afterVars: base.afterVars,
		};
		if (cfg.indentation != null) applyIndentation(cfg.indentation, result);
		if (cfg.wrapping != null) applyWrapping(cfg.wrapping, result);
		if (cfg.sameLine != null) applySameLine(cfg.sameLine, result);
		if (cfg.trailingCommas != null) applyTrailingCommas(cfg.trailingCommas, result);
		if (cfg.lineEnds != null) applyLineEnds(cfg.lineEnds, result);
		if (cfg.whitespace != null) applyWhitespace(cfg.whitespace, result);
		if (cfg.emptyLines != null) applyEmptyLines(cfg.emptyLines, result);
		return result;
	}

	private function new() {}

	private static function applyIndentation(section:HxFormatIndentationSection, opt:HxModuleWriteOptions):Void {
		final character:Null<String> = section.character;
		if (character != null) {
			if (character == 'tab') {
				opt.indentChar = Tab;
				opt.indentSize = 1;
			} else if (isAllSpaces(character) && character.length > 0) {
				opt.indentChar = Space;
				opt.indentSize = character.length;
			}
		}
		if (section.tabWidth != null) opt.tabWidth = section.tabWidth;
		if (section.trailingWhitespace != null) opt.trailingWhitespace = section.trailingWhitespace;
	}

	private static function applyWrapping(section:HxFormatWrappingSection, opt:HxModuleWriteOptions):Void {
		if (section.maxLineLength != null) opt.lineWidth = section.maxLineLength;
	}

	private static function applySameLine(section:HxFormatSameLineSection, opt:HxModuleWriteOptions):Void {
		if (section.ifElse != null) opt.sameLineElse = sameLineToRuntime(section.ifElse);
		if (section.tryCatch != null) opt.sameLineCatch = sameLineToRuntime(section.tryCatch);
		if (section.doWhile != null) opt.sameLineDoWhile = sameLineToRuntime(section.doWhile);
		if (section.ifBody != null) opt.ifBody = bodyPolicyToRuntime(section.ifBody);
		if (section.elseBody != null) opt.elseBody = bodyPolicyToRuntime(section.elseBody);
		if (section.forBody != null) opt.forBody = bodyPolicyToRuntime(section.forBody);
		if (section.whileBody != null) opt.whileBody = bodyPolicyToRuntime(section.whileBody);
		if (section.doWhileBody != null) opt.doBody = bodyPolicyToRuntime(section.doWhileBody);
		if (section.elseIf != null) opt.elseIf = keywordPlacementToRuntime(section.elseIf);
		if (section.fitLineIfWithElse != null) opt.fitLineIfWithElse = section.fitLineIfWithElse;
	}

	private static function applyTrailingCommas(section:HxFormatTrailingCommasSection, opt:HxModuleWriteOptions):Void {
		if (section.arrayLiteralDefault != null)
			opt.trailingCommaArrays = trailingCommaToBool(section.arrayLiteralDefault);
		if (section.callArgumentDefault != null)
			opt.trailingCommaArgs = trailingCommaToBool(section.callArgumentDefault);
		if (section.functionParameterDefault != null)
			opt.trailingCommaParams = trailingCommaToBool(section.functionParameterDefault);
	}

	private static function applyLineEnds(section:HxFormatLineEndsSection, opt:HxModuleWriteOptions):Void {
		if (section.leftCurly != null) opt.leftCurly = leftCurlyToRuntime(section.leftCurly);
	}

	private static function applyWhitespace(section:HxFormatWhitespaceSection, opt:HxModuleWriteOptions):Void {
		if (section.objectFieldColonPolicy != null)
			opt.objectFieldColon = whitespaceToRuntime(section.objectFieldColonPolicy);
		if (section.typeHintColonPolicy != null)
			opt.typeHintColon = whitespaceToRuntime(section.typeHintColonPolicy);
		final paren:Null<HxFormatParenConfigSection> = section.parenConfig;
		if (paren != null) {
			final funcParam:Null<HxFormatParenPolicySection> = paren.funcParamParens;
			if (funcParam != null && funcParam.openingPolicy != null)
				opt.funcParamParens = whitespaceToRuntime(funcParam.openingPolicy);
			final call:Null<HxFormatParenPolicySection> = paren.callParens;
			if (call != null && call.openingPolicy != null)
				opt.callParens = whitespaceToRuntime(call.openingPolicy);
		}
	}

	private static function applyEmptyLines(section:HxFormatEmptyLinesSection, opt:HxModuleWriteOptions):Void {
		if (section.afterFieldsWithDocComments != null)
			opt.afterFieldsWithDocComments = commentEmptyLinesToRuntime(section.afterFieldsWithDocComments);
		if (section.beforeDocCommentEmptyLines != null)
			opt.beforeDocCommentEmptyLines = commentEmptyLinesToRuntime(section.beforeDocCommentEmptyLines);
		final classSection:Null<HxFormatClassEmptyLinesConfig> = section.classEmptyLines;
		if (classSection == null) return;
		if (classSection.existingBetweenFields != null)
			opt.existingBetweenFields = keepEmptyLinesToRuntime(classSection.existingBetweenFields);
		if (classSection.betweenVars != null) opt.betweenVars = classSection.betweenVars;
		if (classSection.betweenFunctions != null) opt.betweenFunctions = classSection.betweenFunctions;
		if (classSection.afterVars != null) opt.afterVars = classSection.afterVars;
	}

	private static function sameLineToRuntime(policy:HxFormatSameLinePolicy):SameLinePolicy {
		return switch policy {
			case HxFormatSameLinePolicy.Next: SameLinePolicy.Next;
			case HxFormatSameLinePolicy.Keep: SameLinePolicy.Keep;
			case _: SameLinePolicy.Same;
		};
	}

	private static inline function trailingCommaToBool(policy:HxFormatTrailingCommaPolicy):Bool {
		return policy == HxFormatTrailingCommaPolicy.Yes;
	}

	private static function bodyPolicyToRuntime(policy:HxFormatBodyPolicy):BodyPolicy {
		return switch policy {
			case HxFormatBodyPolicy.Same: BodyPolicy.Same;
			case HxFormatBodyPolicy.Next: BodyPolicy.Next;
			case HxFormatBodyPolicy.FitLine: BodyPolicy.FitLine;
			case HxFormatBodyPolicy.Keep: BodyPolicy.Keep;
			case _: BodyPolicy.Same;
		};
	}

	private static function leftCurlyToRuntime(policy:HxFormatLeftCurlyPolicy):BracePlacement {
		return switch policy {
			case HxFormatLeftCurlyPolicy.Before | HxFormatLeftCurlyPolicy.Both: BracePlacement.Next;
			case _: BracePlacement.Same;
		};
	}

	private static function whitespaceToRuntime(policy:HxFormatWhitespacePolicy):WhitespacePolicy {
		return switch policy {
			case HxFormatWhitespacePolicy.Before | HxFormatWhitespacePolicy.OnlyBefore: WhitespacePolicy.Before;
			case HxFormatWhitespacePolicy.After | HxFormatWhitespacePolicy.OnlyAfter: WhitespacePolicy.After;
			case HxFormatWhitespacePolicy.Around: WhitespacePolicy.Both;
			case _: WhitespacePolicy.None;
		};
	}

	private static function keywordPlacementToRuntime(policy:HxFormatKeywordPlacement):KeywordPlacement {
		return switch policy {
			case HxFormatKeywordPlacement.Next: KeywordPlacement.Next;
			case _: KeywordPlacement.Same;
		};
	}

	private static function commentEmptyLinesToRuntime(policy:HxFormatCommentEmptyLinesPolicy):CommentEmptyLinesPolicy {
		return switch policy {
			case HxFormatCommentEmptyLinesPolicy.None: CommentEmptyLinesPolicy.None;
			case HxFormatCommentEmptyLinesPolicy.One: CommentEmptyLinesPolicy.One;
			case _: CommentEmptyLinesPolicy.Ignore;
		};
	}

	private static function keepEmptyLinesToRuntime(policy:HxFormatKeepEmptyLinesPolicy):KeepEmptyLinesPolicy {
		return switch policy {
			case HxFormatKeepEmptyLinesPolicy.Remove: KeepEmptyLinesPolicy.Remove;
			case _: KeepEmptyLinesPolicy.Keep;
		};
	}

	private static function isAllSpaces(s:String):Bool {
		for (i in 0...s.length) if (s.charCodeAt(i) != ' '.code) return false;
		return true;
	}
}
