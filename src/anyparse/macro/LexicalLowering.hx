package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;

using Lambda;

/**
 * One thing the walk does inside a literal's BODY, in the order the grammar declares it.
 *
 * `Skip` is a run consumed whole so that whatever follows cannot be misread — the escaped
 * trigger `$$`, or a bare trigger that opens nothing. `Hole` is a region of CODE embedded in
 * the literal: the walk re-enters the top-level arms inside it, and finds its end by
 * balancing the declared nesting pair.
 */
enum LexBodyAtom {

	Skip(text: String);
	Hole(open: String, close: String, nestOpen: String, nestClose: String);

}

/**
 * One non-code region a grammar declares, in the form the generated walk consumes.
 *
 * Every field is DERIVED — from the format's comment delimiters, from a terminal's own
 * `@:re`, or from the `@:lead` / `@:trail` / `@:lit` / `@:balanced` of a delimited rule and
 * its segment constructors. Nothing here is spelled twice.
 */
typedef LexRegionSpec = {

	/** The `LexRegionKind` constructor an emitted region of this shape carries. */
	kind: String,

	/** Literal that opens the region. */
	open: String,

	/** Literal that closes it — empty when `lineTerminated`. */
	close: String,

	/** The region ends at the next `\n`, exclusive, rather than at `close`. */
	lineTerminated: Bool,

	/** Character that makes the next one body text; -1 when the body has no escape. */
	escape: Int,

	/**
	 * The body may not cross a `\n`. A region that does not close on its own line opens
	 * NOTHING — the opener was ambiguous — while a region without this bound runs to EOF.
	 */
	sameLine: Bool,

	/** Inclusive character range accepted as trailing flags after `close`; -1 / -1 when none. */
	flagLow: Int,

	flagHigh: Int,

	/** What the body holds besides plain text, in declaration order. */
	body: Array<LexBodyAtom>,

	/** The declaration this was read from — named in a macro error and in the generated doc. */
	origin: String
};

/**
 * The lexical pass's LOWERING — the third of the five passes, run for the
 * `Build.buildLexicalScan` entry point.
 *
 * It answers one question about a grammar: which byte ranges of a source are NOT code. The
 * answer is assembled from declarations that already exist for the parser, plus two that this
 * pass adds:
 *
 *  - the format's `lineComment` / `blockComment`, already read into
 *    `FormatReader.commentPatterns` for the generated `skipWs`;
 *  - `@:lexical(<Kind>)` on a rule that IS such a region — a `@:re` terminal, or a
 *    `@:lead` / `@:trail` rule over a segment enum;
 *  - `@:balanced(<open>, <close>)` on a segment constructor whose body is CODE, naming the
 *    pair whose balancing ends it.
 *
 * `@:balanced` is the ONE thing no declaration expressed before: where an interpolation hole
 * ENDS is brace-and-quote balancing, and a hand lexer was the only place that knew it.
 *
 * A `@:re` a spec is read from must be a DELIMITED-LITERAL pattern —
 * `<open>(?:[^<excluded>]|<esc>.)*<close>[<flags>]*` — because the walk needs the delimiters
 * and the escape, not just a matcher: a literal left open at EOF still bounds a region, and a
 * regex cannot express that. A pattern of any other shape is a compile error naming the rule,
 * never a silently-skipped arm.
 */
class LexicalLowering {

	/** Length of the one trailing-flag form the pattern shape allows, `[a-z]*`. */
	private static inline final FLAG_RANGE_LEN: Int = 6;

	/** Regex metacharacters that end a literal run inside a pattern. */
	private static final RE_META: String = '([{*+?|)^$.';

	/** `(?:[^` — the opening of the body alternation a delimited-literal pattern must have. */
	private static final BODY_OPEN: String = '(?:[^';

