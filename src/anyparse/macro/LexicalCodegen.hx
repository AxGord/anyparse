package anyparse.macro;

#if macro
import anyparse.macro.LexicalLowering.LexBodyAtom;
import anyparse.macro.LexicalLowering.LexRegionSpec;
import haxe.macro.Context;
import haxe.macro.Expr;

/**
 * The lexical pass's CODEGEN — the fourth of the five passes, run for the
 * `Build.buildLexicalScan` entry point.
 *
 * It turns the `LexRegionSpec` list into a specialised byte walk: one arm per declared
 * region, one walk function per region, one balancing walk per interpolation hole, and the
 * two public entries every consumer already calls. Nothing about the grammar survives as a
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

	/** Name of the generated walk over CODE — the top level, and the inside of every hole. */
	private static final CODE_FN: String = '_lexCode';

	/**
	 * The fields the marker class receives: the two public entries, the code walk, one walk
	 * per declared region and one balancing walk per declared hole.
	 */
	public static function emit(specs: Array<LexRegionSpec>): Array<Field> {
		final fields: Array<Field> = [scanField(specs), scanCommentsField(specs), codeField(specs)];
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

	/** Whether `spec` came from the format's comment delimiters rather than from a literal terminal. */
	private static inline function isCommentSpec(spec: LexRegionSpec): Bool {
		return spec.lineTerminated || (spec.escape < 0 && spec.body.length == 0 && spec.flagLow < 0);
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

	// -------- public entries --------

	private static function scanField(specs: Array<LexRegionSpec>): Field {
		final origins: String = [for (spec in specs) spec.origin].join(', ');
		final body: Expr = macro {
			final out: Array<anyparse.query.LexicalRegions.LexRegion> = [];
			$i{CODE_FN}(source, 0, 0, (from: Int, to: Int, kind: anyparse.query.LexicalRegions.LexRegionKind, depth: Int) -> {
				if (depth == 0) out.push({ from: from, to: to, kind: kind });
			});
			return out;
		};
		return {
			name: 'scan',
			doc: ' Every OUTERMOST non-code region of `source` - comment, string literal, regex literal - as\n'
				+ ' `[from, to)` byte offsets in source order.\n\n Generated from the declarations of: $origins.',
			access: [APublic, AStatic],
			kind: FFun({
				args: [{ name: 'source', type: macro :String }],
				ret: TPath({ pack: [], name: 'Array', params: [TPType(regionCT())] }),
				expr: body
			}),
			pos: Context.currentPos()
		};
	}

	private static function scanCommentsField(specs: Array<LexRegionSpec>): Field {
		final test: Expr = commentKindTest(specs);
		final body: Expr = macro {
			$i{CODE_FN}(src, 0, 0, (from: Int, to: Int, kind: anyparse.query.LexicalRegions.LexRegionKind, depth: Int) -> {
				if ($test) onComment(from, to);
			});
		};
		return {
			name: 'scanComments',
			doc: ' Every comment of `src` as a `[start, end)` span, in source order, with the grammar\'s\n'
				+ ' literals skipped so an opener inside one never counts - the `CommentScan` the writer\'s\n comment-loss guard is '
				+ 'handed.\n\n DELIBERATELY NOT `scan` FILTERED TO ITS COMMENT REGIONS: this reports a comment written\n inside an '
				+ 'interpolation hole, which `scan` cannot, because its flat region model says the\n literal rather than the hole. Both '
				+ 'answers are right for their reader, and here they are\n two filters over ONE generated walk rather than two lexers.',
			access: [APublic, AStatic],
			kind: FFun({
				args: [
					{ name: 'src', type: macro :String },
					{ name: 'onComment', type: TFunction([macro :Int, macro :Int], macro :Void) }
				],
				ret: macro :Void,
				expr: body
			}),
			pos: Context.currentPos()
		};
	}

	/** `kind == LineComment || kind == BlockComment`, from the kinds the format contributed. */
	private static function commentKindTest(specs: Array<LexRegionSpec>): Expr {
		final kinds: Array<String> = [];
		for (spec in specs) if (isCommentSpec(spec) && !kinds.contains(spec.kind)) kinds.push(spec.kind);
		var test: Null<Expr> = null;
		for (name in kinds) {
			final one: Expr = macro kind == ${kindValue(name)};
			test = test == null ? one : macro $test || $one;
		}
		return test ?? macro false;
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
		return walkField(CODE_FN, ' Walk the CODE of `source` from `from`, reporting every region it opens at `depth`.', body, macro :Void);
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
			regionFn(k), ' The end offset of the ${spec.kind} that `${spec.origin}` declares, opened at `from`.', body, macro :Int
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
		} else
			stmts.push(macro final limit: Int = n);
		final steps: Array<Expr> = [];
		if (spec.escape >= 0) steps.push(macro if (c == $v{spec.escape}) {
			i += 2;
			continue;
		});
		for (h in 0...spec.body.length) steps.push(atomExpr(spec.body[h], k, h));
		final closeTest: Expr = literalTest(spec.close);
		final flagStep: Array<Expr> = spec.flagLow < 0 ? [] : [
			macro while (i < limit && StringTools.fastCodeAt(source, i) >= $v{spec.flagLow}
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
			holeFn(k, h),
			' The offset just past the `$close` that balances the code hole opened at `from`, or -1 when it is unterminated.', body,
			macro :Int
		);
	}

	private static function walkField(name: String, doc: String, body: Expr, ret: ComplexType): Field {
		return {
			name: name,
			doc: doc,
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{ name: 'source', type: macro :String },
					{ name: 'from', type: macro :Int },
					{ name: 'depth', type: macro :Int },
					{ name: 'emit', type: TFunction([macro :Int, macro :Int, kindCT(), macro :Int], macro :Void) }
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
		return [
			for (k in 0...specs.length) {
				final test: Expr = literalTest(specs[k].open);
				final call: Expr = macro $i{regionFn(k)}(source, i, depth, emit);
				final kind: Expr = kindValue(specs[k].kind);
				macro if ($test) {
					final end: Int = $call;
					if (end >= 0) {
						emit(i, end, $kind, depth);
						i = end;
						continue;
					}
				};
			}
		];
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
				final call: Expr = macro $i{holeFn(k, h)}(source, i + $v{open.length}, depth + 1, emit);
				macro if ($test) {
					final end: Int = $call;
					if (end >= 0) {
						i = end;
						continue;
					}
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

}
#end
