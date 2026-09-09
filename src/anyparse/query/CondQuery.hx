package anyparse.query;

import anyparse.query.CondDirectives.CondDirective;
import anyparse.query.CondRegionLiveness;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.runtime.Span;

using Lambda;
using StringTools;

/**
 * The DIRECTIVE-DELIMITED BRANCH — what `apq cond` reports, and the one thing at this layer that
 * has to be delimited without a node to point at.
 *
 * A `#if A … #elseif B … #else … #end` region projects as ONE node whose span covers every branch
 * and whose children are all the branches' constructs flattened into a single sibling list: the
 * tree carries no branch boundary at all (`CondBranchProjection` says so of its own input, and
 * S163 re-measured it). So a branch is NOT a node, cannot be addressed by a selector, and cannot
 * be sliced out of a node span.
 *
 * What does delimit one is the region's own directive line. This class replays
 * `CondDirectives.scan` through a depth stack — the same replay `CondBranchPath.scan` performs
 * for its own question — and takes a branch's BODY to be the byte run
 * `[openingDirective.span.to, nextSameDepthDirective.span.from)`. Three properties fall out of
 * that definition, and they are what the command's contract rests on:
 *
 * - NEST-SAFE by construction rather than by counting depth inside a branch: an inner region's
 *   directives are consumed while its own frame is on top of the stack, so the outer branch
 *   simply runs across the whole inner region.
 * - PARSE-FREE. The scan is lexical, so `cond` reaches a file the grammar cannot parse and, more
 *   importantly, reaches the shapes where the grammar parses but projects nothing: an
 *   expression-position `#if` (`return #if nodejs a; #else b; #end`) is a single childless
 *   `CondSplice*` node, and that is exactly the site a node-based reader goes silent on.
 * - It never covers its OWN directives, so a printed body starts and stops where the branch
 *   does. That is the whole point of the command: the route it replaces was
 *   `lit --include-directives` for the `#if` line plus one `source --range` per site with a
 *   GUESSED end line.
 *
 * Whether a branch has a tree at all is asked STRUCTURALLY — does any projected node lie wholly
 * inside the body span — and never from `RefShape.opaqueCondRegionKinds`. That list names the
 * ctors a grammar falls back to for an unbalanced region, which is a different question:
 * `CondSpliceReturnStmt` is not on it and still projects no interior, so a kind test would have
 * called such a branch modelled and then had nothing to print for it. A body with text but no
 * node is flagged `raw` and printed VERBATIM — going silent there is the one outcome this class
 * must not have. A BLANK body is not raw: there is nothing in it to model.
 *
 * Liveness is the shared step: `CondRegionLiveness.branchStep` folded over the region's
 * directives under the hypothesis the caller states about the queried define — IS defined by
 * default, is NOT defined when the caller opts into the negative polarity — while every other
 * flag is unknown. `live` means provably taken, `dead` provably not, and `maybe` that a flag outside the
 * query decides — the three-valued answer a positive-only define set can honestly give.
 *
 * Pure: no filesystem, no process, no state between calls.
 */
@:nullSafety(Strict)
final class CondQuery {

	/**
	 * Lines of one branch rendered before the rest are folded into a `… +N more line(s)` marker,
	 * when the caller states no budget of its own.
	 *
	 * A cap is not a nicety here. The define this command is most often asked about is the one a
	 * file uses as its TOP-LEVEL guard, and then a single branch is the whole file: measured on
	 * this tree, `cond nodejs src/anyparse/query` matches 87 regions and prints 215 434 bytes
	 * uncapped against 40 750 at this budget, for the same 121 head lines. `--limit` cannot help —
	 * it counts branches, not lines. Same direction as `lit`'s own flood guard, which folds a
	 * multi-line hit to its first line plus a count; a body is the payload here, so the budget is
	 * larger and the marker still names exactly what it dropped.
	 */
	public static inline final DEFAULT_MAX_BODY: Int = 20;

	/** The two-space group indent every walker's per-file hit lines carry. */
	private static inline final HEAD_INDENT: String = '  ';

	/** The indent a branch's own source — or, under `--names`, its name rows — is re-based onto. */
	private static inline final BODY_INDENT: String = '      ';