	/**
	 * Every non-code region `shape`'s grammar and `formatInfo`'s format declare, ordered so a
	 * longer opener is tried before a shorter one that prefixes it.
	 */
	public static function generate(
		shape: ShapeBuilder.ShapeResult, formatInfo: FormatReader.FormatInfo, schemaTypePath: String
	): Array<LexRegionSpec> {
		final kinds: Array<String> = kindNames();
		final out: Array<LexRegionSpec> = [];
		// Map iteration order is not specified; sort so the generated arms are byte-stable.
		final names: Array<String> = [for (name in shape.rules.keys()) name];
		names.sort((a: String, b: String) -> if (a < b)
			-1
		else if (a > b)
			1
		else
			0);
		for (name in names) {
			final node: Null<ShapeNode> = shape.rules[name];
			if (node == null) continue;
			final kind: Null<String> = lexicalKindOf(node, name, kinds);
			if (kind == null) continue;
			out.push( switch node.kind {
				case Terminal: atomicSpec(node, kind, name);
				case Seq: delimitedSpec(shape, node, kind, name);
				case _: fail('LexicalLowering: @:lexical on $name needs a @:re terminal or a @:lead/@:trail rule');
			});
		}
		for (p in formatInfo.commentPatterns) out.push({
			kind: p.lineTerminated ? 'LineComment' : 'BlockComment',
			open: p.open,
			close: p.lineTerminated ? '' : p.close,
			lineTerminated: p.lineTerminated,
			escape: -1,
			sameLine: false,
			flagLow: -1,
			flagHigh: -1,
			body: [],
			origin: schemaTypePath
		});
		out.sort((a: LexRegionSpec, b: LexRegionSpec) -> b.open.length - a.open.length);
		return out;
	}

	/** The kinds a region may carry — the constructors of the engine's own `LexRegionKind`. */
	public static function kindNames(): Array<String> {
		return switch Context.getType('anyparse.query.LexicalRegions.LexRegionKind') {
			case TAbstract(ref, _):
				final impl: Null<Ref<ClassType>> = ref.get().impl;
				impl == null ? [] : [for (f in impl.get().statics.get()) f.name];
			case _: [];
		};
	}

	/** The `@:re` pattern on `node`, or null. */
	private static inline function patternOf(node: ShapeNode): Null<String> {
		return stringMetaOf(node, ':re');
	}

	/**
	 * Report `message` and stop the build. Typed `Dynamic` so a caller in a value position can
	 * `return` it: `Context.fatalError` never returns, but only a throw says so to the typer,
	 * and seven copies of `throw 'unreachable'` are seven chances to throw the wrong thing.
	 */
	private static function fail(message: String, ?pos: Position): Any {
		return Context.fatalError(message, pos ?? Context.currentPos());
	}

	/** The `@:lexical(<Kind>)` argument on `node`, or null when it declares none. */
	private static function lexicalKindOf(node: ShapeNode, origin: String, kinds: Array<String>): Null<String> {
		final meta: Null<Metadata> = node.annotations[AnnotationKeys.BASE_META];
		if (meta == null) return null;
		for (entry in meta) if (entry.name == ':lexical') {
			if (entry.params.length != 1) Context.fatalError('@:lexical expects exactly one region-kind argument', entry.pos);
			final name: String = switch entry.params[0].expr {
				case EConst(CIdent(s)): s;
				case _: fail('@:lexical argument must be a region-kind identifier', entry.params[0].pos);
			};
			if (!kinds.contains(name))
				Context.fatalError('@:lexical on $origin names "$name", which is not a region kind (${kinds.join(', ')})', entry.pos);
			return name;
		}
		return null;
	}

	/** The spec of a region whose whole extent one `@:re` terminal describes. */
	private static function atomicSpec(node: ShapeNode, kind: String, origin: String): LexRegionSpec {
		final pattern: String = patternOf(node) ?? fail(
			'LexicalLowering: @:lexical on $origin needs a @:re pattern to derive its delimiters from'
		);
		final re: ReShape = parseDelimitedRe(pattern, origin);
		if (re.prefix == '' || re.suffix == '')
			Context.fatalError('LexicalLowering: the @:re on $origin carries no opening or closing literal', Context.currentPos());
		if (!re.excluded.contains(re.suffix.charCodeAt(0) ?? -1))
			Context.fatalError(
				'LexicalLowering: the @:re body on $origin does not exclude its own closer "${re.suffix}"', Context.currentPos()
			);
		return {
			kind: kind,
			open: re.prefix,
			close: re.suffix,
			lineTerminated: false,
			escape: re.escape,
			sameLine: re.excluded.contains('\n'.code),
			flagLow: re.flagLow,
			flagHigh: re.flagHigh,
			body: [],
			origin: origin
		};
	}

