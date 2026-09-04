package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;

using StringTools;

/**
 * Pass 3 — the binary-format field decode emit.
 *
 * The `@:binary` grammar family (the `ar` archive is the shipped case)
 * reads fixed-width integers and strings, length prefixes and raw data
 * runs out of a byte slice rather than matching literals. These are the
 * emitters for those field kinds, plus the integer decode
 * (`makeIntDecodeExpr`) and the slice local they share.
 *
 * Split out of `Lowering` on that responsibility: a text grammar never
 * reaches any of them, and they reach nothing else in the pass. The
 * writer half already had its own module (`BinaryWriterLowering`); this
 * is its parse-side twin.
 */
final class BinaryParseLowering {

	/**
	 * Emit parse steps for a `@:bin(N, Dec|Oct)` Int field — read N bytes
	 * as an ASCII slice, strip trailing spaces, and decode as an integer
	 * in the given base.
	 */
	private static inline function emitBinFixedIntField(
		localName: String, len: Int, encoding: String, fieldName: String, parseSteps: Array<Expr>
	): Void {
		emitIntSliceLocal(localName, len, encoding, 'field "$fieldName"', parseSteps);
	}

	/**
	 * Emit parse steps for a `@:length(N, Dec|Oct)` length prefix. Reads
	 * N bytes, right-trims, decodes as an integer in the given base, and
	 * stores the result in `_lenPrefix_<field>:Int`.
	 */
	private static inline function emitBinLengthPrefix(fieldName: String, width: Int, encoding: String, parseSteps: Array<Expr>): Void {
		emitIntSliceLocal('_lenPrefix_$fieldName', width, encoding, 'length prefix for "$fieldName"', parseSteps);
	}

	/**
	 * Unwrap `Array<T>` (or `Null<Array<T>>`) and return the element
	 * `ComplexType`. Used by `byNameStarParseExpr` to type the
	 * accumulator local against the schema-declared element type
	 * instead of the parse-fn return type, so primitive-rewrite paths
	 * (`Array<Int>` field whose Ref child resolves to `JIntLit`) keep
	 * `Array<Int>` shape and rely on the abstract's `from`/`to`
	 * conversion at each `push`. Returns `null` on any other shape;
	 * caller falls back to `ruleReturnCT(refName)`.
	 */
	private static function extractArrayElementCT(ct: Null<ComplexType>): Null<ComplexType> {
		return ct == null
			? null
			: switch ct {
				case TPath({ pack: [], name: 'Array', params: [TPType(inner)] }): inner;
				case TPath({ pack: [], name: 'Null', params: [TPType(inner)] }): extractArrayElementCT(inner);
				case _: null;
			};
	}

	/**
	 * The schema-declared VALUE type of a `Map<String, V>` field's
	 * ComplexType — the map twin of `extractArrayElementCT`, with the
	 * same purpose: type the accumulator local against the declared type
	 * so a paired (`*T` / `*S`) parse-fn return type cannot diverge from
	 * the field. Only the direct `Map<K, V>` spelling is recognised
	 * (mirroring `ShapeBuilder.mapTypeParams`); `null` falls back to
	 * `ruleReturnCT(refName)` at the caller.
	 */
	private static function extractMapValueCT(ct: Null<ComplexType>): Null<ComplexType> {
		return ct == null
			? null
			: switch ct {
				case TPath({ name: 'Map', params: [TPType(_), TPType(value)] }): value;
				case TPath({ pack: [], name: 'Null', params: [TPType(inner)] }): extractMapValueCT(inner);
				case _: null;
			};
	}

	// -------- binary field helpers --------

	/**
	 * Emit parse steps for a `@:bin(N)` String field — read N bytes as
	 * an ASCII string and strip trailing spaces. The right-padding is a
	 * format convention (e.g. ar), never a meaningful part of the value.
	 */
	private static function emitBinFixedStringField(localName: String, len: Int, parseSteps: Array<Expr>): Void {
		parseSteps.push({
			expr: EVars([
				{
					name: localName,
					type: macro :String,
					expr: macro {
						final _s: String = StringTools.rtrim(ctx.input.substring(ctx.pos, ctx.pos + $v{len}));
						ctx.pos += $v{len};
						_s;
					},
					isFinal: true
				}
			]),
			pos: Context.currentPos()
		});
	}

