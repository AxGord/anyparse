package anyparse.macro;

#if macro
import anyparse.macro.LexicalLowering.LexBodyAtom;
import anyparse.macro.LexicalLowering.LexDirectiveSpec;
import anyparse.macro.LexicalLowering.LexRegionSpec;
import anyparse.macro.LexicalLowering.LexTokenSpec;
import haxe.macro.Context;
import haxe.macro.Expr;

/**
 * The lexical pass's CODEGEN — the fourth of the five passes, run for the
 * `Build.buildLexicalScan` entry point.
 *
 * It turns the `LexRegionSpec` list into a specialised byte walk: one arm per declared
 * region, one walk function per region, one balancing walk per interpolation hole, the
 * two public region entries every consumer already calls, and the `tokens` reader over the
 * same walks. Nothing about the grammar survives as a
 * literal in this file — every character the emitted code compares against arrives in a
 * spec, which is what makes the pass answer for a SECOND grammar without a core change.
 *
 * ## One walk, two readers, one declared policy
 *
 * The emitted walk reports every region it finds together with the interpolation DEPTH it
 * found it at, and the two entries filter that one stream:
 *
 *  - `scan` keeps the OUTERMOST regions (`depth == 0`). A `${ … }` hole is code inside a
 *    literal, but the flat region model cannot say so, so the whole literal is one region and
 *    a literal nested in a hole opens none of its own.
 *  - `scanComments` keeps the COMMENT kinds at ANY depth, so a comment an author wrote inside
 *    a hole is one — the writer's comment-loss guard must not delete it.
 *
 * That is the one place the two answers legitimately differ, and here it is a filter over a
 * single walk rather than a second lexer. `unit.LexicalRegionAgreementTest` pins it by name.
 *
 * ## Where an unterminated region ends
 *
 * A region whose body may not cross a newline (`sameLine`, which a `@:re` declares by
 * excluding `\n` from its body) and that does not close on its own line opens NOTHING: its
 * opener was ambiguous, so the walk resumes one character in. Every other region runs to EOF,
 * because the scan is handed raw, possibly mid-edit text and must still mask what the author
 * has typed so far.
 */
class LexicalCodegen {

	/** The `\n` a line-terminated region ends at. */
	private static inline final NEWLINE: Int = 10;

	/** The name of the source argument every generated entry and walk takes. */
	private static final SOURCE_ARG: String = 'source';

	/** Name of the generated walk over CODE — the top level, and the inside of every hole. */
	private static final CODE_FN: String = '_lexCode';

	/**
	 * The fields the marker class receives: the two public entries, the code walk, one walk
	 * per declared region and one balancing walk per declared hole.
	 */
	public static function emit(specs: Array<LexRegionSpec>, directives: LexDirectiveSpec, tokens: LexTokenSpec): Array<Field> {
		final fields: Array<Field> = [
			scanField(specs),
			scanCommentsField(),
			tokensField(specs, tokens),
			codeField(specs),
			directivesField(directives)
		];
		for (field in keywordFields(directives)) fields.push(field);
		for (k in 0...specs.length) {
			fields.push(regionField(specs, k));
			final spec: LexRegionSpec = specs[k];
			for (h in 0...spec.body.length) switch spec.body[h] {
				case Hole(_, close, nestOpen, nestClose):
					fields.push(holeField(specs, k, h, close, nestOpen, nestClose));
				case Skip(_):
			}
		}
		return fields;
	}

	// -------- names and types --------

	private static inline function regionFn(k: Int): String {
		return '_lexRegion$k';
	}

	private static inline function holeFn(k: Int, h: Int): String {
		return '_lexHole${k}_$h';
	}

	private static inline function codeAt(text: String, at: Int): Int {
		return text.charCodeAt(at) ?? -1;
	}

	private static inline function tokenReName(t: Int): String {
		return '_tokenRe$t';
	}

	// -------- public entries --------

