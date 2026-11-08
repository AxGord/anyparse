package anyparse.check.haxe.expressions;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.GroupedEdit;
import anyparse.check.Check.GroupedFix;
import anyparse.check.scan.RunScan;
import anyparse.grammar.json.JValue;
import anyparse.query.IndexScope;
import anyparse.query.ParseGate;
import anyparse.query.SourceText;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeRefPrinter;
import anyparse.query.TypeSyntax.TypeSyntaxReader;
import anyparse.query.TypingService;

/**
 * Flags a hand-cut of a string at a delimiter that the project's text utility already names — `s.split(",")[0]` for
 * `allBefore`, `s.split(".").pop()` for `allAfterLast` — and rewrites it to the utility call, with its import.
 * `Severity.Info`, with an autofix. Inert until the project names the utility class in `apq.json` and enables the rule:
 *
 *     "prefer-split-part": { "enabled": true, "textTools": "pkg.text.TextTools" }
 *
 * ## What a site must be
 *
 * - **The receiver is a `String`**, by its written or declared type: `EReg.split` has the same spelling and means
 *   something else, and a `Null<String>` is refused because the utility takes a plain `String`.
 * - **The delimiter is a literal that is not empty.** A cut at `""` splits into characters, so `[0]` is one character
 *   where `allBefore` answers the empty string. An interpolated literal is no literal.
 * - **The cut is `[0]` or `.pop()`.** `[0]` is the text before the first occurrence of the delimiter, or the whole text
 *   without one, and so is `allBefore`. `.pop()` is the text after the last occurrence, or the whole text, and so is
 *   `allAfterLast` — unless the delimiter overlaps itself (`"::"`, `".."`, `"aa"`): `split` cuts left to right without
 *   overlap and `lastIndexOf` takes the rightmost match, so `a:::b` ends in `:b` by the split and in `b` by the index.
 *   A `.pop()` is taken only for a delimiter with no proper prefix that is also its suffix; one with an escape or
 *   an interpolation mark is not decoded and is refused. A `[1]` reads the second part, which is the text between two
 *   delimiters and not the text after the first, and answers null when there is no delimiter, so it has no equal and is left alone; so is a
 *   `.length` comparison, which counts parts and does not ask whether a delimiter occurs.
 * - **No comment inside the replaced text.**
 *
 * The receiver is evaluated once on both sides and the delimiter is a literal, so the rewrite reorders nothing. A cut whose
 * receiver is itself a cut (`a.split(",")[0].split(":")[0]`) is rewritten from the inside out, one level per `--fix` pass:
 * the outer one is typed once the inner one is a call.
 *
 * ## Option
 *
 * `textTools` names the class by its qualified path. It must declare `allBefore` and `allAfterLast` as public static
 * functions whose first two parameters are `String` and any further one optional, returning a `String`; a name the
 * resolution index cannot find, or one lacking either, is a configuration error that stops the rule on the files it governs.
 *
 * ## Grammar-agnostic
 *
 * Driven by `callKind`, `fieldAccessKind`, `indexAccessKind`, `stringLiteralKinds`, `literalTypeNames` and the string
 * interpolation kinds; a missing required kind, or a plugin without type information, makes the rule a no-op.
 */
@:nullSafety(Strict)
final class PreferSplitPart extends HaxeRule implements DefaultOff implements ConfigAware implements GroupedFix {

	private static inline final RULE_ID: String = 'prefer-split-part';

	/** The option naming the project's text utility class. */
	private static inline final OPTION_TEXT_TOOLS: String = 'textTools';

	private static inline final SPLIT: String = 'split';
	private static inline final POP: String = 'pop';
	private static inline final BEFORE: String = 'allBefore';
	private static inline final AFTER_LAST: String = 'allAfterLast';
	private static inline final PUBLIC_VISIBILITY: String = 'public';

	/** The text the first part of a split is read with. */
	private static inline final FIRST_PART: String = '0';

	/** A cut utility takes the text and the delimiter. */
	private static inline final CUT_PARAMS: Int = 2;

	/** A quoted literal holds at least its two quotes and one character. */
	private static inline final MIN_QUOTED: Int = 3;

	private static inline final QUOTE_WIDTH: Int = 1;

