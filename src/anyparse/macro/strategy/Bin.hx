package anyparse.macro.strategy;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import anyparse.core.CoreIR;
import anyparse.core.LoweringCtx;
import anyparse.core.RuntimeContrib;
import anyparse.core.ShapeTree;
import anyparse.core.Strategy;

/**
 * Binary strategy — owns metadata for binary format fields.
 *
 * Metadata handled:
 *  - `@:bin(N:Int)` on a `String` field — read/write N bytes as a
 *    fixed-width ASCII string. Trailing spaces are stripped on parse
 *    and re-added on write (right-pad).
 *  - `@:bin(N:Int, enc:Ident)` on an `Int` field — read/write N bytes
 *    as ASCII-encoded integer. `enc` is one of `Dec` or `Oct`. On parse
 *    the slice is right-trimmed and decoded; on write the value is
 *    encoded in the given base and right-padded with spaces.
 *  - `@:bin("fieldName":String)` on a `Bytes` field — read/write a
 *    variable number of bytes determined by `parseInt(trim(fieldName))`.
 *  - `@:length(N:Int, enc:Ident)` on a `Bytes` field — a leading N-byte
 *    ASCII-encoded integer gives the payload length. Removes the need
 *    for an explicit AST-level `size` field paired with `@:bin("size")`.
 *  - `@:magic("...")` on a typedef — validate/emit a fixed magic
 *    prefix before the struct fields.
 *  - `@:align(N:Int)` on a typedef — pad each entry to an N-byte
 *    boundary after all fields.
 *
 * Pass 2 (annotate) writes results under the `bin.*` namespace on
 * the shape node; Lowering reads them back in pass 3.
 */
class Bin implements Strategy {

	public var name(default, null):String = 'Bin';
	public var runsAfter(default, null):Array<String> = [];
	public var runsBefore(default, null):Array<String> = [];
	public var ownedMeta(default, null):Array<String> = [':bin', ':magic', ':align', ':length'];
	public var runtimeContribution(default, null):RuntimeContrib = {ctxFields: [], helpers: [], cacheKeyContributors: []};

	public function new() {}

	public function appliesTo(node:ShapeNode):Bool {
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return false;
		for (entry in meta) switch entry.name {
			case ':bin' | ':magic' | ':align' | ':length': return true;
			case _:
		}
		return false;
	}

	public function annotate(node:ShapeNode, ctx:LoweringCtx):Void {
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return;
		for (entry in meta) switch entry.name {
			case ':bin':
				switch entry.params.length {
					case 1:
						switch entry.params[0].expr {
							case EConst(CInt(v)): node.annotations.set('bin.fixedLen', Std.parseInt(v));
							case EConst(CString(s, _)): node.annotations.set('bin.dataRef', s);
							case _:
								Context.fatalError('@:bin argument must be an Int literal or a String literal', entry.pos);
						}
					case 2:
						node.annotations.set('bin.fixedLen', intOrFail(entry.params[0], ':bin'));
						node.annotations.set('bin.encoding', readEncodingIdent(entry.params[1], 'bin'));
					case _:
						Context.fatalError('@:bin expects 1 argument (Int or String) or 2 arguments (Int, Dec|Oct)', entry.pos);
				}
			case ':length':
				if (entry.params.length != 2)
					Context.fatalError('@:length expects two arguments (Int, Dec|Oct)', entry.pos);
				node.annotations.set('bin.lengthPrefix', {
					width: intOrFail(entry.params[0], ':length'),
					encoding: readEncodingIdent(entry.params[1], 'length'),
				});
			case ':magic':
				if (entry.params.length != 1)
					Context.fatalError('@:magic expects exactly one string argument', entry.pos);
				node.annotations.set('bin.magic', stringOrFail(entry.params[0], ':magic'));
			case ':align':
				if (entry.params.length != 1)
					Context.fatalError('@:align expects exactly one int argument', entry.pos);
				node.annotations.set('bin.align', intOrFail(entry.params[0], ':align'));
			case _:
		}
	}

	public function lower(node:ShapeNode, ctx:LoweringCtx):Null<CoreIR> {
		return null;
	}

	private static function intOrFail(e:Expr, tag:String):Int {
		return switch e.expr {
			case EConst(CInt(v)): Std.parseInt(v);
			case _:
				Context.fatalError('$tag argument must be an Int literal', e.pos);
				throw 'unreachable';
		};
	}

	private static function stringOrFail(e:Expr, tag:String):String {
		return switch e.expr {
			case EConst(CString(s, _)): s;
			case _:
				Context.fatalError('$tag argument must be a string literal', e.pos);
				throw 'unreachable';
		};
	}

	private static function readEncodingIdent(param:Expr, tag:String):String {
		return switch param.expr {
			case EConst(CIdent('Dec')): 'Dec';
			case EConst(CIdent('Oct')): 'Oct';
			case _:
				Context.fatalError('@:$tag encoding must be the identifier Dec or Oct', param.pos);
				throw 'unreachable';
		};
	}
}
#end
