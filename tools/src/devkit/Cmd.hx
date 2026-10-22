package devkit;

import haxe.macro.Expr;
#if macro
import devkit.CmdTemplate.TemplateError;
import devkit.CmdTemplate.TemplatePart;
import haxe.macro.Context;
#end

/**
 * `cmd('git -C $repo log --format=%h $range')` — a `Command` whose argument vector the MACRO reads out of the template
 * at compile time (`CmdTemplate`), so no shell ever sees it and nothing needs quoting. A value interpolated as a whole
 * word is exactly one argument whatever it holds — spaces, quotes, `;`, `$` — and an `Array<String>` value filling a
 * whole word is one argument per element (none for an empty array); a value inside a larger word joins that word's text.
 * A null value throws when the command is built.
 */
@:nullSafety(Strict)
final class Cmd {

	/** The `Command` the string literal `template` describes. */
	public static macro function cmd(template: ExprOf<String>): ExprOf<Command> {
		final text: String = switch template.expr {
			case EConst(CString(s, _)): s;
			case _: Context.error('cmd takes a string literal template', template.pos);
		};
		final words: Array<Array<TemplatePart>> = try CmdTemplate.parse(text) catch (error: TemplateError) Context.error(
			'cmd: ${error.message}', at(template.pos, error.offset)
		);
		if (words.length == 0) Context.error('cmd: the template names no program', template.pos);
		final parts: Array<Expr> = [for (word in words) wordExpr(word, template.pos)];
		return macro devkit.Command.of(devkit.Command.flat([$a{parts}]));
	}

	#if macro
	/** The `Array<String>` expression of one template word. */
	private static function wordExpr(word: Array<TemplatePart>, pos: Position): Expr {
		switch word {
			case [Value(source, offset)]:
				final value: Expr = Context.parseInlineString(source, at(pos, offset));
				return isArray(value) ? macro devkit.Command.words($value, $v{source}) : macro [devkit.Command.word($value, $v{source})];
			case _:
				final pieces: Array<Expr> = [
					for (part in word)
						switch part {
							case Text(text): macro $v{text};
							case Value(source, offset):
								final value: Expr = Context.parseInlineString(source, at(pos, offset));
								if (isArray(value))
									Context.error('cmd: the array `$source` must fill a whole word to splice', at(pos, offset));
								macro devkit.Command.word($value, $v{source});
						}
				];
				// a word of nothing but quotes, `""`, is one empty argument
				var joined: Expr = pieces.length == 0 ? macro $v{''} : pieces[0];
				for (piece in pieces.slice(1)) joined = macro $joined + $piece;
				return macro [$joined];
		}
	}

	/** Whether `value` types as an array of strings — the one value type that splices into several arguments. */
	private static function isArray(value: Expr): Bool {
		return Context.unify(Context.typeof(value), Context.resolveType(macro :Array<String>, value.pos));
	}

	/** The position `offset` characters into the string literal at `pos` (past its opening quote). */
	private static function at(pos: Position, offset: Int): Position {
		final range: { min: Int, max: Int, file: String } = Context.getPosInfos(pos);
		return Context.makePosition({ file: range.file, min: range.min + 1 + offset, max: range.min + 2 + offset });
	}
	#end

}