	/** The linter's per-file config resolver, or null to read each file's chain from disk. */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {
		super(
			RULE_ID, 'a hand-cut of a string at a delimiter (s.split(d)[0], s.split(d).pop()) the project text utility already names',
			RuleCategory.Expressions
		);
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final index: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex(files, plugin);
		final problems: Array<Violation> = [];
		final found: Array<Violation> = RunScan.collectWith(files, plugin, readSeams(plugin), (entry, tree, seams, out) -> {
			final cuts: Array<Cut> = candidates(tree, entry.source, seams);
			if (cuts.length == 0) return;
			final tools: Tools = toolsOf(entry.file, plugin, seams, index);
			final path: Null<String> = tools.path;
			if (tools.problems.length > 0) {
				if (Linter.enabledBy(LintConfig.resolveWith(_resolveConfig, entry.file), this)) for (message in tools.problems) {
					if (!problems.exists(p -> p.message == message)) problems.push({
						file: entry.file,
						span: null,
						rule: RULE_ID,
						severity: Severity.Error,
						message: message
					});
				}
				return;
			}
			if (path == null) return;
			for (c in proved(cuts, tree, entry.file, entry.source, seams, plugin, index())) out.push({
				file: entry.file,
				span: c.span,
				rule: RULE_ID,
				severity: Severity.Info,
				message: 'this cut of a string is ${SourceText.lastSegment(path)}.${c.member}',
				remedy: path
			});
		});
		return found.concat(problems);
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return fixGrouped(source, violations, plugin, index).map(edit -> {span: edit.span, text: edit.text });
	}

	/** An `import` and the rewrites that need it are kept or dropped together. */
	public function fixGrouped(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<GroupedEdit> {
		// A configuration error has no site to fix: said here, or `--fix`, which lists no findings, would never mention it.
		for (v in violations) if (v.span == null) v.declineReason = v.message;
		final sites: Array<Violation> = violations.filter(v -> v.span != null);
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null || sites.length == 0) return [];
		final tree: Null<QueryNode> = ParseGate.parseOrNull(plugin, source);
		if (tree == null) return [];
		final file: String = RunScan.oneFile(sites, RULE_ID);
		final scope: () -> Null<SymbolIndex> = IndexScope.lazySymbolIndex([{ file: file, source: source }], plugin, index);
		final tools: Tools = toolsOf(file, plugin, seams, scope);
		final path: Null<String> = tools.path;
		if (tools.problems.length > 0 || path == null) return [];
		final wanted: Array<String> = sites.map(v -> spanKey(v.span));
		final fixed: Array<Cut> = proved(
			candidates(tree, source, seams), tree, file, source, seams, plugin, scope()
		).filter(c -> wanted.contains(spanKey(c.span)));
		final printer: TypeRefPrinter = TypeRefPrinter.forFile(
			file, source, tree, RunScan.typeInfoOf(plugin)?.importMap(source, file) ?? [], plugin, scope()
		);
		final texts: Array<String> = fixed.map(c ->
			'${printer.printTypeExpr(path, c.span.from)}.${c.member}(${c.receiver}, ${c.delimiter})'
		);
		final imports: Array<PendingImportEdit> = printer.pendingImportEdits();
		final groupOf: Map<String, Int> = [];
		for (group => edit in imports) for (imported in edit.paths) groupOf[imported] = group;
		final edits: Array<GroupedEdit> = [for (i => c in fixed) { span: c.span, text: texts[i], group: groupOf[path] }];
		for (group => edit in imports) edits.push({ span: edit.span, text: edit.text, group: group });
		return edits;
	}

	private function toolsOf(file: String, plugin: GrammarPlugin, s: Seams, index: () -> Null<SymbolIndex>): Tools {
		final option: Null<JValue> = LintConfig.resolveWith(_resolveConfig, file).jsonOption(RULE_ID, OPTION_TEXT_TOOLS);
		return readTools(option, s.stringType, plugin.typeSyntax, index);
	}

	/** The cuts of `cuts` whose receiver is proved a `String`. */
	private static function proved(
		cuts: Array<Cut>, tree: QueryNode, file: String, source: String, s: Seams, plugin: GrammarPlugin, index: Null<SymbolIndex>
	): Array<Cut> {
		final nominal: Null<(QueryNode) -> Null<String>> = CheckScan.typeNominalResolver(source, plugin, tree, file, index);
		return nominal == null ? [] : cuts.filter(c -> nominal(c.operand) == s.stringType);
	}

