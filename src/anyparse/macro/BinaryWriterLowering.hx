package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import anyparse.core.ShapeTree;

/**
 * Pass 3W for binary formats — writer lowering.
 *
 * Walks the shape tree and emits one `WriterRule` per type. Each rule's
 * body writes bytes directly to `output:haxe.io.BytesOutput` — no Doc
 * tree, no Renderer. This is the structural inverse of the binary
 * Terminal/Star handling in `Lowering.lowerStruct`.
 *
 * Separated from `WriterLowering` because text and binary writers have
 * fundamentally different output models (Doc vs BytesOutput) and share
 * zero implementation code.
 */
class BinaryWriterLowering {

	private final shape:ShapeBuilder.ShapeResult;

	public function new(shape:ShapeBuilder.ShapeResult) {
		this.shape = shape;
	}

	public function generate():Array<WriterLowering.WriterRule> {
		return [for (typePath => node in shape.rules) lowerRule(typePath, node)];
	}

	private function lowerRule(typePath:String, node:ShapeNode):WriterLowering.WriterRule {
		final simple:String = simpleName(typePath);
		final fnName:String = 'write$simple';
		final valueCT:ComplexType = TPath({pack: packOf(typePath), name: simple, params: []});

		final body:Expr = switch node.kind {
			case Seq: lowerStruct(node, typePath);
			case _:
				Context.fatalError('BinaryWriterLowering: cannot lower ${node.kind} for $typePath', Context.currentPos());
				throw 'unreachable';
		};
		return {fnName: fnName, valueCT: valueCT, body: body, hasCtxPrec: false, isBinary: true};
	}

	/**
	 * Lower a binary Seq (typedef) into a body that writes bytes to
	 * `output:haxe.io.BytesOutput`. Each field is written sequentially
	 * using `output.writeString` (for fixed ASCII) or `output.write`
	 * (for raw Bytes). Field-level order per iteration is:
	 *
	 *   1. `@:length(N, Dec|Oct)` — compute prefix from the Bytes field's
	 *      length, encode, write N bytes.
	 *   2. `@:lead("...")` — write constant prefix.
	 *   3. Field value (fixed String, fixed Int, Bytes, Star, …).
	 *   4. `@:trail("...")` — write constant suffix.
	 *
	 * Typedef-level: `@:magic` emits a prefix before the loop; `@:align`
	 * emits padding after the loop.
	 */
	private function lowerStruct(node:ShapeNode, typePath:String):Expr {
		final steps:Array<Expr> = [];

		// @:magic prefix
		final magic:Null<String> = node.annotations.get('bin.magic');
		if (magic != null)
			steps.push(macro output.writeString($v{magic}));

		for (child in node.children) {
			final fieldName:Null<String> = child.annotations.get('base.fieldName');
			if (fieldName == null)
				Context.fatalError('BinaryWriterLowering: struct field missing base.fieldName', Context.currentPos());

			final fieldAccess:Expr = {
				expr: EField(macro value, fieldName),
				pos: Context.currentPos(),
			};

			// @:length — write length-prefix bytes before the lead/field.
			final lenPrefix:Null<{width:Int, encoding:String}> = child.annotations.get('bin.lengthPrefix');
			if (lenPrefix != null)
				emitLengthPrefix(lenPrefix.width, lenPrefix.encoding, fieldAccess, steps);

			// @:lead — constant prefix literal.
			final leadText:Null<String> = readMetaString(child, ':lead');
			if (leadText != null)
				steps.push(macro output.writeString($v{leadText}));

			switch child.kind {
				case Terminal:
					emitTerminalField(child, fieldName, fieldAccess, steps);
				case Star:
					emitStarField(child, typePath, fieldAccess, steps);
				case _:
					Context.fatalError(
						'BinaryWriterLowering: struct field kind ${child.kind} not supported',
						Context.currentPos()
					);
			}

			// @:trail — constant suffix literal.
			final trailText:Null<String> = readMetaString(child, ':trail');
			if (trailText != null)
				steps.push(macro output.writeString($v{trailText}));
		}

		// @:align padding
		final align:Null<Int> = node.annotations.get('bin.align');
		if (align != null) {
			steps.push(macro {
				final _rem:Int = output.length % $v{align};
				if (_rem != 0) output.writeByte(0x0A);
			});
		}

		return macro $b{steps};
	}