	private static function scanField(specs: Array<LexRegionSpec>): Field {
		final origins: String = [ for (spec in specs) spec.origin ].join(', ');
		final body: Expr = macro return anyparse.query.LexicalRegions.assemble((onRegion, onHole) ->
			$i{CODE_FN}(source, 0, 0, onRegion, onHole)
		);
		return {
			name: 'scan',
			doc: ' Every OUTERMOST non-code region of `source` - comment, string literal, regex literal - as\n'
				+ ' `[from, to)` byte offsets in source order; an interpolating literal carries its code holes, and\n'
				+ ' each hole the regions written inside it.\n\n Generated from the declarations of: $origins.',
			access: [APublic, AStatic],
			kind: FFun({
				args: [{ name: SOURCE_ARG, type: macro : String }],
				ret: TPath({ pack: [], name: 'Array', params: [TPType(regionCT())] }),
				expr: body
			}),
			pos: Context.currentPos()
		};
	}

	private static function scanCommentsField(): Field {
		final body: Expr = macro anyparse.query.LexicalRegions.eachComment(scan(src), onComment);
		return {
			name: 'scanComments',
			doc: ' Every comment of `src` as a `[start, end)` span, in source order, with the grammar\'s\n'
				+ ' literals skipped so an opener inside one never counts - the `CommentScan` the writer\'s\n comment-loss guard is '
				+ 'handed.\n\n A comment written inside an interpolation hole is reported flat, where `scan` nests it under the hole of '
				+ 'its\n literal; a hole the walk abandoned reports none, so every comment comes once, by its own byte range.',
			access: [APublic, AStatic],
			kind: FFun({
				args: [
					{ name: 'src', type: macro : String },
					{ name: 'onComment', type: TFunction([macro : Int, macro : Int], macro : Void) }
				],
				ret: macro : Void,
				expr: body
			}),
			pos: Context.currentPos()
		};
	}

	// -------- the walks --------

	private static function codeField(specs: Array<LexRegionSpec>): Field {
		final body: Expr = macro {
			final n: Int = source.length;
			var i: Int = from;
			while (i < n) {
				final c: Int = StringTools.fastCodeAt(source, i);
				$b{armExprs(specs)};
				i++;
			}
		};
		return walkField(
			CODE_FN, ' Walk the CODE of `source` from `from`, reporting every region it opens at `depth`.', body, macro : Void
		);
	}

	private static function regionField(specs: Array<LexRegionSpec>, k: Int): Field {
		final spec: LexRegionSpec = specs[k];
		final openLen: Int = spec.open.length;
		final body: Expr = spec.lineTerminated
			? macro {
				final n: Int = source.length;
				var i: Int = from + $v{openLen};
				while (i < n && StringTools.fastCodeAt(source, i) != $v{NEWLINE}) i++;
				return i;
			}
			: delimitedBody(spec, k);
		return walkField(
			regionFn(k), ' The end offset of the ${spec.kind} that `${spec.origin}` declares, opened at `from`.', body, macro : Int
		);
	}

	private static function delimitedBody(spec: LexRegionSpec, k: Int): Expr {
		final openLen: Int = spec.open.length;
		// One FLAT statement list spliced once: a `$b{}` of its own would be a new scope, and
		// the `limit` a nested one declares is then invisible to the loop that reads it.
		final stmts: Array<Expr> = [(macro final n: Int = source.length)];
		if (spec.sameLine) {
			stmts.push(macro final nl: Int = source.indexOf('\n', from + $v{openLen}));
			stmts.push(macro final limit: Int = nl < 0 ? n : nl);
		} else {
			stmts.push(macro final limit: Int = n);
		}
		final steps: Array<Expr> = [];
		if (spec.escape >= 0) steps.push(macro if (c == $v{spec.escape}) {
			i += 2;
			continue;
		});
		for (h in 0...spec.body.length) steps.push(atomExpr(spec.body[h], k, h));
		final closeTest: Expr = literalTest(spec.close);
		final flagStep: Array<Expr> = spec.flagLow < 0 ? [] : [
			macro while (i < limit
				&& StringTools.fastCodeAt(source, i) >= $v{spec.flagLow}
				&& StringTools.fastCodeAt(source, i) <= $v{spec.flagHigh}) i++
		];
		steps.push(macro if ($closeTest) {
			i += $v{spec.close.length};
			$b{flagStep};
			return i;
		});
		final unterminated: Expr = spec.sameLine ? macro -1 : macro n;
		stmts.push(macro var i: Int = from + $v{openLen});
		stmts.push(macro while (i < limit) {
			final c: Int = StringTools.fastCodeAt(source, i);
			$b{steps};
			i++;
		});
		stmts.push(macro return $unterminated);
		return macro $b{stmts};
	}