	/**
	 * Every conditional-compilation region of `source` whose OWN directives mention `define` as a
	 * standalone identifier, in document order, each carrying one entry per branch.
	 *
	 * A region matches on its `#if` and `#elseif` CONDITIONS, so `#if (sys || nodejs)` answers a
	 * query for `nodejs` — which a text search for `#if nodejs` does not. An `#else` carries no
	 * condition and never matches on its own; it is reported as a branch of the region that does.
	 *
	 * A NESTED region that mentions the define is reported as its own entry as well as inside its
	 * parent's branch body, so its text appears twice; the entry is tagged `nested` rather than
	 * suppressed, since a region the query matches is a site the caller asked about.
	 *
	 * `tree` is optional. Without it — a file the grammar could not parse — every non-blank body
	 * comes back `raw`, which is the honest degradation: the bodies are still exact, only their
	 * interior is unmodelled.
	 *
	 * `undefined` flips the hypothesis liveness is folded under: by default `define` is taken to BE
	 * defined, and with it set the define is taken NOT to be — the polarity `apq resolve-define
	 * --undefined` needs. Which regions MATCH is unaffected; only their per-branch `live` changes.
	 *
	 * A region left open at the end of the file is not reported at all, and a stray branch or
	 * closer with no region open is ignored: the same directions `CondDirectives.topLevelBlocks`
	 * and `CondBranchPath.scan` already take, for the same reason — a text whose directives do not
	 * nest is one nothing here can model, and a slice ending somewhere nobody chose is worse than
	 * no slice.
	 */
	public static function regionsMentioning(
		source: String, tree: Null<QueryNode>, shape: RefShape, regions: () -> Array<LexRegion>, define: String, undefined: Bool = false
	): Array<CondRegion> {
		final declared: Null<String> = shape.conditionalIfKeyword;
		if (declared == null || declared == '' || define.length == 0) return [];
		// Re-bound to a non-null local: strict null-safety narrowing does not reach into an
		// anonymous-structure literal.
		final ifKeyword: String = declared;
		final seams: CondSeams = {
			ifKeyword: ifKeyword,
			endKeyword: shape.conditionalEndKeyword,
			elseKeywords: shape.conditionalElseKeywords ?? [],
			define: define,
			facts: undefined ? { defined: [], undefined: [define] } : { defined: [define], undefined: [] }
		};
		final out: Array<CondRegion> = [];
		final open: Array<OpenRegion> = [];
		for (directive in CondDirectives.scan(source, shape, regions)) {
			if (directive.keyword == seams.ifKeyword) {
				open.push({ depth: open.length, heads: [directive], bodies: [] });
				continue;
			}
			if (open.length == 0) continue;
			final frame: OpenRegion = open[open.length - 1];
			if (directive.keyword == seams.endKeyword) {
				closeBranch(frame, directive);
				open.pop();
				final region: Null<CondRegion> = buildRegion(source, tree, frame, directive, seams);
				if (region != null) out.push(region);
				continue;
			}
			if (!seams.elseKeywords.contains(directive.keyword)) continue;
			closeBranch(frame, directive);
			frame.heads.push(directive);
		}
		out.sort((a, b) -> a.span.from - b.span.from);
		return out;
	}

	/**
	 * The distinct `<Kind> <name>` rows of every projected node lying wholly inside `body`, in
	 * document order — what `--names` prints instead of the branch source.
	 *
	 * Named nodes rather than a declaration/call classification: a name slot is what every grammar
	 * carries, so the answer stays grammar-agnostic, and for the question the flag exists to answer
	 * ("what does this branch touch") a declaration and a call target are both wanted. SYMBOLS only —
	 * `collectNames` drops a name that is not identifier-shaped AND a node whose kind the grammar
	 * declares as carrying literal text, so a string literal's content stays out of the list whichever
	 * way it is quoted. Empty for a branch with no tree, which is why the caller prints the raw body
	 * for those instead.
	 */
	public static function namesIn(tree: Null<QueryNode>, body: Span, shape: RefShape): Array<String> {
		final out: Array<String> = [];
		if (tree != null) collectNames(tree, body, shape, out);
		return out;
	}

	/**
	 * Whether a branch with this liveness survives the caller's filter. `--active` keeps every
	 * branch that is not provably dead ("can run with the define set"), `--inactive` keeps exactly
	 * the provably dead ones ("cannot"), and the two partition a region's branches. Neither flag —
	 * or both — keeps everything.
	 */
	public static function keepsBranch(opts: CondRenderOptions, live: Null<Bool>): Bool {
		if (opts.active == opts.inactive) return true;
		final dead: Bool = live != null && !live;
		return opts.active ? !dead : dead;
	}

