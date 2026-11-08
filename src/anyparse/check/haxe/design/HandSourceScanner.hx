package anyparse.check.haxe.design;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FileGated;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.NoAutofix;
import anyparse.check.common.types.AvoidDynamic;
import anyparse.check.scan.RunScan;
import anyparse.query.ShapeVocab;
import anyparse.query.SymbolIndex;

/**
 * Flags a loop that reads the characters of a text and tracks its own lexical state by hand — the strings, escapes,
 * comment openers, `#if` directives or bracket depth of SOURCE text that `LexicalRegions` (strings, comments, regexes),
 * `CondDirectives` (`#if` / `#end`), `HxInterpProjection` (string interpolation) or the AST already answer. The question
 * is "where does this construct start and end"; a second hand scanner is a second answer that drifts from the first.
 *
 * A loop qualifies when it reads characters (`fastCodeAt` / `charCodeAt` / `charAt`, or a `'x'.code`) and holds one of
 * three shapes: it compares at least two of {quote, backslash, a comment opener, `#if`}; or it compares a quote and
 * mutates a flag or state local; or it compares an open / close bracket pair and moves an Int local both up and down by
 * one. A character is named by a one-character string literal or its code (`34`, `0x22`) that is an operand of an equality
 * test or a case pattern; one only emitted or stored names nothing. A comment opener is a spelled `/*` or `//`, a `/`
 * beside a `*`, or two compared `/`; a lone `/` is a path separator.
 *
 * The owners themselves, and code that scans a different alphabet (a regex source, a command template, a generated
 * lexer), are listed under `allow` as `{ "path fragment": "why" }`. `Info`, default-off, report-only: the project's
 * lint gate refuses growth of the findings against the base, so a scanner can be added only through an owner.
 */
@:nullSafety(Strict)
final class HandSourceScanner extends HaxeRule implements ConfigAware implements FileGated implements NoAutofix implements DefaultOff {

	private static inline final RULE_ID: String = 'hand-source-scanner';
	private static inline final ALLOW_KEY: String = 'allow';

	/** The `.code` field of a one-character string literal, which reads a character as a number. */
	private static inline final CODE_FIELD: String = 'code';

	private static inline final SUB_ASSIGN_KIND: String = 'SubAssign';
	private static inline final BACKSLASH: Int = 92;
	private static inline final SLASH: Int = 47;
	private static inline final STAR: Int = 42;
	private static inline final HASH: Int = 35;

	/** The calls that read one character of a text. */
	private static final READ_METHODS: Array<String> = ['fastCodeAt', 'charCodeAt', 'charAt'];

	/** The decrement shapes the shape seams do not name (the increment and assignment ones they do). */
	private static final DECREMENT_KINDS: Array<String> = ['PostDecr', 'PreDecr'];

	private static final QUOTES: Array<Int> = [34, 39];

	/** Open code then close code of each bracket pair a depth counter follows. */
	private static final BRACKET_PAIRS: Array<Array<Int>> = [[40, 41], [123, 125], [91, 93]];

	private static final DIRECTIVES: Array<String> = ['#if', '#elseif', '#else', '#end'];
	private static final OPENERS: Array<String> = ['/*', '//'];

