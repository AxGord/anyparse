package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;

/**
 * Pass 4W of the macro pipeline — writer codegen.
 *
 * Takes the list of `WriterRule`s produced by `WriterLowering`, the root
 * rule name and format info, and returns a full `Array<Field>` ready to
 * be plugged into a marker class via `@:build`.
 *
 * What WriterCodegen owns:
 *  - Writing the `write(value, ?options)` public entry point that
 *    resolves options against the format's defaults, calls the root
 *    write function, and hands the Doc to Renderer.
 *  - Emitting the per-rule `writeXxx(value, opt)` functions. Internal
 *    helpers operate on a fully resolved `WriteOptions` struct — no
 *    nullable fields, no per-call defaulting.
 *  - Emitting Doc wrapper helpers (`_dt`, `_dc`, etc.) that avoid
 *    direct enum constructor calls in macro expressions.
 *  - Emitting layout helpers (`blockBody`, `sepList`) and encoding
 *    helpers (`formatFloat`, `escapeString`).
 */
class WriterCodegen {

	public static function emit(
		rules:Array<WriterLowering.WriterRule>,
		rootTypePath:String,
		rootReturnCT:ComplexType,
		formatInfo:FormatReader.FormatInfo,
		optionsTypePath:Null<String>,
		?rootFnName:Null<String>
	):Array<Field> {
		final fields:Array<Field> = [];
		if (formatInfo.isBinary) {
			fields.push(binaryEntry(rootTypePath, rootReturnCT));
			for (rule in rules) fields.push(binaryRuleField(rule));
		} else {
			if (optionsTypePath == null)
				Context.fatalError('WriterCodegen.emit: text writer requires optionsTypePath', Context.currentPos());
			final optionsCT:ComplexType = optionsComplexType(optionsTypePath);
			final resolvedRootFn:String = rootFnName ?? ('write' + simpleName(rootTypePath));
			fields.push(publicEntry(resolvedRootFn, rootReturnCT, formatInfo, optionsCT));
			for (rule in rules) fields.push(ruleField(rule, optionsCT));
			// Doc wrapper helpers
			for (f in docHelperFields()) fields.push(f);
			// Layout helpers
			fields.push(blockBodyField());
			fields.push(sepListField());
			// Encoding helpers
			fields.push(formatFloatField());
			fields.push(escapeStringField(formatInfo));
			// Trivia helpers (ω₅). Always emitted — unused when
			// the marker class doesn't opt into `{trivia: true}`,
			// but cost is small private-static methods.
			fields.push(leadingCommentDocField());
			fields.push(trailingCommentDocField());
			fields.push(trailingCommentDocVerbatimField());
			// ω₆c: BodyGroup trailing-comment folder. Used by
			// `triviaBlockStarExpr` / `triviaEofStarExpr` to splice
			// a trailing comment into the body's FitLine measure.
			fields.push(foldTrailingIntoBodyGroupField());
			fields.push(foldTrailingRecursiveField());
			fields.push(appendInsideBodyGroupField());
			// ω-issue-316: renders the gap between a just-emitted `@:optional
			// @:kw` and its body (Same-policy / block-ctor path). Picks
			// `Text(' ')` when no trivia present — byte-identical to the
			// pre-slice separator; otherwise inlines a same-line trailing
			// and/or indents own-line leading comments at body interior
			// indent, closing with a hardline so the body's outer brace
			// lands at the parent's indent level.
			fields.push(kwGapDocField());
		}
		return fields;
	}

	// -------- public entry point --------

