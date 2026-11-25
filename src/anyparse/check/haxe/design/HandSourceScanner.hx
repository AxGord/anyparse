package anyparse.check.haxe.design;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.FileGated;
import anyparse.check.Check.FixEdit;
import anyparse.check.Check.NoAutofix;
import anyparse.check.Check.OptionKeyed;
import anyparse.check.common.types.AvoidDynamic;
import anyparse.check.scan.RunScan;
import anyparse.query.Lit;
import anyparse.query.ShapeVocab;
import anyparse.query.SymbolIndex;

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
	final paramKinds: Array<String>;
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

/**
 * Flags source text of a language read by hand: a loop that reads the characters of a text and tracks its own lexical
 * state — the strings, escapes, comment openers, `#if` directives or bracket depth — or a search of source text for a
 * piece of syntax (`source.indexOf('(')`). The question is "where does this construct start and end"; the answer is the
 * AST node that spans it or the grammar declaration that knows it, or, when none does, a declaration added to the
 * grammar with its reader generated. A shared hand scanner is another hand-written answer, not that one.
 *
 * A loop qualifies when it reads characters (`fastCodeAt` / `charCodeAt` / `charAt`, or a `'x'.code`) and holds one of
 * three shapes: it compares at least two of {quote, backslash, a comment opener, `#if`}; or it compares a quote and
 * mutates a flag or state local; or it compares an open / close bracket pair and moves an Int local both up and down by
 * one. A character is named by a one-character string literal or its code (`34`, `0x22`) that is an operand of an equality
 * test or a case pattern; one only emitted or stored names nothing. A comment opener is a spelled `/*` or `//`, a `/`
 * beside a `*`, or two compared `/`; a lone `/` is a path separator.
 *
 * A call is reported when `indexOf` / `lastIndexOf` searches for a literal that spells Haxe syntax (a bracket, `;`, `:`,
 * `=`, an arrow, a comment mark) in text that is a `source` / `src` name or a `substring` / `substr` window cut from a
 * text; a search over a path or a line, and one for a dot or a newline, is not source scanning. A function that searches a
 * text for a name held in a parameter or local and reads a character indexed off the hit is a hand word-boundary test; the
 * files whose such tests the project counts without replacing go under `nameSearchAllow`, which silences that report only.
 *
 * Code that scans a different alphabet (a regex source, a command template, a generated lexer) is listed under `allow` as
 * `{ "path fragment": "why" }`; a reason that names an owner is no reason. `Info`, default-off, report-only: the project's
 * lint gate refuses growth of the findings against the base.
 */