	/** Every `s.split(d)[0]` and `s.split(d).pop()` of `tree` whose delimiter is a non-empty literal. */
	private static function candidates(tree: QueryNode, source: String, s: Seams): Array<Cut> {
		final out: Array<Cut> = [];
		function walk(node: QueryNode): Void {
			if (s.opaqueKinds.contains(node.kind)) return;
			final cut: Null<Cut> = cutAt(node, source, s);
			if (cut != null) out.push(cut);
			for (c in node.children) walk(c);
		}
		walk(tree);
		return out;
	}

	private static function cutAt(node: QueryNode, source: String, s: Seams): Null<Cut> {
		final span: Null<Span> = node.span;
		final read: Null<SplitRead> = splitRead(node, source, s);
		if (span == null || read == null) return null;
		final parts: Array<QueryNode> = read.split.children;
		final callee: Null<QueryNode> = parts[0];
		final delimiter: Null<QueryNode> = parts[1];
		if (callee == null || delimiter == null || read.split.kind != s.callKind || parts.length != CUT_PARAMS) return null;
		final operand: Null<QueryNode> = callee.children[0];
		final operandSpan: Null<Span> = operand?.span;
		final delimiterSpan: Null<Span> = delimiter.span;
		if (operand == null || operandSpan == null || delimiterSpan == null) return null;
		if (callee.kind != s.fieldAccessKind || callee.name != SPLIT || callee.children.length != 1) return null;
		if (!fits(read.member, delimiter, delimiterSpan, source, s) || CheckScan.hasCommentMarker(source, span.from, span.to)) return null;
		return {
			span: span,
			operand: operand,
			receiver: source.substring(operandSpan.from, operandSpan.to),
			delimiter: source.substring(delimiterSpan.from, delimiterSpan.to),
			member: read.member
		};
	}

	/** The call under a `[0]` or a `.pop()` node, and the utility function that reads the same part; null for any other node. */
	private static function splitRead(node: QueryNode, source: String, s: Seams): Null<SplitRead> {
		final first: Null<QueryNode> = node.children[0];
		if (first == null) return null;
		if (node.kind == s.indexAccessKind)
			return node.children.length == 2 && isFirstPart(node.children[1], source, s) ? { split: first, member: BEFORE } : null;
		final popped: Bool = node.kind == s.callKind
			&& node.children.length == 1
			&& first.kind == s.fieldAccessKind
			&& first.name == POP
			&& first.children.length == 1;
		return popped ? { split: first.children[0], member: AFTER_LAST } : null;
	}

	private static function isFirstPart(node: QueryNode, source: String, s: Seams): Bool {
		final span: Null<Span> = node.span;
		return span != null && s.literalTypeNames.exists(node.kind) && source.substring(span.from, span.to) == FIRST_PART;
	}