	/**
	 * The report for one file: a group header, then one head line per kept branch — its position,
	 * its verbatim directive and its tags — followed by its body (or its name rows) indented under
	 * it. Empty when nothing was kept, so a caller can concatenate per-file reports.
	 */
	public static function render(
		file: String, source: String, tree: Null<QueryNode>, found: Array<CondRegion>, opts: CondRenderOptions, shape: RefShape
	): String {
		final buf: StringBuf = new StringBuf();
		final body: StringBuf = new StringBuf();
		for (region in found) for (branch in region.branches) if (keepsBranch(opts, branch.live)) {
			final at: Position = branch.at.lineCol(source);
			final head: String = opts.flat ? '$file:${at.line}:${at.col}: ' : '$HEAD_INDENT${at.line}:${at.col}: ';
			body.add('$head${branch.directive}${tags(region, branch, tree != null)}\n');
			// Trailing blanks are stripped per line: an inline region's body is the text between
			// two directives on one line, so it arrives with the space before the next `#else`
			// still on it, and a whitespace-only interior line would otherwise print as indent.
			for (line in branchLines(source, tree, branch, opts, shape)) {
				final text: String = line.rtrim();
				body.add(text == '' ? '\n' : '$BODY_INDENT$text\n');
			}
		}
		final rendered: String = body.toString();
		if (rendered == '') return '';
		if (!opts.flat) buf.add('$file:\n');
		buf.add(rendered);
		return buf.toString();
	}

	/** Whether `name` earns a row: an identifier path, or a metadata name written with one of the grammar's sigils. */
	private static inline function symbolRow(name: String, shape: RefShape): Bool {
		return isSymbolName(name) || isMetadataName(name, shape);
	}

	/**
	 * Close `frame`'s current branch at `next`, the directive that ends it. The body runs from the
	 * END of the branch's own opening directive to the START of this one, so it carries neither —
	 * which is what makes a printed body need no `#end` hunting.
	 */
	private static function closeBranch(frame: OpenRegion, next: CondDirective): Void {
		frame.bodies.push(new Span(frame.heads[frame.heads.length - 1].span.to, next.span.from));
	}

	/**
	 * The region `frame` and its closing directive describe, with per-branch liveness folded in, or
	 * null when none of its own directives mentions the queried define.
	 */
	private static function buildRegion(
		source: String, tree: Null<QueryNode>, frame: OpenRegion, close: CondDirective, seams: CondSeams
	): Null<CondRegion> {
		if (!mentionsDefine(source, frame.heads, seams.define)) return null;
		final branches: Array<CondBranch> = [];
		var guard: Null<Bool> = true;
		for (i => head in frame.heads) {
			final takes: Bool = CondDirectives.takesCondition(head.keyword, seams.ifKeyword, seams.endKeyword);
			final value: Null<Bool> = takes ? CondRegionLiveness.conditionValueFacts(source, head, seams.facts) : true;
			final step: CondBranchStep = CondRegionLiveness.branchStep(guard, value);
			guard = step.guard;
			final body: Span = frame.bodies[i];
			branches.push({
				keyword: head.keyword,
				directive: CondDirectives.text(source, head),
				at: head.span,
				body: body,
				live: step.live,
				raw: isRawBody(source, tree, body)
			});
		}
		return { span: new Span(frame.heads[0].span.from, close.span.to), depth: frame.depth, branches: branches };
	}

	/** Whether any of a region's own opening / branch directives spells `define` as a standalone identifier. */
	private static function mentionsDefine(source: String, heads: Array<CondDirective>, define: String): Bool {
		for (head in heads) {
			final condition: Null<Span> = head.condition;
			if (condition != null && SourceText.mentionsIdent(source, condition, define)) return true;
		}
		return false;
	}