	/**
	 * Emit parse steps for a `@:bin("fieldName")` Bytes field — read a
	 * variable number of bytes determined by `parseInt(trim(fieldRef))`.
	 */
	private static function emitBinDataField(localName: String, refField: String, parseSteps: Array<Expr>): Void {
		final localRef: Expr = { expr: EConst(CIdent('_f_$refField')), pos: Context.currentPos() };
		final errMsg: String = 'invalid size in field "$refField"';
		parseSteps.push({
			expr: EVars([
				{
					name: localName,
					type: macro :haxe.io.Bytes,
					expr: macro {
						final _len: Int = {
							final _s: String = StringTools.rtrim($localRef);
							final _v: Null<Int> = Std.parseInt(_s);
							if (_v == null) throw new anyparse.runtime.ParseError(new anyparse.runtime.Span(ctx.pos, ctx.pos), $v{errMsg});
							(_v: Int);
						};
						final _b: haxe.io.Bytes = ctx.input.bytes(ctx.pos, ctx.pos + _len);
						ctx.pos += _len;
						_b;
					},
					isFinal: true
				}
			]),
			pos: Context.currentPos()
		});
	}

	/**
	 * Emit `final <localName>:Int = decode(rtrim(slice of <width> bytes))`.
	 * Shared by fixed-width Int fields and length prefixes — they differ
	 * only in the local name they bind to and the error context string.
	 */
	private static function emitIntSliceLocal(
		localName: String, width: Int, encoding: String, errContext: String, parseSteps: Array<Expr>
	): Void {
		final decodeExpr: Expr = makeIntDecodeExpr(encoding, errContext);
		parseSteps.push({
			expr: EVars([
				{
					name: localName,
					type: macro :Int,
					expr: macro {
						final _s: String = StringTools.rtrim(ctx.input.substring(ctx.pos, ctx.pos + $v{width}));
						ctx.pos += $v{width};
						$decodeExpr;
					},
					isFinal: true
				}
			]),
			pos: Context.currentPos()
		});
	}

	/**
	 * Emit parse steps for a `@:length`-paired Bytes field — read the
	 * count stored in `_lenPrefix_<field>` bytes into the AST value.
	 */
	private static function emitBinLengthBytesField(localName: String, fieldName: String, parseSteps: Array<Expr>): Void {
		final lenRef: Expr = { expr: EConst(CIdent('_lenPrefix_$fieldName')), pos: Context.currentPos() };
		parseSteps.push({
			expr: EVars([
				{
					name: localName,
					type: macro :haxe.io.Bytes,
					expr: macro {
						final _b: haxe.io.Bytes = ctx.input.bytes(ctx.pos, ctx.pos + $lenRef);
						ctx.pos += $lenRef;
						_b;
					},
					isFinal: true
				}
			]),
			pos: Context.currentPos()
		});
	}

	/**
	 * Build the Int-decode expression for a right-trimmed `_s:String`
	 * local. `Dec` uses `Std.parseInt`; `Oct` runs an inline digit loop
	 * (Haxe's `Std.parseInt` interprets unprefixed ASCII as decimal, not
	 * octal, so the octal path cannot delegate to it).
	 */
	private static function makeIntDecodeExpr(encoding: String, errContext: String): Expr {
		return switch encoding {
			case 'Dec':
				final errMsg: String = 'invalid decimal in $errContext';
				macro {
					final _v: Null<Int> = Std.parseInt(_s);
					if (_v == null) throw new anyparse.runtime.ParseError(new anyparse.runtime.Span(ctx.pos, ctx.pos), $v{errMsg});
					(_v: Int);
				};
			case 'Oct':
				final emptyMsg: String = 'empty octal in $errContext';
				final digitMsg: String = 'invalid octal digit in $errContext';
				macro {
					if (_s.length == 0) throw new anyparse.runtime.ParseError(new anyparse.runtime.Span(ctx.pos, ctx.pos), $v{emptyMsg});
					var _acc: Int = 0;
					var _oi: Int = 0;
					while (_oi < _s.length) {
						final _oc: Int = StringTools.fastCodeAt(_s, _oi); // noqa: magic-number
						if (_oc < '0'.code || _oc > '7'.code)
							throw new anyparse.runtime.ParseError(new anyparse.runtime.Span(ctx.pos, ctx.pos), $v{digitMsg});
						_acc = (_acc << 3) | (_oc - '0'.code); // noqa: magic-number
						_oi++;
					}
					_acc;
				};
			case _:
				Context.fatalError('Lowering: unsupported bin encoding "$encoding"', Context.currentPos());
				throw 'unreachable';
		};
	}

	// -------- @:raw post-processing --------
}
#end