	/**
	 * The spec of a region declared as a `@:lead` / `@:trail` Star over a segment enum: the
	 * delimiters come off the Star's field, and the body's escape, its skipped runs and its
	 * code holes off the segment constructors, in declaration order.
	 */
	private static function delimitedSpec(shape: ShapeBuilder.ShapeResult, node: ShapeNode, kind: String, origin: String): LexRegionSpec {
		final star: ShapeNode = node.children.find(child ->
			child.kind == Star
		) ?? fail('LexicalLowering: @:lexical on $origin needs a repeated segment field to walk');
		final lead: String = stringMetaOf(star, ':lead') ?? fail(
			'LexicalLowering: @:lexical on $origin needs @:lead and @:trail on its segment field'
		);
		final trail: String = stringMetaOf(star, ':trail') ?? fail(
			'LexicalLowering: @:lexical on $origin needs @:lead and @:trail on its segment field'
		);
		final segments: ShapeNode = altOf(shape, star) ?? fail(
			'LexicalLowering: the segment field of $origin must reference an enum of segments'
		);
		final body: Array<LexBodyAtom> = [];
		var escape: Int = -1;
		var excluded: Array<Int> = [];
		for (branch in segments.children) {
			final lit: Null<String> = stringMetaOf(branch, ':lit');
			if (lit != null) {
				pushSkip(body, lit);
				continue;
			}
			final branchLead: Null<String> = stringMetaOf(branch, ':lead');
			if (branchLead == null) {
				final run: Null<ShapeNode> = refTarget(shape, branch.children[0]);
				final pattern: Null<String> = run == null ? null : patternOf(run);
				if (pattern == null) continue;
				final re: ReShape = parseDelimitedRe(pattern, origin);
				escape = re.escape;
				excluded = re.excluded;
				continue;
			}
			final nest: Null<Array<String>> = balancedOf(branch);
			if (nest == null) {
				pushSkip(body, branchLead);
				continue;
			}
			final branchTrail: String = stringMetaOf(branch, ':trail') ?? fail(
				'LexicalLowering: @:balanced on a segment of $origin needs the @:trail that closes it'
			);
			body.push(Hole(branchLead, branchTrail, nest[0], nest[1]));
		}
		if (escape < 0)
			Context.fatalError('LexicalLowering: no segment of $origin carries the @:re that spells its body escape', Context.currentPos());
		if (!excluded.contains(trail.charCodeAt(0) ?? -1))
			Context.fatalError(
				'LexicalLowering: the segment body of $origin does not exclude its own closer "$trail"', Context.currentPos()
			);
		return {
			kind: kind,
			open: lead,
			close: trail,
			lineTerminated: false,
			escape: escape,
			sameLine: excluded.contains('\n'.code),
			flagLow: -1,
			flagHigh: -1,
			body: body,
			origin: origin
		};
	}

	/**
	 * Record a run the body consumes whole, unless an earlier constructor already declared the
	 * same one. Two constructors may legitimately spell one trigger — an interpolation
	 * shorthand's `@:lead` and the lone-trigger `@:lit` beside it — and only the first
	 * position matters to a walk that is looking for the literal's end.
	 */
	private static function pushSkip(body: Array<LexBodyAtom>, text: String): Void {
		for (atom in body) switch atom {
			case Skip(seen) if (seen == text):
				return;
			case _:
		}
		body.push(Skip(text));
	}

	/** The `@:balanced(<open>, <close>)` pair on `node`, or null when it declares none. */
	private static function balancedOf(node: ShapeNode): Null<Array<String>> {
		final meta: Null<Metadata> = node.annotations[AnnotationKeys.BASE_META];
		if (meta == null) return null;
		for (entry in meta) if (entry.name == ':balanced') {
			if (entry.params.length != 2) Context.fatalError('@:balanced expects an opening and a closing literal', entry.pos);
			final pair: Array<String> = [
				for (p in entry.params) switch p.expr {
					case EConst(CString(s, _)): s;
					case _: fail('@:balanced arguments must be string literals', p.pos);
				}
			];
			for (side in pair) if (side.length != 1) Context.fatalError('@:balanced counts single characters, got "$side"', entry.pos);
			return pair;
		}
		return null;
	}

	/** The single string argument of `node`'s `@:<tag>`, or null when it carries none. */
	private static function stringMetaOf(node: ShapeNode, tag: String): Null<String> {
		final meta: Null<Metadata> = node.annotations[AnnotationKeys.BASE_META];
		if (meta == null) return null;
		for (entry in meta) if (entry.name == tag) {
			if (entry.params.length != 1) return null;
			switch entry.params[0].expr {
				case EConst(CString(s, _)):
					return s;
				case _:
					return null;
			}
		}
		return null;
	}

	/** The rule a `Ref` node points at, or null when `node` is not one. */
	private static function refTarget(shape: ShapeBuilder.ShapeResult, node: Null<ShapeNode>): Null<ShapeNode> {
		if (node == null || node.kind != Ref) return null;
		final name: Null<String> = node.annotations[AnnotationKeys.BASE_REF];
		return name == null ? null : shape.rules[name];
	}