	/**
	 * Whether `body` holds text the tree does not model — the RAW branch, printed verbatim and
	 * marked. Blank is not raw: an empty branch has no interior to lose.
	 *
	 * Blankness is asked of the body's OWN bytes, never of `SourceText.isBlankSpan`: that helper
	 * strips the first and last byte of the span it is handed — a block's `{` / `}` — and a
	 * directive-delimited body carries no delimiters. Asked of it, an EMPTY body read non-blank
	 * (its reversed bounds swap, so it answered about two bytes of the directive) and a two-byte
	 * one read blank, which drops the raw flag and with it the branch's bytes under `--names`.
	 */
	private static function isRawBody(source: String, tree: Null<QueryNode>, body: Span): Bool {
		return source.substring(body.from, body.to).trim() != '' && (tree == null || !hasNodeInside(tree, body));
	}

	/** Whether any node under `node` has a non-empty span lying wholly inside `body`; subtrees that cannot overlap are pruned. */
	private static function hasNodeInside(node: QueryNode, body: Span): Bool {
		final span: Null<Span> = node.span;
		if (span != null) {
			if (span.to <= body.from || span.from >= body.to) return false;
			if (span.from >= body.from && span.to <= body.to && span.to > span.from) return true;
		}
		return node.children.exists(child -> hasNodeInside(child, body));
	}

	/**
	 * Append the distinct `<Kind> <name>` rows of every named node wholly inside `body`, in document
	 * order.
	 *
	 * Two filters, answering different halves of "is this name a SYMBOL".
	 *
	 * SHAPE — a name that is neither identifier-shaped (`isSymbolName`) nor a metadata name
	 * (`isMetadataName`, the shape's own sigils) contributes no row, because a leaf's name slot is
	 * not always a symbol. Asked of the text, so the identifier half needs no grammar seam; and it
	 * cannot finish the job, since `'probe.hx'` IS a dotted pair of identifiers. Half a diagnostic
	 * message and a file name reached a list of declarations that way.
	 *
	 * KIND — a node whose kind is the grammar's `stringInterpTextKind`, or one of its `stringLiteralKinds`,
	 * carries literal CONTENT in its name slot BY DECLARATION and contributes no row either. Its
	 * CHILDREN are still walked: a `$name` (`stringInterpIdentKind`) and a `${ … }`
	 * (`stringInterpBlockKind`) are real references the branch really does touch. Measured over `src` +
	 * `test`, this drops 795 / 900 / 1481 `Literal` rows for `nodejs` / `sys` / `macro`, and rows of no
	 * other kind.
	 *
	 * The kind filter is what makes the two spellings of ONE literal answer alike. They do not project
	 * alike and are not meant to: `'x'` is a composite whose text lives in `Literal` CHILD segments —
	 * segments are what interpolation needs — while `"x"` is one `@:rawString` terminal whose own
	 * `name` is the source slice WITH its quotes (`HxDoubleStringLit` records why the quotes stay).
	 * Before the kind filter the first leaked and the second was kept out only by those quote marks,
	 * which is an accident of the raw spelling and not a contract anything states.
	 *
	 * A metadata NAME is a symbol here, decided in S188 and spelled `metadataNamePrefixes` in the
	 * shape. The argument that settled it is an asymmetry WITHIN one construct rather than a taste
	 * about what `@:meta` is: `@:access(pkg.Other)` under a `#if` contributed `IdentExpr pkg` and
	 * `FieldAccess Other` — its ARGUMENT, reached as an ordinary child — while the annotation that
	 * decides what those two mean contributed nothing, and `@:native('nativeSpelling')` contributed
	 * nothing at all. A census of what a flag reaches that counts a build macro's argument and hides
	 * the build macro is not a census. The sigil STAYS in the row (`MetaCall @:build`), so a reader
	 * and a script can still tell a compile-time annotation from a binding, and the kind column said
	 * so already.
	 *
	 * What that does NOT change is the literal rule below: `@:native('x')`'s string argument is still
	 * dropped by `carriesLiteralText`, which is `--names`' own semantics (symbol names, not literals)
	 * and not a second gap.
	 *
	 * Two neighbouring gaps recorded here by S178 were re-measured in S181 and are NOT open:
	 *
	 * - METADATA ARGUMENTS ARE VISIBLE. `QueryNode` carries them as CHILDREN of the metadata node —
	 *   `@:native('Foo.Bar')` projects `(MetaCall @:native (SingleStringExpr (Literal Foo.Bar)))`,
	 *   `@:access(pkg.Other)` its `FieldAccess` / `IdentExpr` pair — and this walk reaches them like
	 *   any other child, while `apq meta '@:native(...)'` matches the argument exactly.
	 * - NEITHER FORM IS DECODED. Both string terminals are `@:rawString`, so `'a\tb'` yields the
	 *   four-character `Literal a\tb` and not a tab; a consumer wanting the runtime value calls
	 *   `HxStringEscape`.
	 */
	private static function collectNames(node: QueryNode, body: Span, shape: RefShape, out: Array<String>): Void {
		final span: Null<Span> = node.span;
		if (span != null && (span.to <= body.from || span.from >= body.to)) return;
		final name: Null<String> = node.name;
		if (
			name != null && !carriesLiteralText(node.kind, shape) && symbolRow(name, shape) && span != null && span.from >= body.from
			&& span.to <= body.to
		) {
			final row: String = '${node.kind} $name';
			if (!out.contains(row)) out.push(row);
		}
		for (child in node.children) collectNames(child, body, shape, out);
	}