	private static function holeField(
		specs: Array<LexRegionSpec>, k: Int, h: Int, close: String, nestOpen: String, nestClose: String
	): Field {
		final closeTest: Expr = literalTest(close);
		final body: Expr = macro {
			final n: Int = source.length;
			var i: Int = from;
			var nest: Int = 0;
			while (i < n) {
				final c: Int = StringTools.fastCodeAt(source, i);
				$b{armExprs(specs)};
				if (nest == 0 && $closeTest) return i + $v{close.length};
				if (c == $v{codeAt(nestOpen, 0)}) {
					nest++;
					i++;
					continue;
				}
				if (c == $v{codeAt(nestClose, 0)}) {
					if (nest > 0) nest--;
					i++;
					continue;
				}
				i++;
			}
			return -1;
		};
		return walkField(
			holeFn(k, h), ' The offset just past the `$close` that balances the code hole opened at `from`, or -1 when it is unterminated.',
			body, macro : Int
		);
	}

	private static function walkField(name: String, doc: String, body: Expr, ret: ComplexType): Field {
		return {
			name: name,
			doc: doc,
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{ name: SOURCE_ARG, type: macro : String },
					{ name: 'from', type: macro : Int },
					{ name: 'depth', type: macro : Int },
					{ name: 'emit', type: TFunction([macro : Int, macro : Int, kindCT(), macro : Int], macro : Void) },
					{ name: 'hole', type: TFunction([macro : Int, macro : Int, macro : Int], macro : Void) }
				],
				ret: ret,
				expr: body
			}),
			pos: Context.currentPos()
		};
	}

	// -------- arms and atoms --------

	/** One arm per declared region: match its opener, walk it, report it, resume past it. */
	private static function armExprs(specs: Array<LexRegionSpec>): Array<Expr> {
		return [ for (k in 0...specs.length) {
			final test: Expr = literalTest(specs[k].open);
			final call: Expr = macro $i{regionFn(k)}(source, i, depth, emit, hole);
			final kind: Expr = kindValue(specs[k].kind);
			macro if ($test) {
				final end: Int = $call;
				if (end >= 0) {
					emit(i, end, $kind, depth);
					i = end;
					continue;
				}
				emit(i, -1, $kind, depth);
			};
		} ];
	}

	private static function atomExpr(atom: LexBodyAtom, k: Int, h: Int): Expr {
		return switch atom {
			case Skip(text):
				final test: Expr = literalTest(text);
				macro if ($test) {
					i += $v{text.length};
					continue;
				};
			case Hole(open, _, _, _):
				final test: Expr = literalTest(open);
				final call: Expr = macro $i{holeFn(k, h)}(source, i + $v{open.length}, depth + 1, emit, hole);
				macro if ($test) {
					final end: Int = $call;
					if (end >= 0) {
						hole(i, end, depth + 1);
						i = end;
						continue;
					}
					hole(i, -1, depth + 1);
					i++;
					continue;
				};
		}
	}

	/**
	 * `text` matched at `i`, reading the first character from the `c` the caller already
	 * holds and every later one with a bounds guard.
	 */
	private static function literalTest(text: String): Expr {
		var test: Expr = macro c == $v{codeAt(text, 0)};
		for (k in 1...text.length) {
			final code: Int = codeAt(text, k);
			test = macro $test && i + $v{k} < n && StringTools.fastCodeAt(source, i + $v{k}) == $v{code};
		}
		return test;
	}

	private static function regionCT(): ComplexType {
		return TPath({
			pack: ['anyparse', 'query'],
			name: 'LexicalRegions',
			sub: 'LexRegion',
			params: []
		});
	}

	private static function kindCT(): ComplexType {
		return TPath({
			pack: ['anyparse', 'query'],
			name: 'LexicalRegions',
			sub: 'LexRegionKind',
			params: []
		});
	}

	private static function kindValue(name: String): Expr {
		return { expr: EField(macro $p{['anyparse', 'query', 'LexicalRegions', 'LexRegionKind']}, name), pos: Context.currentPos() };
	}

	/**
	 * The `directives` entry: every occurrence of a declared directive keyword, in source order. It knows the keyword
	 * vocabulary and the token boundary — a keyword continued by an identifier character is a longer word — and nothing
	 * about comments or literals: which occurrence is CODE is the caller's mask, because one consumer deliberately
	 * reads them unmasked (`CondRegionScan`).
	 */
	private static function directivesField(directives: LexDirectiveSpec): Field {
		final keywords: Array<String> = [];
		if (directives.open != null) keywords.push(directives.open);
		for (keyword in directives.branches) if (!keywords.contains(keyword)) keywords.push(keyword);
		if (directives.close != null && !keywords.contains(directives.close)) keywords.push(directives.close);
		// Longest first, so a keyword another one prefixes is tried after it.
		keywords.sort((a: String, b: String) -> b.length - a.length);
		final arms: Array<Expr> = [];
		for (keyword in keywords) {
			final test: Expr = literalTest(keyword);
			final len: Int = keyword.length;
			arms.push(macro if (
				$test && (i + $v{len} >= n || !anyparse.util.Strings.isIdentChar(StringTools.fastCodeAt(source, i + $v{len})))
			) {
				out.push({ from: i, keyword: $v{keyword} });
				i += $v{len};
				continue;
			});
		}
		final body: Expr = macro {
			final out: Array<anyparse.query.LexicalRegions.LexDirective> = [];
			final n: Int = source.length;
			var i: Int = 0;
			while (i < n) {
				final c: Int = StringTools.fastCodeAt(source, i);
				$b{arms};
				i++;
			}
			return out;
		};
		return {
			name: 'directives',
			doc: ' Every occurrence of a conditional-compilation directive keyword in `source`, in source order - one followed\n'
				+ ' by an identifier character is a longer word. Comments and literals are NOT masked: that is the caller\'s mask.',
			access: [APublic, AStatic],
			kind: FFun({
				args: [{ name: SOURCE_ARG, type: macro : String }],
				ret: macro : Array<anyparse.query.LexicalRegions.LexDirective>,
				expr: body
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * The declared directive keywords, published as `directiveOpen` / `directiveBranches` / `directiveClose` so a
	 * plugin reads its directive roles from the same declaration the walk reports.
	 */
	private static function keywordFields(directives: LexDirectiveSpec): Array<Field> {
		final stringCT: ComplexType = macro : Null<String>;
		return [
			constField('directiveOpen', stringCT, macro $v{directives.open}),
			constField('directiveBranches', macro : Array<String>, macro $v{directives.branches}),
			constField('directiveClose', stringCT, macro $v{directives.close})
		];
	}

	private static function constField(name: String, type: ComplexType, value: Expr): Field {
		return {
			name: name,
			doc: ' A conditional-compilation directive keyword the grammar declares with `@:condDirectives`.',
			access: [APublic, AStatic, AFinal],
			kind: FVar(type, value),
			pos: Context.currentPos()
		};
	}

	/**
	 * The public `tokens` entry: maximal munch over the declared literal texts and `@:token` terminals, with every
	 * declared region read as ONE token by its own walk and the format's whitespace between tokens. A literal wins a
	 * tie with a terminal, because it is tried first and a terminal must be strictly longer to replace it.
	 */
	private static function tokensField(specs: Array<LexRegionSpec>, tokens: LexTokenSpec): Field {
		// One FLAT statement list: a regex local a nested `$b{}` declared would be invisible to the loop.
		final stmts: Array<Expr> = [];
		for (t in 0...tokens.terminals.length) stmts.push({
			expr: EVars([
				{
					name: tokenReName(t),
					type: macro : EReg,
					expr: macro anyparse.runtime.AnchoredRegex.of($v{tokens.terminals[t].pattern}),
					isFinal: true
				}
			]),
			pos: Context.currentPos()
		});
		final kindType: ComplexType = kindCT();
		stmts.push(macro final out: Array<anyparse.query.TokenSpans.TokenSpan> = []);
		stmts.push(macro final n: Int = source.length);
		stmts.push(macro final limit: Int = to < n ? to : n);
		stmts.push(macro final noRegion: (Int, Int, $kindType, Int) -> Void = (_, _, _, _) -> {});
		stmts.push(macro final noHole: (Int, Int, Int) -> Void = (_, _, _) -> {});
		stmts.push(macro var i: Int = from < 0 ? 0 : from);
		final steps: Array<Expr> = [];
		if (tokens.whitespace.length > 0) {
			var ws: Expr = macro c == $v{tokens.whitespace[0]};
			for (k in 1...tokens.whitespace.length) ws = macro $ws || c == $v{tokens.whitespace[k]};
			steps.push(macro if ($ws) {
				i++;
				continue;
			});
		}
		for (arm in tokenRegionArms(specs)) steps.push(arm);
		steps.push(macro var best: Int = i);
		steps.push(macro var kind: anyparse.query.TokenSpans.TokenKind = ${tokenKindValue('Unknown')});
		final literals: Null<Expr> = literalSwitch(tokens.literals);
		if (literals != null) steps.push(literals);
		for (t in 0...tokens.terminals.length) {
			final re: Expr = macro $i{tokenReName(t)};
			final terminalKind: Expr = tokenKindValue(tokens.terminals[t].kind);
			steps.push(macro if (anyparse.runtime.AnchoredRegex.matchIn($re, source, i)) {
				final end: Int = i + $re.matched(0).length;
				if (end > best) {
					best = end;
					kind = $terminalKind;
				}
			});
		}
		steps.push(macro if (best == i) best = i + 1);
		steps.push(macro out.push({ from: i, to: best, kind: kind }));
		steps.push(macro i = best);
		stmts.push(macro while (i < limit) {
			final c: Int = StringTools.fastCodeAt(source, i);
			$b{steps};
		});
		stmts.push(macro return out);
		final origins: String = [ for (terminal in tokens.terminals) terminal.origin ].join(', ');
		return {
			name: 'tokens',
			doc: ' Every token of `source` that starts in `[from, to)`, as `[from, to)` byte offsets in source order, each at its\n'
				+ ' full extent: a declared literal text, a `@:token` terminal, or a whole non-code region; whitespace is no token,\n'
				+ ' and a character nothing declares is one `Unknown` token.\n\n Generated from the token terminals: $origins.',
			access: [APublic, AStatic],
			kind: FFun({
				args: [
					{ name: SOURCE_ARG, type: macro : String },
					{ name: 'from', type: macro : Int },
					{ name: 'to', type: macro : Int }
				],
				ret: macro : Array<anyparse.query.TokenSpans.TokenSpan>,
				expr: macro $b{stmts}
			}),
			pos: Context.currentPos()
		};
	}

	/**
	 * One switch on the first character over `literals`, each case an else-if chain in the given longest-first order,
	 * so the first literal that matches is the longest one; null when the grammar spells none.
	 */
	private static function literalSwitch(literals: Array<String>): Null<Expr> {
		final groups: Array<{ code: Int, texts: Array<String> }> = [];
		for (text in literals) {
			final code: Int = codeAt(text, 0);
			var group: Null<{ code: Int, texts: Array<String> }> = null;
			for (g in groups) if (g.code == code) group = g;
			if (group == null)
				groups.push({ code: code, texts: [text] })
			else
				group.texts.push(text);
		}
		if (groups.length == 0) return null;
		groups.sort((a: { code: Int, texts: Array<String> }, b: { code: Int, texts: Array<String> }) -> a.code - b.code);
		final literal: Expr = tokenKindValue('Literal');
		final cases: Array<Case> = [];
		for (group in groups) {
			var chain: Expr = macro {};
			var k: Int = group.texts.length;
			while (k > 0) {
				k--;
				final text: String = group.texts[k];
				final test: Expr = literalTest(text);
				chain = macro if ($test) {
					best = i + $v{text.length};
					kind = $literal;
				} else $chain;
			}
			cases.push({ values: [macro $v{group.code}], expr: chain });
		}
		return { expr: ESwitch(macro c, cases, macro {}), pos: Context.currentPos() };
	}

	private static function tokenKindValue(name: String): Expr {
		return { expr: EField(macro $p{['anyparse', 'query', 'TokenSpans', 'TokenKind']}, name), pos: Context.currentPos() };
	}

	/**
	 * One arm per declared region for the token reader: the region's own walk finds its end and the whole region is
	 * one token; an opener that opens nothing falls through to the literals and terminals.
	 */
	private static function tokenRegionArms(specs: Array<LexRegionSpec>): Array<Expr> {
		final region: Expr = tokenKindValue('Region');
		return [ for (k in 0...specs.length) {
			final test: Expr = literalTest(specs[k].open);
			final call: Expr = macro $i{regionFn(k)}(source, i, 0, noRegion, noHole);
			macro if ($test) {
				final end: Int = $call;
				if (end >= 0) {
					out.push({ from: i, to: end, kind: $region });
					i = end;
					continue;
				}
			};
		} ];
	}

}
#end