@:nullSafety(Strict)
final class HandSourceScanner extends HaxeRule implements ConfigAware implements FileGated implements NoAutofix implements OptionKeyed
		implements DefaultOff {

	private static inline final RULE_ID: String = 'hand-source-scanner';
	private static inline final BACKSLASH: Int = 92;
	private static inline final SLASH: Int = 47;
	private static inline final STAR: Int = 42;
	private static inline final HASH: Int = 35;
	private static final NAME_SEARCH_ALLOW_KEY: String = 'nameSearchAllow';
	private static final ALLOW_KEY: String = 'allow';

	/** The `.code` field of a one-character string literal, which reads a character as a number. */
	private static final CODE_FIELD: String = 'code';

	private static final SUB_ASSIGN_KIND: String = 'SubAssign';

	/** The calls that read one character of a text. */
	private static final READ_METHODS: Array<String> = ['fastCodeAt', 'charCodeAt', 'charAt'];

	/** The decrement shapes the shape seams do not name (the increment and assignment ones they do). */
	private static final DECREMENT_KINDS: Array<String> = ['PostDecr', 'PreDecr'];

	private static final QUOTES: Array<Int> = [34, 39];

	/** Open code then close code of each bracket pair a depth counter follows. */
	private static final BRACKET_PAIRS: Array<Array<Int>> = [[40, 41], [123, 125], [91, 93]];

	private static final DIRECTIVES: Array<String> = ['#if', '#elseif', '#else', '#end'];
	private static final OPENERS: Array<String> = ['/*', '//'];

	/** The calls that search a text for a literal, and the calls that cut a window out of one. */
	private static final SEARCH_METHODS: Array<String> = ['indexOf', 'lastIndexOf'];

	private static final WINDOW_METHODS: Array<String> = ['substring', 'substr'];

	/** Parameter names that hold the whole source of a file. */
	private static final SOURCE_NAMES: Array<String> = ['source', 'src'];

	/** The needles that spell a piece of Haxe syntax: brackets, a separator, an assignment or arrow, a comment mark. */
	private static final SYNTAX_LITERALS: Array<String> = ['(', ')', '{', '}', '[', ']', ';', ':', '=', '->', '=>', '/*', '*/', '//'];

	/** The linter's memoised per-file config resolver; null when run outside it. */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {
		super(
			RULE_ID,
			'a loop that reads the characters of a text and tracks its strings, comments, directives or brackets by hand, or a search of '
			+ 'source text for syntax',
			RuleCategory.Design
		);
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	/** `config-excluded` for a file whose path contains an `allow` key. */
	public function skipReason(file: String, config: LintConfig): Null<String> {
		return AvoidDynamic.pathExcluded(file, allowedPaths(config, ALLOW_KEY)) ? 'config-excluded' : null;
	}

	public function noAutofixReason(): String {
		return 'which node or grammar declaration answers the question is the author\'s to choose';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Vocab> = vocabOf(plugin.refShape());
		if (seams == null) return [];
		final vocab: Vocab = seams;
		final shape: RefShape = plugin.refShape();
		return RunScan.collect(files, plugin, (entry, tree, out) -> {
			final nameSearchExcluded: Bool = isNameSearchExcluded(entry.file);
			function walk(node: QueryNode, fn: String): Void {
				final name: String = vocab.functionKinds.contains(node.kind) ? node.name ?? fn : fn;
				if (
					vocab.functionKinds.contains(node.kind)
					&& node.span != null && !nameSearchExcluded
					&& nameSearchWithNeighbours(node, vocab)
				)
					out.push(finding(entry.file, node.span, name, 'searches a text for a name held in a variable and tests the neighbours'));
				if (vocab.loopKinds.contains(node.kind)) {
					final what: Null<String> = verdict(node, entry.source, shape, vocab);
					final span: Null<Span> = node.span;
					if (what != null && span != null) {
						out.push(finding(entry.file, span, name, what));
						return;
					}
				} else {
					final search: Null<String> = syntaxSearch(node, shape, vocab);
					final span: Null<Span> = node.span;
					if (search != null && span != null) out.push(finding(entry.file, span, name, search));
				}
				for (child in node.children) walk(child, name);
			}
			walk(tree, '(module)');
		});
	}

	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {
		return [];
	}

	public function acceptedOptions(): Array<String> {
		return [ALLOW_KEY, NAME_SEARCH_ALLOW_KEY];
	}

	private function isNameSearchExcluded(file: String): Bool {
		final resolve: Null<(String) -> LintConfig> = _resolveConfig;
		return resolve != null && AvoidDynamic.pathExcluded(file, allowedPaths(resolve(file), NAME_SEARCH_ALLOW_KEY));
	}

	/** Whether a literal under `node`, itself an operand of a comparison, is still compared: through parentheses and a `.code` read. */
	private static inline function passesComparison(node: QueryNode, vocab: Vocab): Bool {
		return node.kind == vocab.parenKind || (node.kind == vocab.accessKind && node.name == CODE_FIELD);
	}

	private static function finding(file: String, span: Span, name: String, what: String): Violation {
		return {
			file: file,
			span: span,
			rule: RULE_ID,
			severity: Severity.Info,
			message: '$name $what by hand — read the AST node or the grammar declaration that knows this; if none does, declare it '
				+ 'in the grammar and generate the reader. A shared hand scanner is not the answer'
		};
	}

	/**
	 * What `node` does when it is a search of source text for a piece of syntax (`source.indexOf('(')`), as a phrase for the
	 * message, or null. The receiver is source text when it is a `source` / `src` name or a `substring` window cut from one.
	 */
	private static function syntaxSearch(node: QueryNode, shape: RefShape, vocab: Vocab): Null<String> {
		final callee: Null<QueryNode> = node.children[0];
		final needle: Null<QueryNode> = node.children[1];
		if (node.kind != vocab.callKind || callee == null || needle == null || callee.kind != vocab.accessKind) return null;
		final receiver: Null<QueryNode> = callee.children[0];
		if (!SEARCH_METHODS.contains(callee.name ?? '') || receiver == null) return null;
		final value: Null<String> = Lit.plainStringValue(needle, shape);
		return value != null && SYNTAX_LITERALS.contains(value) && holdsSourceText(receiver, vocab)
			? 'searches source text for `$value`'
			: null;
	}

	private static function holdsSourceText(receiver: QueryNode, vocab: Vocab): Bool {
		final window: Null<QueryNode> = receiver.children[0];
		return receiver.kind == vocab.identKind
			? SOURCE_NAMES.contains(receiver.name ?? '')
			: receiver.kind == vocab.callKind && window != null && window.kind == vocab.accessKind
				&& WINDOW_METHODS.contains(window.name ?? '');
	}

	/** The `allow` keys of `config`: path fragments, each carrying its reason as the value. */
	private static function allowedPaths(config: LintConfig, key: String): Array<String> {
		return switch config.jsonOption(RULE_ID, key) {
			case JObject(entries): [ for (entry in entries) entry.key ];
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
			incrementKinds: [ for (kind in [shape.postIncrKind, shape.preIncrKind]) if (kind != null) kind ],
			parenKind: shape.parenKind,
			paramKinds: shape.paramKinds ?? [],
			comparedHostKinds: (shape.equalityKinds ?? []).concat(
				[ for (kind in [shape.plainCasePatternKind, shape.orPatternKind]) if (kind != null) kind ]
			)
		};
	}

	/** What the loop `loop` does by hand, as a phrase for the message, or null when it is no source scanner. */
	private static function verdict(loop: QueryNode, source: String, shape: RefShape, vocab: Vocab): Null<String> {
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
		collect(loop, source, shape, vocab, facts, false);
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
	private static function collect(node: QueryNode, source: String, shape: RefShape, vocab: Vocab, facts: Facts, compared: Bool): Void {
		final kind: String = node.kind;
		final first: Null<QueryNode> = node.children[0];
		final second: Null<QueryNode> = node.children[1];
		if (vocab.stringKinds.contains(kind)) {
			final value: Null<String> = compared ? Lit.plainStringValue(node, shape) : null;
			if (value != null) literal(value, facts);
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
		for (child in node.children) collect(child, source, shape, vocab, facts, operand);
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

	/** Records the character a string literal `body` names, or the opener or directive it spells whole. */
	private static function literal(body: String, facts: Facts): Void {
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

	/**
	 * Whether the function `fn` searches a text for a name held in a variable and reads a character next to the hit: the search
	 * result lands in a local, and a character read is indexed off that local or one derived from it (`at - 1`, `at + name.length`).
	 * A bare occurrence test, a membership test of one character and a search for a constant are not this.
	 */
	private static function nameSearchWithNeighbours(fn: QueryNode, vocab: Vocab): Bool {
		final bound: Array<String> = [];
		final chars: Array<String> = [];
		boundNames(fn, vocab, bound, chars);
		final hits: Array<String> = [];
		collectHits(fn, null, vocab, bound, chars, hits);
		if (hits.length == 0) return false;
		var grown: Bool = true;
		while (grown) grown = spreadHits(fn, vocab, hits);
		return readsNextTo(fn, vocab, hits);
	}

	/** Gathers the parameters and locals `node` declares into `bound`, and those initialised from a character read into `chars`. */
	private static function boundNames(node: QueryNode, vocab: Vocab, bound: Array<String>, chars: Array<String>): Void {
		final declared: Null<String> = node.name;
		if (declared != null && (vocab.declKinds.contains(node.kind) || vocab.paramKinds.contains(node.kind))) {
			bound.push(declared);
			if (node.children.exists(child -> isCharacterRead(child, vocab))) chars.push(declared);
		}
		for (child in node.children) boundNames(child, vocab, bound, chars);
	}

	/** Records into `hits` the local that holds the result of each search of a bound, multi-character name under `node`. */
	private static function collectHits(
		node: QueryNode, parent: Null<QueryNode>, vocab: Vocab, bound: Array<String>, chars: Array<String>, hits: Array<String>
	): Void {
		if (parent != null && isNameSearch(node, vocab, bound, chars)) {
			final holder: Null<String> = holderOf(node, parent, vocab);
			if (holder != null) hits.push(holder);
		}
		for (child in node.children) collectHits(child, node, vocab, bound, chars, hits);
	}

	private static function isNameSearch(node: QueryNode, vocab: Vocab, bound: Array<String>, chars: Array<String>): Bool {
		final callee: Null<QueryNode> = node.children[0];
		final needle: Null<QueryNode> = node.children[1];
		if (node.kind != vocab.callKind || callee == null || needle == null || callee.kind != vocab.accessKind) return false;
		final receiver: Null<QueryNode> = callee.children[0];
		final root: String = rootName(needle, vocab) ?? '';
		return SEARCH_METHODS.contains(callee.name ?? '')
			&& receiver != null
			&& !vocab.stringKinds.contains(receiver.kind)
			&& bound.contains(root)
			&& !chars.contains(root);
	}

	/** The local a search result is stored into: a declaration's initialiser or the target of an assignment. */
	private static function holderOf(search: QueryNode, parent: QueryNode, vocab: Vocab): Null<String> {
		if (vocab.declKinds.contains(parent.kind)) return parent.name;
		final target: Null<QueryNode> = parent.children[0];
		return parent.kind == vocab.assignKind && target != null && target != search && target.kind == vocab.identKind ? target.name : null;
	}

	/** The identifier an access chain starts from, or null when it starts from anything else. */
	private static function rootName(node: QueryNode, vocab: Vocab): Null<String> {
		var current: QueryNode = node;
		while (current.kind == vocab.accessKind) {
			final next: Null<QueryNode> = current.children[0];
			if (next == null) return null;
			current = next;
		}
		return current.kind == vocab.identKind ? current.name : null;
	}

	/** Adds to `hits` each local declared from one of them; whether it added any. */
	private static function spreadHits(node: QueryNode, vocab: Vocab, hits: Array<String>): Bool {
		var grown: Bool = false;
		final declared: Null<String> = node.name;
		if (
			declared != null
			&& vocab.declKinds.contains(node.kind)
			&& !hits.contains(declared)
			&& node.children.exists(child -> mentionsAny(child, vocab, hits))
		) {
			hits.push(declared);
			grown = true;
		}
		for (child in node.children) if (spreadHits(child, vocab, hits)) grown = true;
		return grown;
	}

	private static function mentionsAny(node: QueryNode, vocab: Vocab, names: Array<String>): Bool {
		return (node.kind == vocab.identKind && names.contains(node.name ?? ''))
			|| node.children.exists(child -> mentionsAny(child, vocab, names));
	}

	/** Whether a call under `node` reads a character at an index that mentions one of `hits`. */
	private static function readsNextTo(node: QueryNode, vocab: Vocab, hits: Array<String>): Bool {
		return (isCharacterRead(node, vocab) && node.children.exists(arg -> arg != node.children[0] && mentionsAny(arg, vocab, hits)))
			|| node.children.exists(child -> readsNextTo(child, vocab, hits));
	}

	private static function isCharacterRead(node: QueryNode, vocab: Vocab): Bool {
		final callee: Null<QueryNode> = node.children[0];
		return node.kind == vocab.callKind && callee != null && callee.kind == vocab.accessKind && READ_METHODS.contains(callee.name ?? '');
	}

}