	/**
	 * Whether `kind`'s name slot holds literal TEXT rather than a symbol — an interpolating
	 * literal's text fragment (`stringInterpTextKind`) or a whole string literal (`stringLiteralKinds`).
	 *
	 * A grammar that declares neither answers false for everything, which is the pre-seam behaviour:
	 * a plugin gets literal content back in its symbol rows until it names the kinds that carry it.
	 */
	private static function carriesLiteralText(kind: String, shape: RefShape): Bool {
		return kind == shape.stringInterpTextKind || (shape.stringLiteralKinds ?? []).contains(kind);
	}

	/**
	 * Whether `name` is symbol-shaped: one identifier, or a dotted path of them.
	 *
	 * Dotted because a name slot is not always a bare word — an import carries its WHOLE path there
	 * (`js.node.ChildProcess.Result`), which is the most useful row a guarded import block can
	 * produce, and rejecting it left the branch reporting nothing at all.
	 */
	private static function isSymbolName(name: String): Bool {
		return name.length != 0 && name.split('.').foreach(segment -> SourceText.isIdentifier(segment));
	}

	/**
	 * Whether `name` is a metadata name: one of the grammar's `metadataNamePrefixes` followed by an
	 * identifier path.
	 *
	 * The LONGEST matching prefix decides, because Haxe's two sigils NEST — `@:` starts with `@`, so
	 * taking the first match in declaration order would leave `:build` as the remainder and reject
	 * it. Read that way rather than by sorting the set: an order-dependent read of a declared
	 * vocabulary is a coupling a grammar author has no way to know about, and it costs one pass over
	 * a two-entry set. It is NOT allocation-free — the remainder check takes a `substr` — but it runs
	 * only on a name that already carries a sigil, which is a minority of the named nodes it sees.
	 */
	private static function isMetadataName(name: String, shape: RefShape): Bool {
		var longest: Int = -1;
		for (prefix in shape.metadataNamePrefixes ?? []) if (name.startsWith(prefix) && prefix.length > longest) longest = prefix.length;
		return longest >= 0 && isSymbolName(name.substr(longest));
	}

	/**
	 * The bracketed tag list on a branch's head line: its liveness, then the unmodelled-body marker
	 * and `nested` when they apply.
	 *
	 * That marker names its CAUSE, because there are two and they read differently: `raw span` for a
	 * body no node covers in a file the grammar DID parse — an expression-position `#if` — and
	 * `no parse` when the file has no tree at all, where every non-blank body is unmodelled for the
	 * same one reason. Spelling both `raw span` would let a whole unparseable file read as a pile of
	 * expression splices, and nothing else in a MULTI-file walk says otherwise: `CliWalk.parseWalked`
	 * reports a parse failure only for a single file.
	 */
	private static function tags(region: CondRegion, branch: CondBranch, parsed: Bool): String {
		final live: Null<Bool> = branch.live;
		final parts: Array<String> = [live == null ? 'maybe' : live ? 'live' : 'dead'];
		if (branch.raw) parts.push(parsed ? 'raw span' : 'no parse');
		if (region.depth > 0) parts.push('nested');
		return ' [${parts.join(', ')}]';
	}

