package unit.macro;

import anyparse.macro.CppLiteralGuard;
import haxe.macro.Expr;
import haxe.macro.Printer;

/**
 * A fixture class run through `CppLiteralGuard.rewriteFields` while the suite compiles, read back as text by the js
 * suite. Each fixture literal holds a different trigraph, so a raw spelling in the text names the one literal left as
 * written.
 */
final class CppLiteralGuardProbe {

	/**
	 * `text`: the fixture's fields printed after the rewrite; `stranded`: the literals the rewrite answers it had to
	 * leave as written, in walk order.
	 */
	public static macro function rewritten(): ExprOf<{ text: String, stranded: Array<String> }> {
		final fields: Array<Field> = (macro class Fixture {
			public static inline final INLINED: String = '??/';
			public static final INIT: String = "??'";

			public function body(): String {
				return '??=';
			}

			public function plain(): String {
				return 'a ?? b';
			}

			public function cases(s: String): String {
				return switch s {
					case '??(': '??)';
					case x if (x == '??<'): 'x';
					case _: '??>';
				}
			}

			public function interpolated(n: Int): String {
				return '??! $n';
			}

			public function native(): String {
				return untyped __cpp__('"??-"');
			}
		}).fields;
		final stranded: Array<String> = [
			for (e in CppLiteralGuard.rewriteFields(fields)) switch e.expr {
				case EConst(CString(s, _)): s;
				case _: '';
			}
		];
		final printer: Printer = new Printer();
		final text: String = [for (field in fields) printer.printField(field)].join('\n');
		return macro { text: $v{text}, stranded: $v{stranded} };
	}

}
