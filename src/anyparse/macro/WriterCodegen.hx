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
 *  - Writing the `write(value, indent, lineWidth)` public entry point
 *    that calls the root write function and hands the Doc to Renderer.
 *  - Emitting the per-rule `writeXxx(value, indent)` functions.
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
		formatInfo:FormatReader.FormatInfo
	):Array<Field> {
		final fields:Array<Field> = [];
		if (formatInfo.isBinary) {
			fields.push(binaryEntry(rootTypePath, rootReturnCT));
			for (rule in rules) fields.push(binaryRuleField(rule));
		} else {
			fields.push(publicEntry(rootTypePath, rootReturnCT));
			for (rule in rules) fields.push(ruleField(rule));
			// Doc wrapper helpers
			for (f in docHelperFields()) fields.push(f);
			// Layout helpers
			fields.push(blockBodyField());
			fields.push(sepListField());
			// Encoding helpers
			fields.push(formatFloatField());
			fields.push(escapeStringField(formatInfo));
		}
		return fields;
	}

	// -------- public entry point --------

	private static function publicEntry(rootTypePath:String, rootReturnCT:ComplexType):Field {
		final rootFn:String = 'write${simpleName(rootTypePath)}';
		final writeCall:Expr = {
			expr: ECall(macro $i{rootFn}, [macro value, macro indent]),
			pos: Context.currentPos(),
		};
		final body:Expr = macro {
			return anyparse.core.Renderer.render($writeCall, lineWidth);
		};
		return {
			name: 'write',
			access: [APublic, AStatic],
			kind: FFun({
				args: [
					{name: 'value', type: rootReturnCT},
					{name: 'indent', type: macro : Int, value: macro 4},
					{name: 'lineWidth', type: macro : Int, value: macro 120},
				],
				ret: macro : String,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
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

	private static function ruleField(rule:WriterLowering.WriterRule):Field {
		final args:Array<FunctionArg> = [
			{name: 'value', type: rule.valueCT},
			{name: 'indent', type: macro : Int},
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
			return _dc([_dt(open), _dn(indent, _dc(_items)), _dhl(), _dt(close)]);
		};
		return {
			name: 'blockBody',
			access: [APrivate, AStatic],
			kind: FFun({
				args: [
					{name: 'open', type: macro : String},
					{name: 'close', type: macro : String},
					{name: 'docs', type: macro : Array<anyparse.core.Doc>},
					{name: 'indent', type: macro : Int},
				],
				ret: macro : anyparse.core.Doc,
				expr: body,
			}),
			pos: Context.currentPos(),
		};
	}

	/** Separated list in delimiters with fit-or-break layout. */
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
			return _dg(_dc([_dt(open), _dn(indent, _dc([_dsl(), _dc(_inner)])), _dsl(), _dt(close)]));
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
					{name: 'indent', type: macro : Int},
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