	/** What goes under a branch's head line: its name rows under `--names`, else its own source; never nothing. */
	private static function branchLines(
		source: String, tree: Null<QueryNode>, branch: CondBranch, opts: CondRenderOptions, shape: RefShape
	): Array<String> {
		if (opts.names && !branch.raw) {
			final rows: Array<String> = namesIn(tree, branch.body, shape);
			return capped(rows.length > 0 ? rows : ['(no named node in this branch)'], opts.maxBody, 'name');
		}
		final lines: Array<String> = bodyLines(source, branch.body);
		return capped(lines.length > 0 ? lines : ['(empty branch)'], opts.maxBody, 'line');
	}

	/**
	 * `lines` folded to `budget` entries plus a marker naming how many it dropped, or unchanged
	 * when they fit or the budget is non-positive. The marker rather than a silent cut: a body that
	 * simply stops is indistinguishable from a branch that ends there, which is the exact
	 * uncertainty this command exists to remove.
	 */
	private static function capped(lines: Array<String>, budget: Int, unit: String): Array<String> {
		if (budget <= 0 || lines.length <= budget) return lines;
		final kept: Array<String> = lines.slice(0, budget);
		kept.push('… +${lines.length - budget} more $unit(s) — raise with --max-body N, 0 for no cap');
		return kept;
	}

	/**
	 * `body`'s own lines, stripped of leading and trailing blank ones and dedented by the smallest
	 * indentation any of them carries — the same normalisation `apq source` applies to a window, so
	 * a branch printed here reads the way the same lines read there.
	 */
	private static function bodyLines(source: String, body: Span): Array<String> {
		final lines: Array<String> = source.substring(body.from, body.to).split('\n');
		while (lines.length > 0 && lines[0].trim() == '') lines.shift();
		while (lines.length > 0 && lines[lines.length - 1].trim() == '') lines.pop();
		var common: Int = -1;
		for (line in lines) if (line.trim() != '') {
			final indent: Int = line.length - line.ltrim().length;
			if (common < 0 || indent < common) common = indent;
		}
		return common <= 0 ? lines : [for (line in lines) line.length >= common ? line.substr(common) : line.ltrim()];
	}

}

/**
 * One conditional-compilation region `CondQuery.regionsMentioning` reports: `span` runs from its
 * `#if` marker to the end of its `#end`, `depth` is 0 for a region no other region encloses, and
 * `branches` holds one entry per branch in source order — including the branches whose conditions
 * do not mention the queried define, since the region is the unit a reader has to see whole.
 */
typedef CondRegion = {
	final span: Span;
	final depth: Int;
	final branches: Array<CondBranch>;
};

/**
 * One DIRECTIVE-DELIMITED branch: the `keyword` as the grammar declares it, the verbatim
 * `directive` text, `at` — the directive's own span, which is what a hit line's `line:col` names —
 * and `body`, the byte run between this directive and the next one at the same nesting depth.
 *
 * `live` is three-valued under the hypothesis the caller stated about the queried define — set,
 * or explicitly NOT set (true = provably taken, false = provably not, null = a flag outside the
 * query decides). `raw` says the body holds
 * text no projected node covers, so `--names` has nothing to answer with and the source is printed
 * instead.
 */
typedef CondBranch = {
	final keyword: String;
	final directive: String;
	final at: Span;
	final body: Span;
	final live: Null<Bool>;
	final raw: Bool;
};

/**
 * What `apq cond` asked for, as `CondQuery.render` and `CondQuery.keepsBranch` consume it. `maxBody` is the
 * per-branch line budget — `CondQuery.DEFAULT_MAX_BODY` unless the caller says otherwise, and non-positive for no cap.
 */
typedef CondRenderOptions = {
	final flat: Bool;
	final names: Bool;
	final active: Bool;
	final inactive: Bool;
	final maxBody: Int;
};

/** A region still being read: how many regions enclose it, its branch directives so far, and the bodies already closed. */
private typedef OpenRegion = {
	final depth: Int;
	final heads: Array<CondDirective>;
	final bodies: Array<Span>;
};

/**
 * The grammar's directive vocabulary plus the queried define, gathered once per
 * `regionsMentioning` call. `facts` is the hypothesis liveness is folded under: the define
 * asserted DEFINED by default, asserted UNDEFINED when the caller opts into that polarity.
 */
private typedef CondSeams = {
	final ifKeyword: String;
	final endKeyword: Null<String>;
	final elseKeywords: Array<String>;
	final define: String;
	final facts: DefineFacts;
};