	/** A quoted literal of at least one character whose value no interpolation computes. */
	private static function isPlainLiteral(node: QueryNode, span: Span, s: Seams): Bool {
		return s.stringLiteralKinds.contains(node.kind)
			&& span.to - span.from >= MIN_QUOTED
			&& node.children.foreach(c -> c.kind == s.interpTextKind || s.interpInertKinds.contains(c.kind));
	}

	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final callKind: Null<String> = shape.callKind;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		final indexAccessKind: Null<String> = shape.indexAccessKind;
		final stringLiteralKinds: Null<Array<String>> = shape.stringLiteralKinds;
		final literalTypeNames: Null<Map<String, String>> = shape.literalTypeNames;
		final stringType: Null<String> = TypingService.stringType(shape);
		return callKind == null
			|| fieldAccessKind == null
			|| indexAccessKind == null
			|| stringLiteralKinds == null
			|| literalTypeNames == null
			|| stringType == null
			|| !(plugin is TypeInfoProvider)
			? null
			: {
				callKind: callKind,
				fieldAccessKind: fieldAccessKind,
				indexAccessKind: indexAccessKind,
				stringLiteralKinds: stringLiteralKinds,
				literalTypeNames: literalTypeNames,
				interpTextKind: shape.stringInterpTextKind,
				interpInertKinds: shape.stringInterpInertSegmentKinds ?? [],
				opaqueKinds: shape.opaqueKinds ?? [],
				stringType: stringType
			};
	}

	/** The utility `option` names, checked against the resolution index; `problems` is empty for a usable one or an unset option. */
	private static function readTools(
		option: Null<JValue>, string: String, typeSyntax: TypeSyntaxReader, index: () -> Null<SymbolIndex>
	): Tools {
		if (option == null) return { path: null, problems: [] };
		final key: String = OPTION_TEXT_TOOLS;
		final path: Null<String> = switch option {
			case JString(p): p;
			case _: null;
		};
		if (path == null) return { path: null, problems: ['$key is not a string: the qualified path of a class'] };
		final idx: Null<SymbolIndex> = index();
		final types: Array<ResolvedType> = idx == null ? [] : idx.refs.resolveQualifiedRefAll(path);
		if (types.length != 1) return {
			path: null,
			problems: [
				types.length == 0
					? '$key: "$path" names no type: the resolution index declares no "$path"'
					: '$key: "$path" is ambiguous: it names ${types.length} types in the resolution index'
			]
		};
		final type: ResolvedType = types[0];
		if (type.type.isPrivate) return { path: null, problems: ['$key: "$path" is a private type, which no other file can call'] };
		final lacking: Array<String> = [BEFORE, AFTER_LAST].filter(name -> {
			final found: Array<MemberInfo> = type.type.members.filter(m -> m.name == name);
			return found.length != 1 || !isTextCut(found[0], string, typeSyntax);
		});
		return lacking.length == 0 ? { path: path, problems: [] } : {
			path: null,
			problems: lacking.map(name -> '$key: "$path" has no one public static function $name($string, $string): $string')
		};
	}

	private static function isTextCut(m: MemberInfo, string: String, typeSyntax: TypeSyntaxReader): Bool {
		return m.isStatic
			&& m.visibility == PUBLIC_VISIBILITY
			&& !m.guarded
			&& !m.isMacro
			&& !m.isDynamic
			&& !m.isOverload
			&& !m.hasOverloadMeta
			&& !m.paramRest
			&& m.paramSkippableFrom == CUT_PARAMS
			&& m.paramTypeSources.length >= CUT_PARAMS
			&& m.paramTypeSources.slice(0, CUT_PARAMS).foreach(source -> spells(source, string, typeSyntax))
			&& spells(m.returnSource, string, typeSyntax);
	}

	private static function spells(source: Null<String>, type: String, typeSyntax: TypeSyntaxReader): Bool {
		return source != null && NominalTypes.outerNominalOf(source, typeSyntax) == type;
	}

	private static function spanKey(span: Null<Span>): String {
		return span == null ? '' : '${span.from}:${span.to}';
	}

	/**
	 * Whether the utility function `member` reads what the split does for this delimiter: a non-empty literal, and for the last part
	 * one with no proper border. `split` cuts left to right without overlap and `lastIndexOf` takes the rightmost match, so
	 * for `"::"` the text `a:::b` ends in `:b` by the split and in `b` by the index. A literal with an escape or an interpolation
	 * mark is not decoded here, so it is refused for the last part.
	 */
	private static function fits(member: String, node: QueryNode, span: Span, source: String, s: Seams): Bool {
		return isPlainLiteral(node, span, s)
			&& (member == BEFORE || isBorderFree(source.substring(span.from + QUOTE_WIDTH, span.to - QUOTE_WIDTH)));
	}

	/** Whether no proper prefix of `text` is also its suffix, so two matches of it never overlap; false for text it cannot read plainly. */
	private static function isBorderFree(text: String): Bool {
		if (text.indexOf('\\') >= 0 || text.indexOf('$') >= 0) return false;
		for (k in 1...text.length) if (text.substring(0, k) == text.substring(text.length - k)) return false;
		return true;
	}

}

/** A cut: the node it replaces, the string operand, and the text of the operand and the delimiter. */
private typedef Cut = {
	final span: Span;
	final operand: QueryNode;
	final receiver: String;
	final delimiter: String;
	final member: String;
};

/** A `[0]` or `.pop()` over a call: that call, and the utility function reading the same part. */
private typedef SplitRead = {
	final split: QueryNode;
	final member: String;
};

/** The text utility a config chain names: its qualified path, or what is wrong with the option as written. */
private typedef Tools = {
	final path: Null<String>;
	final problems: Array<String>;
};

/** The resolved seams `PreferSplitPart` reads in both `run` and `fix`. */
private typedef Seams = {
	final callKind: String;
	final fieldAccessKind: String;
	final indexAccessKind: String;
	final stringLiteralKinds: Array<String>;
	final literalTypeNames: Map<String, String>;
	final interpTextKind: Null<String>;
	final interpInertKinds: Array<String>;
	final opaqueKinds: Array<String>;
	final stringType: String;
};