	/** The `Alt` rule a Star's element references, or null. */
	private static function altOf(shape: ShapeBuilder.ShapeResult, star: ShapeNode): Null<ShapeNode> {
		final target: Null<ShapeNode> = refTarget(shape, star.children[0]);
		return target != null && target.kind == Alt ? target : null;
	}

	/**
	 * The literal run of `pattern` starting at `at` — every character up to the first regex
	 * metacharacter, with a backslash escape contributing the character it escapes.
	 */
	private static function literalRun(pattern: String, at: Int): LiteralRun {
		final run: StringBuf = new StringBuf();
		final n: Int = pattern.length;
		var i: Int = at;
		while (i < n) {
			final c: String = pattern.charAt(i);
			if (c == '\\' && i + 1 < n) {
				run.add(pattern.charAt(i + 1));
				i += 2;
				continue;
			}
			if (RE_META.indexOf(c) >= 0) break;
			run.add(c);
			i++;
		}
		return { text: run.toString(), next: i };
	}

	/** The character codes of the `[^ … ]` set `pattern` opens at `at`, up to its `]`. */
	private static function excludedSet(pattern: String, at: Int): ExcludedSet {
		final codes: Array<Int> = [];
		final n: Int = pattern.length;
		var i: Int = at;
		while (i < n && pattern.charAt(i) != ']') {
			if (pattern.charAt(i) == '\\' && i + 1 < n) {
				codes.push(pattern.charCodeAt(i + 1) ?? -1);
				i += 2;
				continue;
			}
			codes.push(pattern.charCodeAt(i) ?? -1);
			i++;
		}
		return { codes: codes, next: i };
	}

	/**
	 * `pattern` read as a delimited literal — its opening and closing literals, the characters
	 * its body excludes, the escape that suspends them and the trailing flag range.
	 *
	 * Deliberately narrow: it accepts the ONE shape whose delimiters are recoverable, and
	 * errors on everything else naming `origin`. The alternative — running the regex — cannot
	 * answer where an UNTERMINATED literal ends, and that is a region the scan must still
	 * report, since it is handed raw, possibly mid-edit text.
	 */
	private static function parseDelimitedRe(pattern: String, origin: String): ReShape {
		final n: Int = pattern.length;
		inline function reject(why: String): Void {
			fail('LexicalLowering: the @:re on $origin is not a delimited-literal pattern ($why): $pattern');
		}
		final head: LiteralRun = literalRun(pattern, 0);
		var i: Int = head.next;
		if (pattern.substr(i, BODY_OPEN.length) != BODY_OPEN) reject('expected `$BODY_OPEN` after the opening literal');
		i += BODY_OPEN.length;
		final body: ExcludedSet = excludedSet(pattern, i);
		i = body.next;
		if (pattern.substr(i, 2) != ']|') reject('expected `]|` and then the escape alternative');
		i += 2;
		if (pattern.charAt(i) != '\\' || i + 1 >= n) reject('the escape alternative must start with an escaped character');
		final escape: Int = pattern.charCodeAt(i + 1) ?? -1;
		i += 2;
		if (pattern.substr(i, 2) != '.)') reject('the escape alternative must be `<esc>.`');
		i += 2;
		final repeat: String = pattern.charAt(i);
		if (repeat != '*' && repeat != '+') reject('the body alternation must repeat');
		i++;
		final tail: LiteralRun = literalRun(pattern, i);
		i = tail.next;
		var flagLow: Int = -1;
		var flagHigh: Int = -1;
		if (i < n && pattern.charAt(i) == '[') {
			if (pattern.charAt(i + 2) != '-' || pattern.substr(i + 4, 2) != ']*') reject('trailing flags must be one `[a-z]*` range');
			flagLow = pattern.charCodeAt(i + 1) ?? -1;
			flagHigh = pattern.charCodeAt(i + 3) ?? -1;
			i += FLAG_RANGE_LEN;
		}
		if (i != n) reject('trailing pattern text after the closing literal');
		return {
			prefix: head.text,
			suffix: tail.text,
			excluded: body.codes,
			escape: escape,
			flagLow: flagLow,
			flagHigh: flagHigh
		};
	}

}

/** A delimited-literal `@:re` taken apart into the pieces a walk needs. */
private typedef ReShape = {
	prefix: String,
	suffix: String,
	excluded: Array<Int>,
	escape: Int,
	flagLow: Int,
	flagHigh: Int
};
/** A run of literal characters read out of a pattern, and where reading stopped. */
private typedef LiteralRun = {
	text: String,
	next: Int
};

/** The character codes a pattern's `[^ … ]` set excludes, and where reading stopped. */
private typedef ExcludedSet = {
	codes: Array<Int>,
	next: Int
};
#end