	/** The linter's memoised per-file config resolver; null when run outside it. */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {
		super(
			RULE_ID, 'a loop that reads the characters of a text and tracks its strings, comments, directives or brackets by hand',
			RuleCategory.Design
		);
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	/** `config-excluded` for a file whose path contains an `allow` key. */
	public function skipReason(file: String, config: LintConfig): Null<String> {
		return AvoidDynamic.pathExcluded(file, allowedPaths(config)) ? 'config-excluded' : null;
	}

	public function noAutofixReason(): String {
		return 'which owner answers the question is the author\'s to choose';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Vocab> = vocabOf(plugin.refShape());
		if (seams == null) return [];
		final vocab: Vocab = seams;
		return RunScan.collect(files, plugin, (entry, tree, out) -> {
			function walk(node: QueryNode, fn: String): Void {
				final name: String = vocab.functionKinds.contains(node.kind) ? node.name ?? fn : fn;
				if (vocab.loopKinds.contains(node.kind)) {
					final what: Null<String> = verdict(node, entry.source, vocab);
					final span: Null<Span> = node.span;
					if (what != null && span != null) {
						out.push({
							file: entry.file,
							span: span,
							rule: RULE_ID,
							severity: Severity.Info,
							message: '$name $what by hand — ask the owner of the question instead: LexicalRegions for strings and '
							+ 'comments, CondDirectives for #if, HxInterpProjection for string interpolation, the AST for brackets'
						});
						return;
					}
				}
				for (child in node.children) walk(child, name);
			}
			walk(tree, '(module)');
		});
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return [];
	}

	/** Whether a literal under `node`, itself an operand of a comparison, is still compared: through parentheses and a `.code` read. */
	private static inline function passesComparison(node: QueryNode, vocab: Vocab): Bool {
		return node.kind == vocab.parenKind || (node.kind == vocab.accessKind && node.name == CODE_FIELD);
	}

	/** The `allow` keys of `config`: path fragments, each carrying its reason as the value. */
	private static function allowedPaths(config: LintConfig): Array<String> {
		return switch config.jsonOption(RULE_ID, ALLOW_KEY) {
			case JObject(entries): [for (entry in entries) entry.key];
			case _: [];
		};
	}

	/** The seams the scan reads, or null when the grammar names no call or literal. */
	private static function vocabOf(shape: RefShape): Null<Vocab> {
		final call: Null<String> = shape.callKind;
		final access: Null<String> = shape.fieldAccessKind;
		final strings: Null<Array<String>> = shape.stringLiteralKinds;
		final numbers: Null<Array<String>> = shape.numericLiteralKinds;
		return call == null || access == null || strings == null || numbers == null ? null : {
			loopKinds: ShapeVocab.loopKinds(shape),
			functionKinds: ShapeVocab.functionLikeKinds(shape),
			callKind: call,
			accessKind: access,
			identKind: shape.identKind,
			stringKinds: strings,
			numberKinds: numbers,
			declKinds: shape.localDeclKinds ?? [],
			boolKind: shape.boolLitKind,
			notKind: shape.notKind,
			assignKind: shape.assignKind,
			addAssignKind: shape.addAssignKind,
			incrementKinds: [for (kind in [shape.postIncrKind, shape.preIncrKind]) if (kind != null) kind],
			parenKind: shape.parenKind,
			comparedHostKinds: (shape.equalityKinds ?? []).concat([
				for (kind in [shape.plainCasePatternKind, shape.orPatternKind]) if (kind != null) kind
			])
		};
	}

	/** What the loop `loop` does by hand, as a phrase for the message, or null when it is no source scanner. */
	private static function verdict(loop: QueryNode, source: String, vocab: Vocab): Null<String> {
		final facts: Facts = {
			reads: false,
			codes: [],
			opener: false,
			directive: false,
			declared: [],
			flagged: [],
			up: [],
			down: []
		};
		collect(loop, source, vocab, facts, false);
		if (!facts.reads) return null;
		final named: Array<String> = [];
		if (facts.codes.exists(c -> QUOTES.contains(c))) named.push('a quote');
		if (facts.codes.contains(BACKSLASH)) named.push('a backslash');
		final slashes: Int = facts.codes.filter(c -> c == SLASH).length;
		if (facts.opener || slashes >= 2 || (facts.codes.contains(SLASH) && facts.codes.contains(STAR))) named.push('a comment opener');
		if (facts.directive || facts.codes.contains(HASH)) named.push('#if');
		if (named.length >= 2) return 'compares characters with ' + named.join(' and ');
		final state: Bool = facts.flagged.exists(n -> !facts.declared.contains(n));
		if (named.length == 1 && named[0] == 'a quote' && state)
			return 'compares characters with a quote and keeps its state in a variable';
		final depth: Bool = facts.up.exists(n -> facts.down.contains(n) && !facts.declared.contains(n));
		final paired: Bool = BRACKET_PAIRS.exists(p -> facts.codes.contains(p[0]) && facts.codes.contains(p[1]));
		return paired && depth ? 'compares characters with a bracket pair and counts its depth in a variable' : null;
	}

	/** Gathers into `facts` what `node`'s subtree reads, names and mutates. */
	private static function collect(node: QueryNode, source: String, vocab: Vocab, facts: Facts, compared: Bool): Void {
		final kind: String = node.kind;
		final first: Null<QueryNode> = node.children[0];
		final second: Null<QueryNode> = node.children[1];
		if (vocab.stringKinds.contains(kind)) {
			if (compared) literal(textOf(node, source), facts);
		} else if (vocab.numberKinds.contains(kind)) {
			final code: Null<Int> = Std.parseInt(textOf(node, source));
			if (compared && code != null) facts.codes.push(code);
		} else if (vocab.declKinds.contains(kind)) {
			final declared: Null<String> = node.name;
			if (declared != null) facts.declared.push(declared);
		} else if (first != null && first.kind == vocab.identKind) {
			final target: Null<String> = first.name;
			if (target != null) movement(node, target, second, source, vocab, facts);
		}
		if (readsCharacter(node, vocab)) facts.reads = true;
		final operand: Bool = vocab.comparedHostKinds.contains(kind) || (compared && passesComparison(node, vocab));
		for (child in node.children) collect(child, source, vocab, facts, operand);
	}

	/** Records how `node`, whose target is the local `target`, moves it: set to a flag or constant, or stepped by one. */
	private static function movement(
		node: QueryNode, target: String, value: Null<QueryNode>, source: String, vocab: Vocab, facts: Facts
	): Void {
		final kind: String = node.kind;
		if (kind == vocab.assignKind) {
			if (value != null && (value.kind == vocab.boolKind || value.kind == vocab.notKind || vocab.numberKinds.contains(value.kind)))
				facts.flagged.push(target);
		} else if (vocab.incrementKinds.contains(kind)) {
			facts.up.push(target);
		} else if (DECREMENT_KINDS.contains(kind)) {
			facts.down.push(target);
		} else if (value != null && textOf(value, source) == '1') {
			if (kind == vocab.addAssignKind)
				facts.up.push(target);
			else if (kind == SUB_ASSIGN_KIND)
				facts.down.push(target);
		}
	}

	/** Records the character a string literal `text` names, or the opener or directive it spells whole. */
	private static function literal(text: String, facts: Facts): Void {
		if (text.length < 2) return;
		final body: String = text.substring(1, text.length - 1);
		final value: String = body.length == 2 && body.charAt(0) == '\\' ? body.charAt(1) : body;
		if (value.length == 1)
			facts.codes.push(value.charCodeAt(0) ?? 0);
		else if (OPENERS.contains(value))
			facts.opener = true;
		else if (DIRECTIVES.exists(d -> value.indexOf(d) == 0))
			facts.directive = true;
	}

	private static function textOf(node: QueryNode, source: String): String {
		final span: Null<Span> = node.span;
		return span == null ? '' : source.substring(span.from, span.to);
	}

	/** Whether `node` is a call of a character-reading method, or the `.code` of a string literal. */
	private static function readsCharacter(node: QueryNode, vocab: Vocab): Bool {
		final first: Null<QueryNode> = node.children[0];
		return first != null && (
			(node.kind == vocab.callKind && first.kind == vocab.accessKind && READ_METHODS.contains(first.name ?? ''))
			|| (node.kind == vocab.accessKind && node.name == CODE_FIELD && vocab.stringKinds.contains(first.kind))
		);
	}

}

/** The seams the scan reads, resolved once per run. */
private typedef Vocab = {
	final loopKinds: Array<String>;
	final functionKinds: Array<String>;
	final callKind: String;
	final accessKind: String;
	final identKind: String;
	final stringKinds: Array<String>;
	final numberKinds: Array<String>;
	final declKinds: Array<String>;
	final boolKind: Null<String>;
	final notKind: Null<String>;
	final assignKind: Null<String>;
	final addAssignKind: Null<String>;
	final incrementKinds: Array<String>;
	final parenKind: Null<String>;
	final comparedHostKinds: Array<String>;
}

/** What one loop's subtree reads, names and mutates. */
private typedef Facts = {
	var reads: Bool;
	final codes: Array<Int>;
	var opener: Bool;
	var directive: Bool;
	final declared: Array<String>;
	final flagged: Array<String>;
	final up: Array<String>;
	final down: Array<String>;
}