	private static function emitTerminalField(child:ShapeNode, fieldName:String, fieldAccess:Expr, steps:Array<Expr>):Void {
		final binFixedLen:Null<Int> = child.annotations.get('bin.fixedLen');
		final binEncoding:Null<String> = child.annotations.get('bin.encoding');
		final binDataRef:Null<String> = child.annotations.get('bin.dataRef');
		final lenPrefix:Null<{width:Int, encoding:String}> = child.annotations.get('bin.lengthPrefix');
		if (lenPrefix != null) {
			steps.push(macro output.write($fieldAccess));
		} else if (binFixedLen != null && binEncoding != null) {
			final encodeExpr:Expr = makeIntEncodeExpr(binEncoding);
			final overflowMsg:String = 'int field "$fieldName" exceeds width ${binFixedLen}';
			steps.push(macro {
				final _v:Int = $fieldAccess;
				final _raw:String = $encodeExpr;
				if (_raw.length > $v{binFixedLen})
					throw new haxe.Exception($v{overflowMsg});
				output.writeString(StringTools.rpad(_raw, ' ', $v{binFixedLen}));
			});
		} else if (binFixedLen != null) {
			final overflowMsg:String = 'string field "$fieldName" exceeds width ${binFixedLen}';
			steps.push(macro {
				final _s:String = $fieldAccess;
				if (_s.length > $v{binFixedLen})
					throw new haxe.Exception($v{overflowMsg});
				output.writeString(StringTools.rpad(_s, ' ', $v{binFixedLen}));
			});
		} else if (binDataRef != null) {
			steps.push(macro output.write($fieldAccess));
		} else {
			Context.fatalError(
				'BinaryWriterLowering: Terminal field "$fieldName" requires @:bin or @:length',
				Context.currentPos()
			);
		}
	}

	/**
	 * Emit the write step for a `@:length(N, enc)` prefix: take the
	 * Bytes-field's `length`, encode as ASCII, right-pad with spaces to
	 * N, write.
	 */
	private static function emitLengthPrefix(width:Int, encoding:String, fieldAccess:Expr, steps:Array<Expr>):Void {
		final encodeExpr:Expr = makeIntEncodeExpr(encoding);
		final overflowMsg:String = 'length prefix exceeds width $width';
		steps.push(macro {
			final _v:Int = $fieldAccess.length;
			final _raw:String = $encodeExpr;
			if (_raw.length > $v{width}) throw new haxe.Exception($v{overflowMsg});
			output.writeString(StringTools.rpad(_raw, ' ', $v{width}));
		});
	}

	/**
	 * Build the encode expression that turns a local `_v:Int` into a
	 * String in the requested base. Dec delegates to `Std.string`; Oct
	 * runs an inline conversion loop (Haxe has no built-in octal
	 * formatter).
	 */
	private static function makeIntEncodeExpr(encoding:String):Expr {
		return switch encoding {
			case 'Dec': macro Std.string(_v);
			case 'Oct':
				macro {
					if (_v < 0)
						throw new haxe.Exception('negative int cannot be encoded as octal');
					var _rem:Int = _v;
					var _out:String = '';
					if (_rem == 0) _out = '0';
					else while (_rem > 0) {
						_out = String.fromCharCode('0'.code + (_rem & 7)) + _out;
						_rem = _rem >>> 3;
					}
					_out;
				};
			case _:
				Context.fatalError('BinaryWriterLowering: unsupported bin encoding "$encoding"', Context.currentPos());
				throw 'unreachable';
		};
	}

	private static function emitStarField(child:ShapeNode, typePath:String, fieldAccess:Expr, steps:Array<Expr>):Void {
		final inner:ShapeNode = child.children[0];
		if (inner.kind != Ref)
			Context.fatalError('BinaryWriterLowering: Star field must contain a Ref', Context.currentPos());
		final elemRefName:String = inner.annotations.get('base.ref');
		final elemFn:String = 'write${simpleName(elemRefName)}';
		final elemCall:Expr = {
			expr: ECall(macro $i{elemFn}, [macro _arr[_i], macro output]),
			pos: Context.currentPos(),
		};
		steps.push(macro {
			final _arr = $fieldAccess;
			var _i:Int = 0;
			while (_i < _arr.length) {
				$elemCall;
				_i++;
			}
		});
	}

	// -------- helpers --------

	private static function readMetaString(node:ShapeNode, tag:String):Null<String> {
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return null;
		for (entry in meta) if (entry.name == tag) {
			if (entry.params.length != 1) return null;
			return switch entry.params[0].expr {
				case EConst(CString(s, _)): s;
				case _: null;
			};
		}
		return null;
	}

	private static function simpleName(typePath:String):String {
		final idx:Int = typePath.lastIndexOf('.');
		return idx == -1 ? typePath : typePath.substring(idx + 1);
	}

	private static function packOf(typePath:String):Array<String> {
		final idx:Int = typePath.lastIndexOf('.');
		return idx == -1 ? [] : typePath.substring(0, idx).split('.');
	}
}
#end