	private static function publicEntry(
		rootFn:String, rootReturnCT:ComplexType,
		formatInfo:FormatReader.FormatInfo,
		optionsCT:ComplexType
	):Field {
		final fmtParts:Array<String> = formatInfo.schemaTypePath.split('.');
		final defaultOptsExpr:Expr = {
			expr: EField(macro $p{fmtParts}.instance, 'defaultWriteOptions'),
			pos: Context.currentPos(),
		};
		final writeCall:Expr = {
			expr: ECall(macro $i{rootFn}, [macro value, macro _opt]),
			pos: Context.currentPos(),
		};
		final body:Expr = macro {
			final _opt:$optionsCT = options ?? $defaultOptsExpr;
			return anyparse.core.Renderer.render(
				$writeCall,
				_opt.lineWidth,
				_opt.indentChar,
				_opt.tabWidth,
				_opt.lineEnd,
				_opt.finalNewline
			);
		};
		return {
			name: 'write',
			access: [APublic, AStatic],
			kind: FFun({
				args: [
					{name: 'value', type: rootReturnCT},
					{name: 'options', type: macro : Null<$optionsCT>, value: macro null},
				],
				ret: macro : String,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	private static function optionsComplexType(optionsTypePath:String):ComplexType {
		final simple:String = simpleName(optionsTypePath);
		final pack:Array<String> = packOf(optionsTypePath);
		return TPath({pack: pack, name: simple, params: []});
	}

	private static function packOf(typePath:String):Array<String> {
		final idx:Int = typePath.lastIndexOf('.');
		return idx == -1 ? [] : typePath.substring(0, idx).split('.');
	}

	private static function binaryEntry(rootTypePath:String, rootReturnCT:ComplexType):Field {
		final rootFn:String = 'write${simpleName(rootTypePath)}';
		final writeCall:Expr = {
			expr: ECall(macro $i{rootFn}, [macro value, macro output]),
			pos: Context.currentPos(),
		};
		final body:Expr = macro {
			final output:haxe.io.BytesOutput = new haxe.io.BytesOutput();
			$writeCall;
			return output.getBytes();
		};
		return {
			name: 'write',
			access: [APublic, AStatic],
			kind: FFun({
				args: [{name: 'value', type: rootReturnCT}],
				ret: macro : haxe.io.Bytes,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	private static function binaryRuleField(rule:WriterLowering.WriterRule):Field {
		return {
			name: rule.fnName,
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{name: 'value', type: rule.valueCT},
					{name: 'output', type: macro : haxe.io.BytesOutput},
				],
				ret: macro : Void,
				expr: rule.body,
			}),
			pos: Context.currentPos(),
		};
	}

	// -------- per-rule fields --------

	private static function ruleField(rule:WriterLowering.WriterRule, optionsCT:ComplexType):Field {
		final args:Array<FunctionArg> = [
			{name: 'value', type: rule.valueCT},
			{name: 'opt', type: optionsCT},
		];
		if (rule.hasCtxPrec)
			args.push({name: 'ctxPrec', type: macro : Int, value: macro -1});
		return {
			name: rule.fnName,
			access: [APrivate, AStatic],
			kind: FFun({
				args: args,
				ret: macro : anyparse.core.Doc,
				expr: rule.body,
			}),
			pos: Context.currentPos(),
		};
	}

	// -------- Doc wrapper helpers --------
	// Avoids direct enum constructor calls (`anyparse.core.Doc.Text(...)`)
	// in macro expressions, which trigger macro-time type checking.
	// Generated code calls `_dt(s)` instead — resolved at compile time
	// of the generated class, not at macro expansion time.

	private static function docHelperFields():Array<Field> {
		return [
			docHelper('_dt', [{name: 's', type: macro : String}], macro anyparse.core.Doc.Text(s)),
			docHelper('_dc', [{name: 'items', type: macro : Array<anyparse.core.Doc>}], macro anyparse.core.Doc.Concat(items)),
			docHelper('_dn', [{name: 'n', type: macro : Int}, {name: 'inner', type: macro : anyparse.core.Doc}], macro anyparse.core.Doc.Nest(n, inner)),
			docHelper('_dg', [{name: 'inner', type: macro : anyparse.core.Doc}], macro anyparse.core.Doc.Group(inner)),
			docHelper('_dbg', [{name: 'inner', type: macro : anyparse.core.Doc}], macro anyparse.core.Doc.BodyGroup(inner)),
			docHelper('_dhl', [], macro anyparse.core.Doc.Line('\n')),
			docHelper('_dsl', [], macro anyparse.core.Doc.Line('')),
			docHelper('_dl', [], macro anyparse.core.Doc.Line(' ')),
			docHelper('_de', [], macro anyparse.core.Doc.Empty),
			docHelper(
				'_dib',
				[{name: 'br', type: macro : anyparse.core.Doc}, {name: 'fl', type: macro : anyparse.core.Doc}],
				macro anyparse.core.Doc.IfBreak(br, fl)
			),
		];
	}

	private static function docHelper(name:String, args:Array<FunctionArg>, body:Expr):Field {
		return {
			name: name,
			access: [APrivate, AStatic, AInline],
			kind: FFun({args: args, ret: macro : anyparse.core.Doc, expr: macro return $body}),
			pos: Context.currentPos(),
		};
	}

	// -------- layout helpers --------

	/** Block layout: `open + nest(indent, [hardline+item]*) + hardline + close`. */
	private static function blockBodyField():Field {
		final body:Expr = macro {
			if (docs.length == 0) return _dt(open + close);
			final _items:Array<anyparse.core.Doc> = [];
			var _i:Int = 0;
			while (_i < docs.length) {
				_items.push(_dhl());
				_items.push(docs[_i]);
				_i++;
			}
			final _cols:Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			return _dc([_dt(open), _dn(_cols, _dc(_items)), _dhl(), _dt(close)]);
		};
		return {
			name: 'blockBody',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{name: 'open', type: macro : String},
					{name: 'close', type: macro : String},
					{name: 'docs', type: macro : Array<anyparse.core.Doc>},
					{name: 'opt', type: macro : anyparse.format.WriteOptions},
				],
				ret: macro : anyparse.core.Doc,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * Separated list in delimiters with fit-or-break layout.
	 *
	 * When `trailingComma` is `true`, a trailing `sep` is emitted after
	 * the last item only when the enclosing Group lays out in break
	 * mode — an `IfBreak` node carries the conditional. In flat mode
	 * the trailing position is `Empty`, so short lists render unchanged.
	 */
	private static function sepListField():Field {
		final body:Expr = macro {
			if (items.length == 0) return _dt(open + close);
			final _inner:Array<anyparse.core.Doc> = [];
			var _i:Int = 0;
			while (_i < items.length) {
				if (_i > 0) {
					_inner.push(_dt(sep));
					_inner.push(_dl());
				}
				_inner.push(items[_i]);
				_i++;
			}
			if (trailingComma) _inner.push(_dib(_dt(sep), _de()));
			final _cols:Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			return _dg(_dc([_dt(open), _dn(_cols, _dc([_dsl(), _dc(_inner)])), _dsl(), _dt(close)]));
		};
		return {
			name: 'sepList',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{name: 'open', type: macro : String},
					{name: 'close', type: macro : String},
					{name: 'sep', type: macro : String},
					{name: 'items', type: macro : Array<anyparse.core.Doc>},
					{name: 'opt', type: macro : anyparse.format.WriteOptions},
					{name: 'trailingComma', type: macro : Bool},
				],
				ret: macro : anyparse.core.Doc,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	// -------- encoding helpers --------

	/** Format a float ensuring a decimal point is always present. */
	private static function formatFloatField():Field {
		final body:Expr = macro {
			final _s:String = Std.string(value);
			if (_s.indexOf('.') >= 0) return _s;
			return _s + '.0';
		};
		return {
			name: 'formatFloat',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [{name: 'value', type: macro : Float}],
				ret: macro : String,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * Render a captured leading-comment atom as a Doc text atom.
	 * `content` is VERBATIM per `ω-leading-block-style` — it already
	 * carries its open/close delimiters (`//…` or `/*…*\/`), so line-
	 * vs-block choice survives round-trip without style guessing.
	 *
	 * One runtime post-process remains: multi-line block comments
	 * whose closing line is whitespace-only (source tail between the
	 * last `\n` and the closing `*\/` contains only spaces / tabs and
	 * does not already end with a space) get a space inserted before
	 * the closing `*\/` to match haxe-formatter's javadoc-style close
	 * normalization. Line-style comments and single-line block
	 * comments emit byte-identical to the captured source.
	 */
	private static function leadingCommentDocField():Field {
		final body:Expr = macro {
			if (!StringTools.startsWith(content, '/*')) return _dt(content);
			final _lastNl:Int = content.lastIndexOf('\n');
			if (_lastNl < 0) return _dt(content);
			final _closeStart:Int = content.length - 2;
			var _tailBlank:Bool = true;
			for (_i in (_lastNl + 1)..._closeStart) {
				final _c:Int = StringTools.fastCodeAt(content, _i);
				if (_c != ' '.code && _c != '\t'.code) { _tailBlank = false; break; }
			}
			final _endsWithSpace:Bool = _closeStart > 0
				&& StringTools.fastCodeAt(content, _closeStart - 1) == ' '.code;
			if (_tailBlank && !_endsWithSpace) return _dt(content.substring(0, _closeStart) + ' */');
			return _dt(content);
		};
		return {
			name: 'leadingCommentDoc',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [{name: 'content', type: macro : String}],
				ret: macro : anyparse.core.Doc,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * Render a captured trailing-comment body as a Doc text atom
	 * prefixed with a space separator from the preceding element.
	 * Trailing capture rule guarantees single-line content (block
	 * comments with an internal newline attach as leading-of-next),
	 * so line style is always safe.
	 */
	private static function trailingCommentDocField():Field {
		final body:Expr = macro return _dt(' //' + content);
		return {
			name: 'trailingCommentDoc',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [{name: 'content', type: macro : String}],
				ret: macro : anyparse.core.Doc,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * Render a captured trailing-comment body as a Doc text atom
	 * prefixed with a space separator from the preceding element —
	 * VERBATIM variant that expects `content` to already include its
	 * delimiters (e.g. `// foo` or `/* foo *\/`). Used by close-trailing
	 * slots (ω-close-trailing / ω-close-trailing-alt) where the parser
	 * captures via `collectTrailingFull` so block-vs-line style is
	 * preserved across a round-trip. Per-element + AfterKw slots keep
	 * the stripped-body `trailingCommentDoc` helper above — that path
	 * normalises to line style by construction.
	 */
	private static function trailingCommentDocVerbatimField():Field {
		final body:Expr = macro return _dt(' ' + content);
		return {
			name: 'trailingCommentDocVerbatim',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [{name: 'content', type: macro : String}],
				ret: macro : anyparse.core.Doc,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * Splice a trailing Doc atom inside the outermost `BodyGroup`
	 * reachable by walking the Doc tree from the root. The match is
	 * "outermost" in the sense that once a `BodyGroup` is found, the
	 * folder stops descending — nested `BodyGroup`s inside the matched
	 * one are left alone. Walks `Concat` items right-to-left so the
	 * `BodyGroup` emitted by `bodyPolicyWrap` at the tail of a bearing
	 * writer's output is found first.
	 *
	 * Purpose: lets the trivia writer's `trailing`-comment attachment
	 * enter the body's fit/break measurement. Without this, the
	 * `BodyGroup` measures only its own inner content and picks `flat`
	 * on bodies that fit without the trailing, producing output that
	 * overflows once the comment is appended outside.
	 *
	 * Fallback: when no `BodyGroup` is found anywhere, returns a plain
	 * `Concat([doc, trailing])` — the trailing comment appends as a
	 * sibling, matching the behaviour writers without a FitLine body
	 * had before this helper was introduced (byte-identical for block
	 * bodies and simple statements like `VarStmt`/`ReturnStmt`).
	 */
	private static function foldTrailingIntoBodyGroupField():Field {
		final body:Expr = macro {
			final _folded:Null<anyparse.core.Doc> = _foldTrailingIntoBodyGroup(doc, trailing);
			return _folded != null ? _folded : _dc([doc, trailing]);
		};
		return {
			name: 'foldTrailingIntoBodyGroup',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{name: 'doc', type: macro : anyparse.core.Doc},
					{name: 'trailing', type: macro : anyparse.core.Doc},
				],
				ret: macro : anyparse.core.Doc,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	private static function foldTrailingRecursiveField():Field {
		final body:Expr = macro {
			switch (doc) {
				case anyparse.core.Doc.BodyGroup(inner):
					return _dbg(_appendInsideBodyGroup(inner, trailing));
				case anyparse.core.Doc.Concat(items):
					var _i:Int = items.length - 1;
					while (_i >= 0) {
						final _folded:Null<anyparse.core.Doc> = _foldTrailingIntoBodyGroup(items[_i], trailing);
						if (_folded != null) {
							final _newItems:Array<anyparse.core.Doc> = items.copy();
							_newItems[_i] = _folded;
							return _dc(_newItems);
						}
						_i--;
					}
					return null;
				case anyparse.core.Doc.Nest(n, inner):
					final _folded:Null<anyparse.core.Doc> = _foldTrailingIntoBodyGroup(inner, trailing);
					return _folded != null ? _dn(n, _folded) : null;
				case _:
					return null;
			}
		};
		return {
			name: '_foldTrailingIntoBodyGroup',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{name: 'doc', type: macro : anyparse.core.Doc},
					{name: 'trailing', type: macro : anyparse.core.Doc},
				],
				ret: macro : Null<anyparse.core.Doc>,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	private static function appendInsideBodyGroupField():Field {
		final body:Expr = macro {
			switch (inner) {
				case anyparse.core.Doc.Nest(n, innerInner):
					return _dn(n, _appendInsideBodyGroup(innerInner, trailing));
				case anyparse.core.Doc.Concat(items):
					return _dc(items.concat([trailing]));
				case _:
					return _dc([inner, trailing]);
			}
		};
		return {
			name: '_appendInsideBodyGroup',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{name: 'inner', type: macro : anyparse.core.Doc},
					{name: 'trailing', type: macro : anyparse.core.Doc},
				],
				ret: macro : anyparse.core.Doc,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	/**
	 * ω-issue-316 — render the kw→body gap for `@:optional @:kw(...)` Ref
	 * fields in Trivia mode. Output shape depends on captured trivia:
	 *  - both slots empty → space when `nextCurly` is `false`, hardline
	 *    when `true` (byte-identical pre-slice when `false`).
	 *  - `afterKw != null` → ` //<body>` trailing after the kw, then
	 *    hardline back to outer indent.
	 *  - `kwLeading` non-empty → each comment on its own line at the
	 *    body's interior indent (`cols` deeper than outer), then hardline
	 *    back to outer indent before the body token.
	 *  - both populated → trailing first (same line as kw), then the
	 *    own-line leading block, then closing hardline.
	 *
	 * `nextCurly` (ω-issue-316-curly-both) only affects the no-trivia
	 * path. When trivia is captured, the function already emits a
	 * trailing hardline — adding another would produce a blank row. The
	 * caller passes `opt.leftCurly == Next` only when the body writeCall
	 * begins with `{` (block ctor); in every other context, pass `false`.
	 *
	 * Caller concatenates the result with the body's writeCall — the
	 * closing hardline hands control to the Renderer at the parent's
	 * indent level so the body's lead brace lands there.
	 */
	private static function kwGapDocField():Field {
		final body:Expr = macro {
			if (afterKw == null && kwLeading.length == 0) return nextCurly ? _dhl() : _dt(' ');
			final _parts:Array<anyparse.core.Doc> = [];
			if (afterKw != null) {
				_parts.push(_dt(' '));
				_parts.push(_dt('//' + afterKw));
			}
			if (kwLeading.length > 0) {
				final _nested:Array<anyparse.core.Doc> = [];
				for (_c in kwLeading) {
					_nested.push(_dhl());
					_nested.push(leadingCommentDoc(_c));
				}
				_parts.push(_dn(cols, _dc(_nested)));
			}
			_parts.push(_dhl());
			return _dc(_parts);
		};
		return {
			name: 'kwGapDoc',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{name: 'afterKw', type: macro : Null<String>},
					{name: 'kwLeading', type: macro : Array<String>},
					{name: 'cols', type: macro : Int},
					{name: 'nextCurly', type: macro : Bool},
				],
				ret: macro : anyparse.core.Doc,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	/** Escape a string for double-quoted output using the format's escapeChar. */
	private static function escapeStringField(formatInfo:FormatReader.FormatInfo):Field {
		final fmtParts:Array<String> = formatInfo.schemaTypePath.split('.');
		final body:Expr = macro {
			final _buf:StringBuf = new StringBuf();
			_buf.add('"');
			var _i:Int = 0;
			while (_i < value.length) {
				final _c:Null<Int> = value.charCodeAt(_i);
				if (_c != null) _buf.add($p{fmtParts}.instance.escapeChar(_c));
				_i++;
			}
			_buf.add('"');
			return _buf.toString();
		};
		return {
			name: 'escapeString',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [{name: 'value', type: macro : String}],
				ret: macro : String,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	private static function simpleName(typePath:String):String {
		final idx:Int = typePath.lastIndexOf('.');
		return idx == -1 ? typePath : typePath.substring(idx + 1);
	}
}
#end
