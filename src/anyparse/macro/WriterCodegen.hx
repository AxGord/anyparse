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
			// but cost is two small private-static methods.
			fields.push(leadingCommentDocField());
			fields.push(trailingCommentDocField());
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
	 * Render a captured leading-comment body as a Doc text atom. Line
	 * style (`//body`) for single-line content, block style (`/*body*\/`)
	 * when the body contains a newline — captured content is verbatim,
	 * so the two styles are picked at runtime to avoid breaking
	 * multi-line block comments into malformed line comments.
	 *
	 * ω₆ will replace this runtime-auto decision with a policy knob
	 * (`commentStyleDecl` / `commentStyleStmt`).
	 */
	private static function leadingCommentDocField():Field {
		final body:Expr = macro {
			return content.indexOf('\n') >= 0
				? _dt('/*' + content + '*/')
				: _dt('//' + content);
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
